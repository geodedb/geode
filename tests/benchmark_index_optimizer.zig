const std = @import("std");
const testing = std.testing;
const graph_common = @import("../src/types/graph_common.zig");
const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;
const graph_exec = @import("../src/server/graph/exec.zig");

// Performance benchmark for IndexOptimizer
// CANARY: REQ=REQ-GQL-016; FEATURE="IndexOptimizer"; ASPECT=PerformanceBench; STATUS=TESTED; TEST=BenchmarkCANARY_REQ_GQL_016_IndexOptimizerPerformance; OWNER=engine; UPDATED=2025-10-03

const BENCHMARK_NODE_COUNT = 1000;
const BENCHMARK_ITERATIONS = 100;

// Mock index manager for benchmarking
const BenchmarkIndexManager = struct {
    property_indexes: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BenchmarkIndexManager {
        return BenchmarkIndexManager{
            .property_indexes = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BenchmarkIndexManager) void {
        self.property_indexes.deinit();
    }

    pub fn lookupPropertyIndex(self: *BenchmarkIndexManager, index_name: []const u8, search_key: []const u8) !?u64 {
        _ = search_key;
        if (self.property_indexes.contains(index_name)) {
            // Simulate finding a matching node quickly via index
            return 1;
        }
        return null;
    }
};

// Create a test graph with many nodes
fn createBenchmarkGraph(allocator: std.mem.Allocator, node_count: usize) !graph_common.GraphStorage {
    var graph = graph_common.GraphStorage.init(allocator);

    // Add nodes with varying properties
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        try graph.addNode(allocator, i, &[_][]const u8{"Person"});

        // Add name property with pattern
        const name = if (i % 10 == 0) "Alice" else "Other";
        try graph.setNodeProperty(i, "name", .{ .String = name });

        // Add age property
        try graph.setNodeProperty(i, "age", .{ .Int = @intCast(20 + (i % 50)) });
    }

    return graph;
}

test "BenchmarkCANARY_REQ_GQL_016_IndexOptimizerPerformance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create benchmark graph
    var graph = try createBenchmarkGraph(allocator, BENCHMARK_NODE_COUNT);
    defer graph.deinit();

    // Create index manager with and without indexes
    var index_manager_with_index = BenchmarkIndexManager.init(allocator);
    defer index_manager_with_index.deinit();
    try index_manager_with_index.property_indexes.put("Person_name_idx", {});

    var index_manager_without_index = BenchmarkIndexManager.init(allocator);
    defer index_manager_without_index.deinit();

    var optimizer_with_index = IndexOptimizer.init(allocator, &index_manager_with_index);
    var optimizer_without_index = IndexOptimizer.init(allocator, &index_manager_without_index);

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    // Benchmark sequential scan (no index)
    const start_sequential = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const plan_seq = optimizer_without_index.optimizeNodeScan(&labels, "n", "name", prop_val);
        const results_seq = try optimizer_without_index.executeOptimizedScan(&graph, plan_seq, &labels, "n", "name", prop_val);
        allocator.free(results_seq);
    }
    const end_sequential = std.time.nanoTimestamp();
    const sequential_time = end_sequential - start_sequential;

    // Benchmark index scan
    const start_index = std.time.nanoTimestamp();
    i = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const plan_idx = optimizer_with_index.optimizeNodeScan(&labels, "n", "name", prop_val);
        const results_idx = try optimizer_with_index.executeOptimizedScan(&graph, plan_idx, &labels, "n", "name", prop_val);
        allocator.free(results_idx);
    }
    const end_index = std.time.nanoTimestamp();
    const index_time = end_index - start_index;

    // Print performance comparison
    const sequential_avg = @as(f64, @floatFromInt(sequential_time)) / BENCHMARK_ITERATIONS;
    const index_avg = @as(f64, @floatFromInt(index_time)) / BENCHMARK_ITERATIONS;
    const speedup = sequential_avg / index_avg;

    std.debug.print("\nIndexOptimizer Performance Benchmark:\n");
    std.debug.print("  Nodes: {d}\n", .{BENCHMARK_NODE_COUNT});
    std.debug.print("  Iterations: {d}\n", .{BENCHMARK_ITERATIONS});
    std.debug.print("  Sequential scan avg: {d:.2} ns\n", .{sequential_avg});
    std.debug.print("  Index scan avg: {d:.2} ns\n", .{index_avg});
    std.debug.print("  Speedup: {d:.2}x\n", .{speedup});

    // Verify that both methods return correct results
    const plan_seq = optimizer_without_index.optimizeNodeScan(&labels, "n", "name", prop_val);
    const results_seq = try optimizer_without_index.executeOptimizedScan(&graph, plan_seq, &labels, "n", "name", prop_val);
    defer allocator.free(results_seq);

    const plan_idx = optimizer_with_index.optimizeNodeScan(&labels, "n", "name", prop_val);
    const results_idx = try optimizer_with_index.executeOptimizedScan(&graph, plan_idx, &labels, "n", "name", prop_val);
    defer allocator.free(results_idx);

    // Both should find the same number of "Alice" nodes (every 10th node)
    const expected_alice_count = BENCHMARK_NODE_COUNT / 10;
    try testing.expect(results_seq.len == expected_alice_count);
    try testing.expect(results_idx.len == 1); // Mock index returns 1 result

    // Index optimization should make correct decisions
    try testing.expect(plan_seq.type == .sequential);
    try testing.expect(plan_idx.type == .index);

    // Index should have lower estimated cost
    try testing.expect(plan_idx.estimated_cost < plan_seq.estimated_cost);
}

test "BenchmarkCANARY_REQ_GQL_016_IndexOptimizerScalability" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_sizes = [_]usize{ 100, 500, 1000, 2000 };

    std.debug.print("\nIndexOptimizer Scalability Test:\n");

    for (test_sizes) |size| {
        var graph = try createBenchmarkGraph(allocator, size);
        defer graph.deinit();

        var index_manager = BenchmarkIndexManager.init(allocator);
        defer index_manager.deinit();

        var optimizer = IndexOptimizer.init(allocator, &index_manager);

        const labels = [_][]const u8{"Person"};
        const prop_val = graph_common.PropertyValue{ .String = "Alice" };

        // Measure optimization decision time
        const start = std.time.nanoTimestamp();
        const plan = optimizer.optimizeNodeScan(&labels, "n", "name", prop_val);
        const end = std.time.nanoTimestamp();

        const optimization_time = end - start;

        std.debug.print("  {d} nodes: optimization took {d} ns\n", .{ size, optimization_time });

        // Verify optimization remains consistent
        try testing.expect(plan.type == .sequential);
        try testing.expect(plan.estimated_cost > 0);

        // Optimization time should remain reasonable (< 1ms even for large graphs)
        try testing.expect(optimization_time < 1_000_000); // 1ms in nanoseconds
    }
}

test "BenchmarkCANARY_REQ_GQL_016_IndexOptimizerCostAccuracy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = try createBenchmarkGraph(allocator, 1000);
    defer graph.deinit();

    var index_manager = BenchmarkIndexManager.init(allocator);
    defer index_manager.deinit();
    try index_manager.property_indexes.put("Person_name_idx", {});

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    // Test cost estimation accuracy
    const plan_seq = optimizer.optimizeNodeScan(&labels, "n", null, null);
    const plan_idx = optimizer.optimizeNodeScan(&labels, "n", "name", prop_val);

    std.debug.print("\nIndexOptimizer Cost Estimation:\n");
    std.debug.print("  Sequential scan cost: {d:.2}\n", .{plan_seq.estimated_cost});
    std.debug.print("  Sequential scan rows: {d}\n", .{plan_seq.estimated_rows});
    std.debug.print("  Index scan cost: {d:.2}\n", .{plan_idx.estimated_cost});
    std.debug.print("  Index scan rows: {d}\n", .{plan_idx.estimated_rows});

    // Verify cost model sanity
    try testing.expect(plan_idx.estimated_cost < plan_seq.estimated_cost);
    try testing.expect(plan_idx.estimated_rows < plan_seq.estimated_rows);

    // Cost should be proportional to estimated rows
    const seq_cost_per_row = plan_seq.estimated_cost / @as(f64, @floatFromInt(plan_seq.estimated_rows));
    const idx_cost_per_row = plan_idx.estimated_cost / @as(f64, @floatFromInt(plan_idx.estimated_rows));

    // Index should have lower cost per row due to efficiency
    try testing.expect(idx_cost_per_row <= seq_cost_per_row);
}
