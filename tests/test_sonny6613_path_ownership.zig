// SONNY-6613 item 1: a path value a result keeps is the result's to free.
//
// `freeValue` (src/execution/value_utilities.zig) never freed a path's node
// and relationship arrays and `duplicateValue` copied a path by reference,
// so every row that kept a path leaked its arrays (`MATCH p = ... RETURN p`
// on any session; tests/test_sonny3046_with_bound_variable_join.zig ran
// such statements on an arena, `path_leak`). The ownership model: a path in
// a result row owns its arrays (allocated on the result's allocator); the
// nodes and edges they point at stay the store's or the result's entity
// tracker's. Each statement here runs on a leak-checked DebugAllocator in
// every session kind (in memory, persisted, tenant-scoped, RLS policy).
//
// CANARY: REQ=REQ-SONNY-6613-PATH-OWNERSHIP; FEATURE="PathValues"; ASPECT=ResultOwnsPathArrays; STATUS=TESTED; TEST=tests/test_sonny6613_path_ownership.zig; OWNER=engine; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const harness = @import("read_semantics_batch_harness.zig");
const leak = @import("statement_leak_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (a:P6613 {k: 1})-[:R6613]->(b:P6613 {k: 2})-[:R6613]->(c:P6613 {k: 3})" },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN p", .want = &.{"<Path 1 2 R6613>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN p", .want = &.{ "<Path 1 2 R6613>", "<Path 1 2 3 R6613 R6613>" } },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) WITH p RETURN p", .want = &.{"<Path 1 2 R6613>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN p ORDER BY length(p)", .want = &.{ "<Path 1 2 R6613>", "<Path 1 2 3 R6613 R6613>" }, .ordered = true },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN DISTINCT p", .want = &.{"<Path 1 2 R6613>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN collect(p) AS ps", .want = &.{"[<Path 1 2 R6613>, <Path 1 2 3 R6613 R6613>]"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN length(p) AS n, size(nodes(p)) AS v, size(relationships(p)) AS e", .want = &.{ "1, 2, 1", "2, 3, 2" } },
    .{ .q = "MATCH p = shortestPath((a:P6613 {k: 1})-[:R6613*]->(c:P6613 {k: 3})) RETURN p", .want = &.{"<Path 1 2 3 R6613 R6613>"} },
    // Where else a kept path goes: nested in a list or a map, a multi-hop
    // pattern, a second MATCH, a window, a WITH that filters, a set
    // operation's parts. The harness reads each path through its arrays.
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN [p] AS ps", .want = &.{"[<Path 1 2 R6613>]"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN {path: p} AS m", .want = &.{"<Map>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b)-[:R6613]->(c) RETURN p", .want = &.{"<Path 1 2 3 R6613 R6613>"} },
    .{ .q = "MATCH (x:P6613 {k: 1}) MATCH p = (x)-[:R6613]->(b) RETURN p", .want = &.{"<Path 1 2 R6613>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN p ORDER BY length(p) SKIP 1 LIMIT 1", .want = &.{"<Path 1 2 3 R6613 R6613>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) WITH p, length(p) AS n WHERE n > 1 RETURN p, n", .want = &.{"<Path 1 2 3 R6613 R6613>, 2"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN p UNION ALL MATCH p = (a:P6613 {k: 2})-[:R6613]->(b) RETURN p", .want = &.{ "<Path 1 2 R6613>", "<Path 2 3 R6613>" } },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN p UNION MATCH p = (a:P6613 {k: 2})-[:R6613]->(b) RETURN p", .want = &.{ "<Path 1 2 R6613>", "<Path 2 3 R6613>" } },
};

test "SONNY-6613 item 1: a path a result keeps leaks nothing, in every session" {
    try harness.inEveryMode("SONNY-6613 path ownership", &cases);
}

// An allocation failure at every point of a statement that keeps a path
// (`leak.sweep`: the N-th allocation fails, N = 0, 1, ... until a run
// reaches none) leaks nothing and frees nothing twice, and every run that
// answers reads each path through its arrays. The statements run as an
// embedded caller runs them, so the result is also copied out of the
// statement's scratch arena (`execution.detachFromStatementScratch`).
const sweep_visible = [_][]const u8{
    "CREATE (:P {k: 0})-[:R {w: 1}]->(:Q {k: 0})-[:R {w: 2}]->(:X {k: 0})",
};

const sweep_hidden = [_][]const u8{
    "CREATE (:P{H} {k: 9})-[:R]->(:Q{H} {k: 9})",
};

const sweep_shapes = [_][]const u8{
    "MATCH p = (a:P)-[:R]->(b) RETURN p",
    "MATCH p = (a:P)-[:R*1..2]->(b) RETURN p",
    "MATCH p = (a:P)-[:R]->(b) WITH p RETURN p",
    "MATCH p = (a:P)-[:R*1..2]->(b) RETURN collect(p) AS ps",
    "MATCH p = (a:P)-[:R*1..2]->(b) RETURN p ORDER BY length(p) LIMIT 1",
    "MATCH p = (a:P)-[:R]->(b)-[:R]->(c) RETURN p",
    "MATCH p = shortestPath((a:P)-[:R*]->(c:X)) RETURN p",
    "MATCH p = (a:P)-[:R]->(b) RETURN p UNION ALL MATCH p = (a:Q)-[:R]->(b) RETURN p",
};

/// The most runs one shape may take (its allocation count bounds it).
const max_runs = 6000;

fn sweepAll(mode: leak.Mode) !void {
    var s = try leak.Session.init(mode);
    defer s.deinit();
    try s.seed(&sweep_visible, &sweep_hidden);
    var failures: usize = 0;
    for (sweep_shapes) |q| {
        const r = try leak.sweep(&s, q, &.{}, max_runs);
        const bad = r.leaks.items.len > 0 or r.wrong_errors.items.len > 0 or r.swallowed.items.len > 0 or !r.completed;
        if (bad) {
            failures += 1;
            std.debug.print("[{s}] {s}: {d} runs, completed={}, leaks at {any}, swallowed at {any}, wrong errors {d}\n", .{ @tagName(mode), q, r.runs, r.completed, r.leaks.items[0..@min(8, r.leaks.items.len)], r.swallowed.items[0..@min(8, r.swallowed.items.len)], r.wrong_errors.items.len });
            for (r.wrong_errors.items[0..@min(4, r.wrong_errors.items.len)]) |we| std.debug.print("    failure at allocation {d} answered {s}\n", .{ we[0], @errorName(we[1]) });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6613 item 1: a path statement frees what it built when any allocation fails: in memory" {
    try sweepAll(.in_memory);
}

test "SONNY-6613 item 1: a path statement frees what it built when any allocation fails: persisted" {
    try sweepAll(.persisted);
}

test "SONNY-6613 item 1: a path statement frees what it built when any allocation fails: tenant-scoped" {
    try sweepAll(.tenant_scoped);
}

test "SONNY-6613 item 1: a path statement frees what it built when any allocation fails: RLS policy" {
    try sweepAll(.rls_policy);
}
