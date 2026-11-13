# Performance Improvement Review

> **Project:** Geode Graph Database
> **Codebase:** 514 Zig files
> **Analysis Date:** 2026-01-27

## Executive Summary

This document presents performance improvement recommendations based on a comprehensive review of the Geode graph database codebase. The codebase already
 shows evidence of performance awareness with benchmarks, profiling, and optimization markers (`REQ-PERF-*` CANARY markers) throughout. The
recommendations focus on incremental improvements rather than architectural changes.

---

## 1. Memory Allocation Optimizations

**Evidence:** Found 1,802 instances of `defer...free` patterns

### Recommendations (measurable)

- Add per-query arenas for batch allocations (AST nodes, parse buffers, execution scratch).
- Pool or reuse frequently allocated structs (query contexts, row buffers) with explicit init/deinit tests.
- Replace repeated small allocations with bulk allocation or pre-sized buffers in hot paths.

### Acceptance criteria

- `zig build test` passes with leak detection.
- Allocation count or total bytes drop in a targeted microbenchmark (document baseline and delta).
- No regression in p95 latency on the existing single-query benchmark.

### CANARY

`// CANARY: REQ=REQ-PERF-ALLOC-001; FEATURE="ArenaAlloc"; ASPECT=Allocator; STATUS=TESTED; TEST=perf_alloc_arena; OWNER=perf; UPDATED=2026-01-27`

### Priority: High

### Impact: Reduced allocator overhead, improved cache locality

---

## 2. Collection Performance

**Evidence:** Extensive use of ArrayList and HashMap throughout the codebase

### Recommendations (measurable)

- Pre-size collections with `initCapacity` for known sizes and add `ensureTotalCapacity` before bulk appends.
- Replace per-item appends with `appendSlice` for contiguous batches in hot paths.
- Evaluate `ArrayHashMap` only where iteration dominates, and measure with a fixed dataset.

### Acceptance criteria

- Benchmarks show fewer reallocations (instrument with allocator stats or counters).
- p50/p95 latency improves or stays flat with reduced CPU time in the relevant benchmark.

### Priority: Medium

### Impact: Reduced memory reallocation, fewer copies

---

## 3. Hot Path Optimizations

**Evidence:**

- Adaptive backoff in main loop
- Log gating for hot paths
- Single parse optimization for queries

### Recommendations (measurable)

- Capture flamegraphs for `RETURN 1`, `MATCH`, and `ORDER BY` microbenchmarks and attach to the report.
- Add `@setCold(true)` on error paths and verify no hot-path regression in release builds.
- Prove hot paths are allocation-free or use pre-sized buffers with allocator stats.

### Acceptance criteria

- Flamegraph shows top hot functions with a documented baseline and post-change comparison.
- No statistically significant regression in p95 latency.

### Priority: High

### Impact: Direct latency reduction

---

## 4. Parser Optimizations

**Evidence:** Large parser file (296KB)

### Recommendations (measurable)

- Use per-query arena allocation for lexer tokens and AST nodes with a `reset` after execution.
- Intern identifiers and keywords only, and track hit/miss counters.
- Add a parse/AST cache keyed by query hash and record hit rate under repeated workloads.
- Measure parse time in `RETURN 1` and `MATCH` microbenchmarks before/after each change.

### Acceptance criteria

- Cache hit rate reported for repeated workloads (target: >80% for identical queries).
- Parse time reduced vs baseline on `RETURN 1` and `MATCH` microbenchmarks.

### Priority: Medium

### Impact: Faster query parsing, reduced memory for AST

---

## 5. Query Execution

**Evidence:** Match operations file is very large (318KB)

### Recommendations (measurable)

- Add early-termination tests for `LIMIT` and benchmark at 1, 10, 100 rows.
- Log chosen index vs. available indexes and measure with a fixed dataset to validate selection.
- Add a query-plan selection microbenchmark for `MATCH`, `ORDER BY`, `LIMIT`.
- Evaluate lazy evaluation only for path expressions with large expansions and measure with a dedicated benchmark.

### Acceptance criteria

- `LIMIT` benchmarks show reduced work and no correctness regressions.
- Index selection logs show consistent choice for known workloads.

### Priority: High

### Impact: Significant query latency improvement

---

## 6. I/O Performance

**Evidence:** The id map and hydration snapshot are memory-mapped. The "13.18x improvement" came from `src/performance/memory_mapped_io.zig`, which no server path uses (SONNY-6511); it is not evidence.

### Recommendations (measurable)

- Implement WAL batching and measure throughput under write-heavy workloads.
- Add read-ahead hints for sequential scans and track page-fault rate or read amplification.
- Consider direct I/O only after profiling shows cache pollution from large scans.

### Acceptance criteria

- Write throughput improves on `write_heavy` benchmarks without increasing p95 latency.

### Priority: Medium

### Impact: Better throughput under concurrent load

---

## 7. Index Performance

**Evidence:** B-tree and HNSW vector index implementations

### Recommendations (measurable)

- Implement bulk loading for B-tree and measure build time vs row-by-row insertion.
- Add adaptive index selection and measure query latency under mixed workloads.
- Optimize HNSW for batched operations and measure recall/latency trade-offs.
- Consider Bloom filters only if negative lookup rate is high and measurable.

### Acceptance criteria

- Bulk-load build time improves by a measurable margin on a fixed dataset.

### Priority: Medium

### Impact: Faster index operations, better query planning

---

## 8. Distributed Query

**Evidence:** Query coordinator implementation present

### Recommendations (measurable)

- Implement parallel shard fan-out and measure end-to-end latency on distributed benchmarks.
- Stream results instead of buffering for large result sets, and measure memory usage.
- Refine the cost model and validate with a fixed distributed workload.

### Acceptance criteria

- Distributed benchmarks show reduced tail latency without increasing error rate.

### Priority: Low (for single-node deployments)

### Impact: Better distributed query performance

---

## 9. SIMD Opportunities

**Evidence:** Vector operations already use SIMD

### Recommendations (measurable)

- Target SIMD in property filtering and string comparisons, with before/after microbenchmarks.
- Consider SIMD for hash computation only if profiling shows hash hotspots.

### Acceptance criteria

- SIMD microbenchmarks show measurable speedup without correctness regressions.

### Priority: Medium

### Impact: 2-8x improvement for vectorizable operations

---

## 10. Compilation Optimizations

### Recommendations (measurable)

- Use `-OReleaseSafe` for production default, and `-OReleaseFast` only for explicit performance runs.
- Enable PGO with representative workloads and record the before/after delta.
- Enable LTO for cross-module inlining and measure compile time impact.
- Use `-Dcpu=native` only for pinned deployment targets.

### Acceptance criteria

- Build settings are documented with a reproducible benchmark result.

### Priority: Low (one-time setup)

### Impact: 10-30% overall performance improvement

---

## Implementation Priority Matrix

| Category | Priority | Effort | Impact |
|----------|----------|--------|--------|
| Hot Path Optimizations | High | Medium | High |
| Memory Allocation | High | High | High |
| Query Execution | High | High | High |
| Collection Performance | Medium | Low | Medium |
| Parser Optimizations | Medium | Medium | Medium |
| I/O Performance | Medium | Medium | Medium |
| Index Performance | Medium | Medium | Medium |
| SIMD Opportunities | Medium | Medium | Medium |
| Compilation | Low | Low | Medium |
| Distributed Query | Low | High | Low* |

*Impact is Low for single-node deployments but High for distributed deployments

---

## Next Steps

1. **Profile first:** Run benchmarks with profiling to identify actual bottlenecks
2. **Quick wins:** Start with Collection Performance, WAL batching, and inline protocol handling
3. **Measure impact:** Benchmark before/after each optimization with fixed datasets
4. **Document changes:** Add `REQ-PERF-*` CANARY markers for new optimizations

---

## Completed Wins (2026-01-27)

- **Protocol parsing + inline RUN+PULL:** Inline schema+bindings to avoid extra PULL round-trips on small results. Implemented in `src/server/quic_connection_handler.zig`.
- **Shared AST cache:** Query hash keyed cache to avoid reparsing on repeated queries. Implemented in `src/server/query_ast_cache.zig`.
- **WAL flush batching:** Configurable commit flush modes (`GEODE_WAL_FLUSH_MODE`, `GEODE_WAL_FLUSH_EVERY_N`, `GEODE_WAL_FLUSH_WINDOW_MS`) to reduce fsync overhead under write-heavy workloads. Implemented in `src/wal/wal.zig` and `src/server/wal_manager.zig`.
- **Collection pre-sizing:** Pre-allocated row buffers for CALL/WITH pipelines and set operations to reduce reallocations in hot paths. Implemented in `src/execution/query_execution.zig` and `src/execution/set_operations.zig`.

---
