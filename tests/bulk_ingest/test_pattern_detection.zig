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
    var pr = try geode.parseGql("CREATE (n:Widget {node_id: 'abc-123'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects simple CREATE with multiple scalar properties" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "CREATE (n:Widget {node_id: 'abc-123', name: 'alpha', age: 30, active: true})",
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
    var pr = try geode.parseGql("CREATE (n:Widget)", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects simple CREATE with a parameter-valued property" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:Widget {node_id: $node_id})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_create,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects simple CREATE with anonymous node pattern" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (:Widget {node_id: 'abc-123'})", allocator);
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
    var pr = try geode.parseGql("CREATE (n:Widget {node_id: 'abc-123'}) RETURN n", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with arithmetic expression property value" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:Widget {node_id: 1 + 2})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with function-call property value" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:Widget {node_id: toString(42)})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with list-literal property value" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (n:Widget {tags: ['a', 'b']})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with two node patterns" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("CREATE (a:Widget), (b:Gadget)", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects CREATE with relationship hop (two-node path)" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "CREATE (a:Widget {id: 1})-[:LINKS_TO]->(b:Widget {id: 2})",
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
    var pr = try geode.parseGql("CREATE (n:Widget:Elite {node_id: 'abc'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

// ----------------------------------------------------------------------
// Simple MERGE node (Task "MERGE-extend" of enterprise-ingest-throughput):
// `MERGE (n:L {merge_key: lit_or_param}) [ON CREATE SET n.x = ...]`.
// ----------------------------------------------------------------------

test "detects simple MERGE with single merge key and no ON CREATE SET" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("MERGE (n:Widget {node_id: 'abc'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_merge,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
    const spec = bulk_ingest.matchSimpleNodeMergeSpec(&pr.program) orelse
        return error.SpecExpected;
    try testing.expectEqualStrings("Widget", spec.label);
    try testing.expectEqualStrings("node_id", spec.merge_key);
    try testing.expectEqual(@as(usize, 0), spec.on_create_props.len);
}

test "detects simple MERGE with ON CREATE SET scalar properties" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MERGE (n:Widget {node_id: 'abc'}) ON CREATE SET n.name = 'alpha', n.email = 'a@b.c'",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_merge,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
    const spec = bulk_ingest.matchSimpleNodeMergeSpec(&pr.program) orelse
        return error.SpecExpected;
    try testing.expectEqualStrings("Widget", spec.label);
    try testing.expectEqualStrings("node_id", spec.merge_key);
    try testing.expectEqual(@as(usize, 2), spec.on_create_props.len);
    try testing.expectEqualStrings("name", spec.on_create_props[0].key);
    try testing.expectEqualStrings("email", spec.on_create_props[1].key);
}

test "detects simple MERGE with parameter merge value and parameter SET" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MERGE (n:Widget {node_id: $node_id}) ON CREATE SET n.name = $name",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_merge,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects MERGE with RETURN clause" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("MERGE (n:Widget {node_id: 'abc'}) RETURN n", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects MERGE with ON MATCH SET clause" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MERGE (n:Widget {node_id: 'abc'}) ON MATCH SET n.updated = 1",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "detects MERGE with multi-property filter" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MERGE (n:Widget {a: 1, b: 2})",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.simple_node_merge,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
    const spec = bulk_ingest.matchSimpleNodeMergeSpec(&pr.program) orelse
        return error.SpecExpected;
    try testing.expectEqualStrings("Widget", spec.label);
    try testing.expectEqual(@as(usize, 2), spec.merge_props.len);
    try testing.expectEqualStrings("a", spec.merge_props[0].key);
    try testing.expectEqualStrings("b", spec.merge_props[1].key);
}

test "rejects multi-property MERGE with ON MATCH SET clause" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MERGE (n:Widget {a: 1, b: 2}) ON MATCH SET n.updated = 1",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects MERGE with multi-label node pattern" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("MERGE (n:Widget:Elite {node_id: 'abc'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects MERGE without a label" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql("MERGE (n {node_id: 'abc'})", allocator);
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "rejects MERGE with ON CREATE SET non-scalar value" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MERGE (n:Widget {node_id: 'abc'}) ON CREATE SET n.name = toString(42)",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

// ----------------------------------------------------------------------
// MATCH+CREATE edge (Task 12) — positive + negative cases.
// ----------------------------------------------------------------------

test "detects MATCH+CREATE edge with node_id filters (msft-graph shape)" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MATCH (a:Widget {node_id: 'abc'}), (b:Gadget {node_id: 'def'}) CREATE (a)-[:LINKS_TO]->(b)",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.match_create_edge,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
    const spec = bulk_ingest.matchEdgeSpec(&pr.program) orelse
        return error.SpecExpected;
    try testing.expectEqualStrings("a", spec.source.var_name);
    try testing.expectEqualStrings("Widget", spec.source.label);
    try testing.expectEqualStrings("node_id", spec.source.filter_key);
    try testing.expectEqualStrings("b", spec.target.var_name);
    try testing.expectEqualStrings("Gadget", spec.target.label);
    try testing.expectEqualStrings("node_id", spec.target.filter_key);
    try testing.expectEqualStrings("LINKS_TO", spec.rel_type);
    try testing.expectEqual(@as(usize, 0), spec.props.len);
}

test "detects MATCH+CREATE edge with scalar edge properties" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MATCH (a:Widget {node_id: 'abc'}), (b:Gadget {node_id: 'def'}) " ++
            "CREATE (a)-[:LINKS_TO {since: '2020', weight: 5}]->(b)",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.match_create_edge,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
    const spec = bulk_ingest.matchEdgeSpec(&pr.program) orelse
        return error.SpecExpected;
    try testing.expectEqual(@as(usize, 2), spec.props.len);
    try testing.expectEqualStrings("since", spec.props[0].key);
    try testing.expectEqualStrings("weight", spec.props[1].key);
}

test "MATCH+CREATE edge rejects WHERE clause" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MATCH (a:Widget {id: 1}), (b:Gadget {id: 2}) WHERE a.x = 1 CREATE (a)-[:R]->(b)",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "MATCH+CREATE edge rejects RETURN clause" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MATCH (a:Widget {id: 1}), (b:Gadget {id: 2}) CREATE (a)-[r:R]->(b) RETURN r",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "MATCH+CREATE edge rejects single-match (CREATE introduces new node)" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MATCH (a:Widget {id: 1}) CREATE (a)-[:R]->(b:Other)",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}

test "MATCH+CREATE edge rejects undirected edge" {
    const allocator = testing.allocator;
    var pr = try geode.parseGql(
        "MATCH (a:Widget {id: 1}), (b:Gadget {id: 2}) CREATE (a)-[:R]-(b)",
        allocator,
    );
    defer pr.deinit();
    try testing.expectEqual(
        bulk_ingest.BulkPattern.none,
        bulk_ingest.matchSingleStatement(&pr.program),
    );
}
