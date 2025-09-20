# NEXT — Verifiable Backlog (CANARY Oriented)

Principle: Every slice moves a requirement one evidence grade forward (STUB→IMPL or IMPL→TESTED). No large multi-week epics; each acceptance must cite at least one new CANARY test name before merge.

## NOW (High Priority)

1. REQ-GQL-013 Txn MVCC Test Alignment

   - Why: Current test tagged under legacy ID 030; need canonical 013 evidence.
   - What: Add or rename test `TestCANARY_REQ_GQL_013_TxnCommit` validating begin/commit conflict detection.
   - Acceptance: Scanner shows REQ-GQL-013 status TESTED; REQ-GQL-030 disappears (removed or comment updated).
   - ISO: §8 Transactions.
   - CANARY: Add line in `src/txn/manager.zig` or dedicated test file.

2. REQ-GQL-017 Property Access Execution Test

   - Why: Implementation tagged IMPL but no test evidence.
   - What: Create test `TestCANARY_REQ_GQL_017_PropertyAccess` returning a node property; confirm JSON output.
   - Acceptance: Scan promotes to TESTED.
   - ISO: §4.3 Property Graph Model.

3. REQ-GQL-016 Path Expansion Implementation

   - Why: STUB prevents traversal queries.
   - What: Implement minimal BFS variable-length expand (min..max hops) with deterministic tie-break; test `TestCANARY_REQ_GQL_016_PathExpandBfs`.
   - Acceptance: Status moves STUB→TESTED (auto-promotion after test).
   - ISO: §22 Path Patterns.

4. REQ-GQL-028 WAL Compaction Prototype

   - Why: Log growth unmanaged; currently STUB.
   - What: Implement segment scan + copy-live-records to new file; test `TestCANARY_REQ_GQL_028_WalCompact` verifying size reduction & LSN continuity.
   - Acceptance: STUB→TESTED.
   - ISO: §8 Durability (implementation-defined method).

5. REQ-GQL-042 Minimal CDC Tail
   - Why: Streaming STUB; need first event pipeline.
   - What: Implement tailer reading appended WAL records and pushing JSON change events (node create) to channel; test `TestCANARY_REQ_GQL_042_CDC_StartStop`.
   - Acceptance: STUB→TESTED with start/stop lifecycle.
   - ISO: Extension (impl-defined streaming) + Diagnostics §23 for errors.

## NEXT (After NOW)

1. REQ-GQL-032 Schema Constraints Test Matrix

   - Add tests for unique violation, type mismatch, cardinality; ensure diagnostics precedence consistent (US001 unaffected).

2. REQ-GQL-001/002 Wire Negative Cases

   - Add malformed frame + unsupported capability tests; ensure diagnostics folding.

3. REQ-GQL-010 Multi-Diagnostic Ordering Bench

   - Add benchmark `BenchmarkCANARY_REQ_GQL_010_DiagnosticsFold` to promote Engine aspect to BENCHED.

4. REQ-GQL-017 Property Access Edge Cases

   - Null, missing property, decimal formatting tests.

5. REQ-GQL-016 Path Expansion Performance
   - Add benchmark for breadth growth scenarios.

## LATER (Strategic)

1. REQ-GQL-042 CDC Backfill & Resume Tokens
2. REQ-GQL-028 Adaptive Compaction Heuristics
3. REQ-GQL-013 Serializable Isolation Upgrade Path
4. REQ-GQL-016 Weighted Path Cost (Dijkstra) Integration

## Acceptance Template (Per Slice)

Each PR MUST include:

```text
// CANARY_SAMPLE: REQ=REQ-GQL-XXX; FEATURE="<feature name>"; ASPECT=<Aspect>; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_XXX_<Short>; OWNER=<team>; UPDATED=YYYY-MM-DD
```

Plus at least one test file referencing that test name.

## Progress Metrics

- Goal: Reduce STUB count to 0 in NOW set.
- Goal: Achieve >=70% of listed requirements in TESTED within two iterations.

## Verification Command

`./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`

End of backlog.
