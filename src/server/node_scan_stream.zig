const std = @import("std");
const schema = @import("schema");
const gs = @import("graph_storage");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const execution = @import("../execution.zig");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const value_types = @import("../value_types.zig");
const result_utils = @import("../execution/result_utils.zig");
const type_helpers = @import("../eval/type_helpers.zig");

const ExecutionContext = execution.ExecutionContext;
const ExecutionResult = execution.ExecutionResult;
const OwnedGraphEntities = execution.OwnedGraphEntities;
const Value = value_types.Value;
const Env = value_types.Env;

pub const default_inline_rows: usize = 64;
pub const default_page_rows: usize = 128;

/// Test-observability counter: total nodes materialized by the streaming
/// path (lazy per-page `materializeNode`). Bounded scans materialize
/// O(result); count(label) materializes ZERO (served from the label index).
var g_nodes_materialized_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn resetNodesMaterializedTotal() void {
    g_nodes_materialized_total.store(0, .monotonic);
}

pub fn getNodesMaterializedTotal() u64 {
    return g_nodes_materialized_total.load(.monotonic);
}

/// What the stream projects per matched node.
///   - .node     → a single bare-variable column (`RETURN n`)
///   - .projection→ one or more projected expressions (`RETURN n.a, n.b AS x`)
///   - .count     → a single aggregate row (`RETURN count(n)`), O(1) when
///                  unfiltered, O(scanned) when a predicate is present
const ProjectionMode = enum { node, projection, count };

pub const NodeScanStream = struct {
    allocator: std.mem.Allocator,
    /// Arena holding all stream-lifetime metadata that must outlive the
    /// request that produced it (the stream is stored on the session for
    /// subsequent PULL pages).  The cloned RETURN items, WHERE expression,
    /// parameter bindings, and the variable name all live here.
    arena: *std.heap.ArenaAllocator,
    graph_name: []const u8,
    /// The single output column name for the bare-node / count shapes; for
    /// projections the names come from `columns`.
    column_name: []const u8,
    /// Variable bound to the scanned node (e.g. "n").  Used to build the
    /// per-row evaluation environment so `eval.evalExpr` resolves `n` and
    /// `n.prop` exactly as the snapshot executor does.
    var_name: []const u8,
    slot_ids: []u64,
    next_index: usize = 0,
    flags: [][]const u8,

    mode: ProjectionMode,
    /// Cloned RETURN items (projection mode only); evaluated per matched node
    /// with `eval.evalExpr` against the materialized node's environment.
    ret_items: []ast.ReturnItem = &.{},
    /// Pre-computed output column names (projection mode), identical to the
    /// snapshot executor's `generateUniqueColumnNames`.
    columns: [][]const u8 = &.{},
    /// Optional WHERE / FILTER predicate evaluated per matched node.  When
    /// present, non-matching nodes are skipped (LIMIT applies to matched rows).
    where_expr: ?ast.Expr = null,
    /// Cap on total MATCHED rows emitted across all pages. When a WHERE
    /// predicate is present, LIMIT applies to matched rows (not scanned
    /// slots), so the slot list is collected unbounded and this cap enforces
    /// LIMIT during paging. `maxInt` means no cap.
    row_limit: usize = std.math.maxInt(usize),
    rows_emitted: usize = 0,
    /// OFFSET over MATCHED rows (used only with a WHERE predicate; without a
    /// predicate, OFFSET is applied at the slot level via `next_index`).
    row_offset: usize = 0,
    rows_skipped: usize = 0,
    /// Cloned parameter bindings (stream-lifetime), used by predicate /
    /// projection evaluation for `$param` references.
    param_names: [][]const u8 = &.{},
    param_values: []Value = &.{},
    exec_context: ExecutionContext,

    /// count mode: O(1) precomputed cardinality (unfiltered count).  When a
    /// predicate is present this is unused and the count is streamed.
    count_precomputed: ?usize = null,
    count_emitted: bool = false,

    // Scratch storage for the single-binding environment so makeEnv hands out
    // stable slices. Reset per call; the stream is single-threaded per page.
    env_names: [1][]const u8 = .{""},
    env_value: [1]Value = .{.{ .Null = {} }},

    pub fn deinit(self: *NodeScanStream) void {
        self.allocator.free(self.slot_ids);
        for (self.flags) |flag| {
            self.allocator.free(flag);
        }
        self.allocator.free(self.flags);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn hasRemaining(self: *const NodeScanStream) bool {
        if (self.mode == .count) return !self.count_emitted;
        return self.next_index < self.slot_ids.len and self.rows_emitted < self.row_limit;
    }

    pub fn buildSchema(self: *const NodeScanStream, allocator: std.mem.Allocator) !schema.SchemaDefinition {
        switch (self.mode) {
            .node => {
                var cols = try std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, 1);
                try cols.append(allocator, .{
                    .name = try allocator.dupe(u8, self.column_name),
                    .type = try allocator.dupe(u8, "NODE"),
                });
                return .{ .columns = cols };
            },
            .count => {
                var cols = try std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, 1);
                try cols.append(allocator, .{
                    .name = try allocator.dupe(u8, self.column_name),
                    .type = try allocator.dupe(u8, "INTEGER"),
                });
                return .{ .columns = cols };
            },
            .projection => {
                var cols = try std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, self.columns.len);
                for (self.columns) |name| {
                    try cols.append(allocator, .{
                        .name = try allocator.dupe(u8, name),
                        // Projection element types are value-dependent; the
                        // authoritative per-value type rides on each DataPage
                        // Value. The snapshot path infers a placeholder column
                        // type from the first rows (NULL when unknown). We emit
                        // NULL here so transport schema matches the snapshot
                        // path's "unknown until first row" contract.
                        .type = try allocator.dupe(u8, "NULL"),
                    });
                }
                return .{ .columns = cols };
            },
        }
    }

    pub const Page = struct {
        result: ExecutionResult,
        final: bool,
    };

    pub fn buildNextPage(self: *NodeScanStream, allocator: std.mem.Allocator, page_size: usize) !Page {
        if (self.mode == .count) return self.buildCountPage(allocator);

        const page_len = if (page_size == 0) default_page_rows else page_size;
        if (self.next_index >= self.slot_ids.len or self.rows_emitted >= self.row_limit) {
            return .{
                .result = try self.emptyResult(allocator),
                .final = true,
            };
        }

        var rows = try std.ArrayList([]Value).initCapacity(allocator, @min(page_len, 256));
        errdefer {
            for (rows.items) |row| {
                for (row) |val| execution.freeValue(allocator, val);
                allocator.free(row);
            }
            rows.deinit(allocator);
        }

        var owned_entities = try OwnedGraphEntities.init(allocator);
        errdefer owned_entities.deinit();

        // Fill the page up to `page_len` MATCHED rows. With a predicate this
        // may scan more slots than rows produced (O(scanned)); LIMIT still
        // bounds the matched rows via `slot_ids` when no predicate is present,
        // and via early-termination here when a predicate is.
        while (rows.items.len < page_len and self.next_index < self.slot_ids.len and self.rows_emitted < self.row_limit) {
            const slot_id = self.slot_ids[self.next_index];
            self.next_index += 1;

            // Skip nodes that vanished due to concurrent modification (e.g.
            // active ingest adding/removing nodes). This avoids failing the
            // entire page when a single slot becomes stale.
            const node = materializeNode(allocator, self.graph_name, slot_id) catch continue;
            var node_tracked = false;
            errdefer if (!node_tracked) destroyNode(allocator, node);

            if (self.where_expr) |where_expr| {
                const passes = self.evalPredicate(allocator, where_expr, node) catch false;
                if (!passes) {
                    destroyNode(allocator, node);
                    continue;
                }
                // OFFSET over matched rows (predicate path only).
                if (self.rows_skipped < self.row_offset) {
                    self.rows_skipped += 1;
                    destroyNode(allocator, node);
                    continue;
                }
            }

            const row = try self.buildRow(allocator, node, owned_entities, &node_tracked);
            try rows.append(allocator, row);
            self.rows_emitted += 1;
        }

        const result = try self.finishResult(allocator, rows, owned_entities);
        return .{
            .result = result,
            .final = self.next_index >= self.slot_ids.len or self.rows_emitted >= self.row_limit,
        };
    }

    fn buildRow(
        self: *NodeScanStream,
        allocator: std.mem.Allocator,
        node: *graph_store.Node,
        owned_entities: *OwnedGraphEntities,
        node_tracked: *bool,
    ) ![]Value {
        switch (self.mode) {
            .node => {
                try owned_entities.trackNode(node);
                node_tracked.* = true;
                const row = try allocator.alloc(Value, 1);
                row[0] = .{ .Node = node };
                return row;
            },
            .projection => {
                const env = self.makeEnv(allocator, node);
                const row = try allocator.alloc(Value, self.ret_items.len);
                // Track how many entries are initialized so a mid-loop error
                // only frees real values (never uninitialized slots). The node
                // is still owned by the caller's `node_tracked` errdefer on the
                // error path, so we don't free it here.
                var produced: usize = 0;
                errdefer {
                    for (row[0..produced]) |val| execution.freeValue(allocator, val);
                    allocator.free(row);
                }
                var produced_node_value = false;
                for (self.ret_items, 0..) |item, i| {
                    row[i] = try eval.evalExpr(allocator, item.expr, env);
                    produced = i + 1;
                    if (row[i] == .Node) produced_node_value = true;
                }
                // If any projected column is the bare node itself, the node
                // must be kept alive for the lifetime of the page; track it.
                if (produced_node_value) {
                    try owned_entities.trackNode(node);
                    node_tracked.* = true;
                } else {
                    // No reference to the node escapes the row; free it now.
                    destroyNode(allocator, node);
                    node_tracked.* = true;
                }
                return row;
            },
            .count => unreachable,
        }
    }

    fn finishResult(
        self: *NodeScanStream,
        allocator: std.mem.Allocator,
        rows: std.ArrayList([]Value),
        owned_entities: *OwnedGraphEntities,
    ) !ExecutionResult {
        var rows_mut = rows;
        const columns = try self.buildColumns(allocator);
        const owned = owned_entities.nodes.items.len > 0 or owned_entities.edges.items.len > 0;
        const result = ExecutionResult{
            .columns = columns,
            .rows = try rows_mut.toOwnedSlice(allocator),
            .flags = std.ArrayList([]const u8).empty,
            // Projection rows own their scalar values (strings duplicated by
            // evalExpr); freeValue is a no-op for .Node, which is owned by
            // owned_graph_entities — so no double free for mixed rows.
            .owns_value_memory = self.mode == .projection,
            .owned_graph_entities = if (owned) owned_entities else null,
        };
        if (!owned) owned_entities.deinit();
        return result;
    }

    fn emptyResult(self: *NodeScanStream, allocator: std.mem.Allocator) !ExecutionResult {
        const columns = try self.buildColumns(allocator);
        return .{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
            .owns_value_memory = self.mode == .projection,
        };
    }

    fn buildColumns(self: *NodeScanStream, allocator: std.mem.Allocator) ![][]const u8 {
        switch (self.mode) {
            .node, .count => {
                var columns = try allocator.alloc([]const u8, 1);
                errdefer allocator.free(columns);
                columns[0] = try allocator.dupe(u8, self.column_name);
                return columns;
            },
            .projection => {
                var columns = try allocator.alloc([]const u8, self.columns.len);
                errdefer {
                    for (columns, 0..) |c, i| {
                        if (i < self.columns.len) allocator.free(c);
                    }
                    allocator.free(columns);
                }
                for (self.columns, 0..) |name, i| {
                    columns[i] = try allocator.dupe(u8, name);
                }
                return columns;
            },
        }
    }

    fn buildCountPage(self: *NodeScanStream, allocator: std.mem.Allocator) !Page {
        if (self.count_emitted) {
            var columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, self.column_name);
            return .{
                .result = .{
                    .columns = columns,
                    .rows = try allocator.alloc([]Value, 0),
                    .flags = std.ArrayList([]const u8).empty,
                },
                .final = true,
            };
        }

        const n: usize = if (self.count_precomputed) |c| c else blk: {
            // Filtered count: stream the label posting, materialize each node,
            // evaluate the predicate, and tally matches. O(scanned), no clone.
            var matched: usize = 0;
            const where_expr = self.where_expr.?;
            for (self.slot_ids) |slot_id| {
                const node = materializeNode(allocator, self.graph_name, slot_id) catch continue;
                defer destroyNode(allocator, node);
                const passes = self.evalPredicate(allocator, where_expr, node) catch false;
                if (passes) matched += 1;
            }
            break :blk matched;
        };

        self.count_emitted = true;

        var columns = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(columns);
        columns[0] = try allocator.dupe(u8, self.column_name);

        var row = try allocator.alloc(Value, 1);
        errdefer allocator.free(row);
        row[0] = Value{ .Int = @intCast(n) };

        var rows = try allocator.alloc([]Value, 1);
        rows[0] = row;

        return .{
            .result = .{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            },
            .final = true,
        };
    }

    fn makeEnv(self: *NodeScanStream, allocator: std.mem.Allocator, node: *graph_store.Node) Env {
        return Env{
            .names = self.env_names[0..1],
            .values = blk: {
                self.env_value[0] = .{ .Node = node };
                break :blk self.env_value[0..1];
            },
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = allocator,
            .exec_context = @ptrCast(@constCast(&self.exec_context)),
        };
    }

    fn evalPredicate(self: *NodeScanStream, allocator: std.mem.Allocator, where_expr: ast.Expr, node: *graph_store.Node) !bool {
        const env = self.makeEnv(allocator, node);
        const where_result = try eval.evalExpr(allocator, where_expr, env);
        // Match the snapshot executor's label-scan WHERE coercion exactly
        // (match_operations.zig generateCombinations): Bool→value, Null→false,
        // Int→nonzero, else→false.
        return switch (where_result) {
            .Bool => |b| b,
            .Null => false,
            .Int => |i| i != 0,
            else => false,
        };
    }
};

fn destroyNode(allocator: std.mem.Allocator, node: *graph_store.Node) void {
    node.properties.deinit();
    allocator.free(node.graph_name);
    for (node.labels) |label| allocator.free(label);
    allocator.free(node.labels);
    allocator.destroy(node);
}

const Eligibility = struct {
    pattern: ast.NodePattern,
    column_name: []const u8,
    mode: ProjectionMode,
};

// CANARY: REQ=REQ-PERF-UNORDERED-STREAM-001; FEATURE="UnorderedNodeScanStreaming"; ASPECT=TransportFastPath; STATUS=IMPL; OWNER=engine; UPDATED=2026-06-19
pub fn prepare(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    flags: []const []const u8,
) !?NodeScanStream {
    const eligibility = eligibleQuery(q) orelse return null;
    const variable_name = eligibility.pattern.name orelse return null;

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const graph_name = try aa.dupe(u8, resolveGraphName(context));
    const var_name = try aa.dupe(u8, variable_name);

    // Clone parameter bindings into the stream arena so PULL pages can
    // re-evaluate predicates/projections after the request scope ends.
    var owned_param_names = try aa.alloc([]const u8, param_names.len);
    for (param_names, 0..) |name, i| owned_param_names[i] = try aa.dupe(u8, name);
    var owned_param_values = try aa.alloc(Value, param_values.len);
    for (param_values, 0..) |val, i| owned_param_values[i] = try cloneValue(aa, val);

    // Clone the WHERE / FILTER predicate (eligible subset only) into the
    // arena. An un-cloneable shape means we cannot stream correctly: bail to
    // the snapshot path (return null) rather than risk wrong results.
    var where_expr: ?ast.Expr = null;
    if (q.where_clause orelse q.filter_clause) |w| {
        where_expr = cloneExpr(aa, w) catch return null;
    }

    // count mode: O(1) cardinality from the label index when unfiltered.
    var count_precomputed: ?usize = null;
    if (eligibility.mode == .count and where_expr == null) {
        if (graph_store.getGlobalAdapter()) |adapter| {
            if (eligibility.pattern.labels.len == 1) {
                count_precomputed = @intCast(adapter.countNodesByLabel(graph_name, eligibility.pattern.labels[0]) catch return null);
            } else {
                // Unlabeled count: fall back to scanning live nodes (no clone).
                const entries = adapter.scanAllNodes(graph_name, aa) catch return null;
                count_precomputed = entries.len;
            }
        } else return null;
    }

    // Clone RETURN items (projection mode) into the arena.
    var ret_items: []ast.ReturnItem = &.{};
    var columns: [][]const u8 = &.{};
    if (eligibility.mode == .projection) {
        ret_items = cloneReturnItems(aa, q.ret.items) catch return null;
        columns = try result_utils.generateUniqueColumnNames(aa, ret_items);
    }

    // For count mode we never page node slots; for node/projection we collect
    // matching slot ids. When NO WHERE predicate is present, slot-level
    // matches equal row-level matches (inline `{prop:val}` filters are applied
    // during slot collection), so LIMIT/OFFSET are applied at the slot level
    // for early termination. When a WHERE predicate IS present, it is evaluated
    // per node during paging, so LIMIT/OFFSET must apply to MATCHED rows: the
    // slot list is collected unbounded and the row_limit/row_offset enforce the
    // window over matched rows.
    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    const limit = resolveWindowValue(q.limit, q.limit_param, param_names, param_values);

    var slot_ids: []u64 = &.{};
    var start_index: usize = 0;
    var row_limit: usize = std.math.maxInt(usize);
    var row_offset: usize = 0;

    if (eligibility.mode == .count and where_expr == null) {
        // O(1) count: no slots needed.
    } else if (where_expr != null) {
        // Predicate-filtered: collect every pattern-matching slot (unbounded);
        // LIMIT/OFFSET apply to matched rows.
        slot_ids = try collectMatchingSlotIds(allocator, graph_name, eligibility.pattern, null, owned_param_names, owned_param_values, context);
        if (eligibility.mode != .count) {
            row_offset = offset;
            if (limit) |l| row_limit = l;
        }
    } else {
        // No predicate: matched == scanned, so bound slot collection by
        // OFFSET+LIMIT and start paging at OFFSET.
        const required = resolveRequiredRows(q, param_names, param_values);
        slot_ids = try collectMatchingSlotIds(allocator, graph_name, eligibility.pattern, required, owned_param_names, owned_param_values, context);
        start_index = @min(offset, slot_ids.len);
    }
    errdefer if (slot_ids.len > 0) allocator.free(slot_ids);

    var owned_flags = try allocator.alloc([]const u8, flags.len);
    errdefer {
        for (owned_flags[0..flags.len]) |flag| {
            if (flag.len > 0) allocator.free(flag);
        }
        allocator.free(owned_flags);
    }
    for (owned_flags) |*flag| flag.* = "";
    for (flags, 0..) |flag, i| {
        owned_flags[i] = try allocator.dupe(u8, flag);
    }

    return NodeScanStream{
        .allocator = allocator,
        .arena = arena,
        .graph_name = graph_name,
        .column_name = eligibility.column_name,
        .var_name = var_name,
        .slot_ids = slot_ids,
        .next_index = start_index,
        .flags = owned_flags,
        .mode = eligibility.mode,
        .ret_items = ret_items,
        .columns = columns,
        .where_expr = where_expr,
        .row_limit = row_limit,
        .row_offset = row_offset,
        .param_names = owned_param_names,
        .param_values = owned_param_values,
        .exec_context = context,
        .count_precomputed = count_precomputed,
        .env_names = .{var_name},
    };
}

/// GAP-0900 (scan-no-clone): pure-AST predicate — true iff `prepare` would
/// handle this query through the engine-backed streaming path. Broadened
/// (2026-06) to cover property projections, simple WHERE / inline-property
/// filters on the scanned variable, and `count(n)` over a label — all served
/// in O(result)/O(scanned) with no whole-graph clone. The transport handlers
/// use this to skip the O(graph) `QueryReadSession` deep-clone for shapes the
/// streaming path serves engine-side. It does no I/O and inspects only the
/// parsed query, so it is safe to call before acquiring any lock.
pub fn isEligible(q: *const ast.Query) bool {
    return eligibleQuery(q) != null;
}

fn eligibleQuery(q: *const ast.Query) ?Eligibility {
    if (q.optional_match) return null;
    if (q.with_clause != null or q.group_by != null or q.having != null) return null;
    if (q.order_by != null or q.ret.distinct) return null;
    if (q.inline_let_bindings.len != 0) return null;
    if (q.unwind_clause != null or q.create_pattern != null) return null;
    if (q.call_clause != null or q.initial_call_subquery != null) return null;
    if (q.merge_statement != null or q.next_query != null or q.for_statement != null) return null;
    if (q.path_variable != null or q.has_recursive_cte or q.cte_list != null) return null;
    if (q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.delete_items.len != 0) return null;
    if (q.match.chains.len != 1) return null;

    const chain = q.match.chains[0];
    if (chain.is_optional or chain.is_shortest or chain.path_mode != .walk) return null;
    if (chain.head == null or chain.hops.len != 0) return null;

    const head = chain.head.?;
    const variable_name = head.name orelse return null;

    // Inline property patterns (`{prop: val}`) are evaluated as equality
    // filters in collectMatchingSlotIds; only accept ones whose values are
    // streamable literals/params (no variable references / subqueries).
    if (head.props) |props| {
        for (props) |prop| {
            if (!isStreamablePredicateExpr(prop.value.*)) return null;
        }
    }

    // WHERE / FILTER must be a streamable predicate over the scanned variable.
    if (q.where_clause orelse q.filter_clause) |w| {
        if (!isStreamablePredicateExpr(w)) return null;
        if (!predicateOnlyReferences(w, variable_name)) return null;
    }

    // No RETURN items → bare-variable scan.
    if (q.ret.items.len == 0) {
        return .{ .pattern = head, .column_name = variable_name, .mode = .node };
    }

    // Single `count(n)` / `count(*)` aggregate.
    if (q.ret.items.len == 1) {
        if (countColumn(q.ret.items[0], variable_name)) |col| {
            return .{ .pattern = head, .column_name = col, .mode = .count };
        }
    }

    // Otherwise: a projection of one or more streamable expressions over the
    // scanned variable. Each item must reference only `n` (and params/literals)
    // and must NOT be an aggregate (those need grouping the stream can't do).
    for (q.ret.items) |item| {
        if (isAggregateCall(item.expr)) return null;
        if (!isStreamableProjectionExpr(item.expr, variable_name)) return null;
    }

    // A single bare-variable RETURN is the node shape (preserves the existing
    // column-name behavior: alias orelse ident.orig).
    if (q.ret.items.len == 1) {
        switch (q.ret.items[0].expr) {
            .Ident => |ident| {
                if (std.ascii.eqlIgnoreCase(ident.orig, variable_name) or std.ascii.eqlIgnoreCase(ident.cnf, variable_name)) {
                    return .{
                        .pattern = head,
                        .column_name = q.ret.items[0].alias orelse ident.orig,
                        .mode = .node,
                    };
                }
            },
            else => {},
        }
    }

    return .{ .pattern = head, .column_name = variable_name, .mode = .projection };
}

/// `count(n)` or `count(*)` (case-insensitive), no other args — returns the
/// output column name (alias orelse "count").
fn countColumn(item: ast.ReturnItem, variable_name: []const u8) ?[]const u8 {
    const call = switch (item.expr) {
        .Call => |c| c,
        else => return null,
    };
    if (call.callee.* != .Ident) return null;
    if (!std.ascii.eqlIgnoreCase(call.callee.Ident.orig, "count")) return null;
    if (call.args.len != 1) return null;
    const arg = call.args[0].*;
    const ok = switch (arg) {
        .Ident => |id| std.mem.eql(u8, id.orig, "*") or
            std.ascii.eqlIgnoreCase(id.orig, variable_name) or
            std.ascii.eqlIgnoreCase(id.cnf, variable_name),
        else => false,
    };
    if (!ok) return null;
    return item.alias orelse "count";
}

fn isAggregateCall(expr: ast.Expr) bool {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const f = call.callee.Ident.orig;
                return std.ascii.eqlIgnoreCase(f, "count") or
                    std.ascii.eqlIgnoreCase(f, "sum") or
                    std.ascii.eqlIgnoreCase(f, "avg") or
                    std.ascii.eqlIgnoreCase(f, "min") or
                    std.ascii.eqlIgnoreCase(f, "max") or
                    std.ascii.eqlIgnoreCase(f, "collect") or
                    std.ascii.eqlIgnoreCase(f, "countDistinct");
            }
            return false;
        },
        else => return false,
    }
}

/// A RETURN item the stream can project: the bare variable, a property access
/// on it, or a literal. Anything that needs cross-row context (subqueries,
/// pattern comprehensions, other variables, function calls) is rejected.
fn isStreamableProjectionExpr(expr: ast.Expr, variable_name: []const u8) bool {
    return switch (expr) {
        .Ident => |id| std.ascii.eqlIgnoreCase(id.orig, variable_name) or std.ascii.eqlIgnoreCase(id.cnf, variable_name),
        .PropertyAccess => |pa| std.ascii.eqlIgnoreCase(pa.object, variable_name),
        .Member => |m| m.target.* == .Ident and
            (std.ascii.eqlIgnoreCase(m.target.Ident.orig, variable_name) or std.ascii.eqlIgnoreCase(m.target.Ident.cnf, variable_name)),
        else => false,
    };
}

/// A predicate expression the stream can evaluate per node: comparisons and
/// AND/OR/NOT over property accesses on the scanned variable and literals/
/// params. Rejects anything referencing other variables or needing cross-row
/// context, so the per-node `eval.evalExpr` is guaranteed identical to the
/// snapshot executor's per-node evaluation.
fn isStreamablePredicateExpr(expr: ast.Expr) bool {
    return switch (expr) {
        .Bool, .Int, .Null, .String, .Decimal, .Param => true,
        .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .TextLit => true,
        .Ident, .PropertyAccess => true,
        .Member => |m| isStreamablePredicateExpr(m.target.*),
        .Unary => |u| u.op == .Not and isStreamablePredicateExpr(u.expr.*),
        .Binary => |b| switch (b.op) {
            .And, .Or, .Eq, .Ne, .Lt, .Le, .Gt, .Ge => isStreamablePredicateExpr(b.left.*) and isStreamablePredicateExpr(b.right.*),
            else => false,
        },
        .IsNull => |n| isStreamablePredicateExpr(n.target.*),
        else => false,
    };
}

/// Every Ident / property-access target inside the predicate references only
/// the scanned variable (or a parameter). Guards against `WHERE m.x = 1`
/// where `m` is some other (unbound here) variable.
fn predicateOnlyReferences(expr: ast.Expr, variable_name: []const u8) bool {
    return switch (expr) {
        .Bool, .Int, .Null, .String, .Decimal, .Param => true,
        .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .TextLit => true,
        // A bare Ident in a predicate position resolves via Env.get; in the
        // scan it can only legitimately be the scanned variable or a param
        // (param fallback in Env.get). Restrict to the variable name to be safe.
        .Ident => |id| std.ascii.eqlIgnoreCase(id.orig, variable_name) or std.ascii.eqlIgnoreCase(id.cnf, variable_name),
        .PropertyAccess => |pa| std.ascii.eqlIgnoreCase(pa.object, variable_name),
        .Member => |m| predicateOnlyReferences(m.target.*, variable_name),
        .Unary => |u| predicateOnlyReferences(u.expr.*, variable_name),
        .Binary => |b| predicateOnlyReferences(b.left.*, variable_name) and predicateOnlyReferences(b.right.*, variable_name),
        .IsNull => |n| predicateOnlyReferences(n.target.*, variable_name),
        else => false,
    };
}

fn resolveGraphName(context: ExecutionContext) []const u8 {
    if (context.session_state) |session| {
        if (session.graph) |graph_name| return graph_name;
    }
    return graph_store.DEFAULT_GRAPH_NAME;
}

fn resolveRequiredRows(
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
                .Int => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                .SmallInt => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                .BigInt => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                else => null,
            };
        }
    }
    return null;
}

fn collectMatchingSlotIds(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    required_rows: ?usize,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) ![]u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return try allocator.alloc(u64, 0);
    if (!adapter.graphExists(graph_name)) {
        return try allocator.alloc(u64, 0);
    }

    const row_cap = required_rows orelse std.math.maxInt(usize);
    var result = try std.ArrayList(u64).initCapacity(allocator, if (required_rows) |cap| @min(cap, 1024) else 256);
    errdefer result.deinit(allocator);

    if (pattern.labels.len > 0) {
        if (try adapter.iterateNodesByLabel(graph_name, pattern.labels[0], allocator)) |label_iter_init| {
            var label_iter = label_iter_init;
            defer label_iter.deinit();

            while (try label_iter.next()) |slot_id| {
                if (!try nodeMatchesPattern(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context)) continue;
                try result.append(allocator, slot_id);
                if (result.items.len >= row_cap) break;
            }
        }
    } else {
        const entries = try adapter.scanAllNodes(graph_name, allocator);
        defer allocator.free(entries);

        for (entries) |entry| {
            if (!try nodeMatchesPattern(allocator, adapter, graph_name, entry.slot_id, pattern, param_names, param_values, context)) continue;
            try result.append(allocator, entry.slot_id);
            if (result.items.len >= row_cap) break;
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn nodeMatchesPattern(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    if (pattern.labels.len > 0 or pattern.props != null) {
        const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
        defer {
            for (labels) |label| allocator.free(label);
            allocator.free(labels);
        }
        if (!labelsContainAll(labels, pattern.labels)) {
            return false;
        }
    }

    if (pattern.props == null) return true;

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    for (pattern.props.?) |prop| {
        const expected = eval.evalExpr(allocator, prop.value.*, env) catch return false;
        const actual = props.get(prop.key) orelse return false;
        if (!storagePropertyMatches(expected, actual)) {
            return false;
        }
    }
    return true;
}

fn materializeNode(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64) !*graph_store.Node {
    _ = g_nodes_materialized_total.fetchAdd(1, .monotonic);
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
        .properties = graph_store.CompactPropertyMap.init(allocator),
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

fn storagePropertyMatches(expected: Value, actual: gs.PropertyValue) bool {
    return switch (actual) {
        .string => |text| switch (expected) {
            .Str => |expected_text| std.mem.eql(u8, expected_text, text),
            .Text => |expected_text| std.mem.eql(u8, expected_text, text),
            .Varchar => |expected_text| std.mem.eql(u8, expected_text.data, text),
            .Char => |expected_text| std.mem.eql(u8, expected_text.data, text),
            else => false,
        },
        .int => |number| switch (expected) {
            .Int => |expected_number| expected_number == number,
            .SmallInt => |expected_number| expected_number == number,
            .BigInt => |expected_number| expected_number == number,
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
            .Real => |expected_float| expected_float == float_value,
            .Double => |expected_float| expected_float == float_value,
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

// ===========================================================================
// Focused AST / Value cloning into the stream arena.
//
// Only the eligible-subset expression kinds are clonable; anything else
// returns error.Unsupported so `prepare` bails to the snapshot path. This
// keeps the clone bounded and guarantees we never stream a shape we cannot
// evaluate identically.
// ===========================================================================

const CloneError = error{ OutOfMemory, Unsupported };

fn cloneReturnItems(arena: std.mem.Allocator, items: []const ast.ReturnItem) CloneError![]ast.ReturnItem {
    const out = try arena.alloc(ast.ReturnItem, items.len);
    for (items, 0..) |item, i| {
        out[i] = .{
            .expr = try cloneExpr(arena, item.expr),
            .alias = if (item.alias) |a| try arena.dupe(u8, a) else null,
        };
    }
    return out;
}

fn cloneExprPtr(arena: std.mem.Allocator, e: *const ast.Expr) CloneError!*ast.Expr {
    const p = try arena.create(ast.Expr);
    p.* = try cloneExpr(arena, e.*);
    return p;
}

fn cloneIdent(arena: std.mem.Allocator, id: ast.IdentRepr) CloneError!ast.IdentRepr {
    return .{ .orig = try arena.dupe(u8, id.orig), .cnf = try arena.dupe(u8, id.cnf) };
}

fn cloneExpr(arena: std.mem.Allocator, e: ast.Expr) CloneError!ast.Expr {
    return switch (e) {
        .Null => .Null,
        .Int => |n| .{ .Int = n },
        .Bool => |b| .{ .Bool = b },
        .String => |s| .{ .String = try arena.dupe(u8, s) },
        .TextLit => |s| .{ .TextLit = try arena.dupe(u8, s) },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .SmallIntLit => |v| .{ .SmallIntLit = v },
        .BigIntLit => |v| .{ .BigIntLit = v },
        .RealLit => |v| .{ .RealLit = v },
        .DoubleLit => |v| .{ .DoubleLit = v },
        .Param => |p| .{ .Param = try arena.dupe(u8, p) },
        .Ident => |id| .{ .Ident = try cloneIdent(arena, id) },
        .PropertyAccess => |pa| .{ .PropertyAccess = .{
            .object = try arena.dupe(u8, pa.object),
            .property = try arena.dupe(u8, pa.property),
        } },
        .Member => |m| .{ .Member = .{
            .target = try cloneExprPtr(arena, m.target),
            .field = try arena.dupe(u8, m.field),
        } },
        .Unary => |u| .{ .Unary = .{
            .op = u.op,
            .expr = try cloneExprPtr(arena, u.expr),
        } },
        .Binary => |b| .{ .Binary = .{
            .op = b.op,
            .left = try cloneExprPtr(arena, b.left),
            .right = try cloneExprPtr(arena, b.right),
        } },
        .IsNull => |n| .{ .IsNull = .{
            .target = try cloneExprPtr(arena, n.target),
            .negated = n.negated,
        } },
        .Call => |c| blk: {
            const callee = try cloneExprPtr(arena, c.callee);
            const args = try arena.alloc(*ast.Expr, c.args.len);
            for (c.args, 0..) |arg, i| args[i] = try cloneExprPtr(arena, arg);
            break :blk .{ .Call = .{ .callee = callee, .args = args } };
        },
        else => return CloneError.Unsupported,
    };
}

fn cloneValue(arena: std.mem.Allocator, v: Value) CloneError!Value {
    return switch (v) {
        .Str => |s| .{ .Str = try arena.dupe(u8, s) },
        .Text => |s| .{ .Text = try arena.dupe(u8, s) },
        // Scalars and other shallow values copy by value; complex reference
        // types (Node/Edge/List/Map/Path) are not valid bound parameters for
        // a streamed scan predicate — but if present they are shared, not
        // owned, so a shallow copy is the same semantics the executor sees.
        else => v,
    };
}
