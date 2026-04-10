const std = @import("std");
const planned_read_runtime = @import("../execution/planned_read_runtime.zig");
const cost_seed = @import("../planner/cost_seed.zig");
const query_traits = @import("../query/query_traits.zig");
const schema = @import("schema");

pub fn buildExplainPayload(
    allocator: std.mem.Allocator,
    traits: query_traits.QueryTraits,
    union_part_count: usize,
    calibrated: bool,
) !schema.ExplainPayload {
    const ops = try buildOps(allocator, traits);
    defer allocator.free(ops);

    const cfg = cost_seed.EstimatorConfig{};
    var op_list = std.ArrayList(schema.ExplainOp).initCapacity(allocator, ops.len) catch return error.OutOfMemory;
    errdefer {
        for (op_list.items) |*item| item.deinit(allocator);
        op_list.deinit(allocator);
    }

    var total_cost: f64 = 0;
    var total_est_rows: f64 = 0;
    var prev_est: ?cost_seed.CardinalityEstimate = null;
    for (ops, 0..) |op, idx| {
        const children_slice: []const cost_seed.CardinalityEstimate = if (prev_est) |pe| &[_]cost_seed.CardinalityEstimate{pe} else &[_]cost_seed.CardinalityEstimate{};
        const est_card = cost_seed.estimate(op, children_slice, cfg);
        const op_cost = cost_seed.cost(op, est_card, cfg).total();
        if (idx == 0) total_est_rows = est_card.rows;
        total_cost += op_cost;
        const kind_name = @tagName(op.kind);
        const op_entry = schema.ExplainOp{
            .idx = @intCast(idx),
            .kind = try allocator.dupe(u8, kind_name),
            .est_rows = @intFromFloat(@floor(est_card.rows)),
            .cost = @intFromFloat(@floor(op_cost)),
        };
        try op_list.append(allocator, op_entry);
        prev_est = est_card;
    }

    const properties = schema.ExplainProperties{
        .ordered = traits.ordered,
        .limit = if (traits.limit) |lim| @intCast(lim) else 0,
        .offset = if (traits.offset) |off| @intCast(off) else 0,
        .distinct = traits.distinct,
        .union_mode = if (traits.has_union) try allocator.dupe(u8, unionModeToString(traits.union_mode)) else try allocator.dupe(u8, ""),
        .union_part_count = if (traits.has_union) @intCast(union_part_count) else 0,
    };

    var calibration_opt: ?schema.ExplainCalibration = null;
    if (calibrated) {
        const entries = std.ArrayList(schema.ExplainCalibrationEntry).empty;
        calibration_opt = schema.ExplainCalibration{
            .mape = 0,
            .entries = entries,
        };
    }

    const schema_name = if (calibrated) "cost_explain.v2" else "cost_explain.v1";
    var payload = schema.ExplainPayload{
        .schema = try allocator.dupe(u8, schema_name),
        .ops = op_list,
        .totals = .{ .est_rows = @intFromFloat(@floor(total_est_rows)), .cost = @intFromFloat(@floor(total_cost)) },
        .properties = properties,
        .calibration = calibration_opt,
        .profile_version = 2,
    };
    errdefer payload.deinit(allocator);

    return payload;
}

pub fn buildExplainJson(
    allocator: std.mem.Allocator,
    traits: query_traits.QueryTraits,
    union_part_count: usize,
    calibrated: bool,
) ![]u8 {
    var payload = try buildExplainPayload(allocator, traits, union_part_count, calibrated);
    defer payload.deinit(allocator);
    return try explainPayloadToJson(allocator, payload);
}

pub fn buildExplainPayloadFromPlan(
    allocator: std.mem.Allocator,
    plan: planned_read_runtime.Plan,
) !schema.ExplainPayload {
    var op_list = std.ArrayList(schema.ExplainOp).initCapacity(allocator, plan.ops.len) catch return error.OutOfMemory;
    errdefer {
        for (op_list.items) |*item| item.deinit(allocator);
        op_list.deinit(allocator);
    }

    for (plan.ops, 0..) |op, idx| {
        try op_list.append(allocator, .{
            .idx = @intCast(idx),
            .kind = try allocator.dupe(u8, plannedOpName(op.kind)),
            .est_rows = @intCast(@min(op.est_rows, @as(u64, @intCast(std.math.maxInt(i64))))),
            .cost = 0,
        });
    }

    return schema.ExplainPayload{
        .schema = try allocator.dupe(u8, "planned_explain.v1"),
        .ops = op_list,
        .totals = .{
            .est_rows = if (plan.ops.len > 0) @intCast(@min(plan.ops[0].est_rows, @as(u64, @intCast(std.math.maxInt(i64))))) else 0,
            .cost = 0,
        },
        .properties = .{
            .ordered = planHasOp(plan.ops, .Sort),
            .limit = 0,
            .offset = 0,
            .distinct = planHasOp(plan.ops, .Distinct),
            .union_mode = try allocator.dupe(u8, ""),
            .union_part_count = 0,
        },
        .calibration = null,
        .profile_version = 2,
    };
}

pub fn explainPayloadToJson(allocator: std.mem.Allocator, payload: schema.ExplainPayload) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 1024) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.writeAll("{\"schema\":\"");
    try w.writeAll(payload.schema);
    try w.writeAll("\",\"ops\":[");
    for (payload.ops.items, 0..) |op, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"idx\":");
        try w.print("{d}", .{op.idx});
        try w.writeAll(",\"kind\":\"");
        try w.writeAll(op.kind);
        try w.writeAll("\",\"est_rows\":");
        try w.print("{d}", .{op.est_rows});
        try w.writeAll(",\"cost\":");
        try w.print("{d}", .{op.cost});
        try w.writeAll("}");
    }
    try w.writeAll("],\"totals\":{");
    const totals = payload.totals orelse schema.ExplainTotals{ .est_rows = 0, .cost = 0 };
    try w.writeAll("\"est_rows\":");
    try w.print("{d}", .{totals.est_rows});
    try w.writeAll(",\"cost\":");
    try w.print("{d}", .{totals.cost});
    try w.writeAll("},\"profile_version\":");
    try w.print("{d}", .{payload.profile_version});

    if (payload.calibration) |cal| {
        try w.writeAll(",\"calibration\":{\"mape\":");
        try w.print("{d}", .{cal.mape});
        try w.writeAll(",\"entries\":[");
        for (cal.entries.items, 0..) |entry, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"idx\":");
            try w.print("{d}", .{entry.idx});
            try w.writeAll(",\"est_rows\":");
            try w.print("{d}", .{entry.est_rows});
            try w.writeAll(",\"actual_rows\":");
            try w.print("{d}", .{entry.actual_rows});
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }

    const props = payload.properties orelse schema.ExplainProperties{
        .ordered = false,
        .limit = 0,
        .offset = 0,
        .distinct = false,
        .union_mode = "",
        .union_part_count = 0,
    };
    try w.writeAll(",\"properties\":{");
    try w.writeAll("\"ordered\":");
    try w.writeAll(if (props.ordered) "true" else "false");
    if (props.limit > 0) {
        try w.writeAll(",\"limit\":");
        try w.print("{d}", .{props.limit});
    }
    if (props.offset > 0) {
        try w.writeAll(",\"offset\":");
        try w.print("{d}", .{props.offset});
    }
    if (props.distinct) {
        try w.writeAll(",\"distinct\":true");
    }
    if (props.union_mode.len > 0) {
        try w.writeAll(",\"union_mode\":\"");
        try w.writeAll(props.union_mode);
        try w.writeAll("\"");
        if (props.union_part_count > 0) {
            try w.writeAll(",\"union_part_count\":");
            try w.print("{d}", .{props.union_part_count});
        }
    }
    try w.writeAll("}}");

    return buf.toOwnedSlice(allocator);
}

fn buildOps(allocator: std.mem.Allocator, traits: query_traits.QueryTraits) ![]cost_seed.OpDescriptor {
    var list = std.ArrayList(cost_seed.OpDescriptor).initCapacity(allocator, 8) catch return error.OutOfMemory;
    defer list.deinit(allocator);

    try list.append(allocator, .{ .kind = if (traits.has_index_seek) .IndexSeek else .Scan });
    try list.append(allocator, .{ .kind = .Expand });
    if (traits.has_where_eq or traits.has_filter_eq) {
        try list.append(allocator, .{ .kind = .Filter });
    }
    if (traits.has_group_by) {
        try list.append(allocator, .{ .kind = .Aggregate });
    }
    if (traits.distinct) {
        try list.append(allocator, .{ .kind = .Aggregate });
    }
    try list.append(allocator, .{ .kind = .Project });
    if (traits.ordered) {
        try list.append(allocator, .{ .kind = .Sort });
    }
    if (traits.limit != null or traits.offset != null) {
        try list.append(allocator, .{ .kind = .Limit });
    }
    if (traits.has_union) {
        try list.append(allocator, .{ .kind = .SetOp });
    }

    return list.toOwnedSlice(allocator);
}

fn unionModeToString(mode: query_traits.UnionMode) []const u8 {
    return switch (mode) {
        .all => "ALL",
        .distinct => "DISTINCT",
        .intersect => "INTERSECT",
        .except => "EXCEPT",
        .none => "NONE",
    };
}

fn plannedOpName(kind: planned_read_runtime.OpKind) []const u8 {
    return switch (kind) {
        .ConstProjection => "ConstProjection",
        .AllNodesScan => "AllNodesScan",
        .LabelScan => "LabelScan",
        .IndexSeek => "IndexSeek",
        .ExpandOut => "ExpandOut",
        .ExpandIn => "ExpandIn",
        .ExpandEither => "ExpandEither",
        .OptionalMatch => "OptionalMatch",
        .VarLengthExpand => "VarLengthExpand",
        .ShortestPath => "ShortestPath",
        .PathModeExpand => "PathModeExpand",
        .PathCapture => "PathCapture",
        .CallProcedure => "CallProcedure",
        .CallSubquery => "CallSubquery",
        .Create => "Create",
        .Merge => "Merge",
        .Unwind => "Unwind",
        .Set => "Set",
        .Remove => "Remove",
        .Delete => "Delete",
        .RecursiveCTE => "RecursiveCTE",
        .QueryChain => "QueryChain",
        .LegacyExecute => "LegacyExecute",
        .Filter => "Filter",
        .Aggregate => "Aggregate",
        .Project => "Project",
        .Distinct => "Distinct",
        .Limit => "Limit",
        .Sort => "Sort",
    };
}

fn planHasOp(ops: []const planned_read_runtime.PlanOp, kind: planned_read_runtime.OpKind) bool {
    for (ops) |op| {
        if (op.kind == kind) return true;
    }
    return false;
}
