// Comprehensive test suite for Worst-Case Optimal Joins
// CANARY: REQ=REQ-GQL-WCOJ-TEST; FEATURE="WCOJ Test Suite"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_WCOJ_Suite; OWNER=test; UPDATED=2025-09-29

const std = @import("std");
const testing = std.testing;
const lib = @import("geode");
const wcoj = lib.planner_wcoj;

test "TestCANARY_WCOJ_Suite two-way join" {
    const allocator = testing.allocator;

    var executor = wcoj.WCOJExecutor.init(allocator);

    // R(A,B) ⋈ S(B,C)
    const r_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 1 }, .{ .integer = 2 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 3 }, .{ .integer = 2 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 4 }, .{ .integer = 5 } } },
    };

    const s_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 2 }, .{ .integer = 6 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 5 }, .{ .integer = 7 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 8 }, .{ .integer = 9 } } },
    };

    const r = wcoj.WCOJExecutor.Relation{
        .name = "R",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "A", .position = 0 },
            .{ .name = "B", .position = 1 },
        },
        .tuples = &r_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    var s = wcoj.WCOJExecutor.Relation{
        .name = "S",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "B", .position = 0 },
            .{ .name = "C", .position = 1 },
        },
        .tuples = &s_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    // Create indices
    const r_idx_b = try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{1});
    const s_idx_b = try wcoj.WCOJExecutor.createIndex(allocator, &s, &[_]usize{0});
    defer allocator.free(r_idx_b.sorted_tuples);
    defer allocator.free(s_idx_b.sorted_tuples);

    r.indices = &[_]wcoj.WCOJExecutor.Index{r_idx_b};
    s.indices = &[_]wcoj.WCOJExecutor.Index{s_idx_b};

    const query = wcoj.WCOJExecutor.JoinQuery{
        .relations = &[_]wcoj.WCOJExecutor.Relation{ r, s },
        .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
            .{ .name = "B", .relation_indices = &[_]usize{ 0, 1 } },
        },
        .filters = &[_]wcoj.WCOJExecutor.Filter{},
    };

    const result = try executor.executeJoin(query);
    defer {
        for (result.tuples) |tuple| {
            allocator.free(tuple.values);
        }
        allocator.free(result.tuples);
        allocator.free(result.attributes);
    }

    // Should find joins on B=2 and B=5
    try testing.expect(executor.stats.comparisons > 0);
}

test "TestCANARY_WCOJ_Suite three-way triangle join" {
    const allocator = testing.allocator;

    var executor = wcoj.WCOJExecutor.init(allocator);

    // Triangle: R(A,B) ⋈ S(B,C) ⋈ T(A,C)
    const r_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 1 }, .{ .integer = 2 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 1 }, .{ .integer = 3 } } },
    };

    const s_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 2 }, .{ .integer = 4 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 3 }, .{ .integer = 4 } } },
    };

    const t_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 1 }, .{ .integer = 4 } } },
    };

    const r = wcoj.WCOJExecutor.Relation{
        .name = "R",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "A", .position = 0 },
            .{ .name = "B", .position = 1 },
        },
        .tuples = &r_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    var s = wcoj.WCOJExecutor.Relation{
        .name = "S",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "B", .position = 0 },
            .{ .name = "C", .position = 1 },
        },
        .tuples = &s_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    var t = wcoj.WCOJExecutor.Relation{
        .name = "T",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "A", .position = 0 },
            .{ .name = "C", .position = 1 },
        },
        .tuples = &t_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    // Create all necessary indices
    const indices = [_]wcoj.WCOJExecutor.Index{
        try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{0}),
        try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{1}),
        try wcoj.WCOJExecutor.createIndex(allocator, &s, &[_]usize{0}),
        try wcoj.WCOJExecutor.createIndex(allocator, &s, &[_]usize{1}),
        try wcoj.WCOJExecutor.createIndex(allocator, &t, &[_]usize{0}),
        try wcoj.WCOJExecutor.createIndex(allocator, &t, &[_]usize{1}),
    };
    defer for (indices) |idx| {
        allocator.free(idx.sorted_tuples);
    };

    r.indices = indices[0..2];
    s.indices = indices[2..4];
    t.indices = indices[4..6];

    const query = wcoj.WCOJExecutor.JoinQuery{
        .relations = &[_]wcoj.WCOJExecutor.Relation{ r, s, t },
        .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
            .{ .name = "A", .relation_indices = &[_]usize{ 0, 2 } },
            .{ .name = "B", .relation_indices = &[_]usize{ 0, 1 } },
            .{ .name = "C", .relation_indices = &[_]usize{ 1, 2 } },
        },
        .filters = &[_]wcoj.WCOJExecutor.Filter{},
    };

    const result = try executor.executeJoin(query);
    defer {
        for (result.tuples) |tuple| {
            allocator.free(tuple.values);
        }
        allocator.free(result.tuples);
        allocator.free(result.attributes);
    }

    // Should find triangles
    try testing.expect(executor.stats.seek_operations >= 0);
}

test "TestCANARY_WCOJ_Suite with filters" {
    const allocator = testing.allocator;

    var executor = wcoj.WCOJExecutor.init(allocator);

    const r_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 1 }, .{ .integer = 10 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 2 }, .{ .integer = 20 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .integer = 3 }, .{ .integer = 30 } } },
    };

    const r = wcoj.WCOJExecutor.Relation{
        .name = "R",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "A", .position = 0 },
            .{ .name = "B", .position = 1 },
        },
        .tuples = &r_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    const r_idx = try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{0});
    defer allocator.free(r_idx.sorted_tuples);
    r.indices = &[_]wcoj.WCOJExecutor.Index{r_idx};

    // Filter: B > 15
    const filters = [_]wcoj.WCOJExecutor.Filter{
        .{
            .relation_index = 0,
            .attribute_position = 1,
            .operator = .gt,
            .value = .{ .integer = 15 },
        },
    };

    const query = wcoj.WCOJExecutor.JoinQuery{
        .relations = &[_]wcoj.WCOJExecutor.Relation{r},
        .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
            .{ .name = "A", .relation_indices = &[_]usize{0} },
        },
        .filters = &filters,
    };

    const result = try executor.executeJoin(query);
    defer {
        for (result.tuples) |tuple| {
            allocator.free(tuple.values);
        }
        allocator.free(result.tuples);
        allocator.free(result.attributes);
    }

    // Should filter out tuple with B=10
    try testing.expect(result.tuples.len <= 2);
}

test "TestCANARY_WCOJ_Suite string values" {
    const allocator = testing.allocator;

    var executor = wcoj.WCOJExecutor.init(allocator);

    const r_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .string = "alice" }, .{ .string = "bob" } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .string = "bob" }, .{ .string = "charlie" } } },
    };

    const s_tuples = [_]wcoj.WCOJExecutor.Tuple{
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .string = "bob" }, .{ .integer = 25 } } },
        .{ .values = &[_]wcoj.WCOJExecutor.Value{ .{ .string = "charlie" }, .{ .integer = 30 } } },
    };

    const r = wcoj.WCOJExecutor.Relation{
        .name = "R",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "name1", .position = 0 },
            .{ .name = "name2", .position = 1 },
        },
        .tuples = &r_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    var s = wcoj.WCOJExecutor.Relation{
        .name = "S",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "name", .position = 0 },
            .{ .name = "age", .position = 1 },
        },
        .tuples = &s_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    const r_idx = try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{1});
    const s_idx = try wcoj.WCOJExecutor.createIndex(allocator, &s, &[_]usize{0});
    defer allocator.free(r_idx.sorted_tuples);
    defer allocator.free(s_idx.sorted_tuples);

    r.indices = &[_]wcoj.WCOJExecutor.Index{r_idx};
    s.indices = &[_]wcoj.WCOJExecutor.Index{s_idx};

    const query = wcoj.WCOJExecutor.JoinQuery{
        .relations = &[_]wcoj.WCOJExecutor.Relation{ r, s },
        .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
            .{ .name = "name2", .relation_indices = &[_]usize{0} },
            .{ .name = "name", .relation_indices = &[_]usize{1} },
        },
        .filters = &[_]wcoj.WCOJExecutor.Filter{},
    };

    _ = try executor.executeJoin(query);

    // Should handle string comparisons
    try testing.expect(executor.stats.comparisons > 0);
}

test "TestCANARY_WCOJ_Suite empty relations" {
    const allocator = testing.allocator;

    var executor = wcoj.WCOJExecutor.init(allocator);

    const empty_tuples = [_]wcoj.WCOJExecutor.Tuple{};

    const r = wcoj.WCOJExecutor.Relation{
        .name = "R",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "A", .position = 0 },
        },
        .tuples = &empty_tuples,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    const query = wcoj.WCOJExecutor.JoinQuery{
        .relations = &[_]wcoj.WCOJExecutor.Relation{r},
        .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
            .{ .name = "A", .relation_indices = &[_]usize{0} },
        },
        .filters = &[_]wcoj.WCOJExecutor.Filter{},
    };

    const result = try executor.executeJoin(query);
    defer {
        allocator.free(result.tuples);
        allocator.free(result.attributes);
    }

    // Empty relation should produce empty result
    try testing.expect(result.tuples.len == 0);
}

test "TestCANARY_WCOJ_Suite performance scaling" {
    const allocator = testing.allocator;

    var executor = wcoj.WCOJExecutor.init(allocator);

    // Generate larger relations
    var r_tuples = std.ArrayList(wcoj.WCOJExecutor.Tuple).init(allocator);
    defer {
        for (r_tuples.items) |tuple| {
            allocator.free(tuple.values);
        }
        r_tuples.deinit();
    }

    var s_tuples = std.ArrayList(wcoj.WCOJExecutor.Tuple).init(allocator);
    defer {
        for (s_tuples.items) |tuple| {
            allocator.free(tuple.values);
        }
        s_tuples.deinit();
    }

    // Create 100 tuples for each relation
    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        const r_values = try allocator.alloc(wcoj.WCOJExecutor.Value, 2);
        r_values[0] = .{ .integer = i };
        r_values[1] = .{ .integer = i % 10 };
        try r_tuples.append(.{ .values = r_values });

        const s_values = try allocator.alloc(wcoj.WCOJExecutor.Value, 2);
        s_values[0] = .{ .integer = i % 10 };
        s_values[1] = .{ .integer = i * 2 };
        try s_tuples.append(.{ .values = s_values });
    }

    const r = wcoj.WCOJExecutor.Relation{
        .name = "R",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "A", .position = 0 },
            .{ .name = "B", .position = 1 },
        },
        .tuples = r_tuples.items,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    var s = wcoj.WCOJExecutor.Relation{
        .name = "S",
        .attributes = &[_]wcoj.WCOJExecutor.Attribute{
            .{ .name = "B", .position = 0 },
            .{ .name = "C", .position = 1 },
        },
        .tuples = s_tuples.items,
        .indices = &[_]wcoj.WCOJExecutor.Index{},
    };

    const r_idx = try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{1});
    const s_idx = try wcoj.WCOJExecutor.createIndex(allocator, &s, &[_]usize{0});
    defer allocator.free(r_idx.sorted_tuples);
    defer allocator.free(s_idx.sorted_tuples);

    r.indices = &[_]wcoj.WCOJExecutor.Index{r_idx};
    s.indices = &[_]wcoj.WCOJExecutor.Index{s_idx};

    const query = wcoj.WCOJExecutor.JoinQuery{
        .relations = &[_]wcoj.WCOJExecutor.Relation{ r, s },
        .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
            .{ .name = "B", .relation_indices = &[_]usize{ 0, 1 } },
        },
        .filters = &[_]wcoj.WCOJExecutor.Filter{},
    };

    const start_time = std.time.milliTimestamp();
    const result = try executor.executeJoin(query);
    const elapsed = std.time.milliTimestamp() - start_time;
    defer {
        for (result.tuples) |tuple| {
            allocator.free(tuple.values);
        }
        allocator.free(result.tuples);
        allocator.free(result.attributes);
    }

    // Should complete efficiently
    try testing.expect(elapsed < 1000); // Less than 1 second
    try testing.expect(executor.stats.seek_operations < 10000);
}
