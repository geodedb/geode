# Sharded Coordinator Restoration — Design

**Status:** Ready for plan.
**Supersedes (for implementation purposes):** `docs/superpowers/specs/2026-04-24-per-shard-coordinator-wiring-design.md`.
**Relationship to the superseded spec:** v1 remains authoritative for *architectural intent* and *failure-mode analysis*. This v2 spec re-scopes the implementation after discovery that v1's per-shard-`label_index` recommendation targeted a struct (`ManagedGraph`) that does not own those fields (they live on the global `GraphStore`) and a mutex (`string_indexes_mutex`) that no longer dominates after commit `b061a238` narrowed its hold scope to the outer-`StringHashMap` `getOrPut` moment.

## Goal

Land `msft-graph seed --input /data/home/benji/eagleg-topology-data-20 --parallel --workers 16 --chunk-size 1000` in **≤ 70 s** wall-clock with **zero** `40001` errors and **zero** `serial fallback` occurrences in both the client log and the server log.

The ≤ 70 s target is pro-rata of the v1 ≤ 60 s target, recalibrated for the 17 %-larger `data-20` substitute (52 137 vs 44 558 statements). See the plan's "Dataset substitution" deviation note for provenance.

## Non-goals

- **No per-shard label / edge-type index sharding.** `string_indexes_mutex` is microsecond-held and no longer the dominant bottleneck after `b061a238`. Any follow-up sharding of the outer `StringHashMap` on `GraphStore` is out of scope.
- **No standalone `WalFlusher` component.** fsync amortisation is preserved by wrapping each shard-batch in one statement transaction — the same pattern the single-flusher coordinator uses today. A dedicated flusher may be revisited only if post-landing measurement proves the workload fsync-bound.
- **No env-gated dual-coordinator fallback.** The single-flusher `GroupCommitCoordinator` is replaced and deleted outright; there is no `Coordinator` union type and no `GEODE_SHARDED_COORD` toggle.
- **No changes to the QUIC / proto `40001` mapping.** The mapping stays; we eliminate the *cause* of conflict, not the mapping.
- **No changes to the RCU `merge_prop_index` snapshot work.** That plan lands independently.

## Architecture

Replace `src/storage/group_commit.zig`'s single-flusher `GroupCommitCoordinator` with a restored `ShardedCoordinator`. The coordinator's shape is pulled from commit `210de668` (pre-revert) and adapted for current HEAD.

Each per-graph coordinator owns:

- **16 shard worker threads** running on a dedicated lane of the shared `pooled.ThreadPool`.
- **16 per-shard queues** (`std.Deque(*ApplyOp)`), each protected by its own mutex + condvar.
- **Atomic counters** per shard (`ops_applied`, `batches`) for observability.
- **A shutdown atomic** that all workers check on every loop iteration.

`submit(op)` on the coordinator:

1. For `bulk_insert_node` and `bulk_merge_node`, pre-assign a node id via `store.reserveNodeId()` so routing is deterministic before enqueue.
2. For `bulk_match_create_edge` (added Phase 2.3, post-210de668), resolve `source_id` at submit time via `adapter.lookupNodeByMergeKey(...)` under `mg.rwlock` SHARED. On `error.SourceNodeNotFound`, mark the op as orphan-silent-skip (`op.result.done = 1`, `node_or_edge_id = 0`) and return immediately — do not enqueue. On success, stash the resolved id on the op so the worker can pass it to `bulkInsertEdgeWithIdsShardLocked` without another lookup. Shared-lock reads never block shard workers (which hold SHARED + per-shard EXCLUSIVE), so this is safe to do on the submitter's thread.
3. Compute `shard_idx = sharded_store.shardIndex(op.shardKey())` where `shardKey()` returns `assigned_id` for node inserts/merges, `source_id` for pre-resolved edge inserts, and the same resolved `source_id` for `bulk_match_create_edge`.
4. Push onto `shards[shard_idx].queue` under that shard's mutex; signal the shard's condvar.
5. Block the submitter on `op.result.done` via the existing `futexWaitUncancelable` protocol (unchanged).

`shardLoop(shard_idx)`:

1. Wait on the shard's condvar until queue length is non-zero or shutdown.
2. Pop up to `max_batch = 256` ops into a stack buffer.
3. Begin **one** statement transaction via `adapter.beginStatementTxn(graph_name)`.
4. For each op, dispatch to the existing shard-locked helpers on `StorageAdapter`:
   - `bulk_insert_node` → `bulkInsertNodeWithReservedId` (already takes `shard_locks[shardIndex(assigned_id)]` EXCLUSIVE internally)
   - `bulk_insert_edge` → `bulkInsertEdgeWithIdsShardLocked` (handles single-shard and cross-shard edges via ascending-index 2PC inside the helper)
   - `bulk_merge_node` → `bulkMergeNodeWithReservedId`
   - `bulk_match_create_edge` → `bulkInsertEdgeWithIdsShardLocked` (source_id already resolved at submit time — see `submit(op)` step 2; if `dst_id` also needs lookup, the worker resolves it under its already-held shard EXCLUSIVE lock via `adapter.lookupNodeByMergeKey`)
5. Commit the statement transaction (one `fsync` per shard-batch).
6. Wake every submitter in the batch via `op.result.done.store(1, .release)` + `futexWake`.

`getOrStartCoordinator(allocator, adapter, graph_name)` in `group_commit.zig` returns `*ShardedCoordinator` directly; there is no union dispatch layer. `submit(op)` is a method on `ShardedCoordinator`. Callers that today hold a `*GroupCommitCoordinator` by pointer are updated to hold `*ShardedCoordinator`; the `submit` signature is unchanged.

### Coordinator lifecycle

`init` spawns the 16 worker threads and transitions to ready. `deinit` stores `1` into the shutdown atomic, broadcasts every shard's condvar to wake idle workers, joins all 16 worker threads, drains and releases any ops still on the queue (best-effort — submitters blocked on those ops receive `error.Shutdown`), and frees owned memory.

`shutdownAllCoordinators` (existing helper) iterates the registry and calls `deinit` on each. Tests that start coordinators must call it in a `defer` block.

### Cross-shard edge contract

Cross-shard edges (source and target on different shards) are routed by `shardIndex(source_id)`. The source-shard worker calls `bulkInsertEdgeWithIdsShardLocked`, which acquires `shard_locks[source_idx]` EXCLUSIVE, then — only when needed — acquires `shard_locks[target_idx]` EXCLUSIVE in ascending-index order before touching adjacency structures on the target shard. Release order is the reverse. Deadlock avoidance is the helper's responsibility, not the coordinator's; the coordinator only guarantees that ops for a single `source_id` stay on one thread.

## MVCC routing invariant (thread-local-gated debug panic)

Under deterministic shard routing, two concurrent committing transactions should never touch the same resource, so `src/transactions/manager.zig:hasWriteWriteConflicts` should never return `true` when called by a shard worker. To catch routing bugs at test time without affecting unrelated paths:

1. Add a thread-local boolean `is_shard_worker` in the coordinator module (initial `false`).
2. `shardLoop` sets it to `true` at loop entry and clears it on exit (via `defer`).
3. In `hasWriteWriteConflicts`, when the function is about to return `true` AND `is_shard_worker == true` AND `@import("builtin").mode == .Debug`: call `std.debug.panic("routing invariant violated")`.
4. Release mode keeps the existing `error.SerializationFailure` path unchanged (defence in depth).

Non-worker threads (migrations, direct adapter calls, recovery, existing tests) are unaffected because `is_shard_worker` defaults to `false` on every non-worker thread.

## Test coverage

Three new tests, written red → green per task in the implementation plan:

### 1. Routing test (fast, pure coordinator)

`tests/test_sharded_coordinator_routing.zig`. Construct a coordinator, enqueue N ops whose `shardKey()` is chosen to hash to shard 0 only (by linearly searching for ids where `sharded_store.shardIndex(id) == 0`), then inspect per-shard queue depths via a `shardQueueDepthForTest(usize)` accessor guarded by `if (@import("builtin").is_test)`. Shard 0 should hold N ops; every other shard should hold 0.

### 2. Hub-node regression test

`tests/test_sharded_coordinator_hub_regression.zig`. Create one `:Group` hub node. Spawn 16 threads, each submitting 50 `MEMBER_OF` edges pointing INTO the hub (total 800). Assert:

- All 16 submitter threads return without error.
- `mg.edgeTypePostingList("MEMBER_OF")` holds exactly 800 ids on completion (uses whatever read helper currently exists; we do not change read paths here).
- Server log contains zero `SerializationFailure` or `40001`.

### 3. MVCC guard test (Debug-only)

`tests/test_txn_manager_routing_guard.zig`. Debug-only (`if (@import("builtin").mode != .Debug) return error.SkipZigTest`). Stubs out or skips a synthetic conflict construction; asserts the panic fires when `is_shard_worker` is set manually. If `std.testing.expectPanic` is not trivially available on Zig 0.16, mark the test as a placeholder (`return error.SkipZigTest` with a comment pointing at the runtime check). The real regression-catcher is Phase 5's zero-40001 assertion.

### Pre-existing test carry-over

`tests/test_sharded_coordinator.zig` (the Phase 2 Task 6 test registered in `build.zig:3355`) stays registered and must continue to pass. If any of its assertions were specific to the old single-flusher behaviour, they need updating — this is flagged for the implementer.

## Measurement and exit criterion

Two measurement passes gate this work:

### Baseline retry

The first baseline attempt this session failed (client timed out at 5 s; root cause not yet investigated). Before declaring Phase 5 complete, the baseline must be re-run with a robust server-ready healthcheck (poll `geode query "RETURN 1"` until success, with a 60 s cap, instead of a blind `sleep 5`). The retry commits `docs/performance/2026-04-24-sharding/phase2-plan-baseline.log` with the true pre-change wall-clock — needed as the comparison point for the win.

### Post-change exit run

After all implementation tasks land and `zig build test` is green:

```bash
pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
rm -rf /tmp/geode-phase2-final && mkdir -p /tmp/geode-phase2-final
zig build -Doptimize=ReleaseFast install

GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
  nohup zig-out/bin/geode serve \
    --data-dir /tmp/geode-phase2-final \
    --listen 127.0.0.1:3143 --log-level warn \
    > /tmp/geode-phase2-final/server.log 2>&1 &

# healthcheck-loop replacing sleep 5 …

zig-out/bin/geode query ... "CREATE GRAPH abs_eagleg"
time GEODE_DSN="..." msft-graph seed --input /data/home/benji/eagleg-topology-data-20 \
  --parallel --workers 16 --chunk-size 1000 | \
  tee docs/performance/2026-04-24-sharding/phase2-final-run.log
```

Pass criteria (all must hold):

- `time` wall-clock ≤ 70 s.
- `grep -c '40001\|serial fallback' phase2-final-run.log` prints `0`.
- `grep -c '40001\|Write lock acquisition timed out' /tmp/geode-phase2-final/server.log` prints `0`.

On pass, commit the evidence log and append a closure note to `docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md` pointing at this spec and the evidence log.

## Dependencies and external API surface

- **`graph_storage`** pinned at `0ce15769076d7c783c57d674e90182bc073853d1` on the `perf/sharded-engine` branch. Used symbols from this package, all via the `sharded_store` submodule:
  - `graph_storage.sharded_store.SHARD_COUNT: usize = 16`
  - `graph_storage.sharded_store.shardIndex(u64) usize`
  - `graph_storage.ShardedGraphEngine` (root re-export, used indirectly via `StorageAdapter.getShardedEngine`).

- **Geode primitives** used unchanged:
  - `pooled.ThreadPool` (for shard workers' execution lane)
  - `std.atomic.Value`, `std.Io.Mutex`, `std.Io.Condition` (Zig stdlib)
  - `std.Deque` (Zig stdlib)
  - `StorageAdapter.bulkInsertNodeWithReservedId`, `bulkInsertEdgeWithIdsShardLocked`, `bulkMergeNodeWithReservedId` (already shard-locked)
  - `std.Io.Threaded.global_single_threaded.io()` — the ambient IO handle these helpers expect.

## Risks and mitigations

**R1 — Hidden callers of the deleted `GroupCommitCoordinator` type.**
Mitigation: before deleting, `grep -rn 'GroupCommitCoordinator' src/ tests/` and update or remove every hit. Compiling clean is the verification.

**R2 — Pre-existing `test_sharded_coordinator.zig` assertions that were calibrated against the single-flusher revert.**
Mitigation: read the file carefully when restoring. Update assertions to reference `ShardedCoordinator` semantics. If any assertion is single-flusher-specific (e.g., "one queue depth"), rewrite or remove it.

**R3 — `ApplyOp.shardKey()` returning an uninitialised `assigned_id` for node/merge ops.**
Mitigation: `submit(op)` performs the `store.reserveNodeId()` before enqueue, so by the time the worker sees the op, `assigned_id` is set. Unit-test this in the routing test by asserting `op.assigned_id != 0` after `submit` returns.

**R4 — Cross-shard edge deadlock.**
Mitigation: delegate to `bulkInsertEdgeWithIdsShardLocked`, which already implements ascending-index 2PC acquisition. Do not re-implement locking in the coordinator.

**R5 — fsync regression if the per-shard batch-txn isn't actually one fsync.**
Mitigation: the statement-transaction path is already one-fsync-per-txn on HEAD (that's how the single-flusher amortises). Verify via strace or by reading the adapter's `beginStatementTxn` / `commitStatementTxn` path — no code change is needed to get the amortisation, only the correct usage pattern.

**R6 — Baseline flake masking the win.**
Mitigation: fix the baseline's healthcheck before collecting numbers. Both baseline and post-change runs use the same healthcheck helper.

## Exit criteria recap

- `ShardedCoordinator` restored; `GroupCommitCoordinator` deleted; `zig build test` green.
- Three new tests pass; pre-existing tests unchanged or updated-and-passing.
- MVCC routing invariant in place with thread-local gate; no false-positive panics in test suite.
- Baseline run committed with true wall-clock number.
- Exit-criterion run completes in ≤ 70 s with zero `40001` and zero `serial fallback`.
- `PHASE2-SUMMARY.md` closure note appended.

## References

- Superseded design: `docs/superpowers/specs/2026-04-24-per-shard-coordinator-wiring-design.md`.
- Superseded plan: `docs/superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md` (contains the dataset substitution + API-path reconciliation notes that this spec inherits).
- Source commit for restoration: `210de668` (pre-revert `ShardedCoordinator`).
- Evidence carry-over: `docs/performance/2026-04-24-sharding/phase2-4-run.log` (last known 40001-cascade measurement before today's baseline attempt).
