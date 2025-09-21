const std = @import("std");
const exec = @import("exec.zig");
const ast = @import("gql/ast.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggDistinctHighCardVarianceEnvelope; STATUS=BENCHED; TEST=BenchmarkCANARY_REQ_GQL_012_HashAggDistinctHighCardVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21

// Benchmark variance of COUNT DISTINCT over a high-cardinality workload with multiple groups.
// Ensures accumulator map + distinct set growth remain stable in relative variance.

fn makeQuery() ast.Query {
    const g_ident = ast.Expr{ .Ident = "g" };
    const a_ident = ast.Expr{ .Ident = "a" };
    const cd_ident = ast.Expr{ .Ident = "countDistinct" };
    const call_cd = ast.Expr{ .Call = .{ .callee = &cd_ident, .args = &.{&a_ident} } };
    const items = [_]ast.ReturnItem{ .{ .expr = g_ident, .alias = null }, .{ .expr = call_cd, .alias = "c" } };
    return ast.Query{
        .optional_match = false,
        .match = .{ .chains = &.{} },
        .where_clause = null,
        .with_clause = null,
        .group_by = .{ .keys = &.{g_ident} },
        .having = null,
        .ret = .{ .items = items[0..], .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };
}

fn runOnce(ally: std.mem.Allocator, q: ast.Query, rows: []const []const exec.BindingValue) !i128 {
    var eval_rows = try ally.alloc([]const @import("eval.zig").Value, rows.len);
    defer ally.free(eval_rows);
    var i: usize = 0;
    while (i < rows.len) : (i += 1) {
        // Each row has (g,a)
        const gval = rows[i][0];
        const aval = rows[i][1];
        eval_rows[i] = &.{ bindingToEval(gval), bindingToEval(aval) };
    }
    var timings = exec.AggStageTimings{};
    const out = try exec.runGroupedQuery(ally, q, &.{ "g", "a" }, eval_rows, &.{}, &.{}, &timings);
    ally.free(out);
    return timings.build_ns + timings.emit_ns;
}

fn bindingToEval(b: exec.BindingValue) @import("eval.zig").Value {
    return switch (b) {
        .Null => .{ .Null = {} },
        .Int => |n| .{ .Int = n },
        .Bool => |bb| .{ .Bool = bb },
        .Str => |s| .{ .Str = s },
        .Decimal => |_| .{ .Null = {} },
    };
}

test "BenchmarkCANARY_REQ_GQL_012_HashAggDistinctHighCardVarianceEnvelope" {
    const ally = std.testing.allocator;
    const q = makeQuery();
    // Build synthetic rows: G groups, each with ~N distinct values, with duplicates sprinkled.
    const G: usize = 25;
    const N: usize = 400; // distinct cardinality per group target
    const TOTAL = G * N;
    var rows = try ally.alloc([]const exec.BindingValue, TOTAL);
    defer ally.free(rows);
    var gi: usize = 0;
    var idx: usize = 0;
    while (gi < G) : (gi += 1) {
        var vi: usize = 0;
        while (vi < N) : (vi += 1) {
            const g_label = switch (gi % 3) {
                0 => "A",
                1 => "B",
                else => "C",
            }; // keep group label set small for grouping map stress
            const aval: i64 = @intCast((vi + (gi * 131)) % (N * 2)); // Many distinct but some collisions
            rows[idx] = &.{ .{ .Str = g_label }, .{ .Int = aval } };
            idx += 1;
        }
    }
    const iters: usize = 24;
    var samples = try ally.alloc(f64, iters);
    defer ally.free(samples);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t = try runOnce(ally, q, rows);
        samples[i] = @as(f64, @floatFromInt(t));
    }
    // Compute mean, variance, p95
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
    const p95 = samples[(iters * 95) / 100];
    const ratio = p95 / mean;
    try std.testing.expect(cv <= 0.22);
    try std.testing.expect(ratio <= 2.55);
}
