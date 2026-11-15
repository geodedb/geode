//! SONNY-3184, SONNY-6337: OPTIONAL MATCH as ISO/IEC 39075 defines it, a left
//! outer join of each incoming record with the matches of the optional
//! pattern.
//!
//! A part's MATCH and OPTIONAL MATCH clauses (`ast.Query.match_clauses`) are
//! joined left to right, starting from one empty record (or, in a chained
//! part, the record the part before it passes on, which arrives as
//! parameters). For each record, the clause's pattern is matched with the
//! record's variables bound (`match_operations.readPatternRows` with them as
//! parameters: a variable the pattern names again is joined to its element,
//! SONNY-3046), and the clause's own WHERE applied to each candidate. A
//! MATCH keeps the record once per surviving match and drops it when there is
//! none; an OPTIONAL MATCH keeps it once with the clause's new variables NULL.
//! A pattern that names a variable bound to NULL (a variable an earlier
//! OPTIONAL MATCH left unbound) matches nothing. Every node and relationship a
//! clause reaches passes the session's graph, tenant and RLS scope as in any
//! MATCH (a hidden element is no match, so the record keeps NULL), and an
//! error in a clause's pattern or WHERE surfaces.
//!
//! The executor that used to answer these (`executeMatchWithOptionalPatterns`)
//! applied the clause's WHERE to the whole row (`MATCH (q) OPTIONAL MATCH
//! (q)-[:S]->(t) WHERE t.k > 1` dropped every q without such a t), bound only
//! the first hop of a chained OPTIONAL MATCH (the second's variables were
//! always NULL), and could not start from a variable a WITH bound.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const value_types = @import("../value_types.zig");
const execution = @import("../execution.zig");
const match_operations = @import("match_operations.zig");

const Value = value_types.Value;
const Env = value_types.Env;
const ExecutionResult = execution.ExecutionResult;

// CANARY: REQ=REQ-SONNY-3184-OPTIONAL-MATCH; FEATURE="OptionalMatchLeftOuterJoin"; ASPECT=Dispatch; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=engine; UPDATED=2026-11-11
/// Whether `q` has an OPTIONAL MATCH clause the parser recorded.
pub fn hasOptionalClause(q: ast.Query) bool {
    for (q.match_clauses) |clause| if (clause.optional) return true;
    return false;
}

fn appendNameOnce(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try names.append(allocator, name);
}

fn appendChainNames(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), chain: ast.Chain) !void {
    if (chain.head) |head| if (head.name) |n| try appendNameOnce(allocator, names, n);
    for (chain.hops) |hop| {
        for ([_]?[]const u8{ hop.left.name, hop.rel.name, hop.right.name }) |maybe| {
            if (maybe) |n| try appendNameOnce(allocator, names, n);
        }
    }
}

fn lookup(names: []const []const u8, values: []const Value, name: []const u8) ?Value {
    for (names, values) |n, v| if (std.mem.eql(u8, n, name)) return v;
    return null;
}

/// The element a parameter binds `name` to (the record a chained part
/// receives), or null.
fn boundElement(param_names: []const []const u8, param_values: []const Value, name: []const u8) ?Value {
    for (param_names, param_values) |n, v| {
        if (!std.mem.eql(u8, n, name)) continue;
        switch (v) {
            .Node, .Edge => return v,
            else => {},
        }
    }
    return null;
}

/// Move the entities `src` tracks into `dst.*` (`src` is consumed). Trackers
/// that free their entities differently are left unmerged (every executor
/// tracker frees the struct only).
fn adoptEntities(dst: *?*execution.OwnedGraphEntities, src: ?*execution.OwnedGraphEntities) !void {
    const s = src orelse return;
    const d = dst.* orelse {
        dst.* = s;
        return;
    };
    if (d == s) return;
    if (!d.canAbsorb(s)) return;
    // SONNY-6613: the path arrays `src` keeps move too.
    try d.absorb(s);
}

/// Free a clause's rows once their values (nodes and relationships, which
/// its entities keep) are copied out; the entities go to `entities`.
fn releaseClauseRows(allocator: std.mem.Allocator, rows: *ExecutionResult, entities: *?*execution.OwnedGraphEntities) !void {
    try adoptEntities(entities, rows.owned_graph_entities);
    rows.owned_graph_entities = null;
    // The values are element references (no path is read here), which the
    // rows do not own in any case.
    rows.owns_value_memory = false;
    rows.deinit(allocator);
}

fn freeRows(allocator: std.mem.Allocator, rows: *std.ArrayList([]Value)) void {
    for (rows.items) |row| allocator.free(row);
    rows.deinit(allocator);
}

/// The part of `q` that is clause `chains` and its `where` alone.
fn clauseQuery(q: ast.Query, chains: []ast.Chain, where: ?ast.Expr) ast.Query {
    var seg = q;
    seg.match = .{ .chains = chains };
    seg.match_clauses = &.{};
    seg.optional_match = false;
    seg.optional_where = false;
    seg.where_clause = where;
    seg.filter_clause = null;
    seg.with_clause = null;
    seg.is_initial_with = false;
    seg.initial_with = null;
    seg.initial_where = null;
    seg.pre_with_where = null;
    seg.with_where = null;
    seg.group_by = null;
    seg.having = null;
    seg.order_by = null;
    seg.limit = null;
    seg.offset = null;
    seg.limit_param = null;
    seg.offset_param = null;
    seg.let_bindings = &.{};
    seg.inline_let_bindings = &.{};
    seg.path_variable = null;
    seg.next_query = null;
    seg.for_statement = null;
    seg.cte_list = null;
    seg.call_clause = null;
    seg.unwind_clause = null;
    seg.initial_call_subquery = null;
    seg.create_pattern = null;
    seg.merge_statement = null;
    seg.set_clauses = &.{};
    seg.remove_clauses = &.{};
    seg.delete_items = &.{};
    seg.ret = .{ .items = &.{}, .distinct = false };
    return seg;
}

// CANARY: REQ=REQ-SONNY-3184-OPTIONAL-MATCH; FEATURE="OptionalMatchLeftOuterJoin"; ASPECT=LeftOuterJoin; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=engine; UPDATED=2026-11-11
/// The records `q`'s MATCH and OPTIONAL MATCH clauses bind, joined left to
/// right (see the file comment), then its FILTER: one column per pattern
/// variable. `q` has no WITH (a WITH stage reads these rows through
/// `readPatternBindings`). Refused (0A000, `UnsupportedOptionalMatchShape`):
/// a path variable and an inline LET in such a part.
pub fn readOptionalRows(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) anyerror!ExecutionResult {
    if (inline_let_bindings.len != 0 or q.inline_let_bindings.len != 0) return error.UnsupportedOptionalMatchShape;
    {
        // A path variable: on an OPTIONAL MATCH as before (SONNY-3318),
        // and on a MATCH beside one (its path value would be copied into
        // every record the OPTIONAL MATCH extends it to).
        var at: usize = 0;
        for (q.match_clauses) |clause| {
            const end = @min(clause.end, q.match.chains.len);
            for (q.match.chains[@min(at, end)..end]) |chain| {
                if (chain.name != null) return if (clause.optional) error.OptionalPathVariable else error.UnsupportedOptionalMatchShape;
            }
            at = end;
        }
        if (q.path_variable != null) return error.UnsupportedOptionalMatchShape;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var columns: std.ArrayList([]const u8) = .empty;
    var rows: std.ArrayList([]Value) = .empty;
    defer freeRows(allocator, &rows);
    var entities: ?*execution.OwnedGraphEntities = null;
    errdefer if (entities) |e| e.deinit();
    // The unit table: one record binding nothing.
    try rows.append(allocator, try allocator.alloc(Value, 0));

    var pn: std.ArrayList([]const u8) = .empty;
    defer pn.deinit(allocator);
    var pv: std.ArrayList(Value) = .empty;
    defer pv.deinit(allocator);

    var start: usize = 0;
    for (q.match_clauses) |clause| {
        const end = @min(clause.end, q.match.chains.len);
        if (end < start) return error.UnsupportedOptionalMatchShape;
        const chains = try aa.dupe(ast.Chain, q.match.chains[start..end]);
        start = end;
        for (chains) |*chain| chain.is_optional = false;
        // The clause's WHERE is applied below, to each match with the
        // record's variables, so that an error in it surfaces: the pattern
        // executors take a WHERE error for a candidate that does not match,
        // and the record would survive with NULL.
        const seg = clauseQuery(q, chains, null);

        var seg_names: std.ArrayList([]const u8) = .empty;
        for (chains) |chain| try appendChainNames(aa, &seg_names, chain);
        const first_new = columns.items.len;
        for (seg_names.items) |n| try appendNameOnce(aa, &columns, n);
        const width = columns.items.len;

        var next: std.ArrayList([]Value) = .empty;
        defer freeRows(allocator, &next);
        for (rows.items) |row| {
            const known = columns.items[0..first_new];
            // A name bound to NULL (an earlier OPTIONAL MATCH found nothing
            // for it) matches no element.
            const null_bound = for (seg_names.items) |n| {
                const v = lookup(known, row, n) orelse lookup(param_names, param_values, n) orelse continue;
                if (v == .Null) break true;
            } else false;
            var matched = false;
            if (!null_bound) {
                // The record's variables first: the latest binding of a name
                // is the one a pattern joins to.
                pn.clearRetainingCapacity();
                pv.clearRetainingCapacity();
                try pn.appendSlice(allocator, known);
                try pv.appendSlice(allocator, row);
                try pn.appendSlice(allocator, param_names);
                try pv.appendSlice(allocator, param_values);
                var bindings = try match_operations.readPatternRows(allocator, seg, pn.items, pv.items, &.{}, current_graph);
                allocator.free(bindings.items);
                defer releaseClauseRows(allocator, &bindings.rows, &entities) catch {};
                for (bindings.rows.rows) |brow| {
                    const out = try allocator.alloc(Value, width);
                    errdefer allocator.free(out);
                    @memcpy(out[0..first_new], row);
                    for (columns.items[first_new..width], out[first_new..]) |name, *cell| {
                        cell.* = lookup(bindings.rows.columns, brow, name) orelse .Null;
                    }
                    if (clause.where) |where_expr| {
                        // Evaluated on the arena: what it computes is scratch.
                        const env = Env{ .names = columns.items[0..width], .values = out, .param_names = param_names, .param_values = param_values, .allocator = aa };
                        const keep = switch (try eval.evalExpr(aa, where_expr, env)) {
                            .Bool => |b| b,
                            else => false,
                        };
                        if (!keep) {
                            allocator.free(out);
                            continue;
                        }
                    }
                    try next.append(allocator, out);
                    matched = true;
                }
            }
            if (!matched and clause.optional) {
                const out = try allocator.alloc(Value, width);
                errdefer allocator.free(out);
                @memcpy(out[0..first_new], row);
                // A new column the incoming record already binds keeps its
                // element; every other one is NULL.
                for (columns.items[first_new..width], out[first_new..]) |name, *cell| {
                    cell.* = boundElement(param_names, param_values, name) orelse .Null;
                }
                try next.append(allocator, out);
            }
        }
        std.mem.swap(std.ArrayList([]Value), &rows, &next);
    }

    // A FILTER after the clauses drops records.
    if (q.filter_clause) |filter| {
        var kept: usize = 0;
        for (rows.items) |row| {
            const env = Env{ .names = columns.items, .values = row, .param_names = param_names, .param_values = param_values, .allocator = aa };
            const keep = switch (try eval.evalExpr(aa, filter, env)) {
                .Bool => |b| b,
                else => false,
            };
            if (keep) {
                rows.items[kept] = row;
                kept += 1;
            } else allocator.free(row);
        }
        rows.shrinkRetainingCapacity(kept);
    }

    const out_columns = try allocator.alloc([]const u8, columns.items.len);
    var filled: usize = 0;
    errdefer {
        for (out_columns[0..filled]) |c| allocator.free(c);
        allocator.free(out_columns);
    }
    for (columns.items, out_columns) |name, *c| {
        c.* = try allocator.dupe(u8, name);
        filled += 1;
    }
    const out_rows = try rows.toOwnedSlice(allocator);
    return .{
        .columns = out_columns,
        .rows = out_rows,
        .flags = .empty,
        .owned_graph_entities = entities,
    };
}
