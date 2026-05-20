// GPS Phase 3 — Metadata Filtering Unit Tests
//
// Verifies that db.labels(), db.relationshipTypes(), and db.propertyKeys()
// honour ctx.tenant_id and do NOT leak metadata across tenant boundaries.
//
// Strategy: spin up a single shared GraphStore, insert nodes/edges under two
// tenant IDs, then call executeDb* with a context bound to one tenant and
// assert the other tenant's metadata is absent.
//
// These tests call the internal `executeDb*` helpers directly (not via the
// full GQL execution path) so they work without a network stack, avoid the
// catalog singleton contention present in the meta_procedures suite, and
// isolate exactly the filtering logic being changed in tasks 3-4/3-5/3-6.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;

// ---------------------------------------------------------------------------
// Minimal test harness
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
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

    /// Build an ExecutionContext pinned to the given tenant.
    pub fn ctxForTenant(self: *const Harness, tenant_id: ?[]const u8) execution.ExecutionContext {
        var c = self.ctx;
        c.tenant_id = tenant_id;
        return c;
    }
};

// ===========================================================================
// Task 3-4 — db.labels() must filter by tenant
// CANARY: REQ=REQ-GPS-METADATA-001; FEATURE="GPS Metadata Isolation"; ASPECT=DbLabelsTenantFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

test "db.labels() returns only tenant_a labels, not tenant_b labels" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    // tenant_a gets Employee + Department
    const emp_labels = [_][]const u8{"Employee"};
    const dep_labels = [_][]const u8{"Department"};
    const cust_labels = [_][]const u8{"Customer"};
    _ = try store.createNodeWithGraphAndTenant(&emp_labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&dep_labels, "default", "tenant_a");
    // tenant_b gets Customer
    _ = try store.createNodeWithGraphAndTenant(&cust_labels, "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbLabelsForTest(
        allocator,
        store,
        h.ctxForTenant("tenant_a"),
    );
    defer res.deinit(allocator);

    // Must see Employee + Department
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    // Rows are sorted ascending
    try std.testing.expectEqualStrings("Department", res.rows[0][0].Str);
    try std.testing.expectEqualStrings("Employee", res.rows[1][0].Str);
}

test "db.labels() with null tenant sees all labels (admin path)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const emp_labels = [_][]const u8{"Employee"};
    const cust_labels = [_][]const u8{"Customer"};
    _ = try store.createNodeWithGraphAndTenant(&emp_labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&cust_labels, "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbLabelsForTest(
        allocator,
        store,
        h.ctxForTenant(null),
    );
    defer res.deinit(allocator);

    // Admin (null tenant) must see both
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}

// ===========================================================================
// Task 3-5 — db.relationshipTypes() must filter by tenant
// CANARY: REQ=REQ-GPS-METADATA-002; FEATURE="GPS Metadata Isolation"; ASPECT=DbRelationshipTypesTenantFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

test "db.relationshipTypes() returns only tenant_a edge types, not tenant_b" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const na2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");
    const nb2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    _ = try store.createEdgeWithGraphAndTenant(na1, na2, "KNOWS", "default", "tenant_a");
    _ = try store.createEdgeWithGraphAndTenant(nb1, nb2, "FOLLOWS", "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbRelationshipTypesForTest(
        allocator,
        store,
        h.ctxForTenant("tenant_a"),
    );
    defer res.deinit(allocator);

    // Must see KNOWS only, not FOLLOWS
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("KNOWS", res.rows[0][0].Str);
}

test "db.relationshipTypes() with null tenant sees all edge types (admin path)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const na2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");
    const nb2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    _ = try store.createEdgeWithGraphAndTenant(na1, na2, "KNOWS", "default", "tenant_a");
    _ = try store.createEdgeWithGraphAndTenant(nb1, nb2, "FOLLOWS", "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbRelationshipTypesForTest(
        allocator,
        store,
        h.ctxForTenant(null),
    );
    defer res.deinit(allocator);

    // Admin must see both
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}

// ===========================================================================
// Task 3-6 — db.propertyKeys() must filter by tenant
// CANARY: REQ=REQ-GPS-METADATA-003; FEATURE="GPS Metadata Isolation"; ASPECT=DbPropertyKeysTenantFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

test "db.propertyKeys() returns only tenant_a property keys, not tenant_b" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    // tenant_a has "name" and "age"
    try store.setNodeProperty(na, "name", .{ .String = "Alice" });
    try store.setNodeProperty(na, "age", .{ .Int = 30 });

    // tenant_b has "secret_key" — must NOT appear for tenant_a
    try store.setNodeProperty(nb, "secret_key", .{ .String = "hidden" });

    var res = try geode.meta_dispatch.executeDbPropertyKeysForTest(
        allocator,
        store,
        h.ctxForTenant("tenant_a"),
    );
    defer res.deinit(allocator);

    // Must see "age" + "name" only (sorted), not "secret_key"
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    try std.testing.expectEqualStrings("age", res.rows[0][0].Str);
    try std.testing.expectEqualStrings("name", res.rows[1][0].Str);
}

test "db.propertyKeys() with null tenant sees all property keys (admin path)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    try store.setNodeProperty(na, "name", .{ .String = "Alice" });
    try store.setNodeProperty(nb, "secret_key", .{ .String = "hidden" });

    var res = try geode.meta_dispatch.executeDbPropertyKeysForTest(
        allocator,
        store,
        h.ctxForTenant(null),
    );
    defer res.deinit(allocator);

    // Admin must see both
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}

// ===========================================================================
// Task 3-7 — SHOW GRAPHS must filter by gps.decide(.bind_graph)
// CANARY: REQ=REQ-GPS-METADATA-002; FEATURE="GPS Metadata Isolation"; ASPECT=ShowGraphsFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

// Shorthand aliases used across the new tests below.
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const catalog_mod = geode.catalog;
const ast_mod = geode.ast;

// Build a Principal for testing. All GPS-relevant fields populated; the caller
// provides role_names (slice) and username.
fn makePrincipal(user_id: u64, username: ?[]const u8, roles: []const []const u8) principal_mod.Principal {
    return principal_mod.Principal{
        .user_id = user_id,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

// Verify the decision contract: a principal with a grant on "hr" but not
// "sales" receives .allow for "hr" and .unauthorized for "sales". This
// matches exactly what the SHOW GRAPHS handler uses to gate each graph name.
test "SHOW GRAPHS: decide(.bind_graph) allows hr but denies sales for grant-limited user" {
    const Stub = struct {
        fn check(username: []const u8, graph_name: []const u8, action: u8) bool {
            return std.mem.eql(u8, username, "alice") and
                std.mem.eql(u8, graph_name, "hr") and
                action == 0;
        }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = makePrincipal(10, "alice", &role_names);

    // hr -> allow
    const req_hr = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = "hr" },
    };
    const d_hr = try gps.decide(std.testing.allocator, &req_hr);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_hr.kind);

    // sales -> not allowed (alice has no grant on "sales")
    const req_sales = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = "sales" },
    };
    const d_sales = try gps.decide(std.testing.allocator, &req_sales);
    try std.testing.expect(d_sales.kind != .allow);
}

// Admin principal always gets .allow for any graph — verifying the handler
// will never filter out graphs for Admin users.
test "SHOW GRAPHS: decide(.bind_graph) allows Admin to see any graph" {
    const role_names = [_][]const u8{"Admin"};
    const p = makePrincipal(1, "admin", &role_names);

    for ([_][]const u8{ "hr", "sales", "any_graph" }) |graph| {
        const req = gps.DecisionRequest{
            .principal = &p,
            .action = .bind_graph,
            .resource = .{ .graph = graph },
        };
        const d = try gps.decide(std.testing.allocator, &req);
        try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    }
}

// Integration test: call executeShow directly. Without a principal the handler
// must return all graphs (legacy compat). With a principal that has a grant
// only on "hr", the "sales" graph must be absent from the output.
test "SHOW GRAPHS: executeShow filters graphs by principal's bind_graph access" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    // Create two graphs in the store
    store.createGraph("hr") catch {};
    store.createGraph("sales") catch {};

    // Stub: alice has Read grant on "hr" only
    const Stub = struct {
        fn check(username: []const u8, graph_name: []const u8, action: u8) bool {
            return std.mem.eql(u8, username, "alice") and
                std.mem.eql(u8, graph_name, "hr") and
                action == 0;
        }
    };
    const prev_fn = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev_fn;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = makePrincipal(20, "alice", &role_names);

    // Context with principal — should filter
    var ctx_with_principal = h.ctx;
    ctx_with_principal.principal = &p;

    const show_stmt = ast_mod.ShowStatement{ .show_type = .graphs };
    var res = try execution.executeShow(allocator, show_stmt, ctx_with_principal);
    defer res.deinit(allocator);

    // alice can only see "hr", not "sales"
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("hr", res.rows[0][0].Str);

    // Without principal — legacy compat: must see both "hr" and "sales"
    var res2 = try execution.executeShow(allocator, show_stmt, h.ctx);
    defer res2.deinit(allocator);
    // Both graphs must be present (may also include "default" if created by harness)
    var found_hr = false;
    var found_sales = false;
    for (res2.rows) |row| {
        if (std.mem.eql(u8, row[0].Str, "hr")) found_hr = true;
        if (std.mem.eql(u8, row[0].Str, "sales")) found_sales = true;
    }
    try std.testing.expect(found_hr);
    try std.testing.expect(found_sales);
}

// ===========================================================================
// Task 3-8 — SHOW INDEXES and SHOW CONSTRAINTS filter by active graph
// CANARY: REQ=REQ-GPS-METADATA-003; FEATURE="GPS Metadata Isolation"; ASPECT=ShowIndexesFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// CANARY: REQ=REQ-GPS-METADATA-004; FEATURE="GPS Metadata Isolation"; ASPECT=ShowConstraintsFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

// When a principal is bound to an active graph, SHOW INDEXES/CONSTRAINTS gate
// on decide(.bind_graph) for that active graph. A principal with no grant on
// the active graph must see zero rows. A principal with a grant sees all rows.
// Legacy path (no principal): all rows returned unchanged.
test "SHOW INDEXES: executeShow with denied active_graph returns empty result" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Register an index in the catalog so we have something to filter
    try h.ctx.catalog.addIndex(catalog_mod.IndexInfo{
        .name = "idx_person_name",
        .index_type = "btree",
        .table_name = "Person",
        .columns = @constCast(&[_][]const u8{"name"}),
    });

    // Stub: deny everything for this principal
    const Stub = struct {
        fn check(_: []const u8, _: []const u8, _: u8) bool {
            return false;
        }
    };
    const prev_fn = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev_fn;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = makePrincipal(30, "bob", &role_names);

    // Session with active_graph "restricted" — bob has no grant on it
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    session.graph = try allocator.dupe(u8, "restricted");

    var ctx = h.ctx;
    ctx.principal = &p;
    ctx.session_state = &session;

    const show_stmt = ast_mod.ShowStatement{ .show_type = .indexes };
    var res = try execution.executeShow(allocator, show_stmt, ctx);
    defer res.deinit(allocator);

    // Denied: no rows
    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}

test "SHOW INDEXES: executeShow with allowed active_graph returns all indexes" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Register two indexes
    try h.ctx.catalog.addIndex(catalog_mod.IndexInfo{
        .name = "idx_person_name",
        .index_type = "btree",
        .table_name = "Person",
        .columns = @constCast(&[_][]const u8{"name"}),
    });
    try h.ctx.catalog.addIndex(catalog_mod.IndexInfo{
        .name = "idx_company_id",
        .index_type = "hash",
        .table_name = "Company",
        .columns = @constCast(&[_][]const u8{"id"}),
    });

    // Stub: allow alice on "hr"
    const Stub = struct {
        fn check(username: []const u8, graph_name: []const u8, action: u8) bool {
            return std.mem.eql(u8, username, "alice") and
                std.mem.eql(u8, graph_name, "hr") and
                action == 0;
        }
    };
    const prev_fn = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev_fn;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = makePrincipal(40, "alice", &role_names);

    // Session with active_graph "hr" — alice has a Read grant
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    session.graph = try allocator.dupe(u8, "hr");

    var ctx = h.ctx;
    ctx.principal = &p;
    ctx.session_state = &session;

    const show_stmt = ast_mod.ShowStatement{ .show_type = .indexes };
    var res = try execution.executeShow(allocator, show_stmt, ctx);
    defer res.deinit(allocator);

    // Both indexes must be visible
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}

test "SHOW INDEXES: executeShow without principal returns all indexes (legacy compat)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.ctx.catalog.addIndex(catalog_mod.IndexInfo{
        .name = "idx_legacy",
        .index_type = "btree",
        .table_name = "Node",
        .columns = @constCast(&[_][]const u8{"prop"}),
    });

    const show_stmt = ast_mod.ShowStatement{ .show_type = .indexes };
    var res = try execution.executeShow(allocator, show_stmt, h.ctx);
    defer res.deinit(allocator);

    // No principal: all indexes returned
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
}

test "SHOW CONSTRAINTS: executeShow with denied active_graph returns empty result" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Register a constraint
    try h.ctx.catalog.addConstraint(catalog_mod.ConstraintInfo{
        .name = "unique_person_name",
        .constraint_type = .unique,
        .label = "Person",
        .properties = @constCast(&[_][]const u8{"name"}),
        .is_enforced = true,
    });

    // Deny stub
    const Stub = struct {
        fn check(_: []const u8, _: []const u8, _: u8) bool {
            return false;
        }
    };
    const prev_fn = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev_fn;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = makePrincipal(50, "eve", &role_names);

    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    session.graph = try allocator.dupe(u8, "forbidden");

    var ctx = h.ctx;
    ctx.principal = &p;
    ctx.session_state = &session;

    const show_stmt = ast_mod.ShowStatement{ .show_type = .constraints };
    var res = try execution.executeShow(allocator, show_stmt, ctx);
    defer res.deinit(allocator);

    // Denied: no rows
    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}

test "SHOW CONSTRAINTS: executeShow with allowed active_graph returns all constraints" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.ctx.catalog.addConstraint(catalog_mod.ConstraintInfo{
        .name = "unique_user_email",
        .constraint_type = .unique,
        .label = "User",
        .properties = @constCast(&[_][]const u8{"email"}),
        .is_enforced = true,
    });

    // Allow stub for alice on "hr"
    const Stub = struct {
        fn check(username: []const u8, graph_name: []const u8, action: u8) bool {
            return std.mem.eql(u8, username, "alice") and
                std.mem.eql(u8, graph_name, "hr") and
                action == 0;
        }
    };
    const prev_fn = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev_fn;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = makePrincipal(60, "alice", &role_names);

    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    session.graph = try allocator.dupe(u8, "hr");

    var ctx = h.ctx;
    ctx.principal = &p;
    ctx.session_state = &session;

    const show_stmt = ast_mod.ShowStatement{ .show_type = .constraints };
    var res = try execution.executeShow(allocator, show_stmt, ctx);
    defer res.deinit(allocator);

    // One constraint must be visible
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
}

test "SHOW CONSTRAINTS: executeShow without principal returns all constraints (legacy compat)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.ctx.catalog.addConstraint(catalog_mod.ConstraintInfo{
        .name = "legacy_constraint",
        .constraint_type = .not_null,
        .label = "Node",
        .properties = @constCast(&[_][]const u8{"id"}),
        .is_enforced = true,
    });

    const show_stmt = ast_mod.ShowStatement{ .show_type = .constraints };
    var res = try execution.executeShow(allocator, show_stmt, h.ctx);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
}
