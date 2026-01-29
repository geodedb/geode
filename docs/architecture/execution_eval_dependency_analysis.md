# Execution ↔ Eval Circular Dependency Analysis

**Created**: 2025-11-13
**Phase**: 5 M5.1 - Analyze Circular Dependency
**Status**: ANALYSIS COMPLETE

## Executive Summary

This document analyzes the circular dependency between `src/execution.zig` and `src/eval.zig`, identifies the specific coupling points, and documents usage patterns to inform the architectural solution for breaking this cycle.

**Key Finding**: The circular dependency exists because:

- **Execution needs Eval**: To evaluate expressions within queries (WITH clauses, ORDER BY, etc.)
- **Eval needs Execution**: To execute subqueries and graph operations within expressions (IN subqueries, pattern comprehensions, shortest path)

## Circular Dependency Diagram

```
┌─────────────────┐         imports         ┌─────────────┐
│  execution.zig  │ ───────────────────────> │   eval.zig  │
│                 │                          │             │
│  - Query exec   │                          │  - evalExpr │
│  - WITH clauses │ <─────────────────────── │  - Values   │
│  - ORDER BY     │         imports          │  - Env      │
└─────────────────┘                          └─────────────┘
         ↑                                           ↑
         │                                           │
         │  Uses:                          Uses:    │
         │  • Value (50x)                  • getDefaultContext (2x) │
         │  • Env (3x)                     • executeQueryWithContext (2x) │
         │  • evalExpr (3x)                • findShortestPath (1x) │
         │                                  • countPatternMatches (1x) │
         │                                  • executePatternComprehension (1x) │
         │                                           │
         ↓                                           ↓
```

## Dependency Analysis

### 1. execution.zig → eval.zig Dependencies

**Import Statement**: Line 11

```zig
const eval = @import("eval.zig");
```

**Used Types and Functions**:

| Symbol | Type | Usage Count | Purpose |
|--------|------|-------------|---------|
| `eval.Value` | Type | 50 | Core value type for all data in the system (Null, Int, Bool, Str, Node, Edge, Path, List, Map, etc.) |
| `eval.Env` | Type | 3 | Environment type for variable bindings during expression evaluation |
| `eval.evalExpr()` | Function | 3 | Evaluates expressions in context |

**Usage Locations**:

1. **WITH Clause Expression Evaluation** (line ~1543):

   ```zig
   const env = eval.Env{
       .names = input_result.columns,
       .values = input_row,
       .allocator = allocator,
   };

   new_row[i] = try eval.evalExpr(allocator, item.expr, env);
   ```

   - **Context**: Evaluating WITH clause expressions for query chaining
   - **Frequency**: Called for each WITH expression in the query

2. **ORDER BY Expression Evaluation** (lines ~1584-1585):

   ```zig
   const val_a = eval.evalExpr(context.allocator, key.expr, env_a) catch eval.Value{ .Null = {} };
   const val_b = eval.evalExpr(context.allocator, key.expr, env_b) catch eval.Value{ .Null = {} };
   ```

   - **Context**: Evaluating ORDER BY expressions for sorting rows
   - **Frequency**: Called for each pair of rows being compared

3. **Value Type Usage** (50+ locations):
   - Row data: `[][]eval.Value` - 2D array of values representing query results
   - Column data: `[]eval.Value` - 1D array of values representing a single row
   - Literal values: Creating string, int, bool literals for system messages

**Impact Assessment**:

- **Critical**: `eval.Value` is the fundamental data type throughout the execution system
- **Moderate**: `eval.evalExpr()` is used in specific contexts (WITH, ORDER BY)
- **Low**: `eval.Env` is only constructed where needed for expression evaluation

### 2. eval.zig → execution.zig Dependencies

**Import Statement**: Line 5

```zig
const execution = @import("execution.zig");
```

**Used Functions**:

| Function | Usage Count | Source Module | Purpose |
|----------|-------------|---------------|---------|
| `execution.getDefaultContext()` | 2 | execution.zig:194 | Gets default execution context for subqueries |
| `execution.executeQueryWithContext()` | 2 | query_execution.zig:368 (re-exported) | Executes GQL subqueries |
| `execution.findShortestPath()` | 1 | graph_algorithms.zig (re-exported) | Finds shortest paths in graph |
| `execution.countPatternMatches()` | 1 | graph_algorithms.zig (re-exported) | Counts pattern matches |
| `execution.executePatternComprehension()` | 1 | graph_algorithms.zig (re-exported) | Executes pattern comprehensions |

**Usage Locations**:

1. **IN Subquery Expression** (eval.zig:1664-1670):

   ```zig
   .InSubquery => |isq| {
       const v = try evalExpr(allocator, isq.value.*, env);

       const context = execution.getDefaultContext(allocator) catch ...;
       var result = execution.executeQueryWithContext(allocator, isq.subquery.*, context) catch ...;

       // Check if v is in first column of result.rows
   }
   ```

   - **Context**: Evaluating `value IN (SELECT ...)` expressions
   - **Frequency**: Each time an IN subquery expression is evaluated

2. **NOT IN Subquery Expression** (eval.zig:1711-1717):

   ```zig
   .NotInSubquery => |nisq| {
       const v = try evalExpr(allocator, nisq.value.*, env);

       const context = execution.getDefaultContext(allocator) catch ...;
       var result = execution.executeQueryWithContext(allocator, nisq.subquery.*, context) catch ...;

       // Check if v is NOT in first column of result.rows
   }
   ```

   - **Context**: Evaluating `value NOT IN (SELECT ...)` expressions
   - **Frequency**: Each time a NOT IN subquery expression is evaluated

3. **Shortest Path Expression** (eval.zig:2074):

   ```zig
   .ShortestPath => |sp| {
       const path_value = execution.findShortestPath(allocator, sp.pattern.*, sp.all, env) catch {
           break :blk_shortest Value{ .Null = {} };
       };
       break :blk_shortest path_value;
   }
   ```

   - **Context**: Evaluating `shortestPath((a)-[*]-(b))` expressions
   - **Frequency**: Each time a shortestPath expression is evaluated

4. **Pattern Count Expression** (eval.zig:2082):

   ```zig
   .PatternCount => |pc| {
       const count = execution.countPatternMatches(allocator, pc.*) catch {
           break :blk_count Value{ .Int = 0 };
       };
       break :blk_count count;
   }
   ```

   - **Context**: Evaluating `size((pattern))` expressions for counting
   - **Frequency**: Each time a pattern count expression is evaluated

5. **Pattern Comprehension Expression** (eval.zig:2145):

   ```zig
   .PatternComp => |pc| {
       const result_list = execution.executePatternComprehension(
           allocator,
           pc.pattern.*,
           pc.where,
           pc.map.*,
           env
       ) catch {
           break :blk_patterncomp Value{ .List = &.{} };
       };
       break :blk_patterncomp result_list;
   }
   ```

   - **Context**: Evaluating `[(pattern) WHERE condition | expression]` comprehensions
   - **Frequency**: Each time a pattern comprehension is evaluated

**Impact Assessment**:

- **Moderate**: Subquery execution (IN/NOT IN) used in predicate evaluation
- **Low**: Graph operations (shortest path, pattern matching) used in specialized expressions
- **Localized**: All calls are in specific expression evaluation cases within `evalExpr()`

## Dependency Flow Analysis

### Direction of Data Flow

```
User Query (GQL)
      ↓
┌─────────────────────────────────────────┐
│ execution.zig: executeQuery()           │
│  - Parses query structure               │
│  - Routes to appropriate handlers       │
│  - Manages execution context            │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ execution.zig: WITH/ORDER BY handlers   │
│  - Needs to evaluate expressions        │
│  - Creates eval.Env with row data       │
└──────────────┬──────────────────────────┘
               ↓
      ┌────────────────┐
      │ eval.evalExpr()│ ←───────┐
      │  - Evaluates   │         │
      │    expressions │         │ Recursive
      └────────┬───────┘         │ call for
               ↓                  │ nested exprs
    ┌──────────────────┐         │
    │ Expression Type? │         │
    └──────┬───────────┘         │
           ↓                      │
    ┌──────────────────────────────────────┐
    │ Special Cases Requiring Execution:   │
    │                                       │
    │ • IN Subquery       → executeQuery   │───┐
    │ • NOT IN Subquery   → executeQuery   │   │ Circular
    │ • ShortestPath      → findShortestPath│   │ dependency
    │ • PatternCount      → countPatterns  │   │ back to
    │ • PatternComp       → executePattern │   │ execution
    └───────────────────────────────────────┘───┘
                                           ↑
                                           │
                          Calls execution functions
```

### Layering Violation

The circular dependency represents a **layering violation**:

1. **Intended Architecture** (hierarchical):

   ```
   ┌─────────────────┐
   │  Execution      │  ← Top layer: orchestrates query execution
   ├─────────────────┤
   │  Evaluation     │  ← Middle layer: evaluates expressions
   ├─────────────────┤
   │  Value Types    │  ← Bottom layer: core data types
   └─────────────────┘
   ```

2. **Actual Architecture** (circular):

   ```
   ┌─────────────────┐
   │  Execution      │ ───┐
   ├─────────────────┤    │ mutual
   │  Evaluation     │ <──┘ imports
   ├─────────────────┤
   │  Value Types    │
   └─────────────────┘
   ```

**Root Cause**: Eval needs to execute subqueries and graph operations, which are execution-layer concerns.

## Architectural Coupling Points

### Strong Coupling

1. **Value Type Coupling** (`eval.Value`)
   - Used extensively throughout execution (50+ references)
   - Represents all data in the system
   - Cannot be easily extracted or replaced
   - **Assessment**: Fundamental type, should be shared

2. **Expression Evaluation Coupling** (`eval.evalExpr()`)
   - Called from execution for WITH and ORDER BY
   - Requires Environment setup from execution context
   - **Assessment**: Clear interface, good separation

### Weak Coupling

1. **Subquery Execution Coupling** (`execution.executeQueryWithContext()`)
   - Called from eval for IN/NOT IN subqueries
   - Only 2 call sites
   - **Assessment**: Could be abstracted via interface

2. **Graph Operations Coupling** (`execution.findShortestPath()`, etc.)
   - Called from eval for graph expressions
   - Only 3 call sites total
   - **Assessment**: Could be abstracted via callbacks

## Break Points Analysis

### Potential Break Points

We identified several potential points where the circular dependency could be broken:

#### Option 1: Extract Value Types to Shared Module ✅ RECOMMENDED

**Strategy**: Create `src/value_types.zig` as a shared module

```
┌─────────────────┐
│  execution.zig  │ ─────┐
└─────────────────┘      │
                         ↓
                  ┌──────────────┐
                  │ value_types  │  ← Shared types
                  │  - Value     │
                  │  - Env       │
                  └──────────────┘
                         ↑
┌─────────────────┐      │
│   eval.zig      │ ─────┘
└─────────────────┘
```

**Pros**:

- Simple, low-risk refactoring
- `Value` is already a well-defined, stable type
- No behavioral changes required
- Clear separation of concerns

**Cons**:

- Doesn't fully break the circular dependency (execution still calls eval.evalExpr)
- Need to update many import statements

**Partial Solution**: This breaks the value type dependency but not the function call dependency.

#### Option 2: Create Evaluator Interface (Adapter Pattern) ✅ RECOMMENDED

**Strategy**: Use dependency injection to break execution → eval → execution cycle

```
┌─────────────────┐
│  execution.zig  │ ─────> evaluator_interface.zig
└─────────────────┘              ↑
                                 │ implements
┌─────────────────┐              │
│   eval.zig      │ ─────────────┘
└─────────────────┘
         │
         └────> execution_adapter.zig ──> (callbacks to execution)
```

**Implementation**:

1. Create `src/execution/evaluator_adapter.zig` defining `EvaluatorInterface`
2. Execution uses the interface instead of importing eval directly
3. Eval implements the interface and receives execution callbacks at runtime

**Pros**:

- Breaks the compile-time circular dependency
- Enables dependency injection for testing
- Clear separation via interface

**Cons**:

- More complex implementation
- Runtime callback overhead (minimal)
- Requires careful interface design

#### Option 3: Extract Builtin Function Dispatcher

**Strategy**: Move function dispatch out of eval.zig

This is covered in Phase 5 M5.3 and addresses extensibility, not the circular dependency itself.

### Recommended Approach: Combination Strategy

**Phase 5 should use BOTH Option 1 and Option 2**:

1. **M5.1 (Current)**: Analyze dependencies ✅ COMPLETE
2. **M5.2**: Extract value types to `value_types.zig` (breaks value type coupling)
3. **M5.3**: Create evaluator adapter pattern (breaks function call coupling)
4. **M5.4**: Extract builtin function dispatcher (improves extensibility)

## Implementation Complexity Assessment

### Option 1: Extract Value Types (M5.2)

**Estimated Effort**: 3-4 hours

**Steps**:

1. Create `src/value_types.zig` with `Value`, `Env`, and related types
2. Update `execution.zig` to import from `value_types.zig`
3. Update `eval.zig` to import from `value_types.zig`
4. Update all submodules (execution/*, etc.) that reference these types
5. Update `build.zig` module dependencies
6. Run full test suite

**Risk**: LOW - Pure code movement, no behavioral changes

**Test Strategy**:

- Compile-time verification (builds successfully)
- Zero test regressions expected
- No functional changes

### Option 2: Create Evaluator Adapter (M5.3)

**Estimated Effort**: 4-6 hours

**Steps**:

1. Create `src/execution/evaluator_adapter.zig` with:
   - `ExecutionCallbacks` struct with function pointers
   - Initialization function to set up callbacks
   - Clear interface documentation
2. Update `eval.zig` to:
   - Accept `ExecutionCallbacks` parameter in evalExpr
   - Use callbacks instead of direct imports
   - Handle missing callback cases gracefully
3. Update `execution.zig` to:
   - Provide callback implementations
   - Initialize evaluator with callbacks
4. Update all call sites
5. Extensive testing

**Risk**: MEDIUM - Changes evaluation flow, requires careful testing

**Test Strategy**:

- Unit tests for adapter
- Integration tests for subquery evaluation
- Pattern comprehension tests
- Shortest path tests
- Performance benchmarks (ensure no regression)

## Dependencies on Other Modules

### execution.zig Dependencies (Beyond eval.zig)

```zig
const std = @import("std");
const ast = @import("gql/ast.zig");              // AST types
const graph_store = @import("graph_store.zig");  // Graph storage
const fle_integration = @import("fle_integration.zig");  // Encryption
```

### eval.zig Dependencies (Beyond execution.zig)

```zig
const std = @import("std");
const ast = @import("gql/ast.zig");              // AST types (shared with execution)
const eval_funcs = @import("types/evaluator_functions.zig");  // Helper functions
const heap = @import("storage/heap.zig");        // Memory management
const fle_integration = @import("fle_integration.zig");  // Encryption (shared)
```

**Observation**: Both modules share dependencies on:

- `gql/ast.zig` - GQL AST types
- `fle_integration.zig` - Field-level encryption

This is acceptable as AST is a shared interface definition.

## Test Coverage Analysis

### Affected Test Areas

When breaking the circular dependency, these test areas must pass:

1. **Expression Evaluation Tests**:
   - `tests/eval_test.zig` - Core expression evaluation
   - Arithmetic, comparison, logical operations
   - Type coercion and promotion

2. **Subquery Tests**:
   - IN subquery expressions
   - NOT IN subquery expressions
   - Nested subqueries

3. **Pattern Tests**:
   - Pattern comprehensions `[(a)--(b) | b]`
   - Pattern counts `size((pattern))`
   - Shortest path `shortestPath((a)-[*]-(b))`

4. **Integration Tests**:
   - WITH clause with expressions
   - ORDER BY with expressions
   - Complex queries combining execution and evaluation

5. **Performance Tests**:
   - Query execution benchmarks
   - Expression evaluation benchmarks
   - Ensure no regression from abstraction overhead

### Test Strategy for Refactoring

**After M5.2 (Extract Value Types)**:

```bash
# Must pass all tests
make build && make verify-all
python3 extended_test_runner.py
# Expected: 1644+ tests passing (97.4%+)
```

**After M5.3 (Create Evaluator Adapter)**:

```bash
# Must pass all tests + performance validation
make build && make verify-all
python3 extended_test_runner.py
./scripts/benchmark/quick_benchmark.sh
# Expected: 1644+ tests passing, no performance regression
```

## Success Criteria for Phase 5 M5.1

- ✅ **Circular dependency documented** with import statements and usage counts
- ✅ **All coupling points identified** with specific line numbers and contexts
- ✅ **Data flow analyzed** with diagrams showing execution flow
- ✅ **Break points identified** with pros/cons for each approach
- ✅ **Implementation plan proposed** with effort estimates
- ✅ **Test strategy defined** for verification
- ✅ **Risk assessment complete** for each refactoring option

## Next Steps

**Immediate** (Phase 5 M5.2):

- Create `src/value_types.zig` with `Value`, `Env`, and related types
- Update imports in execution.zig and eval.zig
- Verify builds and tests pass

**Following** (Phase 5 M5.3):

- Create `src/execution/evaluator_adapter.zig` with callback interface
- Update eval.zig to use callbacks
- Update execution.zig to provide callbacks
- Extensive testing and validation

**Documentation**:

- Create ADR (Architecture Decision Record) documenting the chosen approach
- Update architecture diagrams
- Document the new dependency structure

---

**Document Status**: COMPLETE
**Milestone**: Phase 5 M5.1 ✅
**Next Milestone**: Phase 5 M5.2 - Extract Value Types
**Last Updated**: 2025-11-13
