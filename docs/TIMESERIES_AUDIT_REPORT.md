# Timeseries Subsystem — Full Audit Report

**Date:** 2026-04-01
**Scope:** `src/timeseries/`, `tests/*timeseries*`, `src/benchmarks/bench_timeseries.zig`, integration points in `src/eval.zig`, `src/exec.zig`, `src/value_types.zig`, `src/gql/main.zig`, external `timeseries` library v0.1.0
**Auditor:** Automated 4-domain audit (gap analysis, code quality, performance, security)

---

## Executive Summary

The timeseries subsystem is **not production-ready** despite documentation claims. The core finding is architectural: the subsystem exists in three disconnected layers with no working end-to-end path through the production server.

| Metric | Value |
|--------|-------|
| Source files | 3 (607 lines) |
| Test files | 3 (531 lines) — **all dead code** (not registered in build.zig) |
| Requirements traced | 52 |
| Implemented + tested | 24 (Geode-level) |
| Critical gaps | 2 |
| High gaps | 2 |
| Total gaps | 14 |
| Security findings | 12 (5 HIGH, 5 MEDIUM, 2 LOW) |
| Performance findings | 17 (2 CRITICAL, 5 HIGH, 5 MEDIUM, 5 LOW) |
| Quality findings | 9 major issues |

### Top 3 Blockers

1. **All test files are dead code** — `tests/e2e_timeseries.zig`, `tests/ts_store_integration.zig`, and `src/benchmarks/bench_timeseries.zig` are not registered in `build.zig`. The 13+ test functions have never been compiled or run.
2. **Server path not wired** — `timeseries.value()` returns NULL for all QUIC/gRPC queries because the server never initializes or passes a `timeseries_store`.
3. **gql_functions.zig is entirely disconnected** — Defines 8 GQL functions with incompatible `Value` types that cannot interoperate with the eval pipeline. 7 of 8 functions are unreachable from GQL queries.

---

## Repository

- **Project:** Geode Graph Database
- **Platform:** GitLab (`gitlab.com/devnw/codepros/geode/geode`)
- **Languages:** Zig 0.15.1
- **Scope:** Timeseries subsystem + integration points
- **External dependency:** `timeseries` v0.1.0 (commit `0103cf25`, pinned in `build.zig.zon:226-228`)

---

## Domain Results

### 1. Gap Analysis

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented + Tested | 24 | 46% |
| Implemented, Not Tested | 8 | 15% |
| Partial | 1 | 2% |
| Not Implemented (server wiring) | 2 | 4% |
| Not Implemented (signal analysis) | 15 | 29% |
| Not Wired (library available) | 9 | — |

**Open gaps:** 14 (Critical: 2, High: 2, Medium: 6, Low: 4)

**Critical gaps:**

| Gap-ID | Title | Impact |
|--------|-------|--------|
| GAP-0279 | Test files not registered in build.zig | Zero test coverage — 13+ tests never compiled |
| GAP-0280 | Server path not wired | `timeseries.value()` returns NULL in production |

**High gaps:**

| Gap-ID | Title | Impact |
|--------|-------|--------|
| GAP-0281 | Zero CANARY governance tokens | Invisible to project governance system |
| GAP-0282 | gql_functions.zig incompatible types | 7 of 8 GQL functions unreachable |

**Medium gaps:**

| Gap-ID | Title |
|--------|-------|
| GAP-0283 | derivative() only 1st order — higher orders silently return NULL |
| GAP-0284 | SUM/FIRST/LAST aggregations untested |
| GAP-0285 | value_at and time_bucket have no dedicated tests |
| GAP-0287 | Benchmarks not in CI |
| GAP-0291 | Documentation claims production-ready — contradicts reality |
| GAP-0292 | Timeseries store is ephemeral in-memory only — no persistence |

**Low gaps:** GAP-0286 (interpolate step/nearest untested), GAP-0288 (legacy GAP IDs untracked), GAP-0289 (15 signal analysis reqs unimplemented), GAP-0290 (9 library capabilities unexposed)

---

### 2. Code Quality

| Category | Count |
|----------|-------|
| Dead Code / Unreachable | 4 |
| Type Mismatch / API Violation | 4 |
| Complexity / Duplication | 4 |
| Memory Management | 3 |
| Build/CI | 4 |

**Top findings:**

| # | Finding | Severity | File |
|---|---------|----------|------|
| Q1 | `gql_functions.zig` is entirely dead from production build | Critical | `src/timeseries/gql_functions.zig` |
| Q2 | `chunk_storage.zig` is dead from production build | High | `src/timeseries/chunk_storage.zig` |
| Q3 | Local `Value` type structurally incompatible with `value_types.Value` | Critical | `gql_functions.zig:6-14` |
| Q4 | `executeFunction` is 254 lines (limit: 50) with 5 nesting levels | High | `gql_functions.zig:76-329` |
| Q5 | Encapsulation violation: `store.by_key.get(store.hashKey(key))` x5 | Medium | `gql_functions.zig:92+` |
| Q6 | Zero `errdefer` — all allocations leak on error | High | `gql_functions.zig` |
| Q7 | `timeseries_store` always null in server path (silent data loss) | Critical | `src/server/`, `src/execution/` |
| Q8 | Unused import (`chunk_storage` in gql_functions.zig line 3) | Low | `gql_functions.zig:3` |
| Q9 | `PointF64` re-exported but never used | Low | `timeseries.zig:10` |

---

### 3. Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 (Critical) | 2 |
| P1 (High) | 5 |
| P2 (Medium) | 5 |
| P3 (Low) | 5 |

**Top findings:**

| # | Finding | Severity | Impact | File |
|---|---------|----------|--------|------|
| P1 | `moving_avg` O(n*m) quadratic nested loop | P0 | 1M pts + 10K steps = 10B iterations | `gql_functions.zig:236-247` |
| P2 | No concurrency safety on Store | P0 | Data race / crash under concurrent access | External `store.zig` |
| P3 | `sampleBy`/`timeBucketAvg` full scan from index 0 | P1 | 99% wasted iterations for tail queries | External `store.zig:245,305` |
| P4 | `queryRange` full decompression then filter | P1 | 4086 of 4096 points decoded and discarded | External `chunk_storage.zig:519` |
| P5 | Full pdq sort on any insertion overlap | P1 | O(n log n) for 1 late point in 1M series | External `store.zig:168` |
| P6 | Per-row `StringHashMap` allocation | P1 | 10K+ small heap allocs per query | `gql_functions.zig:116+` |
| P7 | Dual Wyhash per key lookup | P1 | 3 hash computations per access | External `store.zig:106` |
| P8 | `interpolate` linear scan O(n) | P2 | Should be O(log n) binary search | `gql_functions.zig:170` |
| P9 | Benchmark never run — no baselines | P2 | >10M pts/sec claims unverified | `bench_timeseries.zig` |

---

### 4. Security

| Risk Level | Count |
|-----------|-------|
| High | 5 |
| Medium | 5 |
| Low | 2 |

**Immediate actions required:** 0 (no active secrets or exploitable production paths — findings are latent until server integration)

**Top findings:**

| # | Finding | Severity | CWE | File |
|---|---------|----------|-----|------|
| S1 | BOLA — no authz on `timeseries.value()` | HIGH | CWE-639 | `eval.zig:876-878` |
| S2a | Unbounded `sampleBy` bucket allocation (OOM) | HIGH | CWE-770 | External `store.zig:217` |
| S2c | Infinite loop in `moving_avg` (step_ms=0) | HIGH | CWE-835 | `gql_functions.zig:236` |
| S3 | No thread safety on Store | HIGH | CWE-362 | External `store.zig` |
| S4 | `exec.zig` threads store without RLS | HIGH | CWE-862 | `exec.zig:321,465` |
| S5 | `@constCast` on const Store pointer | MEDIUM | CWE-704 | `eval.zig:865` |
| S6 | Integer overflow in bucket calculation | MEDIUM | CWE-190 | External `store.zig:217` |
| S7 | Incomplete path traversal in ChunkStorage | MEDIUM | CWE-22 | External `chunk_storage.zig:413` |
| S8 | Memory leaks — no Value.deinit() | MEDIUM | CWE-401 | `gql_functions.zig` |
| S9 | Gorilla decoder trusts `num_points` metadata | MEDIUM | CWE-789 | External `chunk_storage.zig:257` |

**Key context:** The timeseries store is NOT currently wired to the production server. All security findings are **latent** — they become exploitable once GAP-0280 is resolved. The demo CLI path (`src/gql/main.zig`) IS affected.

---

## Cross-Domain Summary

| Domain | Findings | Gaps/Issues |
|--------|----------|-------------|
| Gap Analysis | 52 requirements traced | 14 gaps (2 Critical, 2 High) |
| Quality | 9 major findings | Dead code, type mismatches, memory leaks |
| Performance | 17 findings | 2 P0 (quadratic algo, data race), 5 P1 |
| Security | 12 findings | 5 HIGH (BOLA, DoS, data race, no RLS) |

---

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/TIMESERIES_REQUIREMENTS_INVENTORY.md` | Gap | Created (52 requirements) |
| `docs/TIMESERIES_AUDIT_REPORT.md` | All | Created (this file) |

---

## Top 10 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | Gap-ID |
|---|--------|---------|----------|--------|
| 1 | Gap | Test files not registered in build.zig — zero coverage | Critical | GAP-0279 |
| 2 | Gap | Server path not wired — production queries return NULL | Critical | GAP-0280 |
| 3 | Security | BOLA — any user queries any device's timeseries data | HIGH | — |
| 4 | Security | Infinite loop DoS in moving_avg (step_ms=0) | HIGH | — |
| 5 | Perf | moving_avg O(n*m) quadratic — unusable at scale | P0 | — |
| 6 | Security | No thread safety — data race under concurrent access | HIGH | — |
| 7 | Quality | gql_functions.zig entirely dead — incompatible types | Critical | GAP-0282 |
| 8 | Security | Unbounded sampleBy bucket allocation — OOM kill | HIGH | — |
| 9 | Gap | Zero CANARY tokens — invisible to governance | High | GAP-0281 |
| 10 | Perf | sampleBy/timeBucketAvg full scan on sorted data | P1 | — |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│  QUIC/gRPC Server                                       │
│  ┌─────────────────────────────────────────────────┐    │
│  │ quic_connection_handler.zig                      │    │
│  │   └─> executeProgramWithContext(...)             │    │
│  │        └─> Env { timeseries_store: null }  ← ❌ │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ eval.zig:862-890 (PRODUCTION PATH)              │    │
│  │   "timeseries.value(device_id, metric, ts)"     │    │
│  │    └─> env.timeseries_store == null → Null  ← ❌│    │
│  │    └─> store.getSeries(key).valueAt(ts) ← ✅   │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ gql/main.zig (CLI TEST PATH ONLY)          ← ✅│    │
│  │   var ts_store = Store.init(ally);              │    │
│  │   Env { timeseries_store: &ts_store }           │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ gql_functions.zig (DEAD CODE)              ← ❌ │    │
│  │   8 function types, own Value/Expression types  │    │
│  │   Not imported by any production module          │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ External timeseries lib v0.1.0                  │    │
│  │   Store, Series, ChunkStorage, DTW, PELT, etc.  │    │
│  │   No mutex, no authz, no memory limits          │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## Recommended Remediation Order

### Phase A: Foundation (prerequisite for all other work)

1. **GAP-0279** — Register test files in `build.zig` (~20 lines)
2. **GAP-0280** — Wire `timeseries_store` through server execution path (~100 lines)

### Phase B: Security hardening (before production use)

1. Add authorization context to timeseries eval path (S1, S4)
2. Add `RwLock` to Store (S3, P2)
3. Validate `step_ms > 0` in moving_avg (S2c)
4. Cap `n_buckets` in sampleBy (S2a)
5. Fix `@constCast` — make Store methods accept `*const Store` (S5)

### Phase C: Integration & correctness

1. **GAP-0282** — Replace temporary Value types, wire 7 remaining GQL functions
2. **GAP-0283** — Implement or error on derivative order > 1
3. **GAP-0284/0285/0286** — Add missing tests
4. **GAP-0281** — Add CANARY tokens

### Phase D: Performance

1. Replace moving_avg O(n*m) with sliding window O(n+s) (P1)
2. Binary search skip in sampleBy/timeBucketAvg (P3)
3. Streaming decode in queryRange (P4)
4. Merge-insert instead of full pdq sort (P5)
5. Replace per-row StringHashMap with flat struct output (P6)

### Phase E: Persistence & infrastructure

1. **GAP-0292** — Wire ChunkStorage to Store for persistence
2. **GAP-0287** — CI benchmark integration
3. **GAP-0291** — Documentation corrections

---

## Blockers

- **Semgrep has no Zig support** — all SAST was manual code review
- **External library fixes required** — findings P2, P3, P4, P5, P7, S3, S5, S6, S7, S9 require upstream changes at `gitlab.com/devnw/zig/timeseries`
- **Build.zig registration (GAP-0279)** is prerequisite for validating any timeseries fixes

---

*Generated by automated 4-domain audit pipeline. All findings confirmed against source code.*
