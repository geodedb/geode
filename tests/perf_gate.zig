//! Shared gate for performance / timing claims in unit tests (SONNY-2394).
//!
//! Repo convention -- codified in the `zig-test` pre-push hook comment in
//! .pre-commit-config.yaml ("Each of those tests already self-skips when
//! CI=true, treating that as 'the environment is too contended for perf-ratio
//! claims to be meaningful'") and applied by tests/test_fts_latency.zig and
//! tests/test_ts_latency.zig: perf-ratio, variance-envelope and latency-bound
//! claims are ENFORCED only when `CI` is unset. The sharded pre-push hook
//! exports CI=1 and GitLab CI sets CI=true -- oversubscribed Debug-build
//! environments where such claims are not meaningful.
//!
//! Correctness assertions must NEVER go through this gate: they always run.
//! Every perf claim is still measured and evaluated in both modes; a claim that
//! does not hold is reported on stderr either way and fails the test only when
//! enforced.
//!
//! Explicit override (SONNY-2394 review): `GEODE_PERF_GATES=enforce` enforces
//! every claim even when `CI` is set. Without it the claims would never bite in
//! any automated run (the pre-push hook and every GitLab pipeline set CI); the
//! scheduled-pipeline job `test-perf-gates-enforced` (.gitlab-ci.yml) runs the
//! gated steps with the override.
//!
//! Self-test hook: `GEODE_PERF_GATE_SELFTEST=violate` makes every claim count
//! as violated, so any call site can be shown to route through the gate (the
//! step fails when enforced and passes when reported).

const std = @import("std");

pub const Error = error{PerfClaimViolated};

pub const Mode = enum {
    /// `CI` unset, or `GEODE_PERF_GATES=enforce`: a violated claim fails the test.
    enforced,
    /// `CI` set (no override): a violated claim is reported only.
    reported,
};

/// Explicit override variable; the value `enforce` enforces even under CI.
pub const override_env = "GEODE_PERF_GATES";

/// Pure mode resolution (reads no environment): the override wins, otherwise
/// claims are enforced exactly when `CI` is unset.
pub fn modeFor(ci_set: bool, override: ?[]const u8) Mode {
    if (override) |v| {
        if (std.mem.eql(u8, v, "enforce")) return .enforced;
    }
    return if (ci_set) .reported else .enforced;
}

/// The gate mode for this process, from `CI` and `GEODE_PERF_GATES`.
pub fn currentMode() Mode {
    const override: ?[]const u8 = if (std.c.getenv(override_env)) |p| std.mem.span(p) else null;
    return modeFor(std.c.getenv("CI") != null, override);
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
            std.debug.print("PERF_CLAIM_NOT_ENFORCED(CI) [{s}] ", .{claim});
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

// -- Self tests (no environment mutation: see `checkIn`) ---------------------

test "perf_gate: currentMode follows CI and the GEODE_PERF_GATES override" {
    const ci_set = std.c.getenv("CI") != null;
    const override: ?[]const u8 = if (std.c.getenv(override_env)) |p| std.mem.span(p) else null;
    const forced = if (override) |v| std.mem.eql(u8, v, "enforce") else false;
    try std.testing.expectEqual(if (forced or !ci_set) Mode.enforced else Mode.reported, currentMode());
}

test "perf_gate: modeFor -- the enforce override wins over CI" {
    try std.testing.expectEqual(Mode.enforced, modeFor(false, null));
    try std.testing.expectEqual(Mode.reported, modeFor(true, null));
    try std.testing.expectEqual(Mode.enforced, modeFor(true, "enforce"));
    try std.testing.expectEqual(Mode.enforced, modeFor(false, "enforce"));
    // Any other value is not an override.
    try std.testing.expectEqual(Mode.reported, modeFor(true, "1"));
    try std.testing.expectEqual(Mode.reported, modeFor(true, "ENFORCE "));
    try std.testing.expectEqual(Mode.enforced, modeFor(false, "report"));
}

test "perf_gate: a clearly-violating claim FAILS when enforced (CI unset)" {
    // Synthetic values: a 10x ratio against a 1.05 bound; cv 5.0 against 0.22;
    // p95/mean 9.0 against 2.55.
    try std.testing.expectError(error.PerfClaimViolated, checkIn(.enforced, false, "synthetic ratio", 10.0 <= 1.05, "ratio={d:.2}", .{10.0}));
    try std.testing.expectError(error.PerfClaimViolated, envelopeIn(.enforced, false, "synthetic cv", @as(f64, 5.0), @as(f64, 1.0), 0.22, 2.55));
    try std.testing.expectError(error.PerfClaimViolated, envelopeIn(.enforced, false, "synthetic p95", @as(f128, 0.1), @as(f128, 9.0), 0.22, 2.55));
    // Holding claims pass.
    try checkIn(.enforced, false, "synthetic ok", 1.0 <= 1.05, "ratio={d:.2}", .{1.0});
    try envelopeIn(.enforced, false, "synthetic ok", @as(f64, 0.1), @as(f64, 1.2), 0.22, 2.55);
}

test "perf_gate: a violated claim is reported but NOT enforced under CI" {
    try checkIn(.reported, false, "synthetic ratio", 10.0 <= 1.05, "ratio={d:.2}", .{10.0});
    try envelopeIn(.reported, false, "synthetic envelope", @as(f64, 5.0), @as(f64, 9.0), 0.22, 2.55);
}

test "perf_gate: the self-test hook forces a holding claim to count as violated" {
    try std.testing.expectError(error.PerfClaimViolated, checkIn(.enforced, true, "holding claim", true, "", .{}));
    try checkIn(.reported, true, "holding claim", true, "", .{});
}
