// Typed-edge / single-chain scan LIMIT pushdown.
//
// ROOT CAUSE (pre-fix)
// ====================
// `executePatternQuery` seeds every start node (anonymous endpoint ->
// scanAllNodes, no cap) then `exploreHops` materializes EVERY matching path
// before the LIMIT window is applied post-hoc by `applyWindowStage`. For
//   MATCH ()-[r:R]->() RETURN r LIMIT 5
// over a graph with E edges that is E rows materialized to keep 5 -- at scale
// (14.27M edges) this walks the whole edge set for a 5-row query.
//
// FIX
// ===
// Mirror the shipped multi-chain cartesian cap: compute `materialize_cap` =
// offset+limit, gated so it NEVER changes result rows/order/cardinality (null =
// materialize all, unchanged) when WHERE / ORDER BY / WITH / DISTINCT /
// aggregate is present. Thread the cap into `exploreHops` (entry + candidates
// loop) and break the start-slot / seeded-from-tail driver loops at the cap.
//
// OBSERVABLE: `planned_read_runtime.getPathRowsMaterialized()` increments once
// per materialized row. Pre-fix the pushdown case shows all-edges; post-fix it
// is bounded by ~offset+limit.
//
// CANARY: REQ=REQ-READ-TYPED-EDGE-LIMIT-PUSHDOWN; FEATURE="TypedEdgeLimitPushdown"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_typed_edge_limit_pushdown.zig; OWNER=execution; UPDATED=2026-06-29

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

    pub fn exec(self: *Harness, query: []const u8) !void {
        var r = try self.runQuery(query);
        r.deinit(self.arena.allocator());
    }

    // Linear chain n0-[:R]->n1-[:R]->...->n(count-1). Each node carries `k` =
    // its index. count-1 R edges; count-2 two-hop paths.
    pub fn seedChain(self: *Harness, count: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "CREATE (:T {{k: {d}}})", .{i});
            try self.exec(q);
        }
        i = 0;
        while (i + 1 < count) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MATCH (a:T {{k: {d}}}), (b:T {{k: {d}}}) CREATE (a)-[:R]->(b)",
                .{ i, i + 1 },
            );
            try self.exec(q);
        }
    }
};

// ---------------------------------------------------------------------------
// pushdown: single typed-edge scan with LIMIT stops materializing early.
// ---------------------------------------------------------------------------
test "typed-edge scan LIMIT caps materialization at limit" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedChain(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH ()-[r:R]->() RETURN r LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    // RED before fix: materializes all N-1 = 29 edges. After fix: ~5.
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized <= 10);
}

// ---------------------------------------------------------------------------
// offset: OFFSET + LIMIT caps at offset+limit and windows the prefix.
// ---------------------------------------------------------------------------
test "typed-edge scan OFFSET+LIMIT caps at offset+limit and windows correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedChain(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH ()-[r:R]->() RETURN r LIMIT 5 OFFSET 3");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized <= 12);
}

// ---------------------------------------------------------------------------
// multi-hop: (a)-[:R]->(b)-[:R]->(c) with LIMIT stays bounded.
// ---------------------------------------------------------------------------
test "multi-hop typed-edge scan LIMIT stays bounded" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedChain(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (a)-[:R]->(b)-[:R]->(c) RETURN c LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    // RED before fix: materializes all N-2 = 28 two-hop paths. After fix: ~5.
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized <= 10);
}

// ---------------------------------------------------------------------------
// safety: ORDER BY must NOT cap -- full materialize then sort then window.
// b.k ascending: first 5 rows are b.k = 1..5 (chain edges n_i -> n_{i+1}).
// ---------------------------------------------------------------------------
test "ORDER BY does not cap: full materialize then correct sorted window" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedChain(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (a)-[r:R]->(b) RETURN b.k AS bk ORDER BY bk LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    // Full materialize (cap excluded): all N-1 = 29 edges before sort/window.
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 10);
    // Sorted ascending: b.k = 1,2,3,4,5.
    var expected: i64 = 1;
    for (r.rows) |row| {
        try testing.expectEqual(expected, row[0].Int);
        expected += 1;
    }
}

// ---------------------------------------------------------------------------
// safety: WHERE must NOT cap -- where_clause != null disables the cap.
// ---------------------------------------------------------------------------
test "WHERE does not cap: full materialize, correct windowed rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedChain(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (a)-[r:R]->(b) WHERE a.k >= 0 RETURN b.k AS bk LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 10);
}

// ---------------------------------------------------------------------------
// safety: DISTINCT must NOT cap -- full materialize then dedup then window.
// ---------------------------------------------------------------------------
test "DISTINCT does not cap: correct distinct rows under LIMIT" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedChain(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (a)-[r:R]->(b) RETURN DISTINCT b.k AS bk LIMIT 5");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 5), r.rows.len);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 10);
    var seen = std.AutoHashMap(i64, void).init(testing.allocator);
    defer seen.deinit();
    for (r.rows) |row| {
        const gop = try seen.getOrPut(row[0].Int);
        try testing.expect(!gop.found_existing);
    }
}

// ---------------------------------------------------------------------------
// safety: aggregate (count) must NOT cap -- it counts ALL edges, never a
// limit-capped subset. The directed single-typed count(r:TYPE) shape is now
// served O(1) from the per-(graph,type) counter, so it materializes ZERO
// per-edge rows while still reporting the full count. The "does not cap"
// guarantee is therefore proven by the full count (N-1) AND by the fast
// path's zero-materialization (no rows to cap).
// N-1 = 29 R edges.
// ---------------------------------------------------------------------------
test "count aggregate does not cap: counts all edges" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedChain(N);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH ()-[r:R]->() RETURN count(r) AS c");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqual(@as(i64, @intCast(N - 1)), r.rows[0][0].Int);
    // Typed count fast path: O(1) from the per-type counter, no row materialized.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}
