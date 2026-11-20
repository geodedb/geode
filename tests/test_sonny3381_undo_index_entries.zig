// SONNY-3381 regression: statement and transaction undo revert the vector
// and full-text index entries of what they undo.
//
// The executor keeps the vector (HNSW) and full-text indexes current beside
// the graph store's write methods (`property_mutation.setNodePropertyFromValue`
// and the CREATE / DELETE paths call `fts_index_ops.maintainFulltextOnWrite`
// and the advanced-index maintenance), while the undo of a failed statement
// (`statement_undo`) and of a ROLLBACK (`txn_undo_log`) replays through the
// store's write methods only. After the undo the store held the old value,
// and an index still held the undone one until it was rebuilt: a full-text
// search found a node by a word it no longer contains, missed one whose
// DELETE was undone, and knn() ranked a node by a vector it does not hold.
//
// Through the real gRPC handlers in process, a failed statement (the error
// raised in its RETURN, after it wrote) and a ROLLBACK, then the search the
// undone value would answer.
//
// CANARY: REQ=REQ-SONNY-3381-UNDO-INDEX-REPAIR; FEATURE="Execution"; ASPECT=UndoIndexRegression; STATUS=TESTED; TEST=tests/test_sonny3381_undo_index_entries.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const sa = @import("statement_atomicity_fixture.zig");
const fx = sa.fx;

const rowsOf = sa.rowsOf;
const runs = sa.runs;

fn expectFails(ga: std.mem.Allocator, s: []const u8, query: []const u8) !void {
    const r = try sa.runOn(ga, s, query);
    if (!r.failed()) {
        std.debug.print("{s}: ran; expected it to fail\n", .{query});
        return error.TestUnexpectedResult;
    }
}

fn expectRows(ga: std.mem.Allocator, s: []const u8, what: []const u8, query: []const u8, want: usize) !void {
    const got = try rowsOf(ga, s, query);
    if (got != want) std.debug.print("{s}: '{s}' answers {d} rows; expected {d}\n", .{ what, query, got, want });
    try testing.expectEqual(want, got);
}

test "SONNY-3381: after a failed statement a full-text search answers for the values the store holds" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3381f");

    try runs(ga, s, "CREATE INDEX f3381 FOR (n:D3381) ON (n.body) USING fulltext");
    try runs(ga, s, "CREATE (:D3381 {k: 1, body: 'apple'})");
    try runs(ga, s, "CREATE (:D3381 {k: 2, body: 'pear'})");
    try runs(ga, s, "CREATE (:G3381 {i: 5})-[:E]->(:H3381)");
    try expectRows(ga, s, "seeded", "CALL geode.fts.search('f3381', 'apple')", 1);

    // A SET, then the RETURN fails: the undone word is not found, the old
    // one is.
    const replays0 = geode.statement_undo.replayed_statements_total.load(.monotonic);
    try expectFails(ga, s, "MATCH (d:D3381) WHERE d.k = 1 SET d.body = 'zebra' RETURN 10 / (d.k - 1) AS x");
    try testing.expect(geode.statement_undo.replayed_statements_total.load(.monotonic) > replays0);
    try expectRows(ga, s, "failed SET", "CALL geode.fts.search('f3381', 'zebra')", 0);
    try expectRows(ga, s, "failed SET", "CALL geode.fts.search('f3381', 'apple')", 1);

    // A DETACH DELETE, then a later UNION part fails: the node is back, and
    // found.
    try expectFails(ga, s, "MATCH (d:D3381) WHERE d.k = 2 DETACH DELETE d RETURN 1 AS x UNION ALL MATCH (n:G3381) WHERE n.i = 5 DELETE n RETURN 2 AS x");
    try expectRows(ga, s, "failed DELETE", "MATCH (d:D3381) WHERE d.k = 2 RETURN d", 1);
    try expectRows(ga, s, "failed DELETE", "CALL geode.fts.search('f3381', 'pear')", 1);

    // A REMOVE of the indexed property, then the RETURN fails.
    try expectFails(ga, s, "MATCH (d:D3381) WHERE d.k = 2 REMOVE d.body RETURN 10 / (d.k - 2) AS x");
    try expectRows(ga, s, "failed REMOVE", "CALL geode.fts.search('f3381', 'pear')", 1);

    // A CREATE, then the RETURN fails: the node is gone, and not found.
    try expectFails(ga, s, "CREATE (d:D3381 {k: 3, body: 'kiwi'}) RETURN 10 / (d.k - 3) AS x");
    try expectRows(ga, s, "failed CREATE", "CALL geode.fts.search('f3381', 'kiwi')", 0);

    // Live maintenance still works after the repairs.
    try runs(ga, s, "MATCH (d:D3381) WHERE d.k = 1 SET d.body = 'plum'");
    try expectRows(ga, s, "committed SET", "CALL geode.fts.search('f3381', 'plum')", 1);
    try runs(ga, s, "CREATE (:D3381 {k: 4, body: 'fig'})");
    try expectRows(ga, s, "committed CREATE", "CALL geode.fts.search('f3381', 'fig')", 1);
}

test "SONNY-3381: after ROLLBACK a full-text search answers for the values the store holds" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3381r");

    try runs(ga, s, "CREATE INDEX f3381r FOR (n:R3381) ON (n.body) USING fulltext");
    try runs(ga, s, "CREATE (:R3381 {k: 1, body: 'apple'})");
    try runs(ga, s, "CREATE (:R3381 {k: 2, body: 'pear'})");

    try fx.begin(ga, s);
    try runs(ga, s, "MATCH (d:R3381) WHERE d.k = 1 SET d.body = 'mango'");
    try runs(ga, s, "MATCH (d:R3381) WHERE d.k = 2 DETACH DELETE d");
    try runs(ga, s, "CREATE (:R3381 {k: 3, body: 'kiwi'})");
    try testing.expect(try fx.rollback(ga, s));

    try expectRows(ga, s, "ROLLBACK of a SET", "CALL geode.fts.search('f3381r', 'mango')", 0);
    try expectRows(ga, s, "ROLLBACK of a SET", "CALL geode.fts.search('f3381r', 'apple')", 1);
    try expectRows(ga, s, "ROLLBACK of a DELETE", "CALL geode.fts.search('f3381r', 'pear')", 1);
    try expectRows(ga, s, "ROLLBACK of a CREATE", "CALL geode.fts.search('f3381r', 'kiwi')", 0);
}

/// The rows of `label` whose id knn() answers as nearest to `vec`, and whose
/// k is `k`.
fn nearestIs(comptime label: []const u8, comptime vec: []const u8, comptime k: []const u8) []const u8 {
    return "MATCH (v:" ++ label ++ ") WHERE id(v) IN knn('emb3381', vectorf32(" ++ vec ++ "), 1, 'l2') AND v.k = " ++ k ++ " RETURN v";
}

test "SONNY-3381: after a failed statement and after ROLLBACK knn() ranks by the vectors the store holds" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3381v");

    try runs(ga, s, "CREATE INDEX v3381 ON V3381 (emb3381) USING vector WITH (metric = 'l2')");
    try runs(ga, s, "CREATE (:V3381 {k: 1, emb3381: vectorf32([1.0, 0.0, 0.0])})");
    try runs(ga, s, "CREATE (:V3381 {k: 2, emb3381: vectorf32([0.0, 1.0, 0.0])})");
    try runs(ga, s, "CREATE (:V3381 {k: 3})");
    try expectRows(ga, s, "seeded", comptime nearestIs("V3381", "[0.9, 0.1, 0.0]", "1"), 1);

    // The first vector of node 3, then the RETURN fails: node 3 holds no
    // vector, so it is not the nearest to [0, 0, 1].
    try expectFails(ga, s, "MATCH (v:V3381) WHERE v.k = 3 SET v.emb3381 = vectorf32([0.0, 0.0, 1.0]) RETURN 10 / (v.k - 3) AS x");
    try expectRows(ga, s, "failed first SET", "MATCH (v:V3381) WHERE v.k = 3 AND v.emb3381 IS NOT NULL RETURN v", 0);
    try expectRows(ga, s, "failed first SET", comptime nearestIs("V3381", "[0.0, 0.0, 1.0]", "3"), 0);

    // An overwrite of node 1's vector, then the RETURN fails: node 1 is still
    // the nearest to [1, 0, 0].
    try expectFails(ga, s, "MATCH (v:V3381) WHERE v.k = 1 SET v.emb3381 = vectorf32([0.0, -1.0, 0.0]) RETURN 10 / (v.k - 1) AS x");
    try expectRows(ga, s, "failed overwrite", comptime nearestIs("V3381", "[1.0, 0.0, 0.0]", "1"), 1);

    // In a transaction, rolled back.
    try fx.begin(ga, s);
    try runs(ga, s, "MATCH (v:V3381) WHERE v.k = 3 SET v.emb3381 = vectorf32([0.0, 0.0, 1.0])");
    try runs(ga, s, "MATCH (v:V3381) WHERE v.k = 2 SET v.emb3381 = vectorf32([-1.0, 0.0, 0.0])");
    try testing.expect(try fx.rollback(ga, s));
    try expectRows(ga, s, "ROLLBACK of a first SET", comptime nearestIs("V3381", "[0.0, 0.0, 1.0]", "3"), 0);
    try expectRows(ga, s, "ROLLBACK of an overwrite", comptime nearestIs("V3381", "[0.0, 1.0, 0.0]", "2"), 1);

    // A committed first vector is indexed and ranked.
    try runs(ga, s, "MATCH (v:V3381) WHERE v.k = 3 SET v.emb3381 = vectorf32([0.0, 0.0, 1.0])");
    try expectRows(ga, s, "committed SET", comptime nearestIs("V3381", "[0.0, 0.0, 1.0]", "3"), 1);
}
