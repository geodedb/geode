// SONNY-2667 regression: planned reads ignored a WHERE placed after RETURN.
//
// The parser stores `RETURN items WHERE predicate` as the query's HAVING
// (parser.zig: the post-RETURN WHERE). A HAVING without a GROUP BY comes only
// from there. The planned read handed it to the projection
// (`executeWithClauseWithGroupByAndParams`), which applied HAVING only inside
// its GROUP BY branch, so `MATCH (n:N) RETURN n.i WHERE n.i >= 10` over 25
// nodes returned all 25 rows instead of 15. With a WITH clause the planned
// read handed it to the WITH stage instead, which ignored it the same way.
//
// HAVING without a GROUP BY is now a post-projection filter, evaluated per
// output row: a name resolves to a projected column first (an alias, or an
// unaliased item's expression name), then to the input row behind the output
// row, so `n.i` resolves through `n`. The SKIP/LIMIT window is applied to what
// passes. The planned read applies it at the RETURN stage, with or without a
// WITH.
//
// The executor runs on a persisted in-process deployment, so these reads take
// the planned-read path (the node-scan fast path declines a HAVING). The
// expected rows come from the seed. Each query also pins that the planned read
// served it and materialized every row (a HAVING turns the LIMIT pushdown
// off).
//
// CANARY: REQ=REQ-SONNY-2667-RETURN-WHERE; FEATURE="PlannedReadReturnWhere"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2667_return_where.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;
const many = harness.many;

/// 25 `:N` nodes (i = 0..24, s = 's00'..'s24') and 25
/// `(:NA {i})-[:R]->(:NB {i})` pairs with the same i.
fn seed(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    for (0..many) |i| {
        var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:N {{i: {d}, s: 's{d:0>2}'}})", .{ i, i }));
        r.deinit(aa);
        var p = try h.run(try std.fmt.allocPrint(aa, "CREATE (:NA {{i: {d}}})-[:R]->(:NB {{i: {d}}})", .{ i, i }));
        p.deinit(aa);
    }
}

/// One row as text, cells joined by '|'.
fn renderRow(aa: std.mem.Allocator, row: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (row, 0..) |cell, c| {
        if (c > 0) try out.append(aa, '|');
        switch (cell) {
            .Str => |s| try out.appendSlice(aa, s),
            .Int => |n| try out.print(aa, "{d}", .{n}),
            else => return error.UnexpectedCellKind,
        }
    }
    return out.toOwnedSlice(aa);
}

const Answer = struct { rows: [][]const u8, materialized: u64 };

/// The executor's rows for `query`, rendered, in serve order.
fn executor(h: *harness.Harness, query: []const u8) !Answer {
    const aa = h.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = try h.run(query);
    defer result.deinit(aa);
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    const rows = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, 0..) |row, i| rows[i] = try renderRow(aa, row);
    return .{ .rows = rows, .materialized = materialized };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `query` returns exactly `want`, in any order, after the planned read
/// materialized `materialized` rows. Returns the rows in serve order.
fn expectRows(h: *harness.Harness, query: []const u8, want: []const []const u8, materialized: u64) ![][]const u8 {
    const got = try executor(h, query);
    const sorted = try h.arena.allocator().dupe([]const u8, got.rows);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    const want_sorted = try h.arena.allocator().dupe([]const u8, want);
    std.mem.sort([]const u8, want_sorted, {}, lessThan);
    if (sorted.len != want_sorted.len) {
        std.debug.print("{s}: expected {d} rows, found {d} ({d} materialized)\n", .{ query, want_sorted.len, sorted.len, got.materialized });
        return error.TestExpectedEqual;
    }
    for (want_sorted, sorted) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(materialized, got.materialized);
    return got.rows;
}

/// `base SKIP k LIMIT m` (either may be absent) returns the rows of `all` (the
/// unwindowed answer, in serve order) after the first k, at most m of them.
fn expectWindow(h: *harness.Harness, base: []const u8, all: []const []const u8, k: ?usize, m: ?usize, materialized: u64) !void {
    const aa = h.arena.allocator();
    var query = try aa.dupe(u8, base);
    if (k) |n| query = try std.fmt.allocPrint(aa, "{s} SKIP {d}", .{ query, n });
    if (m) |n| query = try std.fmt.allocPrint(aa, "{s} LIMIT {d}", .{ query, n });
    const got = try executor(h, query);
    const start = @min(k orelse 0, all.len);
    const end = if (m) |n| @min(start + n, all.len) else all.len;
    const want = all[start..end];
    if (got.rows.len != want.len) {
        std.debug.print("{s}: expected {d} rows, found {d} ({d} materialized)\n", .{ query, want.len, got.rows.len, got.materialized });
        return error.TestExpectedEqual;
    }
    for (want, got.rows) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(materialized, got.materialized);
}

/// Decimal renderings of `from`..`to` inclusive (harness-arena owned).
fn ints(h: *harness.Harness, from: usize, to: usize) ![][]const u8 {
    const out = try h.arena.allocator().alloc([]const u8, to - from + 1);
    for (out, from..) |*o, i| o.* = try std.fmt.allocPrint(h.arena.allocator(), "{d}", .{i});
    return out;
}

test "SONNY-2667: a WHERE after RETURN filters the rows of a planned node scan" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    const base = "MATCH (n:N) RETURN n.i WHERE n.i >= 10";
    const all = try expectRows(&h, base, try ints(&h, 10, 24), many);
    // The window applies to the rows that pass.
    try expectWindow(&h, base, all, null, 5, many);
    try expectWindow(&h, base, all, 3, null, many);
    try expectWindow(&h, base, all, 3, 5, many);
    try expectWindow(&h, base, all, 14, 5, many);
}

test "SONNY-2667: a WHERE after RETURN can name a projected alias or combine conditions" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    _ = try expectRows(&h, "MATCH (n:N) RETURN n.i AS x WHERE x >= 10", try ints(&h, 10, 24), many);

    const aa = h.arena.allocator();
    var want: std.ArrayList([]const u8) = .empty;
    for (10..many) |i| {
        if (i == 12) continue;
        try want.append(aa, try std.fmt.allocPrint(aa, "s{d:0>2}|{d}", .{ i, i }));
    }
    _ = try expectRows(&h, "MATCH (n:N) RETURN n.s, n.i WHERE n.i >= 10 AND n.s <> 's12'", want.items, many);
}

test "SONNY-2667: a WHERE after RETURN filters a planned path query" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    const base = "MATCH (a:NA)-[:R]->(b:NB) RETURN b.i WHERE b.i >= 10";
    const all = try expectRows(&h, base, try ints(&h, 10, 24), many);
    try expectWindow(&h, base, all, 2, 4, many);
}

test "SONNY-2667: a WHERE after RETURN applies at the RETURN, after a WITH" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    _ = try expectRows(&h, "MATCH (n:N) WITH n RETURN n.i WHERE n.i >= 10", try ints(&h, 10, 24), many);
    // An alias the RETURN defines exists only at the RETURN.
    _ = try expectRows(&h, "MATCH (n:N) WITH n RETURN n.i AS x WHERE x >= 10", try ints(&h, 10, 24), many);
}

test "SONNY-2667: a WHERE after RETURN filters an aggregate row" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    _ = try expectRows(&h, "MATCH (n:N) RETURN count(*) AS c WHERE c > 3", &.{"25"}, many);
    _ = try expectRows(&h, "MATCH (n:N) RETURN count(*) AS c WHERE c > 30", &.{}, many);
}
