const std = @import("std");
const Allocator = std.mem.Allocator;
const interface = @import("interface");
const page_manager = @import("storage_page_manager");

// Persistent storage backend for user management system
// CANARY: REQ=REQ-GQL-202; FEATURE="UserStorage"; ASPECT=PersistentStorage; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_202_UserStorage; OWNER=security; UPDATED=2025-10-04

pub const UserStorageBackend = struct {
    allocator: Allocator,
    page_manager: *page_manager.PageManager,
    users_page_id: ?interface.PageId = null,
    roles_page_id: ?interface.PageId = null,
    permissions_page_id: ?interface.PageId = null,
    policies_page_id: ?interface.PageId = null,

    // In-memory cache for fast lookups
    user_cache: std.AutoHashMap(u64, UserRecord),
    role_cache: std.AutoHashMap(u64, RoleRecord),
    permission_cache: std.AutoHashMap(u64, PermissionRecord),
    policy_cache: std.AutoHashMap(u64, PolicyRecord),

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
        // Variable-length attributes section follows
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

    // Relationship tables (many-to-many)
    pub const UserRoleRecord = extern struct {
        user_id: u64,
        role_id: u64,
        assigned_at: i64,
        assigned_by: u64,
    };

    pub const RolePermissionRecord = extern struct {
        role_id: u64,
        permission_id: u64,
        granted_at: i64,
        granted_by: u64,
    };

    pub const PolicyRoleRecord = extern struct {
        policy_id: u64,
        role_id: u64,
        created_at: i64,
    };

    pub fn init(allocator: Allocator, page_mgr: *page_manager.PageManager) !Self {
        var self = Self{
            .allocator = allocator,
            .page_manager = page_mgr,
            .user_cache = std.AutoHashMap(u64, UserRecord).init(allocator),
            .role_cache = std.AutoHashMap(u64, RoleRecord).init(allocator),
            .permission_cache = std.AutoHashMap(u64, PermissionRecord).init(allocator),
            .policy_cache = std.AutoHashMap(u64, PolicyRecord).init(allocator),
        };

        // Initialize storage pages
        try self.initializeStoragePages();

        // Load existing data into cache
        try self.loadCache();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.user_cache.deinit();
        self.role_cache.deinit();
        self.permission_cache.deinit();
        self.policy_cache.deinit();
    }

    fn initializeStoragePages(self: *Self) !void {
        // Try to find existing pages by scanning metadata
        // For now, allocate new pages if they don't exist

        if (self.users_page_id == null) {
            self.users_page_id = @intCast(try self.page_manager.allocatePage());
        }

        if (self.roles_page_id == null) {
            self.roles_page_id = @intCast(try self.page_manager.allocatePage());
        }

        if (self.permissions_page_id == null) {
            self.permissions_page_id = @intCast(try self.page_manager.allocatePage());
        }

        if (self.policies_page_id == null) {
            self.policies_page_id = @intCast(try self.page_manager.allocatePage());
        }
    }

    fn loadCache(self: *Self) !void {
        // Load users from storage
        if (self.users_page_id) |page_id| {
            try self.loadUsersFromPage(page_id);
        }

        // Load roles from storage
        if (self.roles_page_id) |page_id| {
            try self.loadRolesFromPage(page_id);
        }

        // Load permissions from storage
        if (self.permissions_page_id) |page_id| {
            try self.loadPermissionsFromPage(page_id);
        }

        // Load policies from storage
        if (self.policies_page_id) |page_id| {
            try self.loadPoliciesFromPage(page_id);
        }
    }

    fn loadUsersFromPage(self: *Self, page_id: interface.PageId) !void {
        const page_data = try self.page_manager.getPage(@intCast(page_id));
        var offset: usize = 0;

        // Read record count
        if (page_data.len < 8) return;
        const record_count = std.mem.readInt(u64, page_data[0..8], .little);
        offset += 8;

        var i: u64 = 0;
        while (i < record_count and offset + @sizeOf(UserRecord) <= page_data.len) {
            const record_bytes = page_data[offset .. offset + @sizeOf(UserRecord)];
            const record: UserRecord = @bitCast(record_bytes[0..@sizeOf(UserRecord)].*);

            try self.user_cache.put(record.id, record);
            offset += @sizeOf(UserRecord);

            // Skip variable-length attributes for now
            if (offset + record.attributes_len <= page_data.len) {
                offset += record.attributes_len;
            }

            i += 1;
        }
    }

    fn loadRolesFromPage(self: *Self, page_id: interface.PageId) !void {
        const page_data = try self.page_manager.getPage(@intCast(page_id));
        var offset: usize = 0;

        if (page_data.len < 8) return;
        const record_count = std.mem.readInt(u64, page_data[0..8], .little);
        offset += 8;

        var i: u64 = 0;
        while (i < record_count and offset + @sizeOf(RoleRecord) <= page_data.len) {
            const record_bytes = page_data[offset .. offset + @sizeOf(RoleRecord)];
            const record: RoleRecord = @bitCast(record_bytes[0..@sizeOf(RoleRecord)].*);

            try self.role_cache.put(record.id, record);
            offset += @sizeOf(RoleRecord);
            i += 1;
        }
    }

    fn loadPermissionsFromPage(self: *Self, page_id: interface.PageId) !void {
        const page_data = try self.page_manager.getPage(@intCast(page_id));
        var offset: usize = 0;

        if (page_data.len < 8) return;
        const record_count = std.mem.readInt(u64, page_data[0..8], .little);
        offset += 8;

        var i: u64 = 0;
        while (i < record_count and offset + @sizeOf(PermissionRecord) <= page_data.len) {
            const record_bytes = page_data[offset .. offset + @sizeOf(PermissionRecord)];
            const record: PermissionRecord = @bitCast(record_bytes[0..@sizeOf(PermissionRecord)].*);

            try self.permission_cache.put(record.id, record);
            offset += @sizeOf(PermissionRecord);
            i += 1;
        }
    }

    fn loadPoliciesFromPage(self: *Self, page_id: interface.PageId) !void {
        const page_data = try self.page_manager.getPage(@intCast(page_id));
        var offset: usize = 0;

        if (page_data.len < 8) return;
        const record_count = std.mem.readInt(u64, page_data[0..8], .little);
        offset += 8;

        var i: u64 = 0;
        while (i < record_count and offset + @sizeOf(PolicyRecord) <= page_data.len) {
            const record_bytes = page_data[offset .. offset + @sizeOf(PolicyRecord)];
            const record: PolicyRecord = @bitCast(record_bytes[0..@sizeOf(PolicyRecord)].*);

            try self.policy_cache.put(record.id, record);
            offset += @sizeOf(PolicyRecord);
            i += 1;
        }
    }

    // User operations
    pub fn persistUser(self: *Self, user_id: u64, username: []const u8, email: []const u8, password_hash: []const u8, salt: []const u8) !void {
        if (username.len > 63 or email.len > 127 or password_hash.len > 127 or salt.len > 31) {
            return error.FieldTooLong;
        }

        var record = UserRecord{
            .id = user_id,
            .username = [_]u8{0} ** 64,
            .username_len = @intCast(username.len),
            .email = [_]u8{0} ** 128,
            .email_len = @intCast(email.len),
            .password_hash = [_]u8{0} ** 128,
            .password_hash_len = @intCast(password_hash.len),
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

        @memcpy(record.username[0..username.len], username);
        @memcpy(record.email[0..email.len], email);
        @memcpy(record.password_hash[0..password_hash.len], password_hash);
        @memcpy(record.salt[0..salt.len], salt);

        try self.user_cache.put(user_id, record);
        try self.flushUsersToStorage();
    }

    pub fn updateUser(self: *Self, user_id: u64, email: ?[]const u8, password_hash: ?[]const u8, is_active: ?bool, mfa_enabled: ?bool, mfa_secret: ?[]const u8) !void {
        var record = self.user_cache.get(user_id) orelse return error.UserNotFound;

        if (email) |e| {
            if (e.len > 127) return error.FieldTooLong;
            @memset(record.email[0..], 0);
            @memcpy(record.email[0..e.len], e);
            record.email_len = @intCast(e.len);
        }

        if (password_hash) |ph| {
            if (ph.len > 127) return error.FieldTooLong;
            @memset(record.password_hash[0..], 0);
            @memcpy(record.password_hash[0..ph.len], ph);
            record.password_hash_len = @intCast(ph.len);
        }

        if (is_active) |active| {
            record.is_active = active;
        }

        if (mfa_enabled) |enabled| {
            record.mfa_enabled = enabled;
        }

        if (mfa_secret) |secret| {
            if (secret.len > 63) return error.FieldTooLong;
            @memset(record.mfa_secret[0..], 0);
            @memcpy(record.mfa_secret[0..secret.len], secret);
            record.mfa_secret_len = @intCast(secret.len);
        }

        record.updated_at = std.time.milliTimestamp();

        try self.user_cache.put(user_id, record);
        try self.flushUsersToStorage();
    }

    pub fn removeUser(self: *Self, user_id: u64) !void {
        _ = self.user_cache.remove(user_id);
        try self.flushUsersToStorage();
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

        var record = RoleRecord{
            .id = role_id,
            .name = [_]u8{0} ** 64,
            .name_len = @intCast(name.len),
            .description = [_]u8{0} ** 256,
            .description_len = @intCast(description.len),
            .parent_role = parent_role,
            .priority = priority,
            .is_system = is_system,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
        };

        @memcpy(record.name[0..name.len], name);
        @memcpy(record.description[0..description.len], description);

        try self.role_cache.put(role_id, record);
        try self.flushRolesToStorage();
    }

    pub fn removeRole(self: *Self, role_id: u64) !void {
        _ = self.role_cache.remove(role_id);
        try self.flushRolesToStorage();
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

        var record = PermissionRecord{
            .id = permission_id,
            .name = [_]u8{0} ** 64,
            .name_len = @intCast(name.len),
            .resource = [_]u8{0} ** 128,
            .resource_len = @intCast(resource.len),
            .action = action,
            .conditions = [_]u8{0} ** 512,
            .conditions_len = 0,
            .created_at = std.time.milliTimestamp(),
        };

        @memcpy(record.name[0..name.len], name);
        @memcpy(record.resource[0..resource.len], resource);

        if (conditions) |cond| {
            if (cond.len > 511) return error.FieldTooLong;
            @memcpy(record.conditions[0..cond.len], cond);
            record.conditions_len = @intCast(cond.len);
        }

        try self.permission_cache.put(permission_id, record);
        try self.flushPermissionsToStorage();
    }

    pub fn removePermission(self: *Self, permission_id: u64) !void {
        _ = self.permission_cache.remove(permission_id);
        try self.flushPermissionsToStorage();
    }

    pub fn getPermission(self: *Self, permission_id: u64) ?PermissionRecord {
        return self.permission_cache.get(permission_id);
    }

    // Policy operations
    pub fn persistPolicy(self: *Self, policy_id: u64, name: []const u8, description: []const u8, graph: []const u8, table: []const u8, operation: u8, permissive: bool, enabled: bool, using_clause: ?[]const u8, check_clause: ?[]const u8, audit_level: u8, created_by: u64) !void {
        if (name.len > 63 or description.len > 255 or graph.len > 63 or table.len > 63) {
            return error.FieldTooLong;
        }

        var record = PolicyRecord{
            .id = policy_id,
            .name = [_]u8{0} ** 64,
            .name_len = @intCast(name.len),
            .description = [_]u8{0} ** 256,
            .description_len = @intCast(description.len),
            .graph = [_]u8{0} ** 64,
            .graph_len = @intCast(graph.len),
            .table = [_]u8{0} ** 64,
            .table_len = @intCast(table.len),
            .operation = operation,
            .permissive = permissive,
            .enabled = enabled,
            .using_clause = [_]u8{0} ** 512,
            .using_clause_len = 0,
            .check_clause = [_]u8{0} ** 512,
            .check_clause_len = 0,
            .audit_level = audit_level,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
            .created_by = created_by,
        };

        @memcpy(record.name[0..name.len], name);
        @memcpy(record.description[0..description.len], description);
        @memcpy(record.graph[0..graph.len], graph);
        @memcpy(record.table[0..table.len], table);

        if (using_clause) |clause| {
            if (clause.len > 511) return error.FieldTooLong;
            @memcpy(record.using_clause[0..clause.len], clause);
            record.using_clause_len = @intCast(clause.len);
        }

        if (check_clause) |clause| {
            if (clause.len > 511) return error.FieldTooLong;
            @memcpy(record.check_clause[0..clause.len], clause);
            record.check_clause_len = @intCast(clause.len);
        }

        try self.policy_cache.put(policy_id, record);
        try self.flushPoliciesToStorage();
    }

    pub fn removePolicy(self: *Self, policy_id: u64) !void {
        _ = self.policy_cache.remove(policy_id);
        try self.flushPoliciesToStorage();
    }

    pub fn getPolicy(self: *Self, policy_id: u64) ?PolicyRecord {
        return self.policy_cache.get(policy_id);
    }

    // Storage flush operations
    fn flushUsersToStorage(self: *Self) !void {
        const page_id = self.users_page_id orelse return error.NoStoragePage;

        // Calculate required size
        var total_size: usize = 8; // record count
        var it = self.user_cache.valueIterator();
        while (it.next()) |record| {
            total_size += @sizeOf(UserRecord) + record.attributes_len;
        }

        // Allocate buffer
        const buffer = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buffer);

        // Write record count
        std.mem.writeInt(u64, buffer[0..8], @intCast(self.user_cache.count()), .little);
        var offset: usize = 8;

        // Write records
        it = self.user_cache.valueIterator();
        while (it.next()) |record| {
            const record_bytes: [@sizeOf(UserRecord)]u8 = @bitCast(record.*);
            @memcpy(buffer[offset .. offset + @sizeOf(UserRecord)], &record_bytes);
            offset += @sizeOf(UserRecord);

            // Skip attributes for now (would write them here)
            // offset += record.attributes_len;
        }

        try self.page_manager.flushPage(@intCast(page_id));
    }

    fn flushRolesToStorage(self: *Self) !void {
        const page_id = self.roles_page_id orelse return error.NoStoragePage;

        const total_size = 8 + (self.role_cache.count() * @sizeOf(RoleRecord));
        const buffer = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buffer);

        std.mem.writeInt(u64, buffer[0..8], @intCast(self.role_cache.count()), .little);
        var offset: usize = 8;

        var it = self.role_cache.valueIterator();
        while (it.next()) |record| {
            const record_bytes: [@sizeOf(RoleRecord)]u8 = @bitCast(record.*);
            @memcpy(buffer[offset .. offset + @sizeOf(RoleRecord)], &record_bytes);
            offset += @sizeOf(RoleRecord);
        }

        try self.page_manager.flushPage(@intCast(page_id));
    }

    fn flushPermissionsToStorage(self: *Self) !void {
        const page_id = self.permissions_page_id orelse return error.NoStoragePage;

        const total_size = 8 + (self.permission_cache.count() * @sizeOf(PermissionRecord));
        const buffer = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buffer);

        std.mem.writeInt(u64, buffer[0..8], @intCast(self.permission_cache.count()), .little);
        var offset: usize = 8;

        var it = self.permission_cache.valueIterator();
        while (it.next()) |record| {
            const record_bytes: [@sizeOf(PermissionRecord)]u8 = @bitCast(record.*);
            @memcpy(buffer[offset .. offset + @sizeOf(PermissionRecord)], &record_bytes);
            offset += @sizeOf(PermissionRecord);
        }

        try self.page_manager.flushPage(@intCast(page_id));
    }

    fn flushPoliciesToStorage(self: *Self) !void {
        const page_id = self.policies_page_id orelse return error.NoStoragePage;

        const total_size = 8 + (self.policy_cache.count() * @sizeOf(PolicyRecord));
        const buffer = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buffer);

        std.mem.writeInt(u64, buffer[0..8], @intCast(self.policy_cache.count()), .little);
        var offset: usize = 8;

        var it = self.policy_cache.valueIterator();
        while (it.next()) |record| {
            const record_bytes: [@sizeOf(PolicyRecord)]u8 = @bitCast(record.*);
            @memcpy(buffer[offset .. offset + @sizeOf(PolicyRecord)], &record_bytes);
            offset += @sizeOf(PolicyRecord);
        }

        try self.page_manager.flushPage(@intCast(page_id));
    }

    // Iterator for listing records
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
};
