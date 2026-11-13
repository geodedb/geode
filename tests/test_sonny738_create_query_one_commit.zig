// SONNY-738 (SONNY-2772 / SONNY-3368 follow-up): a CREATE that runs as a
// query part (`CREATE ... RETURN`, `CREATE ... SET`, a FOR body's CREATE)
// commits ONE storage-engine transaction, as a plain `CREATE` statement does.
//
// `crud_operations.executeCreate` (a bare CREATE statement) opens a statement
// transaction so the nodes, labels, properties and relationships it writes
// commit together, with one WAL fsync (R8, SONNY-6425 item 4).
// `executeCreateQuery`, the executor of the query form, opened none: every
// adapter sub-operation committed on its own, a node on whichever shard
// round-robin gave it, so `CREATE (:A {i: 1})-[:E]->(:B {i: 1})` committed
// about seven transactions (seven fsyncs, on seven shards). A FOR body runs
// its CREATE that way once per element: the 1,500-element seed of
// `test-sonny-write-allowlist-r4-transport` committed ~10,500 transactions
// and took 190 s against a spawned server on an ext4 data dir, past the QUIC
// test client's 120 s reply cap.
//
// Counted with the engine's own `txn_committed` metric over the real
// executor and a persisted store; no mocks.
//
// CANARY: REQ=REQ-SONNY-738-CREATE-QUERY-ONE-COMMIT; FEATURE="StatementTxnBatching"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny738_create_query_one_commit.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;

fn committed() !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const mg = try adapter.lookupManagedGraph(graph_store.DEFAULT_GRAPH_NAME);
    return mg.engine.getMetrics().txn_committed;
}

test "SONNY-738: a query-form CREATE commits one engine transaction; a FOR body one per element" {
    h.silenceEngineLogs();
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    // The graph and the labels exist before the measured statements (a
    // statement that creates its graph opens no statement transaction).
    try s.execAs(null, "CREATE (:Q738 {i: 0})-[:E738]->(:Q738b {i: 0})");

    const Case = struct { q: []const u8, commits: u64 };
    const cases = [_]Case{
        .{ .q = "CREATE (:Q738 {i: 1})-[:E738]->(:Q738b {i: 1}) RETURN 1 AS one", .commits = 1 },
        .{ .q = "CREATE (a:Q738 {i: 2})-[:E738]->(b:Q738b {i: 2}) SET a.j = 2, b.j = 2 RETURN a.i", .commits = 1 },
        .{ .q = "CREATE (:Q738 {i: 3, k: 'x'}) RETURN 3 AS three", .commits = 1 },
        .{ .q = "FOR i IN [10, 11, 12, 13] CREATE (:Q738 {i: i})-[:E738]->(:Q738b {i: i})", .commits = 4 },
    };
    var bad: usize = 0;
    // Several rounds: the round-robin shard choice moves on each statement.
    for (0..4) |_| {
        for (cases) |c| {
            const before = try committed();
            try s.execAs(null, c.q);
            const after = try committed();
            if (after - before != c.commits) {
                std.debug.print("{s}: {d} engine transactions committed; expected {d}\n", .{ c.q, after - before, c.commits });
                bad += 1;
            }
        }
    }
    // And what was written is all there.
    var f: h.Failures = .{};
    try h.expectRows(&s, &f, "MATCH (n:Q738) RETURN count(n)", &.{"29"});
    try h.expectRows(&s, &f, "MATCH (:Q738)-[r:E738]->(:Q738b) RETURN count(r)", &.{"25"});
    try h.expectRows(&s, &f, "MATCH (a:Q738 {i: 2})-[:E738]->(b:Q738b) RETURN a.j, b.j, b.i", &.{ "2|2|2", "2|2|2", "2|2|2", "2|2|2" });
    try h.expectRows(&s, &f, "MATCH (a:Q738 {i: 12})-[:E738]->(b:Q738b) RETURN b.i", &.{ "12", "12", "12", "12" });
    try h.expectRows(&s, &f, "MATCH (n:Q738 {k: 'x'}) RETURN count(n)", &.{"4"});
    try f.finish("query-form CREATE contents");
    try testing.expectEqual(@as(usize, 0), bad);
}
