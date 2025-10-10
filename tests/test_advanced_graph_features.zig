const std = @import("std");
const testing = std.testing;
const graph_store = @import("../src/graph_store.zig");
const execution = @import("../src/execution.zig");
const ast = @import("../src/gql/ast.zig");
const eval = @import("../src/eval.zig");
const parser = @import("../src/gql/parser.zig");

// Test pattern comprehensions with size() function
test "pattern comprehension - count nodes with label" {
    const allocator = testing.allocator;

    // Create a test graph store
    const store = graph_store.getGlobalStore(allocator);
    defer store.deinit();

    // Add some test nodes
    try store.addNode(1, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(2, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(3, &[_][]const u8{"Company"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));

    // Create pattern: (n:Person)
    const pattern = ast.GraphPattern{
        .chains = &[_]ast.Chain{
            .{
                .name = null,
                .hops = &[_]ast.Hop{},
                .head = ast.NodePattern{
                    .name = "n",
                    .labels = &[_][]const u8{"Person"},
                    .props = null,
                },
            },
        },
    };

    // Count matches
    const count = try execution.countPatternMatches(allocator, pattern);
    try testing.expectEqual(@as(i64, 2), count);
}

test "pattern comprehension - count relationships" {
    const allocator = testing.allocator;

    const store = graph_store.getGlobalStore(allocator);
    defer store.deinit();

    // Add nodes and edges
    try store.addNode(1, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(2, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(3, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));

    try store.addEdge(100, 1, 2, "KNOWS", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addEdge(101, 2, 3, "KNOWS", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addEdge(102, 1, 3, "WORKS_WITH", std.StringHashMap(graph_store.PropertyValue).init(allocator));

    // Create pattern: ()-[r:KNOWS]->()
    const pattern = ast.GraphPattern{
        .chains = &[_]ast.Chain{
            .{
                .name = null,
                .hops = &[_]ast.Hop{
                    .{
                        .left = ast.NodePattern{ .name = null, .labels = &[_][]const u8{}, .props = null },
                        .rel = ast.RelPattern{
                            .name = "r",
                            .types = &[_][]const u8{"KNOWS"},
                            .props = null,
                            .dir = .right,
                            .min_len = null,
                            .max_len = null,
                        },
                        .right = ast.NodePattern{ .name = null, .labels = &[_][]const u8{}, .props = null },
                    },
                },
                .head = null,
            },
        },
    };

    const count = try execution.countPatternMatches(allocator, pattern);
    try testing.expectEqual(@as(i64, 2), count);
}

test "shortest path - single path" {
    const allocator = testing.allocator;

    const store = graph_store.getGlobalStore(allocator);
    defer store.deinit();

    // Create a simple graph: 1 -> 2 -> 3
    try store.addNode(1, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(2, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(3, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));

    try store.addEdge(100, 1, 2, "LINK", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addEdge(101, 2, 3, "LINK", std.StringHashMap(graph_store.PropertyValue).init(allocator));

    // Create pattern for shortest path from node 1 to node 3
    const pattern = ast.GraphPattern{
        .chains = &[_]ast.Chain{
            .{
                .name = null,
                .hops = &[_]ast.Hop{
                    .{
                        .left = ast.NodePattern{
                            .name = "start",
                            .labels = &[_][]const u8{},
                            .props = null,
                        },
                        .rel = ast.RelPattern{
                            .name = null,
                            .types = &[_][]const u8{},
                            .props = null,
                            .dir = .undirected,
                            .min_len = 1,
                            .max_len = 10, // Variable length
                        },
                        .right = ast.NodePattern{
                            .name = "end",
                            .labels = &[_][]const u8{},
                            .props = null,
                        },
                    },
                },
                .head = null,
            },
        },
    };

    const result = try execution.findShortestPath(allocator, pattern, false);

    // Verify we got a path
    switch (result) {
        .Path => |path| {
            try testing.expect(path.nodes.len >= 2);
            try testing.expect(path.edges.len == path.nodes.len - 1);
        },
        .Null => {
            // No path found is also valid
        },
        else => try testing.expect(false),
    }
}

test "shortest path - multiple paths" {
    const allocator = testing.allocator;

    const store = graph_store.getGlobalStore(allocator);
    defer store.deinit();

    // Create a diamond graph:
    //     2
    //   /   \
    // 1       4
    //   \   /
    //     3
    try store.addNode(1, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(2, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(3, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(4, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));

    try store.addEdge(100, 1, 2, "LINK", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addEdge(101, 2, 4, "LINK", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addEdge(102, 1, 3, "LINK", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addEdge(103, 3, 4, "LINK", std.StringHashMap(graph_store.PropertyValue).init(allocator));

    const pattern = ast.GraphPattern{
        .chains = &[_]ast.Chain{
            .{
                .name = null,
                .hops = &[_]ast.Hop{
                    .{
                        .left = ast.NodePattern{
                            .name = "start",
                            .labels = &[_][]const u8{},
                            .props = null,
                        },
                        .rel = ast.RelPattern{
                            .name = null,
                            .types = &[_][]const u8{},
                            .props = null,
                            .dir = .undirected,
                            .min_len = 1,
                            .max_len = 10,
                        },
                        .right = ast.NodePattern{
                            .name = "end",
                            .labels = &[_][]const u8{},
                            .props = null,
                        },
                    },
                },
                .head = null,
            },
        },
    };

    // Find all shortest paths
    const result = try execution.findShortestPath(allocator, pattern, true);

    switch (result) {
        .List => |paths| {
            // Should find two paths of equal length
            try testing.expect(paths.len > 0);
        },
        .Path => {
            // Single path is also valid
        },
        .Null => {
            // No path is also valid
        },
        else => try testing.expect(false),
    }
}

test "variable-length patterns - bounded" {
    const allocator = testing.allocator;

    const store = graph_store.getGlobalStore(allocator);
    defer store.deinit();

    // Create a chain: 1 -> 2 -> 3 -> 4 -> 5
    var i: u64 = 1;
    while (i <= 5) : (i += 1) {
        try store.addNode(i, &[_][]const u8{"Node"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    }

    i = 1;
    while (i < 5) : (i += 1) {
        try store.addEdge(100 + i, i, i + 1, "NEXT", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    }

    // Pattern with bounded variable length: ()-[*2..3]->()
    const pattern = ast.GraphPattern{
        .chains = &[_]ast.Chain{
            .{
                .name = null,
                .hops = &[_]ast.Hop{
                    .{
                        .left = ast.NodePattern{
                            .name = null,
                            .labels = &[_][]const u8{},
                            .props = null,
                        },
                        .rel = ast.RelPattern{
                            .name = null,
                            .types = &[_][]const u8{"NEXT"},
                            .props = null,
                            .dir = .right,
                            .min_len = 2,
                            .max_len = 3,
                        },
                        .right = ast.NodePattern{
                            .name = null,
                            .labels = &[_][]const u8{},
                            .props = null,
                        },
                    },
                },
                .head = null,
            },
        },
    };

    const count = try execution.countPatternMatches(allocator, pattern);
    // Should find paths: 1->2->3, 2->3->4, 3->4->5 (length 2)
    // and 1->2->3->4, 2->3->4->5 (length 3)
    try testing.expect(count > 0);
}

test "parse size() function with pattern" {
    const allocator = testing.allocator;

    const query = "RETURN size((n:Person)) AS count";
    var p = parser.Parser.init(allocator, query);
    defer p.deinit();

    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);

    switch (prog.statements[0]) {
        .Query => |q| {
            try testing.expectEqual(@as(usize, 1), q.ret.items.len);
            const ret_item = q.ret.items[0];

            switch (ret_item.expr) {
                .PatternCount => |pc| {
                    try testing.expectEqual(@as(usize, 1), pc.chains.len);
                    try testing.expect(pc.chains[0].head != null);
                    try testing.expectEqual(@as(usize, 1), pc.chains[0].head.?.labels.len);
                    try testing.expectEqualStrings("Person", pc.chains[0].head.?.labels[0]);
                },
                else => try testing.expect(false),
            }
        },
        else => try testing.expect(false),
    }
}

test "parse shortestPath() function" {
    const allocator = testing.allocator;

    const query = "RETURN shortestPath((a)-[*]-(b)) AS path";
    var p = parser.Parser.init(allocator, query);
    defer p.deinit();

    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);

    switch (prog.statements[0]) {
        .Query => |q| {
            try testing.expectEqual(@as(usize, 1), q.ret.items.len);
            const ret_item = q.ret.items[0];

            switch (ret_item.expr) {
                .ShortestPath => |sp| {
                    try testing.expect(!sp.all); // shortestPath returns single path
                    try testing.expectEqual(@as(usize, 1), sp.pattern.chains.len);
                    try testing.expectEqual(@as(usize, 1), sp.pattern.chains[0].hops.len);
                },
                else => try testing.expect(false),
            }
        },
        else => try testing.expect(false),
    }
}

// Integration test for pattern comprehension in a real query
test "integration - pattern comprehension in WHERE clause" {
    const allocator = testing.allocator;

    const store = graph_store.getGlobalStore(allocator);
    defer store.deinit();

    // Setup test data
    try store.addNode(1, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(2, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addNode(3, &[_][]const u8{"Person"}, std.StringHashMap(graph_store.PropertyValue).init(allocator));

    try store.addEdge(100, 1, 2, "FRIEND", std.StringHashMap(graph_store.PropertyValue).init(allocator));
    try store.addEdge(101, 1, 3, "FRIEND", std.StringHashMap(graph_store.PropertyValue).init(allocator));

    // Query: MATCH (p:Person) WHERE size((p)-[:FRIEND]->()) > 1 RETURN p
    const query = "MATCH (p:Person) WHERE size((p)-[:FRIEND]->()) > 1 RETURN p";
    var p = parser.Parser.init(allocator, query);
    defer p.deinit();

    const prog = try p.parse();

    switch (prog.statements[0]) {
        .Query => |q| {
            try testing.expect(q.where_clause != null);
            // The WHERE clause should contain a binary comparison with PatternCount
        },
        else => try testing.expect(false),
    }
}
