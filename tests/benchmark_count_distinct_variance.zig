const std = @import("std");
const exec = @import("exec.zig");
const ast = @import("gql/ast.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="Aggregation COUNT DISTINCT"; ASPECT=CountDistinctVarianceEnvelope; STATUS=BENCHED; TEST=BenchmarkCANARY_REQ_GQL_012_CountDistinctVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21

// Simple variance bench for COUNT DISTINCT over synthetic data sets comparing repeated runs.
// Measures CV and p95/mean ratio of build+emit timings across iterations.

fn benchOnce(allocator: std.mem.Allocator, rows: usize, distinct_ratio: f64) !i128 {
    // Build synthetic rows with controlled duplication for a single group.
    const cal = ast.Expr{ .Ident = "countDistinct" };
    const a_id = ast.Expr{ .Ident = "a" };
    var items: [1]ast.ReturnItem = .{.{ .expr = .{ .Call = .{ .callee = &cal, .args = &.{&a_id} } }, .alias = null }};
    const g = ast.Expr{ .Ident = "g" };
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    var input = try allocator.alloc([]const exec.BindingValue, rows);
    var i: usize = 0;
    const distinct_target = @max(@as(usize, @intFromFloat(@as(f64, @floatFromInt(rows)) * distinct_ratio)), 1);
    while (i < rows) : (i += 1) {
        const val: i64 = @intCast(i % distinct_target);
        input[i] = &.{ .{ .Int = val }, .{ .Str = "X" } };
    }
    var timings = exec.AggStageTimings{};
    _ = try exec.runGroupedQuery(allocator, q, &.{ "a", "g" }, input, &.{}, &.{}, &timings);
    allocator.free(input);
    return timings.build_ns + timings.emit_ns;
}

test "BenchmarkCANARY_REQ_GQL_012_CountDistinctVarianceEnvelope" {
    const allocator = std.testing.allocator;
    const iters: usize = 25;
    var samples = try allocator.alloc(f64, iters);
    defer allocator.free(samples);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t = try benchOnce(allocator, 2000, 0.3);
        samples[i] = @as(f64, @floatFromInt(t));
    }
    // compute mean, variance, p95
    var sum: f64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / @as(f64, @floatFromInt(iters));
    var var_sum: f64 = 0;
    for (samples) |s| {
        const d = s - mean;
        var_sum += d * d;
    }
    const variance = var_sum / @as(f64, @floatFromInt(iters));
    const cv = std.math.sqrt(variance) / mean;
    std.sort.pdq(f64, samples, {}, std.sort.asc(f64));
    const idx95 = (iters * 95) / 100;
    const p95 = samples[idx95];
    const ratio = p95 / mean;
    // Thresholds
    try std.testing.expect(cv <= 0.22);
    try std.testing.expect(ratio <= 2.55);
}
