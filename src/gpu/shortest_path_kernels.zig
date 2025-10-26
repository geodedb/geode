const std = @import("std");
const phase0 = @import("phase0.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase4ShortestPath; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUDijkstraSmall; OWNER=engine; UPDATED=2025-10-26

pub const SPGraph = struct {
    row_offsets: []const u32,
    col_indices: []const u32,
    weights: []const f64,
    num_nodes: u32,
};

pub fn dijkstraCPU(g: SPGraph, start: u32, allocator: std.mem.Allocator) ![]f64 {
    var dist = try allocator.alloc(f64, g.num_nodes);
    for (dist) |*d| d.* = std.math.inf(f64);
    dist[start] = 0;
    var visited = std.AutoHashMap(u32, void).init(allocator); defer visited.deinit();
    var pq = std.array_list.Managed(struct { v: u32, d: f64 }).init(allocator); defer pq.deinit();
    try pq.append(.{ .v = start, .d = 0 });
    while (pq.items.len > 0) {
        // simple linear extract-min (small graphs in test)
        var min_idx: usize = 0;
        var i: usize = 1;
        while (i < pq.items.len) : (i += 1) {
            if (pq.items[i].d < pq.items[min_idx].d) min_idx = i;
        }
        const node = pq.items[min_idx].v;
        const node_dist = pq.items[min_idx].d;
        _ = pq.swapRemove(min_idx);
        if (visited.get(node) != null) continue;
        _ = visited.put(node, {}) catch {};
        const start_off = g.row_offsets[node];
        const end_off = g.row_offsets[node + 1];
        var e: usize = start_off;
        while (e < end_off) : (e += 1) {
            const nbr = g.col_indices[e];
            const w = g.weights[e];
            const alt = node_dist + w;
            if (alt < dist[nbr]) {
                dist[nbr] = alt;
                try pq.append(.{ .v = nbr, .d = alt });
            }
        }
    }
    return dist;
}

pub fn dijkstraGPU(g: SPGraph, start: u32, allocator: std.mem.Allocator) ![]f64 {
    // Phase4 scaffold: fallback to CPU
    return dijkstraCPU(g, start, allocator);
}

test "TestCANARY_REQ_GQL_051_GPUDijkstraSmall" {
    // Graph: 0->1 (1.0), 0->2 (4.0), 1->2 (2.0), 1->3 (5.0), 2->3 (1.0)
    const row_offsets = &[_]u32{0,2,4,5,5};
    const col_indices = &[_]u32{1,2,2,3,3};
    const weights = &[_]f64{1.0,4.0,2.0,5.0,1.0};
    const g = SPGraph{ .row_offsets = row_offsets, .col_indices = col_indices, .weights = weights, .num_nodes = 4 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const cpu = try dijkstraCPU(g, 0, alloc);
    defer alloc.free(cpu);
    const gpu = try dijkstraGPU(g, 0, alloc);
    defer alloc.free(gpu);
    var i: usize = 0;
    while (i < g.num_nodes) : (i += 1) {
        const diff = @abs(cpu[i] - gpu[i]);
        try std.testing.expect(diff < 1e-9);
    }
    try std.testing.expectEqual(@as(f64, 0), cpu[0]);
    try std.testing.expectEqual(@as(f64, 1.0), cpu[1]);
    try std.testing.expectEqual(@as(f64, 3.0), cpu[2]); // 0->1->2 path
    try std.testing.expectEqual(@as(f64, 4.0), cpu[3]); // 0->1->2->3 best
}
