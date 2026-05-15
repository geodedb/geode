// CANARY: REQ=REQ-LSP-SCHEMA-INTROSPECT-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=TenantFilterTest; STATUS=TESTED; TEST=tests/test_schema_introspection.zig:1; OWNER=lsp; UPDATED=2026-05-14
//
// Regression tests for src/execution/schema_introspection.zig — the
// permission-filtered schema-listing layer the LSP calls when serving
// label/edge-type completions to a logged-in user.
//
// The "filters by tenant" case exercises the no-auth-manager permissive
// path (auth_mgr = null) and ReadOnly role, which means graphVisible()
// short-circuits to true and the tenant filter on
// GraphStore.listNodeLabels does the actual work.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const intro = @import("schema_introspection");
const rls_types = @import("rls_types");
const graph_store = geode.graph_store;
const user_management = geode.user_management;

test "listLabelsForUser filters by tenant" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    // createNode(&.{"Person"}, .{}, "tenant-a") doesn't exist on
    // GraphStore — Tasks 1-3's tests used the explicit graph+tenant
    // variant, so do the same here.
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Person"}, default_graph, "tenant-a");
    _ = try store.createNodeWithGraphAndTenant(&.{"Secret"}, default_graph, "tenant-b");

    const ctx = intro.IntrospectionContext{
        .user = "alice",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    };
    const labels = try intro.listLabelsForUser(alloc, &store, ctx);
    defer intro.freeStringList(alloc, labels);
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Person", labels[0]);
}

// Helper: install a process-global RLSFilterEngine for the duration of a
// test. Caller MUST call `uninstallRLSEngine(&engine)` before the engine
// goes out of scope, otherwise other tests pick up dangling state.
fn installRLSEngine(engine: *rls_types.RLSFilterEngine) void {
    rls_types.setGlobalRLSFilterEngine(engine);
}

fn uninstallRLSEngine() void {
    rls_types.setGlobalRLSFilterEngine(null);
}

// --- Issue #817 regression coverage ------------------------------------
//
// Two users on the same graph: a label-deny RLS policy hides `Confidential`
// from `bob` but leaves `alice` alone. LSP completion is expected to
// reflect that gating.
//
// We deliberately run on the no-auth-manager path (auth_mgr = null) so the
// existing graph-level visibility check short-circuits to true and the
// label-level filter we added in #817 is what actually decides.

test "GAP #817: listLabelsForUser hides RLS-denied labels for non-admin user" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Person"}, default_graph, "");
    _ = try store.createNodeWithGraphAndTenant(&.{"Confidential"}, default_graph, "");

    var engine = rls_types.RLSFilterEngine.init(alloc);
    defer engine.deinit();
    try engine.addDenyPolicy(default_graph, "Confidential", "bob");

    installRLSEngine(&engine);
    defer uninstallRLSEngine();

    // Alice has no deny policy -- she sees both labels.
    {
        const alice_ctx = intro.IntrospectionContext{
            .user = "alice",
            .tenant_id = null,
            .role = user_management.Role.ReadOnly,
            .graph_name = default_graph,
        };
        const labels = try intro.listLabelsForUser(alloc, &store, alice_ctx);
        defer intro.freeStringList(alloc, labels);
        try testing.expectEqual(@as(usize, 2), labels.len);

        var saw_person = false;
        var saw_confidential = false;
        for (labels) |l| {
            if (std.mem.eql(u8, l, "Person")) saw_person = true;
            if (std.mem.eql(u8, l, "Confidential")) saw_confidential = true;
        }
        try testing.expect(saw_person);
        try testing.expect(saw_confidential);
    }

    // Bob is denied `Confidential` -- only `Person` should surface.
    {
        const bob_ctx = intro.IntrospectionContext{
            .user = "bob",
            .tenant_id = null,
            .role = user_management.Role.ReadOnly,
            .graph_name = default_graph,
        };
        const labels = try intro.listLabelsForUser(alloc, &store, bob_ctx);
        defer intro.freeStringList(alloc, labels);
        try testing.expectEqual(@as(usize, 1), labels.len);
        try testing.expectEqualStrings("Person", labels[0]);
    }
}

test "GAP #817: listPropertiesForLabelForUser returns empty for denied label (not error)" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Confidential"}, default_graph, "");

    var engine = rls_types.RLSFilterEngine.init(alloc);
    defer engine.deinit();
    try engine.addDenyPolicy(default_graph, "Confidential", "bob");

    installRLSEngine(&engine);
    defer uninstallRLSEngine();

    const bob_ctx = intro.IntrospectionContext{
        .user = "bob",
        .tenant_id = null,
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    };

    // Asking for properties on a denied label MUST return an empty list,
    // not an error -- the error channel would leak label existence.
    const props = try intro.listPropertiesForLabelForUser(alloc, &store, bob_ctx, "Confidential");
    defer intro.freeStringList(alloc, props);
    try testing.expectEqual(@as(usize, 0), props.len);
}

test "GAP #817: Admin role bypasses RLS label gate" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Confidential"}, default_graph, "");

    var engine = rls_types.RLSFilterEngine.init(alloc);
    defer engine.deinit();
    // Deny EVERYONE (empty username matches all users) -- Admin still sees.
    try engine.addDenyPolicy(default_graph, "Confidential", "");

    installRLSEngine(&engine);
    defer uninstallRLSEngine();

    const admin_ctx = intro.IntrospectionContext{
        .user = "root",
        .tenant_id = null,
        .role = user_management.Role.Admin,
        .graph_name = default_graph,
    };
    const labels = try intro.listLabelsForUser(alloc, &store, admin_ctx);
    defer intro.freeStringList(alloc, labels);
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Confidential", labels[0]);
}

test "GAP #817: no global RLS engine = permissive (back-compat)" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Person"}, default_graph, "");
    _ = try store.createNodeWithGraphAndTenant(&.{"Confidential"}, default_graph, "");

    // Explicitly clear the global engine so the test runs against the
    // no-engine fallback.
    uninstallRLSEngine();

    const bob_ctx = intro.IntrospectionContext{
        .user = "bob",
        .tenant_id = null,
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    };
    const labels = try intro.listLabelsForUser(alloc, &store, bob_ctx);
    defer intro.freeStringList(alloc, labels);
    // Both labels visible -- no engine means no filter (back-compat with
    // tests and --no-auth developer flows).
    try testing.expectEqual(@as(usize, 2), labels.len);
}
