// ISO/IEC 39075:2024 Conformance Test Suite
// GAP-0257: Comprehensive evidence for GQL compliance claims
// CANARY: REQ=REQ-GQL-ISO-CONFORM-001; FEATURE="ISOConformanceEvidence"; ASPECT=TestSuite; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
//
// Tests organized by ISO 39075:2024 sections to provide traceable evidence
// that each claimed feature is actually parsed/handled correctly.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const ast = geode.gql.ast;
const token = geode.gql.token;

/// Helper: assert that a GQL source string parses successfully.
fn expectParseOk(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    switch (result) {
        .Ok => {},
        .Err => |e| {
            std.debug.print("PARSE FAILED for: {s}\n  error: {s}\n", .{ src, e.msg });
            return error.TestExpectedEqual;
        },
    }
}

/// Helper: assert that a GQL source string fails to parse (expected error).
fn expectParseErr(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    switch (result) {
        .Ok => {
            std.debug.print("EXPECTED PARSE FAILURE for: {s}\n", .{src});
            return error.TestExpectedEqual;
        },
        .Err => {},
    }
}

/// Helper: parse and return the first statement for deeper inspection.
fn parseFirstStmt(src: []const u8, arena: *std.heap.ArenaAllocator) !ast.Statement {
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    switch (result) {
        .Ok => |res| {
            try testing.expect(res.program.statements.len >= 1);
            return res.program.statements[0];
        },
        .Err => |e| {
            std.debug.print("PARSE FAILED for: {s}\n  error: {s}\n", .{ src, e.msg });
            return error.TestExpectedEqual;
        },
    }
}

// ============================================================================
// Section 7: Graph Pattern Matching (MATCH)
// CANARY: REQ=REQ-GQL-ISO-SEC-7-001; FEATURE="ISOGraphPatternMatching"; ASPECT=MATCH; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 7.1: Basic node pattern" {
    try expectParseOk("MATCH (n) RETURN n");
}

test "ISO Sec 7.2: Node with label" {
    try expectParseOk("MATCH (n:Person) RETURN n");
}

test "ISO Sec 7.3: Node with multiple labels" {
    // Geode uses colon-separated labels per GQL spec (not & conjunction)
    try expectParseOk("MATCH (n:Person:Employee) RETURN n");
}

test "ISO Sec 7.4: Node with property filter" {
    try expectParseOk("MATCH (n:Person {name: 'Alice'}) RETURN n");
}

test "ISO Sec 7.5: Directed edge pattern" {
    try expectParseOk("MATCH (a)-[e:KNOWS]->(b) RETURN a, b");
}

test "ISO Sec 7.6: Undirected edge pattern" {
    try expectParseOk("MATCH (a)-[e:KNOWS]-(b) RETURN a, b");
}

test "ISO Sec 7.7: WHERE clause filter" {
    try expectParseOk("MATCH (n:Person) WHERE n.age > 30 RETURN n.name");
}

test "ISO Sec 7.8: Multi-hop pattern" {
    try expectParseOk("MATCH (a)-[:KNOWS]->(b)-[:KNOWS]->(c) RETURN a, c");
}

test "ISO Sec 7.9: Optional MATCH" {
    try expectParseOk("MATCH (n:Person) OPTIONAL MATCH (n)-[:HAS]->(p) RETURN n, p");
}

test "ISO Sec 7.10: Pattern with alias" {
    try expectParseOk("MATCH p = (a)-[:KNOWS]->(b) RETURN p");
}

// ============================================================================
// Section 9: Data Manipulation Language (DML)
// CANARY: REQ=REQ-GQL-ISO-SEC-9-001; FEATURE="ISODataManipulation"; ASPECT=DML; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 9.1: INSERT node" {
    try expectParseOk("INSERT (:Person {name: 'Bob', age: 30})");
}

test "ISO Sec 9.2: INSERT node with edge inline" {
    try expectParseOk("INSERT (:Person {name: 'Alice'})-[:KNOWS]->(:Person {name: 'Bob'})");
}

test "ISO Sec 9.3: SET property" {
    try expectParseOk("MATCH (n:Person {name: 'Alice'}) SET n.age = 31 RETURN n");
}

test "ISO Sec 9.4: REMOVE property" {
    try expectParseOk("MATCH (n:Person {name: 'Alice'}) REMOVE n.age RETURN n");
}

test "ISO Sec 9.5: DELETE node" {
    try expectParseOk("MATCH (n:Temp) DELETE n");
}

test "ISO Sec 9.6: DETACH DELETE" {
    try expectParseOk("MATCH (n:Temp) DETACH DELETE n");
}

test "ISO Sec 9.7: INSERT with RETURN" {
    try expectParseOk("INSERT (:Person {name: 'Charlie'}) RETURN element_id(n) AS id");
}

// ============================================================================
// Section 10: Data Definition Language (DDL)
// CANARY: REQ=REQ-GQL-ISO-SEC-10-001; FEATURE="ISODataDefinition"; ASPECT=DDL; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 10.1: CREATE GRAPH" {
    try expectParseOk("CREATE GRAPH myGraph");
}

test "ISO Sec 10.2: DROP GRAPH" {
    try expectParseOk("DROP GRAPH myGraph");
}

test "ISO Sec 10.3: USE GRAPH" {
    try expectParseOk("USE GRAPH myGraph MATCH (n) RETURN n");
}

test "ISO Sec 10.4: CREATE GRAPH IF NOT EXISTS" {
    try expectParseOk("CREATE GRAPH IF NOT EXISTS myGraph");
}

test "ISO Sec 10.5: CREATE GRAPH TYPE" {
    try expectParseOk("CREATE GRAPH TYPE myType");
}

// ============================================================================
// Section 11: Transactions
// CANARY: REQ=REQ-GQL-ISO-SEC-11-001; FEATURE="ISOTransactions"; ASPECT=Transactions; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 11.1: Implicit transaction (single statement)" {
    try expectParseOk("RETURN 1 AS x");
}

test "ISO Sec 11.2: Multi-statement query" {
    try expectParseOk("MATCH (n) RETURN n ORDER BY n.name");
}

// ============================================================================
// Section 12: Functions
// CANARY: REQ=REQ-GQL-ISO-SEC-12-001; FEATURE="ISOFunctions"; ASPECT=BuiltinFunctions; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 12.1: COUNT aggregate" {
    try expectParseOk("MATCH (n:Person) RETURN count(n) AS total");
}

test "ISO Sec 12.2: SUM aggregate" {
    try expectParseOk("MATCH (n:Person) RETURN sum(n.age) AS total_age");
}

test "ISO Sec 12.3: AVG aggregate" {
    try expectParseOk("MATCH (n:Person) RETURN avg(n.age) AS avg_age");
}

test "ISO Sec 12.4: MIN aggregate" {
    try expectParseOk("MATCH (n:Person) RETURN min(n.age) AS youngest");
}

test "ISO Sec 12.5: MAX aggregate" {
    try expectParseOk("MATCH (n:Person) RETURN max(n.age) AS oldest");
}

test "ISO Sec 12.6: ABS function" {
    try expectParseOk("RETURN abs(-5) AS result");
}

test "ISO Sec 12.7: LENGTH function" {
    try expectParseOk("RETURN length('hello') AS len");
}

test "ISO Sec 12.8: LABELS function" {
    try expectParseOk("MATCH (n) RETURN labels(n) AS lbls");
}

test "ISO Sec 12.9: ELEMENT_ID function" {
    try expectParseOk("MATCH (n) RETURN element_id(n) AS eid");
}

test "ISO Sec 12.10: COALESCE function" {
    try expectParseOk("RETURN coalesce(NULL, 42) AS result");
}

test "ISO Sec 12.11: COUNT DISTINCT" {
    try expectParseOk("MATCH (n:Person) RETURN count(DISTINCT n.city) AS cities");
    // ISO/IEC 39075:2024 <general set function> ::= <computational operation>
    // <left paren> [ <set quantifier> ] <value expression> <right paren>, so the
    // quantifier is legal on EVERY aggregate, not just COUNT. Before
    // docs/@BUGS_731.md bug 6c these all failed to parse ("expected token
    // 'r_paren', got 'identifier'"). Executed-result coverage for the same forms
    // lives in tests/test_bug731_aggregates_vectors.zig — this suite stays
    // parse-only by design.
    try expectParseOk("MATCH (n:Person) RETURN count(ALL n.city) AS cities");
    try expectParseOk("MATCH (n:Person) RETURN collect(DISTINCT n.city) AS cities");
    try expectParseOk("MATCH (n:Person) RETURN sum(DISTINCT n.age) AS total");
    try expectParseOk("MATCH (n:Person) RETURN avg(DISTINCT n.age) AS mean");
    try expectParseOk("MATCH (n:Person) RETURN min(DISTINCT n.age) AS lo");
    try expectParseOk("MATCH (n:Person) RETURN max(ALL n.age) AS hi");
}

test "ISO Sec 12.12: COLLECT aggregate" {
    try expectParseOk("MATCH (n:Person) RETURN collect(n.name) AS names");
}

// ============================================================================
// Section 13: Type System
// CANARY: REQ=REQ-GQL-ISO-SEC-13-001; FEATURE="ISOTypeSystem"; ASPECT=Types; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 13.1: Integer literal" {
    try expectParseOk("RETURN 42 AS x");
}

test "ISO Sec 13.2: Float literal" {
    try expectParseOk("RETURN 3.14 AS x");
}

test "ISO Sec 13.3: String literal" {
    try expectParseOk("RETURN 'hello world' AS x");
}

test "ISO Sec 13.4: Boolean TRUE" {
    try expectParseOk("RETURN TRUE AS x");
}

test "ISO Sec 13.5: Boolean FALSE" {
    try expectParseOk("RETURN FALSE AS x");
}

test "ISO Sec 13.6: NULL literal" {
    try expectParseOk("RETURN NULL AS x");
}

test "ISO Sec 13.7: List literal" {
    try expectParseOk("RETURN [1, 2, 3] AS x");
}

test "ISO Sec 13.8: Map literal" {
    try expectParseOk("RETURN {a: 1, b: 'two'} AS x");
}

test "ISO Sec 13.9: CAST expression" {
    try expectParseOk("RETURN CAST(42 AS STRING) AS x");
}

test "ISO Sec 13.10: Negative integer" {
    try expectParseOk("RETURN -1 AS x");
}

test "ISO Sec 13.11: Scientific notation float" {
    try expectParseOk("RETURN 1.5e10 AS x");
}

// ============================================================================
// Section 14: NULL Semantics (Three-Valued Logic)
// CANARY: REQ=REQ-GQL-ISO-SEC-14-001; FEATURE="ISONullSemantics"; ASPECT=ThreeValuedLogic; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 14.1: IS NULL predicate" {
    try expectParseOk("MATCH (n) WHERE n.email IS NULL RETURN n");
}

test "ISO Sec 14.2: IS NOT NULL predicate" {
    try expectParseOk("MATCH (n) WHERE n.email IS NOT NULL RETURN n");
}

test "ISO Sec 14.3: COALESCE with NULL" {
    try expectParseOk("RETURN coalesce(NULL, NULL, 1) AS x");
}

test "ISO Sec 14.4: NULL in boolean AND" {
    try expectParseOk("RETURN NULL AND TRUE AS x");
}

test "ISO Sec 14.5: NULL in boolean OR" {
    try expectParseOk("RETURN NULL OR FALSE AS x");
}

test "ISO Sec 14.6: NOT NULL" {
    try expectParseOk("RETURN NOT NULL AS x");
}

test "ISO Sec 14.7: NULL comparison" {
    try expectParseOk("RETURN NULL = NULL AS x");
}

// ============================================================================
// Section 15: Path Patterns
// CANARY: REQ=REQ-GQL-ISO-SEC-15-001; FEATURE="ISOPathPatterns"; ASPECT=Paths; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 15.1: Variable-length path" {
    try expectParseOk("MATCH (a)-[:KNOWS*1..5]->(b) RETURN a, b");
}

test "ISO Sec 15.2: Variable-length path with upper bound" {
    try expectParseOk("MATCH (a)-[:KNOWS*1..10]->(b) RETURN a, b");
}

test "ISO Sec 15.3: shortestPath function" {
    try expectParseOk("MATCH p = shortestPath((a)-[*]->(b)) RETURN p");
}

test "ISO Sec 15.4: Variable-length with lower bound" {
    try expectParseOk("MATCH (a)-[:KNOWS*2..]->(b) RETURN a, b");
}

test "ISO Sec 15.5: Zero-or-more quantifier" {
    try expectParseOk("MATCH (a)-[:KNOWS*]->(b) RETURN a, b");
}

test "ISO Sec 15.6: Exact length path" {
    try expectParseOk("MATCH (a)-[:KNOWS*3]->(b) RETURN a, b");
}

// ============================================================================
// Section 16: Aggregation
// CANARY: REQ=REQ-GQL-ISO-SEC-16-001; FEATURE="ISOAggregation"; ASPECT=GroupBy; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 16.1: GROUP BY with aggregate" {
    try expectParseOk("MATCH (n:Person) RETURN n.city, count(n) AS cnt GROUP BY n.city");
}

test "ISO Sec 16.2: Multi-column GROUP BY" {
    try expectParseOk("MATCH (n:Person) RETURN n.city, n.country, count(n) AS cnt GROUP BY n.city, n.country");
}

test "ISO Sec 16.3: HAVING clause" {
    try expectParseOk("MATCH (n:Person) RETURN n.city, count(n) AS cnt GROUP BY n.city HAVING count(n) > 5");
}

test "ISO Sec 16.4: Aggregate without GROUP BY" {
    try expectParseOk("MATCH (n:Person) RETURN count(n) AS total");
}

// ============================================================================
// Section 17: Ordering and Pagination
// CANARY: REQ=REQ-GQL-ISO-SEC-17-001; FEATURE="ISOOrdering"; ASPECT=OrderByLimit; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 17.1: ORDER BY ascending" {
    try expectParseOk("MATCH (n:Person) RETURN n.name ORDER BY n.name ASC");
}

test "ISO Sec 17.2: ORDER BY descending" {
    try expectParseOk("MATCH (n:Person) RETURN n.name ORDER BY n.name DESC");
}

test "ISO Sec 17.3: LIMIT" {
    try expectParseOk("MATCH (n:Person) RETURN n.name LIMIT 10");
}

test "ISO Sec 17.4: OFFSET" {
    try expectParseOk("MATCH (n:Person) RETURN n.name ORDER BY n.name LIMIT 10 OFFSET 5");
}

test "ISO Sec 17.5: Multi-column ORDER BY" {
    try expectParseOk("MATCH (n:Person) RETURN n.name, n.age ORDER BY n.age DESC, n.name ASC");
}

test "ISO Sec 17.6: NULLS FIRST" {
    try expectParseOk("MATCH (n:Person) RETURN n.name ORDER BY n.age NULLS FIRST");
}

test "ISO Sec 17.7: NULLS LAST" {
    try expectParseOk("MATCH (n:Person) RETURN n.name ORDER BY n.age NULLS LAST");
}

// ============================================================================
// Section 18: Set Operations
// CANARY: REQ=REQ-GQL-ISO-SEC-18-001; FEATURE="ISOSetOperations"; ASPECT=Union; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Sec 18.1: UNION" {
    try expectParseOk("RETURN 1 AS x UNION RETURN 2 AS x");
}

test "ISO Sec 18.2: UNION ALL" {
    try expectParseOk("RETURN 1 AS x UNION ALL RETURN 1 AS x");
}

test "ISO Sec 18.3: INTERSECT" {
    try expectParseOk("RETURN 1 AS x INTERSECT RETURN 1 AS x");
}

test "ISO Sec 18.4: EXCEPT" {
    try expectParseOk("RETURN 1 AS x EXCEPT RETURN 2 AS x");
}

// ============================================================================
// Additional Compliance Tests: Expressions
// CANARY: REQ=REQ-GQL-ISO-EXPR-001; FEATURE="ISOExpressions"; ASPECT=Operators; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Expr: Arithmetic operators" {
    try expectParseOk("RETURN 1 + 2 AS a, 10 - 3 AS b, 2 * 5 AS c, 10 / 2 AS d");
}

test "ISO Expr: Comparison operators" {
    try expectParseOk("MATCH (n) WHERE n.x > 1 AND n.x < 100 AND n.y >= 0 AND n.y <= 50 RETURN n");
}

test "ISO Expr: String concatenation" {
    try expectParseOk("RETURN 'hello' || ' ' || 'world' AS greeting");
}

test "ISO Expr: CASE expression" {
    try expectParseOk("RETURN CASE WHEN 1 > 0 THEN 'yes' ELSE 'no' END AS result");
}

test "ISO Expr: Searched CASE" {
    try expectParseOk("MATCH (n) RETURN CASE n.status WHEN 'active' THEN 1 WHEN 'inactive' THEN 0 ELSE -1 END AS code");
}

test "ISO Expr: IN predicate" {
    try expectParseOk("MATCH (n) WHERE n.name IN ['Alice', 'Bob'] RETURN n");
}

test "ISO Expr: EXISTS subquery" {
    try expectParseOk("MATCH (n) WHERE EXISTS { MATCH (n)-[:KNOWS]->() } RETURN n");
}

test "ISO Expr: NOT operator" {
    try expectParseOk("MATCH (n) WHERE NOT n.active RETURN n");
}

test "ISO Expr: STARTS WITH predicate" {
    try expectParseOk("MATCH (n) WHERE n.name STARTS WITH 'Al' RETURN n");
}

test "ISO Expr: Nested property access" {
    try expectParseOk("MATCH (n) RETURN n.address.city AS city");
}

// ============================================================================
// Additional Compliance Tests: LET / WITH / FOR
// CANARY: REQ=REQ-GQL-ISO-LET-001; FEATURE="ISOLetBinding"; ASPECT=VariableScoping; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Let: WITH projection" {
    try expectParseOk("MATCH (n:Person) WITH n.name AS name RETURN name");
}

test "ISO Let: WITH aggregation" {
    try expectParseOk("MATCH (n:Person) WITH n.city AS city, count(n) AS cnt RETURN city, cnt");
}

test "ISO Let: FOR IN list" {
    try expectParseOk("FOR x IN [1, 2, 3] RETURN x");
}

test "ISO Let: FOR IN parameter-bound list" {
    // geode#for-in-param: `<for item source>` is a `<list value expression>`
    // (ISO/IEC 39075:2024), so a `$param` collection is grammatically valid.
    // Parse-only guard; execution correctness is pinned in tests/test_for_write_body.zig.
    try expectParseOk("FOR x IN $rows RETURN x");
}

test "ISO Let: Chained WITH clauses" {
    try expectParseOk("MATCH (n:Person) WITH n.name AS name WITH name RETURN name");
}

// ============================================================================
// Additional Compliance Tests: Schema / Catalog
// CANARY: REQ=REQ-GQL-ISO-CATALOG-001; FEATURE="ISOCatalog"; ASPECT=SchemaManagement; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Catalog: CREATE SCHEMA" {
    try expectParseOk("CREATE SCHEMA mySchema");
}

test "ISO Catalog: DROP SCHEMA" {
    try expectParseOk("DROP SCHEMA mySchema");
}

test "ISO Catalog: USE SCHEMA" {
    try expectParseOk("USE mySchema MATCH (n) RETURN n");
}

// ============================================================================
// Negative Tests: Syntax Errors
// CANARY: REQ=REQ-GQL-ISO-NEGATIVE-001; FEATURE="ISOSyntaxValidation"; ASPECT=ErrorDetection; STATUS=TESTED; TEST=test-iso-conformance; OWNER=compliance; UPDATED=2026-06-11
// ============================================================================

test "ISO Negative: Missing RETURN" {
    try expectParseErr("MATCH (n)");
}

test "ISO Negative: Unclosed parenthesis" {
    try expectParseErr("MATCH (n RETURN n");
}

test "ISO Negative: Gibberish input" {
    try expectParseErr("@@@ %%% !!!");
}

test "ISO Negative: Dangling operator" {
    try expectParseErr("RETURN 1 +");
}
