// SONNY-6456 item 4: SIGTERM stalled for seconds before the final flush.
//
// The persistence loop (src/graph_store.zig `persistenceLoop`) and the final
// flush in `stopPersistenceThread` took the default graph's READ lock
// (`acquireGraphReadLockTagged(DEFAULT_GRAPH_NAME, .misc)`) around the WAL
// checkpoint hook. That hook (`wal.checkpointHook` -> `saveToFileEx(true)` ->
// `checkpointAllLight` -> `checkpointOneGraph`) takes each graph's EXCLUSIVE
// lock, so for the default graph it waited on the read lock its own thread
// held until its 5 s deadline ran out and then skipped the graph: "bounded
// checkpoint skipped: rwlock busy past deadline graph=default
// rwlock_state=4294967296" (one reader) on every persistence tick, so the
// default graph's periodic light checkpoint never landed. At SIGTERM,
// `stopPersistenceThread` waited for the tick in progress to run out its
// deadline and then ran into the same wait again in its final flush: ~8.6 s
// before the clean-shutdown flush began on an idle server.
//
// The test starts an idle single-node server whose default graph holds a node
// (so the graph has an engine to checkpoint) with a 1 s persistence interval,
// and an idle cluster node (two configured peers that are down), sends each
// SIGTERM, and asserts the persistence thread stops within 3 s, the process
// exits within 10 s, and no light checkpoint of the default graph was skipped.
//
// CANARY: REQ=REQ-SONNY-6456-SHUTDOWN-PERSISTENCE-STOP; FEATURE="Persistence"; ASPECT=PersistenceStopIsPrompt; STATUS=TESTED; TEST=tests/test_sonny6456_shutdown_persistence_stop.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const test_ports = @import("test_ports.zig");

const BINARY_PATH = geode_test_bin.geode_exe;
const ADMIN_PASSWORD = "Sonny Shutdown Persistence Passphrase";
/// Loopback addresses no other cluster test uses.
const CLUSTER_IP = "127.0.0.71";
const STARTUP_DEADLINE_MS: i64 = 60_000;
/// Bound on "[shutdown] persistence thread stopped (<n>ms)".
const PERSISTENCE_STOP_BOUND_MS: i64 = 3_000;
/// Bound on SIGTERM to process exit for an idle server (the clean-shutdown
/// full checkpoint and the teardown are included; both are sub-second idle).
const EXIT_BOUND_MS: i64 = 10_000;
const STOPPED_PREFIX = "[shutdown] persistence thread stopped (";
const SKIP_MARKER = "bounded checkpoint skipped";

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

fn spawnServer(aa: std.mem.Allocator, io: std.Io, args: []const []const u8, cluster_env: bool, cluster_port: []const u8, peers: []const u8) !Server {
    const env = try aa.create(std.process.Environ.Map);
    env.* = std.process.Environ.Map.init(aa);
    try env.put("GEODE_AUTH_HMAC_KEY", "6456" ** 16);
    try env.put("GEODE_ADMIN_PASSWORD", ADMIN_PASSWORD);
    try env.put("GEODE_LSP_PORT", "0");
    if (cluster_env) {
        try env.put("GEODE_CLUSTER_TOKEN", "sonny6456-shutdown-token");
        try env.put("GEODE_NODE_ID", "1");
        try env.put("GEODE_PEERS", peers);
        try env.put("GEODE_CLUSTER_PORT", cluster_port);
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", CLUSTER_IP);
    }
    if (posixGetenv("PATH")) |p| try env.put("PATH", p);
    if (posixGetenv("HOME")) |p| try env.put("HOME", p);
    if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);
    const child = std.process.spawn(io, .{ .argv = args, .environ_map = env, .stdout = .pipe, .stderr = .pipe }) catch return error.SkipZigTest;
    try setNonBlocking(child.stdout.?);
    try setNonBlocking(child.stderr.?);
    return .{ .child = child };
}

fn waitForLine(server: *Server, gpa: std.mem.Allocator, io: std.Io, needle: []const u8, deadline_ms: i64) bool {
    const deadline = nowMillis() + deadline_ms;
    while (nowMillis() < deadline) {
        server.drain(gpa, io);
        if (std.mem.indexOf(u8, server.out.items, needle) != null) return true;
        sleepMs(100);
    }
    return false;
}

/// The QUIC port from the server's JSON transport banner (`"port":<n>`).
fn boundPort(log: []const u8) ?u16 {
    const key = "\"port\":";
    const at = std.mem.indexOf(u8, log, key) orelse return null;
    var end = at + key.len;
    while (end < log.len and std.ascii.isDigit(log[end])) end += 1;
    return std.fmt.parseInt(u16, log[at + key.len .. end], 10) catch null;
}

fn runQuery(aa: std.mem.Allocator, port: u16, gql: []const u8) !void {
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
}

const Outcome = struct { exit_ms: ?i64, persistence_stop_ms: ?i64 };

/// SIGTERM the server and collect it; returns the exit time and the logged
/// persistence-stop time.
fn sigtermAndMeasure(server: *Server, gpa: std.mem.Allocator, io: std.Io) !Outcome {
    const pid = server.child.id.?;
    const t0 = nowMillis();
    try std.posix.kill(pid, std.posix.SIG.TERM);
    var exit_ms: ?i64 = null;
    while (nowMillis() - t0 < 45_000) {
        server.drain(gpa, io);
        if (tryReap(pid, std.os.linux.W.NOHANG)) {
            server.child.id = null;
            exit_ms = nowMillis() - t0;
            break;
        }
        sleepMs(20);
    }
    server.drain(gpa, io);
    const log = server.out.items;
    var stop_ms: ?i64 = null;
    if (std.mem.indexOf(u8, log, STOPPED_PREFIX)) |at| {
        const start = at + STOPPED_PREFIX.len;
        var end = start;
        while (end < log.len and std.ascii.isDigit(log[end])) end += 1;
        stop_ms = std.fmt.parseInt(i64, log[start..end], 10) catch null;
    }
    return .{ .exit_ms = exit_ms, .persistence_stop_ms = stop_ms };
}

fn check(name: []const u8, outcome: Outcome, log: []const u8) bool {
    var ok = true;
    std.debug.print("{s}: SIGTERM to exit {?d} ms, persistence thread stop {?d} ms\n", .{ name, outcome.exit_ms, outcome.persistence_stop_ms });
    if (outcome.persistence_stop_ms == null or outcome.persistence_stop_ms.? > PERSISTENCE_STOP_BOUND_MS) {
        std.debug.print("{s}: persistence thread stop missing or over {d} ms\n", .{ name, PERSISTENCE_STOP_BOUND_MS });
        ok = false;
    }
    if (outcome.exit_ms == null or outcome.exit_ms.? > EXIT_BOUND_MS) {
        std.debug.print("{s}: exit missing or over {d} ms\n", .{ name, EXIT_BOUND_MS });
        ok = false;
    }
    if (std.mem.indexOf(u8, log, SKIP_MARKER) != null) {
        std.debug.print("{s}: a light checkpoint was skipped (\"{s}\")\n", .{ name, SKIP_MARKER });
        ok = false;
    }
    if (!ok) {
        const from = std.mem.indexOf(u8, log, "[shutdown] signal") orelse 0;
        var it = std.mem.splitScalar(u8, log, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, SKIP_MARKER) != null) std.debug.print("  {s}\n", .{line});
        }
        std.debug.print("{s} log after SIGTERM:\n{s}\n", .{ name, log[from..] });
    }
    return ok;
}

test "SONNY-6456: SIGTERM stops the persistence thread promptly on an idle single-node server with a default graph" {
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
    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    const data_dir = try std.fmt.allocPrint(aa, "{s}/data", .{dir});
    try std.Io.Dir.cwd().createDirPath(io, data_dir);

    const args = [_][]const u8{
        BINARY_PATH,          "serve",  "--listen",     "127.0.0.1:0",
        "--data-dir",         data_dir, "--log-level",  "info",
        "--persist-interval", "1000",   "--lsp-port=0",
    };
    var server = try spawnServer(aa, io, &args, false, "", "");
    defer server.deinit(gpa, io);
    if (!waitForLine(&server, gpa, io, "[startup] server ready", STARTUP_DEADLINE_MS)) {
        std.debug.print("server never became ready:\n{s}\n", .{server.out.items});
        return error.ServerNotReady;
    }
    const port = boundPort(server.out.items) orelse return error.NoBoundPort;
    // A node in the default graph gives it a storage engine to checkpoint.
    try runQuery(aa, port, "CREATE (:Sonny6456 {x: 1})");
    // Several persistence ticks, so SIGTERM lands while one is running.
    var settle: usize = 0;
    while (settle < 70) : (settle += 1) {
        server.drain(gpa, io);
        sleepMs(100);
    }

    const outcome = try sigtermAndMeasure(&server, gpa, io);
    if (!check("single-node", outcome, server.out.items)) return error.SlowPersistenceStop;
}

test "SONNY-6456: SIGTERM stops the persistence thread promptly on an idle cluster node" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (posixGetenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) return error.SkipZigTest;
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
    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    const data_dir = try std.fmt.allocPrint(aa, "{s}/data", .{dir});
    try std.Io.Dir.cwd().createDirPath(io, data_dir);

    const cport_num = try test_ports.freeUdpPort();
    const cport = try std.fmt.allocPrint(aa, "{d}", .{cport_num});
    // Nodes 2 and 3 are configured but down: node 1 stays idle.
    const peers = try std.fmt.allocPrint(aa, "{s}:{d},127.0.0.72:{d},127.0.0.73:{d}", .{ CLUSTER_IP, cport_num, cport_num, cport_num });
    const listen = try std.fmt.allocPrint(aa, "{s}:0", .{CLUSTER_IP});
    const args = [_][]const u8{
        BINARY_PATH,          "serve",  "--listen",     listen,
        "--cluster-port",     cport,    "--peers",      peers,
        "--data-dir",         data_dir, "--log-level",  "info",
        "--persist-interval", "1000",   "--lsp-port=0",
    };
    var server = try spawnServer(aa, io, &args, true, cport, peers);
    defer server.deinit(gpa, io);
    if (!waitForLine(&server, gpa, io, "[startup] server ready", STARTUP_DEADLINE_MS)) {
        std.debug.print("cluster node never became ready:\n{s}\n", .{server.out.items});
        return error.ServerNotReady;
    }
    var settle: usize = 0;
    while (settle < 70) : (settle += 1) {
        server.drain(gpa, io);
        sleepMs(100);
    }

    const outcome = try sigtermAndMeasure(&server, gpa, io);
    if (!check("cluster node", outcome, server.out.items)) return error.SlowPersistenceStop;
}
