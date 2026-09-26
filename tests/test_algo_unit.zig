// Unit tests for graph algorithm helper functions in:
//   src/execution/centrality_algorithms.zig
//   src/execution/graph_algorithms.zig
//
// These functions are re-exported via execution.zig -> lib.zig -> geode module.
//
// SONNY-1318 / SONNY-2685: these helpers take a trailing scope (the session's
// graph, tenant scope and RLS policies). This harness has one graph, one
// tenant and no policy, so it passes a scope on "default" with no tenant scope
// (`unscoped`), which is exactly the behaviour these tests asserted before the
// parameter existed. The tenant-scoped behaviour is covered by
// tests/test_sonny1318_procedure_tenancy.zig, the RLS behaviour by
// tests/test_sonny2685_algo_rls.zig.
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const Value = geode.value_types.Value;
const Env = geode.value_types.Env;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn createTestStore() !graph_store.GraphStore {
    return graph_store.GraphStore.init(testing.allocator);
}

fn addTestNode(store: *graph_store.GraphStore, id: u64, labels: []const []const u8) !void {
    try store.createNodeWithIdNoSave(id, @constCast(labels), "default");
}

fn addTestEdge(store: *graph_store.GraphStore, edge_id: u64, from: u64, to: u64, label: []const u8) !void {
    try store.createEdgeWithIdNoSave(edge_id, from, to, label, "default");
}

/// The scope of a call on "default" with no tenant scope and no policy.
fn unscoped() !*execution.AlgoScope {
    return execution.AlgoScope.create(testing.allocator, "default", null);
}

// ===========================================================================
// centrality_algorithms.zig — safeU64ToValue
// ===========================================================================

test "safeU64ToValue: zero" {
    const v = execution.safeU64ToValue(0);
    try testing.expectEqual(@as(i64, 0), v.Int);
}

test "safeU64ToValue: normal positive value" {
    const v = execution.safeU64ToValue(42);
    try testing.expectEqual(@as(i64, 42), v.Int);
}

test "safeU64ToValue: maxInt(i64) boundary" {
    const max_i64: u64 = @intCast(std.math.maxInt(i64));
    const v = execution.safeU64ToValue(max_i64);
    try testing.expectEqual(std.math.maxInt(i64), v.Int);
}

test "safeU64ToValue: one above maxInt(i64) saturates" {
    const over: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    const v = execution.safeU64ToValue(over);
    try testing.expectEqual(std.math.maxInt(i64), v.Int);
}

test "safeU64ToValue: maxInt(u64) saturates" {
    const v = execution.safeU64ToValue(std.math.maxInt(u64));
    try testing.expectEqual(std.math.maxInt(i64), v.Int);
}

// ===========================================================================
// centrality_algorithms.zig — getNeighbors
// ===========================================================================

test "getNeighbors: isolated node returns empty slice" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"Person"});

    const scope = try unscoped();
    defer scope.destroy();
    const neighbors = try execution.getNeighbors(&store, 1, testing.allocator, scope);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 0), neighbors.len);
}

test "getNeighbors: outgoing edges" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestNode(&store, 3, &.{"C"});
    try addTestEdge(&store, 100, 1, 2, "KNOWS");
    try addTestEdge(&store, 101, 1, 3, "KNOWS");

    const scope = try unscoped();
    defer scope.destroy();
    const neighbors = try execution.getNeighbors(&store, 1, testing.allocator, scope);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 2), neighbors.len);
    var found2 = false;
    var found3 = false;
    for (neighbors) |n| {
        if (n == 2) found2 = true;
        if (n == 3) found3 = true;
    }
    try testing.expect(found2);
    try testing.expect(found3);
}

test "getNeighbors: incoming edges" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestEdge(&store, 100, 2, 1, "FOLLOWS");

    const scope = try unscoped();
    defer scope.destroy();
    const neighbors = try execution.getNeighbors(&store, 1, testing.allocator, scope);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 1), neighbors.len);
    try testing.expectEqual(@as(u64, 2), neighbors[0]);
}

test "getNeighbors: bidirectional edges" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestEdge(&store, 100, 1, 2, "KNOWS");
    try addTestEdge(&store, 101, 2, 1, "KNOWS");

    const scope = try unscoped();
    defer scope.destroy();
    const neighbors = try execution.getNeighbors(&store, 1, testing.allocator, scope);
    defer testing.allocator.free(neighbors);

    // outgoing to 2 AND incoming from 2
    try testing.expectEqual(@as(usize, 2), neighbors.len);
}

test "getNeighbors: nonexistent node returns empty" {
    var store = try createTestStore();
    defer store.deinit();

    const scope = try unscoped();
    defer scope.destroy();
    const neighbors = try execution.getNeighbors(&store, 999, testing.allocator, scope);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 0), neighbors.len);
}

// ===========================================================================
// centrality_algorithms.zig — precomputeAdjacency / deinitAdjacency
// ===========================================================================

test "precomputeAdjacency: triangle graph" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestNode(&store, 3, &.{"C"});
    try addTestEdge(&store, 10, 1, 2, "E");
    try addTestEdge(&store, 11, 2, 3, "E");
    try addTestEdge(&store, 12, 3, 1, "E");

    const node_list = [_]u64{ 1, 2, 3 };
    const scope = try unscoped();
    defer scope.destroy();
    var adj = try execution.precomputeAdjacency(&store, &node_list, testing.allocator, scope);
    defer execution.deinitAdjacency(&adj, testing.allocator);

    // Each node has 1 outgoing + 1 incoming = 2 neighbors
    try testing.expectEqual(@as(usize, 2), adj.get(1).?.len);
    try testing.expectEqual(@as(usize, 2), adj.get(2).?.len);
    try testing.expectEqual(@as(usize, 2), adj.get(3).?.len);
}

test "precomputeAdjacency: empty node list" {
    var store = try createTestStore();
    defer store.deinit();

    const node_list = [_]u64{};
    const scope = try unscoped();
    defer scope.destroy();
    var adj = try execution.precomputeAdjacency(&store, &node_list, testing.allocator, scope);
    defer execution.deinitAdjacency(&adj, testing.allocator);

    try testing.expectEqual(@as(u32, 0), adj.count());
}

test "deinitAdjacency: cleanup of allocated slices" {
    var adj = std.AutoHashMap(u64, []const u64).init(testing.allocator);

    const slice1 = try testing.allocator.alloc(u64, 2);
    slice1[0] = 10;
    slice1[1] = 20;
    try adj.put(1, slice1);

    const slice2 = try testing.allocator.alloc(u64, 1);
    slice2[0] = 30;
    try adj.put(2, slice2);

    execution.deinitAdjacency(&adj, testing.allocator);
    // Reaching here without leak detector failure means success
}

// ===========================================================================
// centrality_algorithms.zig — buildNeighborSets / deinitNeighborSets
// ===========================================================================

test "buildNeighborSets: O(1) adjacency check" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestNode(&store, 3, &.{"C"});
    try addTestEdge(&store, 10, 1, 2, "E");
    try addTestEdge(&store, 11, 1, 3, "E");

    const node_list = [_]u64{ 1, 2, 3 };
    const scope = try unscoped();
    defer scope.destroy();
    var sets = try execution.buildNeighborSets(&node_list, &store, testing.allocator, scope);
    defer execution.deinitNeighborSets(&sets);

    const set1 = sets.get(1).?;
    try testing.expect(set1.contains(2));
    try testing.expect(set1.contains(3));
    try testing.expect(!set1.contains(1)); // no self-loop

    const set2 = sets.get(2).?;
    try testing.expect(set2.contains(1));
    try testing.expect(!set2.contains(3));
}

test "deinitNeighborSets: cleanup of hash sets" {
    var sets = std.AutoHashMap(u64, execution.NeighborSet).init(testing.allocator);

    var set1 = execution.NeighborSet.init(testing.allocator);
    try set1.put(10, {});
    try set1.put(20, {});
    try sets.put(1, set1);

    var set2 = execution.NeighborSet.init(testing.allocator);
    try set2.put(30, {});
    try sets.put(2, set2);

    execution.deinitNeighborSets(&sets);
    // Reaching here without leak detector failure means success
}

// ===========================================================================
// Union-Find path compression (replicated from executeUnionFind internals)
// ===========================================================================

fn ufFind(p: *std.AutoHashMap(u64, u64), x: u64) ?u64 {
    if (p.get(x) == null) return null;
    var current = x;
    while (p.get(current)) |parent_id| {
        if (parent_id == current) break;
        current = parent_id;
    }
    const root = current;
    current = x;
    while (p.get(current)) |parent_id| {
        if (parent_id == current) break;
        p.put(current, root) catch {};
        current = parent_id;
    }
    return root;
}

test "union-find path compression" {
    var parent = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer parent.deinit();

    // Chain: 1->2->3->4 (4 is root)
    try parent.put(1, 2);
    try parent.put(2, 3);
    try parent.put(3, 4);
    try parent.put(4, 4);

    const root = ufFind(&parent, 1).?;
    try testing.expectEqual(@as(u64, 4), root);

    // After compression, all nodes point directly to root
    try testing.expectEqual(@as(u64, 4), parent.get(1).?);
    try testing.expectEqual(@as(u64, 4), parent.get(2).?);
    try testing.expectEqual(@as(u64, 4), parent.get(3).?);
}

test "union-find find on nonexistent node returns null" {
    var parent = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer parent.deinit();

    try testing.expectEqual(@as(?u64, null), ufFind(&parent, 42));
}

test "union-find find on root returns self" {
    var parent = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer parent.deinit();
    try parent.put(7, 7);

    try testing.expectEqual(@as(u64, 7), ufFind(&parent, 7).?);
}

// ===========================================================================
// graph_algorithms.zig — nodeHasAllLabels
// ===========================================================================

test "nodeHasAllLabels: empty required labels always matches" {
    const node_labels: []const []const u8 = &.{ "Person", "Employee" };
    const required: []const []const u8 = &.{};
    try testing.expect(execution.nodeHasAllLabels(node_labels, required));
}

test "nodeHasAllLabels: single label match" {
    const node_labels: []const []const u8 = &.{ "Person", "Employee" };
    const required: []const []const u8 = &.{"Person"};
    try testing.expect(execution.nodeHasAllLabels(node_labels, required));
}

test "nodeHasAllLabels: multiple labels all present" {
    const node_labels: []const []const u8 = &.{ "Person", "Employee", "Manager" };
    const required: []const []const u8 = &.{ "Employee", "Manager" };
    try testing.expect(execution.nodeHasAllLabels(node_labels, required));
}

test "nodeHasAllLabels: missing label returns false" {
    const node_labels: []const []const u8 = &.{"Person"};
    const required: []const []const u8 = &.{ "Person", "Admin" };
    try testing.expect(!execution.nodeHasAllLabels(node_labels, required));
}

test "nodeHasAllLabels: no node labels with required labels returns false" {
    const node_labels: []const []const u8 = &.{};
    const required: []const []const u8 = &.{"Person"};
    try testing.expect(!execution.nodeHasAllLabels(node_labels, required));
}

test "nodeHasAllLabels: both empty" {
    const node_labels: []const []const u8 = &.{};
    const required: []const []const u8 = &.{};
    try testing.expect(execution.nodeHasAllLabels(node_labels, required));
}

// ===========================================================================
// graph_algorithms.zig — propertyToValue
// ===========================================================================

test "propertyToValue: String" {
    const pv = graph_store.PropertyValue{ .String = "hello" };
    const v = execution.propertyToValue(pv);
    try testing.expectEqualStrings("hello", v.Str);
}

test "propertyToValue: Int" {
    const pv = graph_store.PropertyValue{ .Int = -42 };
    const v = execution.propertyToValue(pv);
    try testing.expectEqual(@as(i64, -42), v.Int);
}

test "propertyToValue: Bool true" {
    const pv = graph_store.PropertyValue{ .Bool = true };
    const v = execution.propertyToValue(pv);
    try testing.expect(v.Bool);
}

test "propertyToValue: Bool false" {
    const pv = graph_store.PropertyValue{ .Bool = false };
    const v = execution.propertyToValue(pv);
    try testing.expect(!v.Bool);
}

test "propertyToValue: Float" {
    const pv = graph_store.PropertyValue{ .Float = 3.14 };
    const v = execution.propertyToValue(pv);
    try testing.expectApproxEqAbs(@as(f64, 3.14), v.Double, 0.001);
}

test "propertyToValue: Null" {
    const pv = graph_store.PropertyValue{ .Null = {} };
    const v = execution.propertyToValue(pv);
    try testing.expect(v == .Null);
}

test "propertyToValue: Decimal" {
    const pv = graph_store.PropertyValue{ .Decimal = .{ .coeff = 12345, .scale = 2 } };
    const v = execution.propertyToValue(pv);
    try testing.expectEqual(@as(i128, 12345), v.Decimal.coeff);
    try testing.expectEqual(@as(u8, 2), v.Decimal.scale);
    try testing.expectEqual(@as(u8, 2), v.Decimal.orig_scale);
    try testing.expect(v.Decimal.orig_repr == null);
}

// ===========================================================================
// graph_algorithms.zig — findBoundNodeId
// ===========================================================================

test "findBoundNodeId: finds bound node" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 42, &.{"Person"});

    const node_ptr = store.nodes.getPtr(42).?;
    const names: []const []const u8 = &.{ "x", "y" };
    const values: []const Value = &.{
        Value{ .Int = 99 },
        Value{ .Node = node_ptr },
    };
    const env = Env{
        .names = names,
        .values = values,
        .allocator = testing.allocator,
    };

    const result = execution.findBoundNodeId("y", env);
    try testing.expectEqual(@as(?u64, 42), result);
}

test "findBoundNodeId: variable not found returns null" {
    const names: []const []const u8 = &.{"x"};
    const values: []const Value = &.{Value{ .Int = 1 }};
    const env = Env{
        .names = names,
        .values = values,
        .allocator = testing.allocator,
    };

    const result = execution.findBoundNodeId("z", env);
    try testing.expectEqual(@as(?u64, null), result);
}

test "findBoundNodeId: variable exists but is not a Node returns null" {
    const names: []const []const u8 = &.{"x"};
    const values: []const Value = &.{Value{ .Int = 42 }};
    const env = Env{
        .names = names,
        .values = values,
        .allocator = testing.allocator,
    };

    const result = execution.findBoundNodeId("x", env);
    try testing.expectEqual(@as(?u64, null), result);
}

// ===========================================================================
// graph_algorithms.zig — findBoundNode
// ===========================================================================

test "findBoundNode: finds node pointer" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 7, &.{"City"});

    const node_ptr = store.nodes.getPtr(7).?;
    const names: []const []const u8 = &.{"city"};
    const values: []const Value = &.{Value{ .Node = node_ptr }};
    const env = Env{
        .names = names,
        .values = values,
        .allocator = testing.allocator,
    };

    const result = execution.findBoundNode("city", env);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 7), result.?.id);
}

test "findBoundNode: not found returns null" {
    const names: []const []const u8 = &.{};
    const values: []const Value = &.{};
    const env = Env{
        .names = names,
        .values = values,
        .allocator = testing.allocator,
    };

    try testing.expect(execution.findBoundNode("missing", env) == null);
}

// ===========================================================================
// graph_algorithms.zig — findEdgeBetween
//
// SONNY-2687 (review): `findEdgeBetween` resolves the whole expression scope
// from the active session (its graph, tenant rule and RLS policies). This unit
// harness has no session, so every call reads the default graph with every
// tenant and no RLS: the legacy behaviour these cases were written against.
// The last case pins that an edge in another graph is not returned.
// ===========================================================================

test "findEdgeBetween: direct edge found" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestEdge(&store, 100, 1, 2, "KNOWS");

    const edge = try execution.findEdgeBetween(testing.allocator, &store, 1, 2);
    try testing.expect(edge != null);
    try testing.expectEqual(@as(u64, 100), edge.?.id);
    try testing.expectEqual(@as(u64, 1), edge.?.from_id);
    try testing.expectEqual(@as(u64, 2), edge.?.to_id);
}

test "findEdgeBetween: reverse direction found" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestEdge(&store, 100, 2, 1, "FOLLOWS");

    // Searching from 1 to 2: edge is 2->1, found via reverse check
    const edge = try execution.findEdgeBetween(testing.allocator, &store, 1, 2);
    try testing.expect(edge != null);
    try testing.expectEqual(@as(u64, 100), edge.?.id);
}

test "findEdgeBetween: no edge returns null" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});

    const edge = try execution.findEdgeBetween(testing.allocator, &store, 1, 2);
    try testing.expect(edge == null);
}

test "findEdgeBetween: multiple edges returns first match" {
    var store = try createTestStore();
    defer store.deinit();
    try addTestNode(&store, 1, &.{"A"});
    try addTestNode(&store, 2, &.{"B"});
    try addTestEdge(&store, 100, 1, 2, "KNOWS");
    try addTestEdge(&store, 101, 1, 2, "LIKES");

    const edge = try execution.findEdgeBetween(testing.allocator, &store, 1, 2);
    try testing.expect(edge != null);
    try testing.expect(edge.?.id == 100 or edge.?.id == 101);
}

test "findEdgeBetween: nonexistent nodes returns null" {
    var store = try createTestStore();
    defer store.deinit();

    const edge = try execution.findEdgeBetween(testing.allocator, &store, 999, 888);
    try testing.expect(edge == null);
}

test "findEdgeBetween: an edge in another graph is not returned" {
    var store = try createTestStore();
    defer store.deinit();
    try store.createNodeWithIdNoSave(1, &.{"A"}, "other");
    try store.createNodeWithIdNoSave(2, &.{"B"}, "other");
    try store.createEdgeWithIdNoSave(100, 1, 2, "KNOWS", "other");

    // The session's graph is the default one; the edge lives in "other".
    const edge = try execution.findEdgeBetween(testing.allocator, &store, 1, 2);
    try testing.expect(edge == null);
}
