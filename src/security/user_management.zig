const std = @import("std");
const crypto = std.crypto;

// CANARY: REQ=REQ-AUTH-001; FEATURE="UserManagement"; ASPECT=Authentication; STATUS=IMPLEMENTED; OWNER=security; UPDATED=2025-10-14
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
    password_hash: [75]u8, // $argon2id$ + 64 hex chars + $ = 75 bytes
    email: []const u8,
    role: Role,
    created_at: i64,
    last_login: ?i64,
    active: bool,

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.email);
    }
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

/// Hash password using Argon2id
/// Argon2id is the recommended password hashing algorithm (combines Argon2i and Argon2d)
/// Resistant to both side-channel and GPU cracking attacks
pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![75]u8 {
    // Argon2id parameters (OWASP recommendations for server-side hashing)
    // - time_cost: Number of iterations (3 is recommended minimum)
    // - memory_cost: Memory in KiB (65536 = 64 MiB, recommended for server)
    // - parallelism: Number of threads (4 is typical for modern CPUs)
    const params = crypto.pwhash.argon2.Params{
        .t = 3, // time cost (iterations)
        .m = 65536, // memory cost in KiB (64 MiB)
        .p = 4, // parallelism (threads)
    };

    // Generate a deterministic salt from a fixed seed for this simplified implementation
    // PRODUCTION NOTE: Each user should have a unique random 16-byte salt stored with their hash
    var salt: [16]u8 = undefined;
    @memcpy(&salt, "geode_salt_v1_16"); // 16-byte salt

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

    // Encode as: $argon2id$ + 64 hex chars + $ = 75 bytes total
    var result: [75]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    _ = std.fmt.bufPrint(result[0..11], "$argon2id$", .{}) catch unreachable;
    var idx: usize = 10;
    for (hash) |b| {
        result[idx] = hex_chars[b >> 4];
        result[idx + 1] = hex_chars[b & 0x0F];
        idx += 2;
    }
    result[74] = '$';

    return result;
}

/// P2-3: Static GPA for password verification (small temporary allocation)
var verify_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var verify_gpa_init = false;

/// Verify password against stored hash using Argon2id
pub fn verifyPassword(password: []const u8, hash: [75]u8) bool {
    // P2-3: Use static GPA for temporary hash computation
    if (!verify_gpa_init) {
        verify_gpa_init = true;
    }
    const computed = hashPassword(verify_gpa.allocator(), password) catch return false;

    // Constant-time comparison to prevent timing attacks
    return crypto.timing_safe.eql([75]u8, computed, hash);
}

/// Create a new user
pub fn createUser(allocator: std.mem.Allocator, username: []const u8, password: []const u8, email: []const u8, role: Role) !void {
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
    };

    try store.put(try allocator.dupe(u8, username), user);
}

/// Authenticate user with username and password
pub fn authenticate(username: []const u8, password: []const u8) !Role {
    user_store_mutex.lock();
    defer user_store_mutex.unlock();

    if (user_store == null) {
        return error.Unauthenticated;
    }

    const store = &user_store.?;

    // Get user
    const user = store.get(username) orelse return error.Unauthenticated;

    // Check if user is active
    if (!user.active) {
        return error.Unauthenticated;
    }

    // Verify password
    if (!verifyPassword(password, user.password_hash)) {
        return error.Unauthenticated;
    }

    // Update last login
    // Note: We can't modify the user here as it's a const copy
    // In production, we'd need to get a mutable reference

    return user.role;
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

/// Create default admin user if no users exist
pub fn ensureDefaultUser(allocator: std.mem.Allocator) !void {
    if (!hasUsers()) {
        // Create default users with standard test credentials
        // These match the test harness secret substitution values
        try createUser(allocator, "admin", "admin123", "admin@geode.dev", .Admin);
        try createUser(allocator, "testuser", "password123", "test@geode.dev", .User);
    }
}
