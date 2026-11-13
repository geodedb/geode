//! SONNY-2811: an ORDER BY key that reads a variable the RETURN does not
//! project (`MATCH (n) RETURN n.k AS k ORDER BY n.x`).
//!
//! Every executor sorts the projected rows, so such a key was evaluated
//! against a row that does not bind `n`: it was NULL for every row and the
//! rows came back unsorted. (A key whose field happened to name a column,
//! `RETURN n.k AS x ORDER BY n.x`, sorted by that column instead.)
//!
//! ISO/IEC 39075 sorts the working table, where the pattern's variables are
//! still bound. For a RETURN that neither aggregates nor is DISTINCT, each
//! row of the working table is one output row, so the key can be computed
//! with the projection: `hide` appends each such key to the RETURN as a
//! hidden item and sorts by that item instead; after the sort and the window
//! the statement drops the hidden columns (`drop`).
//!
//! A key that reads only output columns (an alias, `k + 1`, an ordinal) or
//! that is a projected item's expression is left as it is. A DISTINCT or
//! aggregating RETURN is left as it is too: there a key must be projected
//! (or be a grouping key), and an extra item would change the rows.

const std = @import("std");
const ast = @import("../gql/ast.zig");
const grouped_having = @import("grouped_having.zig");
const execution = @import("../execution.zig");
const value_utilities = @import("value_utilities.zig");

/// The hidden items' names start with a NUL byte: no identifier a query can
/// spell, and no binding can shadow one.
const hidden_prefix = "\x00order_key_";

/// At most this many keys are hidden (`drop` keeps their names on its stack).
const max_hidden = 64;

pub const Hidden = struct {
    arena: std.heap.ArenaAllocator,
    /// The query, with the hidden items appended to its RETURN.
    query: ast.Query,
    /// How many trailing columns of the result are hidden.
    count: usize,

    pub fn deinit(self: *Hidden) void {
        self.arena.deinit();
    }
};

fn appendName(a: std.mem.Allocator, names: *std.ArrayList([]const u8), name: ?[]const u8) !void {
    const n = name orelse return;
    for (names.items) |existing| if (std.mem.eql(u8, existing, n)) return;
    try names.append(a, n);
}

fn itemName(item: ast.ReturnItem) ?[]const u8 {
    if (item.alias) |alias| return alias;
    return if (item.expr == .Ident) item.expr.Ident.orig else null;
}

/// `q` with each ORDER BY key that reads an unprojected variable computed by
/// a hidden RETURN item, or null when no key does (or the RETURN is one this
/// does not apply to).
pub fn hide(gpa: std.mem.Allocator, q: ast.Query) !?Hidden {
    const order = q.order_by orelse return null;
    if (q.next_query != null or q.for_statement != null or q.initial_call_subquery != null) return null;
    if (q.ret.items.len == 0 or q.ret.distinct or q.group_by != null or q.having != null) return null;
    if (q.with_clause) |wc| {
        // A WITH-only part: its RETURN is the WITH's items.
        if (q.ret.items.ptr == wc.items.ptr) return null;
    }
    for (q.ret.items) |item| {
        if (grouped_having.containsAggregate(item.expr)) return null;
        if (item.expr == .Ident and std.mem.eql(u8, item.expr.Ident.orig, "*")) return null;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    var keep_arena = false;
    defer if (!keep_arena) arena.deinit();
    const a = arena.allocator();

    // The variables the RETURN reads from: a WITH's columns, else the
    // pattern's variables.
    var inputs: std.ArrayList([]const u8) = .empty;
    if (q.with_clause) |wc| {
        for (wc.items) |item| try appendName(a, &inputs, itemName(item));
    } else {
        for (q.match.chains) |chain| {
            try appendName(a, &inputs, chain.name);
            if (chain.head) |head| try appendName(a, &inputs, head.name);
            for (chain.hops) |hop| {
                try appendName(a, &inputs, hop.left.name);
                try appendName(a, &inputs, hop.rel.name);
                try appendName(a, &inputs, hop.right.name);
            }
        }
    }
    // Those the RETURN does not project under the same name.
    var unprojected: std.ArrayList([]const u8) = .empty;
    outer: for (inputs.items) |name| {
        for (q.ret.items) |item| {
            if (itemName(item)) |out| if (std.mem.eql(u8, out, name)) continue :outer;
        }
        try unprojected.append(a, name);
    }
    if (unprojected.items.len == 0) return null;

    const keys = try a.dupe(ast.OrderBy.OrderKey, order.keys);
    var items: std.ArrayList(ast.ReturnItem) = .empty;
    try items.appendSlice(a, q.ret.items);
    var hidden: usize = 0;
    for (keys) |*key| {
        if (key.expr == .Int or hidden == max_hidden) continue;
        const projected = for (q.ret.items) |item| {
            if (grouped_having.exprEql(key.expr, item.expr)) break true;
        } else false;
        if (projected) continue;
        if (!grouped_having.mentionsAnyName(key.expr, unprojected.items)) continue;
        const name = try std.fmt.allocPrint(a, hidden_prefix ++ "{d}", .{hidden});
        try items.append(a, .{ .expr = key.expr, .alias = name });
        key.expr = .{ .Ident = .{ .orig = name, .cnf = name } };
        hidden += 1;
    }
    if (hidden == 0) return null;
    const order_ptr = try a.create(ast.OrderBy);
    order_ptr.* = .{ .keys = keys };
    var out = q;
    out.ret = .{ .items = try items.toOwnedSlice(a), .distinct = false };
    out.order_by = order_ptr.*;
    keep_arena = true;
    return .{ .arena = arena, .query = out, .count = hidden };
}

/// Drops the `count` trailing (hidden) columns of `result`, after its sort
/// and window.
pub fn drop(allocator: std.mem.Allocator, result: *execution.ExecutionResult, count: usize) !void {
    if (count == 0 or result.columns.len < count) return;
    const keep = result.columns.len - count;
    const free_value = result.free_value orelse &value_utilities.freeValue;
    for (result.rows) |*row| {
        if (row.len <= keep) continue;
        for (row.*[keep..]) |*v| {
            if (result.owns_value_memory) free_value(allocator, v.*);
            v.* = .Null;
        }
        row.* = try allocator.realloc(row.*, keep);
    }
    // The hidden names, each one the item's allocation (or the column
    // buffer's, freed with it), are freed once the shorter list is in place.
    var names: [max_hidden][]const u8 = undefined;
    const n = @min(count, names.len);
    @memcpy(names[0..n], result.columns[keep..][0..n]);
    result.columns = try allocator.realloc(result.columns, keep);
    if (result.column_buffer == null) for (names[0..n]) |col| allocator.free(col);
}
