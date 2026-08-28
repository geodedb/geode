// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-001; FEATURE="FullText"; ASPECT=TenantFilteredResults; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-28
//
// Spec geode-vectorization-and-reranking (FTS data boundary): `CALL
// geode.fts.search/phrase/proximity` resolve candidate node ids OUTSIDE the
// MATCH loop (straight from the fts-storage engine's positional postings), so
// they previously bypassed the tenant + RLS row-visibility filtering every
// MATCH row gets — a cross-tenant / RLS-bypass leak of node ids and BM25
// scores. These tests drive the real store + real parser + real executor (no
// mocks), mirroring tests/test_fts_e2e.zig for the store/adapter/index
// bootstrap, tests/test_gap0509_tenant_isolation.zig for the tenant tagging
// pattern, and tests/test_gap0903_rls_clone_gate.zig / test_rls_expr_engine_wiring.zig
// for the RLS label-deny engine wiring pattern.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");

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

/// Harness mirrors tests/test_fts_e2e.zig.
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

// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-001; FEATURE="FullText"; ASPECT=TenantFilteredResults; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-28
test "fts search drops rows from other tenants" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // Seed one :FtsAuthDoc node per tenant with the SAME searchable body text
    // so a single query matches both — isolation must come from row
    // visibility filtering, not term mismatch. Node tenant tagging happens
    // via the active-context thread-local (fle_integration.tenantPreferringActiveContext),
    // so the context must be pushed active around each CREATE (mirrors
    // tests/test_gap0903_rls_clone_gate.zig's h.ctx.user + pushActiveContext
    // pattern, applied here to tenant_id).
    var tenant_a_id: i64 = undefined;
    {
        h.ctx.tenant_id = "tenant_a";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);

        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'quick brown fox'})");
        r.deinit(aa);

        var res = try h.runQuery("MATCH (n:FtsAuthDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        tenant_a_id = res.rows[0][0].Int;
    }

    var tenant_b_id: i64 = undefined;
    {
        h.ctx.tenant_id = "tenant_b";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);

        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'quick brown fox'})");
        r.deinit(aa);

        var res = try h.runQuery("MATCH (n:FtsAuthDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        tenant_b_id = res.rows[0][0].Int;
    }
    try testing.expect(tenant_a_id != tenant_b_id);

    // CREATE the fulltext index — DDL backfill is tenant-agnostic and picks
    // up BOTH tenants' nodes; row visibility is enforced at query time.
    h.ctx.tenant_id = null;
    {
        var r = try h.runQuery("CREATE INDEX ftsauth_tenant_idx FOR (d:FtsAuthDoc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // Search scoped to tenant_a: only the tenant_a node id may appear, even
    // though the fts-storage engine's postings match both docs.
    h.ctx.tenant_id = "tenant_a";
    {
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_tenant_idx', 'fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(tenant_a_id, res.rows[0][0].Int);
    }
}

test "fts search with no tenant filter returns all rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    var tenant_a_id: i64 = undefined;
    {
        h.ctx.tenant_id = "tenant_a";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);

        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'quick brown fox'})");
        r.deinit(aa);

        var res = try h.runQuery("MATCH (n:FtsAuthDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        tenant_a_id = res.rows[0][0].Int;
    }

    var tenant_b_id: i64 = undefined;
    {
        h.ctx.tenant_id = "tenant_b";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);

        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'quick brown fox'})");
        r.deinit(aa);

        var res = try h.runQuery("MATCH (n:FtsAuthDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        tenant_b_id = res.rows[0][0].Int;
    }
    try testing.expect(tenant_a_id != tenant_b_id);

    h.ctx.tenant_id = null;
    {
        var r = try h.runQuery("CREATE INDEX ftsauth_notenant_idx FOR (d:FtsAuthDoc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // No tenant scope (admin / all-tenants): both ids must be returned.
    h.ctx.tenant_id = null;
    {
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_notenant_idx', 'fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);

        var saw_a = false;
        var saw_b = false;
        for (res.rows) |row| {
            if (row[0].Int == tenant_a_id) saw_a = true;
            if (row[0].Int == tenant_b_id) saw_b = true;
        }
        try testing.expect(saw_a);
        try testing.expect(saw_b);
    }
}

test "fts search drops RLS-label-denied rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    {
        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'quick brown fox'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE INDEX ftsauth_rls_idx FOR (d:FtsAuthDoc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // RLS setup: deny label :FtsAuthDoc for user "bob" (mirrors
    // tests/test_gap0903_rls_clone_gate.zig's RLSFilterEngine wiring, which is
    // the same Layer-1 label-deny check `match_operations.passesRLSFilter`
    // applies to MATCH rows).
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "FtsAuthDoc", "bob");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    h.ctx.user = "bob";
    const prev = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev);

    {
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_rls_idx', 'fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }

    // Clear the engine — the previously-denied row must now return.
    rls_types.setGlobalRLSFilterEngine(null);
    {
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_rls_idx', 'fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
    }
}
