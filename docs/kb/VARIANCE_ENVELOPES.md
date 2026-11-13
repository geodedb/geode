# Variance Envelope Registry — Geode

Generated catalog of all BENCHED variance / jitter / performance guard aspects (suffix `VarianceEnvelope`) extracted from `status.csv` (authoritative CANARY scan). Each envelope enforces CV ≤ 0.22 and p95/mean ≤ 2.55 unless a tighter/looser policy is explicitly listed.

> Source of truth: `status.csv` / `status.json`. This file is regenerated or updated when new BENCHED variance aspects land. Non-authoritative narrative only — discrepancies must be resolved by adjusting CANARY lines + benchmarks.

## 1. Summary

- Total variance envelopes (BENCHED): 70+ (see exact count in `status.csv`)
- Global policy: CV ≤ 0.22, p95/mean ≤ 2.55 (standard)
- Tightened envelopes (custom thresholds):
  - `AdvancedCostModelCalibrationVarianceEnvelope`: CV ≤ 0.20, p95/mean ≤ 2.50
  - `PlanCostModelCalibrationVarianceEnvelope`: CV ≤ 0.20, p95/mean ≤ 2.50
- Future candidates for tightening: Path cache lookup, WAL flush batch, redo optimized latency.

## 2. Envelope Listing (Grouped)

### Pagination & Planner Pagination

- PaginationExecutionVarianceEnvelope
- PaginationOrderedVarianceEnvelope
- PaginationPrefetchVarianceEnvelope

### Aggregation / Group By

- CountDistinctVarianceEnvelope
- HashAggDistinctSpillEvictVarianceEnvelope
- AvgVarianceEnvelope
- HashAggDistinctHighCardVarianceEnvelope
- HashAggDistinctMergeVarianceEnvelope
- HashAggSpillEvictVarianceEnvelope
- HashAggSpillVarianceEnvelope
- MixedAggregateVarianceEnvelope

### Transactions / MVCC

- MVCCVersionPruneVarianceEnvelope
- TxnConflictMatrixVarianceEnvelope
- MVCCRepairThroughputVarianceEnvelope
- WriteSkewVarianceEnvelope
- RangeTrackerOverheadVarianceEnvelope

### Set Operations

- SetOpDistinctDedupVarianceEnvelope

### Path & Graph Expansion

- PathExpansionHeuristicVarianceEnvelope
- PathExpandBreadthVarianceEnvelope
- PathExpandAllocVarianceEnvelope
- PathHighBranchVarianceEnvelope
- PathMultiBranchDeterminismVarianceEnvelope
- PathQuantifierBoundedVarianceEnvelope
- PathVariableLengthPropertyPredicateVarianceEnvelope

### Property / Access Hot Paths

- PropertyAccessHotPathVarianceEnvelope

### PathCache

- PathCacheEntropyVarianceEnvelope
- PathCacheHitMissVarianceEnvelope
- PathCacheLookupVarianceEnvelope
- PathCacheDegreeBucketUtilizationVarianceEnvelope
- PathCachePlannerPipelineVarianceEnvelope (alias: PlannerPipelineVarianceEnvelope) _if present in scan_
- PathCacheStructuralKeyCollisionVarianceEnvelope (legacy, if still present)

### Query Planner (Cost Model & Enumeration)

- PlanCostModelCalibrationVarianceEnvelope
- AdvancedCostModelCalibrationVarianceEnvelope
- PlanCostModelVarianceEnvelope
- PlanEnumerationVarianceEnvelope
- PlanEnumerationCostPruneVarianceEnvelope
- PlanJoinReorderVarianceEnvelope
- PlanSelectionVarianceEnvelope
- PlanSelectionPipelineVarianceEnvelope
- PlannerAdaptiveReplanVarianceEnvelope
- PlannerAdaptiveReplanRefinementVarianceEnvelope
- PlannerCardinalityEstimateVarianceEnvelope
- PlannerRewritePassVarianceEnvelope (if present)
- PlannerPreValidationVarianceEnvelope
- PlannerGroupValidationVarianceEnvelope
- PlannerProjectionPruneVarianceEnvelope

### WAL / Storage / Recovery

- WALFlushBatchVarianceEnvelope
- WALIOThrottleVarianceEnvelope
- WALPageFlushQueueDepthVarianceEnvelope
- WALSegmentRecycleLatencyVarianceEnvelope
- WalAdaptivePolicyLatencyVarianceEnvelope
- WalCompactionVarianceEnvelope
- RedoOptimizedVarianceEnvelope
- RedoOptimizationDeltaVarianceEnvelope
- CorruptPageRecoveryLatencyVarianceEnvelope

### CDC (Change Data Capture)

- CDCAdaptiveHeuristicsDecisionLatencyVarianceEnvelope
- CDCApplyBatchLatencyVarianceEnvelope
- CDCWatermarkAdvanceVarianceEnvelope

### Schema / Constraints

- ConstraintPerfVarianceEnvelope
- UniquePerfVarianceEnvelope

### Security / Encryption

- EncryptionKeyDeriveVarianceEnvelope
- TDERotationVarianceEnvelope

### Multi-Tenancy / Distributed

- TenantRegistryVarianceEnvelope
- AppendEntriesVarianceEnvelope
- CommitAdvancementVarianceEnvelope

### Graph Algorithms / Centrality & Analytics

- GraphBuilderThroughputVarianceEnvelope
- BetweennessVarianceEnvelope
- ClosenessVarianceEnvelope
- EigenvectorVarianceEnvelope
- GreyCardinalCompositeMetricBreakdownVarianceEnvelope
- GreyCardinalVarianceEnvelope
- PageRankVarianceEnvelope

### Optimizer Extensions / Misc

- PlanEnumerationEngineVarianceEnvelope (alias of PlanEnumerationVarianceEnvelope if duplicated)

## 3. Threshold Exception Table

| Envelope                                     | CV Threshold | p95/mean Threshold | Rationale                                     |
| -------------------------------------------- | ------------ | ------------------ | --------------------------------------------- |
| AdvancedCostModelCalibrationVarianceEnvelope | 0.20         | 2.50               | Calibration determinism for optimizer factors |
| PlanCostModelCalibrationVarianceEnvelope     | 0.20         | 2.50               | Base calibration reproducibility              |

(Empty cells imply default global policy.)

## 4. Maintenance Rules

1. Every new `*VarianceEnvelope` MUST include CANARY line with UPDATED=today.
2. Tightening thresholds requires updating bench assertions + this registry.
3. If an envelope is deprecated, mark line with `(deprecated YYYY-MM-DD)` until removed from `status.csv`.
4. Registry generation script (future) may auto-prune removed envelopes.

## 5. Planned Improvements

- Automated delta summary (adds/removals) in PR comments.
- Badge for tightened envelopes count.
- Historical variance trend archiving (JSONL snapshots).
