// SONNY-6523 (5): a graph dropped before a restart is not created again by a
// late write after it.
//
// SONNY-6472 (2) / SONNY-6492 (3) made a write to a dropped graph's name
// (a local bulk write, a replicated Raft apply) answer GraphNotFound
// instead of creating the graph again, but the set of dropped names
// (`StorageAdapter.dropped_graph_names`) lived in memory only: after a
// restart a replicated write for a name dropped before it, replayed or
// arriving late, created the graph again lazily, with the write in it. The
// names are now kept on disk (a tombstone file in the data directory, written
// before the drop changes anything), loaded at open, and CREATE GRAPH clears
// the name's tombstone before it creates the graph.
//
// Driven through the real Raft apply entry point (`raft_apply.applyCommand`)
// on the real engine-backed global store, closed and reopened in between.
//
// CANARY: REQ=REQ-SONNY-6523-DROPPED-GRAPH-TOMBSTONE; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6523_dropped_graph_restart.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;

const G = "g6523tomb";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn applyCreate(allocator: std.mem.Allocator, store: *graph_store.GraphStore, raft_index: u64) ![]u8 {
    const labels = [_][]const u8{"R"};
    const payload = try cr.serializeNodeCreate(allocator, G, &labels, &.{});
    defer allocator.free(payload);
    return raft_apply.applyCommand(allocator, store, .{ .graph_mutation = .{
        .graph = G,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } }, raft_index);
}

fn adapterHasGraph(allocator: std.mem.Allocator) !bool {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const names = try adapter.listGraphNames(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |n| if (std.mem.eql(u8, n, G)) return true;
    return false;
}

fn open(allocator: std.mem.Allocator, data_dir: []const u8) !*graph_store.GraphStore {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    try store.loadFromFile();
    return store;
}

fn close() void {
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
}

test "SONNY-6523 (5): a write for a graph dropped before a restart does not create it again; CREATE GRAPH makes it afresh" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    // The graph, with data; dropped; the store closed.
    {
        const store = try open(allocator, data_dir);
        defer close();
        try store.createGraph(G);
        for (0..3) |i| allocator.free(try applyCreate(allocator, store, 10 + i));
        try std.testing.expectEqual(@as(usize, 3), store.countNodesByLabel(G, "R", null));
        try store.dropGraph(G);
        try std.testing.expect(!try adapterHasGraph(allocator));
    }

    // After the restart: a late replicated write for the name is refused,
    // also after a second restart (the refusal itself changes nothing).
    for (0..2) |round| {
        const store = try open(allocator, data_dir);
        defer close();
        if (applyCreate(allocator, store, 20 + round)) |r| {
            allocator.free(r);
            std.debug.print("SONNY-6523 (5): round {d}: the write for the graph dropped before the restart was applied\n", .{round});
            return error.WriteRecreatedDroppedGraph;
        } else |err| try std.testing.expectEqual(error.GraphNotFound, err);
        try std.testing.expect(!try adapterHasGraph(allocator));
    }

    // CREATE GRAPH of the name: a fresh, empty graph; writes land in it, and
    // it (with them) survives a restart.
    {
        const store = try open(allocator, data_dir);
        defer close();
        try store.createGraph(G);
        try std.testing.expect(try adapterHasGraph(allocator));
        try std.testing.expectEqual(@as(usize, 0), store.countNodesByLabel(G, "R", null));
        allocator.free(try applyCreate(allocator, store, 30));
        try std.testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, "R", null));
    }
    {
        const store = try open(allocator, data_dir);
        defer close();
        try std.testing.expect(try adapterHasGraph(allocator));
        try std.testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, "R", null));
        allocator.free(try applyCreate(allocator, store, 31));
        try std.testing.expectEqual(@as(usize, 2), store.countNodesByLabel(G, "R", null));
    }
}
