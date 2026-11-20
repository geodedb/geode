// SONNY-6636 (c): server-side Raft snapshots in a cluster of three real
// `geode serve` processes.
//
// Each node runs with GEODE_RAFT_SNAPSHOT_ENTRIES small, so sustained writes
// make every node (leader and followers) snapshot its durable store and
// compact its Raft log over and over. Shown here:
//
//   1. Sustained writes keep the Raft log bounded: every node logs snapshots
//      taken, and the leader's last one is close behind the last write.
//   2. A follower killed (SIGKILL) and kept down while the leader compacts
//      past everything it has catches up from the leader's snapshot when it
//      restarts: it restores the leader's GRS3 snapshot into its durable
//      store and then applies the entries after it.
//   3. That follower, killed again (SIGKILL) and restarted on its data
//      directory, still holds every write exactly once: no lost and no
//      duplicated row, on any node.
//
// Same fixture as test-cluster-replicable-mutations (CA-signed peer TLS,
// distinct loopback addresses), on 127.0.0.51-53, which no other test uses.
// Skips (never silently passes) when not linux, the geode binary is missing,
// openssl is unavailable or GEODE_SKIP_SUBPROC_CLUSTER is set.
//
// CANARY: REQ=REQ-SONNY-6636-CLUSTER-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=MultiProcessRegression; STATUS=TESTED; TEST=tests/test_sonny6636_cluster_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const test_ports = @import("test_ports.zig");
const builtin = @import("builtin");

const BINARY_PATH = geode_test_bin.geode_exe;
const NODE_IPS = [_][]const u8{ "127.0.0.51", "127.0.0.52", "127.0.0.53" };
const STARTUP_DEADLINE_MS: i64 = 45_000;
const ADMIN_PW = "Cluster Snapshot Admin Passphrase 6636";
const TOKEN = "sonny6636-cluster-snapshot-token";
const HMAC = "6c3a" ** 16;
/// Every node snapshots after this many entries.
const SNAPSHOT_ENTRIES = "25";
const SNAPSHOT_EVERY: usize = 25;
/// Writes while all nodes are up, then while the follower is down.
const WRITES_UP: usize = 30;
const WRITES_DOWN: usize = 90;
const WRITES_AFTER: usize = 10;

var client_port: u16 = 0;
var cluster_port: u16 = 0;

fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
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

fn binaryPresent() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, BINARY_PATH, .{}) catch return false;
    return true;
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
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-6636-snap-{d}-{d}", .{ std.os.linux.getpid(), nowMillis() });
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const ca_key = try std.fmt.allocPrint(aa, "{s}/ca.key", .{dir});
    const ca = try std.fmt.allocPrint(aa, "{s}/ca.crt", .{dir});
    const leaf_key = try std.fmt.allocPrint(aa, "{s}/leaf.key", .{dir});
    const leaf_csr = try std.fmt.allocPrint(aa, "{s}/leaf.csr", .{dir});
    const leaf = try std.fmt.allocPrint(aa, "{s}/leaf.crt", .{dir});
    const ext = try std.fmt.allocPrint(aa, "{s}/leaf.ext", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ext,
        .data = "subjectAltName=IP:127.0.0.51,IP:127.0.0.52,IP:127.0.0.53,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n",
    });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-6636-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
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

fn lastRole(buf: []const u8, id: usize) ?[]const u8 {
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "node {d} state=", .{id}) catch return null;
    var role: ?[]const u8 = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, buf, search, prefix)) |pos| {
        const after = pos + prefix.len;
        var e = after;
        while (e < buf.len and buf[e] != ' ') e += 1;
        role = buf[after..e];
        search = after;
    }
    return role;
}

/// The largest `snapshot_index=N` on a "snapshot taken" line, 0 when none.
fn lastSnapshotTaken(buf: []const u8) u64 {
    var best: u64 = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "snapshot taken") == null) continue;
        const k = std.mem.indexOf(u8, line, "snapshot_index=") orelse continue;
        var e = k + "snapshot_index=".len;
        var v: u64 = 0;
        while (e < line.len and line[e] >= '0' and line[e] <= '9') : (e += 1) v = v * 10 + (line[e] - '0');
        best = @max(best, v);
    }
    return best;
}

fn tryReap(pid: i32, flags: u32) bool {
    var status: u32 = undefined;
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return @as(isize, @bitCast(rc)) > 0;
}

const Cluster = struct {
    children: [3]?std.process.Child = .{ null, null, null },
    captures: [3]Capture = .{ .{}, .{}, .{} },
    /// Log of every previous incarnation of a node.
    certs: Certs,
    peers: []const u8,
    cluster_port_str: []const u8,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    io: std.Io,

    fn dataDir(self: *Cluster, i: usize) ![]const u8 {
        return std.fmt.allocPrint(self.aa, "{s}/data{d}", .{ self.certs.dir, i + 1 });
    }

    fn spawn(self: *Cluster, i: usize) !void {
        const aa = self.aa;
        const data_dir = try self.dataDir(i);
        std.Io.Dir.cwd().createDirPath(self.io, data_dir) catch {};
        const listen = try std.fmt.allocPrint(aa, "{s}:{d}", .{ NODE_IPS[i], client_port });
        const node_id = try std.fmt.allocPrint(aa, "{d}", .{i + 1});
        const args = [_][]const u8{
            BINARY_PATH,      "serve",               "--listen",    listen,
            "--cluster-port", self.cluster_port_str, "--peers",     self.peers,
            "--data-dir",     data_dir,              "--cert",      self.certs.leaf,
            "--key",          self.certs.key,        "--log-level", "info",
        };
        const env = try aa.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(aa);
        try env.put("GEODE_CLUSTER_TOKEN", TOKEN);
        try env.put("GEODE_AUTH_HMAC_KEY", HMAC);
        try env.put("GEODE_NODE_ID", node_id);
        try env.put("GEODE_PEERS", self.peers);
        try env.put("GEODE_CLUSTER_PORT", self.cluster_port_str);
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", NODE_IPS[i]);
        try env.put("GEODE_CLUSTER_CA_CERT", self.certs.ca);
        try env.put("GEODE_ADMIN_PASSWORD", ADMIN_PW);
        try env.put("GEODE_RAFT_SNAPSHOT_ENTRIES", SNAPSHOT_ENTRIES);
        if (posixGetenv("PATH")) |p| try env.put("PATH", p);
        if (posixGetenv("HOME")) |p| try env.put("HOME", p);
        if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);
        const child = std.process.spawn(self.io, .{ .argv = &args, .environ_map = env, .stdout = .pipe, .stderr = .pipe }) catch |err| {
            std.debug.print("spawn node {d} failed: {s}\n", .{ i + 1, @errorName(err) });
            return error.SkipZigTest;
        };
        self.children[i] = child;
        try setNonBlocking(child.stdout.?);
        try setNonBlocking(child.stderr.?);
    }

    fn drain(self: *Cluster) void {
        for (&self.children, 0..) |*maybe, i| {
            const ch = &(maybe.* orelse continue);
            if (ch.stdout) |f| self.captures[i].drain(self.gpa, self.io, f);
            if (ch.stderr) |f| self.captures[i].drain(self.gpa, self.io, f);
        }
    }

    fn closePipes(self: *Cluster, ch: *std.process.Child) void {
        if (ch.stdout) |f| f.close(self.io);
        if (ch.stderr) |f| f.close(self.io);
        if (ch.stdin) |f| f.close(self.io);
        ch.stdout = null;
        ch.stderr = null;
        ch.stdin = null;
    }

    /// SIGKILL node `i` and reap it.
    fn kill(self: *Cluster, i: usize) void {
        self.drain();
        const ch = &(self.children[i] orelse return);
        if (ch.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = tryReap(pid, 0);
        }
        self.closePipes(ch);
        self.children[i] = null;
    }

    /// With GEODE_TEST_LOG_DIR set, every node's captured log is written
    /// there (node<N>.log) when the cluster is torn down.
    fn keepLogs(self: *Cluster) void {
        const dir = posixGetenv("GEODE_TEST_LOG_DIR") orelse return;
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch return;
        for (0..3) |i| {
            const path = std.fmt.allocPrint(self.aa, "{s}/node{d}.log", .{ dir, i + 1 }) catch return;
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = self.captures[i].buf.items }) catch {};
        }
    }

    fn deinit(self: *Cluster) void {
        self.drain();
        for (&self.children) |*maybe| {
            const ch = &(maybe.* orelse continue);
            if (ch.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
        const deadline = nowMillis() + 5_000;
        while (nowMillis() < deadline) {
            var all_gone = true;
            for (&self.children) |*maybe| {
                const ch = &(maybe.* orelse continue);
                if (ch.id) |pid| {
                    if (tryReap(pid, std.os.linux.W.NOHANG)) ch.id = null else all_gone = false;
                }
            }
            if (all_gone) break;
            sleepMs(100);
        }
        for (&self.children) |*maybe| {
            const ch = &(maybe.* orelse continue);
            if (ch.id) |pid| {
                std.posix.kill(pid, std.posix.SIG.KILL) catch {};
                _ = tryReap(pid, 0);
            }
            self.closePipes(ch);
            maybe.* = null;
        }
        self.drain();
        self.keepLogs();
        for (&self.captures) |*c| c.buf.deinit(self.gpa);
        std.Io.Dir.cwd().deleteTree(self.io, self.certs.dir) catch {};
    }

    fn leader(self: *Cluster) ?usize {
        self.drain();
        var idx: ?usize = null;
        for (0..3) |i| {
            if (self.children[i] == null) continue;
            if (lastRole(self.captures[i].buf.items, i + 1)) |r| if (std.mem.eql(u8, r, "leader")) {
                idx = i;
            };
        }
        return idx;
    }

    fn waitLeader(self: *Cluster) !usize {
        const deadline = nowMillis() + STARTUP_DEADLINE_MS;
        while (nowMillis() < deadline) {
            if (self.leader()) |l| return l;
            sleepMs(250);
        }
        for (0..3) |i| {
            const buf = self.captures[i].buf.items;
            std.debug.print("\n--- node {d} log tail (no leader) ---\n{s}\n", .{ i + 1, buf[buf.len -| 2000..] });
        }
        return error.NoLeaderElected;
    }

    fn query(self: *Cluster, i: usize, q: []const u8) ![]u8 {
        const server = try std.fmt.allocPrint(self.aa, "{s}:{d}", .{ NODE_IPS[i], client_port });
        const argv = [_][]const u8{ BINARY_PATH, "query", "--server", server, "--ca-cert", self.certs.ca, "-U", "geode", "-P", ADMIN_PW, q };
        const res = try std.process.run(self.gpa, self.io, .{
            .argv = &argv,
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromNanoseconds(20 * std.time.ns_per_s), .clock = .awake } },
        });
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("[6636] query on node {d} exited {any}: {s}\n", .{ i + 1, res.term, res.stderr[0..@min(res.stderr.len, 400)] });
        }
        return res.stdout;
    }

    /// Write `k` once through the current leader (never retried: a lost
    /// reply after commit would make a retry a second row).
    fn write(self: *Cluster, k: usize) !void {
        const l = try self.waitLeader();
        const q = try std.fmt.allocPrint(self.aa, "CREATE (:Snap6636 {{k: {d}}})", .{k});
        const out = self.query(l, q) catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };
        defer self.gpa.free(out);
        if (std.mem.indexOf(u8, out, "error") != null or std.mem.indexOf(u8, out, "Error") != null) {
            std.debug.print("[6636] write {d} on node {d}: {s}\n", .{ k, l + 1, out[0..@min(out.len, 400)] });
        }
    }

    /// Wait until node `i` reports `want` rows and `want` distinct keys.
    fn expectRows(self: *Cluster, i: usize, want: usize) !void {
        const q = "MATCH (n:Snap6636) RETURN count(n) AS c, count(DISTINCT n.k) AS d";
        const expect = try std.fmt.allocPrint(self.aa, "\"c\":{d},\"d\":{d}", .{ want, want });
        var last: []const u8 = "";
        for (0..60) |_| {
            self.drain();
            const out = self.query(i, q) catch |err| {
                last = @errorName(err);
                sleepMs(1000);
                continue;
            };
            defer self.gpa.free(out);
            last = try self.aa.dupe(u8, out[0..@min(out.len, 300)]);
            if (std.mem.indexOf(u8, out, expect) != null) return;
            sleepMs(1000);
        }
        std.debug.print("[6636] node {d} never read {s}; last: {s}\n", .{ i + 1, expect, last });
        const buf = self.captures[i].buf.items;
        std.debug.print("--- node {d} log tail ---\n{s}\n", .{ i + 1, buf[buf.len -| 3000..] });
        return error.RowsWrong;
    }
};

test "SONNY-6636: in a 3-process cluster sustained writes keep every node's Raft log bounded by snapshots, a follower down past the leader's compaction catches up from its snapshot, and survives SIGKILL and restart with every row exactly once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (posixGetenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) return error.SkipZigTest;
    if (!binaryPresent()) {
        std.debug.print("geode binary missing at {s}; run `zig build` first\n", .{BINARY_PATH});
        return error.SkipZigTest;
    }
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const certs = try makeCerts(aa, io);
    client_port = try test_ports.freeUdpPort();
    cluster_port = try test_ports.freeUdpPortExcept(&.{client_port});
    var cluster: Cluster = .{
        .certs = certs,
        .peers = try std.fmt.allocPrint(aa, "{s}:{d},{s}:{d},{s}:{d}", .{ NODE_IPS[0], cluster_port, NODE_IPS[1], cluster_port, NODE_IPS[2], cluster_port }),
        .cluster_port_str = try std.fmt.allocPrint(aa, "{d}", .{cluster_port}),
        .gpa = gpa,
        .aa = aa,
        .io = io,
    };
    defer cluster.deinit();
    for (0..3) |i| try cluster.spawn(i);
    _ = try cluster.waitLeader();

    // All nodes up: writes past the threshold.
    var written: usize = 0;
    while (written < WRITES_UP) : (written += 1) try cluster.write(written);
    for (0..3) |i| try cluster.expectRows(i, written);

    // A follower goes down (SIGKILL) and stays down while the leader
    // compacts past everything it has.
    const l = try cluster.waitLeader();
    const f = (l + 1) % 3;
    cluster.kill(f);
    std.debug.print("[6636] node {d} killed (leader node {d}) after {d} writes\n", .{ f + 1, l + 1, written });
    const before_down = lastSnapshotTaken(cluster.captures[l].buf.items);
    while (written < WRITES_UP + WRITES_DOWN) : (written += 1) try cluster.write(written);
    for (0..3) |i| if (i != f) try cluster.expectRows(i, written);
    cluster.drain();
    const leader_snap = lastSnapshotTaken(cluster.captures[(try cluster.waitLeader())].buf.items);
    std.debug.print("[6636] leader's last snapshot before node {d} returns: index {d} (was {d} when it went down)\n", .{ f + 1, leader_snap, before_down });
    try std.testing.expect(leader_snap > before_down + SNAPSHOT_EVERY);

    // It restarts and catches up from the leader's snapshot.
    const mark = cluster.captures[f].buf.items.len;
    try cluster.spawn(f);
    try cluster.expectRows(f, written);
    cluster.drain();
    const restarted_log = cluster.captures[f].buf.items[mark..];
    try std.testing.expect(std.mem.indexOf(u8, restarted_log, "durable store restored from the leader's snapshot") != null);

    // Writes go on; then the follower is killed again and restarted on its
    // data directory: every row exactly once, everywhere.
    while (written < WRITES_UP + WRITES_DOWN + WRITES_AFTER) : (written += 1) try cluster.write(written);
    try cluster.expectRows(f, written);
    cluster.kill(f);
    try cluster.spawn(f);
    for (0..3) |i| try cluster.expectRows(i, written);

    // The log stayed bounded on every node: each one took snapshots, and
    // the last is within two thresholds (plus the writes that came in
    // while it was copied) of the last write.
    cluster.drain();
    const leader_now = try cluster.waitLeader();
    for (0..3) |i| {
        const taken = lastSnapshotTaken(cluster.captures[i].buf.items);
        std.debug.print("[6636] node {d}: last snapshot taken at index {d}\n", .{ i + 1, taken });
        try std.testing.expect(taken > 0);
    }
    const leader_last = lastSnapshotTaken(cluster.captures[leader_now].buf.items);
    // Each write is one entry, plus a leader no-op per election.
    try std.testing.expect(leader_last + 2 * SNAPSHOT_EVERY + 10 >= written);
}
