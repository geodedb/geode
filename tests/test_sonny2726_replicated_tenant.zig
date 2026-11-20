// SONNY-2726: a replicated write is applied under the writing session's
// tenant. The raft apply thread has no request context, and the replicated
// create payloads carried no tenant, so every node and edge applied through
// raft (on the followers, and on the leader, whose statement writes only
// through the apply) was tagged with the default tenant; since SONNY-2693's
// strict edge rule a tenant's replicated edges, and its nodes, were hidden
// from it.
//
// 1. An in-process 3-node cluster through the real gRPC handler: a tenant
//    session's CREATEs of a node and of an edge between two of its nodes are
//    tagged with its tenant, its MATCH returns them, another tenant's does
//    not.
// 2. The apply on a store of its own (a follower): an entry in the tenant
//    envelope creates its nodes and edges under that tenant, a re-apply of
//    the same index (a restart replay) creates nothing and changes no tag,
//    and an entry without the envelope (already in a log) applies as the
//    default tenant.
//
// Not covered (not fixed): re-tagging replicated data written before this
// change (it needs a leader-driven re-tag replicated through raft).
//
// CANARY: REQ=REQ-SONNY-2726-REPLICATED-TENANT; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2726_replicated_tenant.zig; OWNER=distributed; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const c = @import("sonny3348_cluster_harness.zig");

const raft_apply = geode.distributed.raft_apply;
const raft_consensus = geode.distributed.raft_consensus;
const repl = geode.distributed.cluster_replication;
const GraphStore = geode.graph_store.GraphStore;

const T = "t2726";

/// Every node carrying `label`: how many, and how many are tagged `tenant`.
fn tagged(st: *GraphStore, label: []const u8, tenant: []const u8) struct { total: usize, with_tenant: usize } {
    const ids = st.getNodesByLabel("default", label) orelse return .{ .total = 0, .with_tenant = 0 };
    var n: usize = 0;
    for (ids) |id| {
        const node = st.getNodePtr(id) orelse continue;
        if (std.mem.eql(u8, node.tenant_id, tenant)) n += 1;
    }
    return .{ .total = ids.len, .with_tenant = n };
}

/// Every edge of `edge_type`: how many, and how many are tagged `tenant`.
fn taggedEdges(st: *GraphStore, edge_type: []const u8, tenant: []const u8) !struct { total: usize, with_tenant: usize } {
    const ids = try st.allEdgeIds(testing.allocator);
    defer testing.allocator.free(ids);
    var total: usize = 0;
    var n: usize = 0;
    for (ids) |id| {
        const e = (try st.getEdgePtrHydratedChecked(id)) orelse continue;
        if (!std.mem.eql(u8, e.label, edge_type)) continue;
        total += 1;
        if (std.mem.eql(u8, e.tenant_id, tenant)) n += 1;
    }
    return .{ .total = total, .with_tenant = n };
}

test "SONNY-2726: a tenant session's replicated node and edge creates carry its tenant, and its MATCH returns them" {
    var h: c.Harness = .{};
    try h.init(&.{});
    defer h.deinit();
    const ga = h.ga();
    const st_t = try h.f.sessions.createSession("s2726t", "", null, T, null, false, 0);
    const st_u = try h.f.sessions.createSession("s2726u", "", null, "u2726", null, false, 0);

    try c.expectRan(ga, st_t, "CREATE (:Doc2726 {k: 1})");
    try c.expectRan(ga, st_t, "CREATE (a:Doc2726 {k: 2})-[:R2726]->(b:Doc2726 {k: 3})");
    _ = try h.cl.settle();

    var bad: usize = 0;
    const nodes = tagged(h.f.st, "Doc2726", T);
    if (nodes.total != 3 or nodes.with_tenant != 3) {
        std.debug.print("replicated nodes: {d}, tagged {s}: {d} (want 3 and 3)\n", .{ nodes.total, T, nodes.with_tenant });
        bad += 1;
    }
    const edges = try taggedEdges(h.f.st, "R2726", T);
    if (edges.total != 1 or edges.with_tenant != 1) {
        std.debug.print("replicated edges: {d}, tagged {s}: {d} (want 1 and 1)\n", .{ edges.total, T, edges.with_tenant });
        bad += 1;
    }
    const seen_nodes = try c.rowsOf(ga, st_t, "MATCH (n:Doc2726) RETURN n.k");
    const seen_edges = try c.rowsOf(ga, st_t, "MATCH (:Doc2726)-[r:R2726]->(:Doc2726) RETURN type(r)");
    if (seen_nodes != 3 or seen_edges != 1) {
        std.debug.print("the writing tenant's MATCH: {d} nodes, {d} edges (want 3 and 1)\n", .{ seen_nodes, seen_edges });
        bad += 1;
    }
    const other = try c.rowsOf(ga, st_u, "MATCH (n:Doc2726) RETURN n.k");
    if (other != 0) {
        std.debug.print("another tenant's MATCH returned {d} of them (want 0)\n", .{other});
        bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-2726: a follower applies a tenant-enveloped entry under its tenant, idempotently; an entry without the envelope as the default tenant" {
    const a = testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const multi = try repl.serializeMultiCreate(a, "default", &.{
        .{ .labels = &.{"F2726"}, .props = &.{.{ .key = "k", .value = .{ .Int = 1 } }} },
        .{ .labels = &.{"F2726"}, .props = &.{.{ .key = "k", .value = .{ .Int = 2 } }} },
    }, &.{.{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "FR2726", .props = &.{} }});
    defer a.free(multi);
    const wrapped = try repl.wrapWithTenant(a, T, multi);
    defer a.free(wrapped);
    const split = try repl.splitTenant(wrapped);
    try testing.expectEqualStrings(T, split.tenant);
    try testing.expectEqualSlices(u8, multi, split.inner);

    const cmd = raft_consensus.Command{ .graph_mutation = .{ .graph = "default", .mutation_type = .create, .data = wrapped, .txn_id = null } };
    a.free(try raft_apply.applyCommand(a, &store, cmd, 7));
    var nodes = tagged(&store, "F2726", T);
    try testing.expectEqual(@as(usize, 2), nodes.total);
    try testing.expectEqual(@as(usize, 2), nodes.with_tenant);
    var edges = try taggedEdges(&store, "FR2726", T);
    try testing.expectEqual(@as(usize, 1), edges.total);
    try testing.expectEqual(@as(usize, 1), edges.with_tenant);

    // A restart replay of the same committed entry: nothing new, same tags.
    a.free(try raft_apply.applyCommand(a, &store, cmd, 7));
    nodes = tagged(&store, "F2726", T);
    try testing.expectEqual(@as(usize, 2), nodes.total);
    try testing.expectEqual(@as(usize, 2), nodes.with_tenant);
    edges = try taggedEdges(&store, "FR2726", T);
    try testing.expectEqual(@as(usize, 1), edges.total);

    // The apply thread's tenant is restored: an entry already in a log,
    // without the envelope, applies as the default tenant.
    const legacy = try repl.serializeNodeCreate(a, "default", &.{"L2726"}, &.{});
    defer a.free(legacy);
    a.free(try raft_apply.applyCommand(a, &store, .{ .graph_mutation = .{ .graph = "default", .mutation_type = .create, .data = legacy, .txn_id = null } }, 9));
    const plain = tagged(&store, "L2726", "default");
    try testing.expectEqual(@as(usize, 1), plain.total);
    try testing.expectEqual(@as(usize, 1), plain.with_tenant);

    // A malformed envelope is refused, never applied as the default tenant.
    try testing.expectError(error.CorruptPayload, repl.splitTenant("GTN1"));
    const nested = try repl.wrapWithTenant(a, T, wrapped);
    defer a.free(nested);
    try testing.expectError(error.CorruptPayload, raft_apply.applyCommand(a, &store, .{ .graph_mutation = .{ .graph = "default", .mutation_type = .create, .data = nested, .txn_id = null } }, 11));
}
