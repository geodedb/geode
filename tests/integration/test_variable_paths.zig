const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "variable-length path basic operations" {
    const allocator = std.testing.allocator;

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create a chain: A -> B -> C -> D -> E
    const a = try graph.addNode();
    try graph.setNodeProperty(a, "name", "A");

    const b = try graph.addNode();
    try graph.setNodeProperty(b, "name", "B");

    const c = try graph.addNode();
    try graph.setNodeProperty(c, "name", "C");

    const d = try graph.addNode();
    try graph.setNodeProperty(d, "name", "D");

    const e = try graph.addNode();
    try graph.setNodeProperty(e, "name", "E");

    _ = try graph.addEdge(a, b);
    _ = try graph.addEdge(b, c);
    _ = try graph.addEdge(c, d);
    _ = try graph.addEdge(d, e);

    // Test exact length paths
    const paths_2 = try graph.findPaths(a, c, .{ .exact_length = 2 });
    defer allocator.free(paths_2);
    try testing.expect(paths_2.len == 1);

    // Test range paths
    const paths_range = try graph.findPaths(a, e, .{ .min_length = 2, .max_length = 5 });
    defer allocator.free(paths_range);
    try testing.expect(paths_range.len > 0);
}

test "variable-length path with cycles" {
    const allocator = std.testing.allocator;

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create a cycle: A -> B -> C -> A
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    _ = try graph.addEdge(a, b);
    _ = try graph.addEdge(b, c);
    _ = try graph.addEdge(c, a);

    // Test cycle detection
    const cycles = try graph.findPaths(a, a, .{ .min_length = 1, .max_length = 10 });
    defer allocator.free(cycles);

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

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create a graph with multiple paths
    // A -> B -> E
    // A -> C -> D -> E
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    const d = try graph.addNode();
    const e = try graph.addNode();

    _ = try graph.addEdge(a, b);
    _ = try graph.addEdge(b, e);
    _ = try graph.addEdge(a, c);
    _ = try graph.addEdge(c, d);
    _ = try graph.addEdge(d, e);

    // Find shortest path
    const shortest = try graph.shortestPath(a, e);
    defer if (shortest) |p| allocator.free(p.edges);

    try testing.expect(shortest != null);
    try testing.expect(shortest.?.edges.len == 2); // A -> B -> E

    // Find all shortest paths
    const all_shortest = try graph.allShortestPaths(a, e);
    defer allocator.free(all_shortest);

    try testing.expect(all_shortest.len == 1); // Only one path of length 2
}

test "bidirectional variable paths" {
    const allocator = std.testing.allocator;

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create bidirectional edges
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    _ = try graph.addEdge(a, b);
    _ = try graph.addEdge(b, a); // Reverse edge
    _ = try graph.addEdge(b, c);
    _ = try graph.addEdge(c, b); // Reverse edge

    // Find paths considering both directions
    const paths = try graph.findPathsBidirectional(a, c, .{ .max_length = 3 });
    defer allocator.free(paths);

    // Should find multiple paths including those using reverse edges
    try testing.expect(paths.len > 1);
}

test "path with property filters" {
    const allocator = std.testing.allocator;

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create nodes with properties
    const a = try graph.addNode();
    try graph.setNodeProperty(a, "type", "start");

    const b = try graph.addNode();
    try graph.setNodeProperty(b, "type", "intermediate");
    try graph.setNodeProperty(b, "weight", "5");

    const c = try graph.addNode();
    try graph.setNodeProperty(c, "type", "intermediate");
    try graph.setNodeProperty(c, "weight", "10");

    const d = try graph.addNode();
    try graph.setNodeProperty(d, "type", "end");

    const e1 = try graph.addEdge(a, b);
    try graph.setEdgeProperty(e1, "cost", "100");

    const e2 = try graph.addEdge(b, c);
    try graph.setEdgeProperty(e2, "cost", "200");

    const e3 = try graph.addEdge(c, d);
    try graph.setEdgeProperty(e3, "cost", "150");

    // Find paths with node filters
    const filter = geode.graph.PathFilter{
        .node_predicate = struct {
            fn filter(node: geode.graph.Node) bool {
                const weight = node.getProperty("weight") orelse return true;
                const val = std.fmt.parseInt(i32, weight, 10) catch return false;
                return val <= 10;
            }
        }.filter,
    };

    const filtered_paths = try graph.findPathsFiltered(a, d, .{ .max_length = 5 }, filter);
    defer allocator.free(filtered_paths);

    // Should find paths that respect the filter
    try testing.expect(filtered_paths.len > 0);
}

test "k-shortest paths" {
    const allocator = std.testing.allocator;

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create graph with multiple paths of different lengths
    const nodes = try allocator.alloc(geode.graph.NodeId, 6);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = try graph.addNode();
        const name = try std.fmt.allocPrint(allocator, "N{}", .{i});
        defer allocator.free(name);
        try graph.setNodeProperty(node.*, "name", name);
    }

    // Create various paths from nodes[0] to nodes[5]
    _ = try graph.addEdge(nodes[0], nodes[1]);
    _ = try graph.addEdge(nodes[1], nodes[5]); // Length 2

    _ = try graph.addEdge(nodes[0], nodes[2]);
    _ = try graph.addEdge(nodes[2], nodes[3]);
    _ = try graph.addEdge(nodes[3], nodes[5]); // Length 3

    _ = try graph.addEdge(nodes[0], nodes[4]);
    _ = try graph.addEdge(nodes[4], nodes[5]); // Length 2

    // Find k-shortest paths
    const k_paths = try graph.kShortestPaths(nodes[0], nodes[5], 3);
    defer allocator.free(k_paths);

    // Should find 3 paths
    try testing.expect(k_paths.len == 3);

    // Verify they're sorted by length
    for (1..k_paths.len) |i| {
        try testing.expect(k_paths[i].edges.len >= k_paths[i - 1].edges.len);
    }
}

test "path expansion with depth limit" {
    const allocator = std.testing.allocator;

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create a deep tree structure
    const root = try graph.addNode();
    var current_level = std.ArrayList(geode.graph.NodeId).init(allocator);
    defer current_level.deinit();

    try current_level.append(root);

    const depth = 10;
    const branching = 3;

    var level: u32 = 0;
    while (level < depth) : (level += 1) {
        var next_level = std.ArrayList(geode.graph.NodeId).init(allocator);

        for (current_level.items) |parent| {
            var i: u32 = 0;
            while (i < branching) : (i += 1) {
                const child = try graph.addNode();
                _ = try graph.addEdge(parent, child);
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

    var graph = geode.graph.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create test graph for variable paths
    const alice = try graph.addNode();
    try graph.setNodeProperty(alice, "name", "Alice");

    const bob = try graph.addNode();
    try graph.setNodeProperty(bob, "name", "Bob");

    const charlie = try graph.addNode();
    try graph.setNodeProperty(charlie, "name", "Charlie");

    const dave = try graph.addNode();
    try graph.setNodeProperty(dave, "name", "Dave");

    // Create relationships
    _ = try graph.addEdge(alice, bob);
    _ = try graph.addEdge(bob, charlie);
    _ = try graph.addEdge(charlie, dave);
    _ = try graph.addEdge(alice, dave); // Direct path

    // Test different variable path patterns

    // Any length (*)
    const any_paths = try graph.findPaths(alice, dave, .{});
    defer allocator.free(any_paths);
    try testing.expect(any_paths.len >= 2); // At least direct and indirect

    // Exact length (*2)
    const exact_2 = try graph.findPaths(alice, charlie, .{ .exact_length = 2 });
    defer allocator.free(exact_2);
    try testing.expect(exact_2.len == 1); // Alice -> Bob -> Charlie

    // Range (*1..3)
    const range_paths = try graph.findPaths(alice, dave, .{ .min_length = 1, .max_length = 3 });
    defer allocator.free(range_paths);
    try testing.expect(range_paths.len == 2); // Direct (1) and via Bob-Charlie (3)

    // Up to (*..2)
    const upto_paths = try graph.findPaths(alice, charlie, .{ .max_length = 2 });
    defer allocator.free(upto_paths);
    try testing.expect(upto_paths.len == 1);

    // At least (*2..)
    const atleast_paths = try graph.findPaths(alice, dave, .{ .min_length = 2 });
    defer allocator.free(atleast_paths);
    try testing.expect(atleast_paths.len == 1); // Only the 3-hop path
}
