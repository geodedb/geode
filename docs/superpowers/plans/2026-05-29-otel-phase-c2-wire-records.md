# OTel Phase C Increment 2 — wire unwired record* facade functions

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. TDD per item.

**Goal:** Wire the unwired `otel_metrics.record*` facade functions to their real production call sites so more of the "full performance landscape" is tracked: query row counts, transaction concurrency events (timeout/serialization-conflict/deadlock/lock-wait), RLS/authz decisions, and audit events. Verify the new metric families land in the collector.

**Architecture:** Each function already exists in `src/monitoring/otel_metrics.zig` with a fixed signature; only the call site is missing. Wire each at the real code path, passing values read from the actual subsystem. **Discipline: if a call site or its values are ambiguous after reading the real code, DEFER it and report — never instrument the wrong place or fabricate values (NO MOCK DATA).**

**Tech Stack:** Zig 0.16; verify against the Phase A docker collector.

**BUILD DISCIPLINE:** geode pre-commit does NOT compile. Run `zig build -Doptimize=ReleaseSafe` GREEN before EVERY commit.

---

## Target functions (signature → recommended call site from discovery)

| Function (otel_metrics.zig) | Signature | Call site to verify |
|---|---|---|
| `recordQueryRowsReturned` | `(op: []const u8, summary: []const u8, rows: u64)` | `src/execution.zig` `executeStatementWithContext` — after the result is produced, alongside the existing `recordQueryExecution` defer; `rows` = result row count |
| `recordTransactionTimeout` | `(level: IsolationLevel)` | `src/transactions/manager.zig` — transaction timeout path (near existing `recordTransactionAbort`) |
| `recordSerializationConflict` | `(conflict_type: []const u8)` | `src/transactions/manager.zig` — serialization/SSI conflict detection (bounded conflict_type, e.g. "rw_conflict"/"write_skew") |
| `recordDeadlock` | `(victim_policy: []const u8)` | `src/transactions/manager.zig` — deadlock detection/victim selection (bounded policy string) |
| `recordLockWait` | `(lock_type: LockType, duration_s: f64, outcome: Outcome)` | `src/transactions/manager.zig` — lock acquisition path with wait timing |
| `recordRlsEvaluation` | `(decision: SecurityDecision, policy_type: PolicyType, duration_s: f64)` | `src/server/rls_filter.zig` or the RLS eval path in `src/execution/match_operations.zig` |
| `recordAuthzCheck` | `(decision: SecurityDecision, policy_type: PolicyType, duration_s: f64)` | `src/execution/auth_dispatch.zig` (RBAC/ABAC decision point) |
| `recordAuditEvent` | `(event_type: []const u8, outcome: Outcome)` | `src/security/audit.zig` — after an audit event is emitted (bounded event_type from the existing audit event enum/type) |
| `recordAuditDropped` | `(reason: []const u8)` | `src/security/audit.zig` — audit drop/overflow path |

**Enum types** (read their real definitions in otel_metrics.zig before use): `IsolationLevel`, `LockType`, `Outcome`, `SecurityDecision`, `PolicyType`, `TimeoutKind`.

**Explicitly DEFERRED (do not wire in C2 — report as follow-up):** `recordQueryPlan` (no clean plan-phase boundary in the current execution path — verify; if there genuinely is no separable plan step, defer), `recordTdeOperation`/`recordTdeBytes` (only if the TDE/KMS crypto call site is unambiguous; else defer), the `register*Gauge` resource gauges (the `*const fn () i64` providers may not exist as no-arg fns — defer unless a clean provider exists), backup (private S3Metrics bridge), distributed/CDC/analytics (inactive/absent).

---

### Task 1: recordQueryRowsReturned (execution.zig) — lowest risk, do first

- [ ] **Step 1:** In `src/execution.zig` `executeStatementWithContext`, after the result set is produced (the `switch (stmt)` arms return an `ExecutionResult`), record the row count. The cleanest spot: capture the result, call `om.recordQueryRowsReturned(op_name, op_name, @intCast(result.rows.len))` on the success path before returning. VERIFY the result field holding row count (`result.rows.len`? `result.rows.items.len`?) and that `op_name` (already derived for the span) is in scope. Use the success-path value; on error there are no rows.
- [ ] **Step 2:** `zig build -Doptimize=ReleaseSafe` GREEN.
- [ ] **Step 3:** Commit `feat(otel): record geode.query.rows.returned per query`.

### Task 2: Transaction concurrency metrics (transactions/manager.zig)

- [ ] **Step 1:** Read `src/transactions/manager.zig`. Find the real detection points for: transaction timeout, serialization/SSI conflict, deadlock, and lock-wait. Wire `recordTransactionTimeout`, `recordSerializationConflict`, `recordDeadlock`, `recordLockWait` at each, passing real values (isolation level / bounded conflict_type / bounded victim_policy / lock_type + measured wait duration + outcome). For ANY of these where the detection point does not clearly exist, DEFER that one and note it. Use `@import("otel_metrics")` (or the file's existing alias).
- [ ] **Step 2:** `zig build -Doptimize=ReleaseSafe` GREEN + run `zig build test` for the transactions test target if one exists (find it).
- [ ] **Step 3:** Commit `feat(otel): record transaction concurrency metrics (timeout/conflict/deadlock/lock-wait)` listing which were wired vs deferred.

### Task 3: RLS / authz / audit metrics

- [ ] **Step 1:** Wire `recordRlsEvaluation` at the RLS evaluation path (verify decision + policy_type + measured duration are available — they may not all be; if duration isn't measured, either measure it cheaply or defer). Wire `recordAuthzCheck` at the RBAC/ABAC decision point. Wire `recordAuditEvent`/`recordAuditDropped` in `src/security/audit.zig`. Attributes must be BOUNDED (enums/decisions only — never usernames, policy bodies, or row content). Defer-and-report any whose values aren't cleanly available.
- [ ] **Step 2:** `zig build -Doptimize=ReleaseSafe` GREEN.
- [ ] **Step 3:** Commit `feat(otel): record RLS/authz/audit metrics at decision points` (list wired vs deferred).

### Task 4: Verify new families land

- [ ] **Step 1:** `scripts/otel-compose-verify.sh` must still PASS. Then bring the stack up, run queries that exercise the wired paths (a transaction, an RLS-filtered query if configurable, an auth event), and confirm the new `geode.*` metric names appear in the collector debug output. Capture which landed.
- [ ] **Step 2:** Append a "Phase C2 update" to `docs/otel-compose-baseline-2026-05-29.md` (wired functions + which metric names landed + which were deferred and why). Commit.

---

## Self-Review
- Every wired metric uses BOUNDED attributes (no user content).
- Deferred items are clearly reported (not silently skipped, not instrumented in the wrong place).
- Build GREEN before every commit.
- New metric families verified in the collector (Task 4).
