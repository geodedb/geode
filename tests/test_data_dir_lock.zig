// CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-002; FEATURE="DataDirLock"; ASPECT=Tests; STATUS=IMPL; TEST=self; OWNER=storage; UPDATED=2026-08-29
// ENG-3921: two `geode serve` processes can open the SAME data directory.
// Live-verified consequences: split-brain (each process holds its own
// in-memory store over one on-disk store) and silent data loss (last
// writer's snapshot wins).  The same hole lets offline CLI writers (e.g.
// `geode auth reseal --data-dir <live dir>`) mutate a running server's
// `__geode_security` graph.
//
// This file is the UNIT lane for the fix: it exercises the cross-process
// lock primitive in isolation.  The end-to-end proof (two real `geode
// serve` processes) lives in tests/test_datadir_lock_subprocess.zig.
//
// RED-first status
// ----------------
// `src/server/data_dir_lock.zig` DOES NOT EXIST YET, so this file does not
// compile and `zig build test-data-dir-lock` fails with (verified
// 2026-08-29):
//
//   error: failed to check cache: 'src/server/data_dir_lock.zig'
//          file_hash FileNotFound
//   Build Summary: 0/3 steps succeeded (1 failed)
//
// That compile failure IS the recorded RED evidence for this lane: the
// module the server must depend on is absent, which is exactly the defect.
// A behavioural (runtime) RED is additionally recorded by the subprocess
// test, which fails on observable server behaviour rather than on a
// missing file.
//
// API CONTRACT this file pins (implement `src/server/data_dir_lock.zig` to
// match; structural template is the sibling leaf module
// `src/server/data_dir_permissions.zig`):
//
//   pub const lock_filename: []const u8 = ".geode.lock";
//
//   pub const DataDirLock = struct {
//       /// Non-blocking acquire.  Creates `{data_dir}/.geode.lock` mode
//       /// 0o600, takes an exclusive advisory lock (flock semantics: the
//       /// lock is dropped by the kernel when the holding process dies,
//       /// so a SIGKILLed server leaves no stale lock), and writes the
//       /// holder pid into the file for diagnostics.
//       /// Returns error.DataDirLocked when another open file description
//       /// already holds it.
//       pub fn acquire(allocator: std.mem.Allocator, data_dir: []const u8) !DataDirLock;
//
//       /// Bounded handoff retry: re-attempts `acquire` until
//       /// `budget_ms` elapses.  budget_ms == 0 means "refuse
//       /// immediately" (no retry).
//       pub fn acquireWithTimeout(allocator: std.mem.Allocator, data_dir: []const u8, budget_ms: u64) !DataDirLock;
//
//       pub fn release(self: *DataDirLock) void;
//   };
//
// Acceptance criteria encoded below:
//   - acquire on a fresh dir succeeds and creates the lockfile
//   - the lockfile is mode 0o600 (it names a pid; not world-readable)
//   - the lockfile records the holder pid
//   - a SECOND acquire (separate open file description) is refused with
//     error.DataDirLocked  <-- the bug
//   - release() makes the dir acquirable again
//   - acquireWithTimeout(budget 0) refuses immediately (bounded, no hang)
//   - acquireWithTimeout(budget > 0) succeeds once the holder releases
//   - two distinct data dirs lock independently (no global lock)

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const data_dir_lock = @import("data_dir_lock");
const DataDirLock = data_dir_lock.DataDirLock;

const linux = std.os.linux;

/// std.testing.tmpDir hands back a sub_path relative to `.zig-cache/tmp`;
/// mirror tests/test_admin_bootstrap_hardening.zig so both leaf-module
/// suites resolve fixtures the same way.
fn tmpPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{sub_path});
}

fn lockPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, data_dir_lock.lock_filename });
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    } else {
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    const req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

test "acquire on a fresh data dir succeeds and creates the lockfile (ENG-3921)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);

    var lock = try DataDirLock.acquire(testing.allocator, dir);
    defer lock.release();

    const lock_file = try lockPath(testing.allocator, dir);
    defer testing.allocator.free(lock_file);

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().access(io, lock_file, .{});
}

test "lockfile is mode 0o600 (ENG-3921)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);

    var lock = try DataDirLock.acquire(testing.allocator, dir);
    defer lock.release();

    const lock_file = try lockPath(testing.allocator, dir);
    defer testing.allocator.free(lock_file);

    const io = std.Io.Threaded.global_single_threaded.io();
    var f = try std.Io.Dir.cwd().openFile(io, lock_file, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const mode: u32 = @intCast(st.permissions.toMode() & 0o777);
    try testing.expectEqual(@as(u32, 0o600), mode);
}

test "lockfile records the holder pid (ENG-3921)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);

    var lock = try DataDirLock.acquire(testing.allocator, dir);
    defer lock.release();

    const lock_file = try lockPath(testing.allocator, dir);
    defer testing.allocator.free(lock_file);

    const io = std.Io.Threaded.global_single_threaded.io();
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        lock_file,
        testing.allocator,
        std.Io.Limit.limited(64),
    );
    defer testing.allocator.free(contents);

    const trimmed = std.mem.trim(u8, contents, " \t\r\n\x00");
    const recorded = try std.fmt.parseInt(i64, trimmed, 10);
    try testing.expectEqual(@as(i64, @intCast(std.c.getpid())), recorded);
}

// THE REGRESSION TEST for ENG-3921.  flock is per open-file-description,
// so a second open() of the same lockfile conflicts even from within the
// same process — this is the exact contention two `geode serve` processes
// hit, reproduced without spawning anything.
test "second acquire on the same data dir is refused with DataDirLocked (ENG-3921 regression)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);

    var first = try DataDirLock.acquire(testing.allocator, dir);
    defer first.release();

    try testing.expectError(
        error.DataDirLocked,
        DataDirLock.acquire(testing.allocator, dir),
    );
}

test "release makes the data dir acquirable again (ENG-3921)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);

    var first = try DataDirLock.acquire(testing.allocator, dir);
    first.release();

    var second = try DataDirLock.acquire(testing.allocator, dir);
    defer second.release();
}

test "acquireWithTimeout with a zero budget refuses immediately (ENG-3921)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);

    var held = try DataDirLock.acquire(testing.allocator, dir);
    defer held.release();

    const started = nowMillis();
    try testing.expectError(
        error.DataDirLocked,
        DataDirLock.acquireWithTimeout(testing.allocator, dir, 0),
    );
    const elapsed = nowMillis() - started;
    // budget 0 == immediate refusal; generous ceiling so a loaded CI box
    // does not flake, but tight enough to catch an unbounded/blocking
    // flock (which would never return).
    try testing.expect(elapsed < 2_000);
}

const HandoffCtx = struct {
    dir: []const u8,
    lock: *DataDirLock,
};

fn releaseAfterDelay(ctx: *HandoffCtx) void {
    sleepMs(300);
    ctx.lock.release();
}

test "acquireWithTimeout waits out a holder inside its budget (ENG-3921)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);

    var held = try DataDirLock.acquire(testing.allocator, dir);
    var ctx = HandoffCtx{ .dir = dir, .lock = &held };

    // Handoff: the holder goes away 300ms in; a 10s budget leaves ~30x
    // headroom so this stays deterministic on a loaded runner.
    const t = try std.Thread.spawn(.{}, releaseAfterDelay, .{&ctx});
    defer t.join();

    var acquired = try DataDirLock.acquireWithTimeout(testing.allocator, dir, 10_000);
    defer acquired.release();
}

test "distinct data dirs lock independently (ENG-3921)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp_a = testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = testing.tmpDir(.{});
    defer tmp_b.cleanup();

    const dir_a = try tmpPath(testing.allocator, &tmp_a.sub_path);
    defer testing.allocator.free(dir_a);
    const dir_b = try tmpPath(testing.allocator, &tmp_b.sub_path);
    defer testing.allocator.free(dir_b);

    var lock_a = try DataDirLock.acquire(testing.allocator, dir_a);
    defer lock_a.release();
    var lock_b = try DataDirLock.acquire(testing.allocator, dir_b);
    defer lock_b.release();
}
