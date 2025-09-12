<!-- NEXT.md — Prioritized Execution Backlog (ISO‑GQL Aligned) -->

# NEXT — Execution‑Ready Backlog (ISO‑GQL Aligned)

Each task: Why • What • Acceptance (GQL + expected binding schema / diagnostics) • ISO anchors • Deps • Scope (S/M/L) • DRI.

## Recently Completed (P0 wrap-up)

1. WAL fast-seek sparse pageLSN index & integration (REQ-GQL-026 enhancement).
2. Recovery fuzz expansion (1k seeds with truncation & checksum corruption) (REQ-GQL-041 phase 2).
3. MVCC delete_ts + rollback undo & visibility test (REQ-GQL-027 phase 2 cont.).
4. Index stats maintenance hooks + IndexMeta stub op (REQ-GQL-039 maintenance phase).
5. doc_sync uniqueness enforcement (exactly-one REQ occurrence) (REQ-GQL-018 advancement).
6. StoragePageChecksum diagnostic code added (REQ-GQL-026 diagnostics).
7. Peak contributors ordering accuracy test (REQ-GQL-020 accuracy).
8. GAP_ANALYSIS updated with new progress lines.

## Now (P0)

1. Embed index_name & selectivity inline in NodeIndexScan PROFILE JSON (remove IndexMeta stub) — REQ-GQL-039.
2. WAL skip% metric + test (synthetic pattern >60% skip) — REQ-GQL-026.
3. Propagate StoragePageChecksum diagnostic during recovery (map page_manager failure) — REQ-GQL-026.

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

### WAL Segment Compaction

Implemented initial WAL segment compaction (`Wal.compact(durable_lsn)`) reclaiming segments whose max LSN is below the provided durable checkpoint LSN. Current safety rule retains the active (latest) segment even if fully obsolete; deeper reclamation will follow once checkpoint+rotation choreography lands. Test `e2e_wal_compaction.zig` validates segment deletion and recovery idempotence.

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

- Fast-seek WAL redo path with sparse pageLSN index integrated.
- Expanded recovery fuzz harness (1k seeds, truncation + checksum corruption) green.
- MVCC delete_ts + rollback visibility semantics implemented.
- Index maintenance hooks & IndexMeta op emitting preliminary metadata.
- doc_sync uniqueness enforcement active (CI-ready).
- StoragePageChecksum diagnostic code defined.
- Peak contributors ordering accuracy test added.

## Proposed Next Steps Summary (delta)

1. Inline index metadata (remove IndexMeta stub) & add selectivity field.
2. WAL skip% exposure + synthetic test asserts >60% skip.
3. Recovery path emits StoragePageChecksum diagnostic on page load failure.
4. Scale fuzz seeds to 5k if runtime <30s; otherwise adaptive sampling.
5. Reservoir-sample distinct estimator for selectivity.
6. MVCC version GC & snapshot pin epoch.
7. Real allocator integration for peak contributors.
8. Plan rationale field documenting index choice factors.
