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

    /// Run `query` (a single CALL statement) inside an explicit `START
    /// TRANSACTION { ... }` body. `execution.executeStatementWithContext`'s
    /// `.StartTransaction` handling (execution.zig ~:1383-1388) dispatches a
    /// `.Call` body statement straight to `call_operations.executeCallProcedure`
    /// — NOT through `executeCallStatement`'s `QueryReadSession` wrapper
    /// (execution/call_operations.zig:74-89), which deep-clones/re-materializes
    /// EVERY node from the durable engine on every bare top-level CALL and so
    /// masks bounded-node-cache eviction entirely (confirmed empirically: a bare
    /// `CALL geode.fts.search` still finds an evicted node "resident" because
    /// the snapshot construction rebuilds it). Wrapping in a transaction body is
    /// the one documented, unprivileged way to reach the SAME resident-cache
    /// code path `filterAuthorizedHits` runs against in this harness's
    /// direct-CALL entry point — required for these tests to actually exercise
    /// (not merely appear to exercise) the fallback under test.
    pub fn runQueryUnsnapshotted(self: *Harness, call_query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        const wrapped = try std.fmt.allocPrint(aa, "START TRANSACTION {{ {s} }}", .{call_query});
        var parsed = try geode.parseGql(wrapped, aa);
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

// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-HYDRATE-001; FEATURE="FullText"; ASPECT=SearchHitHydrate; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-29
//
// Spec geode-vectorization-and-reranking, final-review fix wave (2026-08-29):
// `filterAuthorizedHits` (src/execution/fts_dispatch.zig) previously resolved
// each search hit ONLY via `store.nodes.lockShardShared` + `getPtrUnlocked`
// — a resident-cache-only lookup — and treated a miss as "deleted since
// indexing", silently dropping the hit. A durable node the bounded node
// cache had merely EVICTED is not deleted; dropping it is a correctness bug
// (identical in shape to Task 5's write-side fix, commit `34c3988b`, applied
// here to the read side). This test pins the fallback: index a node, confirm
// it is searchable, evict it from the bounded cache via the cache's own
// `remove` primitive (durable storage untouched), and confirm the hit
// SURVIVES because `filterAuthorizedHits` now hydrates via
// `store.nodes.getOrHydrate` outside the shard lock.
//
// The eviction-sensitive assertions run the CALL through
// `Harness.runQueryUnsnapshotted` (see its doc comment) — a bare top-level
// `CALL geode.fts.search` goes through `executeCallStatement`'s
// `QueryReadSession`, which deep-clones/re-materializes every node from the
// durable engine on EVERY call and would mask the very miss this test needs
// to observe.
//
// Pre-fix (RED): 0 rows — `getPtrUnlocked` misses on the evicted node and the
// hit is dropped without ever attempting to hydrate.
// Post-fix (GREEN): 1 row — the hydrated node passes the (permissive, no
// tenant/RLS scoping in this test) visibility check.
test "fts search hydrates a node evicted from the bounded cache before search resolves the hit" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    const store = graph_store.getGlobalStore(h.allocator);
    // Harness.init uses getGlobalStore directly (no hydrate hook wired) — the
    // Task 5 test explains why this must be installed explicitly to isolate
    // the seam under test: without it an evicted node is unrecoverable and
    // this test could not distinguish "no fallback" from "fallback wired but
    // the cache itself cannot rehydrate".
    store.installNodeCacheHydrate();

    var node_id: i64 = undefined;
    {
        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'cold cache hydration widget'})");
        r.deinit(aa);

        var res = try h.runQuery("MATCH (n:FtsAuthDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        node_id = res.rows[0][0].Int;
    }

    {
        var r = try h.runQuery("CREATE INDEX ftsauth_hydrate_idx FOR (d:FtsAuthDoc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // Baseline: resident, searchable.
    {
        var res = try h.runQueryUnsnapshotted("CALL geode.fts.search('ftsauth_hydrate_idx', 'hydration')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(node_id, res.rows[0][0].Int);
    }

    // Evict from the bounded cache — durable storage is untouched. Mirrors
    // tests/test_fts_bulk_merge_maintenance.zig's Task-5 test and
    // tests/test_edge_evicted_endpoint_silent_loss.zig's established
    // real-hydrate wiring pattern (`store.nodes.remove` is the exact
    // primitive real LRU eviction uses internally).
    store.nodes.remove(@intCast(node_id));
    try testing.expect(store.nodes.getPtrUnlocked(@intCast(node_id)) == null);

    // The hit must still resolve: the node is evicted, not deleted.
    {
        var res = try h.runQueryUnsnapshotted("CALL geode.fts.search('ftsauth_hydrate_idx', 'hydration')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(node_id, res.rows[0][0].Int);
    }
}

// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-HYDRATE-001; FEATURE="FullText"; ASPECT=SearchHitHydrateNegativeControl; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-29
//
// Negative control for the same fallback: a node that is GENUINELY gone —
// durably deleted from the storage engine, not merely cache-evicted — must
// stay dropped. `store.deleteNode` (the low-level GraphStore primitive, as
// opposed to the GQL `DELETE` statement) removes the node from both the
// engine and the bounded cache WITHOUT running FTS live-maintenance, so the
// fulltext engine's posting for it goes stale on purpose here — exactly the
// scenario `filterAuthorizedHits` must still handle by dropping the hit
// (hydrate now returns null instead of a stale/wrong node). Runs through
// `runQueryUnsnapshotted` for the same reason as the positive-fallback test
// above — a bare CALL's `QueryReadSession` snapshot would independently
// re-derive "gone" from the engine and mask whether THIS function's own
// fallback handles the miss correctly.
test "fts search still drops a hit for a node genuinely deleted since indexing" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    const store = graph_store.getGlobalStore(h.allocator);
    store.installNodeCacheHydrate();

    var node_id: i64 = undefined;
    {
        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'soon to be deleted document'})");
        r.deinit(aa);

        var res = try h.runQuery("MATCH (n:FtsAuthDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        node_id = res.rows[0][0].Int;
    }

    {
        var r = try h.runQuery("CREATE INDEX ftsauth_deleted_idx FOR (d:FtsAuthDoc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    {
        var res = try h.runQueryUnsnapshotted("CALL geode.fts.search('ftsauth_deleted_idx', 'deleted')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
    }

    // Durable delete that intentionally bypasses FTS maintenance, leaving the
    // fts-storage engine's posting stale.
    store.deleteNode(@intCast(node_id));
    try testing.expect(store.nodes.getPtrUnlocked(@intCast(node_id)) == null);

    {
        var res = try h.runQueryUnsnapshotted("CALL geode.fts.search('ftsauth_deleted_idx', 'deleted')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }
}

// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-HYDRATE-001; FEATURE="FullText"; ASPECT=SearchHitHydrateTenantScoped; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-29
//
// The hydrate fallback must not bypass row visibility: a node belonging to
// the WRONG tenant, once evicted and rehydrated, must still be filtered out
// by `passesRowVisibilityFilters`. This closes the obvious failure mode of a
// naive fix — hydrating the node but forgetting to re-run the tenant/RLS
// check against the hydrated copy. Runs through `runQueryUnsnapshotted` so
// the search actually resolves the hit off the (evicted) primary store
// rather than a freshly-materialized `QueryReadSession` snapshot.
test "fts search applies tenant filter to a hydrated (evicted) node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    const store = graph_store.getGlobalStore(h.allocator);
    store.installNodeCacheHydrate();

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

    h.ctx.tenant_id = null;
    {
        var r = try h.runQuery("CREATE INDEX ftsauth_hydrate_tenant_idx FOR (d:FtsAuthDoc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // Evict the tenant_a node from the bounded cache before searching as a
    // DIFFERENT tenant — the hydrated node must still be tenant-filtered out.
    store.nodes.remove(@intCast(tenant_a_id));
    try testing.expect(store.nodes.getPtrUnlocked(@intCast(tenant_a_id)) == null);

    h.ctx.tenant_id = "tenant_b";
    {
        var res = try h.runQueryUnsnapshotted("CALL geode.fts.search('ftsauth_hydrate_tenant_idx', 'fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }

    // Sanity: the correct tenant still sees the hydrated node.
    h.ctx.tenant_id = "tenant_a";
    {
        var res = try h.runQueryUnsnapshotted("CALL geode.fts.search('ftsauth_hydrate_tenant_idx', 'fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(tenant_a_id, res.rows[0][0].Int);
    }
}

// CANARY: REQ=REQ-SONNY-1318-PROCEDURE-TENANCY; FEATURE="GraphProcedureTenantScope"; ASPECT=FtsStrictTenancyFailClosed; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-09-13
//
// SONNY-1318 review R2: `CALL geode.fts.search` did NOT fail closed under
// strict tenancy. `filterAuthorizedHits` passed the RAW `context.tenant_id`
// to `passesRowVisibilityFilters`, so an UNSCOPED session (null / "" /
// "default") resolved to the null all-tenants filter and got every tenant's
// hits — while `db.labels` (meta_dispatch.zig:115), the LSP introspection path
// (schema_introspection.zig:155) and every `CALL algo.*` procedure
// (algo_dispatch.zig) refused the same session with `TenantScopeRequired`.
//
// The fix routes it through the SAME `tenancy.resolveTenantFilter` decision.
// This test pins all three arms of that decision on the FTS surface.
test "fts search fails closed under strict tenancy with no tenant scope" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    geode.tenancy.setStrictTenancy(false);
    geode.tenancy.resetWarnState();
    defer {
        geode.tenancy.setStrictTenancy(false);
        geode.tenancy.resetWarnState();
    }

    // Same body text for both tenants, so isolation can only come from the
    // row-visibility filter and never from a term mismatch.
    var tenant_a_id: i64 = undefined;
    {
        h.ctx.tenant_id = "tenant_a";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);

        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'strict tenancy canary'})");
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

        var r = try h.runQuery("CREATE (:FtsAuthDoc {body: 'strict tenancy canary'})");
        r.deinit(aa);

        var res = try h.runQuery("MATCH (n:FtsAuthDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        tenant_b_id = res.rows[0][0].Int;
    }
    try testing.expect(tenant_a_id != tenant_b_id);

    h.ctx.tenant_id = null;
    {
        var r = try h.runQuery("CREATE INDEX ftsauth_strict_idx FOR (d:FtsAuthDoc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // (1) NON-STRICT control: an unscoped session keeps the legacy all-tenants
    //     view, byte for byte — the fix must not break single-tenant / legacy
    //     deployments. Asserted BEFORE strict is enabled so a failure here can
    //     never be mistaken for the strict arm.
    {
        h.ctx.tenant_id = null;
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_strict_idx', 'canary')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);
        var saw_a = false;
        var saw_b = false;
        for (res.rows) |row| {
            if (row[0].Int == tenant_a_id) saw_a = true;
            if (row[0].Int == tenant_b_id) saw_b = true;
        }
        try testing.expect(saw_a and saw_b);
    }

    // (1b) NON-STRICT, the OTHER two unscoped spellings. SONNY-1318 review m-4:
    //      the control above only covered `null`, but `tenancy.resolveTenantFilter`
    //      treats "" and "default" as the SAME unscoped session — that is the
    //      whole point of routing FTS through it. Under permissive tenancy all
    //      three must therefore give the identical all-tenants view.
    //
    //      This is a deliberate WIDENING for these two spellings: before the R2
    //      fix `filterAuthorizedHits` passed the raw `context.tenant_id`, so
    //      `"default"` filtered to literally-"default"-tagged rows (0 here) and
    //      `""` to literally-""-tagged rows (0 here) — FTS disagreed with the
    //      MATCH path, which has resolved all three spellings through the shared
    //      tenancy decision since GAP-0840. FTS now matches MATCH.
    for ([_][]const u8{ graph_store.DEFAULT_TENANT_ID, "" }) |unscoped| {
        h.ctx.tenant_id = unscoped;
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_strict_idx', 'canary')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);
        var saw_a = false;
        var saw_b = false;
        for (res.rows) |row| {
            if (row[0].Int == tenant_a_id) saw_a = true;
            if (row[0].Int == tenant_b_id) saw_b = true;
        }
        try testing.expect(saw_a and saw_b);
    }

    geode.tenancy.setStrictTenancy(true);
    geode.tenancy.resetWarnState();

    // (2) STRICT + NO SCOPE: refused with the same TenantScopeRequired every
    //     other tenant-scoped read surface raises — NOT silently widened.
    {
        h.ctx.tenant_id = null;
        try testing.expectError(error.TenantScopeRequired, h.runQuery("CALL geode.fts.search('ftsauth_strict_idx', 'canary')"));
    }
    {
        h.ctx.tenant_id = "";
        try testing.expectError(error.TenantScopeRequired, h.runQuery("CALL geode.fts.search('ftsauth_strict_idx', 'canary')"));
    }
    {
        h.ctx.tenant_id = graph_store.DEFAULT_TENANT_ID;
        try testing.expectError(error.TenantScopeRequired, h.runQuery("CALL geode.fts.search('ftsauth_strict_idx', 'canary')"));
    }
    // The sibling procedures share `filterAuthorizedHits`, so they refuse too.
    {
        h.ctx.tenant_id = null;
        try testing.expectError(error.TenantScopeRequired, h.runQuery("CALL geode.fts.phrase('ftsauth_strict_idx', 'strict tenancy')"));
        try testing.expectError(error.TenantScopeRequired, h.runQuery("CALL geode.fts.proximity('ftsauth_strict_idx', 'strict canary', 3)"));
    }

    // (3) STRICT + CONCRETE SCOPE: filtered exactly as before — only own rows.
    {
        h.ctx.tenant_id = "tenant_a";
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_strict_idx', 'canary')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(tenant_a_id, res.rows[0][0].Int);
    }
    {
        h.ctx.tenant_id = "tenant_b";
        var res = try h.runQuery("CALL geode.fts.search('ftsauth_strict_idx', 'canary')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(tenant_b_id, res.rows[0][0].Int);
    }
}
