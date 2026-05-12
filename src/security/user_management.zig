const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

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
    auth_version: u64 = 1,

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password_hash);
        allocator.free(self.email);
    }
};

pub const AuthResult = struct {
    role: Role,
    password_reset_required: bool,
    auth_version: u64,
};

pub const PersistentUserResolver = struct {
    ctx: ?*anyopaque = null,
    lookup_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?User,
    has_users_fn: *const fn (ctx: ?*anyopaque) anyerror!bool,
    list_fn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]User = null,
    auth_version_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8) anyerror!?u64 = null,
};

const CachedUserNode = struct {
    user: User,
    prev: ?*CachedUserNode = null,
    next: ?*CachedUserNode = null,
};

const UserCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(*CachedUserNode),
    head: ?*CachedUserNode = null,
    tail: ?*CachedUserNode = null,
    max_entries: usize,

    fn init(allocator: std.mem.Allocator, max_entries: usize) UserCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(*CachedUserNode).init(allocator),
            .max_entries = @max(@as(usize, 1), max_entries),
        };
    }

    fn deinit(self: *UserCache) void {
        var node = self.head;
        while (node) |current| {
            const next = current.next;
            current.user.deinit(self.allocator);
            self.allocator.destroy(current);
            node = next;
        }
        self.entries.deinit();
        self.head = null;
        self.tail = null;
    }

    fn get(self: *UserCache, username: []const u8) ?*CachedUserNode {
        const node = self.entries.get(username) orelse return null;
        self.promote(node);
        return node;
    }

    fn putOrUpdate(self: *UserCache, user: User) !*CachedUserNode {
        if (self.entries.get(user.username)) |existing| {
            self.promote(existing);
            self.allocator.free(user.username);
            self.allocator.free(existing.user.password_hash);
            self.allocator.free(existing.user.email);
            existing.user.password_hash = user.password_hash;
            existing.user.email = user.email;
            existing.user.role = user.role;
            existing.user.created_at = user.created_at;
            existing.user.last_login = user.last_login;
            existing.user.active = user.active;
            existing.user.password_reset_required = user.password_reset_required;
            existing.user.auth_version = user.auth_version;
            return existing;
        }

        const node = try self.allocator.create(CachedUserNode);
        node.* = .{ .user = user };
        try self.entries.put(node.user.username, node);
        self.insertHead(node);
        if (self.entries.count() > self.max_entries) {
            self.evictTail();
        }
        return node;
    }

    fn remove(self: *UserCache, username: []const u8) bool {
        const removed = self.entries.fetchRemove(username) orelse return false;
        const node = removed.value;
        self.unlink(node);
        node.user.deinit(self.allocator);
        self.allocator.destroy(node);
        return true;
    }

    fn snapshot(self: *UserCache) ![]const User {
        if (self.entries.count() == 0) return &[_]User{};

        const result = try self.allocator.alloc(User, self.entries.count());
        var i: usize = 0;
        var node = self.head;
        while (node) |current| {
            result[i] = current.user;
            i += 1;
            node = current.next;
        }
        return result;
    }

    fn insertHead(self: *UserCache, node: *CachedUserNode) void {
        node.prev = null;
        node.next = self.head;
        if (self.head) |head| head.prev = node;
        self.head = node;
        if (self.tail == null) self.tail = node;
    }

    fn promote(self: *UserCache, node: *CachedUserNode) void {
        if (self.head == node) return;
        self.unlink(node);
        self.insertHead(node);
    }

    fn unlink(self: *UserCache, node: *CachedUserNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
        node.prev = null;
        node.next = null;
    }

    fn evictTail(self: *UserCache) void {
        const node = self.tail orelse return;
        const key = node.user.username;
        _ = self.entries.fetchRemove(key);
        self.unlink(node);
        node.user.deinit(self.allocator);
        self.allocator.destroy(node);
    }
};

const AuthSnapshot = struct {
    password_hash: []u8,
    role: Role,
    password_reset_required: bool,
    active: bool,
    auth_version: u64,
};

/// Global user store - LRU cache backed by optional persistent resolver.
var user_store_mutex = std.Io.Mutex.init;
var user_store: ?UserCache = null;
var auth_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var persistent_resolver: ?PersistentUserResolver = null;

const default_auth_cache_entries: usize = 256;

fn authCacheCapacity(allocator: std.mem.Allocator) usize {
    const env_val = getEnvVarOwned(allocator, "GEODE_AUTH_CACHE_SIZE") catch return default_auth_cache_entries;
    defer allocator.free(env_val);
    return std.fmt.parseInt(usize, env_val, 10) catch default_auth_cache_entries;
}

fn currentCacheAllocator() std.mem.Allocator {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store) |*store| return store.allocator;
    return std.heap.c_allocator;
}

pub fn initUserStore(allocator: std.mem.Allocator) !void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) {
        user_store = UserCache.init(allocator, authCacheCapacity(allocator));
    }
}

pub fn setPersistentUserResolver(resolver: ?PersistentUserResolver) void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    persistent_resolver = resolver;
}

pub fn setCacheCapacityForTesting(max_entries: usize) !void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store) |*store| {
        store.max_entries = @max(@as(usize, 1), max_entries);
        while (store.entries.count() > store.max_entries) {
            store.evictTail();
        }
    }
}

pub fn setAuthEnabled(enabled: bool) void {
    auth_enabled.store(enabled, .release);
}

pub fn isAuthEnabled() bool {
    return auth_enabled.load(.acquire);
}

pub fn deinitUserStore() void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store) |*store| {
        store.deinit();
        user_store = null;
    }
    persistent_resolver = null;
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
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) {
        user_store = UserCache.init(allocator, authCacheCapacity(allocator));
    }

    var store = &user_store.?;
    const store_allocator = store.allocator;

    // Check if user already exists
    if (store.entries.contains(username)) {
        return error.UserAlreadyExists;
    }

    // Hash password
    const password_hash = try hashPassword(store_allocator, password);

    // Create user
    const user = User{
        .username = try store_allocator.dupe(u8, username),
        .password_hash = password_hash,
        .email = try store_allocator.dupe(u8, email),
        .role = role,
        .created_at = compat_timestamp(),
        .last_login = null,
        .active = true,
        .password_reset_required = password_reset_required,
        .auth_version = 1,
    };

    _ = try store.putOrUpdate(user);
}

/// Create a user with a pre-hashed password (for syncing from auth graph store).
/// Skips if the user already exists in the in-memory store.
pub fn createUserWithHash(allocator: std.mem.Allocator, username: []const u8, password_hash: []const u8, email: []const u8, role: Role, password_reset_required: bool) !void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) {
        user_store = UserCache.init(allocator, authCacheCapacity(allocator));
    }

    var store = &user_store.?;
    const store_allocator = store.allocator;

    // Skip if user already exists
    if (store.entries.contains(username)) {
        return;
    }

    const user = User{
        .username = try store_allocator.dupe(u8, username),
        .password_hash = try store_allocator.dupe(u8, password_hash),
        .email = try store_allocator.dupe(u8, email),
        .role = role,
        .created_at = compat_timestamp(),
        .last_login = null,
        .active = true,
        .password_reset_required = password_reset_required,
        .auth_version = 1,
    };

    _ = try store.putOrUpdate(user);
}

/// Authenticate user with username and password.
/// The Argon2id verification (10-50ms) runs OUTSIDE the mutex to avoid
/// serializing all auth operations behind a single lock.
pub fn authenticate(username: []const u8, password: []const u8) !AuthResult {
    const user_data = try getAuthSnapshot(username) orelse return error.Unauthenticated;
    defer std.heap.c_allocator.free(user_data.password_hash);

    // Phase 2: Verify password OUTSIDE the lock (Argon2id, 10-50ms).
    if (!user_data.active) {
        return error.Unauthenticated;
    }
    if (!verifyPassword(password, user_data.password_hash)) {
        return error.Unauthenticated;
    }

    return AuthResult{
        .role = user_data.role,
        .password_reset_required = user_data.password_reset_required,
        .auth_version = user_data.auth_version,
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
    return getUserInternal(username) catch null;
}

/// GAP-0270: List all users in the in-memory store
pub fn listUsers() ![]const User {
    try loadAllUsersFromResolver();

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return &[_]User{};
    return user_store.?.snapshot();
}

/// GAP-0270: Delete a user from the in-memory store
pub fn deleteUser(username: []const u8) !void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return error.Unauthenticated;
    if (!user_store.?.remove(username)) return error.Unauthenticated;
}

/// Check if any users exist
pub fn hasUsers() bool {
    const resolver = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (user_store != null and user_store.?.entries.count() > 0) return true;
        break :blk persistent_resolver;
    };

    if (resolver) |r| {
        return r.has_users_fn(r.ctx) catch false;
    }
    return false;
}

/// Update a user's password and clear the password_reset_required flag.
/// The new password must not match the current password (prevents reuse).
pub fn updateUserPassword(allocator: std.mem.Allocator, username: []const u8, new_password: []const u8) !void {
    _ = allocator;
    if (!try ensureUserCached(username)) return error.Unauthenticated;

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return error.Unauthenticated;
    const store_allocator = user_store.?.allocator;
    const user_ptr = user_store.?.entries.get(username) orelse return error.Unauthenticated;

    // Reject if new password matches current password
    if (verifyPassword(new_password, user_ptr.user.password_hash)) {
        return error.PasswordReuse;
    }

    // Free the old password hash before replacing
    store_allocator.free(user_ptr.user.password_hash);
    user_ptr.user.password_hash = try hashPassword(store_allocator, new_password);
    user_ptr.user.password_reset_required = false;
    user_ptr.user.auth_version += 1;
}

/// Change a user's role. Idempotent: re-assigning the current role is a no-op
/// (no auth_version bump). On a real change, bumps auth_version to invalidate
/// live sessions (mirrors updateUserPassword). Returns error.Unauthenticated if
/// the user is not present in the store.
// CANARY: REQ=REQ-GQL-AUTH-DDL-003; FEATURE="GQL Auth DDL"; ASPECT=RoleAssignment; STATUS=TESTED; TEST=tests/test_user_management.zig; OWNER=auth; UPDATED=2026-05-11
// CANARY: REQ=REQ-AUTH-ROLE-001; FEATURE="RoleAssignment"; ASPECT=Mutation; STATUS=TESTED; TEST=assignRole_changes_role_and_bumps_version; OWNER=security; UPDATED=2026-05-11
pub fn assignRole(allocator: std.mem.Allocator, username: []const u8, role: Role) !void {
    _ = allocator;
    if (!try ensureUserCached(username)) return error.Unauthenticated;

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return error.Unauthenticated;
    const user_ptr = user_store.?.entries.get(username) orelse return error.Unauthenticated;
    if (user_ptr.user.role == role) return; // no-op, no version bump
    user_ptr.user.role = role;
    user_ptr.user.auth_version += 1;
}

pub fn invalidateCachedUser(username: []const u8) void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store) |*store| {
        _ = store.remove(username);
    }
}

/// Generate a cryptographically secure random password
/// GAP-0104/GAP-0108 SECURITY FIX: Use crypto random for initial passwords
fn generateSecurePassword(allocator: std.mem.Allocator) ![]const u8 {
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*";
    var password: [24]u8 = undefined;
    var random_bytes: [24]u8 = undefined;
    compat_fillRandom(&random_bytes);

    for (&password, random_bytes) |*p, r| {
        p.* = charset[r % charset.len];
    }

    return try allocator.dupe(u8, &password);
}

/// Create default admin user if no users exist
/// GAP-0104 SECURITY FIX: Removed hardcoded credentials. Uses environment variables
/// or generates cryptographically secure random passwords that are logged once on first startup.
pub fn ensureDefaultUser(allocator: std.mem.Allocator) !void {
    if (persistentResolverEnabled()) {
        return;
    }

    if (!hasUsers()) {
        // Get credentials from environment variables (no hardcoded fallback)
        const admin_user = getEnvVarOwned(allocator, "GEODE_ADMIN_USERNAME") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) break :blk try allocator.dupe(u8, "geode");
            return err;
        };
        defer allocator.free(admin_user);

        const admin_email = getEnvVarOwned(allocator, "GEODE_ADMIN_EMAIL") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) break :blk try allocator.dupe(u8, "admin@localhost");
            return err;
        };
        defer allocator.free(admin_email);

        // Get password from env or generate secure random password
        var generated_password: bool = false;
        const admin_password = getEnvVarOwned(allocator, "GEODE_ADMIN_PASSWORD") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
                generated_password = true;
                break :blk try generateSecurePassword(allocator);
            }
            return err;
        };
        defer allocator.free(admin_password);

        // Create admin user (force password reset only for auto-generated passwords)
        try createUser(allocator, admin_user, admin_password, admin_email, .Admin, generated_password);

        // Log that a password was generated (without the password itself — S3 security fix).
        // The actual password is printed to stderr via std.debug.print in server_init.zig
        // for one-time retrieval; it must NEVER appear in structured logs that are forwarded
        // to log aggregators (ELK, Datadog, CloudWatch, etc.).
        if (generated_password) {
            log.err("Initial admin password generated - change on first login", &.{
                Attr.string("admin_username", admin_user),
                Attr.string("action_required", "Password was printed to stderr — change on first login"),
            });
        }
    }
}

fn persistentResolverEnabled() bool {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return persistent_resolver != null;
}

fn resolvePersistentUser(allocator: std.mem.Allocator, username: []const u8) !?User {
    const resolver = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        break :blk persistent_resolver;
    };

    if (resolver) |r| {
        return r.lookup_fn(r.ctx, allocator, username);
    }
    return null;
}

fn resolvePersistentAuthVersion(username: []const u8) !?u64 {
    const resolver = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        break :blk persistent_resolver;
    };

    if (resolver) |r| {
        if (r.auth_version_fn) |lookup| {
            return lookup(r.ctx, username);
        }
    }
    return null;
}

fn loadAllUsersFromResolver() !void {
    const resolver = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        break :blk persistent_resolver;
    };

    if (resolver == null or resolver.?.list_fn == null) return;
    const cache_allocator = currentCacheAllocator();
    const loaded = try resolver.?.list_fn.?(resolver.?.ctx, cache_allocator);
    defer cache_allocator.free(loaded);

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) {
        user_store = UserCache.init(cache_allocator, authCacheCapacity(cache_allocator));
    }

    for (loaded) |user| {
        _ = user_store.?.putOrUpdate(user) catch |err| {
            var owned = user;
            owned.deinit(cache_allocator);
            return err;
        };
    }
}

fn ensureUserCached(username: []const u8) !bool {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    if (user_store) |*store| {
        if (store.get(username) != null) {
            user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return true;
        }
    }
    user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const cache_allocator = currentCacheAllocator();
    const resolved = try resolvePersistentUser(cache_allocator, username);
    if (resolved == null) return false;

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store == null) {
        user_store = UserCache.init(cache_allocator, authCacheCapacity(cache_allocator));
    }
    _ = try user_store.?.putOrUpdate(resolved.?);
    return true;
}

fn refreshCachedUserIfStale(username: []const u8) !bool {
    if (!try ensureUserCached(username)) return false;

    const persistent_version = try resolvePersistentAuthVersion(username);
    if (persistent_version == null) return true;

    var cached_version: ?u64 = null;
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    if (user_store) |*store| {
        if (store.get(username)) |node| {
            cached_version = node.user.auth_version;
        }
    }
    user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (cached_version == null or cached_version.? == persistent_version.?) return true;

    invalidateCachedUser(username);
    return ensureUserCached(username);
}

pub fn currentAuthVersion(username: []const u8) !?u64 {
    if (try resolvePersistentAuthVersion(username)) |version| {
        return version;
    }
    if (!try ensureUserCached(username)) return null;

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store == null) return null;
    const cached = user_store.?.entries.get(username) orelse return null;
    return cached.user.auth_version;
}

pub fn isSessionAuthCurrent(username: []const u8, session_auth_version: u64) !bool {
    const current_version = try currentAuthVersion(username) orelse return false;
    return current_version == session_auth_version;
}

fn getAuthSnapshot(username: []const u8) !?AuthSnapshot {
    if (!try refreshCachedUserIfStale(username)) return null;
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return null;
    const cached = user_store.?.entries.get(username) orelse return null;
    return AuthSnapshot{
        .password_hash = try std.heap.c_allocator.dupe(u8, cached.user.password_hash),
        .role = cached.user.role,
        .password_reset_required = cached.user.password_reset_required,
        .active = cached.user.active,
        .auth_version = cached.user.auth_version,
    };
}

fn getUserInternal(username: []const u8) !?User {
    if (!try refreshCachedUserIfStale(username)) return null;
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return null;
    const cached = user_store.?.entries.get(username) orelse return null;
    return cached.user;
}

const testing = std.testing;

const TestUserDef = struct {
    username: []const u8,
    password: []const u8,
    email: []const u8,
    role: Role = .ReadWrite,
    active: bool = true,
    password_reset_required: bool = false,
    auth_version: u64 = 1,
};

const TestResolverState = struct {
    users: []const TestUserDef,
    lookup_calls: usize = 0,
    list_calls: usize = 0,
    has_users: bool = true,

    fn lookup(ctx: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?User {
        const self: *TestResolverState = @ptrCast(@alignCast(ctx orelse return null));
        self.lookup_calls += 1;
        for (self.users) |entry| {
            if (std.mem.eql(u8, entry.username, username)) {
                return .{
                    .username = try allocator.dupe(u8, entry.username),
                    .password_hash = try hashPassword(allocator, entry.password),
                    .email = try allocator.dupe(u8, entry.email),
                    .role = entry.role,
                    .created_at = 0,
                    .last_login = null,
                    .active = entry.active,
                    .password_reset_required = entry.password_reset_required,
                    .auth_version = entry.auth_version,
                };
            }
        }
        return null;
    }

    fn hasUsers(ctx: ?*anyopaque) anyerror!bool {
        const self: *TestResolverState = @ptrCast(@alignCast(ctx orelse return false));
        return self.has_users;
    }

    fn listUsers(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]User {
        const self: *TestResolverState = @ptrCast(@alignCast(ctx orelse return allocator.alloc(User, 0)));
        self.list_calls += 1;

        const users = try allocator.alloc(User, self.users.len);
        var initialized: usize = 0;
        errdefer {
            for (users[0..initialized]) |*user| {
                user.deinit(allocator);
            }
            allocator.free(users);
        }

        for (self.users, 0..) |entry, i| {
            users[i] = .{
                .username = try allocator.dupe(u8, entry.username),
                .password_hash = try hashPassword(allocator, entry.password),
                .email = try allocator.dupe(u8, entry.email),
                .role = entry.role,
                .created_at = 0,
                .last_login = null,
                .active = entry.active,
                .password_reset_required = entry.password_reset_required,
                .auth_version = entry.auth_version,
            };
            initialized += 1;
        }
        return users;
    }

    fn authVersion(ctx: ?*anyopaque, username: []const u8) anyerror!?u64 {
        const self: *TestResolverState = @ptrCast(@alignCast(ctx orelse return null));
        for (self.users) |entry| {
            if (std.mem.eql(u8, entry.username, username)) {
                return entry.auth_version;
            }
        }
        return null;
    }
};

test "authenticate uses persistent resolver and caches result" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);
    try setCacheCapacityForTesting(2);

    var state = TestResolverState{
        .users = &[_]TestUserDef{
            .{ .username = "alice", .password = "Password1!", .email = "alice@example.com", .role = .Admin },
        },
    };
    setPersistentUserResolver(.{
        .ctx = &state,
        .lookup_fn = TestResolverState.lookup,
        .has_users_fn = TestResolverState.hasUsers,
        .list_fn = TestResolverState.listUsers,
        .auth_version_fn = TestResolverState.authVersion,
    });

    const first = try authenticate("alice", "Password1!");
    try testing.expectEqual(Role.Admin, first.role);
    try testing.expectEqual(@as(usize, 1), state.lookup_calls);

    const second = try authenticate("alice", "Password1!");
    try testing.expectEqual(Role.Admin, second.role);
    try testing.expectEqual(@as(usize, 1), state.lookup_calls);
}

test "isSessionAuthCurrent detects persistent auth version bump" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);
    try setCacheCapacityForTesting(2);

    var users = [_]TestUserDef{
        .{ .username = "alice", .password = "Password1!", .email = "alice@example.com", .role = .ReadWrite, .auth_version = 1 },
    };
    var state = TestResolverState{
        .users = users[0..],
    };
    setPersistentUserResolver(.{
        .ctx = &state,
        .lookup_fn = TestResolverState.lookup,
        .has_users_fn = TestResolverState.hasUsers,
        .list_fn = TestResolverState.listUsers,
        .auth_version_fn = TestResolverState.authVersion,
    });

    const auth = try authenticate("alice", "Password1!");
    try testing.expect(try isSessionAuthCurrent("alice", auth.auth_version));

    users[0].auth_version = 2;
    try testing.expect(!(try isSessionAuthCurrent("alice", auth.auth_version)));
}

test "authenticate refreshes cached role after persistent auth version bump" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);
    try setCacheCapacityForTesting(2);

    var users = [_]TestUserDef{
        .{ .username = "alice", .password = "Password1!", .email = "alice@example.com", .role = .ReadWrite, .auth_version = 1 },
    };
    var state = TestResolverState{
        .users = users[0..],
    };
    setPersistentUserResolver(.{
        .ctx = &state,
        .lookup_fn = TestResolverState.lookup,
        .has_users_fn = TestResolverState.hasUsers,
        .list_fn = TestResolverState.listUsers,
        .auth_version_fn = TestResolverState.authVersion,
    });

    const first = try authenticate("alice", "Password1!");
    try testing.expectEqual(Role.ReadWrite, first.role);
    try testing.expectEqual(@as(usize, 1), state.lookup_calls);

    users[0].role = .Admin;
    users[0].auth_version = 2;

    const second = try authenticate("alice", "Password1!");
    try testing.expectEqual(Role.Admin, second.role);
    try testing.expectEqual(@as(usize, 2), state.lookup_calls);
    try testing.expectEqual(@as(u64, 2), second.auth_version);
}

test "auth cache evicts least recently used user" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);
    try setCacheCapacityForTesting(2);

    var state = TestResolverState{
        .users = &[_]TestUserDef{
            .{ .username = "alice", .password = "Password1!", .email = "alice@example.com" },
            .{ .username = "bob", .password = "Password2!", .email = "bob@example.com" },
            .{ .username = "carol", .password = "Password3!", .email = "carol@example.com" },
        },
    };
    setPersistentUserResolver(.{
        .ctx = &state,
        .lookup_fn = TestResolverState.lookup,
        .has_users_fn = TestResolverState.hasUsers,
        .list_fn = TestResolverState.listUsers,
        .auth_version_fn = TestResolverState.authVersion,
    });

    _ = try authenticate("alice", "Password1!");
    _ = try authenticate("bob", "Password2!");
    _ = try authenticate("alice", "Password1!");
    _ = try authenticate("carol", "Password3!");
    try testing.expectEqual(@as(usize, 3), state.lookup_calls);

    _ = try authenticate("bob", "Password2!");
    try testing.expectEqual(@as(usize, 4), state.lookup_calls);
}

test "ensureDefaultUser is ignored when persistent resolver is configured" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);

    var state = TestResolverState{
        .users = &[_]TestUserDef{},
        .has_users = false,
    };
    setPersistentUserResolver(.{
        .ctx = &state,
        .lookup_fn = TestResolverState.lookup,
        .has_users_fn = TestResolverState.hasUsers,
        .list_fn = TestResolverState.listUsers,
        .auth_version_fn = TestResolverState.authVersion,
    });

    try ensureDefaultUser(testing.allocator);
    try testing.expectError(error.Unauthenticated, authenticate("geode", "irrelevant-password"));
    try testing.expectEqual(@as(usize, 1), state.lookup_calls);
}

// CANARY: REQ=REQ-AUTH-ROLE-001; FEATURE="RoleAssignment"; ASPECT=Mutation; STATUS=TESTED; TEST=assignRole_changes_role_and_bumps_version; OWNER=security; UPDATED=2026-05-11
test "assignRole_changes_role_and_bumps_version" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);

    try createUser(testing.allocator, "ru", "Passw0rd1!", "ru@x.com", .User, false);

    const before = getUser("ru") orelse return error.TestSetupFailed;
    try testing.expectEqual(Role.User, before.role);
    try testing.expectEqual(@as(u64, 1), before.auth_version);

    try assignRole(testing.allocator, "ru", .Admin);

    const after = getUser("ru") orelse return error.TestSetupFailed;
    try testing.expectEqual(Role.Admin, after.role);
    try testing.expectEqual(@as(u64, 2), after.auth_version);
}

// CANARY: REQ=REQ-AUTH-ROLE-001; FEATURE="RoleAssignment"; ASPECT=Idempotent; STATUS=TESTED; TEST=assignRole_same_role_is_noop; OWNER=security; UPDATED=2026-05-11
test "assignRole_same_role_is_noop" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);

    try createUser(testing.allocator, "ru2", "Passw0rd1!", "ru2@x.com", .Admin, false);

    try assignRole(testing.allocator, "ru2", .Admin);

    const u = getUser("ru2") orelse return error.TestSetupFailed;
    try testing.expectEqual(Role.Admin, u.role);
    // auth_version must not have been incremented (no-op path)
    try testing.expectEqual(@as(u64, 1), u.auth_version);
}

// CANARY: REQ=REQ-AUTH-ROLE-001; FEATURE="RoleAssignment"; ASPECT=ErrorHandling; STATUS=TESTED; TEST=assignRole_missing_user_returns_unauthenticated; OWNER=security; UPDATED=2026-05-11
test "assignRole_missing_user_returns_unauthenticated" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);

    try testing.expectError(error.Unauthenticated, assignRole(testing.allocator, "nonexistent_user_xyz", .Admin));
}
