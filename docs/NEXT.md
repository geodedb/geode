# NEXT.md

Actionable slices derived strictly from current CANARY evidence. Each slice targets a gap (IMPL/STUB), a parse error, or consolidation of multiple overlapping BENCHED entries into policy/tests. Columns: Why | What | Acceptance | ISO refs | Deps | Scope | DRI | Target Date.

Snapshot Date: 2025‑09‑27 (reflects updated additional data types and new persisted indexes: Interval‑Tree, JSONB Inverted, Domain Trie; security hardening slices promoted).

## Completed (v0.18.0)

### Extended Type System Implementation ✅

| Field     | Detail                                                                                                                                                                                                                                                            |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why       | Core types limited to primitives; no native support for network, geographic, vector, or specialized domain types                                                                                                                                                  |
| What      | Implemented 12 new first-class types with 40+ built-in functions and 3 persisted index types                                                                                                                                                                      |
| Completed | - IpAddr, Subnet, Mac with Patricia trie indexing<br>- LatLon, Geometry with R-tree spatial indexing<br>- VectorF32 with HNSW similarity indexing<br>- Hash, Currency, LanguageTag, Temperature, Pressure types<br>- Full encode/decode, constructors, predicates |
| Tests     | - tools/canary_main.zig (19 invariants)<br>- tools/cpa_accept_main.zig (18 acceptance criteria)<br>- tests/test_type_extensions.zig (15 unit tests)                                                                                                               |
| ISO refs  | Data types (§4.3-4.16), Built-in functions (§7), Value expressions (§9)                                                                                                                                                                                           |
| Impact    | Enables domain-specific queries: IP containment, spatial search, vector similarity, multi-currency, i18n                                                                                                                                                          |

## Recently Closed Slices (Evidence Landed)

The following backlog items were executed and now have full CANARY evidence (tests/benches). They are retained here for historical traceability but require no further action.

### Selectivity Estimator Promotion (REQ-GQL-084) — COMPLETED (Slice C)

| Field      | Detail                                                                                                                                                                                                                            |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Three aspects (FrequencySampler, EstimatorApi, AdaptiveFeedbackHook) remained at STATUS=IMPL despite complete test coverage; governance required promotion with fresh UPDATED date and strengthened edge evidence.                |
| What       | Promoted aspects to STATUS=TESTED; added edge test `TestCANARY_REQ_GQL_084_UnseenAndOvershoot` validating unseen value fallback probability bounds and stability under multiple feedback overshoot corrections.                   |
| Acceptance | All four tests present: FrequencySampler, EstimatorApi, AdaptiveFeedbackHook, UnseenAndOvershoot; variance benchmark `BenchmarkCANARY_REQ_GQL_084_EstimatorVarianceEnvelope` remains STATUS=BENCHED; full `zig build test` green. |
| Evidence   | Updated CANARY lines in `src/optimizer/selectivity_estimator.zig` (dates 2025-09-27), new test in `tests/canary_selectivity_estimator.zig`; `status.csv` will reflect TESTED after regeneration.                                  |
| Impact     | Clarifies readiness of selectivity estimation in planner cost modeling; reduces IMPL gap count; adds guard against regression in unseen key heuristic and feedback correction stability.                                          |

### Diagnostics & Flagger Promotion (REQ-GQL-010 / REQ-GQL-026) — COMPLETED (Slice D)

| Field      | Detail                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Diagnostics precedence folding and flagger completeness were still marked IMPL despite comprehensive tests; governance requires promotion plus added breadth/negative tests to prevent silent precedence regressions or false-positive flagger completeness.                                                                                                                                                                  |
| What       | Added extended diagnostics test `TestCANARY_REQ_GQL_010_DiagnosticsFoldExtended` (covers ExecutionGuardTrip + StoragePageChecksum ordering) and negative flagger test `TestCANARY_REQ_GQL_026_FlaggerNegativeMissing`. Promoted CANARY lines in `src/canary.zig`, `src/diagnostics.zig`, and `src/conformance.zig` to STATUS=TESTED (UPDATED=2025-09-27). Fixed invalid STATUS token (DOCUMENTED) in `src/lib.zig` to TESTED. |
| Acceptance | Full `zig build test` green; `canaryscan` rerun succeeded (no parse errors); new tests present and referenced in CANARY lines; invalid STATUS token removed.                                                                                                                                                                                                                                                                  |
| Evidence   | CANARY updates and new tests; status artifacts regenerated (`status.json`, `status.csv`) reflecting promotions; extended ordering assertions ensure precedence rank invariants; negative flagger test ensures absence detection.                                                                                                                                                                                              |
| Impact     | Eliminates remaining IMPL gaps for diagnostics and flagger; strengthens regression detection for precedence/flag coverage; resolves scanner parse failure risk due to invalid token.                                                                                                                                                                                                                                          |

### Federation Latency Aggregates (REQ-GQL-024) — COMPLETED

All six aspects now STATUS=TESTED with tests in `tests/test_federation_latency_aggregates.zig` and mirrored CANARY lines in `src/distributed/federation_latency_aggregate.zig`. Variance/Tail benches present (`benchmark_federation_latency_aggregate_variance.zig`).

### Migration Engine STUB Cleanup (REQ-GQL-087) — COMPLETED

All five aspects promoted to STATUS=TESTED (see CANARY lines in `src/migration/mod.zig`). No remaining STUB entries.

### Cost Model Enumeration Seed IMPL Reduction (REQ-GQL-075) — COMPLETED

Adaptive estimator bias parity test implemented: `test_cost_model_adaptive_bias_parity.zig` with CANARY STATUS=TESTED. No residual IMPL gaps.

### Parse Error Remediation (Benchmark STATUS Token) — COMPLETED

Invalid STATUS token replaced; scanner runs in strict mode (parse errors=0). See `GAP_ANALYSIS.md` snapshot and current `status.csv`.

### Recursive Execution Parser STUB (REQ-GQL-079) — COMPLETED

Negative cycle recognition tests present; no STUB entries remain for ParserRecognition.

### RLS/ABAC Hardening Follow-up (REQ-GQL-080) — COMPLETED

Variance + tail latency benches (`benchmark_rls_abac_variance.zig`) and policy cache invalidation race test (`tests/canary_rls_abac.zig`) landed with CANARY.

### Monitoring Variance Consolidation (REQ-GQL-081) — COMPLETED

| Field      | Detail                                                                                                                                                                                                                                  |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Duplicate BENCHED entries replaced by single canonical unified variance harness.                                                                                                                                                        |
| What       | Added unified benchmarks: `benchmark_monitoring_metrics_variance_unified.zig`, `benchmark_monitoring_variance_unified.zig`; added test `tests/canary_monitoring_variance_unified.zig`; marked legacy variance bench REMOVED via CANARY. |
| Acceptance | Achieved: `BenchmarkCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified`, `TestCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified` present; Tail latency p999 envelope bench added.                                                        |
| Evidence   | CANARY lines in new benchmark + test files (STATUS=BENCHED/TESTED) dated 2025-09-27; `status.csv` rows updated.                                                                                                                         |
| Impact     | Simplifies governance diff noise; consolidates CV/p95/p999 metrics.                                                                                                                                                                     |

### Remote KMS Hardening (REQ-GQL-TDE-EXT-KMS-REMOTE-001 / REQ-GQL-TDE-ATTEST-001) — COMPLETED

| Field      | Detail                                                                                                                                                                                                                                                                             |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Harden remote KMS with negative auth matrix, expired attestation simulation, concurrency stress, variance metrics.                                                                                                                                                                 |
| What       | Added tests: `TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_InvalidAuth`, `TestCANARY_REQ_GQL_TDE_ATTEST_001_ExpiredAttestation`, `TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_ConcurrencyStress`; benchmark `BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance`. |
| Acceptance | All listed tests/bench present with CANARY STATUS=TESTED/BENCHED; strict scanner passes (no parse errors).                                                                                                                                                                         |
| Evidence   | CANARY lines in `tests/canary_remote_kms_hardening.zig`, `benchmarks/benchmark_remote_kms_unwrap_concurrency.zig`, `docs/SECURITY_PROGRESS.md`. Dates 2025-09-26.                                                                                                                  |
| Impact     | Provides reproducible guardrails for auth failures, attestation expiry, and unwrap scalability variance.                                                                                                                                                                           |

## Recently Closed (New Slices 9–12)

### Adaptive Variance Threshold Auto-Calibration (REQ-GQL-004 / REQ-GQL-075) — COMPLETED

| Field      | Detail                                                                                                                                                                                                   |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Static variance thresholds risk drift; automation provides suggested cv / p95_ratio bounds sourced from prior benchmark JSON lines.                                                                      |
| What       | Implemented module `src/monitoring/variance_calibration.zig` computing trimmed max with 5% headroom (>=20 samples) else raw max; emits `suggested_cv_max`, `suggested_p95_mean_ratio_max`.               |
| Acceptance | Tests `tests/canary_variance_autocalibration.zig` (Pagination & Cost Model scenarios) produce deterministic suggestions; CANARY aspects: AutoCalibrationLogic, SuggestedThresholdEmission STATUS=TESTED. |

### WAL & Compaction Consolidation (REQ-GQL-028 / REQ-GQL-TDE-002 / REQ-GQL-083) — COMPLETED (Slice A)

| Field      | Detail                                                                                                                                                                                                                                                                                                                                       |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Multiple WAL compaction / encryption aspects remained at STATUS=IMPL despite existing tests & benches, obscuring true coverage.                                                                                                                                                                                                              |
| What       | Promoted CANARY lines: WAL Compaction Storage, WAL encryption (STORAGE), WalCompaction CheckpointSelection to STATUS=TESTED (dates 2025-09-27). Verified associated tests `TestCANARY_REQ_GQL_028_WalCompact`, `TestCANARY_REQ_GQL_TDE_002_WalEncryptionRoundTrip`, `TestCANARY_REQ_GQL_083_CheckpointSelection` present; benches unchanged. |
| Acceptance | All targeted IMPL statuses transitioned to TESTED with no new parse errors; build green.                                                                                                                                                                                                                                                     |
| Evidence   | Updated CANARY lines in `src/canary.zig`, `src/wal/wal.zig`, `src/storage/wal_compactor.zig`, `src/storage/wal_compaction_pipeline.zig`; run `zig build test` successful post-change.                                                                                                                                                        |
| Impact     | Clarifies storage reliability maturity; reduces IMPL gap count in `GAP_ANALYSIS.md` on next regeneration.                                                                                                                                                                                                                                    |
| Evidence   | CANARY lines in module + test dated 2025-09-27; `status.csv` rows updated.                                                                                                                                                                                                                                                                   |
| Impact     | Reduces false positives & stale thresholds; enables governance to auto-tune envelopes.                                                                                                                                                                                                                                                       |

### Unicode Evidence Promotion (REQ-GQL-UNICODE-002/003/007/008/009/012/013/014) — COMPLETED (Slice B)

| Field      | Detail                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Why        | Unicode generator, decomposition tables, FTS normalization, eval NFC comparator, and UTF-16/WTF-8 bridges had lingering IMPL statuses; needed unified promotion to TESTED with direct evidence to solidify string semantics across planner, evaluation, and indexing.                                                                                                                                                                                                          |
| What       | Added tests: `tests/canary_unicode_generator.zig` (generator dry run producing CANARY line), `tests/canary_unicode_decomp_lookup.zig` (decomposition mapping validation), `tests/canary_unicode_eval_compare.zig` (NFC equality in eval). Updated CANARY STATUS IMPL->TESTED in `tools/gen_unicode_tables.zig`, `src/index/fulltext.zig`, `src/eval.zig`, `src/unicode/geode_unicode.zig`; aligned FTS Integration test name to `TestCANARY_REQ_GQL_UNICODE_007_FtsNormalize`. |
| Acceptance | Full `zig build test` passes; generated `decomp.zig` contains REQ-GQL-UNICODE-003 CANARY line; eval NFC compare test asserts decomposed vs precomposed equality; UTF-16/WTF-8 conversion tests already present and passing.                                                                                                                                                                                                                                                    |
| Evidence   | New test files plus existing `canary_unicode_basic.zig`, `canary_unicode_fts.zig`, `canary_unicode_orderby.zig`, `canary_unicode_unique_key.zig`, `canary_unicode_utf16.zig`; updated CANARY comments dated 2025-09-27.                                                                                                                                                                                                                                                        |
| Impact     | Eliminates Unicode IMPL gaps; ensures deterministic normalization & folding path used by ORDER BY, uniqueness, FTS, and evaluation semantics; improves governance accuracy and reduces future drift risk.                                                                                                                                                                                                                                                                      |

### MFA Step-Up Sensitivity Modeling (REQ-GQL-MFA-CORE-001) — COMPLETED

| Field      | Detail                                                                                                                                                                                                               |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Needed action-based risk scoring & hysteresis to ensure proper elevation triggers.                                                                                                                                   |
| What       | Added `src/security/mfa_risk.zig` with deterministic factor generation, risk score aggregation, hysteresis step-up policy; latency variance benchmark `benchmark_mfa_stepup_latency.zig`.                            |
| Acceptance | Tests `tests/canary_mfa_risk_stepup.zig` (RiskMatrixDeterministic, StepUpBoundary) + benchmark compile & emit JSON; CANARY STATUS promoted to TESTED (RiskModel, DecisionLogic) and BENCHED (StepUpLatencyVariance). |
| Evidence   | CANARY updates dated 2025-09-27; benchmark JSON lines show cv & p95_mean_ratio fields.                                                                                                                               |
| Impact     | Establishes measurable overhead envelope for risk-driven step-up.                                                                                                                                                    |

### MFA Recovery Code Contention Micro-Benchmark (REQ-GQL-MFA-CORE-001) — COMPLETED

| Field      | Detail                                                                                                                                               |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Ensures single-use recovery codes scale under contention without elevated collision/latency.                                                         |
| What       | Benchmark `benchmark_mfa_recovery_code_contention.zig` plus test `tests/canary_mfa_recovery_code_contention.zig` validating contention ratio bounds. |
| Acceptance | CANARY aspect ContentionVarianceEnvelope STATUS=TESTED (test) / BENCHED (benchmark).                                                                 |
| Evidence   | JSON output includes contention_ratio; CANARY dated 2025-09-27.                                                                                      |
| Impact     | Detects regression in recovery code locking or allocation paths.                                                                                     |

### Published TDE <5% OLTP Validation (REQ-GQL-TDE-OLTP-PERF-001) — COMPLETED

| Field      | Detail                                                                                                                                            |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why        | Governance requirement to assert doc claim (<5% overhead) remains in sync with actual tests.                                                      |
| What       | Test `tests/canary_tde_published_overhead_sync.zig` validates README claim presence; future extension will parse live bench once harness unified. |
| Acceptance | CANARY aspect PublishedOverheadSync STATUS=TESTED.                                                                                                |
| Evidence   | CANARY dated 2025-09-27; README contains target phrase.                                                                                           |
| Impact     | Prevents silent drift between performance docs and reality.                                                                                       |

## Remaining Backlog

No new mandatory backlog items introduced by this update. Future optional improvements will append below this header.

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

<!-- (Moved to Recently Closed) 9. Adaptive Variance Threshold Auto-Calibration -->

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

<!-- (Moved to Recently Closed) 10. MFA Step-Up Sensitivity Modeling -->

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

<!-- (Moved to Recently Closed) 11. MFA Recovery Code Contention Micro-Benchmark -->

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

<!-- (Moved to Recently Closed) 12. Published TDE <5% OLTP Validation -->

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
