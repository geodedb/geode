# VALUES → MATCH Chaining Technical Specification

## Overview
Enable GQL queries to chain VALUES clauses with MATCH clauses, allowing bindings from VALUES to be used in subsequent MATCH pattern matching.

## Current Status
- ✅ VALUES statements work independently
- ✅ MATCH statements work independently
- ❌ VALUES → MATCH chaining not supported
- ❌ Bindings from VALUES not propagated to MATCH

## Syntax Examples

### Basic Chaining
```gql
VALUES (1 AS x, 'test' AS name)
MATCH (n:Person {id: x})
RETURN n, x, name
```

### Multiple Rows
```gql
VALUES
  (1 AS id, 'Alice' AS name),
  (2 AS id, 'Bob' AS name)
MATCH (n:Person {id: id})
RETURN n.name, name
```

### Complex Expressions
```gql
VALUES (10 AS threshold)
MATCH (n:Product)
WHERE n.price > threshold
RETURN n
```

## Architecture Changes Required

### 1. Parser Modifications (`src/gql/parser.zig`)

#### Current Implementation
- `parseValuesStatement()` returns `ast.Statement`
- VALUES is parsed as a top-level statement
- No integration with query parsing

#### Required Changes

**A. Extend Query AST to Support VALUES**
```zig
// In ast.zig
pub const Query = struct {
    // ... existing fields ...
    values_clause: ?ValuesClause = null,  // NEW
};

pub const ValuesClause = struct {
    rows: [][]Expr,  // Each row is a list of expressions
    column_names: ?[][]const u8 = null,  // Optional column aliases
};
```

**B. Modify Query Parser**
```zig
fn parseQuery(self: *Parser) ParserError!ast.Query {
    var values_clause: ?ast.ValuesClause = null;

    // Check if query starts with VALUES
    if (self.cur.kind == .VALUES) {
        values_clause = try self.parseValuesClause();
    }

    // Continue with existing MATCH/WHERE/RETURN parsing
    var match_pattern: ?ast.GraphPattern = null;
    if (self.cur.kind == .MATCH or self.cur.kind == .OPTIONAL) {
        // ... existing match parsing ...
    }

    return ast.Query{
        .values_clause = values_clause,
        .match = match_pattern,
        // ... other fields ...
    };
}

fn parseValuesClause(self: *Parser) ParserError!ast.ValuesClause {
    _ = try self.expect(.VALUES);

    var rows = std.ArrayList([]ast.Expr).init(self.arena.allocator());
    var column_names: ?[][]const u8 = null;

    // Parse first row to extract column names
    _ = try self.expect(.l_paren);
    var first_row = std.ArrayList(*ast.Expr).init(self.arena.allocator());
    var names = std.ArrayList([]const u8).init(self.arena.allocator());

    while (self.cur.kind != .r_paren) {
        const expr = try self.parseExpr();
        try first_row.append(expr);

        // Check for AS alias
        if (self.cur.kind == .AS) {
            self.advance();
            const name = try self.expect(.identifier);
            try names.append(name.lexeme);
        } else {
            try names.append(""); // Unnamed column
        }

        if (self.cur.kind == .comma) {
            self.advance();
        } else {
            break;
        }
    }
    _ = try self.expect(.r_paren);

    try rows.append(try first_row.toOwnedSlice());
    if (names.items.len > 0) {
        column_names = try names.toOwnedSlice();
    }

    // Parse additional rows
    while (self.cur.kind == .comma) {
        self.advance();
        _ = try self.expect(.l_paren);

        var row = std.ArrayList(*ast.Expr).init(self.arena.allocator());
        while (self.cur.kind != .r_paren) {
            try row.append(try self.parseExpr());
            if (self.cur.kind == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_paren);

        try rows.append(try row.toOwnedSlice());
    }

    return ast.ValuesClause{
        .rows = try rows.toOwnedSlice(),
        .column_names = column_names,
    };
}
```

### 2. Execution Engine Modifications (`src/execution.zig`)

#### Current Implementation
- `executeValues()` returns result directly
- No binding context propagation
- No integration with MATCH execution

#### Required Changes

**A. Extend ExecutionContext**
```zig
pub const ExecutionContext = struct {
    // ... existing fields ...
    values_bindings: ?std.StringHashMap(eval.Value) = null,  // NEW
};
```

**B. Modify Query Execution**
```zig
fn executeQueryStatement(
    allocator: std.mem.Allocator,
    query: ast.Query,
    context: ExecutionContext,
) !ExecutionResult {
    var current_context = context;

    // Step 1: Execute VALUES clause if present
    if (query.values_clause) |values_clause| {
        const values_bindings = try evaluateValuesBindings(
            allocator,
            values_clause,
        );

        // Store bindings in context
        current_context.values_bindings = values_bindings;
    }

    // Step 2: Execute MATCH with VALUES bindings available
    if (query.match) |match_pattern| {
        // Pass context with VALUES bindings
        return try executeMatch(
            allocator,
            match_pattern,
            query,
            current_context,  // Context now includes VALUES bindings
        );
    }

    // If only VALUES (no MATCH), return VALUES result
    if (query.values_clause) |values_clause| {
        return try executeStandaloneValues(allocator, values_clause);
    }

    // ... handle other cases ...
}

fn evaluateValuesBindings(
    allocator: std.mem.Allocator,
    values_clause: ast.ValuesClause,
) !std.StringHashMap(eval.Value) {
    var bindings = std.StringHashMap(eval.Value).init(allocator);

    // For VALUES → MATCH chaining, we only support single-row VALUES
    // (multi-row would require cartesian product with MATCH results)
    if (values_clause.rows.len != 1) {
        return error.MultiRowValuesNotSupportedInChaining;
    }

    const row = values_clause.rows[0];
    const names = values_clause.column_names orelse return bindings;

    // Evaluate each expression and bind to its alias
    for (row, 0..) |expr, i| {
        if (i >= names.len) break;
        const name = names[i];
        if (name.len == 0) continue;  // Skip unnamed columns

        const value = try eval.evalExpr(
            allocator,
            expr.*,
            eval.emptyEnv(),
        );

        try bindings.put(name, value);
    }

    return bindings;
}
```

**C. Modify MATCH Execution to Use VALUES Bindings**
```zig
fn executeMatch(
    allocator: std.mem.Allocator,
    pattern: ast.GraphPattern,
    query: ast.Query,
    context: ExecutionContext,
) !ExecutionResult {
    var store = graph_store.getGlobalStore(allocator);
    var matched_nodes = std.ArrayList(*const graph_store.Node).init(allocator);
    defer matched_nodes.deinit();

    // Create environment with VALUES bindings if present
    var env = eval.Env.init(allocator);
    defer env.deinit();

    if (context.values_bindings) |bindings| {
        var iter = bindings.iterator();
        while (iter.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // Rest of MATCH execution continues with enriched environment
    // WHERE clause expressions can now reference VALUES bindings
    // ...
}
```

### 3. Expression Evaluation Integration (`src/eval.zig`)

#### Required Changes

**Ensure Variable Resolution Checks VALUES Bindings**

The existing `evalExpr()` function already supports environment lookup for identifiers. No changes needed here if the environment is properly populated from VALUES bindings.

```zig
// In evalExpr, .Ident case (already exists, just needs proper env):
.Ident => |ident| {
    // This will automatically resolve VALUES bindings if in env
    if (env.get(ident.orig)) |val| {
        return val;
    }
    return .{ .Null = {} };
},
```

### 4. Multi-Row VALUES Handling (Future Enhancement)

For multiple rows in VALUES with MATCH, we need cartesian product:

```gql
VALUES
  (1 AS x),
  (2 AS x)
MATCH (n:Person {id: x})
RETURN n, x
```

Should return results for both x=1 and x=2.

**Implementation Approach:**
1. Execute MATCH once per VALUES row
2. Collect all results
3. Combine into single result set
4. Maintain correspondence between VALUES row and MATCH results

```zig
fn executeValuesMatchCartesian(
    allocator: std.mem.Allocator,
    values_clause: ast.ValuesClause,
    query: ast.Query,
    context: ExecutionContext,
) !ExecutionResult {
    var all_rows = std.ArrayList([]eval.Value).init(allocator);
    defer all_rows.deinit();

    // Execute MATCH for each VALUES row
    for (values_clause.rows) |row| {
        // Create bindings for this row
        var row_bindings = std.StringHashMap(eval.Value).init(allocator);
        defer row_bindings.deinit();

        const names = values_clause.column_names orelse continue;
        for (row, 0..) |expr, i| {
            if (i >= names.len) break;
            const name = names[i];
            if (name.len == 0) continue;

            const value = try eval.evalExpr(allocator, expr.*, eval.emptyEnv());
            try row_bindings.put(name, value);
        }

        // Execute MATCH with these bindings
        var row_context = context;
        row_context.values_bindings = row_bindings;

        const match_result = try executeMatch(
            allocator,
            query.match.?,
            query,
            row_context,
        );
        defer match_result.deinit(allocator);

        // Append results
        for (match_result.rows) |result_row| {
            try all_rows.append(result_row);
        }
    }

    return ExecutionResult{
        .columns = query.ret.items,  // Column names from RETURN
        .rows = try all_rows.toOwnedSlice(),
        .flags = std.ArrayList([]const u8).init(allocator),
    };
}
```

## Testing Strategy

### Unit Tests

**Test 1: Single Row VALUES → MATCH**
```zig
test "VALUES single row with MATCH" {
    const query = "VALUES (1 AS x) MATCH (n:Person {id: x}) RETURN n, x";
    // Verify:
    // - Parser accepts syntax
    // - Execution binds x=1
    // - MATCH uses x in pattern
    // - Result includes both n and x columns
}
```

**Test 2: VALUES Binding in WHERE**
```zig
test "VALUES binding in WHERE clause" {
    const query =
        \\VALUES (10 AS threshold)
        \\MATCH (n:Product)
        \\WHERE n.price > threshold
        \\RETURN n
    ;
    // Verify WHERE clause can access threshold
}
```

**Test 3: Multi-Row VALUES**
```zig
test "VALUES multiple rows with MATCH" {
    const query =
        \\VALUES (1 AS x), (2 AS x)
        \\MATCH (n:Person {id: x})
        \\RETURN n.name, x
    ;
    // Verify cartesian product behavior
}
```

**Test 4: Complex Expressions in VALUES**
```zig
test "VALUES with expressions" {
    const query =
        \\VALUES (1 + 1 AS computed, 'test' AS label)
        \\MATCH (n:Node)
        \\WHERE n.count = computed
        \\RETURN n, label
    ;
    // Verify expressions evaluated before MATCH
}
```

### Integration Tests (geodetestlab)

Add spec file: `geodetestlab/specs/values_match_chaining.yml`

```yaml
name: values-match-chaining
description: Test VALUES → MATCH binding propagation

tests:
  - name: basic-values-match
    args: ["query", "--no-quic"]
    stdin: |
      CREATE (p:Person {id: 1, name: 'Alice'});
      VALUES (1 AS search_id)
      MATCH (n:Person {id: search_id})
      RETURN n.name, search_id
    expect:
      exit_code: 0
      stdout_contains:
        - "Alice"
        - "1"

  - name: values-where-integration
    args: ["query", "--no-quic"]
    stdin: |
      CREATE (p1:Product {price: 15}), (p2:Product {price: 25});
      VALUES (20 AS max_price)
      MATCH (p:Product)
      WHERE p.price < max_price
      RETURN p.price
    expect:
      exit_code: 0
      stdout_contains:
        - "15"
      stdout_not_contains:
        - "25"
```

## Implementation Checklist

### Phase 1: Parser (2-3 hours)
- [ ] Add `ValuesClause` to AST
- [ ] Extend `Query` struct with `values_clause` field
- [ ] Implement `parseValuesClause()` function
- [ ] Modify `parseQuery()` to check for VALUES at start
- [ ] Add unit tests for parser

### Phase 2: Execution Engine (2-3 hours)
- [ ] Extend `ExecutionContext` with `values_bindings`
- [ ] Implement `evaluateValuesBindings()` function
- [ ] Modify `executeQueryStatement()` to handle VALUES → MATCH
- [ ] Update `executeMatch()` to populate env from VALUES bindings
- [ ] Add error handling for unsupported cases

### Phase 3: Testing (1-2 hours)
- [ ] Add unit tests for single-row VALUES → MATCH
- [ ] Add unit tests for bindings in WHERE clauses
- [ ] Add geodetestlab integration tests
- [ ] Test edge cases (empty VALUES, no aliases, etc.)

### Phase 4: Multi-Row Support (Optional, 2-3 hours)
- [ ] Implement cartesian product for multi-row VALUES
- [ ] Add tests for multi-row scenarios
- [ ] Document performance considerations

## Performance Considerations

### Memory
- VALUES bindings stored in ExecutionContext (small overhead)
- Single-row: O(n) where n = number of columns
- Multi-row: O(n × m) where m = number of MATCH results per row

### Execution Time
- Single-row: Negligible overhead (one-time binding evaluation)
- Multi-row: O(m) where m = number of VALUES rows (MATCH executed m times)

### Optimization Opportunities
1. **Binding Cache**: For repeated VALUES expressions, cache evaluated values
2. **Push-down**: If MATCH pattern directly uses VALUES binding, push filter to node scan
3. **Batch Execution**: For multi-row, batch MATCH executions if possible

## Standards Compliance

### ISO/IEC 39075:2024 (GQL)
Section covering VALUES in query composition:
- VALUES must support aliasing (AS keyword)
- Bindings must be accessible in subsequent clauses
- Multi-row VALUES should behave as table constructor

### Compatibility Notes
- Neo4j doesn't directly support VALUES → MATCH but has similar WITH clause behavior
- This implementation follows GQL standard more closely than Neo4j
- Syntax is compatible with RETURN clause patterns

## Error Handling

### Parse Errors
- `error.UnexpectedToken` - Malformed VALUES syntax
- `error.MissingAlias` - VALUES expression without AS in chaining context

### Execution Errors
- `error.MultiRowValuesNotSupportedInChaining` - Multi-row with MATCH (phase 1)
- `error.BindingConflict` - VALUES alias conflicts with MATCH variable
- `error.UnresolvedBinding` - MATCH references undefined VALUES binding

## Future Enhancements

1. **VALUES with CREATE**
   ```gql
   VALUES (1 AS id, 'Alice' AS name)
   CREATE (p:Person {id: id, name: name})
   ```

2. **Nested VALUES in Subqueries**
   ```gql
   MATCH (n)
   WHERE n.id IN (VALUES (1), (2), (3))
   ```

3. **VALUES in UNION**
   ```gql
   VALUES (1 AS x) MATCH (n {id: x})
   UNION
   VALUES (2 AS x) MATCH (n {id: x})
   ```

## CANARY Marker

```zig
// CANARY: REQ=REQ-GQL-VALUES-MATCH-001; FEATURE="ValuesMatchChaining"; ASPECT=BindingPropagation; STATUS=SPEC; TEST=TestValuesMatchBasic|TestValuesMatchWhere|TestValuesMatchMultiRow; OWNER=engine; UPDATED=2025-10-11
```

## References

- [GQL Standard ISO/IEC 39075:2024](https://www.iso.org/standard/76120.html) - Section on query composition
- [Geode Parser Architecture](../src/gql/parser.zig)
- [Geode Execution Engine](../src/execution.zig)
- [AST Definitions](../src/gql/ast.zig)

---

**Document Status**: Specification Complete, Implementation Pending
**Last Updated**: 2025-10-11
**Estimated Implementation Time**: 6-8 hours (including testing)
