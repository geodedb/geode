const std = @import("std");
const geode = @import("geode");

// CANARY: REQ=REQ-GQL-012; FEATURE="AdvancedUnionOperations"; ASPECT=TypeInference; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_TypeInference; OWNER=engine; UPDATED=2025-10-03
test "TestCANARY_REQ_GQL_012_TypeInference" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var type_inferrer = union_advanced.UnionTypeInference.init(allocator);

    // Test sample data for type inference
    const left_rows = [_][]const u8{
        "{\"name\":\"Alice\",\"age\":30}",
        "{\"name\":\"Bob\",\"age\":25}",
    };
    const right_rows = [_][]const u8{
        "{\"name\":\"Charlie\",\"age\":35.5}",
        "{\"name\":\"Diana\",\"age\":null}",
    };

    const left_cols = [_][]const u8{ "name", "age" };
    const right_cols = [_][]const u8{ "name", "age" };

    const result_types = try type_inferrer.inferUnionTypes(&left_cols, &right_cols, &left_rows, &right_rows);
    defer {
        for (result_types) |col_type| {
            allocator.free(col_type.name);
            allocator.free(col_type.unified_type);
            allocator.free(col_type.left_type);
            allocator.free(col_type.right_type);
        }
        allocator.free(result_types);
    }

    // Verify type inference results
    try std.testing.expect(result_types.len == 2);
    try std.testing.expectEqualStrings(result_types[0].unified_type, "STRING"); // name column
    try std.testing.expectEqualStrings(result_types[1].unified_type, "MIXED"); // age column (INT + DECIMAL = MIXED)
}

// CANARY: REQ=REQ-GQL-013; FEATURE="AdvancedUnionOperations"; ASPECT=IntersectOperation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_013_IntersectOperation; OWNER=engine; UPDATED=2025-10-03
test "TestCANARY_REQ_GQL_013_IntersectOperation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var set_ops = union_advanced.SetOperations.init(allocator);

    // Test INTERSECT ALL
    const left_rows = [_][]const u8{ "row1", "row2", "row1", "row3" };
    const right_rows = [_][]const u8{ "row1", "row1", "row4", "row2" };

    const intersect_all_result = try set_ops.intersect(&left_rows, &right_rows, true);
    defer allocator.free(intersect_all_result);

    try std.testing.expect(intersect_all_result.len == 3); // row1, row2, row1

    // Test INTERSECT DISTINCT
    const intersect_distinct_result = try set_ops.intersect(&left_rows, &right_rows, false);
    defer allocator.free(intersect_distinct_result);

    try std.testing.expect(intersect_distinct_result.len == 2); // row1, row2 (distinct)
}

// CANARY: REQ=REQ-GQL-014; FEATURE="AdvancedUnionOperations"; ASPECT=ExceptOperation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_014_ExceptOperation; OWNER=engine; UPDATED=2025-10-03
test "TestCANARY_REQ_GQL_014_ExceptOperation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var set_ops = union_advanced.SetOperations.init(allocator);

    // Test EXCEPT ALL
    const left_rows = [_][]const u8{ "row1", "row2", "row1", "row3" };
    const right_rows = [_][]const u8{ "row1", "row4", "row2" };

    const except_all_result = try set_ops.except(&left_rows, &right_rows, true);
    defer allocator.free(except_all_result);

    try std.testing.expect(except_all_result.len == 2); // One row1 cancelled, row3 remains, one row1 remains

    // Test EXCEPT DISTINCT
    const except_distinct_result = try set_ops.except(&left_rows, &right_rows, false);
    defer allocator.free(except_distinct_result);

    try std.testing.expect(except_distinct_result.len == 1); // Only row3 remains (distinct)
}

// CANARY: REQ=REQ-GQL-015; FEATURE="AdvancedUnionOperations"; ASPECT=OptimizationStrategy; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_015_OptimizationStrategy; OWNER=engine; UPDATED=2025-10-03
test "TestCANARY_REQ_GQL_015_OptimizationStrategy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var optimizer = union_advanced.UnionOptimizer.init(allocator);

    // Test small dataset optimization
    const small_strategy = optimizer.optimizeUnionExecution(100, 200, true, 1024 * 1024);
    try std.testing.expect(small_strategy.algorithm == .sort_dedup);

    // Test large dataset optimization
    const large_strategy = optimizer.optimizeUnionExecution(10000, 15000, true, 1024 * 1024);
    try std.testing.expect(large_strategy.algorithm == .hash_dedup);

    // Test memory constrained optimization
    const constrained_strategy = optimizer.optimizeUnionExecution(10000, 15000, true, 1024);
    try std.testing.expect(constrained_strategy.algorithm == .external_sort);

    // Test UNION ALL (no duplicates)
    const union_all_strategy = optimizer.optimizeUnionExecution(1000, 2000, false, 1024 * 1024);
    try std.testing.expect(union_all_strategy.algorithm == .concatenation);
}

// CANARY: REQ=REQ-GQL-016; FEATURE="AdvancedUnionOperations"; ASPECT=MultiWayOptimization; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_MultiWayOptimization; OWNER=engine; UPDATED=2025-10-03
test "TestCANARY_REQ_GQL_016_MultiWayOptimization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var optimizer = union_advanced.UnionOptimizer.init(allocator);

    // Test small multi-way union
    const small_branches = [_]usize{ 100, 200, 150, 300 };
    const small_strategy = optimizer.optimizeMultiWayUnion(&small_branches, 1024 * 1024);
    try std.testing.expect(small_strategy.approach == .tree_reduction);
    try std.testing.expect(small_strategy.batch_size == 4);

    // Test large multi-way union requiring streaming
    const large_branches = [_]usize{ 10000, 20000, 15000, 30000, 25000 };
    const large_strategy = optimizer.optimizeMultiWayUnion(&large_branches, 1024 * 1024);
    try std.testing.expect(large_strategy.approach == .streaming_merge);
    try std.testing.expect(large_strategy.batch_size >= 2);
}
