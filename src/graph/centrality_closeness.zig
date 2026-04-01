const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=ClosenessCentrality; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_Closeness; BENCH=BenchmarkCANARY_REQ_GQL_067_Closeness; OWNER=graph; UPDATED=2025-09-21
// Closeness Centrality (standard) and Harmonic variant for disconnected graphs.
// Standard: (reachable_count - 1) / sum(dist) * scaling (optional)
// Harmonic: sum(1/dist) over reachable (excluding self)

pub const Mode = enum { standard, harmonic };

pub const Params = struct {
    mode: Mode = .standard,
    normalize: bool = true, // scale to (n-1)/(N-1) for comparability when standard
};

pub const Result = struct {
    node_ids: []u64,
    scores: []f64,
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.node_ids);
        allocator.free(self.scores);
        self.* = undefined;
    }
};

pub fn compute(allocator: std.mem.Allocator, g: *const builders.Graph, p: Params) !Result {
    const n = g.nodes.count();
    if (n == 0) return .{ .node_ids = &[_]u64{}, .scores = &[_]f64{} };
    var node_ids = try allocator.alloc(u64, n);
    errdefer allocator.free(node_ids);
    var it = g.nodes.iterator();
    var idx: usize = 0;
    while (it.next()) |e| {
        node_ids[idx] = e.key_ptr.*;
        idx += 1;
    }
    std.sort.sort(u64, node_ids, {}, comptime std.sort.asc(u64));
    var id_to_index = std.AutoHashMap(u64, u64).init(allocator);
    defer id_to_index.deinit();
    for (node_ids, 0..) |id, i| id_to_index.put(id, @as(u64, @intCast(i))) catch {};

    var scores = try allocator.alloc(f64, n);
    errdefer allocator.free(scores);

    var dist = try allocator.alloc(i32, n);
    defer allocator.free(dist);
    var queue = try std.ArrayList(u64).initCapacity(allocator, n);
    defer queue.deinit();

    var s_idx: usize = 0;
    while (s_idx < n) : (s_idx += 1) {
        // Reset distances
        var i: usize = 0;
        while (i < n) : (i += 1) dist[i] = -1;
        queue.clearRetainingCapacity();
        dist[s_idx] = 0;
        try queue.append(@as(u64, @intCast(s_idx)));
        var reach_count: u64 = 1;
        var sum_dist: f64 = 0;
        var harmonic_sum: f64 = 0;
        while (queue.items.len > 0) {
            const v = queue.orderedRemove(0);
            const v_id = node_ids[v];
            var out_it = g.outEdges(v_id);
            while (out_it.next()) |e| {
                const w_idx = id_to_index.get(e.dst) orelse continue;
                if (dist[w_idx] < 0) {
                    dist[w_idx] = dist[v] + 1;
                    reach_count += 1;
                    const d = @as(f64, @floatFromInt(dist[w_idx]));
                    sum_dist += d;
                    harmonic_sum += 1.0 / d;
                    try queue.append(w_idx);
                }
            }
        }
        var score: f64 = 0;
        if (p.mode == .standard) {
            if (sum_dist > 0) {
                score = (@as(f64, @floatFromInt(reach_count - 1))) / sum_dist;
                if (p.normalize and n > 1) {
                    // scale by (reach_count -1)/(n -1) to keep within [0,1]
                    score *= (@as(f64, @floatFromInt(reach_count - 1))) / (@as(f64, @floatFromInt(n - 1)));
                }
            } else {
                score = 0;
            }
        } else { // harmonic
            score = harmonic_sum;
            if (p.normalize and n > 1) score /= (@as(f64, @floatFromInt(n - 1)));
        }
        scores[s_idx] = score;
    }

    return .{ .node_ids = node_ids, .scores = scores };
}

test "TestCANARY_REQ_GQL_067_Closeness basic path" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Path 0-1-2-3-4
    var i: u64 = 0;
    while (i <= 4) : (i += 1) g.addNode(i);
    i = 0;
    while (i < 4) : (i += 1) {
        _ = g.addEdge(i, i + 1, 1) catch {};
        _ = g.addEdge(i + 1, i, 1) catch {};
    }
    var res = try compute(std.testing.allocator, &g, .{ .mode = .standard, .normalize = false });
    defer res.deinit(std.testing.allocator);
    // Middle node 2 should have highest closeness
    var idx0: usize = 0;
    while (idx0 < res.node_ids.len) : (idx0 += 1) if (res.node_ids[idx0] == 0) break;
    var idx1: usize = 0;
    while (idx1 < res.node_ids.len) : (idx1 += 1) if (res.node_ids[idx1] == 1) break;
    var idx2: usize = 0;
    while (idx2 < res.node_ids.len) : (idx2 += 1) if (res.node_ids[idx2] == 2) break;
    try std.testing.expect(res.scores[idx2] > res.scores[idx1]);
    try std.testing.expect(res.scores[idx1] > res.scores[idx0]);
}
