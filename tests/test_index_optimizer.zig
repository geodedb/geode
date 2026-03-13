const std = @import("std");
const testing = std.testing;
const graph_common = @import("../src/types/graph_common.zig");
const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;
const graph_exec = @import("../src/server/graph/exec.zig");
const ast = @import("../src/gql/ast.zig");

// Mock index manager for testing
const MockIndexManager = struct {
    property_indexes: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockIndexManager {
        return MockIndexManager{
            .property_indexes = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockIndexManager) void {
        self.property_indexes.deinit();
    }

    pub fn lookupPropertyIndex(self: *MockIndexManager, index_name: []const u8, search_key: []const u8) !?u64 {
        _ = search_key;
        if (self.property_indexes.contains(index_name)) {
            // Return a mock node ID for testing
            return 1;
        }
        return null;
    }
};

test "IndexOptimizer: sequential scan when no property filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    const labels = [_][]const u8{"Person"};
    const plan = optimizer.optimizeNodeScan(&labels, "n", null, null);

    try testing.expect(plan.type == .sequential);
    try testing.expect(plan.estimated_cost == 100.0);
    try testing.expect(plan.estimated_rows == 1000);
}

test "IndexOptimizer: index scan when suitable index exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    // Add a mock index
    try mock_index_manager.property_indexes.put("Person_name_idx", {});

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };
    const plan = optimizer.optimizeNodeScan(&labels, "n", "name", prop_val);

    try testing.expect(plan.type == .index);
    try testing.expect(plan.estimated_cost < 100.0); // Should be cheaper than sequential
}

test "IndexOptimizer: sequential scan when no suitable index exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };
    const plan = optimizer.optimizeNodeScan(&labels, "n", "name", prop_val);

    try testing.expect(plan.type == .sequential);
}

test "IndexOptimizer: executeOptimizedScan sequential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    // Create test graph storage
    var graph = try graph_common.GraphStore.init(allocator);
    defer graph.deinit();

    // Add test nodes
    var labels_arr = [_][]const u8{"Person"};
    const alice_id = try graph.createNode(&labels_arr);
    try graph.setNodeProperty(alice_id, "name", .{ .String = "Alice" });

    const bob_id = try graph.createNode(&labels_arr);
    try graph.setNodeProperty(bob_id, "name", .{ .String = "Bob" });

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    const plan = graph_common.ScanPlan{
        .type = .sequential,
        .estimated_cost = 100.0,
        .estimated_rows = 1000,
    };

    const results = try optimizer.executeOptimizedScan(&graph, plan, &labels, "n", "name", prop_val);
    defer allocator.free(results);

    try testing.expect(results.len == 1);
    try testing.expect(results[0].value == .Node);
    try testing.expect(results[0].value.Node.id == alice_id);
}

test "IndexOptimizer: executeOptimizedScan index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    // Add a mock index
    try mock_index_manager.property_indexes.put("Person_name_idx", {});

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    // Create test graph storage
    var graph = try graph_common.GraphStore.init(allocator);
    defer graph.deinit();

    // Add test nodes
    var labels_arr = [_][]const u8{"Person"};
    const alice_id = try graph.createNode(&labels_arr);
    try graph.setNodeProperty(alice_id, "name", .{ .String = "Alice" });

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    const index_info = graph_common.IndexInfo{
        .name = "Person_name_idx",
        .label = "Person",
        .property = "name",
        .index_type = .btree,
        .selectivity = 0.1,
    };

    const plan = graph_common.ScanPlan{
        .type = .{ .index = index_info },
        .estimated_cost = 1.0,
        .estimated_rows = 100,
    };

    const results = try optimizer.executeOptimizedScan(&graph, plan, &labels, "n", "name", prop_val);
    defer allocator.free(results);

    try testing.expect(results.len == 1);
    try testing.expect(results[0].value == .Node);
    try testing.expect(results[0].value.Node.id == alice_id);
}

test "IndexOptimizer: cost estimation comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    const labels = [_][]const u8{"Person"};

    // Test sequential scan cost
    const seq_cost = optimizer.estimateSequentialScanCost(&labels);
    try testing.expect(seq_cost == 100.0);

    // Test index scan cost
    const index_info = graph_common.IndexInfo{
        .name = "test_idx",
        .label = "Person",
        .property = "name",
        .index_type = .btree,
        .selectivity = 0.1,
    };
    const prop_val = graph_common.PropertyValue{ .String = "test" };
    const index_cost = optimizer.estimateIndexScanCost(index_info, prop_val);

    try testing.expect(index_cost < seq_cost); // Index should be cheaper
    try testing.expect(index_cost == 1.0); // 10.0 * 0.1 selectivity
}

test "IndexOptimizer: property value comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    // Test string comparison
    const str1 = graph_common.PropertyValue{ .String = "Alice" };
    const str2 = graph_common.PropertyValue{ .String = "Alice" };
    const str3 = graph_common.PropertyValue{ .String = "Bob" };

    try testing.expect(optimizer.propertyValuesEqual(str1, str2));
    try testing.expect(!optimizer.propertyValuesEqual(str1, str3));

    // Test int comparison
    const int1 = graph_common.PropertyValue{ .Int = 42 };
    const int2 = graph_common.PropertyValue{ .Int = 42 };
    const int3 = graph_common.PropertyValue{ .Int = 24 };

    try testing.expect(optimizer.propertyValuesEqual(int1, int2));
    try testing.expect(!optimizer.propertyValuesEqual(int1, int3));

    // Test null comparison
    const null1 = graph_common.PropertyValue.Null;
    const null2 = graph_common.PropertyValue.Null;

    try testing.expect(optimizer.propertyValuesEqual(null1, null2));
    try testing.expect(!optimizer.propertyValuesEqual(null1, str1));
}

test "IndexOptimizer: node matching criteria" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    // Create test node
    var properties = std.StringHashMap(graph_common.PropertyValue).init(allocator);
    try properties.put("name", .{ .String = "Alice" });
    try properties.put("age", .{ .Int = 30 });

    const node = graph_common.Node{
        .id = 1,
        .labels = &[_][]const u8{"Person"},
        .properties = properties,
    };

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    // Should match with correct label and property
    try testing.expect(optimizer.nodeMatchesCriteria(node, &labels, "name", prop_val));

    // Should not match with wrong property value
    const wrong_val = graph_common.PropertyValue{ .String = "Bob" };
    try testing.expect(!optimizer.nodeMatchesCriteria(node, &labels, "name", wrong_val));

    // Should not match with wrong label
    const wrong_labels = [_][]const u8{"Company"};
    try testing.expect(!optimizer.nodeMatchesCriteria(node, &wrong_labels, "name", prop_val));

    // Should match without property filter
    try testing.expect(optimizer.nodeMatchesCriteria(node, &labels, null, null));
}

test "IndexOptimizer: integration with graph execution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    // Add a mock index
    try mock_index_manager.property_indexes.put("Person_name_idx", {});

    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    // Create test graph storage
    var graph = try graph_common.GraphStore.init(allocator);
    defer graph.deinit();

    // Add test nodes
    var labels_arr = [_][]const u8{"Person"};
    const alice_id = try graph.createNode(&labels_arr);
    try graph.setNodeProperty(alice_id, "name", .{ .String = "Alice" });

    const bob_id = try graph.createNode(&labels_arr);
    try graph.setNodeProperty(bob_id, "name", .{ .String = "Bob" });

    // Create IndexOptimizer interface for graph execution
    const exec_optimizer = graph_exec.IndexOptimizer{
        .optimizeNodeScanFn = optimizeNodeScanWrapper,
        .executeOptimizedScanFn = executeOptimizedScanWrapper,
        .ctx = &optimizer,
    };

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    const results = try graph_exec.indexAwareNodeScan(allocator, &graph, @constCast(&exec_optimizer), &labels, "n", "name", prop_val);
    defer allocator.free(results);

    try testing.expect(results.len == 1);
    try testing.expect(results[0].value == .Node);
    try testing.expect(results[0].value.Node.id == alice_id);
}

// Wrapper functions to bridge the IndexOptimizer interface
fn optimizeNodeScanWrapper(
    ctx: *anyopaque,
    labels: []const []const u8,
    var_name: ?[]const u8,
    prop_key: ?[]const u8,
    prop_val: ?graph_common.PropertyValue,
) graph_common.ScanPlan {
    const optimizer: *IndexOptimizer = @ptrCast(@alignCast(ctx));
    return optimizer.optimizeNodeScan(labels, var_name, prop_key, prop_val);
}

fn executeOptimizedScanWrapper(
    ctx: *anyopaque,
    graph: *const graph_common.GraphStore,
    plan: graph_common.ScanPlan,
    labels: []const []const u8,
    var_name: ?[]const u8,
    prop_key: ?[]const u8,
    prop_val: ?graph_common.PropertyValue,
) anyerror![]graph_common.Binding {
    const optimizer: *IndexOptimizer = @ptrCast(@alignCast(ctx));
    return optimizer.executeOptimizedScan(graph, plan, labels, var_name, prop_key, prop_val);
}
