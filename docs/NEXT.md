<!-- NEXT.md — Prioritized Execution Backlog (ISO‑GQL Aligned) -->

# NEXT — Execution‑Ready Backlog (ISO‑GQL Aligned)

Each task: Why • What • Acceptance (GQL + expected binding schema / diagnostics) • ISO anchors • Deps • Scope (S/M/L) • DRI.

## Recently Completed (P0 wrap-up)

1. Diagnostics precedence & multi-status cluster (REQ-GQL-014/022/030/036) — precedence table validated via multidiag tests.
2. EXPLAIN / PROFILE stabilization (REQ-GQL-019/020/033) — profile_version=1 frozen; snapshot freeze tests added.
3. Decimal ordering correctness & fuzz (REQ-GQL-031/037/013) — 10k pair fuzz + mixed-scale comparator.
4. Storage integration phase 0 (REQ-GQL-025) — slotted page manager + unit test.
5. Parameter arrays: empty & hetero coverage (REQ-GQL-015/032) — zero-length expansion semantics.
6. Flagger enhancement (REQ-GQL-010/029) — US001/enforced flag in ERROR frames.

## Now (P0)

1. Recovery harness (REQ-GQL-041)

   - Why: Validate durability semantics early.
   - What: Inject crash mid-execution; replay WAL; assert committed visible, uncommitted absent.
   - Acceptance: deterministic test with simulated crash passes.
   - ISO: §8 durability.
   - Deps: wal/, storage/page_manager.
   - Scope: M
   - DRI: storage

2. WAL flush & durability path (REQ-GQL-026 impl)

   - Why: Make recovery harness meaningful.
   - What: File-backed WAL append + fsync on commit; page LSN tracking.
   - Acceptance: commit test ensures LSN persisted; simulated crash replays.
   - ISO: §8 WAL rule.
   - Deps: wal/, storage/.
   - Scope: M
   - DRI: storage

3. MVCC snapshot isolation carve-out (REQ-GQL-027)

   - Why: Correct read semantics under concurrent writes.
   - What: Per-txn read timestamp; version chains (append-only heap); simple write-write abort.
   - Acceptance: two concurrent writers to same key -> one abort; reader sees snapshot.
   - ISO: §8 isolation.
   - Deps: txn/, storage/.
   - Scope: L
   - DRI: core

4. Counting allocator refinements

   - Why: Improve metric precision.
   - What: Track per-op begin/end snapshots vs net deltas; add peak attribution list.
   - Acceptance: PROFILE bytes_alloc sum equals memory.total_alloc_bytes.
   - ISO: impl-defined metrics.
   - Deps: util/counting_allocator.zig, server/main.zig.
   - Scope: S
   - DRI: core

5. Index scan operator (REQ-GQL-039 exec)

   - Why: Planner cost framework groundwork.
   - What: Implement NodeIndexScan logical & physical; choose selectively.
   - Acceptance: selective predicate chooses index in EXPLAIN.
   - ISO: 14.4 pattern semantics.
   - Deps: planner.zig, storage/.
   - Scope: M
   - DRI: core

6. Doc sync CI & diagnostics fuzz

   - Why: Keep ledger consistent + guard against precedence regressions.
   - What: CI step runs doc_sync + multidiag permutation fuzz.
   - Acceptance: CI passes; failing fold prints reproducible seed.
   - ISO: 23.2 diagnostics.
   - Deps: scripts/doc_sync.zig, diagnostics.zig tests.
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

   ## Completed (moved this cycle)

   - Transactions baseline (REQ-GQL-027 subset) — session state + BEGIN/COMMIT/ROLLBACK plumbing.
   - WAL/ARIES design & LSN layout (REQ-GQL-026 design phase) — Lsn struct, monotonic test.
   - Multi-diagnostics reducer UA002 (REQ-GQL-014/022/030/036) — foldCodes precedence + additional_statuses.
   - Counting allocator (initial) & accurate bytes_alloc groundwork (REQ-GQL-020 enhancement) — CountingAllocator + basic tests.
   - Conformance auto-sync script (REQ-GQL-018) — doc_sync.zig scanning REQ-GQL-### ids.
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
