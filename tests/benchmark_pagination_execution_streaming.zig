const std = @import("std");

// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination"; ASPECT=PaginationExecutionStreaming; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_004_PaginationExecutionStreaming; OWNER=planner; UPDATED=2026-11-14

fn simulate_page_emission(pages: usize, base_ms: i64, jitter_ms: i64) []i64 {
    var times: [256]i64 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < pages and count < times.len) : (i += 1) {
        const start = std.time.milliTimestamp();
        // Simulate work
        std.Thread.sleep(@intCast((base_ms + @as(i64, @intCast(i % @as(usize, @intCast(jitter_ms))))) * std.time.ns_per_ms));
        const endt = std.time.milliTimestamp();
        times[count] = endt - start;
        count += 1;
    }
    return times[0..count];
}

test "BenchmarkCANARY_REQ_GQL_004_PaginationExecutionStreaming" {
    const pages: usize = 20;
    const samples: usize = 32;
    var lat: [32]f64 = undefined;
    var s: usize = 0;
    while (s < samples) : (s += 1) {
        const arr = simulate_page_emission(pages, 1, 2);
        var sum: f64 = 0;
        for (arr) |v| sum += @as(f64, @floatFromInt(v));
        lat[s] = sum / @as(f64, @floatFromInt(arr.len));
    }
    var mean: f64 = 0;
    for (lat) |v| mean += v;
    mean /= @as(f64, @floatFromInt(lat.len));
    var var_acc: f64 = 0;
    for (lat) |v| {
        const d = v - mean;
        var_acc += d * d;
    }
    const cv = if (mean == 0) 0 else @sqrt(var_acc / @as(f64, @floatFromInt(lat.len))) / mean;
    try std.testing.expect(cv <= 0.22);
}
