const std = @import("std");
const planned_read_runtime = @import("../execution/planned_read_runtime.zig");
const query_traits = @import("../query/query_traits.zig");
const schema = @import("schema");

pub const ProfileOptions = struct {
    compact: bool = false,
    include_mem_curve: bool = false,
    disable_estimates: bool = false,
    committed_txns: u64 = 0,
    graph_store_nodes: u64 = 0,
    graph_store_edges: u64 = 0,
    graph_store_dirty: bool = false,
    flagger_findings: []const []const u8 = &.{},
    union_part_count: usize = 0,
    // CANARY: REQ=REQ-AUTO-INDEX-PROFILE-001; FEATURE="AutoIdIndex"; ASPECT=ProfileIndexName; STATUS=IMPL; OWNER=engine; UPDATED=2026-02-07
    // SONNY-1335: the catalog index the executor seeked, set only by a caller
    // that knows it did. Null means no index operator.
    index_name: ?[]const u8 = null,
    /// The nodes the seek on `index_name` returned.
    index_rows: u64 = 0,
    /// SONNY-6596: the wall-clock time of the legacy execution, measured by
    /// the transport (`monotonicNs`) around it.
    execute_time_ns: u64 = 0,
};

/// SONNY-6596: the monotonic clock the transports read around a legacy
/// execution for its version-1 PROFILE.
pub fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

const OpSpec = struct {
    name: []const u8,
    phase: []const u8,
    rows: u64,
    time_ns: u64,
    index_name: ?[]const u8 = null,
};

// CANARY: REQ=REQ-SONNY-6596-PROFILE-V1-MEASURED; FEATURE="PROFILE"; ASPECT=NoSyntheticOperators; STATUS=TESTED; TEST=tests/test_sonny6596_profile_v1_measured.zig; OWNER=engine; UPDATED=2026-11-15
/// The version-1 payload: a statement the legacy executor ran (the planned
/// read runtime's trace is version 2). SONNY-6596: it reports what was
/// measured and nothing else. The executor has no operator hooks, so the
/// statement is one `LegacyExecute` operator (the version-2 trace's name for
/// the same thing) with `opts.execute_time_ns`, the wall-clock time the
/// transport measured around it, and the rows it returned. What was not
/// measured is 0 or absent: CPU time, bytes, memory, a UNION's input rows,
/// planner estimates (there is no planner here). It was a fixed model: a
/// CREATE listed NodeScan, Expand and Project, a UNION four phase operators,
/// each with `time_ns = 10 * (i + 1)`, 64 bytes allocated and estimates.
pub fn buildProfilePayload(
    allocator: std.mem.Allocator,
    traits: query_traits.QueryTraits,
    row_count: usize,
    opts: ProfileOptions,
) !schema.ProfilePayload {
    const rows: u64 = @intCast(row_count);
    var specs_buf: [2]OpSpec = undefined;
    var op_count: usize = 0;
    // CANARY: REQ=REQ-SONNY-1335-PROFILE-ACCESS-PATH; FEATURE="PROFILE"; ASPECT=NoFabricatedIndexScan; STATUS=TESTED; TEST=tests/test_sonny1335_profile_access_path.zig; OWNER=engine; UPDATED=2026-11-11
    // SONNY-1335: an index operator only for an index the executor used.
    // Its time is part of the statement's (not measured apart).
    if (opts.index_name) |name| {
        specs_buf[op_count] = .{ .name = "NodeIndexScan", .phase = "SCAN", .rows = opts.index_rows, .time_ns = 0, .index_name = name };
        op_count += 1;
    }
    specs_buf[op_count] = .{ .name = "LegacyExecute", .phase = "EXECUTE", .rows = rows, .time_ns = opts.execute_time_ns };
    op_count += 1;
    const specs = specs_buf[0..op_count];

    var op_list = std.ArrayList(schema.ProfileOp).initCapacity(allocator, op_count) catch return error.OutOfMemory;
    errdefer {
        for (op_list.items) |*item| item.deinit(allocator);
        op_list.deinit(allocator);
    }
    var cumulative_time: u64 = 0;
    for (specs, 0..) |spec, op_idx| {
        cumulative_time += spec.time_ns;
        const op_name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(op_name);
        const phase = try allocator.dupe(u8, spec.phase);
        errdefer allocator.free(phase);
        const index_name: []const u8 = if (spec.index_name) |name| try allocator.dupe(u8, name) else "";
        errdefer if (index_name.len > 0) allocator.free(index_name);
        try op_list.append(allocator, .{
            .op = op_name,
            .phase = phase,
            .id = 0,
            .op_index = @intCast(op_idx),
            .input_rows = 0,
            .rows = spec.rows,
            .time_ns = spec.time_ns,
            .cpu_time_ns = 0,
            .bytes_out = 0,
            .bytes_alloc = 0,
            .estimate_bytes = 0,
            .estimate_vs_actual = 0,
            .percent_peak = 0,
            .percent_net = 0,
            .cumulative_time_ns = cumulative_time,
            .freed_bytes = 0,
            .net_after_op = 0,
            .error_bytes = 0,
            .error_abs_pct = 0,
            .index_name = index_name,
            .selectivity_est = 0,
        });
    }

    var mem_curve = std.ArrayList(schema.ProfileMemCurvePoint).initCapacity(allocator, if (opts.include_mem_curve) op_count else 0) catch return error.OutOfMemory;
    errdefer mem_curve.deinit(allocator);
    if (opts.include_mem_curve) {
        for (0..op_count) |i| mem_curve.appendAssumeCapacity(.{ .op_index = @intCast(i), .net_after_op = 0 });
    }

    // The output rows of a set operation are counted; its parts' are not.
    var setop_opt: ?schema.ProfileSetOp = null;
    if (traits.has_union) {
        const set_type = try allocator.dupe(u8, "UNION");
        errdefer allocator.free(set_type);
        setop_opt = .{
            .type = set_type,
            .mode = try allocator.dupe(u8, unionModeToString(traits.union_mode)),
            .input_rows = 0,
            .output_rows = rows,
            .hash_dedup_size = 0,
            .distinct_fill_pct = 0,
        };
    }
    errdefer if (setop_opt) |*so| so.deinit(allocator);

    var findings = std.ArrayList([]const u8).initCapacity(allocator, opts.flagger_findings.len) catch return error.OutOfMemory;
    errdefer {
        for (findings.items) |flag| allocator.free(flag);
        findings.deinit(allocator);
    }
    for (opts.flagger_findings) |flag| {
        findings.appendAssumeCapacity(try allocator.dupe(u8, flag));
    }

    return schema.ProfilePayload{
        .profile_version = 1,
        .ops = op_list,
        .peak_contributors = .empty,
        .totals = .{ .time_ns = cumulative_time, .peak_bytes = 0 },
        .total_time_ns = cumulative_time,
        // SONNY-6562: the executor never spills.
        .spills = .{
            .sort_spills = 0,
            .distinct_spills = 0,
            .union_spills = 0,
            .spill_reason = "",
            .peak_bytes_at_spill = 0,
            .first_spill_op_index = 0,
        },
        .memory = .{ .net_bytes = 0, .peak_bytes = 0, .total_alloc_bytes = 0 },
        .planner_estimates = null,
        .mem_curve = mem_curve,
        .setop = setop_opt,
        .hashagg_spills = 0,
        .hashagg_spill_reason = "",
        .committed_txns = opts.committed_txns,
        .graph_store_nodes = opts.graph_store_nodes,
        .graph_store_edges = opts.graph_store_edges,
        .graph_store_dirty = opts.graph_store_dirty,
        .flagger_findings = findings,
        .compact = opts.compact,
    };
}

pub fn buildProfilePayloadFromTrace(
    allocator: std.mem.Allocator,
    plan: planned_read_runtime.Plan,
    trace: planned_read_runtime.RuntimeTrace,
    opts: ProfileOptions,
) !schema.ProfilePayload {
    _ = plan;

    var op_list = std.ArrayList(schema.ProfileOp).initCapacity(allocator, trace.ops.len) catch return error.OutOfMemory;
    errdefer {
        for (op_list.items) |*item| item.deinit(allocator);
        op_list.deinit(allocator);
    }

    var cumulative_time: u64 = 0;
    for (trace.ops, 0..) |op, idx| {
        cumulative_time += op.time_ns;
        // SONNY-1335: the catalog index the executor seeked (set on an
        // IndexSeek by `planned_read_runtime.recordStartAccess`), else none.
        const index_name: []const u8 = if (op.index_name) |name| try allocator.dupe(u8, name) else "";
        errdefer if (index_name.len > 0) allocator.free(index_name);
        try op_list.append(allocator, .{
            .op = try allocator.dupe(u8, plannedOpName(op.kind)),
            .phase = try allocator.dupe(u8, plannedOpPhase(op.kind)),
            .id = 0,
            .op_index = @intCast(idx),
            .input_rows = op.input_rows,
            .rows = op.rows,
            .time_ns = op.time_ns,
            .cpu_time_ns = op.time_ns,
            .bytes_out = 0,
            .bytes_alloc = 0,
            .estimate_bytes = 0,
            .estimate_vs_actual = 0,
            .percent_peak = 0,
            .percent_net = 0,
            .cumulative_time_ns = cumulative_time,
            .freed_bytes = 0,
            .net_after_op = 0,
            .error_bytes = 0,
            .error_abs_pct = 0,
            .index_name = index_name,
            .selectivity_est = 0,
        });
    }

    var peak_contributors = std.ArrayList(schema.ProfilePeakContributor).empty;
    errdefer peak_contributors.deinit(allocator);

    var mem_curve = std.ArrayList(schema.ProfileMemCurvePoint).empty;
    errdefer mem_curve.deinit(allocator);

    var flagger_findings = std.ArrayList([]const u8).initCapacity(allocator, opts.flagger_findings.len) catch return error.OutOfMemory;
    errdefer {
        for (flagger_findings.items) |flag| allocator.free(flag);
        flagger_findings.deinit(allocator);
    }
    for (opts.flagger_findings) |flag| {
        try flagger_findings.append(allocator, try allocator.dupe(u8, flag));
    }

    return schema.ProfilePayload{
        .profile_version = 2,
        .ops = op_list,
        .peak_contributors = peak_contributors,
        .totals = .{
            .time_ns = trace.totalTimeNs(),
            .peak_bytes = 0,
        },
        .total_time_ns = trace.totalTimeNs(),
        .spills = .{
            .sort_spills = 0,
            .distinct_spills = 0,
            .union_spills = 0,
            .spill_reason = "",
            .peak_bytes_at_spill = 0,
            .first_spill_op_index = 0,
        },
        .memory = .{
            .net_bytes = 0,
            .peak_bytes = 0,
            .total_alloc_bytes = 0,
        },
        .planner_estimates = null,
        .mem_curve = mem_curve,
        .setop = null,
        .hashagg_spills = 0,
        .hashagg_spill_reason = "",
        .committed_txns = opts.committed_txns,
        .graph_store_nodes = opts.graph_store_nodes,
        .graph_store_edges = opts.graph_store_edges,
        .graph_store_dirty = opts.graph_store_dirty,
        .flagger_findings = flagger_findings,
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
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 1024) catch return error.OutOfMemory;
    errdefer aw.deinit();
    const w = &aw.writer;

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

    var buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn plannedOpName(kind: planned_read_runtime.OpKind) []const u8 {
    return switch (kind) {
        .ConstProjection => "ConstProjection",
        .AllNodesScan => "AllNodesScan",
        .LabelScan => "LabelScan",
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
        .IndexSeek => "IndexSeek",
    };
}

fn plannedOpPhase(kind: planned_read_runtime.OpKind) []const u8 {
    return switch (kind) {
        .ConstProjection => "PROJECT",
        .AllNodesScan, .LabelScan, .IndexSeek => "SCAN",
        .ExpandOut, .ExpandIn, .ExpandEither => "EXPAND",
        .OptionalMatch => "MATCH",
        .VarLengthExpand, .ShortestPath, .PathModeExpand => "EXPAND",
        .PathCapture => "PROJECT",
        .CallProcedure, .CallSubquery => "CALL",
        .Create, .Merge, .Set, .Remove, .Delete => "WRITE",
        .Unwind => "UNWIND",
        .RecursiveCTE => "CTE",
        .QueryChain => "CHAIN",
        .LegacyExecute => "EXECUTE",
        .Filter => "FILTER",
        .Aggregate => "AGGREGATE",
        .Project => "PROJECT",
        .Distinct => "DISTINCT",
        .Limit => "PAGE",
        .Sort => "ORDER",
    };
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
