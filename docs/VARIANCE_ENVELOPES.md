# Variance Envelopes Index (CANARY)

All active runtime variance guards (BENCHED aspects with \*\_VarianceEnvelope) with enforced statistical thresholds.

| #   | Aspect                                               | Requirement / Feature                      | CV Threshold              | p95/Mean Threshold      | Rationale                                                      |
| --- | ---------------------------------------------------- | ------------------------------------------ | ------------------------- | ----------------------- | -------------------------------------------------------------- |
| 1   | PageRankVarianceEnvelope                             | REQ-GQL-067 Centrality                     | <0.20                     | <2.4x                   | Iterative rank convergence variance acceptable; damping noise. |
| 2   | BetweennessVarianceEnvelope                          | REQ-GQL-067 Centrality                     | <0.22                     | <2.5x                   | High path enumeration variability; relaxed bound.              |
| 3   | ClosenessVarianceEnvelope                            | REQ-GQL-067 Centrality                     | <0.19                     | <2.35x                  | Multi-source shortest path cost accumulation.                  |
| 4   | EigenvectorVarianceEnvelope                          | REQ-GQL-067 Centrality                     | <0.19                     | <2.4x                   | Power iteration oscillation window.                            |
| 5   | GreyCardinalVarianceEnvelope                         | REQ-GQL-067 Centrality                     | <0.21                     | <2.5x                   | Composite metric aggregation overhead.                         |
| 6   | TxnConflictMatrixVarianceEnvelope                    | REQ-GQL-013 Transactions                   | <0.18                     | <2.3x                   | Conflict pattern sampling stable with fixed seed.              |
| 7   | SSIPhantomPreventionVarianceEnvelope                 | REQ-GQL-013 Transactions                   | <0.18                     | <2.3x                   | Phatom detection overhead bounded.                             |
| 8   | PropertyAccessHotPathVarianceEnvelope                | REQ-GQL-017 Property Access                | <0.15                     | <2.1x                   | Hot path must remain very stable.                              |
| 9   | PathExpandBreadthVarianceEnvelope                    | REQ-GQL-016 Paths                          | <0.20                     | <2.4x                   | Branching factor randomization introduces variability.         |
| 10  | CDCApplyBatchLatencyVarianceEnvelope                 | REQ-GQL-042 CDC                            | <0.21                     | <2.55x                  | Batch composition noise under adaptive flush.                  |
| 11  | WalAdaptivePolicyLatencyVarianceEnvelope             | REQ-GQL-028 WAL                            | <0.22                     | <2.6x                   | Adaptive threshold oscillation allowed.                        |
| 12  | MVCCRepairThroughputVarianceEnvelope                 | REQ-GQL-073 MVCC Advanced                  | <0.20                     | <2.4x                   | Repair heuristic branch variance.                              |
| 13  | GraphBuilderThroughputVarianceEnvelope               | REQ-GQL-060 Core Builders                  | <0.18                     | <2.3x                   | Builder concurrency scheduling jitter.                         |
| 14  | ConstraintPerfVarianceEnvelope                       | REQ-GQL-032 Schema Constraints Performance | <0.17                     | <2.25x                  | Deterministic evaluation after warm-up.                        |
| 15  | WalCompactionVarianceEnvelope                        | REQ-GQL-028 WAL                            | <0.19                     | <2.35x                  | Segment rewrite selection variability.                         |
| 16  | TenantRegistryVarianceEnvelope                       | REQ-GQL-050 Multi-Tenancy                  | <0.16                     | <2.2x                   | Hash map insert/get dominated cost stable.                     |
| 17  | GPUFlaggerEnumerationVarianceEnvelope                | REQ-GQL-051 GPU Acceleration               | <0.18                     | <2.3x                   | Unsupported fast path dominated by loop overhead.              |
| 18  | UniquePerfVarianceEnvelope                           | REQ-GQL-032 Schema Constraints Performance | <0.18                     | <2.3x                   | Uniqueness hashing & allocation moderate variability.          |
| 19  | WALFlushBatchVarianceEnvelope                        | REQ-GQL-028 WAL Flush Batch                | <0.20                     | <2.4x                   | Flush grouping jitter bounded by record size distribution.     |
| 20  | PlannerRewritePassVarianceEnvelope                   | REQ-GQL-021 Query Planner                  | <0.18                     | <2.3x                   | Rewrite pipeline deterministic rule application window.        |
| 21  | SetOpDistinctDedupVarianceEnvelope                   | REQ-GQL-015 Set Operations                 | <0.21                     | <2.45x                  | Hash set build variability under key collisions.               |
| 22  | TDERotationVarianceEnvelope                          | REQ-GQL-046 TDE Multi-Key                  | <0.22                     | <2.55x                  | Page re-encryption cost plus key slot scan jitter.             |
| 23  | PathExpansionHeuristicVarianceEnvelope               | REQ-GQL-016 Paths                          | <0.20                     | <2.4x                   | Heuristic pruning bounding frontier growth variability.        |
| 24  | WALIOThrottleVarianceEnvelope                        | REQ-GQL-028 WAL I/O Throttle               | <0.21                     | <2.45x                  | Feedback loop smooths bursty write rate; mild overshoot bound. |
| 25  | QueryPlanCacheEvictVarianceEnvelope                  | REQ-GQL-021 Query Planner                  | <0.19                     | <2.35x                  | Eviction sweep should remain predictable; hash recompute rare. |
| 26  | MVCCVersionPruneVarianceEnvelope                     | REQ-GQL-013 Transactions                   | <0.20                     | <2.4x                   | Obsolete version unlink and epoch advance jitter bounded.      |
| 27  | CDCWatermarkAdvanceVarianceEnvelope                  | REQ-GQL-042 CDC                            | <0.21                     | <2.5x                   | Global min timestamp scan variability under stream skew.       |
| 28  | EncryptionKeyDeriveVarianceEnvelope                  | REQ-GQL-046 TDE                            | <0.18                     | <2.3x                   | KDF iterations deterministic; cache/memory noise small.        |
| 29  | GreyCardinalCompositeMetricBreakdownVarianceEnvelope | REQ-GQL-067 Centrality                     | <0.17 (total), <0.16 comp | <2.3x total, <2.2x comp | Finer-grain stability across component metric passes.          |
| 30  | PlannerCardinalityEstimateVarianceEnvelope           | REQ-GQL-021 Query Planner                  | <0.18                     | <2.4x                   | Estimator heuristic stability; allows slightly looser tail.    |
| 31  | CDCAdaptiveHeuristicsDecisionLatencyVarianceEnvelope | REQ-GQL-042 CDC                            | <0.20                     | <2.5x                   | Adaptive decision path latency stabilization.                  |
| 32  | WALSegmentRecycleLatencyVarianceEnvelope             | REQ-GQL-028 WAL                            | <0.21                     | <2.55x                  | Periodic encryption + splice variability bounded.              |

Generated: 2025-09-21 (updated with rows 24-32)
