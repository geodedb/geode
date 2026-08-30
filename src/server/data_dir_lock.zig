// CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-001; FEATURE="DataDirLock"; ASPECT=CrossProcessExclusion; STATUS=TESTED; TEST=tests/test_data_dir_lock.zig; OWNER=storage; UPDATED=2026-08-29
//! ENG-3921: single-writer exclusion for a Geode data directory.
//!
//! Two `geode serve` processes used to be able to open the SAME `--data-dir`.
//! Each held its own in-memory store over one on-disk store (split-brain), and
//! the last snapshot written won (silent data loss). The same hole let offline
//! CLI writers (`geode auth reseal --data-dir <live dir>`) rewrite a running
//! server's `__geode_security` graph.
//!
//! Mechanism: a NON-BLOCKING advisory `flock(LOCK_EX | LOCK_NB)` on
//! `{data_dir}/.geode.lock` (`std.Io.File.tryLock`). Two properties matter:
//!
//!   1. The kernel drops the lock when the holding process dies **by any
//!      means**, SIGKILL included. There is therefore no staleness concept:
//!      no TTL, no pid-liveness probe, and no manual `rm the lockfile`
//!      recovery step for an operator to get wrong.
//!   2. The lock is per open file description, so a second `open()` of the
//!      same path conflicts even from within one process — which is what
//!      makes the primitive unit-testable without spawning anything.
//!
//! The holder pid is written into the file **after** the lock is taken, purely
//! so the refusal diagnostic can name the incumbent. It is advisory
//! information only: exclusion is decided by `flock`, never by the recorded
//! pid (a pid can be reused, truncated, or absent on a fresh file).
//!
//! Lives in its own leaf file — with no dependency on the heavy `geode` /
//! `logging` modules — so it can be exercised by lightweight unit tests
//! without dragging in the whole server module graph. Same structural shape as
//! the sibling `data_dir_permissions.zig`.

const std = @import("std");
const builtin = @import("builtin");

/// Lockfile name, created inside the data directory.
pub const lock_filename: []const u8 = ".geode.lock";

/// Env knob for the bounded handoff-retry budget, in milliseconds.
/// `0` means "refuse immediately" (no retry).
pub const timeout_env_var: [:0]const u8 = "GEODE_DATA_DIR_LOCK_TIMEOUT_MS";

/// Default handoff budget: a restart wants the outgoing process to finish its
/// shutdown flush before the incoming one gives up.
pub const default_timeout_ms: u64 = 15_000;

/// Upper bound on the env-supplied budget so a typo cannot wedge startup for
/// hours; mirrors the bounded-retry shape in `raft_consensus.zig`.
pub const max_timeout_ms: u64 = 600_000;

/// Retry step for `acquireWithTimeout`, matching the 250ms handoff step used
/// by the raft leadership-handoff retry loop.
const retry_step_ms: u64 = 250;

pub const Error = error{
    /// Another live open file description already holds the directory.
    DataDirLocked,
    /// The lockfile could not be created/opened, or the filesystem does not
    /// support advisory locks. Fail closed: callers refuse to start.
    DataDirLockUnavailable,
    OutOfMemory,
};

fn ioHandle() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn currentPid() i64 {
    if (comptime builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    }
    return @intCast(std.c.getpid());
}

fn nowMillis() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    } else {
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    }
    const ms = @as(i128, ts.sec) * 1000 + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_ms);
    return if (ms < 0) 0 else @intCast(ms);
}

fn sleepMillis(ms: u64) void {
    if (ms == 0) return;
    const req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

/// Resolve the handoff budget from `GEODE_DATA_DIR_LOCK_TIMEOUT_MS`, falling
/// back to `default_timeout_ms`. A malformed value is treated as "unset"
/// rather than as zero, so a typo never silently turns a restart handoff into
/// an immediate refusal. Clamped to `max_timeout_ms`.
pub fn timeoutFromEnv() u64 {
    const raw = std.c.getenv(timeout_env_var.ptr) orelse return default_timeout_ms;
    const text = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    if (text.len == 0) return default_timeout_ms;
    const parsed = std.fmt.parseInt(u64, text, 10) catch return default_timeout_ms;
    return @min(parsed, max_timeout_ms);
}

/// Best-effort read of the pid recorded in `{data_dir}/.geode.lock`, for
/// refusal diagnostics only. Returns null when the file is absent, empty, or
/// unparsable. NEVER gate exclusion on this — `flock` is the authority.
pub fn readHolderPid(allocator: std.mem.Allocator, data_dir: []const u8) ?i64 {
    const path = std.fs.path.join(allocator, &.{ data_dir, lock_filename }) catch return null;
    defer allocator.free(path);
    const io = ioHandle();
    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(64),
    ) catch return null;
    defer allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n\x00");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

pub const DataDirLock = struct {
    allocator: std.mem.Allocator,
    /// Owned `{data_dir}/.geode.lock` path; kept for diagnostics and freed by
    /// `release`.
    path: []u8,
    file: std.Io.File,
    locked: bool,
    released: bool = false,

    /// Non-blocking acquire. Creates `{data_dir}/.geode.lock` mode 0o600,
    /// takes an exclusive advisory lock, and records the holder pid.
    /// Returns `error.DataDirLocked` when another open file description
    /// already holds it.
    pub fn acquire(allocator: std.mem.Allocator, data_dir: []const u8) Error!DataDirLock {
        const io = ioHandle();

        const path = std.fs.path.join(allocator, &.{ data_dir, lock_filename }) catch
            return error.OutOfMemory;
        errdefer allocator.free(path);

        // `truncate = false`: never clobber an incumbent's recorded pid before
        // we know we own the lock.
        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .read = true,
        }) catch return error.DataDirLockUnavailable;
        errdefer file.close(io);

        // The file names a pid; keep it owner-only (matches the 0o700 data
        // dir hardening in data_dir_permissions.zig).
        if (comptime builtin.os.tag != .windows) {
            file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600)) catch {};
        }

        const held = file.tryLock(io, .exclusive) catch return error.DataDirLockUnavailable;
        if (!held) return error.DataDirLocked;

        var self = DataDirLock{
            .allocator = allocator,
            .path = path,
            .file = file,
            .locked = true,
        };
        self.writeHolderPid();
        return self;
    }

    /// Bounded handoff retry: re-attempts `acquire` until `budget_ms` elapses.
    /// `budget_ms == 0` means "refuse immediately" (no retry). Always
    /// terminates — the underlying acquire never blocks.
    pub fn acquireWithTimeout(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        budget_ms: u64,
    ) Error!DataDirLock {
        const deadline = nowMillis() +| budget_ms;
        while (true) {
            if (acquire(allocator, data_dir)) |lock| {
                return lock;
            } else |err| switch (err) {
                error.DataDirLocked => {},
                else => return err,
            }
            const now = nowMillis();
            if (now >= deadline) return error.DataDirLocked;
            sleepMillis(@min(retry_step_ms, deadline - now));
        }
    }

    /// Drop the lock and close the file. Idempotent. The lockfile itself is
    /// intentionally left on disk: unlinking it would race a concurrent
    /// acquirer that already has it open, handing the directory to two
    /// processes at once.
    pub fn release(self: *DataDirLock) void {
        if (self.released) return;
        self.released = true;
        const io = ioHandle();
        if (self.locked) {
            self.file.unlock(io);
            self.locked = false;
        }
        self.file.close(io);
        self.allocator.free(self.path);
        self.path = &.{};
    }

    /// Diagnostic-only: record the owning pid once the lock is held. Failures
    /// are ignored — a missing pid degrades the refusal message, never the
    /// exclusion guarantee.
    fn writeHolderPid(self: *DataDirLock) void {
        const io = ioHandle();
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}\n", .{currentPid()}) catch return;
        self.file.writePositionalAll(io, text, 0) catch return;
        // Truncate any longer pid left by a previous holder so the file
        // parses cleanly.
        self.file.setLength(io, text.len) catch {};
    }
};

// Tests live in tests/test_data_dir_lock.zig so this stays a leaf module with
// no test-time dependency on std.testing's tmpDir handle quirks; the
// end-to-end proof (two real `geode serve` processes) is in
// tests/test_datadir_lock_subprocess.zig.
