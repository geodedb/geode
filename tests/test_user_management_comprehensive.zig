const std = @import("std");
const testing = std.testing;

// Comprehensive integration tests for Enterprise User Management System
// CANARY: REQ=REQ-GQL-202; FEATURE="UserManagementComprehensive"; ASPECT=Integration; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_202_UserManagementComprehensive; OWNER=auth; UPDATED=2026-11-14

// Comprehensive user management structures for integration testing
const UserRole = enum {
    super_admin,
    admin,
    analyst,
    read_only,
    custom,
};

const Permission = enum {
    read_database,
    write_database,
    create_index,
    drop_index,
    manage_users,
    manage_roles,
    backup_restore,
    system_config,
    audit_logs,
    execute_queries,
};

const AuthenticationMethod = enum {
    password,
    api_key,
    oauth2,
    ldap,
    saml,
};

const User = struct {
    id: u64,
    username: []const u8,
    email: []const u8,
    role: UserRole,
    permissions: std.ArrayList(Permission),
    auth_methods: std.ArrayList(AuthenticationMethod),
    tenant_id: ?u64,
    is_active: bool,
    created_at: i64,
    last_login: ?i64,
    failed_login_attempts: u32,
    mfa_enabled: bool,
    session_timeout: u32,

    pub fn init(allocator: std.mem.Allocator, id: u64, username: []const u8, email: []const u8, role: UserRole) User {
        return User{
            .id = id,
            .username = username,
            .email = email,
            .role = role,
            .permissions = std.ArrayList(Permission).initCapacity(allocator, 0) catch unreachable,
            .auth_methods = std.ArrayList(AuthenticationMethod).initCapacity(allocator, 0) catch unreachable,
            .tenant_id = null,
            .is_active = true,
            .created_at = std.time.timestamp(),
            .last_login = null,
            .failed_login_attempts = 0,
            .mfa_enabled = false,
            .session_timeout = 3600, // 1 hour default
        };
    }

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        self.permissions.deinit(allocator);
        self.auth_methods.deinit(allocator);
    }
};

const Policy = struct {
    id: u64,
    name: []const u8,
    tenant_id: ?u64,
    rules: std.ArrayList(PolicyRule),
    is_active: bool,

    pub fn init(allocator: std.mem.Allocator, id: u64, name: []const u8) Policy {
        return Policy{
            .id = id,
            .name = name,
            .tenant_id = null,
            .rules = std.ArrayList(PolicyRule).initCapacity(allocator, 0) catch unreachable,
            .is_active = true,
        };
    }

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        self.rules.deinit(allocator);
    }
};

const PolicyRule = struct {
    action: []const u8,
    resource: []const u8,
    conditions: []const u8,
    effect: enum { allow, deny },
};

const Tenant = struct {
    id: u64,
    name: []const u8,
    domain: []const u8,
    is_active: bool,
    user_limit: ?u32,
    storage_limit_gb: ?u32,
    features_enabled: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, id: u64, name: []const u8, domain: []const u8) Tenant {
        return Tenant{
            .id = id,
            .name = name,
            .domain = domain,
            .is_active = true,
            .user_limit = null,
            .storage_limit_gb = null,
            .features_enabled = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *Tenant, allocator: std.mem.Allocator) void {
        self.features_enabled.deinit(allocator);
    }
};

const UserManagementSystem = struct {
    allocator: std.mem.Allocator,
    users: std.AutoHashMap(u64, User),
    policies: std.AutoHashMap(u64, Policy),
    tenants: std.AutoHashMap(u64, Tenant),
    role_permissions: std.AutoHashMap(UserRole, std.ArrayList(Permission)),
    next_user_id: u64,
    next_policy_id: u64,
    next_tenant_id: u64,
    password_policy: PasswordPolicy,
    session_manager: SessionManager,
    audit_logger: AuditLogger,

    pub fn init(allocator: std.mem.Allocator) UserManagementSystem {
        var system = UserManagementSystem{
            .allocator = allocator,
            .users = std.AutoHashMap(u64, User).init(allocator),
            .policies = std.AutoHashMap(u64, Policy).init(allocator),
            .tenants = std.AutoHashMap(u64, Tenant).init(allocator),
            .role_permissions = std.AutoHashMap(UserRole, std.ArrayList(Permission)).init(allocator),
            .next_user_id = 1,
            .next_policy_id = 1,
            .next_tenant_id = 1,
            .password_policy = PasswordPolicy.default(),
            .session_manager = SessionManager.init(allocator),
            .audit_logger = AuditLogger.init(allocator),
        };

        // Initialize default role permissions
        system.initializeDefaultRoles() catch unreachable;
        return system;
    }

    pub fn deinit(self: *UserManagementSystem) void {
        // Clean up users
        var user_it = self.users.iterator();
        while (user_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.users.deinit();

        // Clean up policies
        var policy_it = self.policies.iterator();
        while (policy_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.policies.deinit();

        // Clean up tenants
        var tenant_it = self.tenants.iterator();
        while (tenant_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.tenants.deinit();

        // Clean up role permissions
        var role_it = self.role_permissions.iterator();
        while (role_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.role_permissions.deinit();

        self.session_manager.deinit();
        self.audit_logger.deinit();
    }

    pub fn createUser(self: *UserManagementSystem, username: []const u8, email: []const u8, role: UserRole, tenant_id: ?u64) !u64 {
        // Validate username uniqueness
        var user_it = self.users.iterator();
        while (user_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                return error.UsernameAlreadyExists;
            }
        }

        // Validate tenant exists if specified
        if (tenant_id) |tid| {
            if (!self.tenants.contains(tid)) {
                return error.TenantNotFound;
            }
        }

        const user_id = self.next_user_id;
        self.next_user_id += 1;

        var user = User.init(self.allocator, user_id, username, email, role);
        user.tenant_id = tenant_id;

        // Assign default permissions based on role
        if (self.role_permissions.get(role)) |perms| {
            for (perms.items) |perm| {
                try user.permissions.append(self.allocator, perm);
            }
        }

        try self.users.put(user_id, user);
        try self.audit_logger.logUserCreated(user_id, username, role);

        return user_id;
    }

    pub fn updateUserRole(self: *UserManagementSystem, user_id: u64, new_role: UserRole) !void {
        if (self.users.getPtr(user_id)) |user| {
            const old_role = user.role;
            user.role = new_role;

            // Update permissions based on new role
            user.permissions.clearRetainingCapacity();
            if (self.role_permissions.get(new_role)) |perms| {
                for (perms.items) |perm| {
                    try user.permissions.append(self.allocator, perm);
                }
            }

            try self.audit_logger.logRoleChanged(user_id, old_role, new_role);
        } else {
            return error.UserNotFound;
        }
    }

    pub fn deactivateUser(self: *UserManagementSystem, user_id: u64) !void {
        if (self.users.getPtr(user_id)) |user| {
            user.is_active = false;
            try self.session_manager.invalidateUserSessions(user_id);
            try self.audit_logger.logUserDeactivated(user_id);
        } else {
            return error.UserNotFound;
        }
    }

    pub fn createTenant(self: *UserManagementSystem, name: []const u8, domain: []const u8) !u64 {
        // Validate domain uniqueness
        var tenant_it = self.tenants.iterator();
        while (tenant_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.domain, domain)) {
                return error.DomainAlreadyExists;
            }
        }

        const tenant_id = self.next_tenant_id;
        self.next_tenant_id += 1;

        const tenant = Tenant.init(self.allocator, tenant_id, name, domain);
        try self.tenants.put(tenant_id, tenant);
        try self.audit_logger.logTenantCreated(tenant_id, name, domain);

        return tenant_id;
    }

    pub fn createPolicy(self: *UserManagementSystem, name: []const u8, tenant_id: ?u64) !u64 {
        const policy_id = self.next_policy_id;
        self.next_policy_id += 1;

        var policy = Policy.init(self.allocator, policy_id, name);
        policy.tenant_id = tenant_id;

        try self.policies.put(policy_id, policy);
        try self.audit_logger.logPolicyCreated(policy_id, name);

        return policy_id;
    }

    pub fn addPolicyRule(self: *UserManagementSystem, policy_id: u64, rule: PolicyRule) !void {
        if (self.policies.getPtr(policy_id)) |policy| {
            try policy.rules.append(self.allocator, rule);
            try self.audit_logger.logPolicyRuleAdded(policy_id, rule.action);
        } else {
            return error.PolicyNotFound;
        }
    }

    pub fn authenticateUser(self: *UserManagementSystem, username: []const u8, password: []const u8) !AuthResult {
        // Find user by username
        var user_it = self.users.iterator();
        var target_user: ?*User = null;

        while (user_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                target_user = entry.value_ptr;
                break;
            }
        }

        if (target_user == null) {
            try self.audit_logger.logAuthenticationFailed(username, "user_not_found");
            return AuthResult{ .success = false, .user_id = null, .session_token = null, .reason = "User not found" };
        }

        const user = target_user.?;

        if (!user.is_active) {
            try self.audit_logger.logAuthenticationFailed(username, "user_inactive");
            return AuthResult{ .success = false, .user_id = null, .session_token = null, .reason = "User account is inactive" };
        }

        // Check for account lockout
        if (user.failed_login_attempts >= 5) {
            try self.audit_logger.logAuthenticationFailed(username, "account_locked");
            return AuthResult{ .success = false, .user_id = null, .session_token = null, .reason = "Account locked due to failed attempts" };
        }

        // Simulate password verification
        const password_valid = self.verifyPassword(password, user.id);

        if (!password_valid) {
            user.failed_login_attempts += 1;
            try self.audit_logger.logAuthenticationFailed(username, "invalid_password");
            return AuthResult{ .success = false, .user_id = null, .session_token = null, .reason = "Invalid password" };
        }

        // Reset failed attempts on successful auth
        user.failed_login_attempts = 0;
        user.last_login = std.time.timestamp();

        // Create session
        const session_token = try self.session_manager.createSession(user.id, user.session_timeout);
        try self.audit_logger.logAuthenticationSuccessful(username, user.id);

        return AuthResult{
            .success = true,
            .user_id = user.id,
            .session_token = session_token,
            .reason = "Authentication successful",
        };
    }

    pub fn hasPermission(self: *const UserManagementSystem, user_id: u64, permission: Permission) bool {
        if (self.users.get(user_id)) |user| {
            for (user.permissions.items) |perm| {
                if (perm == permission) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn getUsersByTenant(self: *const UserManagementSystem, tenant_id: u64) !std.ArrayList(u64) {
        var tenant_users = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable;

        var user_it = self.users.iterator();
        while (user_it.next()) |entry| {
            const user = entry.value_ptr;
            if (user.tenant_id != null and user.tenant_id.? == tenant_id) {
                try tenant_users.append(self.allocator, user.id);
            }
        }

        return tenant_users;
    }

    pub fn getSystemStats(self: *const UserManagementSystem) SystemStats {
        var stats = SystemStats{
            .total_users = 0,
            .active_users = 0,
            .total_tenants = 0,
            .total_policies = 0,
            .total_sessions = 0,
        };

        var user_it = self.users.iterator();
        while (user_it.next()) |entry| {
            stats.total_users += 1;
            if (entry.value_ptr.is_active) {
                stats.active_users += 1;
            }
        }

        stats.total_tenants = @intCast(self.tenants.count());
        stats.total_policies = @intCast(self.policies.count());
        stats.total_sessions = @intCast(self.session_manager.getActiveSessionCount());

        return stats;
    }

    // Private helper methods

    fn initializeDefaultRoles(self: *UserManagementSystem) !void {
        // Super Admin permissions
        var super_admin_perms = std.ArrayList(Permission).initCapacity(self.allocator, 0) catch unreachable;
        try super_admin_perms.append(self.allocator, .read_database);
        try super_admin_perms.append(self.allocator, .write_database);
        try super_admin_perms.append(self.allocator, .create_index);
        try super_admin_perms.append(self.allocator, .drop_index);
        try super_admin_perms.append(self.allocator, .manage_users);
        try super_admin_perms.append(self.allocator, .manage_roles);
        try super_admin_perms.append(self.allocator, .backup_restore);
        try super_admin_perms.append(self.allocator, .system_config);
        try super_admin_perms.append(self.allocator, .audit_logs);
        try super_admin_perms.append(self.allocator, .execute_queries);
        try self.role_permissions.put(.super_admin, super_admin_perms);

        // Admin permissions
        var admin_perms = std.ArrayList(Permission).initCapacity(self.allocator, 0) catch unreachable;
        try admin_perms.append(self.allocator, .read_database);
        try admin_perms.append(self.allocator, .write_database);
        try admin_perms.append(self.allocator, .create_index);
        try admin_perms.append(self.allocator, .drop_index);
        try admin_perms.append(self.allocator, .manage_users);
        try admin_perms.append(self.allocator, .execute_queries);
        try self.role_permissions.put(.admin, admin_perms);

        // Analyst permissions
        var analyst_perms = std.ArrayList(Permission).initCapacity(self.allocator, 0) catch unreachable;
        try analyst_perms.append(self.allocator, .read_database);
        try analyst_perms.append(self.allocator, .execute_queries);
        try self.role_permissions.put(.analyst, analyst_perms);

        // Read-only permissions
        var readonly_perms = std.ArrayList(Permission).initCapacity(self.allocator, 0) catch unreachable;
        try readonly_perms.append(self.allocator, .read_database);
        try self.role_permissions.put(.read_only, readonly_perms);
    }

    fn verifyPassword(self: *const UserManagementSystem, password: []const u8, user_id: u64) bool {
        _ = self;
        _ = user_id;
        // Simplified password verification for testing
        return password.len >= self.password_policy.min_length;
    }
};

const AuthResult = struct {
    success: bool,
    user_id: ?u64,
    session_token: ?[]const u8,
    reason: []const u8,
};

const SystemStats = struct {
    total_users: u32,
    active_users: u32,
    total_tenants: u32,
    total_policies: u32,
    total_sessions: u32,
};

const PasswordPolicy = struct {
    min_length: u32,
    require_uppercase: bool,
    require_lowercase: bool,
    require_numbers: bool,
    require_symbols: bool,

    fn default() PasswordPolicy {
        return PasswordPolicy{
            .min_length = 8,
            .require_uppercase = true,
            .require_lowercase = true,
            .require_numbers = true,
            .require_symbols = false,
        };
    }
};

const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions: std.AutoHashMap([]const u8, SessionInfo),

    fn init(allocator: std.mem.Allocator) SessionManager {
        return SessionManager{
            .allocator = allocator,
            .sessions = std.AutoHashMap([]const u8, SessionInfo).init(allocator),
        };
    }

    fn deinit(self: *SessionManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    fn createSession(self: *SessionManager, user_id: u64, timeout_seconds: u32) ![]const u8 {
        const session_token = try std.fmt.allocPrint(self.allocator, "session_{d}_{d}", .{ user_id, std.time.timestamp() });
        const session_info = SessionInfo{
            .user_id = user_id,
            .created_at = std.time.timestamp(),
            .expires_at = std.time.timestamp() + timeout_seconds,
            .is_active = true,
        };

        try self.sessions.put(session_token, session_info);
        return session_token;
    }

    fn invalidateUserSessions(self: *SessionManager, user_id: u64) !void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.user_id == user_id) {
                entry.value_ptr.is_active = false;
            }
        }
    }

    fn getActiveSessionCount(self: *const SessionManager) u32 {
        var count: u32 = 0;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_active and entry.value_ptr.expires_at > std.time.timestamp()) {
                count += 1;
            }
        }
        return count;
    }
};

const SessionInfo = struct {
    user_id: u64,
    created_at: i64,
    expires_at: i64,
    is_active: bool,
};

const AuditLogger = struct {
    allocator: std.mem.Allocator,
    log_entries: std.ArrayList(AuditEntry),

    fn init(allocator: std.mem.Allocator) AuditLogger {
        return AuditLogger{
            .allocator = allocator,
            .log_entries = std.ArrayList(AuditEntry).initCapacity(allocator, 0) catch unreachable,
        };
    }

    fn deinit(self: *AuditLogger) void {
        self.log_entries.deinit(self.allocator);
    }

    fn logUserCreated(self: *AuditLogger, user_id: u64, username: []const u8, role: UserRole) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .user_created,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "User '{}' created with role '{}'", .{ username, @tagName(role) }),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn logRoleChanged(self: *AuditLogger, user_id: u64, old_role: UserRole, new_role: UserRole) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .role_changed,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "Role changed from '{}' to '{}'", .{ @tagName(old_role), @tagName(new_role) }),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn logUserDeactivated(self: *AuditLogger, user_id: u64) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .user_deactivated,
            .user_id = user_id,
            .details = try self.allocator.dupe(u8, "User deactivated"),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn logTenantCreated(self: *AuditLogger, tenant_id: u64, name: []const u8, domain: []const u8) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .tenant_created,
            .user_id = null,
            .details = try std.fmt.allocPrint(self.allocator, "Tenant '{}' created with domain '{}'", .{ name, domain }),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn logPolicyCreated(self: *AuditLogger, policy_id: u64, name: []const u8) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .policy_created,
            .user_id = null,
            .details = try std.fmt.allocPrint(self.allocator, "Policy '{}' created (ID: {})", .{ name, policy_id }),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn logPolicyRuleAdded(self: *AuditLogger, policy_id: u64, action: []const u8) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .policy_updated,
            .user_id = null,
            .details = try std.fmt.allocPrint(self.allocator, "Rule added to policy {} for action '{}'", .{ policy_id, action }),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn logAuthenticationSuccessful(self: *AuditLogger, username: []const u8, user_id: u64) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .authentication_success,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "Successful authentication for user '{}'", .{username}),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn logAuthenticationFailed(self: *AuditLogger, username: []const u8, reason: []const u8) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .event_type = .authentication_failed,
            .user_id = null,
            .details = try std.fmt.allocPrint(self.allocator, "Failed authentication for user '{}': {}", .{ username, reason }),
        };
        try self.log_entries.append(self.allocator, entry);
    }

    fn getAuditLog(self: *const AuditLogger) []const AuditEntry {
        return self.log_entries.items;
    }
};

const AuditEntry = struct {
    timestamp: i64,
    event_type: AuditEventType,
    user_id: ?u64,
    details: []const u8,
};

const AuditEventType = enum {
    user_created,
    user_deactivated,
    role_changed,
    tenant_created,
    policy_created,
    policy_updated,
    authentication_success,
    authentication_failed,
};

// Integration Tests

test "TestCANARY_REQ_GQL_202_UserManagementComprehensive" {
    const allocator = testing.allocator;

    var ums = UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create tenants
    const tenant1 = try ums.createTenant("Acme Corp", "acme.com");
    const tenant2 = try ums.createTenant("Beta Inc", "beta.com");

    // Create users with different roles
    const admin_user = try ums.createUser("admin", "admin@acme.com", .admin, tenant1);
    const analyst_user = try ums.createUser("analyst", "analyst@acme.com", .analyst, tenant1);
    const readonly_user = try ums.createUser("viewer", "viewer@beta.com", .read_only, tenant2);

    // Test role-based permissions
    try testing.expect(ums.hasPermission(admin_user, .manage_users));
    try testing.expect(ums.hasPermission(analyst_user, .execute_queries));
    try testing.expect(!ums.hasPermission(analyst_user, .manage_users));
    try testing.expect(ums.hasPermission(readonly_user, .read_database));
    try testing.expect(!ums.hasPermission(readonly_user, .write_database));

    // Test multi-tenant isolation
    const tenant1_users = try ums.getUsersByTenant(tenant1);
    defer tenant1_users.deinit(allocator);
    const tenant2_users = try ums.getUsersByTenant(tenant2);
    defer tenant2_users.deinit(allocator);

    try testing.expect(tenant1_users.items.len == 2); // admin and analyst
    try testing.expect(tenant2_users.items.len == 1); // readonly

    // Test authentication
    const auth_result = try ums.authenticateUser("admin", "validpassword123");
    try testing.expect(auth_result.success);
    try testing.expect(auth_result.user_id.? == admin_user);
    try testing.expect(auth_result.session_token != null);

    // Test system statistics
    const stats = ums.getSystemStats();
    try testing.expect(stats.total_users == 3);
    try testing.expect(stats.active_users == 3);
    try testing.expect(stats.total_tenants == 2);
    try testing.expect(stats.total_sessions >= 1);

    std.debug.print("\nComprehensive user management integration test passed\n", .{});
    std.debug.print("  Created {} users across {} tenants\n", .{ stats.total_users, stats.total_tenants });
    std.debug.print("  Active sessions: {}\n", .{stats.total_sessions});
}

test "policy and permission management" {
    const allocator = testing.allocator;

    var ums = UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create tenant and policy
    const tenant_id = try ums.createTenant("PolicyTest Corp", "policy.com");
    const policy_id = try ums.createPolicy("Data Access Policy", tenant_id);

    // Add policy rules
    const read_rule = PolicyRule{
        .action = "read",
        .resource = "database.*",
        .conditions = "tenant_id = " ++ "policy.com",
        .effect = .allow,
    };

    const write_rule = PolicyRule{
        .action = "write",
        .resource = "database.sensitive",
        .conditions = "role = admin",
        .effect = .deny,
    };

    try ums.addPolicyRule(policy_id, read_rule);
    try ums.addPolicyRule(policy_id, write_rule);

    // Verify policy creation
    try testing.expect(ums.policies.contains(policy_id));
    const policy = ums.policies.get(policy_id).?;
    try testing.expect(policy.rules.items.len == 2);
    try testing.expect(policy.tenant_id.? == tenant_id);

    std.debug.print("\nPolicy and permission management test passed\n", .{});
}

test "authentication and session management" {
    const allocator = testing.allocator;

    var ums = UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create test user
    const user_id = try ums.createUser("testuser", "test@example.com", .analyst, null);

    // Test successful authentication
    const success_auth = try ums.authenticateUser("testuser", "validpassword123");
    try testing.expect(success_auth.success);
    try testing.expect(success_auth.user_id.? == user_id);

    // Test failed authentication - wrong password
    const fail_auth = try ums.authenticateUser("testuser", "wrong");
    try testing.expect(!fail_auth.success);
    try testing.expect(std.mem.indexOf(u8, fail_auth.reason, "password") != null);

    // Test failed authentication - non-existent user
    const nouser_auth = try ums.authenticateUser("nonexistent", "password");
    try testing.expect(!nouser_auth.success);
    try testing.expect(std.mem.indexOf(u8, nouser_auth.reason, "not found") != null);

    // Test account lockout after multiple failed attempts
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        _ = try ums.authenticateUser("testuser", "wrong");
    }

    const locked_auth = try ums.authenticateUser("testuser", "validpassword123");
    try testing.expect(!locked_auth.success);
    try testing.expect(std.mem.indexOf(u8, locked_auth.reason, "locked") != null);

    std.debug.print("\nAuthentication and session management test passed\n", .{});
}

test "role hierarchy and permission inheritance" {
    const allocator = testing.allocator;

    var ums = UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create users with different roles
    const super_admin = try ums.createUser("superadmin", "super@test.com", .super_admin, null);
    const admin = try ums.createUser("admin", "admin@test.com", .admin, null);
    const analyst = try ums.createUser("analyst", "analyst@test.com", .analyst, null);
    const readonly = try ums.createUser("readonly", "readonly@test.com", .read_only, null);

    // Test permission hierarchy
    try testing.expect(ums.hasPermission(super_admin, .system_config)); // Super admin has all permissions
    try testing.expect(ums.hasPermission(super_admin, .audit_logs));
    try testing.expect(ums.hasPermission(admin, .manage_users)); // Admin has most permissions
    try testing.expect(!ums.hasPermission(admin, .system_config)); // But not system config
    try testing.expect(ums.hasPermission(analyst, .execute_queries)); // Analyst can query
    try testing.expect(!ums.hasPermission(analyst, .write_database)); // But not write
    try testing.expect(ums.hasPermission(readonly, .read_database)); // Readonly can read
    try testing.expect(!ums.hasPermission(readonly, .execute_queries)); // But not execute

    // Test role changes
    try ums.updateUserRole(analyst, .admin);
    try testing.expect(ums.hasPermission(analyst, .manage_users)); // Now has admin permissions

    std.debug.print("\nRole hierarchy and permission inheritance test passed\n", .{});
}

test "multi-tenant isolation and limits" {
    const allocator = testing.allocator;

    var ums = UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Create tenants with limits
    const enterprise_tenant = try ums.createTenant("Enterprise Corp", "enterprise.com");
    const startup_tenant = try ums.createTenant("Startup Inc", "startup.com");

    // Set tenant-specific features
    var enterprise = ums.tenants.getPtr(enterprise_tenant).?;
    try enterprise.features_enabled.append(allocator, "advanced_analytics");
    try enterprise.features_enabled.append(allocator, "enterprise_backup");
    enterprise.user_limit = 1000;
    enterprise.storage_limit_gb = 1000;

    var startup = ums.tenants.getPtr(startup_tenant).?;
    try startup.features_enabled.append(allocator, "basic_analytics");
    startup.user_limit = 10;
    startup.storage_limit_gb = 10;

    // Create users in different tenants
    const ent_admin = try ums.createUser("ent_admin", "admin@enterprise.com", .admin, enterprise_tenant);
    const ent_user = try ums.createUser("ent_user", "user@enterprise.com", .analyst, enterprise_tenant);
    const startup_admin = try ums.createUser("startup_admin", "admin@startup.com", .admin, startup_tenant);

    // Test tenant isolation
    const ent_users = try ums.getUsersByTenant(enterprise_tenant);
    defer ent_users.deinit(allocator);
    const startup_users = try ums.getUsersByTenant(startup_tenant);
    defer startup_users.deinit(allocator);

    try testing.expect(ent_users.items.len == 2);
    try testing.expect(startup_users.items.len == 1);

    // Verify users are in correct tenants
    var found_ent_admin = false;
    var found_ent_user = false;
    for (ent_users.items) |user_id| {
        if (user_id == ent_admin) found_ent_admin = true;
        if (user_id == ent_user) found_ent_user = true;
    }
    try testing.expect(found_ent_admin and found_ent_user);

    var found_startup_admin = false;
    for (startup_users.items) |user_id| {
        if (user_id == startup_admin) found_startup_admin = true;
    }
    try testing.expect(found_startup_admin);

    std.debug.print("\nMulti-tenant isolation and limits test passed\n", .{});
    std.debug.print("  Enterprise tenant: {} users, {} features\n", .{ ent_users.items.len, enterprise.features_enabled.items.len });
    std.debug.print("  Startup tenant: {} users, {} features\n", .{ startup_users.items.len, startup.features_enabled.items.len });
}

test "audit logging and compliance" {
    const allocator = testing.allocator;

    var ums = UserManagementSystem.init(allocator);
    defer ums.deinit();

    // Perform various operations that should be audited
    const tenant_id = try ums.createTenant("Audit Corp", "audit.com");
    const user_id = try ums.createUser("audituser", "audit@audit.com", .analyst, tenant_id);
    const policy_id = try ums.createPolicy("Audit Policy", tenant_id);

    try ums.updateUserRole(user_id, .admin);
    try ums.deactivateUser(user_id);
    _ = try ums.authenticateUser("audituser", "password"); // Should fail due to deactivation
    _ = try ums.authenticateUser("nonexistent", "password"); // Should fail due to non-existence

    // Check audit log
    const audit_log = ums.audit_logger.getAuditLog();
    try testing.expect(audit_log.len >= 6); // At least 6 audit events

    // Verify specific audit events exist
    var found_user_created = false;
    var found_role_changed = false;
    var found_user_deactivated = false;
    var found_auth_failed = false;

    for (audit_log) |entry| {
        switch (entry.event_type) {
            .user_created => found_user_created = true,
            .role_changed => found_role_changed = true,
            .user_deactivated => found_user_deactivated = true,
            .authentication_failed => found_auth_failed = true,
            else => {},
        }
    }

    try testing.expect(found_user_created);
    try testing.expect(found_role_changed);
    try testing.expect(found_user_deactivated);
    try testing.expect(found_auth_failed);

    std.debug.print("\nAudit logging and compliance test passed\n", .{});
    std.debug.print("  Total audit events: {}\n", .{audit_log.len});
}

test "large scale user management simulation" {
    const allocator = testing.allocator;

    var ums = UserManagementSystem.init(allocator);
    defer ums.deinit();

    var timer = std.time.Timer.start() catch return;

    // Create multiple tenants
    const num_tenants = 10;
    const users_per_tenant = 50;

    var tenant_ids = std.ArrayList(u64).initCapacity(allocator, num_tenants) catch unreachable;
    defer tenant_ids.deinit(allocator);

    // Create tenants
    for (0..num_tenants) |i| {
        const tenant_name = try std.fmt.allocPrint(allocator, "Tenant_{}", .{i});
        defer allocator.free(tenant_name);
        const tenant_domain = try std.fmt.allocPrint(allocator, "tenant{}.com", .{i});
        defer allocator.free(tenant_domain);

        const tenant_id = try ums.createTenant(tenant_name, tenant_domain);
        try tenant_ids.append(allocator, tenant_id);
    }

    const tenant_creation_time = timer.lap();

    // Create users across tenants
    for (tenant_ids.items, 0..) |tenant_id, tenant_idx| {
        for (0..users_per_tenant) |user_idx| {
            const username = try std.fmt.allocPrint(allocator, "user_{}_{}", .{ tenant_idx, user_idx });
            defer allocator.free(username);
            const email = try std.fmt.allocPrint(allocator, "user{}@tenant{}.com", .{ user_idx, tenant_idx });
            defer allocator.free(email);

            const role = switch (user_idx % 4) {
                0 => UserRole.admin,
                1 => UserRole.analyst,
                2 => UserRole.read_only,
                else => UserRole.analyst,
            };

            _ = try ums.createUser(username, email, role, tenant_id);
        }
    }

    const user_creation_time = timer.lap();

    // Test authentication performance
    const auth_start = timer.lap();
    for (0..100) |i| {
        const username = try std.fmt.allocPrint(allocator, "user_0_{}", .{i % users_per_tenant});
        defer allocator.free(username);
        _ = try ums.authenticateUser(username, "testpassword123");
    }
    const auth_time = timer.read();

    // Get final statistics
    const stats = ums.getSystemStats();

    try testing.expect(stats.total_tenants == num_tenants);
    try testing.expect(stats.total_users == num_tenants * users_per_tenant);
    try testing.expect(stats.active_users == stats.total_users);

    std.debug.print("\nLarge scale user management simulation completed\n", .{});
    std.debug.print("  Tenants: {}\n", .{stats.total_tenants});
    std.debug.print("  Users: {}\n", .{stats.total_users});
    std.debug.print("  Tenant creation time: {}ms\n", .{@divTrunc(tenant_creation_time, 1000000)});
    std.debug.print("  User creation time: {}ms\n", .{@divTrunc(user_creation_time, 1000000)});
    std.debug.print("  100 authentications time: {}ms\n", .{@divTrunc(auth_time, 1000000)});
    std.debug.print("  Active sessions: {}\n", .{stats.total_sessions});
}
