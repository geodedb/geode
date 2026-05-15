// CANARY: REQ=REQ-PERF-LSP-INTROSPECTION-INDEX-001; FEATURE="LspIntrospectionIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_perf_c_lsp_introspection_index.zig:1; OWNER=perf; UPDATED=2026-05-15
//
// PERF-C (issue #814): tenant-keyed multiset for LSP introspection.
//
//   listNodeLabels         — reads from `node_labels_by_tenant`
//   listEdgeTypes          — reads from `edge_types_by_tenant`
//   listPropertiesForLabel — reads from `label_properties_by_tenant`
//
// The indexes are maintained on every create/delete/addLabel/removeLabel/
// setProperty/removeProperty path. Reference counts ensure entries are
// dropped when the last carrier node/edge is removed — the introspection
// API must never report a label/type/property no node still carries.
//
// Coverage:
//
//   1. Insert nodes across multiple tenants with overlapping labels;
//      assert listNodeLabels returns only that tenant's labels
//      (preserves the GAP-0509 isolation property).
//   2. Deleting the last node carrying a label removes it from listing.
//   3. Adding / removing properties from existing nodes updates the
//      listPropertiesForLabel output.
//   4. Cross-tenant isolation: labels in tenant_a don't appear in
//      listings for tenant_b.
//   5. Edge types follow the same pattern, including delete refcount.
//   6. addNodeLabel / removeNodeLabel keep both the label set and the
//      label-property set consistent.
//   7. Admin path (filter_tenant=null) aggregates across every tenant.
//   8. 100-node × 3-graph stress test for the dedup'd union.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

fn freeStringList(allocator: std.mem.Allocator, slice: [][]const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

test "PERF-C: listNodeLabels returns the tenant's labels" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    // tenant_a: User, Order
    _ = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&[_][]const u8{"Order"}, "g", "tenant_a");

    // tenant_b: User, Product (overlap with tenant_a on User, but distinct
    // index buckets — listing for tenant_b must NOT mention Order).
    _ = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_b");
    _ = try store.createNodeWithGraphAndTenant(&[_][]const u8{"Product"}, "g", "tenant_b");

    const labels_a = try store.listNodeLabels(allocator, "tenant_a");
    defer freeStringList(allocator, labels_a);
    try testing.expectEqual(@as(usize, 2), labels_a.len);
    try testing.expect(containsString(labels_a, "User"));
    try testing.expect(containsString(labels_a, "Order"));
    try testing.expect(!containsString(labels_a, "Product"));

    const labels_b = try store.listNodeLabels(allocator, "tenant_b");
    defer freeStringList(allocator, labels_b);
    try testing.expectEqual(@as(usize, 2), labels_b.len);
    try testing.expect(containsString(labels_b, "User"));
    try testing.expect(containsString(labels_b, "Product"));
    try testing.expect(!containsString(labels_b, "Order"));

    // Admin / no-filter path: union of every tenant.
    const labels_all = try store.listNodeLabels(allocator, null);
    defer freeStringList(allocator, labels_all);
    try testing.expectEqual(@as(usize, 3), labels_all.len);
    try testing.expect(containsString(labels_all, "User"));
    try testing.expect(containsString(labels_all, "Order"));
    try testing.expect(containsString(labels_all, "Product"));
}

test "PERF-C: deleting the last carrier node drops the label from listings" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    const order_id = try store.createNodeWithGraphAndTenant(&[_][]const u8{"Order"}, "g", "tenant_a");
    const user_id = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");
    const user_id2 = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");

    {
        const labels = try store.listNodeLabels(allocator, "tenant_a");
        defer freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 2), labels.len);
    }

    // Delete the sole Order node — Order should disappear from listings.
    store.deleteNodeNoSave(order_id);
    {
        const labels = try store.listNodeLabels(allocator, "tenant_a");
        defer freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 1), labels.len);
        try testing.expect(containsString(labels, "User"));
        try testing.expect(!containsString(labels, "Order"));
    }

    // Delete ONE of two User carriers — User must stay (refcount > 0).
    store.deleteNodeNoSave(user_id);
    {
        const labels = try store.listNodeLabels(allocator, "tenant_a");
        defer freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 1), labels.len);
        try testing.expect(containsString(labels, "User"));
    }

    // Delete the last User — listing now empty.
    store.deleteNodeNoSave(user_id2);
    {
        const labels = try store.listNodeLabels(allocator, "tenant_a");
        defer freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 0), labels.len);
    }
}

test "PERF-C: setProperty / removeProperty maintains listPropertiesForLabel" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    const usr1 = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");
    const usr2 = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");

    // No properties yet — listing should be empty.
    {
        const props = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
        defer freeStringList(allocator, props);
        try testing.expectEqual(@as(usize, 0), props.len);
    }

    try store.setNodeProperty(usr1, "email", .{ .String = "alice@example.com" });
    try store.setNodeProperty(usr1, "age", .{ .Int = 30 });
    try store.setNodeProperty(usr2, "email", .{ .String = "bob@example.com" });

    {
        const props = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
        defer freeStringList(allocator, props);
        try testing.expectEqual(@as(usize, 2), props.len);
        try testing.expect(containsString(props, "email"));
        try testing.expect(containsString(props, "age"));
    }

    // Remove `email` from one of two User carriers — should still appear
    // (other node still has it).
    store.removeNodeProperty(usr1, "email");
    {
        const props = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
        defer freeStringList(allocator, props);
        try testing.expect(containsString(props, "email"));
        try testing.expect(containsString(props, "age"));
    }

    // Remove `email` from the last User carrier — should disappear.
    store.removeNodeProperty(usr2, "email");
    {
        const props = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
        defer freeStringList(allocator, props);
        try testing.expectEqual(@as(usize, 1), props.len);
        try testing.expect(containsString(props, "age"));
        try testing.expect(!containsString(props, "email"));
    }

    // Updating an existing property's VALUE does not change the property
    // key set — verify the listing remains identical.
    try store.setNodeProperty(usr1, "age", .{ .Int = 31 });
    {
        const props = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
        defer freeStringList(allocator, props);
        try testing.expectEqual(@as(usize, 1), props.len);
        try testing.expect(containsString(props, "age"));
    }
}

test "PERF-C: cross-tenant isolation for labels and properties" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    const ua = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");
    const ub = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_b");

    try store.setNodeProperty(ua, "secret_a", .{ .String = "value_a" });
    try store.setNodeProperty(ub, "secret_b", .{ .String = "value_b" });

    const props_a = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
    defer freeStringList(allocator, props_a);
    try testing.expectEqual(@as(usize, 1), props_a.len);
    try testing.expect(containsString(props_a, "secret_a"));
    try testing.expect(!containsString(props_a, "secret_b"));

    const props_b = try store.listPropertiesForLabel(allocator, "tenant_b", "User");
    defer freeStringList(allocator, props_b);
    try testing.expectEqual(@as(usize, 1), props_b.len);
    try testing.expect(containsString(props_b, "secret_b"));
    try testing.expect(!containsString(props_b, "secret_a"));
}

test "PERF-C: addNodeLabel and removeNodeLabel update the tenant index" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    // Single User node, then add a second label.
    const u = try store.createNodeWithGraphAndTenant(&[_][]const u8{"User"}, "g", "tenant_a");
    try store.setNodeProperty(u, "email", .{ .String = "a@b" });

    try store.addNodeLabel(u, "Admin");

    {
        const labels = try store.listNodeLabels(allocator, "tenant_a");
        defer freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 2), labels.len);
        try testing.expect(containsString(labels, "User"));
        try testing.expect(containsString(labels, "Admin"));
    }

    // Property `email` should now appear under BOTH labels.
    {
        const props_user = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
        defer freeStringList(allocator, props_user);
        try testing.expect(containsString(props_user, "email"));

        const props_admin = try store.listPropertiesForLabel(allocator, "tenant_a", "Admin");
        defer freeStringList(allocator, props_admin);
        try testing.expect(containsString(props_admin, "email"));
    }

    // Remove Admin — label drops, property drops under Admin only.
    try store.removeNodeLabel(u, "Admin");

    {
        const labels = try store.listNodeLabels(allocator, "tenant_a");
        defer freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 1), labels.len);
        try testing.expect(containsString(labels, "User"));
        try testing.expect(!containsString(labels, "Admin"));

        const props_admin = try store.listPropertiesForLabel(allocator, "tenant_a", "Admin");
        defer freeStringList(allocator, props_admin);
        try testing.expectEqual(@as(usize, 0), props_admin.len);

        const props_user = try store.listPropertiesForLabel(allocator, "tenant_a", "User");
        defer freeStringList(allocator, props_user);
        try testing.expect(containsString(props_user, "email"));
    }
}

test "PERF-C: listEdgeTypes returns the tenant's edge types" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    const a = try store.createNodeWithGraphAndTenant(&[_][]const u8{"X"}, "g", "tenant_a");
    const b = try store.createNodeWithGraphAndTenant(&[_][]const u8{"X"}, "g", "tenant_a");
    const c = try store.createNodeWithGraphAndTenant(&[_][]const u8{"X"}, "g", "tenant_b");
    const d = try store.createNodeWithGraphAndTenant(&[_][]const u8{"X"}, "g", "tenant_b");

    _ = try store.createEdgeWithGraphAndTenant(a, b, "KNOWS", "g", "tenant_a");
    _ = try store.createEdgeWithGraphAndTenant(a, b, "FOLLOWS", "g", "tenant_a");
    const eid = try store.createEdgeWithGraphAndTenant(c, d, "BUYS", "g", "tenant_b");

    {
        const types_a = try store.listEdgeTypes(allocator, "tenant_a");
        defer freeStringList(allocator, types_a);
        try testing.expectEqual(@as(usize, 2), types_a.len);
        try testing.expect(containsString(types_a, "KNOWS"));
        try testing.expect(containsString(types_a, "FOLLOWS"));
        try testing.expect(!containsString(types_a, "BUYS"));
    }

    {
        const types_b = try store.listEdgeTypes(allocator, "tenant_b");
        defer freeStringList(allocator, types_b);
        try testing.expectEqual(@as(usize, 1), types_b.len);
        try testing.expect(containsString(types_b, "BUYS"));
    }

    // Delete the sole BUYS edge — should disappear.
    store.deleteEdgeNoSave(eid);
    {
        const types_b = try store.listEdgeTypes(allocator, "tenant_b");
        defer freeStringList(allocator, types_b);
        try testing.expectEqual(@as(usize, 0), types_b.len);
    }

    // Admin view: BUYS gone, KNOWS + FOLLOWS still alive.
    const all = try store.listEdgeTypes(allocator, null);
    defer freeStringList(allocator, all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expect(containsString(all, "KNOWS"));
    try testing.expect(containsString(all, "FOLLOWS"));
    try testing.expect(!containsString(all, "BUYS"));
}

test "PERF-C: 100-node x 3-graph stress for label union" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g1");
    try store.createGraph("g2");
    try store.createGraph("g3");

    // Each graph hosts 100 nodes split across {Person, Order} labels.
    const graphs = [_][]const u8{ "g1", "g2", "g3" };
    var label_choice: usize = 0;
    for (graphs) |gn| {
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const label: []const u8 = if (label_choice % 2 == 0) "Person" else "Order";
            label_choice += 1;
            _ = try store.createNodeWithGraphAndTenant(&[_][]const u8{label}, gn, "shared");
        }
    }

    const labels = try store.listNodeLabels(allocator, "shared");
    defer freeStringList(allocator, labels);
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expect(containsString(labels, "Person"));
    try testing.expect(containsString(labels, "Order"));
}
