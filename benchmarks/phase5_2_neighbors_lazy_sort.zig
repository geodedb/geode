// Phase 5.1.2 Performance Optimization Benchmarks
// Validates the lazy sorting optimization in InMemory.neighbors()

const std = @import("std");
const testing = std.testing;

// CANARY: BENCHMARK_PHASE5_2 - Performance validation for Phase 5.1.2 optimization
// CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE="GraphOptimization"; ASPECT=TESTING; STATUS=IMPL; OWNER=performance; UPDATED=2025-11-16

// =============================================================================
// Test Structures - Simplified InMemory-like graph for benchmarking
// =============================================================================

/// Baseline implementation: sorts on every call (O(n²) for repeated queries)
const GraphBaseline = struct {
    allocator: std.mem.Allocator,
    adj: std.AutoHashMap(u64, std.ArrayList(u64)),

    pub fn init(allocator: std.mem.Allocator) GraphBaseline {
        return .{
            .allocator = allocator,
            .adj = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *GraphBaseline) void {
        var it = self.adj.valueIterator();
        while (it.next()) |lst| lst.*.deinit(self.allocator);
        self.adj.deinit();
    }

    pub fn addEdge(self: *GraphBaseline, src: u64, dst: u64) !void {
        var gop = try self.adj.getOrPut(src);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable;
        }
        try gop.value_ptr.append(self.allocator, dst);
    }

    pub fn neighbors(self: *GraphBaseline, src: u64) []const u64 {
        if (self.adj.get(src)) |lst| {
            var slice = lst.items;
            // BASELINE: Sort on EVERY call (inefficient)
            std.mem.sort(u64, slice, {}, std.sort.asc(u64));

            // Deduplicate
            var w: usize = 0;
            var i: usize = 0;
            while (i < slice.len) : (i += 1) {
                if (w == 0 or slice[i] != slice[w - 1]) {
                    slice[w] = slice[i];
                    w += 1;
                }
            }
            return slice[0..w];
        }
        return &.{};
    }
};

/// Optimized implementation: lazy sorting (Phase 5.1.2)
const GraphOptimized = struct {
    allocator: std.mem.Allocator,
    adj: std.AutoHashMap(u64, std.ArrayList(u64)),
    adj_sorted: std.AutoHashMap(u64, bool),

    pub fn init(allocator: std.mem.Allocator) GraphOptimized {
        return .{
            .allocator = allocator,
            .adj = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .adj_sorted = std.AutoHashMap(u64, bool).init(allocator),
        };
    }

    pub fn deinit(self: *GraphOptimized) void {
        var it = self.adj.valueIterator();
        while (it.next()) |lst| lst.*.deinit(self.allocator);
        self.adj.deinit();
        self.adj_sorted.deinit();
    }

    pub fn addEdge(self: *GraphOptimized, src: u64, dst: u64) !void {
        var gop = try self.adj.getOrPut(src);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable;
        }
        try gop.value_ptr.append(self.allocator, dst);
        // Mark as unsorted
        try self.adj_sorted.put(src, false);
    }

    pub fn neighbors(self: *GraphOptimized, src: u64) []const u64 {
        if (self.adj.getPtr(src)) |lst_ptr| {
            const is_sorted = self.adj_sorted.get(src) orelse false;

            if (!is_sorted) {
                // OPTIMIZED: Sort ONCE, then cache
                var slice = lst_ptr.items;
                std.mem.sort(u64, slice, {}, std.sort.asc(u64));

                // Deduplicate in-place
                var w: usize = 0;
                var i: usize = 0;
                while (i < slice.len) : (i += 1) {
                    if (w == 0 or slice[i] != slice[w - 1]) {
                        slice[w] = slice[i];
                        w += 1;
                    }
                }
                lst_ptr.items.len = w;

                // Mark as sorted
                self.adj_sorted.put(src, true) catch {};
            }

            return lst_ptr.items;
        }
        return &.{};
    }
};

// =============================================================================
// Benchmarks
// =============================================================================

/// Benchmark baseline: sorts on every call
fn benchmarkBaseline(allocator: std.mem.Allocator, edges: usize, queries: usize) !u64 {
    var graph = GraphBaseline.init(allocator);
    defer graph.deinit();

    // Add edges
    var i: usize = 0;
    while (i < edges) : (i += 1) {
        try graph.addEdge(1, i);
    }

    var timer = try std.time.Timer.start();
    const start = timer.read();

    // Query neighbors multiple times
    var q: usize = 0;
    while (q < queries) : (q += 1) {
        const neighbors = graph.neighbors(1);
        std.mem.doNotOptimizeAway(neighbors.len);
    }

    const end = timer.read();
    return end - start;
}

/// Benchmark optimized: lazy sorting
fn benchmarkOptimized(allocator: std.mem.Allocator, edges: usize, queries: usize) !u64 {
    var graph = GraphOptimized.init(allocator);
    defer graph.deinit();

    // Add edges
    var i: usize = 0;
    while (i < edges) : (i += 1) {
        try graph.addEdge(1, i);
    }

    var timer = try std.time.Timer.start();
    const start = timer.read();

    // Query neighbors multiple times
    var q: usize = 0;
    while (q < queries) : (q += 1) {
        const neighbors = graph.neighbors(1);
        std.mem.doNotOptimizeAway(neighbors.len);
    }

    const end = timer.read();
    return end - start;
}

test "Benchmark: Lazy sorting - 100 edges, 100 queries" {
    const allocator = testing.allocator;
    const edges = 100;
    const queries = 100;

    const baseline_time = try benchmarkBaseline(allocator, edges, queries);
    const optimized_time = try benchmarkOptimized(allocator, edges, queries);

    const ratio = @as(f64, @floatFromInt(baseline_time)) / @as(f64, @floatFromInt(optimized_time));

    std.debug.print("\n=== Phase 5.1.2: Lazy Sorting (100 edges, 100 queries) ===\n", .{});
    std.debug.print("Baseline (sort every time):  {} ns\n", .{baseline_time});
    std.debug.print("Optimized (lazy sort):       {} ns\n", .{optimized_time});
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.3x (30% improvement)\n", .{});

    // Verify we get at least 30% improvement
    try testing.expect(ratio >= 1.3);
}

test "Benchmark: Lazy sorting - 500 edges, 100 queries" {
    const allocator = testing.allocator;
    const edges = 500;
    const queries = 100;

    const baseline_time = try benchmarkBaseline(allocator, edges, queries);
    const optimized_time = try benchmarkOptimized(allocator, edges, queries);

    const ratio = @as(f64, @floatFromInt(baseline_time)) / @as(f64, @floatFromInt(optimized_time));

    std.debug.print("\n=== Phase 5.1.2: Lazy Sorting (500 edges, 100 queries) ===\n", .{});
    std.debug.print("Baseline (sort every time):  {} ns\n", .{baseline_time});
    std.debug.print("Optimized (lazy sort):       {} ns\n", .{optimized_time});
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.4x (40% improvement)\n", .{});

    // Verify we get at least 40% improvement
    try testing.expect(ratio >= 1.4);
}

test "Benchmark: Lazy sorting - 1000 edges, 100 queries" {
    const allocator = testing.allocator;
    const edges = 1000;
    const queries = 100;

    const baseline_time = try benchmarkBaseline(allocator, edges, queries);
    const optimized_time = try benchmarkOptimized(allocator, edges, queries);

    const ratio = @as(f64, @floatFromInt(baseline_time)) / @as(f64, @floatFromInt(optimized_time));

    std.debug.print("\n=== Phase 5.1.2: Lazy Sorting (1000 edges, 100 queries) ===\n", .{});
    std.debug.print("Baseline (sort every time):  {} ns\n", .{baseline_time});
    std.debug.print("Optimized (lazy sort):       {} ns\n", .{optimized_time});
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.5x (50% improvement)\n", .{});

    // Verify we get at least 50% improvement
    try testing.expect(ratio >= 1.5);
}

test "Correctness: lazy sorting produces correct results" {
    const allocator = testing.allocator;
    var graph = GraphOptimized.init(allocator);
    defer graph.deinit();

    // Add edges in random order with duplicates
    try graph.addEdge(1, 5);
    try graph.addEdge(1, 2);
    try graph.addEdge(1, 8);
    try graph.addEdge(1, 2); // duplicate
    try graph.addEdge(1, 3);
    try graph.addEdge(1, 5); // duplicate

    // First query: should sort and deduplicate
    const neighbors1 = graph.neighbors(1);
    try testing.expectEqual(@as(usize, 4), neighbors1.len); // 2, 3, 5, 8
    try testing.expectEqual(@as(u64, 2), neighbors1[0]);
    try testing.expectEqual(@as(u64, 3), neighbors1[1]);
    try testing.expectEqual(@as(u64, 5), neighbors1[2]);
    try testing.expectEqual(@as(u64, 8), neighbors1[3]);

    // Second query: should return cached sorted result
    const neighbors2 = graph.neighbors(1);
    try testing.expectEqual(@as(usize, 4), neighbors2.len);
    try testing.expectEqual(@as(u64, 2), neighbors2[0]);
    try testing.expectEqual(@as(u64, 3), neighbors2[1]);
    try testing.expectEqual(@as(u64, 5), neighbors2[2]);
    try testing.expectEqual(@as(u64, 8), neighbors2[3]);

    // Add more edges - should mark as unsorted
    try graph.addEdge(1, 1);
    try graph.addEdge(1, 7);

    // Third query: should re-sort
    const neighbors3 = graph.neighbors(1);
    try testing.expectEqual(@as(usize, 6), neighbors3.len); // 1, 2, 3, 5, 7, 8
    try testing.expectEqual(@as(u64, 1), neighbors3[0]);
    try testing.expectEqual(@as(u64, 2), neighbors3[1]);
    try testing.expectEqual(@as(u64, 3), neighbors3[2]);
    try testing.expectEqual(@as(u64, 5), neighbors3[3]);
    try testing.expectEqual(@as(u64, 7), neighbors3[4]);
    try testing.expectEqual(@as(u64, 8), neighbors3[5]);

    std.debug.print("\n=== Correctness Test ===\n", .{});
    std.debug.print("✅ Lazy sorting produces correct sorted, deduplicated results\n", .{});
    std.debug.print("✅ Adding edges correctly invalidates cache\n", .{});
}
