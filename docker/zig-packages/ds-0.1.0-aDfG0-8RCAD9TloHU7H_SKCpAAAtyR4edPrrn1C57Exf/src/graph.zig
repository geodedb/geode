// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_core = @import("graph_core.zig");

/// Graph structure with mutex-protected mutation operations.
///
/// Thread-safety contract:
/// - **Mutation operations** (`addVertex`, `addEdge`, `removeVertex`, `removeEdge`)
///   are protected by internal mutexes and are safe for concurrent use.
/// - **Read operations** (`getVertices`, `getEdges`, `getLeaves`, `findVertexById`,
///   `vertexCount`, `edgeCount`, `isEmpty`, `hasVertex`, `hasEdgeBetween`,
///   `degree`, `getNeighbors`) return raw slices or iterate internal data
///   structures without locking. These are **NOT safe** for concurrent access
///   during mutation. Callers must provide their own synchronization when
///   mixing reads with concurrent writes.
///
/// Lock ordering invariant: when acquiring both mutexes, `vertices_mutex`
/// must always be acquired before `edges_mutex` to prevent deadlock.
///
/// The `version` counter is not atomic; concurrent version reads during
/// mutation may observe stale values. Use external synchronization if
/// a consistent version snapshot is required.
pub fn Graph(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const VertexType = graph_core.Vertex(T);
        pub const EdgeType = graph_core.Edge(T);

        allocator: Allocator,
        vertices: std.ArrayListUnmanaged(*VertexType),
        edges: std.ArrayListUnmanaged(*EdgeType),
        vertex_index: std.StringHashMap(*VertexType),
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
                .vertex_index = std.StringHashMap(*VertexType).init(allocator),
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

            // Free vertex index
            self.vertex_index.deinit();
        }

        /// Add a vertex to the graph.
        /// Returns `Allocator.Error` if the internal list cannot grow.
        pub fn addVertex(self: *Self, vertex: *VertexType) Allocator.Error!void {
            self.vertices_mutex.lock();
            defer self.vertices_mutex.unlock();

            try self.vertices.append(self.allocator, vertex);
            errdefer _ = self.vertices.pop();
            try self.vertex_index.put(vertex.id, vertex);
            self.version += 1;
        }

        /// Add an edge to the graph and update flags.
        /// Returns `Allocator.Error` if the internal list cannot grow.
        pub fn addEdge(self: *Self, edge: *EdgeType) Allocator.Error!void {
            self.edges_mutex.lock();
            defer self.edges_mutex.unlock();

            if (edge.isDirected()) {
                self.directed = true;
            }
            if (edge.isWeighted()) {
                self.weighted = true;
            }

            try self.edges.append(self.allocator, edge);
            self.version += 1;
        }

        /// Remove a vertex and all its edges.
        /// Uses O(1) swap-remove; internal vertex order is not guaranteed.
        /// Edge removal is batched under a single lock acquisition for performance.
        pub fn removeVertex(self: *Self, vertex: *VertexType) void {
            self.vertices_mutex.lock();
            defer self.vertices_mutex.unlock();

            // Find and remove the vertex
            var i: usize = 0;
            while (i < self.vertices.items.len) {
                if (self.vertices.items[i].eql(vertex)) {
                    // Batch-remove all edges connected to this vertex under a single lock.
                    // Lock ordering: vertices_mutex (held) before edges_mutex (acquiring).
                    const vertex_edges = vertex.getEdges();
                    if (vertex_edges.len > 0) {
                        self.edges_mutex.lock();
                        defer self.edges_mutex.unlock();

                        for (vertex_edges) |edge| {
                            var j: usize = 0;
                            while (j < self.edges.items.len) {
                                if (self.edges.items[j] == edge) {
                                    _ = self.edges.swapRemove(j);
                                    break;
                                }
                                j += 1;
                            }
                        }
                    }

                    _ = self.vertices.swapRemove(i);
                    _ = self.vertex_index.remove(vertex.id);
                    self.version += 1;
                    break;
                }
                i += 1;
            }
        }

        /// Remove an edge from the graph.
        /// Uses O(1) swap-remove; internal edge order is not guaranteed.
        pub fn removeEdge(self: *Self, edge: *const EdgeType) void {
            self.edges_mutex.lock();
            defer self.edges_mutex.unlock();

            var i: usize = 0;
            while (i < self.edges.items.len) {
                if (self.edges.items[i] == edge) {
                    _ = self.edges.swapRemove(i);
                    self.version += 1;
                    break;
                }
                i += 1;
            }
        }

        /// Get all vertices as a slice (zero-copy, internal storage).
        ///
        /// WARNING: The returned slice points directly into the internal
        /// `ArrayList` backing array. It is invalidated if the graph is
        /// mutated (`addVertex`, `removeVertex`, `addEdge`, `removeEdge`)
        /// because the backing array may reallocate. Using a stale slice
        /// after mutation is **use-after-free** (CWE-416).
        ///
        /// Safe usage patterns:
        /// - Use the slice immediately within a single scope with no mutations.
        /// - Use `getVerticesCopy()` if the slice must outlive a mutation.
        /// - Use external synchronization if sharing across threads.
        pub fn getVertices(self: *Self) []const *VertexType {
            return self.vertices.items;
        }

        /// Get a caller-owned copy of all vertices.
        /// The returned slice must be freed with `allocator.free(slice)`.
        /// Safe to use across mutations — the copy is independent of internal storage.
        pub fn getVerticesCopy(self: *Self, allocator: Allocator) Allocator.Error![]const *VertexType {
            return allocator.dupe(*VertexType, self.vertices.items);
        }

        /// Get all edges as a slice (zero-copy, internal storage).
        ///
        /// WARNING: Same invalidation rules as `getVertices()`. The slice
        /// is backed by internal storage and becomes dangling after any
        /// graph mutation. See `getVertices()` documentation.
        pub fn getEdges(self: *Self) []const *EdgeType {
            return self.edges.items;
        }

        /// Get a caller-owned copy of all edges.
        /// The returned slice must be freed with `allocator.free(slice)`.
        /// Safe to use across mutations — the copy is independent of internal storage.
        pub fn getEdgesCopy(self: *Self, allocator: Allocator) Allocator.Error![]const *EdgeType {
            return allocator.dupe(*EdgeType, self.edges.items);
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

        /// Get the current version (mutation counter).
        ///
        /// NOTE: The version counter is not atomic. Concurrent reads during
        /// mutation may observe stale values. Use external synchronization
        /// if a consistent version snapshot is required.
        pub fn getVersion(self: *Self) u64 {
            return self.version;
        }

        /// Get vertex by ID (O(1) via hash index)
        pub fn findVertexById(self: *Self, id: []const u8) ?*VertexType {
            return self.vertex_index.get(id);
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
        /// O(1) vertex membership check using the vertex index.
        pub fn hasVertex(self: *Self, vertex: *const VertexType) bool {
            return self.vertex_index.contains(vertex.id);
        }

        /// Check if an edge exists between two vertices.
        /// O(degree(from)) -- iterates only the from-vertex's incident edges
        /// instead of scanning all graph edges.
        pub fn hasEdgeBetween(self: *Self, from: *const VertexType, to: *const VertexType) bool {
            _ = self;
            for (from.edges.items) |edge| {
                const vertices = edge.getVertices();
                if (edge.isDirected()) {
                    // For directed edges, from must be the source
                    if (vertices[0] == from and vertices[1] == to) return true;
                } else {
                    // For undirected edges, check the other endpoint
                    if (vertices[0] == from and vertices[1] == to) return true;
                    if (vertices[1] == from and vertices[0] == to) return true;
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

    try graph.addVertex(v1);
    try graph.addVertex(v2);

    try testing.expectEqual(@as(usize, 2), graph.vertexCount());
    try testing.expectEqual(@as(u64, 2), graph.getVersion());
}

test "Graph - add edges and track flags" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);

    try graph.addVertex(v1);
    try graph.addVertex(v2);

    const edge = try graph_core.createEdge(i32, testing.allocator, v1, v2, 10, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });

    try graph.addEdge(edge);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    // Create edge between v1 and v2, leaving v3 as a leaf
    const edge = try graph_core.createEdge(i32, testing.allocator, v1, v2, 10, .{});
    try graph.addEdge(edge);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);

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
    try graph.addVertex(v1);

    try testing.expectEqual(@as(u64, 1), graph.getVersion());

    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);
    try graph.addVertex(v2);

    try testing.expectEqual(@as(u64, 2), graph.getVersion());
}

test "Graph - isEmpty, hasVertex, hasEdgeBetween" {
    const testing = std.testing;

    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    try testing.expect(graph.isEmpty());

    const v1 = try graph_core.Vertex(i32).init(testing.allocator, 1);
    const v2 = try graph_core.Vertex(i32).init(testing.allocator, 2);

    try graph.addVertex(v1);
    try graph.addVertex(v2);

    try testing.expect(!graph.isEmpty());
    try testing.expect(graph.hasVertex(v1));
    try testing.expect(graph.hasVertex(v2));
    try testing.expect(!graph.hasEdgeBetween(v1, v2));

    const edge = try graph_core.createEdge(i32, testing.allocator, v1, v2, 10, .{});
    try graph.addEdge(edge);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, v1, v3, 0, .{});
    try graph.addEdge(e1);
    try graph.addEdge(e2);

    try testing.expectEqual(@as(usize, 2), graph.degree(v1));
    try testing.expectEqual(@as(usize, 1), graph.degree(v2));
    try testing.expectEqual(@as(usize, 1), graph.degree(v3));

    var neighbors = try graph.getNeighbors(v1, testing.allocator);
    defer neighbors.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), neighbors.items.len);
}
