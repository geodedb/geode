// CANARY: REQ=REQ-GQL-066; FEATURE="Flow/Matching"; ASPECT=EdmondsKarp; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_066_EdmondsKarp; BENCH=BenchmarkCANARY_REQ_GQL_066_EdmondsKarp; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");
const builders = @import("builders.zig");

fn key(src: u32, dst: u32) u64 {
    return (@as(u64, src) << 32) | @as(u64, dst);
}

pub fn maxFlow(alloc: std.mem.Allocator, g: *const builders.Graph, source: u32, sink: u32) !f64 {
    if (source == sink) return 0;
    if (!g.nodes.contains(source) or !g.nodes.contains(sink)) return 0;
    var cap = std.AutoHashMap(u64, f64).init(alloc);
    defer cap.deinit();
    for (g.edges.items) |e| {
        const k = key(e.src, e.dst);
        if (cap.get(k)) |existing| {
            try cap.put(k, existing + e.w);
        } else try cap.put(k, e.w);
        const rk = key(e.dst, e.src);
        if (!cap.contains(rk)) try cap.put(rk, 0);
    }
    var flow: f64 = 0;
    while (true) {
        var parent = std.AutoHashMap(u32, u32).init(alloc);
        defer parent.deinit();
        var edge_cap = std.AutoHashMap(u32, f64).init(alloc);
        defer edge_cap.deinit();
        var queue = std.ArrayList(u32).init(alloc);
        defer queue.deinit();
        try queue.append(source);
        try parent.put(source, source);
        try edge_cap.put(source, std.math.inf(f64));
        var found = false;
        while (queue.items.len > 0 and !found) {
            const v = queue.items[0];
            std.mem.copy(u32, queue.items[0 .. queue.items.len - 1], queue.items[1..]);
            _ = queue.pop();
            var out_it = g.outEdges(v);
            while (out_it.next()) |e| {
                const k = key(e.src, e.dst);
                const residual = cap.get(k) orelse 0;
                if (residual > 0 and !parent.contains(e.dst)) {
                    try parent.put(e.dst, e.src);
                    try edge_cap.put(e.dst, @min(edge_cap.get(v) orelse 0, residual));
                    try queue.append(e.dst);
                    if (e.dst == sink) {
                        found = true;
                        break;
                    }
                }
            }
        }
        if (!found) break;
        const path_cap = edge_cap.get(sink) orelse 0;
        if (path_cap <= 0) break;
        flow += path_cap;
        var cur = sink;
        while (cur != source) {
            const prev = parent.get(cur) orelse break;
            const fwd_k = key(prev, cur);
            const rev_k = key(cur, prev);
            const fwd_res = cap.get(fwd_k) orelse 0;
            _ = try cap.put(fwd_k, fwd_res - path_cap);
            const rev_res = cap.get(rev_k) orelse 0;
            _ = try cap.put(rev_k, rev_res + path_cap);
            cur = prev;
        }
    }
    return flow;
}

test "TestCANARY_REQ_GQL_066_EdmondsKarp basic max flow" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2, 3);
    try g.addEdge(1, 3, 2);
    try g.addEdge(2, 3, 1);
    try g.addEdge(2, 4, 2);
    try g.addEdge(3, 4, 3);
    try g.rebuildIndex(std.testing.allocator);
    const f = try maxFlow(std.testing.allocator, &g, 1, 4);
    try std.testing.expect(std.math.fabs(f - 5) < 1e-9);
}
