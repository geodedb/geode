// SONNY-6362 item 6: an index-served read does not wait for the exact-index
// build mutex.
//
// While a deferred build or a late-key catch-up of a graph's exact
// node-property index holds `exact_index_build_mutex`, the read seeks
// (`getCandidateNodesByLabelAndProperty`, `countCandidateNodesByLabelAndProperty`,
// `collectPropertyPostingSummaries`) parked on it for the whole O(graph)
// build. They now answer `error.ExactIndexBusy` at once, which every read
// caller treats as "no index answer" and serves from a scan. A write-path
// lookup (the MERGE resolver `lookupNodeIdByLabelAndAllProps`) still waits:
// it must see a complete index.
//
// Real on-disk engine; the in-flight build is stood in for by holding the
// mutex from the test thread (`holdExactIndexBuildMutexForTesting`), on a
// graph whose index is deferred at reopen.
//
// CANARY: REQ=REQ-SONNY-6362-READ-NO-BUILD-WAIT; FEATURE="ExactPropertyIndex"; ASPECT=ReadFallsBackDuringBuild; STATUS=TESTED; TEST=tests/test_sonny6362_exact_index_read_fallback.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;

const graph = "g6362";
const label = "Item";
const N: usize = 32;

fn testConfig() gs.GraphConfig {
    return .{ .page_size = 4096, .buffer_pool_pages = 64, .sync_mode = .deferred };
}

const Reader = struct {
    adapter: *StorageAdapter,
    done: std.atomic.Value(bool) = .init(false),
    get_err: ?anyerror = null,
    count_err: ?anyerror = null,
    summary_err: ?anyerror = null,

    fn run(self: *Reader) void {
        defer self.done.store(true, .release);
        if (self.adapter.getCandidateNodesByLabelAndProperty(graph, label, "uid", .{ .Int = 3 }, testing.allocator)) |ids| {
            testing.allocator.free(ids);
        } else |e| self.get_err = e;
        _ = self.adapter.countCandidateNodesByLabelAndProperty(graph, label, "uid", .{ .Int = 3 }) catch |e| {
            self.count_err = e;
        };
        if (self.adapter.collectPropertyPostingSummaries(graph, label, "uid", testing.allocator)) |s| {
            testing.allocator.free(s);
        } else |e| self.summary_err = e;
    }
};

const Merger = struct {
    adapter: *StorageAdapter,
    done: std.atomic.Value(bool) = .init(false),
    id: ?u64 = null,
    err: ?anyerror = null,

    fn run(self: *Merger) void {
        defer self.done.store(true, .release);
        const filters = [_]StorageAdapter.PropKV{.{ .key = "uid", .value = .{ .Int = 5 } }};
        self.id = self.adapter.lookupNodeIdByLabelAndAllProps(graph, label, &filters, error.NodeNotFound) catch |e| blk: {
            self.err = e;
            break :blk null;
        };
    }
};

fn waitFor(flag: *std.atomic.Value(bool), ms: u64) bool {
    var waited: u64 = 0;
    while (waited < ms) : (waited += 10) {
        if (flag.load(.acquire)) return true;
        std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return flag.load(.acquire);
}

test "SONNY-6362 item 6: index-served reads do not wait for an in-flight exact-index build; MERGE lookups do" {
    const allocator = testing.allocator;
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    var ids: [N]u64 = undefined;
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        for (&ids, 0..) |*id, i| {
            id.* = try adapter.createNode(graph, &[_][]const u8{label});
            try adapter.setNodeProperty(graph, id.*, "uid", .{ .Int = @intCast(i) });
        }
        try adapter.checkpointAll();
        adapter.invalidateExactIndexFileForTesting(graph);
    }

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);

    // A build in flight.
    try adapter.holdExactIndexBuildMutexForTesting(graph);
    var held = true;
    defer if (held) adapter.releaseExactIndexBuildMutexForTesting(graph) catch {};

    var reader = Reader{ .adapter = adapter };
    const rt = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    const reader_returned = waitFor(&reader.done, 5000);

    var merger = Merger{ .adapter = adapter };
    const mt = try std.Thread.spawn(.{}, Merger.run, .{&merger});
    const merger_returned_early = waitFor(&merger.done, 300);

    try adapter.releaseExactIndexBuildMutexForTesting(graph);
    held = false;
    rt.join();
    mt.join();

    try testing.expect(reader_returned);
    try testing.expectEqual(@as(?anyerror, error.ExactIndexBusy), reader.get_err);
    try testing.expectEqual(@as(?anyerror, error.ExactIndexBusy), reader.count_err);
    try testing.expectEqual(@as(?anyerror, error.ExactIndexBusy), reader.summary_err);

    // The MERGE resolver waited for the build and found the node.
    try testing.expect(!merger_returned_early);
    try testing.expect(merger.err == null);
    try testing.expectEqual(@as(?u64, ids[5]), merger.id);

    // With no build in flight a read builds the index and is served from it.
    const got = try adapter.getCandidateNodesByLabelAndProperty(graph, label, "uid", .{ .Int = 3 }, allocator);
    defer allocator.free(got);
    try testing.expectEqualSlices(u64, ids[3..4], got);
}
