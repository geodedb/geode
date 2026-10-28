// SONNY-2806 (round 8): the duplicate paths the round-7 re-review found in
// MERGE's property index (graph_store.merge_prop_index) and the server's
// bulk MERGE, each from one of the review's probe phases.
//
//   * race2: a lookup that settles an unresolved entry (the lowest holder of
//     its key was removed while others may remain) ran a label scan, then
//     dropped the entry when the scan found no holder. A holder inserted
//     during the scan left the unresolved entry as it was, so the settle
//     could not see it, and the entry of a live holder was lost; the next
//     MERGE created a second node. Lookups run under SHARED graph locks (the
//     QUIC edge fast path's `lookupNodeByMergeKey`, the group-commit
//     workers), so an insert can land inside the scan. 40 of 40 trials lost
//     the entry. The lookup and the insert start at a spin barrier, the
//     insert after a few microseconds of spinning (the round-8 re-review's
//     race3): through the exact index the lookup takes ~80 us, and a writer
//     that slept its delay started after the lookup had ended.
//   * race1: two bulk MERGEs of one value in two forms (INT 7 and
//     DECIMAL 7.0; DOUBLE 7.5 and DECIMAL 7.5) took different per-tuple
//     locks, since the lock was chosen by the value's representation, and
//     both created a node (6000 nodes for 3000 keys).
//   * lean: with GEODE_INDEX_MERGE_KEYS_ONLY=1, the server's MERGE of a
//     number that is not an integer trusted the exact node-property index,
//     which holds no value of a key registered after its nodes were
//     written, and created a second node.
//
// Also: a string and a boolean (or an integer) no longer share a merge key,
// so the server's MERGE of `true` does not match a stored 'true'.
//
// CANARY: REQ=REQ-SONNY-2806-MERGE-RACES; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2806_merge_races.zig; OWNER=storage; UPDATED=2026-09-27

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
const PropKV = gsa.StorageAdapter.PropKV;
const G = graph_store.DEFAULT_GRAPH_NAME;

const Param = struct { name: []const u8, value: Value };

/// A persisted store in a temporary directory, as the server runs.
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

    fn deinit(self: *Session) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
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

    /// The single integer cell `query` returns.
    fn int(self: *Session, query: []const u8, params: []const Param) !i64 {
        var r = try self.run(query, params);
        defer r.deinit(self.arena.allocator());
        if (r.rows.len != 1 or r.rows[0].len != 1 or r.rows[0][0] != .Int) return error.NotOneInteger;
        return r.rows[0][0].Int;
    }

    fn count(self: *Session, label: []const u8) !i64 {
        const q = try std.fmt.allocPrint(self.arena.allocator(), "MATCH (n:{s}) RETURN count(n) AS c", .{label});
        return self.int(q, &.{});
    }
};

fn adapterOrFail() !*gsa.StorageAdapter {
    return graph_store.getGlobalAdapter() orelse error.NoAdapter;
}

fn store() *graph_store.GraphStore {
    return graph_store.getGlobalStore(testing.allocator);
}

/// The `t` property of node `id`, or "" when it has none.
fn tOf(id: u64) []const u8 {
    const v = store().getNodeProperty(id, "t") orelse return "";
    return switch (v) {
        .String => |t| t,
        else => "?",
    };
}

fn dec(coeff: i128, scale: u8) PropertyValue {
    return .{ .Decimal = .{ .coeff = coeff, .scale = scale } };
}

/// Every failed check, reported together.
const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, fmt, args));
    }

    fn deinit(self: *Failures) void {
        for (self.items.items) |msg| testing.allocator.free(msg);
        self.items.deinit(testing.allocator);
    }

    fn check(self: *Failures, name: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.MergeDuplicated;
    }
};

// ---------------------------------------------------------------------------
// race1: one value, two forms, two concurrent bulk MERGEs
// ---------------------------------------------------------------------------

test "SONNY-2806: equal values in two forms take one MERGE tuple lock" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const ext_double = try geode.property_value_codec.valueToPropertyValue(aa, .{ .Double = 7.5 });
    const ext_small = try geode.property_value_codec.valueToPropertyValue(aa, .{ .SmallInt = 7 });
    const pairs = [_][2]PropertyValue{
        .{ .{ .Int = 7 }, dec(70, 1) },
        .{ .{ .Int = 7 }, .{ .Float = 7.0 } },
        .{ .{ .Int = 7 }, ext_small },
        .{ .{ .Float = 7.5 }, dec(750, 2) },
        .{ ext_double, dec(75, 1) },
        .{ .{ .Float = 0.0 }, .{ .Float = -0.0 } },
    };
    for (pairs) |p| {
        const a = [_]PropKV{.{ .key = "k", .value = p[0] }};
        const b = [_]PropKV{.{ .key = "k", .value = p[1] }};
        try testing.expectEqual(gsa.mergeTupleLockIndexForTest("RC", &a), gsa.mergeTupleLockIndexForTest("RC", &b));
        // A composite tuple too, in either order.
        const ma = [_]PropKV{ .{ .key = "k", .value = p[0] }, .{ .key = "s", .value = .{ .String = "x" } } };
        const mb = [_]PropKV{ .{ .key = "s", .value = .{ .String = "x" } }, .{ .key = "k", .value = p[1] } };
        try testing.expectEqual(gsa.mergeTupleLockIndexForTest("RC", &ma), gsa.mergeTupleLockIndexForTest("RC", &mb));
    }
}

const Race1 = struct {
    adapter: *gsa.StorageAdapter,
    label: []const u8,
    n: usize,
    which: u8,
    arrive: *std.atomic.Value(u64),
    errs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn value(which: u8, i: usize) PropertyValue {
        const ii: i64 = @intCast(i);
        return switch (which) {
            0 => .{ .Int = ii },
            1 => dec(@as(i128, ii) * 10, 1),
            2 => .{ .Float = @as(f64, @floatFromInt(ii)) + 0.5 },
            else => dec(@as(i128, ii) * 10 + 5, 1),
        };
    }

    fn worker(c: *Race1) void {
        var i: usize = 0;
        while (i < c.n) : (i += 1) {
            // Both threads MERGE key i at the same moment.
            _ = c.arrive.fetchAdd(1, .acq_rel);
            const target: u64 = @as(u64, @intCast(i + 1)) * 2;
            while (c.arrive.load(.acquire) < target) std.atomic.spinLoopHint();
            _ = c.adapter.bulkMergeNodeWithReservedId(G, store().reserveNodeId(), c.label, "k", value(c.which, i), &.{}, false) catch {
                _ = c.errs.fetchAdd(1, .monotonic);
            };
        }
    }
};

test "SONNY-2806: concurrent bulk MERGEs of one value in two forms create one node" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const adapter = try adapterOrFail();
    var f: Failures = .{};
    defer f.deinit();

    const n: usize = 400;
    const pairs = [_]struct { label: []const u8, a: u8, b: u8 }{
        .{ .label = "RC", .a = 0, .b = 1 }, // INT i and DECIMAL i.0: MERGE's index
        .{ .label = "RD", .a = 2, .b = 3 }, // DOUBLE i.5 and DECIMAL i.5: the exact index
    };
    for (pairs) |p| {
        var arrive = std.atomic.Value(u64).init(0);
        var ca = Race1{ .adapter = adapter, .label = p.label, .n = n, .which = p.a, .arrive = &arrive };
        var cb = Race1{ .adapter = adapter, .label = p.label, .n = n, .which = p.b, .arrive = &arrive };
        const ta = try std.Thread.spawn(.{}, Race1.worker, .{&ca});
        const tb = try std.Thread.spawn(.{}, Race1.worker, .{&cb});
        ta.join();
        tb.join();
        if (ca.errs.load(.monotonic) + cb.errs.load(.monotonic) != 0) try f.add("{s}: {d} bulk MERGE errors", .{ p.label, ca.errs.load(.monotonic) + cb.errs.load(.monotonic) });
        const nodes = try s.count(p.label);
        if (nodes != n) try f.add("{s}: {d} nodes for {d} keys", .{ p.label, nodes, n });
    }
    try f.check("race1");
}

// ---------------------------------------------------------------------------
// race2: an insert during a lookup's settle
// ---------------------------------------------------------------------------

const Race2 = struct {
    adapter: *gsa.StorageAdapter,
    v: i64,
    delay_ns: u64,
    /// The spin barrier: both threads arrive, then start together.
    arrive: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    insert_err: ?anyerror = null,
    /// When the lookup and the insert ran (monotonic ns), to count the
    /// trials whose insert overlapped the lookup.
    lookup_start: u64 = 0,
    lookup_end: u64 = 0,
    insert_start: u64 = 0,
    insert_end: u64 = 0,

    fn arriveAndWait(c: *Race2) void {
        _ = c.arrive.fetchAdd(1, .acq_rel);
        while (c.arrive.load(.acquire) < 2) std.atomic.spinLoopHint();
    }

    fn reader(c: *Race2) void {
        c.arriveAndWait();
        const h = graph_store.acquireGraphReadLockTagged(G, .bulk_merge);
        defer graph_store.releaseGraphLock(h);
        c.lookup_start = monoNs();
        _ = c.adapter.lookupNodeByMergeKey(G, "SR", "x", .{ .Int = c.v }, error.MergeCandidateMissing) catch {};
        c.lookup_end = monoNs();
    }

    fn writer(c: *Race2) void {
        c.arriveAndWait();
        // Microsecond jitter by spinning: a sleep's wake-up latency (tens of
        // microseconds or more) exceeds the lookup (~80 us through the exact
        // index), so a sleeping writer inserted after the lookup had ended.
        const t0 = monoNs();
        while (monoNs() - t0 < c.delay_ns) std.atomic.spinLoopHint();
        const props = [_]PropKV{ .{ .key = "x", .value = .{ .Int = c.v } }, .{ .key = "t", .value = .{ .String = "c" } } };
        c.insert_start = monoNs();
        _ = c.adapter.bulkInsertNodeWithReservedId(G, store().reserveNodeId(), &[_][]const u8{"SR"}, &props) catch |e| {
            c.insert_err = e;
        };
        c.insert_end = monoNs();
    }

    fn overlapped(c: *const Race2) bool {
        return c.insert_start < c.lookup_end and c.insert_end > c.lookup_start;
    }
};

fn monoNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Nodes of :SR holding `v` (the `+ 0` keeps the query off every index).
fn holders(s: *Session, v: i64) !i64 {
    return s.int("MATCH (n:SR) WHERE n.x + 0 = $v RETURN count(n) AS c", &.{.{ .name = "v", .value = .{ .Int = v } }});
}

fn race2(s: *Session, f: *Failures, tag: []const u8, filler: i64, trials: usize, step_ns: u64) !void {
    const adapter = try adapterOrFail();
    if (filler > 0) try s.exec("FOR i IN range(1, $n) CREATE (:SR {f: i})", &.{.{ .name = "n", .value = .{ .Int = filler } }});
    var overlapping: usize = 0;
    var j: usize = 0;
    while (j < trials) : (j += 1) {
        const v: i64 = 1_000_000 + @as(i64, @intCast(j));
        const pv = [_]Param{.{ .name = "v", .value = .{ .Int = v } }};
        // Two holders of v; delete both. The entry is left unresolved
        // (its lowest holder went while another held the key) with no
        // holder at all.
        try s.exec("CREATE (:SR {x: $v, t: 'a'})", &pv);
        try s.exec("CREATE (:SR {x: $d, t: 'b'})", &.{.{ .name = "d", .value = .{ .Decimal = .{ .coeff = @as(i128, v) * 10, .scale = 1, .orig_scale = 1, .orig_repr = null } } }});
        try s.exec("MATCH (n:SR {t: 'a'}) WHERE n.x + 0 = $v DELETE n", &pv);
        try s.exec("MATCH (n:SR {t: 'b'}) WHERE n.x + 0 = $v DELETE n", &pv);
        // A lookup under a SHARED lock settles the entry while a writer
        // inserts a new holder.
        // The writer starts 0, 1, 2, ... steps after the lookup does.
        var c = Race2{ .adapter = adapter, .v = v, .delay_ns = @as(u64, @intCast(j)) * step_ns };
        const tr = try std.Thread.spawn(.{}, Race2.reader, .{&c});
        const tw = try std.Thread.spawn(.{}, Race2.writer, .{&c});
        tr.join();
        tw.join();
        if (c.insert_err) |e| {
            try f.add("[{s}] trial {d}: insert failed: {s}", .{ tag, j, @errorName(e) });
            continue;
        }
        if (c.overlapped()) overlapping += 1;
        var id: u64 = 0;
        const after = store().lookupMergeCandidate(G, "SR", "x", .{ .Int = v }, &id);
        if (after != .found or !std.mem.eql(u8, tOf(id), "c")) try f.add("[{s}] trial {d}: MERGE's index lost the new holder ({s})", .{ tag, j, @tagName(after) });
        try s.exec("MERGE (:SR {x: $v})", &pv);
        const n = try holders(s, v);
        if (n != 1) try f.add("[{s}] trial {d}: MERGE after the race left {d} holders", .{ tag, j, n });
    }
    // The race was run: some insert overlapped its lookup. Not claimed on a
    // contended CI runner (CI set), where the threads' timing is not the
    // test's to decide.
    if (overlapping == 0 and std.c.getenv("CI") == null) try f.add("[{s}] no insert overlapped its lookup in {d} trials", .{ tag, trials });
}

test "SONNY-2806: a lookup does not drop the entry of a holder inserted while it settles" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    {
        // Lean mode: the settle scans the label, a window of milliseconds.
        var s = try Session.init();
        defer s.deinit();
        graph_store.setLeanIndexingForTest(true);
        defer graph_store.setLeanIndexingForTest(false);
        graph_store.registerMergeIndexKey("x");
        // A label scan of 20,000 nodes: steps of 500 us.
        try race2(&s, &f, "lean", 20_000, 12, 500 * std.time.ns_per_us);
    }
    {
        // The default: the settle reads the exact node-property index.
        var s = try Session.init();
        defer s.deinit();
        // The exact index answers in ~80 us: steps of 4 us.
        try race2(&s, &f, "default", 0, 12, 4 * std.time.ns_per_us);
    }
    try f.check("race2");
}

// ---------------------------------------------------------------------------
// lean: a key registered after its nodes were written
// ---------------------------------------------------------------------------

fn expectMatch(f: *Failures, what: []const u8, res: anyerror!gsa.StorageAdapter.MergeResult, want_t: []const u8) !void {
    const r = res catch |err| {
        try f.add("{s}: error {s}", .{ what, @errorName(err) });
        return;
    };
    if (r.wrote) try f.add("{s}: created a node (t='{s}'), expected the one with t='{s}'", .{ what, tOf(r.id), want_t });
    if (!r.wrote and !std.mem.eql(u8, tOf(r.id), want_t)) try f.add("{s}: matched t='{s}', expected '{s}'", .{ what, tOf(r.id), want_t });
}

fn expectCreate(f: *Failures, what: []const u8, res: anyerror!gsa.StorageAdapter.MergeResult) !void {
    const r = res catch |err| {
        try f.add("{s}: error {s}", .{ what, @errorName(err) });
        return;
    };
    if (!r.wrote) try f.add("{s}: matched t='{s}', expected a new node", .{ what, tOf(r.id) });
}

test "SONNY-2806: in lean mode the server's MERGE finds a number that is not an integer" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    const adapter = try adapterOrFail();
    const aa = s.arena.allocator();
    var f: Failures = .{};
    defer f.deinit();

    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);
    defer graph_store.clearCompositeMergeKeysForTest();

    // Written before any MERGE registers `x`, `a` or `b`: lean mode indexes
    // neither in the exact index.
    try s.exec("CREATE (:LN {x: 1.5, t: 'created'})", &.{});
    try s.exec("CREATE (:LN2 {x: 1.5, t: 'created'})", &.{});
    try s.exec("CREATE (:LM {a: 1.5, b: 'k', t: 'created'})", &.{});

    const dbl = try geode.property_value_codec.valueToPropertyValue(aa, .{ .Double = 1.5 });
    try expectMatch(&f, "reserved-id MERGE (:LN {x: DOUBLE 1.5})", adapter.bulkMergeNodeWithReservedId(G, store().reserveNodeId(), "LN", "x", dbl, &.{}, false), "created");
    try expectMatch(&f, "direct MERGE (:LN2 {x: DECIMAL 1.50})", adapter.bulkMergeNode(G, "LN2", "x", dec(150, 2), &.{}, null, false), "created");
    const mp = [_]PropKV{ .{ .key = "a", .value = dbl }, .{ .key = "b", .value = .{ .String = "k" } } };
    try expectMatch(&f, "multi-property MERGE (:LM {a: DOUBLE 1.5, b: 'k'})", adapter.bulkMergeNodeWithReservedIdMultiProp(G, store().reserveNodeId(), "LM", &mp, &.{}, false), "created");
    // A new value is created once, then found.
    try expectCreate(&f, "MERGE (:LN {x: 2.75})", adapter.bulkMergeNode(G, "LN", "x", dec(275, 2), &.{}, null, false));
    const again = adapter.bulkMergeNode(G, "LN", "x", dec(2750, 3), &.{}, null, false) catch |err| blk: {
        try f.add("MERGE (:LN {{x: 2.750}}): error {s}", .{@errorName(err)});
        break :blk null;
    };
    if (again) |r| if (r.wrote) try f.add("MERGE (:LN {{x: 2.750}}): created a second node", .{});

    for ([_][]const u8{ "LN", "LN2", "LM" }, [_]i64{ 2, 1, 1 }) |label, want| {
        const got = try s.count(label);
        if (got != want) try f.add("{s}: {d} nodes, expected {d}", .{ label, got, want });
    }
    try f.check("lean");
}

// ---------------------------------------------------------------------------
// A string does not share a key with a boolean or an integer
// ---------------------------------------------------------------------------

test "SONNY-2806: the server's MERGE of true does not match a stored 'true'" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    const adapter = try adapterOrFail();
    var f: Failures = .{};
    defer f.deinit();

    try s.exec("CREATE (:TB {x: 'true', t: 'str'})", &.{});
    try expectCreate(&f, "MERGE (:TB {x: true}) over a stored 'true'", adapter.bulkMergeNode(G, "TB", "x", .{ .Bool = true }, &.{}, null, false));
    try s.exec("CREATE (:TB2 {x: false, t: 'bool'})", &.{});
    try expectCreate(&f, "MERGE (:TB2 {x: 'false'}) over a stored false", adapter.bulkMergeNode(G, "TB2", "x", .{ .String = "false" }, &.{}, null, false));
    // The integer 7 keyed as 'I' and its eight bytes, the same bytes as
    // this string.
    var bytes: [9]u8 = undefined;
    bytes[0] = 'I';
    std.mem.writeInt(i64, bytes[1..9], 7, .little);
    try s.exec("CREATE (:TI {x: $s, t: 'str'})", &.{.{ .name = "s", .value = .{ .Str = &bytes } }});
    try expectCreate(&f, "MERGE (:TI {x: 7}) over a stored string", adapter.bulkMergeNode(G, "TI", "x", .{ .Int = 7 }, &.{}, null, false));

    // A string and a boolean holding one key, then the boolean deleted: the
    // string is still found, and the boolean is not.
    try s.exec("CREATE (:TC {x: true, t: 'bool'})", &.{});
    try s.exec("CREATE (:TC {x: 'true', t: 'str'})", &.{});
    try s.exec("MATCH (n:TC {t: 'bool'}) DELETE n", &.{});
    try expectMatch(&f, "MERGE (:TC {x: 'true'})", adapter.bulkMergeNode(G, "TC", "x", .{ .String = "true" }, &.{}, null, false), "str");
    try expectCreate(&f, "MERGE (:TC {x: true})", adapter.bulkMergeNode(G, "TC", "x", .{ .Bool = true }, &.{}, null, false));

    for ([_][]const u8{ "TB", "TB2", "TI", "TC" }) |label| {
        const got = try s.count(label);
        if (got != 2) try f.add("{s}: {d} nodes, expected 2", .{ label, got });
    }
    try f.check("key types");
}
