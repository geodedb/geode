# perf/rcu-merge-prop-index — SHELVED

**Status:** parked, do not merge as-is
**Decided:** 2026-04-24
**Verification report:** [`optimize-report.md`](optimize-report.md)
**Author's prior validation:** [`../2026-04-24-sharding/RCU-MERGE-PROP-VALIDATION.md`](../2026-04-24-sharding/RCU-MERGE-PROP-VALIDATION.md)

## Why parked

Verification on a 56-core / 251 GB host confirmed and amplified the regression
the author called out himself: the RCU snapshot path is 5–20× slower than the
no-snapshot fallthrough at every measured thread count between 4 and 56,
because the single `MergePropSnapshot.refcount` cache line serialises every
reader. `bench-merge bulk_merge_update` is +14.8% slower on this host
(+28% on the author's host).

The RCU work is correct and unit-tested, but it competes with a *lock-free*
fallthrough — every `lookupMergeCandidate` call adds two atomic RMWs that
the existing `*const GraphStore` `StringHashMap.get` path doesn't pay. The
design's actual benefit (eliminating outer `mg.rwlock.lockShared` in
callers) requires Task 10, which is explicitly out of scope on this branch.

## What's worth keeping

The branch is a complete, correct foundation. If we ever reopen it, the
following primitives ship as-is:

- `MergePropSnapshot` RCU primitive (`src/graph_store_merge_snapshot.zig`)
- `verifyMergeCandidate` strong-verify helper
- `publishMergePropSnapshotIfDirty` writer-trigger plumbing
- `lookupMergeCandidateSnapshot` lock-free probe
- 16-reader stress test (`tests/test_merge_prop_snapshot_concurrency.zig`)
- Microbench harness (`benchmarks/merge_prop_snapshot_lookup/main.zig`)

## Resurrection criteria

Reopen this branch only when **all three** are true:

1. **Per-shard coordinator wiring has landed** (the existing plan
   `docs/superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md`).
   That plan removes the global `string_indexes_mutex` bottleneck and lets
   16 shard threads write in parallel. With that win in place, endpoint
   resolution may *become* the next bottleneck.
2. **A profile of the resharded workload shows endpoint resolution
   (`lookupMergeCandidate` / `lookupNodeByMergeKey` under
   `acquireGraphReadLock`) as a measurable hotspot** — not just
   hypothesised, measured.
3. **The single-cache-line refcount design is replaced** with one of:
   - Epoch-based reclamation (per-CPU epochs, no shared atomic on hot path)
   - Per-thread hazard pointers
   - Padded per-shard refcount arrays (one cache line per reader)

   Without (3), Task 10 inherits the same flatline this verification just
   measured.

## Why not just "fix the refcount and merge"?

Three reasons:

1. **No end-to-end win to gate against.** Without callers actually dropping
   `acquireGraphReadLock` (Task 10), the RCU path costs more and saves
   nothing. The bench-merge `bulk_merge_update` regression is the visible
   cost; the win is hypothetical.
2. **Sequencing.** The existing per-shard-coordinator plan is the
   highest-leverage ingest work today (target ≤ 60 s msft-graph; current
   cascade at 25–40 min). Doing fine-grained lookup optimisation while writes
   are still single-threaded per graph is optimising a non-bottleneck.
   Amdahl's law.
3. **Risk surface.** Task 10 also requires `nodes`-map RCU or per-shard
   rwlocks — otherwise readers race ShardedStore rehash on `nodes.get` and
   segfault (this is exactly what `d9790762` removed from the stress test).
   That's a coupled architectural change, not a localised perf tweak.

## What to do instead (next session)

The user-committed plan in
[`docs/superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md`](../../superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md)
is fully scoped (1272 lines, 11 tasks across 5 phases) and Phase 0
dependency is **satisfied** as of `ec5bfb26` — the pinned `graph_storage`
SHA `0ce15769` exports `ShardedGraphEngine`, `sharded_engine.SHARD_COUNT`,
and `sharded_store.shardIndex(u64)`. Phase 0 baseline-reproduction can
start immediately.

Minor plan-vs-reality drift to handle in Phase 0:

- The plan's grep expects `pub const SHARD_COUNT` at the package root.
  In the currently-pinned dep it lives at
  `graph_storage.sharded_engine.SHARD_COUNT`. Either bump upstream to
  re-export at root, or update the plan's import paths in Tasks 1–5.

## Branch hygiene

- Local worktree at `../geode-rcu-verify` can be removed:
  `git worktree remove ../geode-rcu-verify`
- The branch lives on the remote (`origin/perf/rcu-merge-prop-index`); do
  not delete it — this doc references its commits.
- No code on `main` depends on the branch.
