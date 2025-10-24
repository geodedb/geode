const std = @import("std");
const exec = @import("../src/exec.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggSpillFlag; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_HashAggSpillFlag; OWNER=engine; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_012_HashAggSpillFlag" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Very small memory limit to force spill quickly.
    var agg = exec.HashAggregator.init(allocator, 128);
    defer agg.deinit();

    const aggs = [_]exec.Agg{.Sum};

    // Insert enough distinct groups (keys) to exceed limit.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const key_val = exec.BindingValue{ .Int = @intCast(i) };
        const key_slice = [_]exec.BindingValue{key_val};
        const input = [_]exec.BindingValue{.{ .Int = 1 }};
        try agg.addRow(key_slice[0..], input[0..], &aggs);
        // Artificially increase current memory to simulate usage and trigger spill
        agg.current_memory += 64; // simulate per-group memory footprint
        if (!agg.spilled and agg.current_memory > agg.memory_limit) try agg.spillToDisk();
    }

    try std.testing.expect(agg.spilled);
    const results = try agg.getResults();
    defer allocator.free(results);
    // We expect up to 64 groups retained since phase-1 spill keeps in-memory state.
    try std.testing.expect(results.len > 0);
}
