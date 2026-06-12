// RED reproduction tests — k8s churn recovery, ROOT CAUSE #3 (RC3):
// follower response-direction suppression in src/distributed/raft_consensus.zig.
//
// THE BUG (evidence-verified):
//   * `shouldEvictOnStallArmed` suppresses eviction for any FOLLOWER
//     unconditionally (raft_consensus.zig:1147: `if (arm == .follower) return false;`).
//   * But a follower whose RESPONSE-carrying OUTBOUND is dead keeps receiving
//     AppendEntries (its INBOUND is fine), answers into a dead send buffer, and
//     the leader never gets the acks — the write never commits, and the follower
//     never rebuilds because it is a follower. This is the observed "geode-0 stuck
//     candidate at term 1 while 2/3 quorum couldn't commit a write".
//   * Blanket follower suppression existed for a good reason (a QUIET follower
//     during a leaderless election must NOT churn its connections — that was the
//     original election-livelock), so the fix must NOT simply arm all followers.
//
// INTENDED FIX CONTRACT C (what these tests pin):
//   Replace blanket follower suppression with a DIRECTIONAL condition: a follower
//   (or any role) that is ACTIVELY RECEIVING request frames from a peer while
//   having NO outbound-delivery proof (no `*_response` frames received) for the
//   stall budget must ALSO be allowed to evict/rebuild its outbound to that peer.
//   A QUIET follower (no recent inbound requests) stays suppressed — no churn.
//
// REQUIRED NEW SURFACE:
//
//   (1) A new PURE decision on Transport (additive — leaves the existing
//       `shouldEvictOnStallArmed` untouched so the current 22-test stall suite
//       stays green):
//
//   pub fn directionalEvictAllowed(
//       arm: StallArm,
//       frames_sent_nonzero: bool,    // we have actually been sending to this peer
//       outbound_proof_stale: bool,   // now - last_progress_ms > effective budget
//       inbound_request_recent: bool, // we recently saw an inbound REQUEST from this peer
//   ) bool {
//       if (!frames_sent_nonzero) return false;   // never sent -> nothing to rebuild
//       if (!outbound_proof_stale) return false;  // outbound proven recently -> healthy
//       return switch (arm) {
//           .leader, .candidate => true,           // armed roles evict on stale proof alone
//           .follower => inbound_request_recent,    // follower: only the one-way-wedge case
//       };
//   }
//
//   (2) A new field on Transport.PeerConnection to drive `inbound_request_recent`,
//       the complement of the response-only `notePeerProgress`:
//
//   /// Wall-clock ms of the last inbound REQUEST (request_vote / append_entries /
//   /// install_snapshot) observed FROM this peer. Stamped in the inbound path
//   /// (cluster.zig:applyDecodedRaftFrame) for the NON-response branch — i.e.
//   /// exactly when `!frameProvesOurOutboundDelivered(body)`.
//   last_inbound_request_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
//
// IMPORTANT WIRING CAVEAT for the fixer (so a HEALTHY follower does NOT churn):
//   For a follower, `outbound_proof_stale` must NOT be permanently true just
//   because a follower never receives `*_response` frames. A healthy follower's
//   outbound IS implicitly proven when it receives an AppendEntries whose
//   prev_log_index / leader_commit ADVANCES (the leader only advances after it
//   applied the follower's prior response). Stamp `notePeerProgress` on that
//   advance too, so a healthy follower reads `outbound_proof_stale == false` and
//   directionalEvictAllowed returns false; a WEDGED follower sees repeated
//   non-advancing retransmits -> `outbound_proof_stale == true` + inbound recent
//   -> eviction allowed. The pure decision below is correct given its inputs; the
//   fixer owns computing those two booleans correctly.
//
// RED MECHANISM: comptime `@hasDecl` / `@hasField` guards. The `directionalEvictAllowed`
// tests return an error until the function exists (file still compiles — the
// missing-symbol then-branch is comptime-pruned). The `@hasField` test compiles
// today and FAILS its assertion until the field is added.

const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const Transport = raft_consensus.Transport;
const StallArm = Transport.StallArm;

// ---------------------------------------------------------------------------
// (C.1) THE FIX: a follower actively receiving requests but with no outbound
// proof for the budget IS allowed to evict (the one-way-wedge victim recovers).
// ---------------------------------------------------------------------------
test "directional: follower with inbound requests + stale outbound proof may evict" {
    if (comptime @hasDecl(Transport, "directionalEvictAllowed")) {
        try std.testing.expect(Transport.directionalEvictAllowed(
            .follower,
            true, // frames_sent_nonzero: we have been sending responses
            true, // outbound_proof_stale: no *_response / advance for the budget
            true, // inbound_request_recent: still receiving AppendEntries
        ));
    } else {
        return error.DirectionalEvictAllowedNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (C.2) NO REGRESSION: a QUIET follower (no recent inbound requests) stays
// suppressed — this is the original reason follower suppression existed (don't
// churn connections during a leaderless election).
// ---------------------------------------------------------------------------
test "directional: quiet follower (no inbound requests) stays suppressed" {
    if (comptime @hasDecl(Transport, "directionalEvictAllowed")) {
        try std.testing.expect(!Transport.directionalEvictAllowed(
            .follower,
            true, // frames_sent_nonzero
            true, // outbound_proof_stale
            false, // inbound_request_recent: NOTHING coming in -> no one-way-wedge signal
        ));
    } else {
        return error.DirectionalEvictAllowedNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (C.3) A follower whose outbound was proven recently is healthy -> no eviction,
// even while actively receiving requests.
// ---------------------------------------------------------------------------
test "directional: follower with fresh outbound proof is never evicted" {
    if (comptime @hasDecl(Transport, "directionalEvictAllowed")) {
        try std.testing.expect(!Transport.directionalEvictAllowed(
            .follower,
            true, // frames_sent_nonzero
            false, // outbound_proof_stale: proven recently (advancing commit) -> healthy
            true, // inbound_request_recent
        ));
    } else {
        return error.DirectionalEvictAllowedNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (C.4) A peer we have never sent to is never evicted (no outbound to rebuild),
// regardless of role or inbound traffic.
// ---------------------------------------------------------------------------
test "directional: a peer with no frames sent is never evicted" {
    if (comptime @hasDecl(Transport, "directionalEvictAllowed")) {
        try std.testing.expect(!Transport.directionalEvictAllowed(.follower, false, true, true));
        try std.testing.expect(!Transport.directionalEvictAllowed(.leader, false, true, true));
        try std.testing.expect(!Transport.directionalEvictAllowed(.candidate, false, true, true));
    } else {
        return error.DirectionalEvictAllowedNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (C.5) Armed roles (leader / candidate) evict on stale outbound proof ALONE —
// inbound activity is irrelevant for them (this mirrors the existing
// `shouldEvictOnStallArmed` armed behavior; the directional gate must not weaken
// it).
// ---------------------------------------------------------------------------
test "directional: leader and candidate evict on stale proof regardless of inbound" {
    if (comptime @hasDecl(Transport, "directionalEvictAllowed")) {
        // Stale proof + no inbound at all -> still evict for armed roles.
        try std.testing.expect(Transport.directionalEvictAllowed(.leader, true, true, false));
        try std.testing.expect(Transport.directionalEvictAllowed(.candidate, true, true, false));
        // Fresh proof -> never evict, armed or not.
        try std.testing.expect(!Transport.directionalEvictAllowed(.leader, true, false, false));
        try std.testing.expect(!Transport.directionalEvictAllowed(.candidate, true, false, true));
    } else {
        return error.DirectionalEvictAllowedNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (C.6) The PeerConnection must carry an inbound-request timestamp so the reaper
// can compute `inbound_request_recent`. `@hasField` is total (returns false when
// absent), so this test COMPILES today and FAILS its assertion until the field
// is added — a genuine compile-and-assert RED.
// ---------------------------------------------------------------------------
test "directional: PeerConnection carries a last_inbound_request_ms timestamp" {
    try std.testing.expect(@hasField(Transport.PeerConnection, "last_inbound_request_ms"));
}

// ===========================================================================
// (D) RED reproduction tests — IDLE-CLUSTER CONNECTION CHURN (RC3 residual).
//
// THE BUG (residual flagged on the RC3 landing, evidence below):
//   On a fully idle (zero-write) HEALTHY cluster the leader keeps sending EMPTY
//   heartbeats (no log entries, constant prev_log_index / leader_commit). A
//   follower's implicit-ack path (`noteInboundAppendEntriesAdvance`) only stamps
//   outbound proof when prev_log_index / leader_commit ADVANCE — which never
//   happens on an idle cluster. So a healthy quiet follower's outbound proof goes
//   permanently stale after the base budget while the leader's heartbeats keep
//   `last_inbound_request_ms` fresh -> `directionalEvictAllowed(.follower, true,
//   true, true)` returns true -> the follower evicts and rebuilds its perfectly
//   healthy outbound every `currentBudgetMs()` (capped 60s), FOREVER. Perpetual
//   churn on every idle cluster — and churn is exactly what destabilizes this
//   fire-and-forget transport (teardown drops in-flight acks, which can make the
//   leader's per-direction detector fire too, amplifying).
//
// THE DISTINGUISHING SIGNAL:
//   A WEDGED follower->leader response direction manifests leader-side as ack
//   loss, so the leader RETRANSMITS entries — the follower sees repeated
//   NON-EMPTY, NON-ADVANCING AppendEntries. A HEALTHY idle cluster sends EMPTY
//   heartbeats (no entries, constant indices). So an empty heartbeat is "nothing
//   pending, connection presumed fine" and MUST stamp proof; only a non-advancing
//   retransmit WITH entries leaves the follower eviction-eligible.
//
// INTENDED FIX CONTRACT (what these tests pin):
//   * `noteInboundAppendEntriesAdvance` gains a `has_entries: bool` parameter,
//     populated at the cluster.zig decode site from `ae.entries.len > 0`.
//   * A PURE decision `implicitAckStampsProof(advanced, has_entries)` governs the
//     stamp: proof is stamped when (advanced) OR (!advanced AND !has_entries).
//
//   Behavior matrix (the 3 cases):
//     1. advancing (entries or not)        -> STAMP (existing behavior, keep)
//     2. non-advancing + empty (heartbeat) -> STAMP (NEW — the churn guard)
//     3. non-advancing + has_entries       -> NO STAMP (preserves the F2/RC3 wedge
//                                             detection: a committed-blocked write
//                                             shows up exactly as this case)
//
// Accepted residual (documented in the impl comment): an idle cluster whose
// follower outbound dies SILENTLY is indistinguishable from healthy-idle at the
// follower until the next write turns the loss into retransmits — at which point
// case 3 makes it eligible. Leader-side per-direction liveness (dacf4771) covers
// detection meanwhile.
//
// RED MECHANISM: `@hasDecl` comptime guard on the pure function returns an error
// until it exists; the Transport-level integration test guards on the new
// `has_entries` parameter arity via @typeInfo and errors until the signature
// changes.
// ===========================================================================

const Peer = raft_consensus.Peer;

// Build a heap-allocated PeerConnection with the in-test QUIC stub for the
// stamping side-effect tests, mirroring tests/test_raft_stall_detector.zig.
const QuicClientType = @FieldType(Transport.PeerConnection, "client");
fn makePeerConn(
    allocator: std.mem.Allocator,
    peer_id: u64,
    frames_sent: u64,
    last_progress_ms: i64,
) !*Transport.PeerConnection {
    const pc = try allocator.create(Transport.PeerConnection);
    pc.* = .{
        .allocator = allocator,
        .client = QuicClientType.init(allocator),
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

// ---------------------------------------------------------------------------
// (D.1) PURE matrix — advancing always stamps (entries present or not).
// ---------------------------------------------------------------------------
test "implicit ack: advancing AppendEntries always stamps proof (with or without entries)" {
    if (comptime @hasDecl(Transport, "implicitAckStampsProof")) {
        // case 1: advanced + has_entries -> stamp
        try std.testing.expect(Transport.implicitAckStampsProof(true, true));
        // case 1: advanced + empty -> stamp
        try std.testing.expect(Transport.implicitAckStampsProof(true, false));
    } else {
        return error.ImplicitAckStampsProofNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (D.2) PURE matrix — THE CHURN GUARD: a non-advancing EMPTY heartbeat (idle
// healthy cluster) stamps proof so a quiet follower never churns.
// ---------------------------------------------------------------------------
test "implicit ack: non-advancing EMPTY heartbeat stamps proof (idle churn guard)" {
    if (comptime @hasDecl(Transport, "implicitAckStampsProof")) {
        try std.testing.expect(Transport.implicitAckStampsProof(false, false));
    } else {
        return error.ImplicitAckStampsProofNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (D.3) PURE matrix — a non-advancing RETRANSMIT (entries present) does NOT
// stamp, so a genuinely wedged follower stays eviction-eligible (preserves F2).
// ---------------------------------------------------------------------------
test "implicit ack: non-advancing RETRANSMIT (has_entries) does NOT stamp (preserves wedge detection)" {
    if (comptime @hasDecl(Transport, "implicitAckStampsProof")) {
        try std.testing.expect(!Transport.implicitAckStampsProof(false, true));
    } else {
        return error.ImplicitAckStampsProofNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (D.4) INTEGRATION — `noteInboundAppendEntriesAdvance` with the new
// `has_entries` parameter actually STAMPS `last_progress_ms` on an idle EMPTY
// heartbeat (non-advancing), proving the wired churn guard, while a non-advancing
// retransmit WITH entries leaves the clock stale (eviction-eligible).
// ---------------------------------------------------------------------------
test "implicit ack: empty heartbeat stamps last_progress_ms; retransmit-with-entries does not" {
    // RED arity guard: until `noteInboundAppendEntriesAdvance` takes the extra
    // `has_entries: bool`, the call below would not compile, so we gate the body
    // on the parameter count and fail loudly when it's the old 4-arg shape.
    const params = @typeInfo(@TypeOf(Transport.noteInboundAppendEntriesAdvance)).@"fn".params;
    if (comptime params.len < 6) {
        return error.NoteInboundAppendEntriesAdvanceMissingHasEntries;
    }

    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    const peer_id: u64 = 42;
    // Seed the outbound connection with a STALE last_progress_ms and a non-zero
    // last-seen index/commit so a later heartbeat at the SAME index/commit is
    // non-advancing. The map owns the PeerConnection; transport.deinit destroys it.
    const pc = try makePeerConn(allocator, peer_id, 12, 1_000);
    pc.last_seen_prev_log_index.store(7, .release);
    pc.last_seen_leader_commit.store(7, .release);
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        transport.peers_mutex.lockUncancelable(io);
        try transport.peers.put(peer_id, pc);
        transport.peers_mutex.unlock(io);
    }

    // Case 3: non-advancing (same 7/7) + has_entries=true (a retransmit) -> NO stamp.
    transport.noteInboundAppendEntriesAdvance(peer_id, 7, 7, 5_000, true);
    try std.testing.expectEqual(@as(i64, 1_000), pc.last_progress_ms.load(.acquire));

    // Case 2: non-advancing (same 7/7) + has_entries=false (empty heartbeat) -> STAMP.
    transport.noteInboundAppendEntriesAdvance(peer_id, 7, 7, 9_000, false);
    try std.testing.expectEqual(@as(i64, 9_000), pc.last_progress_ms.load(.acquire));

    // Case 1: advancing (8 > 7) -> STAMP regardless of has_entries.
    transport.noteInboundAppendEntriesAdvance(peer_id, 8, 7, 12_000, true);
    try std.testing.expectEqual(@as(i64, 12_000), pc.last_progress_ms.load(.acquire));
}

comptime {
    // Silence unused-import if Peer is not otherwise referenced.
    _ = Peer;
}
