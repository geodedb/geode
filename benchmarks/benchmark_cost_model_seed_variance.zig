const std = @import("std");
const seed = @import("../src/planner/cost_seed.zig");

// Benchmark cost model seed variance envelope.
// Measures stability of estimation + cost evaluation loop by executing a synthetic
// operator pipeline multiple times and recording total estimated cost (as a proxy latency metric).
// Thresholds (General class): CV <= 0.20, p95/mean <= 2.55
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=EstimatorPrimitives; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_075_CostModelSeedVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

fn nextRand(state: *u64) f64 {
    state.* = (state.* * 6364136223846793005 + 1) % 0xffffffffffffffff;
    const mant = (@as(f64, @floatFromInt(state.* & 0xFFFFFF)) / 0xFFFFFF);
    return mant; // [0,1)
}

fn runPipeline(iter_seed: usize) f64 {
    const cfg = seed.EstimatorConfig{};
    var l: u64 = @intCast(iter_seed * 48271 + 1);
    const scan_est = seed.estimate(.{ .kind = .Scan }, &[_]seed.CardinalityEstimate{}, cfg);
    const expand_est = seed.estimate(.{ .kind = .Expand }, &[_]seed.CardinalityEstimate{scan_est}, cfg);
    // introduce 3 filters with slight selectivity noise
    var cur = expand_est;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const sel_noise = 0.15 + (nextRand(&l) * 0.25); // 0.15..0.40
        cur = seed.estimate(.{ .kind = .Filter, .selectivity = sel_noise }, &[_]seed.CardinalityEstimate{cur}, cfg);
    }
    const agg = seed.estimate(.{ .kind = .Aggregate }, &[_]seed.CardinalityEstimate{cur}, cfg);
    const sort = seed.estimate(.{ .kind = .Sort }, &[_]seed.CardinalityEstimate{agg}, cfg);
    const limit = seed.estimate(.{ .kind = .Limit }, &[_]seed.CardinalityEstimate{sort}, cfg);
    // Sum costs
    var total: f64 = 0;
    const ests = [_]seed.CardinalityEstimate{ scan_est, expand_est, cur, agg, sort, limit };
    var idx: usize = 0;
    while (idx < ests.len) : (idx += 1) {
        const est = ests[idx];
        const kind: seed.LogicalOpKind = switch (idx) {
            0 => .Scan,
            1 => .Expand,
            2 => .Filter,
            3 => .Aggregate,
            4 => .Sort,
            else => .Limit,
        };
        total += seed.cost(.{ .kind = kind }, est, cfg).total();
    }
    return total;
}

pub fn benchmarkCostModelSeedVarianceEnvelope() !void {
    const iterations = 96; // enough for stable estimates
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var samples = try gpa.allocator().alloc(f64, iterations);
    defer gpa.allocator().free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        samples[i] = runPipeline(i + 1);
    }
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, s);
    const mean_f = sum / @as(f128, @floatFromInt(samples.len));
    var diff_sum: f128 = 0;
    for (samples) |s| {
        const d = @as(f128, s) - mean_f;
        diff_sum += d * d;
    }
    const variance = diff_sum / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean_f;
    std.sort.sort(f64, samples, {}, comptime struct {
        fn lessThan(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.lessThan);
    const p95_index = (samples.len * 95) / 100;
    const p95 = samples[p95_index];
    const p95_mean_ratio = @as(f128, p95) / mean_f;
    const pass = !(cv > 0.20 or p95_mean_ratio > 2.55);
    // Emit JSON lines (schema_version 1 & 2) similar to pagination benchmark formatting.
    const scale = 10000.0;
    var buf1: [512]u8 = undefined;
    var fbs1 = std.io.fixedBufferStream(&buf1);
    const w1 = fbs1.writer();
    w1.print("{s}", .{"{\"schema_version\":1,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"cost_model_seed_variance\","}) catch {};
    w1.print("\"mean_scaled_ppm\":{d},", .{@as(u64, @intFromFloat((mean_f) * scale))}) catch {};
    w1.print("\"cv_scaled_ppm\":{d},", .{@as(u64, @intFromFloat((cv) * scale))}) catch {};
    w1.print("\"p95_mean_ratio_scaled_ppm\":{d},", .{@as(u64, @intFromFloat((p95_mean_ratio) * scale))}) catch {};
    w1.print("\"pass\":{s}}\n", .{if (pass) "true" else "false"}) catch {};
    std.debug.print("{s}", .{fbs1.getWritten()});
    // schema_version 2 extended
    var buf2: [640]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf2);
    const w2 = fbs2.writer();
    const jitter_class = if (cv < 0.10) "low" else if (cv < 0.20) "medium" else "high";
    w2.print("{s}", .{"{\"schema_version\":2,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"cost_model_seed_variance\",\"class\":\"General\","}) catch {};
    w2.print("\"sample_count\":{d},", .{iterations}) catch {};
    w2.print("\"mean_scaled_ppm\":{d},", .{@as(u64, @intFromFloat(mean_f * scale))}) catch {};
    w2.print("\"cv_scaled_ppm\":{d},", .{@as(u64, @intFromFloat(cv * scale))}) catch {};
    w2.print("\"p95_mean_ratio_scaled_ppm\":{d},", .{@as(u64, @intFromFloat(p95_mean_ratio * scale))}) catch {};
    w2.print("\"jitter_class\":\"{s}\",", .{jitter_class}) catch {};
    // thresholds array
    const cv_thresh = 0.20;
    const ratio_thresh = 2.55;
    w2.print("\"thresholds_evaluated\":[{s}{s}],", .{ blk: {
        var tmp: [128]u8 = undefined;
        const fb = std.io.fixedBufferStream(&tmp);
        const wr = fb.writer();
        wr.print("{s}", .{"{\"metric\":\"cv_scaled_ppm\",\"actual\":"}) catch {};
        wr.print("{d}", .{@as(u64, @intFromFloat(cv * scale))}) catch {};
        wr.print(",\"max\":{d},\"pass\":{s}}", .{ @as(u64, @intFromFloat(cv_thresh * scale)), if (cv <= cv_thresh) "true" else "false" }) catch {};
        break :blk fb.getWritten();
    }, blk2: {
        var tmp2: [128]u8 = undefined;
        const fb2 = std.io.fixedBufferStream(&tmp2);
        const wr2 = fb2.writer();
        wr2.print("{s}", .{"{\"metric\":\"p95_mean_ratio_scaled_ppm\",\"actual\":"}) catch {};
        wr2.print("{d}", .{@as(u64, @intFromFloat(p95_mean_ratio * scale))}) catch {};
        wr2.print(",\"max\":{d},\"pass\":{s}}", .{ @as(u64, @intFromFloat(ratio_thresh * scale)), if (p95_mean_ratio <= ratio_thresh) "true" else "false" }) catch {};
        break :blk2 fb2.getWritten();
    } }) catch {};
    w2.print("\"pass\":{s}}\n", .{if (pass) "true" else "false"}) catch {};
    std.debug.print("{s}", .{fbs2.getWritten()});
    if (!pass) return error.VarianceEnvelopeBreached;
}

test "BenchmarkCANARY_REQ_GQL_075_CostModelSeedVarianceEnvelope" {
    try benchmarkCostModelSeedVarianceEnvelope();
}
