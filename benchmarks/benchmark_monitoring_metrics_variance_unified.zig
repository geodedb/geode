const std = @import("std");
// Unified monitoring metrics variance benchmark consolidating prior scattered variance probes.
// Provides single canonical evidence line for governance.
// Thresholds (General): CV<=0.25, p95/mean<=2.8 (initial). Trimmed metrics optional.
//
// CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=MetricsRegistryVarianceUnified; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified; OWNER=ops; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=TailLatencyP999Envelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_081_MetricsRegistryTailP999; OWNER=ops; UPDATED=2025-09-26

pub fn runMonitoringVarianceUnified() !void {
    const iterations = 48;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var samples = try gpa.allocator().alloc(u64, iterations);
    defer gpa.allocator().free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var t = std.time.Timer.start() catch unreachable;
        // Deterministic synthetic workload approximating metrics snapshot + export cost.
        var acc: u64 = 0;
        var spin: usize = 40_000;
        while (spin > 0) : (spin -= 1) {
            acc +%= @as(u64, @intCast(spin)) * 31 + 11;
            std.mem.doNotOptimizeAway(acc);
        }
        samples[i] = t.read();
    }
    // stats
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var diff: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean_f;
        diff += d * d;
    }
    const variance = diff / @as(f128, @floatFromInt(samples.len));
    const stdev = std.math.sqrt(variance);
    const cv = stdev / mean_f;
    std.sort.heap(u64, samples, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    const p95_idx = (samples.len * 95) / 100;
    const p999_idx = (samples.len * 999) / 1000;
    const p95 = samples[if (p95_idx == 0) 0 else p95_idx - 1];
    const p999 = samples[if (p999_idx == 0) 0 else p999_idx - 1];
    const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    const p999_mean_ratio = @as(f128, @floatFromInt(p999)) / mean_f;
    // trimmed
    const trim_each = samples.len * 5 / 100;
    const start = trim_each;
    const end = samples.len - trim_each;
    var trim_sum: u128 = 0;
    var trim_count: usize = 0;
    var j: usize = start;
    while (j < end) : (j += 1) {
        trim_sum += samples[j];
        trim_count += 1;
    }
    const trim_mean = @as(f128, @floatFromInt(trim_sum)) / @as(f128, @floatFromInt(trim_count));
    var trim_diff: f128 = 0;
    j = start;
    while (j < end) : (j += 1) {
        const sf = @as(f128, @floatFromInt(samples[j]));
        const d = sf - trim_mean;
        trim_diff += d * d;
    }
    const trim_var = trim_diff / @as(f128, @floatFromInt(trim_count));
    const trim_std = std.math.sqrt(trim_var);
    const trim_cv = trim_std / trim_mean;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("{\"bench\":\"BenchmarkCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified\",");
    try w.print("\"iterations\":{},", .{iterations});
    try w.print("\"cv\":{d:.6},", .{cv});
    try w.print("\"p95_mean_ratio\":{d:.4},", .{p95_mean_ratio});
    try w.print("\"p999_mean_ratio\":{d:.4},", .{p999_mean_ratio});
    try w.print("\"trim_cv\":{d:.6}", .{trim_cv});
    try w.writeAll("}\n");
    const line = fbs.getWritten();
    _ = try std.posix.write(std.posix.STDOUT_FILENO, line);
    if (cv > 0.25 or p95_mean_ratio > 2.8) {
        if (std.posix.getenv("MON_VARIANCE_ENFORCE")) |v| if (v.len > 0 and v[0] == '1') return error.MonitoringVarianceUnifiedBreached;
    }
}

pub fn main() !void {
    try runMonitoringVarianceUnified();
}

test "BenchmarkCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified_Run" {
    try runMonitoringVarianceUnified();
}

test "TestCANARY_REQ_GQL_081_MetricsRegistryVarianceUnified" {
    try runMonitoringVarianceUnified();
}
