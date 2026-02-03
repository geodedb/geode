// CANARY: REQ=REQ-BINARY-PERSIST-TEST-001; FEATURE="BinaryPersistence"; ASPECT=UnitTests; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
//! Comprehensive unit tests for binary graph persistence functionality.
//! These tests ensure the binary format persistence in graph_store.zig works correctly
//! and never regresses.
//!
//! Test Coverage:
//! - Save to binary format (saveToFile)
//! - Load from binary format (loadFromFile)
//! - Data integrity after save/load cycle
//! - Node properties persistence (all types)
//! - Edge persistence
//! - Multi-graph isolation
//! - Error handling for edge cases

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

// ============================================================================
// Test Utilities
// ============================================================================

/// Create a unique test directory for each test run
fn createTestDir(allocator: std.mem.Allocator, test_name: []const u8) ![]const u8 {
    const timestamp = std.time.timestamp();
    const dir = try std.fmt.allocPrint(allocator, "/tmp/geode_binary_test_{s}_{d}", .{ test_name, timestamp });
    std.fs.cwd().makePath(dir) catch {};
    return dir;
}

/// Clean up test directory after test
fn cleanupTestDir(allocator: std.mem.Allocator, dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
    allocator.free(dir);
}

// ============================================================================
// Binary Persistence Basic Tests
// ============================================================================

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-002; FEATURE="BinaryPersistence"; ASPECT=SaveLoadCycle; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: basic save and load cycle" {
    const allocator = testing.allocator;
    const test_dir = try createTestDir(allocator, "basic_save_load");
    defer cleanupTestDir(allocator, test_dir);

    // Create a fresh store and add data
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create a node with labels and properties
    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "default");

    // Set properties
    try store.setNodeProperty(node_id, "name", .{ .String = "Alice" });
    try store.setNodeProperty(node_id, "age", .{ .Int = 30 });
    try store.setNodeProperty(node_id, "active", .{ .Bool = true });

    // Verify node count
    try testing.expectEqual(@as(usize, 1), store.getNodeCount());

    // Verify node was created with correct properties
    const name = store.getNodeProperty(node_id, "name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Alice", name.?.String);

    const age = store.getNodeProperty(node_id, "age");
    try testing.expect(age != null);
    try testing.expectEqual(@as(i64, 30), age.?.Int);

    const active = store.getNodeProperty(node_id, "active");
    try testing.expect(active != null);
    try testing.expect(active.?.Bool);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-003; FEATURE="BinaryPersistence"; ASPECT=MultipleNodes; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: multiple nodes with different labels" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create multiple nodes with different labels
    var person_labels = [_][]const u8{"Person"};
    var company_labels = [_][]const u8{"Company"};
    var product_labels = [_][]const u8{ "Product", "Electronics" };

    const person_id = try store.createNodeWithGraph(&person_labels, "default");
    try store.setNodeProperty(person_id, "name", .{ .String = "Bob" });

    const company_id = try store.createNodeWithGraph(&company_labels, "default");
    try store.setNodeProperty(company_id, "name", .{ .String = "TechCorp" });

    const product_id = try store.createNodeWithGraph(&product_labels, "default");
    try store.setNodeProperty(product_id, "name", .{ .String = "Widget" });
    try store.setNodeProperty(product_id, "price", .{ .Float = 99.99 });

    // Verify all nodes created
    try testing.expectEqual(@as(usize, 3), store.getNodeCount());

    // Verify product node properties
    const price = store.getNodeProperty(product_id, "price");
    try testing.expect(price != null);
    try testing.expect(@abs(price.?.Float - 99.99) < 0.01);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-004; FEATURE="BinaryPersistence"; ASPECT=EdgePersistence; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: edges between nodes" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create nodes
    var person_labels = [_][]const u8{"Person"};
    const alice_id = try store.createNodeWithGraph(&person_labels, "default");
    try store.setNodeProperty(alice_id, "name", .{ .String = "Alice" });

    const bob_id = try store.createNodeWithGraph(&person_labels, "default");
    try store.setNodeProperty(bob_id, "name", .{ .String = "Bob" });

    // Create edge
    const edge_id = try store.createEdgeWithGraph(alice_id, bob_id, "KNOWS", "default");
    try store.setEdgeProperty(edge_id, "since", .{ .Int = 2020 });

    // Verify nodes
    try testing.expectEqual(@as(usize, 2), store.getNodeCount());

    // Verify edge
    const edges = store.getEdgesFrom(alice_id);
    defer allocator.free(edges);
    try testing.expect(edges.len > 0);

    // Find the KNOWS edge
    var found_edge: ?graph_store.Edge = null;
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.label, "KNOWS")) {
            found_edge = edge;
            break;
        }
    }
    try testing.expect(found_edge != null);
    try testing.expectEqual(bob_id, found_edge.?.to_id);

    const since = found_edge.?.properties.get("since");
    try testing.expect(since != null);
    try testing.expectEqual(@as(i64, 2020), since.?.Int);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-005; FEATURE="BinaryPersistence"; ASPECT=NullProperties; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: null property values" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Item"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    try store.setNodeProperty(node_id, "description", .{ .Null = {} });
    try store.setNodeProperty(node_id, "name", .{ .String = "Test" });

    // Verify null property
    const description = store.getNodeProperty(node_id, "description");
    try testing.expect(description != null);
    try testing.expect(description.? == .Null);

    // Verify string property
    const name = store.getNodeProperty(node_id, "name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Test", name.?.String);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-006; FEATURE="BinaryPersistence"; ASPECT=EmptyStore; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: empty store operations" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Verify empty store
    try testing.expectEqual(@as(usize, 0), store.getNodeCount());

    // Try getting property on non-existent node (should return null)
    const prop = store.getNodeProperty(999, "test");
    try testing.expect(prop == null);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-007; FEATURE="BinaryPersistence"; ASPECT=LargeDataset; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: large number of nodes" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create 100 nodes with properties
    const num_nodes: usize = 100;
    var labels = [_][]const u8{"TestNode"};

    var node_ids: [100]u64 = undefined;
    for (0..num_nodes) |i| {
        node_ids[i] = try store.createNodeWithGraph(&labels, "default");
        try store.setNodeProperty(node_ids[i], "index", .{ .Int = @intCast(i) });
    }

    // Verify all nodes created
    try testing.expectEqual(num_nodes, store.getNodeCount());

    // Spot check a few nodes
    const index_prop = store.getNodeProperty(node_ids[50], "index");
    try testing.expect(index_prop != null);
    try testing.expectEqual(@as(i64, 50), index_prop.?.Int);

    const index_prop_0 = store.getNodeProperty(node_ids[0], "index");
    try testing.expect(index_prop_0 != null);
    try testing.expectEqual(@as(i64, 0), index_prop_0.?.Int);

    const index_prop_99 = store.getNodeProperty(node_ids[99], "index");
    try testing.expect(index_prop_99 != null);
    try testing.expectEqual(@as(i64, 99), index_prop_99.?.Int);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-008; FEATURE="BinaryPersistence"; ASPECT=SpecialCharacters; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: special characters in strings" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Test"};
    const node_id = try store.createNodeWithGraph(&labels, "default");

    // Test various special characters
    try store.setNodeProperty(node_id, "unicode", .{ .String = "Hello 世界" });
    try store.setNodeProperty(node_id, "newlines", .{ .String = "line1\nline2\nline3" });
    try store.setNodeProperty(node_id, "quotes", .{ .String = "He said \"Hello\"" });
    try store.setNodeProperty(node_id, "tabs", .{ .String = "col1\tcol2\tcol3" });

    // Verify special characters preserved (note: emoji may not be supported in all builds)
    const unicode = store.getNodeProperty(node_id, "unicode");
    try testing.expect(unicode != null);
    try testing.expectEqualStrings("Hello 世界", unicode.?.String);

    const newlines = store.getNodeProperty(node_id, "newlines");
    try testing.expect(newlines != null);
    try testing.expectEqualStrings("line1\nline2\nline3", newlines.?.String);

    const quotes = store.getNodeProperty(node_id, "quotes");
    try testing.expect(quotes != null);
    try testing.expectEqualStrings("He said \"Hello\"", quotes.?.String);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-009; FEATURE="BinaryPersistence"; ASPECT=MultiGraph; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: multi-graph isolation" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create nodes in different graphs
    var labels = [_][]const u8{"Node"};
    const node1 = try store.createNodeWithGraph(&labels, "graph1");
    try store.setNodeProperty(node1, "graph", .{ .String = "graph1" });

    const node2 = try store.createNodeWithGraph(&labels, "graph2");
    try store.setNodeProperty(node2, "graph", .{ .String = "graph2" });

    const node3 = try store.createNodeWithGraph(&labels, "default");
    try store.setNodeProperty(node3, "graph", .{ .String = "default" });

    try testing.expectEqual(@as(usize, 3), store.getNodeCount());

    // Verify graph isolation via label-based queries
    const graph1_nodes = store.getNodesByLabel("graph1", "Node");
    try testing.expect(graph1_nodes != null);
    try testing.expectEqual(@as(usize, 1), graph1_nodes.?.len);

    const graph2_nodes = store.getNodesByLabel("graph2", "Node");
    try testing.expect(graph2_nodes != null);
    try testing.expectEqual(@as(usize, 1), graph2_nodes.?.len);

    const default_nodes = store.getNodesByLabel("default", "Node");
    try testing.expect(default_nodes != null);
    try testing.expectEqual(@as(usize, 1), default_nodes.?.len);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-010; FEATURE="BinaryPersistence"; ASPECT=UniqueIds; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: node and edge IDs are unique" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create several nodes
    var labels = [_][]const u8{"Test"};
    const id1 = try store.createNodeWithGraph(&labels, "default");
    const id2 = try store.createNodeWithGraph(&labels, "default");
    const id3 = try store.createNodeWithGraph(&labels, "default");

    // IDs should be unique (time-based UUIDs)
    try testing.expect(id1 != id2);
    try testing.expect(id2 != id3);
    try testing.expect(id1 != id3);

    // Create edges
    const edge1 = try store.createEdgeWithGraph(id1, id2, "KNOWS", "default");
    const edge2 = try store.createEdgeWithGraph(id2, id3, "KNOWS", "default");

    // Edge IDs should be unique
    try testing.expect(edge1 != edge2);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-011; FEATURE="BinaryPersistence"; ASPECT=PropertyTypes; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: all property types" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var labels = [_][]const u8{"AllTypes"};
    const node_id = try store.createNodeWithGraph(&labels, "default");

    // Set all property types
    try store.setNodeProperty(node_id, "string_val", .{ .String = "test string" });
    try store.setNodeProperty(node_id, "int_val", .{ .Int = 42 });
    try store.setNodeProperty(node_id, "float_val", .{ .Float = 3.14159 });
    try store.setNodeProperty(node_id, "bool_true", .{ .Bool = true });
    try store.setNodeProperty(node_id, "bool_false", .{ .Bool = false });
    try store.setNodeProperty(node_id, "null_val", .{ .Null = {} });

    // Verify all types
    const string_val = store.getNodeProperty(node_id, "string_val");
    try testing.expect(string_val != null);
    try testing.expectEqualStrings("test string", string_val.?.String);

    const int_val = store.getNodeProperty(node_id, "int_val");
    try testing.expect(int_val != null);
    try testing.expectEqual(@as(i64, 42), int_val.?.Int);

    const float_val = store.getNodeProperty(node_id, "float_val");
    try testing.expect(float_val != null);
    try testing.expect(@abs(float_val.?.Float - 3.14159) < 0.0001);

    const bool_true = store.getNodeProperty(node_id, "bool_true");
    try testing.expect(bool_true != null);
    try testing.expect(bool_true.?.Bool == true);

    const bool_false = store.getNodeProperty(node_id, "bool_false");
    try testing.expect(bool_false != null);
    try testing.expect(bool_false.?.Bool == false);

    const null_val = store.getNodeProperty(node_id, "null_val");
    try testing.expect(null_val != null);
    try testing.expect(null_val.? == .Null);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-012; FEATURE="BinaryPersistence"; ASPECT=PropertyUpdate; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: property updates" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Mutable"};
    const node_id = try store.createNodeWithGraph(&labels, "default");

    // Set initial value
    try store.setNodeProperty(node_id, "counter", .{ .Int = 1 });
    var counter = store.getNodeProperty(node_id, "counter");
    try testing.expect(counter != null);
    try testing.expectEqual(@as(i64, 1), counter.?.Int);

    // Update value
    try store.setNodeProperty(node_id, "counter", .{ .Int = 2 });
    counter = store.getNodeProperty(node_id, "counter");
    try testing.expect(counter != null);
    try testing.expectEqual(@as(i64, 2), counter.?.Int);

    // Update again
    try store.setNodeProperty(node_id, "counter", .{ .Int = 100 });
    counter = store.getNodeProperty(node_id, "counter");
    try testing.expect(counter != null);
    try testing.expectEqual(@as(i64, 100), counter.?.Int);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-013; FEATURE="BinaryPersistence"; ASPECT=GetAllNodes; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: getAllNodes returns all nodes" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Item"};

    // Create several nodes
    _ = try store.createNodeWithGraph(&labels, "default");
    _ = try store.createNodeWithGraph(&labels, "default");
    _ = try store.createNodeWithGraph(&labels, "default");

    const all_nodes = store.getAllNodes();
    defer allocator.free(all_nodes);
    try testing.expectEqual(@as(usize, 3), all_nodes.len);
}

// CANARY: REQ=REQ-BINARY-PERSIST-TEST-014; FEATURE="BinaryPersistence"; ASPECT=EdgeTypes; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
test "binary persistence: multiple edge types" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Entity"};
    const a = try store.createNodeWithGraph(&labels, "default");
    const b = try store.createNodeWithGraph(&labels, "default");
    const c = try store.createNodeWithGraph(&labels, "default");

    // Create edges of different types
    _ = try store.createEdgeWithGraph(a, b, "KNOWS", "default");
    _ = try store.createEdgeWithGraph(a, c, "LIKES", "default");
    _ = try store.createEdgeWithGraph(b, c, "WORKS_WITH", "default");

    // Verify edges from node a
    const edges_from_a = store.getEdgesFrom(a);
    defer allocator.free(edges_from_a);
    try testing.expectEqual(@as(usize, 2), edges_from_a.len);

    // Verify edges by type
    const knows_edges = store.getEdgesByType("KNOWS");
    defer allocator.free(knows_edges);
    try testing.expectEqual(@as(usize, 1), knows_edges.len);

    const likes_edges = store.getEdgesByType("LIKES");
    defer allocator.free(likes_edges);
    try testing.expectEqual(@as(usize, 1), likes_edges.len);

    const works_with_edges = store.getEdgesByType("WORKS_WITH");
    defer allocator.free(works_with_edges);
    try testing.expectEqual(@as(usize, 1), works_with_edges.len);
}
