// GAP-0867: real statistics into the CBO + truthful EXPLAIN estimates.
//
// Pins three behaviors:
//   (a) StatsRegistry.analyzeTable() collects REAL row counts from the live
//       graph store (previously returned error.FeatureDisabled);
//   (b) cbo.explainEstimateJSON() emits a scan node whose estimated_rows
//       comes from those collected statistics (previously a canned skeleton);
//   (c) index_catalog.chooseIndexForPredicate() is predicate-aware: an index
//       is only selected when the predicate references the indexed property
//       (previously the predicate expression was ignored entirely).
//
// CANARY: REQ=REQ-GQL-CBO; FEATURE="Cost Based Optimizer"; ASPECT=RealStatistics; STATUS=TESTED; TEST=tests/test_gap0867_cbo_estimates.zig; OWNER=planner; UPDATED=2026-06-10

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const index_catalog = @import("index_catalog");

const execution = geode.execution;
const graph_store = geode.graph_store;
const cbo = geode.cbo;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Harness mirrors `tests/test_gap0811_aggregation_fastpath.zig`: route query
/// allocations through an arena, install a data-dir override, lazy-init the
/// global store via `getGlobalStore`.
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

    pub fn seedLabel(self: *Harness, comptime label: []const u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const aa = self.arena.allocator();
            const q = try std.fmt.allocPrint(aa, "CREATE (:" ++ label ++ " {{i: {d}}})", .{i});
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

/// Duck-typed statistics source over the live GraphStore — the wiring
/// `StatsRegistry.analyzeTable` expects (see src/planner/cbo.zig).
const StoreSource = struct {
    store: *graph_store.GraphStore,

    pub fn rowCountForLabel(self: @This(), label: []const u8) usize {
        return self.store.countNodesByLabel("default", label, null);
    }
};

test "GAP-0867a: analyzeTable collects real row counts from the graph store" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.seedLabel("GAP0867_A", 100);

    const store = graph_store.getGlobalStore(testing.allocator);

    var registry = cbo.StatsRegistry.init(testing.allocator);
    defer registry.deinit();

    // Previously: error.FeatureDisabled. Now: real count from the store.
    try registry.analyzeTable("GAP0867_A", StoreSource{ .store = store });

    const stats = registry.getTableStats("GAP0867_A") orelse return error.StatsMissing;
    try testing.expectEqual(@as(u64, 100), stats.row_count);
    try testing.expectEqual(@as(u64, 1), stats.page_count);
    try testing.expect(stats.last_updated > 0);
}

test "GAP-0867b: EXPLAIN estimate JSON carries a scan node with estimated_rows from statistics" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.seedLabel("GAP0867_A", 100);

    const store = graph_store.getGlobalStore(testing.allocator);

    var registry = cbo.StatsRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.analyzeTable("GAP0867_A", StoreSource{ .store = store });

    const aa = h.arena.allocator();
    var parsed = try geode.parseGql("MATCH (n:GAP0867_A) RETURN n", aa);
    defer parsed.deinit();
    const q = parsed.program.statements[0].Query;

    const json = try cbo.explainEstimateJSON(testing.allocator, &registry, q);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"node_scan\",\"label\":\"GAP0867_A\",\"estimated_rows\":100,\"estimate_source\":\"statistics\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"estimated_total_rows\":100") != null);

    // A label with no collected statistics must be truthfully marked as a
    // heuristic default, never presented as a measured estimate.
    var parsed_unknown = try geode.parseGql("MATCH (n:GAP0867_NoStats) RETURN n", aa);
    defer parsed_unknown.deinit();
    const q_unknown = parsed_unknown.program.statements[0].Query;
    const json_unknown = try cbo.explainEstimateJSON(testing.allocator, &registry, q_unknown);
    defer testing.allocator.free(json_unknown);
    try testing.expect(std.mem.indexOf(u8, json_unknown, "\"estimate_source\":\"default_heuristic\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_unknown, "\"estimate_source\":\"statistics\"") == null);
}

test "GAP-0867c: index selection is predicate-aware" {
    index_catalog.initIndexCatalog(testing.allocator);
    defer index_catalog.deinitIndexCatalog();

    // Predicate references the indexed property "x" -> idx_x is selected.
    const chosen = index_catalog.chooseIndexForPredicate("x", true, 1000);
    try testing.expect(chosen != null);
    try testing.expect(std.mem.eql(u8, chosen.?.key, "x"));
    try testing.expect(std.mem.eql(u8, chosen.?.name, "idx_x"));

    // Predicate references an unindexed property -> table scan (null).
    try testing.expect(index_catalog.chooseIndexForPredicate("z", true, 1000) == null);

    // No property referenced by the predicate -> the index cannot apply.
    try testing.expect(index_catalog.chooseIndexForPredicate(null, true, 1000) == null);

    // Non-equality predicate -> equality index path declines.
    try testing.expect(index_catalog.chooseIndexForPredicate("x", false, 1000) == null);
}
