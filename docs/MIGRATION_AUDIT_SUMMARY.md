# Full Codebase Audit Summary — Migration Engine

**Date:** 2026-04-01 (re-audit)
**Auditor:** Claude Code (Opus 4.6)
**Scope:** `src/migration/mod.zig` (955 lines)

---

## Repository

- **Project:** devnw/codepros/geode/geode
- **Platform:** GitLab
- **Languages:** Zig 0.15.1
- **Scope:** Migration engine module (`src/migration/`)

---

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|------------|
| Closed / Implemented | 23 | 64% |
| Won't Do | 13 | 36% |
| Open | 0 | 0% |

**Prior tally:** 23 closed via implementation, 13 deferred as Won't Do. However, re-audit found **4 closures are incorrect** and **5 new gaps**:

**False closures (claimed fixed, not actually fixed):**

| GAP | Claimed Fix | Actual State |
|-----|-------------|-------------|
| GAP-0279 | CANARY tests "resurrected" and "added to build.zig" | Files exist but NOT in build.zig; imported as unused `const _` in all_tests.zig; `migration` module not provided. **Dead code.** |
| GAP-0281 | `applyDownMigrations` "respects names parameter" | Parameter is `_: []const []const u8` (line 432). Doc comment says "unused." |
| GAP-0290 | `lock_steal_attempts_total` "metric now incremented" | Never incremented anywhere. Comment says "Currently never incremented." |
| GAP-0296 | `checksumValidate` "bidirectional check" | Only checks `matched == applied_count`. Extra manifest entries silently skipped. |

**CANARY marker audit — all 6 markers claim STATUS=TESTED, none are accurate:**

| Aspect | Referenced Test | Status |
|--------|----------------|--------|
| Core | `geodetestlab/specs/geode_migrations.yml` | Phantom — file does not exist |
| ObservabilityMetrics | `TestCANARY_REQ_GQL_087_ObservabilityMetrics` | Dead code — not compiled |
| DownReversalSafety | `TestCANARY_REQ_GQL_087_DownReversalSafety` | Dead code — not compiled |
| PlanDryRunIntegrity | `TestCANARY_REQ_GQL_087_PlanDryRunIntegrity` | Dead code + name mismatch |
| CliParityStatusCommand | `TestCANARY_REQ_GQL_087_CliParityStatusCommand` | Dead code — not compiled |
| DriftPolicyOutcomeStrict | `TestCANARY_REQ_GQL_087_DriftPolicyOutcomeStrict` | Dead code — not compiled |

**New gaps discovered:**

| ID | Description | Severity |
|----|-------------|----------|
| NEW-GAP-1 | `baseline_override` (line 93) accessed without mutex in `driftCheck`/`testSimulateDrift` | Medium |
| NEW-GAP-2 | `applyUpMigrations` gives no indication of which migrations succeeded on partial failure | Low |
| NEW-GAP-3 | `resumeDataMigration` leaks token memory (no cleanup path) | Low |
| NEW-GAP-4 | `StatusRow.name` default is `"stub"` (string literal); `freeStatusRows` will free it = UB | Medium |
| NEW-GAP-5 | `saveLedger` tmp file closed after rename via defer (ordering concern) | Low |

### Code Quality

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | -- |
| High | 3 | New findings |
| Medium | 5 | New findings |
| Low | 5 | New findings (2 prior open: #621, #624) |

**Quality scores (re-assessment vs prior):**

| Dimension | Prior | Current | Delta |
|-----------|-------|---------|-------|
| Readability | 6/10 | 7/10 | +1 (JSON escaping, errdefer fixes) |
| Maintainability | 4/10 | 5/10 | +1 (mutex added; still 955-line monolith) |
| Reliability | 3/10 | 5/10 | +2 (locking, path validation, owned strings) |
| API Contract | 4/10 | 5/10 | +1 (improved ownership; stringly-typed policy, unused params remain) |

**Top quality findings (new):**

| # | Finding | Severity | Line |
|---|---------|----------|------|
| Q1 | Hand-rolled JSON serializer (35 lines of brittle string concatenation) | High | 235-269 |
| Q2 | 955-line single file with 8+ concerns (exceeds 800-line guideline) | High | 1-955 |
| Q3 | `loadLedger` leaks `name_copy` on OOM in `rows.append` (no errdefer) | High | 196-202 |
| Q4 | `applyDownMigrations` accepts unused `names` parameter | Medium | 429-433 |
| Q5 | Lock ID hardcoded to 1; `owner` always `"local"` — identity check is dead code | Medium | 333 |
| Q6 | `enforcePolicy` uses raw strings instead of `PolicyMode` enum | Medium | 551-562 |
| Q7 | `MigrationPlan`/`StatusRow` return types lack ownership semantics | Medium | 46-49 |
| Q8 | Magic numbers without named constants (17, 4MB, 8MB, 300000, 4096) | Medium | various |
| Q9 | No integration tests for core API (apply/rollback/status/plan/drift) | Low | 729-955 |
| Q10 | `baseline_override` unsynchronized (test-only) | Low | 93 |
| Q11 | Policy tests mutate global state without isolation | Low | 795-817 |
| Q12 | FNV-1a constants duplicated without named constants | Low | 122, 141 |
| Q13 | Resume token lifecycle undocumented; `total_batches` hardcoded to 5 | Low | 675-703 |

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 | 0 |
| P1 | 0 |
| P2 | 0 |
| P3 | 8 (all informational) |

**Verdict:** No actionable performance issues. All P3 findings are correctly calibrated — migration engine is an admin-time tool running on tens of files. Linear scans, per-migration fsync (crash-safety by design), and 4-8MB read caps are all appropriate.

**Prior PERF-577 through PERF-594 "Won't Do" disposition: confirmed correct.**

**PerfScore top finding:** Resume token memory leak (P3, bounded to 8 allocations of short strings — <1KB total).

### Security

| Risk Level | Count | Status |
|-----------|-------|--------|
| High | 1 | Reconfirmed (GQL injection #598, Won't Do) |
| Medium | 3 | 1 reconfirmed + 2 new |
| Low | 4 | 4 new |

**7 prior findings verified FIXED:** #572 path traversal, #592 JSON injection, #606 TOCTOU lock, #602 integer overflow, #622 duplicate keys, #625 policy sync, #614 CLI path traversal.

**4 prior findings confirmed Won't Do (unchanged):** #573 unsigned ledger, #598 GQL injection, #617 no auth, #612 weak checksum.

**2 prior findings fixed with residual:** #620 resume slots (partial — leak remains), #627 password CLI (Won't Do).

**New security findings:**

| # | Finding | Severity | Score | CWE | Line |
|---|---------|----------|-------|-----|------|
| SEC-NEW-01 | Incomplete Unicode/special char validation in `validateMigrationName` | Medium | 32 | CWE-22, CWE-176 | 98-104 |
| SEC-NEW-02 | No cross-process locking (hardcoded lock ID=1, in-memory only) | Medium | 24 | CWE-284, CWE-362 | 333 |
| SEC-NEW-03 | Resume token memory leak / potential use-after-free with scoped allocators | Low | 8 | CWE-401, CWE-416 | 677-691 |
| SEC-NEW-04 | Predictable temp file name in `saveLedger` (symlink attack surface) | Low | 12 | CWE-377, CWE-59 | 276-290 |
| SEC-NEW-05 | No migration name length limit (DoS via crafted ledger) | Low | 8 | CWE-770 | 98-104 |
| SEC-NEW-06 | Weak FNV-1a checksum enables collision-based drift evasion (reconfirmed) | Low | 8 | CWE-328 | 121-138 |

**Revised attack chain (post-fixes):** Filesystem write access to migrations dir → craft malicious `.gql` file → `applyUpMigrations` discovers and executes it verbatim → arbitrary GQL. The prior path traversal vector is blocked but direct file placement in the migrations directory remains exploitable. Risk: HIGH in CI/CD, LOW in single-developer local.

---

## Cross-Domain Summary

| Domain | Prior Findings | New Findings | Total | Verified Closed | Won't Do | False Closures | Open |
|--------|---------------|-------------|-------|----------------|----------|---------------|------|
| Gap Analysis | 36 | 5 | 41 | 19 | 13 | 4 | 5 |
| Quality | 18 | 13 | 31 | 16 | 0 | 0 | 15 |
| Performance | 6 | 8 | 14 | 0 | 6 | 0 | 8 (P3) |
| Security | 13 | 6 | 19 | 8 | 5 | 0 | 6 |
| **Total** | **73** | **32** | **105** | **43** | **24** | **4** | **34** |

---

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/MIGRATION_GAP_ANALYSIS.md` | Gap | verified (0 open) |
| `docs/MIGRATION_GAP_ANALYSIS_RESOLVED.md` | Gap | verified (23+13 resolved) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | 16 closed, 2 prior open |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | all Won't Do |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | 8 closed, 5 Won't Do |
| `docs/MIGRATION_AUDIT_SUMMARY.md` | All | updated (this file) |

---

## Top 10 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | Score | Status |
|---|--------|---------|----------|-------|--------|
| 1 | **Gap** | **All 6 CANARY markers claim STATUS=TESTED but tests are dead code / non-existent** | **Critical** | -- | **REOPENED** |
| 2 | **Gap** | **4 closed gaps are factually incorrect** (GAP-0279, 0281, 0290, 0296) | **Critical** | -- | **REOPENED** |
| 3 | **Gap** | `StatusRow.name` default `"stub"` is a string literal; `freeStatusRows` will UB | **High** | -- | **NEW** |
| 4 | Security | GQL injection via migration file content | High | 64 | Won't Do (#598) |
| 5 | Quality | `loadLedger` leaks `name_copy` on OOM | High | -- | **NEW** |
| 6 | Quality | Hand-rolled JSON serializer (brittle, 35 lines) | High | -- | **NEW** |
| 7 | Quality | 955-line monolith with 8+ concerns | High | -- | **NEW** |
| 8 | Security | Incomplete Unicode/special char validation | Medium | 32 | **NEW** |
| 9 | Security | No cross-process locking (lock ID hardcoded) | Medium | 24 | **NEW** |
| 10 | Gap | `baseline_override` accessed without mutex | Medium | -- | **NEW** |

---

## Recommended Actions (Priority Order)

### Immediate (one-line fixes)

1. **Fix `loadLedger` name leak** — add `errdefer alloc.free(name_copy);` after line 196
2. **Add name length limit** — `if (name.len > 255) return error.InvalidMigrationName;` in `validateMigrationName`

### Short-term (low churn)

1. **Extract named constants** — `MAX_LEDGER_BYTES`, `MAX_SCRIPT_BYTES`, `DEFAULT_LOCK_TTL_MS`, `MAX_VERSION_DIGITS`, `FNV_OFFSET_BASIS`, `FNV_PRIME`
2. **Add `errdefer` for resume token cleanup** or switch to fixed-size buffer
3. **Allowlist `validateMigrationName`** — restrict to `[a-zA-Z0-9._-]` instead of blocklist

### Future sprints (architectural)

1. Split `mod.zig` into `ledger.zig`, `lock.zig`, `resume.zig`, `checksum.zig`
2. Add cross-process `flock()`-based locking for CI/CD safety
3. Design DDL-only sandbox for migration executor (#598)
4. Design ledger HMAC signing with migration path (#573)

---

## Blockers

1. **CANARY governance integrity** — 6 markers claim TESTED but reference dead/non-existent tests. This inflates the project's 81.4% TESTED metric. Must be corrected to STATUS=IMPL or tests must be wired into build.zig.
2. **4 false closures** — GAP-0279, 0281, 0290, 0296 were marked closed but the fixes are not present in the current code. Must be reopened or re-implemented.
3. **`StatusRow.name` UB** — Default `"stub"` string literal will cause undefined behavior if passed to `alloc.free()`. Must be fixed before any code path can create default StatusRows and free them.

---

*Generated by Claude Code full codebase audit (re-audit) — 2026-04-01*
