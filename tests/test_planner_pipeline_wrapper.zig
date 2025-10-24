const std = @import("std");
const ast = @import("../src/ast.zig");
const pipeline = @import("../src/planner/pipeline.zig");
const path_cache_mod = @import("../src/planner/path_cache.zig");

test "TestCANARY_REQ_GQL_021_PlannerPipelineWrapperIntegration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    // Build a minimal ast.Query resembling earlier planner tests
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    var cache = try path_cache_mod.PathCache.init(gpa.allocator(), 8);
    defer cache.deinit();
    const first = try pipeline.planQueryWithPipeline(gpa.allocator(), .{}, &cache, q);
    try std.testing.expect(first.pipeline.timings.rewrite_ns > 0);
    const second = try pipeline.planQueryWithPipeline(gpa.allocator(), .{}, &cache, q);
    try std.testing.expect(second.pipeline.cache_hit); // second invocation should hit cache
}
