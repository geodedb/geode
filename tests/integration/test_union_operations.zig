const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "UNION basic operations" {
    const allocator = std.testing.allocator;

    var exec = geode.server.graph.Executor.init(allocator);
    defer exec.deinit();

    // Create test data
    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    const node1 = try graph.createNode(&.{});
    try graph.setNodeProperty(node1, "type", .{ .String = "A" });
    try graph.setNodeProperty(node1, "value", .{ .String = "1" });

    const node2 = try graph.createNode(&.{});
    try graph.setNodeProperty(node2, "type", .{ .String = "B" });
    try graph.setNodeProperty(node2, "value", .{ .String = "2" });

    const node3 = try graph.createNode(&.{});
    try graph.setNodeProperty(node3, "type", .{ .String = "A" });
    try graph.setNodeProperty(node3, "value", .{ .String = "3" });

    // Query 1: Find type A nodes
    const query1 = try geode.parse(allocator, "MATCH (n) WHERE n.type = 'A' RETURN n.value", .{});
    defer query1.deinit();

    // Query 2: Find type B nodes
    const query2 = try geode.parse(allocator, "MATCH (n) WHERE n.type = 'B' RETURN n.value", .{});
    defer query2.deinit();

    // Create UNION query
    const union_stmt = geode.ast.Statement{
        .Union = .{
            .first = query1.program.statements[0].Query,
            .distinct = true,
            .tails = &[_]geode.ast.UnionTail{
                .{
                    .op = .Union,
                    .distinct = true,
                    .query = query2.program.statements[0].Query,
                },
            },
        },
    };

    const results = try exec.executeStatement(&graph, union_stmt);
    defer allocator.free(results);

    // Should return values from both queries
    try testing.expect(results.len == 3); // "1", "2", "3"
}

test "UNION ALL with duplicates" {
    const allocator = std.testing.allocator;

    var exec = geode.server.graph.Executor.init(allocator);
    defer exec.deinit();

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create nodes with duplicate values
    const node1 = try graph.createNode(&.{});
    try graph.setNodeProperty(node1, "group", .{ .String = "X" });
    try graph.setNodeProperty(node1, "value", .{ .String = "100" });

    const node2 = try graph.createNode(&.{});
    try graph.setNodeProperty(node2, "group", .{ .String = "Y" });
    try graph.setNodeProperty(node2, "value", .{ .String = "100" }); // Same value

    const node3 = try graph.createNode(&.{});
    try graph.setNodeProperty(node3, "group", .{ .String = "X" });
    try graph.setNodeProperty(node3, "value", .{ .String = "200" });

    // Query both groups
    const query1 = try geode.parse(allocator, "MATCH (n) WHERE n.group = 'X' RETURN n.value", .{});
    defer query1.deinit();

    const query2 = try geode.parse(allocator, "MATCH (n) WHERE n.group = 'Y' RETURN n.value", .{});
    defer query2.deinit();

    // UNION ALL keeps duplicates
    const union_all = geode.ast.Statement{
        .Union = .{
            .first = query1.program.statements[0].Query,
            .distinct = false,
            .tails = &[_]geode.ast.UnionTail{
                .{
                    .op = .Union,
                    .distinct = false,
                    .query = query2.program.statements[0].Query,
                },
            },
        },
    };

    const results_all = try exec.executeStatement(&graph, union_all);
    defer allocator.free(results_all);

    // Should keep duplicates
    try testing.expect(results_all.len == 3); // "100", "200", "100"

    // UNION DISTINCT removes duplicates
    const union_distinct = geode.ast.Statement{
        .Union = .{
            .first = query1.program.statements[0].Query,
            .distinct = true,
            .tails = &[_]geode.ast.UnionTail{
                .{
                    .op = .Union,
                    .distinct = true,
                    .query = query2.program.statements[0].Query,
                },
            },
        },
    };

    const results_distinct = try exec.executeStatement(&graph, union_distinct);
    defer allocator.free(results_distinct);

    // Should remove duplicates
    try testing.expect(results_distinct.len == 2); // "100", "200"
}

test "INTERSECT operations" {
    const allocator = std.testing.allocator;

    var exec = geode.server.graph.Executor.init(allocator);
    defer exec.deinit();

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create nodes in different categories
    var i: u32 = 1;
    while (i <= 10) : (i += 1) {
        const node = try graph.createNode(&.{});
        const val_str = try std.fmt.allocPrint(allocator, "{}", .{i});
        defer allocator.free(val_str);

        try graph.setNodeProperty(node, "value", .{ .String = val_str });

        if (i % 2 == 0) {
            try graph.setNodeProperty(node, "even", .{ .String = "true" });
        }
        if (i % 3 == 0) {
            try graph.setNodeProperty(node, "div3", .{ .String = "true" });
        }
    }

    // Query 1: Even numbers
    const query1 = try geode.parse(allocator, "MATCH (n) WHERE n.even = 'true' RETURN n.value", .{});
    defer query1.deinit();

    // Query 2: Divisible by 3
    const query2 = try geode.parse(allocator, "MATCH (n) WHERE n.div3 = 'true' RETURN n.value", .{});
    defer query2.deinit();

    // INTERSECT to find numbers that are both even and divisible by 3
    const intersect = geode.ast.Statement{
        .Union = .{
            .first = query1.program.statements[0].Query,
            .distinct = true,
            .tails = &[_]geode.ast.UnionTail{
                .{
                    .op = .Intersect,
                    .distinct = true,
                    .query = query2.program.statements[0].Query,
                },
            },
        },
    };

    const results = try exec.executeStatement(&graph, intersect);
    defer allocator.free(results);

    // Should find 6 (even and divisible by 3)
    try testing.expect(results.len == 1);
    try testing.expect(std.mem.eql(u8, results[0], "6"));
}

test "EXCEPT operations" {
    const allocator = std.testing.allocator;

    var exec = geode.server.graph.Executor.init(allocator);
    defer exec.deinit();

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create employees and managers
    const employees = [_][]const u8{ "Alice", "Bob", "Charlie", "Dave", "Eve" };
    const managers = [_][]const u8{ "Bob", "Dave" };

    for (employees) |name| {
        const node = try graph.createNode(&.{});
        try graph.setNodeProperty(node, "name", .{ .String = name });
        try graph.setNodeProperty(node, "role", .{ .String = "employee" });
    }

    for (managers) |name| {
        // Find and update the node
        const nodes = try graph.getAllNodes(allocator);
        defer allocator.free(nodes);

        for (nodes) |node| {
            const node_name = graph.getNodeProperty(node, "name");
            if (node_name) |n| switch (n) {
                .String => |s| {
                    if (std.mem.eql(u8, s, name)) {
                        try graph.setNodeProperty(node, "role", .{ .String = "manager" });
                        break;
                    }
                },
                else => {},
            };
        }
    }

    // Query 1: All employees
    const query1 = try geode.parse(allocator, "MATCH (n) WHERE n.role IS NOT NULL RETURN n.name", .{});
    defer query1.deinit();

    // Query 2: Managers
    const query2 = try geode.parse(allocator, "MATCH (n) WHERE n.role = 'manager' RETURN n.name", .{});
    defer query2.deinit();

    // EXCEPT to find non-manager employees
    const except = geode.ast.Statement{
        .Union = .{
            .first = query1.program.statements[0].Query,
            .distinct = true,
            .tails = &[_]geode.ast.UnionTail{
                .{
                    .op = .Except,
                    .distinct = true,
                    .query = query2.program.statements[0].Query,
                },
            },
        },
    };

    const results = try exec.executeStatement(&graph, except);
    defer allocator.free(results);

    // Should find non-managers: Alice, Charlie, Eve
    try testing.expect(results.len == 3);
}

test "Multiple set operations chained" {
    const allocator = std.testing.allocator;

    var exec = geode.server.graph.Executor.init(allocator);
    defer exec.deinit();

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create three sets of numbers
    // Set A: 1-5
    // Set B: 3-7
    // Set C: 6-10

    var n: u32 = 1;
    while (n <= 10) : (n += 1) {
        const node = try graph.createNode(&.{});
        const val = try std.fmt.allocPrint(allocator, "{}", .{n});
        defer allocator.free(val);

        try graph.setNodeProperty(node, "value", .{ .String = val });

        if (n >= 1 and n <= 5) {
            try graph.setNodeProperty(node, "setA", .{ .String = "true" });
        }
        if (n >= 3 and n <= 7) {
            try graph.setNodeProperty(node, "setB", .{ .String = "true" });
        }
        if (n >= 6 and n <= 10) {
            try graph.setNodeProperty(node, "setC", .{ .String = "true" });
        }
    }

    // Complex query: (A UNION B) EXCEPT C
    const queryA = try geode.parse(allocator, "MATCH (n) WHERE n.setA = 'true' RETURN n.value", .{});
    defer queryA.deinit();

    const queryB = try geode.parse(allocator, "MATCH (n) WHERE n.setB = 'true' RETURN n.value", .{});
    defer queryB.deinit();

    const queryC = try geode.parse(allocator, "MATCH (n) WHERE n.setC = 'true' RETURN n.value", .{});
    defer queryC.deinit();

    // First create A UNION B
    const union_query = geode.ast.Query{
        // Simplified - would need full query structure
        .match = queryA.program.statements[0].Query.match,
        .where_clause = queryA.program.statements[0].Query.where_clause,
        .return_clause = queryA.program.statements[0].Query.return_clause,
        .order_by = null,
        .limit = null,
        .skip = null,
    };

    // Then EXCEPT C
    const complex = geode.ast.Statement{
        .Union = .{
            .first = union_query,
            .distinct = true,
            .tails = &[_]geode.ast.UnionTail{
                .{
                    .op = .Union,
                    .distinct = true,
                    .query = queryB.program.statements[0].Query,
                },
                .{
                    .op = .Except,
                    .distinct = true,
                    .query = queryC.program.statements[0].Query,
                },
            },
        },
    };

    const results = try exec.executeStatement(&graph, complex);
    defer allocator.free(results);

    // (A UNION B) = {1,2,3,4,5,6,7}
    // EXCEPT C = {6,7,8,9,10}
    // Result = {1,2,3,4,5}
    try testing.expect(results.len == 5);
}

test "UNION with ORDER BY and LIMIT" {
    const allocator = std.testing.allocator;

    var exec = geode.server.graph.Executor.init(allocator);
    defer exec.deinit();

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create products in different categories
    const products = [_]struct { name: []const u8, category: []const u8, price: i32 }{
        .{ .name = "Laptop", .category = "Electronics", .price = 1000 },
        .{ .name = "Phone", .category = "Electronics", .price = 800 },
        .{ .name = "Shirt", .category = "Clothing", .price = 50 },
        .{ .name = "Pants", .category = "Clothing", .price = 80 },
        .{ .name = "TV", .category = "Electronics", .price = 1500 },
    };

    for (products) |product| {
        const node = try graph.createNode(&.{});
        try graph.setNodeProperty(node, "name", .{ .String = product.name });
        try graph.setNodeProperty(node, "category", .{ .String = product.category });

        const price_str = try std.fmt.allocPrint(allocator, "{}", .{product.price});
        defer allocator.free(price_str);
        try graph.setNodeProperty(node, "price", .{ .String = price_str });
    }

    // Query electronics and clothing, union them, then order by price and limit
    const query =
        \\(MATCH (p) WHERE p.category = 'Electronics' RETURN p.name, p.price
        \\UNION
        \\MATCH (p) WHERE p.category = 'Clothing' RETURN p.name, p.price)
        \\ORDER BY p.price DESC
        \\LIMIT 3
    ;

    const parsed = try geode.parse(allocator, query, .{});
    defer parsed.deinit();

    const results = try exec.executeStatement(&graph, parsed.program.statements[0]);
    defer allocator.free(results);

    // Should return top 3 most expensive items across both categories
    try testing.expect(results.len == 3);
}

test "CANARY: REQ=REQ-GQL-SET-OPERATIONS" {
    // CANARY: REQ=REQ-GQL-SET-OPERATIONS; FEATURE="SetOperations"; ASPECT=Core; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SET_OPERATIONS; OWNER=team; UPDATED=2025-10-02
    const allocator = std.testing.allocator;

    var exec = geode.server.graph.Executor.init(allocator);
    defer exec.deinit();

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create test data for comprehensive set operations test
    const skills = [_]struct { person: []const u8, skill: []const u8 }{
        .{ .person = "Alice", .skill = "Python" },
        .{ .person = "Alice", .skill = "Java" },
        .{ .person = "Bob", .skill = "Python" },
        .{ .person = "Bob", .skill = "JavaScript" },
        .{ .person = "Charlie", .skill = "Java" },
        .{ .person = "Charlie", .skill = "Go" },
    };

    for (skills) |entry| {
        const node = try graph.createNode(&.{});
        try graph.setNodeProperty(node, "person", .{ .String = entry.person });
        try graph.setNodeProperty(node, "skill", .{ .String = entry.skill });
    }

    // Test all set operations

    // 1. UNION: All unique skills
    const union_query = try geode.parse(allocator,
        \\MATCH (n) WHERE n.person = 'Alice' RETURN n.skill
        \\UNION
        \\MATCH (n) WHERE n.person = 'Bob' RETURN n.skill
    , .{});
    defer union_query.deinit();

    const union_results = try exec.executeStatement(&graph, union_query.program.statements[0]);
    defer allocator.free(union_results);

    // Alice: Python, Java; Bob: Python, JavaScript
    // Union: Python, Java, JavaScript (3 unique)
    try testing.expect(union_results.len == 3);

    // 2. INTERSECT: Common skills between Alice and Bob
    const intersect_query = try geode.parse(allocator,
        \\MATCH (n) WHERE n.person = 'Alice' RETURN n.skill
        \\INTERSECT
        \\MATCH (n) WHERE n.person = 'Bob' RETURN n.skill
    , .{});
    defer intersect_query.deinit();

    const intersect_results = try exec.executeStatement(&graph, intersect_query.program.statements[0]);
    defer allocator.free(intersect_results);

    // Common: Python
    try testing.expect(intersect_results.len == 1);
    try testing.expect(std.mem.eql(u8, intersect_results[0], "Python"));

    // 3. EXCEPT: Skills Alice has but Bob doesn't
    const except_query = try geode.parse(allocator,
        \\MATCH (n) WHERE n.person = 'Alice' RETURN n.skill
        \\EXCEPT
        \\MATCH (n) WHERE n.person = 'Bob' RETURN n.skill
    , .{});
    defer except_query.deinit();

    const except_results = try exec.executeStatement(&graph, except_query.program.statements[0]);
    defer allocator.free(except_results);

    // Alice only: Java
    try testing.expect(except_results.len == 1);
    try testing.expect(std.mem.eql(u8, except_results[0], "Java"));
}
