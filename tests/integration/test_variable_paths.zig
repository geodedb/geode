const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "variable-length path basic operations" {
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create a chain: A -> B -> C -> D -> E
    const a = try graph.createNode(&.{});
    try graph.setNodeProperty(a, "name", .{ .String = "A" });

    const b = try graph.createNode(&.{});
    try graph.setNodeProperty(b, "name", .{ .String = "B" });

    const c = try graph.createNode(&.{});
    try graph.setNodeProperty(c, "name", .{ .String = "C" });

    const d = try graph.createNode(&.{});
    try graph.setNodeProperty(d, "name", .{ .String = "D" });

    const e = try graph.createNode(&.{});
    try graph.setNodeProperty(e, "name", .{ .String = "E" });

    _ = try graph.createEdge(a, b, "REL");
    _ = try graph.createEdge(b, c, "REL");
    _ = try graph.createEdge(c, d, "REL");
    _ = try graph.createEdge(d, e, "REL");

    // Test exact length paths
    const paths_2 = try graph.findPaths(a, c, .{ .exact_length = 2 });
    defer graph.freePaths(paths_2);
    try testing.expect(paths_2.len == 1);

    // Test range paths
    const paths_range = try graph.findPaths(a, e, .{ .min_length = 2, .max_length = 5 });
    defer graph.freePaths(paths_range);
    try testing.expect(paths_range.len > 0);
}

test "variable-length path with cycles" {
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create a cycle: A -> B -> C -> A
    const a = try graph.createNode(&.{});
    const b = try graph.createNode(&.{});
    const c = try graph.createNode(&.{});

    _ = try graph.createEdge(a, b, "REL");
    _ = try graph.createEdge(b, c, "REL");
    _ = try graph.createEdge(c, a, "REL");

    // Test cycle detection
    const cycles = try graph.findPaths(a, a, .{ .min_length = 1, .max_length = 10 });
    defer graph.freePaths(cycles);

    // Should find multiple cycles of different lengths
    try testing.expect(cycles.len > 0);

    // Verify shortest cycle has length 3
    var min_length: usize = std.math.maxInt(usize);
    for (cycles) |path| {
        if (path.edges.len < min_length) {
            min_length = path.edges.len;
        }
    }
    try testing.expect(min_length == 3);
}

test "shortest path algorithms" {
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create a graph with multiple paths
    // A -> B -> E
    // A -> C -> D -> E
    const a = try graph.createNode(&.{});
    const b = try graph.createNode(&.{});
    const c = try graph.createNode(&.{});
    const d = try graph.createNode(&.{});
    const e = try graph.createNode(&.{});

    _ = try graph.createEdge(a, b, "REL");
    _ = try graph.createEdge(b, e, "REL");
    _ = try graph.createEdge(a, c, "REL");
    _ = try graph.createEdge(c, d, "REL");
    _ = try graph.createEdge(d, e, "REL");

    // Find shortest path
    const shortest = try graph.shortestPath(a, e);
    defer if (shortest) |p| graph.freePath(p);

    try testing.expect(shortest != null);
    try testing.expect(shortest.?.edges.len == 2); // A -> B -> E

    // Find all shortest paths
    const all_shortest = try graph.allShortestPaths(a, e);
    defer graph.freePaths(all_shortest);

    try testing.expect(all_shortest.len == 1); // Only one path of length 2
}

test "bidirectional variable paths" {
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create bidirectional edges
    const a = try graph.createNode(&.{});
    const b = try graph.createNode(&.{});
    const c = try graph.createNode(&.{});

    _ = try graph.createEdge(a, b, "REL");
    _ = try graph.createEdge(b, a, "REL"); // Reverse edge
    _ = try graph.createEdge(b, c, "REL");
    _ = try graph.createEdge(c, b, "REL"); // Reverse edge

    // Find paths considering both directions
    const paths = try graph.findPathsBidirectional(a, c, .{ .max_length = 3 });
    defer graph.freePaths(paths);

    // Should find multiple paths including those using reverse edges
    try testing.expect(paths.len > 1);
}

test "path with property filters" {
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create nodes with properties
    const a = try graph.createNode(&.{});
    try graph.setNodeProperty(a, "type", .{ .String = "start" });

    const b = try graph.createNode(&.{});
    try graph.setNodeProperty(b, "type", .{ .String = "intermediate" });
    try graph.setNodeProperty(b, "weight", .{ .String = "5" });

    const c = try graph.createNode(&.{});
    try graph.setNodeProperty(c, "type", .{ .String = "intermediate" });
    try graph.setNodeProperty(c, "weight", .{ .String = "10" });

    const d = try graph.createNode(&.{});
    try graph.setNodeProperty(d, "type", .{ .String = "end" });

    const e1 = try graph.createEdge(a, b, "REL");
    try graph.setEdgeProperty(e1, "cost", .{ .String = "100" });

    const e2 = try graph.createEdge(b, c, "REL");
    try graph.setEdgeProperty(e2, "cost", .{ .String = "200" });

    const e3 = try graph.createEdge(c, d, "REL");
    try graph.setEdgeProperty(e3, "cost", .{ .String = "150" });

    // Find paths with node filters
    const filter = geode.graph_store.PathFilter{
        .node_predicate = struct {
            fn filter(node: *const geode.graph_store.Node) bool {
                const weight = node.properties.get("weight") orelse return true;
                switch (weight) {
                    .String => |s| {
                        const val = std.fmt.parseInt(i32, s, 10) catch return false;
                        return val <= 10;
                    },
                    else => return true,
                }
            }
        }.filter,
    };

    const filtered_paths = try graph.findPathsFiltered(a, d, .{ .max_length = 5 }, filter);
    defer graph.freePaths(filtered_paths);

    // Should find paths that respect the filter
    try testing.expect(filtered_paths.len > 0);
}

test "k-shortest paths" {
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create graph with multiple paths of different lengths
    const nodes = try allocator.alloc(u64, 6);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = try graph.createNode(&.{});
        const name = try std.fmt.allocPrint(allocator, "N{}", .{i});
        defer allocator.free(name);
        try graph.setNodeProperty(node.*, "name", .{ .String = name });
    }

    // Create various paths from nodes[0] to nodes[5]
    _ = try graph.createEdge(nodes[0], nodes[1], "REL");
    _ = try graph.createEdge(nodes[1], nodes[5], "REL"); // Length 2

    _ = try graph.createEdge(nodes[0], nodes[2], "REL");
    _ = try graph.createEdge(nodes[2], nodes[3], "REL");
    _ = try graph.createEdge(nodes[3], nodes[5], "REL"); // Length 3

    _ = try graph.createEdge(nodes[0], nodes[4], "REL");
    _ = try graph.createEdge(nodes[4], nodes[5], "REL"); // Length 2

    // Find k-shortest paths
    const k_paths = try graph.kShortestPaths(nodes[0], nodes[5], 3);
    defer graph.freePaths(k_paths);

    // Should find 3 paths
    try testing.expect(k_paths.len == 3);

    // Verify they're sorted by length
    for (1..k_paths.len) |i| {
        try testing.expect(k_paths[i].edges.len >= k_paths[i - 1].edges.len);
    }
}

test "path expansion with depth limit" {
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create a deep tree structure
    const root = try graph.createNode(&.{});
    var current_level = std.ArrayList(u64).init(allocator);
    defer current_level.deinit();

    try current_level.append(root);

    const depth = 10;
    const branching = 3;

    var level: u32 = 0;
    while (level < depth) : (level += 1) {
        var next_level = std.ArrayList(u64).init(allocator);

        for (current_level.items) |parent| {
            var i: u32 = 0;
            while (i < branching) : (i += 1) {
                const child = try graph.createNode(&.{});
                _ = try graph.createEdge(parent, child, "REL");
                try next_level.append(child);
            }
        }

        current_level.deinit();
        current_level = next_level;
    }

    // Test depth-limited expansion
    const shallow_expansion = try graph.expandFromNode(root, .{ .max_depth = 3 });
    defer allocator.free(shallow_expansion);

    const deep_expansion = try graph.expandFromNode(root, .{ .max_depth = 5 });
    defer allocator.free(deep_expansion);

    // Deeper expansion should find more nodes
    try testing.expect(deep_expansion.len > shallow_expansion.len);

    // Calculate expected nodes at depth 3
    var expected_at_3: usize = 1; // root
    var d: u32 = 1;
    while (d <= 3) : (d += 1) {
        expected_at_3 += std.math.pow(usize, branching, d);
    }

    try testing.expect(shallow_expansion.len == expected_at_3);
}

test "CANARY: REQ=REQ-GQL-VARIABLE-PATHS" {
    // CANARY: REQ=REQ-GQL-VARIABLE-PATHS; FEATURE="VariablePaths"; ASPECT=Core; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_VARIABLE_PATHS; OWNER=team; UPDATED=2025-10-02
    const allocator = std.testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create test graph for variable paths
    const alice = try graph.createNode(&.{});
    try graph.setNodeProperty(alice, "name", .{ .String = "Alice" });

    const bob = try graph.createNode(&.{});
    try graph.setNodeProperty(bob, "name", .{ .String = "Bob" });

    const charlie = try graph.createNode(&.{});
    try graph.setNodeProperty(charlie, "name", .{ .String = "Charlie" });

    const dave = try graph.createNode(&.{});
    try graph.setNodeProperty(dave, "name", .{ .String = "Dave" });

    // Create relationships
    _ = try graph.createEdge(alice, bob, "REL");
    _ = try graph.createEdge(bob, charlie, "REL");
    _ = try graph.createEdge(charlie, dave, "REL");
    _ = try graph.createEdge(alice, dave, "REL"); // Direct path

    // Test different variable path patterns

    // Any length (*)
    const any_paths = try graph.findPaths(alice, dave, .{});
    defer graph.freePaths(any_paths);
    try testing.expect(any_paths.len >= 2); // At least direct and indirect

    // Exact length (*2)
    const exact_2 = try graph.findPaths(alice, charlie, .{ .exact_length = 2 });
    defer graph.freePaths(exact_2);
    try testing.expect(exact_2.len == 1); // Alice -> Bob -> Charlie

    // Range (*1..3)
    const range_paths = try graph.findPaths(alice, dave, .{ .min_length = 1, .max_length = 3 });
    defer graph.freePaths(range_paths);
    try testing.expect(range_paths.len == 2); // Direct (1) and via Bob-Charlie (3)

    // Up to (*..2)
    const upto_paths = try graph.findPaths(alice, charlie, .{ .max_length = 2 });
    defer graph.freePaths(upto_paths);
    try testing.expect(upto_paths.len == 1);

    // At least (*2..)
    const atleast_paths = try graph.findPaths(alice, dave, .{ .min_length = 2 });
    defer graph.freePaths(atleast_paths);
    try testing.expect(atleast_paths.len == 1); // Only the 3-hop path
}
