const std = @import("std");

// CANARY: REQ=REQ-GQL-060; FEATURE="Core Graph Builders"; ASPECT=DirectedWeightedBuilders; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_060_CoreGraphBuilders; OWNER=graph; UPDATED=2025-09-21

// Minimal directed weighted graph builder supporting:
//  - addNode(id)
//  - addEdge(src,dst,weight)
//  - outEdges(id) iteration
//  - stable storage in contiguous arrays ( SoA )
// Chosen structure: node ids assumed dense-ish u32; edges stored in single array with offset index per node.
// For simplicity we rebuild adjacency offsets after each edge add (O(E)) acceptable for small test scale.

pub const Weight = f64;

pub const Edge = struct { src: u32, dst: u32, w: Weight };

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u32, void),
    edges: std.ArrayList(Edge),
    // adjacency index: node -> slice range (start,end)
    index: std.AutoHashMap(u32, struct { start: usize, end: usize }),

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{ .allocator = allocator, .nodes = std.AutoHashMap(u32, void).init(allocator), .edges = std.ArrayList(Edge).initCapacity(allocator, 0) catch unreachable, .index = std.AutoHashMap(u32, struct { start: usize, end: usize }).init(allocator) };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit();
        self.edges.deinit(self.allocator);
        self.index.deinit();
    }

    pub fn addNode(self: *Graph, id: u32) void {
        _ = self.nodes.put(id, {}) catch {};
        // ensure index entry exists
        if (!self.index.contains(id)) self.index.put(id, .{ .start = 0, .end = 0 }) catch {};
    }

    pub fn addEdge(self: *Graph, src: u32, dst: u32, w: Weight) !void {
        if (!self.nodes.contains(src)) self.addNode(src);
        if (!self.nodes.contains(dst)) self.addNode(dst);
        try self.edges.append(self.allocator, .{ .src = src, .dst = dst, .w = w });
        try self.rebuildIndex();
    }

    fn rebuildIndex(self: *Graph) !void {
        // Group edges by source node for standard outgoing adjacency semantics.
        var temp = std.AutoHashMap(u32, std.ArrayList(Edge)).init(self.allocator);
        defer {
            var it = temp.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
            temp.deinit();
        }
        const es = self.edges.items;
        var i: usize = 0;
        while (i < es.len) : (i += 1) {
            const e = es[i];
            var gop = try temp.getOrPut(e.src);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edge).initCapacity(self.allocator, 0) catch unreachable;
            try gop.value_ptr.append(e);
        }
        // Rebuild index with sequential ordering per node (source-based)
        self.index.clearRetainingCapacity();
        var cursor: usize = 0;
        var temp_iter = temp.iterator();
        while (temp_iter.next()) |entry| {
            const arr = entry.value_ptr.*;
            const start = cursor;
            // copy edges back in place (in current order)
            for (arr.items) |ed| {
                self.edges.items[cursor] = ed;
                cursor += 1;
            }
            const end = cursor;
            try self.index.put(entry.key_ptr.*, .{ .start = start, .end = end });
        }
    }

    pub const OutEdgeIter = struct {
        edges: []const Edge,
        i: usize = 0,
        pub fn next(self: *OutEdgeIter) ?Edge {
            if (self.i >= self.edges.len) return null;
            const e = self.edges[self.i];
            self.i += 1;
            return e;
        }
    };

    pub fn outEdges(self: *const Graph, node: u32) OutEdgeIter {
        if (self.index.get(node)) |rng| {
            return .{ .edges = self.edges.items[rng.start..rng.end] };
        }
        return .{ .edges = &[_]Edge{} };
    }
};

test "basic directed weighted builder add & iterate" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    g.addNode(1);
    g.addNode(2);
    try g.addEdge(1, 2, 3.5);
    var it = g.outEdges(1);
    const e = it.next() orelse return error.MissingEdge;
    try std.testing.expect(e.src == 1 and e.dst == 2 and e.w == 3.5);
}
