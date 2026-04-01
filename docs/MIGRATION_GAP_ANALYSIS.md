# Gap Analysis -- Migration Engine (`src/migration/mod.zig`)

> This file contains ONLY open gaps. Resolved items move to `MIGRATION_GAP_ANALYSIS_RESOLVED.md`.
>
> **Source of truth:** GitLab issue tracker. This file is a flatfile mirror.
>
> **Previously closed migration issues (not tracked here):** #124, #149, #177, #178, #179, #180, #219, #229, #337, #366, #367, #376, #512

## Closure Status (2026-04-01)

| Status | Count | Items |
|--------|-------|-------|
| Closed | 17 | GAP-0280, 0281, 0284, 0285, 0287, 0288, 0289, 0290, 0291, 0292, 0293, 0295, 0296, 0297, 0298, 0299, 0301, 0302, 0303, 0304, 0305, SEC-622 |
| Won't Do | 10 | GAP-0282, 0283, 0286, 0294, 0300, SEC-598, SEC-627, PERF-577, PERF-579/582/584, PERF-589 |
| Open | 1 | GAP-0279 (requires fixing dead CANARY test files) |

## Summary

| Severity | Count | Resolved |
|----------|-------|----------|
| Critical | 1 | 0 (GAP-0279 open) |
| High | 10 | 8 closed, 2 won't-do |
| Medium | 12 | 9 closed, 3 won't-do |
| Low | 4 | 0 closed, 4 won't-do |
| **Total** | **27** | **17 closed, 9 won't-do, 1 open** |

### Won't Do Items

| Gap-ID | Title | Reason |
|--------|-------|--------|
| GAP-0282 | CLI down subcommand | Feature addition, not a gap fix |
| GAP-0283 | CLI drift/checksum/policy/metrics subcommands | Feature additions, not gap fixes |
| GAP-0286 | Ledger HMAC integrity | Too invasive, needs separate sprint |
| GAP-0294 | SHA-256 checksums | Breaking change, needs versioned ledger format |
| GAP-0300 | Authorization in module | Needs architectural decision |
| SEC-598 | GQL injection via file content | Needs DDL sandbox design |
| SEC-627 | --password CLI exposure | CLI backlog item |
| PERF-577 | Ledger caching | Not recommended (ledger is small) |
| PERF-579/582/584 | HashMap optimizations | Not recommended (unmeasurable benefit) |
| PERF-589 | planDryRun sort optimization | Unmeasurable improvement |

## Gaps

### GAP-0279: CANARY integration tests are dead code -- never compiled or run

- **Issue:** [#566](https://gitlab.com/devnw/codepros/geode/geode/-/issues/566)
- **Category:** Test
- **Severity:** Critical
- **Requirement source:** CANARY governance -- TESTED markers must correspond to executing tests
- **Current state (evidence):**
  - `tests/canary_migration_engine_stubs.zig` -- uses `tmp.path` (nonexistent in Zig 0.15 `TmpDir`)
  - `tests/canary_migration_engine_new_tests.zig` -- passes `&alloc` instead of `alloc`
  - Neither file referenced in `build.zig` test steps
- **Why this is a gap:** 5 CANARY markers report TESTED status for tests that never compile or execute, inflating governance metrics.
- **Impact/Risk:** Zero actual integration test coverage for migration engine while metrics claim TESTED. False confidence in migration safety.
- **Recommended fix:** Fix API calls, fix arg types, fix imports, add to `build.zig`, verify all 5 CANARY markers.
- **Acceptance criteria:** Both files compile, both run in `zig build test`, all 5 CANARY markers reflect actual execution.

---

### GAP-0280: No errdefer on partial apply in applyUpMigrations

- **Issue:** [#567](https://gitlab.com/devnw/codepros/geode/geode/-/issues/567)
- **Category:** Bug
- **Severity:** High
- **Requirement source:** Migration engine reliability -- atomic batch or consistent rollback
- **Current state (evidence):**
  - `src/migration/mod.zig:applyUpMigrations` -- no errdefer on ledger writes after partial application
- **Why this is a gap:** Mid-batch failure leaves ledger out of sync with applied state.
- **Impact/Risk:** Subsequent runs may skip or re-apply migrations, causing data corruption.
- **Recommended fix:** Add errdefer to revert ledger on partial failure; add test for mid-batch failure recovery.
- **Acceptance criteria:** Mid-batch failure leaves ledger consistent; test verifies partial failure recovery.

---

### GAP-0281: applyDownMigrations ignores names parameter

- **Issue:** [#568](https://gitlab.com/devnw/codepros/geode/geode/-/issues/568)
- **Category:** Bug
- **Severity:** High
- **Requirement source:** Migration engine -- selective rollback capability
- **Current state (evidence):**
  - `src/migration/mod.zig:applyDownMigrations` -- `names` parameter unused in function body
- **Why this is a gap:** Function signature promises selective rollback but always rolls back one migration.
- **Impact/Risk:** Misleading API; no selective rollback capability.
- **Recommended fix:** Implement selective rollback or remove parameter; add tests.
- **Acceptance criteria:** Function respects `names` parameter or parameter is removed with documented behavior.

---

### GAP-0282: No CLI down/rollback subcommand

- **Issue:** [#569](https://gitlab.com/devnw/codepros/geode/geode/-/issues/569)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** Migration engine usability -- rollback accessible to operators
- **Current state (evidence):**
  - `src/migration/mod.zig:applyDownMigrations` -- implemented but no CLI wiring
- **Why this is a gap:** Rollback functionality exists but is unreachable from CLI.
- **Impact/Risk:** Operators cannot roll back migrations without custom code; delays incident recovery.
- **Recommended fix:** Add `geode migrate down` CLI subcommand; wire to `applyDownMigrations`; add `--steps` flag.
- **Acceptance criteria:** CLI command exists, invokes rollback correctly, documented in `--help`.

---

### GAP-0283: driftCheck, checksumValidate, enforcePolicy, metricsSnapshot not wired to CLI

- **Issue:** [#570](https://gitlab.com/devnw/codepros/geode/geode/-/issues/570)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** Migration engine operability -- diagnostic tools accessible to operators
- **Current state (evidence):**
  - `src/migration/mod.zig` -- all four functions exist but no CLI wiring
- **Why this is a gap:** Four operational functions are unreachable from command line.
- **Impact/Risk:** Operators cannot run diagnostics without custom code.
- **Recommended fix:** Add CLI subcommands for each function.
- **Acceptance criteria:** All four accessible via CLI; documented in `--help`; each produces meaningful output.

---

### GAP-0284: acquireLock never called by migration apply functions

- **Issue:** [#571](https://gitlab.com/devnw/codepros/geode/geode/-/issues/571)
- **Category:** Bug
- **Severity:** High
- **Requirement source:** Migration safety -- concurrent execution must be prevented
- **Current state (evidence):**
  - `src/migration/mod.zig:acquireLock` -- implemented but never called from apply paths
- **Why this is a gap:** Lock mechanism exists but is not enforced; concurrent migrations can run.
- **Impact/Risk:** Concurrent runs corrupt ledger and schema.
- **Recommended fix:** Call `acquireLock` at start of apply functions; release via defer/errdefer; test concurrent rejection.
- **Acceptance criteria:** Lock acquired before apply; released on completion/failure; concurrent attempt returns error.

---

### GAP-0285: Path traversal in applyUpMigrations

- **Issue:** [#572](https://gitlab.com/devnw/codepros/geode/geode/-/issues/572)
- **Category:** Security
- **Severity:** High
- **Requirement source:** Security -- input validation at system boundaries
- **Current state (evidence):**
  - `src/migration/mod.zig:applyUpMigrations` -- user-supplied names concatenated into paths without sanitization
- **Why this is a gap:** `../` in migration names can access files outside migrations directory.
- **Impact/Risk:** Arbitrary file read/execution outside intended directory.
- **Recommended fix:** Validate names (alphanumeric/hyphens/underscores only); reject `../`, `/`, `\`; verify resolved path stays in migrations dir.
- **Acceptance criteria:** Path traversal attempts rejected with error; test verifies blocking.

---

### GAP-0286: Unsigned ledger file -- no HMAC or integrity check

- **Issue:** [#573](https://gitlab.com/devnw/codepros/geode/geode/-/issues/573)
- **Category:** Security
- **Severity:** High
- **Requirement source:** Security -- data integrity for critical state files
- **Current state (evidence):**
  - `src/migration/mod.zig:writeLedgerJson` -- writes plain JSON without signature
  - No integrity check on ledger read
- **Why this is a gap:** Tampered ledger can skip or re-run migrations.
- **Impact/Risk:** Data loss or schema corruption via ledger tampering.
- **Recommended fix:** Sign with HMAC; verify on read; reject tampered files.
- **Acceptance criteria:** Ledger includes HMAC; tampered ledger detected; test verifies.

---

### GAP-0287: JSON injection in writeLedgerJson

- **Issue:** [#574](https://gitlab.com/devnw/codepros/geode/geode/-/issues/574)
- **Category:** Security
- **Severity:** High
- **Requirement source:** Security -- output encoding at serialization boundaries
- **Current state (evidence):**
  - `src/migration/mod.zig:writeLedgerJson` -- `row.name` written directly without escaping
- **Why this is a gap:** Names with quotes/control characters inject arbitrary JSON.
- **Impact/Risk:** Corrupted ledger file; potential manipulation of migration state.
- **Recommended fix:** Use `std.json.stringify` or escape special characters; test with special-character names.
- **Acceptance criteria:** Special characters properly escaped; ledger valid JSON after write.

---

### GAP-0288: planDryRun returns MigrationPlan with dangling name pointers

- **Issue:** [#575](https://gitlab.com/devnw/codepros/geode/geode/-/issues/575)
- **Category:** Bug
- **Severity:** High
- **Requirement source:** Memory safety -- no dangling pointers in returned data
- **Current state (evidence):**
  - `src/migration/mod.zig:planDryRun` -- returns plan with names pointing into iterator-owned memory
- **Why this is a gap:** Use-after-free when caller reads plan after function return.
- **Impact/Risk:** Undefined behavior: crashes, silent corruption, potential security vulnerability.
- **Recommended fix:** Duplicate name strings with `alloc.dupe`; document ownership semantics.
- **Acceptance criteria:** Plan contains owned strings; no use-after-free under safety checks; test reads plan after return.

---

### GAP-0289: Dangling pointer in resume_slots

- **Issue:** [#576](https://gitlab.com/devnw/codepros/geode/geode/-/issues/576)
- **Category:** Bug
- **Severity:** High
- **Requirement source:** Memory safety -- stored references must own their data
- **Current state (evidence):**
  - `src/migration/mod.zig` -- `resume_slots` stores caller's token slice without `alloc.dupe`
- **Why this is a gap:** Dangling pointer when caller frees token memory.
- **Impact/Risk:** Use-after-free during migration resume; crashes or corruption.
- **Recommended fix:** Duplicate tokens with `alloc.dupe` on store; free on clear/overwrite.
- **Acceptance criteria:** Slots own their data; freed on clear; no use-after-free.

---

### GAP-0290: lock_steal_attempts_total metric declared but never incremented

- **Issue:** [#578](https://gitlab.com/devnw/codepros/geode/geode/-/issues/578)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Observability -- declared metrics must be functional
- **Current state (evidence):**
  - `src/migration/mod.zig` -- metric declared, no increment site, not in `metricsSnapshot`
- **Why this is a gap:** Dead metric code; operators get no lock-steal observability.
- **Impact/Risk:** Misleading metric declaration.
- **Recommended fix:** Increment on lock steal attempts and include in snapshot; or remove.
- **Acceptance criteria:** Metric incremented on attempts OR removed; snapshot includes all declared metrics.

---

### GAP-0291: Off-by-one in parseVersion guard

- **Issue:** [#580](https://gitlab.com/devnw/codepros/geode/geode/-/issues/580)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Correctness -- boundary checks must be exact
- **Current state (evidence):**
  - `src/migration/mod.zig:parseVersion` -- `i > 17` should be `i >= 17`
- **Why this is a gap:** Off-by-one allows reading one byte past intended boundary.
- **Impact/Risk:** Potential OOB read on version strings of exactly length 17.
- **Recommended fix:** Change to `i >= 17`; test with boundary-length input.
- **Acceptance criteria:** Guard uses `>=`; boundary-length test passes.

---

### GAP-0292: Duplicated version parsing without overflow guard

- **Issue:** [#581](https://gitlab.com/devnw/codepros/geode/geode/-/issues/581)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Correctness -- DRY and consistent safety checks
- **Current state (evidence):**
  - `src/migration/mod.zig:statusReport` -- inline version parsing, no overflow check
  - `src/migration/mod.zig:checksumValidate` -- inline version parsing, no overflow check
- **Why this is a gap:** Duplicated logic misses overflow guard present in `parseVersion`.
- **Impact/Risk:** Integer overflow on malformed versions causes incorrect ordering.
- **Recommended fix:** Refactor to use shared `parseVersion`; test with overflow-inducing input.
- **Acceptance criteria:** All parsing uses shared function; overflow handled at all sites.

---

### GAP-0293: Global lock TOCTOU race

- **Issue:** [#583](https://gitlab.com/devnw/codepros/geode/geode/-/issues/583)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Thread safety -- lock primitives must use atomic ops or OS synchronization
- **Current state (evidence):**
  - `src/migration/mod.zig` -- `global_lock` is plain variable without mutex/atomic protection
- **Why this is a gap:** Check-then-act on plain variable is a TOCTOU race.
- **Impact/Risk:** Concurrent migrations bypass lock; schema corruption.
- **Recommended fix:** Use `std.Thread.Mutex` or atomic CAS; or filesystem locking for cross-process safety.
- **Acceptance criteria:** Lock uses proper synchronization; concurrent attempts serialized; test verifies.

---

### GAP-0294: Weak checksum -- 28-bit FNV-1a with prefix matching

- **Issue:** [#586](https://gitlab.com/devnw/codepros/geode/geode/-/issues/586)
- **Category:** Security
- **Severity:** Medium
- **Requirement source:** Data integrity -- sufficient collision resistance
- **Current state (evidence):**
  - `src/migration/mod.zig` -- 28-bit truncated FNV-1a with prefix-match validation
- **Why this is a gap:** ~268M possible values; high collision probability for integrity verification.
- **Impact/Risk:** Modified files may pass checksum validation; silent schema drift.
- **Recommended fix:** Use 64-bit+ hash; exact match validation; migration path for old checksums.
- **Acceptance criteria:** At least 64-bit hash; exact match; modified file detected by test.

---

### GAP-0295: computeFingerprint casts i64 to u64 without handling negatives

- **Issue:** [#587](https://gitlab.com/devnw/codepros/geode/geode/-/issues/587)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Correctness -- integer casts must handle all input ranges
- **Current state (evidence):**
  - `src/migration/mod.zig:computeFingerprint` -- `@intCast(u64, value)` where value can be negative
- **Why this is a gap:** Negative i64 to u64 cast panics in safe mode.
- **Impact/Risk:** Runtime crash on certain hash combinations.
- **Recommended fix:** Use `@bitCast` instead of `@intCast`; test with negative intermediates.
- **Acceptance criteria:** No panic on negative values; test covers negative case.

---

### GAP-0296: checksumValidate asymmetric matching

- **Issue:** [#591](https://gitlab.com/devnw/codepros/geode/geode/-/issues/591)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Migration integrity -- bidirectional checksum validation
- **Current state (evidence):**
  - `src/migration/mod.zig:checksumValidate` -- checks disk vs manifest but not manifest vs disk
- **Why this is a gap:** Deleted migration files pass validation (extra manifest entries ignored).
- **Impact/Risk:** Drift between manifest and filesystem is invisible; incomplete rollback capability.
- **Recommended fix:** Add reverse check; report missing files as errors; test deleted-file detection.
- **Acceptance criteria:** Extra manifest entries reported as errors; deleted file detected by test.

---

### GAP-0297: planDryRun silently drops invalid names

- **Issue:** [#593](https://gitlab.com/devnw/codepros/geode/geode/-/issues/593)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Consistency -- dry-run must surface same errors as execution
- **Current state (evidence):**
  - `src/migration/mod.zig:planDryRun` -- skips invalid names without error
  - `src/migration/mod.zig:applyUpMigrations` -- returns error for same input
- **Why this is a gap:** Dry-run succeeds where apply fails, defeating validation purpose.
- **Impact/Risk:** False confidence from dry-run; unexpected failures during actual apply.
- **Recommended fix:** Return same errors from dry-run; test comparing dry-run and apply behavior.
- **Acceptance criteria:** Dry-run reports errors for invalid names; consistent with apply behavior.

---

### GAP-0298: statusReport swallows directory iteration errors

- **Issue:** [#595](https://gitlab.com/devnw/codepros/geode/geode/-/issues/595)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Error handling -- errors must not be silently swallowed
- **Current state (evidence):**
  - `src/migration/mod.zig:statusReport` -- `catch null` on directory iteration
- **Why this is a gap:** I/O errors, permission denials, filesystem corruption all silently ignored.
- **Impact/Risk:** Incomplete/empty status reports without error indication; wrong operational decisions.
- **Recommended fix:** Propagate errors to caller; test for permission-denied scenario.
- **Acceptance criteria:** Errors propagated; test verifies error on unreadable directory.

---

### GAP-0299: driftCheck loses drift signal on save failure

- **Issue:** [#597](https://gitlab.com/devnw/codepros/geode/geode/-/issues/597)
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** Reliability -- detected anomalies must be durably recorded
- **Current state (evidence):**
  - `src/migration/mod.zig:driftCheck` -- drift detected but save failure loses the signal
- **Why this is a gap:** Drift detection result discarded when persistence fails.
- **Impact/Risk:** Drift goes unrecorded in automated pipelines.
- **Recommended fix:** Return drift result regardless of save success; test save-failure scenario.
- **Acceptance criteria:** Caller receives drift info even if persistence fails.

---

### GAP-0300: No authorization checks in migration module

- **Issue:** [#600](https://gitlab.com/devnw/codepros/geode/geode/-/issues/600)
- **Category:** Security
- **Severity:** Medium
- **Requirement source:** Security -- privileged operations require authorization
- **Current state (evidence):**
  - `src/migration/mod.zig` -- no role/permission checks in any public function
- **Why this is a gap:** Any authenticated user can run schema-modifying migrations.
- **Impact/Risk:** Unauthorized schema changes; privilege escalation.
- **Recommended fix:** Require admin role for apply/rollback; operator role for status/drift; integrate with RBAC.
- **Acceptance criteria:** Apply/rollback requires admin; status requires operator; unauthorized attempt returns error.

---

### GAP-0301: cmdMigrateCreate path traversal in migration name

- **Issue:** [#603](https://gitlab.com/devnw/codepros/geode/geode/-/issues/603)
- **Category:** Security
- **Severity:** Medium
- **Requirement source:** Security -- input validation at CLI boundaries
- **Current state (evidence):**
  - `src/migration/mod.zig:cmdMigrateCreate` -- user-supplied name in path construction without sanitization
- **Why this is a gap:** `../` in name creates files outside migrations directory.
- **Impact/Risk:** Arbitrary file creation; potential overwrite of config or scripts.
- **Recommended fix:** Validate name pattern; reject path separators and `..`; share logic with GAP-0285.
- **Acceptance criteria:** Path traversal rejected in create command; test verifies.

---

### GAP-0302: 5 global mutable variables without synchronization

- **Issue:** [#605](https://gitlab.com/devnw/codepros/geode/geode/-/issues/605)
- **Category:** Bug
- **Severity:** Low
- **Requirement source:** Thread safety -- global mutable state needs synchronization
- **Current state (evidence):**
  - `src/migration/mod.zig` -- 5 `var` declarations at module scope without atomics or mutex
- **Why this is a gap:** Data races under concurrent access.
- **Impact/Risk:** Lost counter increments; inconsistent state flags.
- **Recommended fix:** Convert to `std.atomic.Value` or protect with mutex.
- **Acceptance criteria:** All globals use proper synchronization; no data races under concurrent test.

---

### GAP-0303: Resume slots silent overwrite when full

- **Issue:** [#607](https://gitlab.com/devnw/codepros/geode/geode/-/issues/607)
- **Category:** Bug
- **Severity:** Low
- **Requirement source:** Reliability -- resource exhaustion must be reported
- **Current state (evidence):**
  - `src/migration/mod.zig` -- resume slot insertion wraps silently when all 8 slots occupied
- **Why this is a gap:** Overwritten resume tokens are silently lost.
- **Impact/Risk:** Migrations cannot resume from checkpointed state; difficult to debug.
- **Recommended fix:** Log warning or return error on slot exhaustion; consider dynamic allocation.
- **Acceptance criteria:** Slot overwrite produces warning/error; test verifies full-slot behavior.

---

### GAP-0304: testSimulateDrift is pub with runtime is_test guard

- **Issue:** [#609](https://gitlab.com/devnw/codepros/geode/geode/-/issues/609)
- **Category:** Code Quality
- **Severity:** Low
- **Requirement source:** Code quality -- test-only code not in production API
- **Current state (evidence):**
  - `src/migration/mod.zig:testSimulateDrift` -- `pub fn` with runtime `is_test` check
- **Why this is a gap:** Test helper in public API surface of production build.
- **Impact/Risk:** Minor -- function is no-op in production but adds unnecessary code.
- **Recommended fix:** Move to `test` block or use comptime guard; or make non-pub.
- **Acceptance criteria:** Function not accessible in production; still available for tests.

---

### GAP-0305: alloc.alloc + copyForwards instead of idiomatic alloc.dupe

- **Issue:** [#611](https://gitlab.com/devnw/codepros/geode/geode/-/issues/611)
- **Category:** Code Quality
- **Severity:** Low
- **Requirement source:** Code quality -- idiomatic Zig patterns
- **Current state (evidence):**
  - `src/migration/mod.zig` -- multiple instances of manual alloc+copy instead of `dupe`
- **Why this is a gap:** More verbose and error-prone than idiomatic alternative.
- **Impact/Risk:** Low -- functionally equivalent but harder to maintain.
- **Recommended fix:** Replace with `alloc.dupe` where applicable.
- **Acceptance criteria:** Manual alloc+copy patterns replaced; tests pass.
