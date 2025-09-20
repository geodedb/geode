# NEXT — Verifiable Backlog (Aligned with Current Evidence 2025-09-20)

Principle: Each slice introduces or upgrades at most one aspect per REQ and MUST add at least one new CANARY test or bench name. Small, reviewable, machine-verifiable.

## NOW (Execute Immediately)

1. REQ-GQL-042 CDC Core API Lifecycle (COMPLETED: TESTED)

   - Why: Core CDC API still STUB; need functional start/stop lifecycle.
   - What: Implement minimal start (register listener) and stop (drain + close) semantics in CDC API layer.
   - Tests: Add `TestCANARY_REQ_GQL_042_CDC_StartStopLifecycle` (ensures idempotent stop, emits START/STOP diagnostics sequence).
   - CANARY: Update existing CDC API line to include new test; STATUS stays STUB until implementation then IMPL auto-promotes to TESTED.
   - Acceptance: Scan shows REQ-GQL-042 CDC API status TESTED; log contains no resource leak warnings.

2. REQ-GQL-013 Transactions Bench (COMPLETED: BENCHED)

   - Why: No performance signal; need baseline conflict matrix cost.
   - What: Add benchmark measuring commit latency under write/write conflicts.
   - Bench: `BenchmarkCANARY_REQ_GQL_013_TxnConflictMatrix`.
   - Acceptance: REQ-GQL-013 gains a BENCHED aspect (or existing upgraded to BENCHED) with benchmark listed.

3. REQ-GQL-017 Property Access Hot Path (COMPLETED: BENCHED)

   - Why: Add visibility into property lookup micro-cost.
   - Bench: `BenchmarkCANARY_REQ_GQL_017_PropertyAccessHotPath` scanning 1M simple accesses.
   - Acceptance: New BENCHED entry; runtime < target threshold documented (record initial ms/op baseline in README perf notes).

4. REQ-GQL-005 Frame Decode Micro-bench (COMPLETED: BENCHED)

   - Why: Wire performance unmeasured; ensure framing overhead tracked.
   - Bench: `BenchmarkCANARY_REQ_GQL_005_FrameDecode` reading synthetic HELLO/PULL frames.
   - Acceptance: BENCHED entry appears; captures bytes/sec metric in benchmark log (informational).

5. REQ-GQL-016 Path Expansion Breadth Stress (COMPLETED: BENCHED)
   - Why: Existing benches cover pruning, mem; need pure breadth growth scaling.
   - Bench: `BenchmarkCANARY_REQ_GQL_016_PathExpandBreadth`.
   - Acceptance: Additional BENCHED aspect with new bench name; no regressions in existing path benches (±5%).

## NEXT (Queue After NOW)

1. REQ-GQL-028 Adaptive Compaction Policy (COMPLETED)
   - Implemented `BenchmarkCANARY_REQ_GQL_028_WalAdaptivePolicy`.
2. REQ-GQL-032 Constraint Negative Diagnostics Matrix (COMPLETED)
   - Added negative tests for unique + type mismatch.
3. REQ-GQL-042 CDC Resume Tokens (COMPLETED)
   - Added resume token generation & replay test.
4. REQ-GQL-010 Diagnostics Large Fold Memory (COMPLETED)
   - Added large fold benchmark.
5. REQ-GQL-004 Pagination Policy Edge (COMPLETED)
   - Added override toggle test.

## LATER (Strategic / Design)

1. REQ-GQL-046 TDE Key Rotation Bench (COMPLETED) `BenchmarkCANARY_REQ_GQL_046_KeyRotateThroughput`.
2. REQ-GQL-042 Backfill & Catch-up Latency (COMPLETED) `BenchmarkCANARY_REQ_GQL_042_CDC_BackfillLatency`.
3. REQ-GQL-016 Weighted Path Cost (COMPLETED) test `TestCANARY_REQ_GQL_016_PathWeightedCost`.
4. REQ-GQL-028 Crash Recovery Compaction Interaction (COMPLETED) test `TestCANARY_REQ_GQL_028_RecoveryAfterCompaction`.

## Slice Template

```text
// Example (replace placeholders):
// CANARY: REQ=REQ-GQL-013; FEATURE="Txn Conflict Matrix"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_013_TxnConflictMatrix; BENCH=BenchmarkCANARY_REQ_GQL_013_TxnConflictMatrix; OWNER=engine; UPDATED=2025-09-20
```

Every PR: include updated CANARY line(s) + new test/bench names compiled & passing. Avoid modifying historical UPDATED dates unless feature changed.

## Verification

Command (CI & local):
`./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`

Failure modes:

- `CANARY_VERIFY_FAIL` if over-claim introduced.
- `CANARY_STALE` if UPDATED > 60 days.

## Progress Metrics

Target after NOW:

- Reduce STUB count for REQ-GQL-042 (CDC API aspects) from 2 → 0.
- Increase BENCHED coverage for core runtime (txn, property, wire, planner) by +4 aspects.

End of backlog.
