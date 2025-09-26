const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
// Local MFA module (no external feature_flag dependency)
const mfa = @import("mfa.zig");

// Core user management
pub const UserId = u64;
pub const RoleId = u64;
pub const PermissionId = u64;
pub const PolicyId = u64;

pub const User = struct {
    id: UserId,
    username: []const u8,
    email: []const u8,
    password_hash: [64]u8, // Argon2id hash
    created_at: i64,
    updated_at: i64,
    last_login: ?i64,
    is_active: bool,
    is_superuser: bool,
    mfa_enabled: bool,
    mfa_secret: ?[]const u8,
    attributes: std.StringHashMap([]const u8), // For ABAC
    metadata: std.json.Value,
};

pub const Role = struct {
    id: RoleId,
    name: []const u8,
    description: []const u8,
    permissions: std.ArrayList(PermissionId),
    created_at: i64,
    is_system: bool, // System roles cannot be deleted
    priority: u32, // For role hierarchy
    parent_role: ?RoleId, // For role inheritance
};

pub const Permission = struct {
    id: PermissionId,
    name: []const u8,
    resource: []const u8,
    action: Action,
    conditions: ?[]const u8, // JSON conditions for fine-grained control
    created_at: i64,
};

pub const Action = enum {
    create,
    read,
    update,
    delete,
    execute,
    grant,
    revoke,
    all,
};

pub const Resource = enum {
    graph,
    node,
    edge,
    property,
    index,
    user,
    role,
    permission,
    query,
    transaction,
    system,
};

// RBAC - Role-Based Access Control
pub const RBACPolicy = struct {
    user_roles: std.AutoHashMap(UserId, std.ArrayList(RoleId)),
    role_permissions: std.AutoHashMap(RoleId, std.ArrayList(Permission)),
    role_hierarchy: std.AutoHashMap(RoleId, std.ArrayList(RoleId)),

    pub fn hasPermission(self: *RBACPolicy, user_id: UserId, resource: []const u8, action: Action) bool {
        const roles = self.user_roles.get(user_id) orelse return false;

        for (roles.items) |role_id| {
            if (self.checkRolePermission(role_id, resource, action)) {
                return true;
            }
        }

        return false;
    }

    fn checkRolePermission(self: *RBACPolicy, role_id: RoleId, resource: []const u8, action: Action) bool {
        // Check direct permissions
        if (self.role_permissions.get(role_id)) |permissions| {
            for (permissions.items) |perm| {
                if (std.mem.eql(u8, perm.resource, resource) and
                    (perm.action == action or perm.action == .all))
                {
                    return true;
                }
            }
        }

        // Check inherited permissions
        if (self.role_hierarchy.get(role_id)) |parent_roles| {
            for (parent_roles.items) |parent_id| {
                if (self.checkRolePermission(parent_id, resource, action)) {
                    return true;
                }
            }
        }

        return false;
    }
};

// ABAC - Attribute-Based Access Control
pub const ABACPolicy = struct {
    id: PolicyId,
    name: []const u8,
    description: []const u8,
    effect: Effect,
    subjects: []const AttributeCondition,
    resources: []const AttributeCondition,
    actions: []const Action,
    conditions: []const EnvironmentCondition,
    priority: u32,
    enabled: bool,
};

pub const Effect = enum {
    allow,
    deny,
};

pub const AttributeCondition = struct {
    attribute: []const u8,
    operator: ComparisonOperator,
    value: std.json.Value,
};

pub const ComparisonOperator = enum {
    equals,
    not_equals,
    contains,
    not_contains,
    greater_than,
    less_than,
    in,
    not_in,
    matches, // Regex
};

pub const EnvironmentCondition = struct {
    type: ConditionType,
    parameters: std.json.Value,
};

pub const ConditionType = enum {
    time_range,
    ip_range,
    location,
    device_type,
    request_rate,
};

// Row-Level Security
pub const RowLevelPolicy = struct {
    id: PolicyId,
    name: []const u8,
    table: []const u8, // Graph, node type, or edge type
    operation: Operation,
    using_clause: []const u8, // GQL expression for filtering
    check_clause: ?[]const u8, // GQL expression for validation
    roles: []const RoleId, // Roles this policy applies to
    enabled: bool,
};

pub const Operation = enum {
    select,
    insert,
    update,
    delete,
    all,
};

// Security Context for request evaluation
pub const SecurityContext = struct {
    user: *User,
    roles: []const Role,
    session_attributes: std.StringHashMap([]const u8),
    request_attributes: std.StringHashMap([]const u8),
    environment: EnvironmentInfo,
};

pub const EnvironmentInfo = struct {
    timestamp: i64,
    ip_address: []const u8,
    user_agent: []const u8,
    location: ?Location,
    device_id: ?[]const u8,
};

pub const Location = struct {
    country: []const u8,
    region: []const u8,
    city: []const u8,
    latitude: f64,
    longitude: f64,
};

// Main Security Manager
pub const SecurityManager = struct {
    allocator: Allocator,
    users: std.AutoHashMap(UserId, User),
    roles: std.AutoHashMap(RoleId, Role),
    permissions: std.AutoHashMap(PermissionId, Permission),
    rbac: RBACPolicy,
    abac_policies: std.ArrayList(ABACPolicy),
    row_policies: std.ArrayList(RowLevelPolicy),
    sessions: std.StringHashMap(Session),
    audit_log: AuditLog,
    password_policy: PasswordPolicy,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        var manager = Self{
            .allocator = allocator,
            .users = std.AutoHashMap(UserId, User).init(allocator),
            .roles = std.AutoHashMap(RoleId, Role).init(allocator),
            .permissions = std.AutoHashMap(PermissionId, Permission).init(allocator),
            .rbac = RBACPolicy{
                .user_roles = std.AutoHashMap(UserId, std.ArrayList(RoleId)).init(allocator),
                .role_permissions = std.AutoHashMap(RoleId, std.ArrayList(Permission)).init(allocator),
                .role_hierarchy = std.AutoHashMap(RoleId, std.ArrayList(RoleId)).init(allocator),
            },
            .abac_policies = std.ArrayList(ABACPolicy).initCapacity(allocator, 0) catch unreachable,
            .row_policies = std.ArrayList(RowLevelPolicy).initCapacity(allocator, 0) catch unreachable,
            .sessions = std.StringHashMap(Session).init(allocator),
            .audit_log = try AuditLog.init(allocator),
            .password_policy = PasswordPolicy.default(),
        };

        // Initialize default roles
        try manager.initializeDefaultRoles();

        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.users.deinit();
        self.roles.deinit();
        self.permissions.deinit();
        self.rbac.user_roles.deinit();
        self.rbac.role_permissions.deinit();
        self.rbac.role_hierarchy.deinit();
        self.abac_policies.deinit(self.allocator);
        self.row_policies.deinit(self.allocator);
        self.sessions.deinit();
        self.audit_log.deinit();
    }

    // User Management
    pub fn createUser(self: *Self, username: []const u8, email: []const u8, password: []const u8) !*User {
        // Validate password
        try self.validatePassword(password);

        // Check if user exists
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                return error.UserAlreadyExists;
            }
            if (std.mem.eql(u8, entry.value_ptr.email, email)) {
                return error.EmailAlreadyExists;
            }
        }

        // Hash password
        const password_hash = try self.hashPassword(password);

        const user_id = @as(UserId, @intCast(self.users.count() + 1));
        const user = User{
            .id = user_id,
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password_hash = password_hash,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
            .last_login = null,
            .is_active = true,
            .is_superuser = false,
            .mfa_enabled = false,
            .mfa_secret = null,
            .attributes = std.StringHashMap([]const u8).init(self.allocator),
            .metadata = .{ .object = std.json.ObjectMap.init(self.allocator) },
        };

        try self.users.put(user_id, user);

        // Assign default role
        try self.assignRole(user_id, 1); // Default user role

        // Audit log
        try self.audit_log.logUserCreated(user_id, username);

        return self.users.getPtr(user_id).?;
    }

    pub fn authenticate(self: *Self, username: []const u8, password: []const u8) !*User {
        // Find user
        var user: ?*User = null;
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                user = entry.value_ptr;
                break;
            }
        }

        const u = user orelse return error.InvalidCredentials;

        // Check if user is active
        if (!u.is_active) {
            return error.UserInactive;
        }

        // Verify password
        if (!try self.verifyPassword(password, u.password_hash)) {
            try self.audit_log.logFailedLogin(u.id, username);
            return error.InvalidCredentials;
        }

        // MFA enforcement: if global flag enabled and user has MFA, require second factor
        if (mfa.globallyEnabled() and u.mfa_enabled) {
            // Do not create session yet; signal requirement
            return error.MFARequired;
        }

        // Update last login
        u.last_login = std.time.milliTimestamp();

        // Create session
        const session_token = try self.createSession(u.id);
        _ = session_token;

        // Audit log
        try self.audit_log.logSuccessfulLogin(u.id, username);

        return u;
    }

    /// Authenticate including MFA code when required. If MFA not required behaves like authenticate.
    /// CANARY: REQ=REQ-GQL-MFA-002; FEATURE="MFA authentication enforcement"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=tests/unit_mfa_enforcement.zig:1; OWNER=security; UPDATED=2025-09-26
    pub fn authenticateWithMFA(self: *Self, username: []const u8, password: []const u8, code: ?u32) !*User {
        // First attempt base authentication (may return MFARequired)
        const base = self.authenticate(username, password) catch |e| switch (e) {
            error.MFARequired => null, // proceed to MFA path
            else => return e,
        };

        if (base) |u| {
            // No MFA required; already authenticated.
            return u;
        }

        // At this point MFA is required.
        if (code == null) return error.MFAVerificationFailed; // missing code

        // Lookup user again (password already verified earlier)
        var found: ?*User = null;
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                found = entry.value_ptr;
                break;
            }
        }
        const u = found orelse return error.InvalidCredentials;

        const secret = u.mfa_secret orelse return error.MFASecretMissing;

        // Verify provided TOTP code (current +/-1 step)
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        // Enable MFA module temporarily if test harness disabled (should rely on flag otherwise)
        if (!mfa.globallyEnabled()) return error.MFAVerificationFailed;
        const ok = mfa.verifyCode(self.allocator, secret, now_ms, code.?, 30, 6, 1) catch |mferr| switch (mferr) {
            error.FeatureDisabled => false,
            else => return mferr,
        };
        if (!ok) return error.MFAVerificationFailed;

        // Success: create session & audit
        u.last_login = std.time.milliTimestamp();
        const session_token = try self.createSession(u.id);
        _ = session_token;
        try self.audit_log.logSuccessfulLogin(u.id, username);
        return u;
    }

    // Role Management
    pub fn createRole(self: *Self, name: []const u8, description: []const u8) !*Role {
        const role_id = @as(RoleId, @intCast(self.roles.count() + 1));

        const role = Role{
            .id = role_id,
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, description),
            .permissions = std.ArrayList(PermissionId).initCapacity(self.allocator, 0) catch unreachable,
            .created_at = std.time.milliTimestamp(),
            .is_system = false,
            .priority = 100,
            .parent_role = null,
        };

        try self.roles.put(role_id, role);
        return self.roles.getPtr(role_id).?;
    }

    pub fn assignRole(self: *Self, user_id: UserId, role_id: RoleId) !void {
        // Verify user and role exist
        _ = self.users.get(user_id) orelse return error.UserNotFound;
        _ = self.roles.get(role_id) orelse return error.RoleNotFound;

        // Get or create user's role list
        const result = try self.rbac.user_roles.getOrPut(user_id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(RoleId).initCapacity(self.allocator, 0) catch unreachable;
        }

        // Check if role already assigned
        for (result.value_ptr.items) |existing_role| {
            if (existing_role == role_id) {
                return; // Already assigned
            }
        }

        try result.value_ptr.append(self.allocator, role_id);

        // Audit log
        try self.audit_log.logRoleAssigned(user_id, role_id);
    }

    pub fn revokeRole(self: *Self, user_id: UserId, role_id: RoleId) !void {
        const user_roles = self.rbac.user_roles.getPtr(user_id) orelse return error.UserHasNoRoles;

        for (user_roles.items, 0..) |role, i| {
            if (role == role_id) {
                _ = user_roles.orderedRemove(i);
                try self.audit_log.logRoleRevoked(user_id, role_id);
                return;
            }
        }

        return error.RoleNotAssigned;
    }

    // Permission Management
    pub fn createPermission(self: *Self, name: []const u8, resource: []const u8, action: Action) !*Permission {
        const perm_id = @as(PermissionId, @intCast(self.permissions.count() + 1));

        const permission = Permission{
            .id = perm_id,
            .name = try self.allocator.dupe(u8, name),
            .resource = try self.allocator.dupe(u8, resource),
            .action = action,
            .conditions = null,
            .created_at = std.time.milliTimestamp(),
        };

        try self.permissions.put(perm_id, permission);
        return self.permissions.getPtr(perm_id).?;
    }

    pub fn grantPermission(self: *Self, role_id: RoleId, permission_id: PermissionId) !void {
        const role = self.roles.getPtr(role_id) orelse return error.RoleNotFound;
        const permission = self.permissions.get(permission_id) orelse return error.PermissionNotFound;

        // Check if already granted
        for (role.permissions.items) |perm| {
            if (perm == permission_id) {
                return; // Already granted
            }
        }

        try role.permissions.append(self.allocator, permission_id);

        // Update RBAC policy
        const result = try self.rbac.role_permissions.getOrPut(role_id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(Permission).initCapacity(self.allocator, 0) catch unreachable;
        }
        try result.value_ptr.append(self.allocator, permission);

        try self.audit_log.logPermissionGranted(role_id, permission_id);
    }

    // ABAC Policy Management
    pub fn createABACPolicy(self: *Self, policy: ABACPolicy) !void {
        try self.abac_policies.append(self.allocator, policy);
        try self.audit_log.logPolicyCreated(policy.id, policy.name);
    }

    pub fn evaluateABACPolicies(self: *Self, context: *SecurityContext, resource: []const u8, action: Action) !bool {
        var allow = false;
        var explicit_deny = false;

        for (self.abac_policies.items) |policy| {
            if (!policy.enabled) continue;

            // Check if action matches
            var action_matches = false;
            for (policy.actions) |pol_action| {
                if (pol_action == action or pol_action == .all) {
                    action_matches = true;
                    break;
                }
            }
            if (!action_matches) continue;

            // Evaluate subject conditions
            if (!self.evaluateAttributeConditions(policy.subjects, context.user.attributes)) {
                continue;
            }

            // Evaluate resource conditions
            var resource_attrs = std.StringHashMap([]const u8).init(self.allocator);
            defer resource_attrs.deinit();
            try resource_attrs.put("name", resource);

            if (!self.evaluateAttributeConditions(policy.resources, resource_attrs)) {
                continue;
            }

            // Evaluate environment conditions
            if (!try self.evaluateEnvironmentConditions(policy.conditions, context.environment)) {
                continue;
            }

            // Apply effect
            switch (policy.effect) {
                .allow => allow = true,
                .deny => {
                    explicit_deny = true;
                    break; // Deny takes precedence
                },
            }
        }

        return !explicit_deny and allow;
    }

    fn evaluateAttributeConditions(self: *Self, conditions: []const AttributeCondition, attributes: std.StringHashMap([]const u8)) bool {
        _ = self;
        for (conditions) |condition| {
            const attr_value = attributes.get(condition.attribute) orelse return false;

            // Simplified evaluation - in production would handle all operators
            switch (condition.operator) {
                .equals => {
                    if (condition.value == .string) {
                        if (!std.mem.eql(u8, attr_value, condition.value.string)) {
                            return false;
                        }
                    }
                },
                .contains => {
                    if (condition.value == .string) {
                        if (std.mem.indexOf(u8, attr_value, condition.value.string) == null) {
                            return false;
                        }
                    }
                },
                else => return false,
            }
        }
        return true;
    }

    fn evaluateEnvironmentConditions(self: *Self, conditions: []const EnvironmentCondition, env: EnvironmentInfo) !bool {
        _ = self;
        for (conditions) |condition| {
            switch (condition.type) {
                .time_range => {
                    // Check if current time is within range
                    const now = env.timestamp;
                    if (condition.parameters == .object) {
                        const start = condition.parameters.object.get("start").?.integer;
                        const end = condition.parameters.object.get("end").?.integer;
                        if (now < start or now > end) {
                            return false;
                        }
                    }
                },
                .ip_range => {
                    // Check if IP is in allowed range
                    // Simplified - would need proper IP parsing
                    if (condition.parameters == .string) {
                        if (!std.mem.startsWith(u8, env.ip_address, condition.parameters.string)) {
                            return false;
                        }
                    }
                },
                else => {},
            }
        }
        return true;
    }

    // Row-Level Security
    pub fn createRowLevelPolicy(self: *Self, policy: RowLevelPolicy) !void {
        try self.row_policies.append(self.allocator, policy);
        try self.audit_log.logRowPolicyCreated(policy.id, policy.name);
    }

    pub fn applyRowLevelSecurity(self: *Self, user_id: UserId, query: []const u8, table: []const u8) ![]const u8 {
        const user_roles = self.rbac.user_roles.get(user_id) orelse return query;

        var applicable_policies = std.ArrayList(RowLevelPolicy).init(self.allocator);
        defer applicable_policies.deinit();

        // Find applicable policies
        for (self.row_policies.items) |policy| {
            if (!policy.enabled) continue;
            if (!std.mem.eql(u8, policy.table, table)) continue;

            // Check if user has required role
            for (policy.roles) |required_role| {
                for (user_roles.items) |user_role| {
                    if (user_role == required_role) {
                        try applicable_policies.append(policy);
                        break;
                    }
                }
            }
        }

        if (applicable_policies.items.len == 0) {
            return query; // No policies apply
        }

        // Build modified query with security predicates
        var modified_query = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        try modified_query.appendSlice(self.allocator, query);

        // Add WHERE clause with security predicates
        try modified_query.appendSlice(self.allocator, " WHERE (");
        for (applicable_policies.items, 0..) |policy, i| {
            if (i > 0) {
                try modified_query.appendSlice(self.allocator, " OR ");
            }
            try modified_query.appendSlice(self.allocator, policy.using_clause);
        }
        try modified_query.appendSlice(self.allocator, ")");

        return try modified_query.toOwnedSlice(self.allocator);
    }

    // Session Management
    pub fn createSession(self: *Self, user_id: UserId) ![]const u8 {
        var token_bytes: [32]u8 = undefined;
        crypto.random.bytes(&token_bytes);

        // Convert to base64 for the token string
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const token = try self.allocator.alloc(u8, encoder.calcSize(token_bytes.len));
        _ = encoder.encode(token, &token_bytes);

        const session = Session{
            .token = token,
            .user_id = user_id,
            .created_at = std.time.milliTimestamp(),
            .expires_at = std.time.milliTimestamp() + (24 * 60 * 60 * 1000), // 24 hours
            .ip_address = null,
            .user_agent = null,
        };

        try self.sessions.put(token, session);
        return token;
    }

    pub fn validateSession(self: *Self, token: []const u8) !UserId {
        const session = self.sessions.get(token) orelse return error.InvalidSession;

        if (std.time.milliTimestamp() > session.expires_at) {
            _ = self.sessions.remove(token);
            return error.SessionExpired;
        }

        return session.user_id;
    }

    // Authorization checks
    pub fn authorize(self: *Self, user_id: UserId, resource: []const u8, action: Action) !bool {
        const user = self.users.getPtr(user_id) orelse return error.UserNotFound;

        // Superuser bypass
        if (user.is_superuser) {
            return true;
        }

        // Check RBAC
        if (self.rbac.hasPermission(user_id, resource, action)) {
            return true;
        }

        // Check ABAC if RBAC fails
        var context = SecurityContext{
            .user = user,
            .roles = &[_]Role{},
            .session_attributes = std.StringHashMap([]const u8).init(self.allocator),
            .request_attributes = std.StringHashMap([]const u8).init(self.allocator),
            .environment = EnvironmentInfo{
                .timestamp = std.time.milliTimestamp(),
                .ip_address = "127.0.0.1",
                .user_agent = "geode-client",
                .location = null,
                .device_id = null,
            },
        };
        defer {
            context.session_attributes.deinit();
            context.request_attributes.deinit();
        }

        return try self.evaluateABACPolicies(&context, resource, action);
    }

    // Helper functions
    pub fn hashPassword(_: *Self, password: []const u8) ![64]u8 {
        var hash: [64]u8 = undefined;

        // Use simple hash for now - in production use Argon2id
        const salt = "geode-salt-v1";
        var h = std.hash.Wyhash.init(0);
        h.update(password);
        h.update(salt);
        const result = h.final();

        // Fill the hash array
        std.mem.writeInt(u64, hash[0..8], result, .little);
        for (hash[8..]) |*b| {
            b.* = 0;
        }

        return hash;
    }

    fn verifyPassword(self: *Self, password: []const u8, hash: [64]u8) !bool {
        _ = self;
        _ = password;
        _ = hash;
        // Simplified - in production would properly verify
        return true;
    }

    pub fn validatePassword(self: *Self, password: []const u8) !void {
        if (password.len < self.password_policy.min_length) {
            return error.PasswordTooShort;
        }

        if (password.len > self.password_policy.max_length) {
            return error.PasswordTooLong;
        }

        if (self.password_policy.require_uppercase) {
            var has_upper = false;
            for (password) |c| {
                if (std.ascii.isUpper(c)) {
                    has_upper = true;
                    break;
                }
            }
            if (!has_upper) return error.PasswordMissingUppercase;
        }

        if (self.password_policy.require_lowercase) {
            var has_lower = false;
            for (password) |c| {
                if (std.ascii.isLower(c)) {
                    has_lower = true;
                    break;
                }
            }
            if (!has_lower) return error.PasswordMissingLowercase;
        }

        if (self.password_policy.require_digit) {
            var has_digit = false;
            for (password) |c| {
                if (std.ascii.isDigit(c)) {
                    has_digit = true;
                    break;
                }
            }
            if (!has_digit) return error.PasswordMissingDigit;
        }

        if (self.password_policy.require_special) {
            var has_special = false;
            for (password) |c| {
                if (!std.ascii.isAlphanumeric(c)) {
                    has_special = true;
                    break;
                }
            }
            if (!has_special) return error.PasswordMissingSpecial;
        }
    }

    fn initializeDefaultRoles(self: *Self) !void {
        // Create default roles
        _ = try self.createRole("user", "Default user role");
        _ = try self.createRole("admin", "Administrator role");
        _ = try self.createRole("viewer", "Read-only role");

        // Create default permissions
        const read_perm = try self.createPermission("read_all", "graph", .read);
        _ = try self.createPermission("write_all", "graph", .update);
        const admin_perm = try self.createPermission("admin_all", "system", .all);

        // Assign permissions to roles
        try self.grantPermission(1, read_perm.id); // user can read
        try self.grantPermission(2, admin_perm.id); // admin can do everything
        try self.grantPermission(3, read_perm.id); // viewer can only read

        // Set up role hierarchy
        try self.rbac.role_hierarchy.put(2, std.ArrayList(RoleId).initCapacity(self.allocator, 0) catch unreachable); // Admin inherits from user
        try self.rbac.role_hierarchy.getPtr(2).?.append(self.allocator, 1);
    }
};

// Session management
pub const Session = struct {
    token: []const u8,
    user_id: UserId,
    created_at: i64,
    expires_at: i64,
    ip_address: ?[]const u8,
    user_agent: ?[]const u8,
};

// Password policy
pub const PasswordPolicy = struct {
    min_length: usize,
    max_length: usize,
    require_uppercase: bool,
    require_lowercase: bool,
    require_digit: bool,
    require_special: bool,
    max_age_days: u32,
    history_count: u32,

    pub fn default() PasswordPolicy {
        return .{
            .min_length = 8,
            .max_length = 128,
            .require_uppercase = true,
            .require_lowercase = true,
            .require_digit = true,
            .require_special = true,
            .max_age_days = 90,
            .history_count = 5,
        };
    }
};

// Audit logging
pub const AuditLog = struct {
    allocator: Allocator,
    entries: std.ArrayList(AuditEntry),

    pub fn init(allocator: Allocator) !AuditLog {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(AuditEntry).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *AuditLog) void {
        self.entries.deinit(self.allocator);
    }

    pub fn logUserCreated(self: *AuditLog, user_id: UserId, username: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .user_created,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "User created: {s}", .{username}),
        });
    }

    pub fn logSuccessfulLogin(self: *AuditLog, user_id: UserId, username: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .login_success,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "Successful login: {s}", .{username}),
        });
    }

    pub fn logFailedLogin(self: *AuditLog, user_id: UserId, username: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .login_failed,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "Failed login: {s}", .{username}),
        });
    }

    pub fn logRoleAssigned(self: *AuditLog, user_id: UserId, role_id: RoleId) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .role_assigned,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "Role {} assigned to user {}", .{ role_id, user_id }),
        });
    }

    pub fn logRoleRevoked(self: *AuditLog, user_id: UserId, role_id: RoleId) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .role_revoked,
            .user_id = user_id,
            .details = try std.fmt.allocPrint(self.allocator, "Role {} revoked from user {}", .{ role_id, user_id }),
        });
    }

    pub fn logPermissionGranted(self: *AuditLog, role_id: RoleId, permission_id: PermissionId) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .permission_granted,
            .user_id = 0,
            .details = try std.fmt.allocPrint(self.allocator, "Permission {} granted to role {}", .{ permission_id, role_id }),
        });
    }

    pub fn logPolicyCreated(self: *AuditLog, policy_id: PolicyId, name: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .policy_created,
            .user_id = 0,
            .details = try std.fmt.allocPrint(self.allocator, "Policy created: {} - {s}", .{ policy_id, name }),
        });
    }

    pub fn logRowPolicyCreated(self: *AuditLog, policy_id: PolicyId, name: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .row_policy_created,
            .user_id = 0,
            .details = try std.fmt.allocPrint(self.allocator, "Row policy created: {} - {s}", .{ policy_id, name }),
        });
    }
};

pub const AuditEntry = struct {
    timestamp: i64,
    event_type: AuditEventType,
    user_id: UserId,
    details: []const u8,
};

pub const AuditEventType = enum {
    user_created,
    user_updated,
    user_deleted,
    login_success,
    login_failed,
    logout,
    role_assigned,
    role_revoked,
    permission_granted,
    permission_revoked,
    policy_created,
    policy_updated,
    policy_deleted,
    row_policy_created,
    row_policy_updated,
    row_policy_deleted,
    access_granted,
    access_denied,
};
