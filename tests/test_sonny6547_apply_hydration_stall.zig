// SONNY-6547 (4): the first hydration of a graph that a replicated write
// needs does not run under the Raft node's `inner_mutex`.
//
// A Raft apply runs on the thread that ticks, steps or proposes to the node,
// under `inner_mutex` (`RaftNode.drainReady`); nothing else on the node moves
// meanwhile (no tick, so no heartbeat and no election timer; no inbound
// message; no propose; no term or leader read). The graph-mutation apply
// hydrated its graph first (`raft_apply.applyGraphMutationInner` ->
// `GraphStore.ensureGraphHydrated`), and a first hydration persists its
// products (`persistHydrationProductsForGraph` -> `checkpointGraph`), which
// waits up to 5 s for the graph's lock. A local request holding that lock
// (a read in progress on the leader) kept the whole Raft node stopped for up
// to 5 s: longer than any election timeout, so the followers of a real
// cluster elect a new leader.
//
// The cluster is the in-process 3-node Raft cluster of the SONNY-3348
// regressions (`sonny3348_cluster_harness.zig`): the real coordinators, the
// raft library's in-process transport, every node applying to the process
// store. The graph is put back to "not hydrated yet" with
// `markPendingHydrationForTest` (as a restart leaves it), a reader holds its
// lock for 3 s, and a replicated create on it is proposed through the
// statement path (`statement_proposals.submit`). Meanwhile a probe thread
// reads the leader's term (`RaftNode.currentTerm`, which takes
// `inner_mutex`) every 2 ms. The longest a probe waited is the time the
// leader could not tick (its heartbeat gap). It must stay under the
// harness's election timeout (250 ms); the create must still apply.
//
// CANARY: REQ=REQ-SONNY-6547-APPLY-HYDRATION-OFF-RAFT-MUTEX; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6547_apply_hydration_stall.zig; OWNER=distributed; UPDATED=2026-11-14

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
const HOLD_MS: i64 = 3_000;
const ELECTION_TIMEOUT_MS: i64 = 250;

const Reader = struct {
    locked: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Reader) void {
        defer self.done.store(true, .release);
        const lock = graph_store.acquireGraphReadLock(G);
        defer graph_store.releaseGraphLock(lock);
        self.locked.store(true, .release);
        const until = nowMs() + HOLD_MS;
        while (nowMs() < until) fx.sleepMs(5);
    }
};

const Probe = struct {
    raft: *geode.distributed.raft_consensus.RaftNode,
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
            fx.sleepMs(2);
        }
    }
};

test "SONNY-6547 (4): a replicated write's first hydration of its graph does not stop the Raft node" {
    var h: ch.Harness = .{};
    try h.init(&.{
        "USE GRAPH g1; CREATE (:H6547 {k: 1})",
        "USE GRAPH g1; CREATE (:H6547 {k: 2})",
        "USE GRAPH g1; CREATE (:H6547 {k: 3})",
    });
    defer h.deinit();
    const leader = h.cl.leader;
    const term_before = leader.raft.currentTerm();

    // As after a restart: g1's resident indexes are built on first touch.
    try h.f.st.markPendingHydrationForTest(G);

    var reader: Reader = .{};
    const rt = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    while (!reader.locked.load(.acquire)) fx.sleepMs(1);

    var probe: Probe = .{ .raft = leader.raft };
    const pt = try std.Thread.spawn(.{}, Probe.run, .{&probe});

    const labels = [_][]const u8{"After6547"};
    const props = [_]cr.Prop{.{ .key = "k", .value = .{ .Int = 9 } }};
    const payload = try cr.serializeNodeCreate(testing.allocator, G, &labels, &props);
    defer testing.allocator.free(payload);
    const t0 = nowMs();
    const submitted = statement_proposals.submit(.create, G, payload, null);
    const submit_ms = nowMs() - t0;

    while (!reader.done.load(.acquire)) fx.sleepMs(5);
    rt.join();
    _ = try h.cl.settle();
    probe.stop.store(true, .release);
    pt.join();
    const term_after = leader.raft.currentTerm();

    std.debug.print("SONNY-6547 (4): submit {s} in {d} ms; the leader's inner_mutex was unavailable for up to {d} ms ({d} probes; election timeout {d} ms); term {d} -> {d}\n", .{
        if (submitted) |_| "ok" else |e| @errorName(e), submit_ms, probe.max_wait_ms, probe.samples, ELECTION_TIMEOUT_MS, term_before, term_after,
    });
    try submitted;
    try testing.expectEqual(@as(usize, 1), fx.countLabel(h.f.st, G, "After6547"));
    try testing.expect(probe.max_wait_ms < ELECTION_TIMEOUT_MS);
}
