// SONNY-6547 (3): a replicated DROP GRAPH applied on a node where the graph
// is in use is not reported as applied while the node keeps the graph.
//
// The report: in a single-voter cluster the apply runs on the proposer's own
// thread, under `inner_mutex`; if that thread holds the graph's read lock,
// `GraphStore.dropGraph` refuses with `ObjectInUse` (its write lock would wait
// for that thread forever, SONNY-6425), and the `drop_graph` apply arm logged
// the refusal, then logged the graph as dropped, and returned success: the
// entry counted as applied, the node kept the graph, and every node that
// replays the log later drops it.
//
// The first test runs the reported scenario on a real one-voter
// `ClusterCoordinator` (raft library, apply callback wired to the process
// store through `raft_apply`), ticked by a driver thread: a thread holding
// the graph's read lock proposes the drop (through the coordinator's public
// propose, as a future replicated DROP GRAPH would: no server code proposes a
// `schema_change` today, SONNY-6547 item 6). With the pinned raft library a
// propose only appends; the entry commits and applies on the next tick, on
// the driver thread, which holds no graph lock: the apply announces its wait
// (`beginReplicatedDrop`), waits for the proposer's read lock, and drops the
// graph once it is released. The outcome is the same on every node.
//
// The second test forces the refusal the report describes, through the real
// apply entry point (`raft_apply.applyCommand`) called by a thread that holds
// the graph's read lock: the apply must fail (`ObjectInUse`: the Raft node
// counts and logs it as a committed entry not applied), not report the graph
// dropped. SONNY-6567 (6a): the node then stops applying committed entries
// (`raft_apply.applyHalted`) until it is restarted, rather than go on
// without the drop every other node applied.
//
// CANARY: REQ=REQ-SONNY-6547-REPLICATED-DROP-IN-USE; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6547_single_voter_drop.zig; OWNER=distributed; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const cluster_mod = geode.distributed.cluster;
const ClusterCoordinator = cluster_mod.ClusterCoordinator;
const raft_lib = geode.distributed.raft;
const raft_apply = geode.distributed.raft_apply;

const G = "g1";

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

const OneVoter = struct {
    c: *ClusterCoordinator = undefined,
    ipt: raft_lib.InProcessTransport = undefined,
    running: std.atomic.Value(bool) = .init(true),
    driver: ?std.Thread = null,

    fn init(self: *OneVoter, a: std.mem.Allocator) !void {
        self.ipt = raft_lib.InProcessTransport.init(a);
        errdefer self.ipt.deinit();
        const cfg = ClusterCoordinator.Config{
            .peers = &.{},
            .listen_address = "127.0.0.1",
            .cluster_port = 22480,
            .cluster_token = "test-sonny6547-one-voter", // gitleaks:allow
            .cluster_name = "test-cluster",
            .election_timeout_ms = 250,
        };
        self.c = try a.create(ClusterCoordinator);
        errdefer a.destroy(self.c);
        self.c.* = try ClusterCoordinator.init(a, 1, cfg);
        try self.ipt.register(1);
        self.c.raft.setInnerTransport(self.ipt.transport());
        self.driver = try std.Thread.spawn(.{}, drive, .{self});
        const deadline = nowMs() + 15_000;
        while (self.c.role() != .leader) : (fx.sleepMs(5)) {
            if (nowMs() > deadline) return error.NoLeader;
        }
        // The leader's own no-op commits and applies first.
        while (self.c.raft.appliedIndex() == 0 or self.c.raft.appliedIndex() < self.c.raft.committedIndex()) : (fx.sleepMs(5)) {
            if (nowMs() > deadline) return error.NoCommit;
        }
    }

    fn deinit(self: *OneVoter, a: std.mem.Allocator) void {
        self.running.store(false, .release);
        if (self.driver) |t| t.join();
        self.c.deinit();
        a.destroy(self.c);
        self.ipt.deinit();
    }

    fn drive(self: *OneVoter) void {
        while (self.running.load(.acquire)) {
            self.c.raft.tick() catch {};
            const msgs = self.ipt.drain(1, testing.allocator) catch &.{};
            testing.allocator.free(msgs);
            fx.sleepMs(5);
        }
    }

    fn settle(self: *OneVoter) !void {
        const deadline = nowMs() + 10_000;
        while (self.c.raft.appliedIndex() < self.c.raft.committedIndex()) : (fx.sleepMs(5)) {
            if (nowMs() > deadline) return error.ApplyTimeout;
        }
    }
};

test "SONNY-6547 (3): a one-voter cluster applies a drop proposed under the graph's read lock on its tick thread, once the lock is released" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    raft_apply.setGlobalStore(f.st);
    defer raft_apply.resetGlobalStore();
    try testing.expect(f.st.graphExists(G));

    var one: OneVoter = .{};
    try one.init(testing.allocator);
    defer one.deinit(testing.allocator);

    const errors_before = one.c.raft.stats.apply_errors;
    var idx: u64 = 0;
    var applied_under_lock: u64 = 0;
    {
        // A request reading the graph proposes while it holds its read lock.
        const lock = graph_store.acquireGraphReadLock(G);
        defer graph_store.releaseGraphLock(lock);
        idx = try one.c.proposeWrite(.{ .schema_change = .{ .operation = .drop_graph, .graph = G, .schema = "" } });
        // The entry commits on the driver's next tick; its apply then waits
        // for this thread's read lock.
        const deadline = nowMs() + 10_000;
        while (one.c.raft.committedIndex() < idx) : (fx.sleepMs(5)) {
            if (nowMs() > deadline) return error.DropNeverCommitted;
        }
        fx.sleepMs(300);
        applied_under_lock = one.c.raft.appliedIndex();
        try testing.expect(f.st.graphExists(G));
    }
    try one.settle();
    const exists = f.st.graphExists(G);
    std.debug.print("SONNY-6547 (3): drop entry {d}: applied index {d} while the proposer held the read lock, {d} after; apply errors {d} -> {d}; graph exists={}\n", .{
        idx, applied_under_lock, one.c.raft.appliedIndex(), errors_before, one.c.raft.stats.apply_errors, exists,
    });
    // Not applied while the proposer held the lock (it waited for it), then
    // applied, and the graph is gone.
    try testing.expect(applied_under_lock < idx);
    try testing.expect(one.c.raft.appliedIndex() >= idx);
    try testing.expect(!exists);
    try testing.expectEqual(errors_before, one.c.raft.stats.apply_errors);
}

test "SONNY-6547 (3): a drop_graph apply refused because its thread holds the graph's read lock fails instead of reporting the graph dropped" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expect(f.st.graphExists(G));

    const result = blk: {
        const lock = graph_store.acquireGraphReadLock(G);
        defer graph_store.releaseGraphLock(lock);
        break :blk raft_apply.applyCommand(testing.allocator, f.st, .{ .schema_change = .{ .operation = .drop_graph, .graph = G, .schema = "" } }, 7);
    };
    if (result) |payload| {
        testing.allocator.free(payload);
        std.debug.print("SONNY-6547 (3): the drop_graph apply reported success; graph exists={}\n", .{f.st.graphExists(G)});
    } else |err| {
        std.debug.print("SONNY-6547 (3): the drop_graph apply failed with {s}; graph exists={}\n", .{ @errorName(err), f.st.graphExists(G) });
    }
    try testing.expectError(error.ObjectInUse, result);
    try testing.expect(f.st.graphExists(G));
    // SONNY-6567 (6a): and the node stops applying, so it cannot go on
    // without the drop: every later entry is refused until a restart (whose
    // log replay applies the drop with nothing open).
    try testing.expect(raft_apply.applyHalted());
    try testing.expectError(error.ReplicatedApplyHalted, raft_apply.applyCommand(testing.allocator, f.st, .noop, 8));
    try testing.expect(f.st.graphExists(G));
    raft_apply.resetApplyHaltForTesting(); // what a restart does
    // Without the lock, the same entry drops it.
    const again = try raft_apply.applyCommand(testing.allocator, f.st, .{ .schema_change = .{ .operation = .drop_graph, .graph = G, .schema = "" } }, 7);
    testing.allocator.free(again);
    try testing.expect(!f.st.graphExists(G));
}
