# Performance Audit — Phase 3 Deep Review

Anchored to `ping_c2=727 qps / p50=2.7ms / p99=3.4ms`; point_read c=8 extrapolation. **PerfScore** 0–10: 10 = ship now. Line numbers verified Phase 2.

## Top 15 (ranked by PerfScore × QPS headroom)

| # | Finding | File:Line | Root Cause | Expected Delta | Effort | Conf | Score |
|---|---------|-----------|------------|----------------|--------|------|------:|
| 1 | Per-row RLS alloc with no policy. `passesRLSFilter` → `nodePropertiesToRLSRow` (HashMap + N put) before engine-null check. ≥19 MATCH sites. | `execution/match_operations.zig:104-145`; `rls_value_bridge.zig:55-69` | Inverted fast-path | MATCH rows +30-80%; alloc −3-5× | S | conf | **10** |
| 2 | QUIC handler wake storm. 30+ handlers on 2ms `poll_cv`; pollLoop broadcasts every 500μs. In-code `PERF-P1-001`. | `quic_connection_handler.zig:329-337`; `quic.zig:389-404` | Broadcast-CV, no per-stream signal | p50 2.7→1.6ms; ping_c4 646→≥900 (+40%); one_hop c8 +15-25% | M | conf | **9** |
| 3 | TDE key reload per encrypt/decrypt. `loadKey` = getenv+dupe+64-hex, 8 sites. | `tde_file_encryption.zig:59-96, 135-143, 190-203` | No cached key/AES ctx | TDE 30→120+ MB/s; per-page 3μs→<100ns | S | conf | **9** |
| 4 | Per-query malloc on dispatch. `create(SubmittedTask)`+destroy per task — 1454/s at ping_c2. | `transport/thread_pool.zig:262-274` | No freelist | submit 500ns→≤50ns; QPS +3-5% ping | S | conf | **8** |
| 5 | All tasks → `.blocking` lane. CPU MATCH contends with I/O. | `transport/thread_pool.zig:203-214` | API has no lane param | fan_out/two_hop +10-20% c≥8 | S | conf | **8** |
| 6 | StorageAdapter Mutex on read-only lookups (5 accessors, tier-0). | `graph_storage_adapter.zig:668-750` | Mutex not RwLock | Linear scaling c≥8; +30-50% fan_out c=16 | M | conf | **8** |
| 7 | No per-request arena in match_operations. `checkPushedPredicates`/`checkNodeProperty`/`matchesEdgeProperties` call `evalExpr(allocator,…)` per row — ~5000 allocs/query. | `match_operations.zig:183-267, 864-946, 1542-1577` | No arena guard | Per-row −40-70% WHERE-heavy; error leaks fixed | S-M | conf | **8** |
| 8 | Per-stream heavyweight init: FederationManager + DistributedQueryPlanner + 3 HashMap catalogs — federation dead without `GEODE_CLUSTER_TOKEN`. | `quic_connection_handler.zig:704-745` | No cluster gate | Stream accept 200-500μs→<50μs | S | conf | **7** |
| 9 | Planner DP leaks PlanNodes. O(3^n) create, overwrite without free; n=8 ≈ 6561 retained. | `planner/cbo.zig:166-240` | No ctx arena; no free | Plan RSS −50-100×; p99 tail reduced | M | conf | **7** |
| 10 | `getEdgesByType` = 3 passes + `bufPrint` composite key. | `graph_store.zig:3021-3076` | String key; no null-tenant fast path | −30-50% type-filtered two_hop | S | conf | **6** |
| 11 | DRR scheduler O(N) scan + 256-sort per call. | `stream_scheduler.zig:111-184` | Full sort vs top-K heap | 5μs→1μs/call; up to 8% fan_out c=32 | M | conf | **6** |
| 12 | `checkPushedPredicates` re-walks WHERE AST per row. | `match_operations.zig:183-267, 879-884` | No compile-once-at-plan | 2× WHERE-heavy; composes with #7 | M | susp | **6** |
| 13 | WAL fsync per tick regardless of dirty. | `graph_store.zig:5184-5205`; `wal.zig:241-248` | No dirty atomic | Idle IOPS 1→0; SSD wear removed | S | conf | **5** |
| 14 | QUIC `writeAll` sleep-spins ~10s on flow-control block. Pins handler + pool slot. | `transport/quic.zig:705-728` | No CV on window update | p99 10s→sub-ms; HOL removed | M | conf | **5** |
| 15 | `nextMessage` WouldBlock counter not reset on activity — pairs with #2. | `quic_connection_handler.zig:282-356` | Counter reset only on read | Minor QPS; idle ctx-switch reduction | S | conf | **4** |

## Cross-cutting

**#1+#4+#7** compose: **p50 2.7→1.5-1.8ms, QPS +25-40% at c=2..8**, no I/O touch. **#2+#8** are the c≥4 wall — 727→646 ping is `poll_cv.broadcast` contention at handler count > 8 cores. HNSW query path clean. #6 stays within GAP-0278 hierarchy.

## Validation

1. Tracking allocator, `MATCH (n:L) RETURN n LIMIT 1000` × 10k: pre ≥20k allocs, post-#1 <100.
2. `perf record -F 999 -g` point_read c=8: `poll_cv.broadcast` + `nodePropertiesToRLSRow` top 10 pre; both drop post.
3. `iostat -x 1` idle 60s pre/post #13: write IOPS 1→0.
4. `make bench-tde` pre/post #3: ≥4× throughput.
5. `make loadtest-compare` c={1..16} after #1+#2+#3+#7 merged; save baseline only then.

## Out of scope (→ Phase 4)

HNSW build alloc; R-tree path; MVCC snapshot-vector; grpc bridge (opt-in); S3 multipart.
