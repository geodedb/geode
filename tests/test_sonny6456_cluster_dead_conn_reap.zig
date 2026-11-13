// SONNY-6456 item 2: the QUIC dead-connection reaper was off on the cluster
// listener in production.
//
// `ClusterCoordinator.start` (src/distributed/cluster.zig) creates the
// intra-cluster QUIC server itself and never set `dead_conn_reap_ms`;
// `raft_consensus.Transport.listen`, the only code that sets it (30 s,
// `GEODE_RAFT_DEAD_CONN_REAP_MS`), is never called on that path. An inbound
// connection whose peer vanished without CONNECTION_CLOSE (a killed process,
// a rescheduled pod whose old IP went dark) was therefore closed only by the
// coordinator's own inbound idle deadline or the 300 s QUIC idle timeout.
//
// The test starts a real coordinator (127.0.0.74) with
// GEODE_RAFT_DEAD_CONN_REAP_MS=1000 and the inbound idle deadline left far
// out of the way (60 s), connects a real QUIC client, delivers one
// authenticated raft heartbeat on a long-lived stream (so the connection is
// accepted and its handler parks on the stream), then lets the client go
// silent without FIN or CONNECTION_CLOSE. The listener must drop the
// connection, and the inbound handler must release its worker, within a few
// reap budgets — long before the 60 s idle deadline.
//
// CANARY: REQ=REQ-SONNY-6456-CLUSTER-DEAD-CONN-REAP; FEATURE="DistributedCluster"; ASPECT=ClusterListenerReapsDeadConnections; STATUS=TESTED; TEST=tests/test_sonny6456_cluster_dead_conn_reap.zig; OWNER=distributed; UPDATED=2026-11-13

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
const receiver_ip = "127.0.0.74";
const token = "test-sonny6456-dead-conn-reap";
const reap_ms: i64 = 1000;
/// Reap budget plus the vendor's reaper cadence and handler unwind headroom;
/// far below the 60 s inbound idle deadline this test configures.
const reaped_within_ms: i64 = 10 * reap_ms;

fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

test "SONNY-6456: the cluster listener reaps an inbound connection whose peer went silent" {
    if (comptime builtin.mode != .Debug) return error.SkipZigTest; // insecure peer TLS + self-signed listener
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const cert_path = try std.fmt.allocPrint(a, "{s}/cluster.crt", .{dir});
    defer a.free(cert_path);
    const key_path = try std.fmt.allocPrint(a, "{s}/cluster.key", .{dir});
    defer a.free(key_path);

    if (setenv("GEODE_CLUSTER_INSECURE", "1", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_INSECURE");
    if (setenv("GEODE_CLUSTER_TOKEN", token, 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_TOKEN");
    if (setenv("GEODE_RAFT_DEAD_CONN_REAP_MS", "1000", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_RAFT_DEAD_CONN_REAP_MS");
    if (setenv("GEODE_CLUSTER_INBOUND_IDLE_MS", "60000", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_INBOUND_IDLE_MS");

    const port = try test_ports.freeUdpPort();
    const peers = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 2, .address = "127.0.0.75", .port = port },
        .{ .id = 3, .address = "127.0.0.76", .port = port },
    };
    const coord = try a.create(ClusterCoordinator);
    defer a.destroy(coord);
    coord.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers[0..],
        .listen_address = receiver_ip,
        .cluster_port = port,
        .cluster_token = token,
        .cluster_name = "test-sonny6456-dead-conn-reap",
        .election_timeout_ms = 60_000,
        .cert_path = cert_path,
        .key_path = key_path,
    });
    defer coord.deinit();
    try coord.start();
    sleepMs(300);

    // Peer 2: connect, deliver one heartbeat on a long-lived stream.
    var client = quic.QuicClient.init(a);
    defer client.deinit();
    try client.connectInsecure(receiver_ip, port, true);
    try client.waitForHandshake(5);
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
    const deliver_deadline = nowMillis() + 10_000;
    var last_send: i64 = 0;
    while (coord.currentTerm() < 7 and nowMillis() < deliver_deadline) {
        if (nowMillis() - last_send >= 200) {
            last_send = nowMillis();
            try raft.writeRaftFrame(a, stream, 2, 7, msg);
        }
        client.poll(5) catch {};
        sleepMs(5);
    }
    try std.testing.expect(coord.currentTerm() >= 7);
    const server = &coord.network_transport.quic_server.?;
    try std.testing.expect(server.getConnectionCount() >= 1);
    try std.testing.expect(coord.active_connections.load(.acquire) >= 1);

    // Peer 2 vanishes: its endpoint is never polled again (no FIN, no
    // CONNECTION_CLOSE). The listener must reap the connection.
    const t0 = nowMillis();
    while (nowMillis() - t0 < reaped_within_ms) {
        if (server.getConnectionCount() == 0 and coord.active_connections.load(.acquire) == 0) break;
        sleepMs(50);
    }
    const conns = server.getConnectionCount();
    const handlers = coord.active_connections.load(.acquire);
    std.debug.print("after {d} ms of peer silence: {d} listener connection(s), {d} inbound handler(s)\n", .{ nowMillis() - t0, conns, handlers });
    try std.testing.expectEqual(@as(usize, 0), conns);
    try std.testing.expectEqual(@as(u32, 0), handlers);
}
