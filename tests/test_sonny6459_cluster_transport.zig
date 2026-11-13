// SONNY-6459 items 5 and 6: two cluster transport defects.
//
// Item 5: `ClusterCoordinator.networkLoop` (src/distributed/cluster.zig)
// handed each accepted connection to `connection_pool`, but with the pool
// null it did nothing with it: the connection was neither handled nor
// destroyed and stayed tracked by the listener until a reaper found it. (A
// failed context allocation also ended the loop and leaked the connection.)
// The test starts a real coordinator (127.0.0.94) with the dead-connection
// reaper off and the inbound idle deadline far away, drops its connection
// pool, connects a real QUIC client that sends raft frames, and requires the
// listener to close the connection (the client sees CONNECTION_CLOSE) and
// stop tracking it.
//
// Item 6: `raft_consensus.Transport.getOrCreatePeerConnection` returned the
// cached connection for a peer id whenever it was established, even when
// the peer's configured endpoint had changed, so frames for the peer kept
// going to its old address. The test drives the real sender
// (`raft.useRealQuicInTests(true)`) against two real receivers (127.0.0.95
// and 127.0.0.96): a heartbeat to peer 1 at the first, then peer 1's
// endpoint changes to the second, and the next heartbeat must reach the
// second and not the first.
//
// CANARY: REQ=REQ-SONNY-6459-CLUSTER-TRANSPORT; FEATURE="DistributedCluster"; ASPECT=AcceptWithoutPoolAndPeerEndpointChange; STATUS=TESTED; TEST=tests/test_sonny6459_cluster_transport.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const test_ports = @import("test_ports.zig");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const raft = geode.distributed.raft_consensus;
const quic = @import("transport/quic");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Loopback addresses no other cluster test uses.
const accept_ip = "127.0.0.94";
const first_ip = "127.0.0.95";
const second_ip = "127.0.0.96";
/// Configured (never started) peers of the receivers.
const idle_peer_ips = [_][]const u8{ "127.0.0.97", "127.0.0.98" };
const token = "test-sonny6459-cluster-transport";
const deliver_budget_ms: i64 = 15_000;

fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]u8,

    fn init(a: std.mem.Allocator) !TestEnv {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(dir);
        if (setenv("GEODE_CLUSTER_INSECURE", "1", 1) != 0) return error.SetEnvFailed;
        if (setenv("GEODE_CLUSTER_TOKEN", token, 1) != 0) return error.SetEnvFailed;
        return .{ .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *TestEnv, a: std.mem.Allocator) void {
        _ = unsetenv("GEODE_CLUSTER_INSECURE");
        _ = unsetenv("GEODE_CLUSTER_TOKEN");
        a.free(self.dir);
        self.tmp.cleanup();
    }
};

fn startReceiver(a: std.mem.Allocator, env: *const TestEnv, ip: []const u8, port: u16) !*ClusterCoordinator {
    const cert_path = try std.fmt.allocPrint(a, "{s}/{s}.crt", .{ env.dir, ip });
    defer a.free(cert_path);
    const key_path = try std.fmt.allocPrint(a, "{s}/{s}.key", .{ env.dir, ip });
    defer a.free(key_path);
    const peers = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 2, .address = idle_peer_ips[0], .port = port },
        .{ .id = 3, .address = idle_peer_ips[1], .port = port },
    };
    const coord = try a.create(ClusterCoordinator);
    errdefer a.destroy(coord);
    coord.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers[0..],
        .listen_address = ip,
        .cluster_port = port,
        .cluster_token = token,
        .cluster_name = "test-sonny6459-cluster-transport",
        .election_timeout_ms = 60_000,
        .cert_path = cert_path,
        .key_path = key_path,
    });
    errdefer coord.deinit();
    try coord.start();
    return coord;
}

fn stopReceiver(a: std.mem.Allocator, coord: *ClusterCoordinator) void {
    coord.deinit();
    a.destroy(coord);
}

test "SONNY-6459 item 5: with no connection pool the cluster listener closes an accepted connection" {
    if (comptime builtin.mode != .Debug) return error.SkipZigTest; // insecure peer TLS + self-signed listener
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var env = try TestEnv.init(a);
    defer env.deinit(a);
    // Neither the dead-connection reaper nor the inbound idle deadline may
    // be what closes the connection.
    if (setenv("GEODE_RAFT_DEAD_CONN_REAP_MS", "0", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_RAFT_DEAD_CONN_REAP_MS");
    if (setenv("GEODE_CLUSTER_INBOUND_IDLE_MS", "60000", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_INBOUND_IDLE_MS");

    const port = try test_ports.freeUdpPort();
    const coord = try startReceiver(a, &env, accept_ip, port);
    defer stopReceiver(a, coord);
    sleepMs(300);
    // No connection has arrived yet, so the network loop is not using the
    // pool; take it away as if the coordinator had none.
    if (coord.connection_pool) |pool| {
        coord.connection_pool = null;
        pool.deinit();
    }

    var client = quic.QuicClient.init(a);
    defer client.deinit();
    try client.connectInsecure(accept_ip, port, true);
    try client.waitForHandshake(5);
    // Traffic on a stream, as a raft peer sends (the listener hands the
    // connection to the accept loop once the peer is talking).
    const stream = try client.openStream(true);
    defer stream.deinit();
    var no_entries = [_]raft.LogEntry{};
    const msg: raft.Message = .{ .append_entries = .{
        .term = 7,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = no_entries[0..],
        .leader_commit = 0,
    } };
    try raft.writeRaftFrame(a, stream, 2, 7, msg);

    const server = &coord.network_transport.quic_server.?;
    // The accept loop takes the connection; with no pool it must close it:
    // the client sees CONNECTION_CLOSE and the listener stops tracking it.
    // (Left alone it stays open: the reapers are off and the client keeps
    // talking.)
    const t0 = nowMillis();
    var last_send = t0;
    while (nowMillis() - t0 < 5_000) : (sleepMs(5)) {
        client.poll(5) catch {};
        if (client.isClosed() and server.getConnectionCount() == 0) break;
        if (nowMillis() - last_send >= 200) {
            last_send = nowMillis();
            raft.writeRaftFrame(a, stream, 2, 7, msg) catch {};
        }
    }
    const closed = client.isClosed();
    const left = server.getConnectionCount();
    std.debug.print("accepted with no pool: closed by the listener={}, still tracked after {d} ms: {d}\n", .{ closed, nowMillis() - t0, left });
    try std.testing.expect(closed);
    try std.testing.expectEqual(@as(usize, 0), left);
    try std.testing.expectEqual(@as(u32, 0), coord.active_connections.load(.acquire));
}

/// Heartbeats at `term` to `peer` through the real sender every 100 ms until
/// `target` adopts `term` or the budget runs out.
fn deliver(t: *raft.Transport, peer: raft.Peer, target: *ClusterCoordinator, term: u64) bool {
    var no_entries = [_]raft.LogEntry{};
    const msg: raft.Message = .{ .append_entries = .{
        .term = term,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = no_entries[0..],
        .leader_commit = 0,
    } };
    const deadline = nowMillis() + deliver_budget_ms;
    while (nowMillis() < deadline) {
        if (target.currentTerm() >= term) return true;
        t.send(peer, 2, term, msg) catch {};
        sleepMs(100);
    }
    return target.currentTerm() >= term;
}

test "SONNY-6459 item 6: the raft sender reconnects when a peer's endpoint changes" {
    if (comptime builtin.mode != .Debug) return error.SkipZigTest; // insecure peer TLS + self-signed listener
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var env = try TestEnv.init(a);
    defer env.deinit(a);

    raft.useRealQuicInTests(true);
    defer raft.useRealQuicInTests(false);

    const port = try test_ports.freeUdpPort();
    const first = try startReceiver(a, &env, first_ip, port);
    defer stopReceiver(a, first);
    const second = try startReceiver(a, &env, second_ip, port);
    defer stopReceiver(a, second);
    sleepMs(300);

    var t = raft.Transport.init(a);
    defer t.deinit();
    try t.startClientPoll();
    defer t.stopClientPoll();

    var peer: raft.Peer = .{ .id = 1, .endpoint = first_ip, .port = port, .alive = true, .last_contact = 0, .rpc_client = null };
    const to_first = deliver(&t, peer, first, 10);
    std.debug.print("peer 1 at {s}: delivered={} (terms: first={d} second={d})\n", .{ first_ip, to_first, first.currentTerm(), second.currentTerm() });
    try std.testing.expect(to_first);

    // Peer 1 moves: the next frames must go to its new endpoint.
    peer.endpoint = second_ip;
    const to_second = deliver(&t, peer, second, 20);
    std.debug.print("peer 1 moved to {s}: delivered={} (terms: first={d} second={d})\n", .{ second_ip, to_second, first.currentTerm(), second.currentTerm() });
    try std.testing.expect(to_second);
    // And not to the old one.
    try std.testing.expect(first.currentTerm() < 20);
}
