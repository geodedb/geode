//! GAP-0839 — Tenant lifecycle surface (`CALL geode.tenant.*`) end-to-end tests.
//!
//! Before this gap, a tenant only "existed" implicitly by data being tagged with
//! its tenant_id: there was NO create/list/show/drop surface, no production seam
//! to populate the GAP-0838 HierarchyManager, no production path to configure a
//! per-tenant quota (GAP-0289 setQuota was tests-only), and the admin_tenant GPS
//! action had ZERO dispatch callers.
//!
//! These tests drive the native `geode.tenant.*` procedure family through the
//! REAL parse → execute pipeline (`execution.executeStatementWithContext`, the
//! same entry the QUIC/gRPC servers use), exactly like ts_ingest_roundtrip.zig
//! does for `geode.ts.*`. They assert:
//!   1. create → list/show reflect the tenant
//!   2. create-with-parent populates the GAP-0838 hierarchy (via canAccessTenant)
//!   3. set_quota changes the resolved production quota (not default_quota)
//!   4. an unauthorized (non-Admin) caller is rejected (admin_tenant authz)
//!   5. persistence — a registry reload/hydrate sees a created tenant
//!
//! The dispatcher's admin_tenant gate is bypassed when auth is disabled (the
//! same posture as every other admin op). Tests that want to exercise authz turn
//! auth ON and drive an explicit role; the rest disable auth to isolate registry
//! behavior.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const tenant_registry = geode.tenant_registry;
const tenant_quota = geode.tenant_quota;
const user_mgmt = geode.user_management;
const rls = @import("rls");
const rls_types = @import("rls_types");

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Parse + execute a single statement through the full execution path with an
/// explicit context (so we can attach a role for authz tests). Frees the parse
/// arena before returning; results hold only dupe'd scalars/strings.
fn runQueryCtx(
    allocator: std.mem.Allocator,
    query: []const u8,
    role: ?user_mgmt.Role,
    user: ?[]const u8,
) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    defer geode.graph_store.deinitGlobalStore();

    var ctx = execution.ExecutionContext{ .catalog = catalog };
    ctx.role = role;
    ctx.user = user;
    return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
}

/// Default helper: auth disabled (registry-behavior tests don't care about authz).
fn runQuery(allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
    return runQueryCtx(allocator, query, null, null);
}

fn colIndex(res: execution.ExecutionResult, name: []const u8) ?usize {
    for (res.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build the absolute path of a
// testing.tmpDir from cwd + its sub_path (mirrors auth_graph_manager's helper).
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Install a fresh in-memory registry as the global for the duration of a test.
const RegistryFixture = struct {
    reg: *tenant_registry.TenantRegistry,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !RegistryFixture {
        const reg = try allocator.create(tenant_registry.TenantRegistry);
        reg.* = tenant_registry.TenantRegistry.init(allocator);
        tenant_registry.setGlobalRegistry(reg);
        return .{ .reg = reg, .allocator = allocator };
    }

    fn deinit(self: *RegistryFixture) void {
        tenant_registry.setGlobalRegistry(null);
        self.reg.deinit();
        self.allocator.destroy(self.reg);
    }
};

// ---------------------------------------------------------------------------
// 1. create → list/show reflect it
// ---------------------------------------------------------------------------

test "GAP-0839: create then list and show reflect the tenant" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try RegistryFixture.init(allocator);
    defer fx.deinit();

    {
        var r = try runQuery(allocator, "CALL geode.tenant.create('acme')");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        const ti = colIndex(r, "tenant_id").?;
        try testing.expectEqualStrings("acme", r.rows[0][ti].Str);
    }

    // list() must contain acme.
    {
        var r = try runQuery(allocator, "CALL geode.tenant.list()");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        const ti = colIndex(r, "tenant_id").?;
        try testing.expectEqualStrings("acme", r.rows[0][ti].Str);
    }

    // show('acme') returns exactly one row.
    {
        var r = try runQuery(allocator, "CALL geode.tenant.show('acme')");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        const ti = colIndex(r, "tenant_id").?;
        try testing.expectEqualStrings("acme", r.rows[0][ti].Str);
    }

    // show() of a missing tenant returns zero rows (no error).
    {
        var r = try runQuery(allocator, "CALL geode.tenant.show('ghost')");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), r.rows.len);
    }
}

test "GAP-0839: drop removes the tenant from list/show" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try RegistryFixture.init(allocator);
    defer fx.deinit();

    {
        var r = try runQuery(allocator, "CALL geode.tenant.create('acme')");
        r.deinit(allocator);
    }
    {
        var r = try runQuery(allocator, "CALL geode.tenant.drop('acme')");
        defer r.deinit(allocator);
        const di = colIndex(r, "dropped").?;
        try testing.expect(r.rows[0][di].Bool);
    }
    {
        var r = try runQuery(allocator, "CALL geode.tenant.show('acme')");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), r.rows.len);
    }
}

// ---------------------------------------------------------------------------
// 2. create-with-parent populates the GAP-0838 hierarchy
// ---------------------------------------------------------------------------

test "GAP-0839: create with parent populates the production HierarchyManager" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try RegistryFixture.init(allocator);
    defer fx.deinit();

    // Stand up a live expr-RLS engine and publish it so the dispatcher's
    // addToHierarchy seam targets a real HierarchyManager (the server-boot path).
    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();
    rls_types.setGlobalExprRLSEngine(@ptrCast(&engine));
    defer rls_types.setGlobalExprRLSEngine(null);

    {
        var r = try runQuery(allocator, "CALL geode.tenant.create('acme')");
        r.deinit(allocator);
    }
    {
        var r = try runQuery(allocator, "CALL geode.tenant.create('acme-bu1', 'acme')");
        defer r.deinit(allocator);
        const pi = colIndex(r, "parent").?;
        try testing.expectEqualStrings("acme", r.rows[0][pi].Str);
    }

    // The hierarchy must now answer the ancestor→descendant access query that
    // CaaST needs. Parent can reach child; child cannot reach parent.
    try testing.expect(try engine.hierarchy_manager.canAccessTenant("acme", "acme-bu1"));
    try testing.expect(!try engine.hierarchy_manager.canAccessTenant("acme-bu1", "acme"));
}

// ---------------------------------------------------------------------------
// 3. set_quota changes the resolved production quota (not default)
// ---------------------------------------------------------------------------

test "GAP-0839: set_quota makes the production quota manager resolve a non-default quota" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try RegistryFixture.init(allocator);
    defer fx.deinit();

    // Publish a real production quota manager (the seam set_quota must reach).
    var qm = tenant_quota.TenantQuotaManager.init(allocator);
    defer qm.deinit();
    tenant_quota.setGlobalQuotaManager(&qm);
    defer tenant_quota.setGlobalQuotaManager(null);

    // Before any set_quota, a tenant resolves to the generous default.
    const before = qm.getQuota("acme");
    try testing.expectEqual(@as(u32, 100), before.max_connections);

    {
        var r = try runQuery(allocator, "CALL geode.tenant.create('acme')");
        r.deinit(allocator);
    }
    {
        // set_quota(tenant, max_connections, max_concurrent_queries, max_graphs, max_nodes_per_graph)
        var r = try runQuery(allocator, "CALL geode.tenant.set_quota('acme', 5, 2, 10, 500)");
        defer r.deinit(allocator);
        const ui = colIndex(r, "updated").?;
        try testing.expect(r.rows[0][ui].Bool);
    }

    // The live quota manager now resolves the override — NOT the default.
    const after = qm.getQuota("acme");
    try testing.expectEqual(@as(u32, 5), after.max_connections);
    try testing.expectEqual(@as(u32, 2), after.max_concurrent_queries);
    try testing.expectEqual(@as(u32, 10), after.max_graphs);
    try testing.expectEqual(@as(u64, 500), after.max_nodes_per_graph);

    // And list() surfaces the override in its quota columns.
    {
        var r = try runQuery(allocator, "CALL geode.tenant.list()");
        defer r.deinit(allocator);
        const ci = colIndex(r, "max_connections").?;
        try testing.expectEqual(@as(i64, 5), r.rows[0][ci].Int);
    }
}

// ---------------------------------------------------------------------------
// 4. admin_tenant authorization (fail-closed)
// ---------------------------------------------------------------------------

test "GAP-0839: non-admin caller is rejected by admin_tenant authz" {
    const allocator = testing.allocator;
    // Auth ENABLED: the admin_tenant gate is live.
    user_mgmt.setAuthEnabled(true);

    var fx = try RegistryFixture.init(allocator);
    defer fx.deinit();

    // A ReadOnly user must NOT be able to create a tenant.
    try testing.expectError(
        error.Unauthorized,
        runQueryCtx(allocator, "CALL geode.tenant.create('acme')", .ReadOnly, "bob"),
    );
    // The registry must be untouched by the rejected call.
    try testing.expect(!fx.reg.contains("acme"));

    // Even a read op (list) is admin-only.
    try testing.expectError(
        error.Unauthorized,
        runQueryCtx(allocator, "CALL geode.tenant.list()", .ReadOnly, "bob"),
    );
}

test "GAP-0839: admin caller is authorized for tenant lifecycle" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(true);

    var fx = try RegistryFixture.init(allocator);
    defer fx.deinit();

    // An Admin user CAN create a tenant.
    {
        var r = try runQueryCtx(allocator, "CALL geode.tenant.create('acme')", .Admin, "root");
        defer r.deinit(allocator);
        const ti = colIndex(r, "tenant_id").?;
        try testing.expectEqualStrings("acme", r.rows[0][ti].Str);
    }
    try testing.expect(fx.reg.contains("acme"));
}

// ---------------------------------------------------------------------------
// 5. durable persistence: a reload/hydrate sees a created tenant
// ---------------------------------------------------------------------------

test "GAP-0839: created tenant survives a durable registry reload" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    // First "process": create acme + acme-bu1 with a quota override, through the
    // CALL surface against a durable registry.
    {
        var reg = try tenant_registry.TenantRegistry.initWithDataDir(allocator, data_dir);
        defer reg.deinit();
        tenant_registry.setGlobalRegistry(&reg);
        defer tenant_registry.setGlobalRegistry(null);

        {
            var r = try runQuery(allocator, "CALL geode.tenant.create('acme')");
            r.deinit(allocator);
        }
        {
            var r = try runQuery(allocator, "CALL geode.tenant.create('acme-bu1', 'acme')");
            r.deinit(allocator);
        }
        {
            var r = try runQuery(allocator, "CALL geode.tenant.set_quota('acme-bu1', 7, 3, 11, 999)");
            r.deinit(allocator);
        }
    }

    // Second "process": a fresh durable registry over the SAME data dir must
    // hydrate the tenants — proving lifecycle survives restart.
    {
        var reg2 = try tenant_registry.TenantRegistry.initWithDataDir(allocator, data_dir);
        defer reg2.deinit();
        tenant_registry.setGlobalRegistry(&reg2);
        defer tenant_registry.setGlobalRegistry(null);

        var r = try runQuery(allocator, "CALL geode.tenant.show('acme-bu1')");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        const ti = colIndex(r, "tenant_id").?;
        const pi = colIndex(r, "parent").?;
        const ci = colIndex(r, "max_connections").?;
        try testing.expectEqualStrings("acme-bu1", r.rows[0][ti].Str);
        try testing.expectEqualStrings("acme", r.rows[0][pi].Str);
        try testing.expectEqual(@as(i64, 7), r.rows[0][ci].Int);
    }
}
