const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_store = @import("../graph_store.zig");

// CANARY: REQ=REQ-GQL-202; FEATURE="UserStorage"; ASPECT=PersistentStorage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_202_UserStorage; OWNER=security; UPDATED=2026-02-04

const logging = @import("logging");
const log = logging.scoped("user_storage");
const Attr = logging.Attr;

const SECURITY_GRAPH_NAME = "__geode_security";
const USER_LABEL = "User";
const ROLE_LABEL = "Role";
const PERMISSION_LABEL = "Permission";
const POLICY_LABEL = "Policy";

pub const UserStorageBackend = struct {
    allocator: Allocator,
    store: *graph_store.GraphStore,

    // In-memory cache for fast lookups
    user_cache: std.AutoHashMap(u64, UserRecord),
    role_cache: std.AutoHashMap(u64, RoleRecord),
    permission_cache: std.AutoHashMap(u64, PermissionRecord),
    policy_cache: std.AutoHashMap(u64, PolicyRecord),

    // Map entity id -> GraphStore node id
    user_nodes: std.AutoHashMap(u64, u64),
    role_nodes: std.AutoHashMap(u64, u64),
    permission_nodes: std.AutoHashMap(u64, u64),
    policy_nodes: std.AutoHashMap(u64, u64),

    const Self = @This();

    // Persistent record structures
    pub const UserRecord = extern struct {
        id: u64,
        username: [64]u8,
        username_len: u16,
        email: [128]u8,
        email_len: u16,
        password_hash: [128]u8,
        password_hash_len: u16,
        salt: [32]u8,
        is_active: bool,
        is_superuser: bool,
        mfa_enabled: bool,
        mfa_secret: [64]u8,
        mfa_secret_len: u16,
        failed_login_attempts: u16,
        lockout_until: i64,
        last_login: i64,
        created_at: i64,
        updated_at: i64,
        // Variable-length attributes section follows (unused in GraphStore backend)
        attributes_len: u32,

        pub fn getUsername(self: *const UserRecord) []const u8 {
            return self.username[0..self.username_len];
        }

        pub fn getEmail(self: *const UserRecord) []const u8 {
            return self.email[0..self.email_len];
        }

        pub fn getPasswordHash(self: *const UserRecord) []const u8 {
            return self.password_hash[0..self.password_hash_len];
        }

        pub fn getMFASecret(self: *const UserRecord) ?[]const u8 {
            if (self.mfa_secret_len == 0) return null;
            return self.mfa_secret[0..self.mfa_secret_len];
        }
    };

    pub const RoleRecord = extern struct {
        id: u64,
        name: [64]u8,
        name_len: u16,
        description: [256]u8,
        description_len: u16,
        parent_role: u64, // 0 = no parent
        priority: u32,
        is_system: bool,
        created_at: i64,
        updated_at: i64,

        pub fn getName(self: *const RoleRecord) []const u8 {
            return self.name[0..self.name_len];
        }

        pub fn getDescription(self: *const RoleRecord) []const u8 {
            return self.description[0..self.description_len];
        }
    };

    pub const PermissionRecord = extern struct {
        id: u64,
        name: [64]u8,
        name_len: u16,
        resource: [128]u8,
        resource_len: u16,
        action: u8, // Encoded Action enum
        conditions: [512]u8,
        conditions_len: u16,
        created_at: i64,

        pub fn getName(self: *const PermissionRecord) []const u8 {
            return self.name[0..self.name_len];
        }

        pub fn getResource(self: *const PermissionRecord) []const u8 {
            return self.resource[0..self.resource_len];
        }

        pub fn getConditions(self: *const PermissionRecord) ?[]const u8 {
            if (self.conditions_len == 0) return null;
            return self.conditions[0..self.conditions_len];
        }
    };

    pub const PolicyRecord = extern struct {
        id: u64,
        name: [64]u8,
        name_len: u16,
        description: [256]u8,
        description_len: u16,
        graph: [64]u8,
        graph_len: u16,
        table: [64]u8,
        table_len: u16,
        operation: u8, // Encoded operation
        permissive: bool,
        enabled: bool,
        using_clause: [512]u8,
        using_clause_len: u16,
        check_clause: [512]u8,
        check_clause_len: u16,
        audit_level: u8,
        created_at: i64,
        updated_at: i64,
        created_by: u64,

        pub fn getName(self: *const PolicyRecord) []const u8 {
            return self.name[0..self.name_len];
        }

        pub fn getDescription(self: *const PolicyRecord) []const u8 {
            return self.description[0..self.description_len];
        }

        pub fn getGraph(self: *const PolicyRecord) []const u8 {
            return self.graph[0..self.graph_len];
        }

        pub fn getTable(self: *const PolicyRecord) []const u8 {
            return self.table[0..self.table_len];
        }

        pub fn getUsingClause(self: *const PolicyRecord) ?[]const u8 {
            if (self.using_clause_len == 0) return null;
            return self.using_clause[0..self.using_clause_len];
        }

        pub fn getCheckClause(self: *const PolicyRecord) ?[]const u8 {
            if (self.check_clause_len == 0) return null;
            return self.check_clause[0..self.check_clause_len];
        }
    };

    pub fn init(allocator: Allocator, store: *graph_store.GraphStore) !Self {
        try ensureSecurityGraph(store);

        var self = Self{
            .allocator = allocator,
            .store = store,
            .user_cache = std.AutoHashMap(u64, UserRecord).init(allocator),
            .role_cache = std.AutoHashMap(u64, RoleRecord).init(allocator),
            .permission_cache = std.AutoHashMap(u64, PermissionRecord).init(allocator),
            .policy_cache = std.AutoHashMap(u64, PolicyRecord).init(allocator),
            .user_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .role_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .permission_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .policy_nodes = std.AutoHashMap(u64, u64).init(allocator),
        };

        try self.loadCache();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.user_cache.deinit();
        self.role_cache.deinit();
        self.permission_cache.deinit();
        self.policy_cache.deinit();
        self.user_nodes.deinit();
        self.role_nodes.deinit();
        self.permission_nodes.deinit();
        self.policy_nodes.deinit();
    }

    fn ensureSecurityGraph(store: *graph_store.GraphStore) !void {
        store.createGraph(SECURITY_GRAPH_NAME) catch |err| switch (err) {
            error.GraphAlreadyExists => {},
            else => return err,
        };
    }

    fn loadCache(self: *Self) !void {
        try self.loadUsersFromGraph();
        try self.loadRolesFromGraph();
        try self.loadPermissionsFromGraph();
        try self.loadPoliciesFromGraph();
    }

    fn loadUsersFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            const node = self.store.getNodePtr(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const id_val = getIntProp(self.store, node_id, "id", -1);
            if (id_val < 0) continue;
            const user_id: u64 = @intCast(id_val);

            var record = blankUserRecord(user_id);
            record.username_len = copyIntoField(&record.username, getStringProp(self.store, node_id, "username", ""));
            record.email_len = copyIntoField(&record.email, getStringProp(self.store, node_id, "email", ""));
            record.password_hash_len = copyIntoField(&record.password_hash, getStringProp(self.store, node_id, "password_hash", ""));
            _ = copyIntoField(&record.salt, getStringProp(self.store, node_id, "salt", ""));
            record.is_active = getBoolProp(self.store, node_id, "is_active", true);
            record.is_superuser = getBoolProp(self.store, node_id, "is_superuser", false);
            record.mfa_enabled = getBoolProp(self.store, node_id, "mfa_enabled", false);
            record.mfa_secret_len = copyIntoField(&record.mfa_secret, getStringProp(self.store, node_id, "mfa_secret", ""));
            record.failed_login_attempts = @intCast(@max(0, getIntProp(self.store, node_id, "failed_login_attempts", 0)));
            record.lockout_until = getIntProp(self.store, node_id, "lockout_until", 0);
            record.last_login = getIntProp(self.store, node_id, "last_login", 0);
            record.created_at = getIntProp(self.store, node_id, "created_at", std.time.milliTimestamp());
            record.updated_at = getIntProp(self.store, node_id, "updated_at", record.created_at);

            try self.user_cache.put(user_id, record);
            try self.user_nodes.put(user_id, node_id);
        }
    }

    fn loadRolesFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, ROLE_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            const node = self.store.getNodePtr(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const id_val = getIntProp(self.store, node_id, "id", -1);
            if (id_val < 0) continue;
            const role_id: u64 = @intCast(id_val);

            var record = blankRoleRecord(role_id);
            record.name_len = copyIntoField(&record.name, getStringProp(self.store, node_id, "name", ""));
            record.description_len = copyIntoField(&record.description, getStringProp(self.store, node_id, "description", ""));
            record.parent_role = @intCast(@max(0, getIntProp(self.store, node_id, "parent_role", 0)));
            record.priority = @intCast(@max(0, getIntProp(self.store, node_id, "priority", 0)));
            record.is_system = getBoolProp(self.store, node_id, "is_system", false);
            record.created_at = getIntProp(self.store, node_id, "created_at", std.time.milliTimestamp());
            record.updated_at = getIntProp(self.store, node_id, "updated_at", record.created_at);

            try self.role_cache.put(role_id, record);
            try self.role_nodes.put(role_id, node_id);
        }
    }

    fn loadPermissionsFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, PERMISSION_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            const node = self.store.getNodePtr(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const id_val = getIntProp(self.store, node_id, "id", -1);
            if (id_val < 0) continue;
            const perm_id: u64 = @intCast(id_val);

            var record = blankPermissionRecord(perm_id);
            record.name_len = copyIntoField(&record.name, getStringProp(self.store, node_id, "name", ""));
            record.resource_len = copyIntoField(&record.resource, getStringProp(self.store, node_id, "resource", ""));
            record.action = @intCast(@max(0, getIntProp(self.store, node_id, "action", 0)));
            record.conditions_len = copyIntoField(&record.conditions, getStringProp(self.store, node_id, "conditions", ""));
            record.created_at = getIntProp(self.store, node_id, "created_at", std.time.milliTimestamp());

            try self.permission_cache.put(perm_id, record);
            try self.permission_nodes.put(perm_id, node_id);
        }
    }

    fn loadPoliciesFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, POLICY_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            const node = self.store.getNodePtr(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const id_val = getIntProp(self.store, node_id, "id", -1);
            if (id_val < 0) continue;
            const policy_id: u64 = @intCast(id_val);

            var record = blankPolicyRecord(policy_id);
            record.name_len = copyIntoField(&record.name, getStringProp(self.store, node_id, "name", ""));
            record.description_len = copyIntoField(&record.description, getStringProp(self.store, node_id, "description", ""));
            record.graph_len = copyIntoField(&record.graph, getStringProp(self.store, node_id, "graph", ""));
            record.table_len = copyIntoField(&record.table, getStringProp(self.store, node_id, "table", ""));
            record.operation = @intCast(@max(0, getIntProp(self.store, node_id, "operation", 0)));
            record.permissive = getBoolProp(self.store, node_id, "permissive", false);
            record.enabled = getBoolProp(self.store, node_id, "enabled", true);
            record.using_clause_len = copyIntoField(&record.using_clause, getStringProp(self.store, node_id, "using_clause", ""));
            record.check_clause_len = copyIntoField(&record.check_clause, getStringProp(self.store, node_id, "check_clause", ""));
            record.audit_level = @intCast(@max(0, getIntProp(self.store, node_id, "audit_level", 0)));
            record.created_at = getIntProp(self.store, node_id, "created_at", std.time.milliTimestamp());
            record.updated_at = getIntProp(self.store, node_id, "updated_at", record.created_at);
            record.created_by = @intCast(@max(0, getIntProp(self.store, node_id, "created_by", 0)));

            try self.policy_cache.put(policy_id, record);
            try self.policy_nodes.put(policy_id, node_id);
        }
    }

    // User operations
    pub fn persistUser(self: *Self, user_id: u64, username: []const u8, email: []const u8, password_hash: []const u8, salt: []const u8) !void {
        if (username.len > 63 or email.len > 127 or password_hash.len > 127 or salt.len > 31) {
            return error.FieldTooLong;
        }

        var record = blankUserRecord(user_id);
        record.username_len = copyIntoField(&record.username, username);
        record.email_len = copyIntoField(&record.email, email);
        record.password_hash_len = copyIntoField(&record.password_hash, password_hash);
        _ = copyIntoField(&record.salt, salt);
        record.created_at = std.time.milliTimestamp();
        record.updated_at = record.created_at;

        try self.user_cache.put(user_id, record);
        try self.upsertUserNode(record);
    }

    pub fn updateUser(self: *Self, user_id: u64, email: ?[]const u8, password_hash: ?[]const u8, is_active: ?bool, mfa_enabled: ?bool, mfa_secret: ?[]const u8) !void {
        var record = self.user_cache.get(user_id) orelse return error.UserNotFound;

        if (email) |e| {
            if (e.len > 127) return error.FieldTooLong;
            record.email_len = copyIntoField(&record.email, e);
        }

        if (password_hash) |ph| {
            if (ph.len > 127) return error.FieldTooLong;
            record.password_hash_len = copyIntoField(&record.password_hash, ph);
        }

        if (is_active) |active| record.is_active = active;
        if (mfa_enabled) |enabled| record.mfa_enabled = enabled;

        if (mfa_secret) |secret| {
            if (secret.len > 63) return error.FieldTooLong;
            record.mfa_secret_len = copyIntoField(&record.mfa_secret, secret);
        }

        record.updated_at = std.time.milliTimestamp();

        try self.user_cache.put(user_id, record);
        try self.upsertUserNode(record);
    }

    pub fn removeUser(self: *Self, user_id: u64) !void {
        _ = self.user_cache.remove(user_id);
        if (self.user_nodes.fetchRemove(user_id)) |kv| {
            self.store.deleteNode(kv.value);
            self.store.saveIfDirty();
        }
    }

    pub fn getUser(self: *Self, user_id: u64) ?UserRecord {
        return self.user_cache.get(user_id);
    }

    pub fn getUserByUsername(self: *Self, username: []const u8) ?UserRecord {
        var it = self.user_cache.valueIterator();
        while (it.next()) |record| {
            if (std.mem.eql(u8, record.getUsername(), username)) {
                return record.*;
            }
        }
        return null;
    }

    // Role operations
    pub fn persistRole(self: *Self, role_id: u64, name: []const u8, description: []const u8, parent_role: u64, priority: u32, is_system: bool) !void {
        if (name.len > 63 or description.len > 255) {
            return error.FieldTooLong;
        }

        var record = blankRoleRecord(role_id);
        record.name_len = copyIntoField(&record.name, name);
        record.description_len = copyIntoField(&record.description, description);
        record.parent_role = parent_role;
        record.priority = priority;
        record.is_system = is_system;
        record.created_at = std.time.milliTimestamp();
        record.updated_at = record.created_at;

        try self.role_cache.put(role_id, record);
        try self.upsertRoleNode(record);
    }

    pub fn removeRole(self: *Self, role_id: u64) !void {
        _ = self.role_cache.remove(role_id);
        if (self.role_nodes.fetchRemove(role_id)) |kv| {
            self.store.deleteNode(kv.value);
            self.store.saveIfDirty();
        }
    }

    pub fn getRole(self: *Self, role_id: u64) ?RoleRecord {
        return self.role_cache.get(role_id);
    }

    pub fn getRoleByName(self: *Self, name: []const u8) ?RoleRecord {
        var it = self.role_cache.valueIterator();
        while (it.next()) |record| {
            if (std.mem.eql(u8, record.getName(), name)) {
                return record.*;
            }
        }
        return null;
    }

    // Permission operations
    pub fn persistPermission(self: *Self, permission_id: u64, name: []const u8, resource: []const u8, action: u8, conditions: ?[]const u8) !void {
        if (name.len > 63 or resource.len > 127) {
            return error.FieldTooLong;
        }

        var record = blankPermissionRecord(permission_id);
        record.name_len = copyIntoField(&record.name, name);
        record.resource_len = copyIntoField(&record.resource, resource);
        record.action = action;
        if (conditions) |cond| {
            if (cond.len > 511) return error.FieldTooLong;
            record.conditions_len = copyIntoField(&record.conditions, cond);
        }
        record.created_at = std.time.milliTimestamp();

        try self.permission_cache.put(permission_id, record);
        try self.upsertPermissionNode(record);
    }

    pub fn removePermission(self: *Self, permission_id: u64) !void {
        _ = self.permission_cache.remove(permission_id);
        if (self.permission_nodes.fetchRemove(permission_id)) |kv| {
            self.store.deleteNode(kv.value);
            self.store.saveIfDirty();
        }
    }

    pub fn getPermission(self: *Self, permission_id: u64) ?PermissionRecord {
        return self.permission_cache.get(permission_id);
    }

    // Policy operations
    pub const PolicyPersistOptions = struct {
        policy_id: u64,
        name: []const u8,
        description: []const u8,
        graph: []const u8,
        table: []const u8,
        operation: u8,
        permissive: bool,
        enabled: bool,
        using_clause: ?[]const u8,
        check_clause: ?[]const u8,
        audit_level: u8,
        created_by: u64,
    };

    pub fn persistPolicy(self: *Self, opts: PolicyPersistOptions) !void {
        if (opts.name.len > 63 or opts.description.len > 255 or opts.graph.len > 63 or opts.table.len > 63) {
            return error.FieldTooLong;
        }

        var record = blankPolicyRecord(opts.policy_id);
        record.name_len = copyIntoField(&record.name, opts.name);
        record.description_len = copyIntoField(&record.description, opts.description);
        record.graph_len = copyIntoField(&record.graph, opts.graph);
        record.table_len = copyIntoField(&record.table, opts.table);
        record.operation = opts.operation;
        record.permissive = opts.permissive;
        record.enabled = opts.enabled;
        if (opts.using_clause) |uc| {
            if (uc.len > 511) return error.FieldTooLong;
            record.using_clause_len = copyIntoField(&record.using_clause, uc);
        }
        if (opts.check_clause) |cc| {
            if (cc.len > 511) return error.FieldTooLong;
            record.check_clause_len = copyIntoField(&record.check_clause, cc);
        }
        record.audit_level = opts.audit_level;
        record.created_at = std.time.milliTimestamp();
        record.updated_at = record.created_at;
        record.created_by = opts.created_by;

        try self.policy_cache.put(opts.policy_id, record);
        try self.upsertPolicyNode(record);
    }

    pub fn removePolicy(self: *Self, policy_id: u64) !void {
        _ = self.policy_cache.remove(policy_id);
        if (self.policy_nodes.fetchRemove(policy_id)) |kv| {
            self.store.deleteNode(kv.value);
            self.store.saveIfDirty();
        }
    }

    pub fn getPolicy(self: *Self, policy_id: u64) ?PolicyRecord {
        return self.policy_cache.get(policy_id);
    }

    pub fn userIterator(self: *Self) std.AutoHashMap(u64, UserRecord).ValueIterator {
        return self.user_cache.valueIterator();
    }

    pub fn roleIterator(self: *Self) std.AutoHashMap(u64, RoleRecord).ValueIterator {
        return self.role_cache.valueIterator();
    }

    pub fn permissionIterator(self: *Self) std.AutoHashMap(u64, PermissionRecord).ValueIterator {
        return self.permission_cache.valueIterator();
    }

    pub fn policyIterator(self: *Self) std.AutoHashMap(u64, PolicyRecord).ValueIterator {
        return self.policy_cache.valueIterator();
    }

    fn blankUserRecord(user_id: u64) UserRecord {
        return UserRecord{
            .id = user_id,
            .username = [_]u8{0} ** 64,
            .username_len = 0,
            .email = [_]u8{0} ** 128,
            .email_len = 0,
            .password_hash = [_]u8{0} ** 128,
            .password_hash_len = 0,
            .salt = [_]u8{0} ** 32,
            .is_active = true,
            .is_superuser = false,
            .mfa_enabled = false,
            .mfa_secret = [_]u8{0} ** 64,
            .mfa_secret_len = 0,
            .failed_login_attempts = 0,
            .lockout_until = 0,
            .last_login = 0,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
            .attributes_len = 0,
        };
    }

    fn blankRoleRecord(role_id: u64) RoleRecord {
        return RoleRecord{
            .id = role_id,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .description = [_]u8{0} ** 256,
            .description_len = 0,
            .parent_role = 0,
            .priority = 0,
            .is_system = false,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
        };
    }

    fn blankPermissionRecord(permission_id: u64) PermissionRecord {
        return PermissionRecord{
            .id = permission_id,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .resource = [_]u8{0} ** 128,
            .resource_len = 0,
            .action = 0,
            .conditions = [_]u8{0} ** 512,
            .conditions_len = 0,
            .created_at = std.time.milliTimestamp(),
        };
    }

    fn blankPolicyRecord(policy_id: u64) PolicyRecord {
        return PolicyRecord{
            .id = policy_id,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .description = [_]u8{0} ** 256,
            .description_len = 0,
            .graph = [_]u8{0} ** 64,
            .graph_len = 0,
            .table = [_]u8{0} ** 64,
            .table_len = 0,
            .operation = 0,
            .permissive = false,
            .enabled = true,
            .using_clause = [_]u8{0} ** 512,
            .using_clause_len = 0,
            .check_clause = [_]u8{0} ** 512,
            .check_clause_len = 0,
            .audit_level = 0,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
            .created_by = 0,
        };
    }

    fn copyIntoField(dest: []u8, src: []const u8) u16 {
        const max_len = dest.len;
        const len = @min(src.len, max_len);
        @memset(dest, 0);
        @memcpy(dest[0..len], src[0..len]);
        if (src.len > max_len) {
            log.warn("User storage field truncated", &.{
                Attr.uint("max", @intCast(max_len)),
                Attr.uint("actual", @intCast(src.len)),
            });
        }
        return @intCast(len);
    }

    fn getStringProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8, default: []const u8) []const u8 {
        if (store.getNodeProperty(node_id, key)) |val| {
            if (val == .String) return val.String;
        }
        return default;
    }

    fn getIntProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8, default: i64) i64 {
        if (store.getNodeProperty(node_id, key)) |val| {
            if (val == .Int) return val.Int;
        }
        return default;
    }

    fn getBoolProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8, default: bool) bool {
        if (store.getNodeProperty(node_id, key)) |val| {
            if (val == .Bool) return val.Bool;
        }
        return default;
    }

    fn upsertUserNode(self: *Self, record: UserRecord) !void {
        const node_id = self.user_nodes.get(record.id) orelse try self.createEntityNode(USER_LABEL);
        try self.user_nodes.put(record.id, node_id);

        try self.store.setNodeProperty(node_id, "id", .{ .Int = safeI64(record.id) });
        try self.store.setNodeProperty(node_id, "username", .{ .String = record.getUsername() });
        try self.store.setNodeProperty(node_id, "email", .{ .String = record.getEmail() });
        try self.store.setNodeProperty(node_id, "password_hash", .{ .String = record.getPasswordHash() });
        if (sliceUntilZero(&record.salt)) |salt_str| {
            try self.store.setNodeProperty(node_id, "salt", .{ .String = salt_str });
        }
        try self.store.setNodeProperty(node_id, "is_active", .{ .Bool = record.is_active });
        try self.store.setNodeProperty(node_id, "is_superuser", .{ .Bool = record.is_superuser });
        try self.store.setNodeProperty(node_id, "mfa_enabled", .{ .Bool = record.mfa_enabled });
        if (record.getMFASecret()) |mfa| {
            try self.store.setNodeProperty(node_id, "mfa_secret", .{ .String = mfa });
        }
        try self.store.setNodeProperty(node_id, "failed_login_attempts", .{ .Int = record.failed_login_attempts });
        try self.store.setNodeProperty(node_id, "lockout_until", .{ .Int = record.lockout_until });
        try self.store.setNodeProperty(node_id, "last_login", .{ .Int = record.last_login });
        try self.store.setNodeProperty(node_id, "created_at", .{ .Int = record.created_at });
        try self.store.setNodeProperty(node_id, "updated_at", .{ .Int = record.updated_at });

        self.store.saveIfDirty();
    }

    fn upsertRoleNode(self: *Self, record: RoleRecord) !void {
        const node_id = self.role_nodes.get(record.id) orelse try self.createEntityNode(ROLE_LABEL);
        try self.role_nodes.put(record.id, node_id);

        try self.store.setNodeProperty(node_id, "id", .{ .Int = safeI64(record.id) });
        try self.store.setNodeProperty(node_id, "name", .{ .String = record.getName() });
        try self.store.setNodeProperty(node_id, "description", .{ .String = record.getDescription() });
        try self.store.setNodeProperty(node_id, "parent_role", .{ .Int = safeI64(record.parent_role) });
        try self.store.setNodeProperty(node_id, "priority", .{ .Int = record.priority });
        try self.store.setNodeProperty(node_id, "is_system", .{ .Bool = record.is_system });
        try self.store.setNodeProperty(node_id, "created_at", .{ .Int = record.created_at });
        try self.store.setNodeProperty(node_id, "updated_at", .{ .Int = record.updated_at });

        self.store.saveIfDirty();
    }

    fn upsertPermissionNode(self: *Self, record: PermissionRecord) !void {
        const node_id = self.permission_nodes.get(record.id) orelse try self.createEntityNode(PERMISSION_LABEL);
        try self.permission_nodes.put(record.id, node_id);

        try self.store.setNodeProperty(node_id, "id", .{ .Int = safeI64(record.id) });
        try self.store.setNodeProperty(node_id, "name", .{ .String = record.getName() });
        try self.store.setNodeProperty(node_id, "resource", .{ .String = record.getResource() });
        try self.store.setNodeProperty(node_id, "action", .{ .Int = record.action });
        if (record.getConditions()) |cond| {
            try self.store.setNodeProperty(node_id, "conditions", .{ .String = cond });
        }
        try self.store.setNodeProperty(node_id, "created_at", .{ .Int = record.created_at });

        self.store.saveIfDirty();
    }

    fn upsertPolicyNode(self: *Self, record: PolicyRecord) !void {
        const node_id = self.policy_nodes.get(record.id) orelse try self.createEntityNode(POLICY_LABEL);
        try self.policy_nodes.put(record.id, node_id);

        try self.store.setNodeProperty(node_id, "id", .{ .Int = safeI64(record.id) });
        try self.store.setNodeProperty(node_id, "name", .{ .String = record.getName() });
        try self.store.setNodeProperty(node_id, "description", .{ .String = record.getDescription() });
        try self.store.setNodeProperty(node_id, "graph", .{ .String = record.getGraph() });
        try self.store.setNodeProperty(node_id, "table", .{ .String = record.getTable() });
        try self.store.setNodeProperty(node_id, "operation", .{ .Int = record.operation });
        try self.store.setNodeProperty(node_id, "permissive", .{ .Bool = record.permissive });
        try self.store.setNodeProperty(node_id, "enabled", .{ .Bool = record.enabled });
        if (record.getUsingClause()) |uc| {
            try self.store.setNodeProperty(node_id, "using_clause", .{ .String = uc });
        }
        if (record.getCheckClause()) |cc| {
            try self.store.setNodeProperty(node_id, "check_clause", .{ .String = cc });
        }
        try self.store.setNodeProperty(node_id, "audit_level", .{ .Int = record.audit_level });
        try self.store.setNodeProperty(node_id, "created_at", .{ .Int = record.created_at });
        try self.store.setNodeProperty(node_id, "updated_at", .{ .Int = record.updated_at });
        try self.store.setNodeProperty(node_id, "created_by", .{ .Int = safeI64(record.created_by) });

        self.store.saveIfDirty();
    }

    fn createEntityNode(self: *Self, label: []const u8) !u64 {
        const labels = [_][]const u8{label};
        return self.store.createNodeWithGraph(@constCast(&labels), SECURITY_GRAPH_NAME);
    }

    fn safeI64(value: u64) i64 {
        const max = std.math.maxInt(i64);
        if (value > @as(u64, @intCast(max))) {
            log.warn("User storage value truncated to i64", &.{Attr.uint("value", value)});
            return max;
        }
        return @intCast(value);
    }

    fn sliceUntilZero(bytes: []const u8) ?[]const u8 {
        var len: usize = 0;
        while (len < bytes.len) : (len += 1) {
            if (bytes[len] == 0) break;
        }
        if (len == 0) return null;
        return bytes[0..len];
    }
};
