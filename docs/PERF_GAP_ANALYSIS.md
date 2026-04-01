# Performance Gap Analysis

Last updated: 2026-04-01

## Summary

- Total findings: 30
- Open: 0
- Closed / Implemented: 23
- Closed (Won't Do / Sufficient): 7 (1 transport + 6 migration engine)
- Blocked: 0

Previous 17 findings (2026-02-17 audit) all resolved. March 2026 audit added 7 new findings -- all 7 closed 2026-03-13. April 2026 migration engine audit added 6 new findings (1x P2, 5x P3) -- all closed Won't Do 2026-04-01 (unmeasurable benefit at realistic migration counts).

### Top 5 Open Risks (by PerfScore)

No open performance risks. All migration engine findings closed as Won't Do (unmeasurable benefit at realistic migration counts).

## Stack-Ranked Findings

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|---|
| 1 | P0 | 100 | AST cache initialized but not wired into parse hot path | Query exec | `src/server/quic_connection_handler.zig:701` | [#444](https://gitlab.com/devnw/codepros/geode/geode/-/issues/444) | SharedAstCache wired into parse hot path via `parse_blk:` labeled block; all post-parse functions accept `*const ParseResult`, no ownership refactor needed | Closed / Implemented |
| 2 | P0 | 100 | Full graph serialization on every commit | Storage | `src/graph_store.zig:2403` | [#445](https://gitlab.com/devnw/codepros/geode/geode/-/issues/445) | WAL (`src/wal.zig`) captures mutation deltas via graph_store callback; persistence loop syncs WAL on every wake (O(delta)), full checkpoint only when byte threshold exceeded (16MB default); crash recovery replays WAL after last checkpoint; CRC32 integrity validation detects torn writes | Closed / Implemented |
| 3 | P0 | 80 | Per-result string duplication in protobuf serialization | Serialization | `src/server/proto_util.zig:340` | [#446](https://gitlab.com/devnw/codepros/geode/geode/-/issues/446) | ArenaAllocator wraps buildDataPage+buildStatus+send scopes at all QUIC and gRPC data page call sites; per-value string dups become bump allocations, individual frees become no-ops, arena bulk-frees after send | Closed / Implemented |
| 4 | P0 | 80 | Busy-wait polling in QUIC reader loop | Transport | `src/server/quic_connection_handler.zig:145` | [#447](https://gitlab.com/devnw/codepros/geode/geode/-/issues/447) | Exponential backoff replaced fixed busy-wait | Closed / Implemented |
| 5 | P0 | 60 | O(n) column type inference scans all rows | Serialization | `src/server/proto_util.zig:320` | [#448](https://gitlab.com/devnw/codepros/geode/geode/-/issues/448) | Type inference now samples first 10 rows (`@min(rows.len, 10)`) | Closed / Implemented |
| 6 | P1 | 64 | O(V^2) BFS dequeue via linear ArrayList behavior | Graph algos | `src/graph/traversal_bfs.zig:30` | [#449](https://gitlab.com/devnw/codepros/geode/geode/-/issues/449) | Queue front-index/ring behavior removes linear memcopy dequeue cost | Closed / Implemented |
| 7 | P1 | 64 | O(m*n) quadratic edge deduplication | Graph store | `src/graph_store.zig:1655` | [#450](https://gitlab.com/devnw/codepros/geode/geode/-/issues/450) | Hash-based dedup path replaces nested scan | Closed / Implemented |
| 8 | P1 | 60 | Per-node string allocation in label index | Graph store | `src/graph_store.zig:727` | [#451](https://gitlab.com/devnw/codepros/geode/geode/-/issues/451) | Stack `bufPrint` probe before heap allocation | Closed / Implemented |
| 9 | P1 | 60 | Plan cache initialized but never consulted | Query exec | `src/server/quic_connection_handler.zig:455` | [#452](https://gitlab.com/devnw/codepros/geode/geode/-/issues/452) | Real `generateRealPlan()` walks AST to produce scan/filter/sort/limit/path_expand operators with cost estimates driven by store statistics; `OptimizerHints` (scan strategy, index preference, estimated rows) flow through `ExecutionContext`; schema epoch invalidation evicts stale plans on DDL | Closed / Implemented |
| 10 | P1 | 60 | Global mutex on gRPC session store | Transport | `src/transport/grpc_server.zig:102` | [#453](https://gitlab.com/devnw/codepros/geode/geode/-/issues/453) | RwLock substitution enables concurrent readers | Closed / Implemented |
| 11 | P1 | 48 | Thread pool spin-sleep when idle | Transport | `src/transport/thread_pool.zig:108`; `src/transport/thread_pool.zig:274` | [#454](https://gitlab.com/devnw/codepros/geode/geode/-/issues/454) | Added condition-variable wait path with wake signaling for submit/complete/shutdown | Closed / Implemented |
| 12 | P2 | 48 | HNSW `knnSearch` computed distances twice | Index | `src/index/hnsw.zig:399` | [#455](https://gitlab.com/devnw/codepros/geode/geode/-/issues/455) | Added distance-returning search path to avoid duplicate compute | Closed / Implemented |
| 13 | P2 | 36 | O(N) LRU eviction in AST/plan caches | Query exec | `src/server/query_ast_cache.zig:102` | [#456](https://gitlab.com/devnw/codepros/geode/geode/-/issues/456) | Intrusive doubly-linked list (lru_prev/lru_next keyed by hash) added to QueryAstCache, SharedAstCache, and QueryPlanCache; eviction removes tail in O(1), access promotes to head in O(1); SharedAstCache walks backward from tail skipping ref_count > 0 | Closed / Implemented |
| 14 | P2 | 36 | O(N) linear stream removal in QUIC | Transport | `src/transport/quic.zig:561`; `src/transport/quic.zig:605` | [#457](https://gitlab.com/devnw/codepros/geode/geode/-/issues/457) | Added stream `tracking_index` + swap-remove index repair for O(1) removal | Closed / Implemented |
| 15 | P2 | 36 | memcpy buffer compaction per message | Transport | `src/server/quic_connection_handler.zig:191` | [#458](https://gitlab.com/devnw/codepros/geode/geode/-/issues/458) | Existing heuristic is sufficient: compaction triggers only at 4KB+ consumed or 50%+ buffer fill; memcpy overhead negligible for typical message sizes | Closed (Won't Do: current heuristic adequate) |
| 16 | P2 | 36 | Exponential plan enumeration without early stop | Planner | `src/planner/enumerator.zig:32` | [#459](https://gitlab.com/devnw/codepros/geode/geode/-/issues/459) | Pruning logic already existed but was disabled; enabled `enable_prune: true` default with conservative 4x prune_factor | Closed / Implemented |
| 17 | P2 | 32 | Per-connection optimizer (no sharing) | Query exec | `src/server/quic_connection_handler.zig:455` | [#460](https://gitlab.com/devnw/codepros/geode/geode/-/issues/460) | `SharedQueryOptimizer` in `query_plan_cache.zig` provides thread-safe cross-connection plan reuse with Mutex + ref-counting + O(1) LRU eviction; `SharedPlanHandle` prevents eviction while in use; schema epoch invalidation ensures fresh plans after DDL; wired into `InitContext` alongside `SharedAstCache` | Closed / Implemented |

### March 2026 Audit — New Findings

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|---|
| 18 | P0 | 90 | N² binding clone in multi-chain MATCH joins — HashMap.clone() per edge match | Query exec | `src/execution/match_operations.zig:1343-1443` | [#557](https://gitlab.com/devnw/codepros/geode/geode/-/issues/557) | Pre-sized clone HashMap with `ensureTotalCapacity(count + 2)` to eliminate rehash during clone; pre-sized `new_bindings` ArrayList based on current bindings count | Closed / Implemented |
| 19 | P1 | 64 | Full node scan fallback when MATCH pattern has no labels | Query exec | `src/execution/match_operations.zig:1264-1302` | [#558](https://gitlab.com/devnw/codepros/geode/geode/-/issues/558) | Added right-label index path (use `getNodesByLabels` on right labels when left labels absent); added edge-type scan path (use `getEdgesByType` when relationship type present); full scan only when no labels AND no rel type | Closed / Implemented |
| 20 | P1 | 60 | WAL per-record unbuffered writes — multiple syscalls per mutation | Storage | `src/wal.zig:223-282` | [#559](https://gitlab.com/devnw/codepros/geode/geode/-/issues/559) | Assembled record (header+payload+crc) into single buffer before `writeAll`; plaintext uses stack buffer ≤64KB, heap fallback for larger; TDE path combines len_prefix+encrypted into single write | Closed / Implemented |
| 21 | P1 | 56 | Per-row environment allocation in MATCH pipeline | Query exec | `src/execution/match_operations.zig:1454-1493` | [#560](https://gitlab.com/devnw/codepros/geode/geode/-/issues/560) | Hoisted `env_names` and `env_values` ArrayLists outside the binding loop; reuse via `clearRetainingCapacity()` per iteration; pre-sized rows ArrayList to `bindings.items.len` | Closed / Implemented |
| 22 | P2 | 42 | O(M×N×L) label string comparison — no label interning | Query exec | `src/execution/pattern_helpers.zig:246-258` | [#561](https://gitlab.com/devnw/codepros/geode/geode/-/issues/561) | Added pointer equality fast-path (`ptr == ptr and len == len`) before byte comparison in `matchesLabels`; replaced inline label check in OPTIONAL MATCH with shared helper | Closed / Implemented |
| 23 | P2 | 36 | WAL truncation is O(n) full file rewrite | Storage | `src/wal.zig:425-500` | [#562](https://gitlab.com/devnw/codepros/geode/geode/-/issues/562) | Added early exit for `up_to_lsn == 0`; pre-sized `kept` buffer from file end position instead of 4096 | Closed / Implemented |
| 24 | P2 | 32 | GroupBy HashMap allocation churn — per-query HashMap without reuse | Query exec | `src/execution/match_operations.zig:852` | [#563](https://gitlab.com/devnw/codepros/geode/geode/-/issues/563) | Pre-sized with `ensureTotalCapacity` at 5 GroupBy locations (heuristic: 25% distinct groups or min 16); addressed via #552 | Closed / Implemented |

### April 2026 Audit -- Migration Engine (`src/migration/mod.zig`)

Context: Admin-time CLI tool. Dominant cost is QUIC round-trip (~1.3-1.9s per migration). No benchmarks exist. Reviewer consensus: none of these represent real bottlenecks at any realistic migration count (<10K).

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|---|
| 25 | P2 | 24 | Repeated full ledger load/parse -- `loadLedger` called by every public operation (7 call sites) | Migration | `src/migration/mod.zig:165-200` (7 call sites: L321, L378, L409, L508, L548, L563) | [#577](https://gitlab.com/devnw/codepros/geode/geode/-/issues/577) | Not recommended: caching adds complexity for negligible gain vs QUIC round-trip | Closed (Won't Do) |
| 26 | P3 | 16 | `applyUpMigrations` saves ledger only at end -- partial progress lost on crash | Migration | `src/migration/mod.zig:345-369` | [#594](https://gitlab.com/devnw/codepros/geode/geode/-/issues/594) | Already covered by GAP-0280 errdefer fix for crash safety | Closed (Won't Do) |
| 27 | P3 | 4 | O(N*R) quadratic scan in `applyUpMigrations` -- `versionExists` per name | Migration | `src/migration/mod.zig:328-335` | [#579](https://gitlab.com/devnw/codepros/geode/geode/-/issues/579) | Not recommended: HashMap overhead exceeds scan cost at realistic counts | Closed (Won't Do) |
| 28 | P3 | 4 | O(F*R) quadratic scan in `statusReport` -- ledger scan per file | Migration | `src/migration/mod.zig:447-464` | [#582](https://gitlab.com/devnw/codepros/geode/geode/-/issues/582) | Not recommended: unmeasurable benefit at realistic counts | Closed (Won't Do) |
| 29 | P3 | 4 | O(M*R) quadratic scan in `checksumValidate` -- ledger scan per manifest line | Migration | `src/migration/mod.zig:531-538` | [#584](https://gitlab.com/devnw/codepros/geode/geode/-/issues/584) | Not recommended: HashMap overhead exceeds scan cost at realistic counts | Closed (Won't Do) |
| 30 | P3 | 4 | `planDryRun` sort calls `parseVersion` per comparison instead of using pre-parsed `.version` field | Migration | `src/migration/mod.zig:587-592` | [#589](https://gitlab.com/devnw/codepros/geode/geode/-/issues/589) | Unmeasurable improvement | Closed (Won't Do) |

## Findings by Area

- Query execution: `#444` (Closed), `#452` (Closed), `#456` (Closed), `#460` (Closed), `#557` (Closed), `#558` (Closed), `#560` (Closed), `#561` (Closed), `#563` (Closed)
- Storage/graph: `#445` (Closed), `#449` (Closed), `#450` (Closed), `#451` (Closed), `#559` (Closed), `#562` (Closed)
- Serialization: `#446` (Closed), `#448` (Closed)
- Transport/concurrency: `#447` (Closed), `#453` (Closed), `#454` (Closed), `#457` (Closed), `#458` (Closed/Won't Do)
- Planner/index: `#455` (Closed), `#459` (Closed)
- Migration: `#577` (Won't Do), `#579` (Won't Do), `#582` (Won't Do), `#584` (Won't Do), `#589` (Won't Do), `#594` (Won't Do)

## Related Open Performance Bugs (tracked separately)

| Issue | Title | Severity | Relates to |
|-------|-------|----------|------------|
| [#538](https://gitlab.com/devnw/codepros/geode/geode/-/issues/538) | OOM on large-graph ingest | High | Storage memory |
| [#539](https://gitlab.com/devnw/codepros/geode/geode/-/issues/539) | WAL grows unboundedly across restarts | High | #559, #562 (WAL write path) |
| [#540](https://gitlab.com/devnw/codepros/geode/geode/-/issues/540) | Excessive CPU usage: idles at ~60% CPU | High | QUIC handshake spin |
| [#545](https://gitlab.com/devnw/codepros/geode/geode/-/issues/545) | CI benchmarks optional for release builds | High | Regression detection — **fixed via GAP-0252** |
| [#552](https://gitlab.com/devnw/codepros/geode/geode/-/issues/552) | HashMap/ArrayList pre-sizing ratio 0.7% | Medium | #561, #563 (allocation churn) — **fixed: 5 GroupBy locations pre-sized** |

## Roadmap

No open performance items. All migration engine perf findings closed as Won't Do (2026-04-01).

## Blockers and Unblock Steps

All blockers resolved (2026-02-17):

1. `#445` — **Resolved**: WAL with mutation callback architecture, checkpoint thresholds, CRC32 integrity, crash recovery replay.
2. `#452` — **Resolved**: Real plan generation from AST, OptimizerHints in ExecutionContext, schema epoch cache invalidation.
3. `#460` — **Resolved**: SharedQueryOptimizer with thread-safe cross-connection plan reuse, ref-counting, O(1) LRU eviction.

## Verification Executed for Closed Items

- `zig build test --summary all` — 628/628 tests passed (2026-03-13)
- `rg -n "tracking_index|destroyStream" src/transport/quic.zig`
- `rg -n "sample_size|@min\(rows.len, 10\)" src/server/proto_util.zig`
- `rg -n "wait_cond|timedWait|signal\(" src/transport/thread_pool.zig`
- `rg -n "enable_prune" src/planner/enumerator.zig` — confirmed `enable_prune: bool = true`
- `rg -n "ast_cache_handle|parse_blk" src/server/quic_connection_handler.zig` — confirmed cache wiring
- `rg -n "page_arena|pull_arena|schema_arena" src/server/quic_connection_handler.zig` — confirmed arena serialization scopes
- `rg -n "page_arena|pull_arena" src/transport/grpc_server.zig` — confirmed gRPC arena scopes
- `rg -n "lru_head|lru_tail|lru_prev|lru_next" src/server/query_ast_cache.zig` — confirmed O(1) LRU in AST caches
- `rg -n "lru_head|lru_tail|lru_prev|lru_next" src/server/query_plan_cache.zig` — confirmed O(1) LRU in plan cache
- `rg -n "WriteAheadLog|g_wal" src/wal.zig` — confirmed WAL implementation
- `rg -n "mutationCallback|installMutationCallback" src/wal.zig` — confirmed mutation callback wiring
- `rg -n "generateRealPlan|OptimizerHints" src/server/query_plan_cache.zig` — confirmed real plan generation + hints
- `rg -n "SharedQueryOptimizer|SharedPlanHandle" src/server/query_plan_cache.zig` — confirmed shared optimizer
- `rg -n "schema_epoch" src/graph_store.zig` — confirmed schema epoch invalidation
- Unit tests: `test_wal.zig` (10 tests), `test_plan_cache_lifecycle.zig` (10 tests), `test_shared_optimizer.zig` (8 tests)

### March 2026 Verification

- `zig build test --summary all` — 628/628 tests passed (2026-03-13)
- `rg -n "ensureTotalCapacity" src/execution/match_operations.zig` — confirmed #557 clone pre-sizing + #563 GroupBy pre-sizing
- `rg -n "getNodesByLabels\|getEdgesByType" src/execution/match_operations.zig` — confirmed #558 index-driven scan paths
- `rg -n "clearRetainingCapacity" src/execution/match_operations.zig` — confirmed #560 env list reuse
- `rg -n "ptr ==" src/execution/pattern_helpers.zig` — confirmed #561 pointer equality fast-path
- `rg -n "record_buf\|enc_buf" src/wal.zig` — confirmed #559 single-write buffering
- `rg -n "up_to_lsn == 0\|getEndPos" src/wal.zig` — confirmed #562 truncation optimizations
