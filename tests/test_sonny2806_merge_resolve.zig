// SONNY-2806 (round 8): how MERGE's property index finds the holders of an
// entry it cannot trust (unresolved: the lowest holder of its key was
// removed while others may remain; or naming a deleted node).
//
// Round 7 scanned the entry's label under the graph lock: 72 ms per key at
// 200,000 nodes in the re-review's probe, about 5 s per key at 14.27M. A
// lookup now reads the exact node-property index, which lists the nodes
// holding each value, so the cost is the key's holders. It scans the label
// only when that index cannot answer: in lean mode (where it holds no value
// of a key registered after its nodes were written) and while it is
// deferred or being rebuilt after a reopen, when the lookup scans rather
// than wait, under the graph lock, for a build that can run for minutes.
//
// A settle that read every holder through the exact index and found one
// records it alone again, so the entry's "shared" flag clears.
//
// Also: a persisted public id with bit 63 set (the bit MERGE's index uses as
// a flag) is refused.
//
// CANARY: REQ=REQ-SONNY-2806-MERGE-RESOLVE-EXACT; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2806_merge_resolve.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const gsa = geode.graph_storage_adapter;
const Value = geode.value_types.Value;
const PropertyValue = graph_store.PropertyValue;
const G = graph_store.DEFAULT_GRAPH_NAME;

const Param = struct { name: []const u8, value: Value };

const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init() !Session {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.NoAdapter;
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = .{ .catalog = catalog },
        };
    }

    fn close(self: *Session) void {
        _ = self;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
    }

    fn open(self: *Session) !void {
        const allocator = testing.allocator;
        graph_store.resetLazyHydrateCounters();
        graph_store.setDataDirOverride(allocator, self.data_dir);
        _ = graph_store.getGlobalStore(allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(allocator) };
    }

    fn deinit(self: *Session) void {
        self.close();
        self.arena.deinit();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Session, query: []const u8, params: []const Param) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const names = try aa.alloc([]const u8, params.len);
        const values = try aa.alloc(Value, params.len);
        for (params, names, values) |p, *n, *v| {
            n.* = p.name;
            v.* = p.value;
        }
        var ctx = self.ctx;
        ctx.query_param_names = names;
        ctx.query_param_values = values;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    fn exec(self: *Session, query: []const u8, params: []const Param) !void {
        var r = try self.run(query, params);
        r.deinit(self.arena.allocator());
    }

    /// The single cell `query` returns, as text.
    fn cell(self: *Session, query: []const u8, params: []const Param) ![]const u8 {
        const aa = self.arena.allocator();
        var r = try self.run(query, params);
        defer r.deinit(aa);
        if (r.rows.len != 1 or r.rows[0].len != 1) return error.NotOneCell;
        return switch (r.rows[0][0]) {
            .Str => |s| try aa.dupe(u8, s),
            .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
            .Null => "null",
            else => |v| try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
        };
    }
};

fn store() *graph_store.GraphStore {
    return graph_store.getGlobalStore(testing.allocator);
}

fn tOf(id: u64) []const u8 {
    const v = store().getNodeProperty(id, "t") orelse return "";
    return switch (v) {
        .String => |t| t,
        else => "?",
    };
}

fn decParam(v: i64) Value {
    return .{ .Decimal = .{ .coeff = @as(i128, v) * 10, .scale = 1, .orig_scale = 1, .orig_repr = null } };
}

/// For each of `k` keys of :`label`: 'lo' (INT v, the lower id) and 'hi'
/// (DECIMAL v.0), which share MERGE's key, then 'lo' deleted, leaving the
/// entry unresolved with 'hi' its only holder.
fn seedUnresolved(s: *Session, label: []const u8, k: usize) !void {
    const aa = s.arena.allocator();
    const create_lo = try std.fmt.allocPrint(aa, "CREATE (:{s} {{x: $v, t: 'lo'}})", .{label});
    const create_hi = try std.fmt.allocPrint(aa, "CREATE (:{s} {{x: $d, t: 'hi'}})", .{label});
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const v: i64 = 5_000_000 + @as(i64, @intCast(i));
        try s.exec(create_lo, &.{.{ .name = "v", .value = .{ .Int = v } }});
        try s.exec(create_hi, &.{.{ .name = "d", .value = decParam(v) }});
    }
    try s.exec(try std.fmt.allocPrint(aa, "MATCH (n:{s} {{t: 'lo'}}) DELETE n", .{label}), &.{});
}

test "SONNY-2806: an unresolved entry is settled through the exact index, not a label scan" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    const k: usize = 10;
    try s.exec("FOR i IN range(1, 2000) CREATE (:SC {f: i})", &.{});
    try seedUnresolved(&s, "SC", k);

    graph_store.resetMergeResolveCounts();
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const v: i64 = 5_000_000 + @as(i64, @intCast(i));
        const pv = [_]Param{.{ .name = "v", .value = .{ .Int = v } }};
        if (i % 2 == 0) {
            try testing.expectEqualStrings("hi", try s.cell("MERGE (n:SC {x: $v}) RETURN n.t AS t", &pv));
        } else {
            const r = try adapter.bulkMergeNode(G, "SC", "x", .{ .Int = v }, &.{}, null, false);
            try testing.expect(!r.wrote);
            try testing.expectEqualStrings("hi", tOf(r.id));
        }
        // 'hi' is the key's only holder: the entry names it alone again.
        var id: u64 = 0;
        try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, store().lookupOnlyMergeHolder(G, "SC", "x", .{ .Int = v }, &id));
        try testing.expectEqualStrings("hi", tOf(id));
    }
    const counts = graph_store.mergeResolveCounts();
    try testing.expectEqual(@as(u64, 0), counts.scan);
    try testing.expect(counts.exact >= k);
    // 1999 filler nodes (range stops before its end) and the 10 'hi' nodes.
    try testing.expectEqualStrings("2009", try s.cell("MATCH (n:SC) RETURN count(n) AS c", &.{}));

    // A number that is not an integer (not in MERGE's index): the server's
    // MERGE finds it through the exact index too.
    try s.exec("CREATE (:SD {x: 2.5, t: 'dec'})", &.{});
    graph_store.resetMergeResolveCounts();
    const r = try adapter.bulkMergeNode(G, "SD", "x", .{ .Float = 2.5 }, &.{}, null, false);
    try testing.expect(!r.wrote);
    try testing.expectEqualStrings("dec", tOf(r.id));
    try testing.expectEqual(@as(u64, 0), graph_store.mergeResolveCounts().scan);
    try testing.expectEqual(@as(u64, 1), graph_store.mergeResolveCounts().exact);
}

test "SONNY-2806: in lean mode an unresolved entry is settled by a label scan" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);
    graph_store.registerMergeIndexKey("x");

    try seedUnresolved(&s, "SL", 3);
    graph_store.resetMergeResolveCounts();
    try testing.expectEqualStrings("hi", try s.cell("MERGE (n:SL {x: 5000001}) RETURN n.t AS t", &.{}));
    const counts = graph_store.mergeResolveCounts();
    try testing.expectEqual(@as(u64, 0), counts.exact);
    try testing.expect(counts.scan >= 1);
    try testing.expectEqualStrings("3", try s.cell("MATCH (n:SL) RETURN count(n) AS c", &.{}));
}

fn deleteAllNamed(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, name)) {
            try dir.deleteFile(io, entry.path);
            n += 1;
        }
    }
    return n;
}

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const Lookup = struct {
    v: i64,
    result: graph_store.GraphStore.MergeLookupResult = .not_indexable,
    id: u64 = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(c: *Lookup) void {
        c.result = store().lookupMergeCandidate(G, "GR", "x", .{ .Int = c.v }, &c.id);
        c.done.store(true, .release);
    }
};

test "SONNY-2806: while the exact index is rebuilt, a lookup settles by a label scan and does not wait for the build" {
    harness.silenceEngineLogs();
    const allocator = testing.allocator;
    var s = try Session.init();
    defer s.deinit();
    try s.exec("FOR i IN range(1, 500) CREATE (:GR {f: i})", &.{});
    try seedUnresolved(&s, "GR", 3);
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    // The merge index, its unresolved entries included, goes to
    // hydration_merge.snap; the reopen loads it.
    try adapter.checkpointAll();
    s.close();
    // With no persisted exact index, the reopen rebuilds it on a background
    // thread, held at the test gate.
    try testing.expect(try deleteAllNamed(allocator, s.data_dir, "prop_exact.idx") >= 1);
    gsa.resetExactReopenSpawnsForTesting();
    gsa.resetExactHydrationBuildsForTesting();
    gsa.closeExactBuildGateForTesting();
    defer gsa.openExactBuildGateForTesting();
    try s.open();
    const reopened = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    _ = try reopened.getOrCreateGraph(G);
    try testing.expect(gsa.getExactReopenSpawnsForTesting() >= 1);

    graph_store.resetMergeResolveCounts();
    var lookup = Lookup{ .v = 5_000_001 };
    const t = try std.Thread.spawn(.{}, Lookup.run, .{&lookup});
    var waited: usize = 0;
    while (!lookup.done.load(.acquire) and waited < 30_000) : (waited += 1) sleepMs(1);
    const returned = lookup.done.load(.acquire);
    // Release the build either way, so a lookup that waits on it returns.
    gsa.openExactBuildGateForTesting();
    t.join();
    try testing.expect(returned);
    try testing.expect(graph_store.hydrationSnapshotLoadCount() >= 1);
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, lookup.result);
    try testing.expectEqualStrings("hi", tOf(lookup.id));
    const counts = graph_store.mergeResolveCounts();
    try testing.expectEqual(@as(u64, 0), counts.exact);
    try testing.expectEqual(@as(u64, 1), counts.scan);

    // Once the build is done, a lookup settles through the exact index.
    waited = 0;
    while (gsa.getExactHydrationBuildsForTesting() == 0 and waited < 120_000) : (waited += 1) sleepMs(1);
    try testing.expect(gsa.getExactHydrationBuildsForTesting() >= 1);
    graph_store.resetMergeResolveCounts();
    var id: u64 = 0;
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, store().lookupMergeCandidate(G, "GR", "x", .{ .Int = 5_000_002 }, &id));
    try testing.expectEqualStrings("hi", tOf(id));
    try testing.expectEqual(@as(u64, 1), graph_store.mergeResolveCounts().exact);
    try testing.expectEqualStrings("502", try s.cell("MATCH (n:GR) RETURN count(n) AS c", &.{}));
}

test "SONNY-2806: a persisted public id with bit 63 set is refused" {
    harness.silenceEngineLogs();
    try testing.expectEqual(@as(?u64, 0x7fff_ffff_ffff_ffff), graph_store.parsePersistedPublicId("7fffffffffffffff"));
    try testing.expectEqual(@as(?u64, 0x0192_3456_7000_0001), graph_store.parsePersistedPublicId("0192345670000001"));
    try testing.expectEqual(@as(?u64, null), graph_store.parsePersistedPublicId("8000000000000001"));
    try testing.expectEqual(@as(?u64, null), graph_store.parsePersistedPublicId("ffffffffffffffff"));
    try testing.expectEqual(@as(?u64, null), graph_store.parsePersistedPublicId("not an id"));
}
