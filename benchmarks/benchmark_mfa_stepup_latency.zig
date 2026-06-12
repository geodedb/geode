const std = @import("std");
const risk = @import("security/mfa_risk.zig");

// Zig 0.16 compat: std.time.nanoTimestamp removed; clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Benchmark: step-up decision latency variance envelope
// Outputs JSON line with iterations, cv, p95_mean_ratio.
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRiskStepUpDecision"; ASPECT=LatencyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_MFA_CORE_001_StepUpLatencyVariance; OWNER=security; UPDATED=2025-09-27

pub fn main() !void {
    // Zig 0.16: GeneralPurposeAllocator renamed to DebugAllocator.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const iters: usize = 256;
    var times = try alloc.alloc(u64, iters);
    defer alloc.free(times);
    var total: u128 = 0;
    var i: usize = 0;
    var enforced = false;
    const policy = risk.StepUpPolicy{ .threshold = 0.55, .hysteresis = 0.05 };
    while (i < iters) : (i += 1) {
        const start = nowNs();
        const f = risk.deterministicFactors("userA", if (i % 2 == 0) .Login else .TransferFunds);
        const sc = risk.score(if (i % 2 == 0) .Login else .TransferFunds, f);
        enforced = policy.requiresStepUp(sc, enforced);
        const end = nowNs();
        const dt: u64 = end - start;
        times[i] = dt;
        total += dt;
    }
    // compute mean
    const mean_ns = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iters));
    // compute p95 & stddev
    const sorted = try alloc.alloc(u64, iters);
    defer alloc.free(sorted);
    std.mem.copyForwards(u64, sorted, times);
    std.sort.heap(u64, sorted, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    const p95 = sorted[iters * 95 / 100];
    var sum_sq: f128 = 0;
    for (times) |t| {
        const diff = @as(f128, @floatFromInt(t)) - @as(f128, mean_ns);
        sum_sq += diff * diff;
    }
    const variance = sum_sq / @as(f128, @floatFromInt(iters));
    const stddev = std.math.sqrt(variance);
    const cv = (@as(f64, @floatCast(stddev)) / mean_ns);
    const p95_mean_ratio = @as(f64, @floatFromInt(p95)) / mean_ns;
    // Escape literal JSON braces for Zig format string with double '{{' and '}}'
    std.debug.print("{{\"bench\":\"BenchmarkCANARY_REQ_GQL_MFA_CORE_001_StepUpLatencyVariance\",\"iterations\":{d},\"cv\":{},\"p95_mean_ratio\":{}}}\n", .{ iters, cv, p95_mean_ratio });
}
