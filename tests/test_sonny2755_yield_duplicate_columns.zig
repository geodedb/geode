// SONNY-2755 regression: a YIELD that names a column twice was a double free.
//
// `filterYieldColumns` (execution_helpers.zig), which every procedure that
// honours YIELD runs (algo.bfs/dfs/dijkstra, geode.fts.*, geode.ts.*, and
// geode.tenant.* through its own maybeYield), copied the named column's name
// pointer into the result once per YIELD item. `YIELD path, path` gave two
// columns sharing one name allocation, and `ExecutionResult.deinit` freed
// both; the tenant procedures' results own their values too, so those were
// freed twice as well. Any user who may call one of these procedures could
// abort the server (release builds use the C allocator). The helper also
// returned a result that owned no values (BFS paths leaked on every call)
// and leaked the dropped columns' names.
//
// A YIELD that names a column twice is now refused (DuplicateYieldColumn,
// 42702) before the procedure runs, and the helper refuses one too. The
// filtered result keeps the original's ownership, and what the YIELD drops
// is freed. Every test here runs under the leak-checking testing allocator:
// a double free panics, a leak fails the test.
//
// CANARY: REQ=REQ-SONNY-2755-YIELD-COLUMNS; FEATURE="ProcedureYield"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2755_yield_duplicate_columns.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const eval = geode.eval;
const ts = geode.timeseries;
const tenant_registry = geode.tenant_registry;
const tenant_quota = geode.tenant_quota;
const user_mgmt = geode.user_management;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// A durable global store (the fulltext index needs the adapter), the
/// catalog, an in-memory time-series store, a tenant registry and a quota
/// manager. Queries run with the testing allocator itself, so the results'
/// memory is leak-checked; only the parse uses an arena.
const Harness = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    ts_store: ts.Store,
    registry: tenant_registry.TenantRegistry,
    quotas: tenant_quota.TenantQuotaManager,
    auth_was_enabled: bool,

    fn init(self: *Harness) !void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        errdefer testing.allocator.free(self.data_dir);
        graph_store.setDataDirOverride(testing.allocator, self.data_dir);
        _ = graph_store.getGlobalStore(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ts_store = ts.Store.init(testing.allocator);
        eval.setGlobalTimeseriesStore(&self.ts_store);
        self.registry = tenant_registry.TenantRegistry.init(testing.allocator);
        tenant_registry.setGlobalRegistry(&self.registry);
        self.quotas = tenant_quota.TenantQuotaManager.init(testing.allocator);
        tenant_quota.setGlobalQuotaManager(&self.quotas);
        // The tenant procedures' admin_tenant gate is open with auth off.
        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
    }

    fn deinit(self: *Harness) void {
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        tenant_quota.setGlobalQuotaManager(null);
        self.quotas.deinit();
        tenant_registry.setGlobalRegistry(null);
        self.registry.deinit();
        eval.setGlobalTimeseriesStore(null);
        self.ts_store.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parse_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer parse_arena.deinit();
        var parsed = try geode.parseGql(query, parse_arena.allocator());
        defer parsed.deinit();
        return execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], self.ctx);
    }

    /// `query` must succeed; its result is freed.
    fn ok(self: *Harness, query: []const u8) !void {
        var r = self.run(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        r.deinit(testing.allocator);
    }
};

/// One procedure call, YIELDed three ways: naming a column twice (refused
/// before the procedure runs), naming some of its columns (the rest are
/// dropped and freed), and naming them in another order.
const Case = struct {
    call: []const u8,
    twice: []const u8,
    some: []const u8,
    reordered: []const u8,
};

fn expectCase(h: *Harness, c: Case) !void {
    var buf: [512]u8 = undefined;
    const twice = try std.fmt.bufPrint(&buf, "{s} YIELD {s}", .{ c.call, c.twice });
    if (h.run(twice)) |r| {
        var res = r;
        res.deinit(testing.allocator);
        std.debug.print("{s}: ran; expected DuplicateYieldColumn\n", .{twice});
        return error.DuplicateYieldAccepted;
    } else |err| try testing.expectEqual(error.DuplicateYieldColumn, err);

    var buf2: [512]u8 = undefined;
    const some = try std.fmt.bufPrint(&buf2, "{s} YIELD {s}", .{ c.call, c.some });
    var r = h.run(some) catch |err| {
        std.debug.print("{s}: {s}\n", .{ some, @errorName(err) });
        return err;
    };
    defer r.deinit(testing.allocator);
    var names = std.mem.tokenizeAny(u8, c.some, ", ");
    var i: usize = 0;
    while (names.next()) |name| : (i += 1) {
        if (i >= r.columns.len or !std.mem.eql(u8, r.columns[i], name)) {
            std.debug.print("{s}: column {d} is not {s}\n", .{ some, i, name });
            return error.WrongYieldColumns;
        }
    }
    try testing.expectEqual(i, r.columns.len);

    var buf3: [512]u8 = undefined;
    try h.ok(try std.fmt.bufPrint(&buf3, "{s} YIELD {s}", .{ c.call, c.reordered }));
}

test "SONNY-2755: the graph algorithms that YIELD refuse a column named twice and free what they drop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    var labels = [_][]const u8{"P"};
    const a = try st.createNodeWithGraph(&labels, "default");
    const b = try st.createNodeWithGraph(&labels, "default");
    const c = try st.createNodeWithGraph(&labels, "default");
    _ = try st.createEdge(a, b, "R");
    _ = try st.createEdge(b, c, "R");

    var calls: [3][128]u8 = undefined;
    const bfs = try std.fmt.bufPrint(&calls[0], "CALL algo.bfs.stream({d})", .{a});
    const dfs = try std.fmt.bufPrint(&calls[1], "CALL algo.dfs.stream({d})", .{a});
    const dijkstra = try std.fmt.bufPrint(&calls[2], "CALL algo.dijkstra.stream({d}, {d})", .{ a, c });
    // BFS and DFS have one column, `path`, a list per row: before, every
    // path leaked, with or without a YIELD.
    try expectCase(&h, .{ .call = bfs, .twice = "path, path", .some = "path", .reordered = "path" });
    try expectCase(&h, .{ .call = dfs, .twice = "path, path", .some = "path", .reordered = "path" });
    try expectCase(&h, .{ .call = dijkstra, .twice = "cost, path, cost", .some = "path", .reordered = "cost, path" });
    // No YIELD at all: the paths are freed with the result.
    try h.ok(bfs);
    try h.ok(dijkstra);
}

test "SONNY-2755: the fulltext procedures refuse a column named twice and free what they drop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.ok("CREATE (:Doc {body: 'the quick brown fox'})");
    try h.ok("CREATE (:Doc {body: 'lazy dog sleeps'})");
    try h.ok("CREATE INDEX doc_body_idx FOR (d:Doc) ON (d.body) USING fulltext");

    try expectCase(&h, .{ .call = "CALL geode.fts.search('doc_body_idx', 'fox')", .twice = "node, node", .some = "score", .reordered = "score, node" });
    try expectCase(&h, .{ .call = "CALL geode.fts.phrase('doc_body_idx', 'quick brown')", .twice = "score, score", .some = "node", .reordered = "score, node" });
    try expectCase(&h, .{ .call = "CALL geode.fts.proximity('doc_body_idx', 'quick fox', 3)", .twice = "node, score, node", .some = "node", .reordered = "score, node" });
    // rebuild's `index` is an owned string: dropped, it is freed; kept, it
    // is freed with the result.
    try expectCase(&h, .{ .call = "CALL geode.fts.rebuild('doc_body_idx')", .twice = "index, index", .some = "nodes_indexed", .reordered = "nodes_indexed, index" });
}

test "SONNY-2755: the time-series procedures refuse a column named twice and free what they drop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectCase(&h, .{ .call = "CALL geode.ts.insert(1, 'cpu', 1000, 5)", .twice = "inserted, inserted", .some = "inserted", .reordered = "inserted" });
    try expectCase(&h, .{ .call = "CALL geode.ts.insert_many(1, 'cpu', [[2000, 6], [3000, 7]])", .twice = "inserted, inserted", .some = "inserted", .reordered = "inserted" });
    try expectCase(&h, .{ .call = "CALL geode.ts.range(1, 'cpu', 0, 5000)", .twice = "value, ts, value", .some = "value", .reordered = "value, ts" });
    try expectCase(&h, .{ .call = "CALL geode.ts.last(1, 'cpu')", .twice = "ts, ts", .some = "ts", .reordered = "value, ts" });
    try expectCase(&h, .{ .call = "CALL geode.ts.bucket_avg(1, 'cpu', 0, 5000, 1)", .twice = "avg, avg", .some = "bucket_ts", .reordered = "avg, bucket_ts" });
    try expectCase(&h, .{ .call = "CALL geode.ts.sample_by(1, 'cpu', 1000, 0, 5000, 'max')", .twice = "value, value", .some = "value", .reordered = "value, bucket_ts" });
}

test "SONNY-2755: the tenant procedures refuse a column named twice, before they change anything, and free what they drop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // The refusal comes before the procedure runs: no tenant is created.
    try testing.expectError(error.DuplicateYieldColumn, h.run("CALL geode.tenant.create('ghost') YIELD tenant_id, tenant_id"));
    try testing.expectError(error.DuplicateYieldColumn, h.run("CALL geode.tenant.create('ghost') YIELD created, tenant_id, created"));
    try testing.expect(!h.registry.contains("ghost"));
    // Each create makes a tenant, so each YIELD shape gets its own.
    try h.ok("CALL geode.tenant.create('acme') YIELD tenant_id");
    try h.ok("CALL geode.tenant.create('beta', 'acme') YIELD created, parent");

    try expectCase(&h, .{ .call = "CALL geode.tenant.list()", .twice = "tenant_id, tenant_id", .some = "parent, tenant_id", .reordered = "active, tenant_id" });
    try expectCase(&h, .{ .call = "CALL geode.tenant.show('acme')", .twice = "tenant_id, tenant_id", .some = "tenant_id", .reordered = "max_connections, tenant_id" });
    try expectCase(&h, .{ .call = "CALL geode.tenant.set_quota('acme', 5, 2, 10, 500)", .twice = "updated, updated", .some = "tenant_id", .reordered = "updated, tenant_id" });
    try expectCase(&h, .{ .call = "CALL geode.tenant.backfill_edge_tags(true)", .twice = "edge_id, action, edge_id", .some = "action", .reordered = "reason, edge_id" });
    // drop last (a tenant is dropped once): the child, then its parent.
    try testing.expectError(error.DuplicateYieldColumn, h.run("CALL geode.tenant.drop('beta') YIELD dropped, dropped"));
    try testing.expect(h.registry.contains("beta"));
    try h.ok("CALL geode.tenant.drop('beta') YIELD dropped");
    try h.ok("CALL geode.tenant.drop('acme') YIELD tenant_id, dropped");
}

/// The YIELD items of `CALL p() YIELD <items>`, parsed into `arena`.
fn yieldItems(arena: *std.heap.ArenaAllocator, items: []const u8) ![]geode.gql.ast.ReturnItem {
    const query = try std.fmt.allocPrint(arena.allocator(), "CALL p() YIELD {s}", .{items});
    const parsed = try geode.parseGql(query, arena.allocator());
    return parsed.program.statements[0].Call.Procedure.yield_items.?;
}

/// Columns a, b, c; one row of owned strings "a0", "b0", "c0".
fn ownedResult() !execution.ExecutionResult {
    const a = testing.allocator;
    const columns = try a.alloc([]const u8, 3);
    const rows = try a.alloc([]Value, 1);
    rows[0] = try a.alloc(Value, 3);
    for ([_][]const u8{ "a", "b", "c" }, 0..) |name, i| {
        columns[i] = try a.dupe(u8, name);
        rows[0][i] = .{ .Str = try std.fmt.allocPrint(a, "{s}0", .{name}) };
    }
    return .{ .columns = columns, .rows = rows, .flags = .empty, .owns_value_memory = true };
}

test "SONNY-2755: filterYieldColumns keeps what the YIELD names, frees the rest, and refuses a name twice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Owned values: the kept ones move, in the YIELD's order; the dropped
    // column's name and value are freed.
    {
        var r = try execution.filterYieldColumns(testing.allocator, try ownedResult(), try yieldItems(&arena, "c, a, missing"));
        defer r.deinit(testing.allocator);
        try testing.expect(r.owns_value_memory);
        try testing.expectEqual(@as(usize, 2), r.columns.len);
        try testing.expectEqualStrings("c", r.columns[0]);
        try testing.expectEqualStrings("a", r.columns[1]);
        try testing.expectEqualStrings("c0", r.rows[0][0].Str);
        try testing.expectEqualStrings("a0", r.rows[0][1].Str);
    }
    // A name twice: refused, and the result it was given is freed.
    try testing.expectError(error.DuplicateYieldColumn, execution.filterYieldColumns(testing.allocator, try ownedResult(), try yieldItems(&arena, "b, b")));
    try testing.expectError(error.DuplicateYieldColumn, execution.filterYieldColumns(testing.allocator, try ownedResult(), try yieldItems(&arena, "a, b AS a")));

    // Values it does not own (string literals) are neither freed nor kept
    // alive by it; column names in a single buffer stay in that buffer.
    {
        const a = testing.allocator;
        const buffer = try a.dupe(u8, "xyz");
        const columns = try a.alloc([]const u8, 3);
        for (0..3) |i| columns[i] = buffer[i .. i + 1];
        const rows = try a.alloc([]Value, 2);
        for (rows) |*row| {
            row.* = try a.alloc(Value, 3);
            row.*[0] = .{ .Str = "literal x" };
            row.*[1] = .{ .Int = 1 };
            row.*[2] = .{ .Str = "literal z" };
        }
        const source: execution.ExecutionResult = .{ .columns = columns, .rows = rows, .flags = .empty, .column_buffer = buffer };
        var r = try execution.filterYieldColumns(a, source, try yieldItems(&arena, "z, y"));
        defer r.deinit(a);
        try testing.expect(!r.owns_value_memory);
        try testing.expectEqualStrings("z", r.columns[0]);
        try testing.expectEqualStrings("y", r.columns[1]);
        try testing.expectEqualStrings("literal z", r.rows[1][0].Str);
    }
}
