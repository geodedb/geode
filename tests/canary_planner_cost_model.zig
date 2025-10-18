const std = @import("std");
const geode = @import("../src/lib.zig");
const pipeline = geode.planner_pipeline;
const enumerator = @import("../src/planner/enumerator.zig");

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanCostModelFactors; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanCostModelFactors; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanCostModelVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

fn makeQuery(ret_items: usize, allocator: std.mem.Allocator) geode.planner.ast.Query {
    var items = allocator.alloc(geode.planner.ast.ReturnItem, ret_items) catch unreachable;
    var i: usize = 0;
    while (i < ret_items) : (i += 1) {
        items[i] = .{ .expr = geode.planner.ast.Expr{ .Int = @intCast(i + 1) }, .alias = null };
    }
    return .{
        .optional_match = false,
        .match = .{ .chains = &.{} },
        .where_clause = null,
        .with_clause = null,
        .group_by = null,
        .having = null,
        .ret = .{ .items = items, .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };
}

test "TestCANARY_REQ_GQL_024_PlanCostModelFactors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const small = makeQuery(1, allocator);
    const large = makeQuery(4, allocator);
    const res_small = try pipeline.planQuerySelectBest(allocator, small, .{ .max_plans = 64 });
    const res_large = try pipeline.planQuerySelectBest(allocator, large, .{ .max_plans = 128 });
    try std.testing.expect(res_small.best != null and res_large.best != null);
    // Expect refined cost for larger query (more leaves) to be greater
    try std.testing.expect(res_large.best.?.cost > res_small.best.?.cost);
}

// Variance envelope for cost model evaluation runtime (stability guard)
test "BenchmarkCANARY_REQ_GQL_024_PlanCostModelVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const runs: usize = 80;
    var samples = try allocator.alloc(u64, runs);
    defer allocator.free(samples);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const ri: usize = 1 + (i % 4); // 1..4 return items
        const q = makeQuery(ri, allocator);
        const t0 = std.time.nanoTimestamp();
        _ = try pipeline.planQuerySelectBest(allocator, q, .{ .max_plans = 64 });
        const t1 = std.time.nanoTimestamp();
        samples[i] = @intCast(t1 - t0);
    }
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var acc: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;
    const tmp = try allocator.alloc(u64, samples.len);
    defer allocator.free(tmp);
    std.mem.copy(u64, tmp, samples);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;
    if (cv > 0.22 or p95_ratio > 2.55) return error.VarianceEnvelopeBreached;
}
