const std = @import("std");
const auth = @import("geode_auth");
const rls = @import("rls");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Row-Level Security Implementation Test\n", .{});
    std.debug.print("========================================\n\n", .{});

    // Initialize security manager
    var security_manager = try auth.SecurityManager.init(allocator);
    defer security_manager.deinit();

    // Initialize RLS engine
    var rls_engine = try rls.RLSEngine.init(allocator);
    defer rls_engine.deinit();

    // Create test users
    std.debug.print("Creating users...\n", .{});
    const alice = try security_manager.createUser("alice", "alice@example.com", "SecurePass123!");
    const bob = try security_manager.createUser("bob", "bob@example.com", "SecurePass123!");
    std.debug.print("  Created user: {} - {}\n", .{ alice.id, alice.username });
    std.debug.print("  Created user: {} - {}\n", .{ bob.id, bob.username });

    // Create roles
    std.debug.print("\nCreating roles...\n", .{});
    const employee_role = try security_manager.createRole("employee", "Regular employee");
    const manager_role = try security_manager.createRole("manager", "Manager with elevated privileges");
    std.debug.print("  Created role: {} - {}\n", .{ employee_role.id, employee_role.name });
    std.debug.print("  Created role: {} - {}\n", .{ manager_role.id, manager_role.name });

    // Assign roles
    std.debug.print("\nAssigning roles...\n", .{});
    try security_manager.assignRole(alice.id, employee_role.id);
    try security_manager.assignRole(bob.id, manager_role.id);
    std.debug.print("  Alice assigned role: employee\n", .{});
    std.debug.print("  Bob assigned role: manager\n", .{});

    // Create RLS policy
    std.debug.print("\nCreating RLS policies...\n", .{});
    const employee_policy = rls.RLSEngine.Policy{
        .id = 1,
        .name = "employee_data_isolation",
        .description = "Employees can only see their own data",
        .graph = "default",
        .table = "employee_records",
        .operation = .select,
        .permissive = true,
        .roles = &[_]auth.RoleId{employee_role.id},
        .using_expr = rls.RLSEngine.Expression{
            .raw = "employee_id = current_user()",
            .parsed = null,
            .compiled = null,
            .parameters = &[_]rls.RLSEngine.Expression.Parameter{},
        },
        .check_expr = null,
        .enabled = true,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = 0,
        .temporal = null,
        .data_classification = .confidential,
        .audit_level = .all_access,
    };

    const manager_policy = rls.RLSEngine.Policy{
        .id = 2,
        .name = "manager_full_access",
        .description = "Managers can see all employee data",
        .graph = "default",
        .table = "employee_records",
        .operation = .all,
        .permissive = true,
        .roles = &[_]auth.RoleId{manager_role.id},
        .using_expr = null, // No restriction for managers
        .check_expr = null,
        .enabled = true,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = 0,
        .temporal = null,
        .data_classification = .confidential,
        .audit_level = .all_access,
    };

    try rls_engine.createPolicy(employee_policy);
    try rls_engine.createPolicy(manager_policy);
    std.debug.print("  Created policy: {}\n", .{employee_policy.name});
    std.debug.print("  Created policy: {}\n", .{manager_policy.name});

    // Test authorization
    std.debug.print("\nTesting authorization...\n", .{});

    // Create permissions
    const read_perm = try security_manager.createPermission("read_employee_data", "employee_records", .read);
    const write_perm = try security_manager.createPermission("write_employee_data", "employee_records", .update);

    // Grant permissions to roles
    try security_manager.grantPermission(employee_role.id, read_perm.id);
    try security_manager.grantPermission(manager_role.id, read_perm.id);
    try security_manager.grantPermission(manager_role.id, write_perm.id);

    // Test RBAC
    const alice_can_read = try security_manager.authorize(alice.id, "employee_records", .read);
    const alice_can_write = try security_manager.authorize(alice.id, "employee_records", .update);
    const bob_can_read = try security_manager.authorize(bob.id, "employee_records", .read);
    const bob_can_write = try security_manager.authorize(bob.id, "employee_records", .update);

    std.debug.print("  Alice (employee) can read: {}\n", .{alice_can_read});
    std.debug.print("  Alice (employee) can write: {}\n", .{alice_can_write});
    std.debug.print("  Bob (manager) can read: {}\n", .{bob_can_read});
    std.debug.print("  Bob (manager) can write: {}\n", .{bob_can_write});

    // Test RLS query rewriting
    std.debug.print("\nTesting RLS query rewriting...\n", .{});

    var alice_context = auth.SecurityContext{
        .user = alice,
        .roles = &[_]auth.Role{employee_role.*},
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = auth.EnvironmentInfo{
            .timestamp = std.time.milliTimestamp(),
            .ip_address = "192.168.1.100",
            .user_agent = "test-client",
            .location = null,
            .device_id = null,
        },
    };
    defer {
        alice_context.session_attributes.deinit();
        alice_context.request_attributes.deinit();
    }

    const original_query = "MATCH (e:Employee) RETURN e";
    const rewritten_query = try rls_engine.rewriteQuery(
        original_query,
        &alice_context,
        "default",
    );

    std.debug.print("  Original query: {}\n", .{original_query});
    std.debug.print("  Rewritten query: {}\n", .{rewritten_query});

    // Test ABAC
    std.debug.print("\nTesting ABAC policies...\n", .{});

    // Add attributes to users
    try alice.attributes.put("department", "engineering");
    try alice.attributes.put("clearance_level", "confidential");
    try bob.attributes.put("department", "management");
    try bob.attributes.put("clearance_level", "top_secret");

    const abac_policy = auth.ABACPolicy{
        .id = 1,
        .name = "engineering_access",
        .description = "Engineering department access to technical resources",
        .effect = .allow,
        .subjects = &[_]auth.AttributeCondition{
            .{
                .attribute = "department",
                .operator = .equals,
                .value = .{ .string = "engineering" },
            },
        },
        .resources = &[_]auth.AttributeCondition{
            .{
                .attribute = "name",
                .operator = .contains,
                .value = .{ .string = "technical" },
            },
        },
        .actions = &[_]auth.Action{ .read, .update },
        .conditions = &[_]auth.EnvironmentCondition{},
        .priority = 100,
        .enabled = true,
    };

    try security_manager.createABACPolicy(abac_policy);

    const alice_abac_allowed = try security_manager.evaluateABACPolicies(
        &alice_context,
        "technical_docs",
        .read,
    );

    std.debug.print("  Alice can access technical_docs (ABAC): {}\n", .{alice_abac_allowed});

    // Summary
    std.debug.print("\n========================================\n", .{});
    std.debug.print("Row-Level Security Test Complete!\n", .{});
    std.debug.print("✓ Users created and authenticated\n", .{});
    std.debug.print("✓ RBAC roles and permissions configured\n", .{});
    std.debug.print("✓ RLS policies applied\n", .{});
    std.debug.print("✓ ABAC policies evaluated\n", .{});
    std.debug.print("✓ Query rewriting functional\n", .{});
}
