# Performance Gap Analysis

Last updated: 2026-02-17

## Summary

- Total findings: 17
- Closed / Implemented: 13
- Closed (Won't Do / Sufficient): 1
- Blocked: 3

All tracked performance gaps are now explicitly marked `Closed`, `Closed (Won't Do)`, or `Blocked`.

## Stack-Ranked Findings

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|---|
| 1 | P0 | 100 | AST cache initialized but not wired into parse hot path | Query exec | `src/server/quic_connection_handler.zig:701` | [#444](https://gitlab.com/devnw/codepros/geode/geode/-/issues/444) | SharedAstCache wired into parse hot path via `parse_blk:` labeled block; all post-parse functions accept `*const ParseResult`, no ownership refactor needed | Closed / Implemented |
| 2 | P0 | 100 | Full graph serialization on every commit | Storage | `src/graph_store.zig:2403` | [#445](https://gitlab.com/devnw/codepros/geode/geode/-/issues/445) | Requires WAL + delta-persistence architecture | Blocked (strategic storage redesign) |
| 3 | P0 | 80 | Per-result string duplication in protobuf serialization | Serialization | `src/server/proto_util.zig:340` | [#446](https://gitlab.com/devnw/codepros/geode/geode/-/issues/446) | ArenaAllocator wraps buildDataPage+buildStatus+send scopes at all QUIC and gRPC data page call sites; per-value string dups become bump allocations, individual frees become no-ops, arena bulk-frees after send | Closed / Implemented |
| 4 | P0 | 80 | Busy-wait polling in QUIC reader loop | Transport | `src/server/quic_connection_handler.zig:145` | [#447](https://gitlab.com/devnw/codepros/geode/geode/-/issues/447) | Exponential backoff replaced fixed busy-wait | Closed / Implemented |
| 5 | P0 | 60 | O(n) column type inference scans all rows | Serialization | `src/server/proto_util.zig:320` | [#448](https://gitlab.com/devnw/codepros/geode/geode/-/issues/448) | Type inference now samples first 10 rows (`@min(rows.len, 10)`) | Closed / Implemented |
| 6 | P1 | 64 | O(V^2) BFS dequeue via linear ArrayList behavior | Graph algos | `src/graph/traversal_bfs.zig:30` | [#449](https://gitlab.com/devnw/codepros/geode/geode/-/issues/449) | Queue front-index/ring behavior removes linear memcopy dequeue cost | Closed / Implemented |
| 7 | P1 | 64 | O(m*n) quadratic edge deduplication | Graph store | `src/graph_store.zig:1655` | [#450](https://gitlab.com/devnw/codepros/geode/geode/-/issues/450) | Hash-based dedup path replaces nested scan | Closed / Implemented |
| 8 | P1 | 60 | Per-node string allocation in label index | Graph store | `src/graph_store.zig:727` | [#451](https://gitlab.com/devnw/codepros/geode/geode/-/issues/451) | Stack `bufPrint` probe before heap allocation | Closed / Implemented |
| 9 | P1 | 60 | Plan cache initialized but never consulted | Query exec | `src/server/quic_connection_handler.zig:455` | [#452](https://gitlab.com/devnw/codepros/geode/geode/-/issues/452) | Requires optimizer lifecycle integration and invalidation policy | Blocked (cache lifecycle/invalidation design pending) |
| 10 | P1 | 60 | Global mutex on gRPC session store | Transport | `src/transport/grpc_server.zig:102` | [#453](https://gitlab.com/devnw/codepros/geode/geode/-/issues/453) | RwLock substitution enables concurrent readers | Closed / Implemented |
| 11 | P1 | 48 | Thread pool spin-sleep when idle | Transport | `src/transport/thread_pool.zig:108`; `src/transport/thread_pool.zig:274` | [#454](https://gitlab.com/devnw/codepros/geode/geode/-/issues/454) | Added condition-variable wait path with wake signaling for submit/complete/shutdown | Closed / Implemented |
| 12 | P2 | 48 | HNSW `knnSearch` computed distances twice | Index | `src/index/hnsw.zig:399` | [#455](https://gitlab.com/devnw/codepros/geode/geode/-/issues/455) | Added distance-returning search path to avoid duplicate compute | Closed / Implemented |
| 13 | P2 | 36 | O(N) LRU eviction in AST/plan caches | Query exec | `src/server/query_ast_cache.zig:102` | [#456](https://gitlab.com/devnw/codepros/geode/geode/-/issues/456) | Intrusive doubly-linked list (lru_prev/lru_next keyed by hash) added to QueryAstCache, SharedAstCache, and QueryPlanCache; eviction removes tail in O(1), access promotes to head in O(1); SharedAstCache walks backward from tail skipping ref_count > 0 | Closed / Implemented |
| 14 | P2 | 36 | O(N) linear stream removal in QUIC | Transport | `src/transport/quic.zig:561`; `src/transport/quic.zig:605` | [#457](https://gitlab.com/devnw/codepros/geode/geode/-/issues/457) | Added stream `tracking_index` + swap-remove index repair for O(1) removal | Closed / Implemented |
| 15 | P2 | 36 | memcpy buffer compaction per message | Transport | `src/server/quic_connection_handler.zig:191` | [#458](https://gitlab.com/devnw/codepros/geode/geode/-/issues/458) | Existing heuristic is sufficient: compaction triggers only at 4KB+ consumed or 50%+ buffer fill; memcpy overhead negligible for typical message sizes | Closed (Won't Do: current heuristic adequate) |
| 16 | P2 | 36 | Exponential plan enumeration without early stop | Planner | `src/planner/enumerator.zig:32` | [#459](https://gitlab.com/devnw/codepros/geode/geode/-/issues/459) | Pruning logic already existed but was disabled; enabled `enable_prune: true` default with conservative 4x prune_factor | Closed / Implemented |
| 17 | P2 | 32 | Per-connection optimizer (no sharing) | Query exec | `src/server/quic_connection_handler.zig:455` | [#460](https://gitlab.com/devnw/codepros/geode/geode/-/issues/460) | Requires shared optimizer/cache architecture with tenancy-safe invalidation | Blocked (cross-connection architecture change) |

## Findings by Area

- Query execution: `#444` (Closed), `#452` (Blocked), `#456` (Closed), `#460` (Blocked)
- Storage/graph: `#445` (Blocked), `#449` (Closed), `#450` (Closed), `#451` (Closed)
- Serialization: `#446` (Closed), `#448` (Closed)
- Transport/concurrency: `#447` (Closed), `#453` (Closed), `#454` (Closed), `#457` (Closed), `#458` (Closed/Won't Do)
- Planner/index: `#455` (Closed), `#459` (Closed)

## Blockers and Unblock Steps

1. `#445` — Implement WAL/delta persistence design and migration plan.
2. `#452` — `QueryOptimizer.generateOptimizedPlan()` produces stub plans; execution engine consumes `*const ast.Program` not `CompiledPlan`. Requires: (a) real optimizer producing physical plans, (b) execution engine consuming `CompiledPlan`, (c) cache invalidation policy.
3. `#460` — Design shared optimizer/cache with thread safety, tenant isolation, and cross-connection plan reuse.

## Verification Executed for Closed Items

- `zig build test --summary all` — 570/570 tests passed (2026-02-17)
- `rg -n "tracking_index|destroyStream" src/transport/quic.zig`
- `rg -n "sample_size|@min\(rows.len, 10\)" src/server/proto_util.zig`
- `rg -n "wait_cond|timedWait|signal\(" src/transport/thread_pool.zig`
- `rg -n "enable_prune" src/planner/enumerator.zig` — confirmed `enable_prune: bool = true`
- `rg -n "ast_cache_handle|parse_blk" src/server/quic_connection_handler.zig` — confirmed cache wiring
- `rg -n "page_arena|pull_arena|schema_arena" src/server/quic_connection_handler.zig` — confirmed arena serialization scopes
- `rg -n "page_arena|pull_arena" src/transport/grpc_server.zig` — confirmed gRPC arena scopes
- `rg -n "lru_head|lru_tail|lru_prev|lru_next" src/server/query_ast_cache.zig` — confirmed O(1) LRU in AST caches
- `rg -n "lru_head|lru_tail|lru_prev|lru_next" src/server/query_plan_cache.zig` — confirmed O(1) LRU in plan cache
