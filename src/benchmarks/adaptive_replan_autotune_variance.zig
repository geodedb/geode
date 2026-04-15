const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}


// Adaptive Replan Autotune Variance Envelope (S-019 / REQ-GQL-021)
// Simulates an adaptive replan trigger loop where successive query executions
// produce observed vs estimated cost deltas. An autotune controller adjusts a
// replan threshold parameter toward a stable region (target ratio window).
// We measure the interval (in synthetic execution iterations) between actual
// replan triggers. After convergence (detected when the moving average of the
// interval length stabilizes within a tolerance) we collect the last N stable
// intervals and enforce variance guardrails: CV <= 0.20 (General class) and
// p95/mean <= 2.55. A pass boolean is emitted; failure returns
// error.VarianceEnvelopeBreached for integration into `zig build test`.
//
// Design notes:
// - Purely synthetic (does not depend on real planner yet) to establish the
//   governance envelope early; future integration can swap the interval driver.
// - Deterministic PRNG (xorshift64*) with fixed seed for reproducibility.
// - Convergence detection: track moving average over a fixed window W; once the
//   relative change between successive window means < 2% for K consecutive windows
//   we declare convergence and start recording stable intervals (including the
//   last window). Safety cap on total iterations prevents infinite loops.
// - Intervals are influenced by (estimated_cost, actual_cost) ratio synthetic
//   drift which decays exponentially as controller adapts.
//
// Env overrides:
//   GEODE_ADAPT_REPLAN_MAX_ITERS (default 8000)
//   GEODE_ADAPT_REPLAN_WINDOW (default 16)
//   GEODE_ADAPT_REPLAN_STABLE_WINDOWS (default 4)
//   GEODE_ADAPT_REPLAN_STABLE_SAMPLES (default 48) -- number of stable intervals to evaluate
//   GEODE_ADAPT_REPLAN_SEED (default 0xABCDEF0123456789)
//   GEODE_ADAPT_REPLAN_DRIFT (default 9000 ppm) initial ratio drift in parts-per-million
//
// Output: One JSON line (schema_version=1) with fields:
//   intervals_collected, mean_interval, cv_scaled_ppm, p95_over_mean_scaled_ppm, pass
//
// CANARY: REQ=REQ-GQL-021; FEATURE="Adaptive Replan Autotune"; ASPECT=AdaptiveReplanAutotuneVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_AdaptiveReplanAutotuneVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

const PPM_SCALE = 10000.0; // scale factor for ppm style metrics (cv * 1e4)

fn xorshift64Star(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    // Use wrapping multiply to avoid overflow trap in Debug builds.
    return @mulWithOverflow(x, 0x2545F4914F6CDD1D)[0];
}

fn prngFloat(state: *u64) f64 {
    const v = xorshift64Star(state);
    // Use upper 53 bits for IEEE f64 mantissa
    return @as(f64, @floatFromInt((v >> 11) & 0x1F_FFFF_FFFF_FFFF)) / 9007199254740991.0;
}

pub fn benchmarkAdaptiveReplanAutotuneVarianceEnvelope() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const max_iters: usize = envOr(allocator, "GEODE_ADAPT_REPLAN_MAX_ITERS", 8000); // total safety cap
    const window: usize = envOr(allocator, "GEODE_ADAPT_REPLAN_WINDOW", 16); // moving average window
    const stable_windows_needed: usize = envOr(allocator, "GEODE_ADAPT_REPLAN_STABLE_WINDOWS", 4);
    const stable_samples_target: usize = envOr(allocator, "GEODE_ADAPT_REPLAN_STABLE_SAMPLES", 48);
    const seed_val: u64 = envOrU64(allocator, "GEODE_ADAPT_REPLAN_SEED", 0xABCDEF0123456789);
    const initial_drift_ppm: usize = envOr(allocator, "GEODE_ADAPT_REPLAN_DRIFT", 9000); // parts-per-million

    var rng_state: u64 = seed_val;

    // Synthetic controller state
    var replan_threshold: f64 = 1.50; // ratio above which replan triggers (estimated vs actual)
    var ratio_drift_ppm: f64 = @as(f64, @floatFromInt(initial_drift_ppm));

    // Circular buffer for last window intervals
    var interval_window = try allocator.alloc(f64, window);
    defer allocator.free(interval_window);
    var iw_index: usize = 0;
    var intervals_recorded: usize = 0;
    var last_window_mean: f64 = 0.0;
    var stable_window_streak: usize = 0;
    var collecting_stable = false;

    // Storage for stable intervals
    var stable_intervals = try allocator.alloc(f64, stable_samples_target);
    defer allocator.free(stable_intervals);
    var stable_count: usize = 0;

    // Generate successive intervals until criteria met or max iters.
    var iter: usize = 0;
    while (iter < max_iters and stable_count < stable_samples_target) : (iter += 1) {
        // Simulate cost ratio behavior.
        // Baseline random component in [0.9, 1.1)
        const base_ratio = 0.9 + (prngFloat(&rng_state) * 0.2);
        // Apply decaying drift (exponential decay tied to iterations)
        const drift_factor = 1.0 + (ratio_drift_ppm / 1_000_000.0);
        const observed_ratio = base_ratio * drift_factor;

        // Replan triggers if observed_ratio > replan_threshold.
        var interval: f64 = 0;
        if (observed_ratio > replan_threshold) {
            // Interval length modeled as scaled geometric-like wait influenced by overshoot.
            const overshoot = observed_ratio - replan_threshold;
            interval = 8.0 + overshoot * 40.0 + prngFloat(&rng_state) * 4.0; // deterministic-ish formula
            // Controller adjusts threshold toward observed ratio to reduce future overshoot.
            replan_threshold = replan_threshold * 0.9 + observed_ratio * 0.1;
            // Decay drift gradually (simulates learning & improved estimates)
            ratio_drift_ppm *= 0.985;
        } else {
            // No replan; produce a small baseline interval noise (simulate idle cycles)
            interval = 4.0 + prngFloat(&rng_state) * 2.0;
            // Encourage slight increase in drift decay even without replan (system evolves)
            ratio_drift_ppm *= 0.995;
        }

        // Update window
        interval_window[iw_index] = interval;
        iw_index = (iw_index + 1) % window;
        if (intervals_recorded < window) {
            intervals_recorded += 1;
        } else {
            // Evaluate moving average stability
            var sum: f64 = 0;
            var k: usize = 0;
            while (k < window) : (k += 1) sum += interval_window[k];
            const mean_now = sum / @as(f64, @floatFromInt(window));
            if (!collecting_stable) {
                if (last_window_mean == 0) {
                    last_window_mean = mean_now;
                } else {
                    const diff = mean_now - last_window_mean;
                    const rel_change = (if (diff < 0) -diff else diff) / last_window_mean;
                    if (rel_change < 0.02) { // <2% change
                        stable_window_streak += 1;
                        if (stable_window_streak >= stable_windows_needed) {
                            collecting_stable = true;
                            // Seed first stable sample window by copying entire window
                            var copy_i: usize = 0;
                            while (copy_i < window and stable_count < stable_samples_target) : (copy_i += 1) {
                                stable_intervals[stable_count] = interval_window[(iw_index + copy_i) % window];
                                stable_count += 1;
                            }
                        }
                    } else {
                        stable_window_streak = 0;
                    }
                    last_window_mean = mean_now;
                }
            } else {
                // Already converged: record each new interval until stable_samples_target reached
                stable_intervals[stable_count] = interval;
                stable_count += 1;
            }
        }
    }

    if (stable_count == 0) return error.ConvergenceNotReached; // defensive

    // Compute statistics over collected stable intervals
    const view = stable_intervals[0..stable_count];
    var sum: f128 = 0;
    for (view) |v| sum += v;
    const mean = sum / @as(f128, @floatFromInt(view.len));
    var var_acc: f128 = 0;
    for (view) |v| {
        const d = @as(f128, v) - mean;
        var_acc += d * d;
    }
    const variance = var_acc / @as(f128, @floatFromInt(view.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;

    // Sort copy for quantiles
    const copy = try allocator.alloc(f64, view.len);
    defer allocator.free(copy);
    std.mem.copyForwards(f64, copy, view);
    std.sort.pdq(f64, copy, {}, comptime std.sort.asc(f64));
    const p95 = copy[@min(copy.len - 1, (copy.len * 95) / 100)];
    const p95_mean_ratio = p95 / mean;
    const pass = !(cv > 0.20 or p95_mean_ratio > 2.55);

    // Emit JSON line
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("{\"schema_version\":1,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"adaptive_replan_autotune_variance\",") catch {};
    inline for (.{
        struct { k: []const u8, v: u64, comma: bool }{ .k = "intervals_collected", .v = @intCast(stable_count), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "mean_interval", .v = @as(u64, @intFromFloat(mean)), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_scaled_ppm", .v = @as(u64, @intFromFloat(cv * PPM_SCALE)), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_scaled_ppm", .v = @as(u64, @intFromFloat(p95_mean_ratio * PPM_SCALE)), .comma = true },
    }) |entry| {
        w.writeAll("\"") catch {};
        w.writeAll(entry.k) catch {};
        w.writeAll("\":") catch {};
        var numtmp: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&numtmp, "{d}", .{entry.v}) catch "0";
        w.writeAll(slice) catch {};
        if (entry.comma) w.writeAll(",") catch {};
    }
    w.writeAll("\"pass\":") catch {};
    w.writeAll(if (pass) "true" else "false") catch {};
    w.writeAll("}\n") catch {};
    std.debug.print("{s}", .{fbs.getWritten()});

    if (!pass) return error.VarianceEnvelopeBreached;
}

fn envOr(allocator: std.mem.Allocator, name: []const u8, default_: usize) usize {
    if (getEnvVarOwned(allocator, name)) |val| {
        defer allocator.free(val);
        return std.fmt.parseInt(usize, val, 10) catch default_;
    } else |_| {
        return default_;
    }
}

fn envOrU64(allocator: std.mem.Allocator, name: []const u8, default_: u64) u64 {
    if (getEnvVarOwned(allocator, name)) |val| {
        defer allocator.free(val);
        return std.fmt.parseInt(u64, val, 16) catch default_;
    } else |_| return default_;
}

test "BenchmarkCANARY_REQ_GQL_021_AdaptiveReplanAutotuneVarianceEnvelope" {
    try benchmarkAdaptiveReplanAutotuneVarianceEnvelope();
}
