//! Shared gate for performance / timing claims in unit tests (SONNY-2394).
//!
//! Perf-ratio, variance-envelope and latency-bound claims are REPORTED by
//! default and ENFORCED only under `GEODE_PERF_GATES=enforce`, whether or not
//! `CI` is set (SONNY-2439). The SONNY-2394 review found that 8 of the 12
//! gated sites measure benchmark artifacts rather than product performance: a
//! test-local loop the optimizer may drop, a microsecond-scale sample on
//! CLOCK_REALTIME, a DebugAllocator path, a loaded host. A violated claim is
//! therefore no evidence of a product regression until SONNY-2439 fixes the
//! methodology. Enforcing them whenever `CI` was unset (the rule until then)
//! made local runs of the gated named steps fail on noise alone, with no
//! product change (test-canary-path-varlen-predicate, since removed as a
//! benchmark of test-local code: CV 0.30-0.51 against a 0.22 bound).
//!
//! The scheduled-pipeline job `test-perf-gates-enforced` (.gitlab-ci.yml) runs
//! every gated step with the override, so the claims can still be enforced on
//! purpose.
//!
//! Correctness assertions must NEVER go through this gate: they always run.
//! Every perf claim is still measured and evaluated in both modes; a claim that
//! does not hold is reported on stderr either way and fails the test only when
//! enforced.
//!
//! Self-test hook: `GEODE_PERF_GATE_SELFTEST=violate` makes every claim count
//! as violated, so any call site can be shown to route through the gate (the
//! step fails when enforced and passes when reported).

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{PerfClaimViolated};

pub const Mode = enum {
    /// `GEODE_PERF_GATES=enforce`: a violated claim fails the test.
    enforced,
    /// The default, with or without `CI`: a violated claim is reported only.
    reported,
};

/// Override variable; only the exact value `enforce` enforces the claims.
pub const override_env = "GEODE_PERF_GATES";

/// Pure mode resolution (reads no environment). SONNY-2439: `CI` no longer
/// takes part; only the override does.
///
///   | GEODE_PERF_GATES       | CI unset | CI set   |
///   |------------------------|----------|----------|
///   | `enforce`              | enforced | enforced |
///   | unset, or any other    | reported | reported |
pub fn modeFor(override: ?[]const u8) Mode {
    if (override) |v| {
        if (std.mem.eql(u8, v, "enforce")) return .enforced;
    }
    return .reported;
}

/// The gate mode for this process, from `GEODE_PERF_GATES` alone.
pub fn currentMode() Mode {
    const override: ?[]const u8 = if (std.c.getenv(override_env)) |p| std.mem.span(p) else null;
    return modeFor(override);
}

fn selftestForcesViolation() bool {
    const v = std.c.getenv("GEODE_PERF_GATE_SELFTEST") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "violate");
}

/// Evaluate one perf claim. `holds` is the claim applied to the measured
/// value(s); `fmt`/`args` render the measurement for the report line.
pub fn check(claim: []const u8, holds: bool, comptime fmt: []const u8, args: anytype) Error!void {
    return checkIn(currentMode(), selftestForcesViolation(), claim, holds, fmt, args);
}

/// The common BenchmarkCANARY variance envelope: coefficient of variation and
/// p95/mean ratio bounds (both checked through `check`).
pub fn envelope(name: []const u8, cv: anytype, p95_over_mean: anytype, max_cv: f64, max_p95_over_mean: f64) Error!void {
    return envelopeIn(currentMode(), selftestForcesViolation(), name, cv, p95_over_mean, max_cv, max_p95_over_mean);
}

/// `check` with the mode and self-test override made explicit (pure: reads no
/// environment), so the gate's behaviour is unit-testable without mutating the
/// process environment.
pub fn checkIn(mode: Mode, force_violation: bool, claim: []const u8, holds: bool, comptime fmt: []const u8, args: anytype) Error!void {
    if (holds and !force_violation) return;
    switch (mode) {
        .enforced => {
            std.debug.print("PERF_CLAIM_VIOLATED [{s}] ", .{claim});
            std.debug.print(fmt ++ "\n", args);
            return error.PerfClaimViolated;
        },
        .reported => {
            std.debug.print("PERF_CLAIM_NOT_ENFORCED [{s}] ", .{claim});
            std.debug.print(fmt ++ "\n", args);
        },
    }
}

pub fn envelopeIn(mode: Mode, force_violation: bool, name: []const u8, cv: anytype, p95_over_mean: anytype, max_cv: f64, max_p95_over_mean: f64) Error!void {
    const cv_f: f64 = @floatCast(cv);
    const ratio_f: f64 = @floatCast(p95_over_mean);
    try checkIn(mode, force_violation, name, cv_f <= max_cv, "cv={d:.4} (max {d:.2})", .{ cv_f, max_cv });
    try checkIn(mode, force_violation, name, ratio_f <= max_p95_over_mean, "p95/mean={d:.3} (max {d:.2})", .{ ratio_f, max_p95_over_mean });
}

// -- Measurement (SONNY-2439) ------------------------------------------------
//
// A gated benchmark measures with these, not with its own clock reads:
//   - `nowNs` reads CLOCK_MONOTONIC (NTP slews and steps CLOCK_REALTIME);
//   - one sample is a BATCH of `batch` operations timed together, recorded
//     as nanoseconds per operation, so a sample is far above the clock's
//     resolution and per-call overhead;
//   - every operation's result goes through std.mem.doNotOptimizeAway, so
//     the optimizer cannot drop the work being timed;
//   - an A/B comparison runs the two arms INTERLEAVED, batch by batch,
//     alternating which arm goes first, so drift on the host (frequency
//     scaling, other load) hits both arms alike instead of one;
//   - claims use robust statistics: the median, and the interquartile range
//     relative to the median, which one preempted batch cannot move the way
//     it moves a mean and a standard deviation.
// The benchmarks allocate from `bench_allocator` (the production allocator
// in an optimized build), not DebugAllocator, whose bookkeeping dominates a
// microbenchmark.
//
// Still open (SONNY-2439): the thresholds are the former CV / p95-over-mean
// bounds carried over to their robust counterparts (relative IQR at 1.35x
// the CV bound, the IQR of a normal distribution being 1.35 sigma); they
// have not been calibrated on the quiet CI runner.

/// The allocator gated benchmarks allocate from: the C allocator the server
/// uses in optimized builds (src/server/main.zig ServerAllocator), so a
/// benchmark does not time DebugAllocator's bookkeeping.
pub const bench_allocator = std.heap.c_allocator;

/// CLOCK_MONOTONIC in nanoseconds.
pub fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Robust summary of a sample set (ns per operation).
pub const Robust = struct {
    median: f64,
    q1: f64,
    q3: f64,
    p95: f64,
    /// (q3 - q1) / median.
    rel_iqr: f64,
    /// p95 / median.
    p95_over_median: f64,
};

fn quantile(sorted: []const f64, q: f64) f64 {
    if (sorted.len == 0) return 0;
    const pos = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi: usize = @min(lo + 1, sorted.len - 1);
    const frac = pos - @floor(pos);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

/// Summarize `samples` (sorted in place).
pub fn robust(samples: []f64) Robust {
    std.sort.block(f64, samples, {}, comptime std.sort.asc(f64));
    const med = quantile(samples, 0.5);
    const q1 = quantile(samples, 0.25);
    const q3 = quantile(samples, 0.75);
    const p95 = quantile(samples, 0.95);
    return .{
        .median = med,
        .q1 = q1,
        .q3 = q3,
        .p95 = p95,
        .rel_iqr = if (med > 0) (q3 - q1) / med else 0,
        .p95_over_median = if (med > 0) p95 / med else 0,
    };
}

/// Run `op(ctx)` `batch` times and return the mean ns per operation.
/// `op` returns a value that is passed to doNotOptimizeAway.
pub fn timeBatch(ctx: anytype, comptime op: anytype, batch: usize) !f64 {
    const start = nowNs();
    for (0..batch) |_| {
        const r = try op(ctx);
        std.mem.doNotOptimizeAway(r);
    }
    const elapsed = nowNs() - start;
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(@max(batch, 1)));
}

/// One sample per element of `out`, each a batch of `batch` operations.
pub fn sampleBatches(ctx: anytype, comptime op: anytype, batch: usize, out: []f64) !void {
    for (out) |*o| o.* = try timeBatch(ctx, op, batch);
}

/// Interleaved A/B: sample `i` of each arm is a batch of `batch`
/// operations; arm A goes first in even rounds and arm B in odd ones.
pub fn interleavedAB(ctx: anytype, comptime op_a: anytype, comptime op_b: anytype, batch: usize, out_a: []f64, out_b: []f64) !void {
    std.debug.assert(out_a.len == out_b.len);
    for (out_a, out_b, 0..) |*a, *b, i| {
        if (i % 2 == 0) {
            a.* = try timeBatch(ctx, op_a, batch);
            b.* = try timeBatch(ctx, op_b, batch);
        } else {
            b.* = try timeBatch(ctx, op_b, batch);
            a.* = try timeBatch(ctx, op_a, batch);
        }
    }
}

/// The robust variance envelope: relative IQR and p95/median bounds.
pub fn robustEnvelope(name: []const u8, r: Robust, max_rel_iqr: f64, max_p95_over_median: f64) Error!void {
    return robustEnvelopeIn(currentMode(), selftestForcesViolation(), name, r, max_rel_iqr, max_p95_over_median);
}

pub fn robustEnvelopeIn(mode: Mode, force_violation: bool, name: []const u8, r: Robust, max_rel_iqr: f64, max_p95_over_median: f64) Error!void {
    try checkIn(mode, force_violation, name, r.rel_iqr <= max_rel_iqr, "median={d:.1}ns rel_iqr={d:.4} (max {d:.2})", .{ r.median, r.rel_iqr, max_rel_iqr });
    try checkIn(mode, force_violation, name, r.p95_over_median <= max_p95_over_median, "p95/median={d:.3} (max {d:.2})", .{ r.p95_over_median, max_p95_over_median });
}

/// The relative cost of arm `b` over arm `a`, from medians: (b - a) / a.
pub fn medianOverhead(a: Robust, b: Robust) f64 {
    return if (a.median > 0) (b.median - a.median) / a.median else 0;
}

// -- Self tests (no environment mutation: see `checkIn`) ---------------------

// Run with CI unset, with CI set, and with the override: the expectation is
// the same table in every environment.
test "perf_gate: currentMode follows only the GEODE_PERF_GATES override, whether or not CI is set" {
    const override: ?[]const u8 = if (std.c.getenv(override_env)) |p| std.mem.span(p) else null;
    const forced = if (override) |v| std.mem.eql(u8, v, "enforce") else false;
    try std.testing.expectEqual(if (forced) Mode.enforced else Mode.reported, currentMode());
}

test "perf_gate: modeFor -- claims are reported unless the override is exactly enforce" {
    try std.testing.expectEqual(Mode.reported, modeFor(null));
    try std.testing.expectEqual(Mode.enforced, modeFor("enforce"));
    // Any other value is not an override.
    try std.testing.expectEqual(Mode.reported, modeFor("1"));
    try std.testing.expectEqual(Mode.reported, modeFor("ENFORCE "));
    try std.testing.expectEqual(Mode.reported, modeFor("report"));
    try std.testing.expectEqual(Mode.reported, modeFor(""));
}

test "perf_gate: a clearly-violating claim FAILS when enforced (GEODE_PERF_GATES=enforce)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Synthetic values: a 10x ratio against a 1.05 bound; cv 5.0 against 0.22;
    // p95/mean 9.0 against 2.55.
    try std.testing.expectError(error.PerfClaimViolated, checkIn(.enforced, false, "synthetic ratio", 10.0 <= 1.05, "ratio={d:.2}", .{10.0}));
    try std.testing.expectError(error.PerfClaimViolated, envelopeIn(.enforced, false, "synthetic cv", @as(f64, 5.0), @as(f64, 1.0), 0.22, 2.55));
    try std.testing.expectError(error.PerfClaimViolated, envelopeIn(.enforced, false, "synthetic p95", @as(f128, 0.1), @as(f128, 9.0), 0.22, 2.55));
    // Holding claims pass.
    try checkIn(.enforced, false, "synthetic ok", 1.0 <= 1.05, "ratio={d:.2}", .{1.0});
    try envelopeIn(.enforced, false, "synthetic ok", @as(f64, 0.1), @as(f64, 1.2), 0.22, 2.55);
}

test "perf_gate: a violated claim is reported but NOT enforced by default" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try checkIn(.reported, false, "synthetic ratio", 10.0 <= 1.05, "ratio={d:.2}", .{10.0});
    try envelopeIn(.reported, false, "synthetic envelope", @as(f64, 5.0), @as(f64, 9.0), 0.22, 2.55);
}

test "perf_gate: the self-test hook forces a holding claim to count as violated" {
    try std.testing.expectError(error.PerfClaimViolated, checkIn(.enforced, true, "holding claim", true, "", .{}));
    try checkIn(.reported, true, "holding claim", true, "", .{});
}

test "perf_gate: robust statistics are the median and quartiles, not moved by one outlier" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var xs = [_]f64{ 10, 11, 9, 10, 12, 10, 9, 11, 10, 10_000 };
    const r = robust(&xs);
    try std.testing.expectApproxEqAbs(@as(f64, 10), r.median, 1e-9);
    try std.testing.expect(r.q1 >= 9 and r.q1 <= 10);
    try std.testing.expect(r.q3 >= 10 and r.q3 <= 11.25);
    try std.testing.expect(r.rel_iqr < 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), medianOverhead(.{ .median = 10, .q1 = 0, .q3 = 0, .p95 = 0, .rel_iqr = 0, .p95_over_median = 0 }, .{ .median = 15, .q1 = 0, .q3 = 0, .p95 = 0, .rel_iqr = 0, .p95_over_median = 0 }), 1e-9);
}

test "perf_gate: batches and interleaving run every operation and alternate the arms" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Ctx = struct {
        order: std.ArrayList(u8) = .empty,
        n: usize = 0,
        fn a(self: *@This()) !usize {
            try self.order.append(std.testing.allocator, 'a');
            self.n += 1;
            return self.n;
        }
        fn b(self: *@This()) !usize {
            try self.order.append(std.testing.allocator, 'b');
            self.n += 1;
            return self.n;
        }
    };
    var ctx: Ctx = .{};
    defer ctx.order.deinit(std.testing.allocator);
    var out_a: [3]f64 = undefined;
    var out_b: [3]f64 = undefined;
    try interleavedAB(&ctx, Ctx.a, Ctx.b, 2, &out_a, &out_b);
    try std.testing.expectEqual(@as(usize, 12), ctx.n);
    try std.testing.expectEqualStrings("aabbbbaaaabb", ctx.order.items);
    for (out_a ++ out_b) |v| try std.testing.expect(v >= 0);
}

test "perf_gate: the robust envelope fails when enforced and only reports by default" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const wide: Robust = .{ .median = 10, .q1 = 5, .q3 = 20, .p95 = 90, .rel_iqr = 1.5, .p95_over_median = 9 };
    try std.testing.expectError(error.PerfClaimViolated, robustEnvelopeIn(.enforced, false, "synthetic", wide, 0.30, 2.55));
    try robustEnvelopeIn(.reported, false, "synthetic", wide, 0.30, 2.55);
    const tight: Robust = .{ .median = 10, .q1 = 9.5, .q3 = 10.5, .p95 = 12, .rel_iqr = 0.1, .p95_over_median = 1.2 };
    try robustEnvelopeIn(.enforced, false, "synthetic", tight, 0.30, 2.55);
}
