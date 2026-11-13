// SONNY-6472 (4): the unlabeled node scan's live-count check (SONNY-2409)
// reports DataCorruption only for lost records, never for a write in flight.
//
// `StorageAdapter.scanAllNodes` compares, per shard, the live node records it
// finds with the shard manifest's live-node count. The engine changes the
// two in separate steps: a delete tombstones the record, then decrements the
// count; a create counts the node when it allocates the slot, then writes the
// record. A scan between the two steps of a write on another thread found one
// record fewer than the count and failed the read with DataCorruption.
//
// Writers delete and create nodes on their own threads, as the shard-locked
// bulk writers do (graph lock SHARED + the shard's lock), while a reader
// scans under the graph lock SHARED, many times. No scan may fail. The
// detection itself stays: test-sonny2409-zeroed-page-header.
//
// CANARY: REQ=REQ-SONNY-6472-SCAN-LIVE-COUNT-RACE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6472_scan_live_count_race.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const G = "g6472scan";
const seed_nodes = 2048;
const scans = 400;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Writer = struct {
    adapter: *gsa.StorageAdapter,
    store: *graph_store.GraphStore,
    /// Node slots this writer deletes, one per round, and re-creates.
    victims: []const u64,
    stop: *std.atomic.Value(bool),
    errors: std.atomic.Value(usize) = .init(0),
    ops: std.atomic.Value(usize) = .init(0),

    fn go(self: *Writer) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const labels = [_][]const u8{"N"};
        var i: usize = 0;
        while (!self.stop.load(.acquire)) : (i += 1) {
            const victim = self.victims[i % self.victims.len];
            // A delete, as a shard-locked writer makes it: the graph lock
            // SHARED and the node's shard lock.
            {
                const acq = self.adapter.acquireGraphReadLock(G) catch {
                    _ = self.errors.fetchAdd(1, .monotonic);
                    return;
                };
                defer self.adapter.releaseGraphReadLock(acq.mg, acq.hold_start_ns, .misc);
                const shard = acq.mg.shardEngineForNode(victim);
                const si = for (acq.mg.engine.shards, 0..) |sh, k| {
                    if (sh == shard) break k;
                } else unreachable;
                acq.mg.shard_locks[si].lockUncancelable(io);
                defer acq.mg.shard_locks[si].unlock(io);
                self.adapter.deleteNode(G, victim) catch |err| switch (err) {
                    error.NodeNotFound => {},
                    else => {
                        _ = self.errors.fetchAdd(1, .monotonic);
                        return;
                    },
                };
            }
            // A create: the bulk insert takes the graph and shard locks itself.
            _ = self.adapter.bulkInsertNodeWithReservedId(G, self.store.reserveNodeId(), &labels, &.{}) catch {
                _ = self.errors.fetchAdd(1, .monotonic);
                return;
            };
            _ = self.ops.fetchAdd(1, .monotonic);
        }
    }
};

test "SONNY-6472 (4): an unlabeled scan racing deletes and creates never reports DataCorruption" {
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
    const ids = try adapter.createNodesBatch(G, &labels, seed_nodes, allocator);
    defer allocator.free(ids);

    const n_writers = 4;
    var stop = std.atomic.Value(bool).init(false);
    var ws: [n_writers]Writer = undefined;
    var ts: [n_writers]std.Thread = undefined;
    const per = seed_nodes / n_writers;
    for (&ws, &ts, 0..) |*w, *t, wi| {
        w.* = .{ .adapter = adapter, .store = store, .victims = ids[wi * per .. (wi + 1) * per], .stop = &stop };
        t.* = try std.Thread.spawn(.{}, Writer.go, .{w});
    }

    var corrupt: usize = 0;
    var scanned: usize = 0;
    while (scanned < scans) : (scanned += 1) {
        const acq = try adapter.acquireGraphReadLock(G);
        defer adapter.releaseGraphReadLock(acq.mg, acq.hold_start_ns, .misc);
        const entries = adapter.scanAllNodes(G, allocator) catch |err| switch (err) {
            error.DataCorruption => {
                corrupt += 1;
                continue;
            },
            else => return err,
        };
        allocator.free(entries);
    }
    stop.store(true, .release);
    for (ts) |t| t.join();

    var ops: usize = 0;
    for (ws) |w| {
        try std.testing.expectEqual(@as(usize, 0), w.errors.load(.monotonic));
        ops += w.ops.load(.monotonic);
    }
    std.debug.print("SONNY-6472 (4): {d} scans against {d} delete+create rounds; {d} reported DataCorruption\n", .{ scans, ops, corrupt });
    try std.testing.expect(ops > 0);
    if (corrupt > 0) return error.FalseDataCorruption;
}

/// Scans the graph from inside a bulk insert, after the engine counted the
/// new node and before its record is written (`node_slot_allocated_hook`).
const MidCreateScan = struct {
    var scanned: usize = 0;
    var corrupt: usize = 0;
    var other: usize = 0;

    fn hook(mg: *gsa.ManagedGraph) void {
        if (!std.mem.eql(u8, mg.name, G)) return;
        const adapter = graph_store.getGlobalAdapter() orelse return;
        scanned += 1;
        const entries = adapter.scanAllNodes(G, std.testing.allocator) catch |err| {
            if (err == error.DataCorruption) corrupt += 1 else other += 1;
            return;
        };
        std.testing.allocator.free(entries);
    }
};

test "SONNY-6472 (4): a scan between a create's count and its record does not report DataCorruption" {
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

    MidCreateScan.scanned = 0;
    MidCreateScan.corrupt = 0;
    MidCreateScan.other = 0;
    gsa.node_slot_allocated_hook = MidCreateScan.hook;
    defer gsa.node_slot_allocated_hook = null;
    for (0..16) |_| _ = try adapter.bulkInsertNodeWithReservedId(G, store.reserveNodeId(), &labels, &.{});

    std.debug.print("SONNY-6472 (4): {d} scans mid-create; {d} reported DataCorruption\n", .{ MidCreateScan.scanned, MidCreateScan.corrupt });
    try std.testing.expectEqual(@as(usize, 16), MidCreateScan.scanned);
    try std.testing.expectEqual(@as(usize, 0), MidCreateScan.other);
    try std.testing.expectEqual(@as(usize, 0), MidCreateScan.corrupt);

    // With nothing in flight the count is exact: the scan finds every node.
    const all = try adapter.scanAllNodes(G, allocator);
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 64 + 16), all.len);
}
