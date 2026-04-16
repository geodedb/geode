# Performance Audit — Phase 2 Red-Flag Scan

Read-only grep + targeted reads over hot-path files from Phase 1. No product code modified.

## Top 15 Red Flags

| # | Finding | File:Line | Sev | Confidence |
|---|---------|-----------|----:|-----------|
| 1 | Per-row RLS alloc in MATCH: `passesRLSFilter` calls `nodePropertiesToRLSRow` → `StringHashMap.init` + N `put()` per node even when no policy active. ~19 MATCH sites. | `src/execution/match_operations.zig:131`; `src/security/rls_value_bridge.zig:55-69` | HIGH | confirmed |
| 2 | Per-query heap alloc: `allocator.create(SubmittedTask)` on every `pool.submit` → malloc/free on hot dispatch. | `src/transport/thread_pool.zig:262-274` | HIGH | confirmed |
| 3 | All queries use `.blocking` lane — CPU-bound MATCH contends with I/O on one lane. | `src/transport/thread_pool.zig:203-206` | HIGH | suspected |
| 4 | Planner DP leaks PlanNodes: `dpEnumerateJoinOrders` allocates `2^n` tables + `ctx.allocator.create(PlanNode)` per partition (~3^n), no free of unused joins. | `src/planner/cbo.zig:166-240` (L214) | HIGH | confirmed |
| 5 | `getEdgesByType` triple-passes + `bufPrint("{s}:{s}")` composite key per call. | `src/graph_store.zig:3021-3076`; caller `match_operations.zig:1639` | MED | confirmed |
| 6 | Handler busy-wait on QUIC reads: `nextMessage` loops WouldBlock with 2ms `waitForPoll` / 100μs `nanosleep` up to 5min; 500μs poll-CV broadcast. Code flags as c4-regression cause. Likely ping_c4 727→646 qps. | `src/server/quic_connection_handler.zig:282-356`; `src/transport/quic.zig:389-404` | HIGH | confirmed |
| 7 | Per-stream heavyweight init: every accept allocates 3 StringHashMap catalogs + SessionState + FederationManager + DistributedQueryPlanner — federation is dead code without `GEODE_CLUSTER_TOKEN`. | `src/server/quic_connection_handler.zig:704-745` | HIGH | confirmed |
| 8 | DRR scheduler O(N) double-HashMap scan + 256-entry sort per call. | `src/transport/stream_scheduler.zig:111-184` | MED | confirmed |
| 9 | 5 filter calls per edge row, no short-circuit on RLS-disabled common case. | `src/execution/match_operations.zig:1543-1575, 1649, 1659` | MED | confirmed |
| 10 | TDE reloads key per encrypt/decrypt: `loadKey()` → `getenv` + `dupe` + parse 64 hex every call. Blocks 30 MB/s TDE target. | `src/storage/tde_file_encryption.zig:106, 135, 149, 197, 250, 279, 328, 350` | HIGH | confirmed |
| 11 | WAL fsync per persistence tick regardless of dirty flag; idle server fsync-spams. | `src/graph_store.zig:5201-5205`; `src/wal.zig:241-248` | MED | confirmed |
| 12 | QUIC `writeAll` sleep-spin up to 10s on flow-control block; pins handler slot. | `src/transport/quic.zig:705-728, 1063-1090, 1120-1187` | MED | confirmed |
| 13 | StorageAdapter Mutex on read-only lookups — 7 read-heavy accessors serialize on one tier-0 Mutex. | `src/storage/graph_storage_adapter.zig:669-750` | HIGH | confirmed |
| 14 | Full-scan fallbacks + `evalExpr(allocator,…)` per property per row. | `src/execution/match_operations.zig:900-946, 1670-1722, 1740-1763, 6122-6146` | MED | confirmed |
| 15 | `checkPushedPredicates` re-walks WHERE AST per row with allocating `evalExpr`; should compile once at plan time. | `src/execution/match_operations.zig:183-267, 879-884` | MED | suspected |

## Notes

- No tier inversions in hot paths; finding #13's mutex is tier-0 correct but too wide.
- HNSW `searchVectorF32/I32` clean (one dim-bounded conversion alloc in I32 path).
- `match_log.warn` fires once per query, not per row — not a red flag.
- ~200 alloc/dupe/create sites in `match_operations.zig`; confirm whether MATCH end-to-end uses a per-request arena.
- ping_c4 regression hypothesis: findings #2, #3, #6, #7 are the likely drivers.

## Verification for Phase 3

1. `perf record -g` flamegraph on `point_read`/`one_hop` at c=4/8/16.
2. Allocator-tracking build to quantify per-query allocs.
3. `iostat -x 1` during idle for finding #11 fsync rate.
4. Baseline `point_read`/`one_hop`/`two_hop`/`fan_out`; `baseline.jsonl` currently has `ping` only.
5. Install `hyperfine` for statistical regression comparison.
