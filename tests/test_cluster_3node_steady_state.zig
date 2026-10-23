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
    query_ca_path = ca;
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

/// State lines node `id` logged in `buf[off..]`: how many, and whether any
/// reported `state=leader`.
fn stateLinesSince(buf: []const u8, off: usize, id: usize) struct { lines: usize, leader: bool } {
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "node {d} state=", .{id}) catch return .{ .lines = 0, .leader = false };
    var lines: usize = 0;
    var leader = false;
    var search: usize = @min(off, buf.len);
    while (std.mem.indexOfPos(u8, buf, search, prefix)) |pos| {
        lines += 1;
        if (std.mem.startsWith(u8, buf[pos + prefix.len ..], "leader")) leader = true;
        search = pos + prefix.len;
    }
    return .{ .lines = lines, .leader = leader };
}

/// Robust teardown: SIGTERM each node, then keep draining its stdout+stderr
/// pipe while polling for exit, with a SIGKILL fallback after a deadline.  This
/// avoids the teardown deadlock where `Child.kill` (SIGTERM + a BLOCKING wait4,
/// no SIGKILL fallback in Zig 0.16) hangs forever because the node can't finish
/// its graceful shutdown while a logging thread is blocked on a full pipe that
/// nobody is draining.  Reaps each child so no zombie is left.
/// Non-blocking reap. Returns true once `pid` has been collected.  The raw
/// linux `waitpid` returns the child pid on a successful reap, 0 when the child
/// is still alive (WNOHANG), or a negative errno otherwise.
fn tryReap(pid: i32, flags: u32) bool {
    var status: u32 = undefined;
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return @as(isize, @bitCast(rc)) > 0;
}

fn teardownNodes(children: []std.process.Child, captures: []Capture, spawned: usize, gpa: std.mem.Allocator, io: std.Io) void {
    // Phase 1: SIGTERM and keep draining pipes so a node's graceful-shutdown
    // logging never blocks on a full pipe.  Poll (non-blocking) for exit.
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
                ch.id = null; // reaped
            } else {
                all_gone = false;
            }
        }
        if (all_gone) break;
        sleepMs(100);
    }
    // Phase 2: SIGKILL + blocking reap anything that ignored SIGTERM.
    for (children[0..spawned]) |*ch| {
        if (ch.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = tryReap(pid, 0);
            ch.id = null;
        }
    }
    // Close the inherited pipe FDs so the test process leaks none.
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

/// Continuously drain every node's stdout+stderr pipe.  CRITICAL: the three
/// `--log-level info` nodes keep logging throughout the replication phases; if
/// the harness ever stops reading, a node's pipe buffer (64 KiB) fills, its
/// logging thread blocks in `pipe_write`, and the whole node stalls — which both
/// spuriously fails replication AND wedges teardown (`ch.kill` → `do_wait` while
/// the node can't exit on a blocked pipe).  Call this inside every sleep in the
/// replication/hold loops, not just startup.
fn drainAll(captures: []Capture, children: []std.process.Child, gpa: std.mem.Allocator, io: std.Io) void {
    for (children, 0..) |*ch, i| {
        if (ch.stdout) |f| captures[i].drain(gpa, io, f);
        if (ch.stderr) |f| captures[i].drain(gpa, io, f);
    }
}

/// Index of the node whose last observed raft state is "leader", or null.
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

/// A node is "healthy" if it produced a raft state line — i.e. it actually
/// started and joined raft. On a dev host where a node's client port (:3141) is
/// already bound by another geode it fails to start and is excluded here, so the
/// surviving quorum is still asserted (and the dead node is never queried, which
/// would otherwise stall the poll on a 15s client timeout).
fn isNodeHealthy(captures: []const Capture, idx: usize) bool {
    return lastState(captures[idx].buf.items, idx + 1).role != null;
}

/// Run a CREATE on the CURRENT leader (re-resolved each attempt, since leadership
/// can move on a loaded host) and assert it replicates to EVERY healthy follower.
/// Retries when the chosen node turns out not to be the leader
/// (error.ClusterNotLeader). Only healthy nodes are queried, so a node that never
/// started cannot stall the poll. Errors if there is no healthy follower or one
/// never receives the row (the leader-only divergence this bug is about).
fn assertReplicatesToHealthyFollowers(
    gpa: std.mem.Allocator,
    io: std.Io,
    aa: std.mem.Allocator,
    captures: []Capture,
    children: []std.process.Child,
    label: []const u8,
    create_q: []const u8,
) !void {
    const read_q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{label});
    // Creates actually handed to a node. A create whose client call failed
    // (timeout) or that came back ClusterNotLeader after the old leader had
    // already appended it can still commit, and an external retry is not
    // deduplicated (crud_operations.zig effectiveIdempotencyKey: the
    // documented residual), so the label may end up with up to `sent` rows.
    var sent: usize = 0;
    var attempt: usize = 0;
    const li: usize = while (attempt < 12) : (attempt += 1) {
        drainAll(captures, children, gpa, io);
        const idx = currentLeaderIdx(captures) orelse {
            sleepMs(500);
            continue;
        };
        sent += 1;
        const out = runQuery(gpa, io, aa, NODE_IPS[idx], create_q) catch {
            sleepMs(500);
            continue;
        };
        defer gpa.free(out);
        // Leadership moved between resolve and send — retry against the new leader.
        if (std.mem.indexOf(u8, out, "ClusterNotLeader") != null) {
            sleepMs(700);
            continue;
        }
        // NOTE: the create may return a `Timeout` here when commit latency on a
        // loaded host exceeds the leader's internal waitForApplied budget — the
        // write still replicates, it just hasn't committed by the time the client
        // call returns (commit-latency-under-load, root cause #5 in the bug doc).
        // So we do NOT gate replication on this response; we poll the followers.
        break idx;
    } else return error.NoStableLeaderForWrite;

    // Expected = healthy non-leader nodes (the quorum's followers).
    var expected: usize = 0;
    for (0..3) |i| {
        if (i != li and isNodeHealthy(captures, i)) expected += 1;
    }
    if (expected == 0) return error.NoHealthyFollower;

    // Replication is asserted by EVERY healthy node (the leader the create went
    // to and every healthy follower) reporting the same row count, at least 1
    // and at most the number of creates sent. A never-started node is skipped,
    // so it cannot stall this loop. Bounded wait (60 s) for commit + apply on a
    // loaded host; a follower that never receives the row still fails.
    var last_out: [3][]const u8 = .{ "", "", "" };
    const deadline = nowMillis() + 60_000;
    var polls: usize = 0;
    while (nowMillis() < deadline) {
        sleepMs(1000);
        polls += 1;
        drainAll(captures, children, gpa, io);
        var agreed: ?u64 = null;
        var all_agree = true;
        for (0..3) |ni| {
            if (ni != li and !isNodeHealthy(captures, ni)) continue;
            const read_out = runQuery(gpa, io, aa, NODE_IPS[ni], read_q) catch |err| {
                last_out[ni] = @errorName(err);
                all_agree = false;
                continue;
            };
            defer gpa.free(read_out);
            last_out[ni] = aa.dupe(u8, read_out[0..@min(read_out.len, 300)]) catch "";
            const c = countOf(read_out) orelse {
                all_agree = false;
                continue;
            };
            if (agreed) |a| {
                if (a != c) all_agree = false;
            } else agreed = c;
        }
        if (all_agree) if (agreed) |n| if (n >= 1 and n <= sent) {
            if (n > 1) std.debug.print("[repl] '{s}': {d} rows from {d} creates sent (a retried create also committed)\n", .{ label, n, sent });
            std.debug.print("[repl] '{s}' replicated to all {d} healthy follower(s) after {d} poll(s)\n", .{ label, expected, polls });
            return;
        };
    }
    std.debug.print("[repl] '{s}' did NOT replicate to all {d} healthy follower(s) ({d} create(s) sent, leader node {d})\n", .{ label, expected, sent, li + 1 });
    for (0..3) |ni| std.debug.print("[repl]   node {d} last read: {s}\n", .{ ni + 1, last_out[ni] });
    return error.ReplicationIncomplete;
}

/// The integer after `"c":` in a `geode query` JSON result, or null.
fn countOf(out: []const u8) ?u64 {
    const key = "\"c\":";
    const at = std.mem.indexOf(u8, out, key) orelse return null;
    var i = at + key.len;
    var n: u64 = 0;
    var digits: usize = 0;
    while (i < out.len and out[i] >= '0' and out[i] <= '9') : (i += 1) {
        n = n * 10 + (out[i] - '0');
        digits += 1;
    }
    return if (digits == 0) null else n;
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
    var captures: [3]Capture = .{ .{}, .{}, .{} };
    // Free the capture buffers LAST (registered first → runs last, LIFO).
    defer for (&captures) |*c| c.buf.deinit(gpa);
    // Robust teardown (drains pipes while terminating, SIGKILL fallback) so a
    // node blocked on a full log pipe can't wedge `Child.kill`'s blocking wait.
    // Registered last → runs FIRST, so it can still drain into the (not-yet-
    // freed) capture buffers.
    defer teardownNodes(&children, &captures, spawned, gpa, io);

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
    _ = leader_idx orelse return error.LeaderDidNotHold;

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
    // A leader CREATE must now be visible on every healthy follower; assert it.
    // Asserting replication to ALL healthy followers (not just >=1) is what
    // catches the re-open's "leader-only" divergence. The write is sent to the
    // CURRENT leader (re-resolved, retry on a leadership move) so the assertion
    // measures replication, not a leadership race.
    try assertReplicatesToHealthyFollowers(gpa, io, aa, &captures, &children, "ReplTest", "CREATE (:ReplTest {v:1})");

    // Phase 4 — REPLICATION OF A `CREATE ... RETURN` (re-open regression).
    // A `CREATE (...) RETURN ...` reaches the executor via the query path, which
    // previously skipped Raft routing entirely (the routing only fired for a
    // bare create with NO RETURN) and wrote leader-local only, so the followers
    // stayed empty — exactly the re-open symptom. The cluster write-routing gate
    // (crud_operations.zig::clusterReplicateNodeCreate) now replicates a
    // RETURN-create through Raft and evaluates the constant RETURN. Assert it
    // lands on every healthy follower.
    try assertReplicatesToHealthyFollowers(gpa, io, aa, &captures, &children, "ReplRet", "CREATE (:ReplRet {v:2}) RETURN 1");

    // Phase 5 — FOLLOWER WRITES MUST FAIL CLOSED (re-open regression). A write
    // sent to a FOLLOWER previously fell through to that follower's local store
    // (the re-open's "exit 0 fast, committed locally, never replicated"). It
    // must now be rejected (error.ClusterNotLeader) and NOT applied anywhere —
    // a follower must never hold data the rest of the cluster does not.
    //
    // Roles come from the nodes' ~1 s `[raft] node N state=...` lines, so on a
    // loaded host leadership can move to the probed node between choosing it
    // and sending the write; it then accepts the write as the LEADER, which is
    // correct. Such an attempt is recognised from the probed node's own state
    // lines around the probe and retried on a fresh label; a write accepted by
    // a node that stayed a follower throughout fails the test.
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        drainAll(&captures, &children, gpa, io);
        const cur_leader = currentLeaderIdx(&captures) orelse return error.LeaderDidNotHold;
        // Pick a HEALTHY node whose latest state line says follower; never
        // probe a node that failed to start (its :3141 would be answered by an
        // unrelated process).
        var follower_idx: ?usize = null;
        for (0..3) |i| {
            const st = lastState(captures[i].buf.items, i + 1);
            if (i != cur_leader and st.role != null and std.mem.eql(u8, st.role.?, "follower")) {
                follower_idx = i;
                break;
            }
        }
        const fidx = follower_idx orelse {
            sleepMs(1000);
            continue;
        };
        const follower_ip = NODE_IPS[fidx];
        const label = try std.fmt.allocPrint(aa, "FollowerReject{d}", .{attempt});
        const create_q = try std.fmt.allocPrint(aa, "CREATE (:{s} {{v:9}})", .{label});
        const read_q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{label});

        const log_off = captures[fidx].buf.items.len;
        const rej_out = runQuery(gpa, io, aa, follower_ip, create_q) catch |err| {
            std.debug.print("[repl] follower-write probe {s} failed: {s}\n", .{ follower_ip, @errorName(err) });
            return error.FollowerWriteProbeFailed;
        };
        defer gpa.free(rej_out);
        // Let the probed node log at least two more state lines (bounded), so
        // its role around the probe is known.
        const settle_deadline = nowMillis() + 10_000;
        while (nowMillis() < settle_deadline) {
            sleepMs(250);
            drainAll(&captures, &children, gpa, io);
            if (stateLinesSince(captures[fidx].buf.items, log_off, fidx + 1).lines >= 2) break;
        }
        const fr_read = runQuery(gpa, io, aa, follower_ip, read_q) catch return error.FollowerWriteProbeFailed;
        defer gpa.free(fr_read);
        // The follower must NOT have applied the write (the divergence bug).
        if (std.mem.indexOf(u8, fr_read, "\"c\":0") != null) return;

        // Applied. Correct only if the probed node was the leader by then.
        const seen = stateLinesSince(captures[fidx].buf.items, log_off, fidx + 1);
        const prior = lastState(captures[fidx].buf.items[0..log_off], fidx + 1);
        const was_leader = seen.leader or (prior.role != null and std.mem.eql(u8, prior.role.?, "leader"));
        if (!was_leader) {
            std.debug.print("[repl] FOLLOWER SILENTLY APPLIED A WRITE (divergence): node {d} probe={s} read={s}\n", .{ fidx + 1, rej_out, fr_read });
            return error.FollowerAppliedWriteLocally;
        }
        std.debug.print("[repl] node {d} became leader around the follower-write probe (attempt {d}); retrying\n", .{ fidx + 1, attempt });
    }
    std.debug.print("[repl] no follower-write probe reached a node that stayed a follower in 5 attempts\n", .{});
    return error.FollowerWriteProbeInconclusive;
}
