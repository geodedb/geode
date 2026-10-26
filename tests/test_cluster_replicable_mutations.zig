// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MUTATIONS; FEATURE="DistributedCluster"; ASPECT=ReplicateEdgeDeleteMergeSet; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
//
// FAILING reproduction tests (TDD red phase) for the cluster write-replication
// gaps triaged on 2026-06-09. In a Raft cluster, ONLY a pure single-node CREATE
// replicates today. Every other write either fails closed or silently diverges:
//
//   * Edge CREATE (chains with hops) is rejected at
//     src/execution/crud_operations.zig (clusterReplicateNodeCreate) with
//     error.ClusterWriteNotReplicable.
//   * DELETE / DETACH DELETE is rejected at crud_operations.zig (executeDelete);
//     the apply path in src/distributed/raft_apply.zig is a "not fully wired,
//     skipping" stub.
//   * MERGE (node + rel) is rejected at crud_operations.zig (executeMerge); the
//     apply path is a "not fully wired, skipping" stub.
//   * MATCH ... SET is NOT GATED AT ALL: query_execution.zig only routes through
//     Raft when a create_pattern is present, and match_operations.zig writes the
//     local store directly. In cluster mode a leader SET mutates ONLY the leader
//     -> SILENT DIVERGENCE (followers never see it). This is the divergence proof.
//
// These tests spin up three REAL `geode serve` processes on distinct loopback
// IPs (127.0.0.11/12/13) with CA-signed peer TLS -- the same fixture the
// node-CREATE replication regression (test_cluster_3node_steady_state.zig) uses,
// because true follower convergence can only be observed across SEPARATE stores
// (separate processes). The in-process raft fixture shares ONE process-global
// GraphStore and serializes raft on a single-threaded-IO mutex, so it cannot
// model leader-vs-follower divergence nor the blocking waitForApplied path.
//
// RED at HEAD:
//   * Edge / DELETE / MERGE: the leader returns error.ClusterWriteNotReplicable,
//     so the write never lands -> followers never converge -> the assertion
//     fails with error.ReplicationIncomplete (or the leader-reject is detected).
//   * SET: the leader applies it locally but never proposes it through Raft, so
//     the followers keep the old value -> error.SetDidNotReplicate.
//
// GREEN after the fix: each mutation is serialized into a Raft command, proposed
// by the leader, and applied deterministically on every node, so all healthy
// followers converge.
//
// Skips (error.SkipZigTest, never silently passes) when: not linux, the geode
// binary is missing (run `zig build` first), openssl is unavailable, or
// 127.0.0.11 cannot be bound. Set GEODE_SKIP_SUBPROC_CLUSTER=1 to opt out on a
// flaky CI runner.

const std = @import("std");
const builtin = @import("builtin");

const BINARY_PATH = "./zig-out/bin/geode";
const NODE_IPS = [_][]const u8{ "127.0.0.11", "127.0.0.12", "127.0.0.13" };
const CLUSTER_PORT_STR = "4242";
const STARTUP_DEADLINE_MS: i64 = 45_000;
const ADMIN_PW = "ReplicableMutPw123!";

// ---------------------------------------------------------------------------
// Zig 0.16 compat shims (mirrored from test_cluster_3node_steady_state.zig so
// this test does not depend on private compat helpers in a sibling module).
// ---------------------------------------------------------------------------

fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .linux) {
        const req = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        const req = std.c.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

fn setNonBlocking(file: std.Io.File) !void {
    if (comptime builtin.os.tag != .linux) return;
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

// ---------------------------------------------------------------------------
// Client query helper.
// ---------------------------------------------------------------------------

/// CA that signed the nodes' leaf cert; set by makeCerts. `geode query` trusts it
/// via --ca-cert so the client VERIFIES the node's TLS certificate. The client
/// refuses --insecure-tls-skip-verify in a release build (SEC-CLI-01), so a
/// skip-verify client exits 1 before connecting under ReleaseSafe and every
/// query of this suite came back empty.
var query_ca_path: ?[]const u8 = null;

/// Run `geode query` against `ip:3141` and return captured stdout (caller frees
/// with `gpa`). Bounded by a hard timeout so a hung query can't wedge the suite.
/// A client that exits non-zero has its stderr printed, so a failure says why.
fn runQuery(gpa: std.mem.Allocator, io: std.Io, aa: std.mem.Allocator, ip: []const u8, q: []const u8) ![]u8 {
    const server = try std.fmt.allocPrint(aa, "{s}:3141", .{ip});
    const ca = query_ca_path orelse return error.NoQueryCa;
    const argv = [_][]const u8{
        BINARY_PATH, "query",  "--server", server,
        "--ca-cert", ca,       "-U",       "geode",
        "-P",        ADMIN_PW, q,
    };
    const res = try std.process.run(gpa, io, .{
        .argv = &argv,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(15 * std.time.ns_per_s),
            .clock = .awake,
        } },
    });
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("[query] {s} on {s} exited {any}: {s}\n", .{ q, ip, res.term, res.stderr[0..@min(res.stderr.len, 400)] });
    }
    return res.stdout;
}

// ---------------------------------------------------------------------------
// Certificate generation (CA + shared leaf with IP SANs for the 3 nodes).
// ---------------------------------------------------------------------------

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

    // Unique per-pid AND per-call dir so sequential tests in this binary do not
    // race on a shared cert/serial file.
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-repl-mut-{d}-{d}", .{ std.os.linux.getpid(), nowMillis() });
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
        .data = "subjectAltName=IP:127.0.0.11,IP:127.0.0.12,IP:127.0.0.13,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n",
    });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-rm-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-new", "-key", leaf_key, "-subj", "/CN=geode-node", "-out", leaf_csr });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "x509", "-req", "-in", leaf_csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", leaf });
    query_ca_path = ca;
    return .{ .dir = dir, .ca = ca, .leaf = leaf, .key = leaf_key };
}

// ---------------------------------------------------------------------------
// Per-node log capture + raft-state scanning.
// ---------------------------------------------------------------------------

const Capture = struct {
    buf: std.ArrayList(u8) = .empty,
    fn drain(self: *Capture, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) void {
        var tmp: [8192]u8 = undefined;
        const n = file.readStreaming(io, &.{&tmp}) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return,
        };
        if (n > 0) self.buf.appendSlice(gpa, tmp[0..n]) catch {};
    }
};

/// Returns the last observed raft state of node `id` ("leader"/"follower"/
/// "candidate"/null) and its term, scanned from the captured log buffer.
fn lastState(buf: []const u8, id: usize) struct { role: ?[]const u8, term: i64 } {
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "node {d} state=", .{id}) catch return .{ .role = null, .term = 0 };
    var role: ?[]const u8 = null;
    var term: i64 = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, buf, search, prefix)) |pos| {
        const after = pos + prefix.len;
        var e = after;
        while (e < buf.len and buf[e] != ' ') e += 1;
        role = buf[after..e];
        if (std.mem.indexOfPos(u8, buf, e, "term=")) |tp| {
            if (tp < e + 8) {
                var te = tp + 5;
                var t: i64 = 0;
                while (te < buf.len and buf[te] >= '0' and buf[te] <= '9') : (te += 1) t = t * 10 + (buf[te] - '0');
                term = t;
            }
        }
        search = after;
    }
    return .{ .role = role, .term = term };
}

fn currentLeaderIdx(captures: []const Capture) ?usize {
    var idx: ?usize = null;
    for (captures, 0..) |c, i| {
        const s = lastState(c.buf.items, i + 1);
        if (s.role) |r| if (std.mem.eql(u8, r, "leader")) {
            idx = i;
        };
    }
    return idx;
}

fn isNodeHealthy(captures: []const Capture, idx: usize) bool {
    return lastState(captures[idx].buf.items, idx + 1).role != null;
}

// ---------------------------------------------------------------------------
// Teardown / drain.
// ---------------------------------------------------------------------------

fn tryReap(pid: i32, flags: u32) bool {
    var status: u32 = undefined;
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return @as(isize, @bitCast(rc)) > 0;
}

fn drainAll(captures: []Capture, children: []std.process.Child, gpa: std.mem.Allocator, io: std.Io) void {
    for (children, 0..) |*ch, i| {
        if (ch.stdout) |f| captures[i].drain(gpa, io, f);
        if (ch.stderr) |f| captures[i].drain(gpa, io, f);
    }
}

fn teardownNodes(children: []std.process.Child, captures: []Capture, spawned: usize, gpa: std.mem.Allocator, io: std.Io) void {
    for (children[0..spawned]) |*ch| {
        if (ch.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    }
    const term_deadline = nowMillis() + 5_000;
    while (nowMillis() < term_deadline) {
        drainAll(captures, children, gpa, io);
        var all_gone = true;
        for (children[0..spawned]) |*ch| {
            if (ch.id == null) continue;
            if (tryReap(ch.id.?, std.os.linux.W.NOHANG)) {
                ch.id = null;
            } else {
                all_gone = false;
            }
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
    }
    for (children[0..spawned]) |*ch| {
        if (ch.stdout) |f| {
            f.close(io);
            ch.stdout = null;
        }
        if (ch.stderr) |f| {
            f.close(io);
            ch.stderr = null;
        }
        if (ch.stdin) |f| {
            f.close(io);
            ch.stdin = null;
        }
    }
}

// ---------------------------------------------------------------------------
// Cluster fixture: spawn 3 nodes, wait for a stable leader+quorum.  Returned to
// the caller so each test runs its own mutation phase against the live cluster.
// ---------------------------------------------------------------------------

const Cluster = struct {
    children: [3]std.process.Child,
    captures: [3]Capture,
    spawned: usize,
    certs: Certs,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    io: std.Io,

    fn deinit(self: *Cluster) void {
        teardownNodes(&self.children, &self.captures, self.spawned, self.gpa, self.io);
        for (&self.captures) |*c| c.buf.deinit(self.gpa);
        std.Io.Dir.cwd().deleteTree(self.io, self.certs.dir) catch {};
    }

    /// Re-resolve the current leader (leadership can move) and return its IP, or
    /// null when there is currently no leader.
    fn leaderIp(self: *Cluster) ?[]const u8 {
        drainAll(&self.captures, &self.children, self.gpa, self.io);
        const idx = currentLeaderIdx(&self.captures) orelse return null;
        return NODE_IPS[idx];
    }
};

/// Bring up the 3-node cluster and block until a single leader + >=1 follower is
/// observed (or skip/fail).  The caller owns the returned Cluster and must call
/// `deinit`.  `aa` must be an arena that outlives the cluster.
fn startCluster(gpa: std.mem.Allocator, aa: std.mem.Allocator, io: std.Io) !Cluster {
    const certs = makeCerts(aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };

    const peers = "127.0.0.11:4242,127.0.0.12:4242,127.0.0.13:4242";
    const token = "replicable-mutations-cluster-token";
    const hmac = "replmut-hmac-0123456789abcdef0123456789abcdef";

    var cluster = Cluster{
        .children = undefined,
        .captures = .{ .{}, .{}, .{} },
        .spawned = 0,
        .certs = certs,
        .gpa = gpa,
        .aa = aa,
        .io = io,
    };
    errdefer cluster.deinit();

    for (0..3) |i| {
        const ip = NODE_IPS[i];
        const data_dir = try std.fmt.allocPrint(aa, "{s}/data{d}", .{ certs.dir, i + 1 });
        std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
        const listen = try std.fmt.allocPrint(aa, "{s}:3141", .{ip});
        const node_id = try std.fmt.allocPrint(aa, "{d}", .{i + 1});

        const args = [_][]const u8{
            BINARY_PATH,      "serve",          "--listen",    listen,
            "--cluster-port", CLUSTER_PORT_STR, "--peers",     peers,
            "--data-dir",     data_dir,         "--cert",      certs.leaf,
            "--key",          certs.key,        "--log-level", "info",
        };
        const env = try aa.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(aa);
        try env.put("GEODE_CLUSTER_TOKEN", token);
        try env.put("GEODE_AUTH_HMAC_KEY", hmac);
        try env.put("GEODE_NODE_ID", node_id);
        try env.put("GEODE_PEERS", peers);
        try env.put("GEODE_CLUSTER_PORT", CLUSTER_PORT_STR);
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", ip);
        try env.put("GEODE_CLUSTER_CA_CERT", certs.ca);
        try env.put("GEODE_ADMIN_PASSWORD", ADMIN_PW);
        if (posixGetenv("PATH")) |p| try env.put("PATH", p);
        if (posixGetenv("HOME")) |p| try env.put("HOME", p);
        if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);

        cluster.children[i] = std.process.spawn(io, .{ .argv = &args, .environ_map = env, .stdout = .pipe, .stderr = .pipe }) catch |err| {
            std.debug.print("spawn node {d} failed: {s}\n", .{ i + 1, @errorName(err) });
            return error.SkipZigTest;
        };
        cluster.spawned += 1;
        try setNonBlocking(cluster.children[i].stdout.?);
        try setNonBlocking(cluster.children[i].stderr.?);
    }

    // Wait for a single leader + >=1 follower.
    const startup_deadline = nowMillis() + STARTUP_DEADLINE_MS;
    var have_quorum = false;
    while (nowMillis() < startup_deadline) {
        for (0..3) |i| {
            cluster.captures[i].drain(gpa, io, cluster.children[i].stdout.?);
            cluster.captures[i].drain(gpa, io, cluster.children[i].stderr.?);
        }
        var leaders: usize = 0;
        var followers: usize = 0;
        for (0..3) |i| {
            const s = lastState(cluster.captures[i].buf.items, i + 1);
            if (s.role) |r| {
                if (std.mem.eql(u8, r, "leader")) {
                    leaders += 1;
                } else if (std.mem.eql(u8, r, "follower")) {
                    followers += 1;
                }
            }
        }
        if (leaders == 1 and followers >= 1) {
            have_quorum = true;
            break;
        }
        sleepMs(250);
    }

    if (!have_quorum) {
        for (0..3) |i| {
            const tail_start = if (cluster.captures[i].buf.items.len > 1500) cluster.captures[i].buf.items.len - 1500 else 0;
            std.debug.print("\n--- node {d} log tail (no leader+quorum) ---\n{s}\n", .{ i + 1, cluster.captures[i].buf.items[tail_start..] });
        }
        return error.NoLeaderElected;
    }

    return cluster;
}

// ---------------------------------------------------------------------------
// Generic "run a mutation on the leader, poll the followers" assertion.
// ---------------------------------------------------------------------------

/// Run `mutate_q` against the CURRENT leader (retrying on a leadership move) and
/// then poll every healthy follower until `read_q` returns a row containing
/// `expect_substr`.  Fails (error.ReplicationIncomplete) if any healthy follower
/// never converges within the poll budget.
///
/// `mutate_q` MUST NOT be retried blindly across leadership moves once it has
/// succeeded once (it is idempotent in these tests: each phase uses a unique
/// label and MERGE-style/SET-style single writes), so a retry on
/// error.ClusterNotLeader is safe.
fn assertMutationReplicates(
    cluster: *Cluster,
    label_for_msg: []const u8,
    mutate_q: []const u8,
    read_q: []const u8,
    expect_substr: []const u8,
) !void {
    const gpa = cluster.gpa;
    const aa = cluster.aa;
    const io = cluster.io;

    // Send the mutation to the current leader. Retry on a leadership move
    // (error.ClusterNotLeader). A returned error.ClusterWriteNotReplicable is the
    // HEAD failure mode: it means the leader refused to replicate the write at
    // all -> the followers can never converge, which the poll below catches. We
    // surface it explicitly for a clearer red-phase diagnostic.
    var attempt: usize = 0;
    const li: usize = while (attempt < 12) : (attempt += 1) {
        const leader_ip = cluster.leaderIp() orelse {
            sleepMs(500);
            continue;
        };
        const out = runQuery(gpa, io, aa, leader_ip, mutate_q) catch {
            sleepMs(500);
            continue;
        };
        defer gpa.free(out);
        if (std.mem.indexOf(u8, out, "ClusterNotLeader") != null) {
            sleepMs(700);
            continue;
        }
        if (std.mem.indexOf(u8, out, "ClusterWriteNotReplicable") != null) {
            std.debug.print(
                "\n[repl] LEADER REFUSED to replicate '{s}': error.ClusterWriteNotReplicable\n" ++
                    "       mutation '{s}' fails closed in cluster mode (HEAD gap).\n",
                .{ label_for_msg, mutate_q },
            );
            return error.ClusterWriteNotReplicable;
        }
        // The write may legitimately return a Timeout under commit-latency-on-a-
        // loaded-host (the write still replicates); we do NOT gate on the
        // response, we poll the followers below.
        const idx = currentLeaderIdx(&cluster.captures) orelse {
            sleepMs(500);
            continue;
        };
        break idx;
    } else return error.NoStableLeaderForWrite;

    var expected: usize = 0;
    for (0..3) |i| {
        if (i != li and isNodeHealthy(&cluster.captures, i)) expected += 1;
    }
    if (expected == 0) return error.NoHealthyFollower;

    var poll: usize = 0;
    while (poll < 18) : (poll += 1) {
        sleepMs(1000);
        drainAll(&cluster.captures, &cluster.children, gpa, io);
        var got: usize = 0;
        for (0..3) |fi| {
            if (fi == li or !isNodeHealthy(&cluster.captures, fi)) continue;
            const read_out = runQuery(gpa, io, aa, NODE_IPS[fi], read_q) catch continue;
            defer gpa.free(read_out);
            if (std.mem.indexOf(u8, read_out, expect_substr) != null) got += 1;
        }
        if (got >= expected) {
            std.debug.print("[repl] '{s}' converged on all {d} healthy follower(s) after {d}s\n", .{ label_for_msg, expected, poll + 1 });
            return;
        }
    }
    std.debug.print(
        "\n[repl] '{s}' did NOT converge on all {d} healthy follower(s) (expected read '{s}')\n",
        .{ label_for_msg, expected, expect_substr },
    );
    return error.ReplicationIncomplete;
}

/// Seed a row via the replicable single-node CREATE path (which works at HEAD),
/// blocking until it is visible on every healthy follower.  Used to set up the
/// DELETE and SET regressions, whose preconditions need data already replicated.
fn seedReplicableNode(cluster: *Cluster, label: []const u8, create_q: []const u8) !void {
    const aa = cluster.aa;
    const read_q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{label});
    try assertMutationReplicates(cluster, label, create_q, read_q, "\"c\":1");
}

fn skipPreflight() bool {
    if (builtin.os.tag != .linux) return true;
    if (posixGetenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) return true;
    if (!binaryPresent()) {
        std.debug.print("geode binary missing at {s}; run `zig build` first\n", .{BINARY_PATH});
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Test 1: EDGE CREATE replicates.
// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MUTATIONS; FEATURE="DistributedCluster"; ASPECT=ReplicateEdgeCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
test "cluster: edge CREATE replicates to followers" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    // A single statement creating two nodes joined by a relationship. At HEAD
    // this is rejected by clusterReplicateNodeCreate (chain.hops.len != 0) ->
    // error.ClusterWriteNotReplicable. After the fix it replicates the two nodes
    // + the edge to every follower.
    try assertMutationReplicates(
        &cluster,
        "EdgeRepl",
        "CREATE (a:EdgeRepl {k:1})-[:LINKS]->(b:EdgeRepl {k:2})",
        "MATCH (:EdgeRepl)-[r:LINKS]->(:EdgeRepl) RETURN count(r) AS c",
        "\"c\":1",
    );

    // Also assert the two endpoint nodes landed on the followers.
    try assertMutationReplicates(
        &cluster,
        "EdgeRepl-nodes",
        // No-op mutation: re-run is not needed, we only want to read.  Use a
        // constant-RETURN replicable create as a cheap "barrier" then read.
        "RETURN 1",
        "MATCH (n:EdgeRepl) RETURN count(n) AS c",
        "\"c\":2",
    );
}

// ---------------------------------------------------------------------------
// Test 2: DELETE / DETACH DELETE replicates.
// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MUTATIONS; FEATURE="DistributedCluster"; ASPECT=ReplicateDelete; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
test "cluster: DETACH DELETE replicates to followers" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    // Seed via the replicable single-node CREATE path (works at HEAD), so every
    // follower starts with exactly one :DelRepl node.
    try seedReplicableNode(&cluster, "DelRepl", "CREATE (:DelRepl {id:1})");

    // Now DELETE it on the leader. At HEAD executeDelete fails closed with
    // error.ClusterWriteNotReplicable AND the apply path is a stub, so the
    // followers keep the node -> never converge to count 0.
    try assertMutationReplicates(
        &cluster,
        "DelRepl",
        "MATCH (n:DelRepl) DETACH DELETE n",
        "MATCH (n:DelRepl) RETURN count(n) AS c",
        "\"c\":0",
    );
}

/// Run `q` against the current leader, retrying on a leadership move, and
/// return its output (the caller frees it with `cluster.gpa`).
fn runOnLeader(cluster: *Cluster, q: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (attempt < 12) : (attempt += 1) {
        const leader_ip = cluster.leaderIp() orelse {
            sleepMs(500);
            continue;
        };
        const out = runQuery(cluster.gpa, cluster.io, cluster.aa, leader_ip, q) catch {
            sleepMs(500);
            continue;
        };
        if (std.mem.indexOf(u8, out, "ClusterNotLeader") != null) {
            cluster.gpa.free(out);
            sleepMs(700);
            continue;
        }
        return out;
    }
    return error.NoStableLeaderForWrite;
}

// ---------------------------------------------------------------------------
// Test 2b: a DELETE's RETURN is the RETURN it asked for (SONNY-3044).
// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-SONNY-3044-CLUSTER-DELETE-RETURN; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-09-27
test "cluster: a DELETE's RETURN is computed over the rows it deletes, as a standalone server computes it" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    try seedReplicableNode(&cluster, "DelRet", "CREATE (:DelRet {i: 1})");
    try assertMutationReplicates(&cluster, "DelRet#2", "CREATE (:DelRet {i: 2})", "MATCH (n:DelRet) RETURN count(n) AS c", "\"c\":2");

    // The leader answered `deleted_count` whatever the RETURN asked for.
    const out = try runOnLeader(&cluster, "MATCH (n:DelRet) DELETE n RETURN sum(n.i) AS s");
    defer gpa.free(out);
    if (std.mem.indexOf(u8, out, "\"s\":3") == null or std.mem.indexOf(u8, out, "deleted_count") != null) {
        std.debug.print("\n[repl] the leader's DELETE ... RETURN sum(n.i) AS s answered: {s}\n", .{out});
        return error.WrongDeleteReturn;
    }
    // And the delete replicated.
    try assertMutationReplicates(&cluster, "DelRet-deleted", "RETURN 1", "MATCH (n:DelRet) RETURN count(n) AS c", "\"c\":0");
}

// ---------------------------------------------------------------------------
// Test 3: MERGE replicates and is idempotent across re-execution.
// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MUTATIONS; FEATURE="DistributedCluster"; ASPECT=ReplicateMerge; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
test "cluster: MERGE replicates and is idempotent" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    // First MERGE: creates the node. At HEAD executeMerge fails closed
    // (error.ClusterWriteNotReplicable) -> followers never see it.
    try assertMutationReplicates(
        &cluster,
        "MergeRepl#1",
        "MERGE (n:MergeRepl {k: 1})",
        "MATCH (n:MergeRepl) RETURN count(n) AS c",
        "\"c\":1",
    );

    // Second MERGE of the SAME key: must be idempotent. Still exactly 1 node on
    // every follower (not 2). After the fix, MERGE's match-or-create semantics
    // replicate deterministically.
    try assertMutationReplicates(
        &cluster,
        "MergeRepl#2",
        "MERGE (n:MergeRepl {k: 1})",
        "MATCH (n:MergeRepl) RETURN count(n) AS c",
        "\"c\":1",
    );
}

// ---------------------------------------------------------------------------
// Test 4: MATCH ... SET replicates (silent-divergence regression).
// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MUTATIONS; FEATURE="DistributedCluster"; ASPECT=ReplicateMatchSet; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
test "cluster: MATCH...SET replicates (silent divergence regression)" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    // Seed a replicable node with v=1 (works at HEAD), converge on all followers.
    try seedReplicableNode(&cluster, "SetRepl", "CREATE (:SetRepl {v: 1})");

    // Confirm the seed value is v=1 on the followers first (precondition).
    try assertMutationReplicates(
        &cluster,
        "SetRepl-seed-v1",
        "RETURN 1",
        "MATCH (n:SetRepl) RETURN n.v AS v",
        "\"v\":1",
    );

    // Now SET v=2 on the leader. At HEAD MATCH...SET is NOT gated and NOT routed
    // through Raft -- it mutates ONLY the leader's local store. The followers
    // keep v=1 -> THIS IS THE SILENT DIVERGENCE. assertMutationReplicates polls
    // the followers for v=2 and fails with error.ReplicationIncomplete at HEAD.
    assertMutationReplicates(
        &cluster,
        "SetRepl-v2",
        "MATCH (n:SetRepl) SET n.v = 2",
        "MATCH (n:SetRepl) RETURN n.v AS v",
        "\"v\":2",
    ) catch |err| {
        std.debug.print(
            "\n[repl] SILENT DIVERGENCE: leader applied `SET n.v = 2` locally but it\n" ++
                "       NEVER replicated through Raft -- followers still report v=1.\n" ++
                "       MATCH...SET is ungated in cluster mode (query_execution.zig only\n" ++
                "       routes when a create_pattern is present; match_operations.zig\n" ++
                "       writes the local store directly).\n",
            .{},
        );
        return err;
    };
}

// ---------------------------------------------------------------------------
// Test 5: MATCH ... CREATE edge between EXISTING nodes replicates
// (silent-divergence regression, confirmed live on a 3-pod k8s cluster).
// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=ReplicateMatchCreateEdge; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
test "cluster: MATCH…CREATE edge between existing nodes replicates to followers" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    // Seed both endpoints through the (working) replicable CREATE path so every
    // follower already holds the two nodes before the edge write.
    try seedReplicableNode(&cluster, "McSrc", "CREATE (n:McSrc {id:1})");
    try seedReplicableNode(&cluster, "McDst", "CREATE (n:McDst {id:2})");

    // THE LIVE BUG: at HEAD `MATCH (a),(b) CREATE (a)-[:R]->(b)` bypasses
    // clusterWriteRole() entirely — the leader returns 00000 success, writes
    // the edge to its LOCAL store only, and never proposes through Raft. The
    // followers never see the edge -> error.ReplicationIncomplete (silent
    // divergence).
    assertMutationReplicates(
        &cluster,
        "MatchCreateEdge",
        "MATCH (a:McSrc {id:1}), (b:McDst {id:2}) CREATE (a)-[:MCL]->(b)",
        "MATCH (:McSrc)-[r:MCL]->(:McDst) RETURN count(r) AS c",
        "\"c\":1",
    ) catch |err| {
        std.debug.print(
            "\n[repl] SILENT DIVERGENCE: leader applied `MATCH…CREATE (a)-[:MCL]->(b)`\n" ++
                "       locally (00000 success) but it NEVER replicated through Raft --\n" ++
                "       followers report 0 :MCL edges. MATCH…CREATE bypasses\n" ++
                "       clusterWriteRole() on the leader.\n",
            .{},
        );
        return err;
    };
}

// ---------------------------------------------------------------------------
// Test 6: MATCH ... CREATE edge sent to a FOLLOWER must fail closed.
// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=MatchCreateFollowerFailClosed; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
test "cluster: MATCH…CREATE edge sent to a follower fails closed" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    // Seed both endpoints via the replicable CREATE path so the follower holds
    // them locally (the MATCH must succeed; only the CREATE must be refused).
    try seedReplicableNode(&cluster, "McFSrc", "CREATE (n:McFSrc {id:1})");
    try seedReplicableNode(&cluster, "McFDst", "CREATE (n:McFDst {id:2})");

    // Re-resolve the leader RIGHT BEFORE picking a follower (leadership can
    // move during the seeding phase) and pick a HEALTHY non-leader node.
    drainAll(&cluster.captures, &cluster.children, gpa, io);
    const cur_leader = currentLeaderIdx(&cluster.captures) orelse return error.LeaderDidNotHold;
    var follower_idx: ?usize = null;
    for (0..3) |i| {
        if (i != cur_leader and isNodeHealthy(&cluster.captures, i)) {
            follower_idx = i;
            break;
        }
    }
    const fidx = follower_idx orelse return error.NoHealthyFollower;
    const follower_ip = NODE_IPS[fidx];

    // THE LIVE BUG (follower half): at HEAD the follower accepts this write
    // (00000 success), applies the edge to its LOCAL store only, and never
    // forwards/rejects -> a follower holds data the rest of the cluster does
    // not. It must instead be rejected with error.ClusterNotLeader.
    const rej_out = runQuery(gpa, io, aa, follower_ip, "MATCH (a:McFSrc {id:1}), (b:McFDst {id:2}) CREATE (a)-[:FOLLOWERMCL]->(b)") catch |err| {
        std.debug.print("[repl] follower MATCH…CREATE probe {s} failed: {s}\n", .{ follower_ip, @errorName(err) });
        return error.FollowerWriteProbeFailed;
    };
    defer gpa.free(rej_out);
    if (std.mem.indexOf(u8, rej_out, "ClusterNotLeader") == null) {
        std.debug.print(
            "\n[repl] FOLLOWER ACCEPTED MATCH…CREATE (expected ClusterNotLeader rejection):\n{s}\n",
            .{rej_out},
        );
        return error.FollowerAcceptedMatchCreate;
    }

    // And nothing may have landed in the follower's local store (divergence).
    sleepMs(1500);
    drainAll(&cluster.captures, &cluster.children, gpa, io);
    const fr_read = runQuery(gpa, io, aa, follower_ip, "MATCH (:McFSrc)-[r:FOLLOWERMCL]->(:McFDst) RETURN count(r) AS c") catch return error.FollowerWriteProbeFailed;
    defer gpa.free(fr_read);
    if (std.mem.indexOf(u8, fr_read, "\"c\":0") == null) {
        std.debug.print("[repl] FOLLOWER SILENTLY APPLIED MATCH…CREATE (divergence): {s}\n", .{fr_read});
        return error.FollowerAppliedWriteLocally;
    }
}

// ---------------------------------------------------------------------------
// Test 7: every durable write surface WITHOUT a Raft replication slice must
// fail closed in cluster mode (no silent divergence).
// ---------------------------------------------------------------------------
// Fixed 2026-06-10 (docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md):
// write surfaces with no Raft replication slice now fail closed instead of
// silently applying to the local store only. This has been the green pin
// ever since — `gateUnreplicatedWrite` (src/distributed/cluster.zig) refuses
// every gated surface listed in CLAUDE.md's "Cluster-mode fail-closed
// surfaces" section (geode.ts.insert*, auth/policy DDL, tenant
// create/drop/set_quota, CREATE/DROP INDEX/GRAPH, constraints, mutating
// TDE/CDC/FLE procedures):
//   leader   → error.ClusterWriteNotReplicable (no replication slice exists)
//   follower → error.ClusterNotLeader          (standard Raft redirect)
//   standalone → unchanged.
// This test accumulates ALL accepting surfaces before failing, so a future
// regression that reopens any hole shows the full inventory in one pass.
// CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=E2EFailClosed; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-08-28
test "cluster: unreplicated write surfaces fail closed (no silent divergence)" {
    if (skipPreflight()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cluster = startCluster(gpa, aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer cluster.deinit();

    // Every ungated durable write surface the wire harness can express with
    // the admin connection runQuery already uses (-U geode -P <admin pw>):
    //   * timeseries ingest    (src/execution/ts_dispatch.zig handleInsert)
    //   * auth DDL             (src/execution/admin_ddl.zig executeCreateUser;
    //                           syntax per docs/GQL_AUTH_DDL.md: SET PASSWORD)
    //   * graph DDL            (src/execution.zig CreateGraph)
    //   * fulltext index DDL   (src/execution.zig CreateIndex USING fulltext)
    //   * fulltext rebuild     (src/execution/fts_dispatch.zig handleFtsRebuild)
    //   * tenant ops           (src/execution/tenant_dispatch.zig
    //                           geode.tenant.create — admin role passes the
    //                           admin_tenant GPS gate)
    //   * policy DDL           (src/execution.zig CreatePolicy; syntax per
    //                           tests/test_gps_policy_ddl_parser.zig)
    const Surface = struct { name: []const u8, query: []const u8 };
    const surfaces = [_]Surface{
        .{ .name = "timeseries-insert", .query = "CALL geode.ts.insert(1, 'temp', 100, 42)" },
        .{ .name = "auth-ddl-create-user", .query = "CREATE USER fcuser SET PASSWORD 'Str0ng!Pass1'" },
        .{ .name = "graph-ddl-create-graph", .query = "CREATE GRAPH fcgraph" },
        .{ .name = "index-ddl-fulltext", .query = "CREATE INDEX fcidx FOR (n:FcDoc) ON (n.body) USING fulltext" },
        // fulltext rebuild (src/execution/fts_dispatch.zig handleFtsRebuild):
        // the gate fires before index resolution (cluster_mod.gateUnreplicatedWrite
        // runs before fts_index_ops.rebuildFulltextIndex), so the fail-closed
        // refusal happens regardless of whether 'fcidx' actually exists.
        .{ .name = "fulltext-rebuild", .query = "CALL geode.fts.rebuild('fcidx')" },
        .{ .name = "tenant-create", .query = "CALL geode.tenant.create('fctenant')" },
        .{ .name = "policy-ddl-create-policy", .query = "CREATE POLICY fcpol ON GRAPH * FOR READ" },
    };

    var failures: std.ArrayList([]const u8) = .empty;
    defer failures.deinit(aa);

    for (surfaces) |s| {
        // ── LEADER half: must refuse with error.ClusterWriteNotReplicable. ──
        // Retry on a leadership move (ClusterNotLeader from the node we
        // believed was the leader) exactly like assertMutationReplicates.
        var attempt: usize = 0;
        var leader_checked = false;
        while (attempt < 12) : (attempt += 1) {
            const leader_ip = cluster.leaderIp() orelse {
                sleepMs(500);
                continue;
            };
            const out = runQuery(gpa, io, aa, leader_ip, s.query) catch {
                sleepMs(500);
                continue;
            };
            defer gpa.free(out);
            if (std.mem.indexOf(u8, out, "ClusterNotLeader") != null) {
                // Leadership moved between log-scan and query; retry.
                sleepMs(700);
                continue;
            }
            leader_checked = true;
            if (std.mem.indexOf(u8, out, "ClusterWriteNotReplicable") == null) {
                // RED: the leader ACCEPTED (or failed for an unrelated reason
                // instead of the gate) — either way the fail-closed gate is
                // missing. Print the actual output for diagnosis.
                std.debug.print(
                    "\n[failclosed] LEADER did not refuse '{s}' with ClusterWriteNotReplicable\n" ++
                        "  query : {s}\n  output: {s}\n",
                    .{ s.name, s.query, out },
                );
                try failures.append(aa, try std.fmt.allocPrint(aa, "{s} (leader accepted)", .{s.name}));
            }
            break;
        }
        if (!leader_checked) {
            try failures.append(aa, try std.fmt.allocPrint(aa, "{s} (no stable leader to probe)", .{s.name}));
            continue;
        }

        // ── FOLLOWER half: must refuse with error.ClusterNotLeader. ─────────
        drainAll(&cluster.captures, &cluster.children, gpa, io);
        const cur_leader = currentLeaderIdx(&cluster.captures) orelse {
            try failures.append(aa, try std.fmt.allocPrint(aa, "{s} (leader lost before follower probe)", .{s.name}));
            continue;
        };
        var follower_idx: ?usize = null;
        for (0..3) |i| {
            if (i != cur_leader and isNodeHealthy(&cluster.captures, i)) {
                follower_idx = i;
                break;
            }
        }
        const fidx = follower_idx orelse {
            try failures.append(aa, try std.fmt.allocPrint(aa, "{s} (no healthy follower to probe)", .{s.name}));
            continue;
        };
        const f_out = runQuery(gpa, io, aa, NODE_IPS[fidx], s.query) catch |err| {
            std.debug.print("[failclosed] follower probe for '{s}' failed: {s}\n", .{ s.name, @errorName(err) });
            try failures.append(aa, try std.fmt.allocPrint(aa, "{s} (follower probe failed)", .{s.name}));
            continue;
        };
        defer gpa.free(f_out);
        if (std.mem.indexOf(u8, f_out, "ClusterNotLeader") == null) {
            // RED: the follower accepted the write into its LOCAL store (or
            // failed for an unrelated reason instead of the redirect) — a
            // follower-only write is divergence by definition.
            std.debug.print(
                "\n[failclosed] FOLLOWER did not refuse '{s}' with ClusterNotLeader\n" ++
                    "  query : {s}\n  output: {s}\n",
                .{ s.name, s.query, f_out },
            );
            try failures.append(aa, try std.fmt.allocPrint(aa, "{s} (follower accepted)", .{s.name}));
        }
    }

    if (failures.items.len != 0) {
        std.debug.print(
            "\n[failclosed] {d} unreplicated write surface(s) did NOT fail closed in cluster mode:\n",
            .{failures.items.len},
        );
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        std.debug.print(
            "  Each acceptance above is a single-node write that the rest of the\n" ++
                "  cluster never sees -> SILENT DIVERGENCE. Expected: leader refuses\n" ++
                "  with ClusterWriteNotReplicable, follower with ClusterNotLeader\n" ++
                "  (gateUnreplicatedWrite, src/distributed/cluster.zig).\n",
            .{},
        );
        return error.UnreplicatedSurfaceAcceptedWrite;
    }
}
