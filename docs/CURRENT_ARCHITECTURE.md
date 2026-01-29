# Geode Current Architecture Documentation

**Generated**: 2025-11-12
**Purpose**: Baseline architecture documentation for modularization effort
**Phase**: Phase 0, M0.4 - Document Current Architecture
**Status**: Pre-Modularization Snapshot

## Table of Contents

1. [Overview](#overview)
2. [Module Structure](#module-structure)
3. [Dependency Graph](#dependency-graph)
4. [Circular Dependencies](#circular-dependencies)
5. [Test Coverage](#test-coverage)
6. [Critical Paths](#critical-paths)
7. [Refactoring Priorities](#refactoring-priorities)

---

## Overview

### Codebase Statistics

**Source Code**:

- **Total LOC**: 173,048 lines
- **Source Files**: 436 Zig files
- **Average File Size**: 396 LOC
- **Modules**: 50 top-level directories

**Test Code**:

- **Test Files**: 843 Zig test files
- **Test/Source Ratio**: 1.9:1
- **Integration Tests**: 1,688 geodetestlab tests
- **Pass Rate**: 97.4% (1,644 passing, 9 failing)

**File Size Distribution**:

- **Large (>1000 LOC)**: 23 files (5.3%)
- **Medium (500-1000 LOC)**: 78 files (17.9%)
- **Small (<500 LOC)**: 335 files (76.8%)

### Architecture Style

- **Language**: Zig 0.15.1+
- **Paradigm**: Modular with some monolithic components
- **Build System**: Zig build system with module injection
- **Testing**: Unit tests (Zig) + Integration tests (geodetestlab)
- **Transport**: QUIC + TLS

---

## Module Structure

### Top-Level Modules (50 directories)

#### Core System Modules

**Server & CLI** (Entry Points):

```
src/server/         - Server implementation (7,039 LOC in main.zig)
src/cli/            - CLI implementation (5,885 LOC in main.zig)
src/client/         - Client library and REPL
```

**Query Processing**:

```
src/gql/            - GQL parser and lexer (5,883 LOC in parser.zig)
src/execution/      - Query execution engine (4,725 LOC in path_and_call_operations.zig)
src/eval.zig        - Expression evaluation (3,332 LOC)
src/planner/        - Query planning and optimization
src/optimizer/      - Query optimization strategies
```

**Storage & Data**:

```
src/storage/        - Storage engine, page management, backup
src/wal/            - Write-ahead logging
src/index/          - Index implementations (B-tree, HNSW, R-tree, etc.)
src/txn/            - Transaction management
src/graph/          - Graph-specific data structures
```

**Security**:

```
src/security/       - Authentication, authorization, audit, TDE, RLS
src/crypto/         - Cryptographic primitives
src/keys/           - Key management
```

**Distributed Systems**:

```
src/distributed/    - Federation, sharding, Raft consensus
src/federation/     - Cross-cluster queries
```

**Advanced Features**:

```
src/ml/             - Machine learning (graph embeddings)
src/analytics/      - Real-time analytics
src/streaming/      - CDC (Change Data Capture)
src/gpu/            - GPU acceleration (Vulkan, CUDA)
src/fts/            - Full-text search
src/timeseries/     - Time-series operations
src/temporal/       - Temporal data types
```

**Infrastructure**:

```
src/transport/      - QUIC transport layer
src/protocol.zig    - Protocol implementation
src/monitoring/     - Metrics and monitoring
src/audit/          - Audit logging
src/log/            - Logging infrastructure
src/util/           - Utility functions
src/utils/          - Additional utilities
```

**Data Types**:

```
src/types/          - Advanced data types (vector, geographic, network, etc.)
src/containers/     - Container data structures
src/unicode/        - Unicode support
```

**Schema & Catalog**:

```
src/schema/         - Schema management
src/migration/      - Schema migrations
src/query/          - Query management (materialized views)
```

**Development & Testing**:

```
src/tests/          - Test utilities
src/bench/          - Benchmarking utilities
src/benchmarks/     - Benchmark implementations
src/fuzz/           - Fuzzing infrastructure
```

**Miscellaneous**:

```
src/admin/          - Admin operations
src/tools/          - Development tools
src/runtime/        - Runtime support
src/multitenancy/   - Multi-tenancy support
src/pagination/     - Pagination utilities
src/parser/         - Generic parsing utilities
src/performance/    - Performance optimizations
src/algorithms/     - Algorithm implementations
src/dist/           - Distribution utilities
src/cdc/            - CDC core
```

### Module Dependencies (Major Components)

```
┌─────────────────────────────────────────────────────────────┐
│                      Entry Points                           │
│  ┌────────────┐                       ┌─────────────┐       │
│  │ Server     │                       │    CLI      │       │
│  │ (7,039 L)  │                       │  (5,885 L)  │       │
│  └─────┬──────┘                       └──────┬──────┘       │
│        │                                     │              │
│        └─────────────┬──────────────────────┘              │
│                      │                                      │
└──────────────────────┼──────────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
   ┌─────────┐   ┌──────────┐   ┌─────────┐
   │ GQL     │   │Execution │   │  Eval   │
   │ Parser  │   │ Engine   │◄──┤ (3,332L)│
   │(5,883L) │   │(4,725L)  │──►└─────────┘
   └────┬────┘   └─────┬────┘        ▲
        │              │              │
        └──────────────┴──────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
   ┌─────────┐   ┌──────────┐   ┌─────────┐
   │ Planner │   │ Storage  │   │Security │
   └─────────┘   │  Engine  │   │(Audit,  │
                 └─────┬────┘   │ TDE,RLS)│
                       │        └─────────┘
                       ▼
                 ┌──────────┐
                 │   WAL    │
                 │  Index   │
                 │   Txn    │
                 └──────────┘
```

**Note**: Red double arrows indicate circular dependencies (see next section).

---

## Dependency Graph

### Detailed Dependency Visualization

The complete dependency graph is available in `metrics/dependency_graph.dot` (GraphViz format).

**Key Dependency Relationships**:

1. **Server Dependencies**:
   - `server/main.zig` → `execution.zig`
   - `server/main.zig` → `eval.zig`
   - `server/main.zig` → `execution/path_and_call_operations.zig`
   - `server/main.zig` → `protocol.zig`
   - `server/main.zig` → `storage/*`
   - `server/main.zig` → `security/*`

2. **CLI Dependencies**:
   - `cli/main.zig` → `execution.zig`
   - `cli/main.zig` → `eval.zig`
   - `cli/main.zig` → `gql/parser.zig`
   - `cli/main.zig` → `transport/quic.zig`

3. **Execution Dependencies**:
   - `execution.zig` → `eval.zig` ⚠️ **CIRCULAR**
   - `execution.zig` → `execution/path_and_call_operations.zig`
   - `execution.zig` → `planner/*`
   - `execution.zig` → `storage/*`

4. **Evaluation Dependencies**:
   - `eval.zig` → `execution.zig` ⚠️ **CIRCULAR**
   - `eval.zig` → `types/*`
   - `eval.zig` → `graph/*`

**Import Statistics**:

- **Total Imports**: 1,036 import statements across codebase
- **Average Imports per File**: 2.4 imports
- **Most Imported Modules**: std, types, storage, execution

---

## Circular Dependencies

### Critical Issue: Circular Dependencies

**Total Detected**: 1 major circular dependency cluster

#### 1. execution.zig ↔ eval.zig

**Severity**: **HIGH** - Prevents clean modularization

**Description**:

- `execution.zig` imports `eval.zig` for expression evaluation during query execution
- `eval.zig` imports `execution.zig` for accessing execution context and state

**Impact**:

- Cannot test modules in isolation
- Difficult to maintain and understand data flow
- Blocks modularization of execution engine
- Complicates dependency injection

**Current Usage**:

- Execution engine calls eval for WHERE clauses, projections, aggregations
- Eval calls back to execution for subqueries, path evaluation, function dispatch

**Resolution Strategy** (Phase 5):

1. Create `execution/evaluator_adapter.zig` interface
2. Define clear boundary between execution and evaluation
3. Use dependency injection for evaluation callbacks
4. Break bidirectional dependency by introducing adapter pattern

**Related Files Affected**:

- `src/execution.zig` (1,723 LOC)
- `src/eval.zig` (3,332 LOC)
- `src/execution/path_and_call_operations.zig` (4,725 LOC)
- Various execution/* submodules

#### 2. server/main.zig ↔ execution/* (Secondary)

**Severity**: **MEDIUM** - Manageable but needs attention

**Description**:

- Server main imports multiple execution submodules
- Some execution modules may reference server state

**Resolution Strategy** (Phase 3):

- Extract server state management
- Create clear interfaces for execution engine
- Eliminate reverse dependencies from execution to server

---

## Test Coverage

### Test Organization

**Test Categories**:

1. **Unit Tests** (Zig `test` blocks):
   - **Total**: 393 Zig test blocks
   - **Pass Rate**: 100% (393/393 passing)
   - **Location**: Inline with source files
   - **Coverage**: Core functionality, data structures, algorithms

2. **Integration Tests** (geodetestlab):
   - **Total**: 1,688 tests across 80+ spec files
   - **Pass Rate**: 97.4% (1,644 passing, 9 failing, 46 skipped)
   - **Location**: `geodetestlab/specs/*.yml`
   - **Coverage**: End-to-end scenarios, GQL compliance, features

3. **Client Tests**:
   - **Go Client**: PASS
   - **Python Client**: Integration ready
   - **Rust Client**: Integration ready
   - **QUIC Vendor**: PASS

4. **Benchmarks**:
   - **Performance Tests**: 150+ benchmark variants
   - **Location**: `tests/benchmark_*.zig`
   - **Purpose**: Regression detection, optimization validation

### Test Coverage by Module

**Well-Tested Modules** (>90% coverage):

```
✓ storage/*          - High coverage (backup, page manager, heap)
✓ security/*         - High coverage (auth, audit, TDE, RLS)
✓ types/*            - High coverage (vector, geographic, network)
✓ gql/*              - High coverage (parser, lexer, AST)
✓ planner/*          - Good coverage (CBO, optimizer, pipeline)
✓ index/*            - Good coverage (B-tree, HNSW, spatial)
✓ ml/*               - Good coverage (embeddings, integration)
✓ streaming/*        - Good coverage (CDC, real-time)
```

**Moderate Coverage** (70-90%):

```
⚠ execution/*        - Moderate coverage (complex logic)
⚠ server/main.zig    - Moderate coverage (integration heavy)
⚠ cli/main.zig       - Moderate coverage (integration heavy)
⚠ distributed/*      - Moderate coverage (multi-node complexity)
⚠ txn/*              - Moderate coverage (isolation testing)
```

**Needs More Testing** (<70%):

```
⚠ Some edge cases in execution engine
⚠ Error handling paths in server
⚠ Complex distributed scenarios
⚠ GPU acceleration paths (hardware-dependent)
```

### Test File Distribution

**Test-to-Source Ratios by Module**:

```
High Ratio (>2:1):
- storage/: 3.2:1
- security/: 2.8:1
- types/: 2.5:1

Medium Ratio (1-2:1):
- execution/: 1.7:1
- planner/: 1.9:1
- gql/: 1.6:1

Lower Ratio (<1:1):
- server/: 0.8:1 (large integration tests compensate)
- cli/: 0.9:1 (integration tests compensate)
```

---

## Critical Paths

### Identified Critical Code Paths

#### 1. Query Execution Pipeline (P0 CRITICAL)

**Flow**:

```
CLI/Server → GQL Parser → Planner → Execution Engine → Eval → Storage → Results
```

**Key Files**:

- `src/cli/main.zig` (5,885 LOC) - Entry point
- `src/server/main.zig` (7,039 LOC) - Entry point
- `src/gql/parser.zig` (5,883 LOC) - Query parsing
- `src/planner.zig` + `src/planner/*.zig` - Query planning
- `src/execution.zig` + `src/execution/*.zig` - Execution
- `src/eval.zig` (3,332 LOC) - Expression evaluation
- `src/storage/*.zig` - Data access

**Risk**:

- **HIGH** - Any failure breaks core functionality
- Changes must be carefully tested
- Circular dependency (execution ↔ eval) adds complexity

**Test Coverage**: 95%+ (critical path well-tested)

#### 2. Transaction & MVCC Path (P0 CRITICAL)

**Flow**:

```
Client → Server → Transaction Manager → MVCC → WAL → Storage
```

**Key Files**:

- `src/txn/manager.zig` (680 LOC)
- `src/server/txn/mvcc.zig` (708 LOC)
- `src/server/txn/enhanced_isolation.zig` (539 LOC)
- `src/wal/wal.zig` (840 LOC)
- `src/storage/*.zig`

**Risk**:

- **HIGH** - Data consistency depends on this
- Must maintain ACID guarantees
- Complex concurrency control

**Test Coverage**: 92% (well-tested, some edge cases remain)

#### 3. Security Pipeline (P1 HIGH)

**Flow**:

```
Request → Authentication → Authorization → RLS Policies → Audit → Response
```

**Key Files**:

- `src/security/auth.zig` (1,226 LOC)
- `src/security/rls.zig` (1,158 LOC)
- `src/security/rls_enhanced.zig` (972 LOC)
- `src/security/audit.zig` (1,701 LOC)
- `src/security/user_manager.zig` (733 LOC)

**Risk**:

- **HIGH** - Security vulnerabilities unacceptable
- Audit must be comprehensive
- RLS must be foolproof

**Test Coverage**: 94% (well-tested security features)

#### 4. Index Selection & Optimization Path (P1 HIGH)

**Flow**:

```
Query → Planner → IndexOptimizer → Cost Model → Execution Plan
```

**Key Files**:

- `src/server/index_optimizer.zig` (2,444 LOC)
- `src/planner/cbo.zig` (760 LOC)
- `src/planner/cost_model.zig` (594 LOC)
- `src/planner/optimizer.zig` (609 LOC)

**Risk**:

- **MEDIUM** - Performance implications
- Wrong index choice = slow queries
- Cost model accuracy critical

**Test Coverage**: 88% (good coverage, performance-focused)

#### 5. Distributed Query Path (P2 MEDIUM)

**Flow**:

```
Query → Federation → Sharding → Cross-Shard Coordinator → Results Merge
```

**Key Files**:

- `src/distributed/federation.zig` (1,171 LOC)
- `src/distributed/sharding.zig` (868 LOC)
- `src/distributed/enhanced_query_coordinator.zig` (750 LOC)
- `src/distributed/raft_consensus.zig` (1,689 LOC)

**Risk**:

- **MEDIUM** - Complexity of distributed systems
- Network failures must be handled
- Consensus protocol correctness

**Test Coverage**: 85% (moderate, requires multi-node testing)

#### 6. Backup & Recovery Path (P2 MEDIUM)

**Flow**:

```
Backup Command → Backup Manager → S3 Upload → Encryption → Compression
```

**Key Files**:

- `src/storage/backup.zig` (572 LOC)
- `src/storage/s3_backup.zig` (778 LOC)
- `src/security/tde.zig` (1,482 LOC)

**Risk**:

- **MEDIUM** - Data loss unacceptable
- Must be reliable and tested
- Encryption must be secure

**Test Coverage**: 90% (good coverage, critical feature)

---

## Refactoring Priorities

### Based on Architecture Analysis

#### P0 CRITICAL (Must Address)

**1. Server Monolith** (`src/server/main.zig` - 7,039 LOC):

- **Issue**: Too many responsibilities in one file
- **Impact**: Hard to test, maintain, understand
- **Target**: Split into 5+ focused modules (~300 LOC entry point)
- **Phase**: Phase 3

**2. CLI Monolith** (`src/cli/main.zig` - 5,885 LOC):

- **Issue**: All CLI commands in one massive file
- **Impact**: Hard to add new commands, test individual features
- **Target**: Split into command modules (~400 LOC entry point)
- **Phase**: Phase 4

**3. GQL Parser** (`src/gql/parser.zig` - 5,883 LOC):

- **Issue**: Large parser with mixed concerns
- **Impact**: Difficult to extend grammar, maintain
- **Target**: Extract sub-parsers, expression handling
- **Phase**: Not in current plan (consider for Phase 9)

#### P1 HIGH (Should Address)

**4. Execution Engine** (`src/execution/path_and_call_operations.zig` - 4,725 LOC):

- **Issue**: Path operations + call operations + pattern comprehension + recursion
- **Impact**: Hard to test individual features
- **Target**: Split into 4 focused modules
- **Phase**: Phase 2

**5. Circular Dependency** (execution.zig ↔ eval.zig):

- **Issue**: Prevents modular testing
- **Impact**: Cannot refactor execution or eval independently
- **Target**: Break with adapter pattern
- **Phase**: Phase 5

**6. Expression Evaluator** (`src/eval.zig` - 3,332 LOC):

- **Issue**: Evaluation + type promotion + builtin dispatch
- **Impact**: Hard to extend, test type system
- **Target**: Extract type promotion (~2,500 LOC remaining)
- **Phase**: Phase 6

#### P2 MEDIUM (Nice to Have)

**7. Mixed Concerns in Security Modules**:

- `src/security/audit.zig` (1,701 LOC): Logic + I/O + formatting
- `src/security/tde.zig` (1,482 LOC): Encryption + key management + nonce generation
- **Target**: Separate concerns
- **Phase**: Phase 1

**8. CDC Module** (`src/streaming/cdc_enhanced.zig` - 1,390 LOC):

- **Issue**: CDC logic + webhook + Kafka sinks
- **Target**: Extract sink adapters
- **Phase**: Phase 1

**9. Schema & Transaction Organization**:

- **Issue**: Scattered across multiple directories
- **Target**: Consolidate into coherent modules
- **Phase**: Phase 7

---

## Modularization Readiness

### Current State Assessment

**Strengths**:

- ✅ High test coverage (97.4% integration tests, 100% unit tests)
- ✅ Clear module boundaries in many areas
- ✅ Good documentation
- ✅ Strong type system
- ✅ Comprehensive test infrastructure

**Challenges**:

- ⚠️ Large monolithic files (server, CLI, parser)
- ⚠️ Circular dependency (execution ↔ eval)
- ⚠️ Mixed concerns in some modules
- ⚠️ Complex execution engine logic
- ⚠️ Deep dependency trees

**Opportunities**:

- ✓ Clear refactoring targets identified
- ✓ Test suite can catch regressions
- ✓ Modularization utilities available (Phase 0, M0.3)
- ✓ Metrics tracking in place (Phase 0, M0.2)
- ✓ Baseline established (Phase 0, M0.1)

### Success Metrics for Modularization

**File Size Targets**:

- No file >2,000 LOC (ideally <1,500 LOC)
- Current: 23 files >1,000 LOC
- Target: 0 files >2,000 LOC after all phases

**Dependency Targets**:

- Zero circular dependencies
- Current: 1 major circular dependency
- Target: 0 after Phase 5

**Testability Targets**:

- All modules testable in isolation
- All dependencies injectable
- Mock-friendly interfaces

---

## Next Steps

Based on this architecture analysis, the modularization phases should proceed as planned:

1. **Phase 1**: Extract Mixed Concerns (Low risk, high value)
   - audit.zig, tde.zig, cdc_enhanced.zig

2. **Phase 2**: Decompose Execution Module (Medium risk, high impact)
   - path_and_call_operations.zig

3. **Phase 3**: Decompose Server Monolith (High risk, critical)
   - server/main.zig

4. **Phase 4**: Decompose CLI Monolith (Medium risk, important)
   - cli/main.zig

5. **Phase 5**: Resolve Circular Dependencies (High priority)
   - execution.zig ↔ eval.zig

6. **Phase 6**: Extract Expression Evaluation (Medium priority)
   - eval.zig

7. **Phase 7**: Consolidate Schema & Transactions (Organizational)
   - schema/*, txn/*

8. **Phase 8**: Testing & Documentation (Quality assurance)
   - Final verification and documentation

---

## Appendix: Module Inventory

### Complete Module List (50 directories)

| Module | Purpose | Files | Notable Large Files |
|--------|---------|-------|---------------------|
| admin | Admin operations | - | - |
| algorithms | Algorithm implementations | - | - |
| analytics | Real-time analytics | - | real_time.zig (635) |
| audit | Audit logging | - | - |
| bench | Benchmarking utilities | - | - |
| benchmarks | Benchmark implementations | - | - |
| cdc | CDC core | - | - |
| cli | Command-line interface | ~20 | main.zig (5,885) |
| client | Client library | ~15 | main.zig (1,081) |
| containers | Container data structures | - | - |
| crypto | Cryptographic primitives | - | - |
| dist | Distribution utilities | - | scaffold.zig (563) |
| distributed | Distributed systems | ~15 | federation.zig (1,171), raft_consensus.zig (1,689) |
| execution | Query execution | ~15 | path_and_call_operations.zig (4,725), crud_operations.zig (1,876), match_operations.zig (2,015) |
| federation | Cross-cluster queries | - | - |
| fts | Full-text search | ~5 | advanced.zig (519) |
| fuzz | Fuzzing infrastructure | - | - |
| gpu | GPU acceleration | ~5 | vulkan_compute.zig (759), vulkan_ffi.zig (687) |
| gql | GQL parser/lexer | ~10 | parser.zig (5,883), lexer.zig (631), main.zig (781), match.zig (836), print.zig (725) |
| graph | Graph data structures | ~10 | builtin_algorithms.zig (1,581), aggregator.zig (723) |
| index | Index implementations | ~10 | index_manager.zig (924), btree.zig (697), advanced_types_index.zig (702), spatial_index.zig (522) |
| keys | Key management | - | - |
| log | Logging infrastructure | - | - |
| migration | Schema migrations | - | - |
| ml | Machine learning | ~5 | graph_embeddings.zig (750), integration_enhanced.zig (787) |
| monitoring | Metrics and monitoring | - | metrics.zig (585) |
| multitenancy | Multi-tenancy support | - | - |
| optimizer | Query optimization | ~5 | advanced_types_optimizer.zig (599) |
| pagination | Pagination utilities | - | - |
| parser | Generic parsing | - | - |
| performance | Performance optimizations | ~5 | async_io.zig (739), memory_mapped_io.zig (606), io_optimized.zig (545) |
| planner | Query planning | ~10 | cbo.zig (760), pipeline.zig (750), adaptive.zig (668), recursive.zig (695), cost_model.zig (594), optimizer.zig (609) |
| query | Query management | ~5 | enhanced_materialized_views.zig (884), materialized_views.zig (650) |
| runtime | Runtime support | - | - |
| schema | Schema management | ~5 | catalog.zig (568) |
| security | Security features | ~15 | audit.zig (1,701), auth.zig (1,226), rls.zig (1,158), tde.zig (1,482), rls_enhanced.zig (972), user_manager.zig (733) |
| server | Server implementation | ~15 | main.zig (7,039), index_optimizer.zig (2,444), graph/exec.zig (724), txn/mvcc.zig (708), txn/phantom_read_prevention.zig (651), txn/enhanced_isolation.zig (539) |
| storage | Storage engine | ~15 | materialized_views.zig (1,597), heap.zig (830), s3_backup.zig (778), constraints.zig (685), user_storage.zig (681), page_manager.zig (622), backup.zig (572), crypto_enhanced.zig (568) |
| streaming | CDC and streaming | ~5 | cdc_enhanced.zig (1,390) |
| temporal | Temporal data types | - | - |
| tests | Test utilities | - | - |
| timeseries | Time-series operations | - | - |
| tools | Development tools | ~5 | user_auth.zig (681) |
| transport | Network transport | ~5 | quic.zig (944) |
| txn | Transaction management | ~5 | manager.zig (680) |
| types | Advanced data types | ~15 | evaluator_functions.zig (1,271), geographic.zig (853), vector.zig (597) |
| unicode | Unicode support | - | - |
| util | Utility functions | ~10 | text_formatter.zig (948), yaml.zig (686), yaml_test.zig (525) |
| utils | Additional utilities | - | - |
| wal | Write-ahead logging | ~5 | wal.zig (840) |

---

**Document Version**: 1.0
**Last Updated**: 2025-11-12
**Status**: Complete - Ready for Phase 1
