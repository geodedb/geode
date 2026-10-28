// GAP residual: multi-chain comma-MATCH LIMIT pushdown.
//
// ROOT CAUSE (pre-fix)
// ====================
// `executeMultiChainHashJoin` emits EVERY slot combination of the pure
// cartesian product into `rows`, and the LIMIT window is applied post-hoc by
// the caller. For `MATCH (a:T),(b:T) RETURN a,b LIMIT 5` over N nodes that is
// N×N rows materialized before 5 are kept — the audit measured 259²=67,081
// rows for a LIMIT-5 query, OOM-equivalent at 14.27M nodes.
//
// FIX
// ===
// Cap the pure-cartesian emission loops (the 2-chain `else` branch and
// `nestedLoopCartesian` for N>2) at offset+limit, gated so it NEVER changes
// result rows/order/cardinality: the cap is null (= materialize all, unchanged
// behavior) when WHERE / ORDER BY / WITH / DISTINCT / aggregate is present.
//
// OBSERVABLE: `planned_read_runtime.getPathRowsMaterialized()` increments once
// per materialized row on the planned-read path. Pre-fix the pushdown case
// shows the full N×N; post-fix it is bounded by ~offset+limit.
//
// CANARY: REQ=REQ-READ-MULTICHAIN-LIMIT-PUSHDOWN; FEATURE="MultiChainLimitPushdown"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_multichain_limit_pushdown.zig; OWNER=execution; UPDATED=2026-06-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;

const N: usize = 30;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn seedT(self: *Harness, count: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "CREATE (:T {{k: {d}}})", .{i});
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

// ---------------------------------------------------------------------------
// pushdown: 2-chain pure cartesian with LIMIT stops early.
// ---------------------------------------------------------------------------
test "2-chain cartesian LIMIT caps materialization at limit" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedT(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (a:T),(b:T) RETURN a, b LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    // RED before fix: this materializes N*N = 900. After fix: ~5.
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized <= 10);
}

// ---------------------------------------------------------------------------
// 3-chain pure cartesian with LIMIT stops early.
// ---------------------------------------------------------------------------
test "3-chain cartesian LIMIT caps materialization at limit" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedT(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (a:T),(b:T),(c:T) RETURN a, b, c LIMIT 4");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 4), r.rows.len);
    // RED before fix: N*N*N = 27000. After fix: ~4.
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized <= 10);
}

// ---------------------------------------------------------------------------
// offset: SKIP/OFFSET + LIMIT caps at offset+limit and windows correctly.
// ---------------------------------------------------------------------------
test "2-chain cartesian OFFSET+LIMIT caps at offset+limit and windows correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedT(N);

    // Full-materialize reference: first 8 rows of the deterministic product,
    // windowed [3,8) = 5 rows. We assert the windowed result has 5 rows and the
    // materialization stayed bounded near offset+limit.
    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (a:T),(b:T) RETURN a, b LIMIT 5 OFFSET 3");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized <= 12);
}

// ---------------------------------------------------------------------------
// safety: ORDER BY must NOT trigger the cap — must materialize all then sort.
// First 5 rows after sorting by a.k ascending all have a.k == 0 (a0 paired
// with every b). The cap firing would break this (it would emit unsorted).
// ---------------------------------------------------------------------------
test "ORDER BY does not cap: full materialize then correct sorted window" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedT(N);

    var r = try h.runQuery("MATCH (a:T),(b:T) RETURN a.k AS ak, b.k AS bk ORDER BY ak LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    // After global sort, the first 5 rows are all (a.k = 0, b.k = 0..4).
    for (r.rows) |row| {
        try testing.expectEqual(@as(i64, 0), row[0].Int);
    }
}

// ---------------------------------------------------------------------------
// safety: DISTINCT must NOT trigger the cap — must materialize all then dedup.
// DISTINCT a.k over the N×N product yields N distinct values; LIMIT 5 keeps 5.
// ---------------------------------------------------------------------------
test "DISTINCT does not cap: correct distinct rows under LIMIT" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedT(N);

    var r = try h.runQuery("MATCH (a:T),(b:T) RETURN DISTINCT a.k AS ak LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    // All 5 values must be distinct.
    var seen = std.AutoHashMap(i64, void).init(testing.allocator);
    defer seen.deinit();
    for (r.rows) |row| {
        const gop = try seen.getOrPut(row[0].Int);
        try testing.expect(!gop.found_existing);
    }
}

// ---------------------------------------------------------------------------
// regression: WHERE-join path (hash-join) is unchanged — cap excluded because
// where_clause != null. a.k = b.k matches each node to itself → N pairs,
// LIMIT 5 keeps 5.
// ---------------------------------------------------------------------------
test "WHERE-join path unchanged under LIMIT (cap excluded)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedT(N);

    var r = try h.runQuery("MATCH (a:T),(b:T) WHERE a.k = b.k RETURN a.k AS ak, b.k AS bk LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    // Each kept row is a self-match: a.k == b.k.
    for (r.rows) |row| {
        try testing.expectEqual(row[0].Int, row[1].Int);
    }
}
