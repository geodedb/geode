// SONNY-6456 item 3: no in-process test could run the real raft sender.
//
// `src/distributed/raft_consensus.zig` swapped its `quic` for a do-nothing
// stub in every test binary (`builtin.is_test`), so `raft.Transport.send`
// sent nothing in any test, and the SONNY-6451 sender-side reconnect (a
// connection the peer closed is evicted and rebuilt on the next send) had only
// churn-log evidence. The stub is now the default and a test opts into the
// real QUIC client with `raft.useRealQuicInTests(true)`.
//
// The test drives the REAL sender (`raft.Transport` with its client poll
// thread, real QUIC, TLS and frame encoding) against a real receiver (a
// started ClusterCoordinator on 127.0.0.77, inbound idle deadline 1 s):
//   1. a heartbeat reaches the receiver;
//   2. the sender goes quiet past the receiver's idle deadline, the receiver
//      gives up the stream and closes the connection, and the next sends
//      must observe the close (error.ConnectionClosed), rebuild the
//      connection, and deliver;
//   3. the receiver restarts (a new process incarnation on the same
//      address), and the sender must reach the new incarnation.
//
// CANARY: REQ=REQ-SONNY-6456-RAFT-REAL-SENDER; FEATURE="DistributedCluster"; ASPECT=RaftSenderReconnectsInProcess; STATUS=TESTED; TEST=tests/test_sonny6456_raft_real_sender.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const test_ports = @import("test_ports.zig");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const raft = geode.distributed.raft_consensus;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// A loopback address no other cluster test uses.
const receiver_ip = "127.0.0.77";
const token = "test-sonny6456-real-sender";
const deliver_budget_ms: i64 = 15_000;

fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn startReceiver(a: std.mem.Allocator, port: u16, cert_path: []const u8, key_path: []const u8) !*ClusterCoordinator {
    const peers = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 2, .address = "127.0.0.78", .port = port },
        .{ .id = 3, .address = "127.0.0.79", .port = port },
    };
    const coord = try a.create(ClusterCoordinator);
    errdefer a.destroy(coord);
    coord.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers[0..],
        .listen_address = receiver_ip,
        .cluster_port = port,
        .cluster_token = token,
        .cluster_name = "test-sonny6456-real-sender",
        .election_timeout_ms = 60_000,
        .cert_path = cert_path,
        .key_path = key_path,
    });
    errdefer coord.deinit();
    try coord.start();
    return coord;
}

const SendResult = struct { delivered: bool, closed_seen: usize, sends: usize };

/// Send heartbeats at `term` from peer 2 through the real sender every
/// 100 ms until the receiver adopts `term` or the budget runs out.
fn deliver(a: std.mem.Allocator, t: *raft.Transport, coord: *ClusterCoordinator, port: u16, term: u64) SendResult {
    _ = a;
    const peer: raft.Peer = .{ .id = 1, .endpoint = receiver_ip, .port = port, .last_contact = 0 };
    var no_entries = [_]raft.LogEntry{};
    const msg: raft.Message = .{ .append_entries = .{
        .term = term,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = no_entries[0..],
        .leader_commit = 0,
    } };
    var res: SendResult = .{ .delivered = false, .closed_seen = 0, .sends = 0 };
    const deadline = nowMillis() + deliver_budget_ms;
    while (nowMillis() < deadline) {
        if (coord.currentTerm() >= term) {
            res.delivered = true;
            return res;
        }
        res.sends += 1;
        t.send(peer, 2, term, msg) catch |err| {
            if (err == error.ConnectionClosed) res.closed_seen += 1;
        };
        sleepMs(100);
    }
    res.delivered = coord.currentTerm() >= term;
    return res;
}

test "SONNY-6456: the real raft sender reconnects after the peer closes its connection and after the peer restarts" {
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
    if (setenv("GEODE_CLUSTER_INBOUND_IDLE_MS", "1000", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_INBOUND_IDLE_MS");

    raft.useRealQuicInTests(true);
    defer raft.useRealQuicInTests(false);

    const port = try test_ports.freeUdpPort();
    var receiver: ?*ClusterCoordinator = try startReceiver(a, port, cert_path, key_path);
    defer if (receiver) |c| {
        c.deinit();
        a.destroy(c);
    };
    var coord = receiver.?;
    sleepMs(300);

    var t = raft.Transport.init(a);
    defer t.deinit();
    try t.startClientPoll();
    defer t.stopClientPoll();

    // 1. First delivery through the real sender.
    const first = deliver(a, &t, coord, port, 10);
    std.debug.print("delivery 1: delivered={} sends={d}\n", .{ first.delivered, first.sends });
    try std.testing.expect(first.delivered);

    // 2. Quiet past the receiver's 1 s idle deadline: the receiver closes the
    // connection. The sender must notice and reconnect.
    sleepMs(3_000);
    const second = deliver(a, &t, coord, port, 20);
    std.debug.print("delivery 2 (after the peer closed the connection): delivered={} sends={d} ConnectionClosed seen={d}\n", .{ second.delivered, second.sends, second.closed_seen });
    try std.testing.expect(second.closed_seen >= 1);
    try std.testing.expect(second.delivered);

    // 3. The receiver restarts on the same address.
    receiver = null;
    coord.deinit();
    a.destroy(coord);
    receiver = try startReceiver(a, port, cert_path, key_path);
    coord = receiver.?;
    sleepMs(300);
    const third = deliver(a, &t, coord, port, 30);
    std.debug.print("delivery 3 (after the peer restarted): delivered={} sends={d} ConnectionClosed seen={d}\n", .{ third.delivered, third.sends, third.closed_seen });
    try std.testing.expect(third.delivered);
}
