// SONNY-6942: what an auto-commit statement that changes nodes on many
// engine shards costs, over the real executor and a persisted store with the
// durable undo log installed, as the server runs it.
//
// `MATCH (n:L) DETACH DELETE n` over 30,000 nodes took longer than 30s on a
// server that ran it inside 30s before SONNY-6658. The nodes are spread over
// every engine shard. SONNY-6658 keeps an auto-commit statement's engine
// transaction open until the statement ends, but on ONE shard only: a delete
// on any other shard committed an engine transaction of its own (a WAL
// fsync), and before each such commit the statement's undo was written to
// `txn_undo.wal` with a second fsync. Two fsyncs per node, where 0.8.22 paid
// one.
//
// The bound is on the work, not on time: a statement opens at most one engine
// transaction per shard, so it commits at most SHARD_COUNT of them however
// many nodes it changes, and its undo reaches the log in one write before the
// first of them commits. Counted with the engine's `txn_committed` metric and
// the log's `txn_undo_wal_records_written_total`; no mocks, no timing.
//
// CANARY: REQ=REQ-SONNY-6942-STATEMENT-SHARD-TXNS; FEATURE="TransactionManagement"; ASPECT=StatementShardTxns; STATUS=TESTED; TEST=tests/test_sonny6942_detach_delete_shards.zig; OWNER=storage; UPDATED=2026-11-23

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;
const durable = geode.txn_durable_undo;
const shard_count = geode.sharded_store.SHARD_COUNT;

/// Nodes the statements change: many per shard, so a per-node commit and a
/// per-shard one are far apart.
const node_count = 32 * shard_count;

fn committed() !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const mg = try adapter.lookupManagedGraph(graph_store.DEFAULT_GRAPH_NAME);
    return mg.engine.getMetrics().txn_committed;
}

fn records() u64 {
    return durable.records_written_total.load(.monotonic);
}

fn logBytes(l: *durable.Log) !u64 {
    return l.file.length(std.Io.Threaded.global_single_threaded.io());
}

/// Run `query` and report how many engine transactions it committed and how
/// many undo log records it wrote.
fn measure(s: *h.Session, query: []const u8) !struct { commits: u64, records: u64 } {
    const c0 = try committed();
    const r0 = records();
    try s.execAs(null, query);
    return .{ .commits = try committed() - c0, .records = records() - r0 };
}

test "SONNY-6942: a statement over every shard commits once per shard, not once per node" {
    h.silenceEngineLogs();
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    const l = try durable.Log.open(testing.allocator, s.data_dir, null);
    durable.install(l);
    defer {
        _ = durable.uninstall();
        l.close();
    }

    // Each CREATE statement opens its engine transaction on the next shard,
    // so the nodes cover every shard.
    for (0..node_count) |i| {
        var buf: [96]u8 = undefined;
        try s.execAs(null, try std.fmt.bufPrint(&buf, "CREATE (:Del6942 {{i: {d}}}), (:Keep6942 {{i: {d}}})", .{ i, i }));
    }
    // Relationships between nodes on different shards, so the DETACH deletes
    // edges too.
    for (0..node_count / 4) |i| {
        var buf: [160]u8 = undefined;
        try s.execAs(null, try std.fmt.bufPrint(&buf, "MATCH (a:Del6942 {{i: {d}}}), (b:Del6942 {{i: {d}}}) CREATE (a)-[:NEXT6942]->(b)", .{ i, i + 1 }));
    }

    // At most one engine transaction per shard, whatever the node count. The
    // undo goes to the log once (its entries in one write) and is sealed with
    // COMMITTED; the log is left empty.
    const max_commits: u64 = shard_count;
    var bad: usize = 0;
    const statements = [_][]const u8{
        "MATCH (n:Keep6942) SET n.v = 1",
        "MATCH (n:Del6942) DETACH DELETE n",
    };
    for (statements) |q| {
        const r0 = records();
        const m = try measure(&s, q);
        if (m.commits > max_commits) {
            std.debug.print("{s}: {d} engine commits for {d} nodes over {d} shards (want at most {d}, one per shard)\n", .{ q, m.commits, node_count, shard_count, max_commits });
            bad += 1;
        }
        if (records() - r0 < 2) {
            std.debug.print("{s}: {d} undo log records (want its entries and COMMITTED)\n", .{ q, records() - r0 });
            bad += 1;
        }
        try testing.expectEqual(@as(u64, 0), try logBytes(l));
        try testing.expectEqual(@as(u32, 0), l.open_txns.count());
    }

    // A failed statement over every shard is undone, committed per shard
    // too, and leaves the log empty.
    {
        const c0 = try committed();
        if (s.execAs(null, "MATCH (n:Keep6942) SET n.w = 1 RETURN CASE WHEN n.i = 300 THEN 1 / 0 ELSE 1 END AS e")) |_| {
            return error.ExpectedStatementToFail;
        } else |_| {}
        const dc = try committed() - c0;
        if (dc > max_commits) {
            std.debug.print("a failed statement over every shard: {d} engine commits (want at most {d})\n", .{ dc, max_commits });
            bad += 1;
        }
        try testing.expectEqual(@as(u64, 0), try logBytes(l));
        try testing.expectEqual(@as(u32, 0), l.open_txns.count());
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // Writes after the statements land on the same shards' pages: nothing
    // is left open there to refuse them (WriteConflict).
    for (0..shard_count * 2) |i| {
        var buf: [64]u8 = undefined;
        try s.execAs(null, try std.fmt.bufPrint(&buf, "CREATE (:After6942 {{i: {d}}})", .{i}));
    }
    try s.execAs(null, "MATCH (n:After6942) SET n.v = 2");

    var f: h.Failures = .{};
    var want_keep: [16]u8 = undefined;
    const keep = try std.fmt.bufPrint(&want_keep, "{d}", .{node_count});
    var want_after: [16]u8 = undefined;
    const after = try std.fmt.bufPrint(&want_after, "{d}", .{shard_count * 2});
    try h.expectRows(&s, &f, "MATCH (n:Del6942) RETURN count(n)", &.{"0"});
    try h.expectRows(&s, &f, "MATCH ()-[r:NEXT6942]->() RETURN count(r)", &.{"0"});
    try h.expectRows(&s, &f, "MATCH (n:Keep6942) WHERE n.v = 1 RETURN count(n)", &.{keep});
    try h.expectRows(&s, &f, "MATCH (n:Keep6942) WHERE n.w IS NOT NULL RETURN count(n)", &.{"0"});
    try h.expectRows(&s, &f, "MATCH (n:After6942) WHERE n.v = 2 RETURN count(n)", &.{after});
    try f.finish("SONNY-6942 statement contents");
}
