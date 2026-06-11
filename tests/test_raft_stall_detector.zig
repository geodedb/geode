// CANARY: REQ=REQ-DIST-RAFT-STALL-LIVENESS; FEATURE="Raft transport stalled-stream liveness"; ASPECT=StallEvictDecision; STATUS=TESTED; TEST=tests/test_raft_stall_detector.zig; OWNER=distributed; UPDATED=2026-06-11
//
// k8s root cause #5 (transport wedge) + its election-livelock REGRESSION, 2026-06-11:
//
// ORIGINAL wedge: a 3-node k8s Raft cluster — the leader pod restarts with a NEW
// IP and re-wins leadership; a third node (geode-2) that did NOT restart is
// stranded as a silent stuck-candidate forever. Neither side logs a transport
// error. The transport is fire-and-forget: `Transport.send` writes a frame onto
// a long-lived per-peer `send_stream` and never reads an ack. A write into a
// stale/half-open QUIC connection (the peer's OLD endpoint) buffers locally and
// returns success, so the hard-send-error eviction path never fires; and the
// IP-change reaper `maybeReconnectOnIpChange` declines (the strand victim's OWN
// IP never changed). The first fix added a stalled-stream liveness detector.
//
// REGRESSION (this revision): that detector caused a TOTAL-CLUSTER ELECTION
// LIVELOCK on real k8s. When the leader pod is deleted, all 3 nodes evict both
// peers every ~3s forever and no leader is ever elected, because:
//
//   1. `peer_stall_budget_ms = 3000` is BELOW real election convergence. The
//      derived election round is `2 * election_tick * tick_ms`: election_tick =
//      max(2, election_timeout_ms/50) = 100 ticks for the default 5000 ms
//      timeout, the raft loop ticks every 10 ms, and the timeout is randomized
//      up to 2x → ~2000 ms per round, multi-round under churn. Worse, the reaper
//      interval (`peer_reresolve_ms = 3000`) EQUALS the budget, so the check
//      window equals what it measures.
//
//   2. The stall check is armed regardless of raft role. During a leaderless
//      election there is legitimately NO AppendEntries flow, yet `frames_sent>0`
//      from RequestVote, so every peer trips and gets evicted; eviction tears
//      down the connection that votes/responses ride; the rebuild handshake
//      costs ~1s; the election never completes.
//
//   3. A SINGLE missed refresh evicts — `notePeerProgress` no-ops for an evicted
//      peer (no map entry), destroying the progress evidence that would clear
//      the stall, so a lone quiet pass re-evicts even with a healthy leader.
//
// CORRECTED behavior these tests encode (and that FAILS against the skeleton):
//
//   A. Leader-only arming: `shouldEvictOnStall(pc, now_ms, is_leader)` must
//      return false whenever this node is NOT the leader (the IP-change reaper
//      covers moved peers regardless of role; the detector's target is the
//      LEADER's silent outbound stream). SKELETON ignores `is_leader`.
//
//   B. Budget ≫ election convergence and decoupled from the reaper interval:
//      `peer_stall_budget_ms` ≥ 3 × the worst-case election round (so ≥ 6000;
//      the real fix raises it to 15000) AND strictly greater than
//      `peer_reresolve_ms`. SKELETON budget is 3000.
//
//   C. M consecutive stalled passes required (`peer_stall_strikes_required` ≥ 2):
//      one stalled observation does NOT evict; `recordStallPass` evicts only on
//      the Mth consecutive stalled pass. SKELETON evicts on the first pass.
//
//   D. A progress stamp resets the strike counter. SKELETON `notePeerProgress`
//      leaves `stall_strikes` untouched.
//
// These tests use NO real QUIC/TLS (the in-test QUIC stubs make
// `QuicClient.init` a no-op), so they are deterministic and fast and inject the
// clock + leader flag directly.

const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;

/// Build a heap-allocated PeerConnection for the pure stall-decision tests.
/// `PeerConnection` is `pub` and its fields are default-initialized
/// (`stall_strikes` defaults to 0), so we create one directly with the test-mode
/// QUIC stub client (a no-op) and set the liveness fields under test.
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

// ---------------------------------------------------------------------------
// (B) Budget vs. election convergence and reaper interval
// ---------------------------------------------------------------------------
// Worst-case election round = 2 * election_tick * tick_ms. With the default
// 5000 ms election timeout: election_tick = max(2, 5000/50) = 100 ticks, the
// raft loop ticks every 10 ms, and the timeout randomizes up to 2x → up to
// 2 * 100 * 10 = 2000 ms per round (multi-round under churn). The detector must
// give >= 3x headroom so a leaderless election never trips, and must NOT equal
// the reaper interval (the original bug: budget == interval == 3000).
// SKELETON: peer_stall_budget_ms = 3000 < 6000 -> FAILS.
test "stall: budget exceeds worst-case election convergence and reaper interval" {
    const worst_case_election_round_ms: i64 = 2000; // 2 * election_tick(100) * tick_ms(10)
    try std.testing.expect(Transport.peer_stall_budget_ms >= 3 * worst_case_election_round_ms);
    try std.testing.expect(Transport.peer_stall_budget_ms > Transport.peer_reresolve_ms);
}

// ---------------------------------------------------------------------------
// (A) Leader-only arming
// ---------------------------------------------------------------------------
// During a leaderless election this exact shape (ancient progress, frames sent)
// is present on every peer; if the detector is armed it evicts them all and
// livelocks the cluster. A non-leader MUST stand down. SKELETON ignores the flag
// and returns true -> FAILS.
test "stall: eviction is suppressed when not leader" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms, false));
}

// (A, positive) As the leader, a stalled outbound stream IS the wedge and reads
// as stalled on a single pass. (Eviction additionally requires M consecutive
// passes — see the strike test.) Passes once is_leader is wired; the skeleton
// already returns true here.
test "stall: leader sees a stalled outbound peer as stalled (single pass)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(Transport.shouldEvictOnStall(pc, now_ms, true));
}

test "stall: healthy peer (recent progress) -> no eviction" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const recent = now_ms - (Transport.peer_stall_budget_ms - 500);
    const pc = try makePeerConn(allocator, 7, 12, recent);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms, true));
}

test "stall: idle peer (no frames sent) -> no eviction even with an ancient timestamp" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // frames_sent == 0: no traffic expected, so no progress to expect.
    const pc = try makePeerConn(allocator, 9, 0, 0);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms, true));
}

// ---------------------------------------------------------------------------
// (C) M consecutive stalled passes required
// ---------------------------------------------------------------------------
// The first stalled observation must NOT evict (it would evict every peer during
// a leaderless election / a single transient quiet pass). Only the Mth
// consecutive pass evicts. SKELETON recordStallPass evicts on the FIRST pass ->
// the "first pass must NOT evict" assertion FAILS.
test "stall: one stalled pass does not evict; M consecutive passes do" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(Transport.peer_stall_strikes_required >= 2);

    // First stalled pass: record a strike, do NOT evict.
    try std.testing.expect(!Transport.recordStallPass(pc, now_ms, true));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));

    // Drive to the required number of consecutive stalled passes; only the last
    // pass evicts.
    var pass: u32 = 1;
    while (pass < Transport.peer_stall_strikes_required) : (pass += 1) {
        const is_last = (pass + 1) == Transport.peer_stall_strikes_required;
        const evict = Transport.recordStallPass(pc, now_ms, true);
        try std.testing.expectEqual(is_last, evict);
    }
}

// ---------------------------------------------------------------------------
// (D) A progress stamp resets the strike counter
// ---------------------------------------------------------------------------
// A peer that resumes responding (progress stamped) must not be evicted on a
// later isolated stalled-looking pass. SKELETON notePeerProgress leaves
// stall_strikes untouched -> the post-progress strike-count assertion FAILS.
test "stall: progress stamp resets strikes" {
    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    const now_ms: i64 = 7_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 1000);
    const pc = try makePeerConn(allocator, 1, 4, stale);

    const io = std.Io.Threaded.global_single_threaded.io();
    transport.peers_mutex.lockUncancelable(io);
    try transport.peers.put(1, pc);
    transport.peers_mutex.unlock(io);
    // transport.deinit frees the entry.

    // First stalled pass accrues strike 1 (no evict).
    try std.testing.expect(!Transport.recordStallPass(pc, now_ms, true));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));

    // Inbound progress arrives -> strikes reset to 0 (and clock refreshed).
    transport.notePeerProgress(1, now_ms);
    try std.testing.expectEqual(@as(u32, 0), pc.stall_strikes.load(.acquire));

    // A later stalled-looking pass is therefore strike 1 again, NOT an eviction.
    const later = now_ms + Transport.peer_stall_budget_ms + 1;
    try std.testing.expect(!Transport.recordStallPass(pc, later, true));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));
}

test "stall: notePeerProgress refreshes the right PeerConnection via the peer-id keyed path" {
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

    // DESIRED: peer 1's stamp is refreshed; peer 2's is untouched. Evaluated as
    // the leader (is_leader=true) so the single-pass look is meaningful.
    try std.testing.expectEqual(now_ms, pc1.last_progress_ms.load(.acquire));
    try std.testing.expect(!Transport.shouldEvictOnStall(pc1, now_ms, true));
    try std.testing.expect(Transport.shouldEvictOnStall(pc2, now_ms, true));
}

test "stall: progress refresh clears the stall (reconnected peer is not immediately re-evicted)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 2_000_000;
    // Just reconnected: progress stamped == now. The next reaper pass must NOT
    // re-evict (which would spin a reconnect loop).
    const pc = try makePeerConn(allocator, 3, 1, now_ms);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms, true));
    // And a later observation keeps it healthy across the full budget window.
    pc.last_progress_ms.store(now_ms + Transport.peer_stall_budget_ms, .release);
    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms + Transport.peer_stall_budget_ms, true));
}
