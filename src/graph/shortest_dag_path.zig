const std = @import("std");

// CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=DagShortestPath; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_063_DagShortestPath; BENCH=BenchmarkCANARY_REQ_GQL_063_DagShortestPath; OWNER=graph; UPDATED=2025-09-21

pub const DagShortestPath = struct {
    pub const Result = struct {
        distances: std.AutoHashMap(u64, f64),
        predecessors: std.AutoHashMap(u64, u64),
    };

    /// Computes single-source shortest paths on a DAG.
    /// The graph is provided via an adjacency iterator function that yields (neighbor, weight) pairs.
    /// `topo_order` must contain a valid topological ordering of the DAG's vertices.
    pub fn singleSource(
        allocator: std.mem.Allocator,
        topo_order: []const u64,
        source: u64,
        getNeighbors: fn (u64, *std.ArrayList(struct { v: u64, w: f64 })) anyerror!void,
    ) !Result {
        var distances = std.AutoHashMap(u64, f64).init(allocator);
        var predecessors = std.AutoHashMap(u64, u64).init(allocator);

        errdefer distances.deinit();
        errdefer predecessors.deinit();

        // Initialize all distances to +inf
        for (topo_order) |v| {
            try distances.put(v, std.math.inf(f64));
        }
        // Source distance = 0
        if (distances.getPtr(source)) |dptr| dptr.* = 0 else try distances.put(source, 0);

        var neighbor_buf = std.ArrayList(struct { v: u64, w: f64 }).init(allocator);
        defer neighbor_buf.deinit();

        for (topo_order) |u| {
            const du_opt = distances.get(u);
            if (du_opt) |du| {
                if (du == std.math.inf(f64)) continue; // unreachable
                neighbor_buf.clearRetainingCapacity();
                try getNeighbors(u, &neighbor_buf);
                for (neighbor_buf.items) |edge| {
                    const alt = du + edge.w;
                    const cur = distances.get(edge.v).?; // must exist if in topo_order
                    if (alt < cur) {
                        if (distances.getPtr(edge.v)) |ptr| ptr.* = alt else try distances.put(edge.v, alt);
                        if (predecessors.getPtr(edge.v)) |pp| pp.* = u else try predecessors.put(edge.v, u);
                    }
                }
            }
        }

        return Result{ .distances = distances, .predecessors = predecessors };
    }
};

test "DagShortestPath basic linear chain" {
    var g = GraphBuilder.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(0, 1, 2);
    try g.addEdge(1, 2, 3);
    const topo = [_]u64{ 0, 1, 2 };
    const res = try DagShortestPath.singleSource(std.testing.allocator, &topo, 0, g.getNeighborsCallback());
    defer res.distances.deinit();
    defer res.predecessors.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 5), res.distances.get(2).?, 1e-9);
}

// Minimal graph builder used for tests/bench; we embed here to avoid large dependency fan-in.
pub const GraphBuilder = struct {
    allocator: std.mem.Allocator,
    edges: std.AutoHashMap(u64, std.ArrayList(struct { v: u64, w: f64 })),

    pub fn init(allocator: std.mem.Allocator) GraphBuilder {
        return .{ .allocator = allocator, .edges = std.AutoHashMap(u64, std.ArrayList(struct { v: u64, w: f64 })).init(allocator) };
    }
    pub fn deinit(self: *GraphBuilder) void {
        var it = self.edges.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit();
        self.edges.deinit();
    }
    pub fn addEdge(self: *GraphBuilder, u: u64, v: u64, w: f64) !void {
        var list = try self.ensureList(u);
        try list.append(.{ .v = v, .w = w });
        // ensure vertex presence for v
        _ = try self.ensureList(v);
    }
    fn ensureList(self: *GraphBuilder, u: u64) !*std.ArrayList(struct { v: u64, w: f64 }) {
        if (self.edges.getPtr(u)) |ptr| return ptr;
        const list = std.ArrayList(struct { v: u64, w: f64 }).init(self.allocator);
        try self.edges.put(u, list);
        return self.edges.getPtr(u).?;
    }
    pub fn getNeighborsCallback(self: *GraphBuilder) fn (u64, *std.ArrayList(struct { v: u64, w: f64 })) anyerror!void {
        const ctx = self; // capture
        return struct {
            fn cb(u: u64, out: *std.ArrayList(struct { v: u64, w: f64 })) anyerror!void {
                const gp: *GraphBuilder = ctx; // use captured context
                if (gp.edges.get(u)) |list| {
                    for (list.items) |e| try out.append(e);
                }
            }
        }.cb;
    }
};
