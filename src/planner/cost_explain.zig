const std = @import("std");
pub const seed = @import("cost_seed.zig");

// Enhanced implementation: adds primitive row estimate & cost fields per op plus totals summary.
// Estimation model: delegate to seed.estimate() and seed.cost() if selectivity provided; else static fallbacks.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSON; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSON; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDetailed; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSONDetailed; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=CalibrationEntries; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelCalibrationEntries; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONBiasFactors; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONBiasFactors; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONRecursive; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONRecursive; OWNER=planner; UPDATED=2025-09-26

fn buildOpsJson(allocator: std.mem.Allocator, schema_name: []const u8, ops: []const seed.OpDescriptor) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    try w.writeAll("{\"schema\":\"");
    try w.writeAll(schema_name);
    try w.writeAll("\",\"ops\":[");
    var total_cost: f64 = 0;
    var total_est_rows: f64 = 0;
    var i: usize = 0;
    var prev_est: ?seed.CardinalityEstimate = null;
    const cfg = seed.EstimatorConfig{};
    while (i < ops.len) : (i += 1) {
        const op = ops[i];
        const children_slice: []const seed.CardinalityEstimate = if (prev_est) |pe| &[_]seed.CardinalityEstimate{pe} else &[_]seed.CardinalityEstimate{};
        const est_card = seed.estimate(op, children_slice, cfg);
        const op_cost_s = seed.cost(op, est_card, cfg);
        const est_rows = est_card.rows;
        const op_cost = op_cost_s.total();
        if (i == 0) total_est_rows = est_rows; // baseline input rows (first op)
        total_cost += op_cost;
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"idx\":");
        try w.print("{}", .{i});
        try w.writeAll(",\"kind\":\"");
        try w.writeAll(@tagName(op.kind));
        try w.writeAll("\",\"est_rows\":");
        try w.print("{d}", .{@as(i64, @intFromFloat(@floor(est_rows)))});
        try w.writeAll(",\"cost\":");
        try w.print("{d}", .{@as(i64, @intFromFloat(@floor(op_cost)))});
        try w.writeAll("}");
        prev_est = est_card;
    }
    try w.writeAll("],\"totals\":{");
    try w.writeAll("\"est_rows\":");
    try w.print("{d}", .{@as(i64, @intFromFloat(@floor(total_est_rows)))});
    try w.writeAll(",\"cost\":");
    try w.print("{d}", .{@as(i64, @intFromFloat(@floor(total_cost)))});
    try w.writeAll("}}");
    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

pub fn explainChain(allocator: std.mem.Allocator, ops: []const seed.OpDescriptor) ![]u8 {
    return buildOpsJson(allocator, "cost_explain.v1", ops);
}

/// Build a synthetic recursive tree form for demonstration: wraps linear chain into a
/// right-deep nested structure {"schema":"cost_explain.recursive.v1","root":{node}}
/// where each node = {idx,kind,est_rows,cost,child?:node}.
pub fn explainRecursive(allocator: std.mem.Allocator, ops: []const seed.OpDescriptor) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const cfg = seed.EstimatorConfig{};
    var prev_est: ?seed.CardinalityEstimate = null;
    try buf.appendSlice("{\"schema\":\"cost_explain.recursive.v1\",\"root\":");
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        const op = ops[i];
        const children_slice: []const seed.CardinalityEstimate = if (prev_est) |pe| &[_]seed.CardinalityEstimate{pe} else &[_]seed.CardinalityEstimate{};
        const est_card = seed.estimate(op, children_slice, cfg);
        prev_est = est_card;
        try buf.appendSlice("{\"idx\":");
        try buf.writer().print("{}", .{i});
        try buf.appendSlice(",\"kind\":\"");
        try buf.appendSlice(@tagName(op.kind));
        try buf.appendSlice("\",\"est_rows\":");
        try buf.writer().print("{d}", .{@as(i64, @intFromFloat(@floor(est_card.rows)))});
        const op_cost = seed.cost(op, est_card, cfg).total();
        try buf.appendSlice(",\"cost\":");
        try buf.writer().print("{d}", .{@as(i64, @intFromFloat(@floor(op_cost)))});
        if (i < ops.len - 1) {
            try buf.appendSlice(",\"child\":");
        }
    }
    // close nested objects
    if (ops.len > 0) {
        var c: usize = 0;
        while (c < ops.len) : (c += 1) try buf.appendSlice("}");
    }
    try buf.appendSlice("}");
    return buf.toOwnedSlice();
}

pub fn explainChainWithCalibration(allocator: std.mem.Allocator, ops: []const seed.OpDescriptor, actual_rows: ?[]const f64, reg: ?*anyopaque) ![]u8 {
    _ = reg; // reserved for future bias registry
    var base = try buildOpsJson(allocator, "cost_explain.v2", ops);
    if (base.len == 0 or base[base.len - 1] != '}') return base;
    if (actual_rows == null or actual_rows.?.len != ops.len or ops.len == 0) {
        const stub = " ,\"calibration\":{\"mape\":0,\"entries\":[]}}";
        var extended_stub = try allocator.alloc(u8, (base.len - 1) + stub.len);
        std.mem.copyForwards(u8, extended_stub, base[0 .. base.len - 1]);
        std.mem.copyForwards(u8, extended_stub[base.len - 1 ..], stub);
        allocator.free(base);
        return extended_stub;
    }
    const acts = actual_rows.?;
    // Re-run estimation to parallel buildOpsJson
    var est_rows = try allocator.alloc(f64, ops.len);
    defer allocator.free(est_rows);
    var prev_est: ?seed.CardinalityEstimate = null;
    const cfg = seed.EstimatorConfig{};
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        const children_slice: []const seed.CardinalityEstimate = if (prev_est) |pe| &[_]seed.CardinalityEstimate{pe} else &[_]seed.CardinalityEstimate{};
        const est_card = seed.estimate(ops[i], children_slice, cfg);
        est_rows[i] = est_card.rows;
        prev_est = est_card;
    }
    var entries_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer entries_buf.deinit(allocator);
    var ew = entries_buf.writer(allocator);
    try ew.writeByte('[');
    var total_pct: f64 = 0;
    i = 0;
    while (i < ops.len) : (i += 1) {
        const est = est_rows[i];
        const act = acts[i];
        const denom = if (act <= 0) 1.0 else act;
        const diff = if (est >= act) est - act else act - est;
        const pct_err = diff / denom; // 0..inf
        total_pct += pct_err;
        const pct_int: i64 = @intFromFloat(@floor(pct_err * 100.0 + 0.5));
        if (i != 0) try ew.writeByte(',');
        try ew.writeAll("{\"idx\":");
        try ew.print("{}", .{i});
        try ew.writeAll(",\"est\":");
        try ew.print("{d}", .{@as(i64, @intFromFloat(@floor(est)))});
        try ew.writeAll(",\"actual\":");
        try ew.print("{d}", .{@as(i64, @intFromFloat(@floor(act)))});
        try ew.writeAll(",\"abs_pct_err\":");
        try ew.print("{d}", .{pct_int});
        try ew.writeByte('}');
    }
    try ew.writeByte(']');
    const mape_int: i64 = @intFromFloat(@floor((total_pct / @as(f64, @floatFromInt(ops.len))) * 100.0 + 0.5));
    // Assemble final JSON
    const prefix_len = base.len - 1;
    const intro = " ,\"calibration\":{\"mape\":";
    const mid = ",\"entries\":";
    const close = "}}";
    var mape_buf: [32]u8 = undefined;
    const mape_slice = try std.fmt.bufPrint(&mape_buf, "{d}", .{mape_int});
    const mlen = mape_slice.len;
    const final_len = prefix_len + intro.len + mlen + mid.len + entries_buf.items.len + close.len;
    var out = try allocator.alloc(u8, final_len);
    var cursor: usize = 0;
    std.mem.copyForwards(u8, out[cursor..], base[0..prefix_len]);
    cursor += prefix_len;
    std.mem.copyForwards(u8, out[cursor..], intro);
    cursor += intro.len;
    std.mem.copyForwards(u8, out[cursor..], mape_slice);
    cursor += mlen;
    std.mem.copyForwards(u8, out[cursor..], mid);
    cursor += mid.len;
    std.mem.copyForwards(u8, out[cursor..], entries_buf.items);
    cursor += entries_buf.items.len;
    std.mem.copyForwards(u8, out[cursor..], close);
    cursor += close.len;
    allocator.free(base);
    return out;
}

pub fn explainChainWithBias(allocator: std.mem.Allocator, ops: []const seed.OpDescriptor, bias_reg: *seed.AdaptiveBiasRegistry) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    try w.writeAll("{\"schema\":\"cost_explain.v3\",\"ops\":[");
    const cfg = seed.EstimatorConfig{};
    var prev_est: ?seed.CardinalityEstimate = null;
    var total_cost: f64 = 0;
    var total_est_rows: f64 = 0;
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        const op = ops[i];
        const child_slice: []const seed.CardinalityEstimate = if (prev_est) |pe| &[_]seed.CardinalityEstimate{pe} else &[_]seed.CardinalityEstimate{};
        const base = seed.estimate(op, child_slice, cfg);
        const biased_rows = bias_reg.apply(op.kind, base.rows);
        const op_cost_s = seed.cost(op, .{ .rows = biased_rows, .confidence = base.confidence }, cfg);
        const op_cost = op_cost_s.total();
        if (i == 0) total_est_rows = biased_rows;
        total_cost += op_cost;
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"idx\":");
        try w.print("{}", .{i});
        try w.writeAll(",\"kind\":\"");
        try w.writeAll(@tagName(op.kind));
        try w.writeAll("\",\"est_rows\":");
        try w.print("{d}", .{@as(i64, @intFromFloat(@floor(biased_rows)))});
        try w.writeAll(",\"bias\":");
        const b = bias_reg.getBias(op.kind);
        // bias as integer percentage (bias*100 rounded)
        const b_int: i64 = @intFromFloat(@floor(b * 100.0 + 0.5));
        try w.print("{d}", .{b_int});
        try w.writeAll(",\"cost\":");
        try w.print("{d}", .{@as(i64, @intFromFloat(@floor(op_cost)))});
        try w.writeAll("}");
        prev_est = .{ .rows = biased_rows, .confidence = base.confidence };
    }
    try w.writeAll("],\"totals\":{");
    try w.writeAll("\"est_rows\":");
    try w.print("{d}", .{@as(i64, @intFromFloat(@floor(total_est_rows)))});
    try w.writeAll(",\"cost\":");
    try w.print("{d}", .{@as(i64, @intFromFloat(@floor(total_cost)))});
    try w.writeAll("}}");
    // embed registry snapshot (per kind bias list) for transparency
    try w.writeAll(",\"bias_snapshot\":[");
    var k: usize = 0;
    while (k < @typeInfo(seed.LogicalOpKind).Enum.fields.len) : (k += 1) {
        if (k != 0) try w.writeByte(',');
        const kind_tag: seed.LogicalOpKind = @enumFromInt(k);
        const bb = bias_reg.getBias(kind_tag);
        const bb_int: i64 = @intFromFloat(@floor(bb * 100.0 + 0.5));
        try w.print("{d}", .{bb_int});
    }
    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

/// Unified explain schema v4 combining base, bias, dynamic alpha, CV stats and classification labels.
/// JSON structure:
/// {"schema":"cost_explain.v4","ops":[{idx,kind,est_rows,bias,alpha,cv,cv_class,cost}...],
///   "totals":{est_rows,cost},
///   "bias_snapshot":[...percent...],
///   "alpha_snapshot":[...float2dp...],
///   "cv_snapshot":[...float3dp...],
///   "cv_class_snapshot":["stable"|"moderate"|"volatile"...]
/// }
pub fn explainChainUnifiedV4(allocator: std.mem.Allocator, ops: []const seed.OpDescriptor, bias_reg: *seed.AdaptiveBiasRegistry) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    try w.writeAll("{\"schema\":\"cost_explain.v4\",\"ops\":[");
    const cfg = seed.EstimatorConfig{};
    var prev_est: ?seed.CardinalityEstimate = null;
    var total_cost: f64 = 0;
    var total_est_rows: f64 = 0;
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        const op = ops[i];
        const child_slice: []const seed.CardinalityEstimate = if (prev_est) |pe| &[_]seed.CardinalityEstimate{pe} else &[_]seed.CardinalityEstimate{};
        const base = seed.estimate(op, child_slice, cfg);
        const biased_rows = bias_reg.apply(op.kind, base.rows);
        const op_cost_s = seed.cost(op, .{ .rows = biased_rows, .confidence = base.confidence }, cfg);
        const op_cost = op_cost_s.total();
        if (i == 0) total_est_rows = biased_rows;
        total_cost += op_cost;
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"idx\":");
        try w.print("{}", .{i});
        try w.writeAll(",\"kind\":\"");
        try w.writeAll(@tagName(op.kind));
        try w.writeAll("\",\"est_rows\":");
        try w.print("{d}", .{@as(i64, @intFromFloat(@floor(biased_rows)))});
        try w.writeAll(",\"bias\":");
        const b = bias_reg.getBias(op.kind);
        const b_int: i64 = @intFromFloat(@floor(b * 100.0 + 0.5));
        try w.print("{d}", .{b_int});
        try w.writeAll(",\"alpha\":");
        const a = bias_reg.getAlpha(op.kind);
        try w.print("{d:.2}", .{a});
        try w.writeAll(",\"cv\":");
        const cv = bias_reg.last_cv[@intFromEnum(op.kind)];
        try w.print("{d:.3}", .{cv});
        try w.writeAll(",\"cv_class\":\"");
        const cls_idx = bias_reg.last_cv_class[@intFromEnum(op.kind)];
        const cls_name = switch (cls_idx) {
            0 => "stable",
            2 => "volatile",
            else => "moderate",
        };
        try w.writeAll(cls_name);
        try w.writeAll("\",\"cost\":");
        try w.print("{d}", .{@as(i64, @intFromFloat(@floor(op_cost)))});
        try w.writeAll("}");
        prev_est = .{ .rows = biased_rows, .confidence = base.confidence };
    }
    try w.writeAll("],\"totals\":{");
    try w.writeAll("\"est_rows\":");
    try w.print("{d}", .{@as(i64, @intFromFloat(@floor(total_est_rows)))});
    try w.writeAll(",\"cost\":");
    try w.print("{d}", .{@as(i64, @intFromFloat(@floor(total_cost)))});
    try w.writeAll("},\"bias_snapshot\":[");
    var k: usize = 0;
    while (k < @typeInfo(seed.LogicalOpKind).Enum.fields.len) : (k += 1) {
        if (k != 0) try w.writeByte(',');
        const kind_tag: seed.LogicalOpKind = @enumFromInt(k);
        const bb = bias_reg.getBias(kind_tag);
        const bb_int: i64 = @intFromFloat(@floor(bb * 100.0 + 0.5));
        try w.print("{d}", .{bb_int});
    }
    try w.writeAll("],\"bias_clamp_warnings\":[");
    var first_warn = true;
    var widx: usize = 0;
    while (widx < @typeInfo(seed.LogicalOpKind).Enum.fields.len) : (widx += 1) {
        const kind_tag: seed.LogicalOpKind = @enumFromInt(widx);
        if (bias_reg.low_clamp_warning[widx]) {
            if (!first_warn) try w.writeByte(',') else first_warn = false;
            try w.writeAll("\"LOW_CLAMP(");
            try w.writeAll(@tagName(kind_tag));
            try w.writeAll(")\"");
        }
        if (bias_reg.high_clamp_warning[widx]) {
            if (!first_warn) try w.writeByte(',') else first_warn = false;
            try w.writeAll("\"HIGH_CLAMP(");
            try w.writeAll(@tagName(kind_tag));
            try w.writeAll(")\"");
        }
    }
    try w.writeAll("]}");
    try w.writeAll("],\"alpha_snapshot\":[");
    k = 0;
    while (k < @typeInfo(seed.LogicalOpKind).Enum.fields.len) : (k += 1) {
        if (k != 0) try w.writeByte(',');
        const kind_tag: seed.LogicalOpKind = @enumFromInt(k);
        const aa = bias_reg.getAlpha(kind_tag);
        try w.print("{d:.2}", .{aa});
    }
    try w.writeAll("],\"cv_snapshot\":[");
    k = 0;
    while (k < @typeInfo(seed.LogicalOpKind).Enum.fields.len) : (k += 1) {
        if (k != 0) try w.writeByte(',');
        const cvv = bias_reg.last_cv[k];
        try w.print("{d:.3}", .{cvv});
    }
    try w.writeAll("],\"cv_class_snapshot\":[");
    k = 0;
    while (k < @typeInfo(seed.LogicalOpKind).Enum.fields.len) : (k += 1) {
        if (k != 0) try w.writeByte(',');
        const cls_idx2 = bias_reg.last_cv_class[k];
        const cls_name2 = switch (cls_idx2) {
            0 => "stable",
            2 => "volatile",
            else => "moderate",
        };
        try w.writeAll("\"");
        try w.writeAll(cls_name2);
        try w.writeAll("\"");
    }
    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}
