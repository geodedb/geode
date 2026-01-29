# ADR: Breaking the Execution ↔ Eval Circular Dependency

**Status**: PROPOSED
**Date**: 2025-11-13
**Phase**: 5 - Resolve Circular Dependencies
**Decision Makers**: Claude AI Agent (Architecture Analysis)
**Related Documents**: [execution_eval_dependency_analysis.md](./execution_eval_dependency_analysis.md)

## Context and Problem Statement

The Geode codebase has a circular dependency between `src/execution.zig` and `src/eval.zig`:

- **execution.zig** imports **eval.zig** to evaluate expressions (using `eval.Value`, `eval.Env`, `eval.evalExpr()`)
- **eval.zig** imports **execution.zig** to execute subqueries and graph operations (using `execution.executeQueryWithContext()`, `execution.findShortestPath()`, etc.)

This circular dependency:

1. **Violates architectural layering** - Creates unclear module boundaries
2. **Complicates testing** - Cannot test modules in isolation
3. **Hinders maintainability** - Changes in one module may require changes in the other
4. **Prevents future refactoring** - Difficult to split or reorganize code

**Question**: How should we break this circular dependency while:

- Maintaining all existing functionality
- Preserving performance
- Ensuring testability
- Keeping code clean and maintainable

## Decision Drivers

### Functional Requirements

- ✅ **Zero breaking changes** - All existing APIs must continue to work
- ✅ **Preserve GQL compliance** - Must maintain 98.6%+ GQL spec compliance
- ✅ **Maintain test pass rate** - Must maintain 97.4%+ test pass rate (1644+ tests)
- ✅ **No feature loss** - All subquery, pattern comprehension, and graph features must work

### Non-Functional Requirements

- ✅ **Performance** - No query execution regression (±5% acceptable)
- ✅ **Testability** - Enable isolated unit testing of modules
- ✅ **Maintainability** - Clear module boundaries and dependencies
- ✅ **Extensibility** - Enable future additions without circular dependencies

### Technical Constraints

- ✅ **Zig 0.15.1+ compatibility** - Must work with current Zig version
- ✅ **Build system compatibility** - Must integrate with existing `build.zig`
- ✅ **Module system** - Must work with Zig's module system
- ✅ **Memory safety** - No memory leaks or unsafe patterns

## Considered Options

### Option 1: Do Nothing (Status Quo)

**Approach**: Keep the circular dependency as-is

**Pros**:

- No implementation effort
- No risk of breaking changes
- Current functionality works

**Cons**:

- Continues to violate architectural principles
- Blocks future modularization efforts (Phase 2, Phase 3)
- Makes testing more difficult
- Technical debt accumulates

**Assessment**: ❌ **NOT ACCEPTABLE** - Violates Phase 5 objectives

---

### Option 2: Merge Modules

**Approach**: Merge `execution.zig` and `eval.zig` into single module

**Pros**:

- Eliminates circular dependency immediately
- No interface abstraction needed
- Simple implementation

**Cons**:

- Creates massive monolithic module (>10,000 lines)
- Violates Phase 5 goal of modularization
- Makes code harder to understand and maintain
- Goes against project modularization direction

**Assessment**: ❌ **NOT ACCEPTABLE** - Contradicts modularization goals

---

### Option 3: Extract Value Types Only

**Approach**: Create `src/value_types.zig` with `Value`, `Env`, and related types

**Architecture**:

```
┌─────────────────┐        ┌──────────────┐        ┌─────────────┐
│  execution.zig  │ ────>  │ value_types  │  <──── │   eval.zig  │
│                 │        │  - Value     │        │             │
│                 │ ────>  │  - Env       │        │             │
│                 │   ↓    └──────────────┘        │             │
│                 │   │                             │             │
│                 │   └─────────────────────────────> evalExpr() │
└─────────────────┘                                 └─────────────┘
                                                            │
                                                            ↓
                                                    (still calls execution)
```

**Pros**:

- Simple, low-risk refactoring
- Value types are well-defined and stable
- Breaks value type dependency
- No behavioral changes

**Cons**:

- **Doesn't fully break circular dependency** - execution still calls eval.evalExpr, and eval still calls execution functions
- Partial solution only
- Still have compile-time cycle

**Assessment**: ⚠️ **PARTIAL SOLUTION** - Good first step but incomplete

---

### Option 4: Create Evaluator Interface (Adapter Pattern) 🏆

**Approach**: Use dependency injection with adapters to break the cycle

**Architecture**:

```
┌─────────────────────────────────────────────────────────┐
│                    value_types.zig                      │
│                    - Value, Env                         │
└────────────────────────┬────────────────────────────────┘
                         │ (imported by both)
                         │
        ┌────────────────┴────────────────┐
        ↓                                  ↓
┌─────────────────┐               ┌─────────────────┐
│  execution.zig  │               │   eval.zig      │
│                 │               │                 │
│  Uses:          │               │  Implements:    │
│  • Evaluator    │               │  • Evaluator    │
│    Interface    │               │    Interface    │
│                 │               │                 │
│  Provides:      │               │  Uses:          │
│  • Execution    │               │  • Execution    │
│    Callbacks    │               │    Callbacks    │
└────────┬────────┘               └────────┬────────┘
         │                                  │
         │                                  │
         └──────> evaluator_adapter.zig <──┘
                 - EvaluatorInterface
                 - ExecutionCallbacks
                 - Runtime wiring
```

**Components**:

1. **value_types.zig** - Shared value types

   ```zig
   pub const Value = union(enum) { ... };
   pub const Env = struct { ... };
   ```

2. **evaluator_adapter.zig** - Interface and adapter

   ```zig
   pub const EvaluatorInterface = struct {
       evalExprFn: *const fn(allocator: Allocator, expr: ast.Expr, env: Env) error!Value,
   };

   pub const ExecutionCallbacks = struct {
       executeQueryFn: *const fn(...) error!ExecutionResult,
       findShortestPathFn: *const fn(...) error!Value,
       countPatternsFn: *const fn(...) error!Value,
       executePatternCompFn: *const fn(...) error!Value,
   };
   ```

3. **execution.zig** - Uses evaluator interface

   ```zig
   const evaluator_adapter = @import("execution/evaluator_adapter.zig");

   // Instead of calling eval.evalExpr directly:
   const result = try ctx.evaluator.evalExprFn(allocator, expr, env);
   ```

4. **eval.zig** - Implements interface, uses callbacks

   ```zig
   const evaluator_adapter = @import("execution/evaluator_adapter.zig");

   pub fn createEvaluator(callbacks: ExecutionCallbacks) EvaluatorInterface {
       return .{ .evalExprFn = evalExprWithCallbacks };
   }

   fn evalExprWithCallbacks(allocator: Allocator, expr: ast.Expr, env: Env) !Value {
       return switch (expr) {
           .InSubquery => {
               // Use callback instead of direct import
               const result = try env.callbacks.executeQueryFn(...);
               ...
           },
           ...
       };
   }
   ```

**Pros**:

- ✅ **Fully breaks circular dependency** at compile time
- ✅ **Enables dependency injection** for testing
- ✅ **Clear separation of concerns** via explicit interfaces
- ✅ **No behavioral changes** - same functionality
- ✅ **Supports future extensions** - easy to add new evaluators

**Cons**:

- ⚠️ More complex implementation (4-6 hours)
- ⚠️ Runtime callback overhead (estimated <1% based on infrequent usage)
- ⚠️ Requires careful interface design
- ⚠️ More files to maintain

**Assessment**: ✅ **RECOMMENDED** - Complete solution meeting all requirements

---

### Option 5: Event-Based Architecture

**Approach**: Use event bus or message passing between modules

**Architecture**:

```
┌─────────────────┐        ┌──────────────┐        ┌─────────────┐
│  execution.zig  │ ────>  │  Event Bus   │  <──── │   eval.zig  │
└─────────────────┘        └──────────────┘        └─────────────┘
```

**Pros**:

- Fully decouples modules
- Highly extensible
- Good for complex event-driven systems

**Cons**:

- **Massive overkill** for this use case
- Significant performance overhead
- Complex debugging
- Hard to reason about call flow
- Not idiomatic Zig

**Assessment**: ❌ **NOT RECOMMENDED** - Too complex, not suitable for Zig

## Decision Outcome

**Chosen Option**: **Combination of Option 3 + Option 4**

We will implement a **two-phase approach**:

### Phase 5 M5.2: Extract Value Types (Option 3)

**Objective**: Break the value type dependency

**Implementation**:

1. Create `src/value_types.zig` containing:
   - `Value` union type
   - `Env` struct type
   - Related helper functions (isNull, stringify, etc.)
2. Update `execution.zig` to import from `value_types.zig`
3. Update `eval.zig` to import from `value_types.zig`
4. Update all submodules that reference these types
5. Update `build.zig`

**Expected Outcome**:

- Shared value types, no duplication
- Execution and eval still have circular function calls
- Low risk, 3-4 hours effort

### Phase 5 M5.3: Create Evaluator Adapter (Option 4)

**Objective**: Break the function call circular dependency

**Implementation**:

1. Create `src/execution/evaluator_adapter.zig` with:
   - `EvaluatorInterface` struct with function pointers
   - `ExecutionCallbacks` struct with function pointers
   - Initialization and wiring functions
2. Update `eval.zig` to:
   - Implement `EvaluatorInterface`
   - Accept `ExecutionCallbacks` in evalExpr
   - Use callbacks for subquery/graph operations
3. Update `execution.zig` to:
   - Use `EvaluatorInterface` instead of direct eval import
   - Provide `ExecutionCallbacks` implementation
   - Initialize evaluator with callbacks at runtime
4. Update all call sites

**Expected Outcome**:

- Fully broken circular dependency
- Runtime callback wiring
- Testability via dependency injection
- Medium risk, 4-6 hours effort

## Consequences

### Positive Consequences

1. **✅ Architectural Clarity**
   - Clear module boundaries
   - Unidirectional dependency flow
   - Easy to reason about code structure

2. **✅ Improved Testability**
   - Can unit test execution without eval
   - Can unit test eval with mock callbacks
   - Isolated component testing

3. **✅ Future Maintainability**
   - Easier to modify individual modules
   - Less risk of cascading changes
   - Clear interface contracts

4. **✅ Extensibility**
   - Easy to add alternative evaluators
   - Can inject test evaluators
   - Supports future plugin architecture

5. **✅ Documentation**
   - Interfaces serve as documentation
   - Clear contracts between modules
   - Easier onboarding for new developers

### Negative Consequences

1. **⚠️ Increased Complexity**
   - Additional abstraction layer
   - More files to maintain
   - Runtime callback setup required

2. **⚠️ Performance Overhead**
   - Function pointer indirection (minimal)
   - Estimated <1% impact based on low call frequency
   - Acceptable trade-off for architectural benefits

3. **⚠️ Implementation Risk**
   - Medium risk refactoring
   - Requires extensive testing
   - 7-10 hours total effort (M5.2 + M5.3)

### Mitigation Strategies

**For Increased Complexity**:

- Comprehensive documentation in ADR and code comments
- Clear naming conventions (EvaluatorInterface, ExecutionCallbacks)
- Examples in documentation

**For Performance**:

- Benchmark before and after
- Profile hot paths
- If overhead >1%, optimize (inline, comptime, etc.)

**For Implementation Risk**:

- Incremental approach (M5.2 first, then M5.3)
- Comprehensive test suite after each phase
- Can rollback M5.3 if issues, keep M5.2 improvements

## Implementation Plan

### Phase 5 M5.2: Extract Value Types (3-4 hours)

**Tasks**:

1. Create `src/value_types.zig` (1 hour)
   - Move Value, Env, and helper functions
   - Add CANARY markers
   - Document all types

2. Update imports (1-2 hours)
   - Update execution.zig
   - Update eval.zig
   - Update all execution/* submodules
   - Update tests

3. Update build system (30 min)
   - Add value_types module to build.zig
   - Verify module dependencies

4. Testing (1 hour)
   - Run full test suite
   - Verify 1644+ tests passing
   - Check for import errors
   - Performance baseline

**Success Criteria**:

- ✅ Builds successfully
- ✅ All 1644+ tests passing
- ✅ No circular import in value types
- ✅ Execution and eval still have function call cycle (expected)

### Phase 5 M5.3: Create Evaluator Adapter (4-6 hours)

**Tasks**:

1. Create evaluator_adapter.zig (2 hours)
   - Define EvaluatorInterface
   - Define ExecutionCallbacks
   - Add initialization functions
   - Document interfaces

2. Update eval.zig (1-2 hours)
   - Implement EvaluatorInterface
   - Accept ExecutionCallbacks parameter
   - Update 7 call sites (IN/NOT IN subqueries, graph ops)
   - Test changes

3. Update execution.zig (1-2 hours)
   - Provide ExecutionCallbacks implementation
   - Use EvaluatorInterface instead of direct import
   - Wire up evaluator at runtime
   - Test changes

4. Testing and validation (1-2 hours)
   - Unit tests for adapter
   - Integration tests for subqueries
   - Pattern comprehension tests
   - Performance benchmarks
   - Full test suite

**Success Criteria**:

- ✅ No circular dependency (verified with build system)
- ✅ All 1644+ tests passing
- ✅ No performance regression (±5%)
- ✅ Subqueries, patterns, shortest path all work
- ✅ Can inject mock evaluator for testing

### Phase 5 M5.4: Extract Builtin Function Dispatcher (Optional)

This milestone is described in the original plan but is not directly related to breaking the circular dependency. It can be deferred or combined with Phase 6 (Extract Expression Evaluation).

## Validation Strategy

### Compile-Time Validation

```bash
# Check for circular dependencies
python3 scripts/modularization/check_circular_deps.py
# Expected: No circular dependencies found between execution and eval

# Build verification
make build
# Expected: Clean build, no circular import errors
```

### Test Suite Validation

```bash
# Unit tests
zig build test --summary all
# Expected: All Zig tests passing

# Integration tests
python3 extended_test_runner.py
# Expected: 1644+ tests passing (97.4%+)

# Specific feature tests
./zig-out/bin/geode query "RETURN 1 IN (SELECT 1)"  # IN subquery
./zig-out/bin/geode query "RETURN [(a)--(b) | b]"   # Pattern comprehension
./zig-out/bin/geode query "RETURN shortestPath((a)-[*]-(b))"  # Shortest path
```

### Performance Validation

```bash
# Benchmark comparison
./scripts/benchmark/quick_benchmark.sh > before.log
# (make changes)
./scripts/benchmark/quick_benchmark.sh > after.log

# Compare results
./scripts/benchmark/compare_benchmarks.sh before.log after.log
# Expected: No regression >5%
```

### Isolated Testing Validation

```zig
// Test that eval can be tested in isolation with mock callbacks
test "eval with mock execution callbacks" {
    const mock_callbacks = ExecutionCallbacks{
        .executeQueryFn = mockExecuteQuery,
        .findShortestPathFn = mockFindShortestPath,
        .countPatternsFn = mockCountPatterns,
        .executePatternCompFn = mockExecutePatternComp,
    };

    const evaluator = createEvaluator(mock_callbacks);

    // Test evalExpr with mocked execution
    const expr = /* ... */;
    const result = try evaluator.evalExprFn(allocator, expr, env);
    // Verify result without needing real execution module
}
```

## Related Decisions

### Past Decisions

- **Phase 4 (CLI Modularization)**: Established pattern for breaking down large modules
- **Phase 3 (Server Modularization)**: Set precedent for incremental refactoring

### Future Decisions

- **Phase 6 (Extract Expression Evaluation)**: May build on evaluator interface
- **Phase 2 (Decompose path_and_call_operations)**: May benefit from cleaner dependency structure

## References

### Documentation

- [execution_eval_dependency_analysis.md](./execution_eval_dependency_analysis.md) - Detailed dependency analysis
- [MODULARIZATION_PLAN.md](../MODULARIZATION_PLAN.md) - Overall modularization strategy
- [MODULARIZATION_STATUS.md](../MODULARIZATION_STATUS.md) - Current progress tracking

### Code Locations

- `src/execution.zig` - Query execution orchestration
- `src/eval.zig` - Expression evaluation
- `src/execution/query_execution.zig` - Query execution implementation (used by eval)
- `src/execution/graph_algorithms.zig` - Graph operations (used by eval)

### Zig Resources

- [Zig Build System](https://ziglang.org/documentation/master/#Build-System) - Module system
- [Zig Dependency Injection Patterns](https://ziglang.org/documentation/master/#Function-Pointers) - Function pointers

## Approval and Sign-off

**Proposed By**: Claude AI Agent (Architecture Analysis)
**Date**: 2025-11-13
**Status**: PROPOSED - Awaiting implementation

**Implementation Authorization**: Proceeding with Phase 5 M5.2 (Extract Value Types)

---

**Document Status**: PROPOSED
**Milestone**: Phase 5 M5.1 ✅
**Next Milestone**: Phase 5 M5.2 - Extract Value Types
**Last Updated**: 2025-11-13
