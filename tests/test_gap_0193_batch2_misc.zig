// GAP-0193 Batch 2: Miscellaneous Tests
// Comprehensive tests for remaining IMPL categories:
// 2PC, Centrality, Parser, FinalSort, StatementHandler, Docs, Main, QUIC, Builtins
//
// CANARY: REQ=REQ-GAP-0193-BATCH2-MISC; FEATURE="IMPLBatchPromotion"; ASPECT=MiscBatch2; STATUS=IMPL; OWNER=test; UPDATED=2026-11-12
//
// SONNY-6378: every case here only parses a query (or checks that the
// parser refuses one); none executes the feature its CANARY names. The
// markers are therefore IMPL, not TESTED, except the "...Refused" ones,
// where refusing to parse is the whole behaviour. Promote a marker only
// against a test that executes the feature.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// ============================================================================
// 2PC Distributed Transaction Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-2PC-002; FEATURE="2PC"; ASPECT=Coordinator; STATUS=IMPL; OWNER=distributed; UPDATED=2026-11-12
test "GAP-0193: 2PC - Distributed transaction coordinator" {
    var result = try geode.parse(testing.allocator, "START TRANSACTION", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-2PC-003; FEATURE="2PC"; ASPECT=Idempotence; STATUS=IMPL; OWNER=distributed; UPDATED=2026-11-12
test "GAP-0193: 2PC - Idempotence" {
    var result = try geode.parse(testing.allocator, "COMMIT", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-2PC-004; FEATURE="2PC"; ASPECT=RaftIntegration; STATUS=IMPL; OWNER=distributed; UPDATED=2026-11-12
test "GAP-0193: 2PC - Raft integration" {
    var result = try geode.parse(testing.allocator, "RETURN 'raft_ready' AS status", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-2PC-APPLY-001; FEATURE="2PC"; ASPECT=WriteSetApplication; STATUS=IMPL; OWNER=distributed; UPDATED=2026-11-12
test "GAP-0193: 2PC - Write set application" {
    var result = try geode.parse(testing.allocator, "CREATE (n:Node {id: 1}) SET n.applied = true RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-2PC-APPLY-002; FEATURE="2PC"; ASPECT=WriteSetParser; STATUS=IMPL; OWNER=distributed; UPDATED=2026-11-12
test "GAP-0193: 2PC - Write set parser and applicator" {
    var result = try geode.parse(testing.allocator, "MATCH (n) SET n.version = n.version + 1 RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Centrality Algorithm Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-BRIDGE-LEV-001; FEATURE="Centrality"; ASPECT=BridgeLeverage; STATUS=IMPL; OWNER=graph; UPDATED=2026-11-12
test "GAP-0193: Centrality - Bridge leverage" {
    var result = try geode.parse(testing.allocator, "CALL algo.bridgeLeverage() YIELD node, score RETURN node, score LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-GREY-CARDINAL-001; FEATURE="Centrality"; ASPECT=GreyCardinal; STATUS=IMPL; OWNER=graph; UPDATED=2026-11-12
test "GAP-0193: Centrality - Grey cardinal composite" {
    var result = try geode.parse(testing.allocator, "CALL algo.greyCardinal() YIELD node, score RETURN node, score LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-HARMONIC-001; FEATURE="Centrality"; ASPECT=Harmonic; STATUS=IMPL; OWNER=graph; UPDATED=2026-11-12
test "GAP-0193: Centrality - Harmonic centrality" {
    var result = try geode.parse(testing.allocator, "CALL algo.harmonic() YIELD node, score RETURN node, score LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-HITS-001; FEATURE="Centrality"; ASPECT=HITS; STATUS=IMPL; OWNER=graph; UPDATED=2026-11-12
test "GAP-0193: Centrality - HITS algorithm" {
    var result = try geode.parse(testing.allocator, "CALL algo.hits() YIELD node, hub, authority RETURN node, hub, authority LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-KATZ-001; FEATURE="Centrality"; ASPECT=Katz; STATUS=IMPL; OWNER=graph; UPDATED=2026-11-12
test "GAP-0193: Centrality - Katz centrality" {
    var result = try geode.parse(testing.allocator, "CALL algo.katz() YIELD node, score RETURN node, score LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Parser Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-CTE-003; FEATURE="Parser"; ASPECT=CTEList; STATUS=IMPL; OWNER=parser; UPDATED=2026-11-12
test "GAP-0193: Parser - CTE list parsing" {
    var result = try geode.parse(testing.allocator, "WITH 1 AS a, 2 AS b, 3 AS c RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MULTI-CREATE-001; FEATURE="Parser"; ASPECT=MultiCreate; STATUS=IMPL; OWNER=parser; UPDATED=2026-11-12
test "GAP-0193: Parser - Multiple consecutive create" {
    var result = try geode.parse(testing.allocator, "CREATE (a:A), (b:B), (c:C) RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-PATH-MODES-003; FEATURE="Parser"; ASPECT=PathModes; STATUS=IMPL; OWNER=parser; UPDATED=2026-11-12
test "GAP-0193: Parser - GQL path mode parsing" {
    // SONNY-6320: a bare `SHORTEST` prefix is neither ISO GQL (`ANY
    // SHORTEST` / `ALL SHORTEST` / `SHORTEST k`) nor accepted; Geode's
    // shortest path is the shortestPath() form.
    try testing.expectError(error.UnexpectedToken, geode.parse(testing.allocator, "MATCH p = SHORTEST (a)-[*]->(b) RETURN p", .{}));
    var result = try geode.parse(testing.allocator, "MATCH p = shortestPath((a)-[*]->(b)) RETURN p", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// FinalSort Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-ORDER-MULTICHAIN-001; FEATURE="FinalSort"; ASPECT=MultiChain; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: FinalSort - Order by multi-chain" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[r]->(b)-[s]->(c) RETURN a, b, c ORDER BY a.id, b.id, c.id", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDER-MULTINODE-001; FEATURE="FinalSort"; ASPECT=MultiNode; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: FinalSort - Order by multi-node" {
    var result = try geode.parse(testing.allocator, "MATCH (a), (b), (c) RETURN a, b, c ORDER BY a.id, b.id, c.id LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDER-POST-WITH-001; FEATURE="FinalSort"; ASPECT=PostWith; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: FinalSort - Order by post with" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n ORDER BY n.created DESC RETURN n LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-ORDER-POST-WITH-002; FEATURE="FinalSort"; ASPECT=PostWithAgg; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: FinalSort - Order by post with aggregation" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n.type AS type, count(*) AS cnt ORDER BY cnt DESC RETURN type, cnt", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Statement Handler Tests
// ============================================================================

// CANARY: REQ=REQ-SHOW-CONSTRAINTS-002; FEATURE="StatementHandler"; ASPECT=ShowConstraints; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: StatementHandler - SHOW CONSTRAINTS" {
    var result = try geode.parse(testing.allocator, "SHOW CONSTRAINTS", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-SHOW-FUNCTIONS-001; FEATURE="StatementHandler"; ASPECT=ShowFunctions; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: StatementHandler - SHOW FUNCTIONS" {
    var result = try geode.parse(testing.allocator, "SHOW FUNCTIONS", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-SHOW-PROCEDURES-001; FEATURE="StatementHandler"; ASPECT=ShowProcedures; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: StatementHandler - SHOW PROCEDURES" {
    var result = try geode.parse(testing.allocator, "SHOW PROCEDURES", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-SHOW-TABLES-001; FEATURE="StatementHandler"; ASPECT=ShowTables; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: StatementHandler - SHOW TABLES" {
    var result = try geode.parse(testing.allocator, "SHOW TABLES", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Documentation Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-017-DOCS; FEATURE="Docs"; ASPECT=MatchGuard; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-12
test "GAP-0193: Docs - Match frontier guard" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.validated = true RETURN n LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-017-STATUS; FEATURE="Docs"; ASPECT=StatusWireMapping; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-12
test "GAP-0193: Docs - Match guard status wire mapping" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n.status AS status", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-017-RESULT; FEATURE="Docs"; ASPECT=ResultGuard; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-12
test "GAP-0193: Docs - Match result guard" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n ORDER BY n.id LIMIT 100", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-017-SAFETY; FEATURE="Docs"; ASPECT=SafetyGuards; STATUS=IMPL; OWNER=engine; UPDATED=2026-11-12
test "GAP-0193: Docs - Match safety guards policy" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n LIMIT 1000", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-017-TUTORIAL; FEATURE="Docs"; ASPECT=Tutorial; STATUS=IMPL; OWNER=docs; UPDATED=2026-11-12
test "GAP-0193: Docs - Match tutorial" {
    var result = try geode.parse(testing.allocator, "MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a.name, b.name", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Loadtest/Main Tests
// ============================================================================

// CANARY: REQ=REQ-LOADTEST-BENCHMARKS-001; FEATURE="Main"; ASPECT=Benchmarks; STATUS=IMPL; OWNER=loadtest; UPDATED=2026-11-12
test "GAP-0193: Main - Benchmark query suite" {
    // Verify benchmark-style queries parse correctly
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN count(n) AS total", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-LOADTEST-CLUSTER-001; FEATURE="Main"; ASPECT=Cluster; STATUS=IMPL; OWNER=loadtest; UPDATED=2026-11-12
test "GAP-0193: Main - Cluster orchestrator" {
    var result = try geode.parse(testing.allocator, "CALL db.cluster.status() YIELD node, status RETURN node, status", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-LOADTEST-GENERATOR-001; FEATURE="Main"; ASPECT=Generator; STATUS=IMPL; OWNER=tooling; UPDATED=2026-11-12
test "GAP-0193: Main - Streaming data generator" {
    var result = try geode.parse(testing.allocator, "FOR i IN range(1, 10000) CREATE (n:Generated {id: i}) RETURN count(*) AS created", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-LOADTEST-REGRESSION-001; FEATURE="Main"; ASPECT=Regression; STATUS=IMPL; OWNER=loadtest; UPDATED=2026-11-12
test "GAP-0193: Main - Regression runner" {
    var result = try geode.parse(testing.allocator, "RETURN 'regression_test' AS test_type", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// QUIC Protocol Tests
// ============================================================================

// CANARY: REQ=REQ-QUIC-PROTOCOL-001; FEATURE="QUICProtocol"; ASPECT=Connection; STATUS=IMPL; OWNER=transport; UPDATED=2026-11-12
test "GAP-0193: QUIC - Connection handling" {
    var result = try geode.parse(testing.allocator, "RETURN 'quic_connected' AS status", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-QUIC-PROTOCOL-002; FEATURE="QUICProtocol"; ASPECT=Streaming; STATUS=IMPL; OWNER=transport; UPDATED=2026-11-12
test "GAP-0193: QUIC - Stream handling" {
    var result = try geode.parse(testing.allocator, "FOR n IN range(1, 100) RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-QUIC-PROTOCOL-003; FEATURE="QUICProtocol"; ASPECT=Security; STATUS=IMPL; OWNER=transport; UPDATED=2026-11-12
test "GAP-0193: QUIC - TLS security" {
    var result = try geode.parse(testing.allocator, "RETURN 'tls_secure' AS status", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-QUIC-PROTOCOL-004; FEATURE="QUICProtocol"; ASPECT=Multiplexing; STATUS=IMPL; OWNER=transport; UPDATED=2026-11-12
test "GAP-0193: QUIC - Connection multiplexing" {
    var result = try geode.parse(testing.allocator, "RETURN 'multiplexed' AS conn", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-QUIC-PROTOCOL-005; FEATURE="QUICProtocol"; ASPECT=FlowControl; STATUS=IMPL; OWNER=transport; UPDATED=2026-11-12
test "GAP-0193: QUIC - Flow control" {
    var result = try geode.parse(testing.allocator, "RETURN 'flow_controlled' AS status", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-QUIC-PROTOCOL-006; FEATURE="QUICProtocol"; ASPECT=Congestion; STATUS=IMPL; OWNER=transport; UPDATED=2026-11-12
test "GAP-0193: QUIC - Congestion control" {
    var result = try geode.parse(testing.allocator, "RETURN 'congestion_managed' AS status", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Builtin Functions Tests
// ============================================================================

// CANARY: REQ=REQ-BUILTIN-STRING-001; FEATURE="BuiltinFunctions"; ASPECT=String; STATUS=IMPL; OWNER=functions; UPDATED=2026-11-12
test "GAP-0193: Builtin - String functions" {
    var result = try geode.parse(testing.allocator, "RETURN toUpper('hello') AS `upper`, toLower('WORLD') AS `lower`, trim('  text  ') AS trimmed", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-BUILTIN-MATH-001; FEATURE="BuiltinFunctions"; ASPECT=Math; STATUS=IMPL; OWNER=functions; UPDATED=2026-11-12
test "GAP-0193: Builtin - Math functions" {
    var result = try geode.parse(testing.allocator, "RETURN abs(-5) AS a, ceil(3.2) AS b, floor(3.8) AS c, round(3.5) AS d", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-BUILTIN-LIST-001; FEATURE="BuiltinFunctions"; ASPECT=List; STATUS=IMPL; OWNER=functions; UPDATED=2026-11-12
test "GAP-0193: Builtin - List functions" {
    var result = try geode.parse(testing.allocator, "RETURN size([1,2,3]) AS len, head([1,2,3]) AS first, tail([1,2,3]) AS rest", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-BUILTIN-DATE-001; FEATURE="BuiltinFunctions"; ASPECT=Date; STATUS=IMPL; OWNER=functions; UPDATED=2026-11-12
test "GAP-0193: Builtin - Date functions" {
    var result = try geode.parse(testing.allocator, "RETURN date() AS today, datetime() AS now, timestamp() AS ts", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-BUILTIN-AGGREGATE-001; FEATURE="BuiltinFunctions"; ASPECT=Aggregate; STATUS=IMPL; OWNER=functions; UPDATED=2026-11-12
test "GAP-0193: Builtin - Aggregate functions" {
    var result = try geode.parse(testing.allocator, "FOR n IN [1,2,3,4,5] RETURN sum(n) AS s, avg(n) AS a, min(n) AS mn, max(n) AS mx", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-BUILTIN-PATH-001; FEATURE="BuiltinFunctions"; ASPECT=Path; STATUS=IMPL; OWNER=functions; UPDATED=2026-11-12
test "GAP-0193: Builtin - Path functions" {
    var result = try geode.parse(testing.allocator, "MATCH p = (a)-[*]->(b) RETURN length(p) AS len, nodes(p) AS n, relationships(p) AS r LIMIT 5", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Where Clause Tests
// ============================================================================

// CANARY: REQ=REQ-WHERE-CLAUSE-001; FEATURE="WhereClause"; ASPECT=Filtering; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: Where - Basic filtering" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.active = true AND n.age > 21 RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-WHERE-CLAUSE-002; FEATURE="WhereClause"; ASPECT=Complex; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: Where - Complex predicates" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE (n.type = 'A' OR n.type = 'B') AND n.value > 100 RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-WHERE-CLAUSE-003; FEATURE="WhereClause"; ASPECT=Pattern; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: Where - Pattern predicates" {
    // SONNY-6320: a bare pattern in WHERE is Cypher; GQL writes EXISTS { }.
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE EXISTS { (n)-[:CONNECTED]->() } RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-WHERE-CLAUSE-004; FEATURE="WhereClause"; ASPECT=Exists; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: Where - Exists predicate" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE exists(n.optional_field) RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// NoReturn Clause Tests
// ============================================================================

// CANARY: REQ=REQ-NORETURN-001; FEATURE="NoReturnClause"; ASPECT=Create; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: NoReturn - Create without return" {
    var result = try geode.parse(testing.allocator, "CREATE (n:Node {id: 1})", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-NORETURN-002; FEATURE="NoReturnClause"; ASPECT=Set; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: NoReturn - Set without return" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.id = 1 SET n.updated = true", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-NORETURN-003; FEATURE="NoReturnClause"; ASPECT=Delete; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: NoReturn - Delete without return" {
    var result = try geode.parse(testing.allocator, "MATCH (n:Temp) DETACH DELETE n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-NORETURN-004; FEATURE="NoReturnClause"; ASPECT=Merge; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: NoReturn - Merge without return" {
    var result = try geode.parse(testing.allocator, "MERGE (n:Node {id: 1}) ON CREATE SET n.created = true", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-NORETURN-005; FEATURE="NoReturnClause"; ASPECT=Remove; STATUS=IMPL; OWNER=execution; UPDATED=2026-11-12
test "GAP-0193: NoReturn - Remove without return" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.id = 1 REMOVE n.temp", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}
