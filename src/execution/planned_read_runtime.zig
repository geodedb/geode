const std = @import("std");
const gs = @import("graph_storage");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const execution = @import("../execution.zig");
const result_utils = @import("result_utils.zig");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const value_types = @import("../value_types.zig");

const ExecutionContext = execution.ExecutionContext;
const ExecutionResult = execution.ExecutionResult;
const OwnedGraphEntities = execution.OwnedGraphEntities;
const Value = value_types.Value;
const Env = value_types.Env;

pub const OpKind = enum {
    ConstProjection,
    AllNodesScan,
    LabelScan,
    ExpandOut,
    ExpandIn,
    ExpandEither,
    OptionalMatch,
    VarLengthExpand,
    ShortestPath,
    PathModeExpand,
    PathCapture,
    CallProcedure,
    CallSubquery,
    Create,
    Merge,
    Unwind,
    Set,
    Remove,
    Delete,
    RecursiveCTE,
    QueryChain,
    LegacyExecute,
    Filter,
    Aggregate,
    Project,
    Distinct,
    Limit,
    Sort,
};

pub const PlanOp = struct {
    kind: OpKind,
    est_rows: u64 = 0,
};

const BindingKind = enum {
    node,
    edge,
};

pub const HopBinding = struct {
    rel_index: usize,
    right_index: usize,
};

const ExecutionMode = enum {
    storage_native,
    legacy,
};

pub const Plan = struct {
    graph_name: []const u8,
    binding_names: [][]const u8,
    binding_kinds: []BindingKind,
    ops: []PlanOp,
    execution_mode: ExecutionMode = .legacy,
    root_index: ?usize = null,
    hops: []HopBinding,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.graph_name);
        for (self.binding_names) |name| {
            allocator.free(name);
        }
        allocator.free(self.binding_names);
        allocator.free(self.binding_kinds);
        allocator.free(self.ops);
        allocator.free(self.hops);
    }
};

pub const RuntimeOp = struct {
    kind: OpKind,
    input_rows: u64 = 0,
    rows: u64 = 0,
    time_ns: u64 = 0,
};

pub const RuntimeTrace = struct {
    ops: []RuntimeOp,

    pub fn deinit(self: *RuntimeTrace, allocator: std.mem.Allocator) void {
        allocator.free(self.ops);
    }

    pub fn totalTimeNs(self: RuntimeTrace) u64 {
        var total: u64 = 0;
        for (self.ops) |op| total += op.time_ns;
        return total;
    }
};

pub const ProfiledExecution = struct {
    plan: Plan,
    result: ExecutionResult,
    trace: RuntimeTrace,

    pub fn deinitMetadata(self: *ProfiledExecution, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        self.trace.deinit(allocator);
    }
};

const PathEdge = struct {
    edge_id: u64,
    actual_from_slot: u64,
    actual_to_slot: u64,
    next_slot: u64,
    rel_type: gs.LabelId,
    prop_head: u32,
};

pub fn buildPlanIfSupported(allocator: std.mem.Allocator, q: *const ast.Query, context: ExecutionContext) !?Plan {
    var binding_names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    errdefer {
        for (binding_names.items) |name| allocator.free(name);
        binding_names.deinit(allocator);
    }
    var binding_kinds = try std.ArrayList(BindingKind).initCapacity(allocator, 0);
    defer binding_kinds.deinit(allocator);
    var ops = try std.ArrayList(PlanOp).initCapacity(allocator, 8);
    defer ops.deinit(allocator);
    var hop_bindings = try std.ArrayList(HopBinding).initCapacity(allocator, 0);
    defer hop_bindings.deinit(allocator);

    const graph_name = try allocator.dupe(u8, resolveGraphName(context));
    errdefer allocator.free(graph_name);
    const execution_mode: ExecutionMode = if (isStorageNativeQuery(q)) .storage_native else .legacy;

    var root_index: ?usize = null;
    if (execution_mode == .storage_native) {
        if (q.match.chains.len == 0) {
            try ops.append(allocator, .{ .kind = .ConstProjection, .est_rows = 1 });
        } else {
            const chain = q.match.chains[0];
            const first_node = if (chain.head) |head| head else chain.hops[0].left;
            root_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, first_node.name, "node", 0);
            try ops.append(allocator, .{
                .kind = if (first_node.labels.len > 0) .LabelScan else .AllNodesScan,
                .est_rows = try estimateScanRows(allocator, graph_name, first_node),
            });

            for (chain.hops, 0..) |hop, hop_idx| {
                try hop_bindings.append(allocator, .{
                    .rel_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .edge, hop.rel.name, "edge", hop_idx),
                    .right_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, hop.right.name, "node", hop_idx + 1),
                });
                try ops.append(allocator, .{
                    .kind = switch (hop.rel.dir) {
                        .right => .ExpandOut,
                        .left => .ExpandIn,
                        .undirected => .ExpandEither,
                    },
                });
            }
        }
    } else {
        try appendLegacyPlanOps(allocator, &ops, q);
        if (ops.items.len == 0) {
            try ops.append(allocator, .{ .kind = .LegacyExecute });
        }
    }

    if (execution_mode == .storage_native) {
        if (hasPreProjectionFilter(q)) {
            try ops.append(allocator, .{ .kind = .Filter });
        }
        if (q.with_clause) |with_clause| {
            try ops.append(allocator, .{
                .kind = if (q.group_by != null or hasAggregationItems(with_clause.items)) .Aggregate else .Project,
            });
            if (with_clause.distinct) {
                try ops.append(allocator, .{ .kind = .Distinct });
            }
            if (with_clause.order_by != null) {
                try ops.append(allocator, .{ .kind = .Sort });
            }
            if (with_clause.limit != null or with_clause.offset != null or with_clause.limit_param != null or with_clause.offset_param != null) {
                try ops.append(allocator, .{ .kind = .Limit });
            }
            if (q.where_clause != null) {
                try ops.append(allocator, .{ .kind = .Filter });
            }
        }

        if (needsFinalProjection(q)) {
            try ops.append(allocator, .{
                .kind = if ((q.with_clause == null and q.group_by != null) or hasAggregationItems(q.ret.items)) .Aggregate else .Project,
            });
            if (q.ret.distinct) {
                try ops.append(allocator, .{ .kind = .Distinct });
            }
            if (q.order_by != null) {
                try ops.append(allocator, .{ .kind = .Sort });
            }
            if (q.limit != null or q.offset != null or q.limit_param != null or q.offset_param != null) {
                try ops.append(allocator, .{ .kind = .Limit });
            }
        }
    }

    return Plan{
        .graph_name = graph_name,
        .binding_names = try binding_names.toOwnedSlice(allocator),
        .binding_kinds = try binding_kinds.toOwnedSlice(allocator),
        .ops = try ops.toOwnedSlice(allocator),
        .execution_mode = execution_mode,
        .root_index = root_index,
        .hops = try hop_bindings.toOwnedSlice(allocator),
    };
}

pub fn executeIfSupported(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
) !?ExecutionResult {
    if (!isStorageNativeQuery(q) or (q.match.chains.len > 0 and graph_store.getGlobalAdapter() == null)) {
        return null;
    }

    if (try executeProfiledIfSupported(allocator, q, context, param_names, param_values, false)) |profiled| {
        var owned_profiled = profiled;
        defer owned_profiled.deinitMetadata(allocator);
        return owned_profiled.result;
    }
    return null;
}

pub fn executeProfiledIfSupported(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    apply_window: bool,
) !?ProfiledExecution {
    var plan = (try buildPlanIfSupported(allocator, q, context)) orelse return null;
    errdefer plan.deinit(allocator);

    if (plan.execution_mode != .storage_native or (q.match.chains.len > 0 and graph_store.getGlobalAdapter() == null)) {
        return try executeLegacyProfiled(allocator, q, context, param_names, param_values, plan);
    }

    var trace = RuntimeTrace{
        .ops = try allocator.alloc(RuntimeOp, plan.ops.len),
    };
    errdefer trace.deinit(allocator);
    for (plan.ops, 0..) |op, idx| {
        trace.ops[idx] = .{ .kind = op.kind };
    }

    var filter_occurrence: usize = 0;
    var aggregate_occurrence: usize = 0;
    var project_occurrence: usize = 0;
    var distinct_occurrence: usize = 0;
    var sort_occurrence: usize = 0;
    var limit_occurrence: usize = 0;

    var result = try buildInitialResult(allocator, q, context, &plan, param_names, param_values, &trace);
    errdefer result.deinit(allocator);

    if (hasPreProjectionFilter(q)) {
        const op_index = nextOpIndex(trace.ops, .Filter, &filter_occurrence) orelse unreachable;
        try applyResultFilters(
            allocator,
            &result,
            if (q.with_clause == null) q.where_clause else null,
            q.filter_clause,
            context,
            param_names,
            param_values,
            &trace.ops[op_index],
        );
    }

    if (q.with_clause) |with_clause| {
        const with_kind: OpKind = if (q.group_by != null or hasAggregationItems(with_clause.items)) .Aggregate else .Project;
        const with_op_index = switch (with_kind) {
            .Aggregate => nextOpIndex(trace.ops, .Aggregate, &aggregate_occurrence),
            .Project => nextOpIndex(trace.ops, .Project, &project_occurrence),
            else => unreachable,
        } orelse unreachable;

        const with_stage = stripWithExecutionModifiers(with_clause);
        const input_rows = result.rows.len;
        const start_ns = std.time.nanoTimestamp();
        var with_result = try transformResultRows(allocator, result, with_stage, q.group_by, q.having);
        transferOwnedGraphEntities(&result, &with_result);
        deinitResultKeepingOwnedGraphEntities(allocator, &result);

        trace.ops[with_op_index].input_rows = @intCast(input_rows);
        trace.ops[with_op_index].rows = @intCast(with_result.rows.len);
        trace.ops[with_op_index].time_ns = elapsedSince(start_ns);

        result = with_result;

        if (with_clause.distinct) {
            const op_index = nextOpIndex(trace.ops, .Distinct, &distinct_occurrence) orelse unreachable;
            try applyDistinctStage(allocator, &result, &trace.ops[op_index]);
        }
        if (with_clause.order_by) |order_ptr| {
            const op_index = nextOpIndex(trace.ops, .Sort, &sort_occurrence) orelse unreachable;
            try applySortStage(allocator, &result, order_ptr.*, with_clause.items, &trace.ops[op_index]);
        }
        if (with_clause.limit != null or with_clause.offset != null or with_clause.limit_param != null or with_clause.offset_param != null) {
            const op_index = nextOpIndex(trace.ops, .Limit, &limit_occurrence) orelse unreachable;
            try applyWindowStage(
                allocator,
                &result,
                if (with_clause.offset) |value| @as(usize, @intCast(value)) else null,
                with_clause.offset_param,
                if (with_clause.limit) |value| @as(usize, @intCast(value)) else null,
                with_clause.limit_param,
                param_names,
                param_values,
                &trace.ops[op_index],
            );
        }
        if (q.where_clause != null) {
            const op_index = nextOpIndex(trace.ops, .Filter, &filter_occurrence) orelse unreachable;
            try applyResultFilters(
                allocator,
                &result,
                q.where_clause,
                null,
                context,
                param_names,
                param_values,
                &trace.ops[op_index],
            );
        }
    }

    if (needsFinalProjection(q)) {
        const return_group_by = if (q.with_clause == null) q.group_by else null;
        const return_having = if (q.with_clause == null) q.having else null;
        const return_kind: OpKind = if ((q.with_clause == null and q.group_by != null) or hasAggregationItems(q.ret.items)) .Aggregate else .Project;
        const return_op_index = switch (return_kind) {
            .Aggregate => nextOpIndex(trace.ops, .Aggregate, &aggregate_occurrence),
            .Project => nextOpIndex(trace.ops, .Project, &project_occurrence),
            else => unreachable,
        } orelse unreachable;

        const return_stage = ast.WithClause{
            .items = q.ret.items,
        };
        const input_rows = result.rows.len;
        const start_ns = std.time.nanoTimestamp();
        var projected = try transformResultRows(allocator, result, return_stage, return_group_by, return_having);
        transferOwnedGraphEntities(&result, &projected);
        deinitResultKeepingOwnedGraphEntities(allocator, &result);

        trace.ops[return_op_index].input_rows = @intCast(input_rows);
        trace.ops[return_op_index].rows = @intCast(projected.rows.len);
        trace.ops[return_op_index].time_ns = elapsedSince(start_ns);

        result = projected;

        if (q.ret.distinct) {
            const op_index = nextOpIndex(trace.ops, .Distinct, &distinct_occurrence) orelse unreachable;
            try applyDistinctStage(allocator, &result, &trace.ops[op_index]);
        }
        if (q.order_by) |order| {
            const op_index = nextOpIndex(trace.ops, .Sort, &sort_occurrence) orelse unreachable;
            try applySortStage(allocator, &result, order, q.ret.items, &trace.ops[op_index]);
        }
        if (apply_window and (q.limit != null or q.offset != null or q.limit_param != null or q.offset_param != null)) {
            const op_index = nextOpIndex(trace.ops, .Limit, &limit_occurrence) orelse unreachable;
            try applyWindowStage(
                allocator,
                &result,
                q.offset,
                q.offset_param,
                q.limit,
                q.limit_param,
                param_names,
                param_values,
                &trace.ops[op_index],
            );
        }
    }

    return ProfiledExecution{
        .plan = plan,
        .result = result,
        .trace = trace,
    };
}

fn executeLegacyProfiled(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    plan: Plan,
) !ProfiledExecution {
    var trace = RuntimeTrace{
        .ops = try allocator.alloc(RuntimeOp, plan.ops.len),
    };
    errdefer trace.deinit(allocator);
    for (plan.ops, 0..) |op, idx| {
        trace.ops[idx] = .{ .kind = op.kind };
    }

    const start_ns = std.time.nanoTimestamp();
    var result = try execution.executeLegacyQueryWithResolvedParams(allocator, q.*, context, param_names, param_values);
    errdefer result.deinit(allocator);

    if (trace.ops.len > 0) {
        const last = &trace.ops[trace.ops.len - 1];
        last.input_rows = @intCast(result.rows.len);
        last.rows = @intCast(result.rows.len);
        last.time_ns = elapsedSince(start_ns);
    }

    return ProfiledExecution{
        .plan = plan,
        .result = result,
        .trace = trace,
    };
}

fn buildInitialResult(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    trace: *RuntimeTrace,
) !ExecutionResult {
    if (q.match.chains.len == 0) {
        const empty_row = try allocator.alloc(Value, 0);
        errdefer allocator.free(empty_row);
        const rows = try allocator.alloc([]Value, 1);
        rows[0] = empty_row;
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    return executePatternQuery(allocator, q, context, plan, param_names, param_values, trace);
}

fn executePatternQuery(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    trace: *RuntimeTrace,
) !ExecutionResult {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const chain = q.match.chains[0];
    var rows = try std.ArrayList([]Value).initCapacity(allocator, 0);
    defer rows.deinit(allocator);
    var owned_entities = try OwnedGraphEntities.init(allocator);
    errdefer owned_entities.deinit();

    if (!adapter.graphExists(plan.graph_name)) {
        const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
        const empty_result = ExecutionResult{
            .columns = column_result.columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .column_buffer = column_result.buffer,
        };
        owned_entities.deinit();
        return empty_result;
    }

    const start_pattern = if (chain.head) |head| head else chain.hops[0].left;
    const scan_op_index = 0;
    const scan_start_ns = std.time.nanoTimestamp();
    const start_slots = try collectStartSlots(
        allocator,
        adapter,
        plan.graph_name,
        start_pattern,
        requiredStartRows(q, param_names, param_values),
        param_names,
        param_values,
        context,
    );
    defer allocator.free(start_slots);
    trace.ops[scan_op_index].rows = @intCast(start_slots.len);
    trace.ops[scan_op_index].time_ns = elapsedSince(scan_start_ns);

    if (chain.hops.len == 0) {
        for (start_slots) |slot_id| {
            // Skip deleted nodes: the engine label index may return slot IDs
            // for nodes that have been deleted (NODE_FLAG_DELETED set) since
            // label entries are not cleaned up on delete. Catch NodeNotFound
            // so the query succeeds with the remaining live nodes.
            materializeNodeOnlyRow(allocator, q, context, plan, slot_id, param_names, param_values, &rows, owned_entities) catch |err| switch (err) {
                error.NodeNotFound => continue,
                else => return err,
            };
        }
    } else {
        var current_nodes = try allocator.alloc(u64, chain.hops.len + 1);
        defer allocator.free(current_nodes);
        const current_edges = try allocator.alloc(PathEdge, chain.hops.len);
        defer allocator.free(current_edges);

        for (start_slots) |start_slot| {
            current_nodes[0] = start_slot;
            // Skip deleted nodes in hop expansion (same stale label index issue).
            exploreHops(allocator, adapter, plan.graph_name, q, context, plan, param_names, param_values, &rows, owned_entities, trace, current_nodes, current_edges, 0) catch |err| switch (err) {
                error.NodeNotFound => continue,
                else => return err,
            };
        }
    }

    const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
    const result = ExecutionResult{
        .columns = column_result.columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .column_buffer = column_result.buffer,
        .owned_graph_entities = if (owned_entities.nodes.items.len > 0 or owned_entities.edges.items.len > 0) owned_entities else null,
    };
    if (result.owned_graph_entities == null) {
        owned_entities.deinit();
    }
    return result;
}

fn exploreHops(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
    trace: *RuntimeTrace,
    current_nodes: []u64,
    current_edges: []PathEdge,
    hop_index: usize,
) !void {
    const chain = q.match.chains[0];
    if (hop_index == chain.hops.len) {
        try materializePathRow(allocator, q, context, plan, graph_name, current_nodes, current_edges, param_names, param_values, rows, owned_entities);
        return;
    }

    const hop = chain.hops[hop_index];
    const op_index = 1 + hop_index;
    trace.ops[op_index].input_rows += 1;
    const start_ns = std.time.nanoTimestamp();

    const candidates = try collectHopEdges(allocator, adapter, graph_name, current_nodes[hop_index], hop.rel.dir);
    defer allocator.free(candidates);

    var produced: u64 = 0;
    for (candidates) |edge| {
        if (!(edgeMatchesPattern(allocator, adapter, graph_name, edge, hop.rel, param_names, param_values, context) catch |err| switch (err) {
            error.NodeNotFound => continue,
            else => return err,
        })) {
            continue;
        }
        if (!(nodeMatchesPatternBySlot(allocator, adapter, graph_name, edge.next_slot, hop.right, param_names, param_values, context) catch |err| switch (err) {
            error.NodeNotFound => continue,
            else => return err,
        })) {
            continue;
        }
        current_edges[hop_index] = edge;
        current_nodes[hop_index + 1] = edge.next_slot;
        produced += 1;
        try exploreHops(allocator, adapter, graph_name, q, context, plan, param_names, param_values, rows, owned_entities, trace, current_nodes, current_edges, hop_index + 1);
    }

    trace.ops[op_index].rows += produced;
    trace.ops[op_index].time_ns += elapsedSince(start_ns);
}

fn materializeNodeOnlyRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    node_slot: u64,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
) !void {
    var local_nodes = try std.ArrayList(*graph_store.Node).initCapacity(allocator, 0);
    defer local_nodes.deinit(allocator);
    var local_edges = try std.ArrayList(*graph_store.Edge).initCapacity(allocator, 0);
    defer local_edges.deinit(allocator);

    const node = try materializeNode(allocator, plan.graph_name, node_slot);
    try local_nodes.append(allocator, node);

    const binding_values = try allocator.alloc(Value, plan.binding_names.len);
    defer allocator.free(binding_values);
    for (binding_values) |*value| value.* = Value{ .Null = {} };
    if (plan.root_index) |idx| {
        binding_values[idx] = Value{ .Node = node };
    }

    const env = Env{
        .names = plan.binding_names,
        .values = binding_values,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    const row = try buildBindingRow(allocator, q, env, binding_values);
    try rows.append(allocator, row);
    for (local_nodes.items) |tracked_node| {
        try owned_entities.trackNode(tracked_node);
    }
}

fn materializePathRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    graph_name: []const u8,
    node_slots: []const u64,
    edge_steps: []const PathEdge,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
) !void {
    var local_nodes = try std.ArrayList(*graph_store.Node).initCapacity(allocator, 0);
    defer local_nodes.deinit(allocator);
    var local_edges = try std.ArrayList(*graph_store.Edge).initCapacity(allocator, 0);
    defer local_edges.deinit(allocator);

    const binding_values = try allocator.alloc(Value, plan.binding_names.len);
    defer allocator.free(binding_values);
    for (binding_values) |*value| value.* = Value{ .Null = {} };

    if (plan.root_index) |idx| {
        const root_node = try materializeNode(allocator, graph_name, node_slots[0]);
        try local_nodes.append(allocator, root_node);
        binding_values[idx] = Value{ .Node = root_node };
    }

    for (plan.hops, 0..) |hop_binding, hop_idx| {
        const edge = try materializeEdge(allocator, graph_name, edge_steps[hop_idx]);
        try local_edges.append(allocator, edge);
        binding_values[hop_binding.rel_index] = Value{ .Edge = edge };

        const right_node = try materializeNode(allocator, graph_name, node_slots[hop_idx + 1]);
        try local_nodes.append(allocator, right_node);
        binding_values[hop_binding.right_index] = Value{ .Node = right_node };
    }

    const env = Env{
        .names = plan.binding_names,
        .values = binding_values,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    const row = try buildBindingRow(allocator, q, env, binding_values);
    try rows.append(allocator, row);
    for (local_nodes.items) |node| {
        try owned_entities.trackNode(node);
    }
    for (local_edges.items) |edge| {
        try owned_entities.trackEdge(edge);
    }
}

fn collectStartSlots(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    required_rows: ?usize,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) ![]u64 {
    if (!adapter.graphExists(graph_name)) {
        return try allocator.alloc(u64, 0);
    }

    const initial = if (pattern.labels.len > 0)
        try adapter.getNodesByLabel(graph_name, pattern.labels[0], allocator)
    else blk: {
        const scan_entries = try adapter.scanAllNodes(graph_name, allocator);
        defer allocator.free(scan_entries);
        var slots = try std.ArrayList(u64).initCapacity(allocator, scan_entries.len);
        defer slots.deinit(allocator);
        for (scan_entries) |entry| {
            try slots.append(allocator, entry.slot_id);
        }
        break :blk try slots.toOwnedSlice(allocator);
    };
    errdefer allocator.free(initial);

    if (required_rows) |needed| {
        if (pattern.labels.len > 0 and initial.len < needed) {
            allocator.free(initial);
            return scanAndFilterStartSlots(allocator, adapter, graph_name, pattern, param_names, param_values, context);
        }
    }

    if (pattern.labels.len <= 1 and pattern.props == null) {
        return initial;
    }

    var filtered = try std.ArrayList(u64).initCapacity(allocator, initial.len);
    defer filtered.deinit(allocator);
    for (initial) |slot_id| {
        // Skip deleted nodes: the engine label index may include stale
        // slot IDs for nodes that have been soft-deleted.
        const matches = nodeMatchesPatternBySlot(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context) catch |err| switch (err) {
            error.NodeNotFound => continue,
            else => return err,
        };
        if (matches) {
            try filtered.append(allocator, slot_id);
        }
    }
    allocator.free(initial);
    return try filtered.toOwnedSlice(allocator);
}

fn scanAndFilterStartSlots(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) ![]u64 {
    const scan_entries = try adapter.scanAllNodes(graph_name, allocator);
    defer allocator.free(scan_entries);

    var filtered = try std.ArrayList(u64).initCapacity(allocator, scan_entries.len);
    defer filtered.deinit(allocator);

    for (scan_entries) |entry| {
        const matches = nodeMatchesPatternBySlot(allocator, adapter, graph_name, entry.slot_id, pattern, param_names, param_values, context) catch |err| switch (err) {
            error.NodeNotFound => continue,
            else => return err,
        };
        if (matches) {
            try filtered.append(allocator, entry.slot_id);
        }
    }

    return try filtered.toOwnedSlice(allocator);
}

fn collectHopEdges(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    node_slot: u64,
    dir: ast.RelDir,
) ![]PathEdge {
    var edges = try std.ArrayList(PathEdge).initCapacity(allocator, 0);
    defer edges.deinit(allocator);

    switch (dir) {
        .right => {
            const out = try adapter.getOutgoingEdges(graph_name, node_slot, allocator);
            defer allocator.free(out);
            for (out) |entry| {
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = node_slot,
                    .actual_to_slot = entry.neighbor,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                });
            }
        },
        .left => {
            const incoming = try adapter.getIncomingEdges(graph_name, node_slot, allocator);
            defer allocator.free(incoming);
            for (incoming) |entry| {
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = entry.neighbor,
                    .actual_to_slot = node_slot,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                });
            }
        },
        .undirected => {
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();

            const out = try adapter.getOutgoingEdges(graph_name, node_slot, allocator);
            defer allocator.free(out);
            for (out) |entry| {
                if (seen.contains(entry.edge_id)) continue;
                try seen.put(entry.edge_id, {});
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = node_slot,
                    .actual_to_slot = entry.neighbor,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                });
            }

            const incoming = try adapter.getIncomingEdges(graph_name, node_slot, allocator);
            defer allocator.free(incoming);
            for (incoming) |entry| {
                if (seen.contains(entry.edge_id)) continue;
                try seen.put(entry.edge_id, {});
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = entry.neighbor,
                    .actual_to_slot = node_slot,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                });
            }
        },
    }

    return try edges.toOwnedSlice(allocator);
}

fn nodeMatchesPatternBySlot(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
    defer {
        for (labels) |label| allocator.free(label);
        allocator.free(labels);
    }

    if (!labelsContainAll(labels, pattern.labels)) {
        return false;
    }
    if (pattern.props == null) return true;

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    return propsMatch(allocator, pattern.props.?, &props, param_names, param_values, context);
}

fn edgeMatchesPattern(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    edge: PathEdge,
    pattern: ast.RelPattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    if (pattern.types.len > 0) {
        const rel_name = try edgeTypeName(allocator, graph_name, edge.rel_type);
        defer allocator.free(rel_name);

        var matched = false;
        for (pattern.types) |rel_type| {
            if (std.mem.eql(u8, rel_name, rel_type)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }

    if (pattern.props == null) return true;

    var props = try adapter.getAllEdgeProperties(graph_name, edge.prop_head, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    return propsMatch(allocator, pattern.props.?, &props, param_names, param_values, context);
}

fn propsMatch(
    allocator: std.mem.Allocator,
    props: []ast.Property,
    actual_props: *std.StringHashMap(gs.PropertyValue),
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) bool {
    for (props) |prop| {
        const expected = eval.evalExpr(allocator, prop.value.*, Env{
            .names = &.{},
            .values = &.{},
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .exec_context = @constCast(&context),
        }) catch return false;
        const actual = actual_props.get(prop.key) orelse return false;
        if (!storagePropertyMatches(expected, actual)) {
            return false;
        }
    }
    return true;
}

fn materializeNode(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64) !*graph_store.Node {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const store = graph_store.getGlobalStore(allocator);
    const external_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, slot_id);

    const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
    errdefer {
        for (labels) |label| allocator.free(label);
        allocator.free(labels);
    }

    const node = try allocator.create(graph_store.Node);
    errdefer allocator.destroy(node);
    node.* = .{
        .id = external_id,
        .labels = labels,
        .properties = std.StringHashMap(graph_store.PropertyValue).init(allocator),
        .graph_name = try allocator.dupe(u8, graph_name),
    };
    errdefer {
        node.properties.deinit();
        allocator.free(node.graph_name);
    }

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    var iter = props.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try graph_storage_adapter.fromStorageProperty(allocator, entry.value_ptr.*);
        try node.properties.put(key, value);
    }

    return node;
}

fn materializeEdge(allocator: std.mem.Allocator, graph_name: []const u8, edge_step: PathEdge) !*graph_store.Edge {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const store = graph_store.getGlobalStore(allocator);
    const id_map = store.getIdMap(graph_name) orelse return error.IdMapNotLoaded;
    const edge_id = @as(u64, @truncate(id_map.edgeUuid(edge_step.edge_id) orelse return error.EdgeSlotMappingMissing));
    const from_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, edge_step.actual_from_slot);
    const to_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, edge_step.actual_to_slot);

    const edge = try allocator.create(graph_store.Edge);
    errdefer allocator.destroy(edge);
    edge.* = .{
        .id = edge_id,
        .from_id = from_id,
        .to_id = to_id,
        .label = try edgeTypeName(allocator, graph_name, edge_step.rel_type),
        .properties = std.StringHashMap(graph_store.PropertyValue).init(allocator),
        .graph_name = try allocator.dupe(u8, graph_name),
    };
    errdefer {
        edge.properties.deinit();
        allocator.free(edge.label);
        allocator.free(edge.graph_name);
    }

    var props = try adapter.getAllEdgeProperties(graph_name, edge_step.prop_head, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    var iter = props.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try graph_storage_adapter.fromStorageProperty(allocator, entry.value_ptr.*);
        try edge.properties.put(key, value);
    }

    return edge;
}

/// Resolve the external (public) node ID for a given adapter slot.
/// First checks the in-memory IdMap; if missing, falls back to reading the
/// persisted `__geode_internal_node_id` property from the adapter and
/// back-fills the IdMap so subsequent lookups are O(1).
fn resolveExternalNodeId(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    slot_id: u64,
) !u64 {
    // Fast path: IdMap already has the mapping.
    if (store.getIdMap(graph_name)) |id_map| {
        if (id_map.nodeUuid(slot_id)) |uuid_128| {
            return @as(u64, @truncate(uuid_128));
        }
    }

    // Slow path: read the persisted public ID property from the adapter.
    if (adapter.getNodeProperty(graph_name, slot_id, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY, allocator) catch null) |stored_prop| {
        defer switch (stored_prop) {
            .string => |text| allocator.free(text),
            else => {},
        };
        const public_id: ?u64 = switch (stored_prop) {
            .string => |text| graph_store.parsePersistedPublicId(text),
            .int => |n| if (n >= 0) @as(u64, @intCast(n)) else null,
            else => null,
        };
        if (public_id) |pid| {
            // Back-fill the IdMap for future lookups.
            const im = store.getOrCreateIdMap(graph_name) catch return pid;
            im.insertNodeWithSlot(@as(u128, pid), slot_id) catch {};
            return pid;
        }
    }

    // Neither the IdMap nor the persisted property had a mapping for this
    // slot.  This happens for nodes created within the current session whose
    // graph has no IdMap yet (e.g. freshly-created test graphs).  Fall back
    // to using the slot_id directly as the external ID so that
    // materializeNode can still succeed.
    return slot_id;
}

fn buildColumns(allocator: std.mem.Allocator, items: []const ast.ReturnItem) !struct { columns: [][]const u8, buffer: []u8 } {
    var names = try std.ArrayList([]const u8).initCapacity(allocator, items.len);
    defer names.deinit(allocator);

    for (items) |item| {
        const name = item.alias orelse switch (item.expr) {
            .Ident => |ident| ident.orig,
            else => "column",
        };
        try names.append(allocator, name);
    }

    const columns = try execution.allocateColumnStrings(allocator, names.items);
    return .{ .columns = columns.columns, .buffer = columns.buffer };
}

fn buildBindingColumns(
    allocator: std.mem.Allocator,
    binding_names: []const []const u8,
    inline_let_bindings: []const ast.LetBinding,
) !struct { columns: [][]const u8, buffer: []u8 } {
    var names = try std.ArrayList([]const u8).initCapacity(allocator, binding_names.len + inline_let_bindings.len);
    defer names.deinit(allocator);

    try names.appendSlice(allocator, binding_names);
    for (inline_let_bindings) |binding| {
        try names.append(allocator, binding.variable);
    }

    const columns = try execution.allocateColumnStrings(allocator, names.items);
    return .{ .columns = columns.columns, .buffer = columns.buffer };
}

fn buildBindingRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    env: Env,
    binding_values: []const Value,
) ![]Value {
    const total_values = binding_values.len + q.inline_let_bindings.len;
    const row = try allocator.alloc(Value, total_values);

    for (binding_values, 0..) |value, idx| {
        row[idx] = value;
    }
    for (q.inline_let_bindings, 0..) |binding, idx| {
        row[binding_values.len + idx] = try eval.evalExpr(allocator, binding.value, env);
    }

    return row;
}

fn transformResultRows(
    allocator: std.mem.Allocator,
    input_result: ExecutionResult,
    with_clause: ast.WithClause,
    group_by: ?ast.GroupBy,
    having: ?ast.Expr,
) !ExecutionResult {
    return execution.executeWithClauseWithGroupBy(allocator, input_result, with_clause, group_by, having);
}

fn applyResultFilters(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    where_expr: ?ast.Expr,
    filter_expr: ?ast.Expr,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    trace_op: *RuntimeOp,
) !void {
    const start_ns = std.time.nanoTimestamp();
    trace_op.input_rows = @intCast(result.rows.len);

    var filtered_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);
    defer filtered_rows.deinit(allocator);

    for (result.rows) |row| {
        const env = Env{
            .names = result.columns,
            .values = row,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .exec_context = @constCast(&context),
        };

        const passes_where = if (where_expr) |expr|
            truthyPredicate(eval.evalExpr(allocator, expr, env) catch Value{ .Bool = false })
        else
            true;
        if (!passes_where) {
            allocator.free(row);
            continue;
        }

        const passes_filter = if (filter_expr) |expr|
            truthyPredicate(eval.evalExpr(allocator, expr, env) catch Value{ .Bool = false })
        else
            true;
        if (!passes_filter) {
            allocator.free(row);
            continue;
        }

        try filtered_rows.append(allocator, row);
    }

    const old_rows = result.rows;
    result.rows = try filtered_rows.toOwnedSlice(allocator);
    allocator.free(old_rows);
    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn applyDistinctStage(allocator: std.mem.Allocator, result: *ExecutionResult, trace_op: *RuntimeOp) !void {
    const start_ns = std.time.nanoTimestamp();
    trace_op.input_rows = @intCast(result.rows.len);
    try result_utils.applyDistinct(allocator, result);
    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn applySortStage(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    order: ast.OrderBy,
    return_items: []const ast.ReturnItem,
    trace_op: *RuntimeOp,
) !void {
    const start_ns = std.time.nanoTimestamp();
    trace_op.input_rows = @intCast(result.rows.len);
    try execution.sortRowsEx(allocator, result, order, return_items);
    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn applyWindowStage(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    offset_literal: ?usize,
    offset_param: ?[]const u8,
    limit_literal: ?usize,
    limit_param: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    trace_op: *RuntimeOp,
) !void {
    const start_ns = std.time.nanoTimestamp();
    trace_op.input_rows = @intCast(result.rows.len);

    const offset = offset_literal orelse resolveWindowValue(null, offset_param, param_names, param_values) orelse 0;
    const end_limit = if (limit_literal) |value|
        @min(result.rows.len, std.math.add(usize, offset, value) catch std.math.maxInt(usize))
    else if (resolveWindowValue(null, limit_param, param_names, param_values)) |limit_value|
        @min(result.rows.len, std.math.add(usize, offset, limit_value) catch std.math.maxInt(usize))
    else
        result.rows.len;

    if (offset != 0 or end_limit != result.rows.len) {
        try execution.applyRowWindow(allocator, result, offset, end_limit);
    }

    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn transferOwnedGraphEntities(source: *ExecutionResult, destination: *ExecutionResult) void {
    destination.owned_graph_entities = source.owned_graph_entities;
    source.owned_graph_entities = null;
}

fn deinitResultKeepingOwnedGraphEntities(allocator: std.mem.Allocator, result: *ExecutionResult) void {
    result.owned_graph_entities = null;
    result.deinit(allocator);
}

fn stripWithExecutionModifiers(with_clause: ast.WithClause) ast.WithClause {
    var stripped = with_clause;
    stripped.distinct = false;
    stripped.order_by = null;
    stripped.limit = null;
    stripped.offset = null;
    stripped.limit_param = null;
    stripped.offset_param = null;
    return stripped;
}

fn resolveWindowValue(
    literal: ?usize,
    param_name: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    if (literal) |value| return value;
    if (param_name) |name| {
        for (param_names, param_values) |param, value| {
            if (!std.mem.eql(u8, param, name)) continue;
            return switch (value) {
                .Int => |int_value| if (int_value >= 0) @as(usize, @intCast(int_value)) else null,
                else => null,
            };
        }
    }
    return null;
}

fn passesPredicates(allocator: std.mem.Allocator, q: *const ast.Query, env: Env) bool {
    if (q.where_clause) |where_expr| {
        const value = eval.evalExpr(allocator, where_expr, env) catch return false;
        if (!truthyPredicate(value)) return false;
    }
    if (q.filter_clause) |filter_expr| {
        const value = eval.evalExpr(allocator, filter_expr, env) catch return false;
        if (!truthyPredicate(value)) return false;
    }
    return true;
}

fn truthyPredicate(value: Value) bool {
    return switch (value) {
        .Bool => |boolean| boolean,
        .Int => |integer| integer != 0,
        else => false,
    };
}

fn storagePropertyMatches(expected: Value, actual: gs.PropertyValue) bool {
    return switch (actual) {
        .string => |text| switch (expected) {
            .Str => |expected_text| std.mem.eql(u8, expected_text, text),
            else => false,
        },
        .int => |number| switch (expected) {
            .Int => |expected_number| expected_number == number,
            else => false,
        },
        .bool => |boolean| switch (expected) {
            .Bool => |expected_boolean| expected_boolean == boolean,
            else => false,
        },
        .null => expected == .Null,
        .decimal => |decimal| switch (expected) {
            .Decimal => |expected_decimal| expected_decimal.coeff == decimal.coeff and expected_decimal.scale == decimal.scale,
            else => false,
        },
        .float => |float_value| switch (expected) {
            .Decimal => |decimal| decimalToFloat(decimal.coeff, decimal.scale) == float_value,
            else => false,
        },
        .ext => false,
    };
}

fn decimalToFloat(coeff: i128, scale: u8) f64 {
    var divisor: f64 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) {
        divisor *= 10;
    }
    return @as(f64, @floatFromInt(coeff)) / divisor;
}

fn labelsContainAll(actual: []const []const u8, required: []const []const u8) bool {
    for (required) |required_label| {
        var found = false;
        for (actual) |actual_label| {
            if (std.mem.eql(u8, actual_label, required_label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn freeTrackedEntities(allocator: std.mem.Allocator, nodes: []const *graph_store.Node, edges: []const *graph_store.Edge) void {
    for (nodes) |node| {
        execution.destroyOwnedNode(allocator, @constCast(node));
    }
    for (edges) |edge| {
        execution.destroyOwnedEdge(allocator, @constCast(edge));
    }
}

fn freeStoragePropertyValue(allocator: std.mem.Allocator, value: gs.PropertyValue) void {
    switch (value) {
        .string => |text| allocator.free(text),
        else => {},
    }
}

fn freeStoragePropertyMap(allocator: std.mem.Allocator, map: *std.StringHashMap(gs.PropertyValue)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeStoragePropertyValue(allocator, entry.value_ptr.*);
    }
    map.deinit();
}

fn edgeTypeName(allocator: std.mem.Allocator, graph_name: []const u8, rel_type: gs.LabelId) ![]const u8 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const managed_graph = try adapter.getOrCreateGraph(graph_name);
    return try allocator.dupe(u8, managed_graph.label_dict.getString(rel_type) orelse "UNKNOWN");
}

fn ensureBinding(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    kinds: *std.ArrayList(BindingKind),
    kind: BindingKind,
    preferred_name: ?[]const u8,
    prefix: []const u8,
    ordinal: usize,
) !usize {
    if (preferred_name) |name| {
        for (names.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, name)) {
                if (kinds.items[idx] != kind) return error.Unsupported;
                return idx;
            }
        }
        try names.append(allocator, try allocator.dupe(u8, name));
        try kinds.append(allocator, kind);
        return names.items.len - 1;
    }

    const generated = try std.fmt.allocPrint(allocator, "__planned_{s}_{d}", .{ prefix, ordinal });
    try names.append(allocator, generated);
    try kinds.append(allocator, kind);
    return names.items.len - 1;
}

fn estimateScanRows(allocator: std.mem.Allocator, graph_name: []const u8, pattern: ast.NodePattern) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return 0;
    if (!adapter.graphExists(graph_name)) return 0;

    if (pattern.labels.len > 0) {
        const nodes = try adapter.getNodesByLabel(graph_name, pattern.labels[0], allocator);
        defer allocator.free(nodes);
        return @intCast(nodes.len);
    }

    return adapter.nodeCount(graph_name) catch 0;
}

fn resolveGraphName(context: ExecutionContext) []const u8 {
    return if (context.session_state) |session|
        session.graph orelse graph_store.DEFAULT_GRAPH_NAME
    else
        graph_store.DEFAULT_GRAPH_NAME;
}

fn nextOpIndex(ops: []const RuntimeOp, kind: OpKind, occurrence: *usize) ?usize {
    var seen: usize = 0;
    for (ops, 0..) |op, idx| {
        if (op.kind != kind) continue;
        if (seen == occurrence.*) {
            occurrence.* += 1;
            return idx;
        }
        seen += 1;
    }
    return null;
}

fn elapsedSince(start_ns: i128) u64 {
    const now = std.time.nanoTimestamp();
    return if (now > start_ns) @intCast(now - start_ns) else 0;
}

fn requiredStartRows(
    q: *const ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    if (resolveWindowValue(q.limit, q.limit_param, param_names, param_values)) |limit| {
        return std.math.add(usize, offset, limit) catch std.math.maxInt(usize);
    }
    if (offset != 0) {
        return std.math.add(usize, offset, 1) catch std.math.maxInt(usize);
    }
    return null;
}

fn hasPreProjectionFilter(q: *const ast.Query) bool {
    return q.filter_clause != null or (q.with_clause == null and q.where_clause != null);
}

fn hasAggregationItems(items: []const ast.ReturnItem) bool {
    for (items) |item| {
        if (execution.isAggregationExpr(item.expr)) return true;
    }
    return false;
}

fn needsFinalProjection(q: *const ast.Query) bool {
    if (q.ret.items.len == 0) return false;
    if (q.with_clause) |with_clause| {
        const same_items = q.ret.items.ptr == with_clause.items.ptr and q.ret.items.len == with_clause.items.len;
        if (same_items) return false;
    }
    return true;
}

fn appendLegacyPlanOps(
    allocator: std.mem.Allocator,
    ops: *std.ArrayList(PlanOp),
    q: *const ast.Query,
) !void {
    if (q.cte_list) |cte_list| {
        for (cte_list.ctes) |cte| {
            try ops.append(allocator, .{ .kind = .RecursiveCTE });
            switch (cte.body) {
                .simple => |subquery| try appendLegacyPlanOps(allocator, ops, subquery),
                .recursive => |recursive| {
                    try appendLegacyPlanOps(allocator, ops, recursive.anchor);
                    try appendLegacyPlanOps(allocator, ops, recursive.recursive_term);
                },
            }
        }
    }

    if (q.initial_call_subquery) |call_subquery| {
        try ops.append(allocator, .{ .kind = .CallSubquery });
        try appendLegacyPlanOps(allocator, ops, call_subquery);
    }

    if (q.unwind_clause != null) {
        try ops.append(allocator, .{ .kind = .Unwind });
    }

    if (q.path_variable != null) {
        try ops.append(allocator, .{ .kind = .PathCapture });
    }

    if (q.match.chains.len == 0 and q.unwind_clause == null and q.initial_call_subquery == null) {
        try ops.append(allocator, .{ .kind = .ConstProjection, .est_rows = 1 });
    }

    const saw_optional = q.optional_match;
    for (q.match.chains) |chain| {
        if (saw_optional or chain.is_optional) {
            try ops.append(allocator, .{ .kind = .OptionalMatch });
        }
        if (chain.head) |head| {
            try ops.append(allocator, .{
                .kind = if (head.labels.len > 0) .LabelScan else .AllNodesScan,
            });
        } else if (chain.hops.len > 0) {
            const root = chain.hops[0].left;
            try ops.append(allocator, .{
                .kind = if (root.labels.len > 0) .LabelScan else .AllNodesScan,
            });
        }

        if (chain.name != null) {
            try ops.append(allocator, .{ .kind = .PathCapture });
        }

        for (chain.hops) |hop| {
            if (chain.is_shortest) {
                try ops.append(allocator, .{ .kind = .ShortestPath });
                continue;
            }
            if (hop.rel.min_len != null or hop.rel.max_len != null) {
                try ops.append(allocator, .{ .kind = .VarLengthExpand });
                continue;
            }
            if (chain.path_mode != .walk) {
                try ops.append(allocator, .{ .kind = .PathModeExpand });
                continue;
            }
            try ops.append(allocator, .{
                .kind = switch (hop.rel.dir) {
                    .right => .ExpandOut,
                    .left => .ExpandIn,
                    .undirected => .ExpandEither,
                },
            });
        }
    }

    if (hasPreProjectionFilter(q)) {
        try ops.append(allocator, .{ .kind = .Filter });
    }

    if (q.call_clause != null) {
        try ops.append(allocator, .{ .kind = .CallProcedure });
    }

    if (q.create_pattern != null) {
        try ops.append(allocator, .{ .kind = .Create });
    }
    if (q.merge_statement != null) {
        try ops.append(allocator, .{ .kind = .Merge });
    }
    if (q.set_clauses.len != 0) {
        try ops.append(allocator, .{ .kind = .Set });
    }
    if (q.remove_clauses.len != 0) {
        try ops.append(allocator, .{ .kind = .Remove });
    }
    if (q.delete_items.len != 0) {
        try ops.append(allocator, .{ .kind = .Delete });
    }

    if (q.with_clause) |with_clause| {
        try ops.append(allocator, .{
            .kind = if (q.group_by != null or hasAggregationItems(with_clause.items)) .Aggregate else .Project,
        });
        if (with_clause.distinct) {
            try ops.append(allocator, .{ .kind = .Distinct });
        }
        if (with_clause.order_by != null) {
            try ops.append(allocator, .{ .kind = .Sort });
        }
        if (with_clause.limit != null or with_clause.offset != null or with_clause.limit_param != null or with_clause.offset_param != null) {
            try ops.append(allocator, .{ .kind = .Limit });
        }
        if (q.where_clause != null) {
            try ops.append(allocator, .{ .kind = .Filter });
        }
    }

    if (needsFinalProjection(q)) {
        try ops.append(allocator, .{
            .kind = if ((q.with_clause == null and q.group_by != null) or hasAggregationItems(q.ret.items)) .Aggregate else .Project,
        });
        if (q.ret.distinct) {
            try ops.append(allocator, .{ .kind = .Distinct });
        }
        if (q.order_by != null) {
            try ops.append(allocator, .{ .kind = .Sort });
        }
        if (q.limit != null or q.offset != null or q.limit_param != null or q.offset_param != null) {
            try ops.append(allocator, .{ .kind = .Limit });
        }
    }

    if (q.next_query != null or q.for_statement != null) {
        try ops.append(allocator, .{ .kind = .QueryChain });
    }
    if (q.next_query) |next_query| {
        try appendLegacyPlanOps(allocator, ops, next_query);
    }

    try ops.append(allocator, .{ .kind = .LegacyExecute });
}

fn isStorageNativeQuery(q: *const ast.Query) bool {
    if (q.next_query != null or q.optional_match) return false;
    if (q.unwind_clause != null or q.create_pattern != null) return false;
    if (q.call_clause != null or q.initial_call_subquery != null or q.merge_statement != null) return false;
    if (q.path_variable != null or q.has_recursive_cte) return false;
    if (q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.delete_items.len != 0) return false;
    if (q.match.chains.len > 1) return false;
    if (q.match.chains.len == 0) return true;

    const chain = q.match.chains[0];
    if (chain.is_optional or chain.is_shortest or chain.path_mode != .walk) return false;
    if (chain.head != null and chain.hops.len > 0) return false;

    var names: [32][]const u8 = undefined;
    var name_count: usize = 0;
    const root = if (chain.head) |head| head else chain.hops[0].left;
    if (root.name) |name| {
        if (name_count >= names.len) return false;
        names[name_count] = name;
        name_count += 1;
    }

    for (chain.hops, 0..) |hop, hop_idx| {
        if (hop.rel.min_len != null or hop.rel.max_len != null) return false;
        if (hop_idx != 0) {
            if (hop.left.name) |name| {
                if (containsName(names[0..name_count], name)) return false;
                if (name_count >= names.len) return false;
                names[name_count] = name;
                name_count += 1;
            }
        }
        if (hop.rel.name) |name| {
            if (containsName(names[0..name_count], name)) return false;
            if (name_count >= names.len) return false;
            names[name_count] = name;
            name_count += 1;
        }
        if (hop.right.name) |name| {
            if (containsName(names[0..name_count], name)) return false;
            if (name_count >= names.len) return false;
            names[name_count] = name;
            name_count += 1;
        }
    }

    return true;
}

fn containsName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}
