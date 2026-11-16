// SONNY-6567 (6): what a Raft apply does to a graph not hydrated yet, on a
// follower, during log replay and for a statement batch whose entry writes
// another graph.
//
// A Raft apply runs under the node's `inner_mutex` (`RaftNode.drainReady`):
// while it runs nothing else on the node moves (no tick, no heartbeat, no
// inbound message). SONNY-6547 (4) moved the leader's first hydration of an
// entry's graph before `inner_mutex` (`raft_apply.prehydrateForApply`) and
// made the apply's own hydration skip its completion persist (a checkpoint
// of the graph that waits up to 5 s for the graph's lock). Two shapes were
// left:
//
//   (b) a follower and a node replaying its log apply entries nobody
//       hydrated for them: the apply hydrates the graph under
//       `inner_mutex` (no persist, so no lock wait: the scan only). Its cost
//       is measured here, the apply called as the follower calls it, on a
//       graph of NODES nodes put back to "not hydrated yet".
//   (c) a GBAT batch whose entry writes ANOTHER graph than the entry's: the
//       entry's create (`GraphStore.createNodeWithId`) hydrated that graph
//       with the completion persist, under `inner_mutex`, waiting for the
//       graph's lock. With a reader holding that graph's lock for 3 s the
//       apply took ~3 s; it must stay under the in-process harness's
//       election timeout (250 ms), and the entry must apply.
//
// SONNY-6631: (b) still scanned the graph under `inner_mutex` (220-262 ms,
// at the 250 ms election timeout, flaky under load), and so did (c) for the
// batch's own graph-of-entries. The Raft node now hydrates an entry's
// graphs, a batch's included, before it takes `inner_mutex`
// (`RaftNode.prehydrate_callback` = `raft_apply.prehydrateForApply`, on
// receive, on replay and on propose). Both shapes run that sequence here:
// prehydrate, then the apply, which is timed and must take at most 50 ms.
// The creates use labels new to the graph: their durable label-dictionary
// writes are interned before the apply too (SONNY-6633 item 4, SONNY-6636).
//
// CANARY: REQ=REQ-SONNY-6567-RAFT-APPLY-HYDRATION; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6567_raft_apply_hydration.zig; OWNER=distributed; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;

const NODES: usize = 20_000;
const HOLD_MS: i64 = 3_000;
const ELECTION_TIMEOUT_MS: i64 = 250;
/// SONNY-6631: the apply critical section's budget.
const CRITICAL_SECTION_MS: i64 = 50;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: i64) void {
    io().sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Reader = struct {
    graph: []const u8,
    locked: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Reader) void {
        defer self.done.store(true, .release);
        const lock = graph_store.acquireGraphReadLock(self.graph);
        defer graph_store.releaseGraphLock(lock);
        self.locked.store(true, .release);
        const until = nowMs() + HOLD_MS;
        while (nowMs() < until) sleepMs(5);
    }
};

fn seed(store: *graph_store.GraphStore, graph: []const u8, n: usize) !void {
    const labels = [_][]const u8{"S6567"};
    for (0..n) |_| _ = try store.createNodeWithGraphAndTenant(&labels, graph, graph_store.DEFAULT_TENANT_ID);
}

fn createCmd(allocator: std.mem.Allocator, graph: []const u8, label: []const u8) ![]u8 {
    const labels = [_][]const u8{label};
    const props = [_]cr.Prop{.{ .key = "k", .value = .{ .Int = 1 } }};
    return cr.serializeNodeCreate(allocator, graph, &labels, &props);
}

fn countLabel(store: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    return store.countNodesByLabel(graph, label, null);
}

test "SONNY-6567 (6): a follower's / replay's apply hydration under inner_mutex, and a batch entry on another graph" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    // The seed is a replayable bulk load: checkpoint-durable WAL (no fsync
    // per create), as GEODE_WAL_SYNC=deferred documents. It changes nothing
    // the apply does.
    if (setenv("GEODE_WAL_SYNC", "deferred", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_WAL_SYNC");

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    raft_apply.setGlobalStore(store);

    try store.createGraph("ga");
    try store.createGraph("gb");
    try seed(store, "ga", NODES);
    try seed(store, "gb", NODES);
    try store.saveToFile();

    // (b) The follower / replay shape: the apply hydrates its own graph.
    try store.markPendingHydrationForTest("ga");
    {
        const payload = try createCmd(allocator, "ga", "B6567");
        defer allocator.free(payload);
        const cmd: geode.distributed.raft_consensus.Command = .{ .graph_mutation = .{ .graph = "ga", .mutation_type = .create, .data = payload, .txn_id = null } };
        raft_apply.prehydrateForApply(cmd);
        const t0 = nowMs();
        const out = try raft_apply.applyCommand(allocator, store, cmd, 1_000_001);
        allocator.free(out);
        const dt = nowMs() - t0;
        std.debug.print("SONNY-6567 (6b) a follower's / replay's apply of a create on a {d}-node graph not hydrated yet held the apply (inner_mutex) for {d} ms (budget {d} ms)\n", .{ NODES, dt, CRITICAL_SECTION_MS });
        try testing.expectEqual(@as(usize, 1), countLabel(store, "ga", "B6567"));
        try testing.expect(dt <= CRITICAL_SECTION_MS);
    }

    // (c) A batch for graph `ga` whose entry writes `gb`, `gb` not hydrated
    // yet and its lock held by a reader.
    try store.markPendingHydrationForTest("gb");
    var reader: Reader = .{ .graph = "gb" };
    const rt = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    while (!reader.locked.load(.acquire)) sleepMs(1);
    var dt: i64 = 0;
    const applied = blk: {
        const inner = try createCmd(allocator, "gb", "C6567");
        defer allocator.free(inner);
        const inner2 = try createCmd(allocator, "gb", "C6567");
        defer allocator.free(inner2);
        const batch = try cr.serializeBatch(allocator, null, &.{
            .{ .mutation = .create, .graph = "gb", .data = inner },
            .{ .mutation = .create, .graph = "gb", .data = inner2 },
        });
        defer allocator.free(batch);
        const cmd: geode.distributed.raft_consensus.Command = .{ .graph_mutation = .{ .graph = "ga", .mutation_type = .create, .data = batch, .txn_id = null } };
        raft_apply.prehydrateForApply(cmd);
        const t0 = nowMs();
        const out = raft_apply.applyCommand(allocator, store, cmd, 1_000_002);
        dt = nowMs() - t0;
        break :blk out;
    };
    while (!reader.done.load(.acquire)) sleepMs(5);
    rt.join();
    const out = try applied;
    allocator.free(out);
    std.debug.print("SONNY-6567 (6c) a batch entry writing another graph not hydrated yet, its lock held: the apply (inner_mutex) took {d} ms (budget {d} ms, election timeout {d} ms)\n", .{ dt, CRITICAL_SECTION_MS, ELECTION_TIMEOUT_MS });
    try testing.expectEqual(@as(usize, 2), countLabel(store, "gb", "C6567"));
    try testing.expect(dt <= CRITICAL_SECTION_MS);
}
