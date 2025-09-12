<!-- NEXT.md — Prioritized Execution Backlog (ISO‑GQL Aligned) -->

# NEXT — Execution‑Ready Backlog (ISO‑GQL Aligned)

Each task: Why • What • Acceptance (GQL + expected binding schema / diagnostics) • ISO anchors • Deps • Scope (S/M/L) • DRI.

## Now (P0)

1. Diagnostics precedence & multi-status cluster (REQ-GQL-014/022/030/036)

   - Why: Deterministic primary diagnostic per ISO 23.2; unblock reliable client UX.
   - What: Implement precedence table (US001 < IllegalOrderKey < GroupByIllegal < TypeMismatch etc.), fold duplicates, stable ordering in additional_statuses.
   - Acceptance: Query `RETURN a ORDER BY f(a) LIMIT 1` under ident-only policy emits primary=IllegalOrderKey (parse stage), no US001; crafted planner-stage conflict emits primary=US001 with IllegalOrderKey in additional_statuses when parser allows key. Added exhaustive precedence validation in `tests/e2e_protocol_multidiag_precedence.zig` (US001 only, IllegalOrderKey only, US001+IllegalOrderKey, TypeMismatch+US001, All three) verifying ordering & flag emission.
   - ISO: 14.10; 16.18–16.19; 23.2 (diagnostics); 24.x (conformance disclosure).
   - Deps: diagnostics.zig, protocol.zig.
   - Scope: S
   - DRI: core

2. EXPLAIN / PROFILE stabilization (REQ-GQL-019/020/033)

   - Why: Plan introspection & perf tuning; required for conformance evidence.
   - What: Stable JSON schema; logical op list; per-op metrics including rows/time/bytes; golden tests (json) + later txt. Subtasks:
   - Freeze logical form: `{"profile_version":1,"logical":[ {"op":"Project","id":0,...} ],"properties":{...}}`.
   - Introduce `id` monotonic and canonical pipeline ordering (Project, Distinct, Sort, Offset, Limit, SetOpUnion) matching executor.
   - PROFILE schema: `{"profile_version":1,"ops":[ {"op":"Project","id":0,"in_rows":N,"out_rows":M,"time_ns":X,"bytes_out":Y,"bytes_alloc":Z}...],"totals":{"time_ns":T,"peak_bytes":B}}`.
   - Golden tests: explain/profile with and without ORDER BY.
   - Tag schema version comment in `protocol.zig`.
   - Acceptance: `EXPLAIN RETURN 1 AS x` => SCHEMA + EXPLAIN lines; PROFILE includes ops[0].op="Project" and time_ns>0; golden tests match.
   - ISO: 14.10 (primitive result); 23.2 (diagnostic context, not failing).
   - Deps: planner.zig, server/main.zig.
   - Scope: M
   - DRI: core

3. Decimal ordering correctness & fuzz (REQ-GQL-031/037/013)

   - Why: Prevent silent mis-ordering; foundation for numeric queries.
   - What: Scale-align compare; fuzz harness 10k random decimals; add division-by-zero diagnostic.
   - Acceptance: UNION DISTINCT of mixed-scale decimals dedups correctly; fuzz run no panic; div by zero -> TypeMismatch subclass.
   - ISO: 16.x numeric; 23.2 diagnostics.
   - Deps: eval.zig.
   - Scope: S
   - DRI: core

4. Storage integration phase 0 (REQ-GQL-025)

   - Why: Persist future catalog & stats; prepare for WAL.
   - What: Page manager API + unit tests; slotted page read/write; simple catalog stub.
   - Acceptance: unit test: create page, insert 3 variable records, read back; free space shrinks deterministically.
   - ISO: 4.8 working table (persistence context impl-defined); §8 durability (future).
   - Deps: storage/heap.zig.
   - Scope: M
   - DRI: storage

5. Parameter arrays: empty & hetero test coverage (REQ-GQL-015/032)

   - Why: Edge-case safety; avoid latent panics.
   - What: Add tests for zero-length param arrays; mixed-length rejection diagnostic.
   - Acceptance: `RETURN $a AS x` with a=[] produces zero-row BINDINGS (ordered=false); mismatched lengths -> TypeMismatch additional_status only.
   - ISO: 16.x expressions; 23.2 diagnostics.
   - Deps: server/main.zig.
   - Scope: S
   - DRI: core

6. Flagger enhancement: explicit US001 enforcement trace (REQ-GQL-010/029)
   - Why: Client transparency for rejected pagination.
   - What: Add U:US001/enforced to ERROR frames; test presence.
   - Acceptance: `RETURN 1 LIMIT 5` (no ORDER) => ERROR with US001 primary + flag present.
   - ISO: 16.18–16.19; 23.2.
   - Deps: protocol.zig.
   - Scope: S
   - DRI: core

## Next (P1)

1. GROUP BY execution & hash aggregation (REQ-GQL-016)

   - Why: Enable actual grouped results (not just legality checks).
   - What: HashAgg op + planner insertion; PROFILE rows reflect reduced cardinality.
   - Acceptance: `RETURN a, SUM(b) GROUP BY a ORDER BY a` yields ordered grouped rows; PROFILE shows Group op with rows < input.
   - ISO: 14.10 (group semantics).
   - Deps: planner.zig, eval.zig.
   - Scope: M
   - DRI: core

2. Transactions baseline (REQ-GQL-027 subset)

   - Why: Provide user-visible txn demarcation semantics.
   - What: Txn manager stub; BEGIN/COMMIT/ROLLBACK state machine; reject nested BEGIN.
   - Acceptance: Sequence BEGIN RETURN 1 COMMIT succeeds; second BEGIN before COMMIT -> TxnState error code.
   - ISO: §8 (transaction); 23.2.
   - Deps: server/main.zig.
   - Scope: M
   - DRI: core

3. Index scan operator introduction (REQ-GQL-039)

   - Why: Planner cost hooks; performance groundwork.
   - What: Add NodeIndexScan logical/physical; tests pick index when label selectivity low.
   - Acceptance: Query with selective label chooses index path (EXPLAIN contains NodeIndexScan).
   - ISO: 14.4 pattern semantics.
   - Deps: planner.zig, storage index stub.
   - Scope: M
   - DRI: core

4. Result formatting parity (txt) for EXPLAIN/PROFILE (REQ-GQL-023/019/020)

   - Why: Multi-format consistency.
   - What: Implement text emit; golden diff tests.
   - Acceptance: `PROFILE RETURN 1` text output stable; diff change fails test.
   - ISO: 24.x.
   - Deps: client/main.zig.
   - Scope: S
   - DRI: core

5. Conformance doc auto-sync script (REQ-GQL-018/034/045)

   - Why: Prevent drift.
   - What: Script regenerates ledger/profile from annotated source comments.
   - Acceptance: Running script produces no diff after manual update.
   - ISO: 24.x.
   - Deps: docs/\*.md.
   - Scope: M
   - DRI: docs

6. Numeric promotion & division-by-zero diagnostic (REQ-GQL-013/012)
   - Why: Clear numeric semantics; correctness.
   - What: Explicit TypeMismatch subclass for div0; doc promotion matrix.
   - Acceptance: `RETURN 1/0` -> ERROR TypeMismatch(div0) with anchor; promotion doc updated.
   - ISO: 16.x; 23.2.
   - Deps: eval.zig.
   - Scope: S
   - DRI: core

## Later (P2+)

1. WAL/ARIES design & log record formats (REQ-GQL-026)

   - Acceptance: Crash replay test recovers committed insert; uncommitted absent.
   - ISO: §8 durability.
   - Scope: L | DRI: storage

2. MVCC Snapshot Isolation (REQ-GQL-027 full)

   - Acceptance: Concurrent write/write conflict aborted; repeatable read for snapshot session.
   - ISO: §8 isolation impl-defined.
   - Scope: L | DRI: core

3. Path patterns & tie-break (REQ-GQL-017)

   - Acceptance: Bounded path query returns shortest (length,id) consistent across runs; flag UA005/UA006.
   - ISO: 22.4; UA005/UA006.
   - Scope: L | DRI: core

4. Distributed scaffold + 2PC (REQ-GQL-028/042/043)

   - Acceptance: Feature-flag build; Raft leader stub test passes; 2PC coordinator interface compiled.
   - ISO: Impl-defined distributed semantics.
   - Scope: L | DRI: dist

5. Encryption at rest design doc (REQ-GQL-038)

   - Acceptance: Document with key lifecycle & KMS placeholders; threat model table.
   - ISO: Impl-defined security.
   - Scope: M | DRI: security

6. Page compaction & vacuum (REQ-GQL-040)

   - Acceptance: Fragmentation test reduces wasted space <15% after vacuum.
   - ISO: Impl-defined storage mgmt.
   - Scope: M | DRI: storage

7. Recovery harness (REQ-GQL-041)

   - Acceptance: Injected crash mid-append replays to consistent state.
   - ISO: §8 durability.
   - Scope: M | DRI: storage

8. Ranked (Any-k) ORDER BY early-stop (optimization) | LIMIT top-k (future)

   - Acceptance: PROFILE shows fewer rows scanned than total for LIMIT query.
   - ISO: 16.18–16.19.
   - Scope: M | DRI: core

9. Adaptive re-optimization checkpoints
   - Acceptance: Plan re-issued when cardinality deviation >4x; log includes old/new plan root costs.
   - ISO: 14.10 execution semantics preserved.
   - Scope: M | DRI: core

## Cutline

Deferred until durability & transactions baseline: Full MVCC, WAL recovery validation suite, distributed execution, ranked enumeration, adaptive re-optimization, encryption implementation (beyond design), vacuum implementation details, path enumeration optimization.

## Recent Progress (since last revision)

- Expanded diagnostics cluster tasks; added fuzz harness prerequisite.
- Added storage page manager phase 0 to NOW.
- Introduced new requirements (038–045) into planning.
