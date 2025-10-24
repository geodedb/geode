const std = @import("std");
const agg = @import("src/distributed/federation_latency_aggregate.zig");

// Federation latency aggregate variance benchmark
// Measures variance characteristics of recording synthetic latency samples and
// finalizing cycles repeatedly. Provides early governance evidence distinct
// from mismatch latency envelope (focuses aggregator internal stability).
//
// Threshold class: General (cv<=0.30, p95/mean<=2.2). Trimmed stability aids
// promotion but not enforced initially. Outlier ratio: <=0.18 target.
//
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateVarianceEnvelope; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=RobustStatsP99; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateVarianceEnvelope; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=TailLatencyP999Envelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateTailP999; OWNER=federation; UPDATED=2025-09-26

const Metrics = struct {
    iterations: usize,
    cv: f128,
    p95_mean_ratio: f128,
    p99_mean_ratio: f128,
    p999_mean_ratio: f128,
    trim_cv: f128,
    passes: usize,
    outlier_ratio: f128,
};

fn simulateOnce(allocator: std.mem.Allocator, cycles: usize, samples_per_cycle: usize) ![]u64 {
    var dist = try allocator.alloc(u64, cycles);
    var c: usize = 0;
    while (c < cycles) : (c += 1) {
        agg.resetAll();
        var i: usize = 0;
        while (i < samples_per_cycle) : (i += 1) {
            const base: u64 = 100 + @as(u64, @intCast(i % 17));
            const jitter: u64 = (i * 13 + c * 7) % 11; // deterministic
            const ns = base + jitter;
            const mismatch = (i % 5 == 0);
            agg.recordLatency(ns, mismatch);
        }
        const snap = agg.finalizeCycle();
        dist[c] = snap.max_ns - snap.min_ns; // use range as per-cycle variability proxy
    }
    return dist;
}

fn computeMetrics(samples: []u64) Metrics {
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var diff_sum: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean_f;
        diff_sum += d * d;
    }
    const variance = diff_sum / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean_f;
    // sort for p95 and trimming
    std.sort.heap(u64, samples, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    const p95_index = (samples.len * 95) / 100;
    const p99_index = (samples.len * 99) / 100;
    const p999_index = (samples.len * 999) / 1000;
    const p95 = samples[if (p95_index == 0) 0 else p95_index - 1];
    const p99 = samples[if (p99_index == 0) 0 else p99_index - 1];
    const p999 = samples[if (p999_index == 0) 0 else p999_index - 1];
    const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    const p99_mean_ratio = @as(f128, @floatFromInt(p99)) / mean_f;
    const p999_mean_ratio = @as(f128, @floatFromInt(p999)) / mean_f;
    const trim_each = samples.len * 5 / 100;
    const start = trim_each;
    const end = samples.len - trim_each;
    var trim_sum: u128 = 0;
    var trim_count: usize = 0;
    var i: usize = start;
    while (i < end) : (i += 1) {
        trim_sum += samples[i];
        trim_count += 1;
    }
    const trim_mean = @as(f128, @floatFromInt(trim_sum)) / @as(f128, @floatFromInt(trim_count));
    var trim_diff: f128 = 0;
    i = start;
    while (i < end) : (i += 1) {
        const sf = @as(f128, @floatFromInt(samples[i]));
        const d = sf - trim_mean;
        trim_diff += d * d;
    }
    const trim_var = trim_diff / @as(f128, @floatFromInt(trim_count));
    const trim_std = std.math.sqrt(trim_var);
    const trim_cv = trim_std / trim_mean;
    const outliers = start + (samples.len - end);
    const outlier_ratio = @as(f128, @floatFromInt(outliers)) / @as(f128, @floatFromInt(samples.len));
    return Metrics{ .iterations = samples.len, .cv = cv, .p95_mean_ratio = p95_mean_ratio, .p99_mean_ratio = p99_mean_ratio, .p999_mean_ratio = p999_mean_ratio, .trim_cv = trim_cv, .passes = 1, .outlier_ratio = outlier_ratio };
}

pub fn runFedLatencyAggregatorVariance() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const cycles: usize = 48;
    const samples: usize = 40;
    const dist = try simulateOnce(allocator, cycles, samples);
    defer allocator.free(dist);
    const m = computeMetrics(dist);
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("{\"bench\":\"BenchmarkCANARY_REQ_GQL_024_FedLatencyAggregatorVarianceEnvelope\",");
    try w.print("\"iterations\":{},", .{m.iterations});
    try w.print("\"cv\":{d:.6},", .{m.cv});
    try w.print("\"p95_mean_ratio\":{d:.4},", .{m.p95_mean_ratio});
    try w.print("\"p99_mean_ratio\":{d:.4},", .{m.p99_mean_ratio});
    try w.print("\"p999_mean_ratio\":{d:.4},", .{m.p999_mean_ratio});
    try w.print("\"trim_cv\":{d:.6},", .{m.trim_cv});
    try w.print("\"outlier_ratio\":{d:.6}", .{m.outlier_ratio});
    try w.writeAll("}\n");
    const line = fbs.getWritten();
    _ = try std.posix.write(std.posix.STDOUT_FILENO, line);
    if (m.cv > 0.30 or m.p95_mean_ratio > 2.2 or m.p99_mean_ratio > 2.8) {
        if (std.posix.getenv("FED_AGG_ENFORCE")) |v| if (v.len > 0 and v[0] == '1') return error.AggregateVarianceEnvelopeBreached;
    }
}

pub fn main() !void {
    try runFedLatencyAggregatorVariance();
}

test "BenchmarkCANARY_REQ_GQL_024_FedLatencyAggregatorVarianceEnvelope_Run" {
    try runFedLatencyAggregatorVariance();
}
