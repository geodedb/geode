# NEXT.md

Actionable slices derived strictly from current CANARY evidence. Each slice targets a gap (IMPL/STUB), a parse error, or consolidation of multiple overlapping BENCHED entries into policy/tests. Columns: Why | What | Acceptance | ISO refs | Deps | Scope | DRI | Target Date.

Snapshot Date: 2025‑09‑26 (matches GAP_ANALYSIS.md). No source edits performed. Future work requires adding or updating CANARY tags in code (out of scope here).

## Slices (Backlog)

### 1. Federation Latency Aggregates (REQ-GQL-024 / LatencyAggregate\*)

| Field       | Detail                                                                                                                                                                                                 |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Why         | Six IMPL aspects (Archive/GovernanceSummary/MultiRun/RobustStats/SchemaValidation/Streak) lack TESTED/BENCHED evidence; risk of silent drift in mismatch diagnostics.                                  |
| What        | Add unit + integration tests generating synthetic federation mismatch events; implement variance envelope benchmark for aggregate streak & schema validation.                                          |
| Acceptance  | Tests: TestCANARY_REQ_GQL_024_FederationLatencyAggregate{Archive,Summary,MultiRun,RobustStats,SchemaValidation,Streak}; Bench: BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateVarianceEnvelope. |
| ISO refs    | GQL ordering & diagnostics propagation (§16.16–16.19 for ordered emission relevance).                                                                                                                  |
| Deps        | Existing federation mismatch benchmarks & protocol tests.                                                                                                                                              |
| Scope       | ~500 LOC tests + 1 benchmark harness.                                                                                                                                                                  |
| DRI         | federation-team                                                                                                                                                                                        |
| Target Date | 2025-10-15                                                                                                                                                                                             |

### 2. Migration Engine STUB Cleanup (REQ-GQL-087 / multiple STUB aspects)

| Field | Detail |
| Why | Four STUB aspects (CliParityStatusCommand, DownReversalSafety, DriftPolicyOutcomeStrict, ObservabilityMetrics, PlanDryRunIntegrity) block governance verify from claiming higher maturity. |
| What | Implement CLI status parity test scaffolding; add safety invariants tests for down reversal; produce metrics export test; create dry-run integrity checksum test. |
| Acceptance | Tests: TestCANARY*REQ_GQL_087*{CliParityStatusCommand,DownReversalSafety,DriftPolicyOutcomeStrict,ObservabilityMetrics,PlanDryRunIntegrity}. All move to TESTED. |
| ISO refs | Conformance & diagnostics reliability mapping (§23). |
| Deps | Existing migration ledger schema tests. |
| Scope | 5 focused tests (~350 LOC). |
| DRI | migration-team |
| Target Date | 2025-10-10 |

### 3. Cost Model Enumeration Seed IMPL Reduction (REQ-GQL-075 / remaining IMPL entry)

| Field | Detail |
| Why | One IMPL aspect remains (AdaptiveEstimatorBias in cost_seed.zig) alongside TESTED/BENCHED peers; risk of uneven bias calibration across enumerations. |
| What | Promote to TESTED via deterministic calibration scenario test comparing expected bias correction deltas vs reported factors. |
| Acceptance | New test: TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasImplementationParity. |
| ISO refs | Query optimization semantics (ISO GQL execution model). |
| Deps | Existing bias persistence & dynamic alpha tests. |
| Scope | Single test ~120 LOC. |
| DRI | planner-team |
| Target Date | 2025-10-05 |

### 4. Parse Error Remediation (Benchmark STATUS Token)

| Field | Detail |
| Why | Previously invalid STATUS=PARTIAL blocked scanner verify; all converted to IMPL/TESTED/BENCHED. |
| What | Replace invalid token with allowed STATUS (likely BENCHED) post confirmation that benchmark produces performance metrics; re-run scanner expecting exit 0. |
| Acceptance | Scanner: `./bin/canaryscan --root . --verify GAP_ANALYSIS.md --strict` returns exit 0. No additional functional tests needed beyond existing benchmark JSON emission check. |
| ISO refs | N/A (governance tooling integrity, internal). |
| Deps | Security team confirmation that benchmark scope matches BENCHED semantics. |
| Scope | 1-line tag fix (separate PR). |
| DRI | security-team |
| Target Date | 2025-09-29 |

### 5. Recursive Execution Parser STUB (REQ-GQL-079 / ParserRecognition STUB)

| Field | Detail |
| Why | Mixed TESTED + STUB entries for ParserRecognition create inconsistent maturity signal. |
| What | Add unit test covering negative + cycle detection path ensuring parser gracefully rejects unsupported recursive constructs outside allowed bounds. |
| Acceptance | Test: TestCANARY_REQ_GQL_079_ParserRecognitionNegativeCycleBound. STUB entry removed (auto-promoted to TESTED). |
| ISO refs | Recursive CTE / pattern recognition (§14 execution of recursive queries). |
| Deps | Existing cycle guard tests. |
| Scope | ~150 LOC test. |
| DRI | engine-team |
| Target Date | 2025-10-03 |

### 6. RLS/ABAC Hardening Follow-up (REQ-GQL-080)

| Field | Detail |
| Why | Current tests cover enforcement/policy cache/catalog; missing stress + variance bench to quantify overhead. |
| What | Introduce benchmark measuring authorization filter latency variance across mixed label/property queries; add negative test for policy cache invalidation race. |
| Acceptance | Bench: BenchmarkCANARY_REQ_GQL_080_RlsAbacEnforcementVarianceEnvelope. Test: TestCANARY_REQ_GQL_080_PolicyCacheInvalidationRace. |
| ISO refs | Security & data access semantics (authorization aspects). |
| Deps | Existing enforcement hook tests. |
| Scope | 1 benchmark + 1 test (~220 LOC). |
| DRI | security-team |
| Target Date | 2025-10-12 |

### 7. Monitoring Variance Consolidation (REQ-GQL-081)

| Field | Detail |
| Why | Duplicate BENCHED entries for MetricsRegistryVarianceEnvelope; desire a single canonical envelope test & bench simplifying governance diffs. |
| What | Deprecate duplicate bench files by merging into unified variance harness; add test asserting single registration path. (Source change required later; tracked here only.) |
| Acceptance | Bench: BenchmarkCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified. Test: TestCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified. |
| ISO refs | N/A (operational, not language). |
| Deps | Existing variance benchmarks. |
| Scope | Refactor bench harness + 1 test (~180 LOC). |
| DRI | ops-team |
| Target Date | 2025-10-18 |

## Governance Notes

- All slices map to existing REQ IDs; no speculative IDs introduced.
- Target Dates are short horizon (<30 days) to maintain freshness guard compliance.
- Future slices should be appended not modified; historical changes tracked in VCS.

## Removed Legacy Sections

Previous marketing roadmap, multi‑year projections, and generic goals were removed because they are not directly verifiable via CANARY evidence. Strategic planning can live in a separate high‑level document outside the governance‑verified scope.

---

END OF FILE
