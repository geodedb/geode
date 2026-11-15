// SONNY-6632: three follow-ups to SONNY-6605's hydration retry.
//
// (1) A graph whose registration failed at open is marked failed with
//     `done` false, so its first touch rebuilds it (the self-heal). A
//     rebuild that succeeded left `failed` set: every read of the graph was
//     refused (`GraphQuarantined`) until a restart, built or not.
// (2) `bumpGraphEdgeTypeCount` returned silently when it could not
//     allocate the key of a relationship type's first count: the hydration
//     succeeded with that type counted one short, and `count(r:TYPE)`
//     answered the wrong number for the life of the process.
// (3) A checkpoint skipped the retired-cache reclaims of a graph whose
//     hydration had not completed (`done` false), to protect a running
//     build's family threads. A graph whose build failed transiently stays
//     at `done` false until a retry succeeds, so while out of memory every
//     retry retired the bodies the previous one cached and none was ever
//     freed. Only a running build needs the reclaims held off.
//
// Allocation failures are real: the store's allocator is wrapped in a
// thread-safe allocator that fails one chosen allocation (by index or by
// size) or every allocation from an index on. The store, the engine and the
// checkpoint are real; nothing is simulated.
//
// CANARY: REQ=REQ-SONNY-6632-HYDRATION-FOLLOWUPS; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6632_hydration_followups.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

const graph_store = geode.graph_store;
const gsa = geode.graph_storage_adapter;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const G = "g6632";
/// A relationship type whose count key ("g6632\x00" ++ type) has a length
/// no other allocation of the hydration has, so a fault on that size hits
/// the count's key.
const RARE_TYPE = "RARE_TYPE_SONNY_6632_XYZ";
const RARE_KEY_LEN = G.len + 1 + RARE_TYPE.len;
const PERSONS: usize = 240;

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

fn run(argv: []const []const u8) !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const r = try std.process.run(testing.allocator, threaded.io(), .{ .argv = argv });
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    switch (r.term) {
        .exited => |c| if (c != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn copyOf(pristine: []const u8, work: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io(), work) catch {};
    try run(&.{ "cp", "-a", pristine, work });
}

/// Thread-safe fault-injecting allocator. Modes (all off by default):
///   * `fail_from`: every allocation (and growing resize/remap) from that
///     allocation index on fails, until `disarm`;
///   * `fail_once_at`: only the allocation with that index fails;
///   * `fail_once_len`: only the first allocation of exactly that length
///     fails.
/// Frees always reach the child.
const FaultAllocator = struct {
    child: std.mem.Allocator,
    count: std.atomic.Value(u64) = .init(0),
    fail_from: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    fail_once_at: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    fail_once_len: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocator(self: *FaultAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn armFrom(self: *FaultAllocator, after: u64) void {
        self.failed.store(0, .release);
        self.fail_from.store(self.count.load(.acquire) + after, .release);
    }

    fn armOnceAt(self: *FaultAllocator, after: u64) void {
        self.failed.store(0, .release);
        self.fail_once_at.store(self.count.load(.acquire) + after, .release);
    }

    fn armOnceLen(self: *FaultAllocator, len: usize) void {
        self.failed.store(0, .release);
        self.fail_once_len.store(len, .release);
    }

    fn disarm(self: *FaultAllocator) void {
        self.fail_from.store(std.math.maxInt(u64), .release);
        self.fail_once_at.store(std.math.maxInt(u64), .release);
        self.fail_once_len.store(0, .release);
    }

    fn failingFrom(self: *FaultAllocator) bool {
        return self.count.load(.acquire) >= self.fail_from.load(.acquire);
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        const n = self.count.fetchAdd(1, .acq_rel);
        const once_len = self.fail_once_len.load(.acquire);
        const fail = n >= self.fail_from.load(.acquire) or
            (n == self.fail_once_at.load(.acquire)) or
            (once_len != 0 and len == once_len and self.fail_once_len.cmpxchgStrong(once_len, 0, .acq_rel, .acquire) == null);
        if (fail) {
            _ = self.failed.fetchAdd(1, .acq_rel);
            return null;
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.failingFrom()) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.failingFrom()) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const Expected = struct {
    persons: usize,
    nodes: usize,
    edges: usize,
    knows: usize,
    rare: usize,
};

/// `PERSONS` Person nodes chained by KNOWS and RARE_TYPE relationships. A
/// full checkpoint writes the IdMap snapshot (the reopen defers hydration
/// to the first touch); the loop2 product snapshots are removed, so that
/// touch scans.
fn buildPristine(allocator: std.mem.Allocator, dir: []const u8) !Expected {
    graph_store.setDataDirOverride(allocator, dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    var ids = try allocator.alloc(u64, PERSONS);
    defer allocator.free(ids);
    for (0..PERSONS) |i| {
        ids[i] = try store.createNodeWithGraph(&.{"Person"}, G);
        try store.setNodeProperty(ids[i], "idx", .{ .Int = @intCast(i) });
    }
    var knows: usize = 0;
    var rare: usize = 0;
    for (0..PERSONS - 1) |i| {
        const ty: []const u8 = if (i % 4 == 0) RARE_TYPE else "KNOWS";
        _ = try store.createEdgeWithGraph(ids[i], ids[i + 1], ty, G);
        if (i % 4 == 0) rare += 1 else knows += 1;
    }
    try store.saveToFile();
    graph_store.deinitGlobalStore();
    return .{ .persons = PERSONS, .nodes = PERSONS, .edges = PERSONS - 1, .knows = knows, .rare = rare };
}

fn removeHydrationSnapshots(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var removed: usize = 0;
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "hydration_") or !std.mem.endsWith(u8, entry.basename, ".snap")) continue;
        try entry.dir.deleteFile(io(), entry.basename);
        removed += 1;
    }
    return removed;
}

fn reopen(allocator: std.mem.Allocator, dir: []const u8, fault: *FaultAllocator) *graph_store.GraphStore {
    graph_store.setTestGlobalStoreAllocator(fault.allocator());
    graph_store.setDataDirOverride(allocator, dir);
    graph_store.resetLazyHydrateCounters();
    return graph_store.getGlobalStore(allocator);
}

fn close(allocator: std.mem.Allocator) void {
    graph_store.deinitGlobalStoreForTestCrash();
    graph_store.setTestGlobalStoreAllocator(null);
    graph_store.setDataDirOverride(allocator, null);
}

fn counts(store: *graph_store.GraphStore) Expected {
    return .{
        .persons = store.countNodesByLabel(G, "Person", null),
        .nodes = store.countNodesForGraph(G, null),
        .edges = store.countEdgesForGraph(G),
        .knows = store.countEdgesByTypeForGraph(G, "KNOWS"),
        .rare = store.countEdgesByTypeForGraph(G, RARE_TYPE),
    };
}

const Fixture = struct {
    base: []u8,
    pristine: []u8,
    work: []u8,
    want: Expected,

    fn init(allocator: std.mem.Allocator, sub_path: []const u8) !Fixture {
        graph_store.deinitGlobalStore();
        _ = setenv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST", "1", 1);
        gsa.setEagerExactRebuildOnReopenDisabledForTest(true);
        const base = try tmpDirRealpathAlloc(allocator, sub_path);
        errdefer allocator.free(base);
        const pristine = try std.fmt.allocPrint(allocator, "{s}/pristine", .{base});
        errdefer allocator.free(pristine);
        const work = try std.fmt.allocPrint(allocator, "{s}/work", .{base});
        errdefer allocator.free(work);
        try std.Io.Dir.cwd().createDirPath(io(), pristine);
        const want = try buildPristine(allocator, pristine);
        try testing.expect(try removeHydrationSnapshots(allocator, pristine) > 0);
        try copyOf(pristine, work);
        return .{ .base = base, .pristine = pristine, .work = work, .want = want };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        allocator.free(self.pristine);
        allocator.free(self.work);
        _ = unsetenv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST");
        gsa.setEagerExactRebuildOnReopenDisabledForTest(null);
    }
};

test "SONNY-6632 (1): a graph whose registration failed at open is readable once its first touch rebuilt it" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx = try Fixture.init(allocator, &tmp.sub_path);
    defer fx.deinit(allocator);

    var fault = FaultAllocator{ .child = std.heap.smp_allocator };
    const store = reopen(allocator, fx.work, &fault);
    defer close(allocator);

    // The allocations of a clean reload.
    const before = fault.count.load(.acquire);
    try store.loadFromFile();
    const reload_allocs = fault.count.load(.acquire) - before;

    // Reload with one allocation failing, from the last one backwards (the
    // first ones clear the store, which panics on an allocation failure),
    // until the failure lands in this graph's registration: the reload then
    // succeeds with the graph marked failed and not built.
    var found: ?u64 = null;
    var k: u64 = reload_allocs;
    while (k > 0 and found == null) {
        k -= 1;
        fault.armOnceAt(k);
        const loaded = store.loadFromFile();
        fault.disarm();
        if (loaded) |_| {} else |_| continue;
        if (store.graphQuarantineError(G) != null) found = k;
    }
    const at = found orelse {
        std.debug.print("SONNY-6632 (1): no single allocation failure of a {d}-allocation reload left {s} failed at open\n", .{ reload_allocs, G });
        return error.OpenFailureNotReproduced;
    };
    std.debug.print("SONNY-6632 (1): allocation {d} of {d} of the reload failed this graph's registration\n", .{ at, reload_allocs });

    // First touch: the rebuild runs and succeeds.
    graph_store.clearQuarantinedReadError();
    const got = counts(store);
    const noted = graph_store.takeQuarantinedReadError();
    const still = store.graphQuarantineError(G);
    std.debug.print("SONNY-6632 (1): after the rebuild: counts {any}, noted {s}, quarantined {s}\n", .{ got, if (noted) |e| @errorName(e) else "nothing", if (still) |e| @errorName(e) else "no" });
    try testing.expect(std.meta.eql(got, fx.want));
    try testing.expect(noted == null);
    try testing.expect(still == null);
}

test "SONNY-6632 (2): a relationship-type count whose key cannot be allocated fails the hydration, and the retry counts every edge" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx = try Fixture.init(allocator, &tmp.sub_path);
    defer fx.deinit(allocator);

    var fault = FaultAllocator{ .child = std.heap.smp_allocator };
    const store = reopen(allocator, fx.work, &fault);
    defer close(allocator);

    graph_store.clearQuarantinedReadError();
    fault.armOnceLen(RARE_KEY_LEN);
    const first = counts(store);
    fault.disarm();
    const noted = graph_store.takeQuarantinedReadError();
    try testing.expectEqual(@as(u64, 1), fault.failed.load(.acquire));
    std.debug.print("SONNY-6632 (2): first touch with the {s} count key failing: counts {any}, noted {s}\n", .{ RARE_TYPE, first, if (noted) |e| @errorName(e) else "nothing" });

    graph_store.clearQuarantinedReadError();
    const got = counts(store);
    try testing.expect(graph_store.takeQuarantinedReadError() == null);
    try testing.expect(store.graphQuarantineError(G) == null);
    if (!std.meta.eql(got, fx.want)) {
        std.debug.print("SONNY-6632 (2): counts {any}, want {any}: the failed count was dropped\n", .{ got, fx.want });
        return error.EdgeTypeCountDropped;
    }
    // The failure was not silent: the touch that hit it failed.
    try testing.expect(noted != null and noted.? == error.OutOfMemory);
}

test "SONNY-6632 (3): a checkpoint frees the retired cache entries of a graph whose hydration failed transiently" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx = try Fixture.init(allocator, &tmp.sub_path);
    defer fx.deinit(allocator);

    var counting = FaultAllocator{ .child = std.heap.smp_allocator };
    const clean_allocs = blk: {
        const store = reopen(allocator, fx.work, &counting);
        defer close(allocator);
        const before = counting.count.load(.acquire);
        _ = store.countNodesByLabel(G, "Person", null);
        break :blk counting.count.load(.acquire) - before;
    };
    try copyOf(fx.pristine, fx.work);

    var fault = FaultAllocator{ .child = std.heap.smp_allocator };
    const store = reopen(allocator, fx.work, &fault);
    defer close(allocator);

    // Two builds that run out of memory late: the second caches again the
    // node bodies the first cached, retiring the first's copies.
    for (0..2) |_| {
        graph_store.clearQuarantinedReadError();
        fault.armFrom(clean_allocs * 60 / 100);
        _ = store.countNodesByLabel(G, "Person", null);
        fault.disarm();
        const noted = graph_store.takeQuarantinedReadError();
        std.debug.print("SONNY-6632 (3): failed build noted {s}\n", .{if (noted) |e| @errorName(e) else "nothing"});
        try testing.expect(noted != null and noted.? == error.OutOfMemory);
    }
    try testing.expect(store.graphQuarantineError(G) == null);
    const retired_before = store.nodes.retiredCount();
    try testing.expect(retired_before > 0);

    gsa.resetHydrationReclaimSkipsForTesting();
    try graph_store.getGlobalAdapter().?.checkpointGraph(G);
    const retired_after = store.nodes.retiredCount();
    const skips = gsa.getHydrationReclaimSkipsForTesting();
    std.debug.print("SONNY-6632 (3): retired node bodies {d} -> {d} across a checkpoint of the not-built graph ({d} reclaim skip(s))\n", .{ retired_before, retired_after, skips });
    try testing.expectEqual(@as(u64, 0), skips);
    try testing.expect(retired_after < retired_before);

    // And the graph still builds, with exact counts.
    graph_store.clearQuarantinedReadError();
    const got = counts(store);
    try testing.expect(graph_store.takeQuarantinedReadError() == null);
    try testing.expect(std.meta.eql(got, fx.want));
}
