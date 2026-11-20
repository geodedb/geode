// SONNY-6671: a group-commit worker writes only its own engine shard.
//
// The group-commit coordinator runs one worker per engine shard. Each worker
// holds a batch transaction open on its shard, and each op takes that
// shard's lock (`shard_locks[i]`), so a shard has one writer at a time.
// Ops are routed to a worker by `shardIndex(op.shardKey())`, the hash of a
// public node id. For a node the bulk insert created, that hash is also its
// engine shard (the insert allocates the slot there). For a node the
// executor created it is not: the executor's `createNode` places the slot
// round-robin, and its public id is time-based. A relationship op whose
// source is such a node (bulk insert, bulk MERGE, MATCH ... CREATE) went to
// the worker of the hashed shard, took that shard's lock, and wrote the
// relationship on the source's real engine shard: beside that shard's own
// worker, which may be writing there at the same moment, in a second open
// engine transaction (graph-storage refuses one with WriteConflict when they
// share a page) and without its lock.
//
// The adapter counts engine writes a worker makes on a shard other than its
// own (`group_commit_foreign_shard_writes_total`, SONNY-6671). The tests
// create nodes through the executor's store path, then relationships from
// them through the coordinator, and require that count to stay 0.
//
// CANARY: REQ=REQ-SONNY-6671-WORKER-SHARD; FEATURE="High-Concurrency Mutations"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6671_group_commit_routing.zig; OWNER=storage; UPDATED=2026-11-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_storage = @import("graph_storage");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;
const group_commit = geode.group_commit;
const PropKV = gsa.StorageAdapter.PropKV;

const G = "g6671";
const n_sources = 32;

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

    /// The engine shard of public node id `id`.
    fn engineShard(self: *Env, id: u64) !usize {
        const slot = self.store.nodeSlotOf(G, id) orelse return error.NodeSlotMissing;
        return self.adapter.shardOfSlot(slot);
    }
};

/// Nodes created as the executor creates them (`GraphStore.createNodeWithGraph`,
/// the slot placed round-robin), each with a unique key `k`; and how many of
/// them the coordinator's hash routes to a worker other than their engine
/// shard's.
fn executorNodes(env: *Env, label: []const u8, out: []u64) !usize {
    var labels = [_][]const u8{label};
    var misrouted: usize = 0;
    for (out, 0..) |*id, i| {
        id.* = try env.store.createNodeWithGraph(&labels, G);
        try env.store.setNodeProperty(id.*, "k", .{ .Int = @intCast(i) });
        if (graph_storage.sharded_store.shardIndex(id.*) != try env.engineShard(id.*)) misrouted += 1;
    }
    return misrouted;
}

fn edgeExists(env: *Env, edge_id: u64) !bool {
    return (try env.store.getEdgeHydratedChecked(edge_id)) != null;
}

test "SONNY-6671: relationships from executor-created nodes through group commit are written by the worker of the source's engine shard" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    var sources: [n_sources]u64 = undefined;
    const misrouted = try executorNodes(&env, "S6671", &sources);

    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, G);
    // Targets through the bulk insert, so the workers also hold batch
    // transactions on their own shards.
    const t_labels = [_][]const u8{"T6671"};
    var targets: [n_sources]u64 = undefined;
    for (&targets, 0..) |*t, i| {
        const props = [_]PropKV{.{ .key = "k", .value = .{ .Int = @intCast(i) } }};
        var op = group_commit.ApplyOp{ .bulk_insert_node = .{ .labels = &t_labels, .props = &props, .result = .{} } };
        t.* = try coord.submit(&op);
    }

    const before = gsa.group_commit_foreign_shard_writes_total.load(.monotonic);
    const no_props = [_]PropKV{};
    var created: usize = 0;
    var failed: usize = 0;
    for (sources, targets, 0..) |s, t, i| {
        // Bulk insert, bulk MERGE and MATCH ... CREATE of a relationship from
        // an executor-created node.
        var ins = group_commit.ApplyOp{ .bulk_insert_edge = .{ .source_id = s, .target_id = t, .rel_type = "I6671", .props = &no_props, .result = .{} } };
        var mer = group_commit.ApplyOp{ .bulk_merge_edge = .{ .source_id = s, .target_id = t, .rel_type = "M6671", .props = &no_props, .result = .{} } };
        var mc = group_commit.ApplyOp{ .bulk_match_create_edge = .{
            .src_label = "S6671",
            .src_filter_key = "k",
            .src_filter_value = .{ .Int = @intCast(i) },
            .dst_label = "T6671",
            .dst_filter_key = "k",
            .dst_filter_value = .{ .Int = @intCast(i) },
            .rel_type = "C6671",
            .props = &no_props,
            .result = .{},
        } };
        for ([_]*group_commit.ApplyOp{ &ins, &mer, &mc }) |op| {
            const id = coord.submit(op) catch |err| {
                std.debug.print("SONNY-6671: {s} from node {d} failed: {s}\n", .{ @tagName(op.*), s, @errorName(err) });
                failed += 1;
                continue;
            };
            if (id == 0 or !try edgeExists(&env, id)) {
                failed += 1;
                continue;
            }
            created += 1;
        }
    }
    const foreign = gsa.group_commit_foreign_shard_writes_total.load(.monotonic) - before;

    std.debug.print("SONNY-6671: {d} executor-created sources, {d} hashed to another worker than their engine shard's; {d} relationships created through group commit, {d} failed; worker writes to another worker's engine shard: {d} (want 0)\n", .{ n_sources, misrouted, created, failed, foreign });
    // The case is exercised: most executor-created nodes hash elsewhere.
    try testing.expect(misrouted > 0);
    try testing.expectEqual(@as(usize, 0), failed);
    try testing.expectEqual(@as(usize, 3 * n_sources), created);
    try testing.expectEqual(@as(u64, 0), foreign);
}
