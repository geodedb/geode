// SONNY-6529: an engine abort graph-storage cannot undo quarantines its
// graph; an undone abort is counted; the 0.4.16 errors have operator
// messages.
//
// graph-storage 0.4.16 `abortTxn` undoes a transaction's writes. One it
// cannot undo exactly (here: a page the caller imaged itself with
// `logPagePublic`, which geode's relationship-property and security-graph
// paths did until this change) fails with `error.AbortNotUndone`, and the
// shard then refuses every write, commit and checkpoint until the store is
// reopened. geode must not ignore it: the graph's reads and writes answer
// 58000 AbortNotUndone (other graphs keep serving), the
// `storage_txn_aborts_not_undone_total` runtime counter counts it, and a
// reopen of the store serves the graph at its committed state, without the
// aborted write.
//
// The transaction runs on the adapter's own API (`beginTransaction`,
// `abortTransaction`), its writes through graph-storage's engine API on the
// transaction's shard: a node record put into a fresh slot (visible to a
// scan if it ever became durable) and the image of that node's page.
//
// An abort graph-storage CAN undo is counted in
// `storage_txn_aborts_undone_total`: a node create whose label-dictionary
// write fails (a directory at every shard's `labels.dict.tmp`, as in
// test-sonny6523-failed-create-count) after its record was written, in the
// adapter's own transaction.
//
// CANARY: REQ=REQ-SONNY-6529-ABORT-NOT-UNDONE; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6529_abort_quarantine.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");
const gs = @import("graph_storage");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;
const gsa = geode.graph_storage_adapter;
const proto_util = geode.proto_util;

const G = "g6529q";
const OTHER = "g6529other";
const SEED: usize = 20;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Outcome = union(enum) { count: i64, failed: anyerror };

fn ask(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) Outcome {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = geode.parseGql(q, allocator) catch |err| return .{ .failed = err };
    defer parsed.deinit();
    const catalog = execution.ensureCatalogInstance(allocator) catch |err| return .{ .failed = err };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session }) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    if (result.rows.len == 1 and result.rows[0].len == 1) switch (result.rows[0][0]) {
        .Int => |v| return .{ .count = v },
        else => {},
    };
    return .{ .count = -1 };
}

fn expectCount(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8, want: i64) !void {
    switch (ask(allocator, session, q)) {
        .count => |c| if (c != want) {
            std.debug.print("SONNY-6529 '{s}': {d}, want {d}\n", .{ q, c, want });
            return error.WrongCount;
        },
        .failed => |err| {
            std.debug.print("SONNY-6529 '{s}' failed: {s}\n", .{ q, @errorName(err) });
            return err;
        },
    }
}

fn expectRefused(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !void {
    switch (ask(allocator, session, q)) {
        .count => |c| {
            std.debug.print("SONNY-6529 '{s}' answered ({d}) on a quarantined graph\n", .{ q, c });
            return error.QuarantinedGraphAnswered;
        },
        .failed => |err| {
            std.debug.print("SONNY-6529 '{s}': {s}\n", .{ q, @errorName(err) });
            if (err != error.AbortNotUndone) return error.WrongRefusal;
        },
    }
}

/// Put (or remove) a directory at `labels.dict.tmp` beside every shard's
/// `labels.dict` (test-sonny6523-failed-create-count's obstruction).
fn obstructLabelDict(allocator: std.mem.Allocator, data_dir: []const u8, on: bool) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (on and entry.kind == .file and std.mem.eql(u8, entry.basename, "labels.dict")) {
                try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}.tmp", .{ data_dir, entry.path }));
            }
            if (!on and entry.kind == .directory and std.mem.eql(u8, entry.basename, "labels.dict.tmp")) {
                try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, entry.path }));
            }
        }
    }
    for (paths.items) |p| {
        if (on) try std.Io.Dir.cwd().createDirPath(io(), p) else try std.Io.Dir.cwd().deleteTree(io(), p);
    }
    return paths.items.len;
}

fn seed(allocator: std.mem.Allocator, session: *execution.SessionState, graph: []const u8) !void {
    var qb: [512]u8 = undefined;
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(allocator);
    try s.print(allocator, "USE GRAPH {s}; CREATE ", .{graph});
    for (0..SEED) |i| {
        if (i > 0) try s.appendSlice(allocator, ", ");
        try s.print(allocator, "(:A {{k: {d}}})", .{i});
    }
    _ = &qb;
    switch (ask(allocator, session, s.items)) {
        .count => {},
        .failed => |err| return err,
    }
}

test "SONNY-6529: an abort graph-storage cannot undo quarantines its graph until a reopen, which serves it at its committed state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        try store.createGraph(G);
        try store.createGraph(OTHER);
        try seed(allocator, &session, G);
        try seed(allocator, &session, OTHER);
        try expectCount(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n:A) RETURN count(n) AS c", SEED);

        const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        const mg = adapter.engines.get(G) orelse return error.NoGraph;

        // A transaction graph-storage cannot undo: a node record in a fresh
        // slot of the transaction's shard, and its page imaged by the caller.
        const txn = try adapter.beginTransaction(G);
        const shard = mg.engine.shards[@intCast(txn >> 56)];
        const local: gs.TxnId = txn & ((@as(u64, 1) << 56) - 1);
        const id = try shard.allocNode();
        var rec = std.mem.zeroes(gs.node.NodeRec);
        rec.txn_stamp = 1;
        try shard.putNodeTxn(id, rec, local);
        try shard.logPagePublic(local, .nodes, shard.nodePageId(id));

        const not_undone0 = gsa.storage_txn_aborts_not_undone_total.load(.monotonic);
        if (adapter.abortTransaction(G, txn)) |_| {
            return error.AbortWasUndone;
        } else |err| try std.testing.expectEqual(error.AbortNotUndone, err);
        try std.testing.expectEqual(not_undone0 + 1, gsa.storage_txn_aborts_not_undone_total.load(.monotonic));

        // Reads and writes of the graph are refused, with the operator
        // message; the other graph serves.
        try expectRefused(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n:A) RETURN count(n) AS c");
        try expectRefused(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n) RETURN count(n) AS c");
        try expectRefused(allocator, &session, "USE GRAPH " ++ G ++ "; CREATE (:A {k: 99}) RETURN 1 AS c");
        try expectRefused(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n:A {k: 1}) SET n.x = 1 RETURN count(n) AS c");
        const info = proto_util.mapError(error.AbortNotUndone);
        try std.testing.expectEqualStrings("58000", info.code);
        try std.testing.expect(std.mem.indexOf(u8, info.message, "restart the server") != null);
        try std.testing.expect(std.mem.indexOf(u8, info.message, "Committed data on disk is intact") != null);
        try std.testing.expect(proto_util.statementErrorInfo(error.AbortNotUndone) != null);
        try expectCount(allocator, &session, "USE GRAPH " ++ OTHER ++ "; MATCH (n:A) RETURN count(n) AS c", SEED);
        try expectCount(allocator, &session, "USE GRAPH " ++ OTHER ++ "; CREATE (:A {k: 99}) RETURN 1 AS c", 1);
        // The shard itself refuses writes and checkpoints.
        if (shard.beginTxn()) |t| {
            shard.abortTxn(t) catch {};
            return error.ShardTookAWrite;
        } else |err| try std.testing.expectEqual(error.AbortNotUndone, err);
    }

    // Reopened (the close skipped the refused shard's checkpoint): the graph
    // is served at its committed state, without the aborted record.
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        const entries = try adapter.scanAllNodes(G, allocator); // live-count check
        defer allocator.free(entries);
        try std.testing.expectEqual(SEED, entries.len);
        try expectCount(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n) RETURN count(n) AS c", SEED);
        try expectCount(allocator, &session, "USE GRAPH " ++ G ++ "; CREATE (:A {k: 99}) RETURN 1 AS c", 1);
        try expectCount(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n:A) RETURN count(n) AS c", SEED + 1);
        try expectCount(allocator, &session, "USE GRAPH " ++ OTHER ++ "; MATCH (n:A) RETURN count(n) AS c", SEED + 1);
    }
}

test "SONNY-6529: an abort graph-storage undoes is counted, and leaves the graph serving" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    try store.createGraph(G);
    try seed(allocator, &session, G);

    const undone0 = gsa.storage_txn_aborts_undone_total.load(.monotonic);
    try std.testing.expect(try obstructLabelDict(allocator, data_dir, true) > 0);
    const fresh = [_][]const u8{"Fresh"};
    if (store.createNodeWithGraph(&fresh, G)) |_| {
        return error.InjectionDidNotFail;
    } else |_| {}
    _ = try obstructLabelDict(allocator, data_dir, false);
    try std.testing.expect(gsa.storage_txn_aborts_undone_total.load(.monotonic) > undone0);

    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const entries = try adapter.scanAllNodes(G, allocator); // live-count check
    defer allocator.free(entries);
    try std.testing.expectEqual(SEED, entries.len);
    try expectCount(allocator, &session, "USE GRAPH " ++ G ++ "; CREATE (:Fresh {k: 1}) RETURN 1 AS c", 1);
    try expectCount(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n) RETURN count(n) AS c", SEED + 1);
}

test "SONNY-6527: a label id space used up answers 54000 with an operator message" {
    const info = proto_util.mapError(error.LabelIdSpaceExhausted);
    try std.testing.expectEqualStrings("54000", info.code);
    try std.testing.expect(std.mem.indexOf(u8, info.message, "LabelIdSpaceExhausted") != null);
    try std.testing.expect(std.mem.indexOf(u8, info.message, "Nothing was written") != null);
}
