// RED reproduction tests — k8s SUSTAINED-churn liveness, ROOT CAUSE A (RC-A):
// AGGREGATE inbound-pool occupancy starvation in src/distributed/cluster.zig.
//
// THE BUG (confirmed by triage with a discrete-event model — distinct from the
// per-connection RC1 reap already in tests/test_raft_receiver_reap.zig):
//   * `connection_pool` has exactly 4 workers (cluster.zig:1055-1058). Each
//     accepted inbound conn runs a long-lived `handleQuicConnection` task that
//     PINS one worker for the connection's lifetime, busy-parking ~200µs on
//     WouldBlock (cluster.zig:1402-1418).
//   * The RC1 30 s idle-reap (`shouldReapIdleInboundConnection`) runs ONLY inside
//     the pinned worker's own loop, and stamps `last_activity_ms` at WORKER-
//     ACQUISITION time (cluster.zig:1400). A QUEUED connection therefore never
//     starts its reap clock, and there is NO independent sweeper.
//   * Under 3 back-to-back 4-kill churn rounds, zombie half-open inbound conns
//     arrive faster than the serialized 4-wide × 30 s-each drain can clear them.
//     Pool occupancy stays ≥ 4, the backlog carries ACROSS churn rounds (the
//     A→B→C monotonic-degradation signature), and the node's ONLY path to
//     `raft.handleMessage` (cluster.zig:1730) is starved for 87–180 s+. It cannot
//     hear the leader's AppendEntries (the raft lib's only same-term step-down
//     trigger) → it strands as candidate at the quorum's term.
//   * tests/test_raft_receiver_reap.zig covers only the PER-CONNECTION reap
//     decision. The AGGREGATE-occupancy gap — a zombie's idle clock must run from
//     ACCEPT time, and aggregate zombie occupancy must not permanently starve the
//     pool — is UNCOVERED. These tests pin that gap.
//
// INTENDED FIX CONTRACT (RC-A — what these tests pin; NOT the implementation):
//   The fixer decouples reaping from worker ownership so that:
//     (a) a zombie's idle clock starts at ACCEPT time, not at worker-acquisition
//         time; and
//     (b) aggregate zombie occupancy cannot permanently starve the pool — a
//         fresh, ACTIVE connection (the leader's rebuilt conn delivering current-
//         term AppendEntries) is serviced within a BOUNDED budget (well under one
//         election timeout) even when many zombies are queued/pinned.
//   The decision is a PURE, unit-testable function (injected clock + injected
//   per-connection accept/last-activity timestamps), a sibling to
//   `shouldReapIdleInboundConnection`, mirroring the stall-detector decision
//   functions in raft_consensus.zig.
//
// REQUIRED NEW SURFACE (the fixer implements these in src/distributed/cluster.zig
// as top-level `pub` decls, siblings to `shouldReapIdleInboundConnection`).
// EXACT names/shapes are the fixer's call so long as the CONTRACT below holds;
// these tests probe for the most likely names and assert behavior. If the fixer
// chooses different names, update ONLY the `@hasDecl` probe strings here — never
// loosen an assertion.
//
//   /// One inbound connection's liveness snapshot for the aggregate decision.
//   /// `accepted_ms` is stamped at ACCEPT time (the RC-A fix — NOT at worker
//   /// acquisition); `last_activity_ms` is the most recent stream/frame activity
//   /// (== accepted_ms until the conn does anything). A "zombie" is a conn whose
//   /// last_activity is older than the idle deadline measured from NOW.
//   pub const InboundConnSnapshot = struct {
//       accepted_ms: i64,
//       last_activity_ms: i64,
//   };
//
//   /// PURE: given the current pool snapshot (every in-flight/queued inbound
//   /// conn) and the worker count + idle deadline, return how many connections
//   /// the sweeper MUST reap THIS pass so that a fresh active conn can be
//   /// serviced. Contract:
//   ///   * counts conns whose idle age (now - last_activity) exceeds deadline as
//   ///     reap-eligible "zombies" — idle clock runs from accept/last-activity,
//   ///     INDEPENDENT of whether the conn ever acquired a worker;
//   ///   * if all `workers` slots are occupied AND >=1 zombie exists, returns
//   ///     >=1 (free at least one slot — never returns 0 while the pool is full
//   ///     of zombies);
//   ///   * never reaps a conn with fresh activity (idle age <= deadline);
//   ///   * returns 0 when no zombie exists (healthy quiet peers are safe).
//   pub fn inboundReapCountForCapacity(
//       snapshots: []const InboundConnSnapshot,
//       workers: usize,
//       now_ms: i64,
//       deadline_ms: i64,
//   ) usize { ... }
//
//   /// PURE: true iff a freshly-accepted ACTIVE conn can be serviced within
//   /// `budget_ms` given the current snapshot — i.e. the sweeper frees a slot in
//   /// time. The whole point of RC-A: this must hold even when `workers` slots
//   /// are all pinned by zombies, because their accept-time idle clocks let the
//   /// sweeper reap them. Returns false only if NON-zombie (active) conns alone
//   /// already saturate every worker (genuine load, not a churn wedge).
//   pub fn freshActiveConnServiceableWithin(
//       snapshots: []const InboundConnSnapshot,
//       workers: usize,
//       now_ms: i64,
//       deadline_ms: i64,
//       budget_ms: i64,
//   ) bool { ... }
//
//   /// The bounded service budget for a fresh active inbound conn under churn —
//   /// MUST be well under one election timeout (so a rebuilt leader conn is
//   /// serviced before the candidate's election timer fires and it strands).
//   pub const inbound_fresh_conn_service_budget_ms: i64 = ...; // e.g. 1_000
//
// RED MECHANISM: every test is guarded by `comptime @hasDecl(...)`. Until the
// fixer adds the named symbols the guard's else-branch returns an error, so the
// test FAILS while the file still COMPILES (the missing-symbol then-branch is
// comptime-pruned). Once the symbols exist, the then-branch runs the real
// behavioral assertions — implement the contract WRONG and the test stays red on
// the assertion. Do not edit these tests to make them pass; implement the
// contract.

const std = @import("std");
const geode = @import("geode");

const cluster = geode.distributed.cluster;

// The fixed inbound worker count (cluster.zig:1055-1058). Not exported; used
// here as the realistic pool size the aggregate decision must reason about.
const inbound_workers: usize = 4;

// The ~300 s QUIC idle timeout the aggregate sweeper must beat by a wide margin.
const quic_idle_timeout_ms: i64 = 300_000;

// A representative election timeout. The fresh-conn service budget must be well
// under this — otherwise a stranded candidate's election timer fires before the
// rebuilt leader connection is serviced. Used only as an upper-bound sanity
// ceiling for the budget constant.
const election_timeout_ms: i64 = 5_000;

// Helper: build a snapshot slice from (accepted_ms, last_activity_ms) pairs,
// gated on the snapshot type existing so the file compiles pre-fix.
fn snap(comptime accepted_ms: i64, comptime last_activity_ms: i64) cluster.InboundConnSnapshot {
    return .{ .accepted_ms = accepted_ms, .last_activity_ms = last_activity_ms };
}

// ---------------------------------------------------------------------------
// (RC-A.1) AGGREGATE: all 4 workers pinned by idle zombies + queued zombies.
// The sweeper MUST reap at least one (free a slot) so a fresh active conn can be
// serviced — the idle clock runs from ACCEPT/last-activity, NOT from worker
// acquisition. This is the core RC-A contract: a full pool of zombies cannot
// return reap-count 0.
// ---------------------------------------------------------------------------
test "occupancy: a pool fully pinned by idle zombies must reap to free capacity" {
    if (comptime @hasDecl(cluster, "inboundReapCountForCapacity") and
        @hasDecl(cluster, "InboundConnSnapshot"))
    {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 1_000_000;
        // 4 pinned + 2 queued zombies — all accepted/last-active well past the
        // deadline (idle for 60 s). Every one is reap-eligible.
        const stale = now_ms - deadline_ms - 30_000;
        const snapshots = [_]cluster.InboundConnSnapshot{
            snap(stale, stale), snap(stale, stale), snap(stale, stale), snap(stale, stale),
            snap(stale, stale), snap(stale, stale),
        };
        const n = cluster.inboundReapCountForCapacity(&snapshots, inbound_workers, now_ms, deadline_ms);
        // MUST free at least one slot — never 0 while the pool is full of zombies.
        try std.testing.expect(n >= 1);
        // And must not exceed the number of actual zombies (no over-reaping).
        try std.testing.expect(n <= snapshots.len);
    } else {
        return error.InboundReapCountForCapacityNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-A.2) ACCEPT-TIME CLOCK: a QUEUED zombie that never acquired a worker is
// still reap-eligible — its idle clock runs from accept time. Pre-fix, a queued
// conn's clock only started at worker acquisition, so it could never be reaped
// while starved in the queue. Here last_activity == accepted (it never ran), and
// both are past the deadline → it MUST count as reap-eligible.
// ---------------------------------------------------------------------------
test "occupancy: a never-serviced queued zombie is reaped on its accept-time clock" {
    if (comptime @hasDecl(cluster, "inboundReapCountForCapacity") and
        @hasDecl(cluster, "InboundConnSnapshot"))
    {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 2_000_000;
        const accepted = now_ms - deadline_ms - 5_000; // accepted 35 s ago, never serviced
        // 4 active+pinned would be fine; here all 5 are queued/pinned zombies that
        // have done NOTHING since accept (last_activity == accepted).
        const snapshots = [_]cluster.InboundConnSnapshot{
            snap(accepted, accepted), snap(accepted, accepted), snap(accepted, accepted),
            snap(accepted, accepted), snap(accepted, accepted),
        };
        const n = cluster.inboundReapCountForCapacity(&snapshots, inbound_workers, now_ms, deadline_ms);
        // A conn idle-since-accept past the deadline is reap-eligible regardless of
        // worker ownership — so the sweeper frees capacity.
        try std.testing.expect(n >= 1);
    } else {
        return error.InboundReapCountForCapacityNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-A.3) GUARD (must stay GREEN post-fix): a healthy long-lived ACTIVE inbound
// conn with RECENT activity is NEVER reaped by the aggregate logic. A pool full
// of active conns is genuine load, not a churn wedge — reap-count must be 0.
// ---------------------------------------------------------------------------
test "occupancy: an active inbound conn with recent activity is never reaped" {
    if (comptime @hasDecl(cluster, "inboundReapCountForCapacity") and
        @hasDecl(cluster, "InboundConnSnapshot"))
    {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 3_000_000;
        // Long-lived (accepted 10 min ago) but ACTIVE 1 s ago — healthy. All 4
        // workers are busy with such conns: that is load, NOT a wedge.
        const accepted = now_ms - 600_000;
        const fresh = now_ms - 1_000;
        const snapshots = [_]cluster.InboundConnSnapshot{
            snap(accepted, fresh), snap(accepted, fresh), snap(accepted, fresh), snap(accepted, fresh),
        };
        const n = cluster.inboundReapCountForCapacity(&snapshots, inbound_workers, now_ms, deadline_ms);
        try std.testing.expectEqual(@as(usize, 0), n);
    } else {
        return error.InboundReapCountForCapacityNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-A.4) MIXED: 3 active conns + 1 idle zombie pinning the 4th worker, with a
// fresh active conn waiting. The single zombie MUST be reaped (free the 4th slot
// for the rebuilt leader conn) while the 3 active conns are untouched.
// ---------------------------------------------------------------------------
test "occupancy: one zombie among active conns is reaped, actives preserved" {
    if (comptime @hasDecl(cluster, "inboundReapCountForCapacity") and
        @hasDecl(cluster, "InboundConnSnapshot"))
    {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 4_000_000;
        const fresh = now_ms - 500; // active half a second ago
        const accepted = now_ms - 120_000;
        const zombie_stale = now_ms - deadline_ms - 1_000; // idle 31 s -> zombie
        const snapshots = [_]cluster.InboundConnSnapshot{
            snap(accepted, fresh), snap(accepted, fresh), snap(accepted, fresh),
            snap(accepted, zombie_stale), // the one pinned by a zombie
        };
        const n = cluster.inboundReapCountForCapacity(&snapshots, inbound_workers, now_ms, deadline_ms);
        // Exactly the one zombie is reapable — actives are never reaped, so the
        // count must be exactly 1 (frees the 4th slot, keeps the 3 live conns).
        try std.testing.expectEqual(@as(usize, 1), n);
    } else {
        return error.InboundReapCountForCapacityNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-A.5) FRESH-CONN SERVICEABILITY under a full zombie pool: the whole RC-A
// contract distilled. With all 4 workers pinned by zombies (accept-time clocks
// past the deadline), a freshly-accepted ACTIVE conn MUST be serviceable within
// the bounded budget — the sweeper reaps a zombie in time. Pre-fix this is FALSE
// (no accept-time clock, no independent sweeper) → candidate strands.
// ---------------------------------------------------------------------------
test "occupancy: a fresh active conn is serviceable within budget despite a full zombie pool" {
    if (comptime @hasDecl(cluster, "freshActiveConnServiceableWithin") and
        @hasDecl(cluster, "InboundConnSnapshot") and
        @hasDecl(cluster, "inbound_fresh_conn_service_budget_ms"))
    {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 5_000_000;
        const budget_ms = cluster.inbound_fresh_conn_service_budget_ms;
        const stale = now_ms - deadline_ms - 20_000; // all 4 workers: idle 50 s
        const snapshots = [_]cluster.InboundConnSnapshot{
            snap(stale, stale), snap(stale, stale), snap(stale, stale), snap(stale, stale),
        };
        try std.testing.expect(cluster.freshActiveConnServiceableWithin(
            &snapshots,
            inbound_workers,
            now_ms,
            deadline_ms,
            budget_ms,
        ));
    } else {
        return error.FreshActiveConnServiceableWithinNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-A.6) GENUINE LOAD is NOT a wedge: when all 4 workers are pinned by ACTIVE
// (non-zombie) conns, a fresh active conn is NOT immediately serviceable within
// the budget — there is nothing to reap. This pins the boundary so the fix does
// not pathologically reap live connections to make the predicate trivially true.
// ---------------------------------------------------------------------------
test "occupancy: genuine active load is not falsely serviceable (no live-conn reaping)" {
    if (comptime @hasDecl(cluster, "freshActiveConnServiceableWithin") and
        @hasDecl(cluster, "InboundConnSnapshot") and
        @hasDecl(cluster, "inbound_fresh_conn_service_budget_ms"))
    {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 6_000_000;
        const budget_ms = cluster.inbound_fresh_conn_service_budget_ms;
        const accepted = now_ms - 90_000;
        const fresh = now_ms - 200; // every worker active 200 ms ago
        const snapshots = [_]cluster.InboundConnSnapshot{
            snap(accepted, fresh), snap(accepted, fresh), snap(accepted, fresh), snap(accepted, fresh),
        };
        // No zombie to reap -> a fresh conn cannot jump the queue within budget.
        try std.testing.expect(!cluster.freshActiveConnServiceableWithin(
            &snapshots,
            inbound_workers,
            now_ms,
            deadline_ms,
            budget_ms,
        ));
    } else {
        return error.FreshActiveConnServiceableWithinNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-A.7) CROSS-ROUND ACCUMULATION (the A→B→C signature): simulate 3 back-to-
// back 4-kill churn rounds — 12 zombie arrivals on a realistic cadence with NO
// settle between rounds — and assert backlog does NOT grow monotonically. By the
// end of round C, with the sweeper draining on each pass, occupancy is back UNDER
// capacity within a bound. Pre-fix (clock from worker acquisition, no independent
// sweeper) the reapable count stays 0 across all rounds while occupancy only
// grows → this assertion fails.
//
// Model: each "round" lands 4 fresh zombies (a 4-kill round leaves 4 half-open
// inbound conns). Rounds are ~5 s apart (rapid k8s churn). At each post-round
// instant we ask the aggregate decision how many it would reap. With accept-time
// clocks, zombies from earlier rounds age past the 30 s deadline and become
// reapable; the contract is that the sweeper CAN drain them — so by a bounded
// time after the last arrival, ALL outstanding zombies are reap-eligible and the
// post-drain occupancy is < workers.
// ---------------------------------------------------------------------------
test "occupancy: 3 back-to-back 4-kill rounds do not grow the backlog monotonically" {
    if (comptime @hasDecl(cluster, "inboundReapCountForCapacity") and
        @hasDecl(cluster, "InboundConnSnapshot"))
    {
        const deadline_ms: i64 = 30_000;
        const round_gap_ms: i64 = 5_000; // rapid churn: rounds ~5 s apart
        const t0: i64 = 10_000_000;

        // 12 zombie arrivals: round A at t0, B at t0+5s, C at t0+10s, 4 each.
        // Each zombie is idle-since-accept (last_activity == accepted) — a half-
        // open peer never sends another frame.
        var snapshots: [12]cluster.InboundConnSnapshot = undefined;
        var i: usize = 0;
        var round: i64 = 0;
        while (round < 3) : (round += 1) {
            const arrive = t0 + round * round_gap_ms;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                snapshots[i] = snap(arrive, arrive);
                i += 1;
            }
        }

        // Evaluate at a bounded settle point AFTER the last arrival: one deadline
        // past round C's arrival plus a small reaper-tick slack. By here EVERY
        // outstanding zombie (incl. round C's) is past its idle deadline, so the
        // aggregate decision must be able to reap them ALL — driving occupancy
        // back under capacity. This is the non-monotonic recovery the bug denies.
        const last_arrival = t0 + 2 * round_gap_ms;
        const settle_ms = last_arrival + deadline_ms + 1_000;

        const reapable = cluster.inboundReapCountForCapacity(&snapshots, inbound_workers, settle_ms, deadline_ms);
        // All 12 are now stale -> all reap-eligible. The sweeper draining them
        // leaves occupancy at 0 (< workers): backlog did NOT accumulate.
        try std.testing.expectEqual(@as(usize, snapshots.len), reapable);

        // And the post-drain residual occupancy is strictly under capacity (the
        // A→B→C monotonic-degradation signature is broken).
        const residual_after_drain: usize = snapshots.len - reapable;
        try std.testing.expect(residual_after_drain < inbound_workers);
    } else {
        return error.InboundReapCountForCapacityNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-A.8) The fresh-conn service budget is SANE: positive, and well under one
// election timeout (so a rebuilt leader conn is serviced before a stranded
// candidate's election timer fires). Also far below the ~300 s QUIC idle timeout.
// ---------------------------------------------------------------------------
test "occupancy: fresh-conn service budget is positive and well under one election timeout" {
    if (comptime @hasDecl(cluster, "inbound_fresh_conn_service_budget_ms")) {
        const b = cluster.inbound_fresh_conn_service_budget_ms;
        try std.testing.expect(b > 0);
        // Must beat the election timer with margin (the whole point of RC-A).
        try std.testing.expect(b < election_timeout_ms);
        // And is obviously far below the QUIC idle timeout it replaces as the
        // effective recovery bound.
        try std.testing.expect(b < quic_idle_timeout_ms);
    } else {
        return error.InboundFreshConnServiceBudgetConstNotImplemented;
    }
}
