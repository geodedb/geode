const std = @import("std");
// Benchmark MFA policy evaluation variance envelope.
// Simulates evaluating a representative set of MFA policies (time window, risk score, re-auth interval)
// across a batch of synthetic session contexts to capture latency distribution stability.
// Threshold policy (initial guardrails):
//   Coefficient of variation (cv) <= 0.30
//   p95/mean <= 2.75
//   p99/mean <= 3.50
// These thresholds are intentionally loose for early stabilization; they should be tightened once
// production telemetry is available. Breaches indicate regression in policy evaluation determinism
// or pathological jitter (e.g. unnecessary allocations, hashing hotspots).
//
// CANARY: REQ=REQ-GQL-MFA-PERF-001; FEATURE="MfaPolicyEvaluation"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_MFA_PERF_001_PolicyEvaluationVarianceEnvelope; OWNER=security; UPDATED=2025-09-26

const PolicyKind = enum { time_window, risk_score, reauth_interval };

const Policy = struct {
    kind: PolicyKind,
    // Simple parameters; expand as engine evolves
    window_ms: u64 = 0,
    min_risk: u8 = 0,
    reauth_interval_ms: u64 = 0,

    pub fn evaluate(self: Policy, now_ms: u64, session: *const SessionCtx) bool {
        return switch (self.kind) {
            .time_window => now_ms < session.issued_at_ms + self.window_ms,
            .risk_score => session.risk_score >= self.min_risk,
            .reauth_interval => now_ms - session.last_auth_ms >= self.reauth_interval_ms,
        };
    }
};

const SessionCtx = struct {
    issued_at_ms: u64,
    last_auth_ms: u64,
    risk_score: u8,
};

fn computeStats(alloc: std.mem.Allocator, samples: []const u64) !struct {
    mean: f128,
    cv: f128,
    p95_ratio: f128,
    p99_ratio: f128,
} {
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
    const cv = if (mean_f == 0) 0 else stddev / mean_f;

    // Copy + deterministic selection sort
    var buf = try alloc.alloc(u64, samples.len);
    defer alloc.free(buf);
    std.mem.copy(u64, buf, samples);
    var i: usize = 0;
    var tmp: u64 = 0;
    while (i < buf.len) : (i += 1) {
        var min_idx = i;
        var j = i + 1;
        while (j < buf.len) : (j += 1) {
            if (buf[j] < buf[min_idx]) min_idx = j;
        }
        if (min_idx != i) {
            tmp = buf[i];
            buf[i] = buf[min_idx];
            buf[min_idx] = tmp;
        }
    }
    const p95 = buf[(buf.len * 95) / 100];
    const p99 = buf[(buf.len * 99) / 100];
    return .{
        .mean = mean_f,
        .cv = cv,
        .p95_ratio = @as(f128, @floatFromInt(p95)) / mean_f,
        .p99_ratio = @as(f128, @floatFromInt(p99)) / mean_f,
    };
}

fn evaluatePolicies(policies: []const Policy, sessions: []const SessionCtx, now_ms: u64) u64 {
    var count: usize = 0;
    for (sessions) |s| {
        for (policies) |p| {
            if (p.evaluate(now_ms, &s)) count += 1;
        }
    }
    return @as(u64, @intCast(count));
}

pub fn benchmarkMfaPolicyEvaluationVarianceEnvelope() !void {
    const iterations = 128; // keep CI friendly while gathering enough samples
    const policy_set = [_]Policy{
        .{ .kind = .time_window, .window_ms = 5 * 60_000 },
        .{ .kind = .risk_score, .min_risk = 42 },
        .{ .kind = .reauth_interval, .reauth_interval_ms = 30 * 60_000 },
    };

    // Synthetic session contexts with controlled variability
    const session_count = 256;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var sessions = try alloc.alloc(SessionCtx, session_count);
    defer alloc.free(sessions);
    var s: usize = 0;
    while (s < session_count) : (s += 1) {
        sessions[s] = .{
            .issued_at_ms = 1_000_000 + @as(u64, @intCast(s * 111)),
            .last_auth_ms = 1_100_000 + @as(u64, @intCast(s * 73)),
            .risk_score = @as(u8, @intCast((s * 17) % 100)),
        };
    }

    var samples = try alloc.alloc(u64, iterations);
    defer alloc.free(samples);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const now_ms: u64 = 2_000_000 + @as(u64, @intCast(i * 10));
        var timer = std.time.Timer.start() catch unreachable;
        // Perform evaluation multiple times to amplify timing signal
        var rep: usize = 0;
        const reps = 32;
        var acc: u64 = 0;
        while (rep < reps) : (rep += 1) acc += evaluatePolicies(&policy_set, sessions, now_ms + @as(u64, @intCast(rep)));
        // Prevent optimizer from eliminating the loop entirely by a volatile read
        std.mem.doNotOptimizeAway(acc);
        samples[i] = timer.read();
    }

    const stats = try computeStats(alloc, samples);
    if (stats.cv > 0.30 or stats.p95_ratio > 2.75 or stats.p99_ratio > 3.50) {
        std.debug.print("MFA policy evaluation variance breach: cv={d:.4} p95/mean={d:.4} p99/mean={d:.4}\n", .{ stats.cv, stats.p95_ratio, stats.p99_ratio });
        return error.VarianceEnvelopeBreached;
    }

    // Emit JSON line for observability (optional)
    var stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{try std.json.stringifyAlloc(alloc, .{
        .bench = "BenchmarkCANARY_REQ_GQL_MFA_PERF_001_PolicyEvaluationVarianceEnvelope",
        .cv = stats.cv,
        .p95_ratio = stats.p95_ratio,
        .p99_ratio = stats.p99_ratio,
    }, .{})});
}

test "BenchmarkCANARY_REQ_GQL_MFA_PERF_001_PolicyEvaluationVarianceEnvelope" {
    try benchmarkMfaPolicyEvaluationVarianceEnvelope();
}
