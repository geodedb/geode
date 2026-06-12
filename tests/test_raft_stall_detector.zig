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
// CORRECTED behavior these tests encode (all now on the role-armed API; the
// legacy `is_leader: bool` form `shouldEvictOnStall`/`recordStallPass` was
// removed in the owed-item-(4) fix):
//
//   A. Role arming (`StallArm`): suppress ONLY a FOLLOWER; arm the LEADER AND
//      the CANDIDATE. A follower's outbound health is the leader's detector's
//      job (and the IP-change reaper covers moved peers regardless of role); a
//      candidate must get its RequestVote frames through a possibly-wedged
//      stream at restart, so it is armed.
//
//   B. Budget ≫ election convergence and decoupled from the reaper interval:
//      `peer_stall_budget_ms` ≥ 3 × the worst-case election round (so ≥ 6000;
//      the real fix raises it to 15000) AND strictly greater than
//      `peer_reresolve_ms`.
//
//   C. M consecutive stalled passes required (`peer_stall_strikes_required` ≥ 2):
//      one stalled observation does NOT evict; `recordStallPassArmed` evicts only
//      on the Mth consecutive stalled pass.
//
//   D. A progress stamp resets the strike counter (`notePeerProgress`).
//
// These tests use NO real QUIC/TLS (the in-test QUIC stubs make
// `QuicClient.init` a no-op), so they are deterministic and fast and inject the
// clock + arm directly.
//
// OWED ITEM (4) (2026-06-11): the original leader-only arming fixed the livelock
// but over-corrected for the divergent-durable-state RESTART wedge — at restart,
// vote frames are silently undelivered over a stale/half-open QUIC stream while a
// leader-only-gated stall detector means that during the leaderless window
// NOTHING detects/recovers the stall and the node sits as a silent candidate
// forever; and `pre_vote=true` freezes the term (term only increments after a WON
// pre-vote), making the wedge silent. The two sections at the bottom of this file
// encode the corrected behavior:
//   (A) role-arming widens to leader-OR-candidate; only FOLLOWERS suppressed
//       (`shouldEvictOnStallArmed` / `recordStallPassArmed` / `StallArm` /
//       `setRoleSource`).
//   (B) frozen-term pre-vote VISIBILITY: `FrozenCandidateTracker.update` fires a
//       rate-limited warn when a node is a candidate at an unchanging term past
//       ~3x the election timeout.

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
// (A) Role arming (migrated to the armed API)
// ---------------------------------------------------------------------------
// During a leaderless election this exact shape (ancient progress, frames sent)
// is present on every peer; if a FOLLOWER were armed it would evict them all and
// livelock the cluster. A follower MUST stand down (its outbound health is the
// leader's detector's job). This is the migrated form of the old "not leader"
// suppression test.
test "stall: eviction is suppressed for a follower" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .follower));
}

// (A, positive) As the leader, a stalled outbound stream IS the wedge and reads
// as stalled on a single pass. (Eviction additionally requires M consecutive
// passes — see the strike test.)
test "stall: leader sees a stalled outbound peer as stalled (single pass)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
}

test "stall: healthy peer (recent progress) -> no eviction" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const recent = now_ms - (Transport.peer_stall_budget_ms - 500);
    const pc = try makePeerConn(allocator, 7, 12, recent);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
}

test "stall: idle peer (no frames sent) -> no eviction even with an ancient timestamp" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // frames_sent == 0: no traffic expected, so no progress to expect.
    const pc = try makePeerConn(allocator, 9, 0, 0);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
}

// ---------------------------------------------------------------------------
// (C) M consecutive stalled passes required
// ---------------------------------------------------------------------------
// The first stalled observation must NOT evict (it would evict every peer during
// a leaderless election / a single transient quiet pass). Only the Mth
// consecutive pass evicts (`recordStallPassArmed`).
test "stall: one stalled pass does not evict; M consecutive passes do" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(Transport.peer_stall_strikes_required >= 2);

    // First stalled pass: record a strike, do NOT evict.
    try std.testing.expect(!Transport.recordStallPassArmed(pc, now_ms, .leader));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));

    // Drive to the required number of consecutive stalled passes; only the last
    // pass evicts.
    var pass: u32 = 1;
    while (pass < Transport.peer_stall_strikes_required) : (pass += 1) {
        const is_last = (pass + 1) == Transport.peer_stall_strikes_required;
        const evict = Transport.recordStallPassArmed(pc, now_ms, .leader);
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
    try std.testing.expect(!Transport.recordStallPassArmed(pc, now_ms, .leader));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));

    // Inbound progress arrives -> strikes reset to 0 (and clock refreshed).
    transport.notePeerProgress(1, now_ms);
    try std.testing.expectEqual(@as(u32, 0), pc.stall_strikes.load(.acquire));

    // A later stalled-looking pass is therefore strike 1 again, NOT an eviction.
    const later = now_ms + Transport.peer_stall_budget_ms + 1;
    try std.testing.expect(!Transport.recordStallPassArmed(pc, later, .leader));
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
    // the leader (arm = .leader) so the single-pass look is meaningful.
    try std.testing.expectEqual(now_ms, pc1.last_progress_ms.load(.acquire));
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc1, now_ms, .leader));
    try std.testing.expect(Transport.shouldEvictOnStallArmed(pc2, now_ms, .leader));
}

test "stall: progress refresh clears the stall (reconnected peer is not immediately re-evicted)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 2_000_000;
    // Just reconnected: progress stamped == now. The next reaper pass must NOT
    // re-evict (which would spin a reconnect loop).
    const pc = try makePeerConn(allocator, 3, 1, now_ms);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
    // And a later observation keeps it healthy across the full budget window.
    pc.last_progress_ms.store(now_ms + Transport.peer_stall_budget_ms, .release);
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms + Transport.peer_stall_budget_ms, .leader));
}

// ===========================================================================
// owed item (4): all-candidate frozen-term wedge
// ===========================================================================
// The leader-only arming above (3aeb0fcc) fixed the election livelock but
// over-corrected for the divergent-durable-state RESTART wedge: at restart, vote
// frames are silently undelivered over a stale/half-open QUIC stream, and the
// stall detector is LEADER-ONLY gated — so during the leaderless window NOTHING
// detects or recovers the stalled outbound vote stream and the node sits as a
// silent candidate forever. (`pre_vote=true` also freezes the term — the term
// only increments after a WON pre-vote — so the wedge is SILENT. That visibility
// half is section (B) below.)
//
// CORRECTED arming (section A): the detector must arm for a node that is the
// LEADER **or a CANDIDATE**, and suppress ONLY a FOLLOWER:
//   * a FOLLOWER expects inbound heartbeats; its outbound health is the leader's
//     detector's job, so it stands down. This is the SAFE REFINEMENT of the old
//     "suppress when not leader" rule — it now suppresses ONLY the follower.
//   * a CANDIDATE is exactly the role that must get its RequestVote frames
//     through a possibly-wedged stream, so it MUST be armed. The 15 s budget +
//     2 consecutive strikes (≥ ~18-30 s to evict, vs 1-2 s healthy election
//     rounds) cannot recreate the old 3 s-budget livelock.
//
// API (see raft_consensus.zig):
//   * `StallArm = enum { leader, candidate, follower }`
//   * `shouldEvictOnStallArmed(pc, now_ms, arm)` — suppress ONLY `.follower`
//   * `recordStallPassArmed(pc, now_ms, arm)` — strike machine over the above
//   * `setRoleSource(ctx, fn(ctx) StallArm)` — role injection;
//     `maybeReconnectOnStall` reads it (null source -> `.follower`, never armed).
// The fix arms `.candidate` (suppress ONLY `.follower`); the candidate-arming
// assertions below pin that, the follower assertions pin the suppression, and
// the leader assertions pin no leader-path regression.

const StallArm = Transport.StallArm;

// ---------------------------------------------------------------------------
// (A.1) Candidate + stalled outbound stream -> ARMED (single pass reads stalled)
// ---------------------------------------------------------------------------
// This is the restart wedge: the strand victim is a CANDIDATE whose RequestVote
// frames buffer into a dead stream (frames_sent>0, no progress past budget).
// A candidate MUST be armed so the reaper can rebuild the stream and let votes
// flow. SKELETON returns false for a non-leader arm -> FAILS.
test "stall(armed): candidate with a stalled outbound stream is armed (single pass)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    // DESIRED: a stalled candidate reads as stalled (armed). RED: skeleton is
    // leader-only and returns false.
    try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .candidate));
}

// ---------------------------------------------------------------------------
// (A.2) Candidate + stalled -> EVICTS after M consecutive passes
// ---------------------------------------------------------------------------
// The full eviction path for the wedge victim: a candidate accrues strikes and
// evicts on the Mth consecutive armed-stalled pass (so a single quiet leaderless
// pass never evicts, but a genuinely wedged candidate recovers). SKELETON never
// arms a candidate, so the first-pass strike never accrues and `recordStallPassArmed`
// returns false forever -> the "evicts on the Mth pass" assertion FAILS.
test "stall(armed): candidate evicts only after M consecutive stalled passes" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(Transport.peer_stall_strikes_required >= 2);

    // First armed-stalled pass: strike 1, no evict.
    try std.testing.expect(!Transport.recordStallPassArmed(pc, now_ms, .candidate));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));

    // Drive to the required number of consecutive stalled passes; only the last
    // pass evicts.
    var pass: u32 = 1;
    while (pass < Transport.peer_stall_strikes_required) : (pass += 1) {
        const is_last = (pass + 1) == Transport.peer_stall_strikes_required;
        const evict = Transport.recordStallPassArmed(pc, now_ms, .candidate);
        try std.testing.expectEqual(is_last, evict);
    }
}

// ---------------------------------------------------------------------------
// (A.3) Follower + same conditions -> SUPPRESSED (refines the old not-leader test)
// ---------------------------------------------------------------------------
// A follower's outbound health is the leader's detector's job; arming it would
// re-introduce the leaderless-window eviction storm. Same shape as the candidate
// wedge (frames sent, ancient progress) but MUST NOT evict. SKELETON returns
// false for `.follower` already, so this PASSES now and pins the post-fix
// suppression (it is the reworked "not leader" -> "follower" test).
test "stall(armed): follower with a stalled outbound stream is suppressed" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .follower));
    // And no strike accrues / no eviction across repeated passes.
    try std.testing.expect(!Transport.recordStallPassArmed(pc, now_ms, .follower));
    try std.testing.expectEqual(@as(u32, 0), pc.stall_strikes.load(.acquire));
}

// ---------------------------------------------------------------------------
// (A.4) Leader behavior is unchanged under the armed API
// ---------------------------------------------------------------------------
// The leader is still armed (it always was). This pins the leader path so the
// rewrite to the armed API does not regress it: a stalled outbound stream
// observed as the leader reads as stalled (the original target wedge).
test "stall(armed): leader arming still detects a stalled outbound stream" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makePeerConn(allocator, 7, 12, stale);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
}

// (A.5) Armed candidate still respects the per-connection guards: a candidate
// with recent progress, or one we've never sent to, must NOT be armed. These
// guards are arm-independent, so they pass against the skeleton too (the
// skeleton returns false for a candidate for the WRONG reason — leader-only —
// but the assertion is the same `false`). Kept so the fixer's widening does not
// drop the frames_sent / progress guards for the newly-armed candidate role.
test "stall(armed): candidate with recent progress is not armed" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const recent = now_ms - (Transport.peer_stall_budget_ms - 500);
    const pc = try makePeerConn(allocator, 7, 12, recent);
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .candidate));
}

test "stall(armed): candidate we have never sent to is not armed" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const pc = try makePeerConn(allocator, 9, 0, 0); // frames_sent == 0
    defer freePeerConn(allocator, pc);

    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .candidate));
}

// ===========================================================================
// (B) Frozen-term pre-vote VISIBILITY
// ===========================================================================
// `pre_vote = true` freezes the term while a node is wedged as a candidate (the
// term only increments after a WON pre-vote), so the all-candidate wedge is
// SILENT — zero transport errors, zero term churn, nothing for an operator to
// see. `FrozenCandidateTracker.update(role, term, now_ms)` fires a rate-limited
// operator warn when a node has been a CANDIDATE at an UNCHANGING term for longer
// than `frozen_candidate_warn_after_ms` (≈ 3× the 5000 ms election timeout =
// 15 s), then suppresses further warns for `frozen_candidate_warn_interval_ms`.
//
// SKELETON `update` ALWAYS returns false (never due), so the "warn is due past
// threshold" assertions FAIL (red); the reset / not-due / rate-limit assertions
// (which expect false) already pass and pin the post-fix contract.

const FrozenCandidateTracker = raft_consensus.FrozenCandidateTracker;

// Threshold derivation pin: the warn must fire at ≈ 3× the default 5000 ms
// election timeout (15 s) so a single slow-but-progressing election round never
// trips it, and the rate-limit interval must be strictly positive and >= the
// warn-after threshold (so a node that warns does not immediately re-warn).
test "frozen-term: warn threshold is ~3x the election timeout and rate-limited" {
    const default_election_timeout_ms: i64 = 5000; // cluster.zig Config default
    try std.testing.expect(
        FrozenCandidateTracker.frozen_candidate_warn_after_ms >= 3 * default_election_timeout_ms,
    );
    try std.testing.expect(FrozenCandidateTracker.frozen_candidate_warn_interval_ms > 0);
    try std.testing.expect(
        FrozenCandidateTracker.frozen_candidate_warn_interval_ms >=
            FrozenCandidateTracker.frozen_candidate_warn_after_ms,
    );
}

// (B.1) Candidate at the SAME term past the threshold -> warn DUE.
// SKELETON returns false -> FAILS.
test "frozen-term: candidate stuck at one term past threshold warns" {
    var t: FrozenCandidateTracker = .{};
    const start_ms: i64 = 1_000_000;
    const term: u64 = 4;

    // Enter candidate at term 4; the run begins now, not yet due.
    try std.testing.expect(!t.update(.candidate, term, start_ms));

    // Still a candidate at the SAME term, but only halfway to the threshold.
    const half = start_ms + @divTrunc(FrozenCandidateTracker.frozen_candidate_warn_after_ms, 2);
    try std.testing.expect(!t.update(.candidate, term, half));

    // Past the threshold at the SAME term -> the wedge is now visible: DUE.
    const past = start_ms + FrozenCandidateTracker.frozen_candidate_warn_after_ms + 1;
    try std.testing.expect(t.update(.candidate, term, past));
}

// (B.2) The term advancing (election progressing) restarts the run -> NOT due,
// even though wall time exceeds the threshold relative to the ORIGINAL start.
// This expects false and passes against the skeleton; it pins that a progressing
// election (term churn) is NEVER flagged as frozen.
test "frozen-term: an advancing term is never flagged as frozen" {
    var t: FrozenCandidateTracker = .{};
    const start_ms: i64 = 2_000_000;

    try std.testing.expect(!t.update(.candidate, 4, start_ms));
    // Term advances to 5 just before the threshold -> run restarts at term 5.
    const bump_at = start_ms + FrozenCandidateTracker.frozen_candidate_warn_after_ms - 10;
    try std.testing.expect(!t.update(.candidate, 5, bump_at));
    // Now past the ORIGINAL threshold, but the term-5 run is young -> NOT due.
    const past_original = start_ms + FrozenCandidateTracker.frozen_candidate_warn_after_ms + 1;
    try std.testing.expect(!t.update(.candidate, 5, past_original));
}

// (B.3) Becoming leader or follower resets the tracker -> NOT due. Expects false;
// passes against the skeleton and pins the role-transition reset.
test "frozen-term: becoming leader or follower resets and is never due" {
    var t: FrozenCandidateTracker = .{};
    const start_ms: i64 = 3_000_000;

    try std.testing.expect(!t.update(.candidate, 7, start_ms));
    // Won the election: now leader, far past the threshold -> NOT due.
    const past = start_ms + FrozenCandidateTracker.frozen_candidate_warn_after_ms + 1;
    try std.testing.expect(!t.update(.leader, 8, past));
    // And a follower likewise is never flagged.
    try std.testing.expect(!t.update(.follower, 8, past + 100));
}

// (B.4) Rate limit: after a warn fires, a node STILL stuck must NOT warn again
// until the interval elapses, then warns once more.
// SKELETON never warns at all -> the FIRST "due" assertion already FAILS (red);
// the post-fix contract is the full sequence below.
test "frozen-term: a warn is rate-limited until the interval elapses" {
    var t: FrozenCandidateTracker = .{};
    const start_ms: i64 = 4_000_000;
    const term: u64 = 9;

    try std.testing.expect(!t.update(.candidate, term, start_ms));

    // First warn fires once past the threshold.
    const first_due = start_ms + FrozenCandidateTracker.frozen_candidate_warn_after_ms + 1;
    try std.testing.expect(t.update(.candidate, term, first_due));

    // Immediately after, still stuck, but inside the rate-limit window -> NOT due.
    try std.testing.expect(!t.update(.candidate, term, first_due + 1));
    const within_interval = first_due + FrozenCandidateTracker.frozen_candidate_warn_interval_ms - 1;
    try std.testing.expect(!t.update(.candidate, term, within_interval));

    // Once the interval elapses and the node is STILL a stuck candidate -> due again.
    const after_interval = first_due + FrozenCandidateTracker.frozen_candidate_warn_interval_ms + 1;
    try std.testing.expect(t.update(.candidate, term, after_interval));
}

// ===========================================================================
// (E) Per-direction liveness: only RESPONSE frames may stamp our outbound clock
// ===========================================================================
// k8s root cause #5 transport-wedge REGRESSION (2026-06-12): the stamp site in
// cluster.zig:applyDecodedRaftFrame calls `notePeerProgress(frame.from, ...)`
// UNCONDITIONALLY for every inbound raft frame. That is per-PEER, not
// per-DIRECTION. A stranded candidate re-sends RequestVote every 1-2 s; each
// inbound RequestVote stamps the LEADER's outbound-to-that-peer clock, so the
// 15 s stall budget never elapses and the leader never evicts/rebuilds its
// genuinely-wedged outbound stream to that peer. The wedge is masked by the
// PEER's healthy outbound traffic.
//
// Direction reasoning:
//   * An inbound REQUEST (request_vote / append_entries / install_snapshot)
//     proves only the PEER's outbound path to us works — NOT that our outbound
//     request to that peer was delivered. It must NOT stamp our outbound clock.
//   * An inbound RESPONSE (*_response) can only exist if OUR outbound request
//     reached the peer (the peer produced it by handling our request). Only a
//     response proves our outbound path, so only a response may stamp.
//
// `frameProvesOurOutboundDelivered(body)` is the pure classifier the gated stamp
// site will call: `if (frameProvesOurOutboundDelivered(body)) notePeerProgress(...)`.
//
// SKELETON returns true for EVERY variant (current unconditional-stamp behavior),
// so the three REQUEST assertions below FAIL (red) and the three RESPONSE
// assertions pass; after the fix narrows the body to the *_response-only switch,
// all six pass.

const Message = raft_consensus.Message;

// Minimal payload builders for each of the 6 Message variants. The classifier
// reads only the union TAG, so payload field values are immaterial; we still
// construct full, valid payloads (mirroring tests/test_quic_raft_smoke.zig's
// empty-entries AppendEntries and the envelope round-trip tests) so the test is
// robust to a future classifier that inspects fields.
fn msgRequestVote(pre_vote: bool) Message {
    return .{ .request_vote = .{
        .term = 3,
        .candidate_id = 7,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = pre_vote,
    } };
}
fn msgRequestVoteResponse(pre_vote: bool) Message {
    return .{ .request_vote_response = .{
        .term = 3,
        .vote_granted = true,
        .voter_id = 7,
        .pre_vote = pre_vote,
    } };
}
fn msgAppendEntries() Message {
    return .{ .append_entries = .{
        .term = 3,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &[_]raft_consensus.LogEntry{},
        .leader_commit = 0,
    } };
}
fn msgAppendEntriesResponse() Message {
    return .{ .append_entries_response = .{
        .term = 3,
        .success = true,
        .match_index = 1,
    } };
}
fn msgInstallSnapshot() Message {
    return .{ .install_snapshot = .{
        .term = 3,
        .leader_id = 2,
        .last_included_index = 0,
        .last_included_term = 0,
        .offset = 0,
        .data = &.{},
        .done = true,
    } };
}
fn msgInstallSnapshotResponse() Message {
    return .{ .install_snapshot_response = .{
        .term = 3,
        .success = true,
    } };
}

// (E.1) Pure classification table over all 6 Message variants.
// DESIRED: true for exactly the three *_response variants; false for the three
// request variants. Pre-vote is a FIELD, not a tag, so a pre-vote RequestVote is
// still a request (false) and a pre-vote RequestVoteResponse is still a response
// (true).
// RED: the skeleton returns true for everything, so the three request assertions
// (and the pre-vote-request assertion) FAIL.
test "raft liveness: only response frames prove our outbound was delivered" {
    // Requests prove only the PEER's outbound — must NOT stamp our clock.
    try std.testing.expect(!raft_consensus.frameProvesOurOutboundDelivered(msgRequestVote(false)));
    try std.testing.expect(!raft_consensus.frameProvesOurOutboundDelivered(msgAppendEntries()));
    try std.testing.expect(!raft_consensus.frameProvesOurOutboundDelivered(msgInstallSnapshot()));

    // A pre-vote RequestVote is still a REQUEST (pre_vote is a field, not a tag).
    try std.testing.expect(!raft_consensus.frameProvesOurOutboundDelivered(msgRequestVote(true)));

    // Responses can only exist if our outbound request reached the peer -> stamp.
    try std.testing.expect(raft_consensus.frameProvesOurOutboundDelivered(msgRequestVoteResponse(false)));
    try std.testing.expect(raft_consensus.frameProvesOurOutboundDelivered(msgAppendEntriesResponse()));
    try std.testing.expect(raft_consensus.frameProvesOurOutboundDelivered(msgInstallSnapshotResponse()));

    // A pre-vote RequestVoteResponse is still a RESPONSE (pre_vote is a field).
    try std.testing.expect(raft_consensus.frameProvesOurOutboundDelivered(msgRequestVoteResponse(true)));
}

// (E.2) Transport-level direction test: encodes the gating CONTRACT the
// cluster.zig stamp site will adopt —
//   `if (frameProvesOurOutboundDelivered(body)) transport.notePeerProgress(...)`
// — composed against the real helper + the real notePeerProgress, without a
// ClusterCoordinator. A leader-armed PeerConnection with an ancient progress
// stamp would evict; an inbound REQUEST must NOT refresh it (eviction decision
// stays true), while an inbound RESPONSE must refresh it (decision flips false).
//
// RED: with the skeleton classifier returning true for the request, the gated
// stamp fires and refreshes the clock, so assertion (a) — "request does NOT
// refresh" — FAILS. After the fix, the request is gated out and the clock stays
// ancient (a) holds; the response and response-response paths still refresh
// ((b), (c)).
test "raft liveness: inbound request does not refresh outbound stall clock; response does" {
    const allocator = std.testing.allocator;

    // Helper that simulates the cluster.zig gated stamp path exactly: stamp only
    // when the inbound frame proves OUR outbound was delivered.
    const Gate = struct {
        fn apply(transport: *Transport, peer_id: u64, body: Message, now_ms: i64) void {
            if (raft_consensus.frameProvesOurOutboundDelivered(body)) {
                transport.notePeerProgress(peer_id, now_ms);
            }
        }
    };

    // --- (a) An inbound REQUEST must NOT refresh: eviction decision stays true.
    {
        var transport = Transport.init(allocator);
        defer transport.deinit();

        const now_ms: i64 = 9_000_000;
        const ancient = now_ms - (Transport.peer_stall_budget_ms + 5000);
        const pc = try makePeerConn(allocator, 4, 8, ancient);
        const io = std.Io.Threaded.global_single_threaded.io();
        transport.peers_mutex.lockUncancelable(io);
        try transport.peers.put(4, pc); // transport.deinit frees the entry.
        transport.peers_mutex.unlock(io);

        // Sanity: armed as leader, this peer is stalled before any frame arrives.
        try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));

        // A stranded candidate's RequestVote arrives FROM this peer. This proves
        // only the PEER's outbound; it must NOT reset our outbound stall clock.
        Gate.apply(&transport, 4, msgRequestVote(false), now_ms);

        // DESIRED: clock untouched -> still stalled -> eviction decision stays true.
        // RED: skeleton stamps it, clock becomes now_ms, decision flips false.
        try std.testing.expectEqual(ancient, pc.last_progress_ms.load(.acquire));
        try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
    }

    // --- (b) An inbound RESPONSE (append_entries_response) MUST refresh: the
    //         eviction decision flips false.
    {
        var transport = Transport.init(allocator);
        defer transport.deinit();

        const now_ms: i64 = 9_000_000;
        const ancient = now_ms - (Transport.peer_stall_budget_ms + 5000);
        const pc = try makePeerConn(allocator, 5, 8, ancient);
        const io = std.Io.Threaded.global_single_threaded.io();
        transport.peers_mutex.lockUncancelable(io);
        try transport.peers.put(5, pc); // transport.deinit frees the entry.
        transport.peers_mutex.unlock(io);

        try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));

        // A response can only exist if our outbound AppendEntries reached the peer.
        Gate.apply(&transport, 5, msgAppendEntriesResponse(), now_ms);

        try std.testing.expectEqual(now_ms, pc.last_progress_ms.load(.acquire));
        try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
    }

    // --- (c) An inbound request_vote_response likewise refreshes.
    {
        var transport = Transport.init(allocator);
        defer transport.deinit();

        const now_ms: i64 = 9_000_000;
        const ancient = now_ms - (Transport.peer_stall_budget_ms + 5000);
        const pc = try makePeerConn(allocator, 6, 8, ancient);
        const io = std.Io.Threaded.global_single_threaded.io();
        transport.peers_mutex.lockUncancelable(io);
        try transport.peers.put(6, pc); // transport.deinit frees the entry.
        transport.peers_mutex.unlock(io);

        try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));

        Gate.apply(&transport, 6, msgRequestVoteResponse(false), now_ms);

        try std.testing.expectEqual(now_ms, pc.last_progress_ms.load(.acquire));
        try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
    }
}
