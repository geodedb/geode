// CANARY: REQ=REQ-GRAPH-PERSIST-TEST-001; FEATURE="NamedGraphPersistence"; ASPECT=UnitTests; STATUS=TESTED; OWNER=storage; UPDATED=2026-01-30
//! Comprehensive unit tests for graph persistence functionality.
//! These tests cover the GAP-384 fix for multi-statement batch graph persistence.
//!
//! Test Coverage:
//! - Data directory management (setDataDir/getDataDir)
//! - Graph storage creation (createGraphStore)
//! - Graph persistence (saveNamedGraph)
//! - Graph loading (loadNamedGraph)
//! - Multi-graph isolation
//! - Batch creation scenarios
//! - Error handling for edge cases

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

const graph_storage_mgr = struct {
    pub const DEFAULT_GRAPH_NAME = graph_store.DEFAULT_GRAPH_NAME;

    pub fn setDataDir(dir: ?[]const u8) void {
        graph_store.setDataDirOverride(std.heap.page_allocator, dir);
    }

    pub fn getDataDir() ?[]const u8 {
        return graph_store.getDataDirOverride();
    }

    pub fn clearGraphStore() void {
        if (graph_store.getCurrentGlobalStore()) |store| {
            store.clearNodes();
            store.clearGraphRegistry();
            store.dirty = true;
        }
    }

    pub fn clearMultiGraphStore() void {
        clearGraphStore();
    }

    pub fn getOrCreateGraphStore(allocator: std.mem.Allocator) *geode.graph_common.GraphStore {
        return graph_store.getGlobalStore(allocator);
    }

    pub fn createGraphStore(allocator: std.mem.Allocator, name: []const u8) !*geode.graph_common.GraphStore {
        const store = graph_store.getGlobalStore(allocator);
        try store.createGraph(name);
        return store;
    }

    pub fn graphExists(name: []const u8) bool {
        return graph_store.getGlobalStore(std.heap.page_allocator).graphExists(name);
    }

    pub fn listGraphNames(allocator: std.mem.Allocator) ![]const []const u8 {
        const store = graph_store.getGlobalStore(allocator);
        return store.listGraphNames(allocator);
    }

    pub fn saveNamedGraph(allocator: std.mem.Allocator, graph_name: []const u8) !void {
        const store = graph_store.getGlobalStore(allocator);
        if (!store.graphExists(graph_name)) return error.GraphNotFound;
        store.saveIfDirty();
    }

    pub fn loadNamedGraph(allocator: std.mem.Allocator, graph_name: []const u8) !*geode.graph_common.GraphStore {
        const store = graph_store.getGlobalStore(allocator);
        if (!store.graphExists(graph_name)) return error.GraphNotFound;
        return store;
    }

    pub fn dropGraphStore(name: []const u8) !void {
        const store = graph_store.getGlobalStore(std.heap.page_allocator);
        try store.dropGraph(name);
    }

    pub fn getGraphDataDir(allocator: std.mem.Allocator, graph_name: []const u8) ![]const u8 {
        _ = graph_name;
        return graph_store.getPersistenceFilePath(allocator);
    }
};

// ============================================================================
// Test Utilities
// ============================================================================

/// Get test allocator - use page_allocator to avoid false positives from GraphStore
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
    // Clear graph storage first (while store still exists)
    graph_storage_mgr.clearGraphStore();
    graph_storage_mgr.clearMultiGraphStore();
    // Deinit the global store
    graph_store.deinitGlobalStore();
    // Clear data dir (this also clears the override in graph_store)
    graph_storage_mgr.setDataDir(null);
    // Clean up default persistence file to avoid test pollution
    std.fs.cwd().deleteFile("/tmp/geode_graph_store.dat") catch {};
}

/// Force a fresh GraphStore instance loaded from disk for the given data dir
fn reloadStore(allocator: std.mem.Allocator, data_dir: []const u8) *geode.graph_common.GraphStore {
    graph_store.deinitGlobalStore();
    graph_storage_mgr.setDataDir(data_dir);
    return graph_storage_mgr.getOrCreateGraphStore(allocator);
}

// ============================================================================
// Data Directory Management Tests
// ============================================================================

test "setDataDir and getDataDir work correctly" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "setDataDir_test");
    defer cleanupTestDir(allocator, test_dir);

    // Initially null
    try testing.expectEqual(@as(?[]const u8, null), graph_storage_mgr.getDataDir());

    // Set data directory
    graph_storage_mgr.setDataDir(test_dir);

    // Verify it was set
    const retrieved = graph_storage_mgr.getDataDir();
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(test_dir, retrieved.?);
}

test "setDataDir can be set to null" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "setDataDir_null_test");
    defer cleanupTestDir(allocator, test_dir);

    // Set and then clear
    graph_storage_mgr.setDataDir(test_dir);
    try testing.expect(graph_storage_mgr.getDataDir() != null);

    graph_storage_mgr.setDataDir(null);
    try testing.expectEqual(@as(?[]const u8, null), graph_storage_mgr.getDataDir());
}

// ============================================================================
// Graph Storage Creation Tests
// ============================================================================

test "createGraphStore creates new empty graph" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "create_graph_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    const graph = try graph_storage_mgr.createGraphStore(allocator, "test_graph_create");

    // Verify graph is empty
    try testing.expectEqual(@as(usize, 0), graph.nodes.count());
    try testing.expectEqual(@as(usize, 0), graph.edges.count());

    // Verify it exists in storage
    try testing.expect(graph_storage_mgr.graphExists("test_graph_create"));
}

test "createGraphStore fails for duplicate graph name" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "duplicate_graph_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    // Create first graph
    _ = try graph_storage_mgr.createGraphStore(allocator, "duplicate_test");

    // Try to create another with same name - should fail
    const result = graph_storage_mgr.createGraphStore(allocator, "duplicate_test");
    try testing.expectError(error.GraphAlreadyExists, result);
}

test "createGraphStore allows multiple unique graphs" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "multiple_graphs_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    // Create multiple graphs with unique names
    _ = try graph_storage_mgr.createGraphStore(allocator, "graph_alpha");
    _ = try graph_storage_mgr.createGraphStore(allocator, "graph_beta");
    _ = try graph_storage_mgr.createGraphStore(allocator, "graph_gamma");

    // All should exist
    try testing.expect(graph_storage_mgr.graphExists("graph_alpha"));
    try testing.expect(graph_storage_mgr.graphExists("graph_beta"));
    try testing.expect(graph_storage_mgr.graphExists("graph_gamma"));

    // Verify list contains at least our 3 graphs
    const names = try graph_storage_mgr.listGraphNames(allocator);
    defer allocator.free(names);
    // We created 3 graphs, so count should be at least 3
    try testing.expect(names.len >= 3);

    // Verify our specific graphs are in the list
    var found_alpha = false;
    var found_beta = false;
    var found_gamma = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "graph_alpha")) found_alpha = true;
        if (std.mem.eql(u8, name, "graph_beta")) found_beta = true;
        if (std.mem.eql(u8, name, "graph_gamma")) found_gamma = true;
    }
    try testing.expect(found_alpha);
    try testing.expect(found_beta);
    try testing.expect(found_gamma);
}

// ============================================================================
// Graph Persistence Tests
// ============================================================================

test "saveNamedGraph creates directory and files" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "save_graph");
    defer cleanupTestDir(allocator, test_dir);

    // Set data directory
    graph_storage_mgr.setDataDir(test_dir);

    // Create and populate a graph
    const graph = try graph_storage_mgr.createGraphStore(allocator, "persist_test");
    var labels = [_][]const u8{"Person"};
    const node_id = try graph.createNodeWithGraph(&labels, "persist_test");
    try graph.setNodeProperty(node_id, "name", .{ .String = "Alice" });

    // Save the graph
    try graph_storage_mgr.saveNamedGraph(allocator, "persist_test");

    // Verify unified store file was created
    const store_path = try graph_storage_mgr.getGraphDataDir(allocator, "persist_test");
    defer allocator.free(store_path);
    const store_stat = try std.fs.cwd().statFile(store_path);
    try testing.expect(store_stat.size > 0);
}

test "saveNamedGraph falls back to temp when no data directory" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();

    // Ensure no data directory - will fall back to temp
    graph_storage_mgr.setDataDir(null);

    // Create a graph
    _ = try graph_storage_mgr.createGraphStore(allocator, "no_dir_test");

    // Should fall back to temp path and succeed
    try graph_storage_mgr.saveNamedGraph(allocator, "no_dir_test");

    const store_path = try graph_storage_mgr.getGraphDataDir(allocator, "no_dir_test");
    defer allocator.free(store_path);
    defer std.fs.cwd().deleteFile(store_path) catch {};
    const store_stat = try std.fs.cwd().statFile(store_path);
    try testing.expect(store_stat.size > 0);
}

test "saveNamedGraph fails for non-existent graph" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "save_nonexistent");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Try to save a graph that doesn't exist
    const result = graph_storage_mgr.saveNamedGraph(allocator, "nonexistent_graph");
    try testing.expectError(error.GraphNotFound, result);
}

test "saveNamedGraph preserves node data correctly" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "preserve_nodes");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Create graph with multiple nodes and properties
    const graph = try graph_storage_mgr.createGraphStore(allocator, "node_data_test");
    var alice_labels = [_][]const u8{"Person"};
    const alice_id = try graph.createNodeWithGraph(&alice_labels, "node_data_test");
    try graph.setNodeProperty(alice_id, "name", .{ .String = "Alice" });
    try graph.setNodeProperty(alice_id, "age", .{ .Int = 30 });

    var bob_labels = [_][]const u8{ "Person", "Employee" };
    const bob_id = try graph.createNodeWithGraph(&bob_labels, "node_data_test");
    try graph.setNodeProperty(bob_id, "name", .{ .String = "Bob" });
    try graph.setNodeProperty(bob_id, "active", .{ .Bool = true });

    // Save the graph
    try graph_storage_mgr.saveNamedGraph(allocator, "node_data_test");

    // Reload from disk and verify data
    const loaded = reloadStore(allocator, test_dir);
    try testing.expectEqual(@as(usize, 2), loaded.getNodeCount());

    const alice_name = loaded.getNodeProperty(alice_id, "name");
    try testing.expect(alice_name != null);
    try testing.expectEqualStrings("Alice", alice_name.?.String);

    const bob_active = loaded.getNodeProperty(bob_id, "active");
    try testing.expect(bob_active != null);
    try testing.expect(bob_active.?.Bool);
}

test "saveNamedGraph preserves edge data correctly" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "preserve_edges");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Create graph with edges
    const graph = try graph_storage_mgr.createGraphStore(allocator, "edge_data_test");
    var labels = [_][]const u8{"Person"};
    const from_id = try graph.createNodeWithGraph(&labels, "edge_data_test");
    const to_id = try graph.createNodeWithGraph(&labels, "edge_data_test");
    const edge_id = try graph.createEdgeWithGraph(from_id, to_id, "KNOWS", "edge_data_test");

    // Save the graph
    try graph_storage_mgr.saveNamedGraph(allocator, "edge_data_test");

    // Reload and verify edge data
    const loaded = reloadStore(allocator, test_dir);
    const edge = loaded.getEdgePtr(edge_id);
    try testing.expect(edge != null);
    try testing.expectEqual(from_id, edge.?.from_id);
    try testing.expectEqual(to_id, edge.?.to_id);
    try testing.expectEqualStrings("KNOWS", edge.?.label);
}

// ============================================================================
// Graph Loading Tests
// ============================================================================

test "loadNamedGraph loads persisted graph" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "load_graph");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Create, populate, and save a graph
    const original = try graph_storage_mgr.createGraphStore(allocator, "load_test");
    var labels = [_][]const u8{"TestLabel"};
    const node_id = try original.createNodeWithGraph(&labels, "load_test");
    try original.setNodeProperty(node_id, "value", .{ .Int = 12345 });
    try graph_storage_mgr.saveNamedGraph(allocator, "load_test");

    // Reload the store from disk
    const loaded = reloadStore(allocator, test_dir);
    _ = try graph_storage_mgr.loadNamedGraph(allocator, "load_test");

    // Verify loaded data
    try testing.expectEqual(@as(usize, 1), loaded.getNodeCount());
    const node = loaded.getNodePtr(node_id);
    try testing.expect(node != null);
    try testing.expectEqual(node_id, node.?.id);
}

test "loadNamedGraph fails for non-existent graph directory" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "load_missing");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Try to load a graph that was never saved
    const result = graph_storage_mgr.loadNamedGraph(allocator, "never_existed");
    try testing.expectError(error.GraphNotFound, result);
}

// ============================================================================
// Multi-Statement Batch Tests (GAP-384 Core Fix Validation)
// ============================================================================

test "multiple graphs can be created and persisted in sequence" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "batch_create");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Simulate batch: CREATE GRAPH g1; CREATE GRAPH g2; CREATE GRAPH g3;
    const graph_names = [_][]const u8{ "batch_g1", "batch_g2", "batch_g3" };

    for (graph_names) |name| {
        _ = try graph_storage_mgr.createGraphStore(allocator, name);
        try graph_storage_mgr.saveNamedGraph(allocator, name);
    }

    // Verify unified store file exists
    const store_path = try graph_storage_mgr.getGraphDataDir(allocator, graph_names[0]);
    defer allocator.free(store_path);
    const store_stat = try std.fs.cwd().statFile(store_path);
    try testing.expect(store_stat.size > 0);

    // Reload and verify graph registry contains all created graphs
    _ = reloadStore(allocator, test_dir);
    for (graph_names) |name| {
        try testing.expect(graph_storage_mgr.graphExists(name));
    }
}

test "graphs persist independently in batch operations" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "batch_independent");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Create graphs with different data
    const g1 = try graph_storage_mgr.createGraphStore(allocator, "independent_g1");
    var g1_labels = [_][]const u8{"TypeA"};
    _ = try g1.createNodeWithGraph(&g1_labels, "independent_g1");
    try graph_storage_mgr.saveNamedGraph(allocator, "independent_g1");

    const g2 = try graph_storage_mgr.createGraphStore(allocator, "independent_g2");
    var g2_labels = [_][]const u8{"TypeB"};
    _ = try g2.createNodeWithGraph(&g2_labels, "independent_g2");
    _ = try g2.createNodeWithGraph(&g2_labels, "independent_g2");
    try graph_storage_mgr.saveNamedGraph(allocator, "independent_g2");

    // Reload and verify each has its own data
    const loaded = reloadStore(allocator, test_dir);
    const g1_nodes = loaded.getNodesByLabel("independent_g1", "TypeA");
    try testing.expect(g1_nodes != null);
    try testing.expectEqual(@as(usize, 1), g1_nodes.?.len);

    const g2_nodes = loaded.getNodesByLabel("independent_g2", "TypeB");
    try testing.expect(g2_nodes != null);
    try testing.expectEqual(@as(usize, 2), g2_nodes.?.len);

    try testing.expect(loaded.getNodesByLabel("independent_g1", "TypeB") == null);
    try testing.expect(loaded.getNodesByLabel("independent_g2", "TypeA") == null);
}

// ============================================================================
// Graph Data Directory Path Tests
// ============================================================================

test "getGraphDataDir returns correct path format" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "path_format_test");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    const path = try graph_storage_mgr.getGraphDataDir(allocator, "my_graph");
    defer allocator.free(path);

    // Verify path ends with graph_store.dat and contains our test dir
    try testing.expect(std.mem.endsWith(u8, path, "graph_store.dat"));
    try testing.expect(std.mem.containsAtLeast(u8, path, 1, "path_format_test"));
}

test "getGraphDataDir falls back to temp directory when unset" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();

    graph_storage_mgr.setDataDir(null);

    // When no data directory is set, it falls back to temp directory
    const path = try graph_storage_mgr.getGraphDataDir(allocator, "test");
    defer allocator.free(path);

    // Should fall back to temp path ending in geode_graph_store.dat
    try testing.expect(std.mem.endsWith(u8, path, "geode_graph_store.dat"));
}

// ============================================================================
// Graph Existence Tests
// ============================================================================

test "graphExists returns false for non-existent graph" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "graph_exists_false_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    try testing.expect(!graph_storage_mgr.graphExists("completely_fake_graph"));
}

test "graphExists returns true after graph creation" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "graph_exists_true_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    // Before creation
    try testing.expect(!graph_storage_mgr.graphExists("existence_test"));

    // Create
    _ = try graph_storage_mgr.createGraphStore(allocator, "existence_test");

    // After creation
    try testing.expect(graph_storage_mgr.graphExists("existence_test"));
}

// ============================================================================
// Drop Graph Tests
// ============================================================================

test "dropGraphStore removes graph" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "drop_graph_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    // Create and verify
    _ = try graph_storage_mgr.createGraphStore(allocator, "drop_test");
    try testing.expect(graph_storage_mgr.graphExists("drop_test"));

    // Drop
    try graph_storage_mgr.dropGraphStore("drop_test");

    // Verify removed
    try testing.expect(!graph_storage_mgr.graphExists("drop_test"));
}

test "dropGraphStore fails for non-existent graph" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "drop_nonexistent_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    const result = graph_storage_mgr.dropGraphStore("never_existed_drop");
    try testing.expectError(error.GraphNotFound, result);
}

test "dropGraphStore fails for default graph" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "drop_default_test");
    defer cleanupTestDir(allocator, test_dir);
    graph_storage_mgr.setDataDir(test_dir);

    const result = graph_storage_mgr.dropGraphStore(graph_storage_mgr.DEFAULT_GRAPH_NAME);
    try testing.expectError(error.CannotDropDefaultGraph, result);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "graph names with special characters" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "special_chars");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Test with underscores and numbers (valid identifiers)
    _ = try graph_storage_mgr.createGraphStore(allocator, "graph_with_underscores_123");
    try graph_storage_mgr.saveNamedGraph(allocator, "graph_with_underscores_123");

    try testing.expect(graph_storage_mgr.graphExists("graph_with_underscores_123"));
}

test "empty graph persists correctly" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "empty_graph");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Create empty graph
    _ = try graph_storage_mgr.createGraphStore(allocator, "empty_test");
    try graph_storage_mgr.saveNamedGraph(allocator, "empty_test");

    // Verify unified store file exists (header-only data for empty graph)
    const store_path = try graph_storage_mgr.getGraphDataDir(allocator, "empty_test");
    defer allocator.free(store_path);
    const stat = try std.fs.cwd().statFile(store_path);
    try testing.expect(stat.size > 0);
}

test "large graph with many nodes persists" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "large_graph");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Create graph with 100 nodes
    const graph = try graph_storage_mgr.createGraphStore(allocator, "large_test");

    var labels = [_][]const u8{"TestNode"};
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        const node_id = try graph.createNodeWithGraph(&labels, "large_test");
        try graph.setNodeProperty(node_id, "index", .{ .Int = @intCast(i) });
    }

    try graph_storage_mgr.saveNamedGraph(allocator, "large_test");

    // Verify file size is substantial
    const store_path = try graph_storage_mgr.getGraphDataDir(allocator, "large_test");
    defer allocator.free(store_path);

    const stat = try std.fs.cwd().statFile(store_path);
    try testing.expect(stat.size > 1000);

    // Reload and verify node count is at least 100 (we created 100 nodes)
    const loaded = reloadStore(allocator, test_dir);
    try testing.expect(loaded.getNodeCount() >= 100);
}

// ============================================================================
// Integration-Style Tests
// ============================================================================

test "full lifecycle: create, modify, save, reload, verify" {
    resetGlobalState();
    defer resetGlobalState();

    const allocator = getTestAllocator();
    const test_dir = try createTestDir(allocator, "lifecycle");
    defer cleanupTestDir(allocator, test_dir);

    graph_storage_mgr.setDataDir(test_dir);

    // Phase 1: Create and populate
    var user_id: u64 = 0;
    var post_id: u64 = 0;
    var edge_id: u64 = 0;
    {
        const graph = try graph_storage_mgr.createGraphStore(allocator, "lifecycle_graph");
        var user_labels = [_][]const u8{"User"};
        user_id = try graph.createNodeWithGraph(&user_labels, "lifecycle_graph");
        try graph.setNodeProperty(user_id, "name", .{ .String = "TestUser" });

        var post_labels = [_][]const u8{"Post"};
        post_id = try graph.createNodeWithGraph(&post_labels, "lifecycle_graph");
        try graph.setNodeProperty(post_id, "title", .{ .String = "Hello World" });

        edge_id = try graph.createEdgeWithGraph(user_id, post_id, "CREATED", "lifecycle_graph");

        // Save
        try graph_storage_mgr.saveNamedGraph(allocator, "lifecycle_graph");
    }

    // Phase 2: Simulate server restart (clear in-memory state)
    resetGlobalState();
    graph_storage_mgr.setDataDir(test_dir);

    // Phase 3: Load and verify
    {
        const loaded = reloadStore(allocator, test_dir);
        _ = try graph_storage_mgr.loadNamedGraph(allocator, "lifecycle_graph");

        // Verify nodes
        try testing.expectEqual(@as(usize, 2), loaded.nodes.count());
        try testing.expect(loaded.getNodePtr(user_id) != null);
        try testing.expect(loaded.getNodePtr(post_id) != null);

        // Verify edge count and labels
        try testing.expectEqual(@as(usize, 1), loaded.edges.count());
        const edge = loaded.getEdgePtr(edge_id);
        try testing.expect(edge != null);
        try testing.expectEqualStrings("CREATED", edge.?.label);
    }
}
