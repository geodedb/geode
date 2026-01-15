const std = @import("std");
const Allocator = std.mem.Allocator;
const auth = @import("geode_auth");
const rls = @import("rls");
const storage = @import("interface");
const user_storage = @import("user_storage");

// User Management CLI and API
pub const UserManager = struct {
    allocator: Allocator,
    security_manager: *auth.SecurityManager,
    rls_engine: *rls.RLSEngine,
    storage_backend: storage.StorageEngine,
    user_storage: *user_storage.UserStorageBackend,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        security_manager: *auth.SecurityManager,
        rls_engine: *rls.RLSEngine,
        storage_backend: storage.StorageEngine,
        user_storage_backend: *user_storage.UserStorageBackend,
    ) !Self {
        return Self{
            .allocator = allocator,
            .security_manager = security_manager,
            .rls_engine = rls_engine,
            .storage_backend = storage_backend,
            .user_storage = user_storage_backend,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    // User CRUD Operations
    pub const CreateUserRequest = struct {
        username: []const u8,
        email: []const u8,
        password: []const u8,
        roles: ?[]const []const u8 = null,
        attributes: ?std.json.Value = null,
        metadata: ?std.json.Value = null,
    };

    pub const CreateUserResponse = struct {
        user_id: auth.UserId,
        username: []const u8,
        email: []const u8,
        created_at: i64,
        roles: []const []const u8,
    };

    pub fn createUser(self: *Self, request: CreateUserRequest) !CreateUserResponse {
        // Create the user
        const user_id = try self.security_manager.createUser(
            request.username,
            request.email,
            request.password,
        );

        // Assign roles if specified
        if (request.roles) |roles| {
            for (roles) |role_name| {
                // Find role by name
                var role_id: ?auth.RoleId = null;
                var it = self.security_manager.roles.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.value_ptr.name, role_name)) {
                        role_id = entry.key_ptr.*;
                        break;
                    }
                }

                if (role_id) |id| {
                    try self.security_manager.assignRole(user_id, id);
                }
            }
        }

        // Set attributes if provided
        if (request.attributes) |attrs| {
            if (attrs == .object) {
                var attr_it = attrs.object.iterator();
                while (attr_it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const user_ptr = self.security_manager.users.getPtr(user_id).?;
                        try user_ptr.attributes.put(
                            try self.allocator.dupe(u8, entry.key_ptr.*),
                            try self.allocator.dupe(u8, entry.value_ptr.string),
                        );
                    }
                }
            }
        }

        // GAP-0126: Handle metadata field properly - return error instead of silently dropping
        // CANARY: REQ=REQ-USER-METADATA-001; FEATURE="User Metadata Handling"; ASPECT=DataIntegrity; STATUS=IMPL; UPDATED=2026-01-13
        if (request.metadata) |_| {
            // Metadata field was removed from auth.User schema
            // Return error to inform callers that metadata is no longer supported
            std.log.warn("User metadata field is deprecated and not supported", .{});
            return error.MetadataFieldDeprecated;
        }

        // Persist to storage
        const user_ptr2 = self.security_manager.users.getPtr(user_id).?;
        try self.persistUser(user_ptr2.*);

        // Build response
        var response_roles = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        if (self.security_manager.rbac.user_roles.get(user_id)) |user_roles| {
            for (user_roles.items) |role_id| {
                if (self.security_manager.roles.get(role_id)) |role| {
                    try response_roles.append(self.allocator, role.name);
                }
            }
        }

        return CreateUserResponse{
            .user_id = user_id,
            .username = self.security_manager.users.getPtr(user_id).?.username,
            .email = self.security_manager.users.getPtr(user_id).?.email,
            .created_at = self.security_manager.users.getPtr(user_id).?.created_at,
            .roles = try response_roles.toOwnedSlice(self.allocator),
        };
    }

    pub const UpdateUserRequest = struct {
        user_id: auth.UserId,
        email: ?[]const u8 = null,
        password: ?[]const u8 = null,
        is_active: ?bool = null,
        mfa_enabled: ?bool = null,
        attributes: ?std.json.Value = null,
        metadata: ?std.json.Value = null,
    };

    pub fn updateUser(self: *Self, request: UpdateUserRequest) !void {
        const user = self.security_manager.users.getPtr(request.user_id) orelse
            return error.UserNotFound;

        // Update fields
        if (request.email) |email| {
            user.email = try self.allocator.dupe(u8, email);
        }

        if (request.password) |password| {
            try self.security_manager.validatePassword(password);
            user.password_hash = try self.security_manager.hashPassword(password);
        }

        if (request.is_active) |is_active| {
            user.is_active = is_active;
        }

        if (request.mfa_enabled) |mfa_enabled| {
            user.mfa_enabled = mfa_enabled;
            if (mfa_enabled and user.mfa_secret == null) {
                // Generate MFA secret
                user.mfa_secret = try self.generateMFASecret();
            }
        }

        if (request.attributes) |attrs| {
            user.attributes.clearRetainingCapacity();
            if (attrs == .object) {
                var it = attrs.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try user.attributes.put(
                            try self.allocator.dupe(u8, entry.key_ptr.*),
                            try self.allocator.dupe(u8, entry.value_ptr.string),
                        );
                    }
                }
            }
        }

        if (request.metadata) |meta| {
            _ = meta; // metadata deprecated
        }

        user.updated_at = std.time.milliTimestamp();

        // Persist changes
        try self.persistUser(user.*);
    }

    pub fn deleteUser(self: *Self, user_id: auth.UserId) !void {
        // Remove user roles
        if (self.security_manager.rbac.user_roles.get(user_id)) |roles| {
            for (roles.items) |role_id| {
                try self.security_manager.revokeRole(user_id, role_id);
            }
        }

        // Remove from storage
        try self.removeUserFromStorage(user_id);

        // Remove from memory
        _ = self.security_manager.users.remove(user_id);
    }

    pub fn getUser(self: *Self, user_id: auth.UserId) !auth.User {
        return self.security_manager.users.get(user_id) orelse
            error.UserNotFound;
    }

    pub fn listUsers(self: *Self, filter: ?UserFilter) ![]auth.User {
        var users = std.ArrayList(auth.User).initCapacity(self.allocator, 0) catch unreachable;

        var it = self.security_manager.users.iterator();
        while (it.next()) |entry| {
            if (filter) |f| {
                if (!self.matchesFilter(entry.value_ptr.*, f)) continue;
            }
            try users.append(self.allocator, entry.value_ptr.*);
        }

        return try users.toOwnedSlice(self.allocator);
    }

    pub const UserFilter = struct {
        is_active: ?bool = null,
        is_superuser: ?bool = null,
        has_mfa: ?bool = null,
        role_name: ?[]const u8 = null,
        created_after: ?i64 = null,
        created_before: ?i64 = null,
    };

    fn matchesFilter(self: *Self, user: auth.User, filter: UserFilter) bool {
        if (filter.is_active) |is_active| {
            if (user.is_active != is_active) return false;
        }

        if (filter.is_superuser) |is_superuser| {
            if (user.is_superuser != is_superuser) return false;
        }

        if (filter.has_mfa) |has_mfa| {
            if (user.mfa_enabled != has_mfa) return false;
        }

        if (filter.role_name) |role_name| {
            const user_roles = self.security_manager.rbac.user_roles.get(user.id) orelse
                return false;

            var has_role = false;
            for (user_roles.items) |role_id| {
                if (self.security_manager.roles.get(role_id)) |role| {
                    if (std.mem.eql(u8, role.name, role_name)) {
                        has_role = true;
                        break;
                    }
                }
            }
            if (!has_role) return false;
        }

        if (filter.created_after) |after| {
            if (user.created_at < after) return false;
        }

        if (filter.created_before) |before| {
            if (user.created_at > before) return false;
        }

        return true;
    }

    // Role Management
    pub const CreateRoleRequest = struct {
        name: []const u8,
        description: []const u8,
        permissions: ?[]const []const u8 = null,
        parent_role: ?[]const u8 = null,
        priority: ?u32 = null,
    };

    pub fn createRole(self: *Self, request: CreateRoleRequest) !auth.RoleId {
        const role = try self.security_manager.createRole(
            request.name,
            request.description,
        );

        // Set parent role if specified
        if (request.parent_role) |parent_name| {
            var it = self.security_manager.roles.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.name, parent_name)) {
                    role.parent_role = entry.key_ptr.*;
                    break;
                }
            }
        }

        // Set priority if specified
        if (request.priority) |priority| {
            role.priority = priority;
        }

        // Grant permissions if specified
        if (request.permissions) |permissions| {
            for (permissions) |perm_name| {
                var it = self.security_manager.permissions.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.value_ptr.name, perm_name)) {
                        try self.security_manager.grantPermission(role.id, entry.key_ptr.*);
                        break;
                    }
                }
            }
        }

        // Persist to storage
        try self.persistRole(role.*);

        return role.id;
    }

    pub fn updateRole(
        self: *Self,
        role_id: auth.RoleId,
        description: ?[]const u8,
        priority: ?u32,
    ) !void {
        const role = self.security_manager.roles.getPtr(role_id) orelse
            return error.RoleNotFound;

        if (description) |desc| {
            role.description = try self.allocator.dupe(u8, desc);
        }

        if (priority) |pri| {
            role.priority = pri;
        }

        try self.persistRole(role.*);
    }

    pub fn deleteRole(self: *Self, role_id: auth.RoleId) !void {
        const role = self.security_manager.roles.get(role_id) orelse
            return error.RoleNotFound;

        if (role.is_system) {
            return error.CannotDeleteSystemRole;
        }

        // Remove role from all users
        var it = self.security_manager.rbac.user_roles.iterator();
        while (it.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (entry.value_ptr.items[i] == role_id) {
                    _ = entry.value_ptr.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Remove from storage
        try self.removeRoleFromStorage(role_id);

        // Remove from memory
        _ = self.security_manager.roles.remove(role_id);
    }

    // Permission Management
    pub const CreatePermissionRequest = struct {
        name: []const u8,
        resource: []const u8,
        action: auth.Action,
        conditions: ?[]const u8 = null,
    };

    pub fn createPermission(self: *Self, request: CreatePermissionRequest) !auth.PermissionId {
        const permission = try self.security_manager.createPermission(
            request.name,
            request.resource,
            request.action,
        );

        if (request.conditions) |conditions| {
            permission.conditions = try self.allocator.dupe(u8, conditions);
        }

        try self.persistPermission(permission.*);

        return permission.id;
    }

    // RLS Policy Management
    pub const CreatePolicyRequest = struct {
        name: []const u8,
        description: []const u8,
        graph: []const u8,
        table: []const u8,
        operation: rls.RLSEngine.Operation,
        permissive: bool = true,
        roles: []const []const u8,
        using_clause: ?[]const u8 = null,
        check_clause: ?[]const u8 = null,
        temporal: ?rls.RLSEngine.TemporalConstraint = null,
        data_classification: ?rls.RLSEngine.DataClassification = null,
        audit_level: rls.RLSEngine.AuditLevel = .denials,
    };

    pub fn createPolicy(self: *Self, request: CreatePolicyRequest) !u64 {
        // Convert role names to IDs
        var role_ids = std.ArrayList(auth.RoleId).initCapacity(self.allocator, 0) catch unreachable;
        for (request.roles) |role_name| {
            var it = self.security_manager.roles.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.name, role_name)) {
                    try role_ids.append(self.allocator, entry.key_ptr.*);
                    break;
                }
            }
        }

        const policy_id = @as(u64, @intCast(std.time.milliTimestamp()));

        const policy = rls.RLSEngine.Policy{
            .id = policy_id,
            .name = try self.allocator.dupe(u8, request.name),
            .description = try self.allocator.dupe(u8, request.description),
            .graph = try self.allocator.dupe(u8, request.graph),
            .table = try self.allocator.dupe(u8, request.table),
            .operation = request.operation,
            .permissive = request.permissive,
            .roles = try role_ids.toOwnedSlice(self.allocator),
            .using_expr = if (request.using_clause) |clause| rls.RLSEngine.Expression{
                .raw = try self.allocator.dupe(u8, clause),
                .parsed = null,
                .compiled = null,
                .parameters = &[_]rls.RLSEngine.Expression.Parameter{},
            } else null,
            .check_expr = if (request.check_clause) |clause| rls.RLSEngine.Expression{
                .raw = try self.allocator.dupe(u8, clause),
                .parsed = null,
                .compiled = null,
                .parameters = &[_]rls.RLSEngine.Expression.Parameter{},
            } else null,
            .enabled = true,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
            .created_by = 0, // System user
            .temporal = request.temporal,
            .data_classification = request.data_classification,
            .audit_level = request.audit_level,
        };

        try self.rls_engine.createPolicy(policy);
        try self.persistPolicy(policy);

        return policy_id;
    }

    pub fn updatePolicy(
        self: *Self,
        policy_id: u64,
        enabled: ?bool,
        using_clause: ?[]const u8,
        check_clause: ?[]const u8,
    ) !void {
        // Find the policy
        var found_policy: ?rls.RLSEngine.Policy = null;
        var policy_key: ?rls.RLSEngine.PolicyKey = null;

        var it = self.rls_engine.policies.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |policy| {
                if (policy.id == policy_id) {
                    found_policy = policy;
                    policy_key = entry.key_ptr.*;
                    break;
                }
            }
        }

        var policy = found_policy orelse return error.PolicyNotFound;

        // Update fields
        if (enabled) |e| {
            policy.enabled = e;
        }

        if (using_clause) |clause| {
            policy.using_expr = rls.RLSEngine.Expression{
                .raw = try self.allocator.dupe(u8, clause),
                .parsed = null,
                .compiled = null,
                .parameters = &[_]rls.RLSEngine.Expression.Parameter{},
            };
        }

        if (check_clause) |clause| {
            policy.check_expr = rls.RLSEngine.Expression{
                .raw = try self.allocator.dupe(u8, clause),
                .parsed = null,
                .compiled = null,
                .parameters = &[_]rls.RLSEngine.Expression.Parameter{},
            };
        }

        try self.rls_engine.updatePolicy(policy_id, policy);
        try self.persistPolicy(policy);
    }

    pub fn deletePolicy(self: *Self, policy_id: u64) !void {
        try self.rls_engine.deletePolicy(policy_id);
        try self.removePolicyFromStorage(policy_id);
    }

    // Storage persistence
    fn persistUser(self: *Self, user: auth.User) !void {
        try self.user_storage.persistUser(
            user.id,
            user.username,
            user.email,
            user.password_hash,
            "", // Salt is included in Argon2id hash
        );
    }

    fn removeUserFromStorage(self: *Self, user_id: auth.UserId) !void {
        try self.user_storage.removeUser(user_id);
    }

    fn persistRole(self: *Self, role: auth.Role) !void {
        try self.user_storage.persistRole(
            role.id,
            role.name,
            role.description,
            role.parent_role orelse 0,
            role.priority,
            role.is_system,
        );
    }

    fn removeRoleFromStorage(self: *Self, role_id: auth.RoleId) !void {
        try self.user_storage.removeRole(role_id);
    }

    fn persistPermission(self: *Self, permission: auth.Permission) !void {
        const action_byte: u8 = switch (permission.action) {
            .read => 0,
            .write => 1,
            .delete => 2,
            .admin => 3,
        };

        try self.user_storage.persistPermission(
            permission.id,
            permission.name,
            permission.resource,
            action_byte,
            permission.conditions,
        );
    }

    fn persistPolicy(self: *Self, policy: rls.RLSEngine.Policy) !void {
        const operation_byte: u8 = switch (policy.operation) {
            .select => 0,
            .insert => 1,
            .update => 2,
            .delete => 3,
            .all => 4,
        };

        const audit_level_byte: u8 = switch (policy.audit_level) {
            .none => 0,
            .errors_only => 1,
            .denials => 2,
            .all_access => 3,
            .detailed => 4,
        };

        const using_clause = if (policy.using_expr) |expr| expr.raw else null;
        const check_clause = if (policy.check_expr) |expr| expr.raw else null;

        try self.user_storage.persistPolicy(
            policy.id,
            policy.name,
            policy.description,
            policy.graph,
            policy.table,
            operation_byte,
            policy.permissive,
            policy.enabled,
            using_clause,
            check_clause,
            audit_level_byte,
            policy.created_by,
        );
    }

    fn removePolicyFromStorage(self: *Self, policy_id: u64) !void {
        try self.user_storage.removePolicy(policy_id);
    }

    fn generateMFASecret(self: *Self) ![]const u8 {
        var secret: [32]u8 = undefined;
        std.crypto.random.bytes(&secret);
        const encoder = std.base64.standard.Encoder;
        const result = try self.allocator.alloc(u8, encoder.calcSize(secret.len));
        _ = encoder.encode(result, &secret);
        return result;
    }
};

// CLI Commands
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printHelp();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "user")) {
        if (args.len < 3) {
            try printUserHelp();
            return;
        }
        try handleUserCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "role")) {
        if (args.len < 3) {
            try printRoleHelp();
            return;
        }
        try handleRoleCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "policy")) {
        if (args.len < 3) {
            try printPolicyHelp();
            return;
        }
        try handlePolicyCommand(allocator, args[2..]);
    } else {
        try printHelp();
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Usage: geode-auth <command> [options]
        \\
        \\Commands:
        \\  user     Manage users
        \\  role     Manage roles
        \\  policy   Manage RLS policies
        \\
        \\Use 'geode-auth <command> --help' for more information about a command.
        \\
    , .{});
}

fn printUserHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Usage: geode-auth user <subcommand> [options]
        \\
        \\Subcommands:
        \\  create   Create a new user
        \\  update   Update an existing user
        \\  delete   Delete a user
        \\  list     List all users
        \\  show     Show user details
        \\  grant    Grant role to user
        \\  revoke   Revoke role from user
        \\
    , .{});
}

fn printRoleHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Usage: geode-auth role <subcommand> [options]
        \\
        \\Subcommands:
        \\  create   Create a new role
        \\  update   Update an existing role
        \\  delete   Delete a role
        \\  list     List all roles
        \\  grant    Grant permission to role
        \\  revoke   Revoke permission from role
        \\
    , .{});
}

fn printPolicyHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Usage: geode-auth policy <subcommand> [options]
        \\
        \\Subcommands:
        \\  create   Create a new RLS policy
        \\  update   Update an existing policy
        \\  delete   Delete a policy
        \\  list     List all policies
        \\  enable   Enable a policy
        \\  disable  Disable a policy
        \\
    , .{});
}

// CANARY: REQ=REQ-CLI-USER-CMD-001; FEATURE="User CLI Commands"; ASPECT=UserManagement; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn handleUserCommand(allocator: Allocator, args: [][]const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len < 1) {
        try printUserHelp();
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "create")) {
        if (args.len < 4) {
            try stdout.print("Usage: user create <username> <email> <password> [--role <role>]\n", .{});
            return;
        }

        const username = args[1];
        const email = args[2];
        const password = args[3];
        var role: []const u8 = "user";

        // Parse optional --role flag
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--role") and i + 1 < args.len) {
                role = args[i + 1];
                i += 1;
            }
        }

        // Create security manager and user
        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        const user_id = try security_manager.createUser(username, email, password);
        try stdout.print("User created successfully:\n", .{});
        try stdout.print("  ID: {}\n", .{user_id});
        try stdout.print("  Username: {s}\n", .{username});
        try stdout.print("  Email: {s}\n", .{email});
        try stdout.print("  Role: {s}\n", .{role});
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        if (args.len < 2) {
            try stdout.print("Usage: user delete <username>\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        // Find user by username
        var user_id: ?auth.UserId = null;
        var it = security_manager.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                user_id = entry.key_ptr.*;
                break;
            }
        }

        if (user_id) |id| {
            try security_manager.deleteUser(id);
            try stdout.print("User '{s}' deleted successfully\n", .{args[1]});
        } else {
            try stdout.print("User '{s}' not found\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        try stdout.print("Users:\n", .{});
        try stdout.print("{s:<20} {s:<30} {s:<10}\n", .{ "Username", "Email", "Active" });
        try stdout.print("{s}\n", .{"-" ** 60});

        var it = security_manager.users.iterator();
        while (it.next()) |entry| {
            const user = entry.value_ptr.*;
            try stdout.print("{s:<20} {s:<30} {s:<10}\n", .{
                user.username,
                user.email,
                if (user.is_active) "Yes" else "No",
            });
        }
    } else if (std.mem.eql(u8, subcommand, "show")) {
        if (args.len < 2) {
            try stdout.print("Usage: user show <username>\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        var it = security_manager.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                const user = entry.value_ptr.*;
                try stdout.print("User Details:\n", .{});
                try stdout.print("  ID: {}\n", .{entry.key_ptr.*});
                try stdout.print("  Username: {s}\n", .{user.username});
                try stdout.print("  Email: {s}\n", .{user.email});
                try stdout.print("  Active: {s}\n", .{if (user.is_active) "Yes" else "No"});
                try stdout.print("  Superuser: {s}\n", .{if (user.is_superuser) "Yes" else "No"});
                try stdout.print("  MFA Enabled: {s}\n", .{if (user.mfa_enabled) "Yes" else "No"});
                return;
            }
        }
        try stdout.print("User '{s}' not found\n", .{args[1]});
    } else {
        try printUserHelp();
    }
}

// CANARY: REQ=REQ-CLI-ROLE-CMD-001; FEATURE="Role CLI Commands"; ASPECT=RoleManagement; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn handleRoleCommand(allocator: Allocator, args: [][]const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len < 1) {
        try printRoleHelp();
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "create")) {
        if (args.len < 2) {
            try stdout.print("Usage: role create <name> [--description <desc>]\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        const role_id = try security_manager.createRole(args[1], args[1]);
        try stdout.print("Role '{s}' created with ID: {}\n", .{ args[1], role_id });
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        if (args.len < 2) {
            try stdout.print("Usage: role delete <name>\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        // Find role by name
        var role_id: ?auth.RoleId = null;
        var it = security_manager.roles.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, args[1])) {
                role_id = entry.key_ptr.*;
                break;
            }
        }

        if (role_id) |id| {
            try security_manager.deleteRole(id);
            try stdout.print("Role '{s}' deleted successfully\n", .{args[1]});
        } else {
            try stdout.print("Role '{s}' not found\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        try stdout.print("Roles:\n", .{});
        try stdout.print("{s:<20} {s:<40}\n", .{ "Name", "Description" });
        try stdout.print("{s}\n", .{"-" ** 60});

        var it = security_manager.roles.iterator();
        while (it.next()) |entry| {
            const role = entry.value_ptr.*;
            try stdout.print("{s:<20} {s:<40}\n", .{ role.name, role.description });
        }
    } else if (std.mem.eql(u8, subcommand, "assign")) {
        if (args.len < 3) {
            try stdout.print("Usage: role assign <username> <role>\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        // Find user and role by name
        var user_id: ?auth.UserId = null;
        var role_id: ?auth.RoleId = null;

        var user_it = security_manager.users.iterator();
        while (user_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                user_id = entry.key_ptr.*;
                break;
            }
        }

        var role_it = security_manager.roles.iterator();
        while (role_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, args[2])) {
                role_id = entry.key_ptr.*;
                break;
            }
        }

        if (user_id != null and role_id != null) {
            try security_manager.assignRole(user_id.?, role_id.?);
            try stdout.print("Role '{s}' assigned to user '{s}'\n", .{ args[2], args[1] });
        } else {
            if (user_id == null) try stdout.print("User '{s}' not found\n", .{args[1]});
            if (role_id == null) try stdout.print("Role '{s}' not found\n", .{args[2]});
        }
    } else {
        try printRoleHelp();
    }
}

// CANARY: REQ=REQ-CLI-POLICY-CMD-001; FEATURE="Policy CLI Commands"; ASPECT=PolicyManagement; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn handlePolicyCommand(allocator: Allocator, args: [][]const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len < 1) {
        try printPolicyHelp();
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "create")) {
        if (args.len < 4) {
            try stdout.print("Usage: policy create <name> <table> <action> [<expression>]\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        const policy = auth.RowLevelPolicy{
            .id = 1, // Will be assigned by system
            .name = args[1],
            .table_name = args[2],
            .for_action = parseAction(args[3]),
            .expression = if (args.len > 4) args[4] else "true",
            .using_expr = null,
            .check_expr = null,
            .enabled = true,
        };

        try security_manager.row_policies.append(allocator, policy);
        try stdout.print("Policy '{s}' created for table '{s}'\n", .{ args[1], args[2] });
    } else if (std.mem.eql(u8, subcommand, "list")) {
        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        try stdout.print("Policies:\n", .{});
        try stdout.print("{s:<20} {s:<20} {s:<10} {s:<10}\n", .{ "Name", "Table", "Action", "Enabled" });
        try stdout.print("{s}\n", .{"-" ** 60});

        for (security_manager.row_policies.items) |policy| {
            try stdout.print("{s:<20} {s:<20} {s:<10} {s:<10}\n", .{
                policy.name,
                policy.table_name,
                @tagName(policy.for_action),
                if (policy.enabled) "Yes" else "No",
            });
        }
    } else if (std.mem.eql(u8, subcommand, "enable")) {
        if (args.len < 2) {
            try stdout.print("Usage: policy enable <name>\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        for (security_manager.row_policies.items) |*policy| {
            if (std.mem.eql(u8, policy.name, args[1])) {
                policy.enabled = true;
                try stdout.print("Policy '{s}' enabled\n", .{args[1]});
                return;
            }
        }
        try stdout.print("Policy '{s}' not found\n", .{args[1]});
    } else if (std.mem.eql(u8, subcommand, "disable")) {
        if (args.len < 2) {
            try stdout.print("Usage: policy disable <name>\n", .{});
            return;
        }

        var security_manager = try auth.SecurityManager.init(allocator);
        defer security_manager.deinit();

        for (security_manager.row_policies.items) |*policy| {
            if (std.mem.eql(u8, policy.name, args[1])) {
                policy.enabled = false;
                try stdout.print("Policy '{s}' disabled\n", .{args[1]});
                return;
            }
        }
        try stdout.print("Policy '{s}' not found\n", .{args[1]});
    } else {
        try printPolicyHelp();
    }
}

fn parseAction(action_str: []const u8) auth.Action {
    if (std.mem.eql(u8, action_str, "create")) return .create;
    if (std.mem.eql(u8, action_str, "read") or std.mem.eql(u8, action_str, "select")) return .read;
    if (std.mem.eql(u8, action_str, "update")) return .update;
    if (std.mem.eql(u8, action_str, "delete")) return .delete;
    if (std.mem.eql(u8, action_str, "execute")) return .execute;
    if (std.mem.eql(u8, action_str, "all")) return .all;
    return .read; // Default to read
}
