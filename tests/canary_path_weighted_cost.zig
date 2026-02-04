const std = @import("std");
const paths = @import("../src/graph/path_algorithms.zig");

// CANARY: REQ=REQ-GQL-016; FEATURE="Weighted Path Cost"; ASPECT=Planner; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_PathWeightedCost; OWNER=planner; UPDATED=2025-09-20

// Minimal fake GraphStore subset for test
const FakeGraph = struct {
    allocator: std.mem.Allocator,
    adj: std.AutoHashMap(u64, []u64),

    pub fn init(allocator: std.mem.Allocator) FakeGraph {
        return .{ .allocator = allocator, .adj = std.AutoHashMap(u64, []u64).init(allocator) };
    }
    pub fn deinit(self: *FakeGraph) void {
        var it = self.adj.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.adj.deinit();
    }

    pub fn addEdge(self: *FakeGraph, a: u64, b: u64) !void {
        const list = self.adj.get(a) orelse blk: {
            break :blk try self.allocator.alloc(u64, 0);
        };
        var new_list = try self.allocator.realloc(list, list.len + 1);
        new_list[list.len] = b;
        try self.adj.put(a, new_list);
        if (!self.adj.contains(b)) try self.adj.put(b, try self.allocator.alloc(u64, 0));
    }

    pub fn getNeighbors(self: *FakeGraph, node: u64) ![]u64 {
        return self.adj.get(node) orelse try self.allocator.alloc(u64, 0);
    }
    pub fn getAllNodes(self: *FakeGraph) ![]u64 {
        var tmp = std.ArrayList(u64).init(self.allocator);
        defer tmp.deinit();
        var it = self.adj.iterator();
        while (it.next()) |e| try tmp.append(e.key_ptr.*);
        return tmp.toOwnedSlice();
    }
    pub fn getIncomingEdges(self: *FakeGraph, node: u64) ![]u64 {
        var tmp = std.ArrayList(u64).init(self.allocator);
        defer tmp.deinit();
        var it = self.adj.iterator();
        while (it.next()) |e| {
            const arr = e.value_ptr.*;
            for (arr) |dst| if (dst == node) try tmp.append(e.key_ptr.*);
        }
        return tmp.toOwnedSlice();
    }
    pub fn getOutDegree(self: *FakeGraph, node: u64) !usize {
        return (self.adj.get(node) orelse &[_]u64{}).len;
    }
};

// Adapt expected interface subset
pub const GraphStore = FakeGraph; // alias

// Weighted shortest path test

test "TestCANARY_REQ_GQL_016_PathWeightedCost" {
    const allocator = std.testing.allocator;
    var g = FakeGraph.init(allocator);
    defer g.deinit();
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    try g.addEdge(1, 3); // direct but we will weight differently

    var weights = std.AutoHashMap(u64, f64).init(allocator);
    defer weights.deinit();
    // Assign heavier weight to direct edge (node 3) so path 1->2->3 is preferred
    try weights.put(2, 1.0); // reaching node 2 cost 1
    try weights.put(3, 5.0); // direct path cost 5

    var pa = paths.PathAlgorithms.init(allocator);
    const path_opt = try pa.dijkstraShortestPath(@ptrCast(&g), 1, 3, weights);
    try std.testing.expect(path_opt != null);
    const path = path_opt.?;
    try std.testing.expect(path.nodes.len == 3);
    try std.testing.expect(path.nodes[0] == 1 and path.nodes[1] == 2 and path.nodes[2] == 3);
    try std.testing.expect(path.weight < 5.0);
}
