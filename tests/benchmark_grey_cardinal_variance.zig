const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const grey = geode.graph.grey_cardinal;

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=GreyCardinalVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_067_GreyCardinalVarianceEnvelope; OWNER=graph; UPDATED=2025-09-21

fn buildSynthetic(allocator: std.mem.Allocator, clusters: u32, cluster_size: u32) !builders.Graph {
    var g = builders.Graph.init(allocator);
    var cluster: u32 = 0;
    var base: u32 = 0;
    while (cluster < clusters) : (cluster += 1) {
        const center = base;
        g.addNode(center);
        var k: u32 = 1;
        while (k <= cluster_size) : (k += 1) {
            g.addNode(base + k);
            _ = g.addEdge(center, base + k, 1) catch {};
            _ = g.addEdge(base + k, center, 1) catch {};
            if (k > 1) {
                _ = g.addEdge(base + k - 1, base + k, 1) catch {};
                _ = g.addEdge(base + k, base + k - 1, 1) catch {};
            }
        }
        if (cluster > 0) {
            const prev_center = base - (cluster_size + 1);
            _ = g.addEdge(prev_center, center, 1) catch {};
            _ = g.addEdge(center, prev_center, 1) catch {};
        }
        base += cluster_size + 1;
    }
    if (clusters > 1) {
        const last_center = base - (cluster_size + 1);
        _ = g.addEdge(0, last_center, 1) catch {};
        _ = g.addEdge(last_center, 0, 1) catch {};
    }
    return g;
}

fn stats(data: []u64) struct { mean: f64, stddev: f64, p95: f64 } {
    if (data.len == 0) return .{ .mean = 0, .stddev = 0, .p95 = 0 };
    var sum: f64 = 0;
    for (data) |v| sum += @as(f64, @floatFromInt(v));
    const mean = sum / @as(f64, @floatFromInt(data.len));
    var var_acc: f64 = 0;
    for (data) |v| {
        const dv = @as(f64, @floatFromInt(v)) - mean;
        var_acc += dv * dv;
    }
    const variance = var_acc / @as(f64, @floatFromInt(data.len));
    const scratch = try std.testing.allocator.alloc(u64, data.len);
    defer std.testing.allocator.free(scratch);
    // copy
    std.mem.copy(u64, scratch, data);
    std.sort.pdq(u64, scratch, {}, std.sort.asc(u64));
    const idx_p95 = (scratch.len * 95 + 99) / 100 - 1; // ceil
    return .{ .mean = mean, .stddev = @sqrt(variance), .p95 = @as(f64, @floatFromInt(scratch[idx_p95])) };
}

test "BenchmarkCANARY_REQ_GQL_067_GreyCardinalVarianceEnvelope" {
    var g = try buildSynthetic(std.testing.allocator, 6, 12);
    defer g.deinit();
    var runs: usize = 0;
    var samples = try std.testing.allocator.alloc(u64, 9);
    defer std.testing.allocator.free(samples);
    while (runs < samples.len) : (runs += 1) {
        const start = std.time.nanoTimestamp();
        var result = try grey.compute(std.testing.allocator, &g, .{ .normalize_final = true });
        result.deinit(std.testing.allocator);
        const end = std.time.nanoTimestamp();
        samples[runs] = @intCast(end - start);
    }
    const s = stats(samples);
    const cv = if (s.mean > 0) s.stddev / s.mean else 0;
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"grey_cardinal_variance\",\"mean_ns\":{d},\"stddev_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(s.mean)), @as(u64, @intFromFloat(s.stddev)), cv, @as(u64, @intFromFloat(s.p95)) });
    // Guardrails: coefficient of variation < 0.15 and p95 < 3x mean (avoid pathological jitter)
    try std.testing.expect(cv < 0.15);
    try std.testing.expect(s.p95 < s.mean * 3.0);
}
