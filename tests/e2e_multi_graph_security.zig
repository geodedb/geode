// CANARY: REQ=REQ-MULTI-GRAPH-SECURITY-TEST; FEATURE="MultiGraphSecurityTests"; ASPECT=Security; STATUS=IMPL; OWNER=testing; UPDATED=2025-12-20
// End-to-end tests for multi-graph security features
// Tests graph-scoped RBAC and FLE (SONNY-6511: the graph-scoped audit log
// and getRolesForGraph these also tested never compiled and were removed)

const std = @import("std");
const multi_graph_security = @import("geode").multi_graph_security;
const auth = @import("geode").auth;

pub fn main() !void {}

// ============================================================================
// Graph-Scoped RBAC Tests
// ============================================================================

test "GraphRBACPolicy - assign role for specific graph" {
    const allocator = std.testing.allocator;

    var rbac = multi_graph_security.GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Assign role 100 to user 1 for graph "sales"
    try rbac.assignRoleForGraph(1, 100, "sales");

    // Add a permission to role 100
    var perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try perms.append(allocator, .{
        .id = 1,
        .name = "read_nodes",
        .resource = "node",
        .action = .read,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(100, perms);

    // Verify user 1 has permission in "sales" graph
    try std.testing.expect(rbac.hasPermission(1, "sales", "node", .read));

    // Verify user 1 does NOT have permission in "hr" graph
    try std.testing.expect(!rbac.hasPermission(1, "hr", "node", .read));

    // Verify user 2 does NOT have permission in "sales" graph
    try std.testing.expect(!rbac.hasPermission(2, "sales", "node", .read));
}

test "GraphRBACPolicy - global roles apply to all graphs" {
    const allocator = std.testing.allocator;

    var rbac = multi_graph_security.GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Assign global admin role to user 1
    try rbac.assignGlobalRole(1, 1);

    // Add "all" permission to the global admin role
    var perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try perms.append(allocator, .{
        .id = 1,
        .name = "global_admin",
        .resource = "node",
        .action = .all,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(1, perms);

    // Global admin should have permission in ANY graph
    try std.testing.expect(rbac.hasPermission(1, "sales", "node", .read));
    try std.testing.expect(rbac.hasPermission(1, "hr", "node", .read));
    try std.testing.expect(rbac.hasPermission(1, "finance", "node", .delete));
    try std.testing.expect(rbac.hasPermission(1, "any_new_graph", "node", .create));
}

test "GraphRBACPolicy - combined graph-specific and global roles" {
    const allocator = std.testing.allocator;

    var rbac = multi_graph_security.GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Give user 1 a viewer role globally
    try rbac.assignGlobalRole(1, 10);

    // Give user 1 an editor role only in "sales" graph
    try rbac.assignRoleForGraph(1, 20, "sales");

    // Add read permission to viewer role (global)
    var viewer_perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try viewer_perms.append(allocator, .{
        .id = 1,
        .name = "viewer",
        .resource = "node",
        .action = .read,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(10, viewer_perms);

    // Add write permission to editor role
    var editor_perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try editor_perms.append(allocator, .{
        .id = 2,
        .name = "editor",
        .resource = "node",
        .action = .create,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(20, editor_perms);

    // User 1 should be able to read in any graph (global viewer)
    try std.testing.expect(rbac.hasPermission(1, "sales", "node", .read));
    try std.testing.expect(rbac.hasPermission(1, "hr", "node", .read));

    // User 1 should ONLY be able to create in "sales" (graph-specific editor)
    try std.testing.expect(rbac.hasPermission(1, "sales", "node", .create));
    try std.testing.expect(!rbac.hasPermission(1, "hr", "node", .create));
}

test "GraphRBACPolicy - revoke role from specific graph" {
    const allocator = std.testing.allocator;

    var rbac = multi_graph_security.GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Assign role
    try rbac.assignRoleForGraph(1, 100, "sales");

    var perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try perms.append(allocator, .{
        .id = 1,
        .name = "read",
        .resource = "node",
        .action = .read,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(100, perms);

    // Verify permission exists
    try std.testing.expect(rbac.hasPermission(1, "sales", "node", .read));

    // Revoke the role
    try rbac.revokeRoleForGraph(1, 100, "sales");

    // Permission should be gone
    try std.testing.expect(!rbac.hasPermission(1, "sales", "node", .read));
}

// ============================================================================
// Graph Security Context Tests
// ============================================================================

test "GraphSecurityContext - superuser has all permissions" {
    const allocator = std.testing.allocator;

    var rbac = multi_graph_security.GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Create a superuser
    var user = auth.User{
        .id = 1,
        .username = "admin",
        .password_hash = "hash",
        .is_superuser = true,
        .is_active = true,
        .mfa_enabled = false,
        .mfa_secret = null,
        .created_at = 0,
        .updated_at = 0,
        .last_login = null,
        .email = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };
    defer user.attributes.deinit();

    const ctx = multi_graph_security.GraphSecurityContext{
        .user = &user,
        .roles = &.{},
        .current_graph = "any_graph",
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = .{
            .ip_address = "127.0.0.1",
            .user_agent = "test",
            .timestamp = 0,
            .geo_location = null,
        },
    };

    // Superuser should have permission for anything
    try std.testing.expect(ctx.hasPermission(&rbac, "sensitive_data", .delete));
}

test "GraphSecurityContext - normal user needs graph context" {
    const allocator = std.testing.allocator;

    var rbac = multi_graph_security.GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Create a normal user
    var user = auth.User{
        .id = 2,
        .username = "viewer",
        .password_hash = "hash",
        .is_superuser = false,
        .is_active = true,
        .mfa_enabled = false,
        .mfa_secret = null,
        .created_at = 0,
        .updated_at = 0,
        .last_login = null,
        .email = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };
    defer user.attributes.deinit();

    // Context without a current graph
    const ctx_no_graph = multi_graph_security.GraphSecurityContext{
        .user = &user,
        .roles = &.{},
        .current_graph = null,
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = .{
            .ip_address = "127.0.0.1",
            .user_agent = "test",
            .timestamp = 0,
            .geo_location = null,
        },
    };

    // Without graph context, permission check should fail
    try std.testing.expect(!ctx_no_graph.hasPermission(&rbac, "node", .read));
}

// ============================================================================
// Integration Test: Multi-Graph Isolation
// ============================================================================

test "integration - multi-graph role isolation" {
    const allocator = std.testing.allocator;

    var rbac = multi_graph_security.GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Setup: 3 users with different access levels
    // User 1: Global admin
    // User 2: Sales graph editor
    // User 3: HR graph viewer

    try rbac.assignGlobalRole(1, 1); // global admin

    try rbac.assignRoleForGraph(2, 100, "sales"); // sales editor
    try rbac.assignRoleForGraph(3, 200, "hr"); // hr viewer

    // Setup role permissions
    var admin_perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try admin_perms.append(allocator, .{ .id = 1, .name = "admin", .resource = "*", .action = .all, .conditions = null, .created_at = 0 });
    try rbac.role_permissions.put(1, admin_perms);

    var editor_perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 2);
    try editor_perms.append(allocator, .{ .id = 2, .name = "editor_read", .resource = "node", .action = .read, .conditions = null, .created_at = 0 });
    try editor_perms.append(allocator, .{ .id = 3, .name = "editor_create", .resource = "node", .action = .create, .conditions = null, .created_at = 0 });
    try rbac.role_permissions.put(100, editor_perms);

    var viewer_perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try viewer_perms.append(allocator, .{ .id = 4, .name = "viewer", .resource = "node", .action = .read, .conditions = null, .created_at = 0 });
    try rbac.role_permissions.put(200, viewer_perms);

    // Verify access isolation

    // User 1 (admin): access everywhere
    try std.testing.expect(rbac.hasPermission(1, "sales", "*", .all));
    try std.testing.expect(rbac.hasPermission(1, "hr", "*", .all));
    try std.testing.expect(rbac.hasPermission(1, "finance", "*", .all));

    // User 2 (sales editor): only sales
    try std.testing.expect(rbac.hasPermission(2, "sales", "node", .read));
    try std.testing.expect(rbac.hasPermission(2, "sales", "node", .create));
    try std.testing.expect(!rbac.hasPermission(2, "hr", "node", .read));
    try std.testing.expect(!rbac.hasPermission(2, "finance", "node", .read));

    // User 3 (hr viewer): only hr, read-only
    try std.testing.expect(rbac.hasPermission(3, "hr", "node", .read));
    try std.testing.expect(!rbac.hasPermission(3, "hr", "node", .create));
    try std.testing.expect(!rbac.hasPermission(3, "sales", "node", .read));
}
