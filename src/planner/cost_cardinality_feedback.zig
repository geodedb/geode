const std = @import("std");
const seed = @import("cost_seed.zig");

// Cardinality Calibration Feedback (Enumeration Seed Phase)
// Tracks (estimated, actual) row counts per logical operator and computes
// per-op Absolute Percentage Error (APE) plus aggregate MAPE. This is a
// lightweight feedback loop (Phase 1): NO adaptive weighting yet (mutates no
// global estimator config). Future phases may feed these metrics into dynamic
// selectivity refinement.
// JSON emission handled by cost_explain.v2 when registry provided.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=CalibrationFeedback; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelCardinalityCalibrationFeedback; OWNER=planner; UPDATED=2025-09-22

pub const Entry = struct {
    kind: seed.LogicalOpKind,
    est_rows: f64,
    actual_rows: f64,
    ape: f64, // absolute percentage error
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .entries = std.ArrayList(Entry).empty };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
    }

    fn computeApe(est_rows: f64, actual_rows: f64) f64 {
        if (actual_rows == 0) {
            if (est_rows == 0) return 0; // perfect
            return 1.0; // clamp to max error
        }
        return @abs(actual_rows - est_rows) / actual_rows;
    }

    pub fn record(self: *Registry, kind: seed.LogicalOpKind, est_rows: f64, actual_rows: f64) !void {
        const ape = computeApe(est_rows, actual_rows);
        try self.entries.append(self.allocator, .{ .kind = kind, .est_rows = est_rows, .actual_rows = actual_rows, .ape = ape });
    }

    pub fn mape(self: *const Registry) f64 {
        if (self.entries.items.len == 0) return 0;
        var sum: f64 = 0;
        for (self.entries.items) |e| sum += e.ape;
        return sum / @as(f64, @floatFromInt(self.entries.items.len));
    }
};

test "TestCANARY_REQ_GQL_075_CostModelCardinalityCalibrationFeedback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var reg = Registry.init(gpa.allocator());
    defer reg.deinit();
    // Simulate two operators with known deviations.
    try reg.record(.Scan, 1000, 1000); // perfect
    try reg.record(.Filter, 200, 250); // 20% low
    const m = reg.mape();
    // MAPE = (0 + 0.2)/2 = 0.1
    try std.testing.expect(std.math.fabs(m - 0.1) < 0.0001);
}
