# Geode Test Failure Implementation Plan

## Summary
- **Critical crash fix**: COMPLETED ✅ (SET all properties allocator issue)
- **Remaining failures**: 128 tests across 3 categories
- **Time estimate for full implementation**: 22-52 hours

## Phase 1: Error Detection (Quick Wins) - 2-4 hours

### 1.1 Transaction State Validation (1 test)
**Issue**: COMMIT without transaction returns success instead of error

**Root cause**: The execution layer correctly returns `error.NoActiveTransaction` for ROLLBACK but not for COMMIT. There appears to be an inconsistency in error handling.

**Solution approach**:
1. Investigate why ROLLBACK works (`./zig-out/bin/geode query --no-quic "ROLLBACK"` returns error correctly)
2. Ensure COMMIT follows the same error handling path
3. The check at `src/execution.zig:583-585` exists but may not be reached

**Files to modify**:
- `src/execution.zig` - Verify COMMIT error handling path
- `src/test_harness.zig` - Possibly adjust transaction session loading for COMMIT

### 1.2 Type Validation (2 tests)
**Tests**: `type-error-invalid-conversion`, `error-char-length-exceeded`

**Solution approach**:
1. Add type conversion validation in expression evaluation
2. Add CHAR length checking in string value assignment
3. Return appropriate type error codes

**Files to modify**:
- `src/eval.zig` - Add type conversion checks
- `src/types/` - Add CHAR length validation

### 1.3 Index Validation (3 tests)
**Tests**: `index-error-invalid-index-type`, `index-error-incompatible-data-type`, `index-error-duplicate-index-name`

**Solution approach**:
1. Maintain index registry with names
2. Validate index type against supported types
3. Check data type compatibility with index type
4. Return errors for violations

**Files to modify**:
- `src/index/` - Add index validation logic
- `src/execution.zig` - Add validation calls in CREATE INDEX handling

### 1.4 Catalog Validation (4 tests)
**Tests**: Duplicate schema/graph errors, nonexistent drops

**Solution approach**:
1. Maintain catalog of schemas and graphs
2. Check for duplicates on CREATE
3. Check for existence on DROP
4. Return appropriate catalog errors

**Files to modify**:
- `src/catalog/` or equivalent - Add catalog tracking
- `src/execution.zig` - Add validation in catalog operations

### 1.5 Other Validations (6 tests)
- Authentication: Check token before query execution
- Pattern matching: Validate variable-length pattern syntax
- CDC: Validate guardrail values and command format
- UNION: Validate column count match

**Files to modify**:
- `src/security/` - Authentication checks
- `src/gql/parser.zig` - Pattern validation
- `src/streaming/cdc.zig` - CDC validation
- `src/execution.zig` - UNION validation

**Estimated time**: 3-4 hours

## Phase 2: Output Format Fixes - 2-4 hours

### 2.1 MERGE 'created' Flag (1 test)
**Solution**: Track whether node was created or matched in MERGE execution, add 'created' field to output

**Files**: `src/execution.zig` - MERGE handling

### 2.2 List Format (1 test)
**Issue**: `[[1,2,3,4,5]]` instead of `[1,2,3,4,5]`

**Solution**: Fix JSON serialization of list values to not double-wrap

**Files**: `src/execution.zig` or `src/eval.zig` - JSON serialization

### 2.3 EXPLAIN Cost Field (1 test)
**Solution**: Add cost estimation to query plans

**Files**: `src/planner/` - Add cost calculation, `src/execution.zig` - Include in EXPLAIN output

### 2.4 PROFILE Metrics (1 test)
**Solution**: Collect and include execution metrics

**Files**: `src/execution.zig` - Add metrics collection for PROFILE

### 2.5 Migration Results (4 tests)
**Solution**: Track migration operations and return results

**Files**: Migration handling code - Add result tracking

### 2.6 Other Formats (10 tests)
- QUIC shell output capture
- Index usage in EXPLAIN
- Various other format adjustments

**Estimated time**: 2-4 hours

## Phase 3: CALL Subquery Support - 12-20 hours

### 3.1 Parser Extension (4-6 hours)
**Current state**: Parser supports `CALL procedure()` for procedure calls

**Required**: `CALL { subquery } RETURN ...` syntax

**Implementation**:
1. Extend `parseStatement` to handle CALL with braces
2. Parse subquery block within braces
3. Handle CALL...WITH...RETURN chaining
4. Support nested CALL blocks

**Files to modify**:
- `src/gql/parser.zig` - Add CALL subquery parsing
- `src/gql/ast.zig` - Add SubqueryBlock node type

### 3.2 AST Extensions (2-3 hours)
**Required nodes**:
```zig
pub const SubqueryBlock = struct {
    statements: []Statement,
    exported_variables: [][]const u8,  // Variables passed to outer scope
};

pub const CallStatement = union(enum) {
    Procedure: struct {
        procedure: Expr,
        yield_items: ?[]ReturnItem,
    },
    Subquery: struct {
        block: SubqueryBlock,
        imported_variables: [][]const u8,  // Variables from outer scope
    },
};
```

**Files to modify**:
- `src/gql/ast.zig` - Add new node types

### 3.3 Execution Context Isolation (4-6 hours)
**Challenges**:
1. Variable scope management (outer vs inner)
2. Result passing between subquery and outer query
3. Binding table management
4. Error propagation

**Implementation**:
1. Create isolated execution context for subquery
2. Import specified variables from outer scope
3. Execute subquery independently
4. Export results back to outer scope
5. Merge result sets

**Files to modify**:
- `src/execution.zig` - Add `executeCallSubquery` function
- Context management for scope isolation

### 3.4 WITH Clause Integration (2-3 hours)
**Required**: CALL results should be usable in subsequent WITH clauses

**Implementation**:
1. Store CALL results in bindings
2. Make available to subsequent WITH/RETURN
3. Handle variable conflicts

**Files to modify**:
- `src/execution.zig` - WITH clause handling

### 3.5 Testing & Integration (2-3 hours)
- Test simple CALL subqueries
- Test nested CALL blocks
- Test WITH integration
- Test error handling

**Estimated time**: 12-20 hours
**Expected test fixes**: 60-70 tests

## Phase 4: FOR Loop Support - 6-12 hours

### 4.1 Parser Completion (2-3 hours)
**Current state**: `parseForStatement` exists but may be incomplete

**Required**: Full FOR...IN syntax with iteration

**Implementation**:
1. Complete FOR parser (already started at line 3554)
2. Handle `FOR item IN collection RETURN ...`
3. Support WITH ORDINALITY and WITH OFFSET
4. Handle nested FOR loops

**Files to modify**:
- `src/gql/parser.zig` - Complete parseForStatement

### 4.2 AST For Loop Node (1-2 hours)
**Required**:
```zig
pub const ForLoop = struct {
    variable: []const u8,
    collection: Expr,
    ordinality_var: ?[]const u8,
    offset_var: ?[]const u8,
    body: []Statement,
};
```

**Files to modify**:
- `src/gql/ast.zig` - Ensure ForLoop is complete

### 4.3 Iterator Execution (3-5 hours)
**Implementation**:
1. Evaluate collection expression
2. Iterate over collection items
3. Bind iteration variable for each item
4. Execute body statements for each iteration
5. Collect and merge results

**Files to modify**:
- `src/execution.zig` - Add `executeForLoop` function

### 4.4 Testing & Integration (1-2 hours)
- Test list iteration
- Test WITH ORDINALITY
- Test nested loops
- Test result collection

**Estimated time**: 6-12 hours
**Expected test fixes**: 10-15 tests

## Phase 5: Other Syntax Features - 4-8 hours

### 5.1 Procedure Definitions
- Parse CREATE PROCEDURE
- Store procedure definitions
- Execute stored procedures

### 5.2 Advanced Constraints
- Complex constraint syntax
- Constraint validation

### 5.3 CDC/TDE Commands
- Specific command syntax
- Command execution

**Estimated time**: 4-8 hours
**Expected test fixes**: 10-20 tests

## Total Implementation Summary

| Phase | Time | Tests Fixed | Cumulative |
|-------|------|-------------|------------|
| 1. Error Detection | 3-4h | 16 | 16 (12%) |
| 2. Output Formats | 2-4h | 18 | 34 (26%) |
| 3. CALL Subqueries | 12-20h | 60-70 | 94-104 (73-81%) |
| 4. FOR Loops | 6-12h | 10-15 | 104-119 (81-93%) |
| 5. Other Syntax | 4-8h | 10-20 | 114-139 (89-100%) |
| **TOTAL** | **27-48h** | **114-139** | **89-100%** |

## Recommended Approach

### Option A: Quick Wins Only (6-8 hours)
- Implement Phases 1 & 2
- Fix 34 tests (26% improvement)
- Pass rate: 77.8% → 80.8%
- **Best for immediate impact**

### Option B: Include CALL (18-28 hours)
- Implement Phases 1, 2, & 3
- Fix 94-104 tests (73-81% of failures)
- Pass rate: 77.8% → 83.3-84.2%
- **Best for substantial progress**

### Option C: Full Implementation (27-48 hours)
- Implement all phases
- Fix 114-139 tests (89-100% of failures)
- Pass rate: 77.8% → 84.5-85.9%
- **Best for complete solution**

## Current Status

✅ **Completed**:
- Critical crash fix (SET all properties)
- Comprehensive failure analysis
- Implementation planning

🔄 **In Progress**:
- None (awaiting direction)

⏳ **Pending**:
- All phases above

## Next Steps

1. Confirm implementation priority (Option A, B, or C)
2. Begin with Phase 1 (Error Detection) as quick wins
3. Progress through phases as time/resources allow
4. Run comprehensive tests after each phase
5. Document progress and remaining issues

---

*Note: This plan represents a production-quality implementation without mocking or simulating data. All fixes implement real functionality in the codebase.*
