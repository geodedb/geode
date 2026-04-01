const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_store = @import("geode").graph_store;
const auth_hmac = @import("auth_lib").hmac;

// CANARY: REQ=REQ-GQL-202; FEATURE="UserStorage"; ASPECT=PersistentStorage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_202_UserStorage; OWNER=security; UPDATED=2026-02-24

const logging = @import("logging");
const log = logging.scoped("user_storage");
const Attr = logging.Attr;

const SECURITY_GRAPH_NAME = "__geode_security";
const USER_LABEL = "User";
const ROLE_LABEL = "Role";
const PERMISSION_LABEL = "Permission";
const POLICY_LABEL = "Policy";
const AUTH_CHAIN_ROOT_LABEL = "AuthChainRoot";

fn computeRecordHmacChecked(hmac_key: *const [32]u8, props: []const auth_hmac.KeyValue) [32]u8 {
    return auth_hmac.computeRecordHmac(hmac_key, props) catch unreachable;
}

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

    // AuthChainRoot singleton node ID (null if not yet created)
    chain_root_node: ?u64,

    const Self = @This();

    // Persistent record structures
    pub const UserRecord = extern struct {
        id: u64,
        username: [64]u8,
        username_len: u16,
        email: [128]u8,
        email_len: u16,
        password_hash: [256]u8,
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
        // HMAC chain integrity fields (added for auth storage migration)
        password_changed_at: i64, // timestamp for password expiry policy
        hash_algorithm: [16]u8, // stores "argon2id" or "blake2b"
        hash_algorithm_len: u16,
        is_default_user: bool, // auto-created admin flag
        password_reset_required: bool, // force password change on next login
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

        pub fn getHashAlgorithm(self: *const UserRecord) []const u8 {
            return self.hash_algorithm[0..self.hash_algorithm_len];
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
            .chain_root_node = null,
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
            record.hash_algorithm_len = copyIntoField(&record.hash_algorithm, getStringProp(self.store, node_id, "hash_algorithm", ""));
            record.is_default_user = getBoolProp(self.store, node_id, "is_default_user", false);
            record.password_reset_required = getBoolProp(self.store, node_id, "password_reset_required", false);
            record.password_changed_at = getIntProp(self.store, node_id, "password_changed_at", 0);

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
        if (username.len > 63 or email.len > 127 or password_hash.len > 255 or salt.len > 31) {
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

    // HMAC-aware user persist
    pub fn persistUserWithHmac(self: *Self, user_id: u64, username: []const u8, email: []const u8, password_hash: []const u8, salt: []const u8, hmac_key: *const [32]u8) !void {
        // Persist the user record first (creates/updates node in graph)
        try self.persistUser(user_id, username, email, password_hash, salt);

        // Compute HMAC over all user properties (sorted by key name)
        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{user_id}) catch "0";

        const record = self.user_cache.get(user_id) orelse return error.UserNotFound;

        var created_buf: [20]u8 = undefined;
        const created_str = std.fmt.bufPrint(&created_buf, "{d}", .{record.created_at}) catch "0";
        var updated_buf: [20]u8 = undefined;
        const updated_str = std.fmt.bufPrint(&updated_buf, "{d}", .{record.updated_at}) catch "0";
        var pwd_changed_buf: [20]u8 = undefined;
        const pwd_changed_str = std.fmt.bufPrint(&pwd_changed_buf, "{d}", .{record.password_changed_at}) catch "0";
        var lockout_buf: [20]u8 = undefined;
        const lockout_str = std.fmt.bufPrint(&lockout_buf, "{d}", .{record.lockout_until}) catch "0";
        var last_login_buf: [20]u8 = undefined;
        const last_login_str = std.fmt.bufPrint(&last_login_buf, "{d}", .{record.last_login}) catch "0";
        var failed_buf: [10]u8 = undefined;
        const failed_str = std.fmt.bufPrint(&failed_buf, "{d}", .{record.failed_login_attempts}) catch "0";

        const mfa_secret = record.getMFASecret() orelse "";

        const props = [_]auth_hmac.KeyValue{
            .{ .key = "created_at", .value = created_str },
            .{ .key = "email", .value = email },
            .{ .key = "failed_login_attempts", .value = failed_str },
            .{ .key = "hash_algorithm", .value = record.getHashAlgorithm() },
            .{ .key = "id", .value = id_str },
            .{ .key = "is_active", .value = if (record.is_active) "true" else "false" },
            .{ .key = "is_default_user", .value = if (record.is_default_user) "true" else "false" },
            .{ .key = "is_superuser", .value = if (record.is_superuser) "true" else "false" },
            .{ .key = "last_login", .value = last_login_str },
            .{ .key = "lockout_until", .value = lockout_str },
            .{ .key = "mfa_enabled", .value = if (record.mfa_enabled) "true" else "false" },
            .{ .key = "mfa_secret", .value = mfa_secret },
            .{ .key = "password_changed_at", .value = pwd_changed_str },
            .{ .key = "password_hash", .value = password_hash },
            .{ .key = "password_reset_required", .value = if (record.password_reset_required) "true" else "false" },
            .{ .key = "salt", .value = salt },
            .{ .key = "updated_at", .value = updated_str },
            .{ .key = "username", .value = username },
        };

        const hmac_bytes = computeRecordHmacChecked(hmac_key, &props);
        const hmac_hex = auth_hmac.hmacToHex(&hmac_bytes);

        // Store the HMAC hex string as a node property
        const node_id = self.user_nodes.get(user_id) orelse return error.UserNotFound;
        try self.store.setNodeProperty(node_id, "hmac", .{ .String = &hmac_hex });
    }

    // ChainRootRecord for HMAC chain integrity
    pub const ChainRootRecord = struct {
        chain_hash: [64]u8, // hex string
        chain_hash_len: u16,
        record_count: u64,
        last_verified: i64,
        hmac_key_id: [64]u8,
        hmac_key_id_len: u16,
        node_id: ?u64, // graph store node ID, null if not yet created
    };

    pub fn loadChainRoot(self: *Self) ?ChainRootRecord {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, AUTH_CHAIN_ROOT_LABEL);
        if (nodes_opt == null) return null;
        const nodes = nodes_opt.?;
        if (nodes.len == 0) return null;

        const node_id = nodes[0];
        const node = self.store.getNodePtr(node_id) orelse return null;
        if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) return null;

        self.chain_root_node = node_id;

        var record = ChainRootRecord{
            .chain_hash = [_]u8{0} ** 64,
            .chain_hash_len = 0,
            .record_count = 0,
            .last_verified = 0,
            .hmac_key_id = [_]u8{0} ** 64,
            .hmac_key_id_len = 0,
            .node_id = node_id,
        };

        record.chain_hash_len = copyIntoField(&record.chain_hash, getStringProp(self.store, node_id, "chain_hash", ""));
        const count_val = getIntProp(self.store, node_id, "record_count", 0);
        record.record_count = if (count_val >= 0) @intCast(count_val) else 0;
        record.last_verified = getIntProp(self.store, node_id, "last_verified", 0);
        record.hmac_key_id_len = copyIntoField(&record.hmac_key_id, getStringProp(self.store, node_id, "hmac_key_id", ""));

        // Only return if we actually have a chain hash stored
        if (record.chain_hash_len == 0) return null;

        return record;
    }

    pub fn persistChainRoot(self: *Self, chain_hash_hex: []const u8, record_count: u64, hmac_key_id: []const u8) !void {
        const node_id = self.chain_root_node orelse blk: {
            const new_id = try self.createEntityNode(AUTH_CHAIN_ROOT_LABEL);
            self.chain_root_node = new_id;
            break :blk new_id;
        };

        try self.store.setNodeProperty(node_id, "chain_hash", .{ .String = chain_hash_hex });
        try self.store.setNodeProperty(node_id, "record_count", .{ .Int = safeI64(record_count) });
        try self.store.setNodeProperty(node_id, "last_verified", .{ .Int = std.time.milliTimestamp() });
        try self.store.setNodeProperty(node_id, "hmac_key_id", .{ .String = hmac_key_id });
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

    pub fn blankUserRecord(user_id: u64) UserRecord {
        return UserRecord{
            .id = user_id,
            .username = [_]u8{0} ** 64,
            .username_len = 0,
            .email = [_]u8{0} ** 128,
            .email_len = 0,
            .password_hash = [_]u8{0} ** 256,
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
            .password_changed_at = 0,
            .hash_algorithm = [_]u8{0} ** 16,
            .hash_algorithm_len = 0,
            .is_default_user = false,
            .password_reset_required = false,
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

    pub fn copyIntoField(dest: []u8, src: []const u8) u16 {
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

    pub fn upsertUserNode(self: *Self, record: UserRecord) !void {
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
        if (record.hash_algorithm_len > 0) {
            try self.store.setNodeProperty(node_id, "hash_algorithm", .{ .String = record.getHashAlgorithm() });
        }
        try self.store.setNodeProperty(node_id, "is_default_user", .{ .Bool = record.is_default_user });
        try self.store.setNodeProperty(node_id, "password_reset_required", .{ .Bool = record.password_reset_required });
        try self.store.setNodeProperty(node_id, "password_changed_at", .{ .Int = record.password_changed_at });
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

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "blankUserRecord initializes new HMAC fields correctly" {
    const record = UserStorageBackend.blankUserRecord(42);

    // Verify new fields are initialized to defaults
    try testing.expectEqual(@as(u16, 0), record.hash_algorithm_len);
    try testing.expect(std.mem.eql(u8, record.hash_algorithm[0..16], &([_]u8{0} ** 16)));
    try testing.expectEqual(false, record.is_default_user);
    try testing.expectEqual(false, record.password_reset_required);
    try testing.expectEqual(@as(i64, 0), record.password_changed_at);

    // Verify existing fields still initialized correctly
    try testing.expectEqual(@as(u64, 42), record.id);
    try testing.expectEqual(true, record.is_active);
    try testing.expectEqual(false, record.is_superuser);
    try testing.expectEqual(@as(u32, 0), record.attributes_len);
}

test "blankUserRecord getHashAlgorithm returns empty for default" {
    const record = UserStorageBackend.blankUserRecord(1);
    try testing.expectEqual(@as(usize, 0), record.getHashAlgorithm().len);
}

test "persistUserWithHmac stores hmac property on graph node" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    try backend.persistUserWithHmac(1, "alice", "alice@example.com", "hashed_pw", "salt123", &hmac_key);

    // Verify user was persisted
    const user = backend.getUser(1);
    try testing.expect(user != null);
    try testing.expect(std.mem.eql(u8, user.?.getUsername(), "alice"));

    // Verify the hmac property is stored on the graph node (64 hex chars)
    const node_id = backend.user_nodes.get(1);
    try testing.expect(node_id != null);
    const hmac_prop = store.getNodeProperty(node_id.?, "hmac");
    try testing.expect(hmac_prop != null);
    try testing.expect(hmac_prop.? == .String);
    try testing.expectEqual(@as(usize, 64), hmac_prop.?.String.len);

    // Verify all chars are valid hex
    for (hmac_prop.?.String) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "persistUserWithHmac produces deterministic HMAC" {
    var store1 = try graph_store.GraphStore.init(testing.allocator);
    defer store1.deinit();
    var backend1 = try UserStorageBackend.init(testing.allocator, &store1);
    defer backend1.deinit();

    var store2 = try graph_store.GraphStore.init(testing.allocator);
    defer store2.deinit();
    var backend2 = try UserStorageBackend.init(testing.allocator, &store2);
    defer backend2.deinit();

    const hmac_key = [_]u8{0x42} ** 32;

    try backend1.persistUserWithHmac(1, "bob", "bob@example.com", "pw_hash", "saltsalt", &hmac_key);
    try backend2.persistUserWithHmac(1, "bob", "bob@example.com", "pw_hash", "saltsalt", &hmac_key);

    const node_id1 = backend1.user_nodes.get(1).?;
    const node_id2 = backend2.user_nodes.get(1).?;

    const hmac1 = store1.getNodeProperty(node_id1, "hmac").?.String;
    const hmac2 = store2.getNodeProperty(node_id2, "hmac").?.String;

    try testing.expect(std.mem.eql(u8, hmac1, hmac2));
}

test "loadChainRoot returns null when no chain root exists" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    const root = backend.loadChainRoot();
    try testing.expect(root == null);
}

test "persistChainRoot creates and loadChainRoot retrieves" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    // Persist a chain root
    const chain_hash_hex = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    try backend.persistChainRoot(chain_hash_hex, 5, "key-id-001");

    // Load and verify
    const root = backend.loadChainRoot();
    try testing.expect(root != null);
    const r = root.?;
    try testing.expectEqual(@as(u64, 5), r.record_count);
    try testing.expect(r.node_id != null);
    try testing.expect(r.last_verified > 0);
    try testing.expect(std.mem.eql(u8, r.chain_hash[0..r.chain_hash_len], chain_hash_hex));
    try testing.expect(std.mem.eql(u8, r.hmac_key_id[0..r.hmac_key_id_len], "key-id-001"));
}

test "persistChainRoot updates existing chain root" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    const hash1 = "1111111111111111111111111111111111111111111111111111111111111111";
    const hash2 = "2222222222222222222222222222222222222222222222222222222222222222";

    try backend.persistChainRoot(hash1, 3, "key-v1");
    try backend.persistChainRoot(hash2, 7, "key-v2");

    const root = backend.loadChainRoot();
    try testing.expect(root != null);
    const r = root.?;
    try testing.expectEqual(@as(u64, 7), r.record_count);
    try testing.expect(std.mem.eql(u8, r.chain_hash[0..r.chain_hash_len], hash2));
    try testing.expect(std.mem.eql(u8, r.hmac_key_id[0..r.hmac_key_id_len], "key-v2"));
}

test "new UserRecord fields persist and reload from graph" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    // Create a user and manually set new fields
    try backend.persistUser(10, "admin", "admin@db.local", "argon2hash", "randomsalt");
    var record = backend.getUser(10).?;

    // Set the new HMAC-related fields
    record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
    record.is_default_user = true;
    record.password_reset_required = true;
    record.password_changed_at = 1700000000;

    // Update cache and persist to graph
    try backend.user_cache.put(10, record);
    try backend.upsertUserNode(record);

    // Verify values in the graph node
    const node_id = backend.user_nodes.get(10).?;
    const algo = store.getNodeProperty(node_id, "hash_algorithm");
    try testing.expect(algo != null);
    try testing.expect(std.mem.eql(u8, algo.?.String, "argon2id"));

    const default_user = store.getNodeProperty(node_id, "is_default_user");
    try testing.expect(default_user != null);
    try testing.expect(default_user.?.Bool == true);

    const reset_req = store.getNodeProperty(node_id, "password_reset_required");
    try testing.expect(reset_req != null);
    try testing.expect(reset_req.?.Bool == true);

    const pwd_changed = store.getNodeProperty(node_id, "password_changed_at");
    try testing.expect(pwd_changed != null);
    try testing.expectEqual(@as(i64, 1700000000), pwd_changed.?.Int);
}

// CANARY: REQ=REQ-AUTH-HMAC-002; FEATURE="UserStorageHmac"; ASPECT=Integration; STATUS=TESTED; TEST=test_persistUserWithHmac_stores_hmac; OWNER=security; UPDATED=2026-02-24
