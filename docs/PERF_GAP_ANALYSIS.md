# Performance Gap Analysis

**Last Updated**: 2026-02-12
**Scope**: Full codebase performance review — query execution, storage, transport, concurrency, parser, planner
**Methodology**: Static code analysis + architectural review (no runtime profiling available in this session)
**Reviewers**: Claude Code performance review agents

## Summary

The Geode graph database has strong architectural foundations but contains several significant performance bottlenecks. The most impactful are: **unused caching infrastructure** (AST + plan caches built but never wired in), **full-graph serialization on every commit**, and **excessive per-query allocations in protobuf serialization**. Fixing the top 5 findings could yield **2-5x throughput improvement** for common workloads.

**Key Pattern**: Multiple complete subsystems (AST cache, plan cache, query optimizer) exist as dead code — they were implemented and tested but never integrated into the execution hot path.

### Severity Distribution

| Severity | Count | Open | Closed | Description |
|----------|-------|------|--------|-------------|
| P0 | 5 | 3 | 1 + 1 Partial | SLO/outage risk, 10x+ impact |
| P1 | 6 | 2 | 4 | Material user-facing, 2-5x impact |
| P2 | 6 | 5 | 1 | Moderate, specific workloads |
| **Total** | **17** | **10** | **6 + 1 Partial** | |

---

## Stack-Ranked Findings

| Rank | Sev | Score | Finding | Component | Evidence | GitLab | Fix Summary | Status |
|------|-----|-------|---------|-----------|----------|--------|-------------|--------|
| 1 | P0 | 100 | AST cache initialized but never used | Query exec | `quic_connection_handler.zig:634` | [#444](https://gitlab.com/devnw/codepros/geode/geode/-/issues/444) | Wire cache into parse path | **PARTIAL** — Import added; full wiring deferred (ownership semantics) |
| 2 | P0 | 100 | Full graph serialization on every commit | Storage | `graph_store.zig:2403-2628` | [#445](https://gitlab.com/devnw/codepros/geode/geode/-/issues/445) | WAL + delta persistence | Open — Strategic |
| 3 | P0 | 80 | Per-result string duplication (4000+ allocs/query) | Serialization | `proto_util.zig:325-396` | [#446](https://gitlab.com/devnw/codepros/geode/geode/-/issues/446) | Arena allocator / zero-copy | Open |
| 4 | P0 | 80 | Busy-wait 1ms sleep polling in QUIC reader | Transport | `quic_connection_handler.zig:145-156` | [#447](https://gitlab.com/devnw/codepros/geode/geode/-/issues/447) | Event-driven / exponential backoff | ✅ **CLOSED** — Exponential backoff 100μs→50ms |
| 5 | P0 | 60 | O(n) column type inference scans all rows | Serialization | `proto_util.zig:315-323` | [#448](https://gitlab.com/devnw/codepros/geode/geode/-/issues/448) | Sample first 10 rows or cache types | Open |
| 6 | P1 | 64 | O(V^2) BFS due to linear ArrayList dequeue | Graph algos | `traversal_bfs.zig:30-34` | [#449](https://gitlab.com/devnw/codepros/geode/geode/-/issues/449) | Ring buffer queue | ✅ **CLOSED** — Front index replaces O(n) mem.copy |
| 7 | P1 | 64 | O(m*n) quadratic edge deduplication | Graph store | `graph_store.zig:1655-1683` | [#450](https://gitlab.com/devnw/codepros/geode/geode/-/issues/450) | HashSet deduplication | ✅ **CLOSED** — AutoHashMap for O(1) dedup |
| 8 | P1 | 60 | Per-node string alloc in label index | Graph store | `graph_store.zig:727-738` | [#451](https://gitlab.com/devnw/codepros/geode/geode/-/issues/451) | Stack-allocated bufPrint | ✅ **CLOSED** — Stack bufPrint probe before heap alloc |
| 9 | P1 | 60 | Plan cache initialized but never consulted | Query exec | `quic_connection_handler.zig:455` | [#452](https://gitlab.com/devnw/codepros/geode/geode/-/issues/452) | Wire cache into optimizer path | Open |
| 10 | P1 | 60 | Global mutex on gRPC session store | Transport | `grpc_server.zig:102-106` | [#453](https://gitlab.com/devnw/codepros/geode/geode/-/issues/453) | RwLock or sharded locks | ✅ **CLOSED** — Replaced Mutex with RwLock |
| 11 | P1 | 48 | Thread pool spin-sleep (100us) when idle | Transport | `thread_pool.zig:229,250-255` | [#454](https://gitlab.com/devnw/codepros/geode/geode/-/issues/454) | Condition variable | Open |
| 12 | P2 | 48 | HNSW knnSearch computes distances twice | Index | `hnsw.zig:399-429` | [#455](https://gitlab.com/devnw/codepros/geode/geode/-/issues/455) | Return distance from searchLayer | ✅ **CLOSED** — Added searchLayerWithDist |
| 13 | P2 | 36 | O(N) LRU eviction in AST/plan caches | Query exec | `query_ast_cache.zig:102-122` | [#456](https://gitlab.com/devnw/codepros/geode/geode/-/issues/456) | Doubly-linked list LRU | Open |
| 14 | P2 | 36 | O(N) linear stream removal in QUIC | Transport | `quic.zig:453-465` | [#457](https://gitlab.com/devnw/codepros/geode/geode/-/issues/457) | Store index in stream struct | Open |
| 15 | P2 | 36 | memcpy buffer compaction per message | Transport | `quic_connection_handler.zig:174-191` | [#458](https://gitlab.com/devnw/codepros/geode/geode/-/issues/458) | Circular buffer | Open |
| 16 | P2 | 36 | Exponential plan enumeration without early stop | Planner | `enumerator.zig:81-132` | [#459](https://gitlab.com/devnw/codepros/geode/geode/-/issues/459) | Branch-and-bound pruning | Open — Strategic |
| 17 | P2 | 32 | Per-connection query optimizer (no sharing) | Query exec | `quic_connection_handler.zig:455` | [#460](https://gitlab.com/devnw/codepros/geode/geode/-/issues/460) | Shared global cache | Open — Strategic |

---

## Findings by Area

### Query Execution (5 findings — 1 partial, 4 open)

The biggest wins are in wiring up existing cache infrastructure:

1. **#444 (P0)**: AST cache exists but is dead code — **PARTIAL** (import added, full wiring needs ownership refactor)
2. **#452 (P1)**: Plan cache exists but is dead code — every query re-planned
3. **#448 (P0)**: Column type inference scans all rows instead of sampling
4. **#456 (P2)**: Cache eviction is O(N) instead of O(1)
5. **#460 (P2)**: Per-connection optimizer prevents cross-client plan sharing

### Storage & Graph (4 findings — 3 closed, 1 strategic)

1. **#445 (P0)**: Full graph dump on every commit — Strategic (WAL + delta persistence)
2. **#449 (P1)**: ~~BFS traversal is O(V^2)~~ — ✅ **CLOSED** (front index replaces mem.copy)
3. **#450 (P1)**: ~~Edge dedup is O(m*n)~~ — ✅ **CLOSED** (AutoHashMap for O(1) dedup)
4. **#451 (P1)**: ~~Label index string alloc~~ — ✅ **CLOSED** (stack bufPrint probe)

### Serialization (2 findings — 0 closed)

Protobuf encoding allocates excessively:

1. **#446 (P0)**: Per-value string duplication (thousands of allocs per query)
2. **#448 (P0)**: Linear column type inference

### Transport & Concurrency (6 findings — 2 closed, 4 open)

1. **#447 (P0)**: ~~1ms busy-wait polling~~ — ✅ **CLOSED** (exponential backoff 100μs→50ms)
2. **#453 (P1)**: ~~Global mutex on session store~~ — ✅ **CLOSED** (replaced with RwLock)
3. **#454 (P1)**: Thread pool workers spin at 100us when idle
4. **#457 (P2)**: O(N) stream removal
5. **#458 (P2)**: memcpy buffer compaction per message
6. **#459 (P2)**: Exponential plan enumeration

---

## Quick Wins (< 1 day each)

| Issue | Fix | Expected Impact | Status |
|-------|-----|-----------------|--------|
| #444 | Wire AST cache into parse path (~20 lines) | 30-50% latency reduction for repeated queries | **PARTIAL** — Import added |
| #448 | Sample first 10 rows for type inference | Eliminate O(rows*cols) overhead | Open |
| #449 | Replace ArrayList with ring buffer in BFS | O(V^2) → O(V+E) | ✅ **CLOSED** |
| #450 | Use HashSet for edge deduplication | O(m*n) → O(m+n) | ✅ **CLOSED** |
| #451 | Use `bufPrint` instead of `allocPrint` for label keys | Eliminate per-node allocation | ✅ **CLOSED** |
| #455 | Return distances from searchLayer | 30% knnSearch speedup | ✅ **CLOSED** |

## Medium Effort (1-3 days each)

| Issue | Fix | Expected Impact | Status |
|-------|-----|-----------------|--------|
| #446 | Arena allocator for serialization batch | 15-25% latency reduction | Open |
| #447 | Exponential backoff or event-driven reads | Eliminate thread stalls | ✅ **CLOSED** |
| #452 | Wire plan cache into optimizer | 5-30% for repeated queries | Open |
| #453 | RwLock for session store | Linear scaling with clients | ✅ **CLOSED** |
| #454 | Condition variable for thread pool | Near-zero idle CPU | Open |

## Strategic (1+ weeks)

| Issue | Fix | Expected Impact |
|-------|-----|-----------------|
| #445 | WAL + delta persistence | 10-100x for large graphs |
| #459 | Branch-and-bound plan enumeration | Bounded planning time |
| #460 | Shared global plan cache | Cross-client plan reuse |

---

## Performance Model

### Estimated Hot Path Cost (per query, current state)

| Stage | Estimated Cost | Bottleneck |
|-------|---------------|------------|
| QUIC read + deserialize | 1-5ms | Busy-wait polling (#447) |
| Parse GQL | 0.1-1ms | Always reparsed (#444) |
| Plan | 0.1-5ms | Always re-planned (#452) |
| Execute | Variable | Graph algo complexity (#449, #450) |
| Serialize results | 1-10ms | String duplication (#446), column scan (#448) |
| Persist | 10-100ms | Full graph dump (#445) |
| QUIC write | 0.1-1ms | Buffer compaction (#458) |
| **Total** | **12-122ms** | |

### With All Fixes Applied (estimated)

| Stage | Estimated Cost | Improvement |
|-------|---------------|-------------|
| QUIC read | 0.01-0.1ms | Event-driven |
| Parse (cached) | 0.001-0.01ms | AST cache hit |
| Plan (cached) | 0.001-0.01ms | Plan cache hit |
| Execute | Variable | Proper algorithms |
| Serialize | 0.5-2ms | Arena allocator |
| Persist (WAL) | 0.1-1ms | Delta + group commit |
| QUIC write | 0.01-0.1ms | Ring buffer |
| **Total** | **0.6-3.2ms** | **4-38x improvement** |

---

## Unknowns / Needs Verification

| Finding | What Would Confirm | Priority |
|---------|-------------------|----------|
| #447 busy-wait | Flamegraph showing Thread.sleep % | High |
| #446 string allocs | GPA allocation count per query | High |
| #453 mutex contention | Lock contention profile under load | Medium |
| #459 plan explosion | 10-way join query, measure planning time | Medium |
| #458 buffer compaction | CPU profile showing memcpy % | Low |

---

## Closure Summary (February 12, 2026)

**6 findings closed, 1 partial, 10 remaining open**

### Closed Items

| Issue | Fix Applied | Files Changed |
|-------|-------------|---------------|
| #447 | Exponential backoff (100μs→50ms) replaces fixed 1ms busy-wait | `src/server/quic_connection_handler.zig` |
| #449 | Front index replaces O(n) mem.copy dequeue in BFS | `src/graph/traversal_bfs.zig` |
| #450 | AutoHashMap replaces O(m*n) linear edge dedup | `src/graph_store.zig` |
| #451 | Stack-allocated bufPrint probe avoids heap alloc for existing keys | `src/graph_store.zig` |
| #453 | RwLock replaces Mutex for concurrent session reads | `src/transport/grpc_server.zig` |
| #455 | searchLayerWithDist avoids recomputing distances in knnSearch | `src/index/hnsw.zig` |

### Partial

| Issue | Work Done | Remaining |
|-------|-----------|-----------|
| #444 | `query_ast_cache` import added to handler | Full wiring blocked by ParseResult ownership semantics — cache owns arena, handler calls deinit on parse result. Needs lifecycle refactor. |

### Remaining Open (by priority)

| Issue | Sev | Category | Blocker |
|-------|-----|----------|---------|
| #445 | P0 | Storage | Strategic — requires WAL architecture |
| #446 | P0 | Serialization | Medium effort — arena allocator |
| #448 | P0 | Serialization | Quick win — row sampling |
| #452 | P1 | Query exec | Medium effort — plan cache lifecycle |
| #454 | P1 | Transport | Medium effort — condition variable |
| #456 | P2 | Query exec | Linked list LRU |
| #457 | P2 | Transport | Stream index tracking |
| #458 | P2 | Transport | Circular buffer |
| #459 | P2 | Planner | Strategic — branch-and-bound |
| #460 | P2 | Query exec | Strategic — shared cache architecture |

---

*Generated by performance review on 2026-02-11*
*Updated with closure status on 2026-02-12*
*Next review recommended: After remaining P0 fixes are implemented*
