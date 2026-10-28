// CANARY: REQ=REQ-GQL-MATCH-CREATE-COUNTERS; FEATURE="MatchCreateCounters"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_match_create_counters.zig; OWNER=execution; UPDATED=2026-06-10
//
// Regression tests for the MATCH…CREATE summary-counter mislabel.
//
// Bug (standalone executor, confirmed live — see
// docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md,
// "Secondary anomaly"): `MATCH (a),(b) CREATE (a)-[:R]->(b)` between two
// EXISTING nodes reported `nodes_created: 1` — but that 1 was a RELATIONSHIP.
// Root cause: `executeCreateForBatchWithTracking` collapsed
// `created_nodes_count + created_relationships_count` into a single
// `created_count`, and `executeMatchCreateQuery` emitted that sum under the
// single summary column `"nodes_created"`.
//
// Fixed contract (these tests pin it): the implicit MATCH…CREATE summary row
// carries TWO columns — `nodes_created` and `relationships_created` — each with
// the correct per-kind count. The `nodes_created` column is kept (value 0 for
// edge-only creates) so any consumer keying on it still resolves; the fix ADDS
// a column, never removes one.
//
// These tests drive the REAL parse -> execute pipeline
// (`execution.executeStatementWithContext`) against the global store — no mocks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;
const tenancy = geode.tenancy;

// ---------------------------------------------------------------------------
// Harness — global store + catalog, per-query arena (mirrors the production
// per-request arena; see tests/test_gap0846_tenant_hierarchy_reads.zig for the
// rationale — the legacy executor's per-row scratch is arena-reclaimed).
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        tenancy.setStrictTenancy(false);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// Run a write statement through the real executor; discard the result.
    fn run(self: *const Harness, allocator: std.mem.Allocator, query: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();

        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);

        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        defer res.deinit(aa);
    }

    /// Run a MATCH…CREATE statement and assert the implicit summary row reports
    /// `nodes_created` == expected_nodes AND `relationships_created` ==
    /// expected_rels. Fails loudly (with the actual column list) if either
    /// column is missing — pre-fix, the single mislabeled `nodes_created`
    /// column carried the node+relationship SUM.
    fn expectSummary(
        self: *const Harness,
        allocator: std.mem.Allocator,
        query: []const u8,
        expected_nodes: i64,
        expected_rels: i64,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();

        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);

        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        defer res.deinit(aa);

        var nodes_idx: ?usize = null;
        var rels_idx: ?usize = null;
        for (res.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col, "nodes_created")) nodes_idx = i;
            if (std.mem.eql(u8, col, "relationships_created")) rels_idx = i;
        }

        if (nodes_idx == null or rels_idx == null) {
            std.debug.print(
                "expected summary columns [nodes_created, relationships_created]; got {d} column(s):",
                .{res.columns.len},
            );
            for (res.columns) |col| std.debug.print(" \"{s}\"", .{col});
            std.debug.print("\n", .{});
            if (res.rows.len > 0 and res.rows[0].len > 0 and res.rows[0][0] == .Int) {
                std.debug.print("first row value: {d}\n", .{res.rows[0][0].Int});
            }
            return error.MissingSummaryColumn;
        }

        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(geode.eval.Value{ .Int = expected_nodes }, res.rows[0][nodes_idx.?]);
        try testing.expectEqual(geode.eval.Value{ .Int = expected_rels }, res.rows[0][rels_idx.?]);
    }

    /// Run a single-row/single-column read query (e.g. `RETURN count(n) AS c`)
    /// through the real executor and assert the integer result.
    fn expectCount(
        self: *const Harness,
        allocator: std.mem.Allocator,
        query: []const u8,
        expected: i64,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();

        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);

        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        defer res.deinit(aa);

        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(@as(usize, 1), res.rows[0].len);
        try testing.expectEqual(geode.eval.Value{ .Int = expected }, res.rows[0][0]);
    }
};

// ---------------------------------------------------------------------------
// 1. Edge-only MATCH…CREATE between two EXISTING nodes: 0 nodes, 1 relationship.
//    Pre-fix this reported the single column `nodes_created = 1` (the
//    relationship, mislabeled).
// ---------------------------------------------------------------------------

test "MATCH…CREATE edge between existing nodes: nodes_created=0, relationships_created=1" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.run(allocator, "CREATE (a:CcA {id: 1})");
    try h.run(allocator, "CREATE (b:CcB {id: 2})");

    try h.expectSummary(
        allocator,
        "MATCH (a:CcA {id: 1}), (b:CcB {id: 2}) CREATE (a)-[:CCL]->(b)",
        0,
        1,
    );
}

// ---------------------------------------------------------------------------
// 2. MATCH…CREATE that creates one NEW node + one edge: 1 node, 1 relationship.
//    Pre-fix this reported `nodes_created = 2` (node + relationship summed).
// ---------------------------------------------------------------------------

test "MATCH…CREATE new node + edge: nodes_created=1, relationships_created=1" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.run(allocator, "CREATE (a:CcA {id: 1})");

    try h.expectSummary(
        allocator,
        "MATCH (a:CcA {id: 1}) CREATE (a)-[:CCL2]->(new:CcNew {k: 1})",
        1,
        1,
    );

    // The new endpoint node must actually carry its inline properties.
    // Pre-fix, the hop-endpoint creation arm in
    // `executeCreateForBatchWithTracking` created `new` with labels only and
    // silently dropped `{k: 1}`.
    try h.expectCount(allocator, "MATCH (n:CcNew) RETURN count(n) AS c", 1);
    try h.expectCount(allocator, "MATCH (n:CcNew {k: 1}) RETURN count(n) AS c", 1);
}
