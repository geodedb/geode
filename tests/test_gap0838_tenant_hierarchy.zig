// CANARY: REQ=REQ-MULTI-TENANT-HIERARCHY-001; FEATURE="TenantHierarchyManager"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0838_tenant_hierarchy.zig:1; OWNER=security; UPDATED=2026-06-08
//
// Regression tests for GAP-0838: the tenant `HierarchyManager` was dead code,
// keyed on `u64`, with NO production provisioning API — only tests ever wrote
// to it, and even those used a `u64` key that is never bridged to the string
// `tenant_id` used everywhere else in the system (HELLO/session/FLE/audit/proto
// and `graph_store.DEFAULT_TENANT_ID = "default"`).
//
// The fix re-keys `HierarchyManager` on `[]const u8` (string tenant_id) and
// adds a production `addTenant(tenant_id, parent)` provisioning API that owns
// its key/path strings. This test exercises the real string-keyed path that
// CaaST's org → business-unit → engagement tree needs.
//
// Access semantics PRESERVED from the original u64 implementation: an accessor
// can access a target iff the accessor's path is a prefix of the target's path
// — i.e. the accessor is an ANCESTOR of, or IS, the target. A parent can access
// a descendant; a descendant CANNOT access an ancestor; siblings CANNOT access
// each other; self-access is allowed; an unknown tenant yields
// error.TenantNotFound.

const std = @import("std");
const testing = std.testing;
const rls = @import("rls");

// org "acme" → child "acme-bu1" → grandchild "acme-bu1-eng1"
// plus an unrelated sibling subtree "acme-bu2" / "acme-bu2-eng1".
fn buildTree(hm: *rls.HierarchyManager) !void {
    try hm.addTenant("acme", null);
    try hm.addTenant("acme-bu1", "acme");
    try hm.addTenant("acme-bu1-eng1", "acme-bu1");
    try hm.addTenant("acme-bu2", "acme");
    try hm.addTenant("acme-bu2-eng1", "acme-bu2");
}

test "GAP-0838: ancestor can access descendant (org -> bu -> engagement)" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();
    try buildTree(&hm);

    // Root org can reach a grandchild engagement.
    try testing.expect(try hm.canAccessTenant("acme", "acme-bu1-eng1"));
    // Direct parent can reach its child.
    try testing.expect(try hm.canAccessTenant("acme", "acme-bu1"));
    try testing.expect(try hm.canAccessTenant("acme-bu1", "acme-bu1-eng1"));
}

test "GAP-0838: descendant CANNOT access ancestor" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();
    try buildTree(&hm);

    try testing.expect(!try hm.canAccessTenant("acme-bu1-eng1", "acme"));
    try testing.expect(!try hm.canAccessTenant("acme-bu1", "acme"));
    try testing.expect(!try hm.canAccessTenant("acme-bu1-eng1", "acme-bu1"));
}

test "GAP-0838: unrelated sibling subtree is denied both directions" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();
    try buildTree(&hm);

    // bu1 and bu2 are siblings; neither can reach the other or each other's
    // descendants.
    try testing.expect(!try hm.canAccessTenant("acme-bu1", "acme-bu2"));
    try testing.expect(!try hm.canAccessTenant("acme-bu2", "acme-bu1"));
    try testing.expect(!try hm.canAccessTenant("acme-bu1-eng1", "acme-bu2-eng1"));
    try testing.expect(!try hm.canAccessTenant("acme-bu2-eng1", "acme-bu1-eng1"));
    // A sibling engagement cannot reach the OTHER business unit either.
    try testing.expect(!try hm.canAccessTenant("acme-bu1-eng1", "acme-bu2"));
}

test "GAP-0838: self-access is allowed at every level" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();
    try buildTree(&hm);

    try testing.expect(try hm.canAccessTenant("acme", "acme"));
    try testing.expect(try hm.canAccessTenant("acme-bu1", "acme-bu1"));
    try testing.expect(try hm.canAccessTenant("acme-bu1-eng1", "acme-bu1-eng1"));
}

test "GAP-0838: unknown tenant yields TenantNotFound" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();
    try buildTree(&hm);

    try testing.expectError(error.TenantNotFound, hm.canAccessTenant("ghost", "acme"));
    try testing.expectError(error.TenantNotFound, hm.canAccessTenant("acme", "ghost"));
    try testing.expectError(error.TenantNotFound, hm.getTenantPath("ghost"));
}

test "GAP-0838: getTenantPath returns root-to-self ancestry chain" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();
    try buildTree(&hm);

    const path = try hm.getTenantPath("acme-bu1-eng1");
    try testing.expectEqual(@as(usize, 3), path.len);
    try testing.expectEqualStrings("acme", path[0]);
    try testing.expectEqualStrings("acme-bu1", path[1]);
    try testing.expectEqualStrings("acme-bu1-eng1", path[2]);
}

test "GAP-0838: addTenant borrows caller slices (no lifetime dependency)" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();

    // Build the ids in a scratch buffer that goes out of scope before the
    // assertions — proves the manager owns (dupes) its key/path strings.
    {
        var buf: [64]u8 = undefined;
        const root = try std.fmt.bufPrint(&buf, "org-{d}", .{7});
        try hm.addTenant(root, null);
        var buf2: [64]u8 = undefined;
        const child = try std.fmt.bufPrint(&buf2, "org-{d}-team", .{7});
        try hm.addTenant(child, root);
        // Overwrite the scratch buffers to make any borrowed-slice bug loud.
        @memset(&buf, 0xAA);
        @memset(&buf2, 0xBB);
    }

    try testing.expect(try hm.canAccessTenant("org-7", "org-7-team"));
    try testing.expect(!try hm.canAccessTenant("org-7-team", "org-7"));
}

test "GAP-0838: duplicate addTenant is rejected" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();

    try hm.addTenant("acme", null);
    try testing.expectError(error.TenantAlreadyExists, hm.addTenant("acme", null));
}

test "GAP-0838: addTenant with unknown parent is rejected" {
    var hm = try rls.HierarchyManager.init(testing.allocator);
    defer hm.deinit();

    try testing.expectError(error.TenantNotFound, hm.addTenant("orphan", "nonexistent-parent"));
}
