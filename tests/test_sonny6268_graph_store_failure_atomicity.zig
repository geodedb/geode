// SONNY-6268 regression: the graph store's node and edge primitives are
// failure-atomic under allocation failure.
//
// An allocation that failed part way through a node create, a property SET
// or a node delete left a half-built node behind: a property-map slot whose
// key was never written (every later lookup in that sorted map, the node's
// delete and the store's teardown read the undefined key), a node in the
// node cache but in none of the indexes (or in some of them), duplicated
// strings nobody freed, a merge-index entry missing for a value the node
// holds (MERGE then trusts the miss), and a `deleteNode` that gave up half
// way and reported nothing.
//
// The sweep: for each primitive, fail allocation k (k = 0, 1, ...) until the
// primitive succeeds, on a fresh store each time, with
// `std.testing.FailingAllocator` over `std.testing.allocator` as the store's
// allocator. The failing allocator is sticky (every allocation from the k-th
// on fails), so a rollback that itself allocates is caught too. After each
// injected failure:
//   * the primitive returned an error (or, for the void primitives, either
//     did nothing and recorded the failure for the statement, or did all of
//     its work);
//   * the store reads back exactly as it did before (resident and per-graph
//     node counts, label postings, label/property/edge-type introspection,
//     merge-index lookups, the target node's labels and properties,
//     adjacency, index key counts);
//   * the same primitive then succeeds and its effect is visible;
//   * teardown neither crashes nor leaks (allocated bytes == freed bytes).
// Run on an in-memory store and on a store with a storage adapter (data
// directory), whose write-through adds failure points of its own. A last
// sweep pins the node cache's ownership rule on its own: a bounded-cache put
// that evicts and fails changed nothing and leaves the value the caller's.
//
// Real GraphStore, real storage adapter; no mocks.
//
// CANARY: REQ=REQ-SONNY-6268-FAILURE-ATOMICITY; FEATURE="GraphStoreFailureAtomicity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6268_graph_store_failure_atomicity.zig; OWNER=storage; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const eval = geode.eval;

const T = "default";
const MAX_K: usize = 400;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Mode = enum { memory, persisted };

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// The storage adapter of a persisted run (its own allocator: the sweep
/// fails the store's allocations, and the adapter's own failure handling is
/// the adapter's suite's concern). One per test; each sweep iteration writes
/// a graph of its own and drops it at the end, so no iteration hydrates
/// another's nodes.
const Env = struct {
    tmp: ?std.testing.TmpDir = null,
    data_dir: ?[]u8 = null,

    fn open(mode: Mode) !Env {
        if (mode == .memory) return .{};
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
        errdefer testing.allocator.free(dir);
        // No per-commit fsync: the sweep opens a store per iteration, and
        // what it checks is the store's memory, not the WAL's durability.
        _ = setenv("GEODE_WAL_SYNC", "deferred", 1);
        defer _ = unsetenv("GEODE_WAL_SYNC");
        _ = try graph_store.initGlobalAdapter(testing.allocator, dir);
        return .{ .tmp = tmp, .data_dir = dir };
    }

    fn close(self: *Env) void {
        if (self.data_dir) |d| {
            graph_store.deinitGlobalAdapter();
            testing.allocator.free(d);
        }
        if (self.tmp) |*t| t.cleanup();
    }
};

/// Ids a scenario's seed made, and the iteration's graph.
const Ids = struct {
    graph: []const u8,
    a: u64 = 0,
    b: u64 = 0,
    e: u64 = 0,
    made: u64 = 0,
};

fn writeValue(out: *std.ArrayList(u8), v: PropertyValue) !void {
    switch (v) {
        .String => |s| try out.print(testing.allocator, "'{s}'", .{s}),
        .Int => |i| try out.print(testing.allocator, "{d}", .{i}),
        .Float => |f| try out.print(testing.allocator, "{d}", .{f}),
        .Bool => |b| try out.print(testing.allocator, "{}", .{b}),
        .Null => try out.appendSlice(testing.allocator, "null"),
        else => try out.appendSlice(testing.allocator, "<other>"),
    }
}

fn writeSortedList(out: *std.ArrayList(u8), name: []const u8, items: [][]const u8) !void {
    defer {
        for (items) |s| testing.allocator.free(s);
        testing.allocator.free(items);
    }
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    try out.print(testing.allocator, "{s}=[", .{name});
    for (items) |s| try out.print(testing.allocator, "{s},", .{s});
    try out.appendSlice(testing.allocator, "]\n");
}

fn writeNode(out: *std.ArrayList(u8), store: *GraphStore, graph: []const u8, name: []const u8, id: u64) !void {
    if (id == 0) return;
    const node = store.nodes.get(id) orelse {
        try out.print(testing.allocator, "node {s}: absent\n", .{name});
        return;
    };
    try out.print(testing.allocator, "node {s}: in_graph={} tenant={s} labels=", .{ name, std.mem.eql(u8, node.graph_name, graph), node.tenant_id });
    for (node.labels) |l| try out.print(testing.allocator, "{s},", .{l});
    try out.appendSlice(testing.allocator, " props=");
    var it = node.properties.iterator();
    while (it.next()) |p| {
        try out.print(testing.allocator, "{s}:", .{p.key_ptr.*});
        try writeValue(out, p.value_ptr.*);
        try out.appendSlice(testing.allocator, ",");
    }
    const out_n = if (store.getOutgoingEdgeIds(id)) |s| s.len else 0;
    const in_n = if (store.getIncomingEdgeIds(id)) |s| s.len else 0;
    try out.print(testing.allocator, " out={d} in={d}\n", .{ out_n, in_n });
}

fn writeMerge(out: *std.ArrayList(u8), store: *GraphStore, ids: Ids, label: []const u8, key: []const u8, v: PropertyValue) !void {
    var found: u64 = 0;
    const r = store.lookupMergeCandidate(ids.graph, label, key, v, &found);
    const who: []const u8 = if (r != .found) "-" else if (found == ids.a) "a" else if (found == ids.b) "b" else if (found == ids.made) "made" else "?";
    try out.print(testing.allocator, "merge {s}.{s}=", .{ label, key });
    try writeValue(out, v);
    try out.print(testing.allocator, " -> {s} {s}\n", .{ @tagName(r), who });
}

/// Everything a reader can see of the store, as text (ids by role, so two
/// runs with different time-based ids compare).
fn render(store: *GraphStore, ids: Ids) ![]u8 {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "resident={d} in_graph={d} edges={d} label_index={d} graph_index={d} merge={d}\n", .{
        store.nodes.count(),
        store.nodesInGraphCount(ids.graph),
        store.edges.count(),
        store.label_index.count(),
        store.nodes_by_graph.count(),
        store.merge_prop_index.count(),
    });
    for ([_][]const u8{ "A", "B", "C" }) |label| {
        const n = if (store.getNodesByLabel(ids.graph, label)) |s| s.len else 0;
        try out.print(a, "label {s}: {d}\n", .{ label, n });
    }
    try writeSortedList(&out, "labels", try store.listNodeLabels(a, null));
    try writeSortedList(&out, "props(A)", try store.listPropertiesForLabel(a, null, "A"));
    try writeSortedList(&out, "props(C)", try store.listPropertiesForLabel(a, null, "C"));
    try writeSortedList(&out, "edge_types", try store.listEdgeTypes(a, null));
    const by_type = store.getEdgesByType(a, "R", null, ids.graph);
    defer a.free(by_type);
    try out.print(a, "edges R: {d}\n", .{by_type.len});
    try writeNode(&out, store, ids.graph, "a", ids.a);
    try writeNode(&out, store, ids.graph, "b", ids.b);
    try writeNode(&out, store, ids.graph, "made", ids.made);
    if (ids.e != 0) {
        if (store.edges.get(ids.e)) |e| {
            try out.print(a, "edge e: {s} props=", .{e.label});
            var it = e.properties.iterator();
            while (it.next()) |p| {
                try out.print(a, "{s}:", .{p.key_ptr.*});
                try writeValue(&out, p.value_ptr.*);
                try out.appendSlice(a, ",");
            }
            try out.appendSlice(a, "\n");
        } else try out.appendSlice(a, "edge e: absent\n");
    }
    try writeMerge(&out, store, ids, "A", "k", .{ .Int = 1 });
    try writeMerge(&out, store, ids, "A", "k", .{ .Int = 2 });
    try writeMerge(&out, store, ids, "A", "name", .{ .String = "x" });
    try writeMerge(&out, store, ids, "C", "k", .{ .Int = 1 });
    return out.toOwnedSlice(a);
}

/// A primitive under the sweep: `seed` builds the state (no failures),
/// `run` is the primitive, `void_op` marks primitives that return nothing
/// (their failure must be recorded for the statement instead).
const Scenario = struct {
    name: []const u8,
    seed: *const fn (store: *GraphStore, graph: []const u8) anyerror!Ids,
    run: *const fn (store: *GraphStore, ids: *Ids) anyerror!void,
    void_op: bool = false,
};

fn seedTwoNodes(store: *GraphStore, graph: []const u8) !Ids {
    var ids: Ids = .{ .graph = graph };
    const G = graph;
    ids.a = try store.createNodeWithGraphAndTenant(&.{ "A", "B" }, G, T);
    try store.setNodeProperty(ids.a, "k", .{ .Int = 1 });
    try store.setNodeProperty(ids.a, "name", .{ .String = "x" });
    ids.b = try store.createNodeWithGraphAndTenant(&.{"A"}, G, T);
    try store.setNodeProperty(ids.b, "k", .{ .Int = 5 });
    ids.e = try store.createEdgeWithGraphAndTenant(ids.a, ids.b, "R", G, T);
    try store.setEdgeProperty(ids.e, "w", .{ .Int = 7 });
    return ids;
}

fn seedEmpty(store: *GraphStore, graph: []const u8) !Ids {
    _ = store;
    return .{ .graph = graph };
}

fn runCreateNode(store: *GraphStore, ids: *Ids) !void {
    ids.made = try store.createNodeWithGraphAndTenant(&.{ "C", "A" }, ids.graph, T);
}

fn runSetNewKey(store: *GraphStore, ids: *Ids) !void {
    try store.setNodeProperty(ids.b, "fresh_key", .{ .String = "a fresh value" });
}

fn runSetExistingKey(store: *GraphStore, ids: *Ids) !void {
    try store.setNodeProperty(ids.a, "k", .{ .Int = 2 });
}

fn runRemoveProperty(store: *GraphStore, ids: *Ids) !void {
    store.removeNodeProperty(ids.a, "name");
}

fn runAddLabel(store: *GraphStore, ids: *Ids) !void {
    try store.addNodeLabel(ids.a, "C");
}

fn runRemoveLabel(store: *GraphStore, ids: *Ids) !void {
    try store.removeNodeLabel(ids.a, "B");
}

fn runDeleteNode(store: *GraphStore, ids: *Ids) !void {
    store.deleteNode(ids.a);
}

fn runCreateEdge(store: *GraphStore, ids: *Ids) !void {
    _ = try store.createEdgeWithGraphAndTenant(ids.b, ids.a, "R", ids.graph, T);
}

fn runSetEdgeProperty(store: *GraphStore, ids: *Ids) !void {
    try store.setEdgeProperty(ids.e, "fresh", .{ .String = "edge value" });
}

fn runDeleteEdge(store: *GraphStore, ids: *Ids) !void {
    store.deleteEdge(ids.e);
}

/// Sweep `sc` on `mode`: fail allocation k for k = 0.. until the primitive
/// completes without an induced failure.
var graph_seq: usize = 0;

fn sweep(mode: Mode, sc: Scenario) !void {
    // The state after each failed-then-retried (or swallowed-failure) run,
    // compared at the end with the clean run's.
    var results: std.ArrayList([]u8) = .empty;
    defer {
        for (results.items) |r| testing.allocator.free(r);
        results.deinit(testing.allocator);
    }
    // One graph per sweep. A persisted iteration deletes what it left in
    // the engine at its end (`emptyEngineGraph`), so the next iteration's
    // fresh store hydrates an empty graph: an orphan a failed primitive left
    // in the engine shows up in the next iteration's "before".
    var name_buf: [32]u8 = undefined;
    graph_seq += 1;
    const graph = try std.fmt.bufPrint(&name_buf, "g6268_{d}", .{graph_seq});
    defer if (mode == .persisted) {
        graph_store.getGlobalAdapter().?.dropGraph(graph) catch {};
    };

    var k: usize = 0;
    while (k < MAX_K) : (k += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var store = try GraphStore.init(fa.allocator());
        var store_live = true;
        defer if (store_live) store.deinit();

        var ids = try sc.seed(&store, graph);
        const before = try render(&store, ids);
        defer testing.allocator.free(before);
        _ = eval.takeDeferredLimitError(true);

        fa.fail_index = fa.alloc_index + k;
        const result = sc.run(&store, &ids);
        const induced = fa.has_induced_failure;
        fa.fail_index = std.math.maxInt(usize);
        const recorded = eval.takeDeferredLimitError(true);

        if (!induced) {
            // Ran clean: the sweep is done. The primitive must have succeeded.
            result catch |err| {
                std.debug.print("[{s} {s}] k={d}: failed with no injected failure: {s}\n", .{ sc.name, @tagName(mode), k, @errorName(err) });
                return err;
            };
            const clean = try render(&store, ids);
            defer testing.allocator.free(clean);
            for (results.items, 0..) |got, i| {
                if (!std.mem.eql(u8, clean, got)) {
                    std.debug.print("[{s} {s}] failure #{d}: the state after it (and the retry) differs from a clean run\n--- clean\n{s}--- got\n{s}", .{ sc.name, @tagName(mode), i, clean, got });
                    return error.StateDiffersFromCleanRun;
                }
            }
            if (mode == .persisted) try emptyEngineGraph(&store);
            store.deinit();
            store_live = false;
            try expectNoLeak(&fa, sc, mode, k);
            return;
        }

        const after = try render(&store, ids);
        defer testing.allocator.free(after);

        var rolled_back = false;
        if (result) |_| {
            if (sc.void_op and recorded != null) {
                rolled_back = true;
            }
        } else |_| {
            rolled_back = true;
        }

        if (rolled_back) {
            if (!std.mem.eql(u8, before, after)) {
                std.debug.print("[{s} {s}] k={d}: the failed primitive changed the store\n--- before\n{s}--- after\n{s}", .{ sc.name, @tagName(mode), k, before, after });
                return error.StoreChangedByFailedPrimitive;
            }
            // The same primitive now succeeds.
            sc.run(&store, &ids) catch |err| {
                std.debug.print("[{s} {s}] k={d}: retry after the failure failed: {s}\n", .{ sc.name, @tagName(mode), k, @errorName(err) });
                return err;
            };
            if (sc.void_op and eval.takeDeferredLimitError(true) != null) {
                std.debug.print("[{s} {s}] k={d}: retry recorded a failure\n", .{ sc.name, @tagName(mode), k });
                return error.RetryFailed;
            }
        } else {
            // Reported success despite a failed allocation: then it must have
            // done all of its work, exactly as a clean run does.
            if (std.mem.eql(u8, before, after)) {
                std.debug.print("[{s} {s}] k={d}: the primitive did nothing and reported nothing (silent failure)\n{s}", .{ sc.name, @tagName(mode), k, after });
                return error.SilentFailure;
            }
        }
        try results.append(testing.allocator, try render(&store, ids));

        if (mode == .persisted) try emptyEngineGraph(&store);
        store.deinit();
        store_live = false;
        try expectNoLeak(&fa, sc, mode, k);
    }
    return error.SweepDidNotConverge;
}

/// Delete every node (and so every edge) of the store, through the store,
/// so the engine's graph is empty for the next iteration.
fn emptyEngineGraph(store: *GraphStore) !void {
    const all = try store.getAllNodes(testing.allocator);
    defer testing.allocator.free(all);
    for (all) |id| try store.deleteNodeChecked(id);
}

fn expectNoLeak(fa: *std.testing.FailingAllocator, sc: Scenario, mode: Mode, k: usize) !void {
    if (fa.allocated_bytes != fa.freed_bytes) {
        std.debug.print("[{s} {s}] k={d}: leaked {d} bytes ({d} allocations, {d} frees)\n", .{
            sc.name, @tagName(mode), k, @as(i64, @intCast(fa.allocated_bytes)) - @as(i64, @intCast(fa.freed_bytes)), fa.allocations, fa.deallocations,
        });
        return error.Leak;
    }
}

const scenarios = [_]Scenario{
    .{ .name = "createNode", .seed = seedTwoNodes, .run = runCreateNode },
    .{ .name = "setNodeProperty(new key)", .seed = seedTwoNodes, .run = runSetNewKey },
    .{ .name = "setNodeProperty(existing key)", .seed = seedTwoNodes, .run = runSetExistingKey },
    .{ .name = "removeNodeProperty", .seed = seedTwoNodes, .run = runRemoveProperty, .void_op = true },
    .{ .name = "deleteNode", .seed = seedTwoNodes, .run = runDeleteNode, .void_op = true },
    .{ .name = "addNodeLabel", .seed = seedTwoNodes, .run = runAddLabel },
    .{ .name = "removeNodeLabel", .seed = seedTwoNodes, .run = runRemoveLabel },
    .{ .name = "createEdge", .seed = seedTwoNodes, .run = runCreateEdge },
    .{ .name = "setEdgeProperty", .seed = seedTwoNodes, .run = runSetEdgeProperty },
    .{ .name = "deleteEdge", .seed = seedTwoNodes, .run = runDeleteEdge, .void_op = true },
};

test "SONNY-6268: node primitives are failure-atomic (in memory)" {
    for (scenarios[0..5]) |sc| try sweep(.memory, sc);
}

test "SONNY-6268: label primitives are failure-atomic (in memory)" {
    for (scenarios[5..7]) |sc| try sweep(.memory, sc);
}

test "SONNY-6268: edge primitives are failure-atomic (in memory)" {
    for (scenarios[7..10]) |sc| try sweep(.memory, sc);
}

test "SONNY-6268: node, label and edge primitives are failure-atomic (storage adapter)" {
    var env = try Env.open(.persisted);
    defer env.close();
    for (scenarios) |sc| try sweep(.persisted, sc);
}

test "SONNY-6268: a node created into an empty store is failure-atomic" {
    try sweep(.memory, .{ .name = "createNode(empty)", .seed = seedEmpty, .run = runCreateNode });
}

fn noHydrate(_: *anyopaque, _: std.mem.Allocator, _: u64) anyerror!?graph_store.Node {
    return null;
}

fn makeNode(allocator: std.mem.Allocator, id: u64) !graph_store.Node {
    const labels = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(labels);
    labels[0] = try allocator.dupe(u8, "L");
    errdefer allocator.free(labels[0]);
    const graph = try allocator.dupe(u8, "g");
    errdefer allocator.free(graph);
    return .{
        .id = id,
        .labels = labels,
        .properties = graph_store.CompactPropertyMap.init(allocator),
        .graph_name = graph,
        .tenant_id = try allocator.dupe(u8, "t"),
    };
}

// The node cache's ownership rule (`BoundedNodeCache.put`): a failed put
// changed nothing and the value is still the caller's; evictions only
// retire. Before, a failed FIFO append freed the value inside `put` (the
// caller's error path freed it again), and a failed eviction append left
// the new entry inserted behind an error and the victim neither resident,
// retired nor freed.
/// A key that shares key 1's cache shard: a put of it into a cache holding
/// key 1, with one resident entry per shard, evicts key 1.
fn keySharingShardWithOne() !u64 {
    var dummy: u8 = 0;
    var candidate: u64 = 2;
    while (candidate < 10_000) : (candidate += 1) {
        var probe = try graph_store.NodeCache.init(testing.allocator, .{
            .cap = 16,
            .free_fn = graph_store.freeNodeValue,
            .hydrate_fn = noHydrate,
            .hydrate_ctx = &dummy,
        });
        defer probe.deinit();
        try probe.put(1, try makeNode(testing.allocator, 1));
        try probe.put(candidate, try makeNode(testing.allocator, candidate));
        if (probe.evictions_total == 1) return candidate;
    }
    return error.NoSharedShardKey;
}

test "SONNY-6268: a bounded node cache put that triggers evictions is all-or-nothing" {
    // The put evicts key 1 into an empty retire list, so it must allocate
    // the list (and its FIFO slot, and maybe the map slot) — the failure
    // points the sweep hits.
    const other = try keySharingShardWithOne();
    var k: usize = 0;
    while (k < MAX_K) : (k += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        var dummy: u8 = 0;
        var cache = try graph_store.NodeCache.init(a, .{
            .cap = 16, // one resident entry per shard
            .free_fn = graph_store.freeNodeValue,
            .hydrate_fn = noHydrate,
            .hydrate_ctx = &dummy,
        });
        try cache.put(1, try makeNode(a, 1));
        const resident = cache.residentCount();
        const retired = cache.retiredCount();
        const evictions = cache.evictions_total;

        var value = try makeNode(a, other);
        fa.fail_index = fa.alloc_index + k;
        const result = cache.put(other, value);
        const induced = fa.has_induced_failure;
        fa.fail_index = std.math.maxInt(usize);

        if (result) |_| {
            // Done in full: the new entry in, key 1 retired (not freed).
            try testing.expect(cache.contains(other));
            try testing.expect(!cache.contains(1));
            try testing.expectEqual(retired + 1, cache.retiredCount());
            try testing.expectEqual(evictions + 1, cache.evictions_total);
            if (!induced) {
                cache.deinit();
                try expectNoLeak(&fa, .{ .name = "NodeCache.put", .seed = seedEmpty, .run = runCreateNode }, .memory, k);
                return;
            }
        } else |_| {
            // Nothing changed, and the value is still ours.
            try testing.expect(!cache.contains(other));
            try testing.expect(cache.contains(1));
            try testing.expectEqual(resident, cache.residentCount());
            try testing.expectEqual(retired, cache.retiredCount());
            try testing.expectEqual(evictions, cache.evictions_total);
            graph_store.freeNodeValue(a, &value);
        }
        cache.deinit();
        try expectNoLeak(&fa, .{ .name = "NodeCache.put", .seed = seedEmpty, .run = runCreateNode }, .memory, k);
    }
    return error.SweepDidNotConverge;
}
