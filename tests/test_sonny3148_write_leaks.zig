// SONNY-3148 regression: allocations a statement made on the caller's
// allocator (the server's main allocator in production) and never freed, once
// per statement or once per row. Found by the review of the SONNY-3139 round:
//
//   1. an initial WITH (`WITH [5, 6] AS ids MATCH ... SET ...`): each item's
//      value was bound for the rest of the part and never freed;
//   2. an UNWIND before a write (`UNWIND [5, 6] AS u MATCH ... SET ...`): the
//      evaluated list was never freed;
//   3. a WITH after the MATCH, before a write (`MATCH (n) WITH n, <computed>
//      AS k ... SET ...`): what the WITH stage's items computed was never
//      freed;
//   4. a path variable over a fixed single-hop pattern (`MATCH p = (a)-[:T]->
//      (b)`): the path's node and edge arrays were never freed;
//   5. the relationship variable of a variable-length pattern (`MATCH (a)-[r:
//      T*1..2]->(b)`) read by a WITH, a write step or a DELETE: its edge list
//      was never freed.
//
// Each statement runs with `std.testing.allocator` as its allocator (a leak
// fails the test), as the server runs it: the context installed and a query
// scratch arena on the thread (released after the result is read, as the
// transports release theirs after the result is sent). A value the statement
// returns is read after the statement returned and before its result is
// released, so a value freed too early reads back wrong (or fails as a double
// free when released), and the write's effect is read back after. In-memory,
// tenant-scoped (persisted) and RLS-policy (persisted) sessions
// (tests/sonny738_write_harness.zig).
//
// A path a result row returns (`RETURN p`, and the target rows `DETACH DELETE
// p` reads) keeps its two arrays: a path is copied by reference everywhere
// (`duplicateValue`, `duplicateResult`, which the gRPC server keeps past the
// request), so nothing can free them safely. Those shapes run on a private
// allocator, and the arrays are the only allocation allowed to remain.
//
// CANARY: REQ=REQ-SONNY-3148-WRITE-LEAKS; FEATURE="WriteStatementOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3148_write_leaks.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");

const query_arena = geode.query_arena;
const Check = h.Check;
const Value = h.Value;

const Shape = struct {
    /// The statement, run on the leak-checked allocator.
    query: []const u8,
    /// Its rows (null: not checked).
    want: ?[]const []const u8 = null,
    /// Its effect, read back as the session after it.
    checks: []const Check = &.{},
    /// Bind `$rows`, a list of three maps `{id, name}`.
    rows_param: bool = false,
    /// A returned path's arrays: the bytes allowed to remain (see above);
    /// the statement then runs on a private allocator.
    residual_bytes: usize = 0,
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A cell as text, maps included (`{k:v;...}`, keys sorted); read while the
/// result is alive, into the session arena.
fn render(aa: std.mem.Allocator, v: Value) anyerror![]const u8 {
    return switch (v) {
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *p| p.* = try render(aa, item);
            std.mem.sort([]const u8, parts, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ";", parts)});
        },
        .Map => |m| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            var it = m.iterator();
            while (it.next()) |entry| try parts.append(aa, try std.fmt.allocPrint(aa, "{s}:{s}", .{ entry.key_ptr.*, try render(aa, entry.value_ptr.*) }));
            std.mem.sort([]const u8, parts.items, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "{{{s}}}", .{try std.mem.join(aa, ";", parts.items)});
        },
        .Path => |p| try std.fmt.allocPrint(aa, "<Path {d}:{d}>", .{ p.nodes.len, p.edges.len }),
        else => h.render(aa, v),
    };
}

fn renderRows(aa: std.mem.Allocator, result: geode.execution.ExecutionResult) ![]const []const u8 {
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    return got;
}

/// The `$rows` parameter, in the session's arena (the caller's memory: the
/// statement must neither free nor keep it).
fn rowsParam(aa: std.mem.Allocator) !Value {
    const rows = try aa.alloc(Value, 3);
    for (rows, 0..) |*row, i| {
        var map = std.StringHashMap(Value).init(aa);
        try map.put("id", .{ .Int = @intCast(i + 1) });
        try map.put("name", .{ .Str = try std.fmt.allocPrint(aa, "n{d}", .{i + 1}) });
        row.* = .{ .Map = map };
    }
    return .{ .List = rows };
}

/// Run `shape.query` on `allocator` with a scratch arena installed; its rows
/// rendered, then its result released.
fn runStatement(s: *h.Session, allocator: std.mem.Allocator, shape: Shape) ![]const []const u8 {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const prev = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev);
    var result = try s.runWith(allocator, shape.query);
    defer result.deinit(allocator);
    return renderRows(s.arena.allocator(), result);
}

fn runShape(mode: h.Mode, shape: Shape, f: *h.Failures) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();

    const names = [_][]const u8{"rows"};
    var values: [1]Value = undefined;
    if (shape.rows_param) {
        values[0] = try rowsParam(aa);
        s.ctx.query_param_names = &names;
        s.ctx.query_param_values = &values;
    }

    var rows: ?[]const []const u8 = null;
    if (shape.residual_bytes == 0) {
        rows = runStatement(&s, testing.allocator, shape) catch |err| blk: {
            try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), shape.query, @errorName(err) });
            break :blk null;
        };
    } else {
        var dbg: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
        defer dbg.deinitWithoutLeakChecks();
        rows = runStatement(&s, dbg.allocator(), shape) catch |err| blk: {
            try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), shape.query, @errorName(err) });
            break :blk null;
        };
        if (rows != null and dbg.total_requested_bytes != shape.residual_bytes) {
            try f.add("[{s}] {s}: {d} bytes remain after the result was released, expected the path arrays' {d}", .{ @tagName(mode), shape.query, dbg.total_requested_bytes, shape.residual_bytes });
        }
    }
    if (rows) |got| if (shape.want) |want| {
        const exp = try aa.dupe([]const u8, want);
        std.mem.sort([]const u8, exp, {}, lessThan);
        const same = got.len == exp.len and for (got, exp) |g, w| {
            if (!std.mem.eql(u8, g, w)) break false;
        } else true;
        if (!same) try f.add("[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(mode), shape.query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
    };
    s.ctx.query_param_names = &.{};
    s.ctx.query_param_values = &.{};
    for (shape.checks) |chk| try h.expectRows(&s, f, "effect", shape.query, chk.query, chk.want);
    if (mode != .in_memory) {
        s.reopen() catch |err| {
            try f.add("[{s}] {s}: reload failed: {s}", .{ @tagName(mode), shape.query, @errorName(err) });
            return;
        };
        for (shape.checks) |chk| try h.expectRows(&s, f, "effect after reload", shape.query, chk.query, chk.want);
    }
}

fn runShapes(title: []const u8, shapes: []const Shape) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: h.Failures = .{ .arena = arena.allocator() };
    for (h.all_modes) |mode| {
        for (shapes) |shape| runShape(mode, shape, &f) catch |err| {
            try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), shape.query, @errorName(err) });
        };
    }
    try f.finish(title);
}

fn gx(comptime want: []const []const u8) [1]Check {
    return .{.{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = want }};
}

fn xx(comptime want: []const []const u8) [1]Check {
    return .{.{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = want }};
}

/// One single-hop path's arrays: two node pointers and one edge pointer.
const path_bytes = 3 * @sizeOf(usize);

// ---------------------------------------------------------------------------
// 1. An initial WITH.

test "SONNY-3148: an initial WITH frees the values it bound, and a RETURN of one returns a copy" {
    try runShapes("initial WITH", &.{
        .{ .query = "WITH [5, 6] AS ids MATCH (n:G) WHERE n.i IN ids SET n.x = 1", .checks = &gx(&.{ "5", "6" }) },
        .{ .query = "WITH [5, 6] AS ids MATCH (n:G) WHERE n.i IN ids SET n.x = 1 RETURN ids AS l, n.i AS i", .want = &.{ "[5;6]|5", "[5;6]|6" }, .checks = &gx(&.{ "5", "6" }) },
        .{ .query = "WITH [5, 6] AS ids, 'k' || '1' AS tag MATCH (n:G) WHERE n.i IN ids SET n.x = 1 RETURN tag AS t, ids AS l", .want = &.{ "k1|[5;6]", "k1|[5;6]" }, .checks = &gx(&.{ "5", "6" }) },
        .{ .query = "WITH {k: 5, s: toUpper('v')} AS m MATCH (n:G) WHERE n.i = m.k SET n.s = m.s RETURN m AS m", .want = &.{"{k:5;s:V}"}, .checks = &.{
            .{ .query = "MATCH (n:G) WHERE n.s IS NOT NULL RETURN n.i, n.s", .want = &.{"5|V"} },
        } },
        // The store keeps its own copy of what it is given.
        .{ .query = "WITH [5, 6] AS ids MATCH (n:G) WHERE n.i = 5 SET n.l = ids", .checks = &.{
            .{ .query = "MATCH (n:G) WHERE n.l IS NOT NULL RETURN n.i, n.l", .want = &.{"5|[5;6]"} },
        } },
        .{ .query = "WITH [5, 6] AS l, toUpper('z') AS t CREATE (:Z {l: l, t: t})", .checks = &.{
            .{ .query = "MATCH (z:Z) RETURN z.l, z.t", .want = &.{"[5;6]|Z"} },
        } },
        // A second MERGE finds the node (no index kept the freed value).
        .{ .query = "WITH toUpper('q') AS g MERGE (m:M {g: g})", .checks = &.{
            .{ .query = "MERGE (m:M {g: 'Q'}) RETURN m.g AS g", .want = &.{"Q"} },
            .{ .query = "MATCH (m:M) WHERE m.g = 'Q' RETURN count(*) AS c", .want = &.{"1"} },
        } },
        // A list the UNWIND reads from the WITH, returned element by element.
        .{ .query = "WITH [[5, 6], [7]] AS ls UNWIND ls AS u MATCH (n:G) WHERE n.i IN u SET n.x = 1 RETURN u AS u, n.i AS i", .want = &.{ "[5;6]|5", "[5;6]|6", "[7]|7" }, .checks = &gx(&.{ "5", "6", "7" }) },
        // A parameter bound by the WITH is the caller's: not freed.
        .{ .query = "WITH $rows AS rows MATCH (n:G) WHERE n.i = 5 SET n.x = 1 RETURN size(rows) AS c, rows AS r", .rows_param = true, .want = &.{"3|[{id:1;name:n1};{id:2;name:n2};{id:3;name:n3}]"}, .checks = &gx(&.{"5"}) },
        // No row: nothing runs.
        .{ .query = "WITH [5, 6] AS ids WHERE size(ids) > 5 MATCH (n:G) SET n.x = 1", .checks = &.{
            .{ .query = "MATCH (n) WHERE n.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
        } },
    });
}

// ---------------------------------------------------------------------------
// 2. An UNWIND before a write.

test "SONNY-3148: an UNWIND before a write frees the list it evaluated, and a RETURN of an element or of the list returns a copy" {
    try runShapes("UNWIND", &.{
        .{ .query = "WITH $rows AS rows UNWIND rows AS r CREATE (:U {id: r.id})", .rows_param = true, .checks = &.{
            .{ .query = "MATCH (u:U) RETURN u.id", .want = &.{ "1", "2", "3" } },
        } },
        .{ .query = "WITH $rows AS rows UNWIND rows AS r CREATE (:U {id: r.id, name: r.name})", .rows_param = true, .checks = &.{
            .{ .query = "MATCH (u:U) RETURN u.id, u.name", .want = &.{ "1|n1", "2|n2", "3|n3" } },
        } },
        .{ .query = "WITH 1 AS one UNWIND [5, 6, 7] AS u MATCH (n:G) WHERE n.i = u SET n.x = 1", .checks = &gx(&.{ "5", "6", "7" }) },
        .{ .query = "WITH [5, 6] AS l UNWIND l AS u MATCH (n:G) WHERE n.i = u SET n.x = 1", .checks = &gx(&.{ "5", "6" }) },
        .{ .query = "WITH [5, 6] AS l UNWIND l AS u MATCH (n:G) WHERE n.i = u SET n.x = 1 RETURN u AS u, l AS l", .want = &.{ "5|[5;6]", "6|[5;6]" }, .checks = &gx(&.{ "5", "6" }) },
        .{ .query = "WITH 1 AS one UNWIND [[5, 6], [7]] AS u MATCH (n:G) WHERE n.i IN u SET n.x = 1 RETURN u AS u, n.i AS i", .want = &.{ "[5;6]|5", "[5;6]|6", "[7]|7" }, .checks = &gx(&.{ "5", "6", "7" }) },
        .{ .query = "WITH 1 AS one UNWIND [toUpper('a'), toUpper('b')] AS u CREATE (:U {id: u})", .checks = &.{
            .{ .query = "MATCH (u:U) RETURN u.id", .want = &.{ "A", "B" } },
        } },
        .{ .query = "WITH 1 AS one UNWIND [{k: 5}, {k: 6}] AS m MATCH (n:G) WHERE n.i = m.k SET n.x = 1 RETURN m AS m", .want = &.{ "{k:5}", "{k:6}" }, .checks = &gx(&.{ "5", "6" }) },
    });
}

// ---------------------------------------------------------------------------
// 3. A WITH after the MATCH, before a write.

test "SONNY-3148: a WITH stage before a write frees the items it computed, and a RETURN of one returns a copy" {
    try runShapes("WITH stage", &.{
        .{ .query = "MATCH (n:G) WITH n, n.i + 1 AS k WHERE k > 7 SET n.x = k", .checks = &.{
            .{ .query = "MATCH (n:G) WHERE n.x IS NOT NULL RETURN n.i, n.x", .want = &.{ "7|8", "8|9", "9|10" } },
        } },
        .{ .query = "MATCH (n:G) WITH n, n.g || '-x' AS s WHERE n.i >= 8 SET n.s = s", .checks = &.{
            .{ .query = "MATCH (n:G) WHERE n.s IS NOT NULL RETURN n.i, n.s", .want = &.{ "8|b-x", "9|b-x" } },
        } },
        .{ .query = "MATCH (n:G) WITH n, n.g || '-x' AS s WHERE n.i >= 8 SET n.s = s RETURN s AS s, n.i AS i", .want = &.{ "b-x|8", "b-x|9" }, .checks = &.{
            .{ .query = "MATCH (n:G) WHERE n.s IS NOT NULL RETURN n.i, n.s", .want = &.{ "8|b-x", "9|b-x" } },
        } },
        .{ .query = "MATCH (n:G)-[:R]->(x:X) WITH x, [n.g, 'y'] AS l, {g: n.g} AS m WHERE x.j = 5 SET x.x = 1 RETURN l AS l, m AS m", .want = &.{"[b;y]|{g:b}"}, .checks = &xx(&.{"5"}) },
        .{ .query = "MATCH (n:G) WITH DISTINCT n.g || '-z' AS s MERGE (m:M {g: s})", .checks = &.{
            .{ .query = "MERGE (m:M {g: 'a-z'}) RETURN m.g AS g", .want = &.{"a-z"} },
            .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "a-z", "b-z" } },
        } },
        .{ .query = "MATCH (n:G) WHERE n.i < 2 WITH n, toUpper(n.g) AS u CREATE (n)-[:T]->(:Z {u: u})", .checks = &.{
            .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, z.u", .want = &.{ "0|A", "1|A" } },
        } },
        .{ .query = "MATCH (q:Q) WITH q, q.name || '!' AS s WHERE q.i < 2 DELETE q", .checks = &.{
            .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "2", "3" } },
        } },
    });
}

// ---------------------------------------------------------------------------
// 4. A path variable over a fixed single-hop pattern.

test "SONNY-3148: a single-hop path variable frees its node and edge arrays unless a row returns the path, which keeps them" {
    try runShapes("single-hop path", &.{
        .{ .query = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i >= 5 RETURN length(p) AS len", .want = &.{ "1", "1", "1", "1", "1" } },
        .{ .query = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 SET x.x = 1", .checks = &xx(&.{"5"}) },
        .{ .query = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 SET x.x = 1 RETURN length(p) AS len", .want = &.{"1"}, .checks = &xx(&.{"5"}) },
        // The residual: a row that returns the path keeps its arrays.
        .{ .query = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 RETURN p, length(p) AS len", .want = &.{"<Path 2:1>|1"}, .residual_bytes = path_bytes },
        .{ .query = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 SET x.x = 1 RETURN p, length(p) AS len", .want = &.{"<Path 2:1>|1"}, .checks = &xx(&.{"5"}), .residual_bytes = path_bytes },
        .{ .query = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DETACH DELETE p", .checks = &.{
            .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"9"} },
            .{ .query = "MATCH (x:X) RETURN count(*) AS c", .want = &.{"9"} },
        }, .residual_bytes = path_bytes },
    });
}

// ---------------------------------------------------------------------------
// 5. The relationship variable of a variable-length pattern.

test "SONNY-3148: a variable-length relationship variable frees its edge list, read by a WITH, a write step or a DELETE" {
    try runShapes("variable-length relationship", &.{
        .{ .query = "MATCH (n:G)-[r:R*1..2]->(x:X) WHERE n.i = 5 RETURN size(r) AS s", .want = &.{"1"} },
        .{ .query = "MATCH (n:G)-[r:R*1..2]->(x:X) WHERE n.i = 5 RETURN r AS rels, size(r) AS s", .want = &.{"[<Edge>]|1"} },
        .{ .query = "MATCH (n:G)-[r:R*1..2]->(x:X) WHERE n.i = 5 SET x.x = 1", .checks = &xx(&.{"5"}) },
        .{ .query = "MATCH (n:G)-[r:R*1..2]->(x:X) WHERE n.i = 5 SET x.x = 1 RETURN size(r) AS s", .want = &.{"1"}, .checks = &xx(&.{"5"}) },
        .{ .query = "MATCH (n:G)-[r:R*1..1]->(x:X) WHERE n.i = 5 DELETE r", .checks = &.{
            .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
            .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"10"} },
        } },
        .{ .query = "MATCH (n:G)-[r:R*1..1]->(x:X) WHERE n.i = 5 SET n.z = 1 DELETE r", .checks = &.{
            .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
            .{ .query = "MATCH (n:G) WHERE n.z = 1 RETURN n.i", .want = &.{"5"} },
        } },
        .{ .query = "MATCH (n:G)-[r:R*1..2]->(x:X) WITH n, r WHERE n.i = 5 SET n.x = 1 RETURN size(r) AS s, r AS rels", .want = &.{"1|[<Edge>]"}, .checks = &gx(&.{"5"}) },
    });
}
