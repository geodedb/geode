// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const dot = @import("dot.zig");
const Graph = @import("graph.zig").Graph;
const Vertex = @import("graph_core.zig").Vertex;
const createEdge = @import("graph_core.zig").createEdge;
const EdgeOptions = @import("graph_core.zig").EdgeOptions;

test "DOT - serialize undirected graph" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Use string literals - initWithId already duplicates the ID
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "A");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "B");

    try graph.addVertex(a);
    try graph.addVertex(b);

    const edge = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = false, .weighted = false, .weight = 0 });
    try graph.addEdge(edge);

    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    // Verify output contains expected elements
    try testing.expect(std.mem.indexOf(u8, result, "graph {") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"B\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "--") != null);
    try testing.expect(std.mem.indexOf(u8, result, "}") != null);

    // Count edge lines
    var edge_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "--") != null) {
            edge_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), edge_count);
}

test "DOT - serialize directed graph" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Use string literals - initWithId already duplicates the ID
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "A");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "B");

    try graph.addVertex(a);
    try graph.addVertex(b);

    const edge = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = true, .weighted = false, .weight = 0 });
    try graph.addEdge(edge);

    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    try testing.expect(std.mem.indexOf(u8, result, "digraph {") != null);
    try testing.expect(std.mem.indexOf(u8, result, "->") != null);
}

test "DOT - parse undirected graph" {
    const input = "graph { \"A\" -- \"B\" }";
    var stream = std.io.fixedBufferStream(input);

    var dot_graph = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
    defer dot_graph.deinit();

    // Verify graph structure
    try testing.expectEqual(@as(usize, 2), dot_graph.graph.vertices.items.len);
    try testing.expectEqual(@as(usize, 1), dot_graph.graph.edges.items.len);
    try testing.expectEqual(false, dot_graph.graph.directed);

    // Verify vertex IDs
    const v0_id = dot_graph.graph.vertices.items[0].id;
    const v1_id = dot_graph.graph.vertices.items[1].id;
    const has_a = std.mem.eql(u8, v0_id, "A") or std.mem.eql(u8, v1_id, "A");
    const has_b = std.mem.eql(u8, v0_id, "B") or std.mem.eql(u8, v1_id, "B");
    try testing.expect(has_a);
    try testing.expect(has_b);
}

test "DOT - parse directed graph" {
    const input = "digraph { \"X\" -> \"Y\" }";
    var stream = std.io.fixedBufferStream(input);

    var dot_graph = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
    defer dot_graph.deinit();

    try testing.expectEqual(@as(usize, 2), dot_graph.graph.vertices.items.len);
    try testing.expectEqual(@as(usize, 1), dot_graph.graph.edges.items.len);
    try testing.expectEqual(true, dot_graph.graph.directed);
}

test "DOT - roundtrip undirected" {
    const input = "graph { \"A\" -- \"B\" }";
    var stream = std.io.fixedBufferStream(input);

    var dot_graph = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    // Verify key components are present
    try testing.expect(std.mem.indexOf(u8, result, "\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"B\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "--") != null);

    // Count edges
    var edge_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "--") != null) {
            edge_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), edge_count);
}

test "DOT - roundtrip directed" {
    const input = "digraph { \"X\" -> \"Y\" }";
    var stream = std.io.fixedBufferStream(input);

    var dot_graph = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    try testing.expect(std.mem.indexOf(u8, result, "\"X\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"Y\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "->") != null);
}

test "DOT - isolated nodes" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Use string literals - initWithId already duplicates the ID
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "A");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "B");
    const c = try Vertex([]const u8).initWithId(testing.allocator, "C", "C");

    try graph.addVertex(a);
    try graph.addVertex(b);
    try graph.addVertex(c);

    // Only connect A and B, C remains isolated
    const edge = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = false, .weighted = false, .weight = 0 });
    try graph.addEdge(edge);

    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    // Verify all nodes are present
    try testing.expect(std.mem.indexOf(u8, result, "\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"B\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"C\"") != null);
}

test "DOT - multiple edges" {
    const input =
        \\graph {
        \\  "A" -- "B"
        \\  "B" -- "C"
        \\  "C" -- "A"
        \\}
    ;
    var stream = std.io.fixedBufferStream(input);

    var dot_graph = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
    defer dot_graph.deinit();

    try testing.expectEqual(@as(usize, 3), dot_graph.graph.vertices.items.len);
    try testing.expectEqual(@as(usize, 3), dot_graph.graph.edges.items.len);
}

test "DOT - strict mode deduplication" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Use string literals - initWithId already duplicates the ID
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "A");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "B");

    try graph.addVertex(a);
    try graph.addVertex(b);

    // Add same edge twice
    const edge1 = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = false, .weighted = false, .weight = 0 });
    const edge2 = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = false, .weighted = false, .weight = 0 });
    try graph.addEdge(edge1);
    try graph.addEdge(edge2);

    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    dot_graph.strict = true;
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    // Verify strict mode in output
    try testing.expect(std.mem.indexOf(u8, result, "strict graph") != null);

    // Count edges - should only be 1 due to strict mode
    var edge_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "--") != null) {
            edge_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), edge_count);
}

test "DOT - canonical ordering" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Use string literals - initWithId already duplicates the ID
    const z = try Vertex([]const u8).initWithId(testing.allocator, "Z", "Z");
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "A");
    const m = try Vertex([]const u8).initWithId(testing.allocator, "M", "M");

    // Add in non-alphabetical order
    try graph.addVertex(z);
    try graph.addVertex(a);
    try graph.addVertex(m);

    const edge1 = try createEdge([]const u8, testing.allocator, z, a, "", .{ .directed = false, .weighted = false, .weight = 0 });
    const edge2 = try createEdge([]const u8, testing.allocator, m, a, "", .{ .directed = false, .weighted = false, .weight = 0 });
    try graph.addEdge(edge1);
    try graph.addEdge(edge2);

    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    // Extract edge lines
    var edge_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer edge_lines.deinit(testing.allocator);

    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "--") != null) {
            try edge_lines.append(testing.allocator, line);
        }
    }

    // Verify edges are sorted
    if (edge_lines.items.len == 2) {
        // First edge should come before second alphabetically
        try testing.expect(std.mem.order(u8, edge_lines.items[0], edge_lines.items[1]) != .gt);
    }
}

test "DOT - parse strict mode" {
    const input = "strict graph { \"A\" -- \"B\" }";
    var stream = std.io.fixedBufferStream(input);

    var dot_graph = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
    defer dot_graph.deinit();

    try testing.expect(dot_graph.strict);
}

test "DOT - empty graph" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    try testing.expect(std.mem.indexOf(u8, result, "graph {") != null);
    try testing.expect(std.mem.indexOf(u8, result, "}") != null);
}

// Acceptance test matching Go implementation
test "Acceptance - DOT serialize" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Use string literals - initWithId already duplicates the ID
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "A");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "B");

    try graph.addVertex(a);
    try graph.addVertex(b);

    const edge = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = false, .weighted = false, .weight = 0 });
    try graph.addEdge(edge);

    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    var edge_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "--") != null) {
            edge_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), edge_count);
}

// Acceptance test matching Go implementation
test "Acceptance - DOT roundtrip" {
    const input = "graph { \"A\" -- \"B\" }";
    var stream = std.io.fixedBufferStream(input);

    var dot_graph = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
    defer dot_graph.deinit();

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(testing.allocator);

    try dot_graph.marshal(output.writer(testing.allocator));
    const result = output.items;

    try testing.expect(std.mem.indexOf(u8, result, "\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"B\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "--") != null);

    var edge_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "--") != null) {
            edge_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), edge_count);
}

test "DOT - complexity limits are configured" {
    // Verify sensible limits exist without creating 10K+ vertices.
    try testing.expect(dot.DOTGraph.max_vertex_count > 0);
    try testing.expect(dot.DOTGraph.max_edge_count > 0);
    try testing.expect(dot.DOTGraph.max_vertex_count <= 100_000);
    try testing.expect(dot.DOTGraph.max_edge_count <= 1_000_000);
}
