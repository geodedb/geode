# Phase 2 ingest validation — 2026-04-23

## Configuration

- Branch: `main` HEAD `210de668` (Phase 2 Task 6)
- Build: `zig build -Doptimize=ReleaseFast install`
- Server: `127.0.0.1:3144`, `GEODE_GROUP_COMMIT=1`, log-level=warn
- Client: `msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000`

## Result: REGRESSION vs 2026-04-23 morning baseline

Killed after ~19 min on the 3rd edge file — clear trend of per-edge-file
latency **3-4× slower** than the morning session with the
single-thread group-commit coordinator.

### Node phase (12m19s, 9350 nodes)

~32s per file regardless of size.  Dominated by per-file QUIC
reconnect cost (HELLO handshake + initial stream setup).  Identical
pattern to the morning session — not affected by Phase 2 changes.
This is the Phase 4 (client-side pipelining) domain.

### Edge phase (3 files done before kill)

| File | Rows | Morning baseline | Phase 2 current | Delta |
| --- | ---: | ---: | ---: | ---: |
| edges_activated_role | 65 | 31 s | ~1m40s (estimate) | **~3× slower** |
| edges_app_role_assignment | 400 | 32 s | ~1m48s | **3.4× slower** |
| edges_audited | 808 | 58 s | ~4m12s | **4.3× slower** |

Projected full run: **hours** (vs the morning session's ~40 min).

## Root cause

`ManagedGraph.string_indexes_mutex` introduced in Task 5 is held
across the ENTIRE `createNodeWithReservedIdAndGraph` /
`createEdgeWithGraph` call in the shard-locked helpers
(`bulkInsertNodeWithReservedId`, `bulkInsertEdgeWithIdsShardLocked`,
`bulkMergeNodeWithReservedId`).  Those functions include:

- Adapter vtable writes (engine persistence, WAL append, page dirty
  tracking)
- IdMap operations
- Label-index getOrPut + posting-list updates

Holding a single process-wide mutex across all this work means **16
shard threads contend on ONE mutex for every op**.  This produces
MORE contention than the pre-Phase-2 design (one coordinator thread,
one rwlock, 256-op batches under one fsync).  The sharded
coordinator's theoretical N-way parallelism is nullified by the
mutex scope.

Server log evidence: hundreds of `thread-pool deinit timed out
after 2000ms with 1 active tasks` warnings — per-connection pools
can't finish in 2 s because every `coord.submit()` parks behind
string_indexes_mutex.

## What to do

Three options:

### A. Narrow string_indexes_mutex scope (correct fix, invasive)

Restructure `createNodeWithReservedIdAndGraph` /
`createEdgeWithGraph` so:

- `string_indexes_mutex` holds ONLY around the outer-StringHashMap
  ops: `label_index.getOrPut`, `edge_type_index.getOrPut`,
  `graphs.put`.
- Everything else (adapter vtable writes, IdMap ops, posting-list
  inner-mutex updates) runs with just the shard locks.

Cost: substantial refactor of the existing functions or parallel
"_shard_safe" variants.  Correct long-term answer.

### B. Revert Phase 2 coordinator wiring (fast, preserves morning-baseline perf)

Revert `group_commit.zig` to the single-thread coordinator design
from the morning session (commit `2588e872`).  Keep the Task 4
(per-shard rwlocks on ManagedGraph) and Task 5 (`*WithReservedId`
helpers, `string_indexes_mutex`) primitives in place for future
work, but don't route production ingest through the sharded
coordinator.

Cost: 1 commit that re-files group_commit.zig to the pre-Phase-2
form with the old `GroupCommitCoordinator`.  Production reverts to
morning-session perf (~40 min, cascades on signed_in_from/_to).
The msft-graph ingest-ceiling goal is unachieved but production is
stable.

### C. Disable Phase 2 via env-gate at runtime

Don't revert; add a runtime kill-switch (e.g. `GEODE_SHARDED_COORD=0`
falls back to the old single-thread coordinator logic, which still
exists in the registry).  Operators choose per-deployment.

Cost: thread through two code paths in group_commit.zig.

## Recommended path

**B is the pragmatic choice right now.**  The Phase 2 design error
(mutex scope) requires a careful refactor of `createNodeWithGraph` /
`createEdgeWithGraph` that wasn't in the original plan's scope.
Revert the coordinator to the morning-baseline design (known good),
keep the Task-4/5 primitives for a proper Phase 2.1 follow-up, and
document the learning.

Alternative: proceed to Phases 3 / 4 (WAL flusher, client
pipelining) which are orthogonal to this mutex issue.  Phase 4
(client-side per-file reconnect cost) is the bigger win per the
node-phase measurement here.
