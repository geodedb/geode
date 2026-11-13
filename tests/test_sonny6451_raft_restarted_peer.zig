// SONNY-6451 item 1: the raft transport to a follower stalled for good after
// repeated peer restarts and IP moves (netns membership churn M6-M8: node3
// never received the leader's writes; the leader logged dozens of "peer
// stalled ... evicting stale connection").
//
// Root cause (receiver side, src/distributed/cluster.zig): since raft frames
// ride ONE long-lived stream per peer (2026-06-08), an inbound cluster
// connection's handler parks inside `dispatchRaftFrameFromAdaptedStream`,
// which looped `while (true)` on `WouldBlock`. A sender that goes away without
// CONNECTION_CLOSE (a restarted or rescheduled process, or an evicted
// `PeerConnection`, whose `deinit` never closes the QUIC connection) leaves
// that stream open-but-silent, and the vendor's `readStream` answers
// `WouldBlock` for it forever. The RC1 idle reap, the RC-A sweeper's
// `reap_requested` and the coordinator's `shutdown` flag were checked only
// between streams, never inside it, so each such peer pinned one of the
// receiver's 4 `connection_pool` workers for the life of the process. After
// four, the receiver serviced no inbound raft connection at all: every
// rebuilt connection from the leader queued behind the pinned workers, the
// leader saw no progress, evicted and rebuilt again (another queued
// connection), and the follower never received another append.
//
// The test drives the real receiver (a started ClusterCoordinator on
// 127.0.0.64) and real QUIC senders with the raft `PeerConnection` lifecycle:
// six incarnations of peer 2, each sending heartbeats at a higher term on one
// long-lived stream and then vanishing without FIN or CONNECTION_CLOSE, as a
// restarted or evicted peer does. Each
// incarnation's frame must reach the receiver (it adopts the term) within a
// bounded time, and once they are gone every inbound handler must have
// released its worker.
//
// CANARY: REQ=REQ-SONNY-6451-RAFT-RESTARTED-PEER; FEATURE="DistributedCluster"; ASPECT=InboundStreamReleasesWorker; STATUS=TESTED; TEST=tests/test_sonny6451_raft_restarted_peer.zig; OWNER=distributed; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const raft = geode.distributed.raft_consensus;
const quic = @import("transport/quic");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// A loopback address no other cluster test uses.
const receiver_ip = "127.0.0.64";
const token = "test-sonny6451-restarted-peer";
/// The receiver's inbound idle deadline for this test (default 30 s).
const idle_deadline_ms: i64 = 1000;
/// More sender incarnations than the receiver has connection workers (4).
const incarnations: u64 = 6;
/// Per-incarnation delivery budget: a released worker is available within
/// one idle deadline, plus handshake and scheduling headroom.
const delivery_budget_ms: i64 = idle_deadline_ms + 9000;

fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

/// Start the receiver: node 1 with two configured (absent) peers and a long
/// election timeout, so its own raft traffic stays out of the way.
fn startReceiver(a: std.mem.Allocator, port: u16, cert_path: []const u8, key_path: []const u8) !*ClusterCoordinator {
    const peers = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 2, .address = "127.0.0.65", .port = port + 1 },
        .{ .id = 3, .address = "127.0.0.66", .port = port + 2 },
    };
    const coord = try a.create(ClusterCoordinator);
    errdefer a.destroy(coord);
    coord.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers[0..],
        .listen_address = receiver_ip,
        .cluster_port = port,
        .cluster_token = token,
        .cluster_name = "test-sonny6451-restarted-peer",
        .election_timeout_ms = 60_000,
        .cert_path = cert_path,
        .key_path = key_path,
    });
    errdefer coord.deinit();
    try coord.start();
    return coord;
}

/// A sender incarnation's QUIC client and its one long-lived raft stream.
const Incarnation = struct {
    client: quic.QuicClient,
    stream: *quic.QuicClientStream,

    fn deinit(self: *Incarnation) void {
        self.stream.deinit();
        self.client.deinit();
    }
};

/// One incarnation of peer 2, sending the way a raft `PeerConnection` does
/// (src/distributed/raft_consensus.zig): connect, open ONE long-lived stream
/// and write a heartbeat at `term` on it, re-sent every 200 ms as the raft
/// tick does, until the receiver has adopted `term` or the budget runs out.
/// Then the incarnation stops existing on the network without a FIN or a
/// CONNECTION_CLOSE, like a killed or force-exited peer process (the churn
/// harness's restarts) or one whose old IP is blackholed (its reschedules):
/// its endpoint is never polled again. The caller deinits it only after the
/// assertions. (A real QUIC client: raft_consensus.zig swaps its `quic` for a
/// no-op stub in every test binary, so `raft.Transport.send` sends nothing
/// here.) Sets `delivered`.
fn incarnation(a: std.mem.Allocator, coord: *ClusterCoordinator, port: u16, term: u64, inc: *Incarnation, delivered: *bool) !void {
    inc.client = quic.QuicClient.init(a);
    errdefer inc.client.deinit();
    try inc.client.connectInsecure(receiver_ip, port, true);
    try inc.client.waitForHandshake(5);
    inc.stream = try inc.client.openStream(true);
    errdefer inc.stream.deinit();
    var no_entries = [_]raft.LogEntry{};
    const msg: raft.Message = .{ .append_entries = .{
        .term = term,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = no_entries[0..],
        .leader_commit = 0,
    } };
    const deadline = nowMillis() + delivery_budget_ms;
    var last_send: i64 = 0;
    while (nowMillis() < deadline) {
        if (coord.currentTerm() >= term) break;
        if (nowMillis() - last_send >= 200) {
            last_send = nowMillis();
            try raft.writeRaftFrame(a, inc.stream, 2, term, msg);
        }
        inc.client.poll(5) catch {};
        sleepMs(5);
    }
    delivered.* = coord.currentTerm() >= term;
}

test "SONNY-6451: a peer that restarts more times than the receiver has workers still reaches it" {
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

    const port: u16 = 23140;
    const coord = try startReceiver(a, port, cert_path, key_path);
    defer {
        coord.deinit();
        a.destroy(coord);
    }
    sleepMs(300);

    var incs: [incarnations]Incarnation = undefined;
    var started: usize = 0;
    defer for (incs[0..started]) |*inc| inc.deinit();

    var k: u64 = 1;
    while (k <= incarnations) : (k += 1) {
        const term = 10 * k;
        const t0 = nowMillis();
        var delivered = false;
        try incarnation(a, coord, port, term, &incs[started], &delivered);
        started += 1;
        if (!delivered) {
            std.debug.print(
                "incarnation {d} of peer 2 (term {d}) never reached the receiver in {d} ms: receiver term {d}, {d} inbound handlers still running\n",
                .{ k, term, nowMillis() - t0, coord.currentTerm(), coord.active_connections.load(.acquire) },
            );
            return error.RestartedPeerNeverReachedReceiver;
        }
    }

    // Every sender is gone: no inbound handler may keep a worker.
    const deadline = nowMillis() + 2 * idle_deadline_ms + 5000;
    while (coord.active_connections.load(.acquire) != 0 and nowMillis() < deadline) sleepMs(50);
    try std.testing.expectEqual(@as(u32, 0), coord.active_connections.load(.acquire));
}
