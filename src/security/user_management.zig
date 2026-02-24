const std = @import("std");
const geode_auth = @import("geode_auth");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-AUTH-001; FEATURE="UserManagement"; ASPECT=Authentication; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
// User management system with Argon2id password hashing and role-based access control

pub const Role = enum {
    Admin, // Full access: read, write, schema changes
    User, // Limited access: read only
    ReadWrite, // Read and write access
    ReadOnly, // Explicit read-only access

    pub fn fromString(s: []const u8) ?Role {
        if (std.ascii.eqlIgnoreCase(s, "admin")) return .Admin;
        if (std.ascii.eqlIgnoreCase(s, "user")) return .User;
        if (std.ascii.eqlIgnoreCase(s, "readwrite")) return .ReadWrite;
        if (std.ascii.eqlIgnoreCase(s, "readonly")) return .ReadOnly;
        return null;
    }

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .Admin => "admin",
            .User => "user",
            .ReadWrite => "readwrite",
            .ReadOnly => "readonly",
        };
    }
};

pub const Permission = enum {
    Read,
    Write,
    Schema,

    pub fn fromRole(role: Role) []const Permission {
        return switch (role) {
            .Admin => &[_]Permission{ .Read, .Write, .Schema },
            .ReadWrite => &[_]Permission{ .Read, .Write },
            .User, .ReadOnly => &[_]Permission{.Read},
        };
    }
};

pub const User = struct {
    username: []const u8,
    password_hash: []const u8, // Argon2id PHC format: $argon2id$v=19$m=19456,t=2,p=1$<salt_hex>$<hash_hex>
    email: []const u8,
    role: Role,
    created_at: i64,
    last_login: ?i64,
    active: bool,
    password_reset_required: bool = false,

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password_hash);
        allocator.free(self.email);
    }
};

pub const AuthResult = struct {
    role: Role,
    password_reset_required: bool,
};

/// Global user store - in-memory for now
var user_store_mutex = std.Thread.Mutex{};
var user_store: ?std.StringHashMap(User) = null;
var auth_enabled: bool = false;

pub fn initUserStore(allocator: std.mem.Allocator) !void {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store == null) {
        user_store = std.StringHashMap(User).init(allocator);
    }
}

pub fn setAuthEnabled(enabled: bool) void {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();
    auth_enabled = enabled;
}

pub fn isAuthEnabled() bool {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();
    return auth_enabled;
}

pub fn deinitUserStore() void {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store) |*store| {
        var iter = store.iterator();
        while (iter.next()) |entry| {
            var user = entry.value_ptr.*;
            user.deinit(store.allocator);
        }
        store.deinit();
        user_store = null;
    }
}

/// Hash password using the canonical Argon2id implementation with OWASP parameters.
/// Returns a heap-allocated PHC format string that must be freed by the caller.
/// Delegates to geode_auth.hashPasswordArgon2id (single source of truth).
// CANARY: REQ=REQ-AUTH-SALT-001; FEATURE="SecurePasswordSalt"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-02-24
pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]const u8 {
    return geode_auth.hashPasswordArgon2id(allocator, password);
}

/// Verify password against stored hash using the canonical Argon2id verification.
/// Delegates to geode_auth.verifyPasswordArgon2id (single source of truth).
// CANARY: REQ=REQ-AUTH-VERIFY-001; FEATURE="SecurePasswordVerify"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-02-24
pub fn verifyPassword(password: []const u8, stored_hash: []const u8) bool {
    // Use c_allocator for Argon2id scratch buffers in verification hot paths.
    // This avoids untracked page allocator usage in production runtime paths.
    const allocator = std.heap.c_allocator;
    return geode_auth.verifyPasswordArgon2id(allocator, password, stored_hash) catch false;
}

/// Create a new user
pub fn createUser(allocator: std.mem.Allocator, username: []const u8, password: []const u8, email: []const u8, role: Role, password_reset_required: bool) !void {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store == null) {
        try initUserStore(allocator);
    }

    var store = &user_store.?;

    // Check if user already exists
    if (store.contains(username)) {
        return error.UserAlreadyExists;
    }

    // Hash password
    const password_hash = try hashPassword(allocator, password);

    // Create user
    const user = User{
        .username = try allocator.dupe(u8, username),
        .password_hash = password_hash,
        .email = try allocator.dupe(u8, email),
        .role = role,
        .created_at = std.time.timestamp(),
        .last_login = null,
        .active = true,
        .password_reset_required = password_reset_required,
    };

    try store.put(try allocator.dupe(u8, username), user);
}

/// Authenticate user with username and password
pub fn authenticate(username: []const u8, password: []const u8) !AuthResult {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store == null) {
        return error.Unauthenticated;
    }

    var store = &user_store.?;

    // Get user from in-memory store (populated from graph store at startup)
    const user = store.get(username) orelse return error.Unauthenticated;

    // Check if user is active
    if (!user.active) {
        return error.Unauthenticated;
    }

    // Verify password
    if (!verifyPassword(password, user.password_hash)) {
        return error.Unauthenticated;
    }

    return AuthResult{
        .role = user.role,
        .password_reset_required = user.password_reset_required,
    };
}

// syncFromAuthStateFile removed — CLI and server both use graph store backend now.

/// Check if user has permission for operation
pub fn hasPermission(role: Role, permission: Permission) bool {
    const perms = Permission.fromRole(role);
    for (perms) |p| {
        if (p == permission) return true;
    }
    return false;
}

/// Get user by username
pub fn getUser(username: []const u8) ?User {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store == null) return null;

    return user_store.?.get(username);
}

/// Check if any users exist
pub fn hasUsers() bool {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store == null) return false;
    return user_store.?.count() > 0;
}

/// Update a user's password and clear the password_reset_required flag.
/// The new password must not match the current password (prevents reuse).
pub fn updateUserPassword(allocator: std.mem.Allocator, username: []const u8, new_password: []const u8) !void {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store == null) return error.Unauthenticated;
    var store = &user_store.?;
    const user_ptr = store.getPtr(username) orelse return error.Unauthenticated;

    // Reject if new password matches current password
    if (verifyPassword(new_password, user_ptr.password_hash)) {
        return error.PasswordReuse;
    }

    // Free the old password hash before replacing
    allocator.free(user_ptr.password_hash);
    user_ptr.password_hash = try hashPassword(allocator, new_password);
    user_ptr.password_reset_required = false;
}

/// Generate a cryptographically secure random password
/// GAP-0104/GAP-0108 SECURITY FIX: Use crypto random for initial passwords
fn generateSecurePassword(allocator: std.mem.Allocator) ![]const u8 {
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*";
    var password: [24]u8 = undefined;
    var random_bytes: [24]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    for (&password, random_bytes) |*p, r| {
        p.* = charset[r % charset.len];
    }

    return try allocator.dupe(u8, &password);
}

/// Create default admin user if no users exist
/// GAP-0104 SECURITY FIX: Removed hardcoded credentials. Uses environment variables
/// or generates cryptographically secure random passwords that are logged once on first startup.
pub fn ensureDefaultUser(allocator: std.mem.Allocator) !void {
    if (!hasUsers()) {
        // Get credentials from environment variables (no hardcoded fallback)
        const admin_user = std.process.getEnvVarOwned(allocator, "GEODE_ADMIN_USERNAME") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) break :blk try allocator.dupe(u8, "geode");
            return err;
        };
        defer allocator.free(admin_user);

        const admin_email = std.process.getEnvVarOwned(allocator, "GEODE_ADMIN_EMAIL") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) break :blk try allocator.dupe(u8, "admin@localhost");
            return err;
        };
        defer allocator.free(admin_email);

        // Get password from env or generate secure random password
        var generated_password: bool = false;
        const admin_password = std.process.getEnvVarOwned(allocator, "GEODE_ADMIN_PASSWORD") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
                generated_password = true;
                break :blk try generateSecurePassword(allocator);
            }
            return err;
        };
        defer allocator.free(admin_password);

        // Create admin user (force password reset only for auto-generated passwords)
        try createUser(allocator, admin_user, admin_password, admin_email, .Admin, generated_password);

        // Log generated password so the admin can retrieve it from journal/logs.
        // Uses log.err to ensure visibility even at --log-level error (the default).
        if (generated_password) {
            log.err("Initial admin password generated - change on first login", &.{
                Attr.string("admin_username", admin_user),
                Attr.string("GEODE_INITIAL_ADMIN_PASSWORD", admin_password),
                Attr.string("action_required", "Password must be changed on first login"),
            });
        }
    }
}
