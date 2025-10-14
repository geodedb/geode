# Implementation Plan: Remaining Test Fixes

## Executive Summary

This document provides a prioritized, actionable plan to address the 32 remaining test failures. Fixes are organized by feasibility, impact, and dependencies.

**Current Status**: 1623/1655 passing (98.1%)
**Target**: 1645+/1655 passing (99%+)
**Estimated Timeline**: 4-8 weeks for high-priority items

## Priority Matrix

| Priority | Tests | Complexity | Impact | Timeline |
|----------|-------|------------|--------|----------|
| **P0** | 4 | Low | High | 1 week |
| **P1** | 2 | Low-Med | Medium | 1 week |
| **P2** | 6 | Medium | Medium | 2-3 weeks |
| **P3** | 13 | High | Low-Med | 4-6 weeks |
| **P4** | 7 | Very High | Low | 6-12 weeks |

## Phase 1: Quick Wins (P0) - Week 1

### Target: +4 tests (1623 → 1627 passing)

### 1.1 CREATE OR REPLACE Support (2 tests)

**Tests Fixed**:
- `create-or-replace-graph`
- `catalog-workflow-schema-graph`

**Current Behavior**:
```bash
$ ./zig-out/bin/geode query "CREATE OR REPLACE GRAPH test_graph ANY"
error: Duplicate graph name
```

**Root Cause**: Parser recognizes syntax but execution doesn't check `or_replace` flag

**Implementation Steps**:

1. **Verify AST has or_replace flag** (10 min)
   ```bash
   grep -n "or_replace" src/gql/ast.zig
   ```

2. **Update executeCreateGraph** (1 hour)
   ```zig
   // File: src/execution.zig, function: executeCreateGraph

   fn executeCreateGraph(allocator: std.mem.Allocator, create_stmt: ast.CreateGraph) !ExecutionResult {
       initCatalog();
       catalog_mutex.lock();
       defer catalog_mutex.unlock();

       const graph_name = create_stmt.name;

       // NEW: Handle OR REPLACE
       if (create_stmt.or_replace) {
           // Check if graph exists
           if (global_catalog.graphs.contains(graph_name)) {
               // Remove existing graph
               _ = global_catalog.graphs.remove(graph_name);
           }
       } else {
           // Original duplicate check
           if (global_catalog.graphs.contains(graph_name)) {
               return error.DuplicateGraph;
           }
       }

       // Proceed with creation
       try global_catalog.graphs.put(allocator, graph_name, GraphMetadata{
           .name = try allocator.dupe(u8, graph_name),
           .graph_type = create_stmt.graph_type,
       });

       // Return success
       // ...
   }
   ```

3. **Similar fix for CREATE OR REPLACE SCHEMA** (30 min)
   ```zig
   fn executeCreateSchema(allocator: std.mem.Allocator, create_stmt: ast.CreateSchema) !ExecutionResult {
       // Same pattern: check or_replace flag
       if (create_stmt.or_replace and schemaExists(schema_name)) {
           try dropSchema(schema_name);
       }
       // Continue with creation
   }
   ```

4. **Test** (30 min)
   ```bash
   # Test create, then create or replace
   ./zig-out/bin/geode query "CREATE GRAPH test_graph ANY" --no-quic
   ./zig-out/bin/geode query "CREATE OR REPLACE GRAPH test_graph ANY" --no-quic

   # Should succeed both times
   ```

**Files Modified**:
- `src/execution.zig` - executeCreateGraph, executeCreateSchema

**Estimated Time**: 2 hours
**Risk**: Low
**Testing**: Create graph twice with OR REPLACE

### 1.2 Boolean Property Comparison (1 test)

**Test Fixed**: `label-test-or-with-property`

**Current Behavior**:
```bash
$ ./zig-out/bin/geode query \
  "CREATE (p:Person {active: true})
   MATCH (n) WHERE n.active = true RETURN n"
error: Type mismatch in expression
```

**Root Cause**: Boolean property stored as ExtValue, comparison with boolean literal fails type check

**Implementation Steps**:

1. **Locate comparison evaluation** (15 min)
   ```bash
   grep -n "evalBinaryOp.*Eq" src/eval.zig
   ```

2. **Add type coercion for boolean comparisons** (2 hours)
   ```zig
   // File: src/eval.zig, function: evalBinaryOp or evalExpr

   fn evalBinaryOp(allocator: std.mem.Allocator, op: BinaryOp, left: Value, right: Value) !Value {
       return switch (op) {
           .Eq => {
               // Handle boolean comparisons
               if (left == .Bool and right == .ExtValue) {
                   // Try to extract bool from ExtValue
                   if (right.ExtValue == .Bool) {
                       return .{ .Bool = left.Bool == right.ExtValue.Bool };
                   }
               }
               if (left == .ExtValue and right == .Bool) {
                   if (left.ExtValue == .Bool) {
                       return .{ .Bool = left.ExtValue.Bool == right.Bool };
                   }
               }
               if (left == .ExtValue and right == .ExtValue) {
                   // Both ExtValues, compare if both Bool
                   if (left.ExtValue == .Bool and right.ExtValue == .Bool) {
                       return .{ .Bool = left.ExtValue.Bool == right.ExtValue.Bool };
                   }
               }

               // Existing comparison logic
               return evalEquality(left, right);
           },
           // ...
       };
   }
   ```

3. **Test various boolean comparisons** (30 min)
   ```bash
   ./zig-out/bin/geode query "
     CREATE (p:Person {active: true, inactive: false})
     MATCH (n) WHERE n.active = true RETURN n.active
   " --no-quic

   # Test inequality
   ./zig-out/bin/geode query "
     CREATE (p:Person {active: true})
     MATCH (n) WHERE n.active != false RETURN n
   " --no-quic
   ```

**Files Modified**:
- `src/eval.zig` - evalBinaryOp or comparison function

**Estimated Time**: 3 hours
**Risk**: Medium (could affect other comparisons)
**Testing**: Create comprehensive boolean comparison tests

### 1.3 Rewrite Test Infrastructure Tests (2 tests)

**Tests Fixed**:
- `values-with-match`
- `split-node-into-multiple`

**Current Issue**: Setup commands don't persist in --no-quic mode

**Solution**: Combine all operations into single query

**Implementation Steps**:

1. **Update test spec for values-with-match** (15 min)
   ```yaml
   # File: geodetestlab/specs/geode_regression_tests.yml

   - name: values-with-match
     args:
       - "query"
       - "--no-quic"
       - |
         CREATE (a:Person {name: 'Alice'}),
                (b:Person {name: 'Bob'}),
                (c:Person {name: 'Charlie'})
         WITH a, b, c
         VALUES ('Alice'), ('Bob'), ('Charlie') AS (name)
         MATCH (p:Person {name: name})
         RETURN p
     expect:
       exit_code: 0
       stdout_contains: ["Person"]
   ```

2. **Update test spec for split-node-into-multiple** (15 min)
   ```yaml
   # File: geodetestlab/specs/geode_migrations.yml

   - name: split-node-into-multiple
     args:
       - "query"
       - "--no-quic"
       - |
         CREATE (p:Person {name: 'John', type: 'employee', department: 'Engineering'})
         WITH p
         MATCH (person:Person) WHERE person.type = 'employee'
         CREATE (e:Employee {name: person.name}),
                (d:Department {name: person.department})
         CREATE (e)-[:WORKS_IN]->(d)
         DELETE person
         RETURN count(e) AS count
     expect:
       exit_code: 0
       stdout_contains: ["1"]
   ```

**Files Modified**:
- `geodetestlab/specs/geode_regression_tests.yml`
- `geodetestlab/specs/geode_migrations.yml`

**Estimated Time**: 1 hour
**Risk**: Low (test-only changes)
**Testing**: Run updated tests

**Phase 1 Total**: 6 hours (1 work day)
**Expected Improvement**: 1627/1655 passing (98.3%)

## Phase 2: Parser Extensions (P1) - Week 2

### Target: +2 tests (1627 → 1629 passing)

### 2.1 Map Literal Syntax (1 test)

**Test Fixed**: `type-map-values`

**Current Behavior**:
```bash
$ ./zig-out/bin/geode query "RETURN values({name: 'Alice'})"
error: Syntax error
```

**Implementation Steps**:

1. **Update lexer to recognize { in expression context** (2 hours)
   ```zig
   // File: src/gql/lexer.zig

   // Already handles { for patterns, need context awareness
   // May need to track parser state or use lookahead
   ```

2. **Add map literal parsing** (4 hours)
   ```zig
   // File: src/gql/parser.zig

   fn parsePrimaryExpr(self: *Parser) !ast.Expr {
       return switch (self.cur.kind) {
           // ... existing cases
           .l_brace => try self.parseMapLiteral(),
           // ...
       };
   }

   fn parseMapLiteral(self: *Parser) !ast.Expr {
       _ = try self.expect(.l_brace);

       var keys = std.ArrayList([]const u8).init(self.arena.allocator());
       var values = std.ArrayList(ast.Expr).init(self.arena.allocator());

       while (self.cur.kind != .r_brace and self.cur.kind != .eof) {
           // Parse key (identifier or string)
           if (self.cur.kind != .identifier and self.cur.kind != .string_lit) {
               return self.unexpected("expected map key");
           }
           const key = self.cur.lexeme;
           self.advance();

           _ = try self.expect(.colon);

           // Parse value expression
           const value = try self.parseOrExpr();

           try keys.append(key);
           try values.append(value);

           if (self.cur.kind == .comma) {
               self.advance();
           } else {
               break;
           }
       }

       _ = try self.expect(.r_brace);

       return .{ .MapLiteral = .{
           .keys = try keys.toOwnedSlice(),
           .values = try values.toOwnedSlice(),
       }};
   }
   ```

3. **Add MapLiteral to AST** (30 min)
   ```zig
   // File: src/gql/ast.zig

   pub const Expr = union(enum) {
       // ... existing variants
       MapLiteral: struct {
           keys: [][]const u8,
           values: []Expr,
       },
       // ...
   };
   ```

4. **Add map literal evaluation** (2 hours)
   ```zig
   // File: src/eval.zig

   pub fn evalExpr(allocator: std.mem.Allocator, expr: ast.Expr, env: Env) !Value {
       return switch (expr) {
           // ... existing cases
           .MapLiteral => |map_lit| {
               var map = std.StringHashMap(Value).init(allocator);

               for (map_lit.keys, map_lit.values) |key, value_expr| {
                   const value = try evalExpr(allocator, value_expr, env);
                   try map.put(key, value);
               }

               return .{ .Map = map };
           },
           // ...
       };
   }
   ```

5. **Implement values() function** (1 hour)
   ```zig
   // File: src/eval_functions.zig or src/eval.zig

   fn builtinValues(allocator: std.mem.Allocator, args: []Value) !Value {
       if (args.len != 1) return error.WrongArgumentCount;

       if (args[0] != .Map) return error.TypeMismatch;

       const map = args[0].Map;
       var values_list = try std.ArrayList(Value).initCapacity(allocator, map.count());

       var iter = map.valueIterator();
       while (iter.next()) |value| {
           try values_list.append(value.*);
       }

       return .{ .List = try values_list.toOwnedSlice() };
   }
   ```

**Files Modified**:
- `src/gql/lexer.zig` - Context-aware { tokenization
- `src/gql/parser.zig` - parseMapLiteral
- `src/gql/ast.zig` - MapLiteral variant
- `src/eval.zig` - evalExpr for MapLiteral, values() function

**Estimated Time**: 10 hours (1.5 days)
**Risk**: Medium (parser changes)
**Testing**: Map literals in various contexts

### 2.2 Deep Nesting Support (1 test)

**Test Fixed**: `extremely-deep-nesting`

**Current Issue**: Deep CALL nesting likely hits recursion limits

**Implementation Steps**:

1. **Identify recursion depth** (30 min)
   ```bash
   # Test with debug output
   ./zig-out/bin/geode query --no-quic "
     CALL {
       CALL {
         CALL {
           CALL {
             RETURN 1 AS x
           } RETURN x
         } RETURN x
       } RETURN x
     } RETURN x
   "
   ```

2. **Increase setEvalBranchQuota** (15 min)
   ```zig
   // File: src/test_harness.zig or src/execution.zig

   @setEvalBranchQuota(5000); // Increase from 2000
   ```

3. **Or implement iterative CALL evaluation** (4 hours)
   ```zig
   // Convert recursive CALL evaluation to iterative with explicit stack
   fn executeCallSubquery(allocator: std.mem.Allocator, subquery: ast.Query, context: ExecutionContext) !ExecutionResult {
       // Use explicit stack instead of recursion
       var call_stack = std.ArrayList(CallFrame).init(allocator);
       defer call_stack.deinit();

       // Push initial call
       try call_stack.append(.{ .query = subquery, .context = context });

       while (call_stack.items.len > 0) {
           const frame = call_stack.pop();
           // Execute frame, push nested calls if any
       }
   }
   ```

**Files Modified**:
- `src/test_harness.zig` or `src/execution.zig`

**Estimated Time**: 5 hours
**Risk**: Low (increase quota) to Medium (iterative evaluation)
**Testing**: Nested CALL blocks

**Phase 2 Total**: 15 hours (2 days)
**Expected Improvement**: 1629/1655 passing (98.4%)

## Phase 3: Set Operations and Complex Queries (P2) - Weeks 3-4

### Target: +2 tests (1629 → 1631 passing)

### 3.1 Mixed Set Operations (1 test)

**Test**: `mixed-set-operations`

**Query Example**:
```sql
(MATCH (a:A) RETURN a.id UNION MATCH (b:B) RETURN b.id)
INTERSECT
(MATCH (c:C) RETURN c.id)
```

**Implementation Steps**:

1. **Verify parenthesized set operations parsing** (1 hour)
   ```zig
   // Parser should handle (query) UNION (query) INTERSECT (query)
   ```

2. **Implement precedence/associativity for set ops** (4 hours)
   ```zig
   // INTERSECT has higher precedence than UNION
   // Need to parse correctly: A UNION B INTERSECT C = A UNION (B INTERSECT C)
   ```

3. **Test execution of mixed operations** (2 hours)

**Estimated Time**: 7 hours (1 day)

### 3.2 Set Operations with Subqueries (1 test)

**Test**: `set-operations-with-subqueries`

**Query Example**:
```sql
MATCH (a:A) WHERE a.id IN (MATCH (x:X) RETURN x.id)
RETURN a.id
UNION
MATCH (b:B) WHERE b.id IN (MATCH (y:Y) RETURN y.id)
RETURN b.id
```

**Implementation Steps**:

1. **Ensure IN with subquery works** (3 hours)
   ```zig
   // IN operator should accept List or subquery result
   ```

2. **Test complex nesting** (2 hours)

**Estimated Time**: 5 hours

**Phase 3 Total**: 12 hours (1.5 days)
**Expected Improvement**: 1631/1655 passing (98.5%)

## Phase 4: Authentication System (P3) - Weeks 5-7

### Target: +6 tests (1631 → 1637 passing)

### 4.1 Basic Authentication

**Tests Fixed** (6 tests):
- `unauthenticated-query-failure`
- `wrong-password-failure`
- `test-read-only-access`
- 3 validation error tests

**Implementation Steps**:

1. **User storage schema** (4 hours)
   ```zig
   pub const User = struct {
       username: []const u8,
       password_hash: [32]u8, // bcrypt hash
       roles: [][]const u8,   // ["admin", "read-only"]
       created_at: i64,
   };

   var global_users: std.StringHashMap(User) = undefined;
   ```

2. **Authentication in CLI** (8 hours)
   ```zig
   // File: src/cli/main.zig

   // Parse --user and --password flags
   // Validate credentials
   // Pass auth context to query execution
   ```

3. **Authorization checks** (8 hours)
   ```zig
   // File: src/execution.zig

   fn executeStatement(stmt: Statement, context: ExecutionContext) !Result {
       // Check permissions before execution
       if (requiresWritePermission(stmt)) {
           if (!context.user.hasPermission("write")) {
               return error.InsufficientPermissions;
           }
       }
   }
   ```

4. **Error handling for auth failures** (2 hours)
   ```zig
   // Return proper error codes
   // Exit with code 1 for auth failures
   ```

**Files Modified**:
- `src/cli/main.zig` - Auth flag parsing
- `src/execution.zig` - Permission checks
- `src/auth.zig` - New module for user management
- `src/test_harness.zig` - Auth context propagation

**Estimated Time**: 22 hours (3 days)
**Risk**: High (security-critical code)
**Testing**: Extensive auth bypass testing needed

**Phase 4 Total**: 22 hours (3 days)
**Expected Improvement**: 1637/1655 passing (98.9%)

## Phase 5: Graph Algorithms (P4) - Weeks 8-13

### Target: +7 tests (1637 → 1644 passing)

### 5.1 Triangle Detection (1 test)

**Algorithm**: Find all triangles (3-node cycles)

**Implementation**:
```zig
// For each node, check if any two neighbors are connected
fn findTriangles(graph: *Graph) ![]Triangle {
    var triangles = std.ArrayList(Triangle).init(allocator);

    for (graph.nodes) |node| {
        const neighbors = graph.getNeighbors(node);

        // Check pairs of neighbors
        for (neighbors, 0..) |n1, i| {
            for (neighbors[i+1..]) |n2| {
                if (graph.hasEdge(n1, n2)) {
                    try triangles.append(.{ node, n1, n2 });
                }
            }
        }
    }

    return triangles.toOwnedSlice();
}
```

**Estimated Time**: 8 hours (1 day)

### 5.2 Jaccard Similarity (1 test)

**Algorithm**: Jaccard coefficient for node pairs

**Implementation**:
```zig
fn jaccardSimilarity(graph: *Graph, node1: NodeId, node2: NodeId) !f64 {
    const neighbors1 = graph.getNeighbors(node1);
    const neighbors2 = graph.getNeighbors(node2);

    // Intersection size
    var intersection: usize = 0;
    for (neighbors1) |n1| {
        for (neighbors2) |n2| {
            if (n1 == n2) {
                intersection += 1;
                break;
            }
        }
    }

    // Union size
    const union_size = neighbors1.len + neighbors2.len - intersection;

    if (union_size == 0) return 0.0;
    return @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_size));
}
```

**Estimated Time**: 6 hours

### 5.3 Clustering Coefficient (1 test)

**Algorithm**: Local clustering coefficient

**Implementation**:
```zig
fn clusteringCoefficient(graph: *Graph, node: NodeId) !f64 {
    const neighbors = graph.getNeighbors(node);
    const k = neighbors.len;

    if (k < 2) return 0.0;

    // Count edges between neighbors
    var edges_between: usize = 0;
    for (neighbors, 0..) |n1, i| {
        for (neighbors[i+1..]) |n2| {
            if (graph.hasEdge(n1, n2)) {
                edges_between += 1;
            }
        }
    }

    // Clustering coefficient = actual edges / possible edges
    const possible_edges = (k * (k - 1)) / 2;
    return @as(f64, @floatFromInt(edges_between)) / @as(f64, @floatFromInt(possible_edges));
}
```

**Estimated Time**: 6 hours

### 5.4 Other Algorithms

- **Graph Density** (4 hours)
- **Subgraph Isomorphism** (16 hours - complex)
- **Temporal Paths** (12 hours)
- **Variable-length with Filter** (8 hours)

**Phase 5 Total**: 60 hours (7.5 days = 1.5 weeks)
**Expected Improvement**: 1644/1655 passing (99.3%)

## Phase 6: Advanced Features (P3/P4) - Weeks 8-16

### Audit Logging (3 tests) - 16 hours

**Implementation**:
1. Event capture hooks
2. JSON formatting
3. File I/O and rotation

### CDC Operations (5 tests) - 40 hours

**Implementation**:
1. WAL tailing
2. Event streaming
3. Ordering guarantees

### Backup/Restore (2 tests) - 16 hours

**Implementation**:
1. Incremental backup
2. Index persistence
3. Recovery procedures

**Phase 6 Total**: 72 hours (9 days = 2 weeks)
**Expected Improvement**: 1654/1655 passing (99.9%)

## Summary Timeline

| Phase | Duration | Tests Fixed | Cumulative |
|-------|----------|-------------|------------|
| Phase 0 (Current) | - | - | 1623 (98.1%) |
| Phase 1 (Quick Wins) | 1 day | +4 | 1627 (98.3%) |
| Phase 2 (Parser) | 2 days | +2 | 1629 (98.4%) |
| Phase 3 (Set Ops) | 1.5 days | +2 | 1631 (98.5%) |
| Phase 4 (Auth) | 3 days | +6 | 1637 (98.9%) |
| Phase 5 (Algorithms) | 10 days | +7 | 1644 (99.3%) |
| Phase 6 (Advanced) | 10 days | +10 | 1654 (99.9%) |
| **Total** | **28 days** | **+31** | **1654 (99.9%)** |

## Recommended Approach

### Sprint 1 (Week 1): Foundation
- ✅ Complete Phase 1 (Quick Wins)
- ✅ Complete Phase 2 (Parser Extensions)
- **Outcome**: 1629/1655 (98.4%), ~10 days total work

### Sprint 2 (Weeks 2-3): Core Features
- ✅ Complete Phase 3 (Set Operations)
- ✅ Start Phase 4 (Authentication)
- **Outcome**: 1637/1655 (98.9%), ~6 days work

### Sprint 3 (Weeks 4-6): Algorithms
- ✅ Complete Phase 5 (Graph Algorithms)
- **Outcome**: 1644/1655 (99.3%), ~10 days work

### Sprint 4 (Weeks 7-8): Enterprise
- ✅ Complete Phase 6 (Audit/CDC/Backup)
- **Outcome**: 1654/1655 (99.9%), ~10 days work

## Risk Mitigation

### High-Risk Items
1. **Authentication System** - Security critical
   - Mitigation: Security review, penetration testing
   - Alternative: Use external auth proxy

2. **Parser Changes** - Could break existing queries
   - Mitigation: Extensive regression testing
   - Alternative: Feature flags for new syntax

3. **CDC Implementation** - Complex state management
   - Mitigation: Incremental rollout, feature flag
   - Alternative: Basic event log first, optimize later

### Low-Risk Items
1. **CREATE OR REPLACE** - Simple flag check
2. **Boolean Comparisons** - Type system fix
3. **Test Rewrites** - No code changes

## Success Criteria

### Minimum Viable (MVP)
- ✅ Phases 1-3 complete
- ✅ 1631/1655 passing (98.5%)
- ✅ All quick wins implemented
- ✅ Build stability maintained

### Production Ready
- ✅ Phase 4 complete (Authentication)
- ✅ 1637/1655 passing (98.9%)
- ✅ Security features enabled
- ✅ Audit logging available

### Feature Complete
- ✅ Phases 1-6 complete
- ✅ 1654/1655 passing (99.9%)
- ✅ All algorithms implemented
- ✅ Enterprise features ready

## Next Steps

### Immediate (This Week)
1. ✅ Implement CREATE OR REPLACE
2. ✅ Fix boolean property comparisons
3. ✅ Rewrite test infrastructure tests
4. ✅ Add map literal syntax

### Short-term (Next 2 Weeks)
1. ✅ Complete set operations fixes
2. ✅ Design authentication system
3. ✅ Begin auth implementation

### Medium-term (Next 2 Months)
1. ✅ Complete authentication
2. ✅ Implement graph algorithms
3. ✅ Begin CDC/audit logging

## Conclusion

The remaining 32 test failures can be systematically addressed over 4-8 weeks:
- **Week 1**: 4 quick wins (98.3%)
- **Week 2**: Parser improvements (98.4%)
- **Weeks 3-4**: Authentication (98.9%)
- **Weeks 5-8**: Algorithms and enterprise features (99%+)

**Recommended Focus**: Complete Phases 1-2 first (4 days) for immediate 98.4% pass rate, then evaluate priorities based on product requirements.

---

*Document Date: October 13, 2025*
*Status: Implementation Plan*
*Target Completion: December 2025*
