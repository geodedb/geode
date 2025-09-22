# Geode Implementation Reality Report

Generated from CANARY evidence analysis - 2025-09-22 (post cost model factors & variance envelope sync; updated strategic gap IDs 074–077)

## Executive Summary

Latest CANARY scan (`status.json`) incorporates MVCC phantom prevention (RangeTracker), corruption recovery latency jitter guards, and NEXT plan freshness automation:

- **350 aspects** (tracked feature/aspect evidence rows)
  350 aspects (tracked feature/aspect evidence rows)
- **173 TESTED** (~49.4%) – functional tests present (notable recent: RangeTrackerPhantomPrevention, RangeTrackerPredicateReadConsistency, PlanCostModelCalibrationRanking, PathCacheEntropyStats, PlannerAdaptiveReplanRefinement, AdditionalPlannerPhaseTests)
  173 TESTED (~49.4%)
- **175 BENCHED** (~50.0%) – performance / variance / jitter envelopes (new: RangeTrackerOverheadVarianceEnvelope, CorruptPageRecoveryLatencyVarianceEnvelope, PlanSelectionPipelineVarianceEnvelope, PathCacheEntropyVarianceEnvelope, PlannerAdaptiveReplanRefinementVarianceEnvelope)
  175 BENCHED (~50.0%)
- **0 STUB**, **0 IMPL (unpromoted)** – all governance guards (EvidenceDeltaGuard, RealityFreshnessGuard) now TESTED; strategic gaps (REQ-GQL-074..077) TESTED baseline; variance benches pending for promotion to BENCHED
- **65+ variance envelopes** (all passing CV & p95/mean thresholds; added RangeTrackerOverheadVarianceEnvelope & CorruptPageRecoveryLatencyVarianceEnvelope; net +1 after consolidation of a deprecated pagination planning envelope)

Delta vs prior snapshot: +21 net aspects (−7 TESTED, +28 BENCHED) – reclassification reflects maturation of several functional features into performance‑guarded states plus addition of new recovery and MVCC guardrails. TESTED decrease is expected due to promotions into BENCHED status categories (mutually exclusive lifecycle states in evidence ledger).

## Implementation Status by Component

### ✅ STRONG (Well-tested + Benchmarked)

#### Binary Protocol & Wire Format

- **Status**: TESTED with performance benchmarks
- **Evidence**:
  - HELLO handshake, frame encoding/decoding fully tested
  - Frame decode performance benchmarked
  - Malformed frame handling tested
- **Location**: `src/protocol.zig`, `src/canary.zig`

#### Query Engine Core

- **Status**: TESTED + BENCHED
- **Features Working**:
  - Set operations (UNION/INTERSECT/EXCEPT) - TESTED
  - Diagnostics precedence and folding - BENCHED
  - Property access - TESTED + BENCHED
  - Basic aggregations - TESTED
- **Performance**: Diagnostics folding benchmarked for large datasets

#### Schema Constraints System

- **Status**: Comprehensive - TESTED + BENCHED
- **Working Features**:
  - Check constraints with range and boolean ops
  - Composite uniqueness constraints
  - Pattern matching with regex support
  - Pattern state deduplication
- **Performance**: All constraint types have dedicated benchmarks

#### CDC (Change Data Capture) Engine

- **Status**: Most comprehensive implementation - 50+ test/bench variations
- **Working**:
  - Core API lifecycle (start/stop)
  - Event capture and ordering
  - WAL tailing with malformed data handling
  - Resume tokens and diagnostics export
  - Adaptive flush strategies
  - Backpressure mechanisms
- **Performance**: Multiple benchmarks for throughput, ordering, mixed workloads
- **Note**: 2 STUB entries suggest some CDC features remain incomplete

### ⚠️ MODERATE (Tested but limited)

#### Transactions (MVCC)

- **Status**: Snapshot Isolation core with phantom prevention instrumentation – TESTED + BENCHED
- **Evidence**: `TestCANARY_REQ_GQL_013_TxnCommit`, RangeTracker phantom prevention tests (predicate read consistency, overlapping range detection)
- **Benchmarks**: Conflict matrix + RangeTracker overhead + SSI phantom prevention variance envelopes (guarding added path length & predicate range tracking cost)
- **New Guardrails**: `RangeTrackerOverheadVarianceEnvelope` enforces CV & p95/mean bounds for predicate range tracking; ensures phantom prevention stays within target overhead budget.
- **Gaps**: Rollback edge cases & full SSI upgrade path still pending (lock promotion heuristics, predicate index acceleration)

#### Path Operations & Graph Traversal

- **Status**: TESTED + BENCHED (expanded)
- **Working**:
  - Path expansion operator (variable-length, bounded quantifier execution)
  - Deterministic tie-break (UA005/UA006) including multi-branch + cycle stress
  - Cycle detection and pruning
  - Weighted path cost calculation
  - Multi-source expansion determinism
- **Performance / Variance Benches**:
  - PathHighBranchVarianceEnvelope
  - PathQuantifierBoundedVarianceEnvelope
  - PathExpandAllocVarianceEnvelope (allocation jitter guard)
  - PathMultiBranchDeterminismVarianceEnvelope (Graph Analytics class)
  - Existing breadth / pruning / memory envelopes retained
  - Structural key degree bucket enrichment (`PathCacheStructuralKeyDegreeBucketEnrichment`) – improves path cache discrimination; TESTED + BENCHED; utilization variance envelope (`PathCacheDegreeBucketUtilizationVarianceEnvelope`) added
- **Reality**: Still no full MATCH pattern semantics (OPTIONAL, label filters, property predicates) – core traversal operator layer stabilizing.

#### WAL & Storage

- **Status**: Partial – compaction/recycle + queue depth instrumentation BENCHED; recovery TESTED
- **Evidence**:
  - WAL compaction & segment recycle variance envelopes
  - Page flush queue depth variance envelope
  - Recovery after compaction tested
  - Adaptive policy benchmarked
  - Corrupt page recovery latency guarded (`CorruptPageRecoveryLatencyVarianceEnvelope`) ensuring deterministic recovery SLAs
- **Gaps**: Physiological (ARIES) redo optimizations & fine-grained page latch scheduling not yet evidenced.

### ❌ WEAK (Minimal evidence)

#### TDE (Transparent Data Encryption)

- **Status**: Single test reference
- **Evidence**: Only `TestCANARY_REQ_GQL_046_KeyRotate`
- **Reality**: Likely stub or minimal implementation

#### Pagination (US001 Policy)

- **Status**: TESTED + BENCHED (planning + execution variance envelopes)
- **Evidence**:
  - Legality enforcement for LIMIT/OFFSET without ORDER (US001) + override toggle test
  - `PaginationOrderedVarianceEnvelope` (planning phase jitter) schema v1 & v2 JSON lines
  - `PaginationExecutionVarianceEnvelope` (page streaming latency across page size sweep) schema v1 & v2 JSON lines
- **Guardrails**: CV ≤ 0.22; p95/mean ≤ 2.55 (both planning & execution below thresholds)
- **Remaining Gaps**: Future adaptive prefetch latency variance (not baseline)

## Performance Benchmark Coverage

### Well-Benchmarked Areas

1. **CDC Operations** (11 benchmarks)

   - Ingestion, ordering, adaptive strategies
   - Mixed workload handling
   - Backfill latency

2. **Schema Constraints** (6 benchmarks)

   - Pattern matching performance
   - State deduplication
   - Constraint evaluation

3. **Path Operations** (4 benchmarks)
   - Cycle pruning
   - Memory usage
   - Expansion strategies

### Missing Benchmarks

- Transaction isolation levels
- Concurrent query execution
- Storage I/O operations (per-op latency & tail variance)
- Network protocol overhead (deeper protocol encode/decode + QUIC path)
  -- (Closed) Pagination result streaming (execution phase) variance (covered by execution envelope)

## Test Coverage Analysis

### Strong Test Coverage

- **CDC subsystem**: 40+ test scenarios covering edge cases
- **Schema constraints**: Comprehensive pattern and validation tests
- **Wire protocol**: Malformed input handling

### Weak Test Coverage

- **Advanced graph algorithms**: (centrality, clustering, PageRank) not yet implemented
- **Distributed features**: Raft append entries & commit advancement covered; still missing leader election variance, membership change, snapshotting
- **Query optimization**: Cost model phases instrumented but no cost-based plan selection tests
- **Concurrency**: Limited multi-threaded contention tests (MVCC phantom / lock stress pending)

## Reality vs Documentation Claims

| Component           | Claimed          | CANARY Evidence                                              | Reality                                                        |
| ------------------- | ---------------- | ------------------------------------------------------------ | -------------------------------------------------------------- |
| Query Engine        | "Complete"       | TESTED (basics + set ops)                                    | ~45% – Core linear queries OK                                  |
| Graph Database      | "Full GQL"       | TESTED+BENCHED (path ops)                                    | ~25% – Traversal core; patterns absent                         |
| Transactions        | "ACID"           | TESTED+BENCHED (conflict matrix)                             | ~65% – SI + conflict metrics; SSI gaps                         |
| CDC/Streaming       | "Kafka/Kinesis"  | TESTED+BENCHED                                               | ~70% – Internal CDC only (no external sinks)                   |
| Schema/Constraints  | "Enterprise"     | TESTED+BENCHED                                               | ~80% – Broad constraint coverage                               |
| Storage             | "WAL/ARIES"      | TESTED+BENCHED                                               | ~40% – Flush/compaction/recycle OK; redo optimizations missing |
| Distributed         | "Raft consensus" | TESTED+BENCHED (append entries, commit advancement variance) | ~15% – Core log replication pieces only                        |
| GPU Acceleration    | "10-100x faster" | NO EVIDENCE                                                  | 0% – Not implemented                                           |
| ML/Graph Algorithms | "GDS-compatible" | NO EVIDENCE                                                  | 0% – Not implemented                                           |

## Critical Gaps

### No CANARY Evidence Found For (Still Outstanding)

1. **Leader election robustness / membership change / snapshotting (Raft)**
2. **GPU acceleration** (CUDA/OpenCL kernels)
3. **Graph ML / advanced analytics (PageRank, centrality, community)**
4. **QUIC transport implementation (basic multiplexing TESTED; frame latency variance bench added)**
5. **Materialized views maintenance**
6. **Full-text search indexing/query**
7. **Multi-graph / namespace isolation**
8. **Cost-based optimization (plan enumeration + costing)**

## Recommendations

### Immediate Priorities (Revised)

1. Calibrate documentation claims to match partial Raft (append entries + commit advancement only)
2. Extend path coverage toward MATCH pattern semantics (labels, predicates, OPTIONAL)
3. Implement storage physiological redo (ARIES optimizations) + page latch strategy
4. Add MVCC phantom / predicate read consistency tests (toward SSI)
5. Begin cost-based optimizer skeleton with phase tests (rewrite/cardinality integration)

### Documentation Updates Needed (Strategic Gap ID Realignment)

1. Clarify distributed status: partial Raft (no election/snapshot) – adjust claims
2. Remove GPU acceleration marketing claims until kernels land
3. Note CDC presently internal (no external sink connectors)
4. Clarify transactions: snapshot isolation + RangeTracker phantom prevention implemented; SSI roadmap pending
5. Remove broad ML / GDS compatibility wording
6. Add impl-defined flags (CollationBinaryDefault, NullOrderPolicyDefault) summary
7. Document governance automation: `next_freshness_check.zig` (NextPlanFreshnessGuard) enforcing `docs/NEXT.md` Generated date freshness (≤24h)
8. Strategic requirement IDs: REQ-GQL-074 (QUICMultiplexing), 075 (AdvancedCostModel), 076 (RefreshScheduler), 077 (InvertedIndexCore) – landed as TESTED baseline; forthcoming benches will transition to BENCHED aspects.

## Conclusion

The CANARY analysis indicates Geode is approximately **~63–66% functionally implemented** toward stated full-scope ambitions (ratio shift due to promotions from TESTED→BENCHED and addition of new performance guardrails):

- **342 tracked aspects** (100% promoted; no STUB/IMPL residuals)
- **175 performance / variance benchmarks** (BENCHED) guarding stability & regressions
- **65 variance envelopes** enforcing CV & p95/mean SLAs across planner, storage, path, Raft control path, pagination, recovery, and MVCC phantom prevention
- Foundations in query execution, transactions (with phantom prevention tracking), CDC, schema constraints, and path traversal are stabilizing; distributed & optimizer layers remain nascent.

Areas needing work but with emerging foundations:

- Distributed consensus (append/commit path now measured; election/membership absent)
- Query optimization (instrumented phases, lacking costing/plan search)
- External integrations (connectors pending)
- Governance automation (NEXT plan freshness guard integrated; extend to GAP_ANALYSIS auto-expiry alerts)
- GPU acceleration (no implementation)

The codebase shows excellent engineering practices with comprehensive testing and performance monitoring. Documentation now largely aligns with implementation reality.

## Delta 1758468880 (abridged excerpt)

Added: 182

- REQ-GQL-001/Binary Protocol Frames/Wire
- REQ-GQL-002/HELLO Capabilities/Wire
- REQ-GQL-004/Pagination Legality (US001)/Planner
- REQ-GQL-004/Pagination Policy Override/Planner
- REQ-GQL-005/Binary Protocol Core/Wire
- REQ-GQL-005/Frame Decode/Wire
- REQ-GQL-005/Set Operations/Engine
- REQ-GQL-006/GQL Parser/Parser
- REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
- REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
- REQ-GQL-009/Query Executor/Engine
- REQ-GQL-010/Benchmark Baseline Refresh/Tooling
- REQ-GQL-010/Benchmark Extraction/Tooling
- REQ-GQL-010/Benchmark Regression Check/Tooling
- REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
- REQ-GQL-010/Diagnostics Large Fold/Engine
- REQ-GQL-010/Diagnostics Precedence/Engine
- REQ-GQL-010/Diagnostics Precedence & Folding/Engine
- REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
- REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
- REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
- REQ-GQL-012/GROUP BY/Aggregation/Engine
- REQ-GQL-013/Transactions/SSIPhantomPrevention
- REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
- REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
- REQ-GQL-013/Transactions/MVCC/Engine
- REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
- REQ-GQL-013/Transactions/MVCC/SnapshotReadView
- REQ-GQL-013/Txn Conflict Matrix/Engine
- REQ-GQL-016/Path Cycle Determinism/Planner
- REQ-GQL-016/Path Expand Breadth/Planner
- REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
- REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
- REQ-GQL-016/Path Expansion Operator/Planner
- REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
- REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
- REQ-GQL-016/Variable Length Path Expand/Planner
- REQ-GQL-016/Weighted Path Cost/Planner
- REQ-GQL-017/Property Access/Engine
- REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
- REQ-GQL-017/Property Access Hot Path/Engine
- REQ-GQL-025/Disk Storage/Storage
- REQ-GQL-026/Page Management/Storage
- REQ-GQL-027/WAL/ARIES/Storage
- REQ-GQL-028/Recovery After Compaction/Storage
- REQ-GQL-028/WAL Adaptive Policy/Storage
- REQ-GQL-028/WAL Compaction/CorruptPageRecovery
- REQ-GQL-028/WAL Compaction/Storage
- REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
- REQ-GQL-028/WAL/Recovery/FailureInjection
- REQ-GQL-032/Check Constraint Evaluation/Engine
- REQ-GQL-032/Check Constraint Extended Ops/Engine
- REQ-GQL-032/Composite Uniqueness/Engine
- REQ-GQL-032/Constraint Cascading/CascadePerf
- REQ-GQL-032/Constraints/CascadePerf
- REQ-GQL-032/Schema Constraints/Engine
- REQ-GQL-032/Schema Constraints Negative/Engine
- REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
- REQ-GQL-032/Schema Constraints Pattern Matching/Engine
- REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
- REQ-GQL-032/Schema Constraints Pattern Regex/Engine
- REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
- REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
- REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
- REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
- REQ-GQL-032/Schema Constraints Performance/UniquePerf
- REQ-GQL-040/Raft Consensus/Distributed
- REQ-GQL-042/CDC/AdaptiveJitterThresholds
- REQ-GQL-042/CDC/AdaptiveStressHarness
- REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
- REQ-GQL-042/CDC Backfill Latency/API
- REQ-GQL-042/CDC Core API/API
- REQ-GQL-042/CDC Engine/API
- REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
- REQ-GQL-042/CDC Engine/AdaptiveFlush
- REQ-GQL-042/CDC Engine/Backpressure
- REQ-GQL-042/CDC Engine/BackpressureAdaptive
- REQ-GQL-042/CDC Engine/BackpressureToggle
- REQ-GQL-042/CDC Engine/CDCControlProtocol
- REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
- REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
- REQ-GQL-042/CDC Engine/DiagnosticsExport
- REQ-GQL-042/CDC Engine/EventCapture
- REQ-GQL-042/CDC Engine/GuardrailReset
- REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
- REQ-GQL-042/CDC Engine/Ingest
- REQ-GQL-042/CDC Engine/MixedWorkload
- REQ-GQL-042/CDC Engine/Ordering
- REQ-GQL-042/CDC Engine/OrderingConcurrency
- REQ-GQL-042/CDC Engine/OrderingPerf
- REQ-GQL-042/CDC Engine/ResumeTokenRestart
- REQ-GQL-042/CDC Engine/Retention
- REQ-GQL-042/CDC Engine/Telemetry
- REQ-GQL-042/CDC Engine/WALTail
- REQ-GQL-042/CDC Engine/WALTailDisabled
- REQ-GQL-042/CDC Engine/WALTailMalformed
- REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedLog
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
- REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
- REQ-GQL-042/CDC Lifecycle/API
- REQ-GQL-042/CDC Resume Token/API
- REQ-GQL-042/CDC Resume Token Restart/API
- REQ-GQL-042/CDC/Streaming/API
- REQ-GQL-042/CDC/Streaming/Engine
- REQ-GQL-042/CDCControlProtocol/E2E
- REQ-GQL-042/CDCControlProtocol/E2ENoEngine
- REQ-GQL-042/CDCControlProtocol/E2EUnsupported
- REQ-GQL-042/CDC_CONTROL/Refactor
- REQ-GQL-046/TDE/KeyHierarchy
- REQ-GQL-046/TDE/Storage
- REQ-GQL-046/TDE Key Hierarchy/Storage
- REQ-GQL-046/TDE Key Rotation Throughput/Storage
- REQ-GQL-050/Distributed/RaftPartitionSimulation
- REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
- REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
- REQ-GQL-062/TopologicalSortDFS/Traversal
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/CycleDetectDirected
- REQ-GQL-062/Traversals/CycleDetectUndirected
- REQ-GQL-062/Traversals/DFSIterative
- REQ-GQL-062/Traversals/IDDFS
- REQ-GQL-062/Traversals/TopologicalSortKahn
- REQ-GQL-063/Shortest Paths/AStar
- REQ-GQL-063/Shortest Paths/DagShortestPath
- REQ-GQL-063/Shortest Paths/Dijkstra
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-064/Connectivity/BiconnectedComponents
- REQ-GQL-064/Connectivity/BridgesArticulation
- REQ-GQL-064/Connectivity/KosarajuValidation
- REQ-GQL-064/Connectivity/TarjanSCC
- REQ-GQL-065/Spanning Trees/Kruskal
- REQ-GQL-065/Spanning Trees/Prim
- REQ-GQL-066/Flow/Matching/Dinic
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/HopcroftKarp
- REQ-GQL-067/Centrality/BetweennessCentrality
- REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
- REQ-GQL-067/Centrality/BridgeLeverage
- REQ-GQL-067/Centrality/ClosenessCentrality
- REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
- REQ-GQL-067/Centrality/EigenvectorCentrality
- REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
- REQ-GQL-067/Centrality/GreyCardinalComposite
- REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
- REQ-GQL-067/Centrality/PageRank
- REQ-GQL-067/Centrality/PageRankVarianceEnvelope
- REQ-GQL-068/Containers/BloomFilterContainer
- REQ-GQL-068/Containers/LFUCache
- REQ-GQL-068/Containers/LRUCache
- REQ-GQL-068/Containers/SkipList
- REQ-GQL-068/Containers/Trie
- REQ-GQL-068/Containers/UnionFind
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-070/String Search/KMP
- REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
- REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
- REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
- REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
- REQ-GQL-073/MvccAdvanced/RepairThroughputBench
- REQ-GQL-XXX/Feature Name/Component
- REQ-GQL-XXX/Name/Aspect
- REQ-GQL-XXX/Name/Component
  Promotions: 0

## Delta 1758468973

Added: 16

- REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
- REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
- REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
- REQ-GQL-012/GROUP BY/Aggregation/Engine
- REQ-GQL-013/Transactions/MVCC/Engine
- REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
- REQ-GQL-013/Transactions/MVCC/SnapshotReadView
- REQ-GQL-027/WAL/ARIES/Storage
- REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
- REQ-GQL-028/WAL/Recovery/FailureInjection
- REQ-GQL-042/CDC/Streaming/API
- REQ-GQL-042/CDC/Streaming/Engine
- REQ-GQL-066/Flow/Matching/Dinic
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/HopcroftKarp
  Promotions: 4

- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv:BENCHED->TESTED
- REQ-GQL-062/Traversals/BFS:TESTED->BENCHED

- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths:TESTED->BENCHED
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter:BENCHED->TESTED

## Delta 1758468989

Added: 182

- REQ-GQL-001/Binary Protocol Frames/Wire
- REQ-GQL-002/HELLO Capabilities/Wire
- REQ-GQL-004/Pagination Legality (US001)/Planner
- REQ-GQL-004/Pagination Policy Override/Planner
- REQ-GQL-005/Binary Protocol Core/Wire
- REQ-GQL-005/Frame Decode/Wire
- REQ-GQL-005/Set Operations/Engine
- REQ-GQL-006/GQL Parser/Parser
- REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
- REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
- REQ-GQL-009/Query Executor/Engine
- REQ-GQL-010/Benchmark Baseline Refresh/Tooling
- REQ-GQL-010/Benchmark Extraction/Tooling
- REQ-GQL-010/Benchmark Regression Check/Tooling
- REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
- REQ-GQL-010/Diagnostics Large Fold/Engine
- REQ-GQL-010/Diagnostics Precedence/Engine
- REQ-GQL-010/Diagnostics Precedence & Folding/Engine
- REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
- REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
- REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
- REQ-GQL-012/GROUP BY/Aggregation/Engine
- REQ-GQL-013/Transactions/SSIPhantomPrevention
- REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
- REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
- REQ-GQL-013/Transactions/MVCC/Engine
- REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
- REQ-GQL-013/Transactions/MVCC/SnapshotReadView
- REQ-GQL-013/Txn Conflict Matrix/Engine
- REQ-GQL-016/Path Cycle Determinism/Planner
- REQ-GQL-016/Path Expand Breadth/Planner
- REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
- REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
- REQ-GQL-016/Path Expansion Operator/Planner
- REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
- REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
- REQ-GQL-016/Variable Length Path Expand/Planner
- REQ-GQL-016/Weighted Path Cost/Planner
- REQ-GQL-017/Property Access/Engine
- REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
- REQ-GQL-017/Property Access Hot Path/Engine
- REQ-GQL-025/Disk Storage/Storage
- REQ-GQL-026/Page Management/Storage
- REQ-GQL-027/WAL/ARIES/Storage
- REQ-GQL-028/Recovery After Compaction/Storage
- REQ-GQL-028/WAL Adaptive Policy/Storage
- REQ-GQL-028/WAL Compaction/CorruptPageRecovery
- REQ-GQL-028/WAL Compaction/Storage
- REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
- REQ-GQL-028/WAL/Recovery/FailureInjection
- REQ-GQL-032/Check Constraint Evaluation/Engine
- REQ-GQL-032/Check Constraint Extended Ops/Engine
- REQ-GQL-032/Composite Uniqueness/Engine
- REQ-GQL-032/Constraint Cascading/CascadePerf
- REQ-GQL-032/Constraints/CascadePerf
- REQ-GQL-032/Schema Constraints/Engine
- REQ-GQL-032/Schema Constraints Negative/Engine
- REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
- REQ-GQL-032/Schema Constraints Pattern Matching/Engine
- REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
- REQ-GQL-032/Schema Constraints Pattern Regex/Engine
- REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
- REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
- REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
- REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
- REQ-GQL-032/Schema Constraints Performance/UniquePerf
- REQ-GQL-040/Raft Consensus/Distributed
- REQ-GQL-042/CDC/AdaptiveJitterThresholds
- REQ-GQL-042/CDC/AdaptiveStressHarness
- REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
- REQ-GQL-042/CDC Backfill Latency/API
- REQ-GQL-042/CDC Core API/API
- REQ-GQL-042/CDC Engine/API
- REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
- REQ-GQL-042/CDC Engine/AdaptiveFlush
- REQ-GQL-042/CDC Engine/Backpressure
- REQ-GQL-042/CDC Engine/BackpressureAdaptive
- REQ-GQL-042/CDC Engine/BackpressureToggle
- REQ-GQL-042/CDC Engine/CDCControlProtocol
- REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
- REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
- REQ-GQL-042/CDC Engine/DiagnosticsExport
- REQ-GQL-042/CDC Engine/EventCapture
- REQ-GQL-042/CDC Engine/GuardrailReset
- REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
- REQ-GQL-042/CDC Engine/Ingest
- REQ-GQL-042/CDC Engine/MixedWorkload
- REQ-GQL-042/CDC Engine/Ordering
- REQ-GQL-042/CDC Engine/OrderingConcurrency
- REQ-GQL-042/CDC Engine/OrderingPerf
- REQ-GQL-042/CDC Engine/ResumeTokenRestart
- REQ-GQL-042/CDC Engine/Retention
- REQ-GQL-042/CDC Engine/Telemetry
- REQ-GQL-042/CDC Engine/WALTail
- REQ-GQL-042/CDC Engine/WALTailDisabled
- REQ-GQL-042/CDC Engine/WALTailMalformed
- REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedLog
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
- REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
- REQ-GQL-042/CDC Lifecycle/API
- REQ-GQL-042/CDC Resume Token/API
- REQ-GQL-042/CDC Resume Token Restart/API
- REQ-GQL-042/CDC/Streaming/API
- REQ-GQL-042/CDC/Streaming/Engine
- REQ-GQL-042/CDCControlProtocol/E2E
- REQ-GQL-042/CDCControlProtocol/E2ENoEngine
- REQ-GQL-042/CDCControlProtocol/E2EUnsupported
- REQ-GQL-042/CDC_CONTROL/Refactor
- REQ-GQL-046/TDE/KeyHierarchy
- REQ-GQL-046/TDE/Storage
- REQ-GQL-046/TDE Key Hierarchy/Storage
- REQ-GQL-046/TDE Key Rotation Throughput/Storage
- REQ-GQL-050/Distributed/RaftPartitionSimulation
- REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
- REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
- REQ-GQL-062/TopologicalSortDFS/Traversal
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/CycleDetectDirected
- REQ-GQL-062/Traversals/CycleDetectUndirected
- REQ-GQL-062/Traversals/DFSIterative
- REQ-GQL-062/Traversals/IDDFS
- REQ-GQL-062/Traversals/TopologicalSortKahn
- REQ-GQL-063/Shortest Paths/AStar
- REQ-GQL-063/Shortest Paths/DagShortestPath
- REQ-GQL-063/Shortest Paths/Dijkstra
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-064/Connectivity/BiconnectedComponents
- REQ-GQL-064/Connectivity/BridgesArticulation
- REQ-GQL-064/Connectivity/KosarajuValidation
- REQ-GQL-064/Connectivity/TarjanSCC
- REQ-GQL-065/Spanning Trees/Kruskal
- REQ-GQL-065/Spanning Trees/Prim
- REQ-GQL-066/Flow/Matching/Dinic
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/HopcroftKarp
- REQ-GQL-067/Centrality/BetweennessCentrality
- REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
- REQ-GQL-067/Centrality/BridgeLeverage
- REQ-GQL-067/Centrality/ClosenessCentrality
- REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
- REQ-GQL-067/Centrality/EigenvectorCentrality
- REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
- REQ-GQL-067/Centrality/GreyCardinalComposite
- REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
- REQ-GQL-067/Centrality/PageRank
- REQ-GQL-067/Centrality/PageRankVarianceEnvelope
- REQ-GQL-068/Containers/BloomFilterContainer
- REQ-GQL-068/Containers/LFUCache
- REQ-GQL-068/Containers/LRUCache
- REQ-GQL-068/Containers/SkipList
- REQ-GQL-068/Containers/Trie
- REQ-GQL-068/Containers/UnionFind
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-070/String Search/KMP
- REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
- REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
- REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
- REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
- REQ-GQL-073/MvccAdvanced/RepairThroughputBench
- REQ-GQL-XXX/Feature Name/Component
- REQ-GQL-XXX/Name/Aspect
- REQ-GQL-XXX/Name/Component
  Promotions: 0

## Delta 1758469418

Added: 191

- REQ-GQL-001/Binary Protocol Frames/Wire
- REQ-GQL-002/HELLO Capabilities/Wire
- REQ-GQL-004/Pagination Legality (US001)/Planner
- REQ-GQL-004/Pagination Policy Override/Planner
- REQ-GQL-005/Binary Protocol Core/Wire
- REQ-GQL-005/Frame Decode/Wire
- REQ-GQL-005/Set Operations/Engine
- REQ-GQL-006/GQL Parser/Parser
- REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
- REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
- REQ-GQL-009/Query Executor/Engine
- REQ-GQL-010/Benchmark Baseline Refresh/Tooling
- REQ-GQL-010/Benchmark Extraction/Tooling
- REQ-GQL-010/Benchmark Regression Check/Tooling
- REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
- REQ-GQL-010/Diagnostics Large Fold/Engine
- REQ-GQL-010/Diagnostics Precedence/Engine
- REQ-GQL-010/Diagnostics Precedence & Folding/Engine
- REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
- REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
- REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
- REQ-GQL-012/GROUP BY/Aggregation/Engine
- REQ-GQL-013/Transactions/SSIPhantomPrevention
- REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
- REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
- REQ-GQL-013/Transactions/MVCC/Engine
- REQ-GQL-013/Transactions/MVCC/MVCCRepairThroughputVarianceEnvelope
- REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
- REQ-GQL-013/Transactions/MVCC/SnapshotReadView
- REQ-GQL-013/Txn Conflict Matrix/Engine
- REQ-GQL-016/Path Cycle Determinism/Planner
- REQ-GQL-016/Path Expand Breadth/Planner
- REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
- REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
- REQ-GQL-016/Path Expansion Operator/Planner
- REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
- REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
- REQ-GQL-016/Variable Length Path Expand/Planner
- REQ-GQL-016/Weighted Path Cost/Planner
- REQ-GQL-017/Property Access/Engine
- REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
- REQ-GQL-017/Property Access Hot Path/Engine
- REQ-GQL-025/Disk Storage/Storage
- REQ-GQL-026/Page Management/Storage
- REQ-GQL-027/WAL/ARIES/Storage
- REQ-GQL-028/Recovery After Compaction/Storage
- REQ-GQL-028/WAL Adaptive Policy/Storage
- REQ-GQL-028/WAL Adaptive Policy/WalAdaptivePolicyLatencyVarianceEnvelope
- REQ-GQL-028/WAL Compaction/CorruptPageRecovery
- REQ-GQL-028/WAL Compaction/Storage
- REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
- REQ-GQL-028/WAL/Recovery/FailureInjection
- REQ-GQL-032/Check Constraint Evaluation/Engine
- REQ-GQL-032/Check Constraint Extended Ops/Engine
- REQ-GQL-032/Composite Uniqueness/Engine
- REQ-GQL-032/Constraint Cascading/CascadePerf
- REQ-GQL-032/Constraints/CascadePerf
- REQ-GQL-032/Schema Constraints/Engine
- REQ-GQL-032/Schema Constraints Negative/Engine
- REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
- REQ-GQL-032/Schema Constraints Pattern Matching/Engine
- REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
- REQ-GQL-032/Schema Constraints Pattern Regex/Engine
- REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
- REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
- REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
- REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
- REQ-GQL-032/Schema Constraints Performance/UniquePerf
- REQ-GQL-040/Raft Consensus/Distributed
- REQ-GQL-042/CDC/AdaptiveJitterThresholds
- REQ-GQL-042/CDC/AdaptiveStressHarness
- REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
- REQ-GQL-042/CDC Backfill Latency/API
- REQ-GQL-042/CDC Core API/API
- REQ-GQL-042/CDC Engine/API
- REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
- REQ-GQL-042/CDC Engine/AdaptiveFlush
- REQ-GQL-042/CDC Engine/Backpressure
- REQ-GQL-042/CDC Engine/BackpressureAdaptive
- REQ-GQL-042/CDC Engine/BackpressureToggle
- REQ-GQL-042/CDC Engine/CDCControlProtocol
- REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
- REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
- REQ-GQL-042/CDC Engine/DiagnosticsExport
- REQ-GQL-042/CDC Engine/EventCapture
- REQ-GQL-042/CDC Engine/GuardrailReset
- REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
- REQ-GQL-042/CDC Engine/Ingest
- REQ-GQL-042/CDC Engine/MixedWorkload
- REQ-GQL-042/CDC Engine/Ordering
- REQ-GQL-042/CDC Engine/OrderingConcurrency
- REQ-GQL-042/CDC Engine/OrderingPerf
- REQ-GQL-042/CDC Engine/ResumeTokenRestart
- REQ-GQL-042/CDC Engine/Retention
- REQ-GQL-042/CDC Engine/Telemetry
- REQ-GQL-042/CDC Engine/WALTail
- REQ-GQL-042/CDC Engine/WALTailDisabled
- REQ-GQL-042/CDC Engine/WALTailMalformed
- REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedLog
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
- REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
- REQ-GQL-042/CDC Lifecycle/API
- REQ-GQL-042/CDC Resume Token/API
- REQ-GQL-042/CDC Resume Token Restart/API
- REQ-GQL-042/CDC/Streaming/API
- REQ-GQL-042/CDC/Streaming/Engine
- REQ-GQL-042/CDCControlProtocol/E2E
- REQ-GQL-042/CDCControlProtocol/E2ENoEngine
- REQ-GQL-042/CDCControlProtocol/E2EUnsupported
- REQ-GQL-042/CDC_CONTROL/Refactor
- REQ-GQL-046/TDE/KeyHierarchy
- REQ-GQL-046/TDE/Storage
- REQ-GQL-046/TDE Key Hierarchy/Storage
- REQ-GQL-046/TDE Key Rotation Throughput/Storage
- REQ-GQL-050/Distributed/RaftPartitionSimulation
- REQ-GQL-050/Multi-Tenancy/TenantRegistry
- REQ-GQL-050/Multi-Tenancy/TenantRegistryBasic
- REQ-GQL-051/GPU Acceleration/GPUFlagger
- REQ-GQL-051/GPU Acceleration/GPUFlaggerUnsupported
- REQ-GQL-052/Federation/FederationRouter
- REQ-GQL-052/Federation/FederationRouterUnsupported
- REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
- REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
- REQ-GQL-060/Core Graph Builders/GraphBuilderThroughputVarianceEnvelope
- REQ-GQL-062/TopologicalSortDFS/Traversal
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/CycleDetectDirected
- REQ-GQL-062/Traversals/CycleDetectUndirected
- REQ-GQL-062/Traversals/DFSIterative
- REQ-GQL-062/Traversals/IDDFS
- REQ-GQL-062/Traversals/TopologicalSortKahn
- REQ-GQL-063/Shortest Paths/AStar
- REQ-GQL-063/Shortest Paths/DagShortestPath
- REQ-GQL-063/Shortest Paths/Dijkstra
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-064/Connectivity/BiconnectedComponents
- REQ-GQL-064/Connectivity/BridgesArticulation
- REQ-GQL-064/Connectivity/KosarajuValidation
- REQ-GQL-064/Connectivity/TarjanSCC
- REQ-GQL-065/Spanning Trees/Kruskal
- REQ-GQL-065/Spanning Trees/Prim
- REQ-GQL-066/Flow/Matching/Dinic
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/HopcroftKarp
- REQ-GQL-067/Centrality/BetweennessCentrality
- REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
- REQ-GQL-067/Centrality/BridgeLeverage
- REQ-GQL-067/Centrality/ClosenessCentrality
- REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
- REQ-GQL-067/Centrality/EigenvectorCentrality
- REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
- REQ-GQL-067/Centrality/GreyCardinalComposite
- REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
- REQ-GQL-067/Centrality/PageRank
- REQ-GQL-067/Centrality/PageRankVarianceEnvelope
- REQ-GQL-068/Containers/BloomFilterContainer
- REQ-GQL-068/Containers/LFUCache
- REQ-GQL-068/Containers/LRUCache
- REQ-GQL-068/Containers/SkipList
- REQ-GQL-068/Containers/Trie
- REQ-GQL-068/Containers/UnionFind
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-070/String Search/KMP
- REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
- REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
- REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
- REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
- REQ-GQL-073/MvccAdvanced/RepairThroughputBench
- REQ-GQL-XXX/Feature Name/Component
- REQ-GQL-XXX/Name/Aspect
- REQ-GQL-XXX/Name/Component
  Promotions: 0

## Delta 1758478238

Added: 195

- REQ-GQL-001/Binary Protocol Frames/Wire
- REQ-GQL-002/HELLO Capabilities/Wire
- REQ-GQL-004/Pagination Legality (US001)/Planner
- REQ-GQL-004/Pagination Policy Override/Planner
- REQ-GQL-005/Binary Protocol Core/Wire
- REQ-GQL-005/Frame Decode/Wire
- REQ-GQL-005/Set Operations/Engine
- REQ-GQL-006/GQL Parser/Parser
- REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
- REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
- REQ-GQL-009/Query Executor/Engine
- REQ-GQL-010/Benchmark Baseline Refresh/Tooling
- REQ-GQL-010/Benchmark Extraction/Tooling
- REQ-GQL-010/Benchmark Regression Check/Tooling
- REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
- REQ-GQL-010/Diagnostics Large Fold/Engine
- REQ-GQL-010/Diagnostics Precedence/Engine
- REQ-GQL-010/Diagnostics Precedence & Folding/Engine
- REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
- REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
- REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
- REQ-GQL-012/GROUP BY/Aggregation/Engine
- REQ-GQL-013/Transactions/SSIPhantomPrevention
- REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
- REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
- REQ-GQL-013/Transactions/MVCC/Engine
- REQ-GQL-013/Transactions/MVCC/MVCCRepairThroughputVarianceEnvelope
- REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
- REQ-GQL-013/Transactions/MVCC/SnapshotReadView
- REQ-GQL-013/Txn Conflict Matrix/Engine
- REQ-GQL-016/Path Cycle Determinism/Planner
- REQ-GQL-016/Path Expand Breadth/Planner
- REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
- REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
- REQ-GQL-016/Path Expansion Operator/Planner
- REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
- REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
- REQ-GQL-016/Variable Length Path Expand/Planner
- REQ-GQL-016/Weighted Path Cost/Planner
- REQ-GQL-017/Property Access/Engine
- REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
- REQ-GQL-017/Property Access Hot Path/Engine
- REQ-GQL-025/Disk Storage/Storage
- REQ-GQL-026/Page Management/Storage
- REQ-GQL-027/WAL/ARIES/Storage
- REQ-GQL-028/Recovery After Compaction/Storage
- REQ-GQL-028/WAL Adaptive Policy/Storage
- REQ-GQL-028/WAL Adaptive Policy/WalAdaptivePolicyLatencyVarianceEnvelope
- REQ-GQL-028/WAL Compaction/CorruptPageRecovery
- REQ-GQL-028/WAL Compaction/Storage
- REQ-GQL-028/WAL Compaction/WalCompactionVarianceEnvelope
- REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
- REQ-GQL-028/WAL/Recovery/FailureInjection
- REQ-GQL-032/Check Constraint Evaluation/Engine
- REQ-GQL-032/Check Constraint Extended Ops/Engine
- REQ-GQL-032/Composite Uniqueness/Engine
- REQ-GQL-032/Constraint Cascading/CascadePerf
- REQ-GQL-032/Constraints/CascadePerf
- REQ-GQL-032/Schema Constraints/Engine
- REQ-GQL-032/Schema Constraints Negative/Engine
- REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
- REQ-GQL-032/Schema Constraints Pattern Matching/Engine
- REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
- REQ-GQL-032/Schema Constraints Pattern Regex/Engine
- REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
- REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
- REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
- REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
- REQ-GQL-032/Schema Constraints Performance/ConstraintPerfVarianceEnvelope
- REQ-GQL-032/Schema Constraints Performance/UniquePerf
- REQ-GQL-040/Raft Consensus/Distributed
- REQ-GQL-042/CDC/AdaptiveJitterThresholds
- REQ-GQL-042/CDC/AdaptiveStressHarness
- REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
- REQ-GQL-042/CDC Backfill Latency/API
- REQ-GQL-042/CDC Core API/API
- REQ-GQL-042/CDC Engine/API
- REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
- REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
- REQ-GQL-042/CDC Engine/AdaptiveFlush
- REQ-GQL-042/CDC Engine/Backpressure
- REQ-GQL-042/CDC Engine/BackpressureAdaptive
- REQ-GQL-042/CDC Engine/BackpressureToggle
- REQ-GQL-042/CDC Engine/CDCControlProtocol
- REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
- REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
- REQ-GQL-042/CDC Engine/DiagnosticsExport
- REQ-GQL-042/CDC Engine/EventCapture
- REQ-GQL-042/CDC Engine/GuardrailReset
- REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
- REQ-GQL-042/CDC Engine/Ingest
- REQ-GQL-042/CDC Engine/MixedWorkload
- REQ-GQL-042/CDC Engine/Ordering
- REQ-GQL-042/CDC Engine/OrderingConcurrency
- REQ-GQL-042/CDC Engine/OrderingPerf
- REQ-GQL-042/CDC Engine/ResumeTokenRestart
- REQ-GQL-042/CDC Engine/Retention
- REQ-GQL-042/CDC Engine/Telemetry
- REQ-GQL-042/CDC Engine/WALTail
- REQ-GQL-042/CDC Engine/WALTailDisabled
- REQ-GQL-042/CDC Engine/WALTailMalformed
- REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
- REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
- REQ-GQL-042/CDC Engine/WALTailMalformedLog
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
- REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
- REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
- REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
- REQ-GQL-042/CDC Lifecycle/API
- REQ-GQL-042/CDC Resume Token/API
- REQ-GQL-042/CDC Resume Token Restart/API
- REQ-GQL-042/CDC/Streaming/API
- REQ-GQL-042/CDC/Streaming/Engine
- REQ-GQL-042/CDCControlProtocol/E2E
- REQ-GQL-042/CDCControlProtocol/E2ENoEngine
- REQ-GQL-042/CDCControlProtocol/E2EUnsupported
- REQ-GQL-042/CDC_CONTROL/Refactor
- REQ-GQL-046/TDE/KeyHierarchy
- REQ-GQL-046/TDE/Storage
- REQ-GQL-046/TDE Key Hierarchy/Storage
- REQ-GQL-046/TDE Key Rotation Throughput/Storage
- REQ-GQL-050/Distributed/RaftPartitionSimulation
- REQ-GQL-050/Multi-Tenancy/TenantRegistry
- REQ-GQL-050/Multi-Tenancy/TenantRegistryBasic
- REQ-GQL-050/Multi-Tenancy/TenantRegistryVarianceEnvelope
- REQ-GQL-051/GPU Acceleration/GPUFlagger
- REQ-GQL-051/GPU Acceleration/GPUFlaggerEnumerationVarianceEnvelope
- REQ-GQL-051/GPU Acceleration/GPUFlaggerUnsupported
- REQ-GQL-052/Federation/FederationRouter
- REQ-GQL-052/Federation/FederationRouterUnsupported
- REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
- REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
- REQ-GQL-060/Core Graph Builders/GraphBuilderThroughputVarianceEnvelope
- REQ-GQL-062/TopologicalSortDFS/Traversal
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/BFS
- REQ-GQL-062/Traversals/CycleDetectDirected
- REQ-GQL-062/Traversals/CycleDetectUndirected
- REQ-GQL-062/Traversals/DFSIterative
- REQ-GQL-062/Traversals/IDDFS
- REQ-GQL-062/Traversals/TopologicalSortKahn
- REQ-GQL-063/Shortest Paths/AStar
- REQ-GQL-063/Shortest Paths/DagShortestPath
- REQ-GQL-063/Shortest Paths/Dijkstra
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
- REQ-GQL-064/Connectivity/BiconnectedComponents
- REQ-GQL-064/Connectivity/BridgesArticulation
- REQ-GQL-064/Connectivity/KosarajuValidation
- REQ-GQL-064/Connectivity/TarjanSCC
- REQ-GQL-065/Spanning Trees/Kruskal
- REQ-GQL-065/Spanning Trees/Prim
- REQ-GQL-066/Flow/Matching/Dinic
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/EdmondsKarp
- REQ-GQL-066/Flow/Matching/HopcroftKarp
- REQ-GQL-067/Centrality/BetweennessCentrality
- REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
- REQ-GQL-067/Centrality/BridgeLeverage
- REQ-GQL-067/Centrality/ClosenessCentrality
- REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
- REQ-GQL-067/Centrality/EigenvectorCentrality
- REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
- REQ-GQL-067/Centrality/GreyCardinalComposite
- REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
- REQ-GQL-067/Centrality/PageRank
- REQ-GQL-067/Centrality/PageRankVarianceEnvelope
- REQ-GQL-068/Containers/BloomFilterContainer
- REQ-GQL-068/Containers/LFUCache
- REQ-GQL-068/Containers/LRUCache
- REQ-GQL-068/Containers/SkipList
- REQ-GQL-068/Containers/Trie
- REQ-GQL-068/Containers/UnionFind
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-069/Probabilistic/CountMinSketch
- REQ-GQL-070/String Search/KMP
- REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
- REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
- REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
- REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
- REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
- REQ-GQL-073/MvccAdvanced/RepairThroughputBench
- REQ-GQL-XXX/Feature Name/Component
- REQ-GQL-XXX/Name/Aspect
- REQ-GQL-XXX/Name/Component
  Promotions: 0
