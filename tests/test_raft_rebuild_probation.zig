// RED reproduction tests — k8s churn recovery, ROOT CAUSE #2 (RC2):
// rebuild clock-reset re-eviction chase in src/distributed/raft_consensus.zig.
//
// THE BUG (evidence-verified):
//   * The stall reaper `maybeReconnectOnStall` (raft_consensus.zig:1227-1250;
//     15 s budget at :1057, 2 strikes at :1072) rebuilds this node's OUTBOUND
//     connection to a peer.
//   * The rebuild path `getOrCreatePeerConnection` resets
//     `last_progress_ms = compat_milliTimestamp()` (raft_consensus.zig:1461) —
//     i.e. a FORCED rebuild is treated as PROOF OF HEALTH.
//   * With all 6 directed connections stale and all nodes candidates, the
//     rebuilds chase each other on phase-shifted clocks: each side rebuilds,
//     stamps itself "healthy", and never actually exchanges a frame before the
//     next stale window — the cluster never converges.
//
// INTENDED FIX CONTRACT B (what these tests pin):
//   A stall-triggered rebuild must NOT count as progress proof. After a rebuild
//   the peer enters PROBATION (it is "unproven"). ONLY a real inbound `*_response`
//   frame (the existing `frameProvesOurOutboundDelivered` gate) clears probation.
//   CONSECUTIVE rebuilds without an intervening proof ESCALATE the next eviction
//   budget (exponential backoff, capped) — so simultaneous mutual rebuilds get
//   progressively longer windows to complete handshakes and exchange frames. A
//   real `*_response` clears probation AND resets the budget to the base.
//
// REQUIRED NEW SURFACE (the fixer implements this in raft_consensus.zig as a
// top-level `pub const`, sibling to `FrozenCandidateTracker` — a pure, clock-free
// state machine, no QUIC):
//
//   pub const RebuildProbation = struct {
//       /// Base eviction budget; equals the flat `Transport.peer_stall_budget_ms`.
//       pub const base_budget_ms: i64 = Transport.peer_stall_budget_ms; // 15_000
//       /// Cap for the exponential backoff (the prompt's 60 s = base * 4).
//       pub const max_budget_ms: i64 = base_budget_ms * 4;              // 60_000
//
//       in_probation: bool = false,
//       consecutive_rebuilds: u32 = 0,
//
//       /// A stall-triggered rebuild occurred: enter probation and escalate the
//       /// consecutive-rebuild count. Stamps NO progress clock (the whole fix).
//       pub fn noteStallRebuild(self: *RebuildProbation) void { ... }
//
//       /// A real inbound `*_response` proved our outbound: clear probation and
//       /// reset the escalation back to base.
//       pub fn noteOutboundProof(self: *RebuildProbation) void { ... }
//
//       /// Are we currently unproven since the last stall-rebuild?
//       pub fn inProbation(self: *const RebuildProbation) bool { ... }
//
//       /// Eviction budget for the NEXT stall window given the current
//       /// escalation: min(base << consecutive_rebuilds, max), i.e.
//       ///   0 rebuilds -> base (15 s); 1 -> 30 s; 2 -> 60 s; 3+ -> 60 s (capped).
//       pub fn currentBudgetMs(self: *const RebuildProbation) i64 { ... }
//   };
//
// WIRING (for the fixer, not unit-tested here): hang a `RebuildProbation` off
// each `PeerConnection`; on a stall-triggered rebuild call `noteStallRebuild()`
// and DO NOT stamp `last_progress_ms` as proof; have the stall reaper compare the
// stall window against `currentBudgetMs()` (not the flat const) while in
// probation; and in the gated stamp site call `noteOutboundProof()` exactly when
// `frameProvesOurOutboundDelivered(body)` is true.
//
// RED MECHANISM: identical to test_raft_receiver_reap.zig — comptime `@hasDecl`
// guard returns an error until `RebuildProbation` exists; the file still compiles
// because the missing-symbol then-branch is comptime-pruned. Once implemented,
// the real behavioral assertions run.

const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const Transport = raft_consensus.Transport;
const Message = raft_consensus.Message;

// Minimal Message builders for the gated-clear test (B.6). The classifier reads
// only the union TAG, so payload values are immaterial; full valid payloads are
// built so the test survives a future field-inspecting classifier.
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

// ---------------------------------------------------------------------------
// (B.1) Fresh state: NOT in probation; the budget is the flat base
// (== Transport.peer_stall_budget_ms). Also pins the cap relationship.
// ---------------------------------------------------------------------------
test "probation: fresh peer is proven and uses the base budget" {
    if (comptime @hasDecl(raft_consensus, "RebuildProbation")) {
        const RP = raft_consensus.RebuildProbation;
        try std.testing.expectEqual(Transport.peer_stall_budget_ms, RP.base_budget_ms);
        try std.testing.expectEqual(RP.base_budget_ms * 4, RP.max_budget_ms);

        var p: RP = .{};
        try std.testing.expect(!p.inProbation());
        try std.testing.expectEqual(RP.base_budget_ms, p.currentBudgetMs());
    } else {
        return error.RebuildProbationNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (B.2) A stall-triggered rebuild enters probation (it is NOT progress proof)
// and escalates the budget to base*2 (15 s -> 30 s). This is the core of the
// fix: the buggy code instead stamped `last_progress_ms = now` (health).
// ---------------------------------------------------------------------------
test "probation: a stall-rebuild enters probation and is not treated as progress" {
    if (comptime @hasDecl(raft_consensus, "RebuildProbation")) {
        const RP = raft_consensus.RebuildProbation;
        var p: RP = .{};

        p.noteStallRebuild();
        try std.testing.expect(p.inProbation()); // unproven, NOT "healthy"
        try std.testing.expectEqual(RP.base_budget_ms * 2, p.currentBudgetMs());
    } else {
        return error.RebuildProbationNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (B.3) Consecutive rebuilds without intervening proof escalate the budget:
// 15 s -> 30 s -> 60 s (capped). Pins the documented backoff sequence.
// ---------------------------------------------------------------------------
test "probation: consecutive rebuilds escalate the budget (15s -> 30s -> 60s, capped)" {
    if (comptime @hasDecl(raft_consensus, "RebuildProbation")) {
        const RP = raft_consensus.RebuildProbation;
        var p: RP = .{};

        // 0 rebuilds -> base.
        try std.testing.expectEqual(RP.base_budget_ms, p.currentBudgetMs());

        // 1 rebuild -> base*2 (30 s).
        p.noteStallRebuild();
        try std.testing.expectEqual(RP.base_budget_ms * 2, p.currentBudgetMs());

        // 2 rebuilds -> base*4 (60 s == cap).
        p.noteStallRebuild();
        try std.testing.expectEqual(RP.base_budget_ms * 4, p.currentBudgetMs());
        try std.testing.expectEqual(RP.max_budget_ms, p.currentBudgetMs());

        // 3 rebuilds -> still capped at max (base*8 would be 120 s).
        p.noteStallRebuild();
        try std.testing.expectEqual(RP.max_budget_ms, p.currentBudgetMs());
        try std.testing.expect(p.inProbation());
    } else {
        return error.RebuildProbationNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (B.4) The backoff is CAPPED: arbitrarily many rebuilds never exceed the cap.
// ---------------------------------------------------------------------------
test "probation: the escalating budget never exceeds the cap" {
    if (comptime @hasDecl(raft_consensus, "RebuildProbation")) {
        const RP = raft_consensus.RebuildProbation;
        var p: RP = .{};
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            p.noteStallRebuild();
            try std.testing.expect(p.currentBudgetMs() <= RP.max_budget_ms);
        }
        // Deep into the escalation we are pinned at the cap.
        try std.testing.expectEqual(RP.max_budget_ms, p.currentBudgetMs());
    } else {
        return error.RebuildProbationNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (B.5) A real outbound proof clears probation AND resets the budget to base.
// ---------------------------------------------------------------------------
test "probation: an outbound proof clears probation and resets the budget" {
    if (comptime @hasDecl(raft_consensus, "RebuildProbation")) {
        const RP = raft_consensus.RebuildProbation;
        var p: RP = .{};

        // Escalate to the cap, fully unproven.
        p.noteStallRebuild();
        p.noteStallRebuild();
        p.noteStallRebuild();
        try std.testing.expect(p.inProbation());
        try std.testing.expectEqual(RP.max_budget_ms, p.currentBudgetMs());

        // A real `*_response` arrived -> proven, budget back to base.
        p.noteOutboundProof();
        try std.testing.expect(!p.inProbation());
        try std.testing.expectEqual(RP.base_budget_ms, p.currentBudgetMs());
    } else {
        return error.RebuildProbationNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (B.6) ONLY a real inbound `*_response` frame clears probation. Composed against
// the REAL `frameProvesOurOutboundDelivered` classifier + the probation state
// machine, exactly as the gated stamp site will wire them: an inbound REQUEST
// must NOT clear probation; an inbound RESPONSE must.
// ---------------------------------------------------------------------------
test "probation: only a response frame (frameProvesOurOutboundDelivered) clears probation" {
    if (comptime @hasDecl(raft_consensus, "RebuildProbation")) {
        const RP = raft_consensus.RebuildProbation;
        var p: RP = .{};

        // Two consecutive stall-rebuilds: escalated and unproven.
        p.noteStallRebuild();
        p.noteStallRebuild();
        try std.testing.expect(p.inProbation());
        try std.testing.expectEqual(RP.base_budget_ms * 4, p.currentBudgetMs());

        // An inbound REQUEST proves only the PEER's outbound -> must NOT clear.
        const req = msgAppendEntries();
        if (raft_consensus.frameProvesOurOutboundDelivered(req)) p.noteOutboundProof();
        try std.testing.expect(p.inProbation()); // still unproven
        try std.testing.expectEqual(RP.base_budget_ms * 4, p.currentBudgetMs());

        // An inbound RESPONSE proves OUR outbound reached the peer -> clears it.
        const resp = msgAppendEntriesResponse();
        if (raft_consensus.frameProvesOurOutboundDelivered(resp)) p.noteOutboundProof();
        try std.testing.expect(!p.inProbation());
        try std.testing.expectEqual(RP.base_budget_ms, p.currentBudgetMs());
    } else {
        return error.RebuildProbationNotImplemented;
    }
}
