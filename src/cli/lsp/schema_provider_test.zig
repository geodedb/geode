// CANARY: REQ=REQ-LSP-SCHEMA-PROVIDER-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=LazyFetchTest; STATUS=TESTED; TEST=src/cli/lsp/schema_provider_test.zig:1; OWNER=lsp; UPDATED=2026-05-14
//
// Regression tests for src/cli/lsp/schema_provider.zig — the LSP's
// lazy-fetch wrapper over schema_introspection.zig. Task 6 only covers
// the unconditional-cache-on-first-call behaviour; TTL expiry, mutex,
// and DDL invalidation hooks land in Tasks 7-9.
//
// The "returns labels accessible to the user" case mirrors Task 5's
// test_schema_introspection.zig "filters by tenant" case so the
// SchemaProvider's first-fetch path is exercised against a real
// GraphStore + a permissive (auth_mgr = null) IntrospectionContext.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const intro = @import("schema_introspection");
const SchemaProvider = @import("schema_provider").SchemaProvider;
const graph_store = geode.graph_store;
const user_management = geode.user_management;

test "SchemaProvider returns labels accessible to the user" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    // createNode(&.{"Person"}, .{}, "tenant-a") doesn't exist on
    // GraphStore — Tasks 1-5's tests use the explicit graph+tenant
    // variant, so do the same here.
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Person"}, default_graph, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "alice",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp.deinit();

    const labels = try sp.getLabels();
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Person", labels[0]);
}
