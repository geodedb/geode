// SONNY-6942: the threads of a statement that writes over every engine
// shard. The auto-commit statement keeps an engine transaction open on each
// shard it writes until it ends (`graph_storage_adapter.t_auto_shard_txns`).
// graph-storage refuses a second open writer of a page (`WriteConflict`), so
// every write made for the statement must land in those transactions:
//
//   * UNION ALL arms that write: they run on the statement's thread
//     (`set_operations.unionArmsAreParallelEligible` keeps parallel arms
//     read-only), so the second arm's writes join the transactions the first
//     arm's opened.
//   * A thread working for the statement (`statement_undo.attach`, as a
//     spawned UNION arm joins it, SONNY-6362): its writes committed engine
//     transactions of their own beside the statement's, and the first one on
//     a page the statement had written failed with WriteConflict (already on
//     the statement's one shard before SONNY-6942; on every shard after it).
//
// Over the real executor, graph-store writes and a persisted store with the
// durable undo log installed, as the server runs it; no mocks.
//
// CANARY: REQ=REQ-SONNY-6942-STATEMENT-SHARD-TXNS; FEATURE="TransactionManagement"; ASPECT=StatementThreads; STATUS=TESTED; TEST=tests/test_sonny6942_statement_threads.zig; OWNER=storage; UPDATED=2026-11-23

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;
const durable = geode.txn_durable_undo;
const execution = geode.execution;
const statement_undo = geode.statement_undo;
const shard_count = geode.sharded_store.SHARD_COUNT;

const node_count = 32 * shard_count;

fn committed() !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const mg = try adapter.lookupManagedGraph(graph_store.DEFAULT_GRAPH_NAME);
    return mg.engine.getMetrics().txn_committed;
}

fn logBytes(l: *durable.Log) !u64 {
    return l.file.length(std.Io.Threaded.global_single_threaded.io());
}

/// Spread `node_count` nodes of `label` over the shards: each CREATE
/// statement opens its engine transaction on the next shard.
fn spread(s: *h.Session, label: []const u8) !void {
    for (0..node_count) |i| {
        var buf: [96]u8 = undefined;
        try s.execAs(null, try std.fmt.bufPrint(&buf, "CREATE (:{s} {{i: {d}}})", .{ label, i }));
    }
}

test "SONNY-6942: UNION arms that write over every shard, in one statement" {
    h.silenceEngineLogs();
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    const l = try durable.Log.open(testing.allocator, s.data_dir, null);
    durable.install(l);
    defer {
        _ = durable.uninstall();
        l.close();
    }
    try spread(&s, "UA6942");
    try spread(&s, "UB6942");

    // Both arms write nodes on every shard; the second arm's writes land on
    // shards the first arm's transactions hold. A write arm runs on the
    // statement's thread (`unionArmsAreParallelEligible` keeps parallel arms
    // read-only), so its writes join the statement's transactions there.
    const c0 = try committed();
    try s.execAs(null, "MATCH (a:UA6942) SET a.u = 1 RETURN count(a) AS c UNION ALL MATCH (b:UB6942) SET b.u = 2 RETURN count(b) AS c");
    const commits = try committed() - c0;
    if (commits > shard_count) {
        std.debug.print("UNION ALL of two writing arms: {d} engine commits (want at most {d})\n", .{ commits, shard_count });
        return error.TooManyCommits;
    }
    try testing.expectEqual(@as(u64, 0), try logBytes(l));

    var f: h.Failures = .{};
    var want: [16]u8 = undefined;
    const all = try std.fmt.bufPrint(&want, "{d}", .{node_count});
    try h.expectRows(&s, &f, "MATCH (n:UA6942) WHERE n.u = 1 RETURN count(n)", &.{all});
    try h.expectRows(&s, &f, "MATCH (n:UB6942) WHERE n.u = 2 RETURN count(n)", &.{all});
    try f.finish("SONNY-6942 UNION writes");
}

/// Writes for the statement whose undo record it joins, on a thread of its
/// own (as a spawned UNION arm joins it, SONNY-6362).
const Worker = struct {
    record: *statement_undo.Record,
    st: *graph_store.GraphStore,
    ids: []const u64,
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        statement_undo.attach(self.record);
        defer statement_undo.detach();
        self.work() catch |e| {
            self.err = e;
        };
    }

    /// Sets `w` on every node, then creates nodes of its own.
    fn work(self: *Worker) !void {
        for (self.ids) |id| try self.st.setNodeProperty(id, "w", .{ .Int = 2 });
        const labels = [_][]const u8{"TWC6942"};
        for (0..shard_count * 2) |_| {
            const id = try self.st.createNodeWithGraph(&labels, graph_store.DEFAULT_GRAPH_NAME);
            try self.st.setNodeProperty(id, "w", .{ .Int = 3 });
        }
    }
};

test "SONNY-6942: a thread writing for the statement, beside its transactions on every shard" {
    h.silenceEngineLogs();
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    const l = try durable.Log.open(testing.allocator, s.data_dir, null);
    durable.install(l);
    defer {
        _ = durable.uninstall();
        l.close();
    }
    try spread(&s, "TW6942");
    const st = graph_store.getWritableGlobalStore(testing.allocator);
    const ids = try testing.allocator.dupe(u64, st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "TW6942") orelse return error.NoNodes);
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, node_count), ids.len);
    const catalog = try execution.ensureCatalogInstance(testing.allocator);

    // The statement's thread writes every node (its transactions open on
    // every shard); a worker joined to its record then writes the same
    // nodes' pages.
    execution.beginStatementScope(true);
    for (ids) |id| try st.setNodeProperty(id, "v", .{ .Int = 1 });
    var w: Worker = .{ .record = statement_undo.current() orelse return error.NoStatementRecord, .st = st, .ids = ids };
    const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Worker.run, .{&w});
    t.join();
    if (w.err) |e| {
        execution.endStatementFailed(true, e) catch {};
        std.debug.print("a worker's write beside the statement's shard transactions failed: {s}\n", .{@errorName(e)});
        return e;
    }
    try execution.endStatementSucceeded(true, catalog);
    try testing.expectEqual(@as(u64, 0), try logBytes(l));

    var f: h.Failures = .{};
    var want: [16]u8 = undefined;
    const all = try std.fmt.bufPrint(&want, "{d}", .{node_count});
    try h.expectRows(&s, &f, "MATCH (n:TW6942) WHERE n.v = 1 AND n.w = 2 RETURN count(n)", &.{all});
    var want_created: [16]u8 = undefined;
    const created = try std.fmt.bufPrint(&want_created, "{d}", .{shard_count * 2});
    try h.expectRows(&s, &f, "MATCH (n:TWC6942) WHERE n.w = 3 RETURN count(n)", &.{created});
    try f.finish("SONNY-6942 worker writes");
}
