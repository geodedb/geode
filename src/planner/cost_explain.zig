const std = @import("std");
pub const seed = @import("cost_seed.zig");

// Enhanced implementation: adds primitive row estimate & cost fields per op plus totals summary.
// Estimation model: delegate to seed.estimate() and seed.cost() if selectivity provided; else static fallbacks.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSON; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSON; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDetailed; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSONDetailed; OWNER=planner; UPDATED=2025-09-22

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

pub fn explainChainWithCalibration(allocator: std.mem.Allocator, ops: []const seed.OpDescriptor, actual_rows: ?[]const f64, reg: ?*anyopaque) ![]u8 {
    _ = actual_rows;
    _ = reg; // unused in minimal variant
    // Append empty calibration block manually.
    var base = try buildOpsJson(allocator, "cost_explain.v2", ops);
    // Replace trailing '}' with calibration block.
    if (base.len == 0 or base[base.len - 1] != '}') return base;
    const tail = " ,\"calibration\":{\"mape\":0,\"entries\":[]}}"; // leading space keeps JSON valid
    var extended = try allocator.alloc(u8, (base.len - 1) + tail.len);
    std.mem.copyForwards(u8, extended, base[0 .. base.len - 1]);
    std.mem.copyForwards(u8, extended[base.len - 1 ..], tail);
    allocator.free(base);
    return extended;
}
