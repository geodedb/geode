// SONNY-6665: raft v0.2.5's snapshot transfer over geode's real QUIC
// transport, in a cluster of three `geode serve` processes.
//
// A follower SIGKILLed and kept down while the leader compacts its Raft log
// past everything the follower has must catch up from the leader's snapshot
// when it restarts. The snapshot (the leader's durable store, several
// 64 KiB chunks) goes over the QUIC transport chunk by chunk, and a chunk
// is lost on the way: the restarted follower runs with the Debug-only
// GEODE_TEST_RAFT_DROP_SNAPSHOT_CHUNKS hook, which drops the chunk right
// after a snapshot's first one (every time) and logs every chunk, so a send
// from offset 0 never completes and only one resumed at the lost chunk can.
//
// The follower then reports the gap (raft v0.2.5 InstallSnapshotResponse
// last_index / next_offset) and the leader must re-send from the lost
// chunk's offset (its "snapshot streamed to a follower" log line) and never
// from offset 0 again (geode dropped the two fields, so the leader saw a
// refusal, backed off and sent the whole snapshot again). Every row arrives
// exactly once on every node.
//
// Same fixture as test-sonny6636-cluster-snapshot (CA-signed peer TLS,
// 127.0.0.51-53). Skips (never silently passes) when not linux, the geode
// binary is missing, openssl is unavailable or GEODE_SKIP_SUBPROC_CLUSTER
// is set.
//
// CANARY: REQ=REQ-SONNY-6665-CLUSTER-SNAPSHOT-RESUME; FEATURE="Raft Snapshot Persistence"; ASPECT=MultiProcessRegression; STATUS=TESTED; TEST=tests/test_sonny6665_cluster_snapshot_resume.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const test_ports = @import("test_ports.zig");
const builtin = @import("builtin");

const BINARY_PATH = geode_test_bin.geode_exe;
const NODE_IPS = [_][]const u8{ "127.0.0.51", "127.0.0.52", "127.0.0.53" };
const STARTUP_DEADLINE_MS: i64 = 45_000;
const ADMIN_PW = "Cluster Snapshot Resume Passphrase 6665";
const TOKEN = "sonny6665-cluster-snapshot-token";
const HMAC = "6d65" ** 16;
/// Every node snapshots after this many entries.
const SNAPSHOT_ENTRIES = "25";
const SNAPSHOT_EVERY: usize = 25;
/// Writes while all nodes are up, then while the follower is down.
const WRITES_UP: usize = 30;
const WRITES_DOWN: usize = 90;
const WRITES_AFTER: usize = 10;
/// Each row carries this, so the leader's snapshot spans several 64 KiB
/// InstallSnapshot chunks.
const PAD = "x" ** 2048;

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
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-6665-snap-{d}-{d}", .{ std.os.linux.getpid(), nowMillis() });
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
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-6665-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
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

    fn spawn(self: *Cluster, i: usize, drop_chunk: bool) !void {
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
        if (drop_chunk) try env.put("GEODE_TEST_RAFT_DROP_SNAPSHOT_CHUNKS", "1000");
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
            std.debug.print("[6665] query on node {d} exited {any}: {s}\n", .{ i + 1, res.term, res.stderr[0..@min(res.stderr.len, 400)] });
        }
        return res.stdout;
    }

    /// Write `k` once through the current leader (never retried: a lost
    /// reply after commit would make a retry a second row).
    fn write(self: *Cluster, k: usize) !void {
        const l = try self.waitLeader();
        const q = try std.fmt.allocPrint(self.aa, "CREATE (:Snap6665 {{k: {d}, pad: '{s}'}})", .{ k, PAD });
        const out = self.query(l, q) catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };
        defer self.gpa.free(out);
        if (std.mem.indexOf(u8, out, "error") != null or std.mem.indexOf(u8, out, "Error") != null) {
            std.debug.print("[6665] write {d} on node {d}: {s}\n", .{ k, l + 1, out[0..@min(out.len, 400)] });
        }
    }

    /// Wait until node `i` reports `want` rows and `want` distinct keys.
    fn expectRows(self: *Cluster, i: usize, want: usize) !void {
        const q = "MATCH (n:Snap6665) RETURN count(n) AS c, count(DISTINCT n.k) AS d";
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
        std.debug.print("[6665] node {d} never read {s}; last: {s}\n", .{ i + 1, expect, last });
        const buf = self.captures[i].buf.items;
        std.debug.print("--- node {d} log tail ---\n{s}\n", .{ i + 1, buf[buf.len -| 3000..] });
        return error.RowsWrong;
    }
};

/// The `name=N` value on `line`, or null.
fn attrValue(line: []const u8, name: []const u8) ?u64 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, line, search, name)) |k| {
        search = k + name.len;
        if (k > 0 and line[k - 1] != ' ') continue;
        if (search >= line.len or line[search] != '=') continue;
        var e = search + 1;
        var v: u64 = 0;
        var any = false;
        while (e < line.len and line[e] >= '0' and line[e] <= '9') : (e += 1) {
            v = v * 10 + (line[e] - '0');
            any = true;
        }
        if (any) return v;
    }
    return null;
}

test "SONNY-6665: in a 3-process cluster a follower down past the leader's compaction installs its snapshot over QUIC, and a chunk lost on the way is re-sent from the follower's offset, not from 0" {
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
    for (0..3) |i| try cluster.spawn(i, false);
    _ = try cluster.waitLeader();

    var written: usize = 0;
    while (written < WRITES_UP) : (written += 1) try cluster.write(written);
    for (0..3) |i| try cluster.expectRows(i, written);

    // A follower goes down (SIGKILL) and stays down while the leader
    // compacts past everything it has.
    const l = try cluster.waitLeader();
    const f = (l + 1) % 3;
    cluster.kill(f);
    const before_down = lastSnapshotTaken(cluster.captures[l].buf.items);
    while (written < WRITES_UP + WRITES_DOWN) : (written += 1) try cluster.write(written);
    for (0..3) |i| if (i != f) try cluster.expectRows(i, written);
    cluster.drain();
    const leader_snap = lastSnapshotTaken(cluster.captures[(try cluster.waitLeader())].buf.items);
    std.debug.print("[6665] node {d} down; the leader's last snapshot is at index {d} (was {d})\n", .{ f + 1, leader_snap, before_down });
    try std.testing.expect(leader_snap > before_down + SNAPSHOT_EVERY);

    // It restarts, loses one chunk of the leader's snapshot, and catches up.
    const mark = cluster.captures[f].buf.items.len;
    try cluster.spawn(f, true);
    try cluster.expectRows(f, written);
    cluster.drain();
    const log_f = cluster.captures[f].buf.items[mark..];
    try std.testing.expect(std.mem.indexOf(u8, log_f, "durable store restored from the leader's snapshot") != null);

    // The chunk the follower lost.
    var lost_index: ?u64 = null;
    var lost_offset: u64 = 0;
    var it = std.mem.splitScalar(u8, log_f, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "TEST HOOK: InstallSnapshot chunk dropped") == null) continue;
        lost_index = attrValue(line, "snapshot_index");
        lost_offset = attrValue(line, "chunk_offset") orelse 0;
        break;
    }
    if (lost_index == null) {
        std.debug.print("--- node {d} log (restarted) tail ---\n{s}\n", .{ f + 1, log_f[log_f.len -| 4000..] });
        return error.NoChunkLost;
    }
    try std.testing.expect(lost_offset > 0);

    // The leader's sends of that snapshot to the follower. A leader re-sends
    // a snapshot nobody answered from offset 0 every few heartbeat rounds,
    // so sends from 0 were already on their way when the chunk was lost;
    // once the follower reported the gap the leader resumes at the lost
    // chunk (the only way the follower can install it here), and never
    // starts over from 0.
    var from_zero: usize = 0;
    var resumed: usize = 0;
    var zero_after_resume: usize = 0;
    for (0..3) |i| {
        if (i == f) continue;
        var lines = std.mem.splitScalar(u8, cluster.captures[i].buf.items, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "snapshot streamed to a follower") == null) continue;
            if (attrValue(line, "to") != f + 1 or attrValue(line, "snapshot_index") != lost_index.?) continue;
            const off = attrValue(line, "offset") orelse continue;
            if (off == lost_offset) {
                resumed += 1;
            } else if (off == 0) {
                if (resumed > 0) zero_after_resume += 1 else from_zero += 1;
            }
        }
    }
    std.debug.print("[6665] node {d} lost the chunk at offset {d} of snapshot {d}; the leader sent it {d} time(s) from 0 before that was reported, {d} time(s) from the lost chunk after, and {d} time(s) from 0 after\n", .{ f + 1, lost_offset, lost_index.?, from_zero, resumed, zero_after_resume });
    try std.testing.expect(resumed > 0);
    try std.testing.expectEqual(@as(usize, 0), zero_after_resume);

    // Writes go on; every row exactly once, everywhere.
    while (written < WRITES_UP + WRITES_DOWN + WRITES_AFTER) : (written += 1) try cluster.write(written);
    for (0..3) |i| try cluster.expectRows(i, written);
}
