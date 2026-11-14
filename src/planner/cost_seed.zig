const std = @import("std");

// Cost Model Enumeration Seed (S-024) – foundational estimation primitives.
// Provides lightweight row & cost estimation for early planner phases without
// altering existing heuristic enumerator selection. Future CBO layers can plug
// into these APIs to refine estimates and compare alternative shapes.
//
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=EstimatorPrimitives; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates; BENCH=BenchmarkCANARY_REQ_GQL_075_CostModelSeedVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

// CANARY: REQ=REQ-AUTO-INDEX-EXPLAIN-003; FEATURE="AutoIdIndex"; ASPECT=IndexSeekOpKind; STATUS=IMPL; OWNER=planner; UPDATED=2026-02-07
pub const LogicalOpKind = enum { Scan, Expand, Filter, Project, Aggregate, Sort, Limit, SetOp, IndexSeek };

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
    adaptive_alpha: f64 = 0.2, // EMA smoothing factor for adaptive bias
};

// Adaptive bias factors (EMA per LogicalOpKind) allow runtime feedback calibration.
// Each kind begins with neutral bias=1.0. After observing actual row counts, update
// with: bias = alpha*(actual/estimate) + (1-alpha)*bias. Applied multiplicatively
// to subsequent estimates of same op kind. Clamped to [0.05, 20.0] to avoid runaway.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBias; STATUS=IMPL; OWNER=planner; UPDATED=2026-11-14
pub const AdaptiveBiasRegistry = struct {
    // NOTE: Zig 0.15 reflection: direct .Enum.fields access not available; keep constant in sync with LogicalOpKind.
    pub const KIND_COUNT: comptime_int = 9; // Scan, Expand, Filter, Project, Aggregate, Sort, Limit, SetOp, IndexSeek
    biases: [KIND_COUNT]f64 = [_]f64{1.0} ** KIND_COUNT,
    // Dynamic alpha adaptation state per kind:
    dyn_alpha: [KIND_COUNT]f64 = [_]f64{0.2} ** KIND_COUNT,
    // Exponential moving averages for ratio mean and squared mean for variance estimation.
    ratio_mean: [KIND_COUNT]f64 = [_]f64{1.0} ** KIND_COUNT,
    ratio_sq_mean: [KIND_COUNT]f64 = [_]f64{1.0} ** KIND_COUNT,
    // Last computed coefficient of variation per kind (for explain transparency)
    last_cv: [KIND_COUNT]f64 = [_]f64{0.0} ** KIND_COUNT,
    // Last CV classification label index (0=stable,1=moderate,2=volatile)
    last_cv_class: [KIND_COUNT]u8 = [_]u8{0} ** KIND_COUNT,
    // Configuration bounds for alpha adaptation (could be exposed later).
    alpha_min: f64 = 0.10,
    alpha_max: f64 = 0.50,
    adapt_rate: f64 = 0.05, // incremental step when adjusting alpha
    variance_stable_threshold: f64 = 0.12, // CV below -> increase alpha
    variance_unstable_threshold: f64 = 0.30, // CV above -> decrease alpha
    // Clamp saturation tracking (consecutive updates that land at min or max clamp bound)
    low_clamp_streak: [KIND_COUNT]u16 = [_]u16{0} ** KIND_COUNT,
    high_clamp_streak: [KIND_COUNT]u16 = [_]u16{0} ** KIND_COUNT,
    // Active warning flags once streak >= threshold (remain set until streak resets)
    low_clamp_warning: [KIND_COUNT]bool = [_]bool{false} ** KIND_COUNT,
    high_clamp_warning: [KIND_COUNT]bool = [_]bool{false} ** KIND_COUNT,
    clamp_warning_threshold: u16 = 5,

    pub fn apply(self: *AdaptiveBiasRegistry, kind: LogicalOpKind, raw_rows: f64) f64 {
        const idx = @intFromEnum(kind);
        return raw_rows * self.biases[idx];
    }

    pub fn getBias(self: *const AdaptiveBiasRegistry, kind: LogicalOpKind) f64 {
        return self.biases[@intFromEnum(kind)];
    }

    pub fn getAlpha(self: *const AdaptiveBiasRegistry, kind: LogicalOpKind) f64 {
        return self.dyn_alpha[@intFromEnum(kind)];
    }

    pub fn update(self: *AdaptiveBiasRegistry, kind: LogicalOpKind, estimated_rows: f64, actual_rows: f64, alpha: f64) void {
        if (estimated_rows <= 0 or actual_rows <= 0) return; // ignore nonsensical inputs
        const ratio = actual_rows / estimated_rows;
        const idx = @intFromEnum(kind);
        const prev = self.biases[idx];
        var next = alpha * ratio + (1.0 - alpha) * prev;
        if (next < 0.05) next = 0.05;
        if (next > 20.0) next = 20.0;
        self.biases[idx] = next;
    }

    /// Adaptive update that also evolves per-kind alpha based on coefficient of variation of ratios.
    /// Steps:
    /// 1. Update running moments for ratio.
    /// 2. Compute CV ~ sqrt(var)/mean.
    /// 3. Adjust alpha toward bounds.
    /// 4. Apply bias update using dynamic alpha.
    pub fn updateAdaptive(self: *AdaptiveBiasRegistry, kind: LogicalOpKind, estimated_rows: f64, actual_rows: f64) void {
        if (estimated_rows <= 0 or actual_rows <= 0) return;
        const idx = @intFromEnum(kind);
        const ratio = actual_rows / estimated_rows;
        // Moment update (EMA with fixed smoothing for statistics)
        const stats_alpha = 0.2; // separate smoothing for variance stats
        const m_prev = self.ratio_mean[idx];
        const m_next = stats_alpha * ratio + (1.0 - stats_alpha) * m_prev;
        self.ratio_mean[idx] = m_next;
        const sq = ratio * ratio;
        const sq_prev = self.ratio_sq_mean[idx];
        const sq_next = stats_alpha * sq + (1.0 - stats_alpha) * sq_prev;
        self.ratio_sq_mean[idx] = sq_next;
        var variance = sq_next - m_next * m_next;
        if (variance < 0) variance = 0; // numerical guard
        const stddev = std.math.sqrt(variance);
        const cv = if (m_next <= 0.0000001) 0 else stddev / m_next;
        var a = self.dyn_alpha[idx];
        var class: u8 = 1; // moderate default
        if (cv < self.variance_stable_threshold) {
            // More stable -> increase alpha
            a += self.adapt_rate;
            class = 0;
        } else if (cv > self.variance_unstable_threshold) {
            // Volatile -> decrease alpha
            a -= self.adapt_rate;
            class = 2;
        }
        if (a < self.alpha_min) a = self.alpha_min;
        if (a > self.alpha_max) a = self.alpha_max;
        self.dyn_alpha[idx] = a;
        self.last_cv[idx] = cv;
        self.last_cv_class[idx] = class;
        // Apply bias update using dynamic alpha
        const prev_bias = self.biases[idx];
        const unclamped = a * ratio + (1.0 - a) * prev_bias;
        var next_bias = unclamped;
        var low_clamped = false;
        var high_clamped = false;
        if (next_bias < 0.05) {
            next_bias = 0.05;
            low_clamped = true;
        }
        if (next_bias > 20.0) {
            next_bias = 20.0;
            high_clamped = true;
        }
        self.biases[idx] = next_bias;

        // Saturation tracking logic
        if (low_clamped and !high_clamped) {
            self.low_clamp_streak[idx] += 1;
            self.high_clamp_streak[idx] = 0;
            if (self.low_clamp_streak[idx] >= self.clamp_warning_threshold) self.low_clamp_warning[idx] = true;
        } else if (high_clamped and !low_clamped) {
            self.high_clamp_streak[idx] += 1;
            self.low_clamp_streak[idx] = 0;
            if (self.high_clamp_streak[idx] >= self.clamp_warning_threshold) self.high_clamp_warning[idx] = true;
        } else {
            // bias inside bounds → reset streak counters and clear warnings
            self.low_clamp_streak[idx] = 0;
            self.high_clamp_streak[idx] = 0;
            self.low_clamp_warning[idx] = false;
            self.high_clamp_warning[idx] = false;
        }
    }

    /// Serialize registry biases to writer in a stable binary format:
    /// v1: [u32 magic 'ABIA'][u16 version=1][u16 count][f64 * count]
    /// v2: [u32 magic 'ABIA'][u16 version=2][u16 count]
    ///      [f64 * count biases][f64 * count dyn_alpha][f64 * count ratio_mean][f64 * count ratio_sq_mean]
    ///      [f64 * count last_cv][u8 * count last_cv_class]
    pub fn serialize(self: *const AdaptiveBiasRegistry, w: anytype) !void {
        try w.writeAll("ABIA");
        try w.writeInt(u16, 2, .little);
        const count: u16 = @intCast(self.biases.len);
        try w.writeInt(u16, count, .little);
        for (self.biases) |b| try w.writeInt(f64, b, .little);
        // v2 extras
        for (self.dyn_alpha) |a| try w.writeInt(f64, a, .little);
        for (self.ratio_mean) |m| try w.writeInt(f64, m, .little);
        for (self.ratio_sq_mean) |m2| try w.writeInt(f64, m2, .little);
        for (self.last_cv) |cv| try w.writeInt(f64, cv, .little);
        // last_cv_class as raw bytes
        var i: usize = 0;
        while (i < self.last_cv_class.len) : (i += 1) {
            try w.writeByte(self.last_cv_class[i]);
        }
    }

    pub const DeserializeError = error{ BadMagic, UnsupportedVersion, Truncated };

    pub fn deserialize(self: *AdaptiveBiasRegistry, r: anytype) !void {
        var magic: [4]u8 = undefined;
        if (try r.readAll(&magic) != magic.len) return DeserializeError.Truncated;
        if (!std.mem.eql(u8, &magic, "ABIA")) return DeserializeError.BadMagic;
        const ver = try r.readInt(u16, .little) catch return DeserializeError.Truncated;
        if (ver != 1 and ver != 2) return DeserializeError.UnsupportedVersion;
        const count = try r.readInt(u16, .little) catch return DeserializeError.Truncated;
        if (count != self.biases.len) return DeserializeError.UnsupportedVersion; // size mismatch unrecognized
        var i: usize = 0;
        while (i < self.biases.len) : (i += 1) {
            const v = try r.readInt(f64, .little) catch return DeserializeError.Truncated;
            self.biases[i] = v;
        }
        if (ver == 2) {
            // dyn_alpha
            i = 0;
            while (i < self.dyn_alpha.len) : (i += 1) {
                self.dyn_alpha[i] = try r.readInt(f64, .little) catch return DeserializeError.Truncated;
            }
            // ratio_mean
            i = 0;
            while (i < self.ratio_mean.len) : (i += 1) {
                self.ratio_mean[i] = try r.readInt(f64, .little) catch return DeserializeError.Truncated;
            }
            // ratio_sq_mean
            i = 0;
            while (i < self.ratio_sq_mean.len) : (i += 1) {
                self.ratio_sq_mean[i] = try r.readInt(f64, .little) catch return DeserializeError.Truncated;
            }
            // last_cv
            i = 0;
            while (i < self.last_cv.len) : (i += 1) {
                self.last_cv[i] = try r.readInt(f64, .little) catch return DeserializeError.Truncated;
            }
            // last_cv_class
            i = 0;
            while (i < self.last_cv_class.len) : (i += 1) {
                var b: [1]u8 = undefined;
                if ((try r.readAll(&b)) != 1) return DeserializeError.Truncated;
                self.last_cv_class[i] = b[0];
            }
        }
    }

    /// Emit JSON array string of biases (percent integers) into provided allocator.
    pub fn toJson(self: *const AdaptiveBiasRegistry, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        try buf.append('[');
        var i: usize = 0;
        while (i < self.biases.len) : (i += 1) {
            if (i != 0) try buf.append(',');
            const b_int: i64 = @intFromFloat(@floor(self.biases[i] * 100.0 + 0.5));
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{b_int});
            try buf.appendSlice(s);
        }
        try buf.append(']');
        return buf.toOwnedSlice();
    }
};

pub fn estimateWithBias(reg: *AdaptiveBiasRegistry, op: OpDescriptor, children: []const CardinalityEstimate, cfg: EstimatorConfig) CardinalityEstimate {
    const base = estimate(op, children, cfg);
    const biased_rows = reg.apply(op.kind, base.rows);
    return .{ .rows = biased_rows, .confidence = base.confidence };
}

/// Estimate a linear chain of operators (each op depends on previous estimate) applying adaptive bias.
/// Returns array of per-op CardinalityEstimate allocated from provided allocator. Caller owns memory.
pub fn estimateChainWithBias(
    allocator: std.mem.Allocator,
    reg: *AdaptiveBiasRegistry,
    ops: []const OpDescriptor,
    cfg: EstimatorConfig,
) ![]CardinalityEstimate {
    var out = try allocator.alloc(CardinalityEstimate, ops.len);
    var prev: ?CardinalityEstimate = null;
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        const child_slice: []const CardinalityEstimate = if (prev) |c| &[_]CardinalityEstimate{c} else &[_]CardinalityEstimate{};
        out[i] = estimateWithBias(reg, ops[i], child_slice, cfg);
        prev = out[i];
    }
    return out;
}

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
        .IndexSeek => {
            // Index seek returns much fewer rows than a full scan
            return .{ .rows = @max(1.0, cfg.scan_default * 0.01), .confidence = 0.7 };
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
        .IndexSeek => .{ .cpu = rows * 0.0002, .memory = rows * row_width * 0.000005, .io = rows * 0.0001 },
    };
}

test "seed basic monotonic filter reduction" {
    const cfg = EstimatorConfig{};
    const scan_est = estimate(.{ .kind = .Scan }, &[_]CardinalityEstimate{}, cfg);
    const filter_est = estimate(.{ .kind = .Filter, .selectivity = 0.2 }, &[_]CardinalityEstimate{scan_est}, cfg);
    try std.testing.expect(filter_est.rows <= scan_est.rows);
    try std.testing.expect(filter_est.rows > 0);
}
