// CANARY: REQ=REQ-PERF-QPS-0809; FEATURE="WhereFastPath"; ASPECT=PropertyIndex; STATUS=TESTED; TEST=tests/test_gap0809_where_fastpath.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0809 regression test: `MATCH (p:Label) WHERE p.key = <literal>` must
// hit the adapter-level `exact_node_property_index` (same as the inline-
// prop variant `MATCH (p:Label {key: ...})`) instead of falling back to a
// full `getNodesByLabels` scan. Before this fix the WHERE-style query ran
// an O(N) label scan, making point_read_where 3000× slower than
// point_read_inline on 5k-node datasets.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Harness mirrors `test_match_set_label_scan_regression.zig`'s pattern:
/// route query allocations through an arena (keeps the env-alloc life-
/// cycle out of std.testing.allocator leak detection), install a data
/// dir override, and lazy-init the global store via `getGlobalStore`.
/// This avoids the init-time FTS/migration warnings that `initGlobalStore`
/// emits in a bare tmp dir, which otherwise trip zig 0.16's
/// "stderr-logged errors fail the test" heuristic.
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

test "GAP-0809: MATCH WHERE p.key = literal hits adapter property index" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed 50 LT_Person nodes via CREATE so the adapter's exact_node_
    // property_index gets populated.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}, name: 'User{d}'}})", .{ i, i });
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    var result = try h.runQuery("MATCH (p:LT_Person) WHERE p.lt_id = 42 RETURN p.name");
    defer result.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 1);
    try testing.expectEqual(@as(u64, 0), graph_store.getNodesByLabelsCallCount());
}

test "GAP-0809: WHERE with mirrored equality (literal = p.key) hits fast path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}, name: 'User{d}'}})", .{ i, i });
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    var result = try h.runQuery("MATCH (p:LT_Person) WHERE 7 = p.lt_id RETURN p.name");
    defer result.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 1);
    try testing.expectEqual(@as(u64, 0), graph_store.getNodesByLabelsCallCount());
}

test "GAP-0809: range predicate declines the equality fast path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}, age: {d}}})", .{ i, 20 + i });
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    graph_storage_adapter.resetLookupCounters();

    // ages 20..39; WHERE p.age > 35 ⇒ ages 36,37,38,39 ⇒ 4 rows.
    var result = try h.runQuery("MATCH (p:LT_Person) WHERE p.age > 35 RETURN p.lt_id");
    defer result.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 4), result.rows.len);
    // The equality fast path must NOT have claimed this query.
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getExactNodePropertyLookupCount());
}
