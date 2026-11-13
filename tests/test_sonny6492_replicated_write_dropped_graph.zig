// SONNY-6492 (3): a replicated data write never creates a dropped graph again.
//
// The Raft apply of a data write (`raft_apply.applyGraphMutation`, the
// `cluster_replication.apply*Payload` helpers, the 2PC write-set apply)
// "ensured" its graph with `GraphStore.createGraph` -- CREATE GRAPH, which
// creates a graph dropped earlier under the name afresh. SONNY-6472 (2) made
// a local write to a dropped name answer GraphNotFound; the apply still
// brought the graph back, with the write in it, after a replicated DROP GRAPH
// earlier in the log. Every replica applies the log in the same order, so the
// write fails alike on all of them; a replicated CREATE GRAPH (schema_change
// create_graph) creates the name again.
//
// Also `StorageAdapter.createNode`, which embedding code may call holding no
// graph lock (which pins): a DROP GRAPH between its lookup and its write freed
// the graph under it, or (another holder pinned it) it wrote into the dropped
// graph and reported success. It now pins the graph for the create and fails
// a create whose graph was dropped before it committed with GraphNotFound.
//
// Driven through the real apply entry point (`raft_apply.applyCommand`) on
// the real engine-backed global store.
//
// CANARY: REQ=REQ-SONNY-6492-REPLICATED-WRITE-NO-RESURRECT; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6492_replicated_write_dropped_graph.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;
const gsa = geode.graph_storage_adapter;

const G = "g6492repl";

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

fn applySchema(allocator: std.mem.Allocator, store: *graph_store.GraphStore, op: anytype) !void {
    const r = try raft_apply.applyCommand(allocator, store, .{ .schema_change = .{
        .operation = op,
        .graph = G,
        .schema = "",
    } }, 1);
    allocator.free(r);
}

fn adapterHasGraph(allocator: std.mem.Allocator, adapter: anytype) !bool {
    const names = try adapter.listGraphNames(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |n| if (std.mem.eql(u8, n, G)) return true;
    return false;
}

test "SONNY-6492 (3): a replicated data write after a replicated DROP GRAPH does not create the graph again" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    // A name never dropped: the first replicated write creates it lazily.
    allocator.free(try applyCreate(allocator, store, 10));
    try std.testing.expect(try adapterHasGraph(allocator, adapter));
    try std.testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, "R", null));

    // A replicated DROP GRAPH, then a data write later in the log.
    try applySchema(allocator, store, .drop_graph);
    try std.testing.expect(!try adapterHasGraph(allocator, adapter));
    if (applyCreate(allocator, store, 12)) |r| {
        allocator.free(r);
        std.debug.print("SONNY-6492 (3): the replicated write after the drop was applied\n", .{});
        return error.ReplicatedWriteRecreatedDroppedGraph;
    } else |err| try std.testing.expectEqual(error.GraphNotFound, err);
    try std.testing.expect(!try adapterHasGraph(allocator, adapter));
    try std.testing.expect(!store.graphs.contains(G));

    // A replicated CREATE GRAPH creates the name again; writes land in it.
    try applySchema(allocator, store, .create_graph);
    try std.testing.expect(try adapterHasGraph(allocator, adapter));
    allocator.free(try applyCreate(allocator, store, 14));
    try std.testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, "R", null));
}

/// Drops the graph from inside a `createNode`, after its lookup and before
/// its record is written (`node_slot_allocated_hook`): the drop an embedding
/// caller's unlocked create can meet.
const MidCreateDrop = struct {
    var drops: usize = 0;
    var drop_error: ?anyerror = null;

    fn hook(mg: *gsa.ManagedGraph) void {
        if (!std.mem.eql(u8, mg.name, G)) return;
        const store = graph_store.getGlobalStore(std.testing.allocator);
        drops += 1;
        store.dropGraph(G) catch |err| {
            drop_error = err;
        };
    }
};

test "SONNY-6492 (3): createNode with no graph lock never writes into a graph dropped under it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    try store.createGraph(G);
    const labels = [_][]const u8{"N"};
    _ = try adapter.createNode(G, &labels);

    MidCreateDrop.drops = 0;
    MidCreateDrop.drop_error = null;
    gsa.node_slot_allocated_hook = MidCreateDrop.hook;
    defer gsa.node_slot_allocated_hook = null;
    const r = adapter.createNode(G, &labels);
    gsa.node_slot_allocated_hook = null;

    try std.testing.expectEqual(@as(usize, 1), MidCreateDrop.drops);
    try std.testing.expectEqual(@as(?anyerror, null), MidCreateDrop.drop_error);
    try std.testing.expectError(error.GraphNotFound, r);
    try std.testing.expect(!try adapterHasGraph(allocator, adapter));
    try std.testing.expectError(error.GraphNotFound, adapter.createNode(G, &labels));
}
