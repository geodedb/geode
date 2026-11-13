// SONNY-6456 item 1: the cluster health monitor had no liveness signal.
//
// `NodeInfo.last_heartbeat` was written only when a peer's entry was created
// (`ClusterCoordinator.init`, `parseNodeInfo`), never when the peer was heard
// from, so `healthPass` judged every peer unhealthy 5 s after start and
// logged "Node detected as failed" for each of them on every node, while the
// cluster was healthy, and a peer that really died was indistinguishable from
// one that was up.
//
// The test runs a real three-node cluster (the built geode, CA-signed TLS,
// loopback addresses 127.0.0.81-83 no other test uses):
//   1. with all three nodes up and a leader elected, no node may report any
//      peer failed over a window of more than twice the 5 s threshold;
//   2. after a follower is SIGKILLed, the leader (which expects a response to
//      every heartbeat) reports it failed, and nobody reports a live peer
//      failed;
//   3. after the follower restarts, the leader reports it active again.
//
// CANARY: REQ=REQ-SONNY-6456-CLUSTER-HEALTH-LIVENESS; FEATURE="DistributedCluster"; ASPECT=HealthLivenessFromRaftTraffic; STATUS=TESTED; TEST=tests/test_sonny6456_cluster_health_liveness.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const test_ports = @import("test_ports.zig");

const BINARY_PATH = geode_test_bin.geode_exe;
const NODE_IPS = [_][]const u8{ "127.0.0.81", "127.0.0.82", "127.0.0.83" };
const STARTUP_DEADLINE_MS: i64 = 60_000;
/// More than twice the 5 s unhealthy threshold.
const HEALTHY_WINDOW_MS: i64 = 12_000;
const FAILED_MARKER = "Node detected as failed node_id=";
const ACTIVE_MARKER = "Node is active again node_id=";

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

    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6456-health-{d}", .{std.os.linux.getpid()});
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
        .data = "subjectAltName=IP:127.0.0.81,IP:127.0.0.82,IP:127.0.0.83,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n",
    });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-sonny6456-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-new", "-key", leaf_key, "-subj", "/CN=geode-node", "-out", leaf_csr });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "x509", "-sha256", "-req", "-in", leaf_csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", leaf });
    return .{ .dir = dir, .ca = ca, .leaf = leaf, .key = leaf_key };
}

/// Non-blocking reap; true once `pid` is collected.
fn tryReap(pid: i32, flags: u32) bool {
    var status: u32 = undefined;
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return @as(isize, @bitCast(rc)) > 0;
}

const Cluster = struct {
    aa: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    certs: Certs,
    peers: []const u8,
    cport: []const u8,
    children: [3]?std.process.Child = .{ null, null, null },
    logs: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty },

    fn spawn(self: *Cluster, i: usize) !void {
        const data_dir = try std.fmt.allocPrint(self.aa, "{s}/data{d}", .{ self.certs.dir, i + 1 });
        std.Io.Dir.cwd().createDirPath(self.io, data_dir) catch {};
        const listen = try std.fmt.allocPrint(self.aa, "{s}:0", .{NODE_IPS[i]});
        const node_id = try std.fmt.allocPrint(self.aa, "{d}", .{i + 1});
        const args = [_][]const u8{
            BINARY_PATH,      "serve",        "--listen",    listen,
            "--cluster-port", self.cport,     "--peers",     self.peers,
            "--data-dir",     data_dir,       "--cert",      self.certs.leaf,
            "--key",          self.certs.key, "--log-level", "info",
        };
        const env = try self.aa.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(self.aa);
        try env.put("GEODE_CLUSTER_TOKEN", "sonny6456-health-token");
        try env.put("GEODE_AUTH_HMAC_KEY", "6456" ** 16);
        try env.put("GEODE_NODE_ID", node_id);
        try env.put("GEODE_PEERS", self.peers);
        try env.put("GEODE_CLUSTER_PORT", self.cport);
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", NODE_IPS[i]);
        try env.put("GEODE_CLUSTER_CA_CERT", self.certs.ca);
        try env.put("GEODE_ADMIN_PASSWORD", "Sonny Health Liveness Passphrase");
        try env.put("GEODE_LSP_PORT", "0");
        if (posixGetenv("PATH")) |p| try env.put("PATH", p);
        if (posixGetenv("HOME")) |p| try env.put("HOME", p);
        if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);
        const child = std.process.spawn(self.io, .{ .argv = &args, .environ_map = env, .stdout = .pipe, .stderr = .pipe }) catch return error.SkipZigTest;
        try setNonBlocking(child.stdout.?);
        try setNonBlocking(child.stderr.?);
        self.children[i] = child;
    }

    fn drain(self: *Cluster) void {
        var tmp: [8192]u8 = undefined;
        for (&self.children, 0..) |*maybe, i| {
            const ch = &(maybe.* orelse continue);
            for ([_]?std.Io.File{ ch.stdout, ch.stderr }) |mf| {
                const f = mf orelse continue;
                while (true) {
                    const n = f.readStreaming(self.io, &.{&tmp}) catch break;
                    if (n == 0) break;
                    self.logs[i].appendSlice(self.gpa, tmp[0..n]) catch break;
                }
            }
        }
    }

    fn closeChild(self: *Cluster, i: usize) void {
        const ch = &(self.children[i] orelse return);
        if (ch.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = tryReap(pid, 0);
        }
        if (ch.stdout) |f| f.close(self.io);
        if (ch.stderr) |f| f.close(self.io);
        self.children[i] = null;
    }

    fn deinit(self: *Cluster) void {
        for (&self.children, 0..) |*maybe, i| {
            if (maybe.*) |*ch| {
                if (ch.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            }
            _ = i;
        }
        const deadline = nowMillis() + 5_000;
        while (nowMillis() < deadline) {
            self.drain();
            var all_gone = true;
            for (&self.children) |*maybe| {
                const ch = &(maybe.* orelse continue);
                if (ch.id == null) continue;
                if (tryReap(ch.id.?, std.os.linux.W.NOHANG)) ch.id = null else all_gone = false;
            }
            if (all_gone) break;
            sleepMs(100);
        }
        for (0..3) |i| self.closeChild(i);
        for (&self.logs) |*l| l.deinit(self.gpa);
    }

    /// The role on node `i`'s last complete "[raft] node <id> state=<role>" line.
    fn lastRole(self: *Cluster, i: usize) ?[]const u8 {
        var prefix_buf: [48]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "node {d} state=", .{i + 1}) catch return null;
        const buf = self.logs[i].items;
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

    /// Index of the node whose latest role is leader, if the other live
    /// nodes follow it.
    fn settledLeader(self: *Cluster) ?usize {
        var leader: ?usize = null;
        for (0..3) |i| {
            if (self.children[i] == null) continue;
            const r = self.lastRole(i) orelse return null;
            if (std.mem.eql(u8, r, "leader")) {
                if (leader != null) return null;
                leader = i;
            } else if (!std.mem.eql(u8, r, "follower")) return null;
        }
        return leader;
    }
};

/// Count of `marker<id>` lines in `log` from byte `from` on.
fn countMarker(log: []const u8, from: usize, marker: []const u8, id: usize) usize {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}{d}", .{ marker, id }) catch return 0;
    var n: usize = 0;
    var pos = from;
    while (std.mem.indexOfPos(u8, log, pos, needle)) |at| {
        const end = at + needle.len;
        if (end >= log.len or !std.ascii.isDigit(log[end])) n += 1;
        pos = end;
    }
    return n;
}

fn dumpLogs(c: *Cluster) void {
    for (0..3) |i| {
        std.debug.print("---- node {d} (last role {s}) health lines ----\n", .{ i + 1, c.lastRole(i) orelse "?" });
        var it = std.mem.splitScalar(u8, c.logs[i].items, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "Node detected as failed") != null or
                std.mem.indexOf(u8, line, "Node is active again") != null)
                std.debug.print("  {s}\n", .{line});
        }
    }
}

test "SONNY-6456: the health monitor reports a peer failed only when it stops being heard from" {
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

    const cport_num = try test_ports.freeUdpPort();
    var c: Cluster = .{
        .aa = aa,
        .gpa = gpa,
        .io = io,
        .certs = certs,
        .cport = try std.fmt.allocPrint(aa, "{d}", .{cport_num}),
        .peers = try std.fmt.allocPrint(aa, "{s}:{d},{s}:{d},{s}:{d}", .{ NODE_IPS[0], cport_num, NODE_IPS[1], cport_num, NODE_IPS[2], cport_num }),
    };
    defer c.deinit();
    for (0..3) |i| try c.spawn(i);

    // 1. A leader and two followers.
    var leader: ?usize = null;
    const startup_deadline = nowMillis() + STARTUP_DEADLINE_MS;
    while (nowMillis() < startup_deadline) : (sleepMs(200)) {
        c.drain();
        leader = c.settledLeader();
        if (leader != null) break;
    }
    const li = leader orelse {
        dumpLogs(&c);
        return error.NoLeader;
    };

    // With everyone up, nobody reports anybody failed over > 2x the threshold.
    const window_end = nowMillis() + HEALTHY_WINDOW_MS;
    while (nowMillis() < window_end) : (sleepMs(200)) c.drain();
    var spurious: usize = 0;
    for (0..3) |i| {
        for (1..4) |id| spurious += countMarker(c.logs[i].items, 0, FAILED_MARKER, id);
    }
    if (spurious != 0) {
        std.debug.print("{d} \"Node detected as failed\" report(s) while all three nodes were up\n", .{spurious});
        dumpLogs(&c);
        return error.SpuriousPeerFailure;
    }

    // 2. SIGKILL a follower: the leader reports it failed.
    const fi: usize = (li + 1) % 3;
    const other: usize = (li + 2) % 3;
    var marks: [3]usize = undefined;
    for (0..3) |i| marks[i] = c.logs[i].items.len;
    c.closeChild(fi);
    const fail_deadline = nowMillis() + 20_000;
    while (nowMillis() < fail_deadline) : (sleepMs(200)) {
        c.drain();
        if (countMarker(c.logs[li].items, marks[li], FAILED_MARKER, fi + 1) > 0) break;
    }
    c.drain();
    if (countMarker(c.logs[li].items, marks[li], FAILED_MARKER, fi + 1) == 0) {
        std.debug.print("leader node {d} never reported killed node {d} failed\n", .{ li + 1, fi + 1 });
        dumpLogs(&c);
        return error.DeadPeerNotReported;
    }
    // Nobody reports a live node failed.
    const live_reports = countMarker(c.logs[li].items, 0, FAILED_MARKER, other + 1) +
        countMarker(c.logs[other].items, 0, FAILED_MARKER, li + 1);
    if (live_reports != 0) {
        std.debug.print("a live node was reported failed\n", .{});
        dumpLogs(&c);
        return error.SpuriousPeerFailure;
    }

    // 3. Restart it: the leader reports it active again (if it is still
    // the leader; a re-election hands the expectation to the new leader).
    try c.spawn(fi);
    const back_deadline = nowMillis() + 30_000;
    var back = false;
    while (nowMillis() < back_deadline) : (sleepMs(200)) {
        c.drain();
        for (0..3) |i| {
            if (i == fi) continue;
            if (countMarker(c.logs[i].items, marks[i], ACTIVE_MARKER, fi + 1) > 0) back = true;
        }
        if (back) break;
    }
    if (!back) {
        std.debug.print("no node reported restarted node {d} active again\n", .{fi + 1});
        dumpLogs(&c);
        return error.RestartedPeerNotActive;
    }
    std.debug.print("leader node {d}, killed and restarted node {d}\n", .{ li + 1, fi + 1 });
    dumpLogs(&c);
}
