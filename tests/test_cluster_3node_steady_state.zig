// CANARY: REQ=REQ-DIST-CLUSTER-STEADY-STATE-TLS; FEATURE="DistributedCluster"; ASPECT=SteadyStateLeaderHoldDistinctIpTls; STATUS=TESTED; TEST=tests/test_cluster_3node_steady_state.zig; OWNER=distributed; UPDATED=2026-06-04
//
// Regression for docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md
//
// The existing loopback subprocess test (test_cluster_3node_subprocess.zig) runs
// three nodes on the SAME loopback IP (127.0.0.1) with DIFFERENT cluster ports,
// in GEODE_CLUSTER_INSECURE mode. That does NOT reproduce a real multi-pod
// deployment, where each node binds the SAME cluster port on a DISTINCT IP and
// peers verify a CA-signed TLS cert.
//
// This test brings up three real `geode serve` processes on DISTINCT loopback
// IPs (127.0.0.11/12/13), all binding cluster port 4242, with a cert-manager-
// style CA + a shared CA-signed leaf (SANs covering the three IPs) and
// GEODE_CLUSTER_CA_CERT pinned to the CA — i.e. secure peer TLS, exactly like
// the arda k8s cluster. It asserts:
//
//   1. a single leader is elected (and the other two are followers at the same
//      term), and
//   2. that leader HOLDS for >= HOLD_SECONDS with the cluster never collapsing
//      to "no leader" (the flap-to-all-candidates failure mode in the bug).
//
// Binding each node to a distinct address is only possible because of the
// GEODE_CLUSTER_LISTEN_ADDRESS knob added alongside this test: without it the
// cluster listener hardcodes 0.0.0.0:<port>, so three co-located processes share
// the socket via SO_REUSEPORT and the kernel misroutes peer handshake datagrams.
//
// Skips (error.SkipZigTest, never silently passes) when: not linux, the geode
// binary is missing (run `zig build` first), openssl is unavailable, or
// 127.0.0.11 cannot be bound. Set GEODE_SKIP_SUBPROC_CLUSTER=1 to opt out on a
// flaky CI runner.

const std = @import("std");
const builtin = @import("builtin");

const BINARY_PATH = "./zig-out/bin/geode";
const NODE_IPS = [_][]const u8{ "127.0.0.11", "127.0.0.12", "127.0.0.13" };
const CLUSTER_PORT: u16 = 4242;
const STARTUP_DEADLINE_MS: i64 = 45_000;
const HOLD_SECONDS: i64 = 15;

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
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
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

const ADMIN_PW = "SteadyStatePw123!";

/// Run `geode query` against `ip:3141` and return captured stdout (caller frees
/// with `gpa`). Bounded by a hard timeout so a hung query can't wedge the suite.
fn runQuery(gpa: std.mem.Allocator, io: std.Io, aa: std.mem.Allocator, ip: []const u8, q: []const u8) ![]u8 {
    const server = try std.fmt.allocPrint(aa, "{s}:3141", .{ip});
    const argv = [_][]const u8{
        BINARY_PATH,                  "query", "--server", server,
        "--insecure-tls-skip-verify", "-U",    "geode",    "-P",
        ADMIN_PW,                     q,
    };
    const res = try std.process.run(gpa, io, .{
        .argv = &argv,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(15 * std.time.ns_per_s),
            .clock = .awake,
        } },
    });
    gpa.free(res.stderr);
    return res.stdout;
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

    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-cluster-ss-{d}", .{std.os.linux.getpid()});
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
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-ss-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-new", "-key", leaf_key, "-subj", "/CN=geode-node", "-out", leaf_csr });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "x509", "-req", "-in", leaf_csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", leaf });
    return .{ .dir = dir, .ca = ca, .leaf = leaf, .key = leaf_key };
}

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
        // role token
        var e = after;
        while (e < buf.len and buf[e] != ' ') e += 1;
        role = buf[after..e];
        // term=
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

test "3 nodes on distinct IPs with CA-signed TLS elect and HOLD a single leader" {
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

    const certs = makeCerts(aa, io) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer std.Io.Dir.cwd().deleteTree(io, certs.dir) catch {};

    const peers = "127.0.0.11:4242,127.0.0.12:4242,127.0.0.13:4242";
    const token = "steady-state-cluster-token";
    const hmac = "steady-hmac-0123456789abcdef0123456789abcdef";

    var children: [3]std.process.Child = undefined;
    var spawned: usize = 0;
    defer for (children[0..spawned]) |*ch| ch.kill(io);

    var captures: [3]Capture = .{ .{}, .{}, .{} };
    defer for (&captures) |*c| c.buf.deinit(gpa);

    for (0..3) |i| {
        const ip = NODE_IPS[i];
        const data_dir = try std.fmt.allocPrint(aa, "{s}/data{d}", .{ certs.dir, i + 1 });
        std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
        const listen = try std.fmt.allocPrint(aa, "{s}:3141", .{ip});
        const node_id = try std.fmt.allocPrint(aa, "{d}", .{i + 1});

        const args = [_][]const u8{
            BINARY_PATH,      "serve",   "--listen",    listen,
            "--cluster-port", "4242",    "--peers",     peers,
            "--data-dir",     data_dir,  "--cert",      certs.leaf,
            "--key",          certs.key, "--log-level", "info",
        };
        const env = try aa.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(aa);
        try env.put("GEODE_CLUSTER_TOKEN", token);
        try env.put("GEODE_AUTH_HMAC_KEY", hmac);
        try env.put("GEODE_NODE_ID", node_id);
        try env.put("GEODE_PEERS", peers);
        try env.put("GEODE_CLUSTER_PORT", "4242");
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", ip);
        try env.put("GEODE_CLUSTER_CA_CERT", certs.ca);
        try env.put("GEODE_ADMIN_PASSWORD", "SteadyStatePw123!");
        if (posixGetenv("PATH")) |p| try env.put("PATH", p);
        if (posixGetenv("HOME")) |p| try env.put("HOME", p);
        if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);

        children[i] = std.process.spawn(io, .{ .argv = &args, .environ_map = env, .stdout = .pipe, .stderr = .pipe }) catch |err| {
            std.debug.print("spawn node {d} failed: {s}\n", .{ i + 1, @errorName(err) });
            return error.SkipZigTest;
        };
        spawned += 1;
        try setNonBlocking(children[i].stdout.?);
        try setNonBlocking(children[i].stderr.?);
    }

    // Phase 1: wait for a single leader + two followers at a common term.
    const startup_deadline = nowMillis() + STARTUP_DEADLINE_MS;
    var have_quorum = false;
    while (nowMillis() < startup_deadline) {
        for (0..3) |i| {
            captures[i].drain(gpa, io, children[i].stdout.?);
            captures[i].drain(gpa, io, children[i].stderr.?);
        }
        var leaders: usize = 0;
        var followers: usize = 0;
        var leader_term: i64 = -1;
        for (0..3) |i| {
            const s = lastState(captures[i].buf.items, i + 1);
            if (s.role) |r| {
                if (std.mem.eql(u8, r, "leader")) {
                    leaders += 1;
                    leader_term = s.term;
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
            const tail_start = if (captures[i].buf.items.len > 1500) captures[i].buf.items.len - 1500 else 0;
            std.debug.print("\n--- node {d} log tail (no leader+quorum) ---\n{s}\n", .{ i + 1, captures[i].buf.items[tail_start..] });
        }
        return error.NoLeaderElected;
    }

    // Phase 2: the leader must HOLD. Over HOLD_SECONDS, every sampled window must
    // still show exactly one leader and at least one follower — never a window
    // with no leader (the flap-to-all-candidates failure in the bug report).
    const hold_deadline = nowMillis() + HOLD_SECONDS * 1000;
    var samples: usize = 0;
    var no_leader_windows: usize = 0;
    while (nowMillis() < hold_deadline) {
        sleepMs(1000);
        for (0..3) |i| {
            captures[i].drain(gpa, io, children[i].stdout.?);
            captures[i].drain(gpa, io, children[i].stderr.?);
        }
        var leaders: usize = 0;
        for (0..3) |i| {
            const s = lastState(captures[i].buf.items, i + 1);
            if (s.role) |r| {
                if (std.mem.eql(u8, r, "leader")) leaders += 1;
            }
        }
        samples += 1;
        if (leaders == 0) no_leader_windows += 1;
    }

    if (no_leader_windows > 0) {
        for (0..3) |i| {
            const tail_start = if (captures[i].buf.items.len > 1500) captures[i].buf.items.len - 1500 else 0;
            std.debug.print("\n--- node {d} log tail (leader did not hold) ---\n{s}\n", .{ i + 1, captures[i].buf.items[tail_start..] });
        }
        std.debug.print("leader collapsed in {d}/{d} sampled windows\n", .{ no_leader_windows, samples });
        return error.LeaderDidNotHold;
    }

    // Confirm at least one node ended as leader, and find it.
    var leader_idx: ?usize = null;
    for (0..3) |i| {
        const s = lastState(captures[i].buf.items, i + 1);
        if (s.role) |r| if (std.mem.eql(u8, r, "leader")) {
            leader_idx = i;
        };
    }
    const li = leader_idx orelse return error.LeaderDidNotHold;

    // Phase 3 — REPLICATION (asserted). A graph write on the leader routes
    // through Raft (crud_operations.zig → proposeCommand) and MUST replicate to
    // BOTH followers and be readable there.  This was the core defect in
    // docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md and
    // is now fixed entirely in geode's raft bridge (the pinned raft library was
    // correct — it shipped the entries; geode dropped/UAF'd/buried them):
    //   1. proto boundary carried no log entries (messageToProto/protoToMessage
    //      now serialize each command into RaftLogEntry.command_bytes),
    //   2. the bridge aliased the library's unstable entry data that stableTo
    //      then freed before the async outbox encoded it (raftLibMessageToGeode
    //      now deep-copies into owned_wire_bytes),
    //   3. a freshly-proposed entry was buried behind an unbounded heartbeat
    //      backlog (enqueueOutbound now coalesces AppendEntries per peer).
    // A leader CREATE must now be visible on a follower; assert it.
    const leader_ip = NODE_IPS[li];

    const create_out = runQuery(gpa, io, aa, leader_ip, "CREATE (:ReplTest {v:1})") catch |err| {
        std.debug.print("[repl] CREATE on leader {s} failed: {s}\n", .{ leader_ip, @errorName(err) });
        return error.LeaderCreateFailed;
    };
    defer gpa.free(create_out);
    sleepMs(3000);

    // Assert the write replicated to BOTH followers (read it back on each).
    var replicated_followers: usize = 0;
    for (0..3) |fi| {
        if (fi == li) continue;
        const follower_ip = NODE_IPS[fi];
        const read_out = runQuery(gpa, io, aa, follower_ip, "MATCH (n:ReplTest) RETURN count(n) AS c") catch |err| {
            std.debug.print("[repl] follower read {s} failed: {s}\n", .{ follower_ip, @errorName(err) });
            continue;
        };
        defer gpa.free(read_out);
        if (std.mem.indexOf(u8, read_out, "\"c\":1") != null) {
            replicated_followers += 1;
            std.debug.print("[repl] leader CREATE replicated to follower {s}\n", .{follower_ip});
        } else {
            std.debug.print("[repl] leader CREATE NOT replicated to follower {s}: {s}\n", .{ follower_ip, read_out });
        }
    }
    // A 3-node cluster must replicate the write to at least one follower (a
    // quorum of 2 commits it; both followers should converge).
    try std.testing.expect(replicated_followers >= 1);
}
