# VALUES Clause Implementation

## Overview
Implementation of ISO/IEC 39075:2024 GQL VALUES clause for table value constructors.

**Syntax:** `VALUES (expr1), (expr2), ... AS (col1, col2, ...) [RETURN ...]`

**Status:** Partially implemented - parsing complete, execution pending

## Changes Made

### 1. Token Support (`src/gql/token.zig`)
- **Line 83:** Added `VALUES` token to `TokenKind` enum
- **Line 265:** Added `VALUES` keyword recognition in `keywordKind()` function

### 2. AST Structure (`src/gql/ast.zig`)
- **Line 53:** Added `Values: ValuesStatement` to `Statement` union
- **Lines 495-499:** Added `ValuesStatement` struct:
  ```zig
  pub const ValuesStatement = struct {
      rows: [][]Expr,              // Each row is a list of expressions
      column_names: [][]const u8,  // Column names from AS clause
      next_statement: ?*Statement, // Continuation (MATCH, RETURN, etc.)
  };
  ```

### 3. Parser Support (`src/gql/parser.zig`)
- **Line 285:** Added `.VALUES => self.parseValuesStatement()` to `parseStatement()` switch
- **Lines 3210-3282:** Implemented `parseValuesStatement()` function:
  - Parses `VALUES (expr1), (expr2), ...` rows
  - Handles multi-column rows: `VALUES (1, 'a'), (2, 'b')`
  - Parses `AS (col1, col2, ...)` column name specification
  - Supports statement chaining for `VALUES ... RETURN ...` or `VALUES ... MATCH ...`

### 4. Execution Stub (`src/execution.zig`)
- **Line 897:** Added case for `.Values` (currently routes to NotImplemented)
- **Missing:** `executeValues()` function implementation

## Implementation Status

### ✅ Complete
1. Lexer recognizes VALUES keyword
2. Parser correctly parses VALUES syntax
3. AST structure supports VALUES statements
4. Integration points prepared in execution engine

### ❌ Pending
1. `executeValues()` function implementation
2. Binding table creation from VALUES rows
3. Context passing to next_statement
4. Test coverage

## Next Steps: Complete Implementation

### Step 1: Add executeValues Function (src/execution.zig)

Add after `executeFor()` function (around line 1050):

```zig
fn executeValues(allocator: std.mem.Allocator, values_stmt: ast.ValuesStatement, context: ExecutionContext) !ExecutionResult {
    _ = context;

    // Evaluate all row expressions with empty environment
    const empty_env = eval.Env{
        .names = &.{},
        .values = &.{},
    };

    // Prepare result rows
    var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, values_stmt.rows.len);

    // Evaluate each row
    for (values_stmt.rows) |row_exprs| {
        var row_values = try allocator.alloc(eval.Value, row_exprs.len);
        for (row_exprs, 0..) |expr, i| {
            row_values[i] = try eval.evalExpr(allocator, expr, empty_env);
        }
        try result_rows.append(allocator, row_values);
    }

    // If there's a next statement, execute it with VALUES as context
    if (values_stmt.next_statement) |next_stmt| {
        // TODO: Create binding table and pass to next statement
        // For now, execute next statement normally
        return executeStatement(allocator, next_stmt.*, context);
    }

    // No continuation - return VALUES table directly
    // Copy column names
    var columns = try allocator.alloc([]const u8, values_stmt.column_names.len);
    for (values_stmt.column_names, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}
```

### Step 2: Update execution.zig switch statement

Change line 897 from:
```zig
.Values => |v| {
    return executeValues(allocator, v, context);
},
```

### Step 3: Handle VALUES → MATCH/RETURN chaining

For `VALUES (1), (2) AS (n) MATCH (x) WHERE x.id = n RETURN x`:

1. Create binding table from VALUES
2. Pass bindings to MATCH execution
3. This requires enhancing ExecutionContext or using a different approach

**Option A: Simple approach (for RETURN only)**
```zig
// If next statement is RETURN, evaluate with VALUES bindings
if (values_stmt.next_statement) |next_stmt| {
    switch (next_stmt.*) {
        .Query => |q| {
            // Create environment with column bindings
            // Execute query with this environment
        },
        else => return error.UnsupportedValuesChain,
    }
}
```

**Option B: Full support (requires context enhancement)**
- Enhance ExecutionContext to carry binding tables
- Modify MATCH to check for binding table context
- Cross-product or join VALUES bindings with MATCH results

### Step 4: Testing

Create test file `geodetestlab/specs/values_clause_tests.yml`:

```yaml
tests:
  - name: "values-simple"
    args: ["query", "--no-quic", "VALUES (1), (2), (3) AS (number) RETURN number"]
    expect:
      exit_code: 0
      geode_query:
        row_count: 3
        columns: ["number"]

  - name: "values-multi-column"
    args: ["query", "--no-quic", "VALUES (1, 'a'), (2, 'b') AS (id, letter) RETURN id, letter"]
    expect:
      exit_code: 0
      geode_query:
        row_count: 2
        columns: ["id", "letter"]

  - name: "values-with-expressions"
    args: ["query", "--no-quic", "VALUES (1), (2), (3), (4), (5) AS (number) RETURN number * 2 AS doubled"]
    expect:
      exit_code: 0
      stdout_contains: ["2", "4", "6", "8", "10"]
```

## Test Cases

### Currently Failing
1. `geode_regression_tests.yml::values-with-return` - VALUES (1), (2), (3), (4), (5) AS (number) RETURN number * 2 AS doubled
2. `geode_regression_tests.yml::values-with-match` - VALUES ('Alice'), ('Bob') AS (name) MATCH (p:Person {name: name}) RETURN p

### Expected Behavior
- VALUES should create a temporary binding table
- Column names defined in AS clause
- Can chain with RETURN, MATCH, or other statements
- RETURN accesses VALUES columns directly
- MATCH uses VALUES columns in WHERE clauses

## Architecture Notes

### Current FOR Implementation Pattern
The `executeFor()` function provides a good template:
1. Evaluates collection expression
2. Iterates over items
3. For each item, creates environment with iteration variable
4. Evaluates RETURN clause with that environment
5. Collects results

### VALUES Adaptation
1. Evaluate all row expressions upfront (no iteration)
2. Create binding table with column names
3. If RETURN: evaluate with each row's bindings
4. If MATCH: pass bindings as filter context
5. Collect and return results

## Performance Considerations

1. **Memory:** All VALUES rows evaluated upfront (not lazy)
2. **Optimization opportunity:** If next_statement is MATCH with WHERE, push predicate into VALUES evaluation
3. **Index usage:** VALUES with MATCH should allow index lookups on VALUES columns

## GQL Compliance

- **ISO/IEC 39075:2024 Section 9.4:** Table value constructor
- **Syntax conformance:** ✅ Parsing matches spec
- **Execution conformance:** ⚠️ Pending implementation
- **Integration:** ⚠️ VALUES → MATCH chaining needs design

## Files Modified

1. `src/gql/token.zig` - Added VALUES keyword
2. `src/gql/ast.zig` - Added ValuesStatement struct
3. `src/gql/parser.zig` - Added parseValuesStatement() function
4. `src/execution.zig` - Added execution stub (needs completion)

## Related Work

- FOR clause implementation (reference for similar pattern)
- WITH clause (reference for binding table passing)
- UNWIND (similar concept, but VALUES is table constructor)

## References

- Test specification: `geodetestlab/specs/geode_regression_tests.yml` lines 283-292
- Similar functionality: FOR clause (lines 3284-3400 in parser.zig)
- ISO GQL spec: Section 9.4 Table Value Constructor

---

**Last Updated:** 2025-10-11
**Status:** Parsing complete, execution pending
**Priority:** Medium (2 test failures)
**Estimated Effort:** 2-3 hours for basic RETURN support, 4-6 hours for full MATCH integration
