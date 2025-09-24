# GAP Analysis — geode (CANARY Evidence Driven, Regenerated 2025-09-23)

<!-- STATUS_JSON_SHA256: fe0cdd5bb4dfad59d673583d58b87b1b699c9dd57b4584087cdbb9d15da689b4 -->

> Note: For count-based governance checks, `status.csv` is the authoritative source. This page’s SHA256 marker guards consistency against `status.json`.

## CANARY Evidence (Scanner Lines)

```text
// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Profile Ledger"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering; OWNER=docs; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Freshness Guard"; ASPECT=GovernanceScript; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceScript; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="NEXT Freshness + Single H1"; ASPECT=NextFreshnessGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_NextFreshnessAndSingleH1; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Status JSON Hash Integrity"; ASPECT=StatusJsonHashIntegrity; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_StatusJsonHashIntegrity; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Delta Detection"; ASPECT=DeltaGuardPreview; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceDelta; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Dry Run Wrapper"; ASPECT=DryRunWrapper; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceDryRunWrapper; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Freshness Pre-Warn"; ASPECT=FreshnessPreWarn; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_FreshnessPreWarn; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Aggregate Nightly"; ASPECT=GovernanceAggregate; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceAggregate; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=EstimatorPrimitives; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates; BENCH=BenchmarkCANARY_REQ_GQL_075_CostModelSeedVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSON; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSON; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=CalibrationFeedback; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelCardinalityCalibrationFeedback; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainProtocolBasic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainProtocolBasic; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainProtocolCalibrated; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainProtocolCalibrated; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDetailed; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSONDetailed; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=CalibrationEntries; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelCalibrationEntries; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBias; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBias; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONBiasFactors; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONBiasFactors; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasPersistence; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistence; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=PlannerAdaptiveBiasApplication; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_PlannerAdaptiveBiasApplication; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorDynamicAlpha; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorDynamicAlpha; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDynamicAlpha; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONDynamicAlpha; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasPersistenceV2; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistenceV2; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasClampWarning; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampWarning; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasClampVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-078; FEATURE="ClusterCoordinator"; ASPECT=LeaderStub; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_078_LeaderStub; OWNER=dist; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-078; FEATURE="ClusterCoordinator"; ASPECT=ShardMapStub; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_078_ShardMapStub; OWNER=dist; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-078; FEATURE="ClusterCoordinator"; ASPECT=RaftInterfaceValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_078_RaftInterfaceValidation; OWNER=dist; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=ParserRecognition; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_ParserRecognition; OWNER=engine; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=FixpointDriver; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_FixpointDriver; OWNER=engine; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=CycleGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_CycleGuard; OWNER=engine; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=PolicyCatalog; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_080_PolicyCatalog; OWNER=security; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=EnforcementHook; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_080_EnforcementHook; OWNER=security; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=PolicyCache; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_080_PolicyCache; OWNER=security; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=MetricsRegistry; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_081_MetricsRegistry; OWNER=ops; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=MetricsRegistryVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_081_MetricsRegistryVarianceEnvelope; OWNER=ops; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=PrometheusEndpoint; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_081_PrometheusEndpoint; OWNER=ops; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=CoreMetricsSet; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_081_CoreMetricsSet; OWNER=ops; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-082; FEATURE="BackupRestore"; ASPECT=FullBackup; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_082_FullBackup; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-082; FEATURE="BackupRestore"; ASPECT=IncrementalBackup; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_082_IncrementalBackup; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-082; FEATURE="BackupRestore"; ASPECT=RestoreDriver; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_082_RestoreDriver; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CheckpointSelection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_083_CheckpointSelection; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CompactionJob; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_083_CompactionJob; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=ArchivalHook; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_083_ArchivalHook; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CompactionVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_083_CompactionVarianceEnvelope; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=FrequencySampler; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_084_FrequencySampler; OWNER=optimizer; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=EstimatorApi; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_084_EstimatorApi; OWNER=optimizer; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=AdaptiveFeedbackHook; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_084_AdaptiveFeedbackHook; OWNER=optimizer; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=EstimatorVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_084_EstimatorVarianceEnvelope; OWNER=optimizer; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=LogLevelCliParsing; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_085_LogLevelCliParsing; OWNER=ops; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=LogEmitterFiltering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_085_LogEmitterFiltering; OWNER=ops; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=LogJSONFormat; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_085_LogJSONFormat; OWNER=ops; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=ClientLoggingParity; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_085_ClientLoggingParity; OWNER=ops; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=ReplLaunchPrompt; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_ReplLaunchPrompt; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=MultilineBuffering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_MultilineBuffering; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=HistoryPersistence; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_HistoryPersistence; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=MetaCommandsBasic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_MetaCommandsBasic; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=TxnPromptIndicator; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_TxnPromptIndicator; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=CtrlCCancelBuffer; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_CtrlCCancelBuffer; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=MigrationLedgerSchema; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_MigrationLedgerSchema; OWNER=migration; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=LockAcquisitionTTLHeartbeat; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_LockAcquisitionTTLHeartbeat; OWNER=migration; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=UpApplyOrderingIdempotency; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_UpApplyOrderingIdempotency; OWNER=migration; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=PolicyEnforcementStrictMode; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_PolicyEnforcementStrictMode; OWNER=migration; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ChecksumValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_ChecksumValidation; OWNER=migration; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ResumeTokenDataMigration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_ResumeTokenDataMigration; OWNER=migration; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DriftDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_DriftDetection; OWNER=migration; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=CliParityStatusCommand; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_CliParityStatusCommand; OWNER=migration; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ObservabilityMetrics; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_ObservabilityMetrics; OWNER=migration; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DriftPolicyOutcomeStrict; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_DriftPolicyOutcomeStrict; OWNER=migration; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DownReversalSafety; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_DownReversalSafety; OWNER=migration; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=PlanDryRunIntegrity; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_PlanDryRunIntegrity; OWNER=migration; UPDATED=2025-09-22
```

This authoritative ledger is generated from `status.json` emitted by:

```bash
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

No manual edits should diverge from scanner evidence; contradictions must be resolved by adding/updating CANARY lines or tests/benches. The STATUS_JSON_SHA256 marker above MUST match the current `sha256sum status.json`; validated by governance-check. To refresh the marker after regenerating `status.json` run:

```bash
make canary              # or run the scanner directly
make update-status-hash  # rewrites the STATUS_JSON_SHA256 marker
```

CI SHOULD run `make canary && make update-status-hash` only when accepting an intentional evidence refresh (avoid noisy hash-only commits). The hash guard test (`status_json_hash_integrity.zig`) will fail if the marker drifts.

-- Total aspect rows (status.csv): 607

## 1. Evidence Summary (Derived from latest `status.json`)

The previously published summary (2025-09-22) claimed 0 `STUB` and 0 `IMPL`. The latest scan (raw `status.json`) shows non‑zero counts; documentation is therefore downgraded per Truth & Reconciliation (§3 of unified prompt).

| Metric                       | Count  |
| ---------------------------- | ------ |
| Total aspects (rows)         | 607    |
| BENCHED                      | 229    |
| TESTED (non‑BENCHED)         | 365    |
| STUB                         | 6      |
| IMPL (unpromoted)            | 7      |
| Coverage (TESTED or BENCHED) | 97.86% |
| Stale (>60d)                 | 0      |

Discrepancy note: Prior ledger asserted 100% coverage; actual coverage ( (229+365)/607 = 97.86% ) reflects remaining STUB/IMPL work. This correction prevents over‑claim and aligns with CANARY evidence.

Promotion lattice (policy reminder): IMPL + test → TESTED; (IMPL|TESTED) + bench → BENCHED. Auto‑promotion DOES NOT erase raw `STUB` / `IMPL` lines without evidence; these remain actionable.

Next actions (see `NEXT.md` slices) target elimination of residual `STUB`/`IMPL` lines, prioritizing security, distributed, and storage durability surfaces.

## 1a. Conformance Profile (ISO/IEC 39075:2024)

| Category     | Minimum Feature                     | Optional Features (Claimed)             | Extensions / Impl-Defined (Flagged)                               | Notes                                                                                     |
| ------------ | ----------------------------------- | --------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Core Query   | RETURN, ORDER BY, basic expressions | UNION / INTERSECT / EXCEPT (GQ03–GQ07)  | US001 (unordered pagination policy), UA005/UA006 (path tie-break) | MATCH partial (patterns, OPTIONAL basic)                                                  |
| Pagination   | ORDER + LIMIT legality enforcement  | OFFSET with stable order only           | US001                                                             | OFFSET without ORDER rejected (policy)                                                    |
| Set Ops      | UNION DISTINCT / ALL                | INTERSECT / EXCEPT DISTINCT             |                                                                   | DISTINCT semantics per binding table equivalence                                          |
| Paths        | Variable-length bounded expand      | Structural PathCache enrichments        | UA005/UA006 deterministic ordering                                | Full MATCH semantics (chained OPTIONAL, property predicates over variable-length) pending |
| Transactions | Snapshot Isolation base             | Phantom prevention instrumentation      | I: PhantomGapLockingPolicy (doc)                                  | SSI upgrade path not complete                                                             |
| Diagnostics  | ISO status precedence               | Multi-diagnostic folding                | CollationBinaryDefault, NullOrderPolicyDefault                    | Additional impl-defined items enumerated                                                  |
| Storage      | WAL + basic recovery                | Variance envelopes for compaction/flush |                                                                   | ARIES physiological redo optimizations pending                                            |
| Security     | Basic TDE key rotation              |                                         |                                                                   | KMS / envelope keys absent                                                                |
| Distributed  | Raft append entries subset          |                                         |                                                                   | Elections, snapshots not implemented                                                      |

## 1b. Per-Requirement Aggregation (High-Density REQs)

| REQ         | Aspects (TESTED) | Aspects (BENCHED) | Total | Notes                                                      |
| ----------- | ---------------- | ----------------- | ----- | ---------------------------------------------------------- |
| REQ-GQL-004 | 2                | 3                 | 5     | Updated counts include prefetch & policy aspects           |
| REQ-GQL-012 | 17               | 11                | 28    | Expanded agg breadth (COUNT DISTINCT, AVG, spill variants) |
| REQ-GQL-021 | 11               | 16                | 27    | Planner + PathCache entropy & autotune additions           |
| REQ-GQL-028 | 0                | 0                 | 0     | (Reclassified under storage improvements; see STUB table)  |
| REQ-GQL-032 | 0                | 1                 | 1     | Constraint performance variance                            |
| REQ-GQL-042 | 2                | 1                 | 3     | CDC API + lifecycle + ingest bench                         |
| REQ-GQL-046 | 0                | 1                 | 1     | TDE key rotation throughput                                |
| REQ-GQL-063 | 0                | 1                 | 1     | Dijkstra benchmark                                         |
| REQ-GQL-065 | 0                | 1                 | 1     | Kruskal benchmark                                          |
| REQ-GQL-067 | 0                | 1                 | 1     | PageRank variance envelope                                 |

_Note_: Table reflects representative multi-aspect density; authoritative enumeration remains `status.csv`. Totals here are subset aggregates (not a full sum of 361) and are for planning focus only.

## 2. Conformance / Scope Snapshot (ISO/IEC 39075:2024)

| Domain                                                 | Status         | Notes / Gaps (ISO anchors)                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------ | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Core Query Parsing (RETURN, ORDER, SET OPS)            | TESTED         | Basic linear composition (§14), ORDER/LIMIT legality (§16.16–16.19) enforced (US001).                                                                                                                                                                                                                                                                                                                                     |
| Set Operations (UNION/INTERSECT/EXCEPT)                | TESTED         | Distinct vs ALL semantics validated; no advanced duplicate elimination costs tracked.                                                                                                                                                                                                                                                                                                                                     |
| Aggregation / GROUP BY                                 | TESTED         | Basic group + SUM; advanced aggregates, HAVING, grouping sets (§14.x) absent.                                                                                                                                                                                                                                                                                                                                             |
| Paths / Pattern Matching                               | PARTIAL        | Variable-length expansion + multi-branch & cycle tie-break (UA005/UA006) TESTED; MATCH label/property predicates + OPTIONAL basic null-preserve TESTED; structural path cache key derivation TESTED; key enrichments (value shape, selectivity, degree bucket placeholder) TESTED; hit/miss + collision variance BENCHED (tightened ≥92% unique); remaining: property predicates over variable-length, OPTIONAL chaining. |
| Transactions (MVCC)                                    | TESTED         | Snapshot isolation; phantom prevention bench; full SSI conflict detection coverage incomplete (§17).                                                                                                                                                                                                                                                                                                                      |
| Diagnostics                                            | BENCHED/TESTED | Folding & precedence mapping (§23) covered; multi-diagnostic precedence verified.                                                                                                                                                                                                                                                                                                                                         |
| Conformance Profile / Flagger                          | PARTIAL        | Profile doc exists; automated flagger outputs limited; implementation-defined catalog incomplete (§24).                                                                                                                                                                                                                                                                                                                   |
| Storage (Pages + WAL + Recovery)                       | TESTED/BENCHED | WAL compaction, adaptive policy, flush, recycle variance guarded; crash recovery basic; no ARIES physiological redo optimizations beyond baseline.                                                                                                                                                                                                                                                                        |
| Distributed / Raft                                     | EMERGING       | AppendEntries success/term mismatch + commit advancement (variance) TESTED/BENCHED; election, membership change, snapshotting absent.                                                                                                                                                                                                                                                                                     |
| Security (TDE)                                         | LIMITED        | Key hierarchy + rotation bench; no KMS / envelope keys; no auditing of key use.                                                                                                                                                                                                                                                                                                                                           |
| Advanced Graph Analytics (Centrality, Flows, Matching) | MIXED          | Several benches (PageRank, Betweenness, etc.); others still STUB-level in algorithm sources though benches exist for higher-level wrappers.                                                                                                                                                                                                                                                                               |

## 3. High-Priority Gaps (Updated – Derived from STUB/IMPL Evidence)

| #   | Gap                                                          | Impact                         | Required Evidence to Close                                     | Target Status       |
| --- | ------------------------------------------------------------ | ------------------------------ | -------------------------------------------------------------- | ------------------- |
| 1   | Remaining STUB aspects (6)                                   | Evidence coverage gap          | Convert each STUB to TESTED via minimal positive test or bench | STUB→TESTED/BENCHED |
| 2   | Remaining IMPL aspects (7)                                   | Unverified implementation risk | Add targeted test + variance bench then promote                | IMPL→BENCHED        |
| 3   | Distributed coordinator stubs (REQ-GQL-078)                  | HA roadmap credibility         | Implement leader stub behaviors & shard map; add tests         | STUB→TESTED         |
| 4   | Security RLS/ABAC policy catalog & enforcement (REQ-GQL-080) | Access control correctness     | Implement policy evaluation path + caching tests               | STUB→TESTED         |
| 5   | Monitoring Prometheus endpoint & core metrics (REQ-GQL-081)  | Operability / SLO tracking     | Implement export; verify metrics count & naming                | STUB→TESTED         |
| 6   | Backup/Restore primitives (REQ-GQL-082)                      | Disaster recovery claims       | Implement full + incremental snapshot test                     | STUB→TESTED         |
| 7   | WAL compaction pipeline (REQ-GQL-083)                        | Storage footprint control      | Implement checkpoint selection + compaction job bench          | STUB→BENCHED        |
| 8   | Selectivity estimator framework (REQ-GQL-084)                | Planner cost accuracy          | Implement frequency sampler + adaptive feedback test/bench     | STUB→BENCHED        |
| 9   | Structured logging client parity (REQ-GQL-085)               | DX consistency                 | Implement client log formatting test                           | STUB→TESTED         |
| 10  | Interactive REPL features (REQ-GQL-086)                      | Usability                      | Implement buffering, history, meta commands tests              | STUB→TESTED         |

## 4. Implementation-Defined / Dependent Items (Current Catalog – INCOMPLETE)

| Code                   | Category             | Description                                                            | Evidence                                                   | Status   |
| ---------------------- | -------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------- | -------- |
| US001                  | Policy               | Reject LIMIT/OFFSET without ORDER (default)                            | Tests: TestCANARY_REQ_GQL_004_UnorderedLimitReject         | ENFORCED |
| UA005/UA006            | Tie-break            | Deterministic path expansion tie-break (multi-branch, cycles)          | Multi-branch + cycle determinism + variance bench          | PARTIAL  |
| CollationBinaryDefault | Collation            | Binary collation default (Unicode collation optional feature disabled) | TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering | TESTED   |
| NullOrderPolicyDefault | Null ordering policy | NULLS LAST default ordering policy surfaced via flagger                | TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering | TESTED   |

## 5. Representative Evidence Rows

Below is a concise representative subset (see `status.csv` for the full authoritative table). Rows reflect current BENCHED/TESTED aspects across critical domains.

| Requirement | Feature                        | Aspect                                      | Status  | UPDATED    |
| ----------- | ------------------------------ | ------------------------------------------- | ------- | ---------- |
| REQ-GQL-005 | Binary Protocol Core           | Wire                                        | TESTED  | 2025-09-20 |
| REQ-GQL-010 | Diagnostics Precedence         | Engine                                      | BENCHED | 2025-09-20 |
| REQ-GQL-013 | Txn Conflict Matrix            | Engine                                      | BENCHED | 2025-09-20 |
| REQ-GQL-016 | Path Expand Breadth            | Planner                                     | BENCHED | 2025-09-20 |
| REQ-GQL-021 | Planner Rewrite Pass           | Planner                                     | BENCHED | 2025-09-20 |
| REQ-GQL-021 | Query Planner                  | PlannerRewritePreValidationTiming           | TESTED  | 2025-09-21 |
| REQ-GQL-021 | Query Planner                  | PlannerGroupValidationTiming                | TESTED  | 2025-09-21 |
| REQ-GQL-021 | PathCache                      | PathCacheStructuralKeySelectivityEnrichment | TESTED  | 2025-09-21 |
| REQ-GQL-004 | Pagination                     | PaginationOrderedVarianceEnvelope           | BENCHED | 2025-09-21 |
| REQ-GQL-028 | WAL Segment Recycle            | WALSegmentRecycleLatencyVarianceEnvelope    | BENCHED | 2025-09-21 |
| REQ-GQL-028 | WAL Page Flush Queue Depth     | WALPageFlushQueueDepthVarianceEnvelope      | BENCHED | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctSpillPersistence             | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDecimalSpillMerge                    | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctSpillEvictVarianceEnvelope   | BENCHED | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctSpillAccurateMerge           | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDecimalEarlyState                    | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctMergeVarianceEnvelope        | BENCHED | 2025-09-21 |
| REQ-GQL-021 | PathCache                      | PathCacheLookup                             | TESTED  | 2025-09-21 |
| REQ-GQL-032 | Schema Constraints Performance | ConstraintPerf                              | BENCHED | 2025-09-20 |
| REQ-GQL-042 | CDC Adaptive Flush             | AdaptiveFlush                               | BENCHED | 2025-09-20 |
| REQ-GQL-046 | TDE Key Rotation Throughput    | Storage                                     | BENCHED | 2025-09-20 |
| REQ-GQL-060 | Core Graph Builders            | ConcurrencySafeGraph                        | TESTED  | 2025-09-20 |
| REQ-GQL-063 | Dijkstra                       | Dijkstra                                    | BENCHED | 2025-09-20 |
| REQ-GQL-064 | Biconnected Components         | BiconnectedComponents                       | BENCHED | 2025-09-20 |
| REQ-GQL-065 | Kruskal                        | Kruskal                                     | BENCHED | 2025-09-21 |
| REQ-GQL-067 | PageRank                       | PageRankVarianceEnvelope                    | BENCHED | 2025-09-20 |

## 6. Closing Plan (Rolling – Adjusted to Eliminate STUB/IMPL)

| Slice | Focus                               | Exit Criteria                               | Owner     | Planned Evidence                                    |
| ----- | ----------------------------------- | ------------------------------------------- | --------- | --------------------------------------------------- |
| S1    | Eliminate Remaining STUBs (Batch 1) | 10 STUB aspects promoted (tests added)      | various   | Each new test named per policy                      |
| S2    | Eliminate Remaining STUBs (Batch 2) | Next 10 STUB aspects promoted               | various   | Tests / benches as applicable                       |
| S3    | Distributed Coordinator Core        | REQ-GQL-078 stubs implemented + tests       | dist      | LeaderStub/ShardMap/RaftIface tests                 |
| S4    | RLS/ABAC Enforcement                | Policy catalog, enforcement hook tests      | security  | Policy evaluation + cache hit test                  |
| S5    | Backup/Restore Primitives           | Full + incremental + restore tests          | storage   | Snapshot size + restore integrity                   |
| S6    | WAL Compaction Pipeline             | Checkpoint selection + compaction bench     | storage   | Throughput & space variance bench                   |
| S7    | Selectivity Estimator Framework     | Frequency sampler + adaptive feedback bench | optimizer | Variance envelope + accuracy test                   |
| S8    | IMPL Cost Model Factors Test        | Add test + bench; promote single IMPL       | planner   | TestCANARY_REQ_GQL_024_PlanCostModelFactors + bench |
| S9    | Interactive REPL Core               | REPL launch + multiline + history tests     | client    | Repl tests verifying prompts & cancels              |

## 7. Regeneration & Integrity

Regenerate anytime after code changes (CI also runs `make governance-check` which validates NEXT freshness & hash integrity):

```bash
go build -o ./bin/canaryscan ./tools/canaryscan
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

If `--verify` fails: address stale dates (>60d), missing evidence, or over-claims then re-run. Do NOT hand-edit counts.

## 8. Legend

Status: TESTED (evidence via tests) | BENCHED (has benchmark) | STUB (placeholder) | IMPL (implementation sans test) — last two must remain at 0 under policy.

---

<!-- Duplicate legacy sections pruned to satisfy single-heading policy (MD024). -->

<!-- Legacy duplicate section removed; original 2025-09-21 snapshot was pruned to avoid duplicate headings. -->

This authoritative ledger is generated from `status.json` emitted by:

```bash
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

No manual edits should diverge from scanner evidence; contradictions must be resolved by adding/updating CANARY lines or tests/benches.

## 1. Evidence Summary (Canonical)

| Metric                       | Count  |
| ---------------------------- | ------ |
| Total aspects (rows)         | 607    |
| BENCHED                      | 229    |
| TESTED (non‑BENCHED)         | 365    |
| STUB                         | 6      |
| IMPL (unpromoted)            | 7      |
| Coverage (TESTED or BENCHED) | 97.86% |
| Stale (>60d)                 | 0      |

Promotion lattice (applied automatically): IMPL + test → TESTED; (IMPL|TESTED) + bench → BENCHED. BENCHED dominates counts. Dates enforced under `--strict` (all current aspects fresh).
