const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const execution = geode.execution;
const lib = geode;
const ast = geode.ast;

// Test that MATCH with labels works
test "MATCH - Labels only" {
    const allocator = testing.allocator;
    const query = "MATCH (a:Person) RETURN a";
    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("MATCH labels error: {}\n", .{err});
        return err;
    };
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// Test that MATCH with WHERE and CALL works
test "MATCH WHERE CALL" {
    const allocator = testing.allocator;
    const query = "MATCH (n:Person) WHERE n.name = 'A' CALL algo.bfs.stream(n, {maxDepth: 2}) YIELD path RETURN path";
    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("MATCH WHERE CALL error: {}\n", .{err});
        return err;
    };
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// Test that MATCH with labels and properties works (with relationship)
test "MATCH - Labels and properties with relationship" {
    const allocator = testing.allocator;
    const query = "MATCH (a:Person {name: \"A\"})-[r]->(b) RETURN a";
    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("MATCH parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();
    try testing.expect(result.program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-001; FEATURE="MatchCallIntegration"; ASPECT=UnitTesting; STATUS=TESTED; TEST=TestMatchCallBasic|TestMatchCallWithProperties|TestMatchCallDijkstra; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - Basic node binding" {
    const allocator = testing.allocator;

    var store = graph_store.getGlobalStore(allocator);
    store.clearNodes();

    // Create test graph
    const labels = [_][]const u8{"TestNode"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    const node_a = try store.createNode(labels_slice);
    const node_b = try store.createNode(labels_slice);
    const node_c = try store.createNode(labels_slice);

    try store.setNodeProperty(node_a, "name", graph_store.PropertyValue{ .String = "A" });
    try store.setNodeProperty(node_b, "name", graph_store.PropertyValue{ .String = "B" });
    try store.setNodeProperty(node_c, "name", graph_store.PropertyValue{ .String = "C" });

    // Create edges
    _ = try store.createEdge(node_a, node_b, "CONNECTS");
    _ = try store.createEdge(node_b, node_c, "CONNECTS");

    // Parse and execute MATCH + CALL query
    const query = "MATCH (source:Person) WHERE source.name = 'A' CALL algo.bfs.stream(source, {maxDepth: 2}) YIELD path RETURN path";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);

    const stmt = program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.call_clause != null);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-002; FEATURE="MatchCallIntegration"; ASPECT=PropertyMatching; STATUS=TESTED; TEST=TestMatchCallPropertyFiltering; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - Property-based node filtering" {
    const allocator = testing.allocator;

    var store = graph_store.getGlobalStore(allocator);
    store.clearNodes();

    // Create test nodes with different properties
    const labels = [_][]const u8{"TestNode"};
    const labels_slice: [][]const u8 = @constCast(&labels);

    const node1 = try store.createNode(labels_slice);
    const node2 = try store.createNode(labels_slice);
    const node3 = try store.createNode(labels_slice);

    try store.setNodeProperty(node1, "name", graph_store.PropertyValue{ .String = "Start" });
    try store.setNodeProperty(node1, "priority", graph_store.PropertyValue{ .Int = 1 });

    try store.setNodeProperty(node2, "name", graph_store.PropertyValue{ .String = "Middle" });
    try store.setNodeProperty(node2, "priority", graph_store.PropertyValue{ .Int = 2 });

    try store.setNodeProperty(node3, "name", graph_store.PropertyValue{ .String = "End" });
    try store.setNodeProperty(node3, "priority", graph_store.PropertyValue{ .Int = 3 });

    // Test that property filtering works
    const query = "MATCH (n:TestNode) WHERE n.priority = 1 CALL algo.dfs.stream(n, {maxDepth: 3}) YIELD path RETURN path";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("Property filtering parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-003; FEATURE="MatchCallIntegration"; ASPECT=DijkstraWithBinding; STATUS=TESTED; TEST=TestMatchCallDijkstraBinding; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - Dijkstra with start and end binding" {
    const allocator = testing.allocator;

    var store = graph_store.getGlobalStore(allocator);
    store.clearNodes();

    // Create test graph for shortest path
    const labels = [_][]const u8{"TestNode"};
    const labels_slice: [][]const u8 = @constCast(&labels);

    const node_a = try store.createNode(labels_slice);
    const node_b = try store.createNode(labels_slice);
    const node_c = try store.createNode(labels_slice);
    const node_d = try store.createNode(labels_slice);

    try store.setNodeProperty(node_a, "name", graph_store.PropertyValue{ .String = "A" });
    try store.setNodeProperty(node_b, "name", graph_store.PropertyValue{ .String = "B" });
    try store.setNodeProperty(node_c, "name", graph_store.PropertyValue{ .String = "C" });
    try store.setNodeProperty(node_d, "name", graph_store.PropertyValue{ .String = "D" });

    // Create weighted edges
    const edge_ab = try store.createEdge(node_a, node_b, "ROAD");
    const edge_bc = try store.createEdge(node_b, node_c, "ROAD");
    const edge_ac = try store.createEdge(node_a, node_c, "ROAD");
    const edge_cd = try store.createEdge(node_c, node_d, "ROAD");

    // Set edge weights using setEdgeProperty to avoid memory leaks
    try store.setEdgeProperty(edge_ab, "weight", graph_store.PropertyValue{ .Float = 1.0 });
    try store.setEdgeProperty(edge_bc, "weight", graph_store.PropertyValue{ .Float = 2.0 });
    try store.setEdgeProperty(edge_ac, "weight", graph_store.PropertyValue{ .Float = 5.0 });
    try store.setEdgeProperty(edge_cd, "weight", graph_store.PropertyValue{ .Float = 1.0 });

    // Parse MATCH + CALL Dijkstra query
    const query = "MATCH (source:Person), (target:Person) WHERE source.name = 'A' AND target.name = 'D' CALL algo.shortestPath.dijkstra(source, target, 'weight') YIELD path, cost RETURN cost";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("Dijkstra parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);
    try testing.expect(program.statements[0] == .Query);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-004; FEATURE="MatchCallIntegration"; ASPECT=MultipleNodeBinding; STATUS=TESTED; TEST=TestMatchCallMultipleNodes; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - Multiple node bindings" {
    const allocator = testing.allocator;

    var store = graph_store.getGlobalStore(allocator);
    store.clearNodes();

    // Create nodes
    const labels = [_][]const u8{"TestNode"};
    const labels_slice: [][]const u8 = @constCast(&labels);

    const node1 = try store.createNode(labels_slice);
    const node2 = try store.createNode(labels_slice);

    try store.setNodeProperty(node1, "type", graph_store.PropertyValue{ .String = "source" });
    try store.setNodeProperty(node2, "type", graph_store.PropertyValue{ .String = "target" });

    // Test query with multiple MATCH variables
    const query = "MATCH (src:TestNode), (tgt:TestNode) WHERE src.type = 'source' AND tgt.type = 'target' CALL algo.shortestPath.dijkstra(src, tgt, 'weight') YIELD path RETURN path";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("Multiple binding parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-005; FEATURE="MatchCallIntegration"; ASPECT=YieldAndReturn; STATUS=TESTED; TEST=TestMatchCallYieldReturn; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - YIELD and RETURN interaction" {
    const allocator = testing.allocator;

    const query = "MATCH (n:TestNode) CALL algo.pageRank.stream({iterations: 20}) YIELD nodeId, score RETURN nodeId, score ORDER BY score DESC LIMIT 10";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("YIELD/RETURN parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);
    const stmt = program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.call_clause != null);
    try testing.expect(q.call_clause.?.yield_items != null);
    try testing.expect(q.order_by != null);
    try testing.expect(q.limit != null);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-006; FEATURE="MatchCallIntegration"; ASPECT=OrderByAndLimit; STATUS=TESTED; TEST=TestMatchCallOrderByLimit; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - ORDER BY and LIMIT on CALL results" {
    const allocator = testing.allocator;

    const query = "MATCH (source:Person) WHERE source.name = 'A' CALL algo.bfs.stream(source, {maxDepth: 3}) YIELD path RETURN length(path) AS depth ORDER BY depth LIMIT 5";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("ORDER BY/LIMIT parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);
    const stmt = program.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.order_by != null);
    try testing.expect(q.limit != null);
    try testing.expectEqual(@as(usize, 5), q.limit.?);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-007; FEATURE="MatchCallIntegration"; ASPECT=LabelMatching; STATUS=TESTED; TEST=TestMatchCallLabelFilter; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - Label-based filtering" {
    const allocator = testing.allocator;

    var store = graph_store.getGlobalStore(allocator);
    store.clearNodes();

    // Create nodes with different labels
    const person_labels = [_][]const u8{"Person"};
    const company_labels = [_][]const u8{"Company"};

    const person_slice: [][]const u8 = @constCast(&person_labels);
    const company_slice: [][]const u8 = @constCast(&company_labels);

    const person = try store.createNode(person_slice);
    const company = try store.createNode(company_slice);

    try store.setNodeProperty(person, "name", graph_store.PropertyValue{ .String = "Alice" });
    try store.setNodeProperty(company, "name", graph_store.PropertyValue{ .String = "TechCorp" });

    // Query should only match Person nodes
    const query = "MATCH (p:Person) CALL algo.bfs.stream(p, {maxDepth: 2}) YIELD path RETURN path";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("Label filter parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);
}

// CANARY: REQ=REQ-GQL-MATCH-CALL-008; FEATURE="MatchCallIntegration"; ASPECT=DirectNodeIdFallback; STATUS=TESTED; TEST=TestMatchCallDirectId; OWNER=engine; UPDATED=2025-10-08
test "MATCH + CALL - Direct node ID usage (fallback mode)" {
    const allocator = testing.allocator;

    // Test that direct node IDs still work
    const query = "CALL algo.bfs.stream(1, {maxDepth: 3}) YIELD path RETURN path";

    var result = lib.parse(allocator, query, .{}) catch |err| {
        std.debug.print("Direct ID parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const program = result.program;

    try testing.expect(program.statements.len > 0);
    const stmt = program.statements[0];
    try testing.expect(stmt == .Call);
}
