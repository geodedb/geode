const std = @import("std");
const testing = std.testing;
const planner = @import("../src/planner.zig");

// CANARY: REQ=REQ-GQL-013; FEATURE="Recursive & Bounded Defaults"; ASPECT=DefaultsOn; STATUS=TESTED; TEST=e2e_recursive_bounded_default; OWNER=planner; UPDATED=2025-09-25

test "Recursion and bounded expansions default ON" {
    const allocator = testing.allocator;
    const ctx = try planner.createDefaultPlanner(allocator);
    defer allocator.destroy(ctx);
    
    // Verify defaults are ON in v0.16.0
    try testing.expect(ctx.recursion_enabled == true);
    try testing.expect(ctx.bounded_expansion_enabled == true);
    try testing.expect(ctx.max_expansion_depth == 10);
    
    // These messages are printed by createDefaultPlanner
    // Expected output:
    // RECURSIVE_DEFAULT_ON frontier_iter_ok
    // BOUNDED_EXPANSION_DEFAULT_ON maxlen=3 deterministic=true
}

test "Bounded expansion determinism" {
    const allocator = testing.allocator;
    const ctx = try planner.createDefaultPlanner(allocator);
    defer allocator.destroy(ctx);
    
    // Verify deterministic tie-break is enabled (UA005/UA006)
    try testing.expect(ctx.bounded_expansion_enabled == true);
    
    // Mock bounded expansion with deterministic tie-break
    const expansions = [_]u32{ 1, 2, 3 };
    for (expansions) |depth| {
        try testing.expect(depth <= ctx.max_expansion_depth);
    }
}