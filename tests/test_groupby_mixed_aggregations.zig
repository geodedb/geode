const std = @import("std");
const ast = @import("../src/ast.zig");
const exec = @import("../src/exec.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=MixedAggregationBreadth; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_MixedAggregationBreadth; OWNER=engine; UPDATED=2025-09-21
// Covers combined COUNT DISTINCT + SUM + AVG + MIN + MAX with HAVING compound predicate and negative value handling.

fn buildRows(allocator: std.mem.Allocator) ![]exec.BindingRow {
    // rows: group g in {"a","a","a","b","b"}; values v = [1,2,2,10,-5]; w = [5,5,5,100,100]
    const groups = [_][]const u8{ "a", "a", "a", "b", "b" };
    const vvals = [_]i64{ 1, 2, 2, 10, -5 };
    const wvals = [_]i64{ 5, 5, 5, 100, 100 };
    var out = std.ArrayList(exec.BindingRow).init(allocator);
    for (groups, 0..) |g, i| {
        var cols = try allocator.alloc(exec.BindingValue, 3);
        cols[0] = exec.BindingValue{ .Str = g };
        cols[1] = exec.BindingValue{ .Int = vvals[i] };
        cols[2] = exec.BindingValue{ .Int = wvals[i] };
        try out.append(.{ .cols = cols });
    }
    return out.toOwnedSlice();
}

test "TestCANARY_REQ_GQL_012_MixedAggregationBreadth" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Logical: SELECT g, COUNT(DISTINCT v) AS cd, SUM(v) AS s, AVG(v) AS av, MIN(v) AS mn, MAX(w) AS mx
    // FROM R GROUP BY g HAVING COUNT(DISTINCT v) > 1 AND SUM(v) > 0 OR MAX(w) >= 100
    // We emulate through direct executor wiring (no full SQL/GQL surface yet for combined HAVING logic)

    const rows = try buildRows(allocator);
    defer {
        for (rows) |r| allocator.free(r.cols);
        allocator.free(rows);
    }

    // Build synthetic group-by plan fragment
    const agg_specs = [_]exec.Agg{ .CountDistinct, .Sum, .Avg, .Min, .Max };

    var agg = exec.HashAggregator.init(allocator, 1 << 20);
    defer agg.deinit();

    // Feed rows
    for (rows) |r| {
        var key_vals = [_]exec.BindingValue{r.cols[0]}; // group key g
        // agg inputs mapping: CountDistinct(v), Sum(v), Avg(v), Min(v), Max(w)
        var inputs = [_]exec.BindingValue{ r.cols[1], r.cols[1], r.cols[1], r.cols[1], r.cols[2] };
        try agg.addRow(&key_vals, &inputs, &agg_specs);
    }

    const result_rows = try agg.getResults();
    defer {
        // result rows reference original values; no ownership of strings allocated here beyond aggregator internals.
        for (result_rows) |rr| allocator.free(rr);
        allocator.free(result_rows);
    }

    // Extract rows into a map keyed by group string for assertions
    var map = std.StringHashMap(struct { cd: i64, sum: i64, avg: i64, mn: i64, mx: i64 }).init(allocator);
    defer map.deinit();

    for (result_rows) |rr| {
        // rr layout: key g, then 5 aggs
        const g = rr[0].Str;
        const cd = rr[1].Int; // CountDistinct
        const s = rr[2].Int; // Sum
        const av = rr[3].Int; // Avg truncated
        const mn = rr[4].Int; // Min
        const mx = rr[5].Int; // Max
        try map.put(g, .{ .cd = cd, .sum = s, .avg = av, .mn = mn, .mx = mx });
    }

    // Group a: v values 1,2,2 => distinct=2, sum=5, avg= (1+2+2)/3=1, min=1, max(w)=5
    const a = map.get("a").?;
    try std.testing.expectEqual(@as(i64, 2), a.cd);
    try std.testing.expectEqual(@as(i64, 5), a.sum);
    try std.testing.expectEqual(@as(i64, 1), a.avg);
    try std.testing.expectEqual(@as(i64, 1), a.mn);
    try std.testing.expectEqual(@as(i64, 5), a.mx);

    // Group b: v values 10,-5 => distinct=2, sum=5, avg= (10-5)/2=2, min=-5, max(w)=100
    const b = map.get("b").?;
    try std.testing.expectEqual(@as(i64, 2), b.cd);
    try std.testing.expectEqual(@as(i64, 5), b.sum);
    try std.testing.expectEqual(@as(i64, 2), b.avg);
    try std.testing.expectEqual(@as(i64, -5), b.mn);
    try std.testing.expectEqual(@as(i64, 100), b.mx);

    // Emulate HAVING predicate evaluation: (cd>1 AND sum>0) OR mx>=100
    const include_a = (a.cd > 1 and a.sum > 0) or (a.mx >= 100);
    const include_b = (b.cd > 1 and b.sum > 0) or (b.mx >= 100);
    try std.testing.expect(include_a); // true: first conjunct passes
    try std.testing.expect(include_b); // true: mx>=100 satisfies OR
}
