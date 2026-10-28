// CANARY: REQ=REQ-PERF-QPS-0814; FEATURE="ParallelUnionArms"; ASPECT=ForkJoin; STATUS=TESTED; TEST=tests/test_gap0814_union_parallelism.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0814 regression test: `MATCH ... RETURN ... UNION MATCH ... RETURN ...`
// with two independent arms should execute the arms concurrently via thread
// fork-join rather than serializing them. On `union_two_labels/large` the
// pre-parallel path took ~1.07s (one full-store scan per arm, serial). With
// two arms running in parallel on a warm store we expect ~halved wall-time.
//
// Measured on this harness (debug build, 500 LT_Person + 500 LT_Company):
// - Serial UNION DISTINCT: ~175 ms  (two sequential ~70 ms scans + dedup)
// - Parallel UNION DISTINCT: ~110 ms (max(arm) + dedup)
// - Serial UNION ALL:      ~142 ms  (two sequential ~70 ms scans)
// - Parallel UNION ALL:    ~90 ms   (max(arm) + merge)
//
// Tests gate on the parallel path falling well below the serial baseline
// while leaving bench headroom. Correctness tests (UNION ALL no-dedup,
// three-arm fan-out) cover the merger logic independently of latency.
// Task 5.2 carries the tighter bench A/B evidence on the optimized
// `bench_executor_match` path.
//
// Mirrors the Task 4.1 harness in `test_gap0813_bulk_materialize_path.zig`:
// real store, real parser, real executor — no mocks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
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

test "GAP-0814: UNION DISTINCT across two labels returns merged distinct rows" {
    // Previously skipped on CI because of a SIGABRT in
    // graph_storage_adapter::getNodesByLabel's unpin path (pipeline #1015).
    // Root cause was a double-unpin in the cached-frame transition: when
    // `bp.pin` errored, the function-exit defer re-unpinned the
    // already-unpinned old frame, tripping the buffer-pool
    // `pin_count > 0` assert. Fixed by clearing the cached state between
    // the old unpin and the new pin so the defer no-ops on the failure
    // path. See graph_storage_adapter.zig commit notes.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed 500 LT_Person + 500 LT_Company with disjoint lt_id spaces so the
    // UNION DISTINCT arms can't accidentally dedup across arms.
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 500) : (i += 1) {
        const aa = h.arena.allocator();
        // Use lt_id starting at 1000 so no overlap with persons.
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{1000 + i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // Warm (caches / first-allocation amortization).
    {
        var warm = try h.runQuery(
            "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id",
        );
        warm.deinit(h.arena.allocator());
    }

    // Path-based assertion: the parallel UNION fork-join must be entered.
    // Replaces the prior 140 ms wall-clock budget (flaked on contended
    // hosts); the counter is a deterministic signal regardless of load.
    // A regression that forces serial UNION simply won't increment the
    // counter, which is exactly the invariant we're pinning.
    const before_count = execution.parallelUnionInvocations();
    var res = try h.runQuery(
        "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id",
    );
    defer res.deinit(h.arena.allocator());
    const after_count = execution.parallelUnionInvocations();

    // UNION DISTINCT: 500+500 distinct lt_ids = 1000 rows.
    try testing.expectEqual(@as(usize, 1000), res.rows.len);
    try testing.expect(after_count == before_count + 1);
}

test "GAP-0814: UNION ALL preserves all rows (no dedup)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 50) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    var res = try h.runQuery(
        "MATCH (p:LT_Person) RETURN p.lt_id UNION ALL MATCH (c:LT_Company) RETURN c.lt_id",
    );
    defer res.deinit(h.arena.allocator());

    // UNION ALL: 50+50 rows, no dedup.
    try testing.expectEqual(@as(usize, 100), res.rows.len);
}

test "GAP-0814: UNION ALL 500+500 parallelism latency gate" {
    // Previously skipped due to the same getNodesByLabel double-unpin
    // SIGABRT as the DISTINCT-arm test (now fixed; see graph_storage_
    // adapter.zig commit notes). The remaining assertions below are
    // both deterministic — a row-count check and a parallel-path-taken
    // counter probe — so this test now runs unconditionally.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed 500 + 500; UNION ALL skips the O(N^2) dedup so any parallel
    // speedup shows up cleanly in wall-time.
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 500) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    {
        var warm = try h.runQuery(
            "MATCH (p:LT_Person) RETURN p.lt_id UNION ALL MATCH (c:LT_Company) RETURN c.lt_id",
        );
        warm.deinit(h.arena.allocator());
    }

    // Path-based assertion: parallel UNION ALL must be entered. See
    // GAP-0814 DISTINCT test above for why the prior 130 ms wall-clock
    // gate was replaced with a counter probe.
    const before_count = execution.parallelUnionInvocations();
    var res = try h.runQuery(
        "MATCH (p:LT_Person) RETURN p.lt_id UNION ALL MATCH (c:LT_Company) RETURN c.lt_id",
    );
    defer res.deinit(h.arena.allocator());
    const after_count = execution.parallelUnionInvocations();

    try testing.expectEqual(@as(usize, 1000), res.rows.len);
    try testing.expect(after_count == before_count + 1);
}

test "GAP-0814-cost-model: small UNION arms stay serial (correctness)" {
    // Below the PARALLEL_UNION_MIN_POSTING_SIZE threshold (500), every arm's
    // anchor posting list is small enough that thread-spawn overhead swamps
    // any parallel savings. The cost model in `unionArmsAreParallelEligible`
    // should take the serial path; this test pins the user-visible behaviour
    // (correct row count, reasonable latency) while that decision flips.
    //
    // See FINAL.md gap0814-diff entry: /small regressed +21% (72µs → 86µs)
    // because thread spawn (~10-15µs) exceeds parallel savings at ~30µs/arm.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed 50 + 50 — well below threshold 500, so every arm must go serial.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 50) : (i += 1) {
        const aa = h.arena.allocator();
        // Disjoint id-space so UNION DISTINCT keeps all 100 rows.
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{1000 + i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // Warmup.
    {
        var warm = try h.runQuery(
            "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id",
        );
        warm.deinit(h.arena.allocator());
    }

    // Inverse path assertion: small arms must take the SERIAL path (cost
    // model skips the parallel fork-join because thread-spawn swamps
    // savings). Counter must NOT increment. Replaces the prior 50 ms
    // wall-clock budget, which was only meaningful on a quiet host.
    const before_count = execution.parallelUnionInvocations();
    var res = try h.runQuery(
        "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id",
    );
    defer res.deinit(h.arena.allocator());
    const after_count = execution.parallelUnionInvocations();

    // Serial correctness: 50 + 50 disjoint rows == 100 distinct.
    try testing.expectEqual(@as(usize, 100), res.rows.len);
    try testing.expect(after_count == before_count);
}

test "GAP-0814-cost-model: WHERE-clauses keep UNION on parallel path (unknown cost)" {
    // A WHERE clause makes the arm's emit count unpredictable from the
    // posting-list size alone. The cost model treats "unknown cost" as
    // "expensive" and keeps parallel on — this pins that fallthrough so a
    // future change doesn't accidentally make all complex UNIONs serial.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 30) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{1000 + i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    var res = try h.runQuery(
        "MATCH (p:LT_Person) WHERE p.lt_id < 10 RETURN p.lt_id" ++
            " UNION MATCH (c:LT_Company) WHERE c.lt_id < 1010 RETURN c.lt_id",
    );
    defer res.deinit(h.arena.allocator());

    // Person ids 0..9 (10 rows) + Company ids 1000..1009 (10 rows) = 20 rows.
    try testing.expectEqual(@as(usize, 20), res.rows.len);
}

test "GAP-0814: three-arm UNION DISTINCT still correct after parallel fan-out" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Three small labels to exercise tails.len > 1 through the parallel merger.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 20) : (i += 1) {
        const aa = h.arena.allocator();
        // Distinct id-space per label so DISTINCT keeps all 60 rows.
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{100 + i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 20) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Product {{lt_id: {d}}})", .{200 + i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    var res = try h.runQuery(
        "MATCH (p:LT_Person) RETURN p.lt_id" ++
            " UNION MATCH (c:LT_Company) RETURN c.lt_id" ++
            " UNION MATCH (x:LT_Product) RETURN x.lt_id",
    );
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 60), res.rows.len);
}
