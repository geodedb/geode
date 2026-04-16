const std = @import("std");
const recursive = @import("../src/planner/recursive.zig");

// TestCANARY_REQ_GQL_079_FixpointDriver
// Verifies convergence and exhaustion behavior of runFixpoint.

fn stepConverge(ctx: *anyopaque, iter: u32) bool {
    _ = ctx;
    // Converge after 3 iterations (i = 0,1,2 run; at i=2 we return false next pass?)
    return iter < 3;
}

const ExhaustCtx = struct { calls: u32 };
fn stepExhaust(ctx_raw: *anyopaque, iter: u32) bool {
    _ = iter;
    var ctx: *ExhaustCtx = @ptrCast(@alignCast(ctx_raw));
    ctx.calls += 1;
    return true; // never converges
}

test "TestCANARY_REQ_GQL_079_FixpointDriver" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Case 1: Converging step
    var exhausted = false;
    const iters = try recursive.RecursiveQueryProcessor.runFixpoint(alloc, 100, &exhausted, stepConverge, null);
    try std.testing.expect(!exhausted);
    // Expect 3 iterations executed (0,1,2) -> loop increments to 3 and breaks due to step false.
    try std.testing.expectEqual(@as(u32, 3), iters);

    // Case 2: Exhaustion (no convergence before cap)
    var exhaust_ctx = ExhaustCtx{ .calls = 0 };
    exhausted = false;
    const max_iters: u32 = 5;
    const iters2 = try recursive.RecursiveQueryProcessor.runFixpoint(alloc, max_iters, &exhausted, stepExhaust, &exhaust_ctx);
    try std.testing.expect(exhausted);
    try std.testing.expectEqual(max_iters, iters2);
    // Number of calls should equal max_iters
    try std.testing.expectEqual(max_iters, exhaust_ctx.calls);
}
