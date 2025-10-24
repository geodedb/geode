# CREATE...WITH Clause Fix - October 2025

## Date: October 9, 2025

## Overview

Implemented support for CREATE followed by WITH/SET/REMOVE clauses, enabling proper variable propagation from CREATE statements to subsequent query clauses.

**Impact**: +1 test (1359/1630 passing, 83.37% pass rate)

---

## Problem

Queries combining CREATE with WITH clause were not working correctly. The WITH clause wasn't receiving variable bindings from the CREATE statement.

### Example of the Bug

```gql
-- This should return the created node but was returning null:
CREATE (n:Test {value: 1}) WITH n RETURN n
-- Expected: {"id":1,"labels":["Test"],"properties":{"value":1}}
-- Actual: null

-- This should create and update but was returning null:
CREATE (n:Test) WITH n SET n.updated = true RETURN n
-- Expected: {"id":1,"labels":["Test"],"properties":{"updated":true}}
-- Actual: null
```

### Root Cause

Two issues were preventing CREATE...WITH from working:

1. **Parser Issue**: When `parseStatement()` encountered CREATE, it called `parseCreateStatement()` which only checked for an optional RETURN clause. It didn't check for WITH, SET, or REMOVE clauses.
   - File: `/home/benji/src/spyder/geode/src/gql/parser.zig:2027-2086`
   - CREATE...WITH was being parsed as a standalone CreateStatement
   - The WITH clause was never parsed at all

2. **Execution Issue**: Even when CREATE pattern was in a Query (via the `create_pattern` field), the execution engine wasn't properly passing the WITH result to RETURN.
   - File: `/home/benji/src/spyder/geode/src/execution.zig:1532`
   - The WITH result was created but then discarded
   - RETURN used `created_nodes` directly instead of the WITH result

---

## Solution

### Part 1: Parser Fix

**File**: `src/gql/parser.zig:2067-2130`

Modified `parseCreateStatement()` to detect WITH/SET/REMOVE after CREATE and return a Query instead of a CreateStatement:

```zig
// CANARY: REQ=REQ-GQL-083; FEATURE="CreateWithClause"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-09
// Check if this is followed by WITH, SET, or REMOVE
if (self.cur.kind == .WITH or self.cur.kind == .SET or self.cur.kind == .REMOVE) {
    // Parse WITH clause if present
    var with_clause: ?ast.WithClause = null;
    if (self.cur.kind == .WITH) {
        self.advance();
        var witems = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        try self.parseProjectionItems(&witems);
        with_clause = .{ .items = try witems.toOwnedSlice(self.arena.allocator()) };
    }

    // Parse SET and REMOVE clauses...
    // Parse RETURN clause...

    // Return a Query with create_pattern set
    return .{ .Query = .{
        .optional_match = false,
        .match = .{ .chains = &.{} },  // Empty match pattern
        .create_pattern = pattern,      // CREATE pattern goes here
        .where_clause = null,
        .with_clause = with_clause,
        .set_clauses = set_clauses,
        .remove_clauses = remove_clauses,
        .ret = return_clause,
        .order_by = null,
        .limit = null,
        .offset = null,
    } };
}
```

### Part 2: Execution Fix

**File**: `src/execution.zig:1531-1583`

Modified `executeCreateQuery()` to use the WITH result as the environment for RETURN:

```zig
// CANARY: REQ=REQ-GQL-083; FEATURE="CreateWithClause"; ASPECT=VariablePropagation; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
if (q.with_clause != null) {
    // WITH clause creates a result that filters/transforms the created nodes
    // RETURN should evaluate in the context of the WITH result
    var return_columns = try allocator.alloc([]const u8, q.ret.items.len);
    // ... (column name handling)

    // Evaluate RETURN items using the WITH result as environment
    var return_rows = try allocator.alloc([]eval.Value, result.rows.len);
    for (result.rows, 0..) |with_row, row_idx| {
        var return_row = try allocator.alloc(eval.Value, q.ret.items.len);

        // Create environment from WITH result columns and this row's values
        const env = eval.Env{
            .names = result.columns,
            .values = with_row,
        };

        for (q.ret.items, 0..) |item, col_idx| {
            return_row[col_idx] = try eval.evalExpr(allocator, item.expr, env);
        }
        return_rows[row_idx] = return_row;
    }

    // Return the RETURN result (not the WITH result)
    return ExecutionResult{
        .columns = return_columns,
        .rows = return_rows,
        .flags = result.flags,
    };
} else {
    // No WITH clause - use created nodes directly for RETURN
    return executeReturnClauseWithNodes(allocator, q.ret, created_nodes);
}
```

Also updated SET clause handling to use WITH result when present (lines 1472-1521).

---

## Testing

### Manual Testing

```bash
# Test 1: Basic CREATE WITH RETURN
$ ./zig-out/bin/geode query --no-quic "CREATE (n:Test {value: 1}) WITH n RETURN n"
{"status_class":"00000","columns":["n"],"rows":[[{"id":84,"labels":["Test"],"properties":{"value":1}}]]} ✓

# Test 2: CREATE WITH SET RETURN
$ ./zig-out/bin/geode query --no-quic "CREATE (n:Test {value: 1}) WITH n SET n.updated = true RETURN n"
{"status_class":"00000","columns":["n"],"rows":[[{"id":85,"labels":["Test"],"properties":{"value":1,"updated":true}}]]} ✓

# Test 3: Multiple nodes with WITH
$ ./zig-out/bin/geode query --no-quic "CREATE (a:Node {x: 1}), (b:Node {x: 2}) WITH a, b RETURN a, b"
{"status_class":"00000","columns":["a","b"],"rows":[[{"id":86,"labels":["Node"],"properties":{"x":1}},{"id":87,"labels":["Node"],"properties":{"x":2}}]]} ✓

# Test 4: WITH filtering (only return 'a')
$ ./zig-out/bin/geode query --no-quic "CREATE (a:Node {x: 1}), (b:Node {x: 2}) WITH a RETURN a"
{"status_class":"00000","columns":["a"],"rows":[[{"id":88,"labels":["Node"],"properties":{"x":1}}]]} ✓

# Test 5: CREATE WITH REMOVE RETURN
$ ./zig-out/bin/geode query --no-quic "CREATE (n:Test {a: 1, b: 2}) WITH n REMOVE n.b RETURN n"
{"status_class":"00000","columns":["n"],"rows":[[{"id":90,"labels":["Test"],"properties":{"a":1}}]]} ✓

# Test 6: Multiple SET clauses
$ ./zig-out/bin/geode query --no-quic "CREATE (n:Test {x: 1}) WITH n SET n.x = 2, n.y = 3 RETURN n"
{"status_class":"00000","columns":["n"],"rows":[[{"id":91,"labels":["Test"],"properties":{"x":2,"y":3}}]]} ✓
```

### Automated Testing

```bash
$ python3 parallel_test_runner.py

Total tests: 1630
Passed: 1359 (+1 from previous run)
Failed: 252
Skipped: 34
Pass rate: 83.37% (+0.07%)
```

---

## Implementation Details

### Memory Management

Important note: The WITH result columns contain strings from the parser's arena allocator. We must NOT free individual column strings, only the array itself:

```zig
// Clean up WITH result arrays (note: column names are from parser arena, don't free them)
allocator.free(result.columns);  // Free the array
for (result.rows) |row| {
    allocator.free(row);
}
allocator.free(result.rows);
```

Initial implementation tried to free column strings, causing "Invalid free" panics.

### Query Flow

The complete flow for `CREATE (n) WITH n SET n.x = 1 RETURN n`:

1. **Parser**: Creates Query with:
   - `create_pattern` = pattern for `(n)`
   - `with_clause` = WITH clause with item `n`
   - `set_clauses` = SET clause for `n.x = 1`
   - `ret` = RETURN clause for `n`

2. **Execution - executeQueryWithContext()**: Detects `create_pattern` and calls `executeCreateQuery()`

3. **Execution - executeCreateQuery()**:
   - Creates node, stores in `created_nodes["n"]`
   - Evaluates WITH clause: creates result with column "n" and row containing the node
   - Evaluates SET clause: uses WITH result as environment, modifies node
   - Evaluates RETURN clause: uses WITH result as environment, returns node

---

## Architecture Improvements

### Before

```
CREATE (n) WITH n RETURN n
    ↓
parseCreateStatement()
    ↓
Returns: CreateStatement{pattern, return_clause}
    ↓
executeCreate()
    ↓
Problem: WITH never parsed
```

### After

```
CREATE (n) WITH n RETURN n
    ↓
parseCreateStatement()
    ↓
Detects WITH → Returns: Query{create_pattern, with_clause, ret}
    ↓
executeQueryWithContext()
    ↓
Detects create_pattern → executeCreateQuery()
    ↓
Creates nodes → Evaluates WITH → Uses WITH result for RETURN
    ↓
Returns: ExecutionResult with proper variable bindings
```

---

## ISO/IEC 39075:2024 Compliance

Per the GQL standard, CREATE can be followed by:
- WITH clause (for variable projection)
- SET clause (for property updates)
- REMOVE clause (for property/label removal)
- RETURN clause (for result projection)

This implementation provides full support for:
- ✅ CREATE ... WITH ... RETURN
- ✅ CREATE ... WITH ... SET ... RETURN
- ✅ CREATE ... WITH ... REMOVE ... RETURN
- ✅ CREATE ... SET ... RETURN (without WITH)
- ✅ CREATE ... REMOVE ... RETURN (without WITH)

---

## Related Issues

- Previously working: `CREATE (n) RETURN n` (standalone CREATE with RETURN)
- Now working: `CREATE (n) WITH n RETURN n` (CREATE with WITH and RETURN)
- Still needed: Full WITH clause support in MATCH queries (already works for simple cases)

---

## Next Steps

1. ✅ CREATE...WITH support (this fix)
2. 📋 **Memory bug fixes** - Invalid free and alignment issues (8 tests)
3. 📋 **Regex operators** - Implement `=~` and `!~` operators (~10 tests)
4. 📋 **CALL subqueries** - Complete CALL { ... } YIELD syntax (~8 tests)

---

*Last Updated: October 9, 2025*
*Status: COMPLETE - CREATE WITH clause support implemented and tested*
