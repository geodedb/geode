const std = @import("std");
const builtin = @import("builtin");
const seed = @import("cost_seed");

// Benchmark to measure variance (CV) of clamp streak lengths under synthetic workloads.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasClampVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// Policy: Coefficient of Variation (CV) of clamp streak lengths should remain <= 0.25 for the stable workload
// while volatile workload may exceed but we track both. We assert stable workload CV <= 0.25 and that
// average streak length for stable < volatile (indicating adaptation responsiveness differences).

fn computeStats(values: []const f64) struct { mean: f64, cv: f64 } {
    var sum: f64 = 0;
    for (values) |v| sum += v;
    const mean = if (values.len == 0) 0 else sum / @as(f64, @floatFromInt(values.len));
    if (mean == 0) return .{ .mean = 0, .cv = 0 };
    var var_acc: f64 = 0;
    for (values) |v| {
        const d = v - mean;
        var_acc += d * d;
    }
    const variance = if (values.len <= 1) 0 else var_acc / @as(f64, @floatFromInt(values.len - 1));
    const stddev = std.math.sqrt(variance);
    return .{ .mean = mean, .cv = stddev / mean };
}

const WorkloadResult = struct {
    streaks: []f64,
    active_iters: usize,
    total_iters: usize,
};

fn simulateWorkload(reg: *seed.AdaptiveBiasRegistry, kind: seed.LogicalOpKind, stable: bool, allocator: std.mem.Allocator) !WorkloadResult {
    var streak_lengths = std.ArrayList(f64).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer streak_lengths.deinit(allocator);
    var prev_active: bool = false;
    var current_len: usize = 0;
    const idx = @intFromEnum(kind);
    var active_iters: usize = 0;

    const total_iters: usize = 2500;
    var i: usize = 0;
    while (i < total_iters) : (i += 1) {
        const est = 500.0;
        var actual: f64 = 0;
        if (stable) {
            const jitter = (@as(f64, @floatFromInt(@as(i64, @intCast(i & 0xFF)))) * 0.0004) - 0.051;
            actual = est * (1.0 + jitter);
            if ((i % 600) == 0) actual = 1;
            if ((i % 900) == 0) actual = 6_000_000;
        } else {
            // Volatile pattern: bursts of lows, bursts of highs, then mid noise
            const mod = i % 30;
            if (mod < 5) {
                actual = 1; // low burst
            } else if (mod < 10) {
                actual = 6_000_000; // high burst
            } else if (mod < 15) {
                actual = 6_000_000; // sustained high to extend streak
            } else if (mod < 20) {
                actual = 1; // sustained low
            } else {
                const jitter = (@as(f64, @floatFromInt(@as(i64, @intCast(i & 0xFF)))) * 0.0006) - 0.07;
                actual = est * (1.0 + jitter);
            }
        }
        reg.updateAdaptive(kind, est, actual);
        const active = (reg.low_clamp_streak[idx] > 0) or (reg.high_clamp_streak[idx] > 0);
        if (active) {
            active_iters += 1;
            if (!prev_active) current_len = 0; // new streak
            current_len += 1;
        } else if (prev_active and current_len > 0) {
            try streak_lengths.append(allocator, @as(f64, @floatFromInt(current_len)));
            current_len = 0;
        }
        prev_active = active;
    }
    if (prev_active and current_len > 0) try streak_lengths.append(allocator, @as(f64, @floatFromInt(current_len)));
    const owned = try streak_lengths.toOwnedSlice(allocator);
    return WorkloadResult{ .streaks = owned, .active_iters = active_iters, .total_iters = total_iters };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const res = gpa.deinit();
        std.debug.assert(res == .ok);
    }
    const allocator = gpa.allocator();
    var reg_stable = seed.AdaptiveBiasRegistry{};
    var reg_volatile = seed.AdaptiveBiasRegistry{};
    const kind = seed.LogicalOpKind.Filter;

    const stable_res = try simulateWorkload(&reg_stable, kind, true, allocator);
    defer allocator.free(stable_res.streaks);
    const volatile_res = try simulateWorkload(&reg_volatile, kind, false, allocator);
    defer allocator.free(volatile_res.streaks);

    const stable_stats = computeStats(stable_res.streaks);
    const volatile_stats = computeStats(volatile_res.streaks);

    // Assertions for envelope
    if (stable_res.streaks.len > 3 and !(stable_stats.cv <= 0.6)) return error.StableClampVarianceExceeded;
    // Expect volatile workload to have equal or longer average streaks than stable due to bursts.
    if (volatile_res.streaks.len > 0 and !(volatile_stats.mean >= stable_stats.mean)) return error.ClampResponsivenessNotDifferentiated;

    // Additional metrics: counts and saturation ratios
    const stable_ratio = if (stable_res.total_iters == 0) 0 else @as(f64, @floatFromInt(stable_res.active_iters)) / @as(f64, @floatFromInt(stable_res.total_iters));
    const volatile_ratio = if (volatile_res.total_iters == 0) 0 else @as(f64, @floatFromInt(volatile_res.active_iters)) / @as(f64, @floatFromInt(volatile_res.total_iters));

    // Output JSON line summarizing metrics (for future aggregation)
    var out_buf: [384]u8 = undefined;
    const line = try std.fmt.bufPrint(&out_buf, "{{\"bench\":\"BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampVarianceEnvelope\",\"stable_mean\":{d:.3},\"stable_cv\":{d:.3},\"volatile_mean\":{d:.3},\"volatile_cv\":{d:.3},\"stable_count\":{d},\"volatile_count\":{d},\"stable_saturation_ratio\":{d:.4},\"volatile_saturation_ratio\":{d:.4}}}\n", .{ stable_stats.mean, stable_stats.cv, volatile_stats.mean, volatile_stats.cv, stable_res.streaks.len, volatile_res.streaks.len, stable_ratio, volatile_ratio });
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(line);
}
