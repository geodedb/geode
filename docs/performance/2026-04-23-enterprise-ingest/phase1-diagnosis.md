# Phase 1 diagnosis — top-3 per-statement cost drivers

**Date:** 2026-04-23
**Build:** R13 + Task 1 instrumentation (commit 63f8333f)
**Evidence:** `phase1-timing-breakdown.txt` (60 s msft-graph sample, 723 statements, users.jsonl/devices.jsonl phase, 16 workers)

## TL;DR

The 3.2 ms p50 `execute` floor is **not** parse + plan + audit as the plan initially hypothesised — those already run outside the critical section (post R6 + `SharedAstCache` + `shared_opt.optimizeQuery`). Confirmed by direct code inspection of `src/server/quic_connection_handler.zig`:

| Lines | Work | Inside mg.rwlock? |
| --- | --- | --- |
| 2204-2240 | Parse (via `SharedAstCache.getOrParse`) | ❌ before lock |
| 2246 | `analyzeProgram` | ❌ before lock |
| 2316 | Plan optimisation (`shared_opt.optimizeQuery`) | ❌ before lock |
| 2454 | `acquireGraphWriteLockCancelable` → `markLockAcquired` | — critical section start |
| 2828 | `executeProgramWithContext` (the mutation work) | ✅ inside |
| 2834 | `markExecuteDone` | — critical section end (execute) |
| 2857 | `rebuildPendingIndexes` | ❌ after `releaseGraphLock` (GAP-0511) |
| 2874 | Post-result RLS filter | ❌ after |
| 2904 | Schema response + page send | ❌ after |
| 2818 | `auditQueryExecution` (non-PROFILE path) | ❌ after |

So the measured 3.2 ms p50 **is** `executeProgramWithContext` for a MERGE, not hoist-able via Phase-2 plan Task 4-6.  Those tasks (hoist parse/plan/audit/RLS) are already partially or fully done; keeping them in the plan would be a no-op for Phase 1 evidence. Retire them or re-target them (see *Plan revision* below).

## Top-3 drivers (by observed absolute ns, per-statement)

### Driver #1 — Per-graph write lock is fully exclusive for 3.2 ms per statement

- **Source line:** `src/server/quic_connection_handler.zig:2452` — `graph_store.acquireGraphWriteLockCancelable(query_graph_name, deadline)`.
- **Observation:** `lock_wait_ms` p50 = 1.06 / p95 = 60.2 / max = 1067. On a single hot graph with 16 workers, 15 of them are always blocked on the `mg.rwlock`.
- **Why:** `ManagedGraph.rwlock` is acquired in exclusive-writer mode for the *entire* `executeProgramWithContext` window. Even though the global `g_store_rwlock` is shared (post-R6), the per-graph lock forces single-writer across all 16 QUIC stream-worker pool threads hitting `abs_eagleg`.
- **Ceiling it imposes:** single-graph write throughput = 1 / execute_p50 ≈ 310 stmts/sec regardless of worker count. Actual aggregate observed in R13 ingest was ~5.9 stmts/s — i.e. **lock amplification ≈ 50×**, dominated by the R2 back-off tail (driver #3).
- **Mapping to plan:** Phase 4 Tasks 14-18 (two-phase locking: read MATCH under shared lock, write apply under exclusive lock; per-posting-list mutex for the label index).

### Driver #2 — `executeProgramWithContext` costs 3.2 ms per MERGE (the per-statement floor)

- **Source line:** `src/server/quic_connection_handler.zig:2828` — `execution.executeProgramWithContext(gpa, &parse_result.program, exec_context)`.
- **Observation:** `execute_ms` p50 = 3.23 / p95 = 7.05 / max = 27.26. This is a per-MERGE-statement floor, not a contention artefact.
- **What's actually in there** (via `src/execution/crud_operations.zig` path from prior R8-R13 investigation):
  - AST traversal + binding resolution
  - `merge_prop_index` probe + insert (should be O(1) hash)
  - `putNodeTxn` / `putPropertyTxn` per property (msft-graph user: ~5 properties ⇒ 5 hash inserts + txn-buffer appends)
  - Adjacency list setup (node-type dependent)
  - Schema-catalog label bookkeeping
  - **NOT** fsync (R9 session txn batches; adapter joins session txn — verified in bench: create_edge already at 1 fsync floor)
  - **NOT** pending_index_rebuilds (deferred to post-lock, GAP-0511)
- **Ceiling it imposes:** 3.2 ms × 16 workers serialised = 51 ms ideal per round of 16 MERGE statements. Over 677 user MERGEs: 677 ÷ 16 ≈ 43 rounds × 3.2 ms ≈ 135 ms serialised-executor ideal. **Observed 32 s** ⇒ executor is ~240× slower than ideal; driver #1 (lock wait) supplies the ~50× amplification, and the 3.2 ms floor supplies the ~4.7× over raw work.
- **Mapping to plan:** Phase 3 Tasks 10-13 (bulk-ingest pattern detection + fast-path dispatch that bypasses the general executor for msft-graph's very regular shapes: single-label CREATE/MERGE node with fixed property map, and MATCH+CREATE edge with exact-match endpoints).

### Driver #3 — R2 cancelable-lock back-off ladder amplifies p95 tail

- **Source line:** `src/storage/graph_storage_adapter.zig` (acquireGraphWriteLockCancelable loop — R6 widened 100 µs → 1-20 ms back-off).
- **Observation:** p50 lock_wait = 1.06 ms (matches the initial back-off floor). p95 = 60.2 ms, max = 1067 ms — these come from repeated back-off retries when the lock is held by a slow MERGE.
- **Why:** when worker #2 wakes from `std.time.sleep(1ms)` and finds the lock still held, it doubles its back-off (→ 2 ms → 4 ms → … → 20 ms cap). Over 16 workers this creates a ladder where workers 8-16 can accumulate ~30-60 ms of pure sleep even when the holder only needed 3 ms of real work. Amplifies *on top of* driver #1.
- **Mapping to plan:** Phase 5 Task 19 (group-commit coordinator — batches fsync across multiple write-holders in one round) *and* Phase 4 critical-section shrink (so back-off expires in 1-2 ms instead of 20 ms). Also re-examine: can the initial back-off be 100 µs again once the critical section is < 500 µs?

## Plan revision (proposed)

Given that parse/plan/audit/RLS are already outside the critical section, these plan tasks need to change shape:

| Task | Original intent | Revised action |
| --- | --- | --- |
| Task 4 "hoist parse + plan outside write lock" | Implement hoist | **DROP** — already done. Add regression test that asserts `SharedAstCache.getOrParse` is called before `acquireGraphWriteLockCancelable` to prevent regressing. |
| Task 5 "move audit.logEvent outside write lock" | Implement move | **DROP** — already done (line 2818 is post-release). Add regression test. |
| Task 6 "skip RLS filter when mutation has no rows" | Implement gate | **KEEP** — `applyAlgorithmRLSFilter` (line 2842) currently runs *before* lock release for algorithm results; `applyRLSFilter` (line 2874) runs *after* but still allocates on empty `exec_result.rows`. Gate both on `exec_result.rows.len > 0`. Minor win (µs), still worth it for the 0-row mutation path. |
| Task 7 "GEODE_BULK_INGEST=1 skip undo-log appends" | Add env var | **KEEP** — the undo-log append is the next likely contributor to the 3.2 ms floor once the fast-path (Task 11-12) is in. |
| Task 8 "consolidate pending_index_rebuilds per Geode txn" | Consolidate | **KEEP** — `rebuildPendingIndexes` at line 2857 runs once per mutation even inside a session txn; batching by session txn would amortise across 38+ statements. |

Phase 3 and Phase 4 plans stand as-is — they target the real drivers.

## Next step

Proceed to Phase 2 with the revised task set:

- Task 6 (RLS empty-result gate) — small win, easy.
- Task 7 (GEODE_BULK_INGEST undo-log skip) — prerequisite for Task 10-12 fast-path.
- Task 8 (pending_index_rebuilds consolidation by session txn) — medium win.
- Tasks 4 and 5 become regression tests (added to Task 9 validation).

Then attack the real ceiling in Phase 3 (fast-path dispatch) and Phase 4 (two-phase lock).
