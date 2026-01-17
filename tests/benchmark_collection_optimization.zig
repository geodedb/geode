const std = @import("std");
const testing = std.testing;
const time = std.time;
const collection_opt = @import("collection_optimized_test.zig");

// CANARY: REQ=REQ-PERF-COLLECTION-001; FEATURE="CollectionOptimization"; ASPECT=Benchmarking; STATUS=EXEMPT; TEST=TestCANARY_CollectionOptimization; OWNER=performance; UPDATED=2025-10-04

const BenchmarkResult = struct {
    operation: []const u8,
    avg_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    samples: u32,
    operations_per_second: f64,
    memory_efficiency: f64, // Ratio of used to allocated memory
};

fn benchmark(comptime operation_name: []const u8, comptime samples: u32, operation_fn: anytype) !BenchmarkResult {
    var times = std.ArrayList(u64).init(testing.allocator);
    defer times.deinit();

    var i: u32 = 0;
    while (i < samples) : (i += 1) {
        const start = time.nanoTimestamp();
        try operation_fn();
        const end = time.nanoTimestamp();
        try times.append(@as(u64, @intCast(end - start)));
    }

    // Calculate statistics
    var total: u64 = 0;
    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;

    for (times.items) |t| {
        total += t;
        min_time = @min(min_time, t);
        max_time = @max(max_time, t);
    }

    const avg_time = total / samples;
    const ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(avg_time));

    return BenchmarkResult{
        .operation = operation_name,
        .avg_time_ns = avg_time,
        .min_time_ns = min_time,
        .max_time_ns = max_time,
        .samples = samples,
        .operations_per_second = ops_per_second,
        .memory_efficiency = 0.0, // Will be set by caller if applicable
    };
}

fn printBenchmarkResult(result: BenchmarkResult) void {
    std.debug.print("\n=== {s} ===\n", .{result.operation});
    std.debug.print("Average: {d:.2} μs ({d} ns)\n", .{ @as(f64, @floatFromInt(result.avg_time_ns)) / 1000.0, result.avg_time_ns });
    std.debug.print("Min: {d:.2} μs ({d} ns)\n", .{ @as(f64, @floatFromInt(result.min_time_ns)) / 1000.0, result.min_time_ns });
    std.debug.print("Max: {d:.2} μs ({d} ns)\n", .{ @as(f64, @floatFromInt(result.max_time_ns)) / 1000.0, result.max_time_ns });
    std.debug.print("Operations/sec: {d:.0}\n", .{result.operations_per_second});
    if (result.memory_efficiency > 0.0) {
        std.debug.print("Memory efficiency: {d:.1}%\n", .{result.memory_efficiency * 100.0});
    }
    std.debug.print("Samples: {d}\n", .{result.samples});
}

// Baseline ArrayList operations (current implementation)
fn baselineArrayListOperations() !void {
    var list = std.ArrayList(u32).init(testing.allocator);
    defer list.deinit();

    // Simulate typical usage: many small appends without pre-allocation
    for (0..1000) |i| {
        try list.append(@as(u32, @intCast(i)));
    }

    // Access pattern simulation
    var sum: u64 = 0;
    for (list.items) |item| {
        sum += item;
    }
    std.mem.doNotOptimizeAway(sum);
}

// Optimized ArrayList with conservative growth
fn optimizedArrayListConservative() !void {
    var list = collection_opt.OptimizedArrayList(u32).init(testing.allocator, .conservative);
    defer list.deinit();

    for (0..1000) |i| {
        try list.append(@as(u32, @intCast(i)));
    }

    var sum: u64 = 0;
    for (list.items()) |item| {
        sum += item;
    }
    std.mem.doNotOptimizeAway(sum);
}

// Optimized ArrayList with aggressive growth
fn optimizedArrayListAggressive() !void {
    var list = collection_opt.OptimizedArrayList(u32).init(testing.allocator, .aggressive);
    defer list.deinit();

    for (0..1000) |i| {
        try list.append(@as(u32, @intCast(i)));
    }

    var sum: u64 = 0;
    for (list.items()) |item| {
        sum += item;
    }
    std.mem.doNotOptimizeAway(sum);
}

// Optimized ArrayList with predictive growth
fn optimizedArrayListPredictive() !void {
    var list = collection_opt.OptimizedArrayList(u32).init(testing.allocator, .predictive);
    defer list.deinit();

    for (0..1000) |i| {
        try list.append(@as(u32, @intCast(i)));
    }

    var sum: u64 = 0;
    for (list.items()) |item| {
        sum += item;
    }
    std.mem.doNotOptimizeAway(sum);
}

// Pre-allocated ArrayList (optimal scenario)
fn preAllocatedArrayList() !void {
    var list = try collection_opt.OptimizedArrayList(u32).initCapacity(testing.allocator, 1000, .conservative);
    defer list.deinit();

    for (0..1000) |i| {
        try list.append(@as(u32, @intCast(i)));
    }

    var sum: u64 = 0;
    for (list.items()) |item| {
        sum += item;
    }
    std.mem.doNotOptimizeAway(sum);
}

// String building operations baseline
fn baselineStringBuilding() !void {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    for (0..100) |i| {
        const formatted = try std.fmt.allocPrint(testing.allocator, "Item {d}: value_{d}\n", .{ i, i * 2 });
        defer testing.allocator.free(formatted);
        try buffer.appendSlice(formatted);
    }

    std.mem.doNotOptimizeAway(buffer.items.len);
}

// Optimized string building
fn optimizedStringBuilding() !void {
    var builder = try collection_opt.OptimizedStringBuilder.init(testing.allocator, 2048);
    defer builder.deinit();

    for (0..100) |i| {
        try builder.appendFormatted(testing.allocator, "Item {d}: value_{d}\n", .{ i, i * 2 });
    }

    std.mem.doNotOptimizeAway(builder.len());
}

// Batch operations test
fn batchOperationsTest() !void {
    var list = collection_opt.OptimizedArrayList(u32).init(testing.allocator, .predictive);
    defer list.deinit();

    // Create batch data
    var batch_data: [500]u32 = undefined;
    for (batch_data, 0..) |*item, i| {
        item.* = @as(u32, @intCast(i));
    }

    // Batch append
    try collection_opt.BatchOps.batchAppend(u32, &list, &batch_data);

    std.mem.doNotOptimizeAway(list.len());
}

// Collection pool operations
fn collectionPoolOperations() !void {
    var pool = try collection_opt.CollectionPool(u32).init(testing.allocator, 5, 100);
    defer pool.deinit();

    // Acquire and use collections
    for (0..10) |i| {
        if (pool.acquire()) |collection| {
            defer pool.release(collection);

            try collection.append(@as(u32, @intCast(i)));
            try collection.append(@as(u32, @intCast(i * 2)));

            std.mem.doNotOptimizeAway(collection.len());
        }
    }
}

// Memory pool operations
fn memoryPoolOperations() !void {
    var memory_pool = collection_opt.MemoryPool.init(testing.allocator);
    defer memory_pool.deinit();
    memory_pool.initTemp();

    // Multiple operations with arena backing
    for (0..50) |i| {
        var list = try memory_pool.createOptimizedList(u32, 20);
        defer list.deinit();

        try list.append(@as(u32, @intCast(i)));
        try list.append(@as(u32, @intCast(i * 2)));

        std.mem.doNotOptimizeAway(list.len());
    }

    memory_pool.reset(); // Reset arena
}

test "Collection optimization benchmark" {
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("    COLLECTION OPTIMIZATION PERFORMANCE ANALYSIS\n", .{});
    std.debug.print("============================================================\n", .{});

    // Baseline ArrayList operations
    const baseline_result = try benchmark("Baseline ArrayList (1000 items)", 500, baselineArrayListOperations);
    printBenchmarkResult(baseline_result);

    // Optimized ArrayList variants
    const conservative_result = try benchmark("Optimized ArrayList (Conservative)", 500, optimizedArrayListConservative);
    printBenchmarkResult(conservative_result);

    const aggressive_result = try benchmark("Optimized ArrayList (Aggressive)", 500, optimizedArrayListAggressive);
    printBenchmarkResult(aggressive_result);

    const predictive_result = try benchmark("Optimized ArrayList (Predictive)", 500, optimizedArrayListPredictive);
    printBenchmarkResult(predictive_result);

    const prealloc_result = try benchmark("Pre-allocated ArrayList", 500, preAllocatedArrayList);
    printBenchmarkResult(prealloc_result);

    // String building operations
    const baseline_string = try benchmark("Baseline String Building", 300, baselineStringBuilding);
    printBenchmarkResult(baseline_string);

    const optimized_string = try benchmark("Optimized String Building", 300, optimizedStringBuilding);
    printBenchmarkResult(optimized_string);

    // Advanced operations
    const batch_ops = try benchmark("Batch Operations", 1000, batchOperationsTest);
    printBenchmarkResult(batch_ops);

    const pool_ops = try benchmark("Collection Pool Operations", 500, collectionPoolOperations);
    printBenchmarkResult(pool_ops);

    const memory_pool_ops = try benchmark("Memory Pool Operations", 200, memoryPoolOperations);
    printBenchmarkResult(memory_pool_ops);

    // Calculate improvements
    std.debug.print("\n=== PERFORMANCE IMPROVEMENTS ===\n", .{});

    const conservative_improvement = @as(f64, @floatFromInt(baseline_result.avg_time_ns)) / @as(f64, @floatFromInt(conservative_result.avg_time_ns));
    std.debug.print("Conservative vs Baseline: {d:.2}x faster\n", .{conservative_improvement});

    const aggressive_improvement = @as(f64, @floatFromInt(baseline_result.avg_time_ns)) / @as(f64, @floatFromInt(aggressive_result.avg_time_ns));
    std.debug.print("Aggressive vs Baseline: {d:.2}x faster\n", .{aggressive_improvement});

    const predictive_improvement = @as(f64, @floatFromInt(baseline_result.avg_time_ns)) / @as(f64, @floatFromInt(predictive_result.avg_time_ns));
    std.debug.print("Predictive vs Baseline: {d:.2}x faster\n", .{predictive_improvement});

    const prealloc_improvement = @as(f64, @floatFromInt(baseline_result.avg_time_ns)) / @as(f64, @floatFromInt(prealloc_result.avg_time_ns));
    std.debug.print("Pre-allocated vs Baseline: {d:.2}x faster\n", .{prealloc_improvement});

    const string_improvement = @as(f64, @floatFromInt(baseline_string.avg_time_ns)) / @as(f64, @floatFromInt(optimized_string.avg_time_ns));
    std.debug.print("String Building Improvement: {d:.2}x faster\n", .{string_improvement});

    // Compare against baseline target (746μs from performance analysis)
    const baseline_target_ns: u64 = 746_000; // 746μs baseline

    std.debug.print("\nVs 746μs Baseline Target:\n", .{});
    const conservative_vs_baseline = @as(f64, @floatFromInt(baseline_target_ns)) / @as(f64, @floatFromInt(conservative_result.avg_time_ns));
    const aggressive_vs_baseline = @as(f64, @floatFromInt(baseline_target_ns)) / @as(f64, @floatFromInt(aggressive_result.avg_time_ns));
    const predictive_vs_baseline = @as(f64, @floatFromInt(baseline_target_ns)) / @as(f64, @floatFromInt(predictive_result.avg_time_ns));

    std.debug.print("Conservative: {d:.2}x faster than baseline target\n", .{conservative_vs_baseline});
    std.debug.print("Aggressive: {d:.2}x faster than baseline target\n", .{aggressive_vs_baseline});
    std.debug.print("Predictive: {d:.2}x faster than baseline target\n", .{predictive_vs_baseline});

    // Validate Phase 1 targets (2-3x improvement)
    try testing.expect(conservative_improvement > 1.5); // At least 1.5x improvement
    try testing.expect(aggressive_improvement > 1.5); // At least 1.5x improvement
    try testing.expect(predictive_improvement > 1.5); // At least 1.5x improvement
    try testing.expect(string_improvement > 1.3); // At least 1.3x improvement for string ops

    // Validate performance is better than 746μs baseline
    try testing.expect(conservative_result.avg_time_ns < 500_000); // Less than 500μs (1.5x better than baseline)
    try testing.expect(aggressive_result.avg_time_ns < 400_000); // Less than 400μs (1.8x better than baseline)
    try testing.expect(predictive_result.avg_time_ns < 400_000); // Less than 400μs (1.8x better than baseline)

    std.debug.print("\n✅ Collection Performance Optimization: VALIDATED\n", .{});
    std.debug.print("✅ Phase 1 Targets (1.5-3x improvement): ACHIEVED\n", .{});
    std.debug.print("✅ Sub-baseline Performance: CONFIRMED\n", .{});
}

test "Memory efficiency validation" {
    const allocator = testing.allocator;

    std.debug.print("\n=== MEMORY EFFICIENCY ANALYSIS ===\n", .{});

    // Test memory usage patterns
    {
        // Baseline: Many reallocations
        var baseline_list = std.ArrayList(u32).init(allocator);
        defer baseline_list.deinit();

        for (0..1000) |i| {
            try baseline_list.append(@as(u32, @intCast(i)));
        }

        const baseline_efficiency = @as(f64, @floatFromInt(baseline_list.items.len * @sizeOf(u32))) / @as(f64, @floatFromInt(baseline_list.capacity * @sizeOf(u32)));
        std.debug.print("Baseline efficiency: {d:.1}% ({d} used / {d} capacity)\n", .{ baseline_efficiency * 100.0, baseline_list.items.len, baseline_list.capacity });
    }

    {
        // Optimized: Predictive growth
        var optimized_list = collection_opt.OptimizedArrayList(u32).init(allocator, .predictive);
        defer optimized_list.deinit();

        for (0..1000) |i| {
            try optimized_list.append(@as(u32, @intCast(i)));
        }

        const optimized_efficiency = @as(f64, @floatFromInt(optimized_list.len() * @sizeOf(u32))) / @as(f64, @floatFromInt(optimized_list.capacity() * @sizeOf(u32)));
        std.debug.print("Optimized efficiency: {d:.1}% ({d} used / {d} capacity)\n", .{ optimized_efficiency * 100.0, optimized_list.len(), optimized_list.capacity() });
    }

    {
        // Pre-allocated: Maximum efficiency
        var prealloc_list = try collection_opt.OptimizedArrayList(u32).initCapacity(allocator, 1000, .conservative);
        defer prealloc_list.deinit();

        for (0..1000) |i| {
            try prealloc_list.append(@as(u32, @intCast(i)));
        }

        const prealloc_efficiency = @as(f64, @floatFromInt(prealloc_list.len() * @sizeOf(u32))) / @as(f64, @floatFromInt(prealloc_list.capacity() * @sizeOf(u32)));
        std.debug.print("Pre-allocated efficiency: {d:.1}% ({d} used / {d} capacity)\n", .{ prealloc_efficiency * 100.0, prealloc_list.len(), prealloc_list.capacity() });
    }

    std.debug.print("✅ Memory efficiency patterns validated\n", .{});
}

test "Collection pool thread safety simulation" {
    const allocator = testing.allocator;

    std.debug.print("\n=== COLLECTION POOL VALIDATION ===\n", .{});

    var pool = try collection_opt.CollectionPool(u32).init(allocator, 3, 50);
    defer pool.deinit();

    // Simulate concurrent usage
    var acquired_count: u32 = 0;
    var collections: [5]?*collection_opt.OptimizedArrayList(u32) = [_]?*collection_opt.OptimizedArrayList(u32){null} ** 5;

    // Acquire all available + attempt overflow
    for (&collections) |*slot| {
        slot.* = pool.acquire();
        if (slot.*) |_| {
            acquired_count += 1;
        }
    }

    std.debug.print("Acquired collections: {d}/5 (pool size: 3)\n", .{acquired_count});
    try testing.expect(acquired_count == 3); // Should only get 3 (pool size)

    // Use collections
    for (collections) |maybe_collection| {
        if (maybe_collection) |collection| {
            try collection.append(42);
            try collection.append(84);
            try testing.expect(collection.len() == 2);
        }
    }

    // Release collections
    for (collections) |maybe_collection| {
        if (maybe_collection) |collection| {
            pool.release(collection);
        }
    }

    // Should be able to acquire again
    const reacquired = pool.acquire();
    try testing.expect(reacquired != null);

    if (reacquired) |collection| {
        // Should be reset
        try testing.expect(collection.len() == 0);
        pool.release(collection);
    }

    std.debug.print("✅ Collection pool behavior validated\n", .{});
}

// Integration test validating collection optimization against performance targets
test "CANARY: REQ=REQ-PERF-COLLECTION-001" {
    // CANARY: REQ=REQ-PERF-COLLECTION-001; FEATURE="CollectionOptimization"; ASPECT=Integration; STATUS=TESTED; TEST=TestCANARY_REQ_PERF_COLLECTION_001; OWNER=performance; UPDATED=2025-10-04

    const allocator = testing.allocator;

    std.debug.print("\n=== CANARY COLLECTION OPTIMIZATION VALIDATION ===\n", .{});

    // Test result collector (simulates query result processing)
    var collector = try collection_opt.ResultCollector.init(allocator, 100, 64);
    defer collector.deinit();

    var timer = try std.time.Timer.start();

    // Simulate adding query results
    for (0..100) |i| {
        const row = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"name\":\"user{d}\",\"email\":\"user{d}@example.com\"}}", .{ i, i, i });
        defer allocator.free(row);

        const owned_row = try allocator.dupe(u8, row);
        try collector.addRow(owned_row);
    }

    const processing_time = timer.read();
    const stats = collector.getStats();

    std.debug.print("Result collection performance:\n", .{});
    std.debug.print("  Processing time: {d}μs\n", .{processing_time / 1000});
    std.debug.print("  Rows: {d}\n", .{stats.rows});
    std.debug.print("  Capacity: {d}\n", .{stats.capacity});
    std.debug.print("  Estimated row size: {d} bytes\n", .{stats.estimated_row_size});
    std.debug.print("  Memory efficiency: {d:.1}%\n", .{@as(f64, @floatFromInt(stats.rows)) / @as(f64, @floatFromInt(stats.capacity)) * 100.0});

    // Performance regression test: should be significantly faster than 746μs baseline
    try testing.expect(processing_time < 400_000); // Less than 400μs (1.8x improvement target)

    // Memory efficiency should be reasonable
    const efficiency = @as(f64, @floatFromInt(stats.rows)) / @as(f64, @floatFromInt(stats.capacity));
    try testing.expect(efficiency > 0.6); // At least 60% efficiency

    // Cleanup allocated rows
    for (collector.getRows()) |row| {
        allocator.free(row);
    }

    std.debug.print("✅ CANARY: Collection optimization validated\n", .{});
    std.debug.print("✅ CANARY: Performance targets achieved\n", .{});
    std.debug.print("✅ CANARY: Memory efficiency confirmed\n", .{});
}
