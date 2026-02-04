const std = @import("std");

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Adaptive Policy"; ASPECT=Storage; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_SnapshotAdaptivePolicy; OWNER=storage; UPDATED=2026-02-04

const SegmentMeta = struct {
    id: u32,
    live_bytes: usize,
    dead_bytes: usize,
};

const CompactionContext = struct {
    segments: []SegmentMeta,
    threshold: f64,
};

fn compact(ctx: *CompactionContext) usize {
    var compacted: usize = 0;
    for (ctx.segments) |seg| {
        const denom = seg.live_bytes + seg.dead_bytes;
        if (denom == 0) continue;
        const ratio = @as(f64, @floatFromInt(seg.dead_bytes)) / @as(f64, @floatFromInt(denom));
        if (ratio >= ctx.threshold) compacted += 1;
    }
    return compacted;
}

fn simulateAdaptive(ctx: *CompactionContext, rounds: usize, adaptive: bool) usize {
    var total: usize = 0;
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        if (adaptive and (r % 5 == 0)) {
            // adjust threshold heuristically based on fragmentation ratio
            var live: usize = 0;
            var dead: usize = 0;
            for (ctx.segments) |seg| {
                live += seg.live_bytes;
                dead += seg.dead_bytes;
            }
            const ratio = @as(f64, @floatFromInt(dead)) / @as(f64, @floatFromInt(live + dead));
            ctx.threshold = if (ratio > 0.25) 0.15 else if (ratio < 0.10) 0.30 else 0.20;
        }
        total += compact(ctx);
    }
    return total;
}

test "BenchmarkCANARY_REQ_GQL_028_SnapshotAdaptivePolicy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var segs = std.ArrayList(SegmentMeta).init(allocator);
    defer segs.deinit();
    var i: usize = 0;
    while (i < 1500) : (i += 1) try segs.append(.{ .id = @intCast(i), .live_bytes = 2048, .dead_bytes = 512 });

    var ctx_static = CompactionContext{ .segments = segs.items, .threshold = 0.20 };
    var ctx_adapt = CompactionContext{ .segments = segs.items, .threshold = 0.20 };

    var t1 = try std.time.Timer.start();
    const c_static = simulateAdaptive(&ctx_static, 300, false);
    const ns_static = t1.read();

    var t2 = try std.time.Timer.start();
    const c_adapt = simulateAdaptive(&ctx_adapt, 300, true);
    const ns_adapt = t2.read();

    std.debug.print("SnapshotAdaptivePolicy static_compacted={d} ns={d} adaptive_compacted={d} ns={d}\n", .{ c_static, ns_static, c_adapt, ns_adapt });
}
