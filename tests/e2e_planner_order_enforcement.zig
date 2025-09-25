const std = @import("std");
const testing = std.testing;
const planner = @import("../src/planner.zig");
const ast = @import("../src/gql/ast.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="Planner ISO Enforcement"; ASPECT=OrderByEnforcement; STATUS=TESTED; TEST=e2e_planner_order_enforcement; OWNER=planner; UPDATED=2025-09-25

test "ORDER BY required with LIMIT" {
    const allocator = testing.allocator;
    
    // Test case 1: LIMIT without ORDER BY should fail
    {
        const ctx = try planner.createDefaultPlanner(allocator);
        defer allocator.destroy(ctx);
        
        var query = ast.QueryNode{
            .has_limit = true,
            .has_offset = false,
            .has_order_by = false,
        };
        
        const result = ctx.validateOrderByWithLimit(&query);
        try testing.expectError(planner.PlannerError.OrderByRequired, result);
        
        // This should print to stderr
        std.debug.print("PLANNER_ERROR ORDER_BY_REQUIRED\n", .{});
    }
    
    // Test case 2: LIMIT with ORDER BY should succeed
    {
        const ctx = try planner.createDefaultPlanner(allocator);
        defer allocator.destroy(ctx);
        
        var query = ast.QueryNode{
            .has_limit = true,
            .has_offset = false,
            .has_order_by = true,
        };
        
        try ctx.validateOrderByWithLimit(&query);
        std.debug.print("ORDER_BY_ENFORCED_OK\n", .{});
    }
}

test "OFFSET without ORDER BY should fail" {
    const allocator = testing.allocator;
    const ctx = try planner.createDefaultPlanner(allocator);
    defer allocator.destroy(ctx);
    
    var query = ast.QueryNode{
        .has_limit = true,
        .has_offset = true,
        .has_order_by = false,
    };
    
    const result = ctx.validateOrderByWithLimit(&query);
    try testing.expectError(planner.PlannerError.OrderByRequired, result);
}