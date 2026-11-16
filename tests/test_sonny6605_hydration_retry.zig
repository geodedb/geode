// SONNY-6605 (1): a graph whose first-touch hydration fails with a transient
// error (out of memory, a file-descriptor quota, ...) is retried on its next
// access, with exact products; a graph whose store is damaged stays
// quarantined.
//
// `ensureGraphHydrated` quarantined a graph on ANY hydration error until the
// server restarted (`GraphQuarantined`), an allocation failure included: a
// retry was not safe because the failed build left partial products behind,
// and the scan bumps the tenant-introspection multisets and the
// per-(graph, type) relationship counts once per node and edge it visits,
// with no guard against a second visit. Now a transient failure fails the
// statement with its own error (53200 for OutOfMemory), the next access
// clears the failed build's counters and builds again, and the counts are
// exactly those of a build that never failed.
//
// Allocation failures are real: the reopened store's allocator is wrapped in
// a thread-safe allocator that fails every allocation from the k-th one on
// (the hydration's scan workers and merge threads allocate concurrently).
// Each failure point is a fraction of the allocations a clean hydration of
// the same store makes, so the sweep lands in the scan, the node merge and
// the relationship phase, for the streaming scan (pipelined and
// single-threaded merge) and the legacy per-node walk. The store, the engine
// and the executor are real; nothing is simulated.
//
// CANARY: REQ=REQ-SONNY-6605-HYDRATION-RETRY; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6605_hydration_retry.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

const graph_store = geode.graph_store;
const execution = geode.execution;
const proto_util = geode.proto_util;
const query_arena = geode.query_arena;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const G = "g6605";
const PERSONS: usize = 240;
const TAGS: usize = 40;
const PAGE_SIZE: u64 = 8192;

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

/// Thread-safe allocator that fails every allocation (and every growing
/// resize or remap) from the `fail_from`-th allocation on, until `disarm`.
/// Frees always reach the child. Counts every allocation, armed or not.
const FaultAllocator = struct {
    child: std.mem.Allocator,
    count: std.atomic.Value(u64) = .init(0),
    fail_from: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
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

    fn arm(self: *FaultAllocator, after: u64) void {
        self.failed.store(0, .release);
        self.fail_from.store(self.count.load(.acquire) + after, .release);
    }

    fn disarm(self: *FaultAllocator) void {
        self.fail_from.store(std.math.maxInt(u64), .release);
    }

    fn failing(self: *FaultAllocator) bool {
        return self.count.load(.acquire) >= self.fail_from.load(.acquire);
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        const n = self.count.fetchAdd(1, .acq_rel);
        if (n >= self.fail_from.load(.acquire)) {
            _ = self.failed.fetchAdd(1, .acq_rel);
            return null;
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.failing()) {
            _ = self.failed.fetchAdd(1, .acq_rel);
            return false;
        }
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.failing()) {
            _ = self.failed.fetchAdd(1, .acq_rel);
            return null;
        }
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// What a hydration that never failed answers.
const Expected = struct {
    persons: usize,
    tags: usize,
    nodes: usize,
    edges: usize,
    knows: usize,
    likes: usize,
};

/// Build the pristine store: `PERSONS` Person nodes chained by KNOWS/LIKES
/// relationships (some with a property), and `TAGS` Tag nodes with no
/// relationship (deleted by the double-count check). A full checkpoint
/// writes the IdMap snapshot, so the reopen defers hydration to the first
/// touch; the loop2 product snapshots are then removed, so that touch scans.
fn buildPristine(allocator: std.mem.Allocator, dir: []const u8) !Expected {
    graph_store.setDataDirOverride(allocator, dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    var ids = try allocator.alloc(u64, PERSONS);
    defer allocator.free(ids);
    var name_buf: [32]u8 = undefined;
    for (0..PERSONS) |i| {
        ids[i] = try store.createNodeWithGraph(&.{"Person"}, G);
        try store.setNodeProperty(ids[i], "name", .{ .String = try std.fmt.bufPrint(&name_buf, "p-{d}", .{i}) });
        try store.setNodeProperty(ids[i], "idx", .{ .Int = @intCast(i) });
    }
    for (0..TAGS) |i| {
        const id = try store.createNodeWithGraph(&.{"Tag"}, G);
        try store.setNodeProperty(id, "t", .{ .Int = @intCast(i) });
    }
    var knows: usize = 0;
    var likes: usize = 0;
    for (0..PERSONS - 1) |i| {
        const ty: []const u8 = if (i % 3 == 0) "LIKES" else "KNOWS";
        const eid = try store.createEdgeWithGraph(ids[i], ids[i + 1], ty, G);
        if (i % 4 == 0) try store.setEdgeProperty(eid, "w", .{ .Int = @intCast(i) });
        if (i % 3 == 0) likes += 1 else knows += 1;
    }
    try store.saveToFile();
    graph_store.deinitGlobalStore();
    return .{
        .persons = PERSONS,
        .tags = TAGS,
        .nodes = PERSONS + TAGS,
        .edges = PERSONS - 1,
        .knows = knows,
        .likes = likes,
    };
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

/// Reopen `dir` with the store allocating through `fault`. The graph's
/// hydration is deferred to its first touch (the IdMap snapshot is valid).
fn reopen(allocator: std.mem.Allocator, dir: []const u8, fault: *FaultAllocator) !*graph_store.GraphStore {
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

fn hasLabel(labels: []const []const u8, want: []const u8) bool {
    for (labels) |l| if (std.mem.eql(u8, l, want)) return true;
    return false;
}

fn freeLabels(allocator: std.mem.Allocator, labels: [][]const u8) void {
    for (labels) |l| allocator.free(l);
    allocator.free(labels);
}

/// Every count the graph answers equals `want`; then every Tag node is
/// deleted, and the Tag label must leave the label listing (its
/// tenant-introspection refcount reaches zero only if each Tag node was
/// counted once).
fn expectExact(allocator: std.mem.Allocator, store: *graph_store.GraphStore, want: Expected, what: []const u8) !void {
    graph_store.clearQuarantinedReadError();
    const got = Expected{
        .persons = store.countNodesByLabel(G, "Person", null),
        .tags = store.countNodesByLabel(G, "Tag", null),
        .nodes = try store.countNodesForGraph(G, null),
        .edges = store.countEdgesForGraph(G),
        .knows = store.countEdgesByTypeForGraph(G, "KNOWS"),
        .likes = store.countEdgesByTypeForGraph(G, "LIKES"),
    };
    if (graph_store.takeQuarantinedReadError()) |err| {
        std.debug.print("{s}: the retry failed again: {s}\n", .{ what, @errorName(err) });
        return error.RetryFailed;
    }
    if (!std.meta.eql(got, want)) {
        std.debug.print("{s}: counts after the retry {any}, want {any}\n", .{ what, got, want });
        return error.CountsNotExact;
    }

    const before = try store.listNodeLabels(allocator, null);
    defer freeLabels(allocator, before);
    if (!hasLabel(before, "Tag") or !hasLabel(before, "Person")) {
        std.debug.print("{s}: label listing after the retry lacks Person or Tag\n", .{what});
        return error.LabelListingWrong;
    }
    const tag_ids = try allocator.dupe(u64, store.getNodesByLabel(G, "Tag") orelse &[_]u64{});
    defer allocator.free(tag_ids);
    try testing.expectEqual(want.tags, tag_ids.len);
    for (tag_ids) |id| store.deleteNode(id);
    try testing.expectEqual(@as(usize, 0), store.countNodesByLabel(G, "Tag", null));
    const after = try store.listNodeLabels(allocator, null);
    defer freeLabels(allocator, after);
    if (hasLabel(after, "Tag")) {
        std.debug.print("{s}: every Tag node is deleted and SHOW TABLES still lists Tag: the retry counted Tag nodes twice\n", .{what});
        return error.DoubleCounted;
    }
}

const Variant = struct {
    name: []const u8,
    env: []const [2][*:0]const u8,
};

const variants = [_]Variant{
    .{ .name = "stream scan, pipelined merge", .env = &.{} },
    .{ .name = "stream scan, single-threaded merge", .env = &.{.{ "GEODE_HYDRATION_MERGE_WORKERS", "1" }} },
    .{ .name = "legacy per-node walk", .env = &.{.{ "GEODE_DISABLE_STREAMING_HYDRATION", "1" }} },
};

const fractions = [_]u64{ 2, 15, 35, 55, 75, 90 };

const Fixture = struct {
    base: []u8,
    pristine: []u8,
    work: []u8,
    want: Expected,

    fn init(allocator: std.mem.Allocator, sub_path: []const u8) !Fixture {
        const base = try tmpDirRealpathAlloc(allocator, sub_path);
        errdefer allocator.free(base);
        const pristine = try std.fmt.allocPrint(allocator, "{s}/pristine", .{base});
        errdefer allocator.free(pristine);
        const work = try std.fmt.allocPrint(allocator, "{s}/work", .{base});
        errdefer allocator.free(work);
        try std.Io.Dir.cwd().createDirPath(io(), pristine);
        const want = try buildPristine(allocator, pristine);
        try testing.expect(try removeHydrationSnapshots(allocator, pristine) > 0);
        return .{ .base = base, .pristine = pristine, .work = work, .want = want };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        allocator.free(self.pristine);
        allocator.free(self.work);
    }
};

fn setUp() void {
    graph_store.deinitGlobalStore();
    // Every reopen must scan: no completion persist, no background exact
    // index rebuild racing the crash-style teardown.
    _ = setenv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST", "1", 1);
    geode.graph_storage_adapter.setEagerExactRebuildOnReopenDisabledForTest(true);
}

fn tearDown() void {
    _ = unsetenv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST");
    geode.graph_storage_adapter.setEagerExactRebuildOnReopenDisabledForTest(null);
}

test "SONNY-6605 (1): an allocation failure during hydration is retried on the next access, with exact counts" {
    const allocator = testing.allocator;
    setUp();
    defer tearDown();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx = try Fixture.init(allocator, &tmp.sub_path);
    defer fx.deinit(allocator);

    var failures: usize = 0;
    for (variants) |v| {
        for (v.env) |kv| _ = setenv(kv[0], kv[1], 1);
        defer for (v.env) |kv| {
            _ = unsetenv(kv[0]);
        };

        // The allocations a clean hydration of this store makes.
        var fault = FaultAllocator{ .child = std.heap.smp_allocator };
        try copyOf(fx.pristine, fx.work);
        const clean_allocs = blk: {
            const store = try reopen(allocator, fx.work, &fault);
            defer close(allocator);
            const before = fault.count.load(.acquire);
            _ = store.countNodesByLabel(G, "Person", null);
            const n = fault.count.load(.acquire) - before;
            try expectExact(allocator, store, fx.want, v.name);
            break :blk n;
        };
        try testing.expect(clean_allocs > 100);

        for (fractions) |pct| {
            var label_buf: [96]u8 = undefined;
            const what = try std.fmt.bufPrint(&label_buf, "{s}, failing from {d}% of a clean hydration's allocations", .{ v.name, pct });
            var f = FaultAllocator{ .child = std.heap.smp_allocator };
            try copyOf(fx.pristine, fx.work);
            const store = try reopen(allocator, fx.work, &f);
            defer close(allocator);

            graph_store.clearQuarantinedReadError();
            f.arm(clean_allocs * pct / 100);
            _ = store.countNodesByLabel(G, "Person", null);
            f.disarm();
            const noted = graph_store.takeQuarantinedReadError();
            try testing.expect(f.failed.load(.acquire) > 0);

            if (noted == null or noted.? != error.OutOfMemory) {
                failures += 1;
                std.debug.print("{s}: the failed hydration noted {s}, want OutOfMemory\n", .{ what, if (noted) |e| @errorName(e) else "nothing" });
                continue;
            }
            if (store.graphQuarantineError(G)) |qerr| {
                failures += 1;
                std.debug.print("{s}: the graph is quarantined ({s}) after an allocation failure\n", .{ what, @errorName(qerr) });
                continue;
            }
            expectExact(allocator, store, fx.want, what) catch |err| {
                failures += 1;
                std.debug.print("{s}: {s}\n", .{ what, @errorName(err) });
            };
        }
    }
    if (failures > 0) {
        std.debug.print("SONNY-6605 (1): {d} failed hydration(s) were not retried cleanly\n", .{failures});
        return error.TransientHydrationFailureNotRetried;
    }
}

fn ask(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) union(enum) { count: i64, failed: anyerror } {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = geode.parseGql(q, allocator) catch |err| return .{ .failed = err };
    defer parsed.deinit();
    const catalog = execution.ensureCatalogInstance(allocator) catch |err| return .{ .failed = err };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session }) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    if (result.rows.len != 1 or result.rows[0].len != 1) return .{ .failed = error.UnexpectedShape };
    return switch (result.rows[0][0]) {
        .Int => |n| .{ .count = n },
        else => .{ .failed = error.UnexpectedShape },
    };
}

test "SONNY-6605 (1): a statement whose hydration runs out of memory fails with 53200, and the next one answers" {
    const allocator = testing.allocator;
    setUp();
    defer tearDown();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx = try Fixture.init(allocator, &tmp.sub_path);
    defer fx.deinit(allocator);

    var counting = FaultAllocator{ .child = std.heap.smp_allocator };
    try copyOf(fx.pristine, fx.work);
    const clean_allocs = blk: {
        const store = try reopen(allocator, fx.work, &counting);
        defer close(allocator);
        const before = counting.count.load(.acquire);
        try testing.expectEqual(fx.want.persons, store.countNodesByLabel(G, "Person", null));
        break :blk counting.count.load(.acquire) - before;
    };

    var fault = FaultAllocator{ .child = std.heap.smp_allocator };
    try copyOf(fx.pristine, fx.work);
    _ = try reopen(allocator, fx.work, &fault);
    defer close(allocator);
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    const q = "USE GRAPH " ++ G ++ "; MATCH (n:Person) RETURN count(n) AS c";

    fault.arm(clean_allocs / 2);
    const first = ask(allocator, &session, q);
    fault.disarm();
    try testing.expect(fault.failed.load(.acquire) > 0);
    switch (first) {
        .count => |n| {
            std.debug.print("the statement whose hydration ran out of memory answered {d}\n", .{n});
            return error.AnsweredFromFailedHydration;
        },
        .failed => |err| {
            const info = proto_util.mapError(err);
            std.debug.print("SONNY-6605 (1): failed hydration -> {s} {s}\n", .{ info.code, @errorName(err) });
            try testing.expect(err == error.OutOfMemory);
            try testing.expectEqualStrings("53200", info.code);
        },
    }

    switch (ask(allocator, &session, q)) {
        .count => |n| try testing.expectEqual(@as(i64, @intCast(fx.want.persons)), n),
        .failed => |err| {
            std.debug.print("the statement after the failed hydration failed: {s}\n", .{@errorName(err)});
            return err;
        },
    }
    try testing.expect(graph_store.quarantineErrorForGraph(allocator, G) == null);
}

/// Zero every written page of every nodes.store under `data_dir` (as
/// test-sonny6541-quarantine-first-read does) and empty labels.idx.
fn damage(data_dir: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var zeroed: usize = 0;
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "labels.idx")) {
            var file = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
            defer file.close(io());
            try file.setLength(io(), 0);
            continue;
        }
        if (!std.mem.eql(u8, entry.basename, "nodes.store")) continue;
        var file = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
        defer file.close(io());
        const len = try file.length(io());
        var page: u64 = 0;
        while ((page + 1) * PAGE_SIZE <= len) : (page += 1) {
            var header: [32]u8 = undefined;
            _ = try file.readPositionalAll(io(), &header, page * PAGE_SIZE);
            if (std.mem.allEqual(u8, &header, 0)) continue;
            const zeros = [_]u8{0} ** PAGE_SIZE;
            try file.writePositionalAll(io(), &zeros, page * PAGE_SIZE);
            zeroed += 1;
        }
    }
    return zeroed;
}

test "SONNY-6605 (1): a damaged store is still quarantined, and is not scanned again" {
    const allocator = testing.allocator;
    setUp();
    defer tearDown();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx = try Fixture.init(allocator, &tmp.sub_path);
    defer fx.deinit(allocator);
    try testing.expect(try damage(fx.pristine) > 0);

    var fault = FaultAllocator{ .child = std.heap.smp_allocator };
    try copyOf(fx.pristine, fx.work);
    const store = try reopen(allocator, fx.work, &fault);
    defer close(allocator);

    graph_store.clearQuarantinedReadError();
    _ = store.countNodesByLabel(G, "Person", null);
    const noted = graph_store.takeQuarantinedReadError() orelse return error.DamageNotNoted;
    std.debug.print("SONNY-6605 (1): damaged store -> {s}\n", .{@errorName(noted)});
    const corruption = noted == error.DataCorruption or noted == error.ChecksumMismatch or noted == error.InvalidData;
    try testing.expect(corruption);
    try testing.expect((store.graphQuarantineError(G) orelse return error.NotQuarantined) == noted);

    // Quarantined: the next access fails with the same error and does not
    // scan the store again.
    const scanned = graph_store.loop2ScanNodeCount();
    _ = store.countNodesByLabel(G, "Person", null);
    try testing.expectEqual(scanned, graph_store.loop2ScanNodeCount());
    try testing.expect((store.graphQuarantineError(G) orelse return error.NotQuarantined) == noted);
    graph_store.clearQuarantinedReadError();
}
