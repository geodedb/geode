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

    // P2 wiring: CREATE INDEX registers the value-ordered index on all 16 shards.
    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)");
        r.deinit(h.arena.allocator());
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
