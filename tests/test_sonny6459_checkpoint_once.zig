// SONNY-6459 items 1 and 2: the persistence loop and the clean shutdown ran
// each checkpoint twice.
//
// Item 1: on every persistence tick `persistenceLoop` (src/graph_store.zig)
// ran the WAL checkpoint hook (`wal.checkpointHook` -> `saveToFileEx(true)` ->
// `adapter.checkpointAllLight()`) and then called
// `adapter.checkpointAllLight()` itself, so `checkpoints_total` rose by 2 per
// tick ("periodic WAL-triggered light checkpoint fired checkpoints_total=2,
// 4, 6, ...").
//
// Item 2: after "[shutdown] data flush complete" the FULL checkpoint ran a
// second time: `deinitGlobalStore` honoured the `g_clean_shutdown_flushed`
// latch, but `deinitGlobalAdapter` then ran `adapter.checkpointAll()` anyway,
// which re-wrote every graph's exact property index and the graph registry
// ("full checkpoint: exact-index persist decision" logged twice per graph).
// `stopPersistenceThread` also ran a light checkpoint just before that FULL
// one.
//
// The tests start a single-node server, write a node, and check from its log
// that every checkpoint run advances `checkpoints_total` by exactly one, that
// a SIGTERM runs the full checkpoint once per graph and no other checkpoint,
// that the shutdown reports its phase timings, and that the node is there
// after a restart on the same data directory.
//
// CANARY: REQ=REQ-SONNY-6459-CHECKPOINT-ONCE; FEATURE="Persistence"; ASPECT=OneCheckpointPerTickAndShutdown; STATUS=TESTED; TEST=tests/test_sonny6459_checkpoint_once.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");

const BINARY_PATH = geode_test_bin.geode_exe;
const ADMIN_PASSWORD = "Sonny Checkpoint Once Passphrase";
const STARTUP_DEADLINE_MS: i64 = 60_000;
const EXIT_DEADLINE_MS: i64 = 60_000;
const FIRED_MARKER = "checkpoint fired checkpoints_total=";
const FULL_DECISION_DEFAULT = "full checkpoint: exact-index persist decision graph=default ";
const SIGNAL_LINE = "[shutdown] signal received";
const FLUSH_DONE_PREFIX = "[shutdown] data flush complete (";
const TEARDOWN_DONE_PREFIX = "[shutdown] teardown complete (";

fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn setNonBlocking(file: std.Io.File) !void {
    const fd = file.handle;
    const flags = std.os.linux.fcntl(fd, std.posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return error.FcntlGetFailed;
    const new_flags = flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const rc = std.os.linux.fcntl(fd, std.posix.F.SETFL, new_flags);
    if (@as(isize, @bitCast(rc)) < 0) return error.FcntlSetFailed;
}

/// Non-blocking reap; true once `pid` is collected.
fn tryReap(pid: i32, flags: u32) bool {
    var status: u32 = undefined;
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return @as(isize, @bitCast(rc)) > 0;
}

const Server = struct {
    child: std.process.Child,
    out: std.ArrayList(u8) = .empty,

    fn drain(self: *Server, gpa: std.mem.Allocator, io: std.Io) void {
        var tmp: [8192]u8 = undefined;
        for ([_]?std.Io.File{ self.child.stdout, self.child.stderr }) |maybe| {
            const file = maybe orelse continue;
            while (true) {
                const n = file.readStreaming(io, &.{&tmp}) catch break;
                if (n == 0) break;
                self.out.appendSlice(gpa, tmp[0..n]) catch break;
            }
        }
    }

    /// SIGKILL and reap if still running; close the pipes.
    fn deinit(self: *Server, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = tryReap(pid, 0);
            self.child.id = null;
        }
        if (self.child.stdout) |f| f.close(io);
        if (self.child.stderr) |f| f.close(io);
        self.child.stdout = null;
        self.child.stderr = null;
        self.out.deinit(gpa);
    }
};

fn spawnServer(aa: std.mem.Allocator, io: std.Io, data_dir: []const u8, persist_interval: []const u8) !Server {
    const env = try aa.create(std.process.Environ.Map);
    env.* = std.process.Environ.Map.init(aa);
    try env.put("GEODE_AUTH_HMAC_KEY", "6459" ** 16);
    try env.put("GEODE_ADMIN_PASSWORD", ADMIN_PASSWORD);
    try env.put("GEODE_LSP_PORT", "0");
    if (posixGetenv("PATH")) |p| try env.put("PATH", p);
    if (posixGetenv("HOME")) |p| try env.put("HOME", p);
    if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);
    const args = [_][]const u8{
        BINARY_PATH,          "serve",          "--listen",     "127.0.0.1:0",
        "--data-dir",         data_dir,         "--log-level",  "info",
        "--persist-interval", persist_interval, "--lsp-port=0",
    };
    const child = std.process.spawn(io, .{ .argv = &args, .environ_map = env, .stdout = .pipe, .stderr = .pipe }) catch return error.SkipZigTest;
    try setNonBlocking(child.stdout.?);
    try setNonBlocking(child.stderr.?);
    return .{ .child = child };
}

fn waitReady(server: *Server, gpa: std.mem.Allocator, io: std.Io) !u16 {
    const deadline = nowMillis() + STARTUP_DEADLINE_MS;
    while (nowMillis() < deadline) {
        server.drain(gpa, io);
        if (std.mem.indexOf(u8, server.out.items, "[startup] server ready") != null) {
            return boundPort(server.out.items) orelse error.NoBoundPort;
        }
        sleepMs(100);
    }
    std.debug.print("server never became ready:\n{s}\n", .{server.out.items});
    return error.ServerNotReady;
}

/// The QUIC port from the server's JSON transport banner (`"port":<n>`).
fn boundPort(log: []const u8) ?u16 {
    const key = "\"port\":";
    const at = std.mem.indexOf(u8, log, key) orelse return null;
    var end = at + key.len;
    while (end < log.len and std.ascii.isDigit(log[end])) end += 1;
    return std.fmt.parseInt(u16, log[at + key.len .. end], 10) catch null;
}

/// Runs `gql` through `geode query` and returns its stdout.
fn runQuery(aa: std.mem.Allocator, port: u16, gql: []const u8) ![]const u8 {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const server = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{port});
    const result = try std.process.run(aa, threaded.io(), .{ .argv = &.{
        BINARY_PATH,                  "query", "--server", server,
        "--insecure-tls-skip-verify", "-U",    "geode",    "-P",
        ADMIN_PASSWORD,               gql,
    } });
    if (result.term != .exited or result.term.exited != 0 or std.mem.indexOf(u8, result.stdout, "\"status_class\":\"00000\"") == null) {
        std.debug.print("query failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ gql, result.stdout, result.stderr });
        return error.QueryFailed;
    }
    return result.stdout;
}

/// SIGTERM the server and wait for it to exit; returns the exit time.
fn sigtermAndWait(server: *Server, gpa: std.mem.Allocator, io: std.Io) !i64 {
    const pid = server.child.id.?;
    const t0 = nowMillis();
    try std.posix.kill(pid, std.posix.SIG.TERM);
    while (nowMillis() - t0 < EXIT_DEADLINE_MS) {
        server.drain(gpa, io);
        if (tryReap(pid, std.os.linux.W.NOHANG)) {
            server.child.id = null;
            server.drain(gpa, io);
            return nowMillis() - t0;
        }
        sleepMs(20);
    }
    server.drain(gpa, io);
    std.debug.print("server did not exit within {d} ms of SIGTERM:\n{s}\n", .{ EXIT_DEADLINE_MS, server.out.items });
    return error.NoExit;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        n += 1;
        from = at + needle.len;
    }
    return n;
}

/// The unsigned integer right after `prefix` in `line`, if any.
fn numberAfter(line: []const u8, prefix: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, line, prefix) orelse return null;
    const start = at + prefix.len;
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    return std.fmt.parseInt(u64, line[start..end], 10) catch null;
}

fn makeDataDir(tmp: *std.testing.TmpDir, aa: std.mem.Allocator, io: std.Io) ![]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    const data_dir = try std.fmt.allocPrint(aa, "{s}/data", .{dir});
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    return data_dir;
}

test "SONNY-6459 item 1: each persistence tick advances checkpoints_total by one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().access(io, BINARY_PATH, .{}) catch return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeDataDir(&tmp, aa, io);

    var server = try spawnServer(aa, io, data_dir, "500");
    defer server.deinit(gpa, io);
    const port = try waitReady(&server, gpa, io);
    _ = try runQuery(aa, port, "CREATE (:Sonny6459Tick {x: 1})");

    // Collect at least four logged checkpoint runs.
    const deadline = nowMillis() + 30_000;
    while (nowMillis() < deadline and countOccurrences(server.out.items, FIRED_MARKER) < 4) {
        server.drain(gpa, io);
        sleepMs(100);
    }
    _ = try sigtermAndWait(&server, gpa, io);
    const log = server.out.items;

    var totals: std.ArrayList(u64) = .empty;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        if (numberAfter(line, FIRED_MARKER)) |n| try totals.append(aa, n);
    }
    std.debug.print("logged checkpoints_total values: {any}\n", .{totals.items});
    if (totals.items.len < 4) {
        std.debug.print("fewer than four checkpoint runs were logged:\n{s}\n", .{log});
        return error.TooFewCheckpointRuns;
    }
    // Every checkpoint run logs one "... checkpoint fired" line, so on an idle
    // server consecutive values differ by exactly one.
    for (totals.items[1..], 0..) |n, i| {
        const prev = totals.items[i];
        if (n != prev + 1) {
            std.debug.print("checkpoints_total went from {d} to {d} between two logged checkpoint runs (expected +1)\n", .{ prev, n });
            return error.CheckpointRanTwicePerTick;
        }
    }
}

test "SONNY-6459 item 2: a clean shutdown runs the full checkpoint once, reports its phase timings, and keeps the data" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().access(io, BINARY_PATH, .{}) catch return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeDataDir(&tmp, aa, io);

    {
        var server = try spawnServer(aa, io, data_dir, "1000");
        defer server.deinit(gpa, io);
        const port = try waitReady(&server, gpa, io);
        _ = try runQuery(aa, port, "CREATE (:Sonny6459Shutdown {x: 1})");
        // A few persistence ticks so the shutdown lands on a running loop.
        var settle: usize = 0;
        while (settle < 25) : (settle += 1) {
            server.drain(gpa, io);
            sleepMs(100);
        }
        const exit_ms = try sigtermAndWait(&server, gpa, io);
        const log = server.out.items;
        const from = std.mem.indexOf(u8, log, SIGNAL_LINE) orelse {
            std.debug.print("no shutdown line in the log:\n{s}\n", .{log});
            return error.NoShutdownLine;
        };
        const shutdown_log = log[from..];
        std.debug.print("SIGTERM to exit {d} ms; shutdown log:\n{s}\n", .{ exit_ms, shutdown_log });

        var ok = true;
        const full_runs = countOccurrences(shutdown_log, FULL_DECISION_DEFAULT);
        if (full_runs != 1) {
            std.debug.print("the default graph's full checkpoint ran {d} times during the shutdown (expected 1)\n", .{full_runs});
            ok = false;
        }
        // The flush line names how many checkpoint runs the shutdown made up
        // to that point: the full checkpoint only (no light one before it).
        if (std.mem.indexOf(u8, shutdown_log, FLUSH_DONE_PREFIX)) |at| {
            const line_end = std.mem.indexOfScalarPos(u8, shutdown_log, at, '\n') orelse shutdown_log.len;
            const line = shutdown_log[at..line_end];
            const runs = numberAfter(line, "checkpoint runs since the signal: ");
            if (numberAfter(line, FLUSH_DONE_PREFIX) == null or runs == null or runs.? != 1) {
                std.debug.print("unexpected flush line (want its duration and 1 checkpoint run): {s}\n", .{line});
                ok = false;
            }
        } else {
            std.debug.print("no \"{s}<ms>...\" line\n", .{FLUSH_DONE_PREFIX});
            ok = false;
        }
        for ([_][]const u8{ "[shutdown] store closed (", TEARDOWN_DONE_PREFIX }) |prefix| {
            const at = std.mem.indexOf(u8, shutdown_log, prefix) orelse {
                std.debug.print("no \"{s}<ms>...\" line\n", .{prefix});
                ok = false;
                continue;
            };
            if (numberAfter(shutdown_log[at..], prefix) == null) {
                std.debug.print("\"{s}\" carries no duration\n", .{prefix});
                ok = false;
            }
        }
        if (!ok) return error.ShutdownCheckpointedMoreThanOnce;
    }

    // The committed node survives the shutdown.
    var server = try spawnServer(aa, io, data_dir, "1000");
    defer server.deinit(gpa, io);
    const port = try waitReady(&server, gpa, io);
    const out = try runQuery(aa, port, "MATCH (n:Sonny6459Shutdown) RETURN count(n) AS c");
    if (std.mem.indexOf(u8, out, "\"rows\":[{\"c\":1}]") == null) {
        std.debug.print("node missing after restart: {s}\n", .{out});
        return error.NodeLostAcrossShutdown;
    }
    _ = try sigtermAndWait(&server, gpa, io);
}
