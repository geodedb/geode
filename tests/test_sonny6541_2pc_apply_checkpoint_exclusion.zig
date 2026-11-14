// SONNY-6541 (2): a 2PC commit's writes to a graph and a checkpoint of that
// graph do not run at the same time.
//
// A committed Raft `txn_decide` applies its prepared write set
// (`raft_apply.applyTxnDecide` -> `TxnCoordinator.handleDecide` ->
// `applyWriteSet` -> `createNodeWithId` ...) on the Raft apply thread, under
// the Raft node's `inner_mutex`, like a replicated graph mutation. SONNY-6528
// (1) made a graph mutation's apply hold the graph's `replicated_apply_mutex`,
// which a checkpoint of the graph takes right after its `rwlock`; the 2PC
// apply held nothing, so a checkpoint could run in the middle of its write
// (persisting a shard's live-node count ahead of the records, or scanning
// maps the write resizes). The coordinator is registered by every cluster
// node (`ClusterCoordinator.init`), so a committed decide is applied.
//
// Forced as test-sonny6528-apply-checkpoint-exclusion forces it: the decide's
// node create stops right after the engine counted the node and before its
// record is written (`node_slot_allocated_hook`), starts a full checkpoint on
// another thread (`checkpointAll`, which waits for each graph's lock without
// a deadline), and waits up to 15 s for it. The checkpoint must not complete
// inside that window; it must complete once the decide's write is done. The
// prepare and the decide run through the real entry point
// (`raft_apply.applyCommand`) with the real coordinator on the real
// engine-backed global store.
//
// CANARY: REQ=REQ-SONNY-6541-2PC-APPLY-CHECKPOINT-EXCLUSION; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6541_2pc_apply_checkpoint_exclusion.zig; OWNER=distributed; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const raft_apply = geode.distributed.raft_apply;
const txn_mod = geode.distributed.txn_coordinator;
const gsa = geode.graph_storage_adapter;

const G = "g6541twopc";
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

var next_xid: u64 = 100;

fn commitCreate(allocator: std.mem.Allocator, node_id: u64) !void {
    const ops = [_]txn_mod.WriteSetOp{
        .{ .node_op = .{ .op_type = .create, .node_id = node_id, .label = "A6541", .graph = G, .props = &.{} } },
    };
    const write_set = try txn_mod.serializeWriteSet(allocator, &ops);
    defer allocator.free(write_set);
    const xid = next_xid;
    next_xid += 1;
    const rp = try raft_apply.applyCommand(allocator, null, .{ .txn_prepare = .{ .xid = xid, .shard_id = 0, .write_set = write_set, .metadata = "" } }, xid * 2);
    defer allocator.free(rp);
    if (rp.len != 1 or rp[0] != 1) return error.PrepareVotedAbort;
    const rd = try raft_apply.applyCommand(allocator, null, .{ .txn_decide = .{ .xid = xid, .commit = true } }, xid * 2 + 1);
    allocator.free(rd);
}

test "SONNY-6541 (2): a checkpoint of a graph waits for a 2PC commit's write to it" {
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
        var coord = try txn_mod.TxnCoordinator.init(allocator, store);
        defer coord.deinit();
        raft_apply.setGlobalTxnCoordinator(&coord);
        defer raft_apply.resetGlobalTxnCoordinator();
        // Some committed nodes first, so the checkpoint has state to write.
        const base: u64 = 1 << 40;
        for (0..8) |i| try commitCreate(allocator, base + i);

        Race.apply_thread = std.Thread.getCurrentId();
        Race.armed.store(true, .release);
        gsa.node_slot_allocated_hook = Race.hook;
        defer gsa.node_slot_allocated_hook = null;
        const t = try std.Thread.spawn(.{}, Race.checkpointer, .{});
        try commitCreate(allocator, base + 100);
        t.join();

        std.debug.print("SONNY-6541 (2): checkpoint completed inside the 2PC commit's create: {}; checkpoint failed: {}\n", .{ Race.done_in_window.load(.acquire), Race.checkpoint_failed.load(.acquire) });
        try std.testing.expect(Race.go.load(.acquire)); // the hook ran
        try std.testing.expect(Race.done.load(.acquire));
        try std.testing.expect(!Race.checkpoint_failed.load(.acquire));
        try std.testing.expectEqual(@as(usize, 9), store.countNodesByLabel(G, "A6541", null));
        if (Race.done_in_window.load(.acquire)) return error.CheckpointRanInsideTwoPhaseCommit;
    }
}
