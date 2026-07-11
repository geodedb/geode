// CANARY: REQ=REQ-PERF-QPS-H3P3; FEATURE="OrderedScanFastPath"; ASPECT=PlannerIndexOrdered; STATUS=TESTED; TEST=tests/test_ordered_scan_fastpath.zig; OWNER=performance; UPDATED=2026-06-29
//
// H3-P3 regression test: `MATCH (n:T) RETURN n.k ORDER BY n.k [DESC] LIMIT m`
// with an ELIGIBLE value-ordered index on (T,k) must be served by the planner
// `orderedScanFastPath` — a global 16-shard k-way merge over the index
// (`adapter.orderedScan`) that early-terminates at `m` — instead of the
// full-scan top-K heap (`topKOrderedFastPath`) which enumerates the WHOLE label.
//
// The "ordered path was taken" signal is `getOrderedScanFastPathHits()`: the
// planner ordered-scan fast path increments it by 1 each time it SERVES a query
// from the value-ordered index; the heap path (and any fallback) leaves it at 0.
// This is config-independent (the test harness runs an UNBOUNDED node cache, so
// the heap path's `getLabelSlotsEnumerated()` signal would read 0 here too).
// We additionally assert `getLabelSlotsEnumerated() == 0` (the ordered path
// never walks the label posting list). Correctness (exact rows + order) is
// asserted alongside the path signal.
//
// Real store, real parser, real executor, tmpDir — no mocks. Mirrors the
// GAP-0812 harness (test_gap0812_topk_streaming.zig).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

// Seed N nodes :T with a STRING key k = zero-padded permutation of [0,N).
// Zero-padded width 5 means lexical order == numeric order; the (i*97)%N
// permutation (gcd(97,300)==1) scrambles insertion vs value order so the
// k-way merge / sort is genuinely exercised. N=300 sequential node ids span
// all 16 shards.
fn seedT(h: *Harness, n: usize) !void {
    const aa = h.arena.allocator();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const q = try std.fmt.allocPrint(aa, "CREATE (:T {{k: '{d:0>5}'}})", .{v});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
}

test "H3-P3: ORDER BY indexed STRING key ASC LIMIT served from ordered index (slots ~0)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const n: usize = 300;
    try seedT(&h, n);

    // CREATE INDEX records the catalog row. Per the CREATE INDEX self-deadlock
    // fix (execution.zig ~1654), the value-ordered tree is NO LONGER built
    // eagerly under the per-graph write lock — it is materialized lazily (a
    // background `spawnOrderedIndexBuildAsync` on the first ORDER BY, or on
    // demand). This test targets the ordered fast-path SERVING, so build the
    // tree synchronously off the write-lock path here (no deadlock: no lock is
    // held at this point), then force a FULL checkpoint so the H3-P4 freshness
    // gate (f85a87c3) is satisfied — registered + eligible + fresh on every shard.
    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)");
        r.deinit(h.arena.allocator());
    }
    {
        const adapter = graph_store.getGlobalAdapter().?;
        try adapter.createOrderedIndex(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
        try adapter.checkpointAll();
    }

    // Reset both signals immediately before the measured query.
    execution.resetOrderedScanFastPathHits();
    adapter_mod.resetLabelSlotsEnumerated();
    var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k ASC LIMIT 10");
    defer res.deinit(h.arena.allocator());
    const hits = execution.getOrderedScanFastPathHits();
    const slots = adapter_mod.getLabelSlotsEnumerated();

    // Correctness: ASC top-10 == "00000".."00009".
    try testing.expectEqual(@as(usize, 10), res.rows.len);
    var expect_buf: [8]u8 = undefined;
    for (res.rows, 0..) |row, idx| {
        const want = try std.fmt.bufPrint(&expect_buf, "{d:0>5}", .{idx});
        try testing.expectEqualStrings(want, row[0].Str);
    }

    // Path signal: the ordered fast path served this query (hits == 1) and never
    // walked the label posting list (slots == 0).
    std.debug.print("[H3-P3 asc] ordered_hits={d} slots_enumerated={d}\n", .{ hits, slots });
    try testing.expectEqual(@as(u64, 1), hits);
    try testing.expect(slots == 0);
}

test "H3-P3: ORDER BY indexed STRING key DESC LIMIT served from ordered index (slots ~0)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const n: usize = 300;
    try seedT(&h, n);
    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)");
        r.deinit(h.arena.allocator());
    }
    {
        // Build the value-ordered tree synchronously + checkpoint to freshen it
        // (CREATE INDEX no longer builds it eagerly; see the ASC test above).
        const adapter = graph_store.getGlobalAdapter().?;
        try adapter.createOrderedIndex(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
        try adapter.checkpointAll();
    }

    execution.resetOrderedScanFastPathHits();
    adapter_mod.resetLabelSlotsEnumerated();
    var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k DESC LIMIT 10");
    defer res.deinit(h.arena.allocator());
    const hits = execution.getOrderedScanFastPathHits();
    const slots = adapter_mod.getLabelSlotsEnumerated();

    // DESC top-10 == "00299".."00290".
    try testing.expectEqual(@as(usize, 10), res.rows.len);
    var expect_buf: [8]u8 = undefined;
    for (res.rows, 0..) |row, idx| {
        const want = try std.fmt.bufPrint(&expect_buf, "{d:0>5}", .{n - 1 - idx});
        try testing.expectEqualStrings(want, row[0].Str);
    }

    std.debug.print("[H3-P3 desc] ordered_hits={d} slots_enumerated={d}\n", .{ hits, slots });
    try testing.expectEqual(@as(u64, 1), hits);
    try testing.expect(slots == 0);
}

// Extract a numeric value from an Int or Double row cell (mixed-type fallback).
fn numOf(v: anytype) f64 {
    return switch (v) {
        .Int => |i| @floatFromInt(i),
        .Double => |d| d,
        else => std.math.nan(f64),
    };
}

test "H3-P3: ORDER BY on a NON-indexed prop falls back to the heap (correct, ordered_hits==0)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed :T2 with an INT key k2 = permutation of [0,N). No CREATE INDEX, so
    // no ordered index is registered → the planner must use the heap.
    const aa = h.arena.allocator();
    const n: usize = 200;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const q = try std.fmt.allocPrint(aa, "CREATE (:T2 {{k2: {d}}})", .{v});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    execution.resetOrderedScanFastPathHits();
    var res = try h.runQuery("MATCH (n:T2) RETURN n.k2 ORDER BY n.k2 ASC LIMIT 10");
    defer res.deinit(aa);
    const hits = execution.getOrderedScanFastPathHits();

    // Fallback taken: the ordered fast path served NOTHING.
    try testing.expectEqual(@as(u64, 0), hits);
    // Heap path still correct: ASC top-10 == 0..9.
    try testing.expectEqual(@as(usize, 10), res.rows.len);
    for (res.rows, 0..) |row, idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)), row[0].Int);
    }
}

test "H3-P3: ORDER BY on an INELIGIBLE column (mixed int+float) falls back to the heap" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed :T3 where k3 is INT for even values and FLOAT for odd values — the
    // (label,key) pair is registered but mixed int+float makes it INELIGIBLE,
    // so the planner must fall back to the heap (which compares numerically).
    const aa = h.arena.allocator();
    const n: usize = 64;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 7) % n; // permutation of [0,64)
        const q = if (v % 2 == 0)
            try std.fmt.allocPrint(aa, "CREATE (:T3 {{k3: {d}}})", .{v}) // INT
        else
            try std.fmt.allocPrint(aa, "CREATE (:T3 {{k3: {d}.0}})", .{v}); // FLOAT
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE INDEX ON :T3(k3)");
        r.deinit(aa);
    }
    {
        // Build the value-ordered tree synchronously + checkpoint so it is
        // populated with the mixed int+float rows — required for the eligibility
        // check below to observe the mixed types and report it INELIGIBLE.
        const adapter = graph_store.getGlobalAdapter().?;
        try adapter.createOrderedIndex(graph_store.DEFAULT_GRAPH_NAME, "T3", "k3");
        try adapter.checkpointAll();
    }

    // Sanity: the index IS registered on all shards but NOT eligible (mixed).
    const adapter = graph_store.getGlobalAdapter().?;
    try testing.expect(adapter.isOrderedIndexRegistered(graph_store.DEFAULT_GRAPH_NAME, "T3", "k3"));
    try testing.expect(!adapter.isOrderedIndexEligible(graph_store.DEFAULT_GRAPH_NAME, "T3", "k3"));

    execution.resetOrderedScanFastPathHits();
    var res = try h.runQuery("MATCH (n:T3) RETURN n.k3 ORDER BY n.k3 ASC LIMIT 10");
    defer res.deinit(aa);
    const hits = execution.getOrderedScanFastPathHits();

    // Fallback taken (ineligible), heap result numerically correct: 0..9.
    try testing.expectEqual(@as(u64, 0), hits);
    try testing.expectEqual(@as(usize, 10), res.rows.len);
    for (res.rows, 0..) |row, idx| {
        try testing.expectEqual(@as(f64, @floatFromInt(idx)), numOf(row[0]));
    }
}

test "H3-P3: parity — ordered-index path == heap path (indexed vs non-indexed twin)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Two labels with IDENTICAL string-key data: T is indexed (ordered path),
    // Tn is NOT indexed (heap path). Their ORDER BY ... LIMIT results must match
    // row-for-row in both directions. (GAP-0064 FIX C's ORDER-BY auto-build is
    // suppressed by default under test, so :Tn stays heap-served across both
    // queries here.)
    const aa = h.arena.allocator();
    const n: usize = 300;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const qa = try std.fmt.allocPrint(aa, "CREATE (:T {{k: '{d:0>5}'}})", .{v});
        var ra = try h.runQuery(qa);
        ra.deinit(aa);
        const qb = try std.fmt.allocPrint(aa, "CREATE (:Tn {{k: '{d:0>5}'}})", .{v});
        var rb = try h.runQuery(qb);
        rb.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)"); // index T only
        r.deinit(aa);
    }
    {
        // Build T's value-ordered tree synchronously + checkpoint (see ASC test).
        // :Tn stays unindexed → heap-served, as this parity test intends.
        const adapter = graph_store.getGlobalAdapter().?;
        try adapter.createOrderedIndex(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
        try adapter.checkpointAll();
    }

    inline for (.{ "ASC", "DESC" }) |dir| {
        const q_idx = "MATCH (n:T) RETURN n.k ORDER BY n.k " ++ dir ++ " LIMIT 25";
        const q_heap = "MATCH (n:Tn) RETURN n.k ORDER BY n.k " ++ dir ++ " LIMIT 25";

        execution.resetOrderedScanFastPathHits();
        var r_idx = try h.runQuery(q_idx);
        defer r_idx.deinit(aa);
        const hits_idx = execution.getOrderedScanFastPathHits();

        execution.resetOrderedScanFastPathHits();
        var r_heap = try h.runQuery(q_heap);
        defer r_heap.deinit(aa);
        const hits_heap = execution.getOrderedScanFastPathHits();

        // T used the ordered path; Tn fell back to the heap.
        try testing.expectEqual(@as(u64, 1), hits_idx);
        try testing.expectEqual(@as(u64, 0), hits_heap);

        // Byte-identical rows + order.
        try testing.expectEqual(r_heap.rows.len, r_idx.rows.len);
        try testing.expectEqual(@as(usize, 25), r_idx.rows.len);
        for (r_idx.rows, r_heap.rows) |ri, rh| {
            try testing.expectEqualStrings(rh[0].Str, ri[0].Str);
        }
    }
}

test "H3-P3: LIMIT > N returns ALL rows in order via the ordered path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    const n: usize = 120;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const q = try std.fmt.allocPrint(aa, "CREATE (:T {{k: '{d:0>5}'}})", .{v});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)");
        r.deinit(aa);
    }
    {
        // Build the value-ordered tree synchronously + checkpoint (see ASC test).
        const adapter = graph_store.getGlobalAdapter().?;
        try adapter.createOrderedIndex(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
        try adapter.checkpointAll();
    }

    // LIMIT (5000) > N (120) but within the fast-path's 10_000 literal cap.
    execution.resetOrderedScanFastPathHits();
    var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k ASC LIMIT 5000");
    defer res.deinit(aa);
    const hits = execution.getOrderedScanFastPathHits();

    try testing.expectEqual(@as(u64, 1), hits);
    try testing.expectEqual(n, res.rows.len);
    var expect_buf: [8]u8 = undefined;
    for (res.rows, 0..) |row, idx| {
        const want = try std.fmt.bufPrint(&expect_buf, "{d:0>5}", .{idx});
        try testing.expectEqualStrings(want, row[0].Str);
    }
}
