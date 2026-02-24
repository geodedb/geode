const std = @import("std");
const crypto = std.crypto;
const auth_state = @import("auth_state.zig");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-AUTH-001; FEATURE="UserManagement"; ASPECT=Authentication; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
// User management system with bcrypt password hashing and role-based access control

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
    password_hash: [108]u8, // $argon2id$ + salt_hex(32) + $ + hash_hex(64) + $ = 108 bytes
    email: []const u8,
    role: Role,
    created_at: i64,
    last_login: ?i64,
    active: bool,
    password_reset_required: bool = false,

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
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

/// Hash password using Argon2id with cryptographically random salt
/// Argon2id is the recommended password hashing algorithm (combines Argon2i and Argon2d)
/// Resistant to both side-channel and GPU cracking attacks
// CANARY: REQ=REQ-AUTH-SALT-001; FEATURE="SecurePasswordSalt"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-10
pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![108]u8 {
    // Argon2id parameters (OWASP recommendations for server-side hashing)
    // - time_cost: Number of iterations (3 is recommended minimum)
    // - memory_cost: Memory in KiB (65536 = 64 MiB, recommended for server)
    // - parallelism: Number of threads (4 is typical for modern CPUs)
    const params = crypto.pwhash.argon2.Params{
        .t = 3, // time cost (iterations)
        .m = 65536, // memory cost in KiB (64 MiB)
        .p = 4, // parallelism (threads)
    };

    // Generate a cryptographically random 16-byte salt
    // Each user gets a unique salt preventing rainbow table attacks
    var salt: [16]u8 = undefined;
    crypto.random.bytes(&salt);

    // Hash the password with Argon2id - produces 32-byte output
    var hash: [32]u8 = undefined;
    crypto.pwhash.argon2.kdf(
        allocator,
        &hash,
        password,
        &salt,
        params,
        .argon2id,
    ) catch |err| {
        // If allocation fails, return the error
        if (err == error.OutOfMemory) return err;
        // For other errors, treat as OutOfMemory
        return error.OutOfMemory;
    };

    // Encode as: $argon2id$ + salt_hex(32) + $ + hash_hex(64) + $ = 108 bytes total
    // Format: $argon2id$<salt_hex>$<hash_hex>$
    // 10 + 32 + 1 + 64 + 1 = 108 bytes
    var result: [108]u8 = undefined;
    const hex_chars = "0123456789abcdef";

    // Write header: $argon2id$
    _ = std.fmt.bufPrint(result[0..10], "$argon2id$", .{}) catch unreachable;
    var idx: usize = 10;

    // Write salt as 32 hex chars
    for (salt) |b| {
        result[idx] = hex_chars[b >> 4];
        result[idx + 1] = hex_chars[b & 0x0F];
        idx += 2;
    }
    result[idx] = '$';
    idx += 1;

    // Write hash as 64 hex chars
    for (hash) |b| {
        result[idx] = hex_chars[b >> 4];
        result[idx + 1] = hex_chars[b & 0x0F];
        idx += 2;
    }
    result[idx] = '$';

    return result;
}

/// Verify password against stored hash using Argon2id
/// Extracts the unique salt from the stored hash and uses it for verification
// CANARY: REQ=REQ-AUTH-VERIFY-001; FEATURE="SecurePasswordVerify"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-10
pub fn verifyPassword(password: []const u8, stored_hash: [108]u8) bool {
    // Use c_allocator for Argon2id scratch buffers in verification hot paths.
    // This avoids untracked page allocator usage in production runtime paths.
    const allocator = std.heap.c_allocator;

    // Extract salt from stored hash (bytes 10-41 are hex-encoded salt)
    // Format: $argon2id$<salt_hex(32)>$<hash_hex(64)>$
    var salt: [16]u8 = undefined;
    const salt_hex = stored_hash[10..42];
    for (0..16) |i| {
        const hi = hexCharToVal(salt_hex[i * 2]) orelse return false;
        const lo = hexCharToVal(salt_hex[i * 2 + 1]) orelse return false;
        salt[i] = (hi << 4) | lo;
    }

    // Compute hash with extracted salt
    const params = crypto.pwhash.argon2.Params{
        .t = 3,
        .m = 65536,
        .p = 4,
    };

    var computed_hash: [32]u8 = undefined;
    crypto.pwhash.argon2.kdf(
        allocator,
        &computed_hash,
        password,
        &salt,
        params,
        .argon2id,
    ) catch return false;

    // Extract stored hash portion (bytes 43-106 are hex-encoded hash)
    var stored_hash_bytes: [32]u8 = undefined;
    const hash_hex = stored_hash[43..107];
    for (0..32) |i| {
        const hi = hexCharToVal(hash_hex[i * 2]) orelse return false;
        const lo = hexCharToVal(hash_hex[i * 2 + 1]) orelse return false;
        stored_hash_bytes[i] = (hi << 4) | lo;
    }

    // Constant-time comparison to prevent timing attacks
    return crypto.timing_safe.eql([32]u8, computed_hash, stored_hash_bytes);
}

fn hexCharToVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
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

    // Get user — if not found, try reloading from auth_state file
    // (the CLI writes user creates to the file, server keeps in-memory store)
    const user = store.get(username) orelse blk: {
        syncFromAuthStateFile(store) catch {};
        break :blk store.get(username) orelse return error.Unauthenticated;
    };

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

/// Sync users from the auth_state file into the in-memory store.
/// Called lazily when a user is not found in the in-memory store.
fn syncFromAuthStateFile(store: *std.StringHashMap(User)) !void {
    const allocator = store.allocator;
    const auth_state_path = auth_state.authStatePath(allocator) catch return;
    defer allocator.free(auth_state_path);

    const file = std.fs.openFileAbsolute(auth_state_path, .{}) catch return;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 64 * 1024) catch return;
    defer allocator.free(contents);

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '|');
        const kind = parts.next() orelse continue;

        if (std.mem.eql(u8, kind, "U")) {
            const uname = parts.next() orelse continue;
            _ = parts.next() orelse continue; // email
            const pwd_hash = parts.next() orelse continue;
            const role_str = parts.next() orelse "user";
            const active_str = parts.next() orelse "1";

            // Skip if already in store
            if (store.contains(uname)) continue;

            const role = Role.fromString(role_str) orelse .User;
            const active = std.mem.eql(u8, active_str, "1") or std.mem.eql(u8, active_str, "true");

            // Auth state file stores plaintext passwords; hash them for in-memory use
            const pwd_hash_buf: [108]u8 = if (pwd_hash.len == 108 and std.mem.startsWith(u8, pwd_hash, "$argon2id$"))
                // Already hashed
                pwd_hash[0..108].*
            else
                // Plaintext password — hash it
                hashPassword(allocator, pwd_hash) catch continue;

            const user = User{
                .username = allocator.dupe(u8, uname) catch continue,
                .password_hash = pwd_hash_buf,
                .email = allocator.dupe(u8, "") catch continue,
                .role = role,
                .created_at = std.time.timestamp(),
                .last_login = null,
                .active = active,
            };
            store.put(allocator.dupe(u8, uname) catch continue, user) catch continue;
        }
    }
}

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
    // Sync persisted users from auth_state file into the in-memory store
    // before checking hasUsers(). This prevents GEODE_ADMIN_PASSWORD from
    // overwriting an existing admin user on server restart.
    {
        user_store_mutex.lock();
        defer user_store_mutex.unlock();
        if (user_store) |*store| {
            syncFromAuthStateFile(store) catch {};
        }
    }

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
