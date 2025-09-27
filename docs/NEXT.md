# NEXT.md

Actionable slices derived strictly from current CANARY evidence. Each slice targets a gap (IMPL/STUB), a parse error, or consolidation of multiple overlapping BENCHED entries into policy/tests. Columns: Why | What | Acceptance | ISO refs | Deps | Scope | DRI | Target Date.

Snapshot Date: 2025‑09‑26 (matches GAP_ANALYSIS.md). No source edits performed. Future work requires adding or updating CANARY tags in code (out of scope here).

## Completed (v0.18.0)

### Extended Type System Implementation ✅

| Field       | Detail |
| ----------- | ------ |
| Why         | Core types limited to primitives; no native support for network, geographic, vector, or specialized domain types |
| What        | Implemented 12 new first-class types with 40+ built-in functions and 3 persisted index types |
| Completed   | - IpAddr, Subnet, Mac with Patricia trie indexing<br>- LatLon, Geometry with R-tree spatial indexing<br>- VectorF32 with HNSW similarity indexing<br>- Hash, Currency, LanguageTag, Temperature, Pressure types<br>- Full encode/decode, constructors, predicates |
| Tests       | - tools/canary_main.zig (19 invariants)<br>- tools/cpa_accept_main.zig (18 acceptance criteria)<br>- tests/test_type_extensions.zig (15 unit tests) |
| ISO refs    | Data types (§4.3-4.16), Built-in functions (§7), Value expressions (§9) |
| Impact      | Enables domain-specific queries: IP containment, spatial search, vector similarity, multi-currency, i18n |

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

### 8. Remote KMS Hardening (REQ-GQL-TDE-EXT-KMS-REMOTE-001 / REQ-GQL-TDE-ATTEST-001)

| Field       | Detail                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why         | Prototype remote KMS gained auth + attestation + privileged unwrap earlier; lacked negative auth matrix, expired/rotated attestation simulation, and concurrency variance evidence. Risk of silent regressions in cryptographic guard paths and unwrap scalability under contention.                                                                                                                                          |
| What        | Add negative auth rejection test, expired attestation tamper simulation test, concurrency stress unwrap test, and variance benchmark capturing cv + p95_mean_ratio for unwrap latency (establishing baseline).                                                                                                                                                                                                                |
| Acceptance  | Tests: TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_InvalidAuth, TestCANARY_REQ_GQL_TDE_ATTEST_001_ExpiredAttestation, TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_ConcurrencyStress; Bench: BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance. CANARY tags present with STATUS=TESTED/BENCHED (NegativeAuthMatrix, ExpiredAttestation, ConcurrencyStressVariance). Scanner passes strict mode (CANARY_OK). |
| ISO refs    | Security & key management integrity (mapping to implementation-defined encryption services; diagnostics reliability §23).                                                                                                                                                                                                                                                                                                     |
| Deps        | Existing kms_remote server/client scaffold; QUIC transport module.                                                                                                                                                                                                                                                                                                                                                            |
| Scope       | ~180 LOC tests + benchmark harness.                                                                                                                                                                                                                                                                                                                                                                                           |
| DRI         | security-team                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Target Date | 2025-09-30                                                                                                                                                                                                                                                                                                                                                                                                                    |

## Governance Notes

- All slices map to existing REQ IDs; no speculative IDs introduced.
- Target Dates are short horizon (<30 days) to maintain freshness guard compliance.
- Future slices should be appended not modified; historical changes tracked in VCS.

## Removed Legacy Sections

Previous marketing roadmap, multi‑year projections, and generic goals were removed because they are not directly verifiable via CANARY evidence. Strategic planning can live in a separate high‑level document outside the governance‑verified scope.

---

END OF FILE

### 8. Tail Latency Envelope Expansion (REQ-GQL-024 / REQ-GQL-080 / REQ-GQL-081)

| Field       | Detail                                                                                                                                                                                                                                                                                                          |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why         | Current variance benches focus on mean/p95/p99; lack of p99.9 (tail) tracking risks silent regression in rare-path latency for federation aggregates, RLS/ABAC enforcement, and metrics registry operations.                                                                                                    |
| What        | Extend existing variance benchmark harnesses (federation latency aggregate, RLS/ABAC enforcement, monitoring metrics) to capture p99.9 and tail outlier ratio; introduce new aspects (TailLatencyP999Envelope) under each REQ.                                                                                  |
| Acceptance  | Benches updated to emit p999_ns + p999_mean_ratio; New CANARY tags: BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateTailP999, BenchmarkCANARY_REQ_GQL_080_RlsAbacTailP999, BenchmarkCANARY_REQ_GQL_081_MetricsRegistryTailP999. Threshold doc: p999_mean_ratio <= 5.0 (initial) with TODO for tightening. |
| ISO refs    | Diagnostics & ordered emission relevance (§16.16–16.19) for latency observability; security enforcement timing (authorization semantics).                                                                                                                                                                       |
| Deps        | Existing variance harness code paths; histogram/percentile utility already used for p95/p99.                                                                                                                                                                                                                    |
| Scope       | ~60 LOC per harness (metrics additions + CANARY lines) ~180 LOC total.                                                                                                                                                                                                                                          |
| DRI         | perf-team                                                                                                                                                                                                                                                                                                       |
| Target Date | 2025-10-08                                                                                                                                                                                                                                                                                                      |

### 9. Adaptive Variance Threshold Auto-Calibration (REQ-GQL-004 / REQ-GQL-075)

| Field       | Detail                                                                                                                                                                                                                                                                                                                  |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why         | Static variance thresholds (cv, p95/mean) can become stale as hardware or allocator behavior evolves, leading to false positives or missed regressions.                                                                                                                                                                 |
| What        | Implement calibration utility reading last N benchmark JSON outputs (pagination + cost model bias benches) to compute rolling baseline and emit suggested thresholds; add test verifying deterministic suggestion given fixed historical sample; add CANARY aspects (AutoCalibrationLogic, SuggestedThresholdEmission). |
| Acceptance  | Test: TestCANARY_REQ_GQL_004_PaginationVarianceAutoCalibration & TestCANARY_REQ_GQL_075_CostModelVarianceAutoCalibration; Tool outputs JSON with new fields: suggested_cv_max, suggested_p95_mean_ratio_max. CANARY tags promoted to TESTED.                                                                            |
| ISO refs    | Planner performance predictability (execution model stability).                                                                                                                                                                                                                                                         |
| Deps        | Existing benchmark output directory; JSON parsing utility.                                                                                                                                                                                                                                                              |
| Scope       | ~250 LOC calibration module + 2 tests.                                                                                                                                                                                                                                                                                  |
| DRI         | planner-team                                                                                                                                                                                                                                                                                                            |
| Target Date | 2025-10-14                                                                                                                                                                                                                                                                                                              |

### 10. MFA Step-Up Sensitivity Modeling (REQ-GQL-MFA-CORE-001)

| Field       | Detail                                                                                                                                                                                                                                                                                                                                                                |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why         | Current MFA tests cover enrollment, recovery, elevation TTL, and policy basics but lack per-action risk sensitivity modeling; without sensitivity matrix, high-risk operations might skip required step-up under new policies.                                                                                                                                        |
| What        | Introduce risk model mapping (action -> base_risk_score) and adaptive policy that enforces step-up when (base_risk_score + dynamic_factors) >= threshold. Add tests for low/high risk actions and boundary conditions; add variance benchmark measuring added latency of step-up vs baseline auth. New aspects: RiskSensitivityMatrix, StepUpLatencyVarianceEnvelope. |
| Acceptance  | Tests: TestCANARY_REQ_GQL_MFA_CORE_001_RiskSensitivityMatrix, TestCANARY_REQ_GQL_MFA_CORE_001_StepUpBoundary; Bench: BenchmarkCANARY_REQ_GQL_MFA_CORE_001_StepUpLatencyVariance (captures mean, p95, added_latency_overhead<=2.0x). CANARY tags set to TESTED/BENCHED.                                                                                                |
| ISO refs    | Security & access control semantics; authentication strengthening (implementation-defined policies).                                                                                                                                                                                                                                                                  |
| Deps        | Existing MFA policy engine + audit hooks.                                                                                                                                                                                                                                                                                                                             |
| Scope       | ~300 LOC (risk model + tests + bench).                                                                                                                                                                                                                                                                                                                                |
| DRI         | security-team                                                                                                                                                                                                                                                                                                                                                         |
| Target Date | 2025-10-16                                                                                                                                                                                                                                                                                                                                                            |

### 11. MFA Recovery Code Contention Micro-Benchmark (REQ-GQL-MFA-CORE-001)

| Field       | Detail                                                                                                                                                                                                                                                                                 |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why         | Recovery codes are single-use; high concurrency consumption could surface race conditions or lock contention not observable in functional tests.                                                                                                                                       |
| What        | Implement micro-benchmark spawning concurrent consumers (configurable goroutines/threads) measuring success rate, mean acquire latency, contention ratio (spins/attempt); add aspect ContentionVarianceEnvelope.                                                                       |
| Acceptance  | Bench: BenchmarkCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionVariance (metrics: mean_acquire_ns, cv<=0.35, contention_ratio<=0.10). CANARY tag BENCHED; optional test verifying all codes consumed exactly once: TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionSingleUse. |
| ISO refs    | Security token single-use guarantees.                                                                                                                                                                                                                                                  |
| Deps        | Existing recovery code data structures.                                                                                                                                                                                                                                                |
| Scope       | ~180 LOC bench + 60 LOC test.                                                                                                                                                                                                                                                          |
| DRI         | perf-team                                                                                                                                                                                                                                                                              |
| Target Date | 2025-10-12                                                                                                                                                                                                                                                                             |

### 12. Published TDE <5% OLTP Validation (REQ-GQL-TDE-OLTP-PERF-001)

| Field       | Detail                                                                                                                                                                                                            |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why         | Internal benchmark asserts <5% overhead, but no publication/test ensures documentation stays in sync; risk of regression without failing governance.                                                              |
| What        | Add integration test that runs OLTP sim bench (existing) with and without TDE key, computes overhead, and verifies README/perf doc updated with current figure (string match). New aspect: PublishedOverheadSync. |
| Acceptance  | Test: TestCANARY_REQ_GQL_TDE_OLTP_PERF_001_PublishedOverheadSync; updates docs/perf section automatically (dry-run mode optional). CANARY tag TESTED.                                                             |
| ISO refs    | Performance transparency (implementation-defined).                                                                                                                                                                |
| Deps        | Existing OLTP sim benchmark + README section.                                                                                                                                                                     |
| Scope       | ~140 LOC test + doc update script (~60 LOC).                                                                                                                                                                      |
| DRI         | perf-team                                                                                                                                                                                                         |
| Target Date | 2025-10-19                                                                                                                                                                                                        |

## Optional Improvement Slices (New)

The above slices (8–12) are optional enhancements extending observability, security robustness, and performance governance. They deliberately reuse existing REQ IDs; no new identifiers introduced. Execution order recommendation: 8 (Remote KMS Hardening, already completed) -> 9 (Adaptive variance calibration) -> 10 (MFA sensitivity modeling) -> 11 (MFA recovery contention) -> 12 (Published TDE overhead sync).
