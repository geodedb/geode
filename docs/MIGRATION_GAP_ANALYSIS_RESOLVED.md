# Gap Analysis -- Migration Engine -- Resolved

> Resolved and invalidated items from `MIGRATION_GAP_ANALYSIS.md` are moved here.
>
> **Source of truth:** GitLab issue tracker. This file is a flatfile mirror.

## Closed / Implemented (39)

### GAP-0279: CANARY integration tests are dead code -- never compiled or run

- **Issue:** [#566](https://gitlab.com/devnw/codepros/geode/geode/-/issues/566)
- **Severity:** Critical
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** CANARY integration test files resurrected: fixed API calls for Zig 0.15, fixed arg types, added to build.zig test steps. All 5 CANARY markers now correspond to executing tests.
- **Evidence:** Commit `72ea65a6`. 648/648 tests passing (up from 619 baseline).

---

### GAP-0280: No errdefer on partial apply in applyUpMigrations

- **Issue:** [#567](https://gitlab.com/devnw/codepros/geode/geode/-/issues/567)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added errdefer to revert ledger on partial migration failure in applyUpMigrations.
- **Evidence:** Commit `7c545694` -- `src/migration/mod.zig` errdefer saveLedger.

---

### GAP-0281: applyDownMigrations ignores names parameter

- **Issue:** [#568](https://gitlab.com/devnw/codepros/geode/geode/-/issues/568)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** applyDownMigrations now respects the names parameter for selective rollback.
- **Evidence:** Commit `c49dc110` -- `src/migration/mod.zig`.

---

### GAP-0284: acquireLock never called by migration apply functions

- **Issue:** [#571](https://gitlab.com/devnw/codepros/geode/geode/-/issues/571)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** acquireLock now called at start of apply functions with defer releaseLock.
- **Evidence:** Commit `0d39cd15` -- `src/migration/mod.zig` lock integration.

---

### GAP-0285: Path traversal in applyUpMigrations

- **Issue:** [#572](https://gitlab.com/devnw/codepros/geode/geode/-/issues/572)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added name sanitization rejecting `../`, `/`, `\` in migration names.
- **Evidence:** Commit `f64bf2c6` -- `src/migration/mod.zig` path validation.

---

### GAP-0287: JSON injection in writeLedgerJson

- **Issue:** [#574](https://gitlab.com/devnw/codepros/geode/geode/-/issues/574)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** writeLedgerJson now uses std.json.stringify for proper escaping of special characters.
- **Evidence:** Commit `f64bf2c6` -- `src/migration/mod.zig`.

---

### GAP-0288: planDryRun returns MigrationPlan with dangling name pointers

- **Issue:** [#575](https://gitlab.com/devnw/codepros/geode/geode/-/issues/575)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** planDryRun now returns owned strings via alloc.dupe; added freePlan function.
- **Evidence:** Commit `7c545694` -- `src/migration/mod.zig`.

---

### GAP-0289: Dangling pointer in resume_slots

- **Issue:** [#576](https://gitlab.com/devnw/codepros/geode/geode/-/issues/576)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** resume_slots now duplicates tokens with alloc.dupe on store; freed on clear/overwrite.
- **Evidence:** Commit `7c545694` -- `src/migration/mod.zig`.

---

### GAP-0290: lock_steal_attempts_total metric declared but never incremented

- **Issue:** [#578](https://gitlab.com/devnw/codepros/geode/geode/-/issues/578)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Metric now incremented on lock steal attempts and included in metricsSnapshot.
- **Evidence:** Commits `f64bf2c6`, `28e4496c` -- `src/migration/mod.zig`.

---

### GAP-0291: Off-by-one in parseVersion guard

- **Issue:** [#580](https://gitlab.com/devnw/codepros/geode/geode/-/issues/580)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Guard changed from `i > 17` to `i >= 17`.
- **Evidence:** Commit `f64bf2c6` -- `src/migration/mod.zig`.

---

### GAP-0292: Duplicated version parsing without overflow guard

- **Issue:** [#581](https://gitlab.com/devnw/codepros/geode/geode/-/issues/581)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** All inline version parsing replaced with calls to shared parseVersion function.
- **Evidence:** Commit `c49dc110` -- `src/migration/mod.zig`.

---

### GAP-0293: Global lock TOCTOU race

- **Issue:** [#583](https://gitlab.com/devnw/codepros/geode/geode/-/issues/583)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Global lock replaced with std.Thread.Mutex for proper synchronization.
- **Evidence:** Commit `0d39cd15` -- `src/migration/mod.zig`.

---

### GAP-0295: computeFingerprint casts i64 to u64 without handling negatives

- **Issue:** [#587](https://gitlab.com/devnw/codepros/geode/geode/-/issues/587)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Changed @intCast to @bitCast for safe i64->u64 conversion.
- **Evidence:** Commit `c49dc110` -- `src/migration/mod.zig`.

---

### GAP-0296: checksumValidate asymmetric matching

- **Issue:** [#591](https://gitlab.com/devnw/codepros/geode/geode/-/issues/591)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added reverse check: extra manifest entries now reported as errors.
- **Evidence:** Commit `c49dc110` -- `src/migration/mod.zig`.

---

### GAP-0297: planDryRun silently drops invalid names

- **Issue:** [#593](https://gitlab.com/devnw/codepros/geode/geode/-/issues/593)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** planDryRun now returns errors for invalid names, consistent with applyUpMigrations.
- **Evidence:** Commit `c49dc110` -- `src/migration/mod.zig`.

---

### GAP-0298: statusReport swallows directory iteration errors

- **Issue:** [#595](https://gitlab.com/devnw/codepros/geode/geode/-/issues/595)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Directory iteration errors now propagated to caller instead of `catch null`.
- **Evidence:** Commit `c49dc110` -- `src/migration/mod.zig`.

---

### GAP-0299: driftCheck loses drift signal on save failure

- **Issue:** [#597](https://gitlab.com/devnw/codepros/geode/geode/-/issues/597)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Drift result returned regardless of save success. Save failure logged but does not mask drift detection.
- **Evidence:** Commit `c49dc110` -- `src/migration/mod.zig`.

---

### GAP-0301: cmdMigrateCreate path traversal in migration name

- **Issue:** [#603](https://gitlab.com/devnw/codepros/geode/geode/-/issues/603)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Name sanitization added to cmdMigrateCreate, sharing validation logic with GAP-0285.
- **Evidence:** Commit `f64bf2c6` -- `src/migration/mod.zig`.

---

### GAP-0302: 5 global mutable variables without synchronization

- **Issue:** [#605](https://gitlab.com/devnw/codepros/geode/geode/-/issues/605)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Global mutable variables converted to std.atomic.Value for thread-safe access.
- **Evidence:** Commit `0d39cd15` -- `src/migration/mod.zig`.

---

### GAP-0303: Resume slots silent overwrite when full

- **Issue:** [#607](https://gitlab.com/devnw/codepros/geode/geode/-/issues/607)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Slot insertion now returns error when all 8 slots are occupied.
- **Evidence:** Commit `7c545694` -- `src/migration/mod.zig`.

---

### GAP-0304: testSimulateDrift is pub with runtime is_test guard

- **Issue:** [#609](https://gitlab.com/devnw/codepros/geode/geode/-/issues/609)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Function moved into test block; no longer in production API surface.
- **Evidence:** Commit `28e4496c` -- `src/migration/mod.zig`.

---

### GAP-0305: alloc.alloc + copyForwards instead of idiomatic alloc.dupe

- **Issue:** [#611](https://gitlab.com/devnw/codepros/geode/geode/-/issues/611)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Manual alloc+copy patterns replaced with idiomatic alloc.dupe.
- **Evidence:** Commit `7c545694` -- `src/migration/mod.zig`.

---

### SEC-622: Ledger use_last enables stealthy field override

- **Issue:** [#622](https://gitlab.com/devnw/codepros/geode/geode/-/issues/622)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Changed JSON parse option from use_last to error for duplicate keys.
- **Evidence:** Commit `f64bf2c6` -- `src/migration/mod.zig`.

---

### GAP-0306: Memory leak in planDryRun on second toOwnedSlice failure

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added errdefer to free first slice if second toOwnedSlice fails. Also fixed mid-loop OOM leak in loadLedger (bonus Q5 fix).
- **Evidence:** Commit `279c4883` -- `src/migration/mod.zig` errdefer between toOwnedSlice calls.

---

### GAP-0307: Memory leak in applyUpMigrations OOM path for new_name

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added errdefer to free new_name on subsequent failure. Fixed double-free from errdefer scope correction in applyUpMigrations (bonus bug).
- **Evidence:** Commit `279c4883` -- `src/migration/mod.zig` errdefer on new_name allocation.

---

### GAP-0308: Data race in test code -- policy_mode written without mutex

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Test code now acquires mutex before writing policy_mode, eliminating data race.
- **Evidence:** Commit `e6b24e21` -- `src/migration/mod.zig` test mutex guards.

---

### GAP-0309: Order-dependent test -- "PolicyMode defaults to lenient"

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Test now resets policy_mode to default before asserting, removing order dependency.
- **Evidence:** Commit `e6b24e21` -- `src/migration/mod.zig` test isolation fix.

---

### GAP-0310: No unit tests for core business logic (apply/rollback/status/plan/drift)

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** High
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added unit tests for apply, rollback, status, plan, and drift functions. Also fixed saveLedger suffix_buf overflow (32->64 bytes) and applyUpMigrations double-free (bonus bugs found by tests).
- **Evidence:** Commit `2c0faf2c` -- `src/migration/mod.zig` test block; 667 tests passing.

---

### GAP-0311: No JSON round-trip test for writeLedgerJson/loadLedger

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added round-trip test: writeLedgerJson then loadLedger, asserting structural equality on a multi-entry ledger with edge cases.
- **Evidence:** Commit `2c0faf2c` -- `src/migration/mod.zig` test_ledger_json_round_trip.

---

### GAP-0312: No concurrent lock test

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added multi-threaded lock contention test verifying mutual exclusion with no deadlocks.
- **Evidence:** Commit `f02b0d2d` -- `src/migration/mod.zig` test_concurrent_lock_contention.

---

### GAP-0313: No test for resumeDataMigration

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added unit tests for resumeDataMigration covering resume from partial state and empty checkpoint.
- **Evidence:** Commit `f02b0d2d` -- `src/migration/mod.zig` test_resume_data_migration.

---

### GAP-0314: Silent error swallow in driftCheck

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Medium
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** driftCheck now logs save errors at warning level instead of silently swallowing them.
- **Evidence:** Commit `6146a839` -- `src/migration/mod.zig` drift save error logging.

---

### GAP-0315: Hand-rolled JSON serializer instead of std.json.stringify

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Replaced hand-rolled JSON construction in writeLedgerJson with std.json.stringify for correctness and maintainability.
- **Evidence:** Commit `ec492504` -- `src/migration/mod.zig` writeLedgerJson rewrite.

---

### GAP-0316: Magic numbers lack named constants

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Extracted all magic numbers (timeouts, buffer sizes, retry counts) to named constants at module scope.
- **Evidence:** Commit `6146a839` -- `src/migration/mod.zig` named constants.

---

### GAP-0317: enforcePolicy accepts raw strings instead of PolicyMode enum

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** Added typed enforcePolicyMode overload accepting PolicyMode enum; original string-based function retained for backwards compatibility.
- **Evidence:** Commit `f0e26e31` -- `src/migration/mod.zig` enforcePolicyMode function.

---

### GAP-0318: total_batches hardcoded to 5 in resume slots

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** total_batches is now configurable via the resume API; defaults to 5 for backwards compatibility but callers can override.
- **Evidence:** Commit `f0e26e31` -- `src/migration/mod.zig` configurable total_batches.

---

### GAP-0319: CANARY marker name mismatch -- PlanDryRunIntegrity

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** CANARY marker renamed to match canonical requirement ID naming convention.
- **Evidence:** Commit `b7114574` -- `src/migration/mod.zig` CANARY marker fix.

---

### GAP-0320: CANARY marker name mismatch -- test_migration_parseVersion

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** CANARY marker renamed to match canonical requirement ID naming convention.
- **Evidence:** Commit `b7114574` -- `src/migration/mod.zig` CANARY marker fix.

---

### GAP-0321: CANARY geodetestlab spec path discrepancy

- **Issue:** (not filed -- discovered in re-audit)
- **Severity:** Low
- **Resolution:** Closed / Implemented
- **Resolution date:** 2026-04-01
- **Resolution summary:** CANARY marker spec path updated to match actual geodetestlab spec file location.
- **Evidence:** Commit `b7114574` -- `src/migration/mod.zig` CANARY spec path fix.

---

## Won't Do (13)

### GAP-0282: No CLI down/rollback subcommand

- **Issue:** [#569](https://gitlab.com/devnw/codepros/geode/geode/-/issues/569)
- **Severity:** High
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Feature addition, not a gap fix. Deferred to CLI feature backlog.

---

### GAP-0283: driftCheck, checksumValidate, enforcePolicy, metricsSnapshot not wired to CLI

- **Issue:** [#570](https://gitlab.com/devnw/codepros/geode/geode/-/issues/570)
- **Severity:** High
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Feature additions, not gap fixes. Deferred to CLI feature backlog.

---

### GAP-0286: Unsigned ledger file -- no HMAC or integrity check

- **Issue:** [#573](https://gitlab.com/devnw/codepros/geode/geode/-/issues/573)
- **Severity:** High
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Too invasive for gap closure scope. Needs separate sprint with migration path design for existing unsigned ledgers.

---

### GAP-0294: Weak checksum -- 28-bit FNV-1a with prefix matching

- **Issue:** [#586](https://gitlab.com/devnw/codepros/geode/geode/-/issues/586)
- **Severity:** Medium
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Breaking change requiring versioned ledger format. Deferred to future sprint.

---

### GAP-0300: No authorization checks in migration module

- **Issue:** [#600](https://gitlab.com/devnw/codepros/geode/geode/-/issues/600)
- **Severity:** Medium
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Needs architectural decision on auth boundary (module vs CLI). Deferred pending design review.

---

### SEC-598: GQL injection via migration file content

- **Issue:** [#598](https://gitlab.com/devnw/codepros/geode/geode/-/issues/598)
- **Severity:** High
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Needs DDL sandbox design for QueryExecutor. Deferred pending sandbox architecture.

---

### SEC-627: --password visible in process listing

- **Issue:** [#627](https://gitlab.com/devnw/codepros/geode/geode/-/issues/627)
- **Severity:** Low
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** CLI backlog item. Deferred to CLI hardening sprint.

---

### PERF-577: Repeated full ledger load/parse (7 call sites)

- **Issue:** [#577](https://gitlab.com/devnw/codepros/geode/geode/-/issues/577)
- **Severity:** P2
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Not recommended by reviewer. Caching adds complexity for negligible gain vs QUIC round-trip.

---

### PERF-579: O(N*R) quadratic in applyUpMigrations

- **Issue:** [#579](https://gitlab.com/devnw/codepros/geode/geode/-/issues/579)
- **Severity:** P3
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** HashMap overhead exceeds scan cost at realistic migration counts. Unmeasurable benefit.

---

### PERF-582: O(F*R) quadratic in statusReport

- **Issue:** [#582](https://gitlab.com/devnw/codepros/geode/geode/-/issues/582)
- **Severity:** P3
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** HashMap overhead exceeds scan cost at realistic migration counts. Unmeasurable benefit.

---

### PERF-584: O(M*R) quadratic in checksumValidate

- **Issue:** [#584](https://gitlab.com/devnw/codepros/geode/geode/-/issues/584)
- **Severity:** P3
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** HashMap overhead exceeds scan cost at realistic migration counts. Unmeasurable benefit.

---

### PERF-589: planDryRun sort optimization

- **Issue:** [#589](https://gitlab.com/devnw/codepros/geode/geode/-/issues/589)
- **Severity:** P3
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Unmeasurable improvement.

---

### PERF-594: Per-migration ledger save

- **Issue:** [#594](https://gitlab.com/devnw/codepros/geode/geode/-/issues/594)
- **Severity:** P3
- **Resolution:** Won't Do
- **Resolution date:** 2026-04-01
- **Reason:** Already covered by GAP-0280 errdefer fix for crash safety. Separate per-migration save not needed.

---

*Generated by gap closure pipeline -- 2026-04-01*
