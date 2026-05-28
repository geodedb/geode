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

// CANARY: REQ=REQ-AUTH-GRANT-PERSIST-002; FEATURE="GQL Auth DDL Persistence"; ASPECT=WriteThrough; STATUS=TESTED; TEST=tests/test_auth_persistence.zig; OWNER=security; UPDATED=2026-05-12
/// Write-through callback set for persisting auth DDL mutations to the __geode_security graph.
/// All callbacks are optional and best-effort: a writer error is logged but never propagates
/// to the caller — the in-memory mutation is always committed first.
pub const PersistentUserWriter = struct {
    ctx: ?*anyopaque = null,
    create_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: Role) anyerror!void = null,
    delete_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8) anyerror!void = null,
    update_password_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void = null,
    set_role_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, role: Role) anyerror!void = null,
    set_active_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, active: bool) anyerror!void = null,
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

const AuthFlightKey = [std.crypto.hash.sha2.Sha256.digest_length]u8;

const AuthFlightResult = struct {
    ok: bool = false,
    result: AuthResult = .{
        .role = .ReadOnly,
        .password_reset_required = false,
        .auth_version = 0,
    },
};

const AuthFlight = struct {
    cv: std.Io.Condition = std.Io.Condition.init,
    refs: usize = 1,
    done: bool = false,
    result: AuthFlightResult = .{},
};

const AuthFlightStart = union(enum) {
    owner: *AuthFlight,
    waited: AuthResult,
};

const RefreshFlightKey = [std.crypto.hash.sha2.Sha256.digest_length]u8;

const RefreshFlightResult = union(enum) {
    ok: bool,
    err: anyerror,
};

const RefreshFlight = struct {
    cv: std.Io.Condition = std.Io.Condition.init,
    refs: usize = 1,
    done: bool = false,
    result: RefreshFlightResult = .{ .ok = false },
};

const RefreshFlightStart = union(enum) {
    owner: *RefreshFlight,
    waited: bool,
};

/// Global user store - LRU cache backed by optional persistent resolver.
var user_store_mutex = std.Io.Mutex.init;
var user_store: ?UserCache = null;
var auth_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
// CANARY: REQ=REQ-QUIC-HC-007; FEATURE="SessionAuthEpoch"; ASPECT=HotPathValidation; STATUS=TESTED; TEST=isSessionAuthCurrentCached_skips_persistent_lookup_until_epoch_changes; OWNER=security; UPDATED=2026-05-25
/// Monotonic process-local epoch for auth mutations that can invalidate live
/// sessions.  QUIC sessions cache the epoch observed at HELLO so steady-state
/// request validation avoids re-entering the persistent auth graph.
var auth_invalidation_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
var persistent_resolver: ?PersistentUserResolver = null;
var persistent_writer: ?PersistentUserWriter = null;
var auth_flight_mutex = std.Io.Mutex.init;
var auth_flights: ?std.AutoHashMap(AuthFlightKey, *AuthFlight) = null;
var auth_flight_lane: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var refresh_flight_mutex = std.Io.Mutex.init;
var refresh_flights: ?std.AutoHashMap(RefreshFlightKey, *RefreshFlight) = null;

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
    bumpAuthInvalidationEpoch();
}

pub fn setPersistentUserWriter(w: ?PersistentUserWriter) void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    persistent_writer = w;
    bumpAuthInvalidationEpoch();
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
    persistent_writer = null;
    auth_invalidation_epoch.store(1, .release);
    auth_flight_lane.store(0, .release);

    auth_flight_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    if (auth_flights) |*flights| {
        var it = flights.iterator();
        while (it.next()) |entry| {
            std.heap.c_allocator.destroy(entry.value_ptr.*);
        }
        flights.deinit();
        auth_flights = null;
    }
    auth_flight_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    refresh_flight_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    if (refresh_flights) |*flights| {
        var it = flights.iterator();
        while (it.next()) |entry| {
            std.heap.c_allocator.destroy(entry.value_ptr.*);
        }
        flights.deinit();
        refresh_flights = null;
    }
    refresh_flight_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

pub fn authInvalidationEpoch() u64 {
    return auth_invalidation_epoch.load(.acquire);
}

pub fn notePersistentAuthMutation() void {
    bumpAuthInvalidationEpoch();
}

fn bumpAuthInvalidationEpoch() void {
    _ = auth_invalidation_epoch.fetchAdd(1, .acq_rel);
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

// CANARY: REQ=REQ-QUIC-HC-068; FEATURE="QUIC High-Concurrency Requests"; ASPECT=AuthSingleFlight; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=security; UPDATED=2026-05-26
// CANARY: REQ=REQ-QUIC-HC-091; FEATURE="QUIC High-Concurrency Requests"; ASPECT=AuthSingleFlightLaneCollapse; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=security; UPDATED=2026-05-27
fn authFlightLane() u64 {
    // Identical username/password/hash/auth-version checks should share one
    // in-flight Argon2 verification. Sharding that key into multiple lanes
    // recreates verification waves during 1000-connection HELLO fan-out.
    return 0;
}

fn authFlightKey(username: []const u8, password: []const u8, stored_hash: []const u8, auth_version: u64, lane: u64) AuthFlightKey {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(username);
    hasher.update(&[_]u8{0});
    hasher.update(password);
    hasher.update(&[_]u8{0});
    hasher.update(stored_hash);
    const version_bytes = std.mem.toBytes(auth_version);
    hasher.update(&version_bytes);
    const lane_bytes = std.mem.toBytes(lane);
    hasher.update(&lane_bytes);
    var out: AuthFlightKey = undefined;
    hasher.final(&out);
    return out;
}

fn beginAuthFlight(key: AuthFlightKey) !AuthFlightStart {
    const io = std.Io.Threaded.global_single_threaded.io();
    auth_flight_mutex.lockUncancelable(io);
    defer auth_flight_mutex.unlock(io);

    if (auth_flights == null) {
        auth_flights = std.AutoHashMap(AuthFlightKey, *AuthFlight).init(std.heap.c_allocator);
    }

    if (auth_flights.?.get(key)) |flight| {
        flight.refs += 1;
        while (!flight.done) {
            flight.cv.waitUncancelable(io, &auth_flight_mutex);
        }
        const result = flight.result;
        flight.refs -= 1;
        if (flight.refs == 0) {
            _ = auth_flights.?.remove(key);
            std.heap.c_allocator.destroy(flight);
        }
        if (!result.ok) return error.Unauthenticated;
        return .{ .waited = result.result };
    }

    const flight = try std.heap.c_allocator.create(AuthFlight);
    errdefer std.heap.c_allocator.destroy(flight);
    flight.* = .{};
    try auth_flights.?.put(key, flight);
    return .{ .owner = flight };
}

fn finishAuthFlight(key: AuthFlightKey, flight: *AuthFlight, result: AuthFlightResult) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    auth_flight_mutex.lockUncancelable(io);
    flight.result = result;
    flight.done = true;
    flight.refs -= 1;
    const destroy_now = flight.refs == 0;
    if (destroy_now) {
        _ = auth_flights.?.remove(key);
    }
    flight.cv.broadcast(io);
    auth_flight_mutex.unlock(io);

    if (destroy_now) {
        std.heap.c_allocator.destroy(flight);
    }
}

// CANARY: REQ=REQ-QUIC-HC-130; FEATURE="QUIC High-Concurrency Requests"; ASPECT=AuthRefreshSingleFlight; STATUS=IMPL; TEST=authenticate_concurrent_cached_user_singleflights_persistent_refresh; OWNER=security; UPDATED=2026-05-28
fn refreshFlightKey(username: []const u8) RefreshFlightKey {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("auth-refresh");
    hasher.update(&[_]u8{0});
    hasher.update(username);
    var out: RefreshFlightKey = undefined;
    hasher.final(&out);
    return out;
}

fn beginRefreshFlight(key: RefreshFlightKey) !RefreshFlightStart {
    const io = std.Io.Threaded.global_single_threaded.io();
    refresh_flight_mutex.lockUncancelable(io);
    defer refresh_flight_mutex.unlock(io);

    if (refresh_flights == null) {
        refresh_flights = std.AutoHashMap(RefreshFlightKey, *RefreshFlight).init(std.heap.c_allocator);
    }

    if (refresh_flights.?.get(key)) |flight| {
        flight.refs += 1;
        while (!flight.done) {
            flight.cv.waitUncancelable(io, &refresh_flight_mutex);
        }
        const result = flight.result;
        flight.refs -= 1;
        if (flight.refs == 0) {
            _ = refresh_flights.?.remove(key);
            std.heap.c_allocator.destroy(flight);
        }
        return switch (result) {
            .ok => |ok| .{ .waited = ok },
            .err => |err| err,
        };
    }

    const flight = try std.heap.c_allocator.create(RefreshFlight);
    errdefer std.heap.c_allocator.destroy(flight);
    flight.* = .{};
    try refresh_flights.?.put(key, flight);
    return .{ .owner = flight };
}

fn finishRefreshFlight(key: RefreshFlightKey, flight: *RefreshFlight, result: RefreshFlightResult) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    refresh_flight_mutex.lockUncancelable(io);
    flight.result = result;
    flight.done = true;
    flight.refs -= 1;
    const destroy_now = flight.refs == 0;
    if (destroy_now) {
        _ = refresh_flights.?.remove(key);
    }
    flight.cv.broadcast(io);
    refresh_flight_mutex.unlock(io);

    if (destroy_now) {
        std.heap.c_allocator.destroy(flight);
    }
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

    const inserted = try store.putOrUpdate(user);
    bumpAuthInvalidationEpoch();
    if (persistent_writer) |w| {
        if (w.create_fn) |f| {
            f(w.ctx, username, email, inserted.user.password_hash, role) catch |err| {
                log.warn("persistent user writer failed", &.{ Attr.string("op", "create_fn"), Attr.string("error", @errorName(err)) });
            };
        }
    }
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

    const inserted2 = try store.putOrUpdate(user);
    bumpAuthInvalidationEpoch();
    if (persistent_writer) |w| {
        if (w.create_fn) |f| {
            f(w.ctx, username, email, inserted2.user.password_hash, role) catch |err| {
                log.warn("persistent user writer failed", &.{ Attr.string("op", "create_fn"), Attr.string("error", @errorName(err)) });
            };
        }
    }
}

/// Authenticate user with username and password.
/// The Argon2id verification (10-50ms) runs OUTSIDE the mutex to avoid
/// serializing all auth operations behind a single lock.
pub fn authenticate(username: []const u8, password: []const u8) !AuthResult {
    const maybe_user_data = try getAuthSnapshot(username);
    if (maybe_user_data == null) {
        // #829: defeat username-enumeration timing oracle by performing
        // equivalent Argon2id work on the provided password before returning
        // auth failure. Without this, the user-miss path returns ~95ms while
        // the wrong-password path takes ~275ms (full Argon2id), giving an
        // unauthenticated attacker a deterministic oracle to classify which
        // usernames exist.
        const dummy_hash = hashPassword(std.heap.c_allocator, password) catch {
            return error.Unauthenticated;
        };
        std.heap.c_allocator.free(dummy_hash);
        return error.Unauthenticated;
    }
    const user_data = maybe_user_data.?;
    defer std.heap.c_allocator.free(user_data.password_hash);

    const flight_key = authFlightKey(username, password, user_data.password_hash, user_data.auth_version, authFlightLane());
    switch (try beginAuthFlight(flight_key)) {
        .waited => |result| return result,
        .owner => |flight| {
            // Phase 2: Verify password OUTSIDE the lock (Argon2id, 10-50ms).
            if (!user_data.active) {
                // Same timing-defense rationale: an inactive user should look the
                // same as an active user with the wrong password.
                _ = verifyPassword(password, user_data.password_hash);
                finishAuthFlight(flight_key, flight, .{ .ok = false });
                return error.Unauthenticated;
            }
            if (!verifyPassword(password, user_data.password_hash)) {
                finishAuthFlight(flight_key, flight, .{ .ok = false });
                return error.Unauthenticated;
            }

            const result = AuthResult{
                .role = user_data.role,
                .password_reset_required = user_data.password_reset_required,
                .auth_version = user_data.auth_version,
            };
            finishAuthFlight(flight_key, flight, .{ .ok = true, .result = result });
            return result;
        },
    }
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
    bumpAuthInvalidationEpoch();

    if (persistent_writer) |w| {
        if (w.delete_fn) |f| {
            f(w.ctx, username) catch |err| {
                log.warn("persistent user writer failed", &.{ Attr.string("op", "delete_fn"), Attr.string("error", @errorName(err)) });
            };
        }
    }
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
    bumpAuthInvalidationEpoch();

    if (persistent_writer) |w| {
        if (w.update_password_fn) |f| {
            f(w.ctx, username, user_ptr.user.password_hash) catch |err| {
                log.warn("persistent user writer failed", &.{ Attr.string("op", "update_password_fn"), Attr.string("error", @errorName(err)) });
            };
        }
    }
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
    bumpAuthInvalidationEpoch();

    if (persistent_writer) |w| {
        if (w.set_role_fn) |f| {
            f(w.ctx, username, role) catch |err| {
                log.warn("persistent user writer failed", &.{ Attr.string("op", "set_role_fn"), Attr.string("error", @errorName(err)) });
            };
        }
    }
}

/// Enable or disable a user account. Idempotent: re-setting the same active state is a no-op.
/// On a real change, bumps auth_version to invalidate live sessions (mirrors assignRole).
/// Returns error.Unauthenticated if the user is not present in the store.
// CANARY: REQ=REQ-GQL-AUTH-DDL-004; FEATURE="GQL Auth DDL"; ASPECT=SetUserActive; STATUS=IMPL; OWNER=auth; UPDATED=2026-05-11
pub fn setUserActive(allocator: std.mem.Allocator, username: []const u8, active: bool) !void {
    _ = allocator;
    if (!try ensureUserCached(username)) return error.Unauthenticated;

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return error.Unauthenticated;
    const user_ptr = user_store.?.entries.get(username) orelse return error.Unauthenticated;
    if (user_ptr.user.active == active) return; // no-op
    user_ptr.user.active = active;
    user_ptr.user.auth_version += 1;
    bumpAuthInvalidationEpoch();

    if (persistent_writer) |w| {
        if (w.set_active_fn) |f| {
            f(w.ctx, username, active) catch |err| {
                log.warn("persistent user writer failed", &.{ Attr.string("op", "set_active_fn"), Attr.string("error", @errorName(err)) });
            };
        }
    }
}

pub fn invalidateCachedUser(username: []const u8) void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store) |*store| {
        if (store.remove(username)) {
            bumpAuthInvalidationEpoch();
        }
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

fn persistentAuthVersionResolverEnabled() bool {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (persistent_resolver) |r| return r.auth_version_fn != null;
    return false;
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

fn refreshCachedUserIfStaleOwner(username: []const u8) !bool {
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

fn refreshCachedUserIfStale(username: []const u8) !bool {
    const key = refreshFlightKey(username);
    switch (try beginRefreshFlight(key)) {
        .waited => |ok| return ok,
        .owner => |flight| {
            const result = refreshCachedUserIfStaleOwner(username) catch |err| {
                finishRefreshFlight(key, flight, .{ .err = err });
                return err;
            };
            finishRefreshFlight(key, flight, .{ .ok = result });
            return result;
        },
    }
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

fn cachedAuthVersion(username: []const u8) ?u64 {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store == null) return null;
    const cached = user_store.?.entries.get(username) orelse return null;
    return cached.user.auth_version;
}

pub fn isSessionAuthCurrentCached(username: []const u8, session_auth_version: u64, observed_epoch: *u64) !bool {
    if (session_auth_version == 0) return true;

    const current_epoch = authInvalidationEpoch();
    if (observed_epoch.* == current_epoch) return true;

    // Local user-management mutations update the in-memory auth_version before
    // their persistent write-through completes, so check the cache first and
    // fail closed for this user's stale sessions without contending on storage.
    if (cachedAuthVersion(username)) |cached_version| {
        if (cached_version != session_auth_version) return false;
    }

    if (try resolvePersistentAuthVersion(username)) |persistent_version| {
        if (persistent_version != session_auth_version) return false;
        observed_epoch.* = authInvalidationEpoch();
        return true;
    }

    if (!try ensureUserCached(username)) return false;
    const cached_version = cachedAuthVersion(username) orelse return false;
    if (cached_version != session_auth_version) return false;

    // If a persistent auth-version resolver exists but could not return a
    // version, preserve the pre-existing cache fallback for this request while
    // leaving observed_epoch stale so a later request retries the graph check.
    if (!persistentAuthVersionResolverEnabled()) {
        observed_epoch.* = authInvalidationEpoch();
    }
    return true;
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

fn testSleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const TestResolverState = struct {
    users: []const TestUserDef,
    lookup_calls: usize = 0,
    list_calls: usize = 0,
    auth_version_calls: usize = 0,
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
        self.auth_version_calls += 1;
        for (self.users) |entry| {
            if (std.mem.eql(u8, entry.username, username)) {
                return entry.auth_version;
            }
        }
        return null;
    }
};

const ConcurrentRefreshResolverState = struct {
    users: []const TestUserDef,
    lookup_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    auth_version_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    delay_ns: u64 = 0,

    fn lookup(ctx: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?User {
        const self: *ConcurrentRefreshResolverState = @ptrCast(@alignCast(ctx orelse return null));
        _ = self.lookup_calls.fetchAdd(1, .acq_rel);
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
        const self: *ConcurrentRefreshResolverState = @ptrCast(@alignCast(ctx orelse return false));
        return self.users.len > 0;
    }

    fn authVersion(ctx: ?*anyopaque, username: []const u8) anyerror!?u64 {
        const self: *ConcurrentRefreshResolverState = @ptrCast(@alignCast(ctx orelse return null));
        _ = self.auth_version_calls.fetchAdd(1, .acq_rel);
        if (self.delay_ns != 0) testSleepNs(self.delay_ns);
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

test "authenticate_concurrent_cached_user_singleflights_persistent_refresh" {
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);
    try setCacheCapacityForTesting(2);

    var users = [_]TestUserDef{
        .{ .username = "alice", .password = "Password1!", .email = "alice@example.com", .role = .Admin, .auth_version = 1 },
    };
    var state = ConcurrentRefreshResolverState{
        .users = users[0..],
        .delay_ns = 25 * std.time.ns_per_ms,
    };
    setPersistentUserResolver(.{
        .ctx = &state,
        .lookup_fn = ConcurrentRefreshResolverState.lookup,
        .has_users_fn = ConcurrentRefreshResolverState.hasUsers,
        .auth_version_fn = ConcurrentRefreshResolverState.authVersion,
    });

    const warm = try authenticate("alice", "Password1!");
    try testing.expectEqual(Role.Admin, warm.role);
    const baseline_version_lookups = state.auth_version_calls.load(.acquire);

    const Worker = struct {
        start: *std.atomic.Value(bool),
        ok: *std.atomic.Value(u32),
        failed: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            while (!ctx.start.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            const auth = authenticate("alice", "Password1!") catch {
                _ = ctx.failed.fetchAdd(1, .acq_rel);
                return;
            };
            if (auth.role == .Admin) {
                _ = ctx.ok.fetchAdd(1, .acq_rel);
            } else {
                _ = ctx.failed.fetchAdd(1, .acq_rel);
            }
        }
    };

    const worker_count = 8;
    var start = std.atomic.Value(bool).init(false);
    var ok = std.atomic.Value(u32).init(0);
    var failed = std.atomic.Value(u32).init(0);
    var contexts: [worker_count]Worker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .start = &start, .ok = &ok, .failed = &failed };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    }
    start.store(true, .release);
    for (&threads) |*thread| thread.join();

    try testing.expectEqual(@as(u32, worker_count), ok.load(.acquire));
    try testing.expectEqual(@as(u32, 0), failed.load(.acquire));
    try testing.expectEqual(baseline_version_lookups + 1, state.auth_version_calls.load(.acquire));
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

test "isSessionAuthCurrentCached_skips_persistent_lookup_until_epoch_changes" {
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
    var observed_epoch = authInvalidationEpoch();
    const baseline_version_lookups = state.auth_version_calls;

    try testing.expect(try isSessionAuthCurrentCached("alice", auth.auth_version, &observed_epoch));
    try testing.expect(try isSessionAuthCurrentCached("alice", auth.auth_version, &observed_epoch));
    try testing.expectEqual(baseline_version_lookups, state.auth_version_calls);

    notePersistentAuthMutation();
    try testing.expect(try isSessionAuthCurrentCached("alice", auth.auth_version, &observed_epoch));
    try testing.expect(state.auth_version_calls > baseline_version_lookups);
}

test "isSessionAuthCurrentCached_rejects_local_auth_version_bump_without_graph_lookup" {
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
    var observed_epoch = authInvalidationEpoch();
    const baseline_version_lookups = state.auth_version_calls;

    try assignRole(testing.allocator, "alice", .Admin);
    try testing.expect(!(try isSessionAuthCurrentCached("alice", auth.auth_version, &observed_epoch)));
    try testing.expectEqual(baseline_version_lookups, state.auth_version_calls);
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
