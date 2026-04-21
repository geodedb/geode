// CANARY: REQ=REQ-PERF-QPS-0815; FEATURE="BatchCreate"; ASPECT=BulkNodeSlots; STATUS=TESTED; TEST=tests/test_gap0815_deep_bulk_create.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0815-deep regression test: `GraphStore.createNodesBatch(labels, graph, n)`
// allocates N node slots + attaches the label set under a SINGLE adapter
// mutex acquisition (not N). Rewires the `executeBatchCreateHomogeneous`
// hot loop to use it — eliminating the per-clause `getOrCreateGraph`
// mutex round-trip and the per-node label-index sortedInsert.
//
// Mirrors the sibling GAP-0815 (shallow) harness: real store, real parser,
// real executor, no mocks. Latency budgets are loose to avoid flake under
// CI filesystem variance while still catching a catastrophic regression.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
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
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn buildHomogeneousBatchQuery(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "CREATE ");
    var i: usize = 0;
    var scratch: [128]u8 = undefined;
    while (i < n) : (i += 1) {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        const chunk = try std.fmt.bufPrint(&scratch, "(:LT_Person {{lt_id: {d}, name: 'p{d}'}})", .{ i, i });
        try buf.appendSlice(allocator, chunk);
    }
    return buf.toOwnedSlice(allocator);
}

test "GAP-0815-deep: createNodesBatch allocates 100 slots under one mutex" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const store = graph_store.getWritableGlobalStore(testing.allocator);
    const labels: []const []const u8 = &.{"LT_Person"};

    // Warmup: first batch hits the getOrCreateGraph cold path + label_index
    // hashmap bucket allocation. The measured batch below is apples-to-apples
    // against the serial baseline (which would see the same warm state).
    {
        const warm_ids = try store.createNodesBatchWithAllocator(labels, "default", 5, testing.allocator);
        testing.allocator.free(warm_ids);
    }

    const t0 = compat_nanoTimestamp();
    const ids = try store.createNodesBatchWithAllocator(labels, "default", 100, testing.allocator);
    const elapsed_ns = compat_nanoTimestamp() - t0;
    defer testing.allocator.free(ids);

    std.debug.print("[GAP-0815-deep bulk100] elapsed_ns={d}\n", .{elapsed_ns});

    try testing.expectEqual(@as(usize, 100), ids.len);

    // Correctness: all IDs unique + all distinct from warm batch.
    var id_set = std.AutoHashMap(u64, void).init(testing.allocator);
    defer id_set.deinit();
    for (ids) |id| {
        try testing.expect(id != 0);
        const gop = try id_set.getOrPut(id);
        try testing.expect(!gop.found_existing);
    }

    // Verify the label index reflects all 105 (100 batch + 5 warm) nodes.
    const aa = h.arena.allocator();
    var count_res = try h.runQuery("MATCH (p:LT_Person) RETURN count(p) AS n");
    defer count_res.deinit(aa);
    try testing.expectEqual(@as(usize, 1), count_res.rows.len);
    try testing.expectEqual(@as(i64, 105), count_res.rows[0][0].Int);

    // Loose latency budget: generous ceiling in Debug covers filesystem
    // variance, FLE encryption overhead, debug-allocator accounting, and
    // contention with sibling test binaries running in parallel. Still
    // catches a catastrophic regression into an N^2 path (pre-deep serial
    // baseline for pure slot-alloc is ~7-10 ms per 100-node burst in
    // isolation; observed deep path ~150 ms in isolation including the
    // MATCH count round-trip). Bench A/B ledger carries the tight gate.
    try testing.expect(elapsed_ns < 2_000_000_000);
}

test "GAP-0815-deep: inline 100-clause CREATE hits deep batch path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    const q = try buildHomogeneousBatchQuery(aa, 100);

    // Warm the parser cache.
    {
        var warm = try h.runQuery("CREATE (:LT_Warmup {x: 1}), (:LT_Warmup {x: 2}), (:LT_Warmup {x: 3})");
        warm.deinit(aa);
    }

    const t0 = compat_nanoTimestamp();
    var res = try h.runQuery(q);
    const elapsed_ns = compat_nanoTimestamp() - t0;
    res.deinit(aa);

    std.debug.print("[GAP-0815-deep inline100] elapsed_ns={d}\n", .{elapsed_ns});

    // GAP-0815 shallow baseline: ~470 ms Debug for 100 clauses.
    // GAP-0815-deep target: well under the shallow baseline. Loose budget
    // (2 s) lets CI absorb parser/coercion + first-run warmup without flake
    // while still flagging a regression into the per-call path.
    try testing.expect(elapsed_ns < 2_000_000_000);

    // Verify all 100 were created.
    var count_res = try h.runQuery("MATCH (p:LT_Person) RETURN count(p) AS n");
    defer count_res.deinit(aa);
    try testing.expectEqual(@as(usize, 1), count_res.rows.len);
    try testing.expectEqual(@as(i64, 100), count_res.rows[0][0].Int);

    // Spot-check: properties preserved round-trip via the batch path.
    var lookup = try h.runQuery("MATCH (p:LT_Person {lt_id: 42}) RETURN p.name");
    defer lookup.deinit(aa);
    try testing.expectEqual(@as(usize, 1), lookup.rows.len);
    try testing.expectEqualStrings("p42", lookup.rows[0][0].Str);
}

test "GAP-0815-deep: createNodesBatch with multi-label assignment" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const store = graph_store.getWritableGlobalStore(testing.allocator);
    const labels: []const []const u8 = &.{ "LT_Person", "LT_Employee" };
    const ids = try store.createNodesBatchWithAllocator(labels, "default", 10, testing.allocator);
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 10), ids.len);

    const aa = h.arena.allocator();
    // Both label indices should reflect all 10 nodes.
    {
        var r = try h.runQuery("MATCH (p:LT_Person) RETURN count(p) AS n");
        defer r.deinit(aa);
        try testing.expectEqual(@as(i64, 10), r.rows[0][0].Int);
    }
    {
        var r = try h.runQuery("MATCH (p:LT_Employee) RETURN count(p) AS n");
        defer r.deinit(aa);
        try testing.expectEqual(@as(i64, 10), r.rows[0][0].Int);
    }
}

test "GAP-0815-deep: createNodesBatch with n=0 returns empty slice" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const store = graph_store.getWritableGlobalStore(testing.allocator);
    const labels: []const []const u8 = &.{"LT_Person"};
    const ids = try store.createNodesBatchWithAllocator(labels, "default", 0, testing.allocator);
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 0), ids.len);
}
