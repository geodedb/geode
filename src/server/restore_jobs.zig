//! Bounded in-process restore jobs. The owner must stop admission and join
//! workers before destroying the source store or any installed observer.
const std = @import("std");
const graph_store = @import("../graph_store.zig");
const backup = @import("storage/backup");

pub const State = enum { queued, running, completed, failed };
pub const Snapshot = struct {
    job_id: []const u8,
    restore_dir: []const u8,
    state: State,
    progress: backup.RestoreProgress,
    // Error names are static compiler-owned strings, never borrowed job storage.
    error_name: []const u8,
    finished_at_ms: u64,

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.restore_dir);
    }
};

// CANARY: REQ=REQ-SONNY-6300; FEATURE="Restore jobs"; ASPECT=WorkerLifetime; STATUS=TESTED; TEST=tests/test_sonny6300_restore_jobs.zig; OWNER=storage; UPDATED=2026-11-11
pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    join_mutex: std.Io.Mutex = .init,
    jobs: std.ArrayList(*Job) = .empty,
    closing: bool = false,
    /// Optional phase observer, valid until shutdown joins every worker.
    /// It runs outside the manager lock; no request allocator is retained.
    progress_observer: ?backup.RestoreObserver = null,
    pub const retained_jobs = 8;

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn start(self: *Manager, response_allocator: std.mem.Allocator, store: *graph_store.GraphStore, backup_dir: []const u8, live_dir: []const u8, target_time: i64) !Snapshot {
        return self.startRetained(response_allocator, store, backup_dir, live_dir, target_time, .history);
    }

    const Retention = enum { history, synchronous_waiter };

    pub fn startAndWait(self: *Manager, allocator: std.mem.Allocator, store: *graph_store.GraphStore, backup_dir: []const u8, live_dir: []const u8, target_time: i64) !Snapshot {
        const accepted = try self.startRetained(allocator, store, backup_dir, live_dir, target_time, .synchronous_waiter);
        defer accepted.deinit(allocator);
        defer {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.mutex.lockUncancelable(io);
            for (self.jobs.items) |job| {
                if (std.mem.eql(u8, &job.id, accepted.job_id)) {
                    job.pinned = false;
                    break;
                }
            }
            self.mutex.unlock(io);
        }
        return self.wait(allocator, accepted.job_id);
    }

    fn startRetained(self: *Manager, response_allocator: std.mem.Allocator, store: *graph_store.GraphStore, backup_dir: []const u8, live_dir: []const u8, target_time: i64, retention: Retention) !Snapshot {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closing) return error.RestoreJobsStopping;
        for (self.jobs.items) |job| {
            if (job.state == .queued or job.state == .running) return error.RestoreAlreadyRunning;
        }
        if (self.jobs.items.len == retained_jobs) {
            var eviction: ?usize = null;
            for (self.jobs.items, 0..) |job, index| {
                if (!job.pinned) {
                    eviction = index;
                    break;
                }
            }
            const old = self.jobs.orderedRemove(eviction orelse return error.RestoreJobCapacity);
            // Terminal state is the worker's last action under this mutex.
            // It never reacquires the mutex, so joining here cannot deadlock.
            if (old.thread) |thread| thread.join();
            old.destroy();
        }
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        const owned_backups = try self.allocator.dupe(u8, backup_dir);
        errdefer self.allocator.free(owned_backups);
        if (live_dir.len == 0) return error.LiveDirectoryUnavailable;
        const canonical_live = try std.Io.Dir.cwd().realPathFileAlloc(io, live_dir, self.allocator);
        defer self.allocator.free(canonical_live);
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const id = std.fmt.bytesToHex(random, .lower);
        const target = try std.fmt.allocPrint(self.allocator, "{s}.restored-{s}", .{ canonical_live, id });
        errdefer self.allocator.free(target);
        try backup.validateRestoreTarget(self.allocator, store, target);
        job.* = .{ .manager = self, .store = store, .id = id, .backup_dir = owned_backups, .target = target, .target_time = target_time, .pinned = retention == .synchronous_waiter };
        // Allocate the entire acceptance response before starting work: OOM
        // must not launch a job whose id could never be returned to the caller.
        const accepted = try job.snapshot(response_allocator);
        errdefer accepted.deinit(response_allocator);
        try self.jobs.append(self.allocator, job);
        errdefer _ = self.jobs.pop();
        job.thread = try std.Thread.spawn(.{}, Job.worker, .{job});
        return accepted;
    }

    pub fn get(self: *Manager, allocator: std.mem.Allocator, id: []const u8) !Snapshot {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        for (self.jobs.items) |job| {
            if (std.mem.eql(u8, &job.id, id)) return job.snapshot(allocator);
        }
        return error.RestoreJobNotFound;
    }

    /// Compatibility path for synchronous callers. Poll scalar state without
    /// allocating a new snapshot on every wait tick.
    fn wait(self: *Manager, allocator: std.mem.Allocator, id: []const u8) !Snapshot {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (true) {
            self.mutex.lockUncancelable(io);
            var found: ?*Job = null;
            for (self.jobs.items) |job| {
                if (std.mem.eql(u8, &job.id, id)) {
                    found = job;
                    break;
                }
            }
            const job = found orelse {
                self.mutex.unlock(io);
                return error.RestoreJobNotFound;
            };
            if (job.state == .completed or job.state == .failed) {
                const snapshot = job.snapshot(allocator);
                self.mutex.unlock(io);
                return snapshot;
            }
            self.mutex.unlock(io);
            try io.sleep(.fromMilliseconds(100), .awake);
        }
    }

    /// Refuse new jobs, then join workers without holding the status mutex.
    /// Status polling remains valid until the owner calls deinit.
    pub fn shutdown(self: *Manager) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.join_mutex.lockUncancelable(io);
        defer self.join_mutex.unlock(io);
        self.mutex.lockUncancelable(io);
        self.closing = true;
        self.mutex.unlock(io);
        // Closing makes the jobs array immutable; only worker status changes.
        for (self.jobs.items) |job| {
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
        }
    }

    /// Call after all requests have drained. Source store and observer may be
    /// freed after shutdown; snapshots already returned own their strings.
    pub fn deinit(self: *Manager) void {
        self.shutdown();
        for (self.jobs.items) |job| job.destroy();
        self.jobs.deinit(self.allocator);
    }
};

const Job = struct {
    manager: *Manager,
    store: *graph_store.GraphStore,
    id: [32]u8,
    backup_dir: []u8,
    target: []u8,
    target_time: i64,
    thread: ?std.Thread = null,
    state: State = .queued,
    pinned: bool = false,
    progress: backup.RestoreProgress = .{ .phase = .reading },
    error_name: []const u8 = "",
    finished_at_ms: u64 = 0,

    fn snapshot(self: *const Job, allocator: std.mem.Allocator) !Snapshot {
        const id = try allocator.dupe(u8, &self.id);
        errdefer allocator.free(id);
        return .{ .job_id = id, .restore_dir = try allocator.dupe(u8, self.target), .state = self.state, .progress = self.progress, .error_name = self.error_name, .finished_at_ms = self.finished_at_ms };
    }

    fn update(raw: *anyopaque, progress: backup.RestoreProgress) void {
        const self: *Job = @ptrCast(@alignCast(raw));
        const io = std.Io.Threaded.global_single_threaded.io();
        self.manager.mutex.lockUncancelable(io);
        self.progress = progress;
        self.manager.mutex.unlock(io);
        if (self.manager.progress_observer) |observer| observer.update(observer.context, progress);
    }

    fn restore(self: *Job) !void {
        var manager = try backup.BackupManager.init(self.manager.allocator, self.backup_dir, .{}, self.store);
        defer manager.deinit();
        try manager.restoreWithProgress(self.target, self.target_time, .{ .context = self, .update = update });
    }

    fn worker(self: *Job) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.manager.mutex.lockUncancelable(io);
        self.state = .running;
        self.manager.mutex.unlock(io);
        const failure: ?anyerror = if (self.restore()) |_| null else |err| err;
        // restore's defers (including adapter teardown) have all completed.
        self.manager.mutex.lockUncancelable(io);
        self.finished_at_ms = @intCast(@max(std.Io.Clock.real.now(io).toMilliseconds(), 0));
        self.state = if (failure == null) .completed else .failed;
        self.error_name = if (failure) |err| @errorName(err) else "";
        self.manager.mutex.unlock(io);
        // No manager access or callback after this terminal-state publication.
    }

    fn destroy(self: *Job) void {
        const allocator = self.manager.allocator;
        allocator.free(self.backup_dir);
        allocator.free(self.target);
        allocator.destroy(self);
    }
};
