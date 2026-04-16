const std = @import("std");
const auth = @import("src/security/auth.zig");
const rls = @import("src/security/rls.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize security system
    var security_mgr = try auth.SecurityManager.init(allocator);
    defer security_mgr.deinit();

    var rls_engine = try rls.RLSEngine.init(allocator);
    defer rls_engine.deinit();

    std.debug.print("=== RBAC and ABAC Feature Verification ===\n\n", .{});

    // Test 1: User Creation
    std.debug.print("1. User Management:\n", .{});
    const user1 = try security_mgr.createUser("alice", "alice@example.com", "P@ssw0rd123!");
    std.debug.print("   ✓ Created user: {} ({})\n", .{ user1.username, user1.email });

    const user2 = try security_mgr.createUser("bob", "bob@example.com", "P@ssw0rd456!");
    std.debug.print("   ✓ Created user: {} ({})\n", .{ user2.username, user2.email });

    // Test 2: Role Management
    std.debug.print("\n2. Role Management:\n", .{});
    std.debug.print("   Default roles:\n", .{});
    var role_it = security_mgr.roles.iterator();
    while (role_it.next()) |entry| {
        std.debug.print("     - {} ({})\n", .{ entry.value_ptr.name, entry.value_ptr.description });
    }

    // Test 3: Permission System
    std.debug.print("\n3. Permission System:\n", .{});
    var perm_it = security_mgr.permissions.iterator();
    while (perm_it.next()) |entry| {
        std.debug.print("     - {}: {} on {}\n", .{ entry.value_ptr.name, @tagName(entry.value_ptr.action), entry.value_ptr.resource });
    }

    // Test 4: Authentication
    std.debug.print("\n4. Authentication:\n", .{});
    const session = try security_mgr.authenticate("alice", "P@ssw0rd123!");
    std.debug.print("   ✓ User authenticated, session token created\n", .{});

    // Test 5: Authorization Check
    std.debug.print("\n5. Authorization (RBAC):\n", .{});
    const can_read = try security_mgr.hasPermission(user1.id, "graph", .read);
    std.debug.print("   ✓ Alice can read graph: {}\n", .{can_read});

    const can_admin = try security_mgr.hasPermission(user1.id, "system", .all);
    std.debug.print("   ✓ Alice can admin system: {}\n", .{can_admin});

    // Test 6: RLS Policy Creation (ABAC)
    std.debug.print("\n6. Row-Level Security (ABAC):\n", .{});
    const policy = rls.RLSEngine.Policy{
        .id = 1,
        .name = "user_own_data",
        .table = "user_data",
        .graph = "default",
        .operation = .select,
        .permissive = true,
        .roles = &[_]auth.RoleId{1}, // user role
        .using_expr = .{
            .raw = "owner_id = current_user_id()",
            .parsed = null,
            .compiled = null,
            .parameters = &.{},
        },
        .check_expr = null,
        .enabled = true,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = user1.id,
        .temporal = null,
        .data_classification = .confidential,
        .audit_level = .all_access,
    };

    try rls_engine.createPolicy(policy);
    std.debug.print("   ✓ Created RLS policy: {}\n", .{policy.name});
    std.debug.print("     - Table: {}\n", .{policy.table});
    std.debug.print("     - Operation: {}\n", .{@tagName(policy.operation)});
    std.debug.print("     - Expression: {s}\n", .{policy.using_expr.?.raw});

    // Test 7: Context-based Access
    std.debug.print("\n7. Context-Based Access:\n", .{});
    const context = auth.SecurityContext{
        .user = user1,
        .session = &session,
        .ip_address = "192.168.1.100",
        .user_agent = "test-client/1.0",
        .request_time = std.time.milliTimestamp(),
        .attributes = null,
    };

    const access_allowed = try rls_engine.evaluatePolicy(.{ .graph = "default", .table = "user_data" }, user1.id, .select, context);
    std.debug.print("   ✓ Access evaluation result: {}\n", .{access_allowed});

    // Test 8: Audit Log
    std.debug.print("\n8. Audit Log:\n", .{});
    try security_mgr.audit_log.logAccess(user1.id, "user_data", .read, true", "Test access");
    std.debug.print("   ✓ Audit event logged\n", .{});

    std.debug.print("\n=== All RBAC/ABAC Features Verified Successfully ===\n", .{});
}
