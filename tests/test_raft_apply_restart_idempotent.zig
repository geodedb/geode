const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const cluster_replication = geode.distributed.cluster_replication;
const Prop = cluster_replication.Prop;

// CANARY: REQ=REQ-DIST-RAFT-RESTART-IDEMPOTENT; FEATURE="DistributedCluster"; ASPECT=RestartApplyIdempotency; STATUS=TESTED; TEST=test_raft_apply_restart_idempotent; OWNER=distributed; UPDATED=2026-06-09
//
// Regression tests for root cause #6 of
//   docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md
// (fix design: /tmp/raft-restart-idempotency-design.md).
//
// The defect: a clustered raft node that restarts loses its in-memory raft
// log + applied-index (InMemoryStorage) while its graph store (the state
// machine) is persisted on a PVC. The leader re-ships its committed log and
// the restarted node RE-APPLIES every committed entry. Because the GNC1
// replicated-create payload carries no node id,
// `cluster_replication.applyNodeCreatePayload` mints a FRESH
// `generateTimeBasedId()` on every apply — so re-applying the SAME committed
// create produces a DUPLICATE node (confirmed on real k8s: count=2, v=[1,1]).
//
// These tests apply the SAME committed payload twice to a single GraphStore,
// faithfully simulating a restarted node re-applying the same committed entry.
// On unfixed code this yields TWO nodes and the count==1 assertion fails (RED).
// After the idempotent-apply fix (id derived from the raft log index, persisted
// store as the dedup oracle) the second apply is a no-op and count stays 1.

/// Count live nodes with the given label in the given graph. Uses the public
/// maintained label-refcount accessor — the same oracle the persisted store
/// uses to dedup. (tenant=null reads the graph+label refcount directly.)
fn countLabel(store: *const GraphStore, graph: []const u8, label: []const u8) usize {
    return store.countNodesByLabel(graph, label, null);
}

test "REGRESSION #6: re-applying a committed replicated create does not duplicate the node (restart idempotency)" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    // Build ONE committed GNC1 create payload for (:M1 {v:1}) in graph "default".
    const labels = [_][]const u8{"M1"};
    const props = [_]Prop{.{ .key = "v", .value = .{ .Int = 1 } }};
    const payload = try cluster_replication.serializeNodeCreate(a, "default", &labels, &props);
    defer a.free(payload);

    // First apply: the node is created (normal committed-entry apply). The node
    // id is the committed Raft log index (2 here).
    _ = try cluster_replication.applyNodeCreatePayload(a, &store, payload, 2);
    try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "M1"));

    // Second apply of the SAME committed entry (same raft index 2) == a restarted
    // node replaying its log on top of the already-persisted store. Must remain
    // idempotent: the id already exists, so this is a no-op.
    _ = try cluster_replication.applyNodeCreatePayload(a, &store, payload, 2);

    // RED on unfixed code: count==2 here (the duplicate). Must be exactly 1.
    try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "M1"));

    // The single surviving node still carries the replicated property exactly once.
    var ids = try store.getNodesByLabels(a, "default", &labels, null);
    defer ids.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    const v = (try store.getNodePropertyOrError(ids.items[0], "v")) orelse return error.MissingProperty;
    try std.testing.expectEqual(@as(i64, 1), v.Int);
}

test "GUARD: two DIFFERENT committed creates yield two distinct nodes (no over-dedup)" {
    // Passes on current code AND must keep passing after the fix: applying two
    // SEPARATE committed creates must produce two nodes — the idempotency must
    // not collapse genuinely distinct committed entries.
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const labels = [_][]const u8{"M1"};
    const p0 = try cluster_replication.serializeNodeCreate(a, "default", &labels, &.{
        .{ .key = "v", .value = .{ .Int = 1 } },
    });
    defer a.free(p0);
    const p1 = try cluster_replication.serializeNodeCreate(a, "default", &labels, &.{
        .{ .key = "v", .value = .{ .Int = 2 } },
    });
    defer a.free(p1);

    // Two SEPARATE committed entries → two DIFFERENT raft indices (2 and 3).
    const id0 = try cluster_replication.applyNodeCreatePayload(a, &store, p0, 2);
    const id1 = try cluster_replication.applyNodeCreatePayload(a, &store, p1, 3);

    try std.testing.expect(id0 != id1);
    try std.testing.expectEqual(@as(usize, 2), countLabel(&store, "default", "M1"));
}

test "DETERMINISTIC ID: applying a create at raft index N yields a node whose id == N" {
    // The replicated node's id IS the committed Raft log index — globally unique
    // and identical on every node (Log Matching Property). This is what makes the
    // persisted store the dedup oracle across restart.
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const labels = [_][]const u8{"D1"};
    const payload = try cluster_replication.serializeNodeCreate(a, "default", &labels, &.{
        .{ .key = "v", .value = .{ .Int = 1 } },
    });
    defer a.free(payload);

    const n: u64 = 12345;
    const returned = try cluster_replication.applyNodeCreatePayload(a, &store, payload, n);
    try std.testing.expectEqual(n, returned);

    var ids = try store.getNodesByLabels(a, "default", &labels, null);
    defer ids.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    try std.testing.expectEqual(n, ids.items[0]);
}

test "PROPERTY IDEMPOTENCY: re-applying a create with {v:1} at the same raft index leaves one node with v == 1" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const labels = [_][]const u8{"P1"};
    const payload = try cluster_replication.serializeNodeCreate(a, "default", &labels, &.{
        .{ .key = "v", .value = .{ .Int = 1 } },
    });
    defer a.free(payload);

    // Apply the SAME committed entry (raft index 4) twice — simulating a restart
    // replay. The second apply must not duplicate the node, and the surviving
    // node must still carry exactly one copy of the replicated property v == 1.
    _ = try cluster_replication.applyNodeCreatePayload(a, &store, payload, 4);
    _ = try cluster_replication.applyNodeCreatePayload(a, &store, payload, 4);

    try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "P1"));

    var ids = try store.getNodesByLabels(a, "default", &labels, null);
    defer ids.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    const v = (try store.getNodePropertyOrError(ids.items[0], "v")) orelse return error.MissingProperty;
    try std.testing.expectEqual(@as(i64, 1), v.Int);
}
