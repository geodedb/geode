# Performance Gap Analysis

Last updated: 2026-05-15 (Phase 3 perf-reviewer pass — 4 findings filed: PERF-A #808, PERF-B #811, PERF-C #814, PERF-D #816; all OPEN. PERF-A queued for separate `/bench-optimize:run` session per operator decision; prior: 2026-04-16)

## Summary

- Total findings: 47
- Open: 4 (2026-05-15 audit Phase 3: PERF-A/B/C/D)
- Closed / Implemented: 34
- Closed (Won't Do / Sufficient): 10 (1 transport + 6 migration engine + 3 strategic deferred)
- Closed (won't-track): 6 (2026-05-15 Phase 3 reviewer triage — see "Not tracked" subsection below)
- Blocked: 0
- /bench-optimize candidate: **PERF-A** (PerfScore 40)

Previous 17 findings (2026-02-17 audit) all resolved. March 2026 audit added 7 new findings -- all 7 closed 2026-03-13. April 2026 migration engine audit added 6 new findings (1x P2, 5x P3) -- all closed Won't Do 2026-04-01 (unmeasurable benefit at realistic migration counts). April 9, 2026 core engine perf review added 13 new findings (2x P0, 5x P1, 6x P2) covering execution engine, graph store, transport, and CLI hot paths. **All 13 closed 2026-04-10** (6 implemented, 4 closed earlier, 3 deferred as Won't Do).

### All findings resolved

> PathIterator BFS memory leak (previously #1, PerfScore 100) -- **Closed 2026-04-09** (commit `9f5e587f`)

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

Context: Admin-time CLI tool. Dominant cost is QUIC round-trip (~1.3-1.9s per migration). No benchmarks exist. Reviewer consensus: none of these represent real bottlenecks at any realistic migration count (<10K). **Re-audit 2026-04-01**: All 6 Won't Do dispositions confirmed correct. Per-migration fsync in `applyUpMigrations` (mod.zig:433-435, 0.5-50ms) is correct for crash safety (GAP-0280) and dominated by QUIC RTT. O(N*R) quadratic loops bounded by migration count (<500). Full ledger reload per API call correct for CLI tool. 4MB/8MB read caps appropriate. Global mutex hold times nanosecond-scale. No pipelining opportunities without violating correctness. No benchmarks needed for admin-time tool. Zero new actionable performance findings.

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|---|
| 25 | P2 | 24 | Repeated full ledger load/parse -- `loadLedger` called by every public operation (7 call sites) | Migration | `src/migration/mod.zig:165-200` (7 call sites: L321, L378, L409, L508, L548, L563) | [#577](https://gitlab.com/devnw/codepros/geode/geode/-/issues/577) | Not recommended: caching adds complexity for negligible gain vs QUIC round-trip | Closed (Won't Do) |
| 26 | P3 | 16 | `applyUpMigrations` saves ledger only at end -- partial progress lost on crash | Migration | `src/migration/mod.zig:345-369` | [#594](https://gitlab.com/devnw/codepros/geode/geode/-/issues/594) | Already covered by GAP-0280 errdefer fix for crash safety | Closed (Won't Do) |
| 27 | P3 | 4 | O(N*R) quadratic scan in `applyUpMigrations` -- `versionExists` per name | Migration | `src/migration/mod.zig:328-335` | [#579](https://gitlab.com/devnw/codepros/geode/geode/-/issues/579) | Not recommended: HashMap overhead exceeds scan cost at realistic counts | Closed (Won't Do) |
| 28 | P3 | 4 | O(F*R) quadratic scan in `statusReport` -- ledger scan per file | Migration | `src/migration/mod.zig:447-464` | [#582](https://gitlab.com/devnw/codepros/geode/geode/-/issues/582) | Not recommended: unmeasurable benefit at realistic counts | Closed (Won't Do) |
| 29 | P3 | 4 | O(M*R) quadratic scan in `checksumValidate` -- ledger scan per manifest line | Migration | `src/migration/mod.zig:531-538` | [#584](https://gitlab.com/devnw/codepros/geode/geode/-/issues/584) | Not recommended: HashMap overhead exceeds scan cost at realistic counts | Closed (Won't Do) |
| 30 | P3 | 4 | `planDryRun` sort calls `parseVersion` per comparison instead of using pre-parsed `.version` field | Migration | `src/migration/mod.zig:587-592` | [#589](https://gitlab.com/devnw/codepros/geode/geode/-/issues/589) | Unmeasurable improvement | Closed (Won't Do) |

### April 9 2026 Audit -- Core Engine Performance Review

Context: Full perf-scan + perf-review of execution engine, graph store, transport, and CLI hot paths. Identified 2x P0, 5x P1, and 6x P2 findings. All findings are evidence-based with verified source locations.

| Rank | Sev | Score | Finding | Component | Evidence | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|
| 31 | P0 | 100 | PathIterator BFS memory leak -- `getEdgesFrom`/`getEdgesTo` allocations never freed during var-len path traversal | Execution | `src/execution.zig:1937-1938`: allocates `[]Edge` slices via `getEdgesFrom(allocator, last_node_id)` and `getEdgesTo(allocator, last_node_id)` in BFS loop; neither slice is freed before next iteration or on path completion | Fixed: added `defer allocator.free()` for all `getEdgesFrom`/`getEdgesTo` allocations in BFS loop; also freed edge slices in streaming PathIterator. Commit `9f5e587f`. | Closed / Implemented |
| 32 | P0 | 60 | `getEdgesByType` O(E) full scan -- no edge-type index | Graph store | `src/graph_store.zig:2850-2875`: two full passes over `self.edges.valueIterator()` (count pass + copy pass); nodes have `label_index` but edges have no type index | Added `edge_type_index: StringHashMap(ArrayList(u64))` keyed by `"graph:type"`; maintained on all 6 mutation paths (`addEdge`/`removeEdge`/clone/load/restore); `getEdgesByType` uses index for O(1) lookup. 5 new tests. | Closed (2026-04-10) |
| 33 | P1 | 48 | O(n^2) BFS dequeue via `orderedRemove(0)` | Execution | `src/execution.zig:1909` (main BFS queue), `:1964` (pending_results queue): `orderedRemove(0)` triggers `memmove` of remaining items on every dequeue; BFS on large graphs becomes quadratic | Replaced with O(1) front-index dequeue (`queue_front`/`pending_front`) with amortized compaction when front > len/2. Both queue and pending_results use same pattern. | Closed (2026-04-10) |
| 34 | P1 | 48 | c=4 throughput regression -- PollSync contention + broadcast wakeup storms | Transport | Load test baseline: 727 QPS at c=2 drops to 646 QPS at c=4 (11% regression); root cause: `PollSync` mutex contention in `src/transport/quic.zig`, persistence thread lock contention, and `streams_cv.broadcast()` waking all waiters in `src/server/quic_connection_handler.zig:746` | Replaced 3x `streams_cv.broadcast()` with `signal()` (single waiter); increased poll loop sleep from 100μs to 500μs reducing broadcast frequency 5x. Commit `b3790685`. | Closed (2026-04-10) |
| 35 | P1 | 45 | No CLI connection reuse -- full QUIC+TLS handshake per `geode query` invocation | CLI | `src/cli/main.zig:1992-2037`: each `geode query` call creates new `QuicClient.init`, connects, handshakes (1.3-1.9s overhead), executes one query, then deinits | Added `--batch` flag that reads queries from stdin (one per line) and executes all over a single QUIC connection. Amortizes 1.3-1.9s handshake across all queries. Commit `b24ddd3a`. | Closed (2026-04-10) |
| 36 | P1 | 32 | Unbounded OS thread spawning per QUIC stream -- up to 65 threads per connection | Transport | `src/server/quic_connection_handler.zig:740`: `std.Thread.spawn(.{}, handleAdditionalStream, ...)` for each additional multiplexed stream; QUIC allows up to 65 concurrent streams per connection; comment at `:735-739` explains why Spice pool was not used | Added `GlobalStreamThrottle` with atomic CAS fast path + condvar backpressure, capped at 256 global threads (configurable). Excess streams wait 10ms then get rejected. 7 new tests. | Closed (2026-04-10) |
| 37 | P1 | 32 | Cartesian product no LIMIT pushdown -- full N*M cross product before truncation | Execution | `src/execution/match_operations.zig:1903`: Cartesian product path generates all N*M bindings before any LIMIT is applied; `scan_cap` hint exists in other paths but not here | Added `scan_cap` early termination to Cartesian product nested loop (outgoing + incoming edges + outer node iteration). Stops expansion once enough bindings collected. Commit `6c3d091f`. | Closed (2026-04-10) |
| 38 | P2 | 27 | Linear visited-check in PathIterator `shouldSkipByPathMode` | Execution | `src/execution.zig:1818-1838`: `.trail` mode scans `current_path.edges.items` linearly per edge expansion; `.acyclic` and `.simple` modes scan `current_path.nodes.items` linearly; O(d) per expansion where d = path depth | Added `node_set` and `edge_set` (`AutoHashMapUnmanaged(u64, void)`) to `VariableLengthPath`; maintained during clone+expand; `shouldSkipByPathMode` uses O(1) hash lookups. Commit `6d4a97aa`. | Closed (2026-04-10) |
| 39 | P2 | 20 | 341x `initCapacity(allocator, 0)` -- no-op allocations on hot paths | Execution | 341 occurrences across 43 files; top offenders: `match_operations.zig` (55), `execution.zig` (33), `centrality_algorithms.zig` (53), `statement_handlers.zig` (22), `crud_operations.zig` (20) | Batch-replaced ~350 occurrences across 44 files with `.empty` (zero-cost compile-time initialization, no function call or error-path codegen). Commit `e75c8704`. | Closed (2026-04-10) |
| 40 | P2 | 18 | Full Edge struct copy in `getEdgesByType` -- ~96+ bytes per edge including shallow StringHashMap | Graph store | `src/graph_store.zig:2870`: `result[i] = edge.*` copies full `Edge` struct including label, properties HashMap, tenant_id, graph_name; callers only need edge IDs or read-only access | Changed return type from `[]Edge` to `[]u64` (edge IDs, 8 bytes vs ~96+ bytes). Callers use `store.edges.getPtr(id)` for zero-copy read-only access. Commit `f9e23b07`. | Closed (2026-04-10) |
| 41 | P2 | 10 | Plan cache stub -- `generateOptimizedPlan` produces hardcoded operators not wired to execution | Planner | `src/server/query_plan_cache.zig:261-278`: `optimizeMatchClause`, `optimizeFilterConditions`, `optimizeProjection`, `optimizeOrdering` ignore AST and produce stub operators with fixed selectivity/cost estimates | Won't Do: requires operator-to-execution bridge (large architectural effort). AST cache already covers parse cost. SharedQueryOptimizer provides cross-connection plan reuse. Benefit is marginal while AST cache is effective. | Closed (Won't Do, 2026-04-10) |
| 42 | P2 | 10 | No wire-level compression -- protobuf query results sent uncompressed | Transport | Backup system uses zstd compression (`src/storage/backup.zig`) but query result protobuf messages are sent raw; large result sets (100K+ rows) transfer more data than necessary | Won't Do: requires QUIC protocol negotiation changes, client-side decompression support, and compression capability handshake. QUIC already uses TLS compression for transport. Benefit limited to large result sets (100K+ rows) which are uncommon in graph workloads. | Closed (Won't Do, 2026-04-10) |
| 43 | P2 | 10 | No latency histogram / allocation tracking in production | Observability | No per-query-type p50/p99 latency metrics; no per-request allocation byte tracking; load test baselines exist but runtime observability is absent | Won't Do: no correctness impact. Load test baselines provide regression detection. Runtime histograms require per-query instrumentation overhead and a metrics exposure endpoint. Defer to future observability sprint when production monitoring requirements are clearer. | Closed (Won't Do, 2026-04-10) |

## Findings by Area

### App (Query Execution)

- `#444` (Closed), `#452` (Closed), `#456` (Closed), `#460` (Closed), `#557` (Closed), `#558` (Closed), `#560` (Closed), `#561` (Closed), `#563` (Closed)
- **Closed (2026-04-09)**: #31 PathIterator memory leak (P0/100, commit `9f5e587f`)
- **Closed (2026-04-10)**: #32 edge-type index (P0/60), #33 BFS dequeue (P1/48), #36 global thread throttle (P1/32), #37 Cartesian LIMIT pushdown (P1/32), #38 visited-check HashSet (P2/27), #39 initCapacity(0) batch fix (P2/20)

### DB (Storage / Graph Store)

- `#445` (Closed), `#449` (Closed), `#450` (Closed), `#451` (Closed), `#559` (Closed), `#562` (Closed)
- **Closed (2026-04-10)**: #32 edge-type index (P0/60), #40 Edge struct copy → ID slice (P2/18)

### Infra (Transport / Concurrency)

- `#447` (Closed), `#453` (Closed), `#454` (Closed), `#457` (Closed), `#458` (Closed/Won't Do)
- **Closed (2026-04-10)**: #34 c=4 throughput fix (P1/48), #36 global thread throttle (P1/32), #42 wire compression (Won't Do, P2/10), #43 latency histograms (Won't Do, P2/10)

### CI

- `#545` (Closed -- fixed via GAP-0252)
- No new CI findings.

### CLI

- **Closed (2026-04-10)**: #35 CLI batch mode (P1/45)

### Planner / Index

- `#455` (Closed), `#459` (Closed)
- **Closed (Won't Do, 2026-04-10)**: #41 plan cache stub (P2/10)

### Migration

- `#577` (Won't Do), `#579` (Won't Do), `#582` (Won't Do), `#584` (Won't Do), `#589` (Won't Do), `#594` (Won't Do)

## Related Open Performance Bugs (tracked separately)

| Issue | Title | Severity | Relates to |
|-------|-------|----------|------------|
| [#538](https://gitlab.com/devnw/codepros/geode/geode/-/issues/538) | OOM on large-graph ingest | High | Storage memory |
| [#539](https://gitlab.com/devnw/codepros/geode/geode/-/issues/539) | WAL grows unboundedly across restarts | High | #559, #562 (WAL write path) |
| [#540](https://gitlab.com/devnw/codepros/geode/geode/-/issues/540) | Excessive CPU usage: idles at ~60% CPU | High | QUIC handshake spin |
| [#545](https://gitlab.com/devnw/codepros/geode/geode/-/issues/545) | CI benchmarks optional for release builds | High | Regression detection — **fixed via GAP-0252** |
| [#552](https://gitlab.com/devnw/codepros/geode/geode/-/issues/552) | HashMap/ArrayList pre-sizing ratio 0.7% | Medium | #561, #563 (allocation churn) — **fixed: 5 GroupBy locations pre-sized** |

## Roadmap

### Quick Wins (< 1 day each)

| Item | Finding | Effort | Expected Impact |
|------|---------|--------|-----------------|
| ~~#31~~ | ~~PathIterator memory leak~~ | ~~2-4h~~ | **Closed 2026-04-09** (commit `9f5e587f`) |
| #33 | BFS orderedRemove(0) | 2-4h | O(1) dequeue vs O(n) memmove; linear BFS instead of quadratic |
| #39 | initCapacity(0) batch fix | 2-4h | Removes 341 no-op allocator calls; marginal per-call but cumulative on hot paths |

### Medium (1-5 days each)

| Item | Finding | Effort | Expected Impact |
|------|---------|--------|-----------------|
| #32 | Edge-type index | 2-3d | O(1) type lookup vs O(E) full scan; critical for MATCH with typed relationships |
| #34 | c=4 throughput regression | 2-3d | Requires instrumentation first; expect 15-30% QPS recovery at c=4 |
| #35 | CLI batch mode | 1-2d | Amortize 1.3-1.9s handshake across multiple queries; 10-100x throughput for scripted use |
| #37 | Cartesian LIMIT pushdown | 1d | Early termination avoids full N*M expansion; orders of magnitude for small LIMIT on large graphs |
| #38 | HashSet visited check | 1d | O(1) vs O(d) per edge expansion; significant for deep path traversals |
| #40 | Edge struct copy elimination | 1d | Avoid ~96+ byte copy per edge; pointer-based access is zero-copy |

### Strategic (> 5 days)

| Item | Finding | Effort | Expected Impact |
|------|---------|--------|-----------------|
| #36 | Thread pool for QUIC streams | 3-5d | Caps OS thread count; prevents resource exhaustion under high connection multiplexing |
| #41 | Plan cache wiring | 5-10d | Requires operator-to-execution bridge; low priority while AST cache covers parse cost |
| #42 | Wire-level compression | 3-5d | Reduces network bandwidth for large result sets; requires protocol negotiation |
| #43 | Latency histograms | 3-5d | Runtime observability for production debugging; no correctness impact |

### Sprint Plan

**Sprint 1 (1 week)**: Fix #31 (PathIterator memory leak), #33 (BFS dequeue), diagnose #34 (c=4 regression via instrumentation)

**Sprint 2 (1 week)**: Fix #32 (edge-type index), #35 (CLI batch mode), #37 (Cartesian LIMIT pushdown), fix #34 based on diagnosis

**Sprint 3 (follow-up)**: #36 (thread pool), #38 (HashSet visited), #39 (initCapacity batch fix), #42 (compression), #43 (histograms)

## Blockers and Unblock Steps

### Resolved (2026-02-17)

1. `#445` — **Resolved**: WAL with mutation callback architecture, checkpoint thresholds, CRC32 integrity, crash recovery replay.
2. `#452` — **Resolved**: Real plan generation from AST, OptimizerHints in ExecutionContext, schema epoch cache invalidation.
3. `#460` — **Resolved**: SharedQueryOptimizer with thread-safe cross-connection plan reuse, ref-counting, O(1) LRU eviction.

### Current Unknowns (2026-04-09)

1. **#34 c=4 regression**: Root cause is suspected (PollSync contention + broadcast storms) but not confirmed via profiling. Unblock: instrument mutex contention times in `quic.zig` PollSync; run load test at c=4 with `--track-allocations` to isolate bottleneck.
2. **#36 thread pool for streams**: Comment at `quic_connection_handler.zig:735-739` explains current design rationale (long-lived blocking I/O vs fork/join). Unblock: prototype Spice-based stream handler with proper lifecycle to validate that approach works without starving heartbeat tasks.
3. **#41 plan cache wiring**: Requires operator-to-execution bridge design. Unblock: define `PhysicalOperator` execution interface that maps to existing execution paths in `match_operations.zig` and `query_execution.zig`.

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

## April 2026 Phase 1-3 Perf Audit — New Findings (2026-04-16)

Anchored to `benchmarks/loadtest/baseline.jsonl`: ping_c1 273.8 qps / p50 2.4ms; ping_c2 727 qps / p50 2.7ms; **ping_c4 646.2 qps / p50 3.1ms with 4 errors** (c=4 regression cliff). Phase 3 review: [docs/audit/perf-phase3-review.md](audit/perf-phase3-review.md). Composite estimate for #1+#4+#7: **p50 2.7 → 1.5-1.8ms, QPS +25-40% at c=2..8**, zero I/O changes.

### 2026-04-16 Closeout note

**Wave 4 and Wave 5 perf items are deferred.** Per `docs/audit/gap-close-plan.md` dependency notes:

- Wave 4 requires a loadtest harness (`../geode-test-harness` Go loadtest + hyperfine) and composite A/B baselining — neither installed on the current verification host. `make loadtest-save-all-baselines` is a prerequisite before attempting #715 / #718 / #720 composite measurement.
- Wave 5 item #719 (match decomposition) must not pair with Wave 4 perf work in the same commit; it needs its own A/B. Schedule after Wave 4 p0 composite is frozen.

No perf items were closed in the 2026-04-16 gap-close pass. All 9 new findings remain Triage. Tracking handoff preserved; Wave-4/5 counts of 8+12 items deferred to the next perf sprint.

### Summary

- **P0:** 3 (#715 RLS row alloc, #718 QUIC wake storm, #720 TDE key reload)
- **P1:** 4 (#722 thread_pool alloc, #726 planner leak, #729 lane routing, #731 federation gating)
- **P2:** 2 (#734 storage RwLock, #735 WAL fsync)

### Top 5 Risks (by expected throughput delta)

1. **#715 per-row RLS alloc** (PerfScore 80; Impact 5 × Likelihood 4 × 4) — **MATCH row-rate +30-80% single-tenant**
2. **#718 QUIC handler wake storm** (PerfScore 72; Impact 4 × Likelihood ~4.5 × 4) — **ping_c4 646 → ≥900 qps (+40%), p50 2.7 → 1.6ms**
3. **#720 TDE key reload per op** (PerfScore 72; Impact 5 × Likelihood ~3.6 × 4) — **TDE 30 → 120+ MB/s (4x)**
4. **#731 per-stream FederationManager** (PerfScore 48; Impact 3 × Likelihood 4 × 4) — **stream accept 200-500μs → <50μs**
5. **#722 thread_pool per-task alloc** (PerfScore 64; Impact 4 × Likelihood 4 × 4) — **submit 500ns → ≤50ns; QPS +3-5% ping**

### Stack-Ranked Findings

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Owner | SLA | Status |
|---|---|---:|---|---|---|---|---|---|---|---|
| 44 | P0 | 80 | Per-row RLS row alloc in MATCH even when policy inactive — `nodePropertiesToRLSRow` allocates StringHashMap per node at ≥19 MATCH sites | Query exec | `src/execution/match_operations.zig:104-145`; `src/security/rls_value_bridge.zig:55-69` | [#715](https://gitlab.com/devnw/codepros/geode/geode/-/issues/715) | Thread-local scratch RLSRow + clearRetainingCapacity + hasPolicyForTable short-circuit; long-term: compile predicate against native property layout | @benjiv | Immediate | Triage |
| 45 | P0 | 72 | QUIC handler wake storm — `poll_cv.broadcast` every 500μs wakes 30+ threads for 1 progress (PERF-P1-001) | Transport | `src/transport/quic.zig:389-404`; `src/server/quic_connection_handler.zig:329-337` | [#718](https://gitlab.com/devnw/codepros/geode/geode/-/issues/718) | Per-connection CV (not broadcast); skip broadcast on empty poll; adaptive wakeup | @benjiv | Immediate | Triage |
| 46 | P0 | 72 | TDE `loadKey()` per encrypt/decrypt — getenv+hex-parse on every call, 8 callers | Storage | `src/storage/tde_file_encryption.zig:59-143, 190-203` | [#720](https://gitlab.com/devnw/codepros/geode/geode/-/issues/720) | Module-level atomic `KeyCache` + `std.once` lazy init; explicit `invalidateKeyCache()` for rotation | @benjiv | Immediate | Triage |
| 47 | P1 | 64 | Thread-pool `submit` allocates `SubmittedTask` per task — 1454/s at ping_c2 | Transport | `src/transport/thread_pool.zig:262-274` | [#722](https://gitlab.com/devnw/codepros/geode/geode/-/issues/722) | Bounded MPSC freelist (4×thread_count slots) with allocator fallback | @benjiv | Sprint | Triage |
| 48 | P1 | 56 | Planner DP `dpEnumerateJoinOrders` leaks PlanNodes — O(3^n) create without free, n=8 retains ~6561 | Planner | `src/planner/cbo.zig:166-240` | [#726](https://gitlab.com/devnw/codepros/geode/geode/-/issues/726) | Scoped `ArenaAllocator` around DP enumeration; deep-copy winning plan to ctx.allocator | @benjiv | Sprint | Triage |
| 49 | P1 | 56 | Thread pool submits all work to `.blocking` lane — CPU MATCH contends with I/O | Transport | `src/transport/thread_pool.zig:203-214` + callers | [#729](https://gitlab.com/devnw/codepros/geode/geode/-/issues/729) | Extend `submit()` with `.lane` param; classify MATCH/planner → `.cpu`, WAL flush → `.io` | @benjiv | Sprint | Triage |
| 50 | P1 | 48 | Per-stream FederationManager + DistributedQueryPlanner + 3 HashMap catalogs even in single-tenant mode | Server | `src/server/quic_connection_handler.zig:704-745` | [#731](https://gitlab.com/devnw/codepros/geode/geode/-/issues/731) | Gate alloc behind `GEODE_CLUSTER_TOKEN != null`; single-tenant path allocates nothing | @benjiv | Sprint | Triage |
| 51 | P2 | 32 | StorageAdapter `graph_handles_mutex` is `Mutex` — serializes read-only lookups at tier-0 | Storage | `src/graph_storage_adapter.zig:668-750` | [#734](https://gitlab.com/devnw/codepros/geode/geode/-/issues/734) | Convert to `std.Thread.RwLock`; readers `.lockShared()`, mutators unique lock; GAP-0278 tier-0 ordering preserved | @benjiv | Quarter | Triage |
| 52 | P2 | 20 | WAL fsync per 1s tick regardless of dirty flag — idle SSD wear | Storage | `src/graph_store.zig:5184-5205`; `src/wal.zig:241-248` | [#735](https://gitlab.com/devnw/codepros/geode/geode/-/issues/735) | `wal.dirty: atomic.Value(bool)` set on append, CAS-clear on sync; skip fsync when clean | @benjiv | Quarter | Triage |

### Consolidated Top-15 (live view — new findings + highest-severity from prior audits)

| Rank | Sev | Score | Issue | Status |
|---:|---|---:|---|---|
| 1 | P0 | 80 | #715 Per-row RLS row alloc | **NEW — Triage** |
| 2 | P0 | 72 | #718 QUIC handler wake storm (PERF-P1-001) | **NEW — Triage** |
| 3 | P0 | 72 | #720 TDE key reload per op | **NEW — Triage** |
| 4 | P1 | 64 | #722 thread_pool per-task alloc | **NEW — Triage** |
| 5 | P1 | 56 | #726 Planner DP leak | **NEW — Triage** |
| 6 | P1 | 56 | #729 Thread-pool lane routing | **NEW — Triage** |
| 7 | P1 | 48 | #731 Per-stream FederationManager | **NEW — Triage** |
| 8 | P2 | 32 | #734 StorageAdapter Mutex → RwLock | **NEW — Triage** |
| 9 | P2 | 20 | #735 WAL fsync per tick | **NEW — Triage** |
| 10 | P0 | 90 | #557 N² binding clone in multi-chain MATCH joins | Closed / Implemented |
| 11 | P1 | 64 | #558 Full node scan fallback (no-labels MATCH) | Closed / Implemented |
| 12 | P1 | 60 | #559 WAL per-record unbuffered writes | Closed / Implemented |
| 13 | P1 | 56 | #560 Per-row environment allocation | Closed / Implemented |
| 14 | P1 | 60 | #449 O(V²) BFS dequeue | Closed / Implemented |
| 15 | P1 | 60 | #450 O(m*n) edge dedup | Closed / Implemented |

### Findings by Area

- **app (execution/transport):** #715, #718, #722, #729, #731 (5 open)
- **db (storage):** #720, #734, #735 (3 open)
- **planner:** #726 (1 open)
- **infra/ci:** none new (existing #545, #701 tracked)

### Roadmap

**Quick Wins (< 1 day)**

- #720 TDE key cache — atomic ptr + once.init
- #735 WAL dirty flag — single atomic bool + CAS in sync loop
- #734 Mutex → RwLock swap in graph_storage_adapter

**Medium (1-5 days)**

- #715 RLS scratch row + short-circuit — composes with #560 (already closed) for full MATCH alloc kill
- #722 thread_pool freelist — bounded ring + fallback
- #726 Planner arena
- #731 FederationManager gating — add env check + null-guards at callers

**Strategic (> 5 days)**

- #718 QUIC per-connection wake — requires endpoint API changes, regression coverage across ping/fan_out/two_hop at c=1..16
- #729 Thread-pool lane routing — API extension + caller-by-caller classification + per-lane sizing policy

### Validation Commands

```sh
# Full regression suite:
cd ../geode-test-harness && make test-everything GEODE_BINARY=/home/benji/src/devnw/codepros/geode/geode/zig-out/bin/geode

# Before merging any of #715/#718/#720/#722: save baseline
make loadtest-save-baseline

# After merge:
make loadtest-compare  # must not regress any benchmark
```

### April 2026 Phase 4 Tracking

- Created 9 GitLab issues: #715, #718, #720, #722, #726, #729, #731, #734, #735
- All tagged `type::performance` + severity + area + confidence labels
- No duplicates: #560 (per-row env alloc, closed) is distinct from #715 (RLS row); #540 (idle CPU broad bug) overlaps with #718 but has different scope (handshake spin vs. wake storm)
- Phase 3 review: `docs/audit/perf-phase3-review.md`
- Baseline regression cited: ping_c4 727 → 646 qps + 4 errors

## LSP — 2026-05-06 Audit (Phase 4)

**Source:** `/tmp/lsp-audit-phase3/perf-reviewer.md` (24 findings) → 15 GitLab issues
**Scope:** `src/cli/lsp/*.zig` (~8,480 LOC) + `src/mcp/lsp.zig` (715 LOC)
**Method:** PerfScore = Impact × Likelihood × 4 (codepros perf-scoring framework)

### Summary

- P0 (PerfScore 100): 5 findings → 3 umbrella/keystone issues
- P1 (PerfScore 48-64): 10 findings → 5 issues + 5 sub-tasks under #770 keystone
- P2 (PerfScore 32-36): 4 findings → 4 issues
- P3 (PerfScore 24): 5 findings → 4 issues + 1 fold

**Top-5 risks (by p95 delta on hot path):**

1. **#770 Per-doc AST cache** (PerfScore 100) — 3× re-parse per save → 1×; gates 5 sub-tasks. Modal-request p95 collapses for documentSymbol/definition/references/semanticTokens.
2. **#766 Tier-A free-money batch** (PerfScore 100) — debounce + buffered transport + completion cap + static JSON + Content-Length stack-buf. Cuts keystroke storm from 5 invocations/sec to ~1/pause.
3. **#772 JSON serialization rewrite** (PerfScore 100) — completion serialize ~300μs → ~50μs via `std.json.WriteStream` direct emission.
4. **#776 OTel instrumentation** (PerfScore 48) — gates measurement of every other fix; cardinality-safe (no URI tagging).
5. **#777 Line offset table** (PerfScore 64) — hover p95 ~300μs → ~10μs on 1000-line docs.

### Stack-Ranked LSP Findings

| Rank | Sev | Score | Finding | File:Line | GitLab | Fix Summary | Status |
|---:|-----|------:|---------|-----------|--------|-------------|--------|
| 1 | P0 | 100 | F-01 didChange debounce | `src/cli/lsp/server.zig:273-289` | [#766](https://gitlab.com/devnw/codepros/geode/geode/-/issues/766) | 80-150ms debounce + per-doc gen counter | **Closed 2026-05-06** (`1603d9a1`) |
| 2 | P0 | 100 | F-02 AST cache (KEYSTONE) | `src/cli/lsp/features.zig:40,461,845` | [#770](https://gitlab.com/devnw/codepros/geode/geode/-/issues/770) | `Document.getOrParse` keyed on `doc.version` + sub-tasks | Deferred to follow-up (gates F-05/06/12/15/16) |
| 3 | P0 | 100 | F-04 Buffered stdin reader | `src/cli/lsp/transport.zig:138-154` | [#766](https://gitlab.com/devnw/codepros/geode/geode/-/issues/766) | 4KB BufferedReader; 1 syscall/msg | **Closed 2026-05-06** (`a0d52c9e`) |
| 4 | P0 | 100 | F-09 Static completion JSON | `src/cli/lsp/server.zig:171-243,373-394,746-754` | [#766](https://gitlab.com/devnw/codepros/geode/geode/-/issues/766), [#772](https://gitlab.com/devnw/codepros/geode/geode/-/issues/772) | Comptime envelope + WriteStream direct emit | Triage |
| 5 | P0 | 100 | F-14 Completion prefix-cap | `src/cli/lsp/features.zig:385-446` | [#766](https://gitlab.com/devnw/codepros/geode/geode/-/issues/766) | Cap 50 items; `isIncomplete=true` | Triage |
| 6 | P1 | 64 | F-05 Identifier-position index | `src/cli/lsp/document.zig:114-227` | [#770](https://gitlab.com/devnw/codepros/geode/geode/-/issues/770) (sub-task) | Built once during cached parse | Triage |
| 7 | P1 | 64 | F-06 semanticTokens lex reuse | `src/cli/lsp/features.zig:1543-1745` | [#770](https://gitlab.com/devnw/codepros/geode/geode/-/issues/770) (sub-task) | Use cached lex stream | Triage |
| 8 | P1 | 64 | F-08 Levenshtein typo memoize | `src/cli/lsp/semantic.zig:261-301,116-160` | [#779](https://gitlab.com/devnw/codepros/geode/geode/-/issues/779) | Cache by `hash(label-set)` | Triage |
| 9 | P1 | 64 | F-12 MCP bridge AST reuse | `src/mcp/lsp.zig:107-188` | [#770](https://gitlab.com/devnw/codepros/geode/geode/-/issues/770) (sub-task) | Share AST cache across LSP+MCP | Triage |
| 10 | P1 | 64 | F-18 Line-start offset table | `src/cli/lsp/document.zig:36-84` | [#777](https://gitlab.com/devnw/codepros/geode/geode/-/issues/777) | O(1) `getOffset`/`getLineContent` | Triage |
| 11 | P1 | 64 | F-22 WriteStream direct emit | indirect→F-09 | [#772](https://gitlab.com/devnw/codepros/geode/geode/-/issues/772) | (folded into JSON rewrite) | Triage |
| 12 | P1 | 48 | F-03 Incremental sync (rope) | `src/cli/lsp/document.zig:30-34` | [#786](https://gitlab.com/devnw/codepros/geode/geode/-/issues/786) | `textDocumentSync.change=2` + piece-table | Triage |
| 13 | P1 | 48 | F-10 Typed JSON-RPC peel | `src/cli/lsp/server.zig:89` | [#787](https://gitlab.com/devnw/codepros/geode/geode/-/issues/787) | MessageHeader + per-method structs | Triage |
| 14 | P1 | 48 | F-11 OTel LSP+MCP | LSP+MCP whole tree | [#776](https://gitlab.com/devnw/codepros/geode/geode/-/issues/776) | 7 spans + 7 metrics, cardinality guards | Triage |
| 15 | P1 | 48 | F-20 Non-blocking dispatcher | `src/cli/lsp/server.zig:51-86` | [#790](https://gitlab.com/devnw/codepros/geode/geode/-/issues/790) | Worker pool + per-request arenas | Triage |
| 16 | P2 | 36 | F-07 Scope.canonicalize arena | `src/cli/lsp/semantic.zig:64-71` | [#780](https://gitlab.com/devnw/codepros/geode/geode/-/issues/780) | Arena-owned uppercase | Triage |
| 17 | P2 | 36 | F-15 References AST cross-check | `src/cli/lsp/features.zig:1416-1513` | [#770](https://gitlab.com/devnw/codepros/geode/geode/-/issues/770) (sub-task) | AST + ident-index | Triage |
| 18 | P2 | 32 | F-19 $/cancelRequest | `src/cli/lsp/server.zig:107-131` | [#789](https://gitlab.com/devnw/codepros/geode/geode/-/issues/789) | Per-id task table + cooperative cancel | Triage |
| 19 | P2 | 32 | F-21 Async didOpen diagnostics | `src/cli/lsp/server.zig:259-271` | [#792](https://gitlab.com/devnw/codepros/geode/geode/-/issues/792) | Deferred publish post-ack | Triage |
| 20 | P3 | 24 | F-13 MCP comptime strings | `src/mcp/lsp.zig:417-473` | [#784](https://gitlab.com/devnw/codepros/geode/geode/-/issues/784) | Drop `allocator.dupe` | Triage |
| 21 | P3 | 24 | F-16 Unify byte-scanners | 4× sites | [#770](https://gitlab.com/devnw/codepros/geode/geode/-/issues/770) (sub-task) | Single canonical scanner | Triage |
| 22 | P3 | 24 | F-17 Stack Content-Length buf | `src/cli/lsp/transport.zig:121-126` | [#766](https://gitlab.com/devnw/codepros/geode/geode/-/issues/766) | `bufPrint` to stack | Triage |
| 23 | P3 | 24 | F-23 DocumentStore LRU | `src/cli/lsp/document.zig:230-247` | [#781](https://gitlab.com/devnw/codepros/geode/geode/-/issues/781) | Bounded LRU cap=64 | Triage |
| 24 | P3 | 24 | F-24 Identifier case-fold | `src/cli/lsp/document.zig:114-227` | [#782](https://gitlab.com/devnw/codepros/geode/geode/-/issues/782) | Pre-normalized lowercase in index | Triage |

### Findings by Area

- **app::lsp:** 23 findings across #766, #770, #772, #776, #777, #779, #780, #781, #782, #786, #787, #789, #790, #792
- **app::mcp::lsp-bridge:** 2 findings folded into AST cache + comptime strings (#770, #784)

### Roadmap

**Quick Wins (< 1 day each, batched in #766)**

- F-01 debounce
- F-04 buffered transport
- F-09 static completion JSON (composes w/ #772)
- F-14 completion prefix-cap
- F-17 stack Content-Length buffer

**Medium (1-5 days)**

- #770 AST cache keystone (3-5d incl. sub-tasks F-05/06/12/15/16)
- #772 JSON WriteStream rewrite
- #777 Line offset table
- #779 Typo memoization
- #780 Scope.canonicalize arena

**Strategic (> 5 days, Tier-C)**

- #786 Incremental sync (rope) — 1-2 weeks
- #787 Typed JSON-RPC peel
- #789 cancelRequest preemption (also closes GAP-0816 functional)
- #790 Non-blocking dispatcher with worker pool
- #792 Async didOpen diagnostics
- #776 OTel — across all of the above

### OTel Plan Committed

`#776` carries the full OTel plan: 7 spans (`lsp.request`, `lsp.parse`, `lsp.diagnostics`, `lsp.semantic_tokens`, `lsp.completion`, `lsp.transport.read`, `mcp.lsp.tool_call`) + 7 metrics (`geode_lsp_request_duration_seconds`, `geode_lsp_parse_duration_seconds`, `geode_lsp_diagnostics_count`, `geode_lsp_completion_items_returned`, `geode_lsp_transport_read_syscalls_total`, `geode_lsp_doc_size_bytes`, `geode_lsp_open_documents`) with cardinality guards (no `uri` tagging; BLAKE2b-128 hash for span attrs; method allowlist; tail-sampling).

### Validation Plan (Phase 5)

Bench harness sketch (proposed in `#776`+follow-up):

- `benchmarks/lsp/bench_lsp_stdio.py` driving `./zig-out/bin/geode lsp` over stdio
- Fixtures `benchmarks/lsp/fixtures/*.gql` sized {1KB, 10KB, 50KB, 100KB}
- Workloads W1 (cold open), W2 (typing burst), W3 (modal), W4 (semanticTokens)
- A/B mode: alternating-rounds baseline vs. patched binary; emit JSON per workload with p50/p95/p99 + syscall counts
- SLOs: completion p95 <100ms (target 30ms); diagnostics-on-save p95 <500ms (target 50ms); semanticTokens p95 <200ms (target 30ms); hover p95 <50ms (target 5ms)

### 2026-05-06 LSP Tracking

- Created 15 GitLab issues: #766, #770, #772, #776, #777, #779, #780, #781, #782, #784, #786, #787, #789, #790, #792
- Cross-references: F-22↔quality-reviewer #2 (semanticTokens lexer dup); F-12↔GAP-0830 (MCP bridge contract); F-19/F-20↔GAP-0816 ($/cancelRequest); F-04/F-17↔GAP-0825 (transport conformance); F-11↔GAP-0826 (perf/stress baseline)
- Phase 3 perf review: `/tmp/lsp-audit-phase3/perf-reviewer.md`
- Phase 4 tracker: `/tmp/lsp-audit-phase4/perf-issue-tracker.md`

### 2026-05-06 closure pass — summary

| ID | Title | Commit | Status |
|---|---|---|---|
| F-01 | Debounce `didChange` diagnostics | `1603d9a1` | Closed |
| F-04 | Buffered stdin reader for LSP transport | `a0d52c9e` | Closed |
| F-02 | AST cache keystone (KEYSTONE) | n/a | Deferred to follow-up; #770 remains open with all sub-tasks (F-05/06/12/15/16) gated on this |

**Tier-A umbrella #766:** Partial closure — F-01 and F-04 closed; F-09 (static completion JSON), F-14 (completion prefix-cap), F-17 (stack Content-Length buffer) remain open as untouched sub-tasks. Issue stays open with checked sub-task list.

## 2026-05-15 — Performance review (Audit Phase 3)

Context: `/codepros:audit` Phase 3 perf-reviewer pass over execution engine, graph store, transport, and LSP hot paths. Reviewer produced 10 candidate findings; Phase 2 triage corrections demoted/folded 6 of them (see "Not tracked" below). Remaining 4 are evidence-based with verified file:line citations and explicit acceptance criteria. **PERF-A is the recommended `/bench-optimize` session candidate** (highest PerfScore, smallest measurement blast radius).

Triage corrections applied by reviewer before this section:

- The 9 full-scan sites in `match_operations.zig` (#1462, #1796, #2582, #2648, #2847, #3091, #3617, #4061, #5242) are **correct fallbacks** for unlabeled MATCH (the `labels.len == 0` branch with explicit `g_full_scan_count.fetchAdd` instrumentation from GAP-0522). Not unmigrated paths — a graph-scoped node-id index is the only viable fix (tracked as PERF-B).
- `user_store_mutex` is **not** hit on the RLS hot path. RLS uses `ExecutionContext.user` string, not `user_management.getUser`. Demoted.
- RLS Wyhash username cost is dwarfed by per-row HashMap rebuild — real bottleneck is row reconstruction (tracked as PERF-A).

### New findings

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|---|---|---:|---|---|---|---|---|---|
| 44 | P1 | 40 | RLS row rebuild dominates per-row cost — `nodePropertiesToRLSRowInto` rebuilds StringHashMap per row, 17 call sites | Execution / Security | `src/security/rls_value_bridge.zig:83-95`; 17 call sites in `src/execution/match_operations.zig` (entry `passesRLSExprFilter` at `:125`) | [#808](https://gitlab.com/devnw/codepros/geode/geode/-/issues/808) | Skip when bytecode has no `load_row` opcodes, or memoize by `(node.id, auth_version)`. **`/bench-optimize` candidate.** | Open (Triage) |
| 45 | P2 | 25 | Graph-scoped node-id list missing — unlabeled MATCH falls back to `read_store.nodes.iterator()` + `std.mem.eql(graph_name)` per node | Execution / Storage | `src/execution/match_operations.zig:1462,1796,2582,2648,2847,3091,3617,4061,5242` (9 sites; paired with `g_full_scan_count` from GAP-0522) | [#811](https://gitlab.com/devnw/codepros/geode/geode/-/issues/811) | Build per-graph `node_id` list as primary scan source; mirror GAP-0510 edge-type index discipline | Open (Triage) |
| 46 | P2 | 12 | LSP introspection full-store scan on TTL miss — O(N·L) per cache refresh | Graph store / LSP | `src/graph_store.zig:1042,1090,1160` | [#814](https://gitlab.com/devnw/codepros/geode/geode/-/issues/814) | Maintain label/property/type summary index updated on writes (write-amplification trade) | Open (Triage) |
| 47 | P2 | 12 | nanosleep admission/throttle waits — Zig 0.16 still has `std.Thread.Condition.timedWait` | Transport | `src/server/main.zig:1363-1365` (5ms admission busy-wait); `src/server/active_stream_registry.zig:84-91` (per-stream timeout fallback) | [#816](https://gitlab.com/devnw/codepros/geode/geode/-/issues/816) | Replace `nanosleep` with `Condition.timedWait` on existing signal path | Open (Triage) |

### Acceptance criteria (per finding)

**PERF-A (#808):** ≥ 10% reduction in `geode.query.execute` p50 on `match_authenticated_*` loadtest specs (OTel span scope `com.geodedb.geode`); no correctness regression in `gap_0510_rls_*` specs; `tests/test_rls_expr_engine_wiring.zig` continues to pass.

**PERF-B (#811):** `g_full_scan_count` drops to 0 for graph-scoped unlabeled MATCH workloads (verified via `match_log.warn` "MATCH+CALL full node scan" log absence and OTel logs in `reports/otel-collector.log`); OTel `geode.query.execute` p50 unchanged or improved on `point_read c=8`; `make test-everything-otel` clean.

**PERF-C (#814):** LSP completion p99 on a 1M-node graph stays < 50ms after TTL invalidation; no regression in `make loadtest-compare`; LSP spec coverage in `docs/LSP_FEATURES.md` unchanged.

**PERF-D (#816):** Under `c=32` admission saturation, p50 latency floor drops by ≥ 1ms; no oversubscription beyond `max_connections`; `make test-everything-otel` clean.

### Not tracked (Phase 3 triage)

| ID | Finding | Disposition |
|---|---|---|
| E | Per-row `std.mem.eql` on `node.graph_name` | Subset of PERF-B; deferred. Closes when PERF-B lands. |
| F | `for (node.labels) isLabelDenied` linear scan | Defer until label-deny mutex claim is verified under loadtest. No current contention evidence. |
| G | 5s metrics nanosleep | Cosmetic; PerfScore 0.5. Not tracked. |
| H | `StringHashMap` without `ensureTotalCapacity` micro-call sites | Micro; PerfScore 4.0. Not tracked. |
| I | `graph_handles_mutex` Tier-0 contention claim | No current loadtest evidence. Defer until reproduced. |
| J | `user_store_mutex` on RLS hot path | Demoted — RLS uses `ExecutionContext.user` string, not `user_management.getUser`. False positive. |

### Roadmap

- **Quick wins (< 1 day):** PERF-D (#816) — mechanical `nanosleep` → `Condition.timedWait` swap on two sites.
- **Medium (1-5 days):** PERF-A (#808) `requires_row` short-circuit (preferred initial scope); PERF-B (#811) graph-scoped node-id index (mirrors existing GAP-0510 edge-type index pattern).
- **Strategic (> 5 days):** PERF-C (#814) full label/property/type summary index with write-amplification trade; PERF-A (#808) `(node.id, auth_version)` memoization variant if short-circuit alone is insufficient.
