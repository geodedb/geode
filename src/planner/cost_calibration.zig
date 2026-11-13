const std = @import("std");
const cost_model = @import("cost_model.zig");

// Cost Calibration collects micro-samples of operator execution surrogate metrics
// (synthetic for now) and derives scaling multipliers applied to CostFactors.
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanCostModelCalibration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanCostModelCalibration; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanCostModelCalibrationVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanCostModelCalibrationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

pub const Operator = enum { scan, filter, project, join, aggregate, sort, limit };

pub const Sample = struct { op: Operator, nanos: u64 };

pub const Calibration = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayListUnmanaged(Sample),
    factors: cost_model.CostFactors = .{},
    applied: bool = false,
    ema_alpha: f64 = 0.3,

    pub fn init(allocator: std.mem.Allocator) Calibration {
        return .{ .allocator = allocator, .samples = .empty };
    }

    pub fn deinit(self: *Calibration) void {
        self.samples.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn record(self: *Calibration, op: Operator, nanos: u64) !void {
        try self.samples.append(self.allocator, .{ .op = op, .nanos = nanos });
    }

    fn applyEma(old: *f64, sample: f64, alpha: f64) void {
        if (old.* == 0) {
            old.* = sample;
        } else {
            old.* = alpha * sample + (1.0 - alpha) * old.*;
        }
    }

    pub fn compute(self: *Calibration) void {
        var scan_ns: f64 = 0;
        var filter_ns: f64 = 0;
        var project_ns: f64 = 0;
        var join_ns: f64 = 0;
        var aggregate_ns: f64 = 0;
        var sort_ns: f64 = 0;
        var limit_ns: f64 = 0;
        for (self.samples.items) |s| {
            const v = @as(f64, @floatFromInt(s.nanos));
            switch (s.op) {
                .scan => applyEma(&scan_ns, v, self.ema_alpha),
                .filter => applyEma(&filter_ns, v, self.ema_alpha),
                .project => applyEma(&project_ns, v, self.ema_alpha),
                .join => applyEma(&join_ns, v, self.ema_alpha),
                .aggregate => applyEma(&aggregate_ns, v, self.ema_alpha),
                .sort => applyEma(&sort_ns, v, self.ema_alpha),
                .limit => applyEma(&limit_ns, v, self.ema_alpha),
            }
        }
        // Derive relative multipliers vs scan (baseline 1.0) with guard for zero.
        const base = if (scan_ns == 0) 1 else scan_ns;
        self.factors.scan_base = 1.0;
        self.factors.filter_base = if (filter_ns == 0) self.factors.filter_base else filter_ns / base;
        self.factors.project_base = if (project_ns == 0) self.factors.project_base else project_ns / base;
        self.factors.join_base = if (join_ns == 0) self.factors.join_base else join_ns / base;
        self.factors.aggregate_base = if (aggregate_ns == 0) self.factors.aggregate_base else aggregate_ns / base;
        self.factors.sort_base = if (sort_ns == 0) self.factors.sort_base else sort_ns / base;
        self.factors.limit_base = if (limit_ns == 0) self.factors.limit_base else limit_ns / base;
        self.applied = true;
    }
};

// Utility to simulate recording (placeholder for real micro-timers later)
pub fn simulateSamples(cal: *Calibration) !void {
    // deterministic pseudo-samples (relative heavy join/sort)
    try cal.record(.scan, 1000);
    try cal.record(.filter, 1200);
    try cal.record(.project, 800);
    try cal.record(.join, 5400);
    try cal.record(.aggregate, 3000);
    try cal.record(.sort, 4500);
    try cal.record(.limit, 300);
    cal.compute();
}

test "TestCANARY_REQ_GQL_024_PlanCostModelCalibration" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var cal = Calibration.init(gpa.allocator());
    defer cal.deinit();
    try simulateSamples(&cal);
    try std.testing.expect(cal.applied);
    // Expect join_base > scan_base and sort_base > project_base after calibration
    try std.testing.expect(cal.factors.join_base > cal.factors.scan_base);
    try std.testing.expect(cal.factors.sort_base > cal.factors.project_base);
}

// Zig 0.16 removed std.time.nanoTimestamp; the variance test below reads
// CLOCK_MONOTONIC directly.
fn monotonicNanos() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

test "BenchmarkCANARY_REQ_GQL_024_PlanCostModelCalibrationVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const Runs = 55;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var cal = Calibration.init(gpa.allocator());
        try simulateSamples(&cal);
        // measure compute path only (simulateSamples already calls compute)
        const start = monotonicNanos();
        cal.compute();
        const end = monotonicNanos();
        samples[r] = @intCast(end - start);
        cal.deinit();
    }
    var sum: f128 = 0;
    for (samples) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var acc: f128 = 0;
    for (samples) |v| {
        const d = @as(f128, @floatFromInt(v)) - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;
    // A timing claim, so it follows the shared perf-gate policy
    // (tests/perf_gate.zig, SONNY-2439): reported by default, enforced only
    // under GEODE_PERF_GATES=enforce. The calibrated factors are asserted
    // by the test above.
    if (cv > 0.22) {
        const mode = std.c.getenv("GEODE_PERF_GATES");
        if (mode != null and std.mem.eql(u8, std.mem.span(mode.?), "enforce")) return error.VarianceEnvelopeBreached;
        std.debug.print("PERF_GATE_REPORTED PlanCostModelCalibrationVarianceEnvelope cv={d:.4} (> 0.22)\n", .{@as(f64, @floatCast(cv))});
    }
}
