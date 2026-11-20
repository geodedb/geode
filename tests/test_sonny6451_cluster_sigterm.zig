// SONNY-6451 item 3: after SIGTERM a cluster node's raft transport kept
// running past "[shutdown] data flush complete" (raft ticks, peer DNS
// re-resolution), and its teardown then wedged: "thread-pool deinit timed out
// after 2000ms with 2 active tasks" and the teardown watchdog force-exited the
// process 30 s later.
//
// Two causes. (1) `geode serve` stopped the ClusterCoordinator only in the
// `cluster_handle` defer, which runs after the final flush, so the raft loop,
// outbox drains and client poll / re-resolve thread were live through the
// flush and the teardown. (2) An inbound cluster connection handler parked on
// a live peer's raft stream never looked at the coordinator's shutdown flag
// (the `WouldBlock` loop in `dispatchRaftFrameFromAdaptedStream`), so the
// connection pool could not join it.
//
// The test starts nodes 1 and 2 of a three-node cluster on distinct loopback
// IPs (127.0.0.61-63) with CA-signed TLS (node 3 stays down; two of three
// elect), waits for a leader, then sends SIGTERM to node 1 while node 2
// keeps its raft stream to it open. Node 1 must exit within a bound well
// under the 30 s teardown watchdog, its log must show the cluster stopped
// before the flush, and no raft activity, pool-join timeout or watchdog exit
// may follow the flush.
//
// CANARY: REQ=REQ-SONNY-6451-CLUSTER-SIGTERM; FEATURE="DistributedCluster"; ASPECT=ShutdownStopsRaftBeforeFlush; STATUS=TESTED; TEST=tests/test_sonny6451_cluster_sigterm.zig; OWNER=distributed; UPDATED=2026-11-12

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");

const BINARY_PATH = geode_test_bin.geode_exe;
/// Loopback addresses no other cluster test uses, so the aggregate's parallel
/// shards cannot collide with test-cluster-steady-state / -replicable-mutations.
const NODE_IPS = [_][]const u8{ "127.0.0.61", "127.0.0.62" };
const PEERS = "127.0.0.61:4251,127.0.0.62:4251,127.0.0.63:4251";
const STARTUP_DEADLINE_MS: i64 = 60_000;
/// Exit bound after SIGTERM: well under the 30 s teardown watchdog that a
/// wedged teardown runs into.
const EXIT_BOUND_MS: i64 = 15_000;
const FLUSH_LINE = "[shutdown] data flush complete";
const CLUSTER_STOPPED_LINE = "[shutdown] cluster transport stopped";

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

fn runOpenssl(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpensslFailed;
}

const Certs = struct { dir: []const u8, ca: []const u8, leaf: []const u8, key: []const u8 };

fn makeCerts(aa: std.mem.Allocator, io: std.Io) !Certs {
    const spawn_gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(spawn_gpa, .{});
    defer threaded.deinit();
    const sio = threaded.io();
    runOpenssl(spawn_gpa, sio, &.{ "openssl", "version" }) catch return error.SkipZigTest;

    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6451-sigterm-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const j = struct {
        fn p(al: std.mem.Allocator, d: []const u8, f: []const u8) []const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f }) catch unreachable;
        }
    }.p;
    const ca_key = j(aa, dir, "ca.key");
    const ca = j(aa, dir, "ca.crt");
    const leaf_key = j(aa, dir, "leaf.key");
    const leaf_csr = j(aa, dir, "leaf.csr");
    const leaf = j(aa, dir, "leaf.crt");
    const ext = j(aa, dir, "leaf.ext");
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ext,
        .data = "subjectAltName=IP:127.0.0.61,IP:127.0.0.62,IP:127.0.0.63,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n",
    });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-sonny6451-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-new", "-key", leaf_key, "-subj", "/CN=geode-node", "-out", leaf_csr });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "x509", "-sha256", "-req", "-in", leaf_csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", leaf });
    return .{ .dir = dir, .ca = ca, .leaf = leaf, .key = leaf_key };
}

const Capture = struct {
    buf: std.ArrayList(u8) = .empty,
    fn drain(self: *Capture, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) void {
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&tmp}) catch return;
            if (n == 0) return;
            self.buf.appendSlice(gpa, tmp[0..n]) catch return;
        }
    }
};

fn drainAll(captures: []Capture, children: []std.process.Child, spawned: usize, gpa: std.mem.Allocator, io: std.Io) void {
    for (children[0..spawned], 0..) |*ch, i| {
        if (ch.stdout) |f| captures[i].drain(gpa, io, f);
        if (ch.stderr) |f| captures[i].drain(gpa, io, f);
    }
}

/// Non-blocking reap; true once `pid` is collected.
fn tryReap(pid: i32, flags: u32) bool {
    var status: u32 = undefined;
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return @as(isize, @bitCast(rc)) > 0;
}

fn teardown(children: []std.process.Child, captures: []Capture, spawned: usize, gpa: std.mem.Allocator, io: std.Io) void {
    for (children[0..spawned]) |*ch| {
        if (ch.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    }
    const deadline = nowMillis() + 5_000;
    while (nowMillis() < deadline) {
        drainAll(captures, children, spawned, gpa, io);
        var all_gone = true;
        for (children[0..spawned]) |*ch| {
            if (ch.id == null) continue;
            if (tryReap(ch.id.?, std.os.linux.W.NOHANG)) ch.id = null else all_gone = false;
        }
        if (all_gone) break;
        sleepMs(100);
    }
    for (children[0..spawned]) |*ch| {
        if (ch.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = tryReap(pid, 0);
            ch.id = null;
        }
        if (ch.stdout) |f| {
            f.close(io);
            ch.stdout = null;
        }
        if (ch.stderr) |f| {
            f.close(io);
            ch.stderr = null;
        }
    }
}

/// The role on node `id`'s last complete "[raft] node <id> state=<role>" line.
fn lastRole(buf: []const u8, id: usize) ?[]const u8 {
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "node {d} state=", .{id}) catch return null;
    var role: ?[]const u8 = null;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buf, start, '\n')) |end| {
        const line = buf[start..end];
        if (std.mem.indexOf(u8, line, prefix)) |pos| {
            var fields = std.mem.tokenizeAny(u8, line[pos + prefix.len ..], " \t\r");
            if (fields.next()) |r| role = r;
        }
        start = end + 1;
    }
    return role;
}

test "SONNY-6451: SIGTERM stops a cluster node's raft transport before the final flush and the node exits promptly" {
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
    const certs = makeCerts(aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer std.Io.Dir.cwd().deleteTree(io, certs.dir) catch {};

    var children: [2]std.process.Child = undefined;
    var spawned: usize = 0;
    var captures: [2]Capture = .{ .{}, .{} };
    defer for (&captures) |*c| c.buf.deinit(gpa);
    defer teardown(&children, &captures, spawned, gpa, io);

    for (0..2) |i| {
        const data_dir = try std.fmt.allocPrint(aa, "{s}/data{d}", .{ certs.dir, i + 1 });
        std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
        const listen = try std.fmt.allocPrint(aa, "{s}:3141", .{NODE_IPS[i]});
        const node_id = try std.fmt.allocPrint(aa, "{d}", .{i + 1});
        const args = [_][]const u8{
            BINARY_PATH,      "serve",   "--listen",    listen,
            "--cluster-port", "4251",    "--peers",     PEERS,
            "--data-dir",     data_dir,  "--cert",      certs.leaf,
            "--key",          certs.key, "--log-level", "info",
        };
        const env = try aa.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(aa);
        try env.put("GEODE_CLUSTER_TOKEN", "sonny6451-sigterm-token");
        try env.put("GEODE_AUTH_HMAC_KEY", "6451" ** 16);
        try env.put("GEODE_NODE_ID", node_id);
        try env.put("GEODE_PEERS", PEERS);
        try env.put("GEODE_CLUSTER_PORT", "4251");
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", NODE_IPS[i]);
        try env.put("GEODE_CLUSTER_CA_CERT", certs.ca);
        try env.put("GEODE_ADMIN_PASSWORD", "Sonny Sigterm Admin Passphrase");
        if (posixGetenv("PATH")) |p| try env.put("PATH", p);
        if (posixGetenv("HOME")) |p| try env.put("HOME", p);
        if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);
        children[i] = std.process.spawn(io, .{ .argv = &args, .environ_map = env, .stdout = .pipe, .stderr = .pipe }) catch return error.SkipZigTest;
        spawned += 1;
        try setNonBlocking(children[i].stdout.?);
        try setNonBlocking(children[i].stderr.?);
    }

    // Two of three elect a leader; the other is its follower.
    const startup_deadline = nowMillis() + STARTUP_DEADLINE_MS;
    var elected = false;
    while (nowMillis() < startup_deadline) : (sleepMs(200)) {
        drainAll(&captures, &children, spawned, gpa, io);
        const r1 = lastRole(captures[0].buf.items, 1) orelse continue;
        const r2 = lastRole(captures[1].buf.items, 2) orelse continue;
        const leader = std.mem.eql(u8, r1, "leader") or std.mem.eql(u8, r2, "leader");
        const follower = std.mem.eql(u8, r1, "follower") or std.mem.eql(u8, r2, "follower");
        if (leader and follower) {
            elected = true;
            break;
        }
    }
    if (!elected) {
        std.debug.print("no leader between nodes 1 and 2 in {d} ms\nnode1:\n{s}\nnode2:\n{s}\n", .{ STARTUP_DEADLINE_MS, captures[0].buf.items, captures[1].buf.items });
        return error.NoLeader;
    }
    // Let raft traffic flow on both directions' streams for a moment.
    var settle: usize = 0;
    while (settle < 10) : (settle += 1) {
        drainAll(&captures, &children, spawned, gpa, io);
        sleepMs(200);
    }

    // SIGTERM node 1 while node 2 is up.
    const pid1 = children[0].id.?;
    const t0 = nowMillis();
    try std.posix.kill(pid1, std.posix.SIG.TERM);
    var exited_ms: ?i64 = null;
    while (nowMillis() - t0 < 45_000) {
        drainAll(&captures, &children, spawned, gpa, io);
        if (tryReap(pid1, std.os.linux.W.NOHANG)) {
            children[0].id = null;
            exited_ms = nowMillis() - t0;
            break;
        }
        sleepMs(50);
    }
    drainAll(&captures, &children, spawned, gpa, io);
    const log1 = captures[0].buf.items;

    const flush_at = std.mem.indexOf(u8, log1, FLUSH_LINE) orelse {
        std.debug.print("node 1 never logged \"{s}\" (exit after {?d} ms)\n{s}\n", .{ FLUSH_LINE, exited_ms, log1 });
        return error.NoFinalFlush;
    };
    const after_flush = log1[flush_at..];
    var failed = false;
    if (exited_ms == null or exited_ms.? > EXIT_BOUND_MS) {
        std.debug.print("node 1 took {?d} ms to exit after SIGTERM (bound {d} ms)\n", .{ exited_ms, EXIT_BOUND_MS });
        failed = true;
    }
    const stopped_at = std.mem.indexOf(u8, log1, CLUSTER_STOPPED_LINE);
    if (stopped_at == null or stopped_at.? > flush_at) {
        std.debug.print("node 1 did not stop its cluster transport before the final flush\n", .{});
        failed = true;
    }
    for ([_][]const u8{ "[raft] node 1 state=", "thread-pool deinit timed out", "teardown watchdog: forcing process exit" }) |marker| {
        if (std.mem.indexOf(u8, after_flush, marker) != null) {
            std.debug.print("node 1 logged \"{s}\" after the final flush\n", .{marker});
            failed = true;
        }
    }
    if (failed) {
        std.debug.print("node 1 log after SIGTERM:\n{s}\n", .{log1[(std.mem.lastIndexOf(u8, log1[0..flush_at], "[shutdown] signal") orelse flush_at)..]});
        return error.UncleanClusterShutdown;
    }
}
