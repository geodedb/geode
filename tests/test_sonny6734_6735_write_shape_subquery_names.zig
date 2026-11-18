// SONNY-6734: a COUNT { } or EXISTS { } that only reads is accepted in a value
// the statement computes (a SET value, a CREATE property value, an item of
// the WITH before the write), as ISO/IEC 39075:2024 allows a value expression
// subquery there. Before, the write-shape allowlist refused any such
// statement with 0A000. Still refused: a subquery in a WHERE (SONNY-3184),
// one that names a variable no clause binds, and one that writes (SONNY-3182).
//
// SONNY-6735: the allowlist's variable-name set held at most 64 names, and a
// CREATE naming more got the generic 0A000. It grows now (to 4096 distinct
// names); past that the statement is refused with 54000 naming the limit.
//
// CANARY: REQ=REQ-SONNY-6734-VALUE-SUBQUERY; FEATURE="WriteShapeAllowlist"; ASPECT=ValueSubquery; STATUS=TESTED; TEST=tests/test_sonny6734_6735_write_shape_subquery_names.zig; OWNER=engine; UPDATED=2026-11-17
// CANARY: REQ=REQ-SONNY-6735-NAME-LIMIT; FEATURE="WriteShapeAllowlist"; ASPECT=NameLimit; STATUS=TESTED; TEST=tests/test_sonny6734_6735_write_shape_subquery_names.zig; OWNER=engine; UPDATED=2026-11-17

const std = @import("std");
const testing = std.testing;
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;
const Check = h.Check;

const refused = error.WriteClauseNotApplied;

// The seed: ten (:G {i})-[:R]->(:X {j}) pairs, four :Q. A tenant session
// counts its own 10 :X only, an RLS session no :Hidden one.
const four_c = [_]Check{
    .{ .query = "MATCH (c:C) RETURN c.n", .want = &.{ "10", "10", "10", "10" } },
};

const nothing_written = [_]Check{
    .{ .query = "MATCH (n) WHERE n.hit IS NOT NULL OR n.c IS NOT NULL OR n.n IS NOT NULL OR n.d IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (c:C) RETURN count(*) AS c", .want = &.{"0"} },
};

const value_cases = [_]Case{
    // The ticket's repro.
    .{ .write = "MATCH (q:Q) CREATE (:C {n: COUNT { MATCH (x:X) }})", .checks = &four_c },
    .{ .write = "MATCH (q:Q) CREATE (:C {n: COUNT { (x:X) }})", .checks = &four_c },
    // A SET value, correlated with the matched node.
    .{ .write = "MATCH (g:G) WHERE g.i < 3 SET g.d = COUNT { (g)-[:R]->() }", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d IS NOT NULL RETURN g.i, g.d", .want = &.{ "0|1", "1|1", "2|1" } },
    } },
    .{ .write = "MATCH (g:G) WHERE g.i < 3 SET g.d = EXISTS { (g)-[:R]->(:X) }", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d IS NOT NULL RETURN g.i, g.d", .want = &.{ "0|true", "1|true", "2|true" } },
    } },
    // The subquery's own WHERE reads its own variable (SONNY-3184: it read
    // false): g.i = 9 reaches x.j = 9 >= 8, g.i = 1 does not.
    .{ .write = "MATCH (g:G) WHERE g.i = 9 OR g.i = 1 SET g.d = COUNT { MATCH (g)-[:R]->(x:X) WHERE x.j >= 8 }", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d IS NOT NULL RETURN g.i, g.d", .want = &.{ "1|0", "9|1" } },
    } },
    // A client parameter inside the subquery.
    .{ .write = "MATCH (g:G) WHERE g.i = 1 SET g.d = COUNT { (g)-[:R]->(x:X) WHERE x.j = 1 }", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d IS NOT NULL RETURN g.i, g.d", .want = &.{"1|1"} },
    } },
    // A WITH item before the write, also inside an aggregate (the pagerank
    // form of geode_advanced_math_algorithms).
    .{ .write = "MATCH (g:G)-[:R]->(x:X) WITH x, sum(g.i + COUNT { (g)-[:R]->() }) AS s SET x.rank = s RETURN count(DISTINCT x) AS updated", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.rank IS NOT NULL RETURN x.j, x.rank", .want = &.{ "0|1", "1|2", "2|3", "3|4", "4|5", "5|6", "6|7", "7|8", "8|9", "9|10" } },
    } },
    .{ .write = "MATCH (g:G) WITH g, COUNT { (g)-[:R]->() } AS k SET g.d = k + 1", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d = 2 RETURN count(*) AS c", .want = &.{"10"} },
    } },
};

// The values a FOR, an initial WITH or an UNWIND binds around the part.
const bound_value_cases = [_]Case{
    .{ .write = "UNWIND [1, 2] AS u MATCH (g:G) WHERE g.i = u SET g.d = COUNT { (g)-[:R]->(x:X) WHERE x.j = u }", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d IS NOT NULL RETURN g.i, g.d", .want = &.{ "1|1", "2|1" } },
    } },
    .{ .write = "WITH 3 AS u MATCH (g:G) WHERE g.i = u SET g.d = COUNT { (g)-[:R]->(x:X) WHERE x.j = u }", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d IS NOT NULL RETURN g.i, g.d", .want = &.{"3|1"} },
    } },
    .{ .write = "FOR u IN [4, 5] MATCH (g:G) WHERE g.i = u SET g.d = COUNT { (g)-[:R]->(x:X) WHERE x.j = u }", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.d IS NOT NULL RETURN g.i, g.d", .want = &.{ "4|1", "5|1" } },
    } },
};

const refused_cases = [_]Case{
    // A WHERE keeps refusing it (SONNY-3184).
    .{ .write = "MATCH (g:G) WHERE EXISTS { (g)-[:R]->(:X) } SET g.d = 1", .refused = refused, .checks = &nothing_written },
    .{ .write = "MATCH (g:G) WITH g WHERE COUNT { (g)-[:R]->() } > 0 SET g.d = 1", .refused = refused, .checks = &nothing_written },
    // A pattern comprehension and shortestPath() keep refusing.
    .{ .write = "MATCH (g:G) SET g.d = size([(g)-[:R]->(x) | x.j])", .refused = refused, .checks = &nothing_written },
    // A MERGE's keys.
    .{ .write = "MERGE (m:M {k: COUNT { (x:X) }})", .refused = refused, .checks = &nothing_written },
    // A write inside the subquery (SONNY-3182): refused, and a write.
    .{ .write = "MATCH (q:Q) SET q.d = COUNT { (x:X) WHERE 1 IN (MATCH (w:Q) SET w.hit = 1 RETURN 1) }", .refused = refused, .checks = &nothing_written },
    .{ .write = "MATCH (q:Q) CREATE (:C {n: COUNT { (x:X) WHERE 1 IN (MATCH (w:Q) SET w.hit = 1 RETURN 1) }})", .refused = refused, .checks = &nothing_written },
    // A client parameter nobody supplied, named inside the subquery.
    .{ .write = "MATCH (q:Q) SET q.d = COUNT { (x:X) WHERE x.j = $nope }", .refused = error.MissingParameter, .checks = &nothing_written },
    // A name no clause binds.
    .{ .write = "MATCH (q:Q) SET q.d = COUNT { (x:X) WHERE nosuch.j = x.j }", .refused = error.VariableNotInScope, .checks = &nothing_written },
};

test "SONNY-6734: a COUNT or EXISTS subquery that only reads is accepted in a value" {
    h.execution.initEvaluator();
    try h.runCases("SONNY-6734 accepted", &value_cases);
}

test "SONNY-6734: a subquery reads the values a FOR, an initial WITH or an UNWIND binds" {
    h.execution.initEvaluator();
    try h.runCases("SONNY-6734 bound values", &bound_value_cases);
}

test "SONNY-6734: a subquery in a WHERE, one that writes or names an unbound variable stays refused" {
    try h.runCases("SONNY-6734 refused", &refused_cases);
}

/// `CREATE (n0:K {i: 0}), (n1:K {i: 1}), ...` with `count` named nodes.
fn manyNames(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "CREATE ");
    for (0..count) |i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        const piece = try std.fmt.allocPrint(allocator, "(n{d}:K {{i: {d}}})", .{ i, i });
        defer allocator.free(piece);
        try out.appendSlice(allocator, piece);
    }
    return out.toOwnedSlice(allocator);
}

test "SONNY-6735: a CREATE with 100 and 1000 named variables writes every node, in every session" {
    for (h.all_modes) |mode| {
        for ([_]usize{ 65, 100, 1000 }) |count| {
            var s = try h.Session.init(mode);
            defer s.deinit();
            try s.seed();
            const aa = s.arena.allocator();
            const q = try manyNames(aa, count);
            var r = try s.run(q);
            r.deinit(aa);
            const want = try std.fmt.allocPrint(aa, "{d}", .{count});
            var f: h.Failures = .{ .arena = aa };
            try h.expectRows(&s, &f, "count", q, "MATCH (k:K) RETURN count(*) AS c", &.{want});
            try f.finish("SONNY-6735 many names");
        }
    }
}

test "SONNY-6735: a MATCH ... CREATE naming 100 variables reads them in a SET value" {
    var s = try h.Session.init(.in_memory);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(aa, "MATCH (g:G) WHERE g.i = 1 CREATE ");
    for (0..100) |i| {
        if (i != 0) try q.appendSlice(aa, ", ");
        try q.appendSlice(aa, try std.fmt.allocPrint(aa, "(g)-[:E]->(n{d}:K {{i: {d}}})", .{ i, i }));
    }
    try q.appendSlice(aa, " SET g.last = n99.i");
    var r = try s.run(q.items);
    r.deinit(aa);
    var f: h.Failures = .{ .arena = aa };
    try h.expectRows(&s, &f, "edges", "edges", "MATCH (:G {i: 1})-[e:E]->(:K) RETURN count(*) AS c", &.{"100"});
    try h.expectRows(&s, &f, "last", "last", "MATCH (g:G {i: 1}) RETURN g.last", &.{"99"});
    try f.finish("SONNY-6735 names in a MATCH ... CREATE");
}

test "SONNY-6735: past 4096 distinct variables the refusal names the limit and nothing is written" {
    var s = try h.Session.init(.in_memory);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();
    const q = try manyNames(aa, 4100);
    if (s.run(q)) |r| {
        var result = r;
        result.deinit(aa);
        return error.TestExpectedRefusal;
    } else |err| try testing.expectEqualStrings("TooManyWriteVariables", @errorName(err));
    var f: h.Failures = .{ .arena = aa };
    try h.expectRows(&s, &f, "count", q[0..10], "MATCH (k:K) RETURN count(*) AS c", &.{"0"});
    try f.finish("SONNY-6735 limit");
}
