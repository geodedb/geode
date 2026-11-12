// CANARY: REQ=REQ-SONNY-6300; FEATURE="Restore jobs"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6300_restore_jobs.zig; OWNER=storage; UPDATED=2026-11-11
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const jobs = geode.restore_jobs;
const backup = @import("storage/backup");
const Fixture = @import("support/restore_harness.zig").Fixture;

fn pause() void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
}

const Gate = struct {
    ready: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    fn update(raw: *anyopaque, progress: backup.RestoreProgress) void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        if (progress.phase != .syncing) return;
        self.ready.store(true, .release);
        while (!self.release.load(.acquire)) std.Thread.yield() catch {};
    }
    fn wait(self: *Gate) !void {
        for (0..60_000) |_| {
            if (self.ready.load(.acquire)) return;
            pause();
        }
        return error.RestoreProgressTimeout;
    }
};

fn terminal(manager: *jobs.Manager, id: []const u8) !jobs.Snapshot {
    for (0..60_000) |_| {
        const status = try manager.get(testing.allocator, id);
        if (status.state == .completed or status.state == .failed) return status;
        status.deinit(testing.allocator);
        pause();
    }
    return error.RestoreJobTimeout;
}

test "SONNY-6300 job acceptance is pending, status progresses and source request can expire" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var backup_manager = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer backup_manager.deinit();
    const meta = try backup_manager.createFullBackup();
    var manager = jobs.Manager.init(testing.allocator);
    defer manager.deinit();
    var gate = Gate{};
    defer gate.release.store(true, .release);
    manager.progress_observer = .{ .context = &gate, .update = Gate.update };
    var request = std.heap.ArenaAllocator.init(testing.allocator);
    const request_path = try request.allocator().dupe(u8, fixture.backups);
    const accepted = manager.start(testing.allocator, &fixture.store, request_path, fixture.live, meta.timestamp + 1) catch |err| {
        request.deinit();
        return err;
    };
    defer accepted.deinit(testing.allocator);
    request.deinit();
    try testing.expectEqual(jobs.State.queued, accepted.state);
    try gate.wait();
    const status = try manager.get(testing.allocator, accepted.job_id);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(jobs.State.running, status.state);
    try testing.expectEqual(backup.RestorePhase.syncing, status.progress.phase);
    try testing.expect(status.progress.total_files > 0);
    try testing.expectEqual(status.progress.total_files, status.progress.completed_files);
    try testing.expectError(error.RestoreAlreadyRunning, manager.start(testing.allocator, &fixture.store, fixture.backups, fixture.live, meta.timestamp + 1));
    gate.release.store(true, .release);
    manager.shutdown();
    const finished = try manager.get(testing.allocator, accepted.job_id);
    defer finished.deinit(testing.allocator);
    try testing.expectEqual(jobs.State.completed, finished.state);
    try testing.expectEqual(backup.RestorePhase.completed, finished.progress.phase);
    try testing.expectError(error.RestoreJobsStopping, manager.start(testing.allocator, &fixture.store, fixture.backups, fixture.live, meta.timestamp + 1));
    const restored = try geode.graph_storage_adapter.StorageAdapter.initForRestoreVerification(testing.allocator, finished.restore_dir);
    defer restored.deinit();
    try testing.expectEqual(@as(u64, 1), try restored.nodeCount("default"));
}

test "SONNY-6300 failed jobs remain errors and bounded history preserves owned responses" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var backup_manager = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer backup_manager.deinit();
    const meta = try backup_manager.createFullBackup();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/full_{x}.backup", .{ fixture.backups, meta.backup_id });
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(io, &byte, @sizeOf(backup.BackupHeader));
        byte[0] ^= 0xff;
        try file.writePositionalAll(io, &byte, @sizeOf(backup.BackupHeader));
    }
    var manager = jobs.Manager.init(testing.allocator);
    var live = true;
    defer if (live) manager.deinit();
    var first: ?jobs.Snapshot = null;
    defer if (first) |snapshot| snapshot.deinit(testing.allocator);
    for (0..jobs.Manager.retained_jobs + 1) |i| {
        const accepted = try manager.start(testing.allocator, &fixture.store, fixture.backups, fixture.live, meta.timestamp + 1);
        defer if (i != 0) accepted.deinit(testing.allocator);
        if (i == 0) first = accepted;
        const failed = try terminal(&manager, accepted.job_id);
        defer failed.deinit(testing.allocator);
        try testing.expectEqual(jobs.State.failed, failed.state);
        try testing.expectEqualStrings("BackupChecksumMismatch", failed.error_name);
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, failed.restore_dir, .{}));
    }
    try testing.expectError(error.RestoreJobNotFound, manager.get(testing.allocator, first.?.job_id));
    manager.deinit();
    live = false;
    // The acceptance response remains owned even after its job is evicted and
    // after the manager itself is destroyed.
    try testing.expectEqual(@as(usize, 32), first.?.job_id.len);
    try testing.expect(std.mem.indexOf(u8, first.?.restore_dir, ".restored-") != null);
}

const ShutdownRelease = struct {
    manager: *jobs.Manager,
    gate: *Gate,
    fn run(self: ShutdownRelease) void {
        while (true) {
            self.manager.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            const closing = self.manager.closing;
            self.manager.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            if (closing) break;
            std.Thread.yield() catch {};
        }
        self.gate.release.store(true, .release);
    }
};

test "SONNY-6300 shutdown drains the actual restore before the source can be destroyed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var backup_manager = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer backup_manager.deinit();
    const meta = try backup_manager.createFullBackup();
    var manager = jobs.Manager.init(testing.allocator);
    defer manager.deinit();
    var gate = Gate{};
    defer gate.release.store(true, .release);
    manager.progress_observer = .{ .context = &gate, .update = Gate.update };
    const accepted = try manager.start(testing.allocator, &fixture.store, fixture.backups, fixture.live, meta.timestamp + 1);
    defer accepted.deinit(testing.allocator);
    try gate.wait();
    const release = try std.Thread.spawn(.{}, ShutdownRelease.run, .{ShutdownRelease{ .manager = &manager, .gate = &gate }});
    manager.shutdown();
    release.join();
    const finished = try manager.get(testing.allocator, accepted.job_id);
    defer finished.deinit(testing.allocator);
    try testing.expectEqual(jobs.State.completed, finished.state);
    try testing.expectEqual(backup.RestorePhase.completed, finished.progress.phase);
}

test "SONNY-6300 synchronous compatibility waits for completion and a stable timestamp" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var backup_manager = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer backup_manager.deinit();
    const meta = try backup_manager.createFullBackup();
    var manager = jobs.Manager.init(testing.allocator);
    defer manager.deinit();
    const finished = try manager.startAndWait(testing.allocator, &fixture.store, fixture.backups, fixture.live, meta.timestamp + 1);
    defer finished.deinit(testing.allocator);
    try testing.expectEqual(jobs.State.completed, finished.state);
    try testing.expectEqual(backup.RestorePhase.completed, finished.progress.phase);
    try testing.expect(finished.finished_at_ms > 0);
    const polled = try manager.get(testing.allocator, finished.job_id);
    defer polled.deinit(testing.allocator);
    try testing.expectEqual(finished.finished_at_ms, polled.finished_at_ms);
}

test "SONNY-6300 restore job request and response fields survive actual protobuf encoding" {
    const protobuf = @import("protobuf");
    const schema = @import("schema");
    var request_bytes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer request_bytes.deinit();
    try protobuf.encode(&request_bytes.writer, testing.allocator, schema.RestoreRequest{ .async_restore = true, .job_id = "restore-job", .session_id = "admin-session" });
    var request_reader: std.Io.Reader = .fixed(request_bytes.written());
    var request = try protobuf.decode(schema.RestoreRequest, &request_reader, testing.allocator);
    defer request.deinit(testing.allocator);
    try testing.expect(request.async_restore);
    try testing.expectEqualStrings("restore-job", request.job_id);
    try testing.expectEqualStrings("admin-session", request.session_id);
    var response_bytes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer response_bytes.deinit();
    try protobuf.encode(&response_bytes.writer, testing.allocator, schema.RestoreResponse{ .success = false, .job_id = "restore-job", .job_state = "running", .phase = "syncing", .completed_files = 701, .total_files = 701 });
    var response_reader: std.Io.Reader = .fixed(response_bytes.written());
    var response = try protobuf.decode(schema.RestoreResponse, &response_reader, testing.allocator);
    defer response.deinit(testing.allocator);
    try testing.expect(!response.success);
    try testing.expectEqualStrings("running", response.job_state);
    try testing.expectEqualStrings("syncing", response.phase);
    try testing.expectEqual(@as(u64, 701), response.completed_files);
    try testing.expectEqual(@as(u64, 701), response.total_files);
}
