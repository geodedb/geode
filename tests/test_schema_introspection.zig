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
