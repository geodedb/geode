# GAP Analysis — geode (CANARY Evidence Driven)

This file is regenerated to align with present CANARY tokens. A requirement may only be marked TESTED/BENCHED when a CANARY line (possibly promoted) exists with at least one test / benchmark name. All prior marketing completeness claims have been removed.

Legend Status:

- MISSING: no implementation
- STUB: structural placeholder only
- IMPL: implementation present (no test evidence)
- TESTED: at least one test (auto-promotion from IMPL)
- BENCHED: at least one benchmark (strongest)

## Current Evidence Snapshot (see `status.json`)

| Requirement | Feature Aspect                            | Status | Evidence (files)                            | Tests                                                  |
| ----------- | ----------------------------------------- | ------ | ------------------------------------------- | ------------------------------------------------------ |
| REQ-GQL-005 | Binary Protocol Core / Wire               | TESTED | src/protocol.zig                            | TestCANARY_REQ_GQL_005_HelloRoundTrip                  |
| REQ-GQL-010 | Diagnostics Precedence & Folding / Engine | TESTED | src/diagnostics.zig                         | TestCANARY_REQ_GQL_010_DiagnosticsFold                 |
| REQ-GQL-013 | Transactions/MVCC / Engine                | IMPL   | src/txn/manager.zig                         | (add dedicated txn tests)                              |
| REQ-GQL-016 | Path Expansion Operator / Planner         | STUB   | src/planner.zig                             | TestCANARY_REQ_GQL_016_PathExpandBfs                   |
| REQ-GQL-017 | Property Access / Engine                  | IMPL   | src/server/graph/exec.zig                   | (planned TestCANARY_REQ_GQL_017_PropertyAccess)        |
| REQ-GQL-028 | WAL Compaction / Storage                  | STUB   | src/storage/wal_compactor.zig               | TestCANARY_REQ_GQL_028_WalCompact                      |
| REQ-GQL-030 | Transactions/MVCC (old id used)           | TESTED | docs/PROMPTS.md (will merge into 013)       | TestCANARY_REQ_GQL_030_TxnCommit                       |
| REQ-GQL-042 | CDC / API                                 | STUB   | docs/PROMPTS.md                             | tests/e2e_cdc.zig:TestCANARY_REQ_GQL_042_CDC_StartStop |
| REQ-GQL-046 | TDE / Storage                             | TESTED | tools/canaryscan/internal/fixtures/file2.go | TestCANARY_REQ_GQL_046_KeyRotate                       |

Pending Normalization: REQ-GQL-030 duplicate of REQ-GQL-013 (identifier misuse earlier). Future scans will retain only REQ-GQL-013.

## Gaps & Immediate Actions

| REQ | Gap                                                         | Action                                              | Target     |
| --- | ----------------------------------------------------------- | --------------------------------------------------- | ---------- |
| 013 | No explicit test tagged (only commit test under old ID 030) | Rename test or add new CANARY line with 013         | Short-term |
| 016 | Still STUB (no algorithm)                                   | Implement variable-length traversal, add test       | Short-term |
| 017 | Needs tagged test                                           | Add execution & property projection test            | Short-term |
| 028 | STUB compactor                                              | Implement basic log segment rewrite & test metadata | Mid-term   |
| 042 | No CDC implementation                                       | Implement minimal WAL tailer & emit events          | Mid-term   |

## Conformance Commentary

Only requirements with CANARY evidence are listed. Previous claims (e.g., broad optimizer, GPU, ML) lacked evidence and are intentionally omitted until tagged.

## Next Steps Traceability

See `NEXT.md` for verifiable slices adding tests to move IMPL→TESTED and STUB→IMPL.

## Scan Integrity

Verification uses: `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`. This file avoids claiming "Implemented" explicitly; promotion is derived from scan.

End of report.
