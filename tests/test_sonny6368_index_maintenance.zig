// SONNY-6368 regression: the full-text and vector indexes the executor keeps
// beside the graph store answer for what the store holds after every kind of
// write, and a repeated SET target answers the GQLSTATE the standard names.
//
//   1. One SET clause assigning one property of an element twice answers
//      22G0M, "data exception - multiple assignments to a graph element
//      property" (ISO/IEC 39075:2024 13.3 General Rule 7 a), IA017). It
//      answered 22G03 (invalid value type).
//   2. `CALL geode.fts.rebuild` from a session on another graph rebuilds the
//      default graph's index, where every fulltext index lives
//      (SONNY-2790, docs/FULLTEXT_SEARCH.md "Graph scope"); it leaves the
//      session's graph alone.
//   3. A live `SET n:L` puts the node into L's full-text and vector indexes.
//      It did neither, so the node was found by neither search.
//   4. A committed `REMOVE n.prop` takes the removed text out of the
//      full-text index. The node stayed findable by the removed word.
//   5. Vector maintenance considers every label of the node. It used only
//      the first, so an index on a second label went stale (SET, CREATE and
//      REMOVE of the vector).
//   6. An undo whose index repair collides with a running rebuild of the same
//      full-text index is not lost: the running rebuild runs again after it.
//      The repair was skipped and logged, and the index kept the undone value
//      the rebuild had read.
//
// Through the real gRPC handlers in process; item 6 calls the real
// `fts_index_ops.rebuildFulltextIndex` and holds it after its backfill
// (`rebuild_backfilled_hook`) while a ROLLBACK runs.
//
// CANARY: REQ=REQ-SONNY-6368-INDEX-MAINTENANCE; FEATURE="Execution"; ASPECT=IndexMaintenanceRegression; STATUS=TESTED; TEST=tests/test_sonny6368_index_maintenance.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const sa = @import("statement_atomicity_fixture.zig");
const fx = sa.fx;

const graph_store = geode.graph_store;
const fts_index_ops = geode.execution.fts_index_ops;

const rowsOf = sa.rowsOf;
const runs = sa.runs;

fn expectRows(ga: std.mem.Allocator, s: []const u8, what: []const u8, query: []const u8, want: usize) !void {
    const got = try rowsOf(ga, s, query);
    if (got != want) std.debug.print("{s}: '{s}' answers {d} rows; expected {d}\n", .{ what, query, got, want });
    try testing.expectEqual(want, got);
}

test "SONNY-6368: a SET clause assigning one property twice answers 22G0M" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6368m");

    try runs(ga, s, "CREATE (:Q6368 {i: 1})");
    _ = try fx.expectRefused(ga, s, "MATCH (q:Q6368 {i: 1}) SET q.c = 1, q.c = 2", "22G0M");
    _ = try fx.expectRefused(ga, s, "MATCH (a:Q6368 {i: 1}), (b:Q6368 {i: 1}) SET a.c = 1, b.c = 2", "22G0M");
    _ = try fx.expectRefused(ga, s, "MERGE (t:T6368 {k: 1}) SET t.a = 1, t.a = 2", "22G0M");
    try expectRows(ga, s, "refused", "MATCH (q:Q6368) WHERE q.c IS NOT NULL RETURN q", 0);
    try expectRows(ga, s, "refused", "MATCH (t:T6368) RETURN t", 0);
}

test "SONNY-6368: geode.fts.rebuild from a session on another graph rebuilds the default graph's index" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const d = try f.session("s6368d");
    const g = try f.session("s6368g");

    try runs(ga, d, "CREATE (:R6368 {body: 'hazel one'})");
    try runs(ga, d, "CREATE (:R6368 {body: 'hazel two'})");
    try runs(ga, d, "CREATE INDEX r6368 FOR (n:R6368) ON (n.body) USING fulltext");
    try runs(ga, g, "USE GRAPH g2");
    try runs(ga, g, "CREATE (:R6368 {body: 'hazel three'})");

    try expectRows(ga, g, "rebuild from g2", "CALL geode.fts.rebuild('r6368')", 1);
    try expectRows(ga, g, "rebuild from g2", "CALL geode.fts.search('r6368', 'hazel')", 2);
    try expectRows(ga, d, "rebuild from g2", "CALL geode.fts.search('r6368', 'hazel')", 2);
    try expectRows(ga, g, "g2 untouched", "MATCH (n:R6368) RETURN n", 1);
}

test "SONNY-6368: a live SET n:L puts the node into L's full-text and vector indexes" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6368l");

    try runs(ga, s, "CREATE INDEX l6368 FOR (n:L6368) ON (n.body) USING fulltext");
    try runs(ga, s, "CREATE INDEX lv6368 ON LV6368 (embl6368) USING vector WITH (metric = 'l2')");
    try runs(ga, s, "CREATE (:LV6368 {k: 0, embl6368: vectorf32([1.0, 0.0, 0.0])})");
    try runs(ga, s, "CREATE (:P6368 {k: 1, body: 'walnut'})");
    try runs(ga, s, "CREATE (:P6368 {k: 2, embl6368: vectorf32([0.0, 1.0, 0.0])})");
    try expectRows(ga, s, "before SET n:L", "CALL geode.fts.search('l6368', 'walnut')", 0);

    try runs(ga, s, "MATCH (p:P6368) WHERE p.k = 1 SET p:L6368");
    try expectRows(ga, s, "SET n:L, fulltext", "CALL geode.fts.search('l6368', 'walnut')", 1);

    // knn() asks the index only while its label is the sole carrier of the
    // property (else it scans), so P6368 gives the property up first.
    try runs(ga, s, "MATCH (p:P6368) WHERE p.k = 2 SET p:LV6368");
    try runs(ga, s, "MATCH (p:LV6368) WHERE p.k = 2 REMOVE p:P6368");
    try expectRows(ga, s, "SET n:L, vector", "MATCH (v:LV6368) WHERE id(v) IN knn('embl6368', vectorf32([0.0, 0.9, 0.1]), 1, 'l2') AND v.k = 2 RETURN v", 1);

    // A SET n:L beside a property SET in one clause, on the MATCH ... SET
    // ... RETURN executor.
    try runs(ga, s, "CREATE (:P6368 {k: 3, body: 'pecan'})");
    try expectRows(ga, s, "SET n:L, n.x RETURN", "MATCH (p:P6368) WHERE p.k = 3 SET p:L6368, p.x = 1 RETURN p.k", 1);
    try expectRows(ga, s, "SET n:L, n.x RETURN", "CALL geode.fts.search('l6368', 'pecan')", 1);
}

test "SONNY-6368: a committed REMOVE n.prop takes the removed text out of the full-text index" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6368r");

    try runs(ga, s, "CREATE (:D6368 {k: 1, body: 'cherry'})");
    try runs(ga, s, "CREATE (:D6368 {k: 2, title: 'almond', body: 'quince'})");
    try runs(ga, s, "CREATE (:D6368 {k: 3, body: 'cherry'})");
    try runs(ga, s, "CREATE INDEX d6368 FOR (n:D6368) ON (n.title, n.body) USING fulltext");
    try expectRows(ga, s, "seeded", "CALL geode.fts.search('d6368', 'cherry')", 2);

    try runs(ga, s, "MATCH (d:D6368) WHERE d.k = 1 REMOVE d.body");
    try expectRows(ga, s, "REMOVE", "CALL geode.fts.search('d6368', 'cherry')", 1);

    // One of two indexed properties: the other stays found.
    try runs(ga, s, "MATCH (d:D6368) WHERE d.k = 2 REMOVE d.title");
    try expectRows(ga, s, "REMOVE one of two", "CALL geode.fts.search('d6368', 'almond')", 0);
    try expectRows(ga, s, "REMOVE one of two", "CALL geode.fts.search('d6368', 'quince')", 1);

    // In a transaction that commits.
    try fx.begin(ga, s);
    try runs(ga, s, "MATCH (d:D6368) WHERE d.k = 3 REMOVE d.body");
    try testing.expect(try fx.commit(ga, s));
    try expectRows(ga, s, "committed REMOVE", "CALL geode.fts.search('d6368', 'cherry')", 0);

    // Live maintenance continues: a value set again is found.
    try runs(ga, s, "MATCH (d:D6368) WHERE d.k = 1 SET d.body = 'damson'");
    try expectRows(ga, s, "SET after REMOVE", "CALL geode.fts.search('d6368', 'damson')", 1);
}

/// The rows of B6368 whose id knn() answers as nearest to `vec` and whose k
/// is `k`.
fn nearestB(comptime vec: []const u8, comptime k: []const u8) []const u8 {
    return "MATCH (v:B6368) WHERE id(v) IN knn('embb6368', vectorf32(" ++ vec ++ "), 1, 'l2') AND v.k = " ++ k ++ " RETURN v";
}

test "SONNY-6368: vector maintenance considers every label of the node, not just the first" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6368v");

    try runs(ga, s, "CREATE INDEX b6368 ON B6368 (embb6368) USING vector WITH (metric = 'l2')");
    try runs(ga, s, "CREATE (:B6368 {k: 0, embb6368: vectorf32([1.0, 0.0, 0.0])})");
    try runs(ga, s, "CREATE (:A6368:B6368 {k: 1})");
    try expectRows(ga, s, "seeded", comptime nearestB("[0.9, 0.1, 0.0]", "0"), 1);

    // knn() asks B6368's index only while B6368 is the sole carrier of the
    // property (else it scans, and the stale index is not seen), so each
    // node gives its first label up before the search.

    // A SET of the vector on a node whose indexed label is its second.
    try runs(ga, s, "MATCH (n:A6368) WHERE n.k = 1 SET n.embb6368 = vectorf32([0.0, 1.0, 0.0])");
    try runs(ga, s, "MATCH (n:A6368) WHERE n.k = 1 REMOVE n:A6368");
    try expectRows(ga, s, "SET on the second label", comptime nearestB("[0.0, 0.9, 0.1]", "1"), 1);

    // A CREATE of such a node.
    try runs(ga, s, "CREATE (:A6368:B6368 {k: 2, embb6368: vectorf32([0.0, 0.0, 1.0])})");
    try runs(ga, s, "MATCH (n:A6368) WHERE n.k = 2 REMOVE n:A6368");
    try expectRows(ga, s, "CREATE on the second label", comptime nearestB("[0.1, 0.0, 0.9]", "2"), 1);

    // A REMOVE of the vector: the node is no longer ranked by it.
    try runs(ga, s, "CREATE (:A6368:B6368 {k: 3, embb6368: vectorf32([0.0, -1.0, 0.0])})");
    try runs(ga, s, "MATCH (n:A6368) WHERE n.k = 3 REMOVE n.embb6368");
    try runs(ga, s, "MATCH (n:A6368) WHERE n.k = 3 REMOVE n:A6368");
    try expectRows(ga, s, "REMOVE on the second label", comptime nearestB("[0.0, -1.0, 0.0]", "3"), 0);
    try expectRows(ga, s, "REMOVE on the second label", comptime nearestB("[0.0, 0.9, 0.1]", "1"), 1);
}

// Item 6: the rebuild held after its backfill, and the ROLLBACK run while
// it is held.
const Collision = struct {
    var ga: std.mem.Allocator = undefined;
    var session: []const u8 = "";
    var fired: std.atomic.Value(u32) = .init(0);
    var rolled_back: bool = false;
    var err: ?anyerror = null;

    fn rollbackOnThread() void {
        rolled_back = fx.rollback(ga, session) catch |e| blk: {
            err = e;
            break :blk false;
        };
    }

    fn hook(index_name: []const u8) void {
        if (!std.mem.eql(u8, index_name, "c6368")) return;
        // Only the first pass: the ROLLBACK lands while the rebuild that
        // read the transaction's value is still running.
        if (fired.fetchAdd(1, .acq_rel) != 0) return;
        const t = std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, rollbackOnThread, .{}) catch |e| {
            err = e;
            return;
        };
        t.join();
    }
};

test "SONNY-6368: an undo whose index repair collides with a running rebuild is not lost" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6368c");

    try runs(ga, s, "CREATE (:C6368 {k: 1, body: 'apple'})");
    try runs(ga, s, "CREATE INDEX c6368 FOR (n:C6368) ON (n.body) USING fulltext");

    try fx.begin(ga, s);
    try runs(ga, s, "MATCH (c:C6368) WHERE c.k = 1 SET c.body = 'zebra'");

    Collision.ga = ga;
    Collision.session = s;
    Collision.fired.store(0, .release);
    Collision.rolled_back = false;
    Collision.err = null;
    fts_index_ops.rebuild_backfilled_hook = &Collision.hook;
    defer fts_index_ops.rebuild_backfilled_hook = null;

    // A rebuild nothing else serializes against the session (an engine-side
    // rebuild, as a restore or snapshot install runs): it reads 'zebra', and
    // the ROLLBACK, and its index repair, run before it finishes.
    const catalog = geode.execution.getCatalogInstanceIfPresent() orelse return error.NoCatalog;
    _ = try fts_index_ops.rebuildFulltextIndex(testing.allocator, catalog, graph_store.DEFAULT_GRAPH_NAME, "c6368");
    fts_index_ops.rebuild_backfilled_hook = null;

    if (Collision.err) |e| return e;
    try testing.expect(Collision.rolled_back);
    try testing.expect(Collision.fired.load(.acquire) >= 1);
    try expectRows(ga, s, "rolled back", "MATCH (c:C6368) WHERE c.body = 'apple' RETURN c", 1);
    try expectRows(ga, s, "repair after the running rebuild", "CALL geode.fts.search('c6368', 'zebra')", 0);
    try expectRows(ga, s, "repair after the running rebuild", "CALL geode.fts.search('c6368', 'apple')", 1);
}
