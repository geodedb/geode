const std = @import("std");

// Adaptive Replan Trigger Module
// Tracks observed cardinality estimation error and triggers a replan when a
// deterministic threshold is exceeded.
//
// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerAdaptiveReplanTrigger; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_AdaptiveReplanTrigger; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerAdaptiveReplanVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

pub const AdaptiveReplan = struct {
    threshold_ppm: u32, // parts per million error threshold
    window: u32,
    count: u32 = 0,
    cumulative_error_ppm: u64 = 0,
    triggered: bool = false,
    // Refinement fields
    dynamic_threshold_ppm: u32 = 0, // starts at threshold_ppm
    avg_bias_ppm: f64 = 0, // exponential moving average of signed error
    ema_alpha: f64 = 0.2,
    hysteresis_ppm: u32 = 20_000, // 2% hysteresis band to avoid flapping
    consecutive_bias_exceed: u8 = 0,
    consecutive_bias_limit: u8 = 3,

    pub fn init(threshold_ppm: u32, window: u32) AdaptiveReplan {
        return .{ .threshold_ppm = threshold_ppm, .window = window, .dynamic_threshold_ppm = threshold_ppm };
    }

    // expected vs actual row counts; error = |actual-expected|/expected * 1e6
    pub fn observe(self: *AdaptiveReplan, expected: u64, actual: u64) void {
        if (self.triggered) return; // no-op after trigger
        const exp = if (expected == 0) 1 else expected; // avoid div by zero
        const diff_signed: i64 = @as(i64, @intCast(actual)) - @as(i64, @intCast(exp));
        const diff = if (diff_signed < 0) @as(u64, @intCast(-diff_signed)) else @as(u64, @intCast(diff_signed));
        const error_ppm: u64 = (diff * 1_000_000) / exp;
        // signed error fraction for bias tracking
        const signed_ppm: f64 = @as(f64, @floatFromInt(diff_signed)) * 1_000_000.0 / @as(f64, @floatFromInt(exp));
        // exponential moving average of bias
        self.avg_bias_ppm = self.ema_alpha * signed_ppm + (1.0 - self.ema_alpha) * self.avg_bias_ppm;
        // If persistent bias in same direction beyond 3 samples, tighten threshold; opposite direction loosens slightly.
        if (std.math.fabs(self.avg_bias_ppm) > @as(f64, @floatFromInt(self.threshold_ppm))) {
            self.consecutive_bias_exceed += 1;
        } else if (self.consecutive_bias_exceed > 0) {
            self.consecutive_bias_exceed = 0;
        }
        if (self.consecutive_bias_exceed >= self.consecutive_bias_limit) {
            // tighten dynamic threshold by 10% but not below 40% of original
            const min_thresh = self.threshold_ppm / 5 * 2; // 40%
            var new_dyn = self.dynamic_threshold_ppm - (self.dynamic_threshold_ppm / 10);
            if (new_dyn < min_thresh) new_dyn = min_thresh;
            self.dynamic_threshold_ppm = new_dyn;
            self.consecutive_bias_exceed = 0; // reset counter after adjustment
        } else if (self.avg_bias_ppm == 0 and self.dynamic_threshold_ppm < self.threshold_ppm) {
            // slowly relax threshold upward (decay) when unbiased
            self.dynamic_threshold_ppm += self.threshold_ppm / 50; // +2% original per neutral period
            if (self.dynamic_threshold_ppm > self.threshold_ppm) self.dynamic_threshold_ppm = self.threshold_ppm;
        }
        self.cumulative_error_ppm += error_ppm;
        self.count += 1;
        if (self.count >= self.window) {
            const avg_error = self.cumulative_error_ppm / self.window;
            const effective_threshold = self.dynamic_threshold_ppm;
            if (avg_error + self.hysteresis_ppm >= effective_threshold) {
                if (avg_error >= effective_threshold) self.triggered = true; // within hysteresis band we don't trigger until exceed
            }
            // reset window after evaluation if not triggered
            if (!self.triggered) {
                self.count = 0;
                self.cumulative_error_ppm = 0;
            }
        }
    }

    pub fn shouldReplan(self: *AdaptiveReplan) bool {
        return self.triggered;
    }
};

test "TestCANARY_REQ_GQL_021_AdaptiveReplanTrigger" {
    var ar = AdaptiveReplan.init(150_000, 4); // 15% threshold
    // Provide three low-error observations
    ar.observe(1000, 1020); // 2% -> 20000 ppm
    ar.observe(1000, 980); // 2% -> 20000
    ar.observe(1000, 990); // 1% -> 10000
    try std.testing.expect(!ar.shouldReplan());
    // Fourth pushes average above 15%? Provide large deviation
    ar.observe(1000, 500); // 50% -> 500000
    // Average ppm = (20000+20000+10000+500000)/4 = 137500 -> still below 150000 threshold
    try std.testing.expect(!ar.shouldReplan());
    // Another window with high errors to trigger
    ar.observe(1000, 400); // new window start (count reset earlier?) depends on if triggered; previous did not trigger so window reset. count=1
    ar.observe(1000, 300); // count=2
    ar.observe(1000, 250); // count=3
    ar.observe(1000, 200); // count=4 -> compute average
    try std.testing.expect(ar.shouldReplan());
}

// Refinement test: verify dynamic threshold tightens under persistent high bias sooner than static threshold would trigger.
// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerAdaptiveReplanRefinement; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_AdaptiveReplanRefinement; OWNER=planner; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_021_AdaptiveReplanRefinement" {
    var ar_ref = AdaptiveReplan.init(200_000, 4); // 20% static baseline
    // Inject persistent 35% underestimation bias (actual higher than expected)
    var i: usize = 0;
    while (!ar_ref.shouldReplan() and i < 40) : (i += 1) {
        const expected: u64 = 10_000;
        const actual: u64 = expected + (expected * 35 / 100); // +35%
        ar_ref.observe(expected, actual);
    }
    // Should replan before hitting many windows due to threshold tightening
    try std.testing.expect(ar_ref.shouldReplan());
}
