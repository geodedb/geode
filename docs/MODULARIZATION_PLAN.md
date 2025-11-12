# Geode Codebase Modularization Plan

**Status**: ACTIVE
**Created**: 2025-11-12
**Last Updated**: 2025-11-12
**Branch**: `claude/modularize-geode-codebase-011CV37UMkJQkniB6ARzFWkH`

## Executive Summary

This document outlines a comprehensive plan to modularize the Geode graph database codebase to improve testability, maintainability, and development velocity. The plan is structured in phases with clear agent-based milestones, allowing multiple agents to work concurrently or sequentially on different aspects of the modularization.

**Key Objectives**:
- Reduce file sizes and improve code organization
- Eliminate circular dependencies
- Separate concerns (logic from I/O, business logic from infrastructure)
- Maintain 97.4%+ test pass rate throughout the process
- Enable better unit testing and isolation
- Preserve all existing functionality

**Critical Constraints**:
- ✅ **Tests and builds MUST continue to function** at each milestone
- ✅ **ALL test failures MUST be fixed** - no matter how complex
- ✅ **NEVER mock responses** - only update tests if they are actually incorrect
- ✅ **NO shortcuts** - implement complex missing logic properly
- ✅ **Zero regression** - maintain or improve current 97.4% pass rate

## Current State Analysis

### Codebase Metrics (as of 2025-11-12)

**Overall Statistics**:
- **Total Source Files**: 400+ files across `/src/`
- **Total Test Files**: 400+ files across `/tests/`
- **Test Coverage**: 1644/1688 passing (97.4%)
- **Build Status**: ✅ 393/393 Zig tests passing
- **Major Modules**: 48 distinct modules

**Largest Files Requiring Modularization**:

| File | Lines | Issues | Priority |
|------|-------|--------|----------|
| `src/server/main.zig` | 7,039 | Server + Protocol + Query Exec + State Mgmt | **P0 CRITICAL** |
| `src/cli/main.zig` | 5,885 | CLI + User Mgmt + Auth + Backup | **P0 CRITICAL** |
| `src/execution/path_and_call_operations.zig` | 4,725 | Paths + Calls + Pattern Comprehension + Recursion | **P1 HIGH** |
| `src/eval.zig` | 3,332 | Evaluation + Type Coercion + Function Dispatch | **P1 HIGH** |
| `src/security/audit.zig` | 1,701 | Audit + I/O + CEF Formatting | **P2 MEDIUM** |
| `src/security/tde.zig` | 1,482 | Encryption + KMS + Hierarchy | **P2 MEDIUM** |

**Circular Dependencies** (Must Resolve):
- `execution.zig` ↔ `eval.zig` (HIGH PRIORITY)
- `server/main.zig` ↔ multiple `execution/*` submodules (HIGH PRIORITY)

**Mixed Concerns** (Separate Logic from I/O):
- `security/audit.zig`: Audit logic + File I/O + CEF formatting
- `streaming/cdc_enhanced.zig`: CDC logic + Webhook/Kafka sinks
- `security/tde.zig`: Encryption + Key management + KMS calls

### Build System Structure

**Build Configuration** (`build.zig`):
- Sophisticated module dependency injection
- Shared modules (e.g., `storage_page_manager`)
- Platform-specific configuration (Vulkan/CUDA paths)
- Multiple executables: `geode`, `gql`, test suites

**Critical Build Dependencies**:
- Root module (`lib.zig`) re-exports 60+ modules
- FLE (Field-Level Encryption) modules injected at build time
- Protocol module shared for test access

### Test Infrastructure

**Test Organization**:
- **Unit Tests**: Component-level tests within modules
- **Integration Tests**: Multi-component scenarios in `/tests/`
- **E2E Tests**: End-to-end scenarios (QUIC, protocol, ML)
- **Geodetestlab**: External test harness with 1688 test cases
- **Benchmarks**: Performance regression testing

**Testing Challenges**:
- Tests must run with isolated data directories
- Server/client coordination required for E2E tests
- Some tests have complex setup/teardown requirements
- Recent fixes to test runner (data directory isolation, flag injection)

## Modularization Goals & Principles

### Goals

1. **Improve Testability**
   - Enable isolated unit testing of individual components
   - Reduce test setup complexity
   - Support dependency injection for testing

2. **Reduce Coupling**
   - Eliminate circular dependencies
   - Create clear module boundaries
   - Define explicit interfaces between modules

3. **Separate Concerns**
   - Logic vs. I/O
   - Business logic vs. infrastructure
   - Protocol vs. implementation
   - Core vs. extensions

4. **Enable Concurrent Development**
   - Clear module ownership
   - Reduced merge conflicts
   - Independent testing of modules

5. **Maintain Performance**
   - No degradation in query performance
   - Preserve existing optimizations
   - Keep memory footprint stable

### Principles

**PRINCIPLE 1: Test-Driven Refactoring**
- Write tests for existing behavior BEFORE modularizing
- Run full test suite after each change
- Fix ALL failures immediately
- Never proceed with failing tests

**PRINCIPLE 2: Incremental Changes**
- Small, reviewable commits
- One logical change per commit
- Build and test after each commit
- Easy rollback if issues arise

**PRINCIPLE 3: No Mocking, Real Implementations**
- Implement complex missing logic properly
- Never simulate responses in test harness
- Fix root causes, not symptoms
- Maintain production-quality code

**PRINCIPLE 4: Documentation-Driven Development**
- Update documentation with each change
- Maintain architectural decision records
- Keep status document current
- Reference commit history

**PRINCIPLE 5: Preserve Functionality**
- Zero breaking changes to public APIs
- Maintain backward compatibility
- Preserve all enterprise features
- Keep GQL compliance at 98.6%+

## Phase-by-Phase Modularization Plan

Each phase is designed as an independent unit of work that can be picked up by an agent. Phases can be executed sequentially or in parallel where dependencies allow.

---

### Phase 0: Foundation & Preparation

**Status**: PENDING
**Estimated Effort**: 4-6 hours
**Dependencies**: None
**Agent Assignment**: Any agent

**Objectives**:
- Set up modularization infrastructure
- Create baseline tests
- Establish metrics tracking

**Tasks**:

1. **Create Baseline Test Suite** (1-2 hours)
   - Capture current test results: `python3 extended_test_runner.py > baseline_tests.log`
   - Document all 1644 passing tests
   - Document all 9 failing tests with detailed failure modes
   - Create test comparison script
   - **Success Criteria**: Baseline captured, comparison script works

2. **Set Up Metrics Dashboard** (1 hour)
   - Create script to measure module sizes
   - Track import dependencies
   - Monitor test pass rates
   - Generate dependency graph
   - **Success Criteria**: Metrics script produces reports

3. **Create Test Utilities** (1-2 hours)
   - Build test isolation helpers
   - Create module testing framework
   - Add dependency injection utilities
   - **Success Criteria**: Utilities work with sample modules

4. **Document Current Architecture** (1-2 hours)
   - Generate module dependency graph
   - Document all circular dependencies
   - Map test coverage by module
   - Identify critical paths
   - **Success Criteria**: Architecture diagrams complete

**Verification**:
```bash
# Run baseline tests
python3 extended_test_runner.py
# Expected: 1644 passing, 9 failing

# Generate metrics
./scripts/modularization/generate_metrics.sh
# Expected: Module sizes, dependency graph, test coverage

# Build verification
make verify-all
# Expected: 393/393 Zig tests passing
```

**Deliverables**:
- `baseline_tests.log` - Complete test results
- `scripts/modularization/` - Metrics and testing utilities
- `docs/architecture/dependency_graph.dot` - Visual dependency map
- Updated `MODULARIZATION_STATUS.md`

---

### Phase 1: Extract Mixed Concerns (Low Risk)

**Status**: PENDING
**Estimated Effort**: 8-12 hours
**Dependencies**: Phase 0
**Agent Assignment**: Any agent with security/streaming knowledge

**Objectives**:
- Separate logic from I/O in audit, CDC, TDE modules
- Create clean interfaces between concerns
- Maintain all existing functionality

**Priority**: P2 MEDIUM (Low risk, high value)

#### Milestone 1.1: Extract Audit Formatting (2-3 hours)

**Current State**:
- `src/security/audit.zig`: 1,701 lines (audit logic + file I/O + CEF formatting)

**Target State**:
```
src/security/
├── audit.zig (~1,200 lines) - Core audit logic
├── audit_formatter.zig (~300 lines) - CEF formatting
└── audit_sink.zig (~200 lines) - I/O abstraction
```

**Tasks**:
1. Create `src/security/audit_formatter.zig`
   - Move CEF formatting functions
   - Define clear interface: `formatAuditEvent(event: AuditEvent) -> []const u8`
   - Add unit tests for formatting logic

2. Create `src/security/audit_sink.zig`
   - Abstract file I/O operations
   - Define interface: `writeToDisk()`, `writeToDatabase()`, `writeToSyslog()`
   - Enable dependency injection for testing

3. Refactor `src/security/audit.zig`
   - Use new formatter module
   - Use sink abstraction
   - Remove direct I/O calls
   - Update tests

4. Update build system
   - Add new modules to `build.zig`
   - Update import paths
   - Verify all tests pass

**Verification**:
```bash
# Build
make build
# Expected: Success, no errors

# Run audit tests
zig build test --summary all | grep audit
# Expected: All audit tests passing

# Run full test suite
python3 extended_test_runner.py
# Expected: 1644+ passing (same or better)

# Check module size
wc -l src/security/audit*.zig
# Expected: audit.zig reduced to ~1200 lines
```

**Rollback Plan**:
- Git revert if tests fail
- Keep original audit.zig as audit_legacy.zig temporarily

**Deliverables**:
- `src/security/audit_formatter.zig`
- `src/security/audit_sink.zig`
- Updated `src/security/audit.zig`
- Updated `build.zig`
- Test results showing no regression

#### Milestone 1.2: Extract CDC Sink Adapters (2-3 hours)

**Current State**:
- `src/streaming/cdc_enhanced.zig`: 1,390 lines (CDC logic + webhook sinks + Kafka adapters)

**Target State**:
```
src/streaming/
├── cdc_enhanced.zig (~800 lines) - Core CDC logic
├── cdc_sinks.zig (~400 lines) - Sink interface
└── sinks/
    ├── webhook_sink.zig (~100 lines)
    └── kafka_sink.zig (~90 lines)
```

**Tasks**:
1. Create `src/streaming/cdc_sinks.zig`
   - Define `SinkInterface` trait
   - Abstract common sink operations
   - Add sink registry

2. Create `src/streaming/sinks/webhook_sink.zig`
   - Move webhook-specific code
   - Implement `SinkInterface`
   - Add HTTP client abstraction

3. Create `src/streaming/sinks/kafka_sink.zig`
   - Move Kafka-specific code
   - Implement `SinkInterface`
   - Add Kafka client abstraction

4. Refactor `src/streaming/cdc_enhanced.zig`
   - Use sink interface
   - Remove direct sink implementations
   - Update tests

**Verification**:
```bash
make build && make verify-all
python3 extended_test_runner.py
# Expected: All tests passing, CDC functionality intact
```

**Deliverables**:
- Sink abstraction modules
- Updated CDC core
- Test results

#### Milestone 1.3: Extract TDE Key Management (3-4 hours)

**Current State**:
- `src/security/tde.zig`: 1,482 lines (encryption + KMS + hierarchy)

**Target State**:
```
src/security/
├── tde.zig (~800 lines) - Core encryption
├── tde_key_manager.zig (~400 lines) - Key derivation & hierarchy
└── tde_nonce_gen.zig (~200 lines) - Nonce generation
```

**Tasks**:
1. Create `src/security/tde_key_manager.zig`
   - Move key hierarchy logic
   - Move key derivation functions
   - Define clear interface

2. Create `src/security/tde_nonce_gen.zig`
   - Move nonce generation
   - Add deterministic and random modes
   - Ensure cryptographic safety

3. Refactor `src/security/tde.zig`
   - Use key manager interface
   - Use nonce generator
   - Simplify main encryption logic

4. Update all tests
   - Ensure TDE tests pass
   - Add unit tests for key manager
   - Add unit tests for nonce generator

**Verification**:
```bash
make build && zig build test --summary all | grep tde
python3 extended_test_runner.py | grep -i encrypt
# Expected: All encryption tests passing
```

**Deliverables**:
- TDE key management modules
- Updated encryption core
- Comprehensive test coverage

**Phase 1 Completion Criteria**:
- ✅ All 3 milestones complete
- ✅ Build passes: `make verify-all`
- ✅ Test pass rate: ≥97.4% (1644+ tests)
- ✅ No new circular dependencies
- ✅ Code reduction: ~800 lines across 3 modules
- ✅ Documentation updated in `MODULARIZATION_STATUS.md`

---

### Phase 2: Decompose Large Execution Module (Medium Risk)

**Status**: PENDING
**Estimated Effort**: 12-16 hours
**Dependencies**: Phase 0
**Agent Assignment**: Agent with execution engine expertise

**Objectives**:
- Split `path_and_call_operations.zig` (4,725 lines) into focused modules
- Maintain all graph traversal and pattern matching functionality
- Improve testability of execution components

**Priority**: P1 HIGH (Large impact, moderate risk)

#### Milestone 2.1: Extract Recursion Handler (3-4 hours)

**Current State**:
- `src/execution/path_and_call_operations.zig`: 4,725 lines

**Target State**:
```
src/execution/
├── path_and_call_operations.zig (~3,500 lines) - Facade (temporary)
└── recursion_handler.zig (~225 lines) - Recursive query logic
```

**Tasks**:
1. Identify all recursion-related functions in `path_and_call_operations.zig`
   - Search for recursive calls
   - Find depth tracking logic
   - Identify cycle detection

2. Create `src/execution/recursion_handler.zig`
   - Extract recursion control flow
   - Add clear interface
   - Add unit tests

3. Update `path_and_call_operations.zig`
   - Import and use recursion handler
   - Remove extracted code
   - Maintain compatibility

4. Test thoroughly
   - Run recursion-specific tests
   - Test with complex nested queries
   - Verify performance

**Verification**:
```bash
# Test recursive queries
./zig-out/bin/geode query "MATCH (a)-[*1..5]->(b) RETURN a, b"
# Expected: Works correctly

# Run full test suite
python3 extended_test_runner.py | grep -i recurs
# Expected: All recursion tests passing
```

**Deliverables**:
- `src/execution/recursion_handler.zig`
- Updated `path_and_call_operations.zig`
- Test results

#### Milestone 2.2: Extract Pattern Comprehension (3-4 hours)

**Target State**:
```
src/execution/
├── path_and_call_operations.zig (~2,500 lines)
├── recursion_handler.zig (~225 lines)
└── pattern_comprehension.zig (~1,000 lines)
```

**Tasks**:
1. Identify pattern comprehension logic
   - Pattern matching code
   - Comprehension syntax handling
   - List/map comprehensions

2. Create `src/execution/pattern_comprehension.zig`
   - Extract pattern matching
   - Define clear interface
   - Add comprehensive tests

3. Update `path_and_call_operations.zig`
   - Use pattern comprehension module
   - Remove extracted code

**Verification**:
```bash
# Test pattern comprehension
./zig-out/bin/geode query "RETURN [x IN [1,2,3] WHERE x > 1 | x * 2]"
# Expected: [4, 6]

python3 extended_test_runner.py | grep -i pattern
# Expected: All pattern tests passing
```

#### Milestone 2.3: Split Path and Call Operations (4-6 hours)

**Target State**:
```
src/execution/
├── path_operations.zig (~1,200 lines) - Path traversal logic
├── call_operations.zig (~1,300 lines) - Function call logic
├── recursion_handler.zig (~225 lines)
└── pattern_comprehension.zig (~1,000 lines)
```

**Tasks**:
1. Create `src/execution/path_operations.zig`
   - Extract path pattern matching
   - Extract path traversal logic
   - Add path-specific tests

2. Create `src/execution/call_operations.zig`
   - Extract function call handling
   - Extract procedure calls
   - Add call-specific tests

3. Remove old `path_and_call_operations.zig`
   - Ensure all code migrated
   - Update all imports
   - Update build system

4. Create new facade if needed
   - Re-export from new modules
   - Maintain backward compatibility

**Verification**:
```bash
make build && make verify-all
python3 extended_test_runner.py
# Expected: 1644+ tests passing, no regressions
```

**Phase 2 Completion Criteria**:
- ✅ 4,725-line file split into 4 focused modules
- ✅ All execution tests passing
- ✅ No performance degradation
- ✅ Clear separation of concerns
- ✅ Build system updated
- ✅ Documentation complete

---

### Phase 3: Decompose Server Monolith (High Risk)

**Status**: PENDING
**Estimated Effort**: 16-24 hours
**Dependencies**: Phase 0, Phase 2 (recommended)
**Agent Assignment**: Agent with server/protocol expertise

**Objectives**:
- Split `server/main.zig` (7,039 lines) into focused components
- Separate protocol handling from query execution
- Improve testability of server components

**Priority**: P0 CRITICAL (Highest impact, highest risk)

**⚠️ CRITICAL WARNINGS**:
- This is the most complex refactoring
- Server is the core of the system
- Extra caution required
- Incremental approach mandatory
- Test after every change

#### Milestone 3.1: Extract Server State Management (4-5 hours)

**Current State**:
- `src/server/main.zig`: 7,039 lines (everything)

**Target State**:
```
src/server/
├── main.zig (~5,500 lines) - Reduced but still large
└── server_state.zig (~1,500 lines) - State management
```

**Tasks**:
1. Identify all state management code
   - Connection tracking
   - Session management
   - State initialization
   - Cleanup logic

2. Create `src/server/server_state.zig`
   - Define `ServerState` struct
   - Extract state operations
   - Add state mutation methods
   - Define clear interface

3. Update `server/main.zig`
   - Use `ServerState` module
   - Remove extracted code
   - Maintain same behavior

4. Add state-specific tests
   - Test state initialization
   - Test state transitions
   - Test cleanup

**Verification**:
```bash
# Start server
./zig-out/bin/geode serve --listen 0.0.0.0:3141 &
SERVER_PID=$!

# Test connection
./zig-out/bin/geode query "RETURN 1"
# Expected: {"result": 1}

# Cleanup
kill $SERVER_PID

# Full tests
python3 extended_test_runner.py
# Expected: All server tests passing
```

#### Milestone 3.2: Extract Protocol Handler (5-6 hours)

**Target State**:
```
src/server/
├── main.zig (~4,000 lines)
├── server_state.zig (~1,500 lines)
└── protocol_handler.zig (~1,500 lines) - QUIC/message handling
```

**Tasks**:
1. Identify protocol handling code
   - QUIC connection handling
   - Message parsing
   - Response formatting
   - Error handling

2. Create `src/server/protocol_handler.zig`
   - Extract protocol logic
   - Define `ProtocolHandler` interface
   - Support dependency injection
   - Add protocol tests

3. Update `server/main.zig`
   - Use protocol handler
   - Remove extracted code
   - Maintain compatibility

**Verification**:
```bash
# Test QUIC connections
python3 clients/test-harness/test_python_connection.py
# Expected: Connection successful

# Test protocol compliance
make test-protocol
# Expected: All protocol tests passing
```

#### Milestone 3.3: Extract Query Executor (5-7 hours)

**Target State**:
```
src/server/
├── main.zig (~300 lines) - Entry point and coordination
├── server_state.zig (~1,500 lines)
├── protocol_handler.zig (~1,500 lines)
└── query_executor.zig (~2,500 lines) - Query execution
```

**Tasks**:
1. Identify query execution code
   - Query parsing coordination
   - Execution pipeline
   - Result formatting
   - Transaction management

2. Create `src/server/query_executor.zig`
   - Extract execution coordination
   - Define executor interface
   - Support transaction isolation
   - Add execution tests

3. Update `server/main.zig` to be a facade
   - Coordinate between components
   - Handle server lifecycle
   - ~300 lines of glue code

4. Extract backup manager (already identified at ~639 lines)
   - Create `src/server/backup_manager.zig`
   - Handle backup operations
   - Integrate with S3

**Verification**:
```bash
# Test query execution
./zig-out/bin/geode query "MATCH (n) RETURN count(n)"
./zig-out/bin/geode query "CREATE (n:Test) RETURN n"

# Test transactions
./zig-out/bin/geode query "BEGIN TRANSACTION; CREATE (n); COMMIT;"

# Full test suite
python3 extended_test_runner.py
# Expected: 1644+ tests passing
```

**Phase 3 Completion Criteria**:
- ✅ 7,039-line file split into 5 focused modules
- ✅ Server starts and accepts connections
- ✅ All queries execute correctly
- ✅ All server tests passing
- ✅ No performance degradation
- ✅ Clear component boundaries
- ✅ Improved testability

---

### Phase 4: Decompose CLI Monolith (Medium Risk)

**Status**: PENDING
**Estimated Effort**: 12-16 hours
**Dependencies**: Phase 0
**Agent Assignment**: Agent with CLI/user management expertise

**Objectives**:
- Split `cli/main.zig` (5,885 lines) into focused modules
- Separate command dispatch from implementations
- Improve CLI testability

**Priority**: P0 CRITICAL (High impact, moderate risk)

#### Milestone 4.1: Extract User Management Commands (3-4 hours)

**Current State**:
- `src/cli/main.zig`: 5,885 lines

**Target State**:
```
src/cli/
├── main.zig (~4,500 lines)
└── user_mgmt_cli.zig (~700 lines) - User/role commands
```

**Tasks**:
1. Extract user management commands
   - `cmdUser()` function
   - `cmdRole()` function
   - User CRUD operations
   - Help text

2. Create `src/cli/user_mgmt_cli.zig`
   - Move user commands
   - Define command interface
   - Add CLI tests

3. Update `cli/main.zig`
   - Import and delegate to user_mgmt_cli
   - Remove extracted code

**Verification**:
```bash
# Test user commands
./zig-out/bin/geode user create testuser test@example.com --password test123
./zig-out/bin/geode user list
./zig-out/bin/geode user delete testuser

# Test help
./zig-out/bin/geode user --help
./zig-out/bin/geode role --help

# Full tests
python3 extended_test_runner.py | grep -i user
# Expected: All user management tests passing
```

#### Milestone 4.2: Extract Auth Commands (2-3 hours)

**Target State**:
```
src/cli/
├── main.zig (~3,800 lines)
├── user_mgmt_cli.zig (~700 lines)
└── auth_cli.zig (~700 lines) - Auth/policy commands
```

**Tasks**:
1. Extract authentication commands
   - Policy management
   - Authentication operations
   - Permission handling

2. Create `src/cli/auth_cli.zig`
   - Move auth commands
   - Define command interface

3. Update `cli/main.zig`
   - Delegate to auth_cli
   - Remove extracted code

**Verification**:
```bash
./zig-out/bin/geode policy create test-policy
./zig-out/bin/geode grant test-policy --to testuser

python3 extended_test_runner.py | grep -i auth
# Expected: All auth tests passing
```

#### Milestone 4.3: Extract Backup Commands (2-3 hours)

**Target State**:
```
src/cli/
├── main.zig (~3,100 lines)
├── user_mgmt_cli.zig (~700 lines)
├── auth_cli.zig (~700 lines)
└── backup_cli.zig (~700 lines) - Backup/restore
```

**Tasks**:
1. Extract backup commands
   - `cmdBackup()` function
   - Backup operations
   - Restore operations

2. Create `src/cli/backup_cli.zig`
   - Move backup commands
   - Define interface

**Verification**:
```bash
./zig-out/bin/geode backup create test-backup
./zig-out/bin/geode backup list
```

#### Milestone 4.4: Create CLI Dispatcher (4-6 hours)

**Target State**:
```
src/cli/
├── main.zig (~400 lines) - Entry point
├── cli_dispatcher.zig (~2,000 lines) - Command routing
├── user_mgmt_cli.zig (~700 lines)
├── auth_cli.zig (~700 lines)
└── backup_cli.zig (~700 lines)
```

**Tasks**:
1. Create `src/cli/cli_dispatcher.zig`
   - Extract command routing logic
   - Flag parsing
   - Help system
   - Error handling

2. Update `cli/main.zig` to minimal entry point
   - Parse global flags
   - Dispatch to appropriate handler
   - ~400 lines of coordination

**Verification**:
```bash
# Test all CLI commands
./zig-out/bin/geode --help
./zig-out/bin/geode serve --help
./zig-out/bin/geode shell --help
./zig-out/bin/geode query --help

make verify-all
python3 extended_test_runner.py
# Expected: 1644+ tests passing
```

**Phase 4 Completion Criteria**:
- ✅ 5,885-line file split into 5 focused modules
- ✅ All CLI commands work
- ✅ Help text correct
- ✅ All CLI tests passing
- ✅ Clear command organization

---

### Phase 5: Resolve Circular Dependencies (High Risk)

**Status**: PENDING
**Estimated Effort**: 8-12 hours
**Dependencies**: Phase 0, Phase 2
**Agent Assignment**: Agent with architecture expertise

**Objectives**:
- Eliminate `execution.zig` ↔ `eval.zig` circular dependency
- Create clean dependency flow
- Maintain all functionality

**Priority**: P1 HIGH (Critical architectural issue)

**⚠️ WARNING**: This requires careful architectural planning

#### Milestone 5.1: Analyze Circular Dependency (2-3 hours)

**Tasks**:
1. Map all dependencies between `execution.zig` and `eval.zig`
   - Find all import statements
   - Identify bidirectional calls
   - Document dependency reasons

2. Create dependency diagram
   - Visualize current circular flow
   - Identify break points
   - Design new architecture

3. Propose solution architecture
   - Document in ADR (Architecture Decision Record)
   - Get architectural review
   - Plan implementation steps

**Deliverables**:
- `docs/architecture/execution_eval_dependency_analysis.md`
- `docs/architecture/ADR_execution_eval_refactor.md`
- Dependency diagrams

#### Milestone 5.2: Create Evaluator Adapter (3-4 hours)

**Target State**:
```
src/
├── execution.zig (imports eval via adapter)
├── eval.zig (no import of execution)
└── execution/
    └── evaluator_adapter.zig (bridge interface)
```

**Tasks**:
1. Create `src/execution/evaluator_adapter.zig`
   - Define interface for execution → eval calls
   - Implement adapter pattern
   - Support dependency injection

2. Update `execution.zig`
   - Use adapter instead of direct eval import
   - Remove bidirectional dependency

3. Update `eval.zig`
   - Remove any execution.zig imports
   - Use callbacks where needed

**Verification**:
```bash
# Check for circular dependencies
python3 scripts/modularization/check_circular_deps.py
# Expected: No circular dependencies found

make build && make verify-all
# Expected: All tests passing
```

#### Milestone 5.3: Extract Builtin Function Dispatcher (3-5 hours)

**Target State**:
```
src/
├── eval.zig (~2,500 lines)
└── eval/
    └── builtin_dispatcher.zig (~800 lines)
```

**Tasks**:
1. Create function registry pattern
   - Define `BuiltinFunction` interface
   - Create function registry
   - Support runtime registration

2. Create `src/eval/builtin_dispatcher.zig`
   - Extract function dispatch logic
   - Implement registry-based lookup
   - Add extensibility

3. Update `eval.zig`
   - Use dispatcher
   - Reduce coupling to specific functions

**Verification**:
```bash
# Test builtin functions
./zig-out/bin/geode query "RETURN sin(0), cos(0), sqrt(4)"
./zig-out/bin/geode query "RETURN length('test'), upper('test')"

python3 extended_test_runner.py | grep -i function
# Expected: All function tests passing
```

**Phase 5 Completion Criteria**:
- ✅ No circular dependencies
- ✅ Clean dependency graph
- ✅ All tests passing
- ✅ Architecture documented
- ✅ Improved extensibility

---

### Phase 6: Extract Expression Evaluation (Medium Risk)

**Status**: PENDING
**Estimated Effort**: 6-8 hours
**Dependencies**: Phase 5
**Agent Assignment**: Agent with type system expertise

**Objectives**:
- Further modularize `eval.zig` (3,332 lines)
- Extract type promotion logic
- Improve type system testability

**Priority**: P1 HIGH (Improves maintainability)

#### Milestone 6.1: Extract Type Promotion (3-4 hours)

**Target State**:
```
src/
├── eval.zig (~2,500 lines)
└── eval/
    ├── builtin_dispatcher.zig (~800 lines)
    └── type_promotion.zig (~800 lines)
```

**Tasks**:
1. Identify type promotion logic in `eval.zig`
   - Numeric type coercion
   - String conversions
   - Type compatibility checks

2. Create `src/eval/type_promotion.zig`
   - Extract promotion rules
   - Define promotion matrix
   - Add promotion tests

3. Update `eval.zig`
   - Use type promotion module
   - Remove extracted code

**Verification**:
```bash
# Test type promotion
./zig-out/bin/geode query "RETURN 1 + 1.5"  # int + float
./zig-out/bin/geode query "RETURN '1' + 1"  # string + int

python3 extended_test_runner.py | grep -i type
# Expected: All type tests passing
```

#### Milestone 6.2: Consolidate Evaluation Logic (2-3 hours)

**Tasks**:
1. Review remaining `eval.zig` code
   - Identify further extraction opportunities
   - Document evaluation flow
   - Optimize hot paths

2. Create evaluation documentation
   - Document evaluation pipeline
   - Add architecture diagrams
   - Create developer guide

**Deliverables**:
- Modularized eval system
- `docs/architecture/evaluation_pipeline.md`

**Phase 6 Completion Criteria**:
- ✅ eval.zig reduced to ~2,500 lines
- ✅ Type system more modular
- ✅ Better test coverage
- ✅ Documentation complete

---

### Phase 7: Consolidate Schema & Transactions (Low Risk)

**Status**: PENDING
**Estimated Effort**: 6-8 hours
**Dependencies**: Phase 0
**Agent Assignment**: Any agent

**Objectives**:
- Consolidate scattered schema management code
- Unify transaction handling
- Create clear module boundaries

**Priority**: P2 MEDIUM (Organizational improvement)

#### Milestone 7.1: Create Schema Module (3-4 hours)

**Target State**:
```
src/schema/
├── catalog.zig (moved from execution/)
├── annotations.zig (already exists)
├── constraints.zig (already exists)
├── schema_manager.zig (new - unified interface)
└── validation.zig (new - validation logic)
```

**Tasks**:
1. Move `src/execution/catalog.zig` → `src/schema/catalog.zig`
2. Create `src/schema/schema_manager.zig` as unified interface
3. Update all imports
4. Add schema-specific tests

**Verification**:
```bash
make build && make verify-all
# Expected: All tests passing
```

#### Milestone 7.2: Consolidate Transaction Module (3-4 hours)

**Target State**:
```
src/transactions/
├── mvcc.zig (moved from txn/)
├── isolation.zig (moved from txn/)
├── coordinator.zig (new - distributed txn)
└── transaction_manager.zig (new - unified interface)
```

**Tasks**:
1. Move transaction code from `src/txn/` → `src/transactions/`
2. Create unified transaction manager
3. Update imports
4. Add transaction tests

**Verification**:
```bash
# Test transactions
./zig-out/bin/geode query "BEGIN; CREATE (n); COMMIT;"

python3 extended_test_runner.py | grep -i transaction
# Expected: All transaction tests passing
```

**Phase 7 Completion Criteria**:
- ✅ Schema code consolidated
- ✅ Transaction code consolidated
- ✅ Clear module organization
- ✅ All tests passing

---

### Phase 8: Test Infrastructure & Documentation (Low Risk)

**Status**: PENDING
**Estimated Effort**: 6-8 hours
**Dependencies**: All previous phases
**Agent Assignment**: Any agent

**Objectives**:
- Create modularization testing framework
- Update all documentation
- Generate final metrics

**Priority**: P2 MEDIUM (Ensures quality)

#### Milestone 8.1: Create Module Testing Framework (3-4 hours)

**Tasks**:
1. Create test utilities for isolated module testing
2. Add dependency injection helpers
3. Create mock interfaces where appropriate (for I/O only)
4. Document testing patterns

**Deliverables**:
- `tests/module_test_framework.zig`
- `docs/testing/module_testing_guide.md`

#### Milestone 8.2: Update Documentation (2-3 hours)

**Tasks**:
1. Update all affected documentation
2. Create architecture diagrams
3. Document new module boundaries
4. Update API documentation

**Deliverables**:
- Updated `docs/architecture/`
- Updated `docs/API_REFERENCE.md`
- Architecture diagrams

#### Milestone 8.3: Final Verification (1-2 hours)

**Tasks**:
1. Run complete test suite
2. Generate final metrics
3. Compare to baseline
4. Document improvements

**Verification**:
```bash
# Full test suite
python3 extended_test_runner.py
# Expected: ≥1644 tests passing (97.4%+)

# Build verification
make verify-all
# Expected: 393/393 Zig tests passing

# Generate metrics
./scripts/modularization/generate_final_metrics.sh
# Expected: Metrics showing improvements
```

**Phase 8 Completion Criteria**:
- ✅ All documentation updated
- ✅ Test framework complete
- ✅ Final metrics generated
- ✅ Success criteria met

---

## Testing Strategy

### Test Categories

**1. Unit Tests**
- Test individual modules in isolation
- Use dependency injection for testing
- Mock only I/O operations, never business logic
- Run after every code change

**2. Integration Tests**
- Test module interactions
- Verify interfaces work correctly
- Test with real dependencies
- Run after completing each milestone

**3. End-to-End Tests**
- Full system testing
- Server + CLI + clients
- Use geodetestlab suite
- Run after completing each phase

**4. Regression Tests**
- Ensure no functionality lost
- Compare against baseline
- Run continuously
- Block merges on failures

### Testing Protocol

**After Each Commit**:
```bash
# 1. Build
make build
# Must succeed with zero errors

# 2. Unit tests
zig build test --summary all
# Must pass all tests

# 3. Quick integration test
./zig-out/bin/geode query "RETURN 1"
# Must work

# 4. Commit only if all pass
git add .
git commit -m "description"
```

**After Each Milestone**:
```bash
# 1. Full build verification
make verify-all
# Expected: 393/393 Zig tests passing

# 2. Full integration tests
python3 extended_test_runner.py
# Expected: ≥1644 tests passing (97.4%+)

# 3. Client tests
cd clients && ./run_client_tests.sh
# Expected: All client tests passing

# 4. Performance check
./scripts/benchmark/quick_benchmark.sh
# Expected: No significant regression
```

**After Each Phase**:
```bash
# 1. All milestone tests pass
# 2. Full geodetestlab suite
python3 extended_test_runner.py --verbose > phase_X_results.log
# 3. Compare to baseline
./scripts/modularization/compare_to_baseline.sh phase_X_results.log
# 4. Document results in MODULARIZATION_STATUS.md
```

### Failure Handling

**If Tests Fail**:
1. **DO NOT PROCEED** - Stop immediately
2. **ANALYZE** - Understand the failure
3. **FIX** - Implement proper fix (never mock)
4. **VERIFY** - Ensure fix works
5. **DOCUMENT** - Record the issue and solution

**If Build Fails**:
1. **REVERT** - Git revert to last working state
2. **ANALYZE** - Understand the build error
3. **FIX INCREMENTALLY** - Smaller changes
4. **TEST FREQUENTLY** - Build after each small change

**Escalation**:
- If stuck >2 hours: Document issue, ask for help
- If architectural issue: Create ADR, get review
- If test infrastructure issue: Fix test runner first

## Success Criteria

### Overall Success Metrics

**Code Quality**:
- ✅ No file >2,000 lines (target: <1,500 lines)
- ✅ No circular dependencies
- ✅ Clear separation of concerns
- ✅ Improved testability (can test modules in isolation)

**Test Coverage**:
- ✅ Test pass rate: ≥97.4% (maintain or improve)
- ✅ All critical tests passing (1644+ tests)
- ✅ No new test failures introduced
- ✅ Build passes: 393/393 Zig tests

**Performance**:
- ✅ No query performance regression (±5% acceptable)
- ✅ No memory footprint increase
- ✅ Startup time unchanged or improved

**Documentation**:
- ✅ All modules documented
- ✅ Architecture diagrams updated
- ✅ API documentation complete
- ✅ Migration guide created

### Phase-Specific Success Criteria

See each phase section for detailed completion criteria.

## Risk Management

### High-Risk Areas

**1. Server Modularization (Phase 3)**
- **Risk**: Breaking core server functionality
- **Mitigation**:
  - Extra testing at each step
  - Incremental changes only
  - Keep backup of working version
  - Test with real clients frequently

**2. Circular Dependency Resolution (Phase 5)**
- **Risk**: Architectural mistakes
- **Mitigation**:
  - Thorough analysis before coding
  - Create ADR for review
  - Prototype solution first
  - Extensive testing

**3. Evaluation System Changes (Phase 6)**
- **Risk**: Breaking type system
- **Mitigation**:
  - Comprehensive type tests
  - Test all type combinations
  - Benchmark performance
  - Review by type system expert

### Rollback Strategy

**Per Commit**:
- Use git revert for single commit rollback
- Keep commits small and atomic
- Test before committing

**Per Milestone**:
- Tag before starting: `git tag before-milestone-X.Y`
- Can rollback entire milestone if needed
- Document why rollback occurred

**Per Phase**:
- Create branch for each phase
- Merge only when complete and tested
- Can abandon branch if fundamental issue

## Agent Coordination

### How Agents Should Use This Plan

**1. Picking Up Work**:
- Read this plan completely
- Check `MODULARIZATION_STATUS.md` for current state
- Choose an available phase/milestone
- Update status to "IN PROGRESS"
- Note your agent ID in status doc

**2. During Work**:
- Follow the phase instructions exactly
- Run tests frequently
- Update status document with progress
- Commit incrementally
- Document any issues or deviations

**3. Completing Work**:
- Run all verification steps
- Update status to "COMPLETE"
- Document results
- Note any issues for next agent
- Commit and push all changes

**4. If Blocked**:
- Document the blocker in status doc
- Mark milestone as "BLOCKED"
- Include detailed description
- Suggest potential solutions
- Alert for human review if needed

### Status Document Usage

All agents must maintain `MODULARIZATION_STATUS.md` with:
- Current phase/milestone status
- Agent working on each item
- Start/completion timestamps
- Test results
- Issues encountered
- Next steps

### Communication Protocol

**Between Agents**:
- Use status document for async communication
- Document all decisions
- Leave clear notes for next agent
- Update architecture docs

**With Humans**:
- Report blockers immediately
- Request architectural decisions
- Escalate test failures
- Confirm major changes

## References

### Documentation

**Primary References**:
- `CLAUDE.md` - Project instructions and requirements
- `docs/TODO.md` - Current priorities and status
- `docs/FEATURES_OVERVIEW.md` - Complete feature catalog
- `docs/IMPLEMENTATION_STATUS_OCTOBER_2025.md` - Implementation details

**Architecture**:
- `docs/architecture/` - Architecture documentation (to be created)
- `build.zig` - Build system configuration
- `src/lib.zig` - Module re-export hub

**Testing**:
- `extended_test_runner.py` - Main test runner
- `geodetestlab/specs/` - Test specifications
- `tests/` - Unit and integration tests

### Tools & Scripts

**Modularization Tools** (to be created in Phase 0):
- `scripts/modularization/generate_metrics.sh` - Module metrics
- `scripts/modularization/check_circular_deps.py` - Dependency checker
- `scripts/modularization/compare_to_baseline.sh` - Test comparison
- `scripts/modularization/generate_final_metrics.sh` - Final report

**Testing Tools**:
- `python3 extended_test_runner.py` - Full test suite
- `make verify-all` - Build verification
- `zig build test` - Unit tests

### Key Files by Phase

**Phase 1**: `src/security/audit.zig`, `src/streaming/cdc_enhanced.zig`, `src/security/tde.zig`
**Phase 2**: `src/execution/path_and_call_operations.zig`
**Phase 3**: `src/server/main.zig`
**Phase 4**: `src/cli/main.zig`
**Phase 5**: `src/execution.zig`, `src/eval.zig`
**Phase 6**: `src/eval.zig`
**Phase 7**: `src/schema/`, `src/txn/`
**Phase 8**: All documentation and tests

---

## Appendix A: File Size Targets

**Current → Target** (lines of code):

| File | Current | Phase | Target | Reduction |
|------|---------|-------|--------|-----------|
| `server/main.zig` | 7,039 | 3 | 300 | -6,739 (-96%) |
| `cli/main.zig` | 5,885 | 4 | 400 | -5,485 (-93%) |
| `path_and_call_operations.zig` | 4,725 | 2 | 0 (split) | -4,725 (-100%) |
| `eval.zig` | 3,332 | 6 | 2,500 | -832 (-25%) |
| `audit.zig` | 1,701 | 1 | 1,200 | -501 (-29%) |
| `tde.zig` | 1,482 | 1 | 800 | -682 (-46%) |
| `cdc_enhanced.zig` | 1,390 | 1 | 800 | -590 (-42%) |

**Total Reduction**: ~19,554 lines reorganized into focused modules

---

## Appendix B: Testing Checklist

Use this checklist after each milestone:

```
Milestone X.Y Completion Checklist:

Build & Compile:
[ ] make build succeeds (zero errors)
[ ] make verify-all passes (393/393 tests)
[ ] No compiler warnings introduced

Unit Tests:
[ ] zig build test --summary all (all pass)
[ ] New unit tests added for new modules
[ ] Code coverage maintained or improved

Integration Tests:
[ ] python3 extended_test_runner.py (≥1644 pass)
[ ] Test pass rate ≥97.4%
[ ] No new test failures
[ ] Critical tests passing

Functionality:
[ ] Server starts: ./zig-out/bin/geode serve
[ ] CLI works: ./zig-out/bin/geode --help
[ ] Queries work: ./zig-out/bin/geode query "RETURN 1"
[ ] Client tests pass

Code Quality:
[ ] No circular dependencies added
[ ] Module boundaries clear
[ ] Code follows project conventions
[ ] Documentation updated

Git:
[ ] Changes committed
[ ] Commit message descriptive
[ ] Status document updated
[ ] Ready for next milestone
```

---

**END OF MODULARIZATION PLAN**

*This plan is a living document. Update as needed based on implementation learnings.*
