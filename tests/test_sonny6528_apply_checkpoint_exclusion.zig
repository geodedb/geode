// SONNY-6528 (1): a Raft apply's write to a graph and a checkpoint of that
// graph do not run at the same time.
//
// A checkpoint takes the graph's rwlock EXCLUSIVE (`checkpointOneGraph`) to
// drain every writer: it writes the shard manifests (next node id, live-node
// count), the label index and the dirty pages, and a writer changing them
// meanwhile crashed it (hash maps resized mid-scan) or let it persist a
// count ahead of the records. Every local writer holds that rwlock (the
// executor EXCLUSIVE, the bulk paths SHARED with a shard lock). The Raft
// apply of a replicated write (`raft_apply.applyGraphMutation` ->
// `cluster_replication.applyNodeCreatePayload` -> `createNodeWithId` ->
// `StorageAdapter.createNode`) held no lock at all. It cannot take the
// rwlock: it runs on the Raft tick thread under the Raft node's
// `inner_mutex`, and a request on the leader proposes (taking `inner_mutex`)
// while it holds its graph's rwlock, so the two would deadlock.
//
// The interleaving is forced, not hoped for: the apply's node create stops
// right after the engine counted the node and before its record is written
// (`node_slot_allocated_hook`), starts a full checkpoint on another thread
// (`checkpointAll`, which waits for each graph's lock without a deadline),
// and waits up to 15 s for it. The checkpoint must not complete inside that
// window; it must complete once the apply is done.
// The apply runs through the real entry point (`raft_apply.applyCommand`)
// on the real engine-backed global store.
//
// CANARY: REQ=REQ-SONNY-6528-APPLY-CHECKPOINT-EXCLUSION; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6528_apply_checkpoint_exclusion.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;
const gsa = geode.graph_storage_adapter;

const G = "g6528apply";
/// The checkpoint's whole run (it completes in about 2 s on a loaded host)
/// must fit in the window when nothing excludes it.
const WINDOW_MS: u64 = 15_000;

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

const Race = struct {
    var armed = std.atomic.Value(bool).init(false);
    var go = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var done_in_window = std.atomic.Value(bool).init(false);
    var checkpoint_failed = std.atomic.Value(bool).init(false);
    var apply_thread: std.Thread.Id = 0;

    fn hook(mg: *gsa.ManagedGraph) void {
        if (!std.mem.eql(u8, mg.name, G)) return;
        if (std.Thread.getCurrentId() != apply_thread) return;
        if (!armed.swap(false, .acq_rel)) return;
        go.store(true, .release);
        const start = std.Io.Clock.awake.now(io()).nanoseconds;
        while (!done.load(.acquire) and std.Io.Clock.awake.now(io()).nanoseconds - start < WINDOW_MS * std.time.ns_per_ms) {
            io().sleep(.fromMilliseconds(2), .awake) catch {};
        }
        done_in_window.store(done.load(.acquire), .release);
    }

    fn checkpointer() void {
        while (!go.load(.acquire)) io().sleep(.fromMilliseconds(1), .awake) catch {};
        const adapter = graph_store.getGlobalAdapter() orelse {
            checkpoint_failed.store(true, .release);
            done.store(true, .release);
            return;
        };
        adapter.checkpointAll() catch checkpoint_failed.store(true, .release);
        done.store(true, .release);
    }
};

fn applyCreate(allocator: std.mem.Allocator, store: *graph_store.GraphStore, raft_index: u64) !void {
    const labels = [_][]const u8{"A6528"};
    const props = [_]cr.Prop{.{ .key = "i", .value = .{ .Int = @intCast(raft_index) } }};
    const payload = try cr.serializeNodeCreate(allocator, G, &labels, &props);
    defer allocator.free(payload);
    const r = try raft_apply.applyCommand(allocator, store, .{ .graph_mutation = .{
        .graph = G,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } }, raft_index);
    allocator.free(r);
}

test "SONNY-6528 (1): a checkpoint of a graph waits for a Raft apply's write to it" {
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
        try store.createGraph(G);
        // Some applied nodes first, so the checkpoint has state to write.
        for (0..8) |i| try applyCreate(allocator, store, 100 + i);

        Race.apply_thread = std.Thread.getCurrentId();
        Race.armed.store(true, .release);
        gsa.node_slot_allocated_hook = Race.hook;
        defer gsa.node_slot_allocated_hook = null;
        const t = try std.Thread.spawn(.{}, Race.checkpointer, .{});
        try applyCreate(allocator, store, 200);
        t.join();

        std.debug.print("SONNY-6528 (1): checkpoint completed inside the apply's create: {}; checkpoint failed: {}\n", .{ Race.done_in_window.load(.acquire), Race.checkpoint_failed.load(.acquire) });
        try std.testing.expect(!Race.go.load(.acquire) or Race.done.load(.acquire));
        try std.testing.expect(Race.go.load(.acquire)); // the hook ran
        try std.testing.expect(!Race.checkpoint_failed.load(.acquire));
        try std.testing.expectEqual(@as(usize, 9), store.countNodesByLabel(G, "A6528", null));
        if (Race.done_in_window.load(.acquire)) return error.CheckpointRanInsideReplicatedApply;
    }
}
