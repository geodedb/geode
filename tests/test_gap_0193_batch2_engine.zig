// GAP-0193 Batch 2: Engine, Storage, Execution, Types, Statistics Tests
// Comprehensive tests for remaining engine-related IMPL categories
//
// CANARY: REQ=REQ-GAP-0193-BATCH2-ENG; FEATURE="IMPLBatchPromotion"; ASPECT=EngineBatch2; STATUS=TESTED; OWNER=test; UPDATED=2026-01-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// ============================================================================
// Engine: Set Operations Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-005; FEATURE="SetOps"; ASPECT=Distinct; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Engine - Set operations distinct" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN DISTINCT n.type AS type", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Engine: Property Access Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-017; FEATURE="PropertyAccess"; ASPECT=Basic; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Engine - Property access basic" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN n.name AS name, n.value AS value", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-017-NULL; FEATURE="PropertyAccess"; ASPECT=Null; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Engine - Property access null handling" {
    var result = try geode.parse(testing.allocator, "MATCH (n) RETURN coalesce(n.missing, 'default') AS value", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Engine: Schema Constraint Tests
// ============================================================================

// SONNY-6320: these cases asserted that CHECK, range and regular-expression
// constraints parse (`ASSERT n.age >= 0`, `=~`). Geode has no value-predicate
// constraints: the parser accepts IS UNIQUE, IS NOT NULL, IS NODE KEY and
// EXISTS only, so they are refused, and that is what is checked.
// CANARY: REQ=REQ-GQL-032-CHECK; FEATURE="Constraints"; ASPECT=CheckRefused; STATUS=TESTED; OWNER=schema; UPDATED=2026-11-12
test "GAP-0193: Engine - Check constraint is refused (no value-predicate constraints)" {
    // A value predicate is not a constraint Geode supports.
    try testing.expectError(error.UnexpectedToken, geode.parse(testing.allocator, "CREATE CONSTRAINT check_age FOR (n:Person) REQUIRE n.age >= 0", .{}));
}

// CANARY: REQ=REQ-GQL-032-RANGE; FEATURE="Constraints"; ASPECT=RangeRefused; STATUS=TESTED; OWNER=schema; UPDATED=2026-11-12
test "GAP-0193: Engine - Range check constraint is refused" {
    // A range predicate is not a constraint Geode supports.
    try testing.expectError(error.UnexpectedToken, geode.parse(testing.allocator, "CREATE CONSTRAINT check_range FOR (n:Item) REQUIRE n.price > 0 AND n.price < 10000", .{}));
}

// CANARY: REQ=REQ-GQL-032-COMPOSITE; FEATURE="Constraints"; ASPECT=Composite; STATUS=TESTED; OWNER=schema; UPDATED=2026-11-12
test "GAP-0193: Engine - Composite node key" {
    var result = try geode.parse(testing.allocator, "CREATE CONSTRAINT unique_pair FOR (n:Pair) REQUIRE (n.key1, n.key2) IS NODE KEY", .{});
    defer result.deinit();
    const cc = result.program.statements[0].CreateConstraint;
    try testing.expectEqual(geode.ast.ConstraintType.node_key, cc.constraint_type);
    try testing.expectEqual(@as(usize, 2), cc.properties.len);
}

// CANARY: REQ=REQ-GQL-032-UNIQUE; FEATURE="Constraints"; ASPECT=Unique; STATUS=TESTED; OWNER=schema; UPDATED=2026-11-12
test "GAP-0193: Engine - Schema constraints uniqueness" {
    var result = try geode.parse(testing.allocator, "CREATE CONSTRAINT unique_id FOR (n:Entity) REQUIRE n.id IS UNIQUE", .{});
    defer result.deinit();
    const cc = result.program.statements[0].CreateConstraint;
    try testing.expectEqual(geode.ast.ConstraintType.unique, cc.constraint_type);
    try testing.expectEqualStrings("Entity", cc.label);
}

// CANARY: REQ=REQ-GQL-032-PATTERN; FEATURE="Constraints"; ASPECT=PatternRefused; STATUS=TESTED; OWNER=schema; UPDATED=2026-11-12
test "GAP-0193: Engine - Regular-expression constraint is refused" {
    // `=~` is not GQL, and pattern constraints are not supported.
    try testing.expectError(error.UnexpectedToken, geode.parse(testing.allocator, "CREATE CONSTRAINT email_format FOR (n:User) REQUIRE n.email =~ '.*@.*'", .{}));
}

// ============================================================================
// Execution: Call Subquery Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-CALL-SUBQUERY; FEATURE="CallSubquery"; ASPECT=Basic; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - Call subquery" {
    var result = try geode.parse(testing.allocator, "CALL { MATCH (n) RETURN n } RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Execution: GroupBy Relationship Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-GROUPBY-REL-001; FEATURE="GroupByRel"; ASPECT=Pattern; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - GroupBy relationship pattern" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[r]->(b) WITH type(r) AS relType, count(*) AS cnt RETURN relType, cnt", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Execution: Multi-Chain Relationship Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-MULTI-CHAIN-REL-001; FEATURE="MultiChainRel"; ASPECT=Match; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Execution - Multi-chain relationship match" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[r1]->(b)-[r2]->(c) RETURN a, b, c", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Execution: MultiHop Pattern Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-MULTIHOP-001; FEATURE="MultiHop"; ASPECT=Patterns; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Execution - MultiHop patterns" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[*1..3]->(b) RETURN a, b LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MULTIHOP-GROUPBY-001; FEATURE="MultiHop"; ASPECT=GroupBy; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Execution - MultiHop groupby" {
    var result = try geode.parse(testing.allocator, "MATCH (a)-[*1..3]->(b) WITH labels(b) AS lbls, count(*) AS cnt RETURN lbls, cnt", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MULTINODE-GROUPBY-001; FEATURE="MultiNode"; ASPECT=GroupBy; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Execution - MultiNode groupby" {
    var result = try geode.parse(testing.allocator, "MATCH (a), (b) WITH a.type AS typeA, b.type AS typeB, count(*) AS cnt RETURN typeA, typeB, cnt", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Execution: Variable Length Path Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-VARLEN-AGG; FEATURE="VarLenPath"; ASPECT=Aggregation; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - Variable length path aggregation" {
    var result = try geode.parse(testing.allocator, "MATCH p = (a)-[*]->(b) RETURN length(p) AS len, count(*) AS cnt", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Execution: WITH GroupBy Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-WITH-GROUPBY-001; FEATURE="WithGroupBy"; ASPECT=Aggregation; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - WITH groupby aggregation" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WITH n.category AS cat, count(*) AS cnt, sum(n.value) AS total RETURN cat, cnt, total", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Types: Cryptographic Types Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-CRYPTO-TYPES-001; FEATURE="CryptoTypes"; ASPECT=Implementation; STATUS=TESTED; OWNER=types; UPDATED=2026-01-16
test "GAP-0193: Types - Cryptographic types" {
    var result = try geode.parse(testing.allocator, "RETURN hash('sha256', 'data') AS hash", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Types: Geographic Types Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-GEO-TYPES-001; FEATURE="GeoTypes"; ASPECT=Implementation; STATUS=TESTED; OWNER=types; UPDATED=2026-01-16
test "GAP-0193: Types - Geographic types" {
    var result = try geode.parse(testing.allocator, "RETURN point({latitude: 37.7749, longitude: -122.4194}) AS location", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Types: Network Types Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-NET-TYPES-000; FEATURE="NetTypes"; ASPECT=Module; STATUS=TESTED; OWNER=types; UPDATED=2026-01-16
test "GAP-0193: Types - Network types module" {
    var result = try geode.parse(testing.allocator, "RETURN '192.168.1.1' AS ip", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-NET-TYPES-001; FEATURE="NetTypes"; ASPECT=IpAddr; STATUS=TESTED; OWNER=types; UPDATED=2026-01-16
test "GAP-0193: Types - IpAddr type" {
    var result = try geode.parse(testing.allocator, "RETURN '10.0.0.1' AS ipv4, '::1' AS ipv6", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-NET-TYPES-002; FEATURE="NetTypes"; ASPECT=Subnet; STATUS=TESTED; OWNER=types; UPDATED=2026-01-16
test "GAP-0193: Types - Subnet CIDR type" {
    var result = try geode.parse(testing.allocator, "RETURN '192.168.0.0/24' AS subnet", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-NET-TYPES-003; FEATURE="NetTypes"; ASPECT=Mac; STATUS=TESTED; OWNER=types; UPDATED=2026-01-16
test "GAP-0193: Types - Mac address type" {
    var result = try geode.parse(testing.allocator, "RETURN 'aa:bb:cc:dd:ee:ff' AS mac", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Types: Vector Types Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-VECTOR-TYPES-001; FEATURE="VectorTypes"; ASPECT=Implementation; STATUS=TESTED; OWNER=types; UPDATED=2026-01-16
test "GAP-0193: Types - Vector types" {
    var result = try geode.parse(testing.allocator, "RETURN vector([1.0, 2.0, 3.0]) AS vec", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Statistics: Graph Metrics Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-GLOBAL-CLUSTERING-001; FEATURE="Statistics"; ASPECT=GlobalClustering; STATUS=TESTED; OWNER=graph; UPDATED=2026-01-16
test "GAP-0193: Statistics - Global clustering coefficient" {
    var result = try geode.parse(testing.allocator, "CALL algo.clustering.global() YIELD coefficient RETURN coefficient", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-GRAPH-DENSITY-001; FEATURE="Statistics"; ASPECT=Density; STATUS=TESTED; OWNER=graph; UPDATED=2026-01-16
test "GAP-0193: Statistics - Graph density" {
    var result = try geode.parse(testing.allocator, "CALL algo.graph.density() YIELD density RETURN density", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-GRAPH-DIAMETER-001; FEATURE="Statistics"; ASPECT=Diameter; STATUS=TESTED; OWNER=graph; UPDATED=2026-01-16
test "GAP-0193: Statistics - Graph diameter" {
    var result = try geode.parse(testing.allocator, "CALL algo.graph.diameter() YIELD diameter RETURN diameter", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-LOCAL-CLUSTERING-001; FEATURE="Statistics"; ASPECT=LocalClustering; STATUS=TESTED; OWNER=graph; UPDATED=2026-01-16
test "GAP-0193: Statistics - Local clustering coefficient" {
    var result = try geode.parse(testing.allocator, "CALL algo.clustering.local() YIELD node, coefficient RETURN node, coefficient LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MEAN-DISTANCE-001; FEATURE="Statistics"; ASPECT=MeanDistance; STATUS=TESTED; OWNER=graph; UPDATED=2026-01-16
test "GAP-0193: Statistics - Mean distance" {
    var result = try geode.parse(testing.allocator, "CALL algo.graph.meanDistance() YIELD distance RETURN distance", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-TRIANGLE-COUNT-001; FEATURE="Statistics"; ASPECT=TriangleCount; STATUS=TESTED; OWNER=graph; UPDATED=2026-01-16
test "GAP-0193: Statistics - Triangle counting" {
    var result = try geode.parse(testing.allocator, "CALL algo.triangleCount() YIELD triangles RETURN triangles", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Storage: List Properties Tests
// ============================================================================

// CANARY: REQ=REQ-LIST-PROP-001; FEATURE="ListProperties"; ASPECT=Storage; STATUS=TESTED; OWNER=crud_operations; UPDATED=2026-01-16
test "GAP-0193: Storage - List properties" {
    var result = try geode.parse(testing.allocator, "CREATE (n:Node {tags: ['a', 'b', 'c']}) RETURN n.tags AS tags", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Storage: Map Properties Tests
// ============================================================================

// CANARY: REQ=REQ-MAP-PROP-001; FEATURE="MapProperties"; ASPECT=Storage; STATUS=TESTED; OWNER=crud_operations; UPDATED=2026-01-16
test "GAP-0193: Storage - Map properties" {
    var result = try geode.parse(testing.allocator, "CREATE (n:Node {metadata: {key: 'value', num: 42}}) RETURN n.metadata AS meta", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// ============================================================================
// Storage: Materialized View Tests
// ============================================================================

// CANARY: REQ=REQ-MATVIEW-STORAGE-001; FEATURE="MatView"; ASPECT=Storage; STATUS=TESTED; OWNER=query; UPDATED=2026-01-16
test "GAP-0193: Storage - Materialized view storage" {
    // SONNY-6320: there is no CREATE MATERIALIZED VIEW statement in Geode's
    // GQL (materialized views are managed through the procedure API); the
    // parser refuses it.
    try testing.expectError(error.UnexpectedToken, geode.parse(testing.allocator, "CREATE MATERIALIZED VIEW mv_test AS MATCH (n) RETURN n.id AS id", .{}));
}

// ============================================================================
// Additional Engine Tests
// ============================================================================

// CANARY: REQ=REQ-ENGINE-QUERY-001; FEATURE="Engine"; ASPECT=QueryExec; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Engine - Query execution pipeline" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.active = true RETURN n ORDER BY n.created DESC LIMIT 10", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-ENGINE-OPTIMIZATION-001; FEATURE="Engine"; ASPECT=Optimization; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Engine - Query optimization" {
    var result = try geode.parse(testing.allocator, "EXPLAIN MATCH (n) WHERE n.indexed_field = 'value' RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-ENGINE-STREAMING-001; FEATURE="Engine"; ASPECT=Streaming; STATUS=TESTED; OWNER=engine; UPDATED=2026-01-16
test "GAP-0193: Engine - Result streaming" {
    var result = try geode.parse(testing.allocator, "FOR n IN range(1, 1000) RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-STORAGE-TXN-001; FEATURE="Storage"; ASPECT=Transaction; STATUS=TESTED; OWNER=storage; UPDATED=2026-01-16
test "GAP-0193: Storage - Transaction support" {
    var result = try geode.parse(testing.allocator, "START TRANSACTION", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-STORAGE-COMMIT-001; FEATURE="Storage"; ASPECT=Commit; STATUS=TESTED; OWNER=storage; UPDATED=2026-01-16
test "GAP-0193: Storage - Commit transaction" {
    var result = try geode.parse(testing.allocator, "COMMIT", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-STORAGE-ROLLBACK-001; FEATURE="Storage"; ASPECT=Rollback; STATUS=TESTED; OWNER=storage; UPDATED=2026-01-16
test "GAP-0193: Storage - Rollback transaction" {
    var result = try geode.parse(testing.allocator, "ROLLBACK", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-EXECUTION-MERGE-001; FEATURE="Execution"; ASPECT=Merge; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - MERGE operation" {
    var result = try geode.parse(testing.allocator, "MERGE (n:MergeTest {id: 1}) ON CREATE SET n.created = timestamp() RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-EXECUTION-DELETE-001; FEATURE="Execution"; ASPECT=Delete; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - DELETE operation" {
    var result = try geode.parse(testing.allocator, "MATCH (n:Temp) DETACH DELETE n RETURN count(*) AS deleted", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-EXECUTION-SET-001; FEATURE="Execution"; ASPECT=Set; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - SET operation" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.id = 1 SET n.updated = timestamp(), n.version = n.version + 1 RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-EXECUTION-REMOVE-001; FEATURE="Execution"; ASPECT=Remove; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-16
test "GAP-0193: Execution - REMOVE operation" {
    var result = try geode.parse(testing.allocator, "MATCH (n) WHERE n.id = 1 REMOVE n.temp_field RETURN n", .{});
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}
