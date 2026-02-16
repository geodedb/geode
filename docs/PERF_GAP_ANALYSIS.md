# Performance Gap Analysis

Last updated: 2026-02-16

## Summary

- Total findings: 17
- Closed / Implemented: 9
- Blocked: 8

All tracked performance gaps are now explicitly marked `Closed` or `Blocked`.

## Stack-Ranked Findings

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|---|
| 1 | P0 | 100 | AST cache initialized but not wired into parse hot path | Query exec | `src/server/quic_connection_handler.zig:634` | [#444](https://gitlab.com/devnw/codepros/geode/geode/-/issues/444) | Needs parser result lifetime/ownership refactor to safely cache AST objects | Blocked (ownership model refactor required) |
| 2 | P0 | 100 | Full graph serialization on every commit | Storage | `src/graph_store.zig:2403` | [#445](https://gitlab.com/devnw/codepros/geode/geode/-/issues/445) | Requires WAL + delta-persistence architecture | Blocked (strategic storage redesign) |
| 3 | P0 | 80 | Per-result string duplication in protobuf serialization | Serialization | `src/server/proto_util.zig:340` | [#446](https://gitlab.com/devnw/codepros/geode/geode/-/issues/446) | Requires arena/zero-copy serialization path with ownership-safe API updates | Blocked (broad serialization API change) |
| 4 | P0 | 80 | Busy-wait polling in QUIC reader loop | Transport | `src/server/quic_connection_handler.zig:145` | [#447](https://gitlab.com/devnw/codepros/geode/geode/-/issues/447) | Exponential backoff replaced fixed busy-wait | Closed / Implemented |
| 5 | P0 | 60 | O(n) column type inference scans all rows | Serialization | `src/server/proto_util.zig:320` | [#448](https://gitlab.com/devnw/codepros/geode/geode/-/issues/448) | Type inference now samples first 10 rows (`@min(rows.len, 10)`) | Closed / Implemented |
| 6 | P1 | 64 | O(V^2) BFS dequeue via linear ArrayList behavior | Graph algos | `src/graph/traversal_bfs.zig:30` | [#449](https://gitlab.com/devnw/codepros/geode/geode/-/issues/449) | Queue front-index/ring behavior removes linear memcopy dequeue cost | Closed / Implemented |
| 7 | P1 | 64 | O(m*n) quadratic edge deduplication | Graph store | `src/graph_store.zig:1655` | [#450](https://gitlab.com/devnw/codepros/geode/geode/-/issues/450) | Hash-based dedup path replaces nested scan | Closed / Implemented |
| 8 | P1 | 60 | Per-node string allocation in label index | Graph store | `src/graph_store.zig:727` | [#451](https://gitlab.com/devnw/codepros/geode/geode/-/issues/451) | Stack `bufPrint` probe before heap allocation | Closed / Implemented |
| 9 | P1 | 60 | Plan cache initialized but never consulted | Query exec | `src/server/quic_connection_handler.zig:455` | [#452](https://gitlab.com/devnw/codepros/geode/geode/-/issues/452) | Requires optimizer lifecycle integration and invalidation policy | Blocked (cache lifecycle/invalidation design pending) |
| 10 | P1 | 60 | Global mutex on gRPC session store | Transport | `src/transport/grpc_server.zig:102` | [#453](https://gitlab.com/devnw/codepros/geode/geode/-/issues/453) | RwLock substitution enables concurrent readers | Closed / Implemented |
| 11 | P1 | 48 | Thread pool spin-sleep when idle | Transport | `src/transport/thread_pool.zig:108`; `src/transport/thread_pool.zig:274` | [#454](https://gitlab.com/devnw/codepros/geode/geode/-/issues/454) | Added condition-variable wait path with wake signaling for submit/complete/shutdown | Closed / Implemented |
| 12 | P2 | 48 | HNSW `knnSearch` computed distances twice | Index | `src/index/hnsw.zig:399` | [#455](https://gitlab.com/devnw/codepros/geode/geode/-/issues/455) | Added distance-returning search path to avoid duplicate compute | Closed / Implemented |
| 13 | P2 | 36 | O(N) LRU eviction in AST/plan caches | Query exec | `src/query_ast_cache.zig:102` | [#456](https://gitlab.com/devnw/codepros/geode/geode/-/issues/456) | Requires linked-list/clock redesign with correctness tests under eviction pressure | Blocked (cache internals redesign pending) |
| 14 | P2 | 36 | O(N) linear stream removal in QUIC | Transport | `src/transport/quic.zig:561`; `src/transport/quic.zig:605` | [#457](https://gitlab.com/devnw/codepros/geode/geode/-/issues/457) | Added stream `tracking_index` + swap-remove index repair for O(1) removal | Closed / Implemented |
| 15 | P2 | 36 | memcpy buffer compaction per message | Transport | `src/server/quic_connection_handler.zig:174` | [#458](https://gitlab.com/devnw/codepros/geode/geode/-/issues/458) | Requires circular-buffer read pipeline and parser boundary adjustments | Blocked (transport parser redesign pending) |
| 16 | P2 | 36 | Exponential plan enumeration without early stop | Planner | `src/planner/enumerator.zig:81` | [#459](https://gitlab.com/devnw/codepros/geode/geode/-/issues/459) | Requires branch-and-bound pruning heuristics + plan quality validation | Blocked (planner algorithm workstream required) |
| 17 | P2 | 32 | Per-connection optimizer (no sharing) | Query exec | `src/server/quic_connection_handler.zig:455` | [#460](https://gitlab.com/devnw/codepros/geode/geode/-/issues/460) | Requires shared optimizer/cache architecture with tenancy-safe invalidation | Blocked (cross-connection architecture change) |

## Findings by Area

- Query execution: `#444` (Blocked), `#452` (Blocked), `#456` (Blocked), `#460` (Blocked)
- Storage/graph: `#445` (Blocked), `#449` (Closed), `#450` (Closed), `#451` (Closed)
- Serialization: `#446` (Blocked), `#448` (Closed)
- Transport/concurrency: `#447` (Closed), `#453` (Closed), `#454` (Closed), `#457` (Closed), `#458` (Blocked)
- Planner/index: `#455` (Closed), `#459` (Blocked)

## Blockers and Unblock Steps

1. `#444` — Introduce AST ownership model that allows cached parsed forms without double-free risk.
2. `#445` — Implement WAL/delta persistence design and migration plan.
3. `#446` — Refactor serialization API for arena/borrowed string ownership.
4. `#452` — Define plan cache invalidation rules and optimizer lifecycle integration.
5. `#456` — Implement O(1) LRU metadata structure and eviction correctness tests.
6. `#458` — Replace compaction with circular buffer and update message framing parser.
7. `#459` — Add branch-and-bound pruning and guardrails for optimality regressions.
8. `#460` — Design shared optimizer/cache with thread safety and tenant isolation.

## Verification Executed for Closed Items

- `zig build test --summary all`
- `make test`
- `rg -n "tracking_index|destroyStream" src/transport/quic.zig`
- `rg -n "sample_size|@min\(rows.len, 10\)" src/server/proto_util.zig`
- `rg -n "wait_cond|timedWait|signal\(" src/transport/thread_pool.zig`
