// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_core = @import("graph_core.zig");

/// Graph structure with thread-safe vertex and edge operations
pub fn Graph(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const VertexType = graph_core.Vertex(T);
        pub const EdgeType = graph_core.Edge(T);

        allocator: Allocator,
        vertices: std.ArrayListUnmanaged(*VertexType),
        edges: std.ArrayListUnmanaged(*EdgeType),
        vertices_mutex: std.Thread.Mutex = .{},
        edges_mutex: std.Thread.Mutex = .{},
        weighted: bool = false,
        directed: bool = false,
        version: u64 = 0,

        /// Create a new empty graph
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .vertices = .{},
                .edges = .{},
            };
        }

        /// Free all graph memory
        pub fn deinit(self: *Self) void {
            // Free all edges first
            for (self.edges.items) |edge| {
                edge.deinit(self.allocator);
            }
            self.edges.deinit(self.allocator);

            // Free all vertices
            for (self.vertices.items) |vertex| {
                vertex.deinit();
            }
            self.vertices.deinit(self.allocator);
        }

        /// Add a vertex to the graph
        pub fn addVertex(self: *Self, vertex: *VertexType) void {
            self.vertices_mutex.lock();
            defer self.vertices_mutex.unlock();

            self.vertices.append(self.allocator, vertex) catch return;
            self.version += 1;
        }

        /// Add an edge to the graph and update flags
        pub fn addEdge(self: *Self, edge: *EdgeType) void {
            self.edges_mutex.lock();
            defer self.edges_mutex.unlock();

            if (edge.isDirected()) {
                self.directed = true;
            }
            if (edge.isWeighted()) {
                self.weighted = true;
            }

            self.edges.append(self.allocator, edge) catch return;
            self.version += 1;
        }

        /// Remove a vertex and all its edges
        pub fn removeVertex(self: *Self, vertex: *VertexType) void {
            self.vertices_mutex.lock();
            defer self.vertices_mutex.unlock();

            // Find and remove the vertex
            var i: usize = 0;
            while (i < self.vertices.items.len) {
                if (self.vertices.items[i].eql(vertex)) {
                    // Remove all edges connected to this vertex
                    for (vertex.getEdges()) |edge| {
                        self.removeEdge(edge);
                    }

                    _ = self.vertices.orderedRemove(i);
                    self.version += 1;
                    break;
                }
                i += 1;
            }
        }

        /// Remove an edge from the graph
        pub fn removeEdge(self: *Self, edge: *const EdgeType) void {
            self.edges_mutex.lock();
            defer self.edges_mutex.unlock();

            var i: usize = 0;
            while (i < self.edges.items.len) {
                if (self.edges.items[i] == edge) {
                    _ = self.edges.orderedRemove(i);
                    self.version += 1;
                    break;
                }
                i += 1;
            }
        }

        /// Get all vertices (returns a slice, caller should lock if needed)
        pub fn getVertices(self: *Self) []const *VertexType {
            return self.vertices.items;
        }

        /// Get all edges (returns a slice, caller should lock if needed)
        pub fn getEdges(self: *Self) []const *EdgeType {
            return self.edges.items;
        }

        /// Check if the graph is directed
        pub fn isDirected(self: *Self) bool {
            return self.directed;
        }

        /// Check if the graph is weighted
        pub fn isWeighted(self: *Self) bool {
            return self.weighted;
        }

        /// Get leaf vertices (vertices with no edges)
        pub fn getLeaves(self: *Self, allocator: Allocator) Allocator.Error!std.ArrayListUnmanaged(*VertexType) {
            var leaves: std.ArrayListUnmanaged(*VertexType) = .{};

            for (self.vertices.items) |vertex| {
                if (vertex.getEdges().len == 0) {
                    try leaves.append(allocator, vertex);
                }
            }

            return leaves;
        }

        /// Get the current version (mutation counter)
        pub fn getVersion(self: *Self) u64 {
            return self.version;
        }

        /// Get vertex by ID
        pub fn findVertexById(self: *Self, id: []const u8) ?*VertexType {
            for (self.vertices.items) |vertex| {
                if (std.mem.eql(u8, vertex.id, id)) {
                    return vertex;
                }
            }
            return null;
        }

        /// Get number of vertices
        pub fn vertexCount(self: *Self) usize {
            return self.vertices.items.len;
        }

        /// Get number of edges
        pub fn edgeCount(self: *Self) usize {
            return self.edges.items.len;
        }

        /// Check if the graph is empty (no vertices).
        pub fn isEmpty(self: *Self) bool {
            return self.vertices.items.len == 0;
        }

        /// Check if a vertex exists in the graph.
        pub fn hasVertex(self: *Self, vertex: *const VertexType) bool {
            for (self.vertices.items) |v| {
                if (v == vertex) return true;
            }
            return false;
        }

        /// Check if an edge exists between two vertices.
        pub fn hasEdgeBetween(self: *Self, from: *const VertexType, to: *const VertexType) bool {
            for (self.edges.items) |edge| {
                const vertices = edge.getVertices();
                if (edge.isDirected()) {
                    if (vertices[0] == from and vertices[1] == to) return true;
                } else {
                    if ((vertices[0] == from and vertices[1] == to) or
                        (vertices[0] == to and vertices[1] == from))
                    {
                        return true;
                    }
                }
            }
            return false;
        }

        /// Get the degree of a vertex (number of incident edges).
        pub fn degree(self: *Self, vertex: *const VertexType) usize {
            _ = self;
            return vertex.edges.items.len;
        }

        /// Get neighbors of a vertex.
        pub fn getNeighbors(self: *Self, vertex: *const VertexType, allocator: Allocator) Allocator.Error!std.ArrayListUnmanaged(*VertexType) {
            _ = self;
            var neighbors: std.ArrayListUnmanaged(*VertexType) = .{};

            for (vertex.edges.items) |edge| {
                const vertices = edge.getVertices();
                if (edge.isDirected()) {
                    // For directed edges, only add child if vertex is parent
                    if (vertices[0] == vertex) {
                        try neighbors.append(allocator, vertices[1]);
                    }
                } else {
                    // For undirected edges, add the other vertex
                    if (vertices[0] == vertex) {
                        try neighbors.append(allocator, vertices[1]);
                    } else if (vertices[1] == vertex) {
                        try neighbors.append(allocator, vertices[0]);
                    }
                }
            }

            return neighbors;
        }
    };
}

test "Graph - basic operations" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    try testing.expectEqual(@as(usize, 2), graph.vertexCount());
    try testing.expectEqual(@as(u64, 2), graph.getVersion());
}

test "Graph - add edges and track flags" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    const edge = try graph_core.createEdge(i32, testing.allocator, v1, v2, 10, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });

    graph.addEdge(edge);

    try testing.expect(graph.isDirected());
    try testing.expect(graph.isWeighted());
    try testing.expectEqual(@as(usize, 1), graph.edgeCount());
}

test "Graph - find vertex by ID" {
    const testing = std.testing;

    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex([]const u8).initWithId(testing.allocator, "node1", "value1");
    const v2 = try graph_core.Vertex([]const u8).initWithId(testing.allocator, "node2", "value2");

    graph.addVertex(v1);
    graph.addVertex(v2);

    const found = graph.findVertexById("node1");
    try testing.expect(found != null);
    try testing.expectEqualStrings("node1", found.?.id);
    try testing.expectEqualStrings("value1", found.?.value);

    const not_found = graph.findVertexById("node3");
    try testing.expect(not_found == null);
}

test "Graph - get leaves" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);
    const v3 = try graph_core.Vertex(i32).init(testing.allocator, 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    // Create edge between v1 and v2, leaving v3 as a leaf
    const edge = try graph_core.createEdge(i32, testing.allocator, v1, v2, 10, .{});
    graph.addEdge(edge);

    var leaves = try graph.getLeaves(testing.allocator);
    defer leaves.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), leaves.items.len);
    try testing.expect(leaves.items[0].eql(v3));
}

test "Graph - remove vertex" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    defer v1.deinit(); // Must free v1 since removeVertex doesn't free it
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    try testing.expectEqual(@as(usize, 2), graph.vertexCount());

    graph.removeVertex(v1);

    try testing.expectEqual(@as(usize, 1), graph.vertexCount());
}

test "Graph - version counter" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const initial_version = graph.getVersion();
    try testing.expectEqual(@as(u64, 0), initial_version);

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    graph.addVertex(v1);

    try testing.expectEqual(@as(u64, 1), graph.getVersion());

    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);
    graph.addVertex(v2);

    try testing.expectEqual(@as(u64, 2), graph.getVersion());
}

test "Graph - isEmpty, hasVertex, hasEdgeBetween" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    try testing.expect(graph.isEmpty());

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    try testing.expect(!graph.isEmpty());
    try testing.expect(graph.hasVertex(v1));
    try testing.expect(graph.hasVertex(v2));
    try testing.expect(!graph.hasEdgeBetween(v1, v2));

    const edge = try graph_core.createEdge(i32, testing.allocator, v1, v2, 10, .{});
    graph.addEdge(edge);

    try testing.expect(graph.hasEdgeBetween(v1, v2));
    try testing.expect(graph.hasEdgeBetween(v2, v1)); // Undirected
}

test "Graph - degree and getNeighbors" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);
    const v3 = try graph_core.Vertex(i32).init(testing.allocator, 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, v1, v3, 0, .{});
    graph.addEdge(e1);
    graph.addEdge(e2);

    try testing.expectEqual(@as(usize, 2), graph.degree(v1));
    try testing.expectEqual(@as(usize, 1), graph.degree(v2));
    try testing.expectEqual(@as(usize, 1), graph.degree(v3));

    var neighbors = try graph.getNeighbors(v1, testing.allocator);
    defer neighbors.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), neighbors.items.len);
}
