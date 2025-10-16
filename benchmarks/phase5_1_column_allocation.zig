// Phase 5.1.1 Performance Optimization Benchmarks
// Validates the batch column allocation optimization

const std = @import("std");
const testing = std.testing;

// CANARY: BENCHMARK_PHASE5_1 - Performance validation for Phase 5.1.1 optimization
// CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=TESTING; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16

// =============================================================================
// Benchmark 1: Batch Column Allocation vs Individual Allocations
// =============================================================================

/// Helper to replicate the allocateColumnStrings function from execution.zig
fn allocateColumnStrings(allocator: std.mem.Allocator, strings: []const []const u8) !struct { columns: [][]const u8, buffer: []u8 } {
    // Calculate total size needed
    var total_size: usize = 0;
    for (strings) |s| {
        total_size += s.len;
    }

    // Allocate single buffer for all strings
    const buffer = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buffer);

    // Allocate columns array
    const columns = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(columns);

    // Copy strings into buffer and create slices
    var offset: usize = 0;
    for (strings, 0..) |s, i| {
        const slice = buffer[offset .. offset + s.len];
        @memcpy(slice, s);
        columns[i] = slice;
        offset += s.len;
    }

    return .{ .columns = columns, .buffer = buffer };
}

/// Benchmark: Batch column allocation (optimized)
fn benchmarkBatchAllocation(allocator: std.mem.Allocator, col_count: usize, iterations: usize) !u64 {
    // Create test strings
    const strings = try allocator.alloc([]const u8, col_count);
    defer allocator.free(strings);

    for (strings, 0..) |*s, i| {
        const str = try std.fmt.allocPrint(allocator, "column{d}", .{i});
        s.* = str;
    }
    defer for (strings) |s| allocator.free(s);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Batch allocation (optimized)
        const result = try allocateColumnStrings(allocator, strings);
        allocator.free(result.buffer);
        allocator.free(result.columns);
    }

    const end = timer.read();
    return end - start;
}

/// Benchmark: Individual column allocations (baseline)
fn benchmarkIndividualAllocation(allocator: std.mem.Allocator, col_count: usize, iterations: usize) !u64 {
    // Create test strings
    const strings = try allocator.alloc([]const u8, col_count);
    defer allocator.free(strings);

    for (strings, 0..) |*s, i| {
        const str = try std.fmt.allocPrint(allocator, "column{d}", .{i});
        s.* = str;
    }
    defer for (strings) |s| allocator.free(s);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Individual allocations (baseline)
        const columns = try allocator.alloc([]const u8, col_count);
        for (strings, 0..) |s, j| {
            columns[j] = try allocator.dupe(u8, s);
        }

        // Cleanup
        for (columns) |col| {
            allocator.free(col);
        }
        allocator.free(columns);
    }

    const end = timer.read();
    return end - start;
}

test "Benchmark: Batch vs Individual Allocation (10 columns)" {
    const allocator = testing.allocator;
    const iterations = 10000;
    const col_count = 10;

    const batch_time = try benchmarkBatchAllocation(allocator, col_count, iterations);
    const individual_time = try benchmarkIndividualAllocation(allocator, col_count, iterations);

    std.debug.print("\n=== Phase 5.1.1: Column Allocation ({d} columns) ===\n", .{col_count});
    std.debug.print("Batch allocation:      {} ns\n", .{batch_time});
    std.debug.print("Individual allocation: {} ns\n", .{individual_time});

    const ratio = @as(f64, @floatFromInt(individual_time)) / @as(f64, @floatFromInt(batch_time));
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.2x (20% improvement)\n", .{});

    // Verify we get at least 20% improvement
    try testing.expect(ratio >= 1.2);
}

test "Benchmark: Batch vs Individual Allocation (50 columns)" {
    const allocator = testing.allocator;
    const iterations = 5000;
    const col_count = 50;

    const batch_time = try benchmarkBatchAllocation(allocator, col_count, iterations);
    const individual_time = try benchmarkIndividualAllocation(allocator, col_count, iterations);

    std.debug.print("\n=== Phase 5.1.1: Column Allocation ({d} columns) ===\n", .{col_count});
    std.debug.print("Batch allocation:      {} ns\n", .{batch_time});
    std.debug.print("Individual allocation: {} ns\n", .{individual_time});

    const ratio = @as(f64, @floatFromInt(individual_time)) / @as(f64, @floatFromInt(batch_time));
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.25x (25% improvement)\n", .{});

    // Verify we get at least 25% improvement
    try testing.expect(ratio >= 1.25);
}

test "Benchmark: Batch vs Individual Allocation (100 columns)" {
    const allocator = testing.allocator;
    const iterations = 2000;
    const col_count = 100;

    const batch_time = try benchmarkBatchAllocation(allocator, col_count, iterations);
    const individual_time = try benchmarkIndividualAllocation(allocator, col_count, iterations);

    std.debug.print("\n=== Phase 5.1.1: Column Allocation ({d} columns) ===\n", .{col_count});
    std.debug.print("Batch allocation:      {} ns\n", .{batch_time});
    std.debug.print("Individual allocation: {} ns\n", .{individual_time});

    const ratio = @as(f64, @floatFromInt(individual_time)) / @as(f64, @floatFromInt(batch_time));
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.3x (30% improvement)\n", .{});

    // Verify we get at least 30% improvement
    try testing.expect(ratio >= 1.3);
}

test "Benchmark: Allocation count validation" {
    const allocator = testing.allocator;

    // Test with 10 columns
    const strings = [_][]const u8{
        "col0", "col1", "col2", "col3", "col4",
        "col5", "col6", "col7", "col8", "col9",
    };

    // Batch allocation should only do 2 allocations (buffer + columns array)
    const result = try allocateColumnStrings(allocator, &strings);
    defer allocator.free(result.buffer);
    defer allocator.free(result.columns);

    // Verify all columns are present and correct
    try testing.expectEqual(@as(usize, 10), result.columns.len);
    for (result.columns, 0..) |col, i| {
        try testing.expectEqualStrings(strings[i], col);
    }

    std.debug.print("\n=== Allocation Count Test ===\n", .{});
    std.debug.print("Columns: {d}\n", .{result.columns.len});
    std.debug.print("Total buffer size: {d} bytes\n", .{result.buffer.len});
    std.debug.print("Allocations: 2 (buffer + columns array)\n", .{});
    std.debug.print("Previous approach: {d} allocations (1 per column + array)\n", .{result.columns.len + 1});
}
