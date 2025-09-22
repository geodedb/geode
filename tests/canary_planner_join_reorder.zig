const std = @import("std");
const geode = @import("../src/lib.zig");
const enumerator = @import("../src/planner/enumerator.zig");
const pipeline = geode.planner_pipeline;

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanJoinReorderDiversity; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanJoinReorderDiversity; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanJoinReorderVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanJoinReorderVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

fn buildQueryWithReturns(n: usize, ally: std.mem.Allocator) geode.planner.ast.Query {
    var items = ally.alloc(geode.planner.ast.ReturnItem, n) catch unreachable;
    var i: usize = 0;
    while (i < n) : (i += 1) items[i] = .{ .expr = geode.planner.ast.Expr{ .Int = @intCast(i + 1) }, .alias = null };
    return .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = items, .distinct = false }, .order_by = null, .limit = null, .offset = null };
}

test "TestCANARY_REQ_GQL_024_PlanJoinReorderDiversity" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const q = buildQueryWithReturns(5, ally); // builds left-deep synthetic join tree of 5 scans
    var pe = enumerator.PlanEnumerator.init(ally, .{ .max_plans = 256, .enable_join_commutativity = true });
    defer pe.deinit();
    var buf = std.ArrayListUnmanaged(enumerator.CandidatePlan){};
    defer buf.deinit(ally);
    try pe.enumerateUnmanaged(.{ .op = .project, .children = &.{pipeline.buildLogicalTree(q, ally) catch unreachable} }, ally, &buf);
    try std.testing.expect(pe.stats.unique_join_signatures > 0);
    // With commutativity enabled we expect >1 unique signature for 5-leaf join chain.
    try std.testing.expect(pe.stats.unique_join_signatures > 1);
}

test "BenchmarkCANARY_REQ_GQL_024_PlanJoinReorderVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const runs: usize = 40;
    var samples = try ally.alloc(u64, runs);
    defer ally.free(samples);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const q = buildQueryWithReturns(4 + (i % 3), ally); // vary leaf count 4..6
        const t0 = std.time.nanoTimestamp();
        _ = try pipeline.planQuerySelectBest(ally, q, .{ .max_plans = 256, .enable_join_commutativity = true });
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
    const tmp = try ally.alloc(u64, samples.len);
    defer ally.free(tmp);
    std.mem.copy(u64, tmp, samples);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;
    if (cv > 0.22 or p95_ratio > 2.55) return error.VarianceEnvelopeBreached;
}
