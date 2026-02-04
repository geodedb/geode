const std = @import("std");
const spice_wrapper = @import("parallel/spice");
const query_traits = @import("../query/query_traits.zig");
const schema = @import("schema");

pub const ProfileOptions = struct {
    compact: bool = false,
    include_mem_curve: bool = false,
    disable_estimates: bool = false,
    spill_sort: usize = 0,
    spill_distinct: usize = 0,
    spill_union: usize = 0,
    spill_hashagg: usize = 0,
    spill_threshold: usize = 0,
    committed_txns: u64 = 0,
    graph_store_nodes: u64 = 0,
    graph_store_edges: u64 = 0,
    graph_store_dirty: bool = false,
    flagger_findings: []const []const u8 = &.{},
    union_part_count: usize = 0,
};

const OpSpec = struct {
    name: []const u8,
    phase: []const u8,
    has_index_meta: bool = false,
};

pub fn buildProfilePayload(
    allocator: std.mem.Allocator,
    traits: query_traits.QueryTraits,
    row_count: usize,
    opts: ProfileOptions,
) !schema.ProfilePayload {
    var ops = std.ArrayList(OpSpec).initCapacity(allocator, 10) catch return error.OutOfMemory;
    defer ops.deinit(allocator);

    if (traits.has_where_eq or traits.has_filter_eq) {
        try ops.append(allocator, .{ .name = "NodeIndexScan", .phase = "SCAN", .has_index_meta = true });
    }
    try ops.append(allocator, .{ .name = "NodeScan", .phase = "SCAN" });
    try ops.append(allocator, .{ .name = "Expand", .phase = "EXPAND" });
    if (traits.has_group_by) {
        try ops.append(allocator, .{ .name = "AggregateBuild", .phase = "AGGREGATE" });
        try ops.append(allocator, .{ .name = "AggregateEmit", .phase = "AGGREGATE" });
    }
    if (traits.distinct) {
        try ops.append(allocator, .{ .name = "Distinct", .phase = "DISTINCT" });
    }
    if (traits.ordered) {
        try ops.append(allocator, .{ .name = "Sort", .phase = "ORDER" });
    }
    try ops.append(allocator, .{ .name = "Project", .phase = "PROJECT" });
    if (traits.limit != null or traits.offset != null) {
        try ops.append(allocator, .{ .name = "Limit", .phase = "PAGE" });
    }
    if (traits.has_union) {
        try ops.append(allocator, .{ .name = "UnionLeft", .phase = "OTHER" });
        try ops.append(allocator, .{ .name = "UnionTails", .phase = "OTHER" });
        if (traits.union_mode == .distinct) {
            try ops.append(allocator, .{ .name = "UnionDedup", .phase = "OTHER" });
        }
        try ops.append(allocator, .{ .name = "SetOpUnion", .phase = "OTHER" });
    }

    const op_count = ops.items.len;
    var bytes_alloc = try allocator.alloc(u64, op_count);
    defer allocator.free(bytes_alloc);
    var time_ns = try allocator.alloc(u64, op_count);
    defer allocator.free(time_ns);
    var cpu_time_ns = try allocator.alloc(u64, op_count);
    defer allocator.free(cpu_time_ns);
    var bytes_out = try allocator.alloc(u64, op_count);
    defer allocator.free(bytes_out);
    var estimate_bytes = try allocator.alloc(u64, op_count);
    defer allocator.free(estimate_bytes);
    var estimate_vs_actual = try allocator.alloc(u64, op_count);
    defer allocator.free(estimate_vs_actual);

    const MetricsContext = struct {
        bytes_alloc: []u64,
        time_ns: []u64,
        cpu_time_ns: []u64,
        bytes_out: []u64,
        estimate_bytes: []u64,
        estimate_vs_actual: []u64,
        row_count: usize,
        disable_estimates: bool,
    };

    const ctx = MetricsContext{
        .bytes_alloc = bytes_alloc,
        .time_ns = time_ns,
        .cpu_time_ns = cpu_time_ns,
        .bytes_out = bytes_out,
        .estimate_bytes = estimate_bytes,
        .estimate_vs_actual = estimate_vs_actual,
        .row_count = row_count,
        .disable_estimates = opts.disable_estimates,
    };

    if (spice_wrapper.shouldUseParallelism(op_count, spice_wrapper.Thresholds.forEach)) {
        var pool = spice_wrapper.SpicePool.init(allocator, null);
        pool.start();
        defer pool.deinit();
        spice_wrapper.parallelForEach(&pool, 0, op_count, ctx, struct {
            fn work(_: *spice_wrapper.Task, idx: usize, c: MetricsContext) void {
                const base_alloc: u64 = if (idx == 0 and c.row_count > 0) 0 else 64;
                c.bytes_alloc[idx] = base_alloc;
                c.time_ns[idx] = 10 * @as(u64, @intCast(idx + 1));
                c.cpu_time_ns[idx] = 5 * @as(u64, @intCast(idx + 1));
                c.bytes_out[idx] = @as(u64, @intCast(c.row_count)) * 8;
                if (c.disable_estimates) {
                    c.estimate_bytes[idx] = 0;
                    c.estimate_vs_actual[idx] = 0;
                } else {
                    const est = c.bytes_out[idx] + base_alloc;
                    c.estimate_bytes[idx] = est;
                    c.estimate_vs_actual[idx] = if (est >= c.bytes_out[idx]) est - c.bytes_out[idx] else c.bytes_out[idx] - est;
                }
            }
        }.work, spice_wrapper.Thresholds.forEach);
    } else {
        for (ops.items, 0..) |_, idx| {
            const base_alloc: u64 = if (idx == 0 and row_count > 0) 0 else 64;
            bytes_alloc[idx] = base_alloc;
            time_ns[idx] = 10 * @as(u64, @intCast(idx + 1));
            cpu_time_ns[idx] = 5 * @as(u64, @intCast(idx + 1));
            bytes_out[idx] = @as(u64, @intCast(row_count)) * 8;
            if (opts.disable_estimates) {
                estimate_bytes[idx] = 0;
                estimate_vs_actual[idx] = 0;
            } else {
                const est = bytes_out[idx] + base_alloc;
                estimate_bytes[idx] = est;
                estimate_vs_actual[idx] = if (est >= bytes_out[idx]) est - bytes_out[idx] else bytes_out[idx] - est;
            }
        }
    }

    var cumulative_time: u64 = 0;
    var net_after_op = try allocator.alloc(u64, op_count);
    defer allocator.free(net_after_op);
    for (ops.items, 0..) |_, idx| {
        cumulative_time += time_ns[idx];
        const prev = if (idx == 0) 0 else net_after_op[idx - 1];
        net_after_op[idx] = prev + bytes_alloc[idx];
    }

    var total_alloc_bytes: u64 = 0;
    var peak_bytes: u64 = 0;
    for (bytes_alloc) |b| total_alloc_bytes += b;
    peak_bytes = total_alloc_bytes;
    const total_time_ns = cumulative_time;

    var op_list = std.ArrayList(schema.ProfileOp).initCapacity(allocator, op_count) catch return error.OutOfMemory;
    errdefer {
        for (op_list.items) |*item| item.deinit(allocator);
        op_list.deinit(allocator);
    }

    for (ops.items, 0..) |spec, op_idx| {
        const input_rows = @as(u64, @intCast(row_count));
        const rows = @as(u64, @intCast(row_count));
        const percent_peak = if (peak_bytes > 0 and bytes_alloc[op_idx] > 0)
            @as(u64, @intCast(@min(@as(u64, 100), bytes_alloc[op_idx] * 100 / peak_bytes)))
        else
            0;
        const percent_net = if (total_alloc_bytes > 0)
            @as(u64, @intCast(@min(@as(u64, 100), net_after_op[op_idx] * 100 / total_alloc_bytes)))
        else
            0;

        const op_entry = schema.ProfileOp{
            .op = try allocator.dupe(u8, spec.name),
            .phase = try allocator.dupe(u8, spec.phase),
            .id = 0,
            .op_index = @intCast(op_idx),
            .input_rows = input_rows,
            .rows = rows,
            .time_ns = time_ns[op_idx],
            .cpu_time_ns = cpu_time_ns[op_idx],
            .bytes_out = bytes_out[op_idx],
            .bytes_alloc = bytes_alloc[op_idx],
            .estimate_bytes = estimate_bytes[op_idx],
            .estimate_vs_actual = estimate_vs_actual[op_idx],
            .percent_peak = percent_peak,
            .percent_net = percent_net,
            .cumulative_time_ns = cumulative_timeFor(op_idx, time_ns),
            .freed_bytes = 0,
            .net_after_op = net_after_op[op_idx],
            .error_bytes = 0,
            .error_abs_pct = 0,
            .index_name = if (spec.has_index_meta) try allocator.dupe(u8, "heuristic_index") else "",
            .selectivity_est = if (spec.has_index_meta) 0.50 else 0,
        };
        try op_list.append(allocator, op_entry);
    }

    var peak_contributors = try buildPeakContributors(allocator, ops.items, bytes_alloc);
    errdefer {
        for (peak_contributors.items) |*item| item.deinit(allocator);
        peak_contributors.deinit(allocator);
    }

    const totals = schema.ProfileTotals{
        .time_ns = total_time_ns,
        .peak_bytes = peak_bytes,
    };

    var spill_reason: ?[]const u8 = null;
    if (opts.spill_threshold > 0 and peak_bytes > opts.spill_threshold) {
        spill_reason = "threshold";
    } else if (opts.spill_sort > 0 or opts.spill_distinct > 0 or opts.spill_union > 0 or opts.spill_hashagg > 0) {
        spill_reason = "forced";
    }

    var spills = schema.ProfileSpills{
        .sort_spills = opts.spill_sort,
        .distinct_spills = opts.spill_distinct,
        .union_spills = opts.spill_union,
        .spill_reason = "",
        .peak_bytes_at_spill = 0,
        .first_spill_op_index = 0,
    };
    if (spill_reason) |reason| {
        spills.spill_reason = try allocator.dupe(u8, reason);
        spills.peak_bytes_at_spill = peak_bytes;
        if (firstSpillIndex(ops.items, opts)) |first_idx| {
            spills.first_spill_op_index = @intCast(first_idx);
        }
    }
    errdefer spills.deinit(allocator);

    const memory = schema.ProfileMemory{
        .net_bytes = total_alloc_bytes,
        .peak_bytes = peak_bytes,
        .total_alloc_bytes = total_alloc_bytes,
    };

    var planner_estimates_opt: ?schema.ProfilePlannerEstimates = null;
    if (!opts.disable_estimates) {
        const sum_est = sumU64(estimate_bytes);
        const sum_actual = sumU64(bytes_out);
        planner_estimates_opt = schema.ProfilePlannerEstimates{
            .sum_estimate_bytes = sum_est,
            .sum_actual_bytes = sum_actual,
            .count_estimated_ops = @intCast(op_count),
            .min_error_abs_pct = 0,
            .max_error_abs_pct = 0,
            .mean_error_abs_pct = 0,
            .median_error_abs_pct = 0,
            .stddev_error_abs_pct = 0,
            .adjusted_estimate_factor = 1,
        };
    }

    var mem_curve = std.ArrayList(schema.ProfileMemCurvePoint).initCapacity(allocator, if (opts.include_mem_curve) op_count else 0) catch return error.OutOfMemory;
    errdefer mem_curve.deinit(allocator);
    if (opts.include_mem_curve) {
        var i: usize = 0;
        while (i < op_count) : (i += 1) {
            const point = schema.ProfileMemCurvePoint{
                .op_index = @intCast(i),
                .net_after_op = net_after_op[i],
            };
            try mem_curve.append(allocator, point);
        }
    }

    var setop_opt: ?schema.ProfileSetOp = null;
    if (traits.has_union) {
        const mode_str = unionModeToString(traits.union_mode);
        const input_rows = if (opts.union_part_count > 0)
            @as(u64, @intCast(opts.union_part_count)) * @as(u64, @intCast(row_count))
        else
            @as(u64, @intCast(row_count));
        const output_rows = @as(u64, @intCast(row_count));

        var setop = schema.ProfileSetOp{
            .type = try allocator.dupe(u8, "UNION"),
            .mode = try allocator.dupe(u8, mode_str),
            .input_rows = input_rows,
            .output_rows = output_rows,
            .hash_dedup_size = 0,
            .distinct_fill_pct = 0,
        };
        if (traits.union_mode == .distinct) {
            setop.hash_dedup_size = output_rows;
            if (input_rows > 0) {
                setop.distinct_fill_pct = @min(@as(u64, 100), (output_rows * 100) / input_rows);
            }
        }
        setop_opt = setop;
    }
    if (setop_opt != null) errdefer setop_opt.?.deinit(allocator);

    var hashagg_spills: u64 = 0;
    var hashagg_reason: []const u8 = "";
    if (traits.has_group_by) {
        if (spill_reason) |reason| {
            hashagg_spills = 1;
            hashagg_reason = try allocator.dupe(u8, reason);
        } else {
            hashagg_spills = 0;
        }
    }
    if (hashagg_reason.len > 0) errdefer allocator.free(hashagg_reason);

    var findings = std.ArrayList([]const u8).initCapacity(allocator, opts.flagger_findings.len) catch return error.OutOfMemory;
    errdefer {
        for (findings.items) |flag| allocator.free(flag);
        findings.deinit(allocator);
    }
    for (opts.flagger_findings) |flag| {
        try findings.append(allocator, try allocator.dupe(u8, flag));
    }

    return schema.ProfilePayload{
        .profile_version = 1,
        .ops = op_list,
        .peak_contributors = peak_contributors,
        .totals = totals,
        .total_time_ns = total_time_ns,
        .spills = spills,
        .memory = memory,
        .planner_estimates = planner_estimates_opt,
        .mem_curve = mem_curve,
        .setop = setop_opt,
        .hashagg_spills = hashagg_spills,
        .hashagg_spill_reason = hashagg_reason,
        .committed_txns = opts.committed_txns,
        .graph_store_nodes = opts.graph_store_nodes,
        .graph_store_edges = opts.graph_store_edges,
        .graph_store_dirty = opts.graph_store_dirty,
        .flagger_findings = findings,
        .compact = opts.compact,
    };
}

pub fn buildProfileJson(
    allocator: std.mem.Allocator,
    traits: query_traits.QueryTraits,
    row_count: usize,
    opts: ProfileOptions,
) ![]u8 {
    var payload = try buildProfilePayload(allocator, traits, row_count, opts);
    defer payload.deinit(allocator);
    return try profilePayloadToJson(allocator, payload);
}

pub fn profilePayloadToJson(allocator: std.mem.Allocator, payload: schema.ProfilePayload) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 1024) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    const compact = payload.compact;
    try w.writeAll("{\"profile_version\":");
    try w.print("{d}", .{payload.profile_version});
    try w.writeAll(",\"ops\":[");
    for (payload.ops.items, 0..) |op, op_idx| {
        if (op_idx != 0) try w.writeByte(',');
        try w.writeAll("{\"op\":\"");
        try w.writeAll(op.op);
        try w.writeAll("\",\"phase\":\"");
        try w.writeAll(op.phase);
        try w.writeAll("\",\"id\":0,\"op_index\":");
        try w.print("{d}", .{op.op_index});
        try w.writeAll(",\"input_rows\":");
        try w.print("{d}", .{op.input_rows});
        try w.writeAll(",\"rows\":");
        try w.print("{d}", .{op.rows});
        try w.writeAll(",\"time_ns\":");
        try w.print("{d}", .{op.time_ns});
        try w.writeAll(",\"cpu_time_ns\":");
        try w.print("{d}", .{op.cpu_time_ns});
        try w.writeAll(",\"bytes_out\":");
        try w.print("{d}", .{op.bytes_out});
        try w.writeAll(",\"bytes_alloc\":");
        try w.print("{d}", .{op.bytes_alloc});

        if (!compact or op.estimate_bytes != 0) {
            try w.writeAll(",\"estimate_bytes\":");
            try w.print("{d}", .{op.estimate_bytes});
        }
        if (!compact or op.estimate_vs_actual != 0) {
            try w.writeAll(",\"estimate_vs_actual\":");
            try w.print("{d}", .{op.estimate_vs_actual});
        }
        if (!compact or op.percent_peak != 0) {
            try w.writeAll(",\"percent_peak\":");
            try w.print("{d}", .{op.percent_peak});
        }
        if (!compact or op.percent_net != 0) {
            try w.writeAll(",\"percent_net\":");
            try w.print("{d}", .{op.percent_net});
        }
        try w.writeAll(",\"cumulative_time_ns\":");
        try w.print("{d}", .{op.cumulative_time_ns});
        try w.writeAll(",\"freed_bytes\":");
        try w.print("{d}", .{op.freed_bytes});
        try w.writeAll(",\"net_after_op\":");
        try w.print("{d}", .{op.net_after_op});
        try w.writeAll(",\"error_bytes\":");
        try w.print("{d}", .{op.error_bytes});
        try w.writeAll(",\"error_abs_pct\":");
        try w.print("{d}", .{op.error_abs_pct});
        if (op.index_name.len > 0) {
            try w.writeAll(",\"index_name\":\"");
            try w.writeAll(op.index_name);
            try w.writeAll("\",\"selectivity_est\":");
            try w.print("{d:.2}", .{op.selectivity_est});
        }
        try w.writeByte('}');
    }
    try w.writeAll("],\"peak_contributors\":[");
    for (payload.peak_contributors.items, 0..) |pc, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"op\":\"");
        try w.writeAll(pc.op);
        try w.writeAll("\",\"bytes_alloc\":");
        try w.print("{d}", .{pc.bytes_alloc});
        try w.writeByte('}');
    }

    const totals = payload.totals orelse schema.ProfileTotals{ .time_ns = 0, .peak_bytes = 0 };
    try w.writeAll("],\"totals\":{\"time_ns\":");
    try w.print("{d}", .{totals.time_ns});
    try w.writeAll(",\"peak_bytes\":");
    try w.print("{d}", .{totals.peak_bytes});
    try w.writeAll("},\"total_time_ns\":");
    try w.print("{d}", .{payload.total_time_ns});

    if (payload.spills) |spills| {
        try w.writeAll(",\"spills\":{\"sort_spills\":");
        try w.print("{d}", .{spills.sort_spills});
        try w.writeAll(",\"distinct_spills\":");
        try w.print("{d}", .{spills.distinct_spills});
        try w.writeAll(",\"union_spills\":");
        try w.print("{d}", .{spills.union_spills});
        if (spills.spill_reason.len > 0) {
            try w.writeAll(",\"spill_reason\":\"");
            try w.writeAll(spills.spill_reason);
            try w.writeAll("\"");
            try w.writeAll(",\"peak_bytes_at_spill\":");
            try w.print("{d}", .{spills.peak_bytes_at_spill});
            if (spills.first_spill_op_index != 0) {
                try w.writeAll(",\"first_spill_op_index\":");
                try w.print("{d}", .{spills.first_spill_op_index});
            }
        }
        try w.writeAll("}");
    }

    if (payload.memory) |memory| {
        try w.writeAll(",\"memory\":{\"net_bytes\":");
        try w.print("{d}", .{memory.net_bytes});
        try w.writeAll(",\"peak_bytes\":");
        try w.print("{d}", .{memory.peak_bytes});
        try w.writeAll(",\"total_alloc_bytes\":");
        try w.print("{d}", .{memory.total_alloc_bytes});
        try w.writeAll("}");
    }

    if (payload.planner_estimates) |est| {
        try w.writeAll(",\"planner_estimates\":{");
        try w.writeAll("\"sum_estimate_bytes\":");
        try w.print("{d}", .{est.sum_estimate_bytes});
        try w.writeAll(",\"sum_actual_bytes\":");
        try w.print("{d}", .{est.sum_actual_bytes});
        try w.writeAll(",\"count_estimated_ops\":");
        try w.print("{d}", .{est.count_estimated_ops});
        try w.writeAll(",\"min_error_abs_pct\":");
        try w.print("{d}", .{@as(u64, @intFromFloat(est.min_error_abs_pct))});
        try w.writeAll(",\"max_error_abs_pct\":");
        try w.print("{d}", .{@as(u64, @intFromFloat(est.max_error_abs_pct))});
        try w.writeAll(",\"mean_error_abs_pct\":");
        try w.print("{d}", .{@as(u64, @intFromFloat(est.mean_error_abs_pct))});
        try w.writeAll(",\"median_error_abs_pct\":");
        try w.print("{d}", .{@as(u64, @intFromFloat(est.median_error_abs_pct))});
        try w.writeAll(",\"stddev_error_abs_pct\":");
        try w.print("{d}", .{@as(u64, @intFromFloat(est.stddev_error_abs_pct))});
        try w.writeAll(",\"adjusted_estimate_factor\":");
        try w.print("{d}", .{@as(u64, @intFromFloat(est.adjusted_estimate_factor))});
        try w.writeAll("}");
    }

    if (payload.mem_curve.items.len > 0) {
        try w.writeAll(",\"mem_curve\":[");
        for (payload.mem_curve.items, 0..) |point, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"op_index\":");
            try w.print("{d}", .{point.op_index});
            try w.writeAll(",\"net_after_op\":");
            try w.print("{d}", .{point.net_after_op});
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }

    if (payload.setop) |setop| {
        try w.writeAll(",\"setop\":{\"type\":\"");
        try w.writeAll(setop.type);
        try w.writeAll("\",\"mode\":\"");
        try w.writeAll(setop.mode);
        try w.writeAll("\",\"input_rows\":");
        try w.print("{d}", .{setop.input_rows});
        try w.writeAll(",\"output_rows\":");
        try w.print("{d}", .{setop.output_rows});
        if (std.mem.eql(u8, setop.mode, "DISTINCT")) {
            try w.writeAll(",\"hash_dedup_size\":");
            try w.print("{d}", .{setop.hash_dedup_size});
            if (setop.distinct_fill_pct > 0) {
                try w.writeAll(",\"distinct_fill_pct\":");
                try w.print("{d}", .{setop.distinct_fill_pct});
            }
        }
        try w.writeAll("}");
    }

    try w.writeAll(",\"hashagg_spills\":");
    try w.print("{d}", .{payload.hashagg_spills});
    if (payload.hashagg_spill_reason.len > 0) {
        try w.writeAll(",\"hashagg_spill_reason\":\"");
        try w.writeAll(payload.hashagg_spill_reason);
        try w.writeByte('"');
    }

    try w.writeAll(",\"committed_txns\":");
    try w.print("{d}", .{payload.committed_txns});
    try w.writeAll(",\"graph_store_nodes\":");
    try w.print("{d}", .{payload.graph_store_nodes});
    try w.writeAll(",\"graph_store_edges\":");
    try w.print("{d}", .{payload.graph_store_edges});
    try w.writeAll(",\"graph_store_dirty\":");
    try w.writeAll(if (payload.graph_store_dirty) "true" else "false");

    try w.writeAll(",\"flagger_findings\":[");
    for (payload.flagger_findings.items, 0..) |flag, fi| {
        if (fi != 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(flag);
        try w.writeByte('"');
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice(allocator);
}

fn sumU64(values: []const u64) u64 {
    var total: u64 = 0;
    for (values) |v| total += v;
    return total;
}

fn cumulative_timeFor(idx: usize, times: []const u64) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i <= idx and i < times.len) : (i += 1) {
        total += times[i];
    }
    return total;
}

fn buildPeakContributors(
    allocator: std.mem.Allocator,
    ops: []const OpSpec,
    bytes_alloc: []const u64,
) !std.ArrayList(schema.ProfilePeakContributor) {
    const count = @min(@as(usize, 2), ops.len);
    var list = std.ArrayList(schema.ProfilePeakContributor).initCapacity(allocator, count) catch return error.OutOfMemory;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }
    if (count == 0) return list;

    var indices = [_]usize{0, 1};
    if (ops.len < 2) indices[1] = 0;
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        if (bytes_alloc[i] > bytes_alloc[indices[0]]) {
            indices[1] = indices[0];
            indices[0] = i;
        } else if (ops.len > 1 and bytes_alloc[i] > bytes_alloc[indices[1]] and i != indices[0]) {
            indices[1] = i;
        }
    }
    var emitted: usize = 0;
    while (emitted < count) : (emitted += 1) {
        const idx = indices[emitted];
        const entry = schema.ProfilePeakContributor{
            .op = try allocator.dupe(u8, ops[idx].name),
            .bytes_alloc = bytes_alloc[idx],
        };
        try list.append(allocator, entry);
    }
    return list;
}

fn firstSpillIndex(ops: []const OpSpec, opts: ProfileOptions) ?usize {
    var distinct_idx: ?usize = null;
    var sort_idx: ?usize = null;
    for (ops, 0..) |op, i| {
        if (std.mem.eql(u8, op.name, "Distinct")) distinct_idx = i;
        if (std.mem.eql(u8, op.name, "Sort")) sort_idx = i;
    }
    if (opts.spill_distinct > 0 and distinct_idx != null) return distinct_idx;
    if (opts.spill_sort > 0 and sort_idx != null) return sort_idx;
    if (opts.spill_union > 0) {
        for (ops, 0..) |op, i| if (std.mem.eql(u8, op.name, "SetOpUnion")) return i;
    }
    return null;
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
