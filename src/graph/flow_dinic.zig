const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-066; FEATURE="Flow/Matching"; ASPECT=Dinic; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_066_DinicBasic; BENCH=BenchmarkCANARY_REQ_GQL_066_Dinic; OWNER=graph; UPDATED=2025-09-21

fn key(src: u32, dst: u32) u64 {
    return (@as(u64, src) << 32) | @as(u64, dst);
}

pub fn maxFlow(alloc: std.mem.Allocator, g: *const builders.Graph, source: u32, sink: u32) !f64 {
    if (source == sink) return 0;
    if (!g.nodes.contains(source) or !g.nodes.contains(sink)) return 0;
    var cap = std.AutoHashMap(u64, f64).init(alloc);
    defer cap.deinit();
    // Build residual capacities
    for (g.edges.items) |e| {
        const k = key(e.src, e.dst);
        if (cap.get(k)) |existing| {
            try cap.put(k, existing + e.w);
        } else try cap.put(k, e.w);
        const rk = key(e.dst, e.src);
        if (!cap.contains(rk)) try cap.put(rk, 0);
    }

    var flow: f64 = 0;
    const inf = std.math.inf(f64);
    // Level graph + blocking flow loop
    while (true) {
        // BFS build levels
        var level = std.AutoHashMap(u32, u32).init(alloc);
        defer level.deinit();
        var q = std.ArrayList(u32).init(alloc);
        defer q.deinit();
        try q.append(source);
        try level.put(source, 0);
        var qi: usize = 0;
        var sink_reached = false;
        while (qi < q.items.len) {
            const v = q.items[qi];
            qi += 1;
            var it = g.outEdges(v);
            while (it.next()) |e| {
                const residual = cap.get(key(e.src, e.dst)) orelse 0;
                if (residual > 0 and !level.contains(e.dst)) {
                    const lv = (level.get(v) orelse 0) + 1;
                    try level.put(e.dst, lv);
                    try q.append(e.dst);
                    if (e.dst == sink) sink_reached = true;
                }
            }
        }
        if (!sink_reached) break; // no more augmenting paths in level graph

        // DFS blocking flows - store per-node edge iteration state (iterators recreated each call)
        var stack = std.ArrayList(struct { v: u32, pushed: bool, send: f64 }).init(alloc);
        defer stack.deinit();
        // We'll implement recursive-style DFS iteratively.
        var path = std.ArrayList(u32).init(alloc); // for debug / potential capture (not used in result)
        defer path.deinit();

        // To avoid recreating iterators too often, we keep adjacency cursor index per vertex.
        var cursor = std.AutoHashMap(u32, usize).init(alloc);
        defer cursor.deinit();

        while (true) {
            // Start DFS attempt
            var sent_total: f64 = 0;
            stack.clearRetainingCapacity();
            path.clearRetainingCapacity();
            try stack.append(.{ .v = source, .pushed = false, .send = inf });
            var augmented = false;
            while (stack.items.len > 0) {
                const top = stack.items[stack.items.len - 1];
                if (top.v == sink) {
                    // Found path, push flow
                    const send_amt = top.send;
                    if (send_amt <= 0 or send_amt == inf) break; // nothing meaningful
                    // Walk path to apply residual adjustments
                    var prev: ?u32 = null;
                    // Reconstruct by scanning stack order
                    var i: usize = 0;
                    while (i < stack.items.len) : (i += 1) {
                        const cur = stack.items[i].v;
                        if (prev) |p| {
                            const fwd = key(p, cur);
                            const rev = key(cur, p);
                            const fwd_res = cap.get(fwd) orelse 0;
                            _ = try cap.put(fwd, fwd_res - send_amt);
                            const rev_res = cap.get(rev) orelse 0;
                            _ = try cap.put(rev, rev_res + send_amt);
                        }
                        prev = cur;
                    }
                    flow += send_amt;
                    sent_total += send_amt;
                    augmented = true;
                    break; // attempt another blocking path search
                }
                // Iterate adjacency respecting level graph
                const base_level = level.get(top.v) orelse 0;
                var out_it = g.outEdges(top.v);
                // Advance iterator 'cursor' times if we have a stored index
                const cur_idx = cursor.get(top.v) orelse 0;
                var advance: usize = 0;
                while (advance < cur_idx) : (advance += 1) {
                    if (out_it.next() == null) break; // safety
                }
                var advanced_this_round = false;
                while (out_it.next()) |e| {
                    const idx = (cursor.get(top.v) orelse 0) + 1;
                    _ = cursor.put(top.v, idx) catch unreachable;
                    const residual = cap.get(key(e.src, e.dst)) orelse 0;
                    if (residual <= 0) continue;
                    const nl = level.get(e.dst) orelse inf;
                    if (nl != base_level + 1) continue; // must go to next level
                    const send_amt = @min(top.send, residual);
                    try stack.append(.{ .v = e.dst, .pushed = false, .send = send_amt });
                    advanced_this_round = true;
                    break;
                }
                if (!advanced_this_round) {
                    // Dead end, backtrack
                    _ = stack.pop();
                }
            }
            if (!augmented) break; // no further blocking flow paths this level graph
        }
    }
    return flow;
}

test "TestCANARY_REQ_GQL_066_DinicBasic" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2, 3);
    try g.addEdge(1, 3, 2);
    try g.addEdge(2, 3, 1);
    try g.addEdge(2, 4, 2);
    try g.addEdge(3, 4, 3);
    try g.rebuildIndex(std.testing.allocator);
    const f = try maxFlow(std.testing.allocator, &g, 1, 4);
    try std.testing.expect(std.math.fabs(f - 5) < 1e-9); // same as Edmonds-Karp example
}
