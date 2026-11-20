// SONNY-6540 item 3 (SONNY-6525 A.7): the lazy adjacency hydrate leaks an
// edge slice when an allocation fails.
//
// `GraphStore.hydrateAdjFromEngine` (the adjacency caches' hydrate-on-miss
// hook, run on the query path) and `loadOneGraphFromAdapterFull` read a
// node's edges through `StorageAdapter.iterateOutgoingEdges` /
// `iterateIncomingEdges`, the type-erased `GraphStorage.expandOut` /
// `expandIn`. graph_storage (0.4.14 and 0.4.15) builds the engine's edge
// slice and then boxes it in an iterator state (`interface.zig`
// `sliceToEdgeIterator`); when that box cannot be allocated the slice is
// never freed. `getOutgoingEdges` / `getIncomingEdges` (SONNY-6498) return
// the engine's slice directly.
//
// The hydrate runs here under every allocation-failure point in turn
// (`std.testing.FailingAllocator`); `std.testing.allocator` fails the test
// on any leak.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], tmp_sub_path });
}

fn sweep(adapter: *geode.graph_storage_adapter.StorageAdapter, slot: u64, dir: graph_store.GraphStore.AdjDir, want: usize) !void {
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var adj = graph_store.GraphStore.hydrateAdjFromEngine(adapter, a, "default", slot, dir) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer if (adj) |*v| graph_store.freeAdjListValue(a, v);
        const got = adj orelse return error.NodeNotHydrated;
        try testing.expectEqual(want, got.list.items.len);
        return;
    }
    return error.SweepDidNotFinish;
}

test "SONNY-6540 item 3: the adjacency hydrate frees what it allocated at every allocation failure, both directions" {
    const saved = graph_store.saveDataDirOverride();
    defer saved.restore();
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir_path);

    const store = try graph_store.initGlobalStore(testing.allocator, dir_path);
    var labels = [_][]const u8{"H6540"};
    try store.createNodeWithId(1001, &labels, "default");
    try store.createNodeWithId(1002, &labels, "default");
    try store.createNodeWithId(1003, &labels, "default");
    try store.createEdgeWithId(9001, 1001, 1002, "R6540", "default");
    try store.createEdgeWithId(9002, 1001, 1003, "R6540", "default");
    try store.createEdgeWithId(9003, 1003, 1002, "R6540", "default");

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();
    const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
    const from_slot = id_map.nodeSlot(@as(u128, 1001)) orelse return error.NodeSlotMappingMissing;
    const to_slot = id_map.nodeSlot(@as(u128, 1002)) orelse return error.NodeSlotMappingMissing;

    try sweep(adapter, from_slot, .outgoing, 2);
    try sweep(adapter, to_slot, .incoming, 2);
}
