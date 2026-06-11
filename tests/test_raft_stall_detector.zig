// CANARY: REQ=REQ-DIST-RAFT-STALL-LIVENESS; FEATURE="Raft transport stalled-stream liveness"; ASPECT=StallEvictDecision; STATUS=TESTED; TEST=tests/test_raft_stall_detector.zig; OWNER=distributed; UPDATED=2026-06-11
//
// k8s root cause #5 (transport wedge), 2026-06-11:
//
// A 3-node k8s Raft cluster: the leader pod restarts with a NEW IP and re-wins
// leadership; a third node (geode-2) that did NOT restart is stranded as a
// silent stuck-candidate forever. Neither side logs a transport error.
//
// Root cause: the raft transport (`raft_consensus.zig`) is fire-and-forget.
// `Transport.send` writes a frame onto a long-lived per-peer `send_stream` and
// never reads an ack. A write into a stale/half-open QUIC connection (the
// peer's OLD endpoint after a pod reschedule) buffers locally and returns
// success, so the hard-send-error eviction path never fires. The only other
// recovery trigger — the IP-change reaper `maybeReconnectOnIpChange` — evicts
// ONLY when the peer's freshly-resolved FQDN differs from the cached IP; the
// strand victim's OWN IP never changed, so it declines to act. The connection
// silently blackholes forever.
//
// Desired fix: a stalled-stream liveness detector, sibling to
// `maybeReconnectOnIpChange`, invoked from the same ~3s `clientPollLoop` pass.
// `PeerConnection` gains a forward-progress timestamp (`last_progress_ms`),
// refreshed by `Transport.notePeerProgress(peer_id, now_ms)` from the inbound
// path (keyed by peer id, because the inbound connection is a different object
// than the outbound PeerConnection). A pure, clock-injectable decision
// `Transport.shouldEvictOnStall(pc, now_ms)` returns true iff frames have been
// sent to the peer but no progress has been observed for longer than
// `peer_stall_budget_ms`; `maybeReconnectOnStall` then calls
// `evictPeerConnection` so the next send re-resolves the FQDN and rebuilds.
//
// These tests encode the DESIRED post-fix behavior and FAIL against the
// skeleton (shouldEvictOnStall always false; notePeerProgress a no-op) — which
// is the proof they catch the wedge. They use NO real QUIC/TLS (the in-test
// QUIC stubs make `QuicClient.init` a no-op), so they are deterministic and
// fast and inject the clock directly.

const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;

/// Build a heap-allocated PeerConnection for the pure stall-decision tests.
/// We construct it through `getOrCreatePeerConnection` indirectly is overkill;
/// instead we publish it into the Transport's peers map via the public surface
/// the production code uses. Because `PeerConnection` is `pub` and its fields
/// are default-initialized, we can create one directly with the test-mode QUIC
/// stub client (a no-op) and set the two liveness fields under test.
fn makePeerConn(
    allocator: std.mem.Allocator,
    peer_id: u64,
    frames_sent: u64,
    last_progress_ms: i64,
) !*Transport.PeerConnection {
    const pc = try allocator.create(Transport.PeerConnection);
    pc.* = .{
        .allocator = allocator,
        .client = QuicClientInit(allocator),
        .established = true,
        .endpoint = try allocator.dupe(u8, "raft-peer.cluster.svc"),
        .port = 7890,
        .peer_id = peer_id,
        .resolved_ip = &.{},
        .frames_sent = std.atomic.Value(u64).init(frames_sent),
        .last_progress_ms = std.atomic.Value(i64).init(last_progress_ms),
    };
    return pc;
}

/// The QUIC client field is the in-test stub; constructing it is a no-op. Name
/// its type via the `@FieldType` builtin so we never have to import the
/// (test-mode) quic namespace directly and the shim survives a stub-signature
/// drift.
const QuicClientType = @FieldType(Transport.PeerConnection, "client");
fn QuicClientInit(allocator: std.mem.Allocator) QuicClientType {
    return QuicClientType.init(allocator);
}

fn freePeerConn(allocator: std.mem.Allocator, pc: *Transport.PeerConnection) void {
    pc.client.deinit();
    allocator.free(pc.endpoint);
    allocator.destroy(pc);
}

test "stalled peer (sends happened, no progress past budget) -> eviction decision fires" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    // DESIRED: a peer we are sending to with no progress past the budget is
    // judged stalled (next send rebuilds the connection to the new IP).
    // SKELETON returns false -> FAILS here, catching the wedge.
    try std.testing.expect(Transport.shouldEvictOnStall(pc, now_ms));
}

test "healthy peer (recent progress) -> no eviction" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const recent = now_ms - (Transport.peer_stall_budget_ms - 500);
    const pc = try makePeerConn(allocator, 7, 12, recent);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms));
}

test "idle peer (no frames sent) -> no eviction even with an ancient timestamp" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // frames_sent == 0: no traffic expected, so no progress to expect.
    const pc = try makePeerConn(allocator, 9, 0, 0);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms));
}

test "notePeerProgress refreshes the right PeerConnection via the peer-id keyed path" {
    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    const now_ms: i64 = 5_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 1000);
    const pc1 = try makePeerConn(allocator, 1, 4, stale);
    const pc2 = try makePeerConn(allocator, 2, 4, stale);

    const io = std.Io.Threaded.global_single_threaded.io();
    transport.peers_mutex.lockUncancelable(io);
    try transport.peers.put(1, pc1);
    try transport.peers.put(2, pc2);
    transport.peers_mutex.unlock(io);
    // transport.deinit frees both peer entries.

    // Inbound progress arrives for peer 1 only, keyed by peer id.
    transport.notePeerProgress(1, now_ms);

    // DESIRED: peer 1's stamp is refreshed; peer 2's is untouched.
    // SKELETON notePeerProgress is a no-op -> peer 1 stays stale -> FAILS here.
    try std.testing.expectEqual(now_ms, pc1.last_progress_ms.load(.acquire));
    try std.testing.expect(!Transport.shouldEvictOnStall(pc1, now_ms));
    try std.testing.expect(Transport.shouldEvictOnStall(pc2, now_ms));
}

test "progress refresh clears the stall (reconnected peer is not immediately re-evicted)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 2_000_000;
    // Just reconnected: progress stamped == now. The next reaper pass must NOT
    // re-evict (which would spin a reconnect loop).
    const pc = try makePeerConn(allocator, 3, 1, now_ms);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms));
    // And a later observation keeps it healthy across the full budget window.
    pc.last_progress_ms.store(now_ms + Transport.peer_stall_budget_ms, .release);
    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms + Transport.peer_stall_budget_ms));
}
