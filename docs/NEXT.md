<!-- NEXT.md — Prioritized Execution Backlog (ISO‑GQL Aligned) -->

# NEXT — Execution‑Ready Backlog (ISO‑GQL Aligned)

Each task: Why • What • Acceptance (GQL + expected binding schema / diagnostics) • ISO anchors • Deps • Scope (S/M/L) • DRI.

## Recently Completed (P0 wrap-up)

1. Diagnostics precedence & multi-status cluster (REQ-GQL-014/022/030/036) — precedence table validated via multidiag tests.
2. EXPLAIN / PROFILE stabilization (REQ-GQL-019/020/033) — profile_version=2 frozen; snapshot freeze tests added.
3. Decimal ordering correctness & fuzz (REQ-GQL-031/037/013) — 10k pair fuzz + mixed-scale comparator.
4. Storage integration phase 0 (REQ-GQL-025) — slotted page manager + unit test.
5. Parameter arrays: empty & hetero coverage (REQ-GQL-015/032) — zero-length expansion semantics.
6. Flagger enhancement (REQ-GQL-010/029) — US001/enforced flag in ERROR frames.
7. Recovery harness initial (REQ-GQL-041) — e2e_wal_recovery updated to structured Insert/prev_lsn chain.
8. WAL / ARIES phase 2 (REQ-GQL-026) — structured Insert/Delete/BeforeImage, durable page images, pageLSN persistence, checkpoint LSN bounding, CLRs (live + recovery), delete undo slot reuse, idempotent redo test, crash mini fuzz.
9. MVCC snapshot carve-out (REQ-GQL-027) — txn timestamps + version skeleton.
10. Counting allocator invariant (REQ-GQL-020 enhancement) — per-op sum test added.
11. Index scan heuristic (REQ-GQL-039) — NodeIndexScan op emitted under simple WHERE equality.
12. Doc sync section test — NEXT.md structure & profile_version=2 assertion.
13. WAL checksum field + corruption tail truncation tolerance (REQ-GQL-026 addendum) — adler32 per-record; corruption test passes.
14. Index catalog stub + selectivity threshold (REQ-GQL-039 phase 2 start) — synthetic catalog entry, eqSelectivity heuristic, flag emission retained.
15. Predicate expansion (logical AND/OR traversal) — nested equality detection test added.
16. Benchmark harness (heuristic planning micro) — JSON timing line; bench smoke test.
17. WAL checksum corruption test — ensures recovery halts at first checksum mismatch without panic.

## Now (P0)

1. WAL/ARIES Hardening (REQ-GQL-026 phase 3)

   - Why: Reduce recovery latency & broaden correctness surface.
   - What: Implement redo start binary seek, segment rollover, torn-write sentinel, full CLR chain validation, page checksum verification (record checksums done).
   - Acceptance: 5k fuzz iterations (crash/truncate/random tail bytes) pass; redo start skips >70% of pre-checkpoint log in synthetic test; segment rollover test verifies boundary; page checksum mismatch surfaces diagnostic.
   - ISO: §8 durability (steal/no-force) + impl-defined recovery optimizations.
   - Scope: L • DRI: storage

2. MVCC Conflict Detection & Lock Skeleton (REQ-GQL-027 phase 2)

   - Why: Enforce write-write exclusion and snapshot visibility.
   - What: Add simple hash-based lock table; abort second writer to same key.
   - Acceptance: Concurrent write test passes; reader snapshot stable.
   - ISO: §8 isolation.
   - Scope: M • DRI: core

3. Index Catalog & Cost Stub (REQ-GQL-039 phase 2 continuation)

   - Why: Replace heuristic with metadata-driven choice.
   - What: Expand from single synthetic entry to keyed map (property->stats), maintain row & distinct counts, incorporate into planner cost comparison (replace heuristic gating).
   - Acceptance: EXPLAIN shows NodeIndexScan only when eqSelectivity <= threshold; disabling catalog (env) falls back to NodeScan.
   - ISO: 14.4 pattern semantics.
   - Scope: M • DRI: core

4. Doc Sync Automation (REQ-GQL-018)

   - Why: Eliminate manual drift updates.
   - What: Implement `zig run doc_sync.zig` to validate REQ IDs & profile_version.
   - Acceptance: Script returns zero diff status on clean tree; test harness passes.
   - ISO: §24 conformance documentation.
   - Scope: S • DRI: docs

5. Recovery Fuzz & Crash Injector (REQ-GQL-041 phase 2)

   - Why: Extend mini fuzz into robust harness.
   - What: Deterministic seed sweep (1..1000), random op sequences, forced sync and truncation, checksum fault injection.
   - Acceptance: 1k iterations, zero invariant failures; invariant: committed rows stable & loser effects absent; checksum injection yields diagnostic not panic.
   - ISO: §8 durability.
   - Scope: M • DRI: storage

6. Peak Memory Attribution Refinement (REQ-GQL-020)
   - Why: Attribute peak to contributing ops.
   - What: Track top-N op ids at peak snapshot; include `peak_contributors` details.
   - Acceptance: PROFILE includes stable contributor list; test asserts presence.
   - ISO: Impl-defined metrics.
   - Scope: S • DRI: core

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

- ARIES phase 2 implemented: structured log records (Insert/Delete/BeforeImage/CLR/Checkpoint), pageLSN persistence to disk pages, checkpoint LSN bounding, recovery & live CLRs, delete undo slot reuse.
- Updated committed-only recovery test to new record formats; added idempotent redo & tail truncation tolerance tests.
- Added durable page image writing & loading; page header includes LSN for redo skip across restarts.
- Implemented mini crash fuzz test (random sequence + crash point) validating idempotent double recovery.
- Extended recovery undo to persist CLRs for loser txns.
- Enhanced delete undo to reuse original slot when tombstoned.

## Proposed Next Steps Summary (delta)

1. Implement redo binary seek & segment rollover + page checksums (026 remaining).
2. Add lock manager & conflict abort path (027 phase 2).
3. Replace heuristic with cost-based plan using catalog stats (039 phase 2 cont.).
4. Build doc_sync automation script and test (018) (still pending automation, validation script placeholder).
5. Expand recovery fuzz to 1k seeds + injected checksum faults & truncations (041).
6. Enhance PROFILE peak attribution list (020) with top-N contributor capture.
7. Add heuristic A/B runtime toggle (env) to bench for cleaner differential metrics.
