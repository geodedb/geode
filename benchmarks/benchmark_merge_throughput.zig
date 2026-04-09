const std = @import("std");
const graph_store = @import("graph_store");

// CANARY: REQ=REQ-PERF-MERGE-001; FEATURE="MergeThroughput"; ASPECT=BulkInsert; STATUS=BENCHED; BENCH=benchmark_merge_throughput; OWNER=perf; UPDATED=2026-04-09

/// Benchmark configuration
const BenchmarkConfig = struct {
    /// Number of nodes to MERGE (insert via index lookup + create)
    node_count: usize = 2000,
    /// Size of each measurement window
    window_size: usize = 200,
    /// Maximum acceptable ratio between the last and first window times.
    /// A ratio > this indicates O(n) degradation instead of O(1).
    max_degradation_ratio: f64 = 3.0,
};

const BenchmarkResult = struct {
    name: []const u8,
    total_ops: u64,
    total_time_ns: u64,
    window_times_ns: []const u64,
    degradation_ratio: f64,

    fn avgNsPerOp(self: BenchmarkResult) u64 {
        return if (self.total_ops == 0) 0 else self.total_time_ns / self.total_ops;
    }
};

/// Simulates the MERGE hot path: index lookup → create if not found → set properties → index update.
/// This mirrors what executeMerge does for `MERGE (n:Label {id: "..."}) SET n.prop = "..."`.
fn runBulkMergeBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    // Reset global store to get a clean graph
    graph_store.deinitGlobalStore();
    const store = graph_store.getWritableGlobalStore(allocator);

    const graph_name = "bench";
    const label = "User";
    const labels: []const []const u8 = &.{label};
    const prop_key = "id";

    const num_windows = config.node_count / config.window_size;
    var window_times = try allocator.alloc(u64, num_windows);

    var timer = try std.time.Timer.start();
    const total_start = timer.read();

    var window: usize = 0;
    while (window < num_windows) : (window += 1) {
        const window_start = timer.read();

        var i: usize = 0;
        while (i < config.window_size) : (i += 1) {
            const node_num = window * config.window_size + i;

            // Build a unique string ID for this node
            var id_buf: [32]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "user-{d:0>8}", .{node_num}) catch unreachable;
            const prop_value = graph_store.PropertyValue{ .String = id_str };

            // Step 1: Lookup via merge property index (mirrors findFirstMatchingNodeId fast path)
            var out_id: u64 = undefined;
            const lookup = store.lookupMergeCandidate(graph_name, label, prop_key, prop_value, &out_id);

            switch (lookup) {
                .found => {
                    // Node already exists — this shouldn't happen during initial insert
                    // but we handle it for correctness (ON MATCH path)
                },
                .not_found => {
                    // Index is authoritative — no fallback scan needed.
                    // Create the node and set properties.
                    const node_id = store.createNodeWithGraph(labels, graph_name) catch |err| {
                        std.debug.print("createNodeWithGraph failed: {s}\n", .{@errorName(err)});
                        return err;
                    };

                    // Set the MERGE pattern property (this adds to merge_prop_index)
                    const id_copy = try allocator.dupe(u8, id_str);
                    store.setNodeProperty(node_id, prop_key, graph_store.PropertyValue{ .String = id_copy }) catch |err| {
                        std.debug.print("setNodeProperty failed: {s}\n", .{@errorName(err)});
                        return err;
                    };
                },
                .not_indexable => {
                    // Would need fallback scan — shouldn't happen with string IDs
                    std.debug.print("unexpected not_indexable for string ID\n", .{});
                    return error.UnexpectedNotIndexable;
                },
            }
        }

        const window_end = timer.read();
        window_times[window] = window_end - window_start;
    }

    const total_end = timer.read();

    // Calculate degradation ratio: last window time / first window time
    const first_window = @as(f64, @floatFromInt(window_times[0]));
    const last_window = @as(f64, @floatFromInt(window_times[num_windows - 1]));
    const degradation = if (first_window > 0) last_window / first_window else 0.0;

    return .{
        .name = "bulk_merge_insert",
        .total_ops = config.node_count,
        .total_time_ns = total_end - total_start,
        .window_times_ns = window_times,
        .degradation_ratio = degradation,
    };
}

/// Benchmark: re-MERGE existing nodes (ON MATCH path) — should be O(1) per op.
fn runBulkMergeUpdateBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    // First, populate the graph
    graph_store.deinitGlobalStore();
    const store = graph_store.getWritableGlobalStore(allocator);

    const graph_name = "bench";
    const label = "User";
    const labels: []const []const u8 = &.{label};
    const prop_key = "id";

    // Insert all nodes first
    for (0..config.node_count) |n| {
        var id_buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "user-{d:0>8}", .{n}) catch unreachable;

        const node_id = try store.createNodeWithGraph(labels, graph_name);
        const id_copy = try allocator.dupe(u8, id_str);
        try store.setNodeProperty(node_id, prop_key, graph_store.PropertyValue{ .String = id_copy });
    }

    // Now benchmark re-MERGE (lookup existing nodes)
    const num_windows = config.node_count / config.window_size;
    var window_times = try allocator.alloc(u64, num_windows);

    var timer = try std.time.Timer.start();
    const total_start = timer.read();

    var window: usize = 0;
    while (window < num_windows) : (window += 1) {
        const window_start = timer.read();

        var i: usize = 0;
        while (i < config.window_size) : (i += 1) {
            const node_num = window * config.window_size + i;
            var id_buf: [32]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "user-{d:0>8}", .{node_num}) catch unreachable;
            const prop_value = graph_store.PropertyValue{ .String = id_str };

            var out_id: u64 = undefined;
            const lookup = store.lookupMergeCandidate(graph_name, label, prop_key, prop_value, &out_id);

            switch (lookup) {
                .found => {
                    // Expected: node exists, ON MATCH path
                },
                .not_found => {
                    // Unexpected during update benchmark
                    return error.ExpectedNodeNotFound;
                },
                .not_indexable => {
                    return error.UnexpectedNotIndexable;
                },
            }
        }

        const window_end = timer.read();
        window_times[window] = window_end - window_start;
    }

    const total_end = timer.read();

    const first_window = @as(f64, @floatFromInt(window_times[0]));
    const last_window = @as(f64, @floatFromInt(window_times[num_windows - 1]));
    const degradation = if (first_window > 0) last_window / first_window else 0.0;

    return .{
        .name = "bulk_merge_update",
        .total_ops = config.node_count,
        .total_time_ns = total_end - total_start,
        .window_times_ns = window_times,
        .degradation_ratio = degradation,
    };
}

fn printResult(result: BenchmarkResult) void {
    std.debug.print("\n=== Benchmark: {s} ===\n", .{result.name});
    std.debug.print("  Total ops:       {d}\n", .{result.total_ops});
    std.debug.print("  Total time:      {d}ms\n", .{result.total_time_ns / std.time.ns_per_ms});
    std.debug.print("  Avg per op:      {d}ns\n", .{result.avgNsPerOp()});
    std.debug.print("  Degradation:     {d:.2}x (last window / first window)\n", .{result.degradation_ratio});
    std.debug.print("  Window times:\n", .{});
    for (result.window_times_ns, 0..) |t, i| {
        std.debug.print("    [{d:>3}] {d}us\n", .{ i, t / std.time.ns_per_us });
    }
}

test "Benchmark: Bulk MERGE insert throughput (O(1) per op)" {
    const allocator = std.testing.allocator;
    const config = BenchmarkConfig{};

    const result = try runBulkMergeBenchmark(allocator, config);
    defer allocator.free(result.window_times_ns);
    printResult(result);

    // Assert no significant degradation: last window should not be more than
    // 3x slower than the first window. With the O(n) fallback scan bug, this
    // ratio would be 10x+ for 2000 nodes.
    try std.testing.expect(result.degradation_ratio < config.max_degradation_ratio);
}

test "Benchmark: Bulk MERGE update throughput (ON MATCH path)" {
    const allocator = std.testing.allocator;
    const config = BenchmarkConfig{};

    const result = try runBulkMergeUpdateBenchmark(allocator, config);
    defer allocator.free(result.window_times_ns);
    printResult(result);

    // Update path should be even more stable since all lookups are O(1) hits
    try std.testing.expect(result.degradation_ratio < config.max_degradation_ratio);
}
