// CANARY: REQ=REQ-GAP-0512-GRAPH-ISOLATION; FEATURE="GraphIsolationEdgeIteration"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_graph_isolation_edge_iteration.zig:1; OWNER=engine; UPDATED=2026-04-11
//
// Regression tests for GAP-0512: "getAllNodes() returns cross-graph
// data — graph isolation not enforced in edge iteration".
//
// The MATCH path at `match_operations.zig:1631` calls
// `store.getEdgesByType(allocator, rel_type, filter_tenant)` to enumerate
// all edges of a given type when no left-node labels are present. Before
// this fix, `getEdgesByType` accepted no graph filter — it walked
// `self.graphs.keyIterator()` and appended every graph's posting list,
// returning a union across graphs. Callers then had to apply a per-edge
// graph check after the fact. Any caller that forgot that check (e.g.
// admin tooling, algorithms, reports) would silently leak cross-graph
// edges into its result set.
//
// These tests exercise the fix at the storage layer:
//
//   1. Two graphs, same edge type, graph-scoped query returns only the
//      requested graph's edges.
//   2. Two graphs, same edge type, unscoped (null graph) query returns
//      the union — this is the existing contract for admin / diagnostic
//      callers and must stay the same.
//   3. A graph-scoped query on a non-existent graph returns an empty
//      slice, not an error or leak.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

test "GAP-0512: getEdgesByType(graph) returns only that graph's edges" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Two isolated graphs with identical edge types.
    try store.createGraph("alpha");
    try store.createGraph("beta");

    const alpha_labels = [_][]const u8{"Node"};
    const beta_labels = [_][]const u8{"Node"};

    const a1 = try store.createNodeWithGraph(&alpha_labels, "alpha");
    const a2 = try store.createNodeWithGraph(&alpha_labels, "alpha");
    const b1 = try store.createNodeWithGraph(&beta_labels, "beta");
    const b2 = try store.createNodeWithGraph(&beta_labels, "beta");

    _ = try store.createEdgeWithGraph(a1, a2, "KNOWS", "alpha");
    _ = try store.createEdgeWithGraph(a1, a2, "KNOWS", "alpha");
    _ = try store.createEdgeWithGraph(b1, b2, "KNOWS", "beta");

    // Graph-scoped query for "alpha" must return exactly 2 edges.
    const alpha_edges = try store.getEdgesByType(allocator, "KNOWS", null, "alpha");
    defer if (alpha_edges.len > 0) allocator.free(alpha_edges);

    if (alpha_edges.len != 2) {
        std.debug.print(
            "GAP-0512 regression: expected 2 alpha edges, got {d} — graph filter leaking\n",
            .{alpha_edges.len},
        );
        return error.GraphIsolationLeaked;
    }

    // Every returned edge must actually belong to "alpha".
    for (alpha_edges) |eid| {
        const edge = store.edges.get(eid) orelse return error.EdgeNotFound;
        if (!std.mem.eql(u8, edge.graph_name, "alpha")) {
            std.debug.print(
                "GAP-0512 regression: edge {d} returned by alpha query belongs to graph '{s}'\n",
                .{ eid, edge.graph_name },
            );
            return error.GraphIsolationLeaked;
        }
    }

    // Graph-scoped query for "beta" must return exactly 1 edge.
    const beta_edges = try store.getEdgesByType(allocator, "KNOWS", null, "beta");
    defer if (beta_edges.len > 0) allocator.free(beta_edges);
    try testing.expectEqual(@as(usize, 1), beta_edges.len);
}

test "GAP-0512: getEdgesByType(null graph) returns union (admin path)" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g1");
    try store.createGraph("g2");

    const labels = [_][]const u8{"N"};
    const n1 = try store.createNodeWithGraph(&labels, "g1");
    const n2 = try store.createNodeWithGraph(&labels, "g1");
    const m1 = try store.createNodeWithGraph(&labels, "g2");
    const m2 = try store.createNodeWithGraph(&labels, "g2");

    _ = try store.createEdgeWithGraph(n1, n2, "REL", "g1");
    _ = try store.createEdgeWithGraph(m1, m2, "REL", "g2");

    // Unscoped (null) query is the admin/diagnostic path — must keep
    // returning edges from every graph. This is NOT a leak when the
    // caller explicitly asked for cross-graph data.
    const all_edges = try store.getEdgesByType(allocator, "REL", null, null);
    defer if (all_edges.len > 0) allocator.free(all_edges);

    try testing.expectEqual(@as(usize, 2), all_edges.len);
}

test "GAP-0512: getEdgesByType for non-existent graph returns empty" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("real");
    const labels = [_][]const u8{"N"};
    const a = try store.createNodeWithGraph(&labels, "real");
    const b = try store.createNodeWithGraph(&labels, "real");
    _ = try store.createEdgeWithGraph(a, b, "LINK", "real");

    const nothing = try store.getEdgesByType(allocator, "LINK", null, "ghost_graph");
    defer if (nothing.len > 0) allocator.free(nothing);
    try testing.expectEqual(@as(usize, 0), nothing.len);
}
