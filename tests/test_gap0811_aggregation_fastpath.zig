// CANARY: REQ=REQ-PERF-QPS-0811; FEATURE="CountFastPath"; ASPECT=LabelScopedCount; STATUS=TESTED; TEST=tests/test_gap0811_aggregation_fastpath.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0811 regression test: `MATCH (p:Label) RETURN count(p)` must hit the
// label-scoped count fast-path (`countNodesByLabel` O(1) posting-list
// lookup) instead of materializing every node and discarding everything
// except the count. Before this fix the labeled count ran the regular
// executor's per-node materialize loop at ~180 µs/node — ~900 ms for 5k
// nodes.
//
// This test exercises the real store + real parser + real executor (no
// mocks): seed a known label population, run the MATCH-count query, and
// assert both correctness (row value matches the seeded count) and a
// strict latency upper bound. The latency check is the smoke signal that
// the fast-path was taken — 200 materializeNode calls at 180 µs each
// would be ~36 ms, far above the 2 ms budget.

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

// Zig 0.16 compat helper (copied from test_count_nodes_pushdown_perf.zig).
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

/// Harness mirrors `test_gap0809_where_fastpath.zig`: route query
/// allocations through an arena, install a data-dir override, lazy-init
/// the global store via `getGlobalStore`.
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

test "GAP-0811: count(p:LT_Person) uses label-index cardinality" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed 200 LT_Person + 20 LT_Company.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < 20) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // Warm up (caches / first-allocation amortization).
    {
        var warm = try h.runQuery("MATCH (p:LT_Person) RETURN count(p) AS n");
        warm.deinit(h.arena.allocator());
    }

    // Timed: fast path should return in <2 ms even for 200 nodes.
    const t0 = compat_nanoTimestamp();
    var res = try h.runQuery("MATCH (p:LT_Person) RETURN count(p) AS n");
    defer res.deinit(h.arena.allocator());
    const elapsed_ns = compat_nanoTimestamp() - t0;

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 200), res.rows[0][0].Int);

    // Latency smoke: 200 materializeNode calls at ~180 µs each would be ~36 ms.
    // <2 ms confirms the fast path skipped per-row materialization.
    try testing.expect(elapsed_ns < 2_000_000);
}

test "GAP-0811: count(c:LT_Company) on different label returns correct count" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    var res = try h.runQuery("MATCH (c:LT_Company) RETURN count(c) AS n");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 5), res.rows[0][0].Int);
}

test "GAP-0811: count of absent label returns 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed a few nodes with label A, then count label B (which was never
    // created). The fast path must return 0 via the missing posting-list
    // short-circuit in `countNodesByLabel`.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_PresentLabel {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    var res = try h.runQuery("MATCH (x:LT_AbsentLabel) RETURN count(x) AS n");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 0), res.rows[0][0].Int);
}
