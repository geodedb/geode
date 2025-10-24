const std = @import("std");
const seed = @import("../src/planner/cost_seed.zig");

// Benchmark adaptive estimator post-calibration error variance envelope.
// Simulates multiple operator chains, applies adaptive bias updates, then
// measures absolute percentage error distribution across a second evaluation pass.
// Thresholds (General class): CV <= 0.22, p95/mean <= 2.55
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

fn simulateChain(reg: *seed.AdaptiveBiasRegistry, cfg: seed.EstimatorConfig, state: *u64) struct { mape_before: f64, mape_after: f64 } {
    // Randomly choose a chain length 3..6 and random op kinds sequence (simple subset)
    // Use modulo approach for chain length 3..6
    state.* = state.* * 6364136223846793005 + 1;
    const chain_len = 3 + (@as(usize, @intCast((state.* >> 32) % 4)));
    var ops_buf: [6]seed.OpDescriptor = undefined;
    var i: usize = 0;
    while (i < chain_len) : (i += 1) {
        state.* = state.* * 6364136223846793005 + 1;
        const r = (state.* >> 32) % 5;
        const kind = switch (r) {
            0 => seed.LogicalOpKind.Scan,
            1 => seed.LogicalOpKind.Expand,
            2 => seed.LogicalOpKind.Filter,
            3 => seed.LogicalOpKind.Project,
            else => seed.LogicalOpKind.Limit,
        };
        state.* = state.* * 6364136223846793005 + 1;
        const sel_rand = @as(f64, @floatFromInt((state.* >> 32) & 0xffff)) / 65535.0;
        ops_buf[i] = .{ .kind = kind, .selectivity = 0.1 + sel_rand * 0.8 };
    }
    const ops = ops_buf[0..chain_len];
    // Pass 1: baseline estimates + synthetic actuals with random bias factors per kind
    var ests = [_]f64{0} ** 6;
    var actuals = [_]f64{0} ** 6;
    // Assign per-kind bias from distributions (Scan underest 1.2-1.6, Expand overest 0.5-0.9, Filter near 0.8-1.2, others 0.7-1.3)
    state.* = state.* * 6364136223846793005 + 1;
    const scan_bias = 1.2 + (@as(f64, @floatFromInt((state.* >> 32) & 0xffff)) / 65535.0) * 0.4;
    state.* = state.* * 6364136223846793005 + 1;
    const expand_bias = 0.5 + (@as(f64, @floatFromInt((state.* >> 32) & 0xffff)) / 65535.0) * 0.4;
    state.* = state.* * 6364136223846793005 + 1;
    const filter_bias = 0.8 + (@as(f64, @floatFromInt((state.* >> 32) & 0xffff)) / 65535.0) * 0.4;
    state.* = state.* * 6364136223846793005 + 1;
    const generic_low = 0.7 + (@as(f64, @floatFromInt((state.* >> 32) & 0xffff)) / 65535.0) * 0.6;
    var prev_cards: [1]seed.CardinalityEstimate = undefined;
    var prev_len: usize = 0;
    i = 0;
    while (i < ops.len) : (i += 1) {
        const slice = if (prev_len == 0) prev_cards[0..0] else prev_cards[0..1];
        const c = seed.estimate(ops[i], slice, cfg);
        ests[i] = c.rows;
        const bias = switch (ops[i].kind) {
            .Scan => scan_bias,
            .Expand => expand_bias,
            .Filter => filter_bias,
            else => generic_low,
        };
        const act = c.rows * bias;
        actuals[i] = switch (ops[i].kind) {
            .Limit => @min(act, 100.0),
            else => act,
        };
        prev_cards[0] = c;
        prev_len = 1;
    }
    var mape_before: f64 = 0;
    i = 0;
    while (i < ops.len) : (i += 1) {
        const a = actuals[i];
        const e = ests[i];
        const diff = if (e > a) e - a else a - e;
        mape_before += diff / a;
        reg.update(ops[i].kind, e, a, cfg.adaptive_alpha);
    }
    mape_before /= @as(f64, @floatFromInt(ops.len));
    // Pass 2: biased estimates
    prev_len = 0;
    i = 0;
    var ests2 = [_]f64{0} ** 6;
    while (i < ops.len) : (i += 1) {
        const slice = if (prev_len == 0) prev_cards[0..0] else prev_cards[0..1];
        const base = seed.estimate(ops[i], slice, cfg);
        const biased_rows = reg.apply(ops[i].kind, base.rows);
        ests2[i] = biased_rows;
        prev_cards[0] = .{ .rows = biased_rows, .confidence = base.confidence };
        prev_len = 1;
    }
    var mape_after: f64 = 0;
    i = 0;
    while (i < ops.len) : (i += 1) {
        const a = actuals[i];
        const e = ests2[i];
        const diff = if (e > a) e - a else a - e;
        mape_after += diff / a;
    }
    mape_after /= @as(f64, @floatFromInt(ops.len));
    return .{ .mape_before = mape_before, .mape_after = mape_after };
}

pub fn benchmarkAdaptiveEstimatorBiasVarianceEnvelope() !void {
    var seed_state: u64 = 0xdecafbadcafebabe;
    var reg = seed.AdaptiveBiasRegistry{};
    const cfg = seed.EstimatorConfig{ .adaptive_alpha = 0.25 };
    const iterations = 64;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var samples = try gpa.allocator().alloc(f64, iterations);
    defer gpa.allocator().free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const r = simulateChain(&reg, cfg, &seed_state);
        // record improvement ratio (before/after) to ensure distribution stabilization
        const improvement = if (r.mape_after <= 0 or r.mape_before <= 0) 1.0 else r.mape_before / r.mape_after;
        samples[i] = improvement;
    }
    // compute mean
    var sum: f128 = 0;
    for (samples) |s| sum += s;
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
    const p95_mean_ratio = p95 / mean_f;
    if (cv > 0.22 or p95_mean_ratio > 2.55 or mean_f < 1.05) { // require at least 5% avg improvement
        std.debug.print("Adaptive estimator variance envelope breached: cv={d:.4} p95/mean={d:.4} mean_improve={d:.4}\n", .{ cv, p95_mean_ratio, mean_f });
        return error.VarianceEnvelopeBreached;
    }
}

test "BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasVarianceEnvelope" {
    try benchmarkAdaptiveEstimatorBiasVarianceEnvelope();
}
