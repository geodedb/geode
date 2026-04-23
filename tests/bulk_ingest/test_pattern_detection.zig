// Task 10 — pattern detection unit tests for the bulk-ingest fast path.
//
// Exercises `bulk_ingest.matchSingleStatement` against the msft-graph node
// CREATE shapes that drive Phase 3 of the enterprise-ingest-throughput plan.
// Each test parses a real GQL statement (through the standard parser path)
// and asserts the detected BulkPattern value — so if the parser emits a
// structure the detector doesn't handle, we catch it here instead of at
// QUIC dispatch time.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const bulk_ingest = geode.bulk_ingest;

// ----------------------------------------------------------------------
// Positive: simple CREATE (n:Label {prop: literal}) is the target pattern.
// ----------------------------------------------------------------------

test "detects simple CREATE with single string property" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User {node_id: 'abc-123'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects simple CREATE with multiple scalar properties" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "CREATE (n:User {node_id: 'abc-123', name: 'Alice', age: 30, active: true})",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects simple CREATE with no properties (label only)" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User)", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects simple CREATE with a parameter-valued property" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User {node_id: $node_id})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects simple CREATE with anonymous node pattern" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (:User {node_id: 'abc-123'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

// ----------------------------------------------------------------------
// Negative: RETURN, WHERE, expressions, multiple patterns all decline.
// ----------------------------------------------------------------------

test "rejects CREATE with RETURN clause" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User {node_id: 'abc-123'}) RETURN n", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with arithmetic expression property value" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User {node_id: 1 + 2})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with function-call property value" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User {node_id: toString(42)})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with list-literal property value" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User {tags: ['a', 'b']})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with two node patterns" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (a:User), (b:Device)", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with relationship hop (two-node path)" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "CREATE (a:User {id: 1})-[:KNOWS]->(b:User {id: 2})",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with two labels on the node" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:User:Admin {node_id: 'abc'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects MERGE (not a CREATE)" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("MERGE (n:User {node_id: 'abc'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects MATCH+CREATE edge (Task 12 dispatch, still .none)" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MATCH (a:User {id: 1}), (b:Device {id: 2}) CREATE (a)-[:OWNS]->(b)",
        allocator,
    );
    defer pr.deinit();
    // Today Task 11 only dispatches simple_node_create; the match_create_edge
    // enum variant exists for future Task 12 work.  The matcher must report
    // `.none` for this shape until Task 12 wires up the full detection.
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}
