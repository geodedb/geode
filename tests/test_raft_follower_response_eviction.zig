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
