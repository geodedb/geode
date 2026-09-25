// SONNY-2652 regression: `SKIP k` with no LIMIT returned one row on the
// executor's planned-read path.
//
// With no WHERE, ORDER BY, WITH, DISTINCT or aggregate, the first rows a
// planned read materializes are the first rows of its answer, so the path
// stops materializing once it has the rows the window needs (`materialize_cap`)
// and applies the window afterwards. It took that bound from
// `requiredStartRows`, which answers OFFSET + 1 for an OFFSET with no LIMIT:
// `MATCH (n:M) RETURN n.s SKIP 5` over 25 nodes materialized 6 rows, skipped
// 5 of them and returned 1. Both cap sites had it: the single-chain loops
// (a node scan, and every hop of a path) and the multi-chain cartesian loops.
//
// The executor runs here on a persisted in-process deployment, so reads take
// the planned-read path (`!wouldEvaluateRLS()`): authenticated reads on a
// deployment with no RLS policy, and every read the node-scan fast path does
// not serve. The expected rows come from the seed, not from another executor
// answer: `SKIP k` returns the rows after the first k of the same query's
// unskipped answer, whose rows are checked against the seed, and exactly as
// many as the seed says. Each query also pins how many rows the planned read
// materialized, which proves the planned-read path served it and that a LIMIT
// still bounds materialization. A WHERE turns the cap off, so the WHERE cases
// pin that the fix leaves them alone.
//
// The same cap ignored a FILTER, which removes rows after materialization just
// as a WHERE does: `MATCH (n:M) FILTER n.i >= 10 RETURN n.s LIMIT 5`
// materialized 5 rows and returned the 2 of them that passed. The FILTER tests
// pin that a FILTER turns the cap off too, at both sites (SONNY-2672).
//
// It ignored a GROUP BY with no aggregate as well (SONNY-2673), which merges
// rows after materialization: `MATCH (n:N {k: 1}) RETURN n.g GROUP BY n.g
// LIMIT 2` materialized 2 rows, both in group 'a', and returned 1 group of the
// 2. The GROUP BY tests pin that a GROUP BY turns the cap off at both sites. (A
// HAVING turns it off too; the SONNY-2667 tests exercise that.)
//
// CANARY: REQ=REQ-SONNY-2652-PLANNED-READ-SKIP; FEATURE="PlannedReadRowWindow"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2652_planned_read_skip_without_limit.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;
const many = harness.many;

/// Chain seeds: `many` `(:A {i})-[:R]->(:B {s})` pairs, with i = 0..24 and
/// s = 'b00'..'b24'.
fn seedPairs(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    for (0..many) |i| {
        var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:A {{i: {d}}})-[:R]->(:B {{s: 'b{d:0>2}'}})", .{ i, i }));
        r.deinit(aa);
    }
}

/// Multi-chain seeds: 3 `:P`, 4 `:Q` and 2 `:X` nodes, s = 'p0'.., 'q0'.., 'x0'...
const p_count: usize = 3;
const q_count: usize = 4;
const x_count: usize = 2;

fn seedCartesian(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    const sets = [_]struct { label: []const u8, prefix: []const u8, count: usize }{
        .{ .label = "P", .prefix = "p", .count = p_count },
        .{ .label = "Q", .prefix = "q", .count = q_count },
        .{ .label = "X", .prefix = "x", .count = x_count },
    };
    for (sets) |set| {
        for (0..set.count) |i| {
            var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:{s} {{s: '{s}{d}'}})", .{ set.label, set.prefix, i }));
            r.deinit(aa);
        }
    }
}

/// One row as text, cells joined by '|': a string as is, an integer in
/// decimal, a node as its `s` property.
fn renderRow(aa: std.mem.Allocator, row: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (row, 0..) |cell, c| {
        if (c > 0) try out.append(aa, '|');
        switch (cell) {
            .Str => |s| try out.appendSlice(aa, s),
            .Int => |n| try out.print(aa, "{d}", .{n}),
            .Node => |node| {
                const s = node.properties.get("s") orelse return error.NodePropertyMissing;
                try out.appendSlice(aa, s.String);
            },
            else => return error.UnexpectedCellKind,
        }
    }
    return out.toOwnedSlice(aa);
}

const Answer = struct {
    rows: [][]const u8,
    /// Rows the planned read materialized for this query.
    materialized: u64,
};

/// The executor's rows for `query`, rendered, in the order it returned them
/// (harness-arena owned).
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

/// `base` (no window) returns exactly `want`, in any order, after the planned
/// read materialized `want_materialized` rows. Returns its rows in serve order.
fn expectBase(h: *harness.Harness, base: []const u8, want: []const []const u8, want_materialized: u64) ![][]const u8 {
    const all = try executor(h, base);
    const sorted = try h.arena.allocator().dupe([]const u8, all.rows);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    try testing.expectEqual(want.len, sorted.len);
    for (want, sorted) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(want_materialized, all.materialized);
    return all.rows;
}

/// `base SKIP k` returns exactly the rows after the first k of `all` (the
/// rows of `base`, in serve order), and the planned read materialized
/// `want_materialized` rows to produce them.
fn expectSkip(h: *harness.Harness, base: []const u8, all: []const []const u8, k: usize, want_materialized: u64) !void {
    const query = try std.fmt.allocPrint(h.arena.allocator(), "{s} SKIP {d}", .{ base, k });
    const got = try executor(h, query);
    const want = all[@min(k, all.len)..];
    if (got.rows.len != want.len) {
        std.debug.print("{s}: expected {d} rows, found {d} ({d} materialized)\n", .{ query, want.len, got.rows.len, got.materialized });
        return error.TestExpectedEqual;
    }
    for (want, got.rows) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(want_materialized, got.materialized);
}

/// `base SKIP k LIMIT m` returns the `m` rows after the first k of `all`, and
/// the planned read stopped materializing after k + m rows.
fn expectSkipLimit(h: *harness.Harness, base: []const u8, all: []const []const u8, k: usize, m: usize) !void {
    const query = try std.fmt.allocPrint(h.arena.allocator(), "{s} SKIP {d} LIMIT {d}", .{ base, k, m });
    const got = try executor(h, query);
    const want = all[k .. k + m];
    try testing.expectEqual(want.len, got.rows.len);
    for (want, got.rows) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(@as(u64, k + m), got.materialized);
}

/// 's00'..'s{n-1}' with prefix `p` (harness-arena owned).
fn names(h: *harness.Harness, p: []const u8, n: usize) ![][]const u8 {
    const out = try h.arena.allocator().alloc([]const u8, n);
    for (out, 0..) |*o, i| o.* = try std.fmt.allocPrint(h.arena.allocator(), "{s}{d:0>2}", .{ p, i });
    return out;
}

test "SONNY-2652: SKIP without LIMIT on a planned node scan returns every row after the offset" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);

    const base = "MATCH (n:M) RETURN n.s";
    const all = try expectBase(&h, base, try names(&h, "s", many), many);
    // Every row is materialized: an OFFSET alone bounds nothing.
    for ([_]usize{ 5, 1, 23, 0, 24, 25, 30 }) |k| try expectSkip(&h, base, all, k, many);
    // A LIMIT still stops materialization at OFFSET + LIMIT.
    try expectSkipLimit(&h, base, all, 5, 3);
}

test "SONNY-2652: SKIP without LIMIT on a planned bare-node scan returns every node after the offset" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);

    // The same cap site, with the node itself in the row.
    const base = "MATCH (n:M) RETURN n";
    const all = try expectBase(&h, base, try names(&h, "s", many), many);
    for ([_]usize{ 5, 24 }) |k| try expectSkip(&h, base, all, k, many);
    try expectSkipLimit(&h, base, all, 5, 3);
}

test "SONNY-2652: SKIP without LIMIT behind a WHERE counts matched rows" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);

    // A WHERE turns the cap off, so every node is materialized and the window
    // counts the 22 rows that pass.
    const base = "MATCH (n:M) WHERE n.i >= 3 RETURN n.s";
    const passing = (try names(&h, "s", many))[3..];
    const all = try expectBase(&h, base, passing, many);
    for ([_]usize{ 5, 1, 22, 30 }) |k| try expectSkip(&h, base, all, k, many);
}

test "SONNY-2652: SKIP without LIMIT on a planned path query returns every row after the offset" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPairs(&h);

    // The cap stops the hop expansion too (`exploreHops`).
    const base = "MATCH (a:A)-[:R]->(b:B) RETURN b.s";
    const all = try expectBase(&h, base, try names(&h, "b", many), many);
    for ([_]usize{ 5, 1, 23, 0, 24, 25 }) |k| try expectSkip(&h, base, all, k, many);
    try expectSkipLimit(&h, base, all, 5, 3);
}

test "SONNY-2652: SKIP without LIMIT on a planned path query behind a WHERE counts matched rows" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPairs(&h);

    // 22 pairs pass, and the cap is off.
    const base = "MATCH (a:A)-[:R]->(b:B) WHERE a.i >= 3 RETURN b.s";
    const all = try expectBase(&h, base, (try names(&h, "b", many))[3..], many);
    for ([_]usize{ 5, 22 }) |k| try expectSkip(&h, base, all, k, many);
}

test "SONNY-2652: SKIP without LIMIT on a planned two-chain query returns every row after the offset" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedCartesian(&h);
    const aa = h.arena.allocator();

    // The P x Q nested loop.
    const base = "MATCH (p:P), (q:Q) RETURN p.s, q.s";
    var want: std.ArrayList([]const u8) = .empty;
    for (0..p_count) |i| for (0..q_count) |j| try want.append(aa, try std.fmt.allocPrint(aa, "p{d}|q{d}", .{ i, j }));
    const n = p_count * q_count;
    const all = try expectBase(&h, base, want.items, n);
    for ([_]usize{ 5, 1, 11, 0, 12, 13 }) |k| try expectSkip(&h, base, all, k, n);
    try expectSkipLimit(&h, base, all, 5, 3);
}

test "SONNY-2652: SKIP without LIMIT on a planned three-chain query returns every row after the offset" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedCartesian(&h);
    const aa = h.arena.allocator();

    // The recursive nested loop (`nestedLoopCartesian`).
    const base = "MATCH (p:P), (q:Q), (x:X) RETURN p.s, q.s, x.s";
    var want: std.ArrayList([]const u8) = .empty;
    for (0..p_count) |i| for (0..q_count) |j| for (0..x_count) |l| try want.append(aa, try std.fmt.allocPrint(aa, "p{d}|q{d}|x{d}", .{ i, j, l }));
    const n = p_count * q_count * x_count;
    const all = try expectBase(&h, base, want.items, n);
    for ([_]usize{ 5, 1, 23, 24 }) |k| try expectSkip(&h, base, all, k, n);
    try expectSkipLimit(&h, base, all, 5, 3);
}

/// `base SKIP k LIMIT m` returns the `m` rows after the first k of `all`, and
/// the planned read materialized every row (`total`): the cap must be off.
fn expectWindowUncapped(h: *harness.Harness, base: []const u8, all: []const []const u8, k: usize, m: usize, total: u64) !void {
    const query = try std.fmt.allocPrint(h.arena.allocator(), "{s} SKIP {d} LIMIT {d}", .{ base, k, m });
    const got = try executor(h, query);
    const want = all[k .. k + m];
    if (got.rows.len != want.len) {
        std.debug.print("{s}: expected {d} rows, found {d} ({d} materialized)\n", .{ query, want.len, got.rows.len, got.materialized });
        return error.TestExpectedEqual;
    }
    for (want, got.rows) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(total, got.materialized);
}

test "SONNY-2652: a FILTER is applied before the LIMIT on a planned node scan" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);

    // FILTER removes rows after materialization, like a WHERE, so the first
    // rows materialized are not the answer's first rows: no cap.
    const base = "MATCH (n:M) FILTER n.i >= 10 RETURN n.s";
    const all = try expectBase(&h, base, (try names(&h, "s", many))[10..], many);
    try expectWindowUncapped(&h, base, all, 0, 5, many);
    try expectWindowUncapped(&h, base, all, 2, 5, many);
}

test "SONNY-2652: a FILTER is applied before the LIMIT on a planned path query" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPairs(&h);

    const base = "MATCH (a:A)-[:R]->(b:B) FILTER a.i >= 10 RETURN b.s";
    const all = try expectBase(&h, base, (try names(&h, "b", many))[10..], many);
    try expectWindowUncapped(&h, base, all, 0, 5, many);
    try expectWindowUncapped(&h, base, all, 2, 5, many);
}

test "SONNY-2652: a FILTER is applied before the LIMIT on a planned multi-chain query" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedCartesian(&h);
    const aa = h.arena.allocator();

    const base = "MATCH (p:P), (q:Q) FILTER p.s = 'p1' RETURN p.s, q.s";
    var want: std.ArrayList([]const u8) = .empty;
    for (0..q_count) |j| try want.append(aa, try std.fmt.allocPrint(aa, "p1|q{d}", .{j}));
    const n = p_count * q_count;
    const all = try expectBase(&h, base, want.items, n);
    try expectWindowUncapped(&h, base, all, 0, 2, n);
    try expectWindowUncapped(&h, base, all, 1, 2, n);
}

/// 25 `:N` nodes (i = 0..24, k = 1 on each, g = 'a' for the first 10 and 'b'
/// for the other 15), 2 `:X` nodes, and 25 `(:NA {i, g})-[:R]->(:NB)` pairs
/// with the same g.
fn seedGroups(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    for (0..many) |i| {
        const g: []const u8 = if (i < 10) "a" else "b";
        var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:N {{i: {d}, k: 1, g: '{s}'}})", .{ i, g }));
        r.deinit(aa);
        var p = try h.run(try std.fmt.allocPrint(aa, "CREATE (:NA {{i: {d}, g: '{s}'}})-[:R]->(:NB {{i: {d}}})", .{ i, g, i }));
        p.deinit(aa);
    }
    for (0..2) |i| {
        var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:X {{s: 'x{d}'}})", .{i}));
        r.deinit(aa);
    }
}

/// `query` returns exactly `want`, in any order. When `want_materialized` is
/// given, the planned read served it and materialized that many rows (every
/// row: the cap must be off).
fn expectRowSet(h: *harness.Harness, query: []const u8, want: []const []const u8, want_materialized: ?u64) !void {
    const got = try executor(h, query);
    const sorted = try h.arena.allocator().dupe([]const u8, got.rows);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    if (sorted.len != want.len) {
        std.debug.print("{s}: expected {d} rows, found {d} ({d} materialized)\n", .{ query, want.len, sorted.len, got.materialized });
        return error.TestExpectedEqual;
    }
    for (want, sorted) |w, g| try testing.expectEqualStrings(w, g);
    if (want_materialized) |n| try testing.expectEqual(n, got.materialized);
}

test "SONNY-2673: a GROUP BY is applied before the LIMIT on a planned node scan" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedGroups(&h);

    // The streaming GROUP BY fast path serves a bare label scan (the planned
    // read never runs: nothing is materialized there). It is right either way.
    try expectRowSet(&h, "MATCH (n:N) RETURN n.g GROUP BY n.g LIMIT 2", &.{ "a", "b" }, 0);
    // An inline property sends the same grouping to the planned read.
    try expectRowSet(&h, "MATCH (n:N {k: 1}) RETURN n.g GROUP BY n.g", &.{ "a", "b" }, many);
    try expectRowSet(&h, "MATCH (n:N {k: 1}) RETURN n.g GROUP BY n.g LIMIT 2", &.{ "a", "b" }, many);
    // Groups come back in no defined order: the window takes the second group
    // of the same query's unwindowed answer.
    const all = (try executor(&h, "MATCH (n:N {k: 1}) RETURN n.g GROUP BY n.g")).rows;
    try testing.expectEqual(@as(usize, 2), all.len);
    try expectRowSet(&h, "MATCH (n:N {k: 1}) RETURN n.g GROUP BY n.g SKIP 1 LIMIT 1", all[1..2], many);
}

test "SONNY-2673: a GROUP BY is applied before the LIMIT on a planned path query" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedGroups(&h);

    try expectRowSet(&h, "MATCH (a:NA)-[:R]->(b:NB) RETURN a.g GROUP BY a.g LIMIT 2", &.{ "a", "b" }, many);
}

test "SONNY-2673: a GROUP BY is applied before the LIMIT on a planned multi-chain query" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedGroups(&h);

    try expectRowSet(&h, "MATCH (n:N), (x:X) RETURN n.g GROUP BY n.g LIMIT 2", &.{ "a", "b" }, many * 2);
}
