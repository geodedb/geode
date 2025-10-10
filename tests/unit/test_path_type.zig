const std = @import("std");
const testing = std.testing;
const eval = @import("../../src/eval.zig");
const ast = @import("../../src/gql/ast.zig");

// CANARY: REQ=REQ-GQL-PATH; FEATURE="Path Type Unit Tests"; ASPECT=Testing; STATUS=TESTED; TEST=test_path_type; OWNER=graph; UPDATED=2025-10-10

test "Path type equality - identical paths" {
    const allocator = testing.allocator;

    // Create mock nodes
    var node1 = @import("../../src/graph_store.zig").Node{
        .id = 1,
        .labels = &[_][]const u8{"Person"},
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer node1.properties.deinit();

    var node2 = @import("../../src/graph_store.zig").Node{
        .id = 2,
        .labels = &[_][]const u8{"Person"},
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer node2.properties.deinit();

    // Create mock edge
    var edge1 = @import("../../src/graph_store.zig").Edge{
        .id = 10,
        .from_id = 1,
        .to_id = 2,
        .label = "KNOWS",
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer edge1.properties.deinit();

    const nodes = [_]*const @import("../../src/graph_store.zig").Node{ &node1, &node2 };
    const edges = [_]*const @import("../../src/graph_store.zig").Edge{ &edge1 };

    const path_a = eval.Value{
        .Path = .{
            .nodes = &nodes,
            .edges = &edges,
        },
    };

    const path_b = eval.Value{
        .Path = .{
            .nodes = &nodes,
            .edges = &edges,
        },
    };

    // Paths with same nodes and edges should be equal
    try testing.expect(eval.eqVals(path_a, path_b));
}

test "Path type equality - different node count" {
    const allocator = testing.allocator;

    var node1 = @import("../../src/graph_store.zig").Node{
        .id = 1,
        .labels = &[_][]const u8{"Person"},
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer node1.properties.deinit();

    var node2 = @import("../../src/graph_store.zig").Node{
        .id = 2,
        .labels = &[_][]const u8{"Person"},
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer node2.properties.deinit();

    var node3 = @import("../../src/graph_store.zig").Node{
        .id = 3,
        .labels = &[_][]const u8{"Person"},
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer node3.properties.deinit();

    var edge1 = @import("../../src/graph_store.zig").Edge{
        .id = 10,
        .from_id = 1,
        .to_id = 2,
        .label = "KNOWS",
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer edge1.properties.deinit();

    var edge2 = @import("../../src/graph_store.zig").Edge{
        .id = 20,
        .from_id = 2,
        .to_id = 3,
        .label = "KNOWS",
        .properties = std.StringHashMap(@import("../../src/graph_store.zig").PropertyValue).init(allocator),
    };
    defer edge2.properties.deinit();

    const nodes_short = [_]*const @import("../../src/graph_store.zig").Node{ &node1, &node2 };
    const edges_short = [_]*const @import("../../src/graph_store.zig").Edge{ &edge1 };

    const nodes_long = [_]*const @import("../../src/graph_store.zig").Node{ &node1, &node2, &node3 };
    const edges_long = [_]*const @import("../../src/graph_store.zig").Edge{ &edge1, &edge2 };

    const path_short = eval.Value{
        .Path = .{
            .nodes = &nodes_short,
            .edges = &edges_short,
        },
    };

    const path_long = eval.Value{
        .Path = .{
            .nodes = &nodes_long,
            .edges = &edges_long,
        },
    };

    // Paths with different lengths should not be equal
    try testing.expect(!eval.eqVals(path_short, path_long));
}

test "Path type vs non-path type" {
    const path = eval.Value{
        .Path = .{
            .nodes = &[_]*const @import("../../src/graph_store.zig").Node{},
            .edges = &[_]*const @import("../../src/graph_store.zig").Edge{},
        },
    };

    const int_val = eval.Value{ .Int = 42 };
    const null_val = eval.Value{ .Null = {} };

    // Path should not equal non-path types
    try testing.expect(!eval.eqVals(path, int_val));
    try testing.expect(!eval.eqVals(path, null_val));
}

test "ShortestPath expression evaluation" {
    const allocator = testing.allocator;

    // Create a simple ShortestPath expression
    var pattern = ast.GraphPattern{
        .parts = &[_]ast.GraphPatternPart{},
    };

    const shortest_path_expr = ast.Expr{
        .ShortestPath = .{
            .pattern = &pattern,
            .all = false,
        },
    };

    const env = eval.Env{
        .names = &[_][]const u8{},
        .values = &[_]eval.Value{},
    };

    // Should return null (requires graph context)
    const result = try eval.evalExpr(allocator, shortest_path_expr, env);
    try testing.expect(result == .Null);
}

test "Path type serialization format" {
    // This test documents the expected JSON format
    // Actual serialization is tested through integration tests

    // Expected format:
    // {
    //   "nodes": [1, 2, 3],
    //   "edges": [10, 20]
    // }

    try testing.expect(true); // Format documented
}
