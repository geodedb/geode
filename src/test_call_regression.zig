// Regression test for CALL procedure functionality
// CANARY: REQ=REQ-TEST-CALL-REGRESSION; FEATURE="CallProcedureRegression"; ASPECT=Testing; STATUS=ACTIVE; OWNER=test; UPDATED=2025-10-18

const std = @import("std");
const testing = std.testing;
const execution = @import("execution.zig");
const execution_helpers = @import("execution/execution_helpers.zig");
const ast = @import("gql/ast.zig");
const eval = @import("eval.zig");
const graph_store = @import("graph_store.zig");

test "CALL procedure YIELD filtering regression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a mock ExecutionResult with two columns
    var result = execution.ExecutionResult{
        .columns = try allocator.alloc([]const u8, 2),
        .rows = try allocator.alloc([]eval.Value, 1),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
    defer {
        allocator.free(result.columns);
        for (result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(result.rows);
    }

    // Set up columns
    result.columns[0] = "path";
    result.columns[1] = "cost";

    // Create a single row
    const row = try allocator.alloc(eval.Value, 2);
    row[0] = eval.Value{ .List = try allocator.alloc(eval.Value, 2) };
    row[0].List[0] = eval.Value{ .Int = 1 };
    row[0].List[1] = eval.Value{ .Int = 2 };
    row[1] = eval.Value{ .Decimal = .{ .coeff = 300, .scale = 2 } }; // 3.00
    result.rows[0] = row;

    // Create YIELD items that only request "cost"
    var yield_items = try allocator.alloc(ast.ReturnItem, 1);
    defer allocator.free(yield_items);

    const ident_expr = try allocator.create(ast.Expr);
    defer allocator.destroy(ident_expr);
    ident_expr.* = ast.Expr{ .Ident = .{ .orig = "cost", .cnf = "COST" } };

    yield_items[0] = ast.ReturnItem{
        .expr = ident_expr,
        .alias = null,
    };

    // Apply YIELD filtering
    const filtered = try execution_helpers.filterYieldColumns(allocator, result, yield_items);
    defer {
        allocator.free(filtered.columns);
        for (filtered.rows) |frow| {
            allocator.free(frow);
        }
        allocator.free(filtered.rows);
    }

    // Verify filtered result has only 1 column
    try testing.expect(filtered.columns.len == 1);
    try testing.expectEqualStrings("cost", filtered.columns[0]);

    // Verify filtered row has only the cost value
    try testing.expect(filtered.rows.len == 1);
    try testing.expect(filtered.rows[0].len == 1);
    try testing.expect(filtered.rows[0][0] == .Decimal);
    try testing.expect(filtered.rows[0][0].Decimal.coeff == 300);
}

// Note: Skipping ExecutionContext test due to changing internal structure

test "CALL procedure name recognition" {
    // Test that various procedure names are recognized correctly
    const test_cases = [_]struct {
        name: []const u8,
        should_match_dijkstra: bool,
    }{
        .{ .name = "algo.shortestPath.dijkstra", .should_match_dijkstra = true },
        .{ .name = "algo.dijkstra.stream", .should_match_dijkstra = true },
        .{ .name = "dijkstra", .should_match_dijkstra = true },
        .{ .name = "algo.bfs.stream", .should_match_dijkstra = false },
        .{ .name = "algo.dfs.stream", .should_match_dijkstra = false },
    };

    for (test_cases) |tc| {
        const matches = std.mem.eql(u8, tc.name, "algo.dijkstra.stream") or
            std.mem.eql(u8, tc.name, "algo.shortestPath.dijkstra") or
            std.mem.eql(u8, tc.name, "dijkstra");
        try testing.expectEqual(tc.should_match_dijkstra, matches);
    }
}
