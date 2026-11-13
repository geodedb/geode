// CANARY: REQ=REQ-MULTI-TENANT-STRICT-001; FEATURE="StrictTenancyMode"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0840_strict_tenancy.zig:1; OWNER=security; UPDATED=2026-06-08
//
// Regression tests for GAP-0840: `tenant_id="default"`/empty disabling tenant
// isolation (cross-tenant data-leak footgun).
//
// The fix adds an opt-in strict-tenancy mode. Both tenant-filter entry points
// (`crud_operations.tenantFilterFromContext` and
// `match_operations.getSessionTenantFilter`) delegate to
// `tenancy.resolveTenantFilter`, so testing that shared decision covers both
// the CRUD (CREATE/MERGE/DELETE) and MATCH read paths.
//
// Asserts:
//   (a) strict mode ON  -> an unscoped/"default"/empty tenant-scoped op is
//       REJECTED with error.TenantScopeRequired (NOT widened to all-tenants);
//   (b) strict mode ON  -> a properly-scoped op still resolves to that tenant;
//   (c) strict mode OFF (default) -> unscoped/"default"/empty still returns the
//       no-filter (null = all-tenants) path, i.e. unchanged behaviour.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const tenancy = geode.tenancy;
const graph_store = geode.graph_store;
const execution = geode.execution;

// Ensure the process-wide flag is reset to the default (OFF) after each test so
// these tests are order-independent and don't leak strict mode into others.
fn resetTenancyFlag() void {
    tenancy.setStrictTenancy(false);
    tenancy.resetWarnState();
}

test "GAP-0840 (a): strict mode rejects unset tenant scope" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    try testing.expectError(error.TenantScopeRequired, tenancy.resolveTenantFilter(null));
}

test "GAP-0840 (a): strict mode rejects empty tenant scope" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    try testing.expectError(error.TenantScopeRequired, tenancy.resolveTenantFilter(""));
}

test "GAP-0840 (a): strict mode rejects the \"default\" wildcard tenant scope" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    try testing.expectError(
        error.TenantScopeRequired,
        tenancy.resolveTenantFilter(graph_store.DEFAULT_TENANT_ID),
    );
}

test "GAP-0840 (b): strict mode allows a properly-scoped tenant" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    const filter = try tenancy.resolveTenantFilter("tenant_alpha");
    try testing.expect(filter != null);
    try testing.expectEqualStrings("tenant_alpha", filter.?);
}

test "GAP-0840 (c): non-strict (default) mode is unchanged — unscoped returns null" {
    defer resetTenancyFlag();
    resetTenancyFlag(); // explicitly OFF for this case

    // No filter (all-tenants) is the legacy behaviour; must NOT regress.
    try testing.expect((try tenancy.resolveTenantFilter(null)) == null);
    try testing.expect((try tenancy.resolveTenantFilter("")) == null);
    try testing.expect((try tenancy.resolveTenantFilter(graph_store.DEFAULT_TENANT_ID)) == null);

    // A concrete scope still filters even in non-strict mode.
    const filter = try tenancy.resolveTenantFilter("tenant_beta");
    try testing.expect(filter != null);
    try testing.expectEqualStrings("tenant_beta", filter.?);
}

// ===========================================================================
// Behavioral end-to-end coverage for the read-path FAST-PATH bypass.
//
// The (a)/(b)/(c) cases above exercise the shared decision in isolation. The
// adversarial review found that the count / aggregate / top-K fast paths in
// `executeQueryWithContext` computed the tenant scope INLINE
// (`if tid==DEFAULT_TENANT_ID null else tid`) and short-circuited BEFORE the
// guarded executor, so strict mode was BYPASSABLE: an unscoped session got
// `count(*)`/`sum`/`avg`/top-K across ALL tenants instead of being rejected.
//
// These tests drive a real parser + real store + real executor through
// `executeStatementWithContext` (which routes `.Query` to
// `executeQueryWithContext` — the exact fast-path entry point that was fixed)
// with an UNSET session tenant under strict mode, and assert the query is
// REJECTED with error.TenantScopeRequired rather than returning rows.
//
// Without the fix (inline tenant computation feeding the fast paths) these
// tests go GREEN-but-wrong: the count/aggregate returns a row instead of
// erroring. With the fix (resolveTenantFilter + `try`) they correctly reject.
// Real store, real parser, real executor — no mocks.
// ===========================================================================

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
            // tenant_id defaults to null == UNSET session scope.
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

    // Relaxed-parse variant: `geode.parse` accepts `ORDER BY p.<key>`
    // (property-access ordering) whatever the environment, which the top-K
    // fast path needs. (`parseGql` accepts it too since SONNY-6351; with
    // GEODE_ORDER_KEYS_EXPR=0 it allows identifier keys only.)
    pub fn runQueryRelaxed(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "GAP-0840 (bypass): strict mode REJECTS unscoped count(n) fast-path" {
    defer resetTenancyFlag();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed a few nodes. Strict mode is OFF during seeding so the CREATEs
    // succeed with the unset (null) tenant.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:ST_Person {{st_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // Now enable strict mode and run the count fast-path with the still-unset
    // session tenant. Pre-fix this returned a single row {count: 5}; post-fix
    // it must reject because the session has no concrete tenant scope.
    tenancy.setStrictTenancy(true);
    try testing.expectError(
        error.TenantScopeRequired,
        h.runQuery("MATCH (n:ST_Person) RETURN count(n) AS c"),
    );
}

test "GAP-0840 (bypass): strict mode REJECTS unscoped sum() aggregate fast-path" {
    defer resetTenancyFlag();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:ST_Person {{age: {d}}})", .{20 + i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    tenancy.setStrictTenancy(true);
    try testing.expectError(
        error.TenantScopeRequired,
        h.runQuery("MATCH (p:ST_Person) RETURN sum(p.age) AS s"),
    );
}

test "GAP-0840 (bypass): strict mode REJECTS unscoped top-K ordered fast-path" {
    defer resetTenancyFlag();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:ST_Person {{age: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    tenancy.setStrictTenancy(true);
    try testing.expectError(
        error.TenantScopeRequired,
        h.runQueryRelaxed("MATCH (p:ST_Person) RETURN p.age ORDER BY p.age LIMIT 3"),
    );
}

// ===========================================================================
// Over-rejection regression (GAP-0840 narrowing).
//
// 177af0b8 placed `resolveTenantFilter(context.tenant_id)` UNCONDITIONALLY at
// the top of `executeQueryWithContext`, BEFORE checking whether the query
// touches graph data. In strict mode that wrongly rejected tenant-AGNOSTIC,
// store-free scalar queries (`RETURN 1`, the `RETURN 1 AS x` liveness probe)
// with error.TenantScopeRequired — even though they read NO tenant-scoped data.
//
// Strict mode must reject tenant-scoped GRAPH-DATA reads without a tenant, NOT
// tenant-agnostic scalar queries. These cases drive a real parser + executor
// through `executeStatementWithContext` with an UNSET session tenant under
// strict mode and assert the scalar RETURN SUCCEEDS (returns its row).
//
// Pre-fix (unconditional resolve) these FAIL with error.TenantScopeRequired
// (RED). Post-fix (resolve gated on `q.match.chains.len > 0`) they SUCCEED
// (GREEN). Real parser, real executor — no mocks.
// ===========================================================================

test "GAP-0840 (over-reject): strict mode ALLOWS store-free RETURN 1 AS x" {
    defer resetTenancyFlag();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Strict ON + UNSET session tenant. `RETURN 1 AS x` has no MATCH chain and
    // reads no tenant-scoped data, so it must NOT be rejected.
    tenancy.setStrictTenancy(true);
    var res = try h.runQuery("RETURN 1 AS x");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(usize, 1), res.rows[0].len);
    try testing.expectEqual(@as(i64, 1), res.rows[0][0].Int);
}

test "GAP-0840 (over-reject): strict mode ALLOWS bare RETURN 1" {
    defer resetTenancyFlag();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    tenancy.setStrictTenancy(true);
    var res = try h.runQuery("RETURN 1");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 1), res.rows[0][0].Int);
}

test "GAP-0840 (no-regress): non-strict mode still serves unscoped count fast-path" {
    defer resetTenancyFlag();
    resetTenancyFlag(); // explicitly OFF
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:ST_Person {{st_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // In the default (non-strict) mode the unscoped count must still succeed
    // (all-tenants), i.e. the fix must not break the legacy hot path.
    var res = try h.runQuery("MATCH (n:ST_Person) RETURN count(n) AS c");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 5), res.rows[0][0].Int);
}
