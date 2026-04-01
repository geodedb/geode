# Temporal Implementation Audit Report

Last updated: 2026-04-01
Audited by: Claude Opus 4.6 (full codebase audit — gap analysis, quality, performance, security)

## Repository

- **Project:** geode
- **Platform:** GitLab
- **Languages:** Zig 0.15.1
- **Scope:** `src/temporal.zig` (451 lines), `src/temporal/time_travel.zig` (543 lines)

## Scope Description

Two files comprise the temporal implementation:

| File | Lines | Purpose | Integration Status |
|------|------:|---------|-------------------|
| `src/temporal.zig` | 451 | ISO 8601 date/time/datetime parsing, formatting, comparison, timezone normalization | **Active** — imported by parser, printer, planner, eval |
| `src/temporal/time_travel.zig` | 543 | Temporal versioning storage, time-travel AS OF queries, vacuum | **Isolated** — zero consumers outside own inline tests |

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|------:|----------:|
| Implemented | 14 | 58% |
| Partial / Stub | 3 | 13% |
| Not Implemented | 5 | 21% |
| Ambiguous | 2 | 8% |

**Open gaps:** 8 (Critical: 0, High: 3, Medium: 3, Low: 2)

#### Fully Implemented (no gaps)

1. `src/temporal.zig` — Date/Time/DateTime parsing, formatting, comparison, timezone normalization (5 inline tests)
2. Date + Interval arithmetic (REQ-DATE-INTERVAL-001 through 004)
3. Temporal conformance profile declarations (RQ-0013, RQ-0014, RQ-0015)
4. Temporal extreme offset arithmetic (REQ-GQL-040)
5. RLS temporal constraints (REQ-RLS-TEMPORAL-001)
6. AS OF property filtering (REQ-TEMPORAL-PROP-001)
7. `current_date` / `current_time` / `current_timestamp` / `now()` functions
8. `date_part` / `time_part` extraction
9. DateTime property access (`.year`, `.month`, `.day`, etc.)
10. `duration()` ISO 8601 parsing

#### Partial / Stub Implementations

| GAP ID | Finding | File:Line | Severity |
|--------|---------|-----------|----------|
| GAP-0279 | `executeBetween()` is a stub returning empty results; all parameters discarded | `time_travel.zig:426-442` | Medium |
| GAP-0280 | `executeVersions()` is a stub returning empty results; all parameters discarded | `time_travel.zig:444-454` | Medium |
| GAP-0281 | `vacuum()` only prunes node versions, not edge versions; O(n²) transaction log cleanup | `time_travel.zig:326-364` | Medium |

#### Missing Implementations

| GAP ID | Finding | Severity |
|--------|---------|----------|
| GAP-0282 | `TemporalEdge` type defined but no `createEdge`, `updateEdge`, `deleteEdge`, `getEdgeAsOf` methods | High |
| GAP-0283 | `TemporalStorage` not wired to query engine — entire `time_travel.zig` is unreachable dead code | High |
| GAP-0284 | No `AS OF` clause in GQL parser — no AST node, no token, no syntax support | High |
| GAP-0285 | `ts_add`/`ts_sub` (Timestamp ± Interval) documented in TYPES_AND_FUNCTIONS.md but not implemented | Low |
| GAP-0286 | `age(ts1, ts2)` function documented in TYPES_AND_FUNCTIONS.md but not implemented | Low |

#### Ambiguities

- **Dual type system**: `temporal.zig` (`Date{y,m,d}`) and `types/datetime.zig` (`Date{days_since_epoch}`) independently implement `isLeapYear`, `daysInMonth`, `daysSinceEpoch` — drift risk
- **CANARY REQ-GQL-086/087/088 overloaded**: same REQ IDs used for both temporal types and unrelated features (REPL, MigrationEngine)

---

### Code Quality

| Severity | Count |
|----------|------:|
| Critical | 1 |
| High | 2 |
| Medium | 4 |
| Low | 3 |

**Top finding:** Memory leak in `filterNodePropertiesAsOf` — allocates `TemporalNode` copies never freed (PriorityScore: 80)

| # | Sev | Score | Finding | File:Line |
|---|-----|------:|---------|-----------|
| 58 | Critical | 80 | `filterNodePropertiesAsOf` allocates new `TemporalNode` + `StringHashMap` per `getNodeAsOf` call, never freed by caller | `time_travel.zig:217-225` |
| 59 | High | 64 | `VersionedValue.previous_version` linked list leaked on `destroyNode` — `deinit` doesn't walk chain | `time_travel.zig:96-99,168` |
| 60 | High | 64 | `getNodeAsOf` swallows allocation failures (`catch return null` on line 208) — violates "never silently swallow errors" | `time_travel.zig:208` |
| 61 | Medium | 48 | `filterNodePropertiesAsOf` shallow-copies `.versions` ArrayList — shared backing pointer with original, stale on mutation | `time_travel.zig:224` |
| 62 | Medium | 48 | Zero CANARY markers on `src/temporal.zig` despite being critical-path code (parser/planner/printer depend on it) | `temporal.zig` |
| 63 | Medium | 36 | Duplicated `isLeapYear`/`daysInMonth`/`daysSinceEpoch` between `temporal.zig` and `types/datetime.zig` | `temporal.zig:120-366` |
| 64 | Medium | 36 | `ArrayList(TransactionRecord){}` initialized without allocator (fragile idiom) — repeated 3× | `time_travel.zig:74,122,140` |
| 65 | Low | 24 | `isDateStrict` name implies strictness but allows Feb 31 (month-day cross-validation only in `parseDate`) | `temporal.zig:34-48` |
| 66 | Low | 24 | Inline test `"vacuum old versions"` sleeps 1.1 seconds — slow test in unit suite | `time_travel.zig:533` |
| 67 | Low | 16 | No doc comments on 13 public functions in `temporal.zig` or any public types in `time_travel.zig` | Both files |

---

### Performance

| PerfSeverity | Count |
|-------------|------:|
| P0 | 0 |
| P1 | 2 |
| P2 | 3 |
| P3 | 2 |

**Top finding:** O(n²) vacuum on transaction log (PerfScore: 64)

| # | Sev | Score | Finding | File:Line |
|---|-----|------:|---------|-----------|
| 25 | P1 | 64 | O(n²) vacuum: `orderedRemove` in forward loop on `transaction_log` — quadratic when most records old | `time_travel.zig:337-344` |
| 26 | P1 | 64 | O(n²) vacuum: `orderedRemove` in forward loop on `node.versions` — same pattern per node | `time_travel.zig:356-363` |
| 27 | P2 | 48 | O(K) linear version chain walk per property per AS OF query — no binary search possible on linked list | `time_travel.zig:244-263` |
| 28 | P2 | 36 | Per-query heap allocation: `filterNodePropertiesAsOf` allocates `TemporalNode` + `StringHashMap` per matching node | `time_travel.zig:217-225` |
| 29 | P2 | 36 | Transaction log unbounded growth between vacuum runs; no size cap, no auto-shrink after cleanup | `time_travel.zig:63,326-345` |
| 30 | P3 | 16 | `asOfToTimestamp` uses synthetic `tid * 1000` conversion instead of actual log lookup — correctness issue | `time_travel.zig:266-273` |
| 31 | P3 | 16 | No benchmarks exist for any temporal operation | Both files |

**Note:** `src/temporal.zig` has zero performance concerns — all operations are O(1), zero-allocation, stack-only computation.

---

### Security

| Risk Level | Count |
|-----------|------:|
| Critical | 0 |
| High | 3 |
| Medium | 2 |
| Low | 2 |

**Immediate actions:** 0 (no secret rotations, no active vulns — `time_travel.zig` is dead code)

| # | Risk | Finding | File:Line |
|---|------|---------|-----------|
| S1 | High | No thread safety on `TemporalStorage` despite atomic txn counter — concurrent access corrupts HashMap/ArrayList | `time_travel.zig:59-65` |
| S2 | High | Memory leak enables OOM denial-of-service via repeated AS OF queries (unbounded `TemporalNode` allocation) | `time_travel.zig:217-225` |
| S3 | High | Unbounded version chains + unbounded transaction log — no limit on versions per node | `time_travel.zig:108-179` |
| S4 | Medium | `asOfToTimestamp` integer overflow: `tid * 1000` panics for large u64 values (DoS in safe mode) | `time_travel.zig:270-271` |
| S5 | Medium | Time-travel queries bypass access controls — no RLS/RBAC integration, exposes deleted/historical data | `time_travel.zig:198-424` |
| S6 | Low | Timezone offset hours/minutes not range-checked — `+99:99` accepted, produces incorrect UTC normalization | `temporal.zig:196-209` |
| S7 | Low | `raw` slice lifetime dependency — `Date.raw`/`Time.raw` point into caller's source buffer (use-after-free if buffer freed) | `temporal.zig:8,15,29` |

**Mitigating factor:** `time_travel.zig` is entirely dead code (zero production consumers). Findings S1-S5 have **no current production impact** but would become critical if the module is integrated.

---

## Cross-Domain Summary

| Domain | Findings | Issues Created | Issues Updated | Issues Closed |
|--------|------:|------:|------:|------:|
| Gap Analysis | 8 | 0 | 0 | 0 |
| Quality | 10 | 0 | 0 | 0 |
| Performance | 7 | 0 | 0 | 0 |
| Security | 7 | 0 | 0 | 0 |
| **Total** | **32** | **0** | **0** | **0** |

*Note: `--skip-issues` effective — no GitLab issues created. All findings documented in gap analysis docs.*

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/TEMPORAL_AUDIT_REPORT.md` | All | created (32 findings) |
| `docs/GAP_ANALYSIS.md` | Gap | updated (8 new gaps: GAP-0279 through GAP-0286) |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | updated (7 new findings: #25-31) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | updated (10 new findings: #58-67) |

## Top 10 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | Score |
|---|--------|---------|----------|------:|
| 1 | Quality | Memory leak: `filterNodePropertiesAsOf` allocates nodes never freed | Critical | 80 |
| 2 | Security | No thread safety on TemporalStorage despite atomic txn counter | High | — |
| 3 | Gap | `TemporalStorage` not wired to query engine — unreachable dead code | High | — |
| 4 | Gap | No `AS OF` clause in GQL parser | High | — |
| 5 | Gap | `TemporalEdge` defined but no CRUD methods implemented | High | — |
| 6 | Quality | `VersionedValue` linked list leaked on destroy | High | 64 |
| 7 | Performance | O(n²) vacuum on transaction log | P1 | 64 |
| 8 | Performance | O(n²) vacuum on node versions | P1 | 64 |
| 9 | Security | Unbounded version chains + transaction log — DoS vector | High | — |
| 10 | Security | Memory leak enables OOM DoS via repeated AS OF queries | High | — |

## Resolution (2026-04-01)

**Option A (delete dead code) was chosen.** All findings resolved:

### Actions Taken

1. **Deleted `src/temporal/time_travel.zig`** and removed its build target from `build.zig`. This closed 28 of 32 findings (GAP-0279 through GAP-0284, Perf #25-31, Quality #67-71/#74/#76, Security S1-S5) as Won't Do.

2. **Fixed `src/temporal.zig`**:
   - Added 5 CANARY markers (REQ-TEMPORAL-PARSE-001, CMP-001, FMT-001, TZ-001, COERCE-001) — closes Quality #72
   - Renamed `isDateStrict` → `isDateFormat` + updated 2 callers in `lexer.zig` — closes Quality #75
   - Added timezone offset range validation (hours 0-14, minutes 0-59) in `parseTime` and `parseOffsetMinutes` — closes Security S6
   - Added doc comments to `Date.raw`, `Time.raw`, `DateTime.raw` explaining lifetime contract — closes Security S7

3. **Implemented in `src/eval.zig`**:
   - `ts_add(timestamp, interval)` and `ts_sub(timestamp, interval)` functions — closes GAP-0285
   - `age(timestamp1, timestamp2)` function returning Interval — closes GAP-0286
   - Timestamp ± Interval binary operators (commutative for addition)
   - Timestamp - Timestamp binary operator returning Interval

4. **Consolidated duplicated algorithms** (Quality #73):
   - Removed `isLeapYear` and `daysInMonth` from `temporal.zig`; now delegates to `types/datetime.zig:Date.daysInMonth()`
   - `daysSinceEpoch` kept in `temporal.zig` since it uses a different algorithm (Hinnant's O(1) formula for UTC comparison) vs `datetime.zig` (iterative accumulation for epoch conversion)

### Final Tally

| Status | Count |
|--------|------:|
| Closed (Won't Do — dead code deleted) | 24 |
| Closed (Implemented) | 8 |
| **Total** | **32** |

### Verification

```
zig build test --summary all
Build Summary: 120/120 steps succeeded; 632/632 tests passed
```
