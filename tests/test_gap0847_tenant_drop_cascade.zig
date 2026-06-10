//! GAP-0847 — Tenant drop: cascade data deletion + refuse-without-cascade guard.
//!
//! Before this gap, `CALL geode.tenant.drop(tenant_id)` removed ONLY the durable
//! registry record. The tenant's nodes/edges stayed in the store, tagged with a
//! tenant id that no longer existed (orphaned rows), and the GAP-0838 hierarchy
//! node for the tenant dangled. There was no way to safely delete a tenant's data
//! and no guard against silently orphaning it.
//!
//! These tests drive `CALL geode.tenant.drop` through the REAL parse → execute
//! pipeline (the same entry the QUIC/gRPC servers use) and assert the corrected
//! semantics:
//!   1. drop WITHOUT cascade is REFUSED (`error.TenantHasData`) when the tenant
//!      still has data rows; the registry record and the data survive the refusal.
//!   2. drop WITH cascade=true deletes the tenant's nodes AND edges (verified via
//!      an admin scan — zero orphan rows), removes the registry record, and
//!      cleans up the hierarchy node.
//!   3. another tenant's data is NEVER touched by a cascade drop.
//!   4. a parent with children is REFUSED without cascade (`error.TenantHasChildren`)
//!      and, with cascade, drops the whole subtree (parent + descendants).
//!   5. a leaf tenant with NO data drops cleanly with or without cascade.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;
const tenant_registry = geode.tenant_registry;
const user_mgmt = geode.user_management;
const rls = @import("rls");
const rls_types = @import("rls_types");

// ---------------------------------------------------------------------------
// Harness — a SINGLE shared global store seeded once, NOT torn down between
// calls (unlike the GAP-0839 harness), so a test can seed data, run a drop, and
// then scan the SAME store to assert orphan-freedom.
// ---------------------------------------------------------------------------

const CatalogPtr = @typeInfo(@typeInfo(@TypeOf(execution.ensureCatalogInstance)).@"fn".return_type.?).error_union.payload;

const Fixture = struct {
    reg: *tenant_registry.TenantRegistry,
    catalog: CatalogPtr,
    store: *graph_store.GraphStore,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const reg = try allocator.create(tenant_registry.TenantRegistry);
        reg.* = tenant_registry.TenantRegistry.init(allocator);
        tenant_registry.setGlobalRegistry(reg);

        const catalog = try execution.ensureCatalogInstance(allocator);
        const store = graph_store.getGlobalStore(allocator);

        return .{ .reg = reg, .catalog = catalog, .store = store, .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        tenant_registry.setGlobalRegistry(null);
        self.reg.deinit();
        self.allocator.destroy(self.reg);
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
    }

    /// Run a single statement against the shared store (no per-call teardown).
    fn run(self: *Fixture, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        var ctx = execution.ExecutionContext{ .catalog = self.catalog };
        ctx.role = null;
        ctx.user = null;
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], ctx);
    }
};

fn colIndex(res: execution.ExecutionResult, name: []const u8) ?usize {
    for (res.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

/// Count store nodes whose tenant_id == tid (admin orphan scan).
fn countTenantNodes(store: *graph_store.GraphStore, allocator: std.mem.Allocator, tid: []const u8) !usize {
    const ids = try store.getAllNodesForTenant(allocator, tid);
    defer allocator.free(ids);
    return ids.len;
}

fn countTenantEdges(store: *graph_store.GraphStore, allocator: std.mem.Allocator, tid: []const u8) !usize {
    const ids = try store.getAllEdgesForTenant(allocator, tid);
    defer allocator.free(ids);
    return ids.len;
}

/// Seed `count` nodes (each with one outgoing edge to the previous) for a tenant.
/// Returns the last node id. All rows are tagged with `tid` in graph `g`.
fn seedTenantData(store: *graph_store.GraphStore, g: []const u8, tid: []const u8, count: usize) !void {
    const labels = [_][]const u8{"Widget"};
    var prev: ?u64 = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const nid = try store.createNodeWithGraphAndTenant(&labels, g, tid);
        if (prev) |p| {
            _ = try store.createEdgeWithGraphAndTenant(p, nid, "LINKS", g, tid);
        }
        prev = nid;
    }
}

// ---------------------------------------------------------------------------
// 1. refuse-without-cascade when data exists
// ---------------------------------------------------------------------------

test "GAP-0847: drop without cascade is refused when the tenant has data" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try Fixture.init(allocator);
    defer fx.deinit();

    try fx.store.createGraph("g1");

    {
        var r = try fx.run("CALL geode.tenant.create('acme')");
        r.deinit(allocator);
    }
    try seedTenantData(fx.store, "g1", "acme", 3); // 3 nodes, 2 edges

    // Sanity: data is present.
    try testing.expectEqual(@as(usize, 3), try countTenantNodes(fx.store, allocator, "acme"));
    try testing.expectEqual(@as(usize, 2), try countTenantEdges(fx.store, allocator, "acme"));

    // Non-cascade drop must be REFUSED — and must NOT remove the registry record
    // or any data.
    try testing.expectError(error.TenantHasData, fx.run("CALL geode.tenant.drop('acme')"));
    try testing.expect(fx.reg.contains("acme"));
    try testing.expectEqual(@as(usize, 3), try countTenantNodes(fx.store, allocator, "acme"));
    try testing.expectEqual(@as(usize, 2), try countTenantEdges(fx.store, allocator, "acme"));

    // Explicit cascade=false is equivalent to omitting it.
    try testing.expectError(error.TenantHasData, fx.run("CALL geode.tenant.drop('acme', false)"));
    try testing.expect(fx.reg.contains("acme"));
}

// ---------------------------------------------------------------------------
// 2. cascade deletes data + 3. leaves other tenants untouched
// ---------------------------------------------------------------------------

test "GAP-0847: cascade drop deletes the tenant's nodes+edges and leaves other tenants intact" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try Fixture.init(allocator);
    defer fx.deinit();

    try fx.store.createGraph("g1");

    {
        var r = try fx.run("CALL geode.tenant.create('acme')");
        r.deinit(allocator);
    }
    {
        var r = try fx.run("CALL geode.tenant.create('globex')");
        r.deinit(allocator);
    }
    try seedTenantData(fx.store, "g1", "acme", 4); // 4 nodes, 3 edges
    try seedTenantData(fx.store, "g1", "globex", 2); // 2 nodes, 1 edge

    // Cascade drop of acme.
    {
        var r = try fx.run("CALL geode.tenant.drop('acme', true)");
        defer r.deinit(allocator);
        const di = colIndex(r, "dropped").?;
        const ni = colIndex(r, "nodes_deleted").?;
        const ei = colIndex(r, "edges_deleted").?;
        try testing.expect(r.rows[0][di].Bool);
        try testing.expectEqual(@as(i64, 4), r.rows[0][ni].Int);
        try testing.expectEqual(@as(i64, 3), r.rows[0][ei].Int);
    }

    // acme: zero orphan rows, registry record gone.
    try testing.expectEqual(@as(usize, 0), try countTenantNodes(fx.store, allocator, "acme"));
    try testing.expectEqual(@as(usize, 0), try countTenantEdges(fx.store, allocator, "acme"));
    try testing.expect(!fx.reg.contains("acme"));

    // globex: completely untouched.
    try testing.expectEqual(@as(usize, 2), try countTenantNodes(fx.store, allocator, "globex"));
    try testing.expectEqual(@as(usize, 1), try countTenantEdges(fx.store, allocator, "globex"));
    try testing.expect(fx.reg.contains("globex"));
}

// ---------------------------------------------------------------------------
// 4. parent/child: refuse without cascade, drop whole subtree with cascade
// ---------------------------------------------------------------------------

test "GAP-0847: parent with children is refused without cascade; cascade drops the subtree" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try Fixture.init(allocator);
    defer fx.deinit();

    // A live expr-RLS engine so the dispatcher's hierarchy seam targets a real
    // HierarchyManager (the server-boot path).
    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();
    rls_types.setGlobalExprRLSEngine(@ptrCast(&engine));
    defer rls_types.setGlobalExprRLSEngine(null);

    try fx.store.createGraph("g1");

    {
        var r = try fx.run("CALL geode.tenant.create('acme')");
        r.deinit(allocator);
    }
    {
        var r = try fx.run("CALL geode.tenant.create('acme-bu1', 'acme')");
        r.deinit(allocator);
    }
    try seedTenantData(fx.store, "g1", "acme", 2); // parent data
    try seedTenantData(fx.store, "g1", "acme-bu1", 3); // child data

    // The hierarchy knows the parent has a child.
    try testing.expect(engine.hierarchy_manager.hasChildren("acme"));

    // Non-cascade drop of the parent is refused (would orphan the child).
    try testing.expectError(error.TenantHasChildren, fx.run("CALL geode.tenant.drop('acme')"));
    try testing.expect(fx.reg.contains("acme"));
    try testing.expect(fx.reg.contains("acme-bu1"));

    // Cascade drop removes the WHOLE subtree: parent + child, data + records.
    {
        var r = try fx.run("CALL geode.tenant.drop('acme', true)");
        defer r.deinit(allocator);
        const di = colIndex(r, "dropped").?;
        try testing.expect(r.rows[0][di].Bool);
    }

    try testing.expect(!fx.reg.contains("acme"));
    try testing.expect(!fx.reg.contains("acme-bu1"));
    try testing.expect(!engine.hierarchy_manager.contains("acme"));
    try testing.expect(!engine.hierarchy_manager.contains("acme-bu1"));

    // Zero orphan rows for the entire subtree.
    try testing.expectEqual(@as(usize, 0), try countTenantNodes(fx.store, allocator, "acme"));
    try testing.expectEqual(@as(usize, 0), try countTenantEdges(fx.store, allocator, "acme"));
    try testing.expectEqual(@as(usize, 0), try countTenantNodes(fx.store, allocator, "acme-bu1"));
    try testing.expectEqual(@as(usize, 0), try countTenantEdges(fx.store, allocator, "acme-bu1"));
}

test "GAP-0847: cascade drop removes a deep subtree (grandchildren) bottom-up" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try Fixture.init(allocator);
    defer fx.deinit();

    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();
    rls_types.setGlobalExprRLSEngine(@ptrCast(&engine));
    defer rls_types.setGlobalExprRLSEngine(null);

    try fx.store.createGraph("g1");

    // org → unit → team (three levels), each with data.
    for ([_][2]?[]const u8{
        .{ "org", null },
        .{ "unit", "org" },
        .{ "team", "unit" },
    }) |pair| {
        const q = if (pair[1]) |p|
            try std.fmt.allocPrint(allocator, "CALL geode.tenant.create('{s}', '{s}')", .{ pair[0].?, p })
        else
            try std.fmt.allocPrint(allocator, "CALL geode.tenant.create('{s}')", .{pair[0].?});
        defer allocator.free(q);
        var r = try fx.run(q);
        r.deinit(allocator);
    }
    try seedTenantData(fx.store, "g1", "org", 1);
    try seedTenantData(fx.store, "g1", "unit", 2);
    try seedTenantData(fx.store, "g1", "team", 3);

    // Cascade drop the root removes the entire 3-level subtree.
    {
        var r = try fx.run("CALL geode.tenant.drop('org', true)");
        r.deinit(allocator);
    }

    for ([_][]const u8{ "org", "unit", "team" }) |t| {
        try testing.expect(!fx.reg.contains(t));
        try testing.expect(!engine.hierarchy_manager.contains(t));
        try testing.expectEqual(@as(usize, 0), try countTenantNodes(fx.store, allocator, t));
        try testing.expectEqual(@as(usize, 0), try countTenantEdges(fx.store, allocator, t));
    }
}

// ---------------------------------------------------------------------------
// 5. empty tenant drops cleanly without cascade
// ---------------------------------------------------------------------------

test "GAP-0847: a tenant with no data drops cleanly without cascade" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try Fixture.init(allocator);
    defer fx.deinit();

    {
        var r = try fx.run("CALL geode.tenant.create('empty')");
        r.deinit(allocator);
    }

    {
        var r = try fx.run("CALL geode.tenant.drop('empty')");
        defer r.deinit(allocator);
        const di = colIndex(r, "dropped").?;
        const ni = colIndex(r, "nodes_deleted").?;
        const ei = colIndex(r, "edges_deleted").?;
        try testing.expect(r.rows[0][di].Bool);
        try testing.expectEqual(@as(i64, 0), r.rows[0][ni].Int);
        try testing.expectEqual(@as(i64, 0), r.rows[0][ei].Int);
    }
    try testing.expect(!fx.reg.contains("empty"));
}

// ---------------------------------------------------------------------------
// 6. dropping an unknown tenant errors (TenantNotFound), no data side effects
// ---------------------------------------------------------------------------

test "GAP-0847: dropping an unknown tenant returns TenantNotFound" {
    const allocator = testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    var fx = try Fixture.init(allocator);
    defer fx.deinit();

    try testing.expectError(
        tenant_registry.RegistryError.TenantNotFound,
        fx.run("CALL geode.tenant.drop('ghost', true)"),
    );
}
