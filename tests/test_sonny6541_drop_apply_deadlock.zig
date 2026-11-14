// SONNY-6541 (1): a Raft `drop_graph` apply and a leader request that holds
// the graph's lock and proposes do not deadlock.
//
// The apply runs on the thread that steps or ticks the Raft node, under the
// node's `inner_mutex` (`RaftNode.drainReady`). Its drop takes the graph's
// write lock (`GraphStore.dropGraph`, SONNY-3350 / SONNY-3135) and waits for
// every holder. A statement on the leader holds its graph's lock from before
// it runs until after its writes are proposed and committed
// (`execution.endStatementSucceeded` -> `statement_proposals.flush`), and the
// propose takes `inner_mutex` (`RaftNode.proposeCommand`). The apply then
// waits for the request's lock, the request for the apply's mutex: the Raft
// node never moves again (no tick, no heartbeat, no apply), and neither does
// any request on the graph.
//
// The interleaving is forced, not hoped for: a request thread takes the
// graph's write lock through the graph-lock API (as the transports do), the
// leader is given a `drop_graph` entry, and the request proposes a write only
// once the drop's apply has started on the leader and is waiting for the
// lock (committed on the leader, not applied). A watchdog ends the run with
// a failure if the request has not returned in 20 s, instead of hanging the
// suite.
//
// The cluster is the in-process 3-node Raft cluster of the SONNY-3348
// regressions (`sonny3348_cluster_harness.zig`): the real coordinators, the
// raft library's in-process transport, every node applying to the process
// store through `raft_apply`.
//
// CANARY: REQ=REQ-SONNY-6541-DROP-APPLY-NO-DEADLOCK; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6541_drop_apply_deadlock.zig; OWNER=distributed; UPDATED=2026-11-14

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const statement_proposals = geode.distributed.statement_proposals;
const cr = geode.distributed.cluster_replication;
const ch = @import("sonny3348_cluster_harness.zig");
const fx = ch.fx;
const nowMs = ch.nowMs;

const G = "g1";
const WATCHDOG_MS: i64 = 20_000;

const Request = struct {
    locked: std.atomic.Value(bool) = .init(false),
    go: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,

    fn run(self: *Request) void {
        defer self.done.store(true, .release);
        const lock = graph_store.acquireGraphWriteLock(G);
        defer graph_store.releaseGraphLock(lock);
        self.locked.store(true, .release);
        while (!self.go.load(.acquire)) fx.sleepMs(1);
        // What a statement's flush does under the transport's lock: propose
        // the write, then wait for its commit.
        const labels = [_][]const u8{"R6541"};
        const props = [_]cr.Prop{.{ .key = "k", .value = .{ .Int = 1 } }};
        const payload = cr.serializeNodeCreate(testing.allocator, G, &labels, &props) catch |e| {
            self.err = e;
            return;
        };
        defer testing.allocator.free(payload);
        statement_proposals.submit(.create, G, payload, null) catch |e| {
            self.err = e;
        };
    }
};

test "SONNY-6541 (1): a leader request holding its graph's lock proposes while a Raft drop_graph of that graph applies" {
    var h: ch.Harness = .{};
    try h.init(&.{});
    defer h.deinit();
    const leader = h.cl.leader;
    try testing.expect(h.f.st.graphExists(G));

    var req: Request = .{};
    const rt = try std.Thread.spawn(.{}, Request.run, .{&req});
    while (!req.locked.load(.acquire)) fx.sleepMs(1);

    const drop_idx = try leader.proposeWrite(.{ .schema_change = .{ .operation = .drop_graph, .graph = G, .schema = "" } });

    // The drop is committed on the leader and its apply is waiting for the
    // request's lock: committed, not applied, for a while.
    var stable_since: ?i64 = null;
    const wait_deadline = nowMs() + 10_000;
    while (true) : (fx.sleepMs(5)) {
        if (nowMs() > wait_deadline) return error.DropNeverCommitted;
        const waiting = leader.raft.committedIndex() >= drop_idx and leader.raft.appliedIndex() < drop_idx;
        if (!waiting) {
            stable_since = null;
            continue;
        }
        if (stable_since == null) stable_since = nowMs();
        if (nowMs() - stable_since.? >= 300) break;
    }

    req.go.store(true, .release);
    const watchdog_deadline = nowMs() + WATCHDOG_MS;
    while (!req.done.load(.acquire)) : (fx.sleepMs(10)) {
        if (nowMs() > watchdog_deadline) {
            std.debug.print("SONNY-6541 (1): DEADLOCK: the request holding {s}'s lock has not returned from its propose in {d} ms; the leader's drop_graph apply waits for that lock under inner_mutex (committed={d} applied={d} drop_idx={d})\n", .{
                G, WATCHDOG_MS, leader.raft.committedIndex(), leader.raft.appliedIndex(), drop_idx,
            });
            std.process.exit(1);
        }
    }
    rt.join();

    // The request learns its graph is being dropped; nothing was proposed.
    std.debug.print("SONNY-6541 (1): the request's propose answered {s}\n", .{if (req.err) |e| @errorName(e) else "success"});
    try testing.expectEqual(@as(?anyerror, error.GraphNotFound), req.err);

    // The drop then applies on every node, and the cluster still commits.
    _ = try h.cl.settle();
    try testing.expect(!h.f.st.graphExists(G));
    const labels = [_][]const u8{"After6541"};
    const props = [_]cr.Prop{.{ .key = "k", .value = .{ .Int = 2 } }};
    const payload = try cr.serializeNodeCreate(testing.allocator, "g2", &labels, &props);
    defer testing.allocator.free(payload);
    try statement_proposals.submit(.create, "g2", payload, null);
    _ = try h.cl.settle();
    try testing.expectEqual(@as(usize, 1), fx.countLabel(h.f.st, "g2", "After6541"));
}
