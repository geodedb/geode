// SONNY-3246: a cluster leader's MATCH ... SET updates only the rows the
// session's MATCH can see, as a single node does. On a single node the MATCH
// reads through the RLS row filters, so a row a policy hides is never
// updated; the leader resolved its candidates on graph, tenant, labels and
// properties only and proposed the update of hidden rows to every node.
//
// Of the other two divergences the ticket names, one is pinned here: a SET
// clause is evaluated against the row as it stood before the clause on both
// (SONNY-3242). The other is NOT fixed: the leader keeps a row only when its
// WHERE is true (SONNY-3184's rule), while the single-node MATCH paths still
// take a non-zero integer as true (match_operations, planned_read_runtime,
// query_execution), so `MATCH (n) WHERE n.a SET ...` with an integer a
// writes on a single node and not on a leader.
//
// An in-process 3-node cluster (the SONNY-3348 fixture) whose nodes apply to
// the session's persisted store, with the expression policy of
// rls_session_harness (`:Doc` visible iff cls <> 'secret') for user bob, and
// the same statements on a single node for comparison. No mocks.
//
// CANARY: REQ=REQ-SONNY-3246-CLUSTER-SET-RLS; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3246_cluster_set_rls.zig; OWNER=distributed; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");
const c = @import("sonny3348_cluster_harness.zig");

const cluster_mod = geode.distributed.cluster;
const raft_apply = geode.distributed.raft_apply;
const graph_store = geode.graph_store;

fn seed(s: *h.Session) !void {
    try s.execAs(null, "CREATE (:Doc {s: 'leak', cls: 'secret', a: 1, b: 2})");
    try s.execAs(null, "CREATE (:Doc {s: 'pub', cls: 'public', a: 1, b: 2})");
    try s.restrict("Hidden");
}

/// The statements, and what each must leave on `pub` (the hidden row must
/// keep its properties).
const statements = [_][]const u8{
    "MATCH (n:Doc) SET n.touched = 1",
    "MATCH (n:Doc) WHERE n.a = 1 SET n.seen = 1",
    // SONNY-3242: evaluated against the row before the clause: a swap.
    "MATCH (n:Doc) SET n.a = n.b, n.b = n.a",
};

fn check(s: *h.Session, phase: []const u8) !usize {
    const aa = s.arena.allocator();
    var bad: usize = 0;
    const leak = try s.idOf("leak");
    const pub_id = try s.idOf("pub");
    const store = graph_store.getGlobalStore(testing.allocator);
    const Want = struct { id: u64, key: []const u8, want: ?i64 };
    for ([_]Want{
        .{ .id = pub_id, .key = "touched", .want = 1 },
        .{ .id = pub_id, .key = "seen", .want = 1 },
        .{ .id = pub_id, .key = "a", .want = 2 },
        .{ .id = pub_id, .key = "b", .want = 1 },
        .{ .id = leak, .key = "touched", .want = null },
        .{ .id = leak, .key = "seen", .want = null },
        .{ .id = leak, .key = "a", .want = 1 },
        .{ .id = leak, .key = "b", .want = 2 },
    }) |w| {
        const node = store.getNodePtr(w.id) orelse return error.NodeNotFound;
        const got: ?i64 = if (node.properties.get(w.key)) |pv| switch (pv) {
            .Int => |i| i,
            else => -1,
        } else null;
        if (got != w.want) {
            std.debug.print("[{s}] {s}.{s} = {?d}, want {?d}\n", .{ phase, if (w.id == leak) "leak (hidden)" else "pub", w.key, got, w.want });
            bad += 1;
        }
    }
    _ = aa;
    return bad;
}

test "SONNY-3246: a single node's MATCH ... SET under an RLS policy (the reference)" {
    var s = try h.Session.init(.expr_policy);
    defer s.deinit();
    try seed(&s);
    for (statements) |q| try s.execAs(null, q);
    try testing.expectEqual(@as(usize, 0), try check(&s, "single node"));
}

test "SONNY-3246: a cluster leader's MATCH ... SET under an RLS policy updates the same rows as a single node" {
    var s = try h.Session.init(.expr_policy);
    defer s.deinit();
    try seed(&s);

    raft_apply.setGlobalStore(graph_store.getGlobalStore(testing.allocator));
    defer raft_apply.resetGlobalStore();
    var cl: c.Cluster = undefined;
    try cl.init(testing.allocator);
    defer cl.deinit();
    const deadline = c.nowMs() + 10_000;
    while (cl.leader.raft.committedIndex() == 0) {
        if (c.nowMs() > deadline) return error.NoCommit;
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch {};
    }
    _ = try cl.settle();
    cluster_mod.setGlobalClusterCoordinator(cl.leader);
    defer cluster_mod.clearGlobalClusterCoordinator();

    const before = try cl.settle();
    for (statements) |q| try s.execAs(null, q);
    const after = try cl.settle();
    // The writes went through raft (the statements are not applied locally).
    try testing.expect(after > before);
    try testing.expectEqual(@as(usize, 0), try check(&s, "cluster leader"));
}
