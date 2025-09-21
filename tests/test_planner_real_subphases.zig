const std = @import("std");
const pipeline = @import("../src/planner/pipeline.zig");
const path_cache_mod = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=RewriteHookPipelineIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_RewriteHookPipelineIntegration; OWNER=planner; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=GroupValidationHookPipelineIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_GroupValidationHookPipelineIntegration; OWNER=planner; UPDATED=2025-09-21

fn run(q: []const u8) !pipeline.PipelineResult {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try path_cache_mod.PathCache.init(gpa.allocator(), 4);
    defer cache.deinit();
    return try pipeline.runPipeline(gpa.allocator(), .{}, &cache, q);
}

test "TestCANARY_REQ_GQL_021_RewriteHookPipelineIntegration" {
    const res = try run("RETURN 1 AS x");
    try std.testing.expect(res.timings.rewrite_ns > 0);
}

test "TestCANARY_REQ_GQL_021_GroupValidationHookPipelineIntegration" {
    const res = try run("MATCH (a)--(b) RETURN a");
    try std.testing.expect(res.timings.cardinality_ns > 0);
    try std.testing.expect(res.group_validation_ns > 0);
}
