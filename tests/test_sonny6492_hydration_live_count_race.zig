// SONNY-6492 (2): the hydration scan's live-count check (REQ-GQL-028)
// reports DataCorruption only for lost records, never for a write in flight.
//
// `hydration_scan.scanShard` compares the live node records it finds in a
// shard with the shard manifest's live-node count, as the unlabeled scan
// does (`StorageAdapter.scanAllNodes`, SONNY-2409). The engine changes the
// two in separate steps: a create counts the node when it allocates the
// slot, then writes the record. SONNY-6472 (4) gave the unlabeled scan an
// allowance of one record per node write in flight (`node_census_writers`);
// the hydration scan had none, so a hydration scan between the two steps of a
// create on another thread failed the graph's hydration with DataCorruption
// (and quarantined it).
//
// A bulk insert runs the hydration scan of every shard from inside the create
// (`node_slot_allocated_hook`: after the engine counted the node, before its
// record is written). No scan may fail; with nothing in flight the scan finds
// every node. The detection itself stays: test-sonny2409-zeroed-page-header,
// test-canary-recovery-corrupt-latency.
//
// CANARY: REQ=REQ-SONNY-6492-HYDRATION-LIVE-COUNT-RACE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6492_hydration_live_count_race.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const G = "g6492hyd";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const opts: gsa.hydration_scan.ScanOptions = .{
    .include_edges = true,
    .resident_mode = true,
    .internal_id_key = graph_store.INTERNAL_NODE_ID_PROPERTY_KEY,
};

/// Hydration-scans every shard; returns the live records found, counting
/// the scans that failed with DataCorruption in `corrupt`.
fn scanAll(adapter: *gsa.StorageAdapter, corrupt: *usize, other: *usize) usize {
    const shards = adapter.hydrationStreamShardCount(G) catch {
        other.* += 1;
        return 0;
    };
    var found: usize = 0;
    for (0..shards) |i| {
        var acc = adapter.hydrationStreamScanShard(G, i, std.testing.allocator, opts) catch |err| {
            if (err == error.DataCorruption) corrupt.* += 1 else other.* += 1;
            continue;
        };
        defer acc.deinit();
        found += acc.rows.len;
    }
    return found;
}

const MidCreateScan = struct {
    var calls: usize = 0;
    var corrupt: usize = 0;
    var other: usize = 0;

    fn hook(mg: *gsa.ManagedGraph) void {
        if (!std.mem.eql(u8, mg.name, G)) return;
        const adapter = graph_store.getGlobalAdapter() orelse return;
        calls += 1;
        _ = scanAll(adapter, &corrupt, &other);
    }
};

test "SONNY-6492 (2): a hydration scan between a create's count and its record does not report DataCorruption" {
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
    try store.createGraph(G);
    const labels = [_][]const u8{"N"};
    const ids = try adapter.createNodesBatch(G, &labels, 64, allocator);
    allocator.free(ids);

    MidCreateScan.calls = 0;
    MidCreateScan.corrupt = 0;
    MidCreateScan.other = 0;
    gsa.node_slot_allocated_hook = MidCreateScan.hook;
    defer gsa.node_slot_allocated_hook = null;
    for (0..16) |_| _ = try adapter.bulkInsertNodeWithReservedId(G, store.reserveNodeId(), &labels, &.{});
    gsa.node_slot_allocated_hook = null;

    std.debug.print("SONNY-6492 (2): {d} hydration scans mid-create; {d} shard scan(s) reported DataCorruption\n", .{ MidCreateScan.calls, MidCreateScan.corrupt });
    try std.testing.expectEqual(@as(usize, 16), MidCreateScan.calls);
    try std.testing.expectEqual(@as(usize, 0), MidCreateScan.other);
    try std.testing.expectEqual(@as(usize, 0), MidCreateScan.corrupt);

    // With nothing in flight the count is exact: the scan finds every node.
    var corrupt: usize = 0;
    var other: usize = 0;
    try std.testing.expectEqual(@as(usize, 64 + 16), scanAll(adapter, &corrupt, &other));
    try std.testing.expectEqual(@as(usize, 0), corrupt + other);
}
