// SONNY-6459 item 3: SHOW CLUSTER STATUS reported every peer's
// last_contact_ms as the time since the node started.
//
// `executeShowClusterStatus` (src/execution/admin_ddl.zig) reports
// `now - Peer.last_contact` for each peer in `coord.raft.peers`, but
// `Peer.last_contact` (src/distributed/raft_consensus.zig) was written only
// when the peer list was built (`resolvePeers`, at startup) and never again,
// so the column grew from start whether the peer was up or down.
//
// The test runs a real three-node cluster (the built geode, CA-signed TLS,
// loopback addresses 127.0.0.91-93 no other test uses) and asks the leader
// for SHOW CLUSTER STATUS through `geode query`:
//   1. with every node up, well after start, each peer's last_contact_ms is
//      below the 5 s health threshold;
//   2. after a follower is SIGKILLed, the leader reports a growing
//      last_contact_ms for it (past the threshold) and a small one for the
//      follower that is still up.
//
// CANARY: REQ=REQ-SONNY-6459-CLUSTER-LAST-CONTACT; FEATURE="SHOW CLUSTER STATUS"; ASPECT=LastContactFromRaftTraffic; STATUS=TESTED; TEST=tests/test_sonny6459_cluster_last_contact.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const test_ports = @import("test_ports.zig");

const BINARY_PATH = geode_test_bin.geode_exe;
const NODE_IPS = [_][]const u8{ "127.0.0.91", "127.0.0.92", "127.0.0.93" };
const ADMIN_PASSWORD = "Sonny Cluster Last Contact Passphrase";
const STARTUP_DEADLINE_MS: i64 = 60_000;
/// How long the cluster runs before the first SHOW CLUSTER STATUS: well
/// past the threshold below, so a last_contact_ms measured from startup
/// cannot pass.
const SETTLE_MS: i64 = 9_000;
/// The health monitor's unhealthy threshold.
const FRESH_BOUND_MS: i64 = 5_000;

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

    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6459-last-contact-{d}", .{std.os.linux.getpid()});
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
        .data = "subjectAltName=IP:127.0.0.91,IP:127.0.0.92,IP:127.0.0.93,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n",
    });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-sonny6459-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
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
    client_ports: [3]u16,
    children: [3]?std.process.Child = .{ null, null, null },
    logs: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty },

    fn spawn(self: *Cluster, i: usize) !void {
        const data_dir = try std.fmt.allocPrint(self.aa, "{s}/data{d}", .{ self.certs.dir, i + 1 });
        std.Io.Dir.cwd().createDirPath(self.io, data_dir) catch {};
        const listen = try std.fmt.allocPrint(self.aa, "{s}:{d}", .{ NODE_IPS[i], self.client_ports[i] });
        const node_id = try std.fmt.allocPrint(self.aa, "{d}", .{i + 1});
        const args = [_][]const u8{
            BINARY_PATH,      "serve",        "--listen",    listen,
            "--cluster-port", self.cport,     "--peers",     self.peers,
            "--data-dir",     data_dir,       "--cert",      self.certs.leaf,
            "--key",          self.certs.key, "--log-level", "info",
            "--lsp-port=0",
        };
        const env = try self.aa.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(self.aa);
        try env.put("GEODE_CLUSTER_TOKEN", "sonny6459-last-contact-token");
        try env.put("GEODE_AUTH_HMAC_KEY", "6459" ** 16);
        try env.put("GEODE_NODE_ID", node_id);
        try env.put("GEODE_PEERS", self.peers);
        try env.put("GEODE_CLUSTER_PORT", self.cport);
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", NODE_IPS[i]);
        try env.put("GEODE_CLUSTER_CA_CERT", self.certs.ca);
        try env.put("GEODE_ADMIN_PASSWORD", ADMIN_PASSWORD);
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
        for (&self.children) |*maybe| {
            if (maybe.*) |*ch| {
                if (ch.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            }
        }
        const deadline = nowMillis() + 15_000;
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

    /// The client QUIC port node `i` listens on, once it is serving.
    fn clientPort(self: *Cluster, i: usize) ?u16 {
        if (std.mem.indexOf(u8, self.logs[i].items, "[startup] server ready") == null) return null;
        return self.client_ports[i];
    }
};

/// A free UDP port that is not `taken` (each node listens on its own
/// address, so the three client ports need only differ from the cluster
/// port).
fn portOtherThan(taken: u16) !u16 {
    while (true) {
        const p = try test_ports.freeUdpPort();
        if (p != taken) return p;
    }
}

/// last_contact_ms per node id (index id-1), from node `i`'s SHOW CLUSTER
/// STATUS; null where a row is missing.
fn showLastContact(c: *Cluster, i: usize) ![3]?i64 {
    const port = c.clientPort(i) orelse return error.NoClientPort;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const server = try std.fmt.allocPrint(c.aa, "{s}:{d}", .{ NODE_IPS[i], port });
    const result = try std.process.run(c.aa, threaded.io(), .{ .argv = &.{
        BINARY_PATH, "query",        "--server",            server,
        "--ca-cert", c.certs.ca,     "-U",                  "geode",
        "-P",        ADMIN_PASSWORD, "SHOW CLUSTER STATUS",
    } });
    if (result.term != .exited or result.term.exited != 0 or std.mem.indexOf(u8, result.stdout, "\"status_class\":\"00000\"") == null) {
        std.debug.print("SHOW CLUSTER STATUS failed on node {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ i + 1, result.stdout, result.stderr });
        return error.QueryFailed;
    }
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.aa, result.stdout, .{});
    const rows = parsed.object.get("rows") orelse return error.NoRows;
    var out: [3]?i64 = .{ null, null, null };
    for (rows.array.items) |row| {
        const id = row.object.get("node_id") orelse continue;
        const lc = row.object.get("last_contact_ms") orelse continue;
        if (id != .integer or lc != .integer) continue;
        if (id.integer >= 1 and id.integer <= 3) out[@intCast(id.integer - 1)] = lc.integer;
    }
    std.debug.print("node {d} SHOW CLUSTER STATUS last_contact_ms: {any}\n", .{ i + 1, out });
    return out;
}

test "SONNY-6459 item 3: SHOW CLUSTER STATUS last_contact_ms follows raft traffic on a real three-node cluster" {
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
        .client_ports = .{ try portOtherThan(cport_num), try portOtherThan(cport_num), try portOtherThan(cport_num) },
        .peers = try std.fmt.allocPrint(aa, "{s}:{d},{s}:{d},{s}:{d}", .{ NODE_IPS[0], cport_num, NODE_IPS[1], cport_num, NODE_IPS[2], cport_num }),
    };
    defer c.deinit();
    for (0..3) |i| try c.spawn(i);
    const started = nowMillis();

    var leader: ?usize = null;
    const startup_deadline = started + STARTUP_DEADLINE_MS;
    while (nowMillis() < startup_deadline) : (sleepMs(200)) {
        c.drain();
        leader = c.settledLeader();
        if (leader != null and c.clientPort(leader.?) != null) break;
    }
    const li = leader orelse return error.NoLeader;
    while (nowMillis() - started < SETTLE_MS) : (sleepMs(200)) c.drain();

    // 1. Every peer of the leader was heard from within the threshold.
    const fresh = try showLastContact(&c, li);
    for (0..3) |i| {
        if (i == li) continue;
        const ms = fresh[i] orelse return error.MissingPeerRow;
        if (ms >= FRESH_BOUND_MS) {
            std.debug.print("leader node {d} reports last_contact_ms={d} for live node {d} {d} ms after start\n", .{ li + 1, ms, i + 1, nowMillis() - started });
            return error.StaleLastContact;
        }
    }

    // 2. SIGKILL a follower: its last_contact_ms grows past the threshold;
    // the other follower's stays small.
    const fi: usize = (li + 1) % 3;
    const other: usize = (li + 2) % 3;
    c.closeChild(fi);
    const killed_at = nowMillis();
    while (nowMillis() - killed_at < FRESH_BOUND_MS + 2_000) : (sleepMs(200)) c.drain();
    if (c.lastRole(li) == null or !std.mem.eql(u8, c.lastRole(li).?, "leader")) return error.LeaderChanged;
    const after = try showLastContact(&c, li);
    const dead_ms = after[fi] orelse return error.MissingPeerRow;
    const live_ms = after[other] orelse return error.MissingPeerRow;
    if (dead_ms < FRESH_BOUND_MS) {
        std.debug.print("killed node {d}: last_contact_ms={d}, expected >= {d}\n", .{ fi + 1, dead_ms, FRESH_BOUND_MS });
        return error.DeadPeerLooksFresh;
    }
    if (live_ms >= FRESH_BOUND_MS) {
        std.debug.print("live node {d}: last_contact_ms={d}, expected < {d}\n", .{ other + 1, live_ms, FRESH_BOUND_MS });
        return error.StaleLastContact;
    }
}
