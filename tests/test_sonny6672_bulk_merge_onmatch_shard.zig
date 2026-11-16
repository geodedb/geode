// SONNY-6672: a bulk node MERGE that matches an existing node writes its ON
// MATCH properties on that node's engine shard, from that shard's worker and
// under that shard's lock.
//
// The group-commit coordinator routes a node MERGE (`bulk_merge_node`,
// `bulk_merge_node_props`) to the worker of `shardIndex(reserved id)`, the
// shard a created node would go on. When the MERGE matches an existing node
// and applies its SET properties there (`apply_on_match`), it wrote them on
// the matched node's engine shard (an executor-created node's slot is placed
// round-robin): from another worker's thread, beside that shard's own worker
// and its open batch transaction, holding the MERGE tuple lock and the graph
// lock SHARED but no shard lock at all.
//
// The adapter counts engine writes a group-commit worker makes on a shard
// other than its own (`group_commit_foreign_shard_writes_total`, SONNY-6671).
// The test creates nodes through the executor's store path, MERGEs each of
// them through the coordinator with ON MATCH properties (single-key and
// multi-key MERGE), and requires the count to stay 0, every MERGE to match
// its node, and the properties to be set.
//
// CANARY: REQ=REQ-SONNY-6672-MERGE-ONMATCH-SHARD; FEATURE="High-Concurrency Mutations"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6672_bulk_merge_onmatch_shard.zig; OWNER=storage; UPDATED=2026-11-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_storage = @import("graph_storage");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;
const group_commit = geode.group_commit;
const PropKV = gsa.StorageAdapter.PropKV;

const G = "g6672";
const n_nodes = 32;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const Env = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    adapter: *gsa.StorageAdapter,
    store: *graph_store.GraphStore,

    fn setup(allocator: std.mem.Allocator, tmp_sub_path: []const u8) !Env {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = setenv("GEODE_WAL_SYNC", "deferred", 1);
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
        var actual_len = cwd_len;
        while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        _ = try execution.ensureCatalogInstance(allocator);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        try store.createGraph(G);
        group_commit.setEnabledForTest(true);
        return .{ .allocator = allocator, .data_dir = data_dir, .adapter = adapter, .store = store };
    }

    fn teardown(self: *Env) void {
        group_commit.shutdownAllCoordinators();
        group_commit.setEnabledForTest(false);
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
    }

    fn engineShard(self: *Env, id: u64) !usize {
        const slot = self.store.nodeSlotOf(G, id) orelse return error.NodeSlotMissing;
        return self.adapter.shardOfSlot(slot);
    }

    fn intProp(self: *Env, id: u64, key: []const u8) !?i64 {
        const v = (try self.store.getNodePropertyOrError(id, key)) orelse return null;
        return switch (v) {
            .Int => |i| i,
            else => error.UnexpectedValue,
        };
    }
};

test "SONNY-6672: a bulk MERGE matching an executor-created node writes its ON MATCH properties from the worker of that node's engine shard" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Nodes as the executor creates them (slot placed round-robin), with a
    // unique single key `k` and a second key `g` for the multi-key MERGE.
    var labels = [_][]const u8{"M6672"};
    var nodes: [n_nodes]u64 = undefined;
    var elsewhere: usize = 0;
    for (&nodes, 0..) |*id, i| {
        id.* = try env.store.createNodeWithGraph(&labels, G);
        try env.store.setNodeProperty(id.*, "k", .{ .Int = @intCast(i) });
        try env.store.setNodeProperty(id.*, "g", .{ .Int = @intCast(1000 + i) });
        if (graph_storage.sharded_store.shardIndex(id.*) != try env.engineShard(id.*)) elsewhere += 1;
    }

    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, G);
    // Bulk-inserted nodes, so the workers also hold batch transactions on
    // their own shards.
    const b_labels = [_][]const u8{"B6672"};
    for (0..n_nodes) |i| {
        const props = [_]PropKV{.{ .key = "b", .value = .{ .Int = @intCast(i) } }};
        var op = group_commit.ApplyOp{ .bulk_insert_node = .{ .labels = &b_labels, .props = &props, .result = .{} } };
        _ = try coord.submit(&op);
    }

    const before = gsa.group_commit_foreign_shard_writes_total.load(.monotonic);
    var matched: usize = 0;
    var set: usize = 0;
    for (nodes, 0..) |id, i| {
        // MERGE (n:M6672 {k: i}) SET n.v = 100 + i
        const single_set = [_]PropKV{.{ .key = "v", .value = .{ .Int = @intCast(100 + i) } }};
        var single = group_commit.ApplyOp{ .bulk_merge_node = .{
            .label = "M6672",
            .merge_key = "k",
            .merge_value = .{ .Int = @intCast(i) },
            .on_create_props = &single_set,
            .result = .{},
            .apply_on_match = true,
        } };
        if (try coord.submit(&single) == id) matched += 1;
        // MERGE (n:M6672 {k: i, g: 1000 + i}) SET n.w = 200 + i
        const keys = [_]PropKV{ .{ .key = "k", .value = .{ .Int = @intCast(i) } }, .{ .key = "g", .value = .{ .Int = @intCast(1000 + i) } } };
        const multi_set = [_]PropKV{.{ .key = "w", .value = .{ .Int = @intCast(200 + i) } }};
        var multi = group_commit.ApplyOp{ .bulk_merge_node_props = .{
            .label = "M6672",
            .merge_props = &keys,
            .on_create_props = &multi_set,
            .result = .{},
            .apply_on_match = true,
        } };
        if (try coord.submit(&multi) == id) matched += 1;
        if ((try env.intProp(id, "v")) == @as(i64, @intCast(100 + i)) and (try env.intProp(id, "w")) == @as(i64, @intCast(200 + i))) set += 1;
    }
    const foreign = gsa.group_commit_foreign_shard_writes_total.load(.monotonic) - before;

    std.debug.print("SONNY-6672: {d} executor-created nodes, {d} on another engine shard than their public id hashes to; {d} of {d} bulk MERGEs matched their node, {d} of {d} nodes got their ON MATCH properties; worker writes to another worker's engine shard: {d} (want 0)\n", .{ n_nodes, elsewhere, matched, 2 * n_nodes, set, n_nodes, foreign });
    try testing.expect(elsewhere > 0);
    try testing.expectEqual(@as(usize, 2 * n_nodes), matched);
    try testing.expectEqual(@as(usize, n_nodes), set);
    try testing.expectEqual(@as(u64, 0), foreign);
}
