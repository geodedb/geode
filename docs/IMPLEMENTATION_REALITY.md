# Geode Implementation Reality Report
*Generated from CANARY evidence analysis - 2025-09-20*

## Executive Summary

Based on comprehensive CANARY token analysis across the codebase:
- **94 features** tracked with evidence
- **63 TESTED** (67%) - have at least one test
- **29 BENCHED** (31%) - have performance benchmarks  
- **2 STUB** (2%) - placeholder implementations only

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
- **Status**: Basic implementation TESTED
- **Evidence**: `TestCANARY_REQ_GQL_013_TxnCommit`
- **Benchmarks**: Conflict matrix performance tested
- **Gaps**: Only basic commit tested, no rollback/isolation tests found

#### Path Operations & Graph Traversal
- **Status**: TESTED with performance focus
- **Working**:
  - Path expansion operator
  - Cycle detection and pruning
  - Variable-length path expansion
  - Weighted path cost calculation
- **Performance**: Memory usage and pruning benchmarked
- **Reality**: Basic graph ops work, but no evidence of complex pattern matching

#### WAL & Storage
- **Status**: Partial - compaction BENCHED, recovery TESTED
- **Evidence**:
  - WAL compaction thoroughly benchmarked
  - Recovery after compaction tested
  - Adaptive policy benchmarked
- **Gaps**: No evidence of full ARIES implementation or page management

### ❌ WEAK (Minimal evidence)

#### TDE (Transparent Data Encryption)
- **Status**: Single test reference
- **Evidence**: Only `TestCANARY_REQ_GQL_046_KeyRotate` 
- **Reality**: Likely stub or minimal implementation

#### Pagination (US001 Policy)
- **Status**: Policy tested, implementation unclear
- **Evidence**: Tests for rejecting unordered LIMIT/OFFSET
- **Gaps**: No evidence of actual pagination mechanism

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
- Storage I/O operations
- Network protocol overhead

## Test Coverage Analysis

### Strong Test Coverage
- **CDC subsystem**: 40+ test scenarios covering edge cases
- **Schema constraints**: Comprehensive pattern and validation tests
- **Wire protocol**: Malformed input handling

### Weak Test Coverage
- **Graph algorithms**: No evidence of shortest path, PageRank, etc.
- **Distributed features**: No Raft/consensus tests found
- **Query optimization**: No cost-based optimizer tests
- **Concurrency**: Limited multi-threaded test evidence

## Reality vs Documentation Claims

| Component | Claimed | CANARY Evidence | Reality |
|-----------|---------|-----------------|---------|
| Query Engine | "Complete" | TESTED (basics) | ~40% - Basic queries work |
| Graph Database | "Full GQL" | TESTED (paths) | ~20% - Simple traversals only |
| Transactions | "ACID" | TESTED (commit) | ~60% - MVCC basics work |
| CDC/Streaming | "Kafka/Kinesis" | TESTED (core) | ~70% - Core CDC works, no Kafka |
| Schema/Constraints | "Enterprise" | TESTED+BENCHED | ~80% - Most constraint types work |
| Storage | "WAL/ARIES" | BENCHED (compact) | ~30% - Compaction works, rest unclear |
| Distributed | "Raft consensus" | NO EVIDENCE | 0% - Not implemented |
| GPU Acceleration | "10-100x faster" | NO EVIDENCE | 0% - Not implemented |
| ML/Graph Algorithms | "GDS-compatible" | NO EVIDENCE | 0% - Not implemented |

## Critical Gaps

### No CANARY Evidence Found For:
1. **Distributed consensus** - No Raft implementation tests
2. **GPU acceleration** - No CUDA/OpenCL evidence
3. **ML algorithms** - No graph ML implementation
4. **QUIC transport** - Despite claims, only TCP evidence
5. **Materialized views** - No refresh/maintenance tests
6. **Full-text search** - No indexing/search tests
7. **Multi-graph support** - No namespace isolation tests
8. **Query optimization** - No cost-based planning tests

## Recommendations

### Immediate Priorities
1. **Remove false claims** about distributed, GPU, ML features
2. **Complete graph execution** - only basic paths work
3. **Implement storage persistence** - serialize/deserialize missing
4. **Add missing tests** for transactions, concurrency

### Documentation Updates Needed
1. Mark distributed features as "not implemented"
2. Remove GPU acceleration claims entirely
3. Clarify CDC works but without external integrations
4. Update transaction docs to reflect MVCC-only scope
5. Remove ML/graph algorithm claims

## Conclusion

The CANARY analysis reveals Geode is approximately **30-35% implemented** with strong foundations in:
- Wire protocol and basic query execution
- Schema constraints and validation  
- CDC core engine (without external integrations)
- Basic path operations

However, most "enterprise" features are entirely missing:
- No distributed capabilities
- No GPU acceleration
- No ML algorithms
- No query optimization
- Limited graph functionality

The codebase shows good engineering practices with comprehensive testing in implemented areas, but the documentation significantly overstates capabilities.

## Delta 1758468880
Added: 182
+ REQ-GQL-001/Binary Protocol Frames/Wire
+ REQ-GQL-002/HELLO Capabilities/Wire
+ REQ-GQL-004/Pagination Legality (US001)/Planner
+ REQ-GQL-004/Pagination Policy Override/Planner
+ REQ-GQL-005/Binary Protocol Core/Wire
+ REQ-GQL-005/Frame Decode/Wire
+ REQ-GQL-005/Set Operations/Engine
+ REQ-GQL-006/GQL Parser/Parser
+ REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
+ REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
+ REQ-GQL-009/Query Executor/Engine
+ REQ-GQL-010/Benchmark Baseline Refresh/Tooling
+ REQ-GQL-010/Benchmark Extraction/Tooling
+ REQ-GQL-010/Benchmark Regression Check/Tooling
+ REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
+ REQ-GQL-010/Diagnostics Large Fold/Engine
+ REQ-GQL-010/Diagnostics Precedence/Engine
+ REQ-GQL-010/Diagnostics Precedence & Folding/Engine
+ REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
+ REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
+ REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
+ REQ-GQL-012/GROUP BY/Aggregation/Engine
+ REQ-GQL-013/Transactions/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
+ REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
+ REQ-GQL-013/Transactions/MVCC/Engine
+ REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/MVCC/SnapshotReadView
+ REQ-GQL-013/Txn Conflict Matrix/Engine
+ REQ-GQL-016/Path Cycle Determinism/Planner
+ REQ-GQL-016/Path Expand Breadth/Planner
+ REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
+ REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
+ REQ-GQL-016/Path Expansion Operator/Planner
+ REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
+ REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
+ REQ-GQL-016/Variable Length Path Expand/Planner
+ REQ-GQL-016/Weighted Path Cost/Planner
+ REQ-GQL-017/Property Access/Engine
+ REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
+ REQ-GQL-017/Property Access Hot Path/Engine
+ REQ-GQL-025/Disk Storage/Storage
+ REQ-GQL-026/Page Management/Storage
+ REQ-GQL-027/WAL/ARIES/Storage
+ REQ-GQL-028/Recovery After Compaction/Storage
+ REQ-GQL-028/WAL Adaptive Policy/Storage
+ REQ-GQL-028/WAL Compaction/CorruptPageRecovery
+ REQ-GQL-028/WAL Compaction/Storage
+ REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
+ REQ-GQL-028/WAL/Recovery/FailureInjection
+ REQ-GQL-032/Check Constraint Evaluation/Engine
+ REQ-GQL-032/Check Constraint Extended Ops/Engine
+ REQ-GQL-032/Composite Uniqueness/Engine
+ REQ-GQL-032/Constraint Cascading/CascadePerf
+ REQ-GQL-032/Constraints/CascadePerf
+ REQ-GQL-032/Schema Constraints/Engine
+ REQ-GQL-032/Schema Constraints Negative/Engine
+ REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
+ REQ-GQL-032/Schema Constraints Pattern Matching/Engine
+ REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
+ REQ-GQL-032/Schema Constraints Pattern Regex/Engine
+ REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
+ REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
+ REQ-GQL-032/Schema Constraints Performance/UniquePerf
+ REQ-GQL-040/Raft Consensus/Distributed
+ REQ-GQL-042/CDC/AdaptiveJitterThresholds
+ REQ-GQL-042/CDC/AdaptiveStressHarness
+ REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
+ REQ-GQL-042/CDC Backfill Latency/API
+ REQ-GQL-042/CDC Core API/API
+ REQ-GQL-042/CDC Engine/API
+ REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
+ REQ-GQL-042/CDC Engine/AdaptiveFlush
+ REQ-GQL-042/CDC Engine/Backpressure
+ REQ-GQL-042/CDC Engine/BackpressureAdaptive
+ REQ-GQL-042/CDC Engine/BackpressureToggle
+ REQ-GQL-042/CDC Engine/CDCControlProtocol
+ REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
+ REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
+ REQ-GQL-042/CDC Engine/DiagnosticsExport
+ REQ-GQL-042/CDC Engine/EventCapture
+ REQ-GQL-042/CDC Engine/GuardrailReset
+ REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
+ REQ-GQL-042/CDC Engine/Ingest
+ REQ-GQL-042/CDC Engine/MixedWorkload
+ REQ-GQL-042/CDC Engine/Ordering
+ REQ-GQL-042/CDC Engine/OrderingConcurrency
+ REQ-GQL-042/CDC Engine/OrderingPerf
+ REQ-GQL-042/CDC Engine/ResumeTokenRestart
+ REQ-GQL-042/CDC Engine/Retention
+ REQ-GQL-042/CDC Engine/Telemetry
+ REQ-GQL-042/CDC Engine/WALTail
+ REQ-GQL-042/CDC Engine/WALTailDisabled
+ REQ-GQL-042/CDC Engine/WALTailMalformed
+ REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedLog
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
+ REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
+ REQ-GQL-042/CDC Lifecycle/API
+ REQ-GQL-042/CDC Resume Token/API
+ REQ-GQL-042/CDC Resume Token Restart/API
+ REQ-GQL-042/CDC/Streaming/API
+ REQ-GQL-042/CDC/Streaming/Engine
+ REQ-GQL-042/CDCControlProtocol/E2E
+ REQ-GQL-042/CDCControlProtocol/E2ENoEngine
+ REQ-GQL-042/CDCControlProtocol/E2EUnsupported
+ REQ-GQL-042/CDC_CONTROL/Refactor
+ REQ-GQL-046/TDE/KeyHierarchy
+ REQ-GQL-046/TDE/Storage
+ REQ-GQL-046/TDE Key Hierarchy/Storage
+ REQ-GQL-046/TDE Key Rotation Throughput/Storage
+ REQ-GQL-050/Distributed/RaftPartitionSimulation
+ REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
+ REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
+ REQ-GQL-062/TopologicalSortDFS/Traversal
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/CycleDetectDirected
+ REQ-GQL-062/Traversals/CycleDetectUndirected
+ REQ-GQL-062/Traversals/DFSIterative
+ REQ-GQL-062/Traversals/IDDFS
+ REQ-GQL-062/Traversals/TopologicalSortKahn
+ REQ-GQL-063/Shortest Paths/AStar
+ REQ-GQL-063/Shortest Paths/DagShortestPath
+ REQ-GQL-063/Shortest Paths/Dijkstra
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-064/Connectivity/BiconnectedComponents
+ REQ-GQL-064/Connectivity/BridgesArticulation
+ REQ-GQL-064/Connectivity/KosarajuValidation
+ REQ-GQL-064/Connectivity/TarjanSCC
+ REQ-GQL-065/Spanning Trees/Kruskal
+ REQ-GQL-065/Spanning Trees/Prim
+ REQ-GQL-066/Flow/Matching/Dinic
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/HopcroftKarp
+ REQ-GQL-067/Centrality/BetweennessCentrality
+ REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
+ REQ-GQL-067/Centrality/BridgeLeverage
+ REQ-GQL-067/Centrality/ClosenessCentrality
+ REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
+ REQ-GQL-067/Centrality/EigenvectorCentrality
+ REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
+ REQ-GQL-067/Centrality/GreyCardinalComposite
+ REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
+ REQ-GQL-067/Centrality/PageRank
+ REQ-GQL-067/Centrality/PageRankVarianceEnvelope
+ REQ-GQL-068/Containers/BloomFilterContainer
+ REQ-GQL-068/Containers/LFUCache
+ REQ-GQL-068/Containers/LRUCache
+ REQ-GQL-068/Containers/SkipList
+ REQ-GQL-068/Containers/Trie
+ REQ-GQL-068/Containers/UnionFind
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-070/String Search/KMP
+ REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
+ REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
+ REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
+ REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
+ REQ-GQL-073/MvccAdvanced/RepairThroughputBench
+ REQ-GQL-XXX/Feature Name/Component
+ REQ-GQL-XXX/Name/Aspect
+ REQ-GQL-XXX/Name/Component
Promotions: 0


## Delta 1758468973
Added: 16
+ REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
+ REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
+ REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
+ REQ-GQL-012/GROUP BY/Aggregation/Engine
+ REQ-GQL-013/Transactions/MVCC/Engine
+ REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/MVCC/SnapshotReadView
+ REQ-GQL-027/WAL/ARIES/Storage
+ REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
+ REQ-GQL-028/WAL/Recovery/FailureInjection
+ REQ-GQL-042/CDC/Streaming/API
+ REQ-GQL-042/CDC/Streaming/Engine
+ REQ-GQL-066/Flow/Matching/Dinic
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/HopcroftKarp
Promotions: 4
* REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv:BENCHED->TESTED
* REQ-GQL-062/Traversals/BFS:TESTED->BENCHED
* REQ-GQL-063/Shortest Paths/UnweightedBFSPaths:TESTED->BENCHED
* REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter:BENCHED->TESTED


## Delta 1758468989
Added: 182
+ REQ-GQL-001/Binary Protocol Frames/Wire
+ REQ-GQL-002/HELLO Capabilities/Wire
+ REQ-GQL-004/Pagination Legality (US001)/Planner
+ REQ-GQL-004/Pagination Policy Override/Planner
+ REQ-GQL-005/Binary Protocol Core/Wire
+ REQ-GQL-005/Frame Decode/Wire
+ REQ-GQL-005/Set Operations/Engine
+ REQ-GQL-006/GQL Parser/Parser
+ REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
+ REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
+ REQ-GQL-009/Query Executor/Engine
+ REQ-GQL-010/Benchmark Baseline Refresh/Tooling
+ REQ-GQL-010/Benchmark Extraction/Tooling
+ REQ-GQL-010/Benchmark Regression Check/Tooling
+ REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
+ REQ-GQL-010/Diagnostics Large Fold/Engine
+ REQ-GQL-010/Diagnostics Precedence/Engine
+ REQ-GQL-010/Diagnostics Precedence & Folding/Engine
+ REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
+ REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
+ REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
+ REQ-GQL-012/GROUP BY/Aggregation/Engine
+ REQ-GQL-013/Transactions/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
+ REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
+ REQ-GQL-013/Transactions/MVCC/Engine
+ REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/MVCC/SnapshotReadView
+ REQ-GQL-013/Txn Conflict Matrix/Engine
+ REQ-GQL-016/Path Cycle Determinism/Planner
+ REQ-GQL-016/Path Expand Breadth/Planner
+ REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
+ REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
+ REQ-GQL-016/Path Expansion Operator/Planner
+ REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
+ REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
+ REQ-GQL-016/Variable Length Path Expand/Planner
+ REQ-GQL-016/Weighted Path Cost/Planner
+ REQ-GQL-017/Property Access/Engine
+ REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
+ REQ-GQL-017/Property Access Hot Path/Engine
+ REQ-GQL-025/Disk Storage/Storage
+ REQ-GQL-026/Page Management/Storage
+ REQ-GQL-027/WAL/ARIES/Storage
+ REQ-GQL-028/Recovery After Compaction/Storage
+ REQ-GQL-028/WAL Adaptive Policy/Storage
+ REQ-GQL-028/WAL Compaction/CorruptPageRecovery
+ REQ-GQL-028/WAL Compaction/Storage
+ REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
+ REQ-GQL-028/WAL/Recovery/FailureInjection
+ REQ-GQL-032/Check Constraint Evaluation/Engine
+ REQ-GQL-032/Check Constraint Extended Ops/Engine
+ REQ-GQL-032/Composite Uniqueness/Engine
+ REQ-GQL-032/Constraint Cascading/CascadePerf
+ REQ-GQL-032/Constraints/CascadePerf
+ REQ-GQL-032/Schema Constraints/Engine
+ REQ-GQL-032/Schema Constraints Negative/Engine
+ REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
+ REQ-GQL-032/Schema Constraints Pattern Matching/Engine
+ REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
+ REQ-GQL-032/Schema Constraints Pattern Regex/Engine
+ REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
+ REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
+ REQ-GQL-032/Schema Constraints Performance/UniquePerf
+ REQ-GQL-040/Raft Consensus/Distributed
+ REQ-GQL-042/CDC/AdaptiveJitterThresholds
+ REQ-GQL-042/CDC/AdaptiveStressHarness
+ REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
+ REQ-GQL-042/CDC Backfill Latency/API
+ REQ-GQL-042/CDC Core API/API
+ REQ-GQL-042/CDC Engine/API
+ REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
+ REQ-GQL-042/CDC Engine/AdaptiveFlush
+ REQ-GQL-042/CDC Engine/Backpressure
+ REQ-GQL-042/CDC Engine/BackpressureAdaptive
+ REQ-GQL-042/CDC Engine/BackpressureToggle
+ REQ-GQL-042/CDC Engine/CDCControlProtocol
+ REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
+ REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
+ REQ-GQL-042/CDC Engine/DiagnosticsExport
+ REQ-GQL-042/CDC Engine/EventCapture
+ REQ-GQL-042/CDC Engine/GuardrailReset
+ REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
+ REQ-GQL-042/CDC Engine/Ingest
+ REQ-GQL-042/CDC Engine/MixedWorkload
+ REQ-GQL-042/CDC Engine/Ordering
+ REQ-GQL-042/CDC Engine/OrderingConcurrency
+ REQ-GQL-042/CDC Engine/OrderingPerf
+ REQ-GQL-042/CDC Engine/ResumeTokenRestart
+ REQ-GQL-042/CDC Engine/Retention
+ REQ-GQL-042/CDC Engine/Telemetry
+ REQ-GQL-042/CDC Engine/WALTail
+ REQ-GQL-042/CDC Engine/WALTailDisabled
+ REQ-GQL-042/CDC Engine/WALTailMalformed
+ REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedLog
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
+ REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
+ REQ-GQL-042/CDC Lifecycle/API
+ REQ-GQL-042/CDC Resume Token/API
+ REQ-GQL-042/CDC Resume Token Restart/API
+ REQ-GQL-042/CDC/Streaming/API
+ REQ-GQL-042/CDC/Streaming/Engine
+ REQ-GQL-042/CDCControlProtocol/E2E
+ REQ-GQL-042/CDCControlProtocol/E2ENoEngine
+ REQ-GQL-042/CDCControlProtocol/E2EUnsupported
+ REQ-GQL-042/CDC_CONTROL/Refactor
+ REQ-GQL-046/TDE/KeyHierarchy
+ REQ-GQL-046/TDE/Storage
+ REQ-GQL-046/TDE Key Hierarchy/Storage
+ REQ-GQL-046/TDE Key Rotation Throughput/Storage
+ REQ-GQL-050/Distributed/RaftPartitionSimulation
+ REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
+ REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
+ REQ-GQL-062/TopologicalSortDFS/Traversal
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/CycleDetectDirected
+ REQ-GQL-062/Traversals/CycleDetectUndirected
+ REQ-GQL-062/Traversals/DFSIterative
+ REQ-GQL-062/Traversals/IDDFS
+ REQ-GQL-062/Traversals/TopologicalSortKahn
+ REQ-GQL-063/Shortest Paths/AStar
+ REQ-GQL-063/Shortest Paths/DagShortestPath
+ REQ-GQL-063/Shortest Paths/Dijkstra
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-064/Connectivity/BiconnectedComponents
+ REQ-GQL-064/Connectivity/BridgesArticulation
+ REQ-GQL-064/Connectivity/KosarajuValidation
+ REQ-GQL-064/Connectivity/TarjanSCC
+ REQ-GQL-065/Spanning Trees/Kruskal
+ REQ-GQL-065/Spanning Trees/Prim
+ REQ-GQL-066/Flow/Matching/Dinic
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/HopcroftKarp
+ REQ-GQL-067/Centrality/BetweennessCentrality
+ REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
+ REQ-GQL-067/Centrality/BridgeLeverage
+ REQ-GQL-067/Centrality/ClosenessCentrality
+ REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
+ REQ-GQL-067/Centrality/EigenvectorCentrality
+ REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
+ REQ-GQL-067/Centrality/GreyCardinalComposite
+ REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
+ REQ-GQL-067/Centrality/PageRank
+ REQ-GQL-067/Centrality/PageRankVarianceEnvelope
+ REQ-GQL-068/Containers/BloomFilterContainer
+ REQ-GQL-068/Containers/LFUCache
+ REQ-GQL-068/Containers/LRUCache
+ REQ-GQL-068/Containers/SkipList
+ REQ-GQL-068/Containers/Trie
+ REQ-GQL-068/Containers/UnionFind
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-070/String Search/KMP
+ REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
+ REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
+ REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
+ REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
+ REQ-GQL-073/MvccAdvanced/RepairThroughputBench
+ REQ-GQL-XXX/Feature Name/Component
+ REQ-GQL-XXX/Name/Aspect
+ REQ-GQL-XXX/Name/Component
Promotions: 0


## Delta 1758469418
Added: 191
+ REQ-GQL-001/Binary Protocol Frames/Wire
+ REQ-GQL-002/HELLO Capabilities/Wire
+ REQ-GQL-004/Pagination Legality (US001)/Planner
+ REQ-GQL-004/Pagination Policy Override/Planner
+ REQ-GQL-005/Binary Protocol Core/Wire
+ REQ-GQL-005/Frame Decode/Wire
+ REQ-GQL-005/Set Operations/Engine
+ REQ-GQL-006/GQL Parser/Parser
+ REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
+ REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
+ REQ-GQL-009/Query Executor/Engine
+ REQ-GQL-010/Benchmark Baseline Refresh/Tooling
+ REQ-GQL-010/Benchmark Extraction/Tooling
+ REQ-GQL-010/Benchmark Regression Check/Tooling
+ REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
+ REQ-GQL-010/Diagnostics Large Fold/Engine
+ REQ-GQL-010/Diagnostics Precedence/Engine
+ REQ-GQL-010/Diagnostics Precedence & Folding/Engine
+ REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
+ REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
+ REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
+ REQ-GQL-012/GROUP BY/Aggregation/Engine
+ REQ-GQL-013/Transactions/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
+ REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
+ REQ-GQL-013/Transactions/MVCC/Engine
+ REQ-GQL-013/Transactions/MVCC/MVCCRepairThroughputVarianceEnvelope
+ REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/MVCC/SnapshotReadView
+ REQ-GQL-013/Txn Conflict Matrix/Engine
+ REQ-GQL-016/Path Cycle Determinism/Planner
+ REQ-GQL-016/Path Expand Breadth/Planner
+ REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
+ REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
+ REQ-GQL-016/Path Expansion Operator/Planner
+ REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
+ REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
+ REQ-GQL-016/Variable Length Path Expand/Planner
+ REQ-GQL-016/Weighted Path Cost/Planner
+ REQ-GQL-017/Property Access/Engine
+ REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
+ REQ-GQL-017/Property Access Hot Path/Engine
+ REQ-GQL-025/Disk Storage/Storage
+ REQ-GQL-026/Page Management/Storage
+ REQ-GQL-027/WAL/ARIES/Storage
+ REQ-GQL-028/Recovery After Compaction/Storage
+ REQ-GQL-028/WAL Adaptive Policy/Storage
+ REQ-GQL-028/WAL Adaptive Policy/WalAdaptivePolicyLatencyVarianceEnvelope
+ REQ-GQL-028/WAL Compaction/CorruptPageRecovery
+ REQ-GQL-028/WAL Compaction/Storage
+ REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
+ REQ-GQL-028/WAL/Recovery/FailureInjection
+ REQ-GQL-032/Check Constraint Evaluation/Engine
+ REQ-GQL-032/Check Constraint Extended Ops/Engine
+ REQ-GQL-032/Composite Uniqueness/Engine
+ REQ-GQL-032/Constraint Cascading/CascadePerf
+ REQ-GQL-032/Constraints/CascadePerf
+ REQ-GQL-032/Schema Constraints/Engine
+ REQ-GQL-032/Schema Constraints Negative/Engine
+ REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
+ REQ-GQL-032/Schema Constraints Pattern Matching/Engine
+ REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
+ REQ-GQL-032/Schema Constraints Pattern Regex/Engine
+ REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
+ REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
+ REQ-GQL-032/Schema Constraints Performance/UniquePerf
+ REQ-GQL-040/Raft Consensus/Distributed
+ REQ-GQL-042/CDC/AdaptiveJitterThresholds
+ REQ-GQL-042/CDC/AdaptiveStressHarness
+ REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
+ REQ-GQL-042/CDC Backfill Latency/API
+ REQ-GQL-042/CDC Core API/API
+ REQ-GQL-042/CDC Engine/API
+ REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
+ REQ-GQL-042/CDC Engine/AdaptiveFlush
+ REQ-GQL-042/CDC Engine/Backpressure
+ REQ-GQL-042/CDC Engine/BackpressureAdaptive
+ REQ-GQL-042/CDC Engine/BackpressureToggle
+ REQ-GQL-042/CDC Engine/CDCControlProtocol
+ REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
+ REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
+ REQ-GQL-042/CDC Engine/DiagnosticsExport
+ REQ-GQL-042/CDC Engine/EventCapture
+ REQ-GQL-042/CDC Engine/GuardrailReset
+ REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
+ REQ-GQL-042/CDC Engine/Ingest
+ REQ-GQL-042/CDC Engine/MixedWorkload
+ REQ-GQL-042/CDC Engine/Ordering
+ REQ-GQL-042/CDC Engine/OrderingConcurrency
+ REQ-GQL-042/CDC Engine/OrderingPerf
+ REQ-GQL-042/CDC Engine/ResumeTokenRestart
+ REQ-GQL-042/CDC Engine/Retention
+ REQ-GQL-042/CDC Engine/Telemetry
+ REQ-GQL-042/CDC Engine/WALTail
+ REQ-GQL-042/CDC Engine/WALTailDisabled
+ REQ-GQL-042/CDC Engine/WALTailMalformed
+ REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedLog
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
+ REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
+ REQ-GQL-042/CDC Lifecycle/API
+ REQ-GQL-042/CDC Resume Token/API
+ REQ-GQL-042/CDC Resume Token Restart/API
+ REQ-GQL-042/CDC/Streaming/API
+ REQ-GQL-042/CDC/Streaming/Engine
+ REQ-GQL-042/CDCControlProtocol/E2E
+ REQ-GQL-042/CDCControlProtocol/E2ENoEngine
+ REQ-GQL-042/CDCControlProtocol/E2EUnsupported
+ REQ-GQL-042/CDC_CONTROL/Refactor
+ REQ-GQL-046/TDE/KeyHierarchy
+ REQ-GQL-046/TDE/Storage
+ REQ-GQL-046/TDE Key Hierarchy/Storage
+ REQ-GQL-046/TDE Key Rotation Throughput/Storage
+ REQ-GQL-050/Distributed/RaftPartitionSimulation
+ REQ-GQL-050/Multi-Tenancy/TenantRegistry
+ REQ-GQL-050/Multi-Tenancy/TenantRegistryBasic
+ REQ-GQL-051/GPU Acceleration/GPUFlagger
+ REQ-GQL-051/GPU Acceleration/GPUFlaggerUnsupported
+ REQ-GQL-052/Federation/FederationRouter
+ REQ-GQL-052/Federation/FederationRouterUnsupported
+ REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
+ REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
+ REQ-GQL-060/Core Graph Builders/GraphBuilderThroughputVarianceEnvelope
+ REQ-GQL-062/TopologicalSortDFS/Traversal
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/CycleDetectDirected
+ REQ-GQL-062/Traversals/CycleDetectUndirected
+ REQ-GQL-062/Traversals/DFSIterative
+ REQ-GQL-062/Traversals/IDDFS
+ REQ-GQL-062/Traversals/TopologicalSortKahn
+ REQ-GQL-063/Shortest Paths/AStar
+ REQ-GQL-063/Shortest Paths/DagShortestPath
+ REQ-GQL-063/Shortest Paths/Dijkstra
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-064/Connectivity/BiconnectedComponents
+ REQ-GQL-064/Connectivity/BridgesArticulation
+ REQ-GQL-064/Connectivity/KosarajuValidation
+ REQ-GQL-064/Connectivity/TarjanSCC
+ REQ-GQL-065/Spanning Trees/Kruskal
+ REQ-GQL-065/Spanning Trees/Prim
+ REQ-GQL-066/Flow/Matching/Dinic
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/HopcroftKarp
+ REQ-GQL-067/Centrality/BetweennessCentrality
+ REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
+ REQ-GQL-067/Centrality/BridgeLeverage
+ REQ-GQL-067/Centrality/ClosenessCentrality
+ REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
+ REQ-GQL-067/Centrality/EigenvectorCentrality
+ REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
+ REQ-GQL-067/Centrality/GreyCardinalComposite
+ REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
+ REQ-GQL-067/Centrality/PageRank
+ REQ-GQL-067/Centrality/PageRankVarianceEnvelope
+ REQ-GQL-068/Containers/BloomFilterContainer
+ REQ-GQL-068/Containers/LFUCache
+ REQ-GQL-068/Containers/LRUCache
+ REQ-GQL-068/Containers/SkipList
+ REQ-GQL-068/Containers/Trie
+ REQ-GQL-068/Containers/UnionFind
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-070/String Search/KMP
+ REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
+ REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
+ REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
+ REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
+ REQ-GQL-073/MvccAdvanced/RepairThroughputBench
+ REQ-GQL-XXX/Feature Name/Component
+ REQ-GQL-XXX/Name/Aspect
+ REQ-GQL-XXX/Name/Component
Promotions: 0


## Delta 1758478238
Added: 195
+ REQ-GQL-001/Binary Protocol Frames/Wire
+ REQ-GQL-002/HELLO Capabilities/Wire
+ REQ-GQL-004/Pagination Legality (US001)/Planner
+ REQ-GQL-004/Pagination Policy Override/Planner
+ REQ-GQL-005/Binary Protocol Core/Wire
+ REQ-GQL-005/Frame Decode/Wire
+ REQ-GQL-005/Set Operations/Engine
+ REQ-GQL-006/GQL Parser/Parser
+ REQ-GQL-007/MATCH/OPTIONAL Parsing/Parser
+ REQ-GQL-008/ORDER/LIMIT/OFFSET Parsing/Parser
+ REQ-GQL-009/Query Executor/Engine
+ REQ-GQL-010/Benchmark Baseline Refresh/Tooling
+ REQ-GQL-010/Benchmark Extraction/Tooling
+ REQ-GQL-010/Benchmark Regression Check/Tooling
+ REQ-GQL-010/Benchmark Regression JSON Summary/Tooling
+ REQ-GQL-010/Diagnostics Large Fold/Engine
+ REQ-GQL-010/Diagnostics Precedence/Engine
+ REQ-GQL-010/Diagnostics Precedence & Folding/Engine
+ REQ-GQL-010/Freshness Guard/StatusFreshnessGuard
+ REQ-GQL-010/RealityDocs/ImplementationRealityDeltaTool
+ REQ-GQL-011/UNION/EXCEPT/INTERSECT/Engine
+ REQ-GQL-012/GROUP BY/Aggregation/Engine
+ REQ-GQL-013/Transactions/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/SSIPhantomPreventionVariance
+ REQ-GQL-013/Transactions/TxnConflictMatrixVarianceEnvelope
+ REQ-GQL-013/Transactions/MVCC/Engine
+ REQ-GQL-013/Transactions/MVCC/MVCCRepairThroughputVarianceEnvelope
+ REQ-GQL-013/Transactions/MVCC/SSIPhantomPrevention
+ REQ-GQL-013/Transactions/MVCC/SnapshotReadView
+ REQ-GQL-013/Txn Conflict Matrix/Engine
+ REQ-GQL-016/Path Cycle Determinism/Planner
+ REQ-GQL-016/Path Expand Breadth/Planner
+ REQ-GQL-016/Path Expansion Cycle Pruning Perf/PathCyclePruningPerf
+ REQ-GQL-016/Path Expansion Memory Perf/PathExpandMemPerf
+ REQ-GQL-016/Path Expansion Operator/Planner
+ REQ-GQL-016/Path Expansion Pruning Stats Perf/PathPruningStatsPerf
+ REQ-GQL-016/Planner Paths/PathExpandBreadthVarianceEnvelope
+ REQ-GQL-016/Variable Length Path Expand/Planner
+ REQ-GQL-016/Weighted Path Cost/Planner
+ REQ-GQL-017/Property Access/Engine
+ REQ-GQL-017/Property Access/PropertyAccessHotPathVarianceEnvelope
+ REQ-GQL-017/Property Access Hot Path/Engine
+ REQ-GQL-025/Disk Storage/Storage
+ REQ-GQL-026/Page Management/Storage
+ REQ-GQL-027/WAL/ARIES/Storage
+ REQ-GQL-028/Recovery After Compaction/Storage
+ REQ-GQL-028/WAL Adaptive Policy/Storage
+ REQ-GQL-028/WAL Adaptive Policy/WalAdaptivePolicyLatencyVarianceEnvelope
+ REQ-GQL-028/WAL Compaction/CorruptPageRecovery
+ REQ-GQL-028/WAL Compaction/Storage
+ REQ-GQL-028/WAL Compaction/WalCompactionVarianceEnvelope
+ REQ-GQL-028/WAL/Recovery/CorruptPageRecovery
+ REQ-GQL-028/WAL/Recovery/FailureInjection
+ REQ-GQL-032/Check Constraint Evaluation/Engine
+ REQ-GQL-032/Check Constraint Extended Ops/Engine
+ REQ-GQL-032/Composite Uniqueness/Engine
+ REQ-GQL-032/Constraint Cascading/CascadePerf
+ REQ-GQL-032/Constraints/CascadePerf
+ REQ-GQL-032/Schema Constraints/Engine
+ REQ-GQL-032/Schema Constraints Negative/Engine
+ REQ-GQL-032/Schema Constraints Pattern Escape Support/Engine
+ REQ-GQL-032/Schema Constraints Pattern Matching/Engine
+ REQ-GQL-032/Schema Constraints Pattern Performance/PatternPerf
+ REQ-GQL-032/Schema Constraints Pattern Regex/Engine
+ REQ-GQL-032/Schema Constraints Pattern Regex NegClass/Engine
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Memory/PatternStateDedupMem
+ REQ-GQL-032/Schema Constraints Pattern State Dedup Perf/PatternStateDedupPerf
+ REQ-GQL-032/Schema Constraints Performance/ConstraintPerf
+ REQ-GQL-032/Schema Constraints Performance/ConstraintPerfVarianceEnvelope
+ REQ-GQL-032/Schema Constraints Performance/UniquePerf
+ REQ-GQL-040/Raft Consensus/Distributed
+ REQ-GQL-042/CDC/AdaptiveJitterThresholds
+ REQ-GQL-042/CDC/AdaptiveStressHarness
+ REQ-GQL-042/CDC/CDCApplyBatchLatencyVarianceEnvelope
+ REQ-GQL-042/CDC Backfill Latency/API
+ REQ-GQL-042/CDC Core API/API
+ REQ-GQL-042/CDC Engine/API
+ REQ-GQL-042/CDC Engine/AdaptiveBaselinePerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerf
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThreshold
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnv
+ REQ-GQL-042/CDC Engine/AdaptiveDiffPerfThresholdEnvInvalidParse
+ REQ-GQL-042/CDC Engine/AdaptiveFlush
+ REQ-GQL-042/CDC Engine/Backpressure
+ REQ-GQL-042/CDC Engine/BackpressureAdaptive
+ REQ-GQL-042/CDC Engine/BackpressureToggle
+ REQ-GQL-042/CDC Engine/CDCControlProtocol
+ REQ-GQL-042/CDC Engine/CDCControlProtocolMalformed
+ REQ-GQL-042/CDC Engine/CDCDiagnosticsProtocol
+ REQ-GQL-042/CDC Engine/DiagnosticsExport
+ REQ-GQL-042/CDC Engine/EventCapture
+ REQ-GQL-042/CDC Engine/GuardrailReset
+ REQ-GQL-042/CDC Engine/GuardrailTimestampsMonotonic
+ REQ-GQL-042/CDC Engine/Ingest
+ REQ-GQL-042/CDC Engine/MixedWorkload
+ REQ-GQL-042/CDC Engine/Ordering
+ REQ-GQL-042/CDC Engine/OrderingConcurrency
+ REQ-GQL-042/CDC Engine/OrderingPerf
+ REQ-GQL-042/CDC Engine/ResumeTokenRestart
+ REQ-GQL-042/CDC Engine/Retention
+ REQ-GQL-042/CDC Engine/Telemetry
+ REQ-GQL-042/CDC Engine/WALTail
+ REQ-GQL-042/CDC Engine/WALTailDisabled
+ REQ-GQL-042/CDC Engine/WALTailMalformed
+ REQ-GQL-042/CDC Engine/WALTailMalformedDiagnostics
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbort
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailAbortEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarn
+ REQ-GQL-042/CDC Engine/WALTailMalformedGuardrailWarnEnv
+ REQ-GQL-042/CDC Engine/WALTailMalformedLog
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBuffer
+ REQ-GQL-042/CDC Engine/WALTailMalformedLogBufferWrap
+ REQ-GQL-042/CDC Engine/WALTailMalformedPayloadHash
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotInterval
+ REQ-GQL-042/CDC Engine/WALTailMalformedSnapshotIntervalEnv
+ REQ-GQL-042/CDC Lifecycle/API
+ REQ-GQL-042/CDC Resume Token/API
+ REQ-GQL-042/CDC Resume Token Restart/API
+ REQ-GQL-042/CDC/Streaming/API
+ REQ-GQL-042/CDC/Streaming/Engine
+ REQ-GQL-042/CDCControlProtocol/E2E
+ REQ-GQL-042/CDCControlProtocol/E2ENoEngine
+ REQ-GQL-042/CDCControlProtocol/E2EUnsupported
+ REQ-GQL-042/CDC_CONTROL/Refactor
+ REQ-GQL-046/TDE/KeyHierarchy
+ REQ-GQL-046/TDE/Storage
+ REQ-GQL-046/TDE Key Hierarchy/Storage
+ REQ-GQL-046/TDE Key Rotation Throughput/Storage
+ REQ-GQL-050/Distributed/RaftPartitionSimulation
+ REQ-GQL-050/Multi-Tenancy/TenantRegistry
+ REQ-GQL-050/Multi-Tenancy/TenantRegistryBasic
+ REQ-GQL-050/Multi-Tenancy/TenantRegistryVarianceEnvelope
+ REQ-GQL-051/GPU Acceleration/GPUFlagger
+ REQ-GQL-051/GPU Acceleration/GPUFlaggerEnumerationVarianceEnvelope
+ REQ-GQL-051/GPU Acceleration/GPUFlaggerUnsupported
+ REQ-GQL-052/Federation/FederationRouter
+ REQ-GQL-052/Federation/FederationRouterUnsupported
+ REQ-GQL-060/Core Graph Builders/ConcurrencySafeGraph
+ REQ-GQL-060/Core Graph Builders/DirectedWeightedBuilders
+ REQ-GQL-060/Core Graph Builders/GraphBuilderThroughputVarianceEnvelope
+ REQ-GQL-062/TopologicalSortDFS/Traversal
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/BFS
+ REQ-GQL-062/Traversals/CycleDetectDirected
+ REQ-GQL-062/Traversals/CycleDetectUndirected
+ REQ-GQL-062/Traversals/DFSIterative
+ REQ-GQL-062/Traversals/IDDFS
+ REQ-GQL-062/Traversals/TopologicalSortKahn
+ REQ-GQL-063/Shortest Paths/AStar
+ REQ-GQL-063/Shortest Paths/DagShortestPath
+ REQ-GQL-063/Shortest Paths/Dijkstra
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-063/Shortest Paths/UnweightedBFSPaths
+ REQ-GQL-064/Connectivity/BiconnectedComponents
+ REQ-GQL-064/Connectivity/BridgesArticulation
+ REQ-GQL-064/Connectivity/KosarajuValidation
+ REQ-GQL-064/Connectivity/TarjanSCC
+ REQ-GQL-065/Spanning Trees/Kruskal
+ REQ-GQL-065/Spanning Trees/Prim
+ REQ-GQL-066/Flow/Matching/Dinic
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/EdmondsKarp
+ REQ-GQL-066/Flow/Matching/HopcroftKarp
+ REQ-GQL-067/Centrality/BetweennessCentrality
+ REQ-GQL-067/Centrality/BetweennessVarianceEnvelope
+ REQ-GQL-067/Centrality/BridgeLeverage
+ REQ-GQL-067/Centrality/ClosenessCentrality
+ REQ-GQL-067/Centrality/ClosenessVarianceEnvelope
+ REQ-GQL-067/Centrality/EigenvectorCentrality
+ REQ-GQL-067/Centrality/EigenvectorVarianceEnvelope
+ REQ-GQL-067/Centrality/GreyCardinalComposite
+ REQ-GQL-067/Centrality/GreyCardinalVarianceEnvelope
+ REQ-GQL-067/Centrality/PageRank
+ REQ-GQL-067/Centrality/PageRankVarianceEnvelope
+ REQ-GQL-068/Containers/BloomFilterContainer
+ REQ-GQL-068/Containers/LFUCache
+ REQ-GQL-068/Containers/LRUCache
+ REQ-GQL-068/Containers/SkipList
+ REQ-GQL-068/Containers/Trie
+ REQ-GQL-068/Containers/UnionFind
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-069/Probabilistic/CountMinSketch
+ REQ-GQL-070/String Search/KMP
+ REQ-GQL-073/MvccAdvanced/ConflictRepairHeuristics
+ REQ-GQL-073/MvccAdvanced/EarlyConflictDetection
+ REQ-GQL-073/MvccAdvanced/FalsePositiveReduction
+ REQ-GQL-073/MvccAdvanced/PartialRollbackMechanism
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveSkewFilter
+ REQ-GQL-073/MvccAdvanced/PredictiveVersionCheck
+ REQ-GQL-073/MvccAdvanced/RepairThroughputBench
+ REQ-GQL-XXX/Feature Name/Component
+ REQ-GQL-XXX/Name/Aspect
+ REQ-GQL-XXX/Name/Component
Promotions: 0
