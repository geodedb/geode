// SONNY-6631: a follower's and a replaying node's Raft apply does not
// hydrate a graph under the Raft node's `inner_mutex`.
//
// A Raft apply runs under `inner_mutex` (`RaftNode.drainReady`): while it
// runs the node takes no tick, no inbound message and no term or leader
// read. SONNY-6547 (4) and SONNY-6567 (6b) hydrated an entry's own graph
// (`GraphMutation.graph`) before `inner_mutex` on the leader's propose and
// on the follower's QUIC receive path. Two shapes still hydrated under it,
// for 220-262 ms on a 20,000-node graph (the in-process election timeout is
// 250 ms, and test-sonny6567-raft-apply-hydration was flaky under load):
//
//   1. a statement batch (GBAT) whose entries write another graph than the
//      entry's: only the entry's graph was hydrated first;
//   2. a node replaying its committed log after a restart: nothing received
//      or proposed the entries, so nothing hydrated their graphs.
//
// Both run here through the real code: a follower `ClusterCoordinator`'s
// Raft node receiving an AppendEntries that carries and commits the entry
// (`RaftNode.handleMessage`, the call the cluster's frame reader makes), and
// a one-voter coordinator with durable Raft storage restarted on its data
// directory, its driver thread ticking it, while one spinning thread per CPU
// loads the machine. No graph may be built (hydrated) on the applying thread
// (`graph_store.replicated_apply_hydrations_total`) and no label or
// relationship type first assigned its id there
// (`graph_storage_adapter.replicated_apply_label_assignments_total`): both
// are what held `inner_mutex` (SONNY-6956: a 50 ms wall-clock bound on the
// apply critical section, `RaftNode.stats.apply_max_ns`, failed on loaded CI
// runners at 96 ms with neither happening; it is still reported). Every
// entry must apply. A probe thread reading the node's term (`RaftNode.currentTerm`,
// which takes `inner_mutex`) every millisecond measures the whole hold. It
// also covers the Raft log's own write and fsync (persist before apply,
// SONNY-6611), whose time is the disk's, not the apply's: SONNY-6667 saw
// 276 ms on a loaded machine with a 0 ms apply. So the probe's longest wait,
// less the longest `advancePersist()` (`RaftNode.stats.persist_max_ns`),
// must stay under the election timeout; both are reported.
//
// The follower's creates use a label new to the graph: graph-storage writes
// a new name to the graph's label dictionary durably (two fsyncs per shard
// set) on first use, which took 40-80 ms under `inner_mutex` until the
// names an entry writes were interned with its graphs' hydration, before
// `inner_mutex` (SONNY-6633 item 4, SONNY-6636).
//
// CANARY: REQ=REQ-SONNY-6631-APPLY-HYDRATION-OFF-RAFT-MUTEX; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6631_apply_hydration_off_mutex.zig; OWNER=distributed; UPDATED=2026-11-24

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const raft_apply = geode.distributed.raft_apply;
const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;
const cr = geode.distributed.cluster_replication;
const adapter_mod = geode.graph_storage_adapter;
const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;

const NODES: usize = 20_000;
const HOLD_MS: i64 = 3_000;
const ELECTION_TIMEOUT_MS: u64 = 250;

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

/// One spinning thread per CPU, until stopped.
const Load = struct {
    stop: std.atomic.Value(bool) = .init(false),
    threads: [64]std.Thread = undefined,
    n: usize = 0,

    fn spin(self: *Load) void {
        var x: u64 = 0;
        while (!self.stop.load(.monotonic)) {
            x +%= 1;
            std.mem.doNotOptimizeAway(x);
        }
    }

    fn start(self: *Load) !void {
        const cpus = @min(std.Thread.getCpuCount() catch 4, self.threads.len);
        while (self.n < cpus) : (self.n += 1) self.threads[self.n] = try std.Thread.spawn(.{}, spin, .{self});
    }

    fn finish(self: *Load) void {
        self.stop.store(true, .release);
        for (self.threads[0..self.n]) |t| t.join();
        self.n = 0;
    }
};

/// The longest `inner_mutex` wait seen by a thread reading the term.
const Probe = struct {
    raft: *raft_consensus.RaftNode,
    stop: std.atomic.Value(bool) = .init(false),
    max_wait_ms: i64 = 0,
    samples: usize = 0,

    fn run(self: *Probe) void {
        while (!self.stop.load(.acquire)) {
            const t0 = nowMs();
            _ = self.raft.currentTerm();
            const dt = nowMs() - t0;
            if (dt > self.max_wait_ms) self.max_wait_ms = dt;
            self.samples += 1;
            sleepMs(1);
        }
    }
};

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
    const labels = [_][]const u8{"S6631"};
    for (0..n) |_| _ = try store.createNodeWithGraphAndTenant(&labels, graph, graph_store.DEFAULT_TENANT_ID);
}

fn createCmd(allocator: std.mem.Allocator, graph: []const u8, label: []const u8) ![]u8 {
    const labels = [_][]const u8{label};
    const props = [_]cr.Prop{.{ .key = "k", .value = .{ .Int = 1 } }};
    return cr.serializeNodeCreate(allocator, graph, &labels, &props);
}

/// The work that held the Raft node's `inner_mutex` in an apply, counted
/// process-wide; a test compares the counts before and after its applies.
const ApplyWork = struct {
    hydrations: u64,
    label_assignments: u64,

    fn now() ApplyWork {
        return .{
            .hydrations = graph_store.replicated_apply_hydrations_total.load(.acquire),
            .label_assignments = adapter_mod.replicated_apply_label_assignments_total.load(.acquire),
        };
    }

    /// No graph built and no name first assigned on an applying thread since `before`.
    fn expectNoneSince(before: ApplyWork) !void {
        const after = now();
        std.debug.print("SONNY-6631: during the applies, {d} graph builds and {d} first label assignments ran on the applying thread\n", .{
            after.hydrations - before.hydrations, after.label_assignments - before.label_assignments,
        });
        try testing.expectEqual(before.hydrations, after.hydrations);
        try testing.expectEqual(before.label_assignments, after.label_assignments);
    }
};

fn countLabel(store: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    return store.countNodesByLabel(graph, label, null);
}

/// A store under `data_dir` holding `graphs`, NODES nodes each, saved.
fn openSeededStore(allocator: std.mem.Allocator, data_dir: []const u8, graphs: []const []const u8) !*graph_store.GraphStore {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    errdefer graph_store.deinitGlobalStore();
    raft_apply.setGlobalStore(store);
    for (graphs) |g| {
        try store.createGraph(g);
        try seed(store, g, NODES);
    }
    try store.saveToFile();
    return store;
}

test "SONNY-6631: a follower applies a batch entry writing another graph not hydrated yet without hydrating it under inner_mutex" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    // A replayable bulk load (checkpoint-durable WAL); the apply is unchanged.
    if (setenv("GEODE_WAL_SYNC", "deferred", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_WAL_SYNC");

    const store = try openSeededStore(allocator, data_dir, &.{ "ga", "gb" });
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    defer raft_apply.resetGlobalStore();

    // Node 2 of a three-node cluster, as the cluster builds it (its apply
    // callbacks wired to the process store).
    const peers = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 22631 },
        .{ .id = 3, .address = "127.0.0.1", .port = 22633 },
    };
    const c = try allocator.create(ClusterCoordinator);
    defer allocator.destroy(c);
    c.* = try ClusterCoordinator.init(allocator, 2, .{
        .peers = &peers,
        .listen_address = "127.0.0.1",
        .cluster_port = 22632,
        .cluster_token = "test-sonny6631-follower", // gitleaks:allow
        .cluster_name = "test-cluster",
        .election_timeout_ms = ELECTION_TIMEOUT_MS,
    });
    defer c.deinit();
    var ipt = raft_lib.InProcessTransport.init(allocator);
    defer ipt.deinit();
    for (1..4) |id| try ipt.register(id);
    c.raft.setInnerTransport(ipt.transport());

    // The batch is for graph `ga` (hydrated); its entries write `gb`, put
    // back to "not hydrated yet" as a restart leaves it, its lock held by
    // a reader (SONNY-6567 (6c)).
    try store.markPendingHydrationForTest("gb");
    const inner1 = try createCmd(allocator, "gb", "F6631");
    defer allocator.free(inner1);
    const inner2 = try createCmd(allocator, "gb", "F6631");
    defer allocator.free(inner2);
    const batch = try cr.serializeBatch(allocator, null, &.{
        .{ .mutation = .create, .graph = "gb", .data = inner1 },
        .{ .mutation = .create, .graph = "gb", .data = inner2 },
    });
    defer allocator.free(batch);
    var entries = [_]raft_consensus.LogEntry{.{
        .term = 1,
        .index = 1,
        .command = .{ .graph_mutation = .{ .graph = "ga", .mutation_type = .create, .data = batch, .txn_id = null } },
        .timestamp = 0,
        .client_id = null,
        .serial_number = null,
    }};

    var reader: Reader = .{ .graph = "gb" };
    const rt = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    while (!reader.locked.load(.acquire)) sleepMs(1);

    var load: Load = .{};
    try load.start();
    var probe: Probe = .{ .raft = c.raft };
    const pt = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    sleepMs(20);

    // The leader's AppendEntries carrying the entry and committing it.
    const work0 = ApplyWork.now();
    const t0 = nowMs();
    try c.raft.handleMessage(1, .{ .append_entries = .{
        .term = 1,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &entries,
        .leader_commit = 1,
    } });
    const handled_ms = nowMs() - t0;
    sleepMs(20);
    probe.stop.store(true, .release);
    pt.join();
    const spinners = load.n;
    load.finish();
    while (!reader.done.load(.acquire)) sleepMs(5);
    rt.join();
    const leftover = try ipt.drain(1, allocator);
    for (leftover) |m| raft_lib.InProcessTransport.freeMessage(allocator, m);
    allocator.free(leftover);

    const apply_ms: i64 = @intCast(c.raft.stats.apply_max_ns / std.time.ns_per_ms);
    const persist_ms: i64 = @intCast(c.raft.stats.persist_max_ns / std.time.ns_per_ms);
    std.debug.print("SONNY-6631 follower: AppendEntries handled in {d} ms (hydration included); apply critical section {d} ms; inner_mutex unavailable for up to {d} ms, of which Raft persistence up to {d} ms ({d} probes, {d} spinning threads; election timeout {d} ms)\n", .{
        handled_ms, apply_ms, probe.max_wait_ms, persist_ms, probe.samples, spinners, ELECTION_TIMEOUT_MS,
    });
    try testing.expectEqual(@as(u64, 1), c.raft.appliedIndex());
    try testing.expectEqual(@as(usize, 2), countLabel(store, "gb", "F6631"));
    try ApplyWork.expectNoneSince(work0);
    try testing.expect(probe.max_wait_ms - persist_ms < ELECTION_TIMEOUT_MS);
}

/// A one-voter coordinator with durable Raft storage, ticked by a thread.
const OneVoter = struct {
    c: *ClusterCoordinator = undefined,
    ipt: raft_lib.InProcessTransport = undefined,
    running: std.atomic.Value(bool) = .init(true),
    driver: ?std.Thread = null,

    fn init(self: *OneVoter, a: std.mem.Allocator, data_dir: []const u8) !void {
        self.ipt = raft_lib.InProcessTransport.init(a);
        errdefer self.ipt.deinit();
        self.c = try a.create(ClusterCoordinator);
        errdefer a.destroy(self.c);
        self.c.* = try ClusterCoordinator.init(a, 1, .{
            .peers = &.{},
            .listen_address = "127.0.0.1",
            .cluster_port = 22634,
            .cluster_token = "test-sonny6631-replay",
            .cluster_name = "test-cluster",
            .election_timeout_ms = ELECTION_TIMEOUT_MS,
            .data_dir = data_dir,
        });
        try self.ipt.register(1);
        self.c.raft.setInnerTransport(self.ipt.transport());
    }

    fn start(self: *OneVoter) !void {
        self.running.store(true, .release);
        self.driver = try std.Thread.spawn(.{}, drive, .{self});
    }

    fn stop(self: *OneVoter) void {
        self.running.store(false, .release);
        if (self.driver) |t| t.join();
        self.driver = null;
    }

    fn deinit(self: *OneVoter, a: std.mem.Allocator) void {
        self.stop();
        self.c.deinit();
        a.destroy(self.c);
        self.ipt.deinit();
    }

    fn drive(self: *OneVoter) void {
        while (self.running.load(.acquire)) {
            self.c.raft.tick() catch {};
            const msgs = self.ipt.drain(1, testing.allocator) catch &.{};
            testing.allocator.free(msgs);
            sleepMs(5);
        }
    }

    /// Leader, and everything committed applied, up to `index` at least.
    fn waitApplied(self: *OneVoter, index: u64) !void {
        const deadline = nowMs() + 15_000;
        while (self.c.role() != .leader or self.c.raft.appliedIndex() < @max(index, self.c.raft.committedIndex())) : (sleepMs(5)) {
            if (nowMs() > deadline) return error.ApplyTimeout;
        }
    }
};

test "SONNY-6631: a node replaying its committed log after a restart does not hydrate the entries' graphs under inner_mutex" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    if (setenv("GEODE_WAL_SYNC", "deferred", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_WAL_SYNC");

    const store = try openSeededStore(allocator, data_dir, &.{"gr"});
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    defer raft_apply.resetGlobalStore();

    // First run: a create on `gr` is proposed, committed and applied.
    var index: u64 = 0;
    {
        var one: OneVoter = .{};
        try one.init(allocator, data_dir);
        defer one.deinit(allocator);
        try one.start();
        try one.waitApplied(1);
        const payload = try createCmd(allocator, "gr", "R6631");
        defer allocator.free(payload);
        index = try one.c.proposeWrite(.{ .graph_mutation = .{ .graph = "gr", .mutation_type = .create, .data = payload, .txn_id = null } });
        try one.waitApplied(index);
    }
    try testing.expectEqual(@as(usize, 1), countLabel(store, "gr", "R6631"));

    // Restart: the Raft node reopens its log on the same directory, and the
    // graph is back to "not hydrated yet", as a process restart leaves it.
    try store.markPendingHydrationForTest("gr");
    var one: OneVoter = .{};
    try one.init(allocator, data_dir);
    defer one.deinit(allocator);

    var load: Load = .{};
    try load.start();
    var probe: Probe = .{ .raft = one.c.raft };
    const pt = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    sleepMs(20);
    const work0 = ApplyWork.now();
    const t0 = nowMs();
    try one.start();
    const replayed = one.waitApplied(index);
    const replay_ms = nowMs() - t0;
    sleepMs(20);
    probe.stop.store(true, .release);
    pt.join();
    const spinners = load.n;
    load.finish();
    try replayed;

    const apply_ms: i64 = @intCast(one.c.raft.stats.apply_max_ns / std.time.ns_per_ms);
    const persist_ms: i64 = @intCast(one.c.raft.stats.persist_max_ns / std.time.ns_per_ms);
    std.debug.print("SONNY-6631 replay: entries 1..{d} replayed in {d} ms after the restart; apply critical section {d} ms; inner_mutex unavailable for up to {d} ms, of which Raft persistence up to {d} ms ({d} probes, {d} spinning threads; election timeout {d} ms)\n", .{
        one.c.raft.appliedIndex(), replay_ms, apply_ms, probe.max_wait_ms, persist_ms, probe.samples, spinners, ELECTION_TIMEOUT_MS,
    });
    // Replayed (the create is idempotent: still one node), and the node was
    // never held for a hydration.
    try testing.expect(one.c.raft.appliedIndex() >= index);
    try testing.expectEqual(@as(usize, 1), countLabel(store, "gr", "R6631"));
    try ApplyWork.expectNoneSince(work0);
    try testing.expect(probe.max_wait_ms - persist_ms < ELECTION_TIMEOUT_MS);
}
