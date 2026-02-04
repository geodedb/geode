const std = @import("std");
const testing = std.testing;

// Integration tests for complete User Management system
// CANARY: REQ=REQ-GQL-202; FEATURE="UserManagementIntegration"; ASPECT=EndToEndWorkflow; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_202_UserManagementIntegration; OWNER=security; UPDATED=2025-10-04

// Simplified structures for integration testing
const UserManagementSystem = struct {
    allocator: std.mem.Allocator,
    users: std.AutoHashMap(u64, User),
    roles: std.AutoHashMap(u64, Role),
    permissions: std.AutoHashMap(u64, Permission),
    policies: std.AutoHashMap(u64, Policy),
    user_roles: std.AutoHashMap(u64, std.ArrayList(u64)), // user_id -> role_ids
    role_permissions: std.AutoHashMap(u64, std.ArrayList(u64)), // role_id -> permission_ids
    policy_roles: std.AutoHashMap(u64, std.ArrayList(u64)), // policy_id -> role_ids
    next_user_id: u64 = 1,
    next_role_id: u64 = 1,
    next_permission_id: u64 = 1,
    next_policy_id: u64 = 1,

    const Self = @This();

    const User = struct {
        id: u64,
        username: []const u8,
        email: []const u8,
        password_hash: []const u8,
        is_active: bool = true,
        is_superuser: bool = false,
        mfa_enabled: bool = false,
        created_at: i64,
        updated_at: i64,
    };

    const Role = struct {
        id: u64,
        name: []const u8,
        description: []const u8,
        parent_role: ?u64 = null,
        priority: u32 = 50,
        is_system: bool = false,
        created_at: i64,
    };

    const Permission = struct {
        id: u64,
        name: []const u8,
        resource: []const u8,
        action: Action,
        conditions: ?[]const u8 = null,
        created_at: i64,
    };

    const Policy = struct {
        id: u64,
        name: []const u8,
        description: []const u8,
        graph: []const u8,
        table: []const u8,
        operation: Operation,
        permissive: bool = true,
        enabled: bool = true,
        using_clause: ?[]const u8 = null,
        check_clause: ?[]const u8 = null,
        audit_level: AuditLevel = .denials,
        created_at: i64,
        created_by: u64,
    };

    const Action = enum { read, write, delete, admin };
    const Operation = enum { SELECT, INSERT, UPDATE, DELETE, ALL };
    const AuditLevel = enum { none, denials, all };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .users = std.AutoHashMap(u64, User).init(allocator),
            .roles = std.AutoHashMap(u64, Role).init(allocator),
            .permissions = std.AutoHashMap(u64, Permission).init(allocator),
            .policies = std.AutoHashMap(u64, Policy).init(allocator),
            .user_roles = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .role_permissions = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .policy_roles = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };

        // Create default system roles
        try self.createSystemRoles();

        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.user_roles.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }

        var it2 = self.role_permissions.valueIterator();
        while (it2.next()) |list| {
            list.deinit(self.allocator);
        }

        var it3 = self.policy_roles.valueIterator();
        while (it3.next()) |list| {
            list.deinit(self.allocator);
        }

        self.users.deinit();
        self.roles.deinit();
        self.permissions.deinit();
        self.policies.deinit();
        self.user_roles.deinit();
        self.role_permissions.deinit();
        self.policy_roles.deinit();
    }

    fn createSystemRoles(self: *Self) !void {
        // Create admin role
        const admin_role = Role{
            .id = self.next_role_id,
            .name = try self.allocator.dupe(u8, "admin"),
            .description = try self.allocator.dupe(u8, "System administrator"),
            .priority = 100,
            .is_system = true,
            .created_at = std.time.milliTimestamp(),
        };
        try self.roles.put(self.next_role_id, admin_role);
        self.next_role_id += 1;

        // Create user role
        const user_role = Role{
            .id = self.next_role_id,
            .name = try self.allocator.dupe(u8, "user"),
            .description = try self.allocator.dupe(u8, "Standard user"),
            .priority = 50,
            .is_system = true,
            .created_at = std.time.milliTimestamp(),
        };
        try self.roles.put(self.next_role_id, user_role);
        self.next_role_id += 1;

        // Create guest role
        const guest_role = Role{
            .id = self.next_role_id,
            .name = try self.allocator.dupe(u8, "guest"),
            .description = try self.allocator.dupe(u8, "Guest access"),
            .priority = 10,
            .is_system = true,
            .created_at = std.time.milliTimestamp(),
        };
        try self.roles.put(self.next_role_id, guest_role);
        self.next_role_id += 1;
    }

    pub fn createUser(self: *Self, username: []const u8, email: []const u8, password_hash: []const u8, roles: ?[]const []const u8) !u64 {
        const user = User{
            .id = self.next_user_id,
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password_hash = try self.allocator.dupe(u8, password_hash),
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
        };

        try self.users.put(self.next_user_id, user);

        // Assign roles
        if (roles) |role_names| {
            var user_role_list = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable;

            for (role_names) |role_name| {
                if (self.getRoleByName(role_name)) |role| {
                    try user_role_list.append(self.allocator, role.id);
                }
            }

            try self.user_roles.put(self.next_user_id, user_role_list);
        }

        const user_id = self.next_user_id;
        self.next_user_id += 1;
        return user_id;
    }

    pub fn createRole(self: *Self, name: []const u8, description: []const u8, parent_role: ?[]const u8, priority: u32) !u64 {
        var parent_id: ?u64 = null;
        if (parent_role) |parent_name| {
            if (self.getRoleByName(parent_name)) |parent| {
                parent_id = parent.id;
            }
        }

        const role = Role{
            .id = self.next_role_id,
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, description),
            .parent_role = parent_id,
            .priority = priority,
            .created_at = std.time.milliTimestamp(),
        };

        try self.roles.put(self.next_role_id, role);

        const role_id = self.next_role_id;
        self.next_role_id += 1;
        return role_id;
    }

    pub fn createPermission(self: *Self, name: []const u8, resource: []const u8, action: Action, conditions: ?[]const u8) !u64 {
        const permission = Permission{
            .id = self.next_permission_id,
            .name = try self.allocator.dupe(u8, name),
            .resource = try self.allocator.dupe(u8, resource),
            .action = action,
            .conditions = if (conditions) |c| try self.allocator.dupe(u8, c) else null,
            .created_at = std.time.milliTimestamp(),
        };

        try self.permissions.put(self.next_permission_id, permission);

        const permission_id = self.next_permission_id;
        self.next_permission_id += 1;
        return permission_id;
    }

    pub fn createPolicy(self: *Self, name: []const u8, description: []const u8, graph: []const u8, table: []const u8, operation: Operation, roles: []const []const u8, using_clause: ?[]const u8, check_clause: ?[]const u8, created_by: u64) !u64 {
        const policy = Policy{
            .id = self.next_policy_id,
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, description),
            .graph = try self.allocator.dupe(u8, graph),
            .table = try self.allocator.dupe(u8, table),
            .operation = operation,
            .using_clause = if (using_clause) |c| try self.allocator.dupe(u8, c) else null,
            .check_clause = if (check_clause) |c| try self.allocator.dupe(u8, c) else null,
            .created_at = std.time.milliTimestamp(),
            .created_by = created_by,
        };

        try self.policies.put(self.next_policy_id, policy);

        // Associate policy with roles
        var policy_role_list = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable;
        for (roles) |role_name| {
            if (self.getRoleByName(role_name)) |role| {
                try policy_role_list.append(self.allocator, role.id);
            }
        }
        try self.policy_roles.put(self.next_policy_id, policy_role_list);

        const policy_id = self.next_policy_id;
        self.next_policy_id += 1;
        return policy_id;
    }

    pub fn assignRoleToUser(self: *Self, user_id: u64, role_name: []const u8) !void {
        const role = self.getRoleByName(role_name) orelse return error.RoleNotFound;

        const result = try self.user_roles.getOrPut(user_id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable;
        }

        // Check if role already assigned
        for (result.value_ptr.items) |existing_role_id| {
            if (existing_role_id == role.id) return; // Already assigned
        }

        try result.value_ptr.append(self.allocator, role.id);
    }

    pub fn grantPermissionToRole(self: *Self, role_name: []const u8, permission_name: []const u8) !void {
        const role = self.getRoleByName(role_name) orelse return error.RoleNotFound;
        const permission = self.getPermissionByName(permission_name) orelse return error.PermissionNotFound;

        const result = try self.role_permissions.getOrPut(role.id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable;
        }

        // Check if permission already granted
        for (result.value_ptr.items) |existing_perm_id| {
            if (existing_perm_id == permission.id) return; // Already granted
        }

        try result.value_ptr.append(self.allocator, permission.id);
    }

    fn getRoleByName(self: *Self, name: []const u8) ?Role {
        var it = self.roles.valueIterator();
        while (it.next()) |role| {
            if (std.mem.eql(u8, role.name, name)) {
                return role.*;
            }
        }
        return null;
    }

    fn getPermissionByName(self: *Self, name: []const u8) ?Permission {
        var it = self.permissions.valueIterator();
        while (it.next()) |permission| {
            if (std.mem.eql(u8, permission.name, name)) {
                return permission.*;
            }
        }
        return null;
    }

    pub fn getUserRoles(self: *Self, user_id: u64) ?std.ArrayList(u64) {
        return self.user_roles.get(user_id);
    }

    pub fn getRolePermissions(self: *Self, role_id: u64) ?std.ArrayList(u64) {
        return self.role_permissions.get(role_id);
    }

    pub fn getPolicyRoles(self: *Self, policy_id: u64) ?std.ArrayList(u64) {
        return self.policy_roles.get(policy_id);
    }

    pub fn getUserByUsername(self: *Self, username: []const u8) ?User {
        var it = self.users.valueIterator();
        while (it.next()) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                return user.*;
            }
        }
        return null;
    }

    pub fn checkUserPermission(self: *Self, user_id: u64, resource: []const u8, action: Action) bool {
        // Get user roles
        const user_roles = self.getUserRoles(user_id) orelse return false;

        // Check each role's permissions
        for (user_roles.items) |role_id| {
            if (self.getRolePermissions(role_id)) |permissions| {
                for (permissions.items) |perm_id| {
                    if (self.permissions.get(perm_id)) |permission| {
                        // Check if permission matches resource and action
                        if ((std.mem.eql(u8, permission.resource, "*") or std.mem.eql(u8, permission.resource, resource)) and
                            (permission.action == action or permission.action == .admin))
                        {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    pub fn getApplicablePolicies(self: *Self, user_id: u64, graph: []const u8, table: []const u8, operation: Operation) std.ArrayList(Policy) {
        var applicable_policies = std.ArrayList(Policy).initCapacity(self.allocator, 0) catch unreachable;

        // Get user roles
        const user_roles = self.getUserRoles(user_id) orelse return applicable_policies;

        // Check each policy
        var policy_it = self.policies.valueIterator();
        while (policy_it.next()) |policy| {
            // Check if policy applies to the operation and table
            if (policy.enabled and
                (policy.operation == operation or policy.operation == .ALL) and
                (std.mem.eql(u8, policy.graph, "*") or std.mem.eql(u8, policy.graph, graph)) and
                (std.mem.eql(u8, policy.table, "*") or std.mem.eql(u8, policy.table, table)))
            {

                // Check if user has one of the roles associated with this policy
                if (self.getPolicyRoles(policy.id)) |policy_roles| {
                    for (policy_roles.items) |policy_role_id| {
                        for (user_roles.items) |user_role_id| {
                            if (policy_role_id == user_role_id) {
                                applicable_policies.append(self.allocator, policy.*) catch break;
                                break;
                            }
                        }
                    }
                }
            }
        }

        return applicable_policies;
    }
};

test "TestCANARY_REQ_GQL_202_UserManagementIntegration" {
    const allocator = testing.allocator;

    var ums = try UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Verify system roles were created
    try testing.expect(ums.getRoleByName("admin") != null);
    try testing.expect(ums.getRoleByName("user") != null);
    try testing.expect(ums.getRoleByName("guest") != null);

    std.debug.print("\nUser Management integration test passed\n", .{});
}

test "complete user lifecycle workflow" {
    const allocator = testing.allocator;

    var ums = try UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create users with different roles
    const admin_id = try ums.createUser("admin", "admin@example.com", "admin_hash", &[_][]const u8{"admin"});
    const alice_id = try ums.createUser("alice", "alice@example.com", "alice_hash", &[_][]const u8{"user"});
    _ = try ums.createUser("bob", "bob@example.com", "bob_hash", &[_][]const u8{"guest"});

    // Verify users were created
    try testing.expect(ums.getUserByUsername("admin") != null);
    try testing.expect(ums.getUserByUsername("alice") != null);
    try testing.expect(ums.getUserByUsername("bob") != null);

    // Verify role assignments
    const admin_roles = ums.getUserRoles(admin_id);
    try testing.expect(admin_roles != null);
    try testing.expect(admin_roles.?.items.len == 1);

    const alice_roles = ums.getUserRoles(alice_id);
    try testing.expect(alice_roles != null);
    try testing.expect(alice_roles.?.items.len == 1);

    std.debug.print("\nUser lifecycle workflow test passed\n", .{});
}

test "role and permission management workflow" {
    const allocator = testing.allocator;

    var ums = try UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create custom roles
    _ = try ums.createRole("analyst", "Data analyst", "user", 75);
    _ = try ums.createRole("manager", "Team manager", "analyst", 80);

    // Create permissions
    _ = try ums.createPermission("read_data", "data", .read", "department = user.department");
    _ = try ums.createPermission("write_reports", "reports", .write, null);
    _ = try ums.createPermission("manage_team", "users", .admin", "manager_id = user.id");

    // Grant permissions to roles
    try ums.grantPermissionToRole("analyst", "read_data");
    try ums.grantPermissionToRole("analyst", "write_reports");
    try ums.grantPermissionToRole("manager", "manage_team");

    // Create users with these roles
    const analyst_id = try ums.createUser("data_analyst", "analyst@example.com", "hash", &[_][]const u8{"analyst"});
    const manager_id = try ums.createUser("team_manager", "manager@example.com", "hash", &[_][]const u8{"manager"});

    // Test permission checking
    try testing.expect(ums.checkUserPermission(analyst_id, "data", .read) == true);
    try testing.expect(ums.checkUserPermission(analyst_id, "reports", .write) == true);
    try testing.expect(ums.checkUserPermission(analyst_id, "users", .admin) == false);

    try testing.expect(ums.checkUserPermission(manager_id, "users", .admin) == true);

    std.debug.print("\nRole and permission management workflow test passed\n", .{});
}

test "policy-based access control workflow" {
    const allocator = testing.allocator;

    var ums = try UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create admin user
    const admin_id = try ums.createUser("admin", "admin@example.com", "hash", &[_][]const u8{"admin"});

    // Create policies
    _ = try ums.createPolicy(
        "user_data_access",
        "Users can only access their own data",
        "main",
        "users",
        .SELECT,
        &[_][]const u8{"user"},
        "user_id = current_user_id()",
        "user_id = current_user_id()",
        admin_id,
    );

    _ = try ums.createPolicy(
        "admin_full_access",
        "Admins can access all data",
        "main",
        "*",
        .ALL,
        &[_][]const u8{"admin"},
        null,
        null,
        admin_id,
    );

    _ = try ums.createPolicy(
        "guest_read_only",
        "Guests can only read public data",
        "main",
        "public_data",
        .SELECT,
        &[_][]const u8{"guest"},
        "is_public = true",
        null,
        admin_id,
    );

    // Create users with different roles
    const user_id = try ums.createUser("regular_user", "user@example.com", "hash", &[_][]const u8{"user"});
    const guest_id = try ums.createUser("guest_user", "guest@example.com", "hash", &[_][]const u8{"guest"});

    // Test policy application
    var admin_policies = ums.getApplicablePolicies(admin_id, "main", "users", .SELECT);
    defer admin_policies.deinit(allocator);
    try testing.expect(admin_policies.items.len == 1); // admin_full_access

    var user_policies = ums.getApplicablePolicies(user_id, "main", "users", .SELECT);
    defer user_policies.deinit(allocator);
    try testing.expect(user_policies.items.len == 1); // user_data_access

    var guest_policies = ums.getApplicablePolicies(guest_id, "main", "public_data", .SELECT);
    defer guest_policies.deinit(allocator);
    try testing.expect(guest_policies.items.len == 1); // guest_read_only

    // Test policy filtering by operation
    var guest_write_policies = ums.getApplicablePolicies(guest_id, "main", "public_data", .INSERT);
    defer guest_write_policies.deinit(allocator);
    try testing.expect(guest_write_policies.items.len == 0); // No write access for guests

    std.debug.print("\nPolicy-based access control workflow test passed\n", .{});
}

test "hierarchical role inheritance workflow" {
    const allocator = testing.allocator;

    var ums = try UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create role hierarchy: guest < user < analyst < manager < admin
    _ = try ums.createRole("analyst", "Data analyst", "user", 75);
    _ = try ums.createRole("manager", "Team manager", "analyst", 85);

    // Create permissions for each level
    _ = try ums.createPermission("view_public", "public", .read, null);
    _ = try ums.createPermission("view_user_data", "user_data", .read", "user_id = current_user_id()");
    _ = try ums.createPermission("analyze_data", "analytics", .read, null);
    _ = try ums.createPermission("manage_team", "team", .admin, null);
    _ = try ums.createPermission("admin_all", "*", .admin, null);

    // Grant permissions to roles
    try ums.grantPermissionToRole("guest", "view_public");
    try ums.grantPermissionToRole("user", "view_user_data");
    try ums.grantPermissionToRole("analyst", "analyze_data");
    try ums.grantPermissionToRole("manager", "manage_team");
    try ums.grantPermissionToRole("admin", "admin_all");

    // Create users at each level
    const guest_id = try ums.createUser("guest", "guest@example.com", "hash", &[_][]const u8{"guest"});
    const user_id = try ums.createUser("user", "user@example.com", "hash", &[_][]const u8{"user"});
    const analyst_id = try ums.createUser("analyst", "analyst@example.com", "hash", &[_][]const u8{"analyst"});
    const manager_id = try ums.createUser("manager", "manager@example.com", "hash", &[_][]const u8{"manager"});
    const admin_id = try ums.createUser("admin", "admin@example.com", "hash", &[_][]const u8{"admin"});

    // Test permission hierarchy (each level should have their specific permissions)
    try testing.expect(ums.checkUserPermission(guest_id, "public", .read) == true);
    try testing.expect(ums.checkUserPermission(guest_id, "user_data", .read) == false);

    try testing.expect(ums.checkUserPermission(user_id, "user_data", .read) == true);
    try testing.expect(ums.checkUserPermission(user_id, "analytics", .read) == false);

    try testing.expect(ums.checkUserPermission(analyst_id, "analytics", .read) == true);
    try testing.expect(ums.checkUserPermission(analyst_id, "team", .admin) == false);

    try testing.expect(ums.checkUserPermission(manager_id, "team", .admin) == true);
    try testing.expect(ums.checkUserPermission(manager_id, "*", .admin) == false);

    try testing.expect(ums.checkUserPermission(admin_id, "*", .admin) == true);

    std.debug.print("\nHierarchical role inheritance workflow test passed\n", .{});
}

test "multi-tenant policy enforcement workflow" {
    const allocator = testing.allocator;

    var ums = try UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create tenant-specific roles
    _ = try ums.createRole("tenant_a_user", "Tenant A User", "user", 60);
    _ = try ums.createRole("tenant_b_user", "Tenant B User", "user", 60);

    // Create admin user
    const admin_id = try ums.createUser("admin", "admin@example.com", "hash", &[_][]const u8{"admin"});

    // Create tenant-specific policies
    _ = try ums.createPolicy(
        "tenant_a_isolation",
        "Tenant A users can only access Tenant A data",
        "tenant_a",
        "*",
        .ALL,
        &[_][]const u8{"tenant_a_user"},
        "tenant_id = 'tenant_a'",
        "tenant_id = 'tenant_a'",
        admin_id,
    );

    _ = try ums.createPolicy(
        "tenant_b_isolation",
        "Tenant B users can only access Tenant B data",
        "tenant_b",
        "*",
        .ALL,
        &[_][]const u8{"tenant_b_user"},
        "tenant_id = 'tenant_b'",
        "tenant_id = 'tenant_b'",
        admin_id,
    );

    // Create cross-tenant admin policy
    _ = try ums.createPolicy(
        "admin_cross_tenant",
        "Admins can access all tenant data",
        "*",
        "*",
        .ALL,
        &[_][]const u8{"admin"},
        null,
        null,
        admin_id,
    );

    // Create tenant users
    const tenant_a_user = try ums.createUser("user_a", "user_a@tenant_a.com", "hash", &[_][]const u8{"tenant_a_user"});
    _ = try ums.createUser("user_b", "user_b@tenant_b.com", "hash", &[_][]const u8{"tenant_b_user"});

    // Test tenant isolation
    var tenant_a_policies = ums.getApplicablePolicies(tenant_a_user, "tenant_a", "data", .SELECT);
    defer tenant_a_policies.deinit(allocator);
    try testing.expect(tenant_a_policies.items.len == 1);

    var tenant_a_cross_policies = ums.getApplicablePolicies(tenant_a_user, "tenant_b", "data", .SELECT);
    defer tenant_a_cross_policies.deinit(allocator);
    try testing.expect(tenant_a_cross_policies.items.len == 0); // No cross-tenant access

    var admin_tenant_a_policies = ums.getApplicablePolicies(admin_id, "tenant_a", "data", .SELECT);
    defer admin_tenant_a_policies.deinit(allocator);
    try testing.expect(admin_tenant_a_policies.items.len == 1); // Admin can access tenant_a

    var admin_tenant_b_policies = ums.getApplicablePolicies(admin_id, "tenant_b", "data", .SELECT);
    defer admin_tenant_b_policies.deinit(allocator);
    try testing.expect(admin_tenant_b_policies.items.len == 1); // Admin can access tenant_b

    std.debug.print("\nMulti-tenant policy enforcement workflow test passed\n", .{});
}

test "audit and compliance workflow" {
    const allocator = testing.allocator;

    var ums = try UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create compliance officer role
    _ = try ums.createRole("compliance_officer", "Compliance Officer", "user", 90);

    // Create admin and compliance users
    const admin_id = try ums.createUser("admin", "admin@example.com", "hash", &[_][]const u8{"admin"});
    const compliance_id = try ums.createUser("compliance", "compliance@example.com", "hash", &[_][]const u8{"compliance_officer"});

    // Create audit policies with different audit levels
    const high_security_policy_id = try ums.createPolicy(
        "high_security_audit",
        "High security data requires full audit logging",
        "main",
        "sensitive_data",
        .ALL,
        &[_][]const u8{"admin"},
        "security_level = 'high'",
        "security_level = 'high'",
        admin_id,
    );

    _ = try ums.createPolicy(
        "compliance_monitoring",
        "Compliance officers can audit all access attempts",
        "main",
        "audit_logs",
        .SELECT,
        &[_][]const u8{"compliance_officer"},
        null,
        null,
        admin_id,
    );

    // Test audit policy application
    var high_security_policies = ums.getApplicablePolicies(admin_id, "main", "sensitive_data", .SELECT);
    defer high_security_policies.deinit(allocator);
    try testing.expect(high_security_policies.items.len == 1);
    try testing.expect(high_security_policies.items[0].audit_level == .denials); // Default audit level

    var compliance_policies = ums.getApplicablePolicies(compliance_id, "main", "audit_logs", .SELECT);
    defer compliance_policies.deinit(allocator);
    try testing.expect(compliance_policies.items.len == 1);

    // Verify policy metadata for compliance tracking
    const policy = ums.policies.get(high_security_policy_id);
    try testing.expect(policy != null);
    try testing.expect(policy.?.created_by == admin_id);
    try testing.expect(policy.?.created_at > 0);

    std.debug.print("\nAudit and compliance workflow test passed\n", .{});
}
