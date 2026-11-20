// SONNY-6433 items 6, 7, 10: the ordered-index read paths follow the graph
// lock discipline of SONNY-6375 / SONNY-3028.
//
// 6. The planner gates `isOrderedIndexRegistered`, `isOrderedIndexEligible`
//    and `isOrderedIndexFresh` read each shard's ordered-index registry and
//    eligibility state, which `createOrderedIndex` (the background ORDER BY
//    auto-build among others) mutates under `mg.rwlock` SHARED and
//    `shard_locks[i]` EXCLUSIVE, and the full checkpoint under `mg.rwlock`
//    EXCLUSIVE. They read it with no lock. They now take `mg.rwlock` SHARED
//    (unless this thread already holds the graph lock) and then each
//    `shard_locks[i]` SHARED, the order `createOrderedIndex` uses (tier 1:
//    rwlock before shard locks), so a gate waits for a build that holds a
//    shard.
// 7. `orderedScan` resolved its graph with no pin and lets its locks go
//    between batches, so a DROP GRAPH between two batches freed the graph
//    the next batch read. The scan now pins the graph (as the graph-lock API
//    does) and, after taking `mg.rwlock`, fails with GraphNotFound when the
//    graph was dropped (as `lockedUnlessDropped` does). The pin keeps the
//    freed-on-last-unpin graph alive until the scan returns.
// 10. The per-thread table of held graph locks had 16 slots; past them every
//    graph counted as held, so an ordered scan on a graph the thread did not
//    lock read it with no `rwlock` at all. The table now grows: a 17th lock
//    is tracked like the first, and a graph the thread does not hold is
//    never reported as held.
//
// Real on-disk engine in a tmpDir; no mocks.
//
// CANARY: REQ=REQ-SONNY-6433-ORDERED-INDEX-LOCKING; FEATURE="OrderedIndex"; ASPECT=GatesPinsAndLockTracking; STATUS=TESTED; TEST=tests/test_sonny6433_ordered_index_locking.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn seed(adapter: *StorageAdapter, graph: []const u8, n: usize) !void {
    for (0..n) |i| {
        const node_id = try adapter.createNode(graph, &[_][]const u8{"T"});
        try adapter.setNodeProperty(graph, node_id, "k", .{ .Int = @intCast(i) });
    }
}

const Gate = enum { registered, eligible, fresh };

const GateCall = struct {
    adapter: *StorageAdapter,
    graph: []const u8,
    gate: Gate,
    done: std.atomic.Value(bool) = .init(false),
    answer: bool = false,

    fn run(self: *GateCall) void {
        self.answer = switch (self.gate) {
            .registered => self.adapter.isOrderedIndexRegistered(self.graph, "T", "k"),
            .eligible => self.adapter.isOrderedIndexEligible(self.graph, "T", "k"),
            .fresh => self.adapter.isOrderedIndexFresh(self.graph, "T", "k"),
        };
        self.done.store(true, .release);
    }
};

test "SONNY-6433: the ordered-index planner gates wait for a build that holds a shard" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 256, .sync_mode = .deferred });
    defer adapter.deinit();
    const graph = "g";
    try seed(adapter, graph, 64);
    try adapter.createOrderedIndex(graph, "T", "k");

    const mg = try adapter.lookupManagedGraph(graph);
    const io = std.Io.Threaded.global_single_threaded.io();
    inline for (.{ Gate.registered, Gate.eligible, Gate.fresh }) |gate| {
        // What `createOrderedIndex` holds while it registers and rebuilds
        // shard 5: the graph lock SHARED, the shard's lock EXCLUSIVE.
        mg.rwlock.lockSharedUncancelable(io);
        mg.shard_locks[5].lockUncancelable(io);
        var call = GateCall{ .adapter = adapter, .graph = graph, .gate = gate };
        const t = try std.Thread.spawn(.{}, GateCall.run, .{&call});
        sleepMs(200);
        const finished_while_held = call.done.load(.acquire);
        mg.shard_locks[5].unlock(io);
        mg.rwlock.unlockShared(io);
        t.join();
        if (finished_while_held) std.debug.print("gate {s} read the shards while a build held shard 5\n", .{@tagName(gate)});
        try testing.expect(!finished_while_held);
        try testing.expect(call.done.load(.acquire));
    }
    try testing.expect(adapter.isOrderedIndexRegistered(graph, "T", "k"));
    try testing.expect(adapter.isOrderedIndexEligible(graph, "T", "k"));
}

test "SONNY-6433: the ordered-index planner gates answer under the caller's own graph lock" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 256, .sync_mode = .deferred });
    defer adapter.deinit();
    const graph = "g";
    try seed(adapter, graph, 16);
    try adapter.createOrderedIndex(graph, "T", "k");

    {
        const acq = try adapter.acquireGraphReadLock(graph);
        defer adapter.releaseGraphReadLock(acq.mg, acq.hold_start_ns, .misc);
        try testing.expect(adapter.isOrderedIndexRegistered(graph, "T", "k"));
        try testing.expect(adapter.isOrderedIndexEligible(graph, "T", "k"));
        _ = adapter.isOrderedIndexFresh(graph, "T", "k");
    }
    {
        const mg = try adapter.acquireGraphWriteLock(graph);
        defer adapter.releaseGraphWriteLock(mg);
        try testing.expect(adapter.isOrderedIndexRegistered(graph, "T", "k"));
        try testing.expect(adapter.isOrderedIndexEligible(graph, "T", "k"));
        _ = adapter.isOrderedIndexFresh(graph, "T", "k");
    }
}

const DropCtx = struct {
    adapter: *StorageAdapter,
    graph: []const u8,
    drops: usize = 0,
    err: ?anyerror = null,

    fn run(raw: *anyopaque) void {
        const self: *DropCtx = @ptrCast(@alignCast(raw));
        if (self.drops > 0) return;
        self.drops += 1;
        self.adapter.dropGraph(self.graph) catch |e| {
            self.err = e;
        };
    }
};

test "SONNY-6433: a DROP GRAPH between two batches of an ordered scan cannot free the graph under it" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 1024, .sync_mode = .deferred });
    defer adapter.deinit();
    const graph = "g";

    // 16 shards x 300 nodes: a second batch on every shard (256 per batch).
    const n: usize = 16 * 300;
    try seed(adapter, graph, n);
    try adapter.createOrderedIndex(graph, "T", "k");

    var ctx = DropCtx{ .adapter = adapter, .graph = graph };
    adapter_mod.test_ordered_scan_between_batches = .{ .ctx = &ctx, .run = DropCtx.run };
    defer adapter_mod.test_ordered_scan_between_batches = null;

    try testing.expectError(error.GraphNotFound, adapter.orderedScan(graph, "T", "k", .asc, n, allocator));
    try testing.expect(ctx.err == null);
    try testing.expectEqual(@as(usize, 1), ctx.drops);
    // The graph is gone, and the last unpin freed it (the leak check of
    // testing.allocator covers the free).
    try testing.expectError(error.GraphNotFound, adapter.lookupManagedGraph(graph));
    try testing.expect(!adapter.isOrderedIndexRegistered(graph, "T", "k"));
}

test "SONNY-6433: a thread holding more than 16 graph locks still tracks each one" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // 19 open graphs at ~180 descriptors each: past a 1024 soft limit, so
    // raise it to the hard limit, as the server does at startup.
    var lim = try std.posix.getrlimit(.NOFILE);
    if (lim.cur < 8192 and lim.max > lim.cur) {
        lim.cur = @min(lim.max, 8192);
        try std.posix.setrlimit(.NOFILE, lim);
    }

    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 64, .sync_mode = .deferred });
    defer adapter.deinit();

    const held_count = 18;
    var names: [held_count + 1][8]u8 = undefined;
    var graphs: [held_count + 1][]const u8 = undefined;
    for (&names, &graphs, 0..) |*buf, *g, i| {
        g.* = try std.fmt.bufPrint(buf, "g{d:0>2}", .{i});
        _ = try adapter.getOrCreateGraph(g.*);
    }
    // The last graph is never locked by this thread.
    const free_mg = try adapter.lookupManagedGraph(graphs[held_count]);

    var acqs: [held_count]adapter_mod.ReadLockAcquisition = undefined;
    var taken: usize = 0;
    defer for (acqs[0..taken]) |a| adapter.releaseGraphReadLock(a.mg, a.hold_start_ns, .misc);
    for (graphs[0..held_count], 0..) |g, i| {
        acqs[i] = try adapter.acquireGraphReadLock(g);
        taken += 1;
    }

    for (acqs[0..taken]) |a| try testing.expect(adapter_mod.threadHoldsGraphLock(a.mg));
    // It was reported held once the 16 slots were full.
    try testing.expect(!adapter_mod.threadHoldsGraphLock(free_mg));

    // Releasing the 17th and 18th, and then the rest, forgets exactly them.
    adapter.releaseGraphReadLock(acqs[17].mg, acqs[17].hold_start_ns, .misc);
    adapter.releaseGraphReadLock(acqs[16].mg, acqs[16].hold_start_ns, .misc);
    const released = [_]*adapter_mod.ManagedGraph{ acqs[16].mg, acqs[17].mg };
    taken = 16;
    for (released) |mg| try testing.expect(!adapter_mod.threadHoldsGraphLock(mg));
    for (acqs[0..16]) |a| try testing.expect(adapter_mod.threadHoldsGraphLock(a.mg));
    for (acqs[0..taken]) |a| adapter.releaseGraphReadLock(a.mg, a.hold_start_ns, .misc);
    taken = 0;
    for (acqs[0..held_count]) |a| try testing.expect(!adapter_mod.threadHoldsGraphLock(a.mg));
    try testing.expect(!adapter_mod.threadHoldsGraphLock(free_mg));
}
