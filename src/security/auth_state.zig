const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-AUTH-STATE-DEFAULTS-001; FEATURE="Production Password Guard"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/gap_153_154_password_security.yml; OWNER=security; UPDATED=2026-01-14
// GAP-0153 FIX: Production builds must not use hardcoded default passwords

/// Check if running in production build mode
const is_production_build = builtin.mode == .ReleaseSafe or builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

/// Lightweight persistent auth state used by CLI workflows and e2e tests.
/// Stores users/roles/policies/grants in a simple line-oriented file so state
/// survives between CLI invocations without requiring the full storage layer.
pub const STATE_PATH = "/tmp/geode_auth_state.db";

pub const User = struct {
    username: []u8,
    email: []u8,
    password: []u8,
    role: []u8,
    active: bool = true,
    mfa_enabled: bool = false,
};

pub const Role = struct {
    name: []u8,
    description: []u8,
    permissions: std.ArrayList([]u8),
};

pub const Policy = struct {
    name: []u8,
    table: []u8,
    condition: []u8,
};

pub const Grant = struct {
    target: []u8,
    permission: []u8,
    resource: []u8,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    users: std.ArrayList(User),
    roles: std.ArrayList(Role),
    policies: std.ArrayList(Policy),
    grants: std.ArrayList(Grant),

    // GAP-0220 FIX: Return error union for proper error propagation
    pub fn init(allocator: std.mem.Allocator) !State {
        return .{
            .allocator = allocator,
            .users = try std.ArrayList(User).initCapacity(allocator, 0),
            .roles = try std.ArrayList(Role).initCapacity(allocator, 0),
            .policies = try std.ArrayList(Policy).initCapacity(allocator, 0),
            .grants = try std.ArrayList(Grant).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *State) void {
        for (self.users.items) |*u| {
            self.allocator.free(u.username);
            self.allocator.free(u.email);
            self.allocator.free(u.password);
            self.allocator.free(u.role);
        }
        for (self.roles.items) |*r| {
            self.allocator.free(r.name);
            self.allocator.free(r.description);
            for (r.permissions.items) |p| self.allocator.free(p);
            r.permissions.deinit(self.allocator);
        }
        for (self.policies.items) |*p| {
            self.allocator.free(p.name);
            self.allocator.free(p.table);
            self.allocator.free(p.condition);
        }
        for (self.grants.items) |*g| {
            self.allocator.free(g.target);
            self.allocator.free(g.permission);
            self.allocator.free(g.resource);
        }

        self.users.deinit(self.allocator);
        self.roles.deinit(self.allocator);
        self.policies.deinit(self.allocator);
        self.grants.deinit(self.allocator);
    }

    pub fn load(allocator: std.mem.Allocator) !State {
        var state = try State.init(allocator);

        const file = std.fs.openFileAbsolute(STATE_PATH, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try state.ensureDefaults();
                try state.save();
                return state;
            },
            else => return err,
        };
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(contents);

        if (contents.len == 0) {
            try state.ensureDefaults();
            try state.save();
            return state;
        }

        var lines = std.mem.tokenizeScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '|');
            const kind = parts.next() orelse continue;

            if (std.mem.eql(u8, kind, "U")) {
                const username = parts.next() orelse continue;
                const email = parts.next() orelse continue;
                const password = parts.next() orelse continue;
                const role = parts.next() orelse "user";
                const active_str = parts.next() orelse "1";
                const mfa_str = parts.next() orelse "0";
                const active = std.mem.eql(u8, active_str, "1") or std.mem.eql(u8, active_str, "true");
                const mfa_enabled = std.mem.eql(u8, mfa_str, "1") or std.mem.eql(u8, mfa_str, "true");
                _ = try state.upsertUser(username, email, password, role, active, mfa_enabled);
            } else if (std.mem.eql(u8, kind, "R")) {
                const name = parts.next() orelse continue;
                const desc = parts.next() orelse "";
                const perms_str = parts.next() orelse "";
                // GAP-0220 FIX: Use try for proper error propagation
                var perm_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                defer perm_list.deinit(allocator);
                var perm_split = std.mem.splitScalar(u8, perms_str, ',');
                while (perm_split.next()) |p| {
                    if (p.len == 0) continue;
                    try perm_list.append(allocator, p);
                }
                _ = try state.upsertRole(name, desc, perm_list.items);
            } else if (std.mem.eql(u8, kind, "P")) {
                const name = parts.next() orelse continue;
                const table = parts.next() orelse "";
                const cond = parts.next() orelse "";
                try state.upsertPolicy(name, table, cond);
            } else if (std.mem.eql(u8, kind, "G")) {
                const target = parts.next() orelse continue;
                const perm = parts.next() orelse continue;
                const resource = parts.next() orelse "";
                _ = try state.grantPermission(target, perm, resource);
            }
        }

        try state.ensureDefaults();
        return state;
    }

    pub fn save(self: *State) !void {
        const file = try std.fs.createFileAbsolute(STATE_PATH, .{ .truncate = true, .read = true });
        defer file.close();
        var buf: [512]u8 = undefined;

        for (self.users.items) |u| {
            const line = try std.fmt.bufPrint(&buf, "U|{s}|{s}|{s}|{s}|{d}|{d}\n", .{ u.username, u.email, u.password, u.role, @intFromBool(u.active), @intFromBool(u.mfa_enabled) });
            try file.writeAll(line);
        }
        for (self.roles.items) |r| {
            // GAP-0220 FIX: Use try for proper error propagation
            var joined = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            defer joined.deinit(self.allocator);
            for (r.permissions.items, 0..) |p, idx| {
                if (idx > 0) try joined.append(self.allocator, ',');
                try joined.appendSlice(self.allocator, p);
            }
            const line = try std.fmt.bufPrint(&buf, "R|{s}|{s}|{s}\n", .{ r.name, r.description, joined.items });
            try file.writeAll(line);
        }
        for (self.policies.items) |p| {
            const line = try std.fmt.bufPrint(&buf, "P|{s}|{s}|{s}\n", .{ p.name, p.table, p.condition });
            try file.writeAll(line);
        }
        for (self.grants.items) |g| {
            const line = try std.fmt.bufPrint(&buf, "G|{s}|{s}|{s}\n", .{ g.target, g.permission, g.resource });
            try file.writeAll(line);
        }
    }

    pub fn ensureDefaults(self: *State) !void {
        // Default roles
        if (self.findRoleIndex("admin") == null) _ = try self.upsertRole("admin", "Administrator role", &[_][]const u8{ "admin", "read", "write", "query" });
        if (self.findRoleIndex("user") == null) _ = try self.upsertRole("user", "Standard user", &[_][]const u8{"read"});
        if (self.findRoleIndex("analyst") == null) _ = try self.upsertRole("analyst", "Analytics role", &[_][]const u8{ "read", "query" });

        // GAP-0153 FIX: Production guard for default passwords
        // In production builds, require env vars or generate random passwords
        const admin_pw_owned = std.process.getEnvVarOwned(self.allocator, "GEODE_ADMIN_PASSWORD") catch null;
        defer if (admin_pw_owned) |buf| self.allocator.free(buf);

        const test_pw_owned = std.process.getEnvVarOwned(self.allocator, "GEODE_USER_PASSWORD") catch null;
        defer if (test_pw_owned) |buf| self.allocator.free(buf);

        // Determine admin password with production safety
        var generated_admin_pw: [16]u8 = undefined;
        var generated_admin_pw_hex: [32]u8 = undefined;
        const admin_password: []const u8 = blk: {
            if (admin_pw_owned) |pw| {
                break :blk pw;
            }
            if (is_production_build) {
                // Generate cryptographically secure random password in production
                std.crypto.random.bytes(&generated_admin_pw);
                generated_admin_pw_hex = std.fmt.bytesToHex(generated_admin_pw, .lower);
                std.log.warn("SECURITY: Generated random admin password. Set GEODE_ADMIN_PASSWORD env var for persistent password.", .{});
                std.log.info("ADMIN_PASSWORD={s}", .{generated_admin_pw_hex});
                break :blk &generated_admin_pw_hex;
            }
            // Debug builds: use simple default for testing convenience
            break :blk "admin";
        };

        // Determine test user password with production safety
        var generated_test_pw: [16]u8 = undefined;
        var generated_test_pw_hex: [32]u8 = undefined;
        const test_password: []const u8 = blk: {
            if (test_pw_owned) |pw| {
                break :blk pw;
            }
            if (is_production_build) {
                // Generate cryptographically secure random password in production
                std.crypto.random.bytes(&generated_test_pw);
                generated_test_pw_hex = std.fmt.bytesToHex(generated_test_pw, .lower);
                std.log.warn("SECURITY: Generated random testuser password. Set GEODE_USER_PASSWORD env var for persistent password.", .{});
                std.log.info("TESTUSER_PASSWORD={s}", .{generated_test_pw_hex});
                break :blk &generated_test_pw_hex;
            }
            // Debug builds: use simple default for testing convenience
            break :blk "testpass";
        };

        if (self.findUserIndex("admin") == null) {
            _ = try self.upsertUser("admin", "admin@geode.dev", admin_password, "admin", true, false);
        }
        if (self.findUserIndex("testuser") == null) {
            _ = try self.upsertUser("testuser", "test@geode.dev", test_password, "user", true, false);
        }
    }

    pub fn upsertUser(self: *State, username: []const u8, email: []const u8, password: []const u8, role: []const u8, active: bool, mfa_enabled: bool) !*User {
        if (self.findUserIndex(username)) |idx| {
            var existing = &self.users.items[idx];
            self.allocator.free(existing.username);
            self.allocator.free(existing.email);
            self.allocator.free(existing.password);
            self.allocator.free(existing.role);
            existing.username = try self.allocator.dupe(u8, username);
            existing.email = try self.allocator.dupe(u8, email);
            existing.password = try self.allocator.dupe(u8, password);
            existing.role = try self.allocator.dupe(u8, role);
            existing.active = active;
            existing.mfa_enabled = mfa_enabled;
            return existing;
        }

        try self.users.append(self.allocator, User{
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password = try self.allocator.dupe(u8, password),
            .role = try self.allocator.dupe(u8, role),
            .active = active,
            .mfa_enabled = mfa_enabled,
        });
        return &self.users.items[self.users.items.len - 1];
    }

    pub fn deleteUser(self: *State, username: []const u8) bool {
        if (self.findUserIndex(username)) |idx| {
            const u = self.users.swapRemove(idx);
            self.allocator.free(u.username);
            self.allocator.free(u.email);
            self.allocator.free(u.password);
            self.allocator.free(u.role);
            return true;
        }
        return false;
    }

    pub fn assignRole(self: *State, username: []const u8, role: []const u8) !bool {
        if (self.findUserIndex(username)) |idx| {
            var u = &self.users.items[idx];
            self.allocator.free(u.role);
            u.role = try self.allocator.dupe(u8, role);
            return true;
        }
        return false;
    }

    pub fn setUserActive(self: *State, username: []const u8, active: bool) bool {
        if (self.findUserIndex(username)) |idx| {
            self.users.items[idx].active = active;
            return true;
        }
        return false;
    }

    pub fn upsertRole(self: *State, name: []const u8, description: []const u8, permissions: []const []const u8) !*Role {
        if (self.findRoleIndex(name)) |idx| {
            var existing = &self.roles.items[idx];
            self.allocator.free(existing.name);
            self.allocator.free(existing.description);
            for (existing.permissions.items) |p| self.allocator.free(p);
            existing.permissions.clearRetainingCapacity();
            existing.name = try self.allocator.dupe(u8, name);
            existing.description = try self.allocator.dupe(u8, description);
            for (permissions) |p| {
                try existing.permissions.append(self.allocator, try self.allocator.dupe(u8, p));
            }
            return existing;
        }

        // GAP-0220 FIX: Use try for proper error propagation
        var role = Role{
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, description),
            .permissions = try std.ArrayList([]u8).initCapacity(self.allocator, 0),
        };
        for (permissions) |p| {
            try role.permissions.append(self.allocator, try self.allocator.dupe(u8, p));
        }
        try self.roles.append(self.allocator, role);
        return &self.roles.items[self.roles.items.len - 1];
    }

    pub fn upsertPolicy(self: *State, name: []const u8, table: []const u8, condition: []const u8) !void {
        if (self.findPolicyIndex(name)) |idx| {
            var p = &self.policies.items[idx];
            self.allocator.free(p.name);
            self.allocator.free(p.table);
            self.allocator.free(p.condition);
            p.name = try self.allocator.dupe(u8, name);
            p.table = try self.allocator.dupe(u8, table);
            p.condition = try self.allocator.dupe(u8, condition);
            return;
        }
        try self.policies.append(self.allocator, Policy{
            .name = try self.allocator.dupe(u8, name),
            .table = try self.allocator.dupe(u8, table),
            .condition = try self.allocator.dupe(u8, condition),
        });
    }

    pub fn deletePolicy(self: *State, name: []const u8) bool {
        if (self.findPolicyIndex(name)) |idx| {
            const p = self.policies.swapRemove(idx);
            self.allocator.free(p.name);
            self.allocator.free(p.table);
            self.allocator.free(p.condition);
            return true;
        }
        return false;
    }

    pub fn grantPermission(self: *State, target: []const u8, permission: []const u8, resource: []const u8) !bool {
        for (self.grants.items) |g| {
            if (std.mem.eql(u8, g.target, target) and std.mem.eql(u8, g.permission, permission) and std.mem.eql(u8, g.resource, resource)) {
                return false;
            }
        }
        try self.grants.append(self.allocator, Grant{
            .target = try self.allocator.dupe(u8, target),
            .permission = try self.allocator.dupe(u8, permission),
            .resource = try self.allocator.dupe(u8, resource),
        });
        return true;
    }

    pub fn revokePermission(self: *State, target: []const u8, permission: []const u8, resource: []const u8) bool {
        var idx: usize = 0;
        while (idx < self.grants.items.len) {
            const g = self.grants.items[idx];
            if (std.mem.eql(u8, g.target, target) and std.mem.eql(u8, g.permission, permission) and std.mem.eql(u8, g.resource, resource)) {
                const removed = self.grants.swapRemove(idx);
                self.allocator.free(removed.target);
                self.allocator.free(removed.permission);
                self.allocator.free(removed.resource);
                return true;
            }
            idx += 1;
        }
        return false;
    }

    pub fn listPermissionsForUser(self: *State, username: []const u8) std.ArrayList([]const u8) {
        var perms = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;

        const user_role = blk: {
            if (self.findUserIndex(username)) |idx| {
                break :blk self.users.items[idx].role;
            }
            break :blk "user";
        };

        if (self.findRoleIndex(user_role)) |idx| {
            for (self.roles.items[idx].permissions.items) |p| {
                _ = perms.append(self.allocator, p) catch {};
            }
        }

        for (self.grants.items) |g| {
            if (std.mem.eql(u8, g.target, username)) {
                _ = perms.append(self.allocator, g.permission) catch {};
            }
        }

        return perms;
    }

    pub fn getUser(self: *State, username: []const u8) ?*User {
        if (self.findUserIndex(username)) |idx| return &self.users.items[idx];
        return null;
    }

    pub fn getPolicy(self: *State, name: []const u8) ?*Policy {
        if (self.findPolicyIndex(name)) |idx| return &self.policies.items[idx];
        return null;
    }

    pub fn validateCredentials(self: *State, username: []const u8, password: []const u8) bool {
        if (self.findUserIndex(username)) |idx| {
            const u = self.users.items[idx];
            if (!u.active) return false;
            return std.mem.eql(u8, u.password, password);
        }
        return false;
    }

    pub fn setPassword(self: *State, username: []const u8, new_password: []const u8) !bool {
        if (self.findUserIndex(username)) |idx| {
            var u = &self.users.items[idx];
            self.allocator.free(u.password);
            u.password = try self.allocator.dupe(u8, new_password);
            return true;
        }
        return false;
    }

    pub fn getRole(self: *State, name: []const u8) ?*Role {
        if (self.findRoleIndex(name)) |idx| return &self.roles.items[idx];
        return null;
    }

    pub fn deleteRole(self: *State, name: []const u8) bool {
        if (self.findRoleIndex(name)) |idx| {
            var r = self.roles.swapRemove(idx);
            self.allocator.free(r.name);
            self.allocator.free(r.description);
            for (r.permissions.items) |p| self.allocator.free(p);
            r.permissions.deinit(self.allocator);
            return true;
        }
        return false;
    }

    fn findUserIndex(self: *State, username: []const u8) ?usize {
        for (self.users.items, 0..) |u, idx| {
            if (std.ascii.eqlIgnoreCase(u.username, username)) return idx;
        }
        return null;
    }

    fn findRoleIndex(self: *State, name: []const u8) ?usize {
        for (self.roles.items, 0..) |r, idx| {
            if (std.ascii.eqlIgnoreCase(r.name, name)) return idx;
        }
        return null;
    }

    fn findPolicyIndex(self: *State, name: []const u8) ?usize {
        for (self.policies.items, 0..) |p, idx| {
            if (std.ascii.eqlIgnoreCase(p.name, name)) return idx;
        }
        return null;
    }
};

pub fn isPasswordStrong(password: []const u8) bool {
    if (password.len < 8) return false;
    var has_digit = false;
    var has_alpha = false;
    for (password) |c| {
        if (std.ascii.isDigit(c)) has_digit = true;
        if (std.ascii.isAlphabetic(c)) has_alpha = true;
    }
    return has_digit and has_alpha;
}

// ============================================================================
// Unit Tests for GAP-0153: Production Password Guard
// ============================================================================

test "GAP-0153: isPasswordStrong validates password requirements" {
    // Too short
    try std.testing.expect(!isPasswordStrong("abc123"));
    try std.testing.expect(!isPasswordStrong("abcdefg"));

    // Missing digits
    try std.testing.expect(!isPasswordStrong("abcdefgh"));

    // Missing letters
    try std.testing.expect(!isPasswordStrong("12345678"));

    // Valid passwords
    try std.testing.expect(isPasswordStrong("password1"));
    try std.testing.expect(isPasswordStrong("abc12345"));
    try std.testing.expect(isPasswordStrong("SecureP4ss!"));
}

test "GAP-0153: State.init creates empty state" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.users.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.roles.items.len);
}

test "GAP-0153: upsertUser creates new user" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    _ = try state.upsertUser("testadmin", "test@example.com", "securepass123", "admin", true, false);

    try std.testing.expectEqual(@as(usize, 1), state.users.items.len);
    try std.testing.expectEqualStrings("testadmin", state.users.items[0].username);
}

test "GAP-0153: upsertUser updates existing user" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    _ = try state.upsertUser("testadmin", "test@example.com", "pass1", "admin", true, false);
    _ = try state.upsertUser("testadmin", "new@example.com", "pass2", "user", false, true);

    try std.testing.expectEqual(@as(usize, 1), state.users.items.len);
    try std.testing.expectEqualStrings("new@example.com", state.users.items[0].email);
    try std.testing.expectEqualStrings("pass2", state.users.items[0].password);
    try std.testing.expect(!state.users.items[0].active);
    try std.testing.expect(state.users.items[0].mfa_enabled);
}

test "GAP-0153: validateCredentials checks password" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    _ = try state.upsertUser("testuser", "test@example.com", "correctpass", "user", true, false);

    try std.testing.expect(state.validateCredentials("testuser", "correctpass"));
    try std.testing.expect(!state.validateCredentials("testuser", "wrongpass"));
    try std.testing.expect(!state.validateCredentials("nouser", "anypass"));
}

test "GAP-0153: validateCredentials rejects inactive users" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    _ = try state.upsertUser("inactiveuser", "test@example.com", "password", "user", false, false);

    // Even correct password should fail for inactive user
    try std.testing.expect(!state.validateCredentials("inactiveuser", "password"));
}

test "GAP-0153: production guard constant is correctly set" {
    // In debug test builds, is_production_build should be false
    // This test verifies the constant is accessible and makes sense
    if (builtin.mode == .Debug) {
        try std.testing.expect(!is_production_build);
    } else {
        // In release builds, this should be true
        try std.testing.expect(is_production_build);
    }
}
