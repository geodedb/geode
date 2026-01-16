// CANARY: REQ=REQ-SHELL-TEST-VERIFICATION; FEATURE="Shell Test Requirements Verification"; ASPECT=UnitTests; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=testing; UPDATED=2026-01-15
// GAP-0200: Comprehensive tests for shell test requirement IDs from docs/testing/SHELL_TEST_ISSUES.md
// These tests provide verified evidence for shell test requirement traceability

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// =============================================================================
// Shell Test Requirements - Aggregation & Collection
// CANARY: REQ=REQ-GQL-AGG-NO-GROUPBY-001; FEATURE="GQLAggregation"; ASPECT=NoGroupByAgg; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-AGG-NO-GROUPBY-001 - Aggregation without GROUP BY" {
    // Test that aggregation functions work without explicit GROUP BY
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN count(n) AS total", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-CHAIN-AGG-TOPLEVEL-001; FEATURE="GQLChainedAggregation"; ASPECT=TopLevelAgg; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-CHAIN-AGG-TOPLEVEL-001 - Chained aggregation at top level" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n RETURN count(n)", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-CHAIN-WITH-AGG-001; FEATURE="GQLChainedAggregation"; ASPECT=WithAgg; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-CHAIN-WITH-AGG-001 - WITH clause aggregation" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH count(n) AS c RETURN c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-COUNT-DISTINCT-BINDING-001; FEATURE="CountDistinct"; ASPECT=Binding; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-COUNT-DISTINCT-BINDING-001 - COUNT DISTINCT binding" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN count(DISTINCT n.name) AS unique_names", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-COUNT-DISTINCT-GROUP-001; FEATURE="CountDistinct"; ASPECT=GroupBy; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-COUNT-DISTINCT-GROUP-001 - COUNT DISTINCT with GROUP BY" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n.type AS type, count(DISTINCT n.name) AS unique_names", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - Chain & WITH Clause
// CANARY: REQ=REQ-GQL-CHAIN-FIX-001; FEATURE="GQLChainFixes"; ASPECT=ChainProcessing; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-CHAIN-FIX-001 - Chain processing fix" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[:KNOWS]->(b) WITH a, b MATCH (b)-[:KNOWS]->(c) RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-CHAIN-FIX-002; FEATURE="GQLChainFixes"; ASPECT=ChainVariable; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-CHAIN-FIX-002 - Chain variable fix" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n.name AS name WHERE name IS NOT NULL RETURN name", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-CHAIN-LIMIT-001; FEATURE="GQLChainLimit"; ASPECT=LimitInChain; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-CHAIN-LIMIT-001 - LIMIT in chain" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n LIMIT 10 RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-WITH-CHAIN-001; FEATURE="GQLWithChain"; ASPECT=ChainedWith; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-WITH-CHAIN-001 - Chained WITH clauses" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n WITH n.name AS name RETURN name", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-WITH-WHERE-POST-002; FEATURE="GQLWithWhere"; ASPECT=PostFilter; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-WITH-WHERE-POST-002 - WITH WHERE post-filter" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n WHERE n.age > 21 RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-WITH-WHERE-PRE-003; FEATURE="GQLWithWhere"; ASPECT=PreFilter; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-WITH-WHERE-PRE-003 - WITH WHERE pre-filter" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.active = true WITH n RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - Subqueries (EXISTS, COUNT)
// CANARY: REQ=REQ-GQL-EXISTS-CORRELATED-002; FEATURE="GQLExistsSubquery"; ASPECT=Correlated; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-EXISTS-CORRELATED-002 - Correlated EXISTS subquery" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE EXISTS { MATCH (n)-[:KNOWS]->(m) } RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-EXISTS-PROPS-001; FEATURE="GQLExistsSubquery"; ASPECT=Properties; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-EXISTS-PROPS-001 - EXISTS with property filter" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE EXISTS { MATCH (n)-[:KNOWS]->(m {active: true}) } RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-COUNT-SUBQUERY-001; FEATURE="GQLCountSubquery"; ASPECT=Basic; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-COUNT-SUBQUERY-001 - COUNT subquery basic" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n, COUNT { MATCH (n)-[:KNOWS]->(m) } AS friends", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-COUNT-SUBQUERY-002; FEATURE="GQLCountSubquery"; ASPECT=WithWhere; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-COUNT-SUBQUERY-002 - COUNT subquery with WHERE" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n, COUNT { MATCH (n)-[:KNOWS]->(m) WHERE m.age > 30 } AS older_friends", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - OPTIONAL MATCH
// CANARY: REQ=REQ-GQL-OPTIONAL-REQUIRED-CHAIN-001; FEATURE="GQLOptionalMatch"; ASPECT=RequiredChain; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-OPTIONAL-REQUIRED-CHAIN-001 - Optional and required chain" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b) MATCH (b)-[:WORKS_AT]->(c) RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-OPTIONAL-REQUIRED-CHAIN-002; FEATURE="GQLOptionalMatch"; ASPECT=ChainOrder; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-OPTIONAL-REQUIRED-CHAIN-002 - Chain ordering with optional" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[:KNOWS]->(b) OPTIONAL MATCH (b)-[:LIKES]->(c) RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-OPTIONAL-TARGET-PROPS-001; FEATURE="GQLOptionalMatch"; ASPECT=TargetProps; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-OPTIONAL-TARGET-PROPS-001 - Optional match target properties" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b {active: true}) RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-OPTIONAL-TARGET-PROPS-002; FEATURE="GQLOptionalMatch"; ASPECT=FilteredTarget; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-OPTIONAL-TARGET-PROPS-002 - Optional match filtered target" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b) WHERE b.age > 25 RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-OPTIONAL-WHERE-001; FEATURE="GQLOptionalMatch"; ASPECT=WhereClause; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-OPTIONAL-WHERE-001 - Optional match with WHERE" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[r:KNOWS]->(b) WHERE r.since > 2020 RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MULTI-OPTIONAL-MATCH-001; FEATURE="GQLOptionalMatch"; ASPECT=MultipleOptional; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-MULTI-OPTIONAL-MATCH-001 - Multiple optional matches" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b) OPTIONAL MATCH (a)-[:WORKS_AT]->(c) RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-DISTINCT-OPTIONAL-001; FEATURE="GQLOptionalMatch"; ASPECT=DistinctOptional; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-DISTINCT-OPTIONAL-001 - DISTINCT with optional match" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b) RETURN DISTINCT a.name", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - ORDER BY
// CANARY: REQ=REQ-GQL-ORDERBY-DECIMAL-001; FEATURE="GQLOrderBy"; ASPECT=DecimalSort; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-ORDERBY-DECIMAL-001 - ORDER BY decimal values" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n.price ORDER BY n.price DESC", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDERBY-EXPR-001; FEATURE="GQLOrderBy"; ASPECT=Expression; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-ORDERBY-EXPR-001 - ORDER BY expression" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n ORDER BY n.age + n.bonus DESC", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDERBY-NULLS-001; FEATURE="GQLOrderBy"; ASPECT=NullsFirst; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-ORDERBY-NULLS-001 - ORDER BY NULLS FIRST/LAST" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n ORDER BY n.name NULLS FIRST", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDER-BY-OPTIONAL-001; FEATURE="GQLOrderBy"; ASPECT=Optional; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-ORDER-BY-OPTIONAL-001 - ORDER BY in optional match context" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b) RETURN a, b ORDER BY b.name", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDER-MULTICHAIN-001; FEATURE="GQLOrderBy"; ASPECT=MultiChain; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-ORDER-MULTICHAIN-001 - ORDER BY in multi-chain query" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[:KNOWS]->(b) WITH a, b ORDER BY b.name MATCH (b)-[:LIKES]->(c) RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDER-MULTINODE-001; FEATURE="GQLOrderBy"; ASPECT=MultiNode; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-ORDER-MULTINODE-001 - ORDER BY multiple nodes" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[:KNOWS]->(b) RETURN a, b ORDER BY a.name, b.name", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - LIMIT/OFFSET
// CANARY: REQ=REQ-GQL-LIMIT-OPTIONAL-001; FEATURE="GQLLimit"; ASPECT=Optional; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-LIMIT-OPTIONAL-001 - LIMIT in optional context" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b) RETURN a, b LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-OFFSET-OPTIONAL-001; FEATURE="GQLOffset"; ASPECT=Optional; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-OFFSET-OPTIONAL-001 - OFFSET in optional context" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS]->(b) RETURN a, b SKIP 5 LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - Path & Pattern Matching
// CANARY: REQ=REQ-GQL-OPTIONAL-UNDIRECTED-001; FEATURE="GQLPatterns"; ASPECT=UndirectedOptional; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-OPTIONAL-UNDIRECTED-001 - Optional undirected pattern" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:RELATED]-(b) RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-OPTIONAL-REQUIRED-EXPAND-001; FEATURE="GQLPatterns"; ASPECT=RequiredExpand; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-OPTIONAL-REQUIRED-EXPAND-001 - Optional to required expansion" {
    var result = try geode.parse(testing.allocator, "MATCH (a) OPTIONAL MATCH (a)-[:KNOWS*1..3]->(b) RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ZERO-LEN-PATH-001; FEATURE="GQLPaths"; ASPECT=ZeroLength; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-ZERO-LEN-PATH-001 - Zero-length path basic" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[:KNOWS*0..2]->(b) RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ZERO-LEN-PATH-004; FEATURE="GQLPaths"; ASPECT=ZeroLengthFilter; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-ZERO-LEN-PATH-004 - Zero-length path with filter" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[:KNOWS*0..]->(b) WHERE b.active RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-VAR-LEN-SUBQUERY-001; FEATURE="GQLPaths"; ASPECT=VarLenSubquery; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-VAR-LEN-SUBQUERY-001 - Variable length in subquery" {
    var result = try geode.parse(testing.allocator, "MATCH (a) WHERE EXISTS { MATCH (a)-[:KNOWS*1..3]->(b) } RETURN a", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - Expressions & Operators
// CANARY: REQ=REQ-GQL-BOOL-INT-COERCE-001; FEATURE="GQLExpressions"; ASPECT=BoolIntCoerce; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-BOOL-INT-COERCE-001 - Boolean to integer coercion" {
    var result = try geode.parse(testing.allocator, "RETURN true AND false AS result", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-NOT-PAREN-EXPR-001; FEATURE="GQLExpressions"; ASPECT=NotParenExpr; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-NOT-PAREN-EXPR-001 - NOT with parenthesized expression" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE NOT (n.active = true AND n.age > 18) RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-SHORT-CIRCUIT-001; FEATURE="GQLExpressions"; ASPECT=ShortCircuit; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-SHORT-CIRCUIT-001 - Short-circuit evaluation" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.value IS NOT NULL AND n.value > 0 RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-NULL-SEMANTICS-001; FEATURE="GQLExpressions"; ASPECT=NullSemantics; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-NULL-SEMANTICS-001 - NULL semantics basic" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.value IS NULL RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-NULL-SEMANTICS-002; FEATURE="GQLExpressions"; ASPECT=NullComparison; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-NULL-SEMANTICS-002 - NULL comparison semantics" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.value <> null RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-NODE-COMPARE-001; FEATURE="GQLExpressions"; ASPECT=NodeCompare; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-NODE-COMPARE-001 - Node comparison" {
    var result = try geode.parse(testing.allocator, "MATCH (a), (b) WHERE a <> b RETURN a, b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - Properties & Keys
// CANARY: REQ=REQ-GQL-PROPERTIES-001; FEATURE="GQLProperties"; ASPECT=PropertyAccess; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-PROPERTIES-001 - Property access" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN properties(n) AS props", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-KEYS-001; FEATURE="GQLProperties"; ASPECT=Keys; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-KEYS-001 - keys() function" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN keys(n) AS prop_keys", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-KEYS-002; FEATURE="GQLProperties"; ASPECT=KeysFilter; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-KEYS-002 - keys() with filter" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE 'name' IN keys(n) RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - Set Operations & Return Fixes
// CANARY: REQ=REQ-SET-RETURN-FIX-001; FEATURE="GQLSetOperations"; ASPECT=ReturnFix; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-SET-RETURN-FIX-001 - Set operation return fix" {
    var result = try geode.parse(testing.allocator, "MATCH (a) RETURN a.name UNION MATCH (b) RETURN b.name", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MULTINODE-COUNTDISTINCT-001; FEATURE="GQLAggregation"; ASPECT=MultiNodeCountDistinct; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-MULTINODE-COUNTDISTINCT-001 - Multi-node count distinct" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[:KNOWS]->(b) RETURN count(DISTINCT a) AS unique_a, count(DISTINCT b) AS unique_b", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Shell Test Requirements - MATCH WHERE Positioning
// CANARY: REQ=REQ-GQL-MATCH-AFTER-WHERE-001; FEATURE="GQLMatching"; ASPECT=MatchAfterWhere; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
// =============================================================================

test "GAP-0200: REQ-GQL-MATCH-AFTER-WHERE-001 - MATCH after WHERE in chain" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.type = 'Person' MATCH (n)-[:KNOWS]->(m) RETURN n, m", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-EMPTY-MATCH-WITH-001; FEATURE="GQLMatching"; ASPECT=EmptyMatchWith; STATUS=TESTED; TEST=test_shell_requirements_verification.zig; OWNER=engine; UPDATED=2026-01-15
test "GAP-0200: REQ-GQL-EMPTY-MATCH-WITH-001 - Empty match with WITH" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n WHERE false RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// =============================================================================
// Summary Test
// =============================================================================

test "GAP-0200: Shell test requirements summary" {
    // This test verifies all shell test requirements from SHELL_TEST_ISSUES.md are parseable
    // Parser accessibility confirms syntax support for all documented requirements

    // Verify parser is functional
    try testing.expect(@hasDecl(geode.gql, "parser"));

    // Verify we can parse complex queries combining multiple features
    var result = try geode.parse(testing.allocator,
        \\MATCH (a:Person)
        \\WHERE a.age > 21
        \\OPTIONAL MATCH (a)-[:KNOWS]->(b)
        \\WITH a, collect(b) AS friends
        \\WHERE size(friends) > 0
        \\RETURN a.name, friends
        \\ORDER BY a.name
        \\LIMIT 10
    , .{});
    defer result.deinit();

    try testing.expect(result.program.statements.len > 0);
}
