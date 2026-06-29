// H3-P3 BENCH REPRO: mirror the synthseed/bench ordering — CREATE INDEX runs
// BEFORE any node exists, then nodes are created via the executor `CREATE (n:T
// {k:...})` path (label added first, property set after). The unit test
// test-ordered-scan-fastpath seeds nodes FIRST then CREATE INDEX, so it exercises
// the build-from-live-scan in createOrderedIndex and passes (hits=1). This repro
// flips the order to reproduce the real benchmark, where the ordered fast path
// does NOT engage.
//
// Real store, real parser, real executor, tmpDir — no mocks.

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

// Bench order: CREATE INDEX FIRST (0 nodes), THEN create nodes via the executor
// CREATE-with-inline-label path (label added, then property set).
test "H3-P3 BENCH REPRO: CREATE INDEX before nodes → ordered fast path must still engage" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();

    // 1) CREATE INDEX while the graph has ZERO :T nodes (synthseed ordering).
    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)");
        r.deinit(aa);
    }

    // 2) Create N nodes via the SAME executor path the SQL driver uses for
    //    `CREATE (n:T {k:...})` — bound var + inline label + inline property.
    const n: usize = 300;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const q = try std.fmt.allocPrint(aa, "CREATE (n:T {{k: '{d:0>5}'}})", .{v});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // Instrument the gate predicates after the create-via-inline-label sequence.
    const adapter = graph_store.getGlobalAdapter().?;
    const registered = adapter.isOrderedIndexRegistered(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const eligible = adapter.isOrderedIndexEligible(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const scan_ids = try adapter.orderedScan(graph_store.DEFAULT_GRAPH_NAME, "T", "k", .asc, 1000, aa);
    std.debug.print("[H3-P3 REPRO] registered={} eligible={} orderedScan_count={d} (expected {d})\n", .{ registered, eligible, scan_ids.len, n });

    // ROOT CAUSE signal: nodes created AFTER `CREATE INDEX` (label added first,
    // property set after) never populate the value-ordered tree, because the
    // engine's only ordered-index maintenance fires on addLabelTxn with the
    // node's prop_head AT LABEL-ADD TIME (== 0 here), and putPropertyTxn does
    // no ordered-index maintenance. So the tree is EMPTY.
    try testing.expectEqual(n, scan_ids.len);

    execution.resetOrderedScanFastPathHits();
    adapter_mod.resetLabelSlotsEnumerated();
    var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k ASC LIMIT 20");
    defer res.deinit(aa);
    const hits = execution.getOrderedScanFastPathHits();
    const slots = adapter_mod.getLabelSlotsEnumerated();

    std.debug.print("[H3-P3 REPRO] ordered_hits={d} slots_enumerated={d} rows={d}\n", .{ hits, slots, res.rows.len });

    // Correctness: ASC top-20 must be "00000".."00019".
    try testing.expectEqual(@as(usize, 20), res.rows.len);
    var expect_buf: [8]u8 = undefined;
    for (res.rows, 0..) |row, idx| {
        const want = try std.fmt.bufPrint(&expect_buf, "{d:0>5}", .{idx});
        try testing.expectEqualStrings(want, row[0].Str);
    }

    // The bug: the ordered fast path is NOT taken for index-before-nodes.
    try testing.expectEqual(@as(u64, 1), hits);
}
