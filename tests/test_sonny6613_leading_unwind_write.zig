// SONNY-6613 task 1: a statement-leading UNWIND that writes is the FOR it is
// read as, and writes exactly what that FOR writes.
//
// `UNWIND [0] AS i CREATE ...` was a syntax error (42000): the parser took
// UNWIND only after another clause. test-sonny3139-write-shapes and
// test-sonny-write-allowlist-r4-transport pinned that refusal for that reason
// alone ("a statement cannot begin with UNWIND"), not for a write-shape
// hazard. Since the leading UNWIND is parsed as ISO/IEC 39075:2024 14.8
// `FOR i IN [0] ...` (a Geode extension, SONNY-6613 item 2), the statement
// runs. This proves it writes what the FOR does: one CREATE per element, no
// rows without a RETURN, its rows with one, nothing for an empty list, all or
// nothing when an element fails, nothing past the write budget; in the
// in-memory, plain persisted (read back after a reload), tenant-scoped and
// RLS-policy sessions. The QUIC and gRPC parity and the transaction checks
// are in tests/test_sonny_write_allowlist_r4_transport.zig.
//
// CANARY: REQ=REQ-SONNY-6613-LEADING-UNWIND; FEATURE="Unwind"; ASPECT=StatementLeadingWrite; STATUS=TESTED; TEST=tests/test_sonny6613_leading_unwind_write.zig; OWNER=engine; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");

const write_budget = geode.write_budget;

const Case = h.Case;
const Check = h.Check;

const no_u = [_]Check{.{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"0"} }};

/// Each write as a leading UNWIND and as the FOR it is read as: both must
/// answer and write the same.
const Pair = struct {
    unwind: []const u8,
    @"for": []const u8,
    want: ?[]const []const u8 = null,
    refused: ?anyerror = null,
    checks: []const Check,
};

const pairs = [_]Pair{
    // One CREATE per element; no RETURN, no rows.
    .{ .unwind = "UNWIND [0, 1, 2] AS i CREATE (:U {i: i})", .@"for" = "FOR i IN [0, 1, 2] CREATE (:U {i: i})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.i", .want = &.{ "0", "1", "2" } },
    } },
    // The ticket's statement.
    .{ .unwind = "UNWIND [0] AS i CREATE (:U {i: i})", .@"for" = "FOR i IN [0] CREATE (:U {i: i})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.i", .want = &.{"0"} },
    } },
    // An empty list writes nothing.
    .{ .unwind = "UNWIND [] AS i CREATE (:U {i: i})", .@"for" = "FOR i IN [] CREATE (:U {i: i})", .want = &.{}, .checks = &no_u },
    // A path per element: two nodes and a relationship each.
    .{ .unwind = "UNWIND [1, 2] AS i CREATE (a:U {i: i})-[:T]->(b:U {i: i + 10})", .@"for" = "FOR i IN [1, 2] CREATE (a:U {i: i})-[:T]->(b:U {i: i + 10})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (a:U)-[:T]->(b:U) RETURN a.i, b.i", .want = &.{ "1|11", "2|12" } },
        .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"4"} },
    } },
    // A RETURN answers a row per element.
    .{ .unwind = "UNWIND [1, 2] AS i CREATE (n:U {i: i}) RETURN n.i AS i", .@"for" = "FOR i IN [1, 2] CREATE (n:U {i: i}) RETURN n.i AS i", .want = &.{ "1", "2" }, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.i", .want = &.{ "1", "2" } },
    } },
    // A MATCH ... SET body runs per element over the session's rows only.
    // (With no RETURN it answers the matched rows, as a statement-level
    // MATCH ... SET does in Geode, match_operations.executeSetRemoveStep; the
    // rows are pinned by the RETURN form below.)
    .{ .unwind = "UNWIND [5, 6] AS i MATCH (n:G) WHERE n.i = i SET n.x = 1", .@"for" = "FOR i IN [5, 6] MATCH (n:G) WHERE n.i = i SET n.x = 1", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{ "5", "6" } },
    } },
    .{ .unwind = "UNWIND [5, 6] AS i MATCH (n:G) WHERE n.i = i SET n.x = i RETURN n.i AS i, n.x AS x", .@"for" = "FOR i IN [5, 6] MATCH (n:G) WHERE n.i = i SET n.x = i RETURN n.i AS i, n.x AS x", .want = &.{ "5|5", "6|6" }, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x IS NOT NULL RETURN n.i", .want = &.{ "5", "6" } },
    } },
    // A MERGE body: the second element matches what the first created.
    .{ .unwind = "UNWIND [7, 7, 8] AS i MERGE (m:U {i: i})", .@"for" = "FOR i IN [7, 7, 8] MERGE (m:U {i: i})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.i", .want = &.{ "7", "8" } },
    } },
    // An element that fails fails the statement whole: the first element's
    // node is not left behind.
    .{ .unwind = "UNWIND [1, 0] AS i CREATE (:U {v: 10 / i})", .@"for" = "FOR i IN [1, 0] CREATE (:U {v: 10 / i})", .refused = error.DivisionByZero, .checks = &no_u },
    // A write the FOR body does not apply is refused before anything runs.
    .{ .unwind = "UNWIND [1, 2] AS v CREATE (z:U {k: v}) DELETE z", .@"for" = "FOR v IN [1, 2] CREATE (z:U {k: v}) DELETE z", .refused = error.WriteClauseNotApplied, .checks = &no_u },
};

test "SONNY-6613 task 1: a leading UNWIND parses to the very FOR statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    for (pairs) |p| {
        var pu = try geode.parseGql(p.unwind, aa);
        defer pu.deinit();
        var pf = try geode.parseGql(p.@"for", aa);
        defer pf.deinit();
        const su = pu.program.statements[0];
        const sf = pf.program.statements[0];
        try testing.expect(su == .For);
        try testing.expect(sf == .For);
        try testing.expectEqualStrings(sf.For.variable, su.For.variable);
        try testing.expectEqual(sf.For.body != null, su.For.body != null);
        try testing.expectEqual(sf.For.return_clause != null, su.For.return_clause != null);
        try testing.expectEqual(@as(?[]const u8, null), su.For.ordinality_var);
        try testing.expectEqual(@as(?[]const u8, null), su.For.offset_var);
    }
}

test "SONNY-6613 task 1: a leading UNWIND that writes writes what its FOR writes, in every session" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var cases: [pairs.len * 2]Case = undefined;
    for (pairs, 0..) |p, i| {
        cases[2 * i] = .{ .write = p.unwind, .want = p.want, .refused = p.refused, .checks = p.checks };
        cases[2 * i + 1] = .{ .write = p.@"for", .want = p.want, .refused = p.refused, .checks = p.checks };
    }
    try h.runCases("leading UNWIND write", &cases);
}

test "SONNY-6613 task 1: a leading UNWIND past the write budget answers 53200 and writes nothing, as its FOR" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var f: h.Failures = .{ .arena = aa };
    // 2,000 nodes (range's end is exclusive) of a 512-byte string each: about 1 MB of undo images, over
    // a 256 KB budget.
    const pad = "p" ** 512;
    const forms = [_][]const u8{
        "UNWIND range(0, 2000) AS i CREATE (:U {i: i, s: '" ++ pad ++ "'})",
        "FOR i IN range(0, 2000) CREATE (:U {i: i, s: '" ++ pad ++ "'})",
    };
    for (h.all_modes) |mode| {
        for (forms) |q| {
            var s = try h.Session.init(mode);
            defer s.deinit();
            try s.seed();
            write_budget.setBudgetBytesForTest(256 * 1024);
            const got = s.run(q);
            write_budget.setBudgetBytesForTest(0);
            if (got) |r| {
                var result = r;
                result.deinit(s.arena.allocator());
                try f.add("[{s}] {s}: expected WriteQueryBudgetExceeded, it ran", .{ @tagName(mode), q[0..20] });
            } else |err| if (err != error.WriteQueryBudgetExceeded) {
                try f.add("[{s}] {s}: expected WriteQueryBudgetExceeded, got {s}", .{ @tagName(mode), q[0..20], @errorName(err) });
            }
            try h.expectEffect(&s, &f, "nothing written", q[0..20], "MATCH (u:U) RETURN count(*) AS c", &.{"0"});
            // Without the budget the same statement runs.
            var ok = s.run(q) catch |err| {
                try f.add("[{s}] {s}: unbudgeted: {s}", .{ @tagName(mode), q[0..20], @errorName(err) });
                continue;
            };
            ok.deinit(s.arena.allocator());
            try h.expectEffect(&s, &f, "written", q[0..20], "MATCH (u:U) RETURN count(*) AS c", &.{"2000"});
        }
    }
    try f.finish("leading UNWIND write budget");
}
