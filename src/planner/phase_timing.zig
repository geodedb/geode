const std = @import("std");

// Planner Phase Timing Instrumentation
// Provides lightweight timers for rewrite, cardinality estimation, and cost evaluation phases.
// Collected metrics are used by variance envelope benchmark PlannerCostModelPhaseVarianceEnvelope.
//
// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerCostModelPhaseTiming; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_021_PlannerCostModelPhaseTiming; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerCostModelPhaseVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

pub const Phase = enum { rewrite, cardinality, cost_eval };

pub const PhaseTimings = struct {
    rewrite_ns: u64 = 0,
    cardinality_ns: u64 = 0,
    cost_eval_ns: u64 = 0,
};

pub const PhaseTimer = struct {
    current: ?Phase = null,
    start_ts: i128 = 0,
    timings: *PhaseTimings,

    pub fn init(timings: *PhaseTimings) PhaseTimer {
        return .{ .timings = timings };
    }

    pub fn begin(self: *PhaseTimer, phase: Phase) void {
        if (self.current) |_| self.end();
        self.current = phase;
        self.start_ts = std.time.nanoTimestamp();
    }

    pub fn end(self: *PhaseTimer) void {
        if (self.current) |p| {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - self.start_ts);
            switch (p) {
                .rewrite => self.timings.rewrite_ns += elapsed,
                .cardinality => self.timings.cardinality_ns += elapsed,
                .cost_eval => self.timings.cost_eval_ns += elapsed,
            }
            self.current = null;
        }
    }

    pub fn snapshot(self: *PhaseTimer) PhaseTimings {
        // Return a copy; ensures any in-progress phase accounted if needed
        if (self.current) |_| self.end();
        return self.timings.*;
    }
};

test "TestCANARY_REQ_GQL_021_PlannerCostModelPhaseTiming" {
    var timings: PhaseTimings = .{};
    var pt = PhaseTimer.init(&timings);
    pt.begin(.rewrite);
    std.time.sleep(1_000); // 1 microsecond
    pt.end();
    pt.begin(.cardinality);
    std.time.sleep(1_000);
    pt.end();
    pt.begin(.cost_eval);
    std.time.sleep(1_000);
    pt.end();
    try std.testing.expect(timings.rewrite_ns > 0);
    try std.testing.expect(timings.cardinality_ns > 0);
    try std.testing.expect(timings.cost_eval_ns > 0);
}
