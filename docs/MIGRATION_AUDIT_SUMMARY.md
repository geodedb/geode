# Full Codebase Audit Summary -- Migration Engine

**Date:** 2026-04-01 (full re-audit, supersedes prior same-day audit)
**Auditor:** Claude Code (Opus 4.6, 1M context)
**Scope:** `src/migration/mod.zig` (1052 lines) + `src/cli/backup_cli.zig` (CLI integration)
**Method:** 4-phase parallel audit (16 specialized agents across gap, quality, perf, security domains)

---

## Repository

- **Project:** devnw/codepros/geode/geode
- **Platform:** GitLab
- **Languages:** Zig 0.15.1
- **Scope:** Migration engine module (`src/migration/`)

---

## Prior Audit Corrections

The earlier same-day audit contained **stale findings** that this re-audit corrects:

| Prior Claim | Actual State (verified) |
|-------------|------------------------|
| GAP-0279: CANARY tests are dead code, not in build.zig | **WRONG.** `tests/all_tests.zig:116-117` imports both files; `build.zig:894-895` adds migration module; `build.zig:1082,1103` wires into test step. **Correctly closed.** |
| GAP-0281: `applyDownMigration` ignores names parameter | **WRONG.** Function was intentionally redesigned to single-step rollback (safety-first). **Correctly closed.** |
| GAP-0290: `lock_steal_count` never incremented | **WRONG.** Incremented at `mod.zig:342`; included in `metricsSnapshot` at line 750. **Correctly closed.** |
| GAP-0296: `checksumValidate` not bidirectional | **WRONG.** Line 620: `matched == applied_count and manifest_entries == matched` is correct bidirectional check. **Correctly closed.** |
| All 6 CANARY markers reference dead/non-existent tests | **PARTIALLY WRONG.** 5 of 6 tests exist and compile. 2 have name mismatches (governance metadata issue, not dead code). Geodetestlab spec exists at `geodetestlab-cli/specs/` (path discrepancy only). |
| StatusRow.name default "stub" causes UB | **ALREADY FIXED.** Default is now `""` (line 53); `freeStatusRows` checks `name.len > 0` (line 553). |
| `baseline_override` accessed without mutex | **ALREADY FIXED.** Protected by `migration_mutex` at lines 629-631, 758-761. |
| `saveLedger` tmp file close ordering | **ALREADY FIXED.** Explicit `tmp.close()` at line 297 before rename; `errdefer` at line 287. |

---

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|------------|
| Closed / Implemented | 23 | 44% |
| Won't Do | 13 | 25% |
| Open (new) | 16 | 31% |

**Prior 36 gaps:** All confirmed correctly resolved (23 closed, 13 Won't Do). No false closures.

**16 new gaps found (GAP-0306 through GAP-0321):**

| Gap-ID | Category | Severity | Description |
|--------|----------|----------|-------------|
| GAP-0306 | Bug | Medium | Memory leak in `planDryRun` — owned slice leaked on second `toOwnedSlice` failure (line 684-687) |
| GAP-0307 | Bug | Medium | Memory leak in `applyUpMigrations` — `new_name` not freed on OOM (line 424-430) |
| GAP-0308 | Test | Low | Data race in tests — `policy_mode` written without mutex (lines 843,847,851) |
| GAP-0309 | Test | Low | Order-dependent test — "PolicyMode defaults to lenient" (line 837-839) |
| GAP-0310 | Test | **High** | Zero unit test coverage of core business logic (apply/rollback/status/plan/drift) |
| GAP-0311 | Test | Medium | No JSON round-trip test for `writeLedgerJson`/`loadLedger` |
| GAP-0312 | Test | Medium | No concurrent lock test for `acquireLock`/`releaseLock` |
| GAP-0313 | Test | Medium | No test for `resumeDataMigration` |
| GAP-0314 | Quality | Medium | Silent error swallow in `driftCheck` line 636 (`catch {}`) |
| GAP-0315 | Quality | Low | Hand-rolled JSON serializer instead of `std.json.stringify` |
| GAP-0316 | Quality | Low | Magic numbers lack named constants |
| GAP-0317 | Quality | Low | `enforcePolicy` accepts raw strings instead of `PolicyMode` enum |
| GAP-0318 | Feature | Low | `total_batches` hardcoded to 5 in resume slots |
| GAP-0319 | Governance | Low | CANARY marker name mismatch — `PlanDryRunIntegrity` vs actual test name |
| GAP-0320 | Governance | Low | CANARY marker name mismatch — `test_migration_parseVersion` vs actual test name |
| GAP-0321 | Governance | Low | CANARY geodetestlab spec path discrepancy (`geodetestlab/` vs `geodetestlab-cli/`) |

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 3 |
| Medium | 8 |
| Low | 8 |

**Quality scores:**

| Dimension | Prior Audit | This Audit | Notes |
|-----------|-----------|------------|-------|
| Readability | 7/10 | 7/10 | Clear naming, good structure; hand-rolled JSON and monolith size hurt |
| Maintainability | 5/10 | 5/10 | 1052-line monolith, global mutable state, no separation of concerns |
| API Contract | 5/10 | 6/10 | Ownership rules exist (freePlan, freeStatusRows) but implicit; improved from prior |
| Reliability | 5/10 | 4/10 | **Downgraded:** 3 confirmed memory leaks, data races in tests, zero core logic test coverage |
| Documentation | -- | 6/10 | CANARY markers present, some doc comments; no architecture doc or ownership docs |

**Top quality findings:**

| # | Finding | Severity | PriorityScore | Line |
|---|---------|----------|---------------|------|
| Q1 | Zero unit test coverage of core business logic | High | 90 | 774-1052 |
| Q2 | Memory leak in `planDryRun` error path | High | 80 | 684-687 |
| Q3 | Data races in tests (policy_mode without mutex) | High | 70 | 843,847,851 |
| Q4 | Memory leak in `applyUpMigrations` OOM path | Medium | 60 | 424-430 |
| Q5 | Memory leak in `loadLedger` mid-loop OOM | Medium | 55 | 198-207 |
| Q6 | No JSON round-trip test | Medium | 50 | -- |
| Q7 | Silent error swallow in `driftCheck` | Medium | 45 | 636 |
| Q8 | Hand-rolled JSON serializer (fragile, 35 lines) | Medium | 45 | 239-273 |
| Q9 | `MigrationPlan` ownership asymmetry (freePlan on default = UB) | Medium | 40 | 46-49 |
| Q10 | 1052-line monolith with 8+ concerns | Medium | 35 | 1-1052 |

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 | 0 |
| P1 | 0 |
| P2 | 1 (per-migration fsync, correct for crash safety) |
| P3 | 8 (all informational) |

**Verdict:** Zero actionable performance findings. All 6 prior Won't Do dispositions (PERF-577 through PERF-594) confirmed correct. Migration engine is an admin-time tool where QUIC RTT (1.3-1.9s) dominates all in-process costs by 3+ orders of magnitude.

### Security

| Risk Level | Count | Status |
|-----------|-------|--------|
| High | 2 | 1 new (supply chain), 1 prior Won't Do (#598 GQL injection) |
| Medium | 4 | All new |
| Low | 7 | 5 new, 2 prior (Won't Do) |

**7 prior fixes verified intact:** #572 path traversal, #592 JSON injection, #606 TOCTOU lock, #602 integer overflow, #622 duplicate keys, #625 policy sync, #614 CLI path traversal.

**5 prior Won't Do confirmed:** #573 unsigned ledger, #598 GQL injection, #617 no auth, #612 weak checksum, #627 password exposure.

**11 new security findings:**

| ID | Finding | Severity | Risk Score | CWE |
|----|---------|----------|------------|-----|
| SEC-MIG-01 | No cryptographic signing of migration files | High | 10 | CWE-345 |
| SEC-MIG-02 | No CI pipeline migration guard | Medium | 8 | CWE-829 |
| SEC-MIG-03 | `migrate status`/`create` have zero authentication | Medium | 9 | CWE-306 |
| SEC-MIG-04 | In-process lock — no cross-process protection | Medium | 9 | CWE-362 |
| SEC-MIG-05 | Drift evasion via FNV-1a collision + unsigned ledger | Medium | 6 | CWE-328 |
| SEC-MIG-06 | No file permissions on ledger/migration files | Low | 6 | CWE-732 |
| SEC-MIG-07 | Predictable temp file name (ms timestamp) | Low | 4 | CWE-377 |
| SEC-MIG-08 | Resume token memory leak (8 slots max) | Low | 2 | CWE-401 |
| SEC-MIG-09 | CLI version counter overflow in cmdMigrateCreate | Low | 1 | CWE-190 |
| SEC-MIG-10 | `--dir` accepts arbitrary paths without validation | Low | 6 | CWE-22 |
| SEC-MIG-11 | Password visible in process listing | Low | 6 | CWE-214 |

**Attack chain (unchanged):** Filesystem write access to migrations dir -> craft malicious `.gql` file -> `applyUpMigrations` executes verbatim -> arbitrary GQL. Risk: HIGH in CI/CD, LOW in single-developer local.

---

## Cross-Domain Summary

| Domain | Prior Findings | New Findings | Total | Verified Closed | Won't Do | Open |
|--------|---------------|-------------|-------|----------------|----------|------|
| Gap Analysis | 36 | 16 | 52 | 23 | 13 | 16 |
| Quality | 84 | 19 | 103 | 78 | 0 | 25 |
| Performance | 6 | 0 | 6 | 0 | 6 | 0 |
| Security | 13 | 11 | 24 | 7 | 5 | 12 |
| **Total** | **139** | **46** | **185** | **108** | **24** | **53** |

---

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/MIGRATION_GAP_ANALYSIS.md` | Gap | Updated (16 open gaps added) |
| `docs/MIGRATION_GAP_ANALYSIS_RESOLVED.md` | Gap | No changes (all prior resolutions verified) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | Updated (19 new findings) |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | Updated (Won't Do confirmed, re-audit note) |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | Updated (11 new findings) |
| `docs/MIGRATION_AUDIT_SUMMARY.md` | All | Rewritten (this file) |

---

## Top 10 Findings (cross-domain, by severity and impact)

| # | Domain | Finding | Severity | Score | Status |
|---|--------|---------|----------|-------|--------|
| 1 | **Gap** | Zero unit test coverage of core business logic (GAP-0310) | **High** | 90 | OPEN |
| 2 | **Quality** | Memory leak in `planDryRun` error path (GAP-0306) | **High** | 80 | OPEN |
| 3 | **Quality** | Data races in tests — `policy_mode` without mutex | **High** | 70 | OPEN |
| 4 | **Security** | No cryptographic signing of migration files (SEC-MIG-01) | **High** | 10 | OPEN |
| 5 | Security | GQL injection via migration file content (#598) | High | -- | Won't Do |
| 6 | **Quality** | Memory leak in `applyUpMigrations` OOM path (GAP-0307) | **Medium** | 60 | OPEN |
| 7 | **Quality** | Memory leak in `loadLedger` mid-loop OOM | **Medium** | 55 | OPEN |
| 8 | Security | In-process lock — no cross-process protection (SEC-MIG-04) | Medium | 9 | OPEN |
| 9 | Security | No CI pipeline migration guard (SEC-MIG-02) | Medium | 8 | OPEN |
| 10 | **Quality** | No JSON round-trip test (GAP-0311) | **Medium** | 50 | OPEN |

---

## Recommended Actions (Priority Order)

### Immediate (one-line fixes, < 1 hour)

1. **Fix `planDryRun` memory leak** (GAP-0306) -- capture first `toOwnedSlice` result, add `errdefer` before second call
2. **Fix `applyUpMigrations` memory leak** (GAP-0307) -- add `errdefer alloc.free(new_name)` after line 424
3. **Fix `loadLedger` memory leak** -- add comprehensive `errdefer` after `rows` init that frees all appended names
4. **Fix test data races** (GAP-0308) -- replace direct `policy_mode` assignments with `enforcePolicy()` calls
5. **Fix CANARY marker names** (GAP-0319, 0320, 0321) -- update TEST fields to match actual test names/paths

### Short-term (1-3 days)

1. **Add core logic unit tests** (GAP-0310) -- `applyUpMigrations`, `planDryRun`, `loadLedger`/`saveLedger` round-trip, `driftCheck` using temp dir + mock executor
2. **Add JSON round-trip test** (GAP-0311) -- write-then-parse with edge-case names
3. **Add concurrent lock test** (GAP-0312) -- spawn N threads, verify exactly one acquires
4. **Extract named constants** (GAP-0316) -- `fnv_offset_basis`, `fnv_prime`, `max_ledger_bytes`, `default_lock_ttl_ms`, etc.
5. **Replace silent `catch {}`** (GAP-0314) -- add `std.log.warn` in `driftCheck`

### Future sprints (architectural)

1. Split `mod.zig` into `ledger.zig`, `lock.zig`, `resume.zig`, `checksum.zig`
2. Add cross-process `flock()`-based locking for CI/CD safety (SEC-MIG-04)
3. Design migration file signing with Ed25519 or HMAC-SHA256 (SEC-MIG-01)
4. Add CI migration guard job in `.gitlab-ci.yml` (SEC-MIG-02)
5. Design DDL-only sandbox for migration executor (#598)

---

## Blockers

None. All prior blockers from the earlier audit have been resolved:

1. ~~CANARY governance integrity~~ -- Tests are wired into build.zig; 2 name mismatches are low-severity governance metadata fixes
2. ~~4 false closures~~ -- All 4 are correctly closed; prior audit was stale
3. ~~StatusRow.name UB~~ -- Already fixed (default is `""`, guard checks `name.len > 0`)

---

*Generated by Claude Code full codebase audit -- 2026-04-01*
*16 specialized agents across 4 phases (orientation, scanning, deep analysis, tracking)*
