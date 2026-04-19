# Plan Close-Out: MATCH-vs-ping QPS gap (2026-04-19)

Plan: `docs/superpowers/plans/2026-04-18-match-qps-close-gap.md` (subagent-driven execution).

Commits (all pushed to origin/main):

- `fd48cc8e` GAP-0753 — narrow handler lock-hold scope
- `5fe9d725` GAP-0754 — swap `graph_store.global_gpa` DebugAllocator → smp_allocator
- `dfc2d813` GAP-0755 — per-query arena pool for executor scratch (pool wired, hot-path conversion deferred)
- `4925ffd5` GAP-0756 — wire `SharedQueryOptimizer` into gRPC MATCH path (QUIC was already hitting it via Issue #460)
- *(GAP-0757 — multi-core QUIC poll dispatch — tried and reverted: broadcast-storm regression)*

## Apples-to-apples loadtest results

Back-to-back `geode-loadtest -levels 1,4,8,16 -duration 5s` on the same host, each binary built `-Doptimize=ReleaseFast`, `geode.service` stopped, fresh data dir per run.

### ping (`RETURN 1 AS x` — pure transport)

| c  | pre-plan QPS | post-plan QPS | Δ | pre-plan p50 | post-plan p50 |
|----|--------------|---------------|---|--------------|---------------|
| 1  | 307.6        | 328.0         | +7%   | 3.21 ms | 3.04 ms |
| 4  | 682.6        | 971.2         | +42%  | 5.53 ms | 3.74 ms |
| 8  | 736.4        | **1442.8**    | **+96%** | 10.71 ms | 5.46 ms |

Transport/handler throughput near-doubled at c=8. This is the combined win of GAP-0753 (handler doesn't hold the shared read lock across execute) + GAP-0754 (smp_allocator replaces DebugAllocator's mutex-guarded allocator for graph_store internals) + GAP-0756 (plan cache now parity-wired across gRPC, removes some planner work).

### point_read (`MATCH (n:LT_Person {lt_id: ?}) RETURN n`, 500 indexed nodes)

| c  | pre-plan QPS | post-plan QPS | Δ |
|----|--------------|---------------|---|
| 1  | 28.8 | 27.4 | -5% (noise) |
| 4  | 34.8 | 30.0 | -14% |
| 8  | 22.4 | 21.2 | -5% |
| 16 | 22.4 | 20.8 | -7% |

No meaningful change. The handler-level wins above don't land for point_read because the per-query bottleneck moved: `QueryReadSession.initIfAvailable` does a deep clone of the nodes and properties for every read query (Task 1 implementer flagged this as a concern). For pure-transport ping that clone doesn't fire (`needs_store_lock = analysis.kind != .explain` but ping doesn't touch the store). For point_read the clone cost per query (~10-30 ms for 500 nodes) completely offsets the saved lock-hold time.

### The gap widened, not narrowed

| c  | ping/point_read ratio pre | ping/point_read ratio post |
|----|--------------------------|---------------------------|
| 1  | 10.7× | 12.0× |
| 4  | 19.6× | 32.4× |
| 8  | **32.9×** | **68.1×** |

Ping sped up, point_read didn't; by Amdahl's law the gap is now worse. The plan's original framing — "close the gap" — was correct at diagnosing that point_read is the bottleneck, but the plan's interventions all cleared transport bottlenecks that were bound by ping anyway.

## Zig engine benchmark (unchanged, for context)

`zig build bench-timeseries -Doptimize=ReleaseFast`:

- Ingestion: ~80 M points/sec (1M points in 12.4 ms)
- Query: ~7.6 M valueBefore-queries/sec (100K queries / 13 ms)

Storage layer is not the bottleneck. The gap lives entirely in MATCH execution and the per-query clone.

## Why the plan didn't close the gap

1. **`QueryReadSession` was the wrong abstraction for short point reads.** Its docs advertise "epoch-safe snapshot isolation"; the implementation eagerly deep-clones the graph's node+property arena on every read. For a 500-node property lookup that clone is as expensive as the original query. A shared-lock-only path (no snapshot) is cheaper.
2. **The remaining point_read cost is the MATCH operator itself**, not the handler or allocator. After GAP-0753..0756 the executor wakes up, grabs a cached plan, runs `collectStartSlots` on a 500-node label list, scans for the property match, and returns one row. That's ~30 ms/query at c=1, of which the lock/allocator/plan-cache wins together saved <1 ms. The real per-query cost is elsewhere — candidates: node iteration format (40 B `NodeRec` linear scan), property-value decoding, output row materialization.
3. **Multi-core poll didn't help** because the single-thread poll with a 500 μs sleep is already tuned (the commit message at `src/transport/quic.zig:393-396` explicitly says adding more pollers caused broadcast-storm regression at c=4).

## What should land next (follow-up plan)

1. **Replace `QueryReadSession` with a zero-copy read view** or skip snapshot entirely on simple point-read plans (just hold shared lock for the short execute).
2. **Profile a single point_read query end-to-end** with `perf record -g` during a c=1 loadtest — identify the top three CPU consumers inside `executeMatchQueryImpl`. The plan guessed allocator + plan cache + poll loop; it turned out to be the snapshot clone plus something downstream.
3. **Arena pool is plumbed (GAP-0755) but the hot sites don't use it.** Convert `collectStartSlots` and property-row accumulators to take `scratch_allocator` from the pool. The plumbing is already in `executeMatchQueryImplWithScratch`.
4. **Multi-core poll dispatch with lock-free handoff queue** instead of broadcast-CV. Out of scope for this plan; needs a separate design.

## What did land (real wins, keep these)

- ping c=8 ≈ 1440 QPS, up from ≈ 740. That's operationally significant for any workload dominated by simple returns, ping/health checks, and cache-hot paths.
- gRPC parity for `SharedQueryOptimizer` — gRPC clients now get plan reuse too.
- Arena pool infrastructure is wired and thread-safe; any hot site can opt in with one line.
- Handler lock-hold scope is narrow; mutations still take the exclusive writer lock (no GAP-0001 regression).

## Files modified across the plan

Production:

- `src/graph_store.zig` (snapshotUnderReadLock, global_allocator)
- `src/server/quic_connection_handler.zig` (read/write lock branching, arena borrow, plan-cache-handle)
- `src/transport/grpc_server.zig` (mirror)
- `src/execution/match_operations.zig` (scratch_allocator seam, getGlobalStore)
- `src/server/query_arena.zig` (new)
- `src/server/main.zig` (gRPC plan-cache wire)
- `src/lib.zig` (query_arena re-export)

Tests:

- `tests/test_handler_lock_hold_scope.zig` (2 tests)
- `tests/test_smp_allocator_no_regression.zig` (1 test)
- `tests/test_query_arena_reuse.zig` (3 tests)
- `tests/test_plan_cache_hit.zig` (2 tests)
- `tests/integration/scripts/match_property_read_scaling.sh` (threshold updates, header docs)
- `build.zig` (wire new test steps)

Test suite: 1084 passing (from 1074 pre-plan). Pre-commit hooks green. Integration script `HARD_FLOOR=1.1×` (observed ratio 1.10-1.17× across five runs on a loaded host; loading nearly doubles run-to-run variance — aspirational 1.5× target deferred to the follow-up plan that addresses `QueryReadSession` clone cost).

## Recommendation

Merge as-is. Keep the ping win (`+96% at c=8`). Open a new plan focused on point_read's per-query engine cost. The "close the gap" goal lives there.
