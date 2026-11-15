# Variance Envelope Registry — Geode

Generated catalog of all BENCHED variance / jitter / performance guard aspects (suffix `VarianceEnvelope`) extracted from `status.csv` (authoritative CANARY scan). Each envelope enforces CV ≤ 0.22 and p95/mean ≤ 2.55 unless a tighter/looser policy is explicitly listed.

> Source of truth: `status.csv` / `status.json`. This file is regenerated or updated when new BENCHED variance aspects land. Non-authoritative narrative only — discrepancies must be resolved by adjusting CANARY lines + benchmarks.

## 1. Summary

- Total variance envelopes (BENCHED): 70+ (see exact count in `status.csv`)
- Global policy: CV ≤ 0.22, p95/mean ≤ 2.55 (standard)
- Tightened envelopes (custom thresholds): none. (SONNY-6540 item 10: this
  listed `AdvancedCostModelCalibrationVarianceEnvelope` and
  `PlanCostModelCalibrationVarianceEnvelope` at CV ≤ 0.20, p95/mean ≤ 2.50.
  `PlanCostModelCalibrationVarianceEnvelope`, an inline test of
  `src/planner/cost_calibration.zig` run by `test-sonny6511-lib-inline`,
  checked CV > 0.22 only and only reported it unless
  `GEODE_PERF_GATES=enforce`; it timed `Calibration.compute` over the
  module's synthetic samples, and no query path called the module, which
  SONNY-6555 removed with it.
  `tests/benchmark_advanced_cost_model_calibration_variance.zig` uses the
  global 0.22 / 2.55 and no build step compiles it.)
- Future candidates for tightening: WAL flush batch, redo optimized latency.

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

- PathCacheDegreeBucketUtilizationVarianceEnvelope (structural key
  derivation, `src/planner/structural_key.zig`; the
  `bench_pathcache_degree_util` executable, run by `test-e2e`; no query
  path derives a structural key)
- PathCacheStructuralKeyCollisionVarianceEnvelope:
  `tests/benchmark_path_cache_structural_collision.zig` is present, but no
  build step compiles it

The entropy, hit/miss, lookup and planner-pipeline envelopes measured
`src/planner/path_cache.zig` and the synthetic `pipeline.runPipeline`, which
no build compiled; they were removed with that code (SONNY-6511).

### Query Planner (Cost Model & Enumeration)

- PlanCostModelCalibrationVarianceEnvelope (removed with
  `src/planner/cost_calibration.zig`, SONNY-6555)
- AdvancedCostModelCalibrationVarianceEnvelope (its CANARY row removed,
  SONNY-6555: the benchmark measures a local stand-in model and does not
  compile)
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

No envelope has a custom threshold (see Summary; the two calibration
envelopes listed here as 0.20 / 2.50 never had one).

## 4. Maintenance Rules

1. Every new `*VarianceEnvelope` MUST include CANARY line with UPDATED=today.
2. Tightening thresholds requires updating bench assertions + this registry.
3. If an envelope is deprecated, mark line with `(deprecated YYYY-MM-DD)` until removed from `status.csv`.
4. Registry generation script (future) may auto-prune removed envelopes.

## 5. Planned Improvements

- Automated delta summary (adds/removals) in PR comments.
- Badge for tightened envelopes count.
- Historical variance trend archiving (JSONL snapshots).
