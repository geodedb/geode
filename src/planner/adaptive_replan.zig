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

    pub fn init(threshold_ppm: u32, window: u32) AdaptiveReplan {
        return .{ .threshold_ppm = threshold_ppm, .window = window };
    }

    // expected vs actual row counts; error = |actual-expected|/expected * 1e6
    pub fn observe(self: *AdaptiveReplan, expected: u64, actual: u64) void {
        if (self.triggered) return; // no-op after trigger
        const exp = if (expected == 0) 1 else expected; // avoid div by zero
        const diff = if (actual > exp) actual - exp else exp - actual;
        const error_ppm: u64 = (diff * 1_000_000) / exp;
        self.cumulative_error_ppm += error_ppm;
        self.count += 1;
        if (self.count >= self.window) {
            const avg_error = self.cumulative_error_ppm / self.window;
            if (avg_error >= self.threshold_ppm) {
                self.triggered = true;
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
