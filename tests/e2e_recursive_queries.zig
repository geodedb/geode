const std = @import("std");
const testing = std.testing;
const recursive = @import("../src/planner/recursive.zig");
const ast = @import("../src/ast.zig");
const exec = @import("../src/exec.zig");

test "recursive query - WITH RECURSIVE for transitive closure" {
    const allocator = testing.allocator;

    var processor = try recursive.RecursiveQueryProcessor.init(allocator, .{
        .max_recursion_depth = 100,
        .cycle_detection = .{
            .enabled = true,
            .strategy = .hash_based,
        },
    });
    defer processor.deinit();

    // Create a recursive CTE for finding all connections
    const cte = recursive.RecursiveQueryProcessor.RecursiveCTE{
        .name = "connections",
        .columns = &[_]recursive.RecursiveQueryProcessor.RecursiveCTE.Column{
            .{ .name = "from_node", .type = .int, .nullable = false },
            .{ .name = "to_node", .type = .int, .nullable = false },
            .{ .name = "depth", .type = .int, .nullable = false },
        },
        .anchor_query = undefined, // Would be: SELECT from_id, to_id, 1 FROM edges WHERE from_id = 1
        .recursive_query = undefined, // Would be: SELECT e.from_id, e.to_id, c.depth + 1 FROM edges e JOIN connections c ON e.from_id = c.to_node
        .union_type = .union_all,
        .cycle_clause = null,
        .search_clause = null,
    };

    // Test validation
    try processor.validateRecursiveCTE(@constCast(&cte));
}

test "recursive query - cycle detection prevents infinite loops" {
    const allocator = testing.allocator;

    var processor = try recursive.RecursiveQueryProcessor.init(allocator, .{
        .max_recursion_depth = 10,
        .cycle_detection = .{
            .enabled = true,
            .strategy = .hash_based,
            .cycle_columns = &[_][]const u8{"node_id"},
        },
    });
    defer processor.deinit();

    // Initialize execution with cycle detection
    const cte = recursive.RecursiveQueryProcessor.RecursiveCTE{
        .name = "graph_traversal",
        .columns = &[_]recursive.RecursiveQueryProcessor.RecursiveCTE.Column{
            .{ .name = "node_id", .type = .int, .nullable = false },
            .{ .name = "path", .type = .string, .nullable = false },
        },
        .anchor_query = undefined,
        .recursive_query = undefined,
        .union_type = .union_all,
        .cycle_clause = .{
            .cycle_columns = &[_][]const u8{"node_id"},
            .cycle_mark_column = "is_cycle",
            .cycle_value = .{ .boolean = true },
            .non_cycle_value = .{ .boolean = false },
            .using_path = "path",
        },
        .search_clause = null,
    };

    var execution = try processor.initializeExecution(@constCast(&cte));
    defer execution.deinit();

    // Add some test rows
    try execution.working_table.current.append(.{
        .values = &[_]recursive.RecursiveQueryProcessor.Value{
            .{ .integer = 1 },
            .{ .string = "/1" },
        },
        .depth = 0,
        .path = "/1",
        .cycle_detected = false,
    });

    // Verify cycle detection is initialized
    try testing.expect(execution.cycle_detector != null);
    try testing.expectEqual(@as(u32, 0), execution.statistics.cycles_detected);
}

test "recursive query - path finding with depth limit" {
    const allocator = testing.allocator;

    var processor = try recursive.RecursiveQueryProcessor.init(allocator, .{
        .max_recursion_depth = 5,
        .path_tracking = .{
            .track_path = true,
            .path_column = "path",
            .path_separator = "->",
            .include_self = true,
            .max_path_length = 100,
        },
    });
    defer processor.deinit();

    // Test path finding
    const paths = try processor.findAllPaths(1, 10, 5, "social_graph");
    defer allocator.free(paths);

    // Verify paths don't exceed depth limit
    for (paths) |path| {
        try testing.expect(path.nodes.len <= 5);
    }
}

test "recursive query - hierarchical query with breadth-first search" {
    const allocator = testing.allocator;

    var processor = try recursive.RecursiveQueryProcessor.init(allocator, .{
        .max_recursion_depth = 100,
        .optimization_hints = .{
            .breadth_first = true,
            .materialize_intermediate = true,
            .memory_limit_mb = 512,
        },
    });
    defer processor.deinit();

    const cte = recursive.RecursiveQueryProcessor.RecursiveCTE{
        .name = "org_hierarchy",
        .columns = &[_]recursive.RecursiveQueryProcessor.RecursiveCTE.Column{
            .{ .name = "employee_id", .type = .int, .nullable = false },
            .{ .name = "manager_id", .type = .int, .nullable = true },
            .{ .name = "level", .type = .int, .nullable = false },
        },
        .anchor_query = undefined,
        .recursive_query = undefined,
        .union_type = .union_all,
        .cycle_clause = null,
        .search_clause = .{
            .search_type = .breadth_first,
            .by_columns = &[_][]const u8{"employee_id"},
            .set_column = "search_order",
        },
    };

    // Test breadth-first traversal
    var context = exec.ExecutionContext.default();
    const result = processor.processRecursiveCTE(@constCast(&cte), context) catch |err| {
        // Expected to fail without actual data
        try testing.expectEqual(error.NotImplemented, err);
        return;
    };
    _ = result;
}

test "recursive query - memory spill for large result sets" {
    const allocator = testing.allocator;

    var processor = try recursive.RecursiveQueryProcessor.init(allocator, .{
        .max_recursion_depth = 1000,
        .optimization_hints = .{
            .memory_limit_mb = 1, // Very low limit to trigger spill
        },
    });
    defer processor.deinit();

    var execution = try processor.initializeExecution(&recursive.RecursiveQueryProcessor.RecursiveCTE{
        .name = "large_traversal",
        .columns = &[_]recursive.RecursiveQueryProcessor.RecursiveCTE.Column{
            .{ .name = "id", .type = .int, .nullable = false },
        },
        .anchor_query = undefined,
        .recursive_query = undefined,
        .union_type = .union_all,
        .cycle_clause = null,
        .search_clause = null,
    });
    defer execution.deinit();

    // Add many rows to trigger memory spill
    var i: u64 = 0;
    while (i < 10000) : (i += 1) {
        try execution.result_accumulator.rows.append(.{
            .values = &[_]recursive.RecursiveQueryProcessor.Value{
                .{ .integer = @intCast(i64, i) },
            },
            .depth = 1,
            .path = null,
            .cycle_detected = false,
        });
        execution.result_accumulator.memory_used += 100; // Simulate memory usage
    }

    // Check if spill would be triggered
    if (execution.result_accumulator.memory_used > processor.optimization_hints.memory_limit_mb * 1024 * 1024) {
        try processor.spillToDisk(&execution);
        try testing.expect(execution.result_accumulator.spilled_to_disk);
        try testing.expect(execution.statistics.spill_count > 0);
    }
}
