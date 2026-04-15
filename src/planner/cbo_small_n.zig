const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const cost_model = @import("cost_model.zig");
const enumerator = @import("enumerator.zig");
const optimizer = @import("optimizer.zig");

/// CBO calibration specifically for small-N datasets
// CANARY: REQ=REQ-GQL-CBO-002; FEATURE="CBO Small-N Calibration"; ASPECT=Optimization; STATUS=TESTED; TEST=e2e_cbo_small_n; BENCH=benchmark_cbo_small_n_variance; OWNER=planner; UPDATED=2026-01-17
pub const SmallNCalibration = struct {
    allocator: std.mem.Allocator,

    /// Threshold for considering a dataset "small"
    small_n_threshold: u64 = 100,

    /// Bias correction factors for small datasets
    bias_factors: BiasFactors,

    /// Guardrails to prevent bad plans
    guardrails: Guardrails,

    /// Decision log for debugging
    decision_log: ?*DecisionLog,

    /// Metrics for monitoring
    metrics: CalibrationMetrics,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .bias_factors = BiasFactors.default(),
            .guardrails = Guardrails.default(),
            .decision_log = null,
            .metrics = CalibrationMetrics.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.decision_log) |log| {
            log.deinit();
        }
    }

    /// Enable decision logging for debugging
    pub fn enableDecisionLogging(self: *Self) !void {
        if (self.decision_log == null) {
            self.decision_log = try self.allocator.create(DecisionLog);
            self.decision_log.?.* = DecisionLog.init(self.allocator);
        }
    }

    /// Calibrate cost model for small-N dataset
    pub fn calibrate(
        self: *Self,
        base_factors: cost_model.CostFactors,
        cardinality: u64,
        stats: QueryStatistics,
    ) CalibratedFactors {
        // Check if this is a small-N case
        const is_small_n = cardinality <= self.small_n_threshold;

        if (!is_small_n) {
            // Use base factors for larger datasets
            return CalibratedFactors{
                .factors = base_factors,
                .applied_bias = false,
                .confidence = 1.0,
            };
        }

        // Apply bias corrections for small-N
        var adjusted = base_factors;

        // Reduce join penalty for small datasets
        adjusted.join_base *= self.bias_factors.join_reduction;
        adjusted.join_depth_penalty *= self.bias_factors.join_depth_reduction;

        // Increase relative cost of scans for small data
        // (makes index usage more attractive)
        adjusted.scan_base *= self.bias_factors.scan_amplification;

        // Reduce sort cost for small datasets
        adjusted.sort_base *= self.bias_factors.sort_reduction;

        // Apply statistical adjustments
        if (stats.has_skew) {
            // Further reduce join costs if data is skewed
            adjusted.join_base *= 0.8;
        }

        if (stats.has_correlation) {
            // Reduce sort costs if data is pre-sorted
            adjusted.sort_base *= 0.5;
        }

        // Apply guardrails
        adjusted = self.applyGuardrails(adjusted, base_factors);

        // Log decision if enabled
        if (self.decision_log) |log| {
            log.recordDecision(.{
                .cardinality = cardinality,
                .is_small_n = is_small_n,
                .base_factors = base_factors,
                .adjusted_factors = adjusted,
                .stats = stats,
            });
        }

        // Calculate confidence based on data size
        const confidence = calculateConfidence(cardinality, stats);

        // Update metrics
        self.metrics.recordCalibration(is_small_n, confidence);

        return CalibratedFactors{
            .factors = adjusted,
            .applied_bias = true,
            .confidence = confidence,
        };
    }

    /// Compare CBO plan with heuristic plan
    pub fn validateAgainstHeuristic(
        self: *Self,
        cbo_plan: enumerator.LogicalPlan,
        heuristic_plan: enumerator.LogicalPlan,
        factors: cost_model.CostFactors,
    ) PlanValidation {
        const cbo_cost = cost_model.estimatePlanCost(cbo_plan, factors);
        const heuristic_cost = cost_model.estimatePlanCost(heuristic_plan, factors);

        const cost_ratio = cbo_cost / heuristic_cost;
        const regression_threshold = 1.1; // Allow 10% regression max

        const has_regression = cost_ratio > regression_threshold;

        if (self.decision_log) |log| {
            log.recordValidation(.{
                .cbo_cost = cbo_cost,
                .heuristic_cost = heuristic_cost,
                .cost_ratio = cost_ratio,
                .has_regression = has_regression,
            });
        }

        self.metrics.recordValidation(has_regression, cost_ratio);

        return PlanValidation{
            .use_cbo = !has_regression,
            .cbo_cost = cbo_cost,
            .heuristic_cost = heuristic_cost,
            .regression_detected = has_regression,
        };
    }

    /// Apply guardrails to prevent extreme adjustments
    fn applyGuardrails(self: *Self, adjusted: cost_model.CostFactors, base: cost_model.CostFactors) cost_model.CostFactors {
        var result = adjusted;

        // Ensure no factor deviates too much from base
        const max_deviation = self.guardrails.max_factor_deviation;

        result.scan_base = clampFactor(result.scan_base, base.scan_base, max_deviation);
        result.filter_base = clampFactor(result.filter_base, base.filter_base, max_deviation);
        result.project_base = clampFactor(result.project_base, base.project_base, max_deviation);
        result.join_base = clampFactor(result.join_base, base.join_base, max_deviation);
        result.aggregate_base = clampFactor(result.aggregate_base, base.aggregate_base, max_deviation);
        result.sort_base = clampFactor(result.sort_base, base.sort_base, max_deviation);
        result.limit_base = clampFactor(result.limit_base, base.limit_base, max_deviation);

        // Ensure minimum values
        result.scan_base = @max(result.scan_base, self.guardrails.min_scan_cost);
        result.join_base = @max(result.join_base, self.guardrails.min_join_cost);

        return result;
    }

    fn clampFactor(value: f64, base: f64, max_deviation: f64) f64 {
        const min = base / max_deviation;
        const max = base * max_deviation;
        return @max(min, @min(max, value));
    }

    fn calculateConfidence(cardinality: u64, stats: QueryStatistics) f64 {
        // Higher confidence for larger samples
        var confidence = @min(1.0, @as(f64, @floatFromInt(cardinality)) / 100.0);

        // Adjust based on statistics quality
        if (stats.has_histograms) confidence *= 1.2;
        if (stats.sample_rate < 0.1) confidence *= 0.8;

        return @min(1.0, confidence);
    }
};

/// Bias correction factors for small-N datasets
pub const BiasFactors = struct {
    join_reduction: f64 = 0.7,
    join_depth_reduction: f64 = 0.8,
    scan_amplification: f64 = 1.2,
    sort_reduction: f64 = 0.6,

    pub fn default() BiasFactors {
        return .{};
    }
};

/// Guardrails to prevent bad plans
pub const Guardrails = struct {
    max_factor_deviation: f64 = 2.0,
    min_scan_cost: f64 = 0.1,
    min_join_cost: f64 = 0.5,

    pub fn default() Guardrails {
        return .{};
    }
};

/// Query statistics for calibration
pub const QueryStatistics = struct {
    has_skew: bool = false,
    has_correlation: bool = false,
    has_histograms: bool = false,
    sample_rate: f64 = 1.0,
    distinct_values: u64 = 0,
    null_fraction: f64 = 0.0,
};

/// Result of calibration
pub const CalibratedFactors = struct {
    factors: cost_model.CostFactors,
    applied_bias: bool,
    confidence: f64,
};

/// Plan validation result
pub const PlanValidation = struct {
    use_cbo: bool,
    cbo_cost: f64,
    heuristic_cost: f64,
    regression_detected: bool,
};

/// Decision log for debugging
const DecisionLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(DecisionEntry),

    const DecisionEntry = struct {
        timestamp: i64,
        decision: CalibrationDecision,
        validation: ?ValidationEntry,
    };

    const CalibrationDecision = struct {
        cardinality: u64,
        is_small_n: bool,
        base_factors: cost_model.CostFactors,
        adjusted_factors: cost_model.CostFactors,
        stats: QueryStatistics,
    };

    const ValidationEntry = struct {
        cbo_cost: f64,
        heuristic_cost: f64,
        cost_ratio: f64,
        has_regression: bool,
    };

    fn init(allocator: std.mem.Allocator) DecisionLog {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(DecisionEntry).init(allocator),
        };
    }

    fn deinit(self: *DecisionLog) void {
        self.entries.deinit();
    }

    fn recordDecision(self: *DecisionLog, decision: CalibrationDecision) void {
        self.entries.append(.{
            .timestamp = compat_milliTimestamp(),
            .decision = decision,
            .validation = null,
        }) catch {};
    }

    fn recordValidation(self: *DecisionLog, validation: ValidationEntry) void {
        if (self.entries.items.len > 0) {
            self.entries.items[self.entries.items.len - 1].validation = validation;
        }
    }

    /// Export log as JSON for analysis
    pub fn exportJSON(self: *DecisionLog, writer: anytype) !void {
        try std.json.stringify(self.entries.items, .{ .whitespace = .indent_2 }, writer);
    }
};

/// Calibration metrics
const CalibrationMetrics = struct {
    small_n_queries: u64,
    large_n_queries: u64,
    regressions_prevented: u64,
    total_confidence: f64,
    validation_count: u64,

    fn init() CalibrationMetrics {
        return .{
            .small_n_queries = 0,
            .large_n_queries = 0,
            .regressions_prevented = 0,
            .total_confidence = 0,
            .validation_count = 0,
        };
    }

    fn recordCalibration(self: *CalibrationMetrics, is_small_n: bool, confidence: f64) void {
        if (is_small_n) {
            self.small_n_queries += 1;
        } else {
            self.large_n_queries += 1;
        }
        self.total_confidence += confidence;
    }

    fn recordValidation(self: *CalibrationMetrics, has_regression: bool, cost_ratio: f64) void {
        _ = cost_ratio;
        self.validation_count += 1;
        if (has_regression) {
            self.regressions_prevented += 1;
        }
    }

    pub fn getAverageConfidence(self: *const CalibrationMetrics) f64 {
        const total = self.small_n_queries + self.large_n_queries;
        if (total == 0) return 0;
        return self.total_confidence / @as(f64, @floatFromInt(total));
    }
};
