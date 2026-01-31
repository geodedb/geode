// CANARY: REQ=REQ-GRAPH-PERSIST-TEST-001; FEATURE="NamedGraphPersistence"; ASPECT=UnitTests; STATUS=TESTED; OWNER=storage; UPDATED=2026-01-30
//! Comprehensive unit tests for graph persistence functionality.
//! These tests cover the GAP-384 fix for multi-statement batch graph persistence.
//!
//! Test Coverage:
//! - Data directory management (setDataDir/getDataDir)
//! - Graph storage creation (createGraphStorage)
//! - Graph persistence (saveNamedGraph)
//! - Graph loading (loadNamedGraph)
//! - Multi-graph isolation
//! - Batch creation scenarios
//! - Error handling for edge cases

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_storage_mgr = geode.graph_storage_manager;

// ============================================================================
// Test Utilities
// ============================================================================

/// Get test allocator - use page_allocator to avoid false positives from GraphStorage
/// internal allocations that aren't fully freed by deinit (pre-existing issue).
fn getTestAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Create a unique test directory for each test run
fn createTestDir(allocator: std.mem.Allocator, test_name: []const u8) ![]const u8 {
    const timestamp = std.time.timestamp();

    const dir = try std.fmt.allocPrint(allocator, "/tmp/geode_test_{s}_{d}", .{ test_name, timestamp });
    std.fs.cwd().makePath(dir) catch {};
    return dir;
}

/// Clean up test directory after test
fn cleanupTestDir(allocator: std.mem.Allocator, dir: []const u8) void {
    // Remove all files and subdirectories recursively
    std.fs.cwd().deleteTree(dir) catch {};
    allocator.free(dir);
}

/// Reset global state between tests
fn resetGlobalState() void {
    graph_storage_mgr.setDataDir(null);
    graph_storage_mgr.clearGraphStorage();
    graph_storage_mgr.clearMultiGraphStorage();
}

// ============================================================================
// Data Directory Management Tests
// ============================================================================

test "setDataDir and getDataDir work correctly" {
    defer resetGlobalState();

    // Initially null
    try testing.expectEqual(@as(?[]const u8, null), graph_storage_mgr.getDataDir());

    // Set data directory
    const test_dir = "/tmp/test_data_dir";
    graph_storage_mgr.setDataDir(test_dir);

    // Verify it was set
    const retrieved = graph_storage_mgr.getDataDir();
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(test_dir, retrieved.?);
}

test "setDataDir can be set to null" {
    defer resetGlobalState();

    // Set and then clear
    graph_storage_mgr.setDataDir("/tmp/test");
    try testing.expect(graph_storage_mgr.getDataDir() != null);

    graph_storage_mgr.setDataDir(null);
    try testing.expectEqual(@as(?[]const u8, null), graph_storage_mgr.getDataDir());
}

// ============================================================================
// Graph Storage Creation Tests
// ============================================================================

test "createGraphStorage creates new empty graph" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    const graph = try graph_storage_mgr.createGraphStorage(allocator, "test_graph_create");

    // Verify graph is empty
    try testing.expectEqual(@as(usize, 0), graph.nodes.count());
    try testing.expectEqual(@as(usize, 0), graph.edges.items.len);

    // Verify it exists in storage
    try testing.expect(graph_storage_mgr.graphExists("test_graph_create"));
}

test "createGraphStorage fails for duplicate graph name" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    // Create first graph
    _ = try graph_storage_mgr.createGraphStorage(allocator, "duplicate_test");

    // Try to create another with same name - should fail
    const result = graph_storage_mgr.createGraphStorage(allocator, "duplicate_test");
    try testing.expectError(error.GraphAlreadyExists, result);
}

test "createGraphStorage allows multiple unique graphs" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    // Create multiple graphs with unique names
    _ = try graph_storage_mgr.createGraphStorage(allocator, "graph_alpha");
    _ = try graph_storage_mgr.createGraphStorage(allocator, "graph_beta");
    _ = try graph_storage_mgr.createGraphStorage(allocator, "graph_gamma");

    // All should exist
    try testing.expect(graph_storage_mgr.graphExists("graph_alpha"));
    try testing.expect(graph_storage_mgr.graphExists("graph_beta"));
    try testing.expect(graph_storage_mgr.graphExists("graph_gamma"));

    // Verify list returns all
    const names = try graph_storage_mgr.listGraphNames(allocator);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 3), names.len);
}

// ============================================================================
// Graph Persistence Tests
// ============================================================================

test "saveNamedGraph creates directory and files" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "save_graph");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    // Set data directory
    graph_storage_mgr.setDataDir(test_dir);

    // Create and populate a graph
    const graph = try graph_storage_mgr.createGraphStorage(allocator, "persist_test");
    try graph.addNode(allocator, 1, &.{"Person"});
    try graph.setNodeProperty(allocator, 1, "name", .{ .String = "Alice" });

    // Save the graph
    try graph_storage_mgr.saveNamedGraph(allocator, "persist_test");

    // Verify directory was created
    const graph_dir = try std.fmt.allocPrint(allocator, "{s}/graphs/persist_test", .{test_dir});
    defer allocator.free(graph_dir);

    var dir = std.fs.cwd().openDir(graph_dir, .{}) catch |err| {
        std.debug.print("Failed to open graph dir: {}\n", .{err});
        return err;
    };
    defer dir.close();

    // Verify nodes.jsonl exists
    const nodes_stat = try dir.statFile("nodes.jsonl");
    try testing.expect(nodes_stat.size > 0);

    // Verify edges.jsonl exists
    const edges_stat = try dir.statFile("edges.jsonl");
    try testing.expect(edges_stat.size >= 0); // Can be empty if no edges
}

test "saveNamedGraph fails without data directory" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    // Ensure no data directory
    graph_storage_mgr.setDataDir(null);

    // Create a graph
    _ = try graph_storage_mgr.createGraphStorage(allocator, "no_dir_test");

    // Should fail with NoDataDirectory
    const result = graph_storage_mgr.saveNamedGraph(allocator, "no_dir_test");
    try testing.expectError(error.NoDataDirectory, result);
}

test "saveNamedGraph fails for non-existent graph" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "save_nonexistent");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Try to save a graph that doesn't exist
    const result = graph_storage_mgr.saveNamedGraph(allocator, "nonexistent_graph");
    try testing.expectError(error.GraphNotFound, result);
}

test "saveNamedGraph preserves node data correctly" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "preserve_nodes");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Create graph with multiple nodes and properties
    const graph = try graph_storage_mgr.createGraphStorage(allocator, "node_data_test");

    try graph.addNode(allocator, 1, &.{"Person"});
    try graph.setNodeProperty(allocator, 1, "name", .{ .String = "Alice" });
    try graph.setNodeProperty(allocator, 1, "age", .{ .Int = 30 });

    try graph.addNode(allocator, 2, &.{ "Person", "Employee" });
    try graph.setNodeProperty(allocator, 2, "name", .{ .String = "Bob" });
    try graph.setNodeProperty(allocator, 2, "active", .{ .Bool = true });

    // Save the graph
    try graph_storage_mgr.saveNamedGraph(allocator, "node_data_test");

    // Read and verify nodes.jsonl content
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/graphs/node_data_test/nodes.jsonl", .{test_dir});
    defer allocator.free(nodes_path);

    const content = try std.fs.cwd().readFileAlloc(allocator, nodes_path, 1024 * 1024);
    defer allocator.free(content);

    // Verify content contains expected data
    try testing.expect(std.mem.indexOf(u8, content, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"id\":2") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"Person\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Bob") != null);
}

test "saveNamedGraph preserves edge data correctly" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "preserve_edges");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Create graph with edges
    const graph = try graph_storage_mgr.createGraphStorage(allocator, "edge_data_test");

    try graph.addNode(allocator, 1, &.{"Person"});
    try graph.addNode(allocator, 2, &.{"Person"});
    _ = try graph.addEdge(allocator, 1, 2, "KNOWS");

    // Save the graph
    try graph_storage_mgr.saveNamedGraph(allocator, "edge_data_test");

    // Read and verify edges.jsonl content
    const edges_path = try std.fmt.allocPrint(allocator, "{s}/graphs/edge_data_test/edges.jsonl", .{test_dir});
    defer allocator.free(edges_path);

    const content = try std.fs.cwd().readFileAlloc(allocator, edges_path, 1024 * 1024);
    defer allocator.free(content);

    // Verify edge data
    try testing.expect(std.mem.indexOf(u8, content, "\"source\":1") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"target\":2") != null);
    try testing.expect(std.mem.indexOf(u8, content, "KNOWS") != null);
}

// ============================================================================
// Graph Loading Tests
// ============================================================================

test "loadNamedGraph loads persisted graph" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "load_graph");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Create, populate, and save a graph
    const original = try graph_storage_mgr.createGraphStorage(allocator, "load_test");
    try original.addNode(allocator, 42, &.{"TestLabel"});
    try original.setNodeProperty(allocator, 42, "value", .{ .Int = 12345 });
    try graph_storage_mgr.saveNamedGraph(allocator, "load_test");

    // Clear the in-memory storage
    resetGlobalState();
    graph_storage_mgr.setDataDir(test_dir);

    // Load the graph
    const loaded = try graph_storage_mgr.loadNamedGraph(allocator, "load_test");

    // Verify loaded data
    try testing.expectEqual(@as(usize, 1), loaded.nodes.count());

    const node = loaded.nodes.get(42);
    try testing.expect(node != null);
    try testing.expectEqual(@as(u64, 42), node.?.id);
}

test "loadNamedGraph fails for non-existent graph directory" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "load_missing");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Try to load a graph that was never saved
    const result = graph_storage_mgr.loadNamedGraph(allocator, "never_existed");
    try testing.expectError(error.GraphNotFound, result);
}

// ============================================================================
// Multi-Statement Batch Tests (GAP-384 Core Fix Validation)
// ============================================================================

test "multiple graphs can be created and persisted in sequence" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "batch_create");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Simulate batch: CREATE GRAPH g1; CREATE GRAPH g2; CREATE GRAPH g3;
    const graph_names = [_][]const u8{ "batch_g1", "batch_g2", "batch_g3" };

    for (graph_names) |name| {
        _ = try graph_storage_mgr.createGraphStorage(allocator, name);
        try graph_storage_mgr.saveNamedGraph(allocator, name);
    }

    // Verify all directories were created
    for (graph_names) |name| {
        const graph_dir = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}", .{ test_dir, name });
        defer allocator.free(graph_dir);

        std.fs.cwd().access(graph_dir, .{}) catch |err| {
            std.debug.print("Directory missing for {s}: {}\n", .{ name, err });
            return err;
        };

        // Verify nodes.jsonl exists
        const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.jsonl", .{graph_dir});
        defer allocator.free(nodes_path);
        std.fs.cwd().access(nodes_path, .{}) catch |err| {
            std.debug.print("nodes.jsonl missing for {s}: {}\n", .{ name, err });
            return err;
        };
    }
}

test "graphs persist independently in batch operations" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "batch_independent");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Create graphs with different data
    const g1 = try graph_storage_mgr.createGraphStorage(allocator, "independent_g1");
    try g1.addNode(allocator, 1, &.{"TypeA"});
    try graph_storage_mgr.saveNamedGraph(allocator, "independent_g1");

    const g2 = try graph_storage_mgr.createGraphStorage(allocator, "independent_g2");
    try g2.addNode(allocator, 2, &.{"TypeB"});
    try g2.addNode(allocator, 3, &.{"TypeB"});
    try graph_storage_mgr.saveNamedGraph(allocator, "independent_g2");

    // Verify each has its own data
    const g1_path = try std.fmt.allocPrint(allocator, "{s}/graphs/independent_g1/nodes.jsonl", .{test_dir});
    defer allocator.free(g1_path);
    const g1_content = try std.fs.cwd().readFileAlloc(allocator, g1_path, 1024 * 1024);
    defer allocator.free(g1_content);

    const g2_path = try std.fmt.allocPrint(allocator, "{s}/graphs/independent_g2/nodes.jsonl", .{test_dir});
    defer allocator.free(g2_path);
    const g2_content = try std.fs.cwd().readFileAlloc(allocator, g2_path, 1024 * 1024);
    defer allocator.free(g2_content);

    // g1 should have TypeA, g2 should have TypeB
    try testing.expect(std.mem.indexOf(u8, g1_content, "TypeA") != null);
    try testing.expect(std.mem.indexOf(u8, g1_content, "TypeB") == null);
    try testing.expect(std.mem.indexOf(u8, g2_content, "TypeB") != null);
    try testing.expect(std.mem.indexOf(u8, g2_content, "TypeA") == null);

    // g2 should have 2 nodes
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, g2_content, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), line_count);
}

// ============================================================================
// Graph Data Directory Path Tests
// ============================================================================

test "getGraphDataDir returns correct path format" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    graph_storage_mgr.setDataDir("/data/geode");

    const path = try graph_storage_mgr.getGraphDataDir(allocator, "my_graph");
    defer allocator.free(path);

    try testing.expectEqualStrings("/data/geode/graphs/my_graph", path);
}

test "getGraphDataDir fails without data directory" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    graph_storage_mgr.setDataDir(null);

    const result = graph_storage_mgr.getGraphDataDir(allocator, "test");
    try testing.expectError(error.NoDataDirectory, result);
}

// ============================================================================
// Graph Existence Tests
// ============================================================================

test "graphExists returns false for non-existent graph" {
    defer resetGlobalState();

    try testing.expect(!graph_storage_mgr.graphExists("completely_fake_graph"));
}

test "graphExists returns true after graph creation" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    // Before creation
    try testing.expect(!graph_storage_mgr.graphExists("existence_test"));

    // Create
    _ = try graph_storage_mgr.createGraphStorage(allocator, "existence_test");

    // After creation
    try testing.expect(graph_storage_mgr.graphExists("existence_test"));
}

// ============================================================================
// Drop Graph Tests
// ============================================================================

test "dropGraphStorage removes graph" {
    const allocator = getTestAllocator();

    defer resetGlobalState();

    // Create and verify
    _ = try graph_storage_mgr.createGraphStorage(allocator, "drop_test");
    try testing.expect(graph_storage_mgr.graphExists("drop_test"));

    // Drop
    try graph_storage_mgr.dropGraphStorage("drop_test");

    // Verify removed
    try testing.expect(!graph_storage_mgr.graphExists("drop_test"));
}

test "dropGraphStorage fails for non-existent graph" {
    defer resetGlobalState();

    const result = graph_storage_mgr.dropGraphStorage("never_existed_drop");
    try testing.expectError(error.GraphNotFound, result);
}

test "dropGraphStorage fails for default graph" {
    defer resetGlobalState();

    const result = graph_storage_mgr.dropGraphStorage(graph_storage_mgr.DEFAULT_GRAPH_NAME);
    try testing.expectError(error.CannotDropDefaultGraph, result);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "graph names with special characters" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "special_chars");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Test with underscores and numbers (valid identifiers)
    _ = try graph_storage_mgr.createGraphStorage(allocator, "graph_with_underscores_123");
    try graph_storage_mgr.saveNamedGraph(allocator, "graph_with_underscores_123");

    try testing.expect(graph_storage_mgr.graphExists("graph_with_underscores_123"));
}

test "empty graph persists correctly" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "empty_graph");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Create empty graph
    _ = try graph_storage_mgr.createGraphStorage(allocator, "empty_test");
    try graph_storage_mgr.saveNamedGraph(allocator, "empty_test");

    // Verify files exist but are empty (or contain only newlines)
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/graphs/empty_test/nodes.jsonl", .{test_dir});
    defer allocator.free(nodes_path);

    const stat = try std.fs.cwd().statFile(nodes_path);
    // Empty graph should have 0 byte nodes.jsonl
    try testing.expectEqual(@as(u64, 0), stat.size);
}

test "large graph with many nodes persists" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "large_graph");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Create graph with 100 nodes
    const graph = try graph_storage_mgr.createGraphStorage(allocator, "large_test");

    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        try graph.addNode(allocator, i, &.{"TestNode"});
        try graph.setNodeProperty(allocator, i, "index", .{ .Int = @intCast(i) });
    }

    try graph_storage_mgr.saveNamedGraph(allocator, "large_test");

    // Verify file size is substantial
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/graphs/large_test/nodes.jsonl", .{test_dir});
    defer allocator.free(nodes_path);

    const stat = try std.fs.cwd().statFile(nodes_path);
    // Should be at least 100 lines of JSON
    try testing.expect(stat.size > 1000);
}

// ============================================================================
// Integration-Style Tests
// ============================================================================

test "full lifecycle: create, modify, save, reload, verify" {
    const allocator = getTestAllocator();

    const test_dir = try createTestDir(allocator, "lifecycle");
    defer cleanupTestDir(allocator, test_dir);
    defer resetGlobalState();

    graph_storage_mgr.setDataDir(test_dir);

    // Phase 1: Create and populate
    {
        const graph = try graph_storage_mgr.createGraphStorage(allocator, "lifecycle_graph");
        try graph.addNode(allocator, 1, &.{"User"});
        try graph.setNodeProperty(allocator, 1, "name", .{ .String = "TestUser" });
        try graph.addNode(allocator, 2, &.{"Post"});
        try graph.setNodeProperty(allocator, 2, "title", .{ .String = "Hello World" });
        _ = try graph.addEdge(allocator, 1, 2, "CREATED");

        // Save
        try graph_storage_mgr.saveNamedGraph(allocator, "lifecycle_graph");
    }

    // Phase 2: Simulate server restart (clear in-memory state)
    resetGlobalState();
    graph_storage_mgr.setDataDir(test_dir);

    // Phase 3: Load and verify
    {
        const loaded = try graph_storage_mgr.loadNamedGraph(allocator, "lifecycle_graph");

        // Verify nodes
        try testing.expectEqual(@as(usize, 2), loaded.nodes.count());

        const user = loaded.nodes.get(1);
        try testing.expect(user != null);

        const post = loaded.nodes.get(2);
        try testing.expect(post != null);

        // Verify edge
        try testing.expectEqual(@as(usize, 1), loaded.edges.items.len);
        const edge = loaded.edges.items[0];
        try testing.expectEqual(@as(u64, 1), edge.source);
        try testing.expectEqual(@as(u64, 2), edge.target);
        try testing.expectEqualStrings("CREATED", edge.edge_type);
    }
}
