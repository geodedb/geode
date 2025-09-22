const std = @import("std");

// Cost Model Enumeration Seed (S-024) – foundational estimation primitives.
// Provides lightweight row & cost estimation for early planner phases without
// altering existing heuristic enumerator selection. Future CBO layers can plug
// into these APIs to refine estimates and compare alternative shapes.
//
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=EstimatorPrimitives; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates; BENCH=BenchmarkCANARY_REQ_GQL_075_CostModelSeedVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

pub const LogicalOpKind = enum { Scan, Expand, Filter, Project, Aggregate, Sort, Limit, SetOp };

pub const CardinalityEstimate = struct {
    rows: f64, // Estimated row count (can be fractional pre-rounding)
    confidence: f32, // 0..1 heuristic confidence
};

pub const Cost = struct {
    cpu: f64,
    memory: f64,
    io: f64,
    pub fn total(self: Cost) f64 {
        return self.cpu + self.memory + self.io;
    }
};

pub const OpDescriptor = struct {
    kind: LogicalOpKind,
    // Basic shaping factors (heuristic): selectivity (0..1), projected column count, avg row width bytes
    selectivity: f64 = 1.0,
    projected_cols: u16 = 1,
    avg_row_width: u16 = 16,
};

pub const EstimatorConfig = struct {
    scan_default: f64 = 1000.0, // default base rows for a Scan (can be replaced with stats)
    expand_degree: f64 = 8.0, // average expansion degree heuristic
    filter_selectivity_floor: f64 = 0.05,
    agg_group_reduction: f64 = 0.25,
    sort_cpu_factor: f64 = 0.002, // per-row log2(rows) multiplier
};

pub fn estimate(op: OpDescriptor, children: []const CardinalityEstimate, cfg: EstimatorConfig) CardinalityEstimate {
    switch (op.kind) {
        .Scan => return .{ .rows = cfg.scan_default, .confidence = 0.4 },
        .Expand => {
            const base = if (children.len == 1) children[0].rows else 1.0;
            return .{ .rows = base * cfg.expand_degree, .confidence = 0.35 };
        },
        .Filter => {
            const base = if (children.len == 1) children[0].rows else 1.0;
            const sel = @max(cfg.filter_selectivity_floor, op.selectivity);
            return .{ .rows = base * sel, .confidence = 0.5 };
        },
        .Project => {
            const base = if (children.len == 1) children[0].rows else 1.0;
            return .{ .rows = base, .confidence = if (children.len == 1) children[0].confidence else 0.3 };
        },
        .Aggregate => {
            const base = if (children.len == 1) children[0].rows else cfg.scan_default;
            return .{ .rows = @max(1.0, base * cfg.agg_group_reduction), .confidence = 0.3 };
        },
        .Sort => {
            const base = if (children.len == 1) children[0].rows else 1.0;
            return .{ .rows = base, .confidence = 0.25 };
        },
        .Limit => {
            const base = if (children.len == 1) children[0].rows else 1.0;
            // A LIMIT cannot increase rows; keep confidence from child but clamp.
            return .{ .rows = @min(base, 100.0), .confidence = if (children.len == 1) children[0].confidence else 0.4 };
        },
        .SetOp => {
            // Simple heuristic: assume union-like distinct reduction.
            var total: f64 = 0;
            for (children) |c| total += c.rows;
            return .{ .rows = @max(1.0, total * 0.7), .confidence = 0.2 };
        },
    }
}

pub fn cost(op: OpDescriptor, card: CardinalityEstimate, cfg: EstimatorConfig) Cost {
    const row_width = @as(f64, @floatFromInt(op.avg_row_width));
    const rows = card.rows;
    return switch (op.kind) {
        .Scan => .{ .cpu = rows * 0.001, .memory = rows * row_width * 0.00001, .io = rows * 0.0005 },
        .Expand => .{ .cpu = rows * 0.0015, .memory = rows * row_width * 0.000012, .io = rows * 0.0006 },
        .Filter => .{ .cpu = rows * 0.0008, .memory = rows * row_width * 0.000004, .io = 0 },
        .Project => .{ .cpu = rows * 0.0003, .memory = rows * (row_width * 0.75) * 0.000004, .io = 0 },
        .Aggregate => .{ .cpu = rows * 0.002, .memory = rows * row_width * 0.00002, .io = 0 },
        .Sort => .{ .cpu = rows * cfg.sort_cpu_factor * std.math.log2(rows + 1), .memory = rows * row_width * 0.00003, .io = 0 },
        .Limit => .{ .cpu = @min(rows, 100.0) * 0.00005, .memory = rows * row_width * 0.000002, .io = 0 },
        .SetOp => .{ .cpu = rows * 0.0012, .memory = rows * row_width * 0.000015, .io = 0 },
    };
}

test "seed basic monotonic filter reduction" {
    const cfg = EstimatorConfig{};
    const scan_est = estimate(.{ .kind = .Scan }, &[_]CardinalityEstimate{}, cfg);
    const filter_est = estimate(.{ .kind = .Filter, .selectivity = 0.2 }, &[_]CardinalityEstimate{scan_est}, cfg);
    try std.testing.expect(filter_est.rows <= scan_est.rows);
    try std.testing.expect(filter_est.rows > 0);
}
