// SONNY-2463 follow-up (review m2): building a node leaked what had been
// built when it failed part way, at two levels.
//
// The storage adapter's `getAllNodeProperties` and `getAllEdgeProperties`
// build a map of copied keys and decoded values. Their errdefer freed only the
// map's table, so every key and value already put into it leaked when a later
// allocation failed; a value whose key copy failed, or a key and value whose
// put failed, leaked too. `getNodeLabels` leaked the copy of a label whose
// append failed.
//
// On top of those reads, the engine-direct node scan's `materializeNode` and
// `materializeNodeProjected` build a node that owns all of its memory (see
// "Node ownership" at `destroyNode`). Their errdefers freed only the property
// map's entry slice, the graph name, the labels and the struct, so every
// property key and value already put into the node leaked when a later step
// failed: an allocation failure while copying, decoding or putting the next
// property, or, in `materializeNodeProjected`, a `NodeNotFound` from a later
// key's read when the node is deleted mid-read. A key and value whose put
// itself failed leaked too.
//
// Each read, and each way of building a node, is driven under
// `std.testing.FailingAllocator`, making each of its allocations fail in turn,
// over a node and an edge with two strings, an integer and a list. Every run
// must either return the whole result, which the test checks and then frees,
// or fail having freed everything it allocated. The mid-read `NodeNotFound`
// leaves `materializeNodeProjected` through the same path as an allocation
// failure after a put, so the sweep covers it.
//
// CANARY: REQ=REQ-SONNY-2463-MATERIALIZE-OOM; FEATURE="EngineDirectNodeOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2463_materialize_oom.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;
const node_scan_stream = geode.node_scan_stream;
const StorageAdapter = graph_storage_adapter.StorageAdapter;

const graph = graph_store.DEFAULT_GRAPH_NAME;

fn adapterOrFail() !*StorageAdapter {
    return graph_store.getGlobalAdapter() orelse error.ExpectedPersistedAdapter;
}

/// The slot of the only node labelled `label`.
fn onlySlot(label: []const u8) !u64 {
    const slots = try (try adapterOrFail()).getNodesByLabel(graph, label, testing.allocator);
    defer testing.allocator.free(slots);
    try testing.expectEqual(@as(usize, 1), slots.len);
    return slots[0];
}

/// One `(:OA {s, t, i, l})-[:R {s, t, i, l}]->(:OB)` pair.
fn seedPair(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    var r = try h.run("CREATE (:OA {s: 's07', t: 't07', i: 7, l: ['l07', 'm07']})-[:R {s: 'e07', t: 'f07', i: 7, l: ['g07', 'h07']}]->(:OB {s: 'b07'})");
    r.deinit(aa);
}

/// Free a property map an adapter read returned: keys, values, table.
fn freeMap(allocator: std.mem.Allocator, map: anytype) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        graph_storage_adapter.freeOwnedStorageProperty(allocator, entry.value_ptr.*);
    }
    map.deinit();
}

/// The map holds s, t, i and l as seeded, with `s_value` for s.
fn checkMap(map: anytype, s_value: []const u8) !void {
    try testing.expectEqualStrings(s_value, map.get("s").?.string);
    try testing.expectEqual(@as(i64, 7), map.get("i").?.int);
    _ = map.get("t").?.string;
    _ = map.get("l").?.ext;
}

const Read = union(enum) {
    labels: u64,
    node_props: u64,
    edge_props: struct { from: u64, prop_head: u64 },
};

/// Run `read` once per allocation it makes, failing that allocation, then
/// once with none failing. Returns how many runs leaked (each is printed).
fn sweep(read: Read) !usize {
    const adapter = try adapterOrFail();
    var leaky_runs: usize = 0;
    var failed_runs: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 10_000) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        const ok = switch (read) {
            .labels => |slot| if (adapter.getNodeLabels(graph, slot, allocator)) |labels| blk: {
                defer {
                    for (labels) |label| allocator.free(label);
                    allocator.free(labels);
                }
                try testing.expectEqual(@as(usize, 1), labels.len);
                try testing.expectEqualStrings("OA", labels[0]);
                break :blk true;
            } else |_| false,
            .node_props => |slot| if (adapter.getAllNodeProperties(graph, slot, allocator)) |map_const| blk: {
                var map = map_const;
                defer freeMap(allocator, &map);
                try checkMap(&map, "s07");
                break :blk true;
            } else |_| false,
            .edge_props => |e| if (adapter.getAllEdgeProperties(graph, e.from, e.prop_head, allocator)) |map_const| blk: {
                var map = map_const;
                defer freeMap(allocator, &map);
                try checkMap(&map, "e07");
                break :blk true;
            } else |_| false,
        };
        if (!ok) failed_runs += 1;
        const leaked = failing.allocations - failing.deallocations;
        if (leaked != 0) {
            leaky_runs += 1;
            std.debug.print("{s}: failing allocation {d} leaked {d} allocations\n", .{ @tagName(read), fail_index, leaked });
        }
        if (!failing.has_induced_failure) {
            // The read must have been able to fail at all.
            try testing.expect(failed_runs > 0);
            return leaky_runs;
        }
    }
    return error.SweepDidNotEnd;
}

test "SONNY-2463: an adapter label read that fails part way frees what it built" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPair(&h);
    try testing.expectEqual(@as(usize, 0), try sweep(.{ .labels = try onlySlot("OA") }));
}

test "SONNY-2463: an adapter node-property read that fails part way frees what it built" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPair(&h);
    try testing.expectEqual(@as(usize, 0), try sweep(.{ .node_props = try onlySlot("OA") }));
}

test "SONNY-2463: an adapter edge-property read that fails part way frees what it built" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPair(&h);
    const from = try onlySlot("OA");
    const edges = try (try adapterOrFail()).getOutgoingEdges(graph, from, testing.allocator);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, 1), edges.len);
    try testing.expectEqual(@as(usize, 0), try sweep(.{ .edge_props = .{ .from = from, .prop_head = edges[0].prop_head } }));
}

/// The `:OA` node is whole: its label, graph name, s, t and l as seeded, and
/// i unless `keys` left it out.
fn checkNode(node: *const graph_store.Node, keys: ?[]const []const u8) !void {
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("OA", node.labels[0]);
    try testing.expectEqualStrings(graph, node.graph_name);
    try testing.expectEqualStrings("s07", node.properties.get("s").?.String);
    try testing.expectEqualStrings("t07", node.properties.get("t").?.String);
    const list = node.properties.get("l").?.ExtValue.List;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("l07", list[0].Str);
    try testing.expectEqualStrings("m07", list[1].Str);
    if (keys == null) {
        try testing.expectEqual(@as(i64, 7), node.properties.get("i").?.Int);
    } else {
        try testing.expect(node.properties.get("i") == null);
    }
}

/// Build the node at `slot` as the scan does, once per allocation that makes,
/// failing that allocation, then once with none failing. Returns how many
/// runs leaked (each is printed).
fn sweepNode(slot: u64, keys: ?[]const []const u8) !usize {
    const name = if (keys == null) "materializeNode" else "materializeNodeProjected";
    var leaky_runs: usize = 0;
    var failed_runs: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 10_000) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        if (node_scan_stream.materializeNodeForTest(allocator, graph, slot, keys)) |node| {
            try checkNode(node, keys);
            node_scan_stream.destroyNodeForTest(allocator, node);
        } else |_| {
            failed_runs += 1;
        }
        const leaked = failing.allocations - failing.deallocations;
        if (leaked != 0) {
            leaky_runs += 1;
            std.debug.print("{s}: failing allocation {d} leaked {d} allocations\n", .{ name, fail_index, leaked });
        }
        if (!failing.has_induced_failure) {
            // Every property is a step that can fail after earlier ones were
            // put into the node.
            try testing.expect(failed_runs > 8);
            return leaky_runs;
        }
    }
    return error.SweepDidNotEnd;
}

test "SONNY-2463: a node the scan fails to materialize part way is freed in full" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPair(&h);
    try testing.expectEqual(@as(usize, 0), try sweepNode(try onlySlot("OA"), null));
}

test "SONNY-2463: a node the scan fails to materialize from its needed keys part way is freed in full" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedPair(&h);
    // `zz` is not set on the node: its read finds nothing and is skipped.
    const keys = [_][]const u8{ "s", "t", "zz", "l" };
    try testing.expectEqual(@as(usize, 0), try sweepNode(try onlySlot("OA"), &keys));
}
