// SONNY-3121: with group commit disabled (GEODE_GROUP_COMMIT=0) the QUIC
// handler calls the self-locking bulk helpers directly, with no graph lock
// held: the relationship MERGE (`bulkMergeEdgeWithIdsShardLocked`) and the
// multi-property node MERGE (`bulkMergeNodeWithReservedIdMultiProp`). They
// looked the graph up without a pin, so a DROP GRAPH between the lookup and
// their locks freed the ManagedGraph under them: a use-after-free.
//
// `bulk_graph_resolved_hook` runs right after a helper has its graph. Here it
// checks that the helper holds a pin on it, and only then drops the graph
// (without a pin the drop would free the graph the helper is about to lock,
// which the test cannot survive to report). With the pin, the helper must
// see the graph dropped and fail with GraphNotFound, and the graph must be
// freed when the helper lets go (the testing allocator checks for leaks).
//
// CANARY: REQ=REQ-SONNY-3121-DIRECT-BULK-PIN; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3121_direct_bulk_pin.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;
const PropKV = gsa.StorageAdapter.PropKV;

const G = "g3121";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Probe = struct {
    var calls: usize = 0;
    var unpinned: usize = 0;
    var dropped: usize = 0;

    fn hook(mg: *gsa.ManagedGraph) void {
        if (!std.mem.eql(u8, mg.name, G)) return;
        calls += 1;
        const pins = mg.pins.load(.acquire) & ~gsa.ManagedGraph.dropped_bit;
        if (pins == 0) {
            unpinned += 1;
            return;
        }
        const store = graph_store.getGlobalStore(std.testing.allocator);
        store.dropGraph(G) catch return;
        dropped += 1;
    }
};

test "SONNY-3121: the direct bulk MERGE helpers hold a pin on their graph, and fail with GraphNotFound when it is dropped under them" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    const cases = [_]enum { merge_node_multi, merge_edge }{ .merge_node_multi, .merge_edge };
    for (cases) |case| {
        try store.createGraph(G);
        const a = [_]PropKV{ .{ .key = "a", .value = .{ .Int = 1 } }, .{ .key = "b", .value = .{ .Int = 2 } } };
        const c = [_]PropKV{ .{ .key = "a", .value = .{ .Int = 3 } }, .{ .key = "b", .value = .{ .Int = 4 } } };
        const src = try adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "L", &a, &.{}, false);
        const dst = try adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "L", &c, &.{}, false);

        Probe.calls = 0;
        Probe.unpinned = 0;
        Probe.dropped = 0;
        gsa.bulk_graph_resolved_hook = Probe.hook;
        defer gsa.bulk_graph_resolved_hook = null;
        const e = [_]PropKV{ .{ .key = "a", .value = .{ .Int = 5 } }, .{ .key = "b", .value = .{ .Int = 6 } } };
        const outcome: anyerror!u64 = switch (case) {
            .merge_node_multi => if (adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "L", &e, &.{}, false)) |r| r.id else |err| err,
            .merge_edge => adapter.bulkMergeEdgeWithIdsShardLocked(G, src.id, dst.id, "R", &.{}),
        };
        gsa.bulk_graph_resolved_hook = null;

        if (Probe.calls == 0) return error.HookNotReached;
        if (Probe.unpinned > 0) {
            std.debug.print("{s}: the helper used graph {s} without a pin ({d} of {d} lookups)\n", .{ @tagName(case), G, Probe.unpinned, Probe.calls });
            return error.BulkHelperGraphNotPinned;
        }
        try std.testing.expectEqual(@as(usize, 1), Probe.dropped);
        try std.testing.expectError(error.GraphNotFound, outcome);
        try std.testing.expect(adapter.pinGraph(G) == null);
    }
}
