const std = @import("std");
const testing = std.testing;
const time = std.time;

// Simple JSON benchmark to validate performance improvements

test "JSON performance comparison" {
    const allocator = testing.allocator;

    std.debug.print("\n=== JSON PERFORMANCE COMPARISON ===\n", .{});

    const test_json =
        \\{"name":"John Doe","age":30,"city":"New York","skills":["programming","design","management"],"active":true}
    ;

    // Baseline approach
    var baseline_times = std.ArrayList(u64).init(allocator);
    defer baseline_times.deinit();

    for (0..1000) |_| {
        const start = time.nanoTimestamp();

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, test_json, .{}) catch continue;
        defer parsed.deinit();

        // Access fields to ensure parsing is complete
        if (parsed.value.object.get("name")) |name| {
            _ = name;
        }

        const end = time.nanoTimestamp();
        try baseline_times.append(@as(u64, @intCast(end - start)));
    }

    // Arena approach (optimized)
    var optimized_times = std.ArrayList(u64).init(allocator);
    defer optimized_times.deinit();

    for (0..1000) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const start = time.nanoTimestamp();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), test_json, .{}) catch continue;
        defer parsed.deinit();

        // Access fields to ensure parsing is complete
        if (parsed.value.object.get("name")) |name| {
            _ = name;
        }

        const end = time.nanoTimestamp();
        try optimized_times.append(@as(u64, @intCast(end - start)));
    }

    // Calculate averages
    var baseline_total: u64 = 0;
    for (baseline_times.items) |t| {
        baseline_total += t;
    }
    const baseline_avg = baseline_total / baseline_times.items.len;

    var optimized_total: u64 = 0;
    for (optimized_times.items) |t| {
        optimized_total += t;
    }
    const optimized_avg = optimized_total / optimized_times.items.len;

    // Results
    std.debug.print("Baseline JSON Parse: {d}ns ({d:.2}μs)\n", .{ baseline_avg, @as(f64, @floatFromInt(baseline_avg)) / 1000.0 });
    std.debug.print("Optimized JSON Parse: {d}ns ({d:.2}μs)\n", .{ optimized_avg, @as(f64, @floatFromInt(optimized_avg)) / 1000.0 });

    const improvement = @as(f64, @floatFromInt(baseline_avg)) / @as(f64, @floatFromInt(optimized_avg));
    std.debug.print("Improvement: {d:.2}x faster\n", .{improvement});

    // Compare to 630μs baseline from performance analysis
    const performance_baseline_ns: u64 = 630_000; // 630μs
    const vs_baseline = @as(f64, @floatFromInt(performance_baseline_ns)) / @as(f64, @floatFromInt(optimized_avg));
    std.debug.print("Vs 630μs baseline: {d:.2}x faster\n", .{vs_baseline});

    // Validate improvements
    try testing.expect(improvement > 1.2); // At least 20% improvement
    try testing.expect(optimized_avg < 200_000); // Less than 200μs

    std.debug.print("✅ JSON optimization validated\n", .{});
}
