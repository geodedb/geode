const std = @import("std");
const cb = @import("crypto_backend");

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
/// Monotonic nanoseconds, for bounding a wait. Never walks backwards on an NTP
/// step, unlike the REALTIME helpers above.
fn compat_monotonicNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        if (rc != 0) return 0;
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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

const build_options = @import("build_options");
const geode_auth = @import("geode_auth");
const auth_ddl_lock = @import("auth_ddl_lock.zig");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-AUTH-001; FEATURE="UserManagement"; ASPECT=Authentication; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
// User management system with Argon2id password hashing and role-based access control

// CANARY: REQ=REQ-NEW8-RESERVED-USERNAME; FEATURE="GeodeClusterReserved"; ASPECT=UserManagement; STATUS=TESTED; TEST=tests/test_new8_envelope_trust.zig; OWNER=security; UPDATED=2026-06-26
// Reserved usernames that MUST NOT be created via normal user management (CREATE USER DDL,
// geode.auth.user_create procedure, or any other user-creation path).
//
// "geode-cluster" is the federation node identity. The envelope trust gate in
// quic_connection_handler.zig uses state.authenticated_user == "geode-cluster" as the
// SOLE discriminant for federation connections (set at HELLO time only via
// validateFederationAuth, which requires GEODE_CLUSTER_TOKEN). If a regular user could
// be created with this name, they could authenticate through the normal user_mgmt path
// (validateFederationAuth fails, falls through to authenticate(), succeeds), set
// state.authenticated_user = "geode-cluster", and forge any principal envelope
// (Admin roles, foreign tenant_id) — completely bypassing NEW-8's fix.
//
// This reservation is therefore a SECURITY INVARIANT, not a convenience policy.
pub const RESERVED_USERNAMES: []const []const u8 = &.{"geode-cluster"};

pub const Role = enum {
    Admin, // Full access: read, write, schema changes
    User, // Limited access: read only
    ReadWrite, // Read and write access
    ReadOnly, // Explicit read-only access
    // CANARY: REQ=REQ-SEC-DEFAULT-ROLE-FAIL-CLOSED; FEATURE="FailClosedDefaultRole"; ASPECT=NoneRole; STATUS=TESTED; TEST=tests/test_default_role_fail_closed.zig; OWNER=security; UPDATED=2026-10-11
    /// No stored role: the default for a user whose record carries no
    /// built-in role (no `HAS_ROLE` edge to one, not a superuser). It holds no
    /// global permission at all: no read, no write, no schema, no admin. Such a
    /// user reaches a graph only through a per-graph grant on it, and gets
    /// that grant's privileges there (`gps.decide`, `isGrantOnly`). It is not
    /// assignable: `fromString` does not parse "none", so `ALTER USER ... SET
    /// ROLE none` is refused like any unknown role. Until 2026-10 the default
    /// was `ReadWrite`, which failed open.
    None,

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
            .None => "none",
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
            .None => &[_]Permission{},
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
    /// SONNY-6369: a superuser (the stored `is_superuser` flag) always
    /// resolves to `.Admin` (`role_resolver`), so `assignRole` refuses any
    /// other role for it. Set by the persistent resolver.
    is_superuser: bool = false,

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password_hash);
        allocator.free(self.email);
    }
};

// CANARY: REQ=REQ-SONNY-6312-USER-LIST-OWNERSHIP; FEATURE="GQL Auth DDL"; ASPECT=CallerOwnedUserCopies; STATUS=TESTED; TEST=tests/test_sonny6312_user_list_ownership.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6312: what SHOW USERS and `geode.auth.user_show` answer about a
/// user, copied under `user_store_mutex` with the caller's allocator: nothing
/// in it points into the user store, so a DROP USER cannot free it. Free with
/// `deinit` (or `freeUserSummaries`).
pub const UserSummary = struct {
    username: []const u8,
    email: []const u8,
    role: Role,
    active: bool,

    fn copyOf(allocator: std.mem.Allocator, user: User) !UserSummary {
        const username = try allocator.dupe(u8, user.username);
        errdefer allocator.free(username);
        return .{
            .username = username,
            .email = try allocator.dupe(u8, user.email),
            .role = user.role,
            .active = user.active,
        };
    }

    pub fn deinit(self: UserSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.email);
    }
};

pub fn freeUserSummaries(allocator: std.mem.Allocator, users: []const UserSummary) void {
    for (users) |u| u.deinit(allocator);
    allocator.free(users);
}

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
/// All callbacks are optional. SONNY-1333 / SONNY-3038: a writer error fails the mutation
/// (`error.UserNotPersisted`) and the in-memory user stays as stored; a security-reducing
/// change that could not be saved (a delete, a disable, a password change, a role
/// downgrade) is enforced in memory instead (`UnsavedRestriction`). Each callback stores
/// all of its change or none of it.
pub const PersistentUserWriter = struct {
    ctx: ?*anyopaque = null,
    create_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: Role) anyerror!void = null,
    delete_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8) anyerror!void = null,
    update_password_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void = null,
    /// SONNY-6369: replace a stored legacy hash with the Argon2id hash of the
    /// same password (no auth version bump: the password is unchanged); an
    /// error when the stored hash is no longer `old_hash`.
    rehash_password_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, old_hash: []const u8, new_hash: []const u8) anyerror!void = null,
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
            existing.user.is_superuser = user.is_superuser;
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

    /// SONNY-6312: a copy of every cached user's listed fields, made with
    /// `allocator` (the caller's), owned by the caller. Caller holds
    /// `user_store_mutex`.
    fn snapshot(self: *UserCache, allocator: std.mem.Allocator) ![]UserSummary {
        const result = try allocator.alloc(UserSummary, self.entries.count());
        var made: usize = 0;
        errdefer freeUserSummaries(allocator, result[0..made]);
        var node = self.head;
        while (node) |current| : (node = current.next) {
            result[made] = try UserSummary.copyOf(allocator, current.user);
            made += 1;
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

const AuthFlightKey = [32]u8;

const AuthFlightResult = struct {
    ok: bool = false,
    result: AuthResult = .{
        .role = .ReadOnly,
        .password_reset_required = false,
        .auth_version = 0,
    },
};

const AuthFlight = struct {
    /// Bumped (and futex-woken) by `finishAuthFlight`. ENG-3954 R-C: waiters
    /// block on this word with a DEADLINE. `std.Io.Condition` has no timed wait
    /// in Zig 0.16, and the untimed `waitUncancelable` it replaces is what let a
    /// single owner that left without publishing strand every later
    /// authentication for the same key — and the worker thread serving it —
    /// for the life of the process.
    wake: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    refs: usize = 1,
    done: bool = false,
    result: AuthFlightResult = .{},
};

const AuthFlightStart = union(enum) {
    owner: *AuthFlight,
    waited: AuthResult,
};

const RefreshFlightKey = [32]u8;

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

// CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=UnsavedRestrictions; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-3038: a security-reducing change to a user that could not be saved
/// to `__geode_security`. The statement fails, the stored user is as it was,
/// and the change is enforced here instead (fail closed, as a REVOKE whose
/// save failed takes the privilege away in memory): the user cannot
/// authenticate and its sessions are no longer current. The in-memory user
/// record cannot carry the change itself: it is reloaded from the store
/// whenever its auth_version differs, and on a cache miss. The restriction
/// lasts until a later change to the user is saved (see `clearUnsaved`) or
/// the process restarts, when the stored user is what applies.
pub const UnsavedRestriction = enum(u8) {
    deleted = 1,
    disabled = 2,
    password = 4,
    role = 8,
};

/// Users with unsaved restrictions: username (owned, c_allocator) -> mask of
/// `UnsavedRestriction`. Guarded by `user_store_mutex`.
var unsaved_restrictions: ?std.StringHashMap(u8) = null;

/// Record an unsaved restriction for `username`. Caller holds
/// `user_store_mutex`. If even this cannot be recorded (no memory), the
/// failure is logged; the statement still fails.
fn recordUnsavedLocked(username: []const u8, what: UnsavedRestriction) void {
    if (unsaved_restrictions == null) unsaved_restrictions = std.StringHashMap(u8).init(std.heap.c_allocator);
    const map = &unsaved_restrictions.?;
    if (map.getPtr(username)) |mask| {
        mask.* |= @intFromEnum(what);
    } else {
        const key = std.heap.c_allocator.dupe(u8, username) catch {
            log.err("SONNY-3038: an unsaved security-reducing user change could not be enforced in memory", &.{Attr.string("user", username)});
            return;
        };
        map.put(key, @intFromEnum(what)) catch {
            std.heap.c_allocator.free(key);
            log.err("SONNY-3038: an unsaved security-reducing user change could not be enforced in memory", &.{Attr.string("user", username)});
            return;
        };
    }
    bumpAuthInvalidationEpoch();
}

/// Drop the unsaved restrictions in `mask` for `username` (a later change
/// that was saved supersedes them). Caller holds `user_store_mutex`.
fn clearUnsavedLocked(username: []const u8, mask: u8) void {
    const map = &(unsaved_restrictions orelse return);
    const entry = map.getEntry(username) orelse return;
    entry.value_ptr.* &= ~mask;
    if (entry.value_ptr.* != 0) return;
    const key = entry.key_ptr.*;
    _ = map.remove(username);
    std.heap.c_allocator.free(key);
}

/// Every unsaved restriction: a saved delete, create, enable or disable
/// leaves the stored user as the one that applies.
const all_unsaved: u8 = 0xff;

fn hasUnsavedLocked(username: []const u8) bool {
    const map = &(unsaved_restrictions orelse return false);
    return map.contains(username);
}

/// SONNY-3038: whether `username` has a security-reducing change that could
/// not be saved and is enforced in memory (`UnsavedRestriction`).
pub fn hasUnsavedRestriction(username: []const u8) bool {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return hasUnsavedLocked(username);
}

fn deinitUnsavedLocked() void {
    const map = &(unsaved_restrictions orelse return);
    var it = map.keyIterator();
    while (it.next()) |key| std.heap.c_allocator.free(key.*);
    map.deinit();
    unsaved_restrictions = null;
}

/// How much a built-in role allows, for telling a downgrade (SONNY-3038).
fn roleRank(role: Role) u8 {
    return switch (role) {
        .Admin => 3,
        .ReadWrite => 2,
        .User, .ReadOnly => 1,
        .None => 0,
    };
}
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
    // Bug 731-4c: this writer owns the single durable password write for a
    // logical password change; tell SecurityManager to stop duplicating it.
    publishPasswordPersistenceOwnership();
    bumpAuthInvalidationEpoch();
}

/// Mirror `persistent_writer`'s password-write ownership into geode_auth so a
/// SecurityManager password change does not perform a SECOND durable write for
/// the same logical change. Caller must hold `user_store_mutex`.
fn publishPasswordPersistenceOwnership() void {
    const owned = if (persistent_writer) |w| w.update_password_fn != null else false;
    geode_auth.setExternalPasswordPersistenceOwner(owned);
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
    deinitUnsavedLocked();
    publishPasswordPersistenceOwnership();
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
/// SONNY-6367: a stored hash in the legacy BLAKE2b format (what `user import
/// --algorithm blake2b` stores) is verified with
/// geode_auth.verifyPasswordBlake2bLegacy; such a user could never log in.
// CANARY: REQ=REQ-AUTH-VERIFY-001; FEATURE="SecurePasswordVerify"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-02-24
// CANARY: REQ=REQ-SONNY-6369-LEGACY-HASH-TIMING; FEATURE="SecurePasswordVerify"; ASPECT=LegacyCheckTimingEqualised; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6369: the legacy check does the Argon2id work an Argon2id check
/// does (it hashes the password and discards the hash), so the time a login
/// takes does not tell an account with a legacy hash from one with an
/// Argon2id hash (the BLAKE2b check alone takes microseconds).
pub fn verifyPassword(password: []const u8, stored_hash: []const u8) !bool {
    if (geode_auth.isLegacyBlake2bHash(stored_hash)) {
        if (hashPassword(std.heap.c_allocator, password)) |equaliser| {
            std.heap.c_allocator.free(equaliser);
        } else |_| {}
        return geode_auth.verifyPasswordBlake2bLegacy(password, stored_hash) catch |err| {
            if (err == error.FipsUnsupported) return err;
            return false;
        };
    }
    // Use c_allocator for Argon2id scratch buffers in verification hot paths.
    // This avoids untracked page allocator usage in production runtime paths.
    const allocator = std.heap.c_allocator;
    return geode_auth.verifyPasswordArgon2id(allocator, password, stored_hash) catch |err| {
        if (err == error.FipsUnsupported) return err;
        return false;
    };
}

// CANARY: REQ=REQ-QUIC-HC-068; FEATURE="QUIC High-Concurrency Requests"; ASPECT=AuthSingleFlight; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=security; UPDATED=2026-05-26
// CANARY: REQ=REQ-QUIC-HC-091; FEATURE="QUIC High-Concurrency Requests"; ASPECT=AuthSingleFlightLaneCollapse; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=security; UPDATED=2026-05-27
fn authFlightLane() u64 {
    // Identical username/password/hash/auth-version checks should share one
    // in-flight Argon2 verification. Sharding that key into multiple lanes
    // recreates verification waves during 1000-connection HELLO fan-out.
    return 0;
}

fn authFlightKey(username: []const u8, password: []const u8, stored_hash: []const u8, auth_version: u64, lane: u64) !AuthFlightKey {
    var hasher = try cb.Hash.Stream.init(.sha256);
    defer hasher.deinit();
    try hasher.update(username);
    try hasher.update(&[_]u8{0});
    try hasher.update(password);
    try hasher.update(&[_]u8{0});
    try hasher.update(stored_hash);
    const version_bytes = std.mem.toBytes(auth_version);
    try hasher.update(&version_bytes);
    const lane_bytes = std.mem.toBytes(lane);
    try hasher.update(&lane_bytes);
    var out: AuthFlightKey = undefined;
    _ = try hasher.final(&out);
    return out;
}

/// Upper bound on how long a single-flight WAITER blocks for the owner to
/// publish its result. It exists only so that an owner which never publishes
/// cannot hang the auth path forever (ENG-3954 R-C); the owner's `defer`
/// already publishes on every exit, so the bound is a last-resort net and must
/// never fire on an owner that is still verifying.
///
/// The owner's critical section is one Argon2id verification: 10-50 ms in a
/// release build on an idle core, but ~360 ms in a Debug build, and several
/// times that on a CPU-starved host or under a HELLO fan-out where many
/// verifications for different users share the cores. The old 2 s bound fired
/// there: the waiters gave up with AuthFlightTimeout (AuthUnavailable to the
/// client) while the owner went on to accept the same credentials, so the
/// failure was spurious (authenticate_concurrent_cached_user_singleflights_
/// persistent_refresh: 1-4 of 8 logins on the k8s CI shards, and locally with
/// the test pinned to one core next to 16 busy loops). 30 s is longer than any
/// verification we have seen and still bounds a stuck owner. A `var` only so
/// the abandoned-owner regression in this file can shorten it.
var auth_flight_wait_timeout_ns: u64 = 30 * std.time.ns_per_s;

/// Drop the registration for `key` only when it still points at `flight`.
/// Caller holds `auth_flight_mutex`. Guarding on identity keeps a late owner
/// from evicting a NEWER flight that has already taken over the same key.
fn unregisterAuthFlight(key: AuthFlightKey, flight: *AuthFlight) void {
    if (auth_flights) |*flights| {
        if (flights.get(key)) |current| {
            if (current == flight) _ = flights.remove(key);
        }
    }
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
        const deadline_ns = compat_monotonicNs() +| auth_flight_wait_timeout_ns;
        while (!flight.done) {
            const now_ns = compat_monotonicNs();
            if (now_ns >= deadline_ns) {
                // ENG-3954 R-C: the owner never published. Fail this attempt
                // cleanly (an infrastructure error, NOT a credential verdict, so
                // auth_rate_limiter.shouldCountFailedAttempt leaves the per-IP
                // lockout alone) and drop the stale registration so the next
                // authentication starts a fresh flight instead of joining a dead
                // one. The abandoned owner still holds its own reference, so the
                // flight itself stays alive for it to finish into.
                flight.refs -= 1;
                unregisterAuthFlight(key, flight);
                if (flight.refs == 0) std.heap.c_allocator.destroy(flight);
                return error.AuthFlightTimeout;
            }
            // Sampled under the mutex, which `finishAuthFlight` also holds while
            // bumping it: a publish that lands after this read but before the
            // futex wait makes the wait return immediately.
            const observed = flight.wake.load(.acquire);
            const remaining_ns = deadline_ns - now_ns;
            auth_flight_mutex.unlock(io);
            io.futexWaitTimeout(u32, &flight.wake.raw, observed, .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(remaining_ns)),
                .clock = .awake,
            } }) catch {};
            auth_flight_mutex.lockUncancelable(io);
        }
        const result = flight.result;
        flight.refs -= 1;
        if (flight.refs == 0) {
            unregisterAuthFlight(key, flight);
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
        unregisterAuthFlight(key, flight);
    }
    // Bump + wake while STILL holding the mutex (as the previous
    // `cv.broadcast` did): once it is released, a waiter can take the result,
    // drop the last reference and destroy `flight` — touching `flight.wake`
    // after that would be a use-after-free.
    _ = flight.wake.fetchAdd(1, .release);
    io.futexWake(u32, &flight.wake.raw, std.math.maxInt(u32));
    auth_flight_mutex.unlock(io);

    if (destroy_now) {
        std.heap.c_allocator.destroy(flight);
    }
}

// CANARY: REQ=REQ-QUIC-HC-130; FEATURE="QUIC High-Concurrency Requests"; ASPECT=AuthRefreshSingleFlight; STATUS=IMPL; TEST=authenticate_concurrent_cached_user_singleflights_persistent_refresh; OWNER=security; UPDATED=2026-05-28
fn refreshFlightKey(username: []const u8) !RefreshFlightKey {
    var hasher = try cb.Hash.Stream.init(.sha256);
    defer hasher.deinit();
    try hasher.update("auth-refresh");
    try hasher.update(&[_]u8{0});
    try hasher.update(username);
    var out: RefreshFlightKey = undefined;
    _ = try hasher.final(&out);
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

// CANARY: REQ=REQ-SONNY-6331-ONE-PASSWORD-POLICY; FEATURE="Unified Password Policy Validation"; ASPECT=ServerUserStore; STATUS=TESTED; TEST=tests/test_sonny6331_password_policy_paths.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6331: the password policy every path that sets a password through
/// the server's user store applies (CREATE USER, ALTER USER SET PASSWORD,
/// geode.auth.user_create / user_reset_password / user_change_password, the
/// forced reset). `PasswordPolicy.geodeSecure()`, as the offline CLI and
/// the forced reset use. CREATE USER applied an older rule (8 characters, a
/// letter and a digit) and a password change none.
pub fn enforcePasswordPolicy(password: []const u8) geode_auth.PasswordPolicy.PolicyError!void {
    return geode_auth.PasswordPolicy.geodeSecure().enforce(password);
}

/// Create a new user. The password must meet the policy
/// (`enforcePasswordPolicy`; a `PasswordPolicy.PolicyError` otherwise).
pub fn createUser(allocator: std.mem.Allocator, username: []const u8, password: []const u8, email: []const u8, role: Role, password_reset_required: bool) !void {
    try enforcePasswordPolicy(password);
    return createUserUnchecked(allocator, username, password, email, role, password_reset_required);
}

/// `createUser` without the policy check: only for the first-boot admin,
/// whose operator-supplied seed is taken with a forced reset when it does
/// not meet the policy (`ensureDefaultUser`).
fn createUserUnchecked(allocator: std.mem.Allocator, username: []const u8, password: []const u8, email: []const u8, role: Role, password_reset_required: bool) !void {
    // NEW-8 / #860: Reject reserved usernames. "geode-cluster" is the federation
    // node identity and the SOLE discriminant for the envelope trust gate; allowing
    // it as a regular user credential would let an attacker bypass the gate entirely.
    for (RESERVED_USERNAMES) |reserved| {
        if (std.mem.eql(u8, username, reserved)) return error.ReservedUsername;
    }

    // SONNY-6352: see `beginUserChange`.
    const ddl_guard = auth_ddl_lock.acquire();
    defer ddl_guard.release();
    const change = try beginUserChange(allocator, username, .must_be_absent) orelse return error.UserAlreadyExists;

    // Hash password (Argon2id, outside the user store's mutex)
    var user = try newUser(change.store_allocator, username, try hashPassword(change.store_allocator, password), email, role, password_reset_required);
    errdefer user.deinit(change.store_allocator);

    if (change.writer) |w| {
        if (w.create_fn) |f| {
            // CANARY: REQ=REQ-SONNY-1333-GRANT-PERSIST-FAIL-CLOSED; FEATURE="GQL Auth DDL Persistence"; ASPECT=CreateUserFailureReported; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-1333: a user that could not be saved is not created. It
            // was kept in memory and reported created: it could log in until
            // the next start, then was gone. SONNY-6352: it is cached only
            // once it is saved.
            f(w.ctx, username, email, user.password_hash, role) catch |err| {
                log.warn("persistent user writer failed; the user was not created", &.{ Attr.string("op", "create_fn"), Attr.string("error", @errorName(err)) });
                return error.UserNotPersisted;
            };
        }
    }
    // SONNY-3038: a new user, stored: nothing unsaved applies to it.
    cacheNewUser(allocator, change, username, user);
}

/// Create a user with a pre-hashed password (for syncing from auth graph store).
/// Skips if the user already exists in the in-memory store.
pub fn createUserWithHash(allocator: std.mem.Allocator, username: []const u8, password_hash: []const u8, email: []const u8, role: Role, password_reset_required: bool) !void {
    // NEW-8 / #860: Reject reserved usernames (see createUser for rationale).
    for (RESERVED_USERNAMES) |reserved| {
        if (std.mem.eql(u8, username, reserved)) return error.ReservedUsername;
    }

    // SONNY-6352: see `beginUserChange`.
    const ddl_guard = auth_ddl_lock.acquire();
    defer ddl_guard.release();
    // Skip if user already exists
    const change = try beginUserChange(allocator, username, .must_be_absent) orelse return;

    var user = try newUser(change.store_allocator, username, try change.store_allocator.dupe(u8, password_hash), email, role, password_reset_required);
    errdefer user.deinit(change.store_allocator);

    if (change.writer) |w| {
        if (w.create_fn) |f| {
            // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=UserImportFailureReported; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-3038: as createUser (SONNY-1333): a user that could not
            // be saved is not imported. It was kept in memory and reported
            // imported (geode.auth.user_import), and was gone at the restart.
            f(w.ctx, username, email, user.password_hash, role) catch |err| {
                log.warn("persistent user writer failed; the user was not imported", &.{ Attr.string("op", "create_fn"), Attr.string("error", @errorName(err)) });
                return error.UserNotPersisted;
            };
        }
    }
    cacheNewUser(allocator, change, username, user);
}

// CANARY: REQ=REQ-SONNY-6352-WRITER-OUTSIDE-USER-STORE-MUTEX; FEATURE="GQL Auth DDL Persistence"; ASPECT=WriterOutsideUserStoreMutex; STATUS=TESTED; TEST=tests/test_sonny6352_auth_writer_and_removals.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6352: what a change to a user reads under `user_store_mutex` before
/// its persistent write-through. The six changes (create, import, delete,
/// password, role, active flag) held `user_store_mutex` (tier 5) while the
/// writer callback wrote `__geode_security` (tier 1 graph locks), a lock
/// order reversal. Each now holds `auth_ddl_lock` (re-entrant; the auth DDL
/// already holds it) for the whole change, so changes to users stay
/// serialized against each other and against the rest of the auth DDL, and
/// takes `user_store_mutex` only to read the cache here and to apply the
/// saved change to it afterwards; the writer and the Argon2id work run with
/// it released. A reader (a login, a session check) may reload the user
/// from the store in between; the apply step changes the cached user only
/// if it is still as it was read.
const UserChange = struct {
    store_allocator: std.mem.Allocator,
    writer: ?PersistentUserWriter,
};

const UserPresence = enum { must_be_absent, must_be_present };

/// `UserChange` for `username`, or null when `presence` does not hold (the
/// user is cached, for `.must_be_absent`; not cached, for
/// `.must_be_present`). Caller holds `auth_ddl_lock`.
fn beginUserChange(allocator: std.mem.Allocator, username: []const u8, presence: UserPresence) !?UserChange {
    std.debug.assert(auth_ddl_lock.heldByThisThread());
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store == null) {
        if (presence == .must_be_present) return null;
        user_store = UserCache.init(allocator, authCacheCapacity(allocator));
    }
    const cached = user_store.?.entries.contains(username);
    if (cached != (presence == .must_be_present)) return null;
    return .{ .store_allocator = user_store.?.allocator, .writer = persistent_writer };
}

/// A new `User` owning `password_hash` (allocated with `store_allocator`).
fn newUser(store_allocator: std.mem.Allocator, username: []const u8, password_hash: []const u8, email: []const u8, role: Role, password_reset_required: bool) !User {
    errdefer store_allocator.free(password_hash);
    const owned_username = try store_allocator.dupe(u8, username);
    errdefer store_allocator.free(owned_username);
    return .{
        .username = owned_username,
        .password_hash = password_hash,
        .email = try store_allocator.dupe(u8, email),
        .role = role,
        .created_at = compat_timestamp(),
        .last_login = null,
        .active = true,
        .password_reset_required = password_reset_required,
        .auth_version = 1,
    };
}

/// Put a created (and saved) user in the cache, taking ownership of `user`.
/// The user is stored, so a cache that cannot take it is not an error: the
/// persistent resolver loads it at its first use.
fn cacheNewUser(allocator: std.mem.Allocator, change: UserChange, username: []const u8, user: User) void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    var owned = user;
    if (user_store == null) user_store = UserCache.init(allocator, authCacheCapacity(allocator));
    if (user_store.?.allocator.ptr != change.store_allocator.ptr) {
        // The store was replaced while the change ran (tests only).
        owned.deinit(change.store_allocator);
    } else {
        _ = user_store.?.putOrUpdate(owned) catch |err| {
            log.warn("a created user could not be cached; it is loaded from the store at first use", &.{Attr.string("error", @errorName(err))});
            owned.deinit(change.store_allocator);
        };
    }
    bumpAuthInvalidationEpoch();
    clearUnsavedLocked(username, all_unsaved);
}

/// Authenticate user with username and password.
/// The Argon2id verification (10-50ms) runs OUTSIDE the mutex to avoid
/// serializing all auth operations behind a single lock.
///
/// ENG-3954 / #874: the ONLY credential verdicts this returns are `AuthResult`
/// (checked and accepted) and `error.Unauthenticated` (checked and rejected).
/// Every other failure — the persistent security store could not be consulted,
/// the store lock was unavailable, an allocation failed — is normalised to
/// `error.AuthUnavailable` so the transports can tell "wrong password" apart
/// from "we could not check" and stop counting server-side faults toward the
/// per-IP brute-force lockout (see auth_rate_limiter.shouldCountFailedAttempt).
/// The normalisation is uniform across principals, so it does not reintroduce
/// the #829 username-enumeration oracle: an unreachable store answers
/// identically for existing and non-existing usernames.
/// CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-001; FEATURE="AuthOutcomeClassification"; ASPECT=Authenticate; STATUS=TESTED; TEST=tests/test_auth_unavailable_classification.zig; OWNER=security; UPDATED=2026-08-28
pub fn authenticate(username: []const u8, password: []const u8) !AuthResult {
    return authenticateChecked(username, password) catch |err| {
        if (err == error.Unauthenticated) return err;
        log.warn("authentication could not be completed", &.{
            Attr.string("error", @errorName(err)),
        });
        return error.AuthUnavailable;
    };
}

/// Credential-checking core of `authenticate`. Any error other than
/// `error.Unauthenticated` escaping here means the credentials were never
/// actually checked; `authenticate` maps those to `error.AuthUnavailable`.
fn authenticateChecked(username: []const u8, password: []const u8) !AuthResult {
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

    const flight_key = try authFlightKey(username, password, user_data.password_hash, user_data.auth_version, authFlightLane());
    switch (try beginAuthFlight(flight_key)) {
        .waited => |result| return result,
        .owner => |flight| {
            // ENG-3954 R-C: the owner MUST publish a result on every exit, or
            // every later authentication for this key blocks on the flight. The
            // `try verifyPassword` below is such an exit (an infrastructure
            // error, e.g. error.FipsUnsupported, propagates straight out), and
            // any fallible call added here later would be another. This guard
            // publishes a failure for whichever exit did not publish one itself;
            // `published` keeps it from double-finishing the explicit paths.
            var published = false;
            defer if (!published) finishAuthFlight(flight_key, flight, .{ .ok = false });

            // Phase 2: Verify password OUTSIDE the lock (Argon2id, 10-50ms).
            if (!user_data.active) {
                // Same timing-defense rationale: an inactive user should look the
                // same as an active user with the wrong password.
                _ = verifyPassword(password, user_data.password_hash) catch false;
                finishAuthFlight(flight_key, flight, .{ .ok = false });
                published = true;
                return error.Unauthenticated;
            }
            if (!(try verifyPassword(password, user_data.password_hash))) {
                finishAuthFlight(flight_key, flight, .{ .ok = false });
                published = true;
                return error.Unauthenticated;
            }

            const result = AuthResult{
                .role = user_data.role,
                .password_reset_required = user_data.password_reset_required,
                .auth_version = user_data.auth_version,
            };
            finishAuthFlight(flight_key, flight, .{ .ok = true, .result = result });
            published = true;
            if (geode_auth.isLegacyBlake2bHash(user_data.password_hash)) {
                upgradeLegacyHash(username, password, user_data.password_hash);
            }
            return result;
        },
    }
}

// CANARY: REQ=REQ-SONNY-6369-LEGACY-HASH-UPGRADE; FEATURE="SecurePasswordVerify"; ASPECT=UpgradeAtLogin; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6369: after `username` logged in with `password` against its
/// legacy BLAKE2b hash `legacy_hash`, store the Argon2id hash of the same
/// password in its place (saved first through the persistent writer's
/// `rehash_password_fn`, then cached). The password is unchanged, so the
/// auth version is not bumped and the session the login opens stays
/// current. Best effort: a failure (no rehash writer, a save that fails,
/// cluster mode, FIPS, a hash changed meanwhile) is logged and the legacy
/// hash stays; the login has already succeeded. A legacy hash used to be
/// kept for ever.
fn upgradeLegacyHash(username: []const u8, password: []const u8, legacy_hash: []const u8) void {
    // SONNY-6352: serialized with the other user changes; user_store_mutex
    // is never held across the write-through.
    const ddl_guard = auth_ddl_lock.acquire();
    defer ddl_guard.release();
    const store_allocator, const writer = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (user_store == null) return;
        const user_ptr = user_store.?.entries.get(username) orelse return;
        if (!std.mem.eql(u8, user_ptr.user.password_hash, legacy_hash)) return;
        break :blk .{ user_store.?.allocator, persistent_writer };
    };
    const new_hash = hashPassword(store_allocator, password) catch |err| {
        log.warn("legacy password hash not upgraded", &.{ Attr.string("op", "hash"), Attr.string("error", @errorName(err)) });
        return;
    };
    var new_hash_cached = false;
    defer if (!new_hash_cached) store_allocator.free(new_hash);
    if (writer) |w| {
        // A writer that cannot store the upgrade: the cache must not carry
        // a hash the store does not have.
        const f = w.rehash_password_fn orelse return;
        f(w.ctx, username, legacy_hash, new_hash) catch |err| {
            log.warn("legacy password hash not upgraded", &.{ Attr.string("op", "rehash_password_fn"), Attr.string("error", @errorName(err)) });
            return;
        };
    }
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (cachedUserForChange(username, store_allocator)) |user_ptr| {
        if (std.mem.eql(u8, user_ptr.user.password_hash, legacy_hash)) {
            store_allocator.free(user_ptr.user.password_hash);
            user_ptr.user.password_hash = new_hash;
            new_hash_cached = true;
        }
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

/// Get user by username. SONNY-6312: the returned `User`'s strings point
/// into the user store and are freed by a DROP USER or an eviction on any
/// connection: use it for existence and the scalar fields only, and
/// `getUserSummary` for anything that keeps or returns a string.
pub fn getUser(username: []const u8) ?User {
    return getUserInternal(username) catch null;
}

/// GAP-0270: List all users in the in-memory store. SONNY-6312: a copy,
/// made under the lock with `allocator` and owned by the caller
/// (`freeUserSummaries`). It returned an array allocated with the store's
/// allocator that no caller freed (every SHOW USERS leaked it), and its
/// rows borrowed the cached users' strings past the lock, which a DROP USER
/// on another connection freed.
pub fn listUsers(allocator: std.mem.Allocator) ![]UserSummary {
    try loadAllUsersFromResolver();

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return allocator.alloc(UserSummary, 0);
    return user_store.?.snapshot(allocator);
}

/// SONNY-6312: one user's listed fields, copied under the lock with
/// `allocator` (caller frees with `UserSummary.deinit`); null if no such
/// user. Unlike `getUser`, nothing returned points into the store, and a
/// failed lookup is an error, not "no such user".
pub fn getUserSummary(allocator: std.mem.Allocator, username: []const u8) !?UserSummary {
    if (!try refreshCachedUserIfStale(username)) return null;
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (user_store == null) return null;
    const cached = user_store.?.entries.get(username) orelse return null;
    return try UserSummary.copyOf(allocator, cached.user);
}

/// GAP-0270: Delete a user from the in-memory store
pub fn deleteUser(username: []const u8) !void {
    // SONNY-3038: a stored user need not be cached (users are loaded at
    // their first login after a start, and evicted). An uncached user
    // answered Unauthenticated, which DROP USER reported as deleted, and the
    // stored user stayed.
    // SONNY-6352: see `beginUserChange`.
    const ddl_guard = auth_ddl_lock.acquire();
    defer ddl_guard.release();
    if (!try ensureUserCached(username)) return error.Unauthenticated;
    const change = try beginUserChange(std.heap.c_allocator, username, .must_be_present) orelse return error.Unauthenticated;

    if (change.writer) |w| {
        if (w.delete_fn) |f| {
            // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=DropUserFailClosed; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-3038: a delete that could not be saved fails, and the
            // user stays stored; it is locked out now (fail closed). It was
            // logged and reported deleted, and the next lookup reloaded the
            // stored user, so it could still log in.
            f(w.ctx, username) catch |err| {
                log.warn("persistent user writer failed; the user was not deleted and is locked out until a change to it is saved or the restart", &.{ Attr.string("op", "delete_fn"), Attr.string("error", @errorName(err)) });
                recordUnsaved(username, .deleted);
                return error.UserNotPersisted;
            };
        }
    }
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (user_store) |*store| _ = store.remove(username);
    clearUnsavedLocked(username, all_unsaved);
    bumpAuthInvalidationEpoch();
}

/// `recordUnsavedLocked`, taking `user_store_mutex` (SONNY-6352: a failed
/// write-through runs with it released).
fn recordUnsaved(username: []const u8, what: UnsavedRestriction) void {
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    recordUnsavedLocked(username, what);
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
    // SONNY-6331: checked before the user is looked up (no existence oracle).
    try enforcePasswordPolicy(new_password);
    // SONNY-6352: see `beginUserChange`.
    const ddl_guard = auth_ddl_lock.acquire();
    defer ddl_guard.release();
    if (!try ensureUserCached(username)) return error.Unauthenticated;

    const store_allocator, const current_hash, const writer = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (user_store == null) return error.Unauthenticated;
        const user_ptr = user_store.?.entries.get(username) orelse return error.Unauthenticated;
        break :blk .{ user_store.?.allocator, try std.heap.c_allocator.dupe(u8, user_ptr.user.password_hash), persistent_writer };
    };
    defer std.heap.c_allocator.free(current_hash);

    // Reject if new password matches current password
    if (try verifyPassword(new_password, current_hash)) {
        return error.PasswordReuse;
    }

    const new_hash = try hashPassword(store_allocator, new_password);
    var new_hash_cached = false;
    defer if (!new_hash_cached) store_allocator.free(new_hash);
    if (writer) |w| {
        if (w.update_password_fn) |f| {
            // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=PasswordChangeFailClosed; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-3038: saved first. A change that could not be saved fails,
            // the stored password stays, and the user is locked out (fail
            // closed: a password is often changed because the old one leaked).
            // It was logged and reported changed; the next lookup reloaded the
            // stored record, so the old password worked again.
            f(w.ctx, username, new_hash) catch |err| {
                log.warn("persistent user writer failed; the password was not changed and the user is locked out until a change to it is saved or the restart", &.{ Attr.string("op", "update_password_fn"), Attr.string("error", @errorName(err)) });
                recordUnsaved(username, .password);
                return error.UserNotPersisted;
            };
        }
    }

    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    // Applied to the cached user if it is still the one read above; one
    // reloaded from the store meanwhile already carries the change.
    if (cachedUserForChange(username, store_allocator)) |user_ptr| {
        if (std.mem.eql(u8, user_ptr.user.password_hash, current_hash)) {
            // Free the old password hash before replacing
            store_allocator.free(user_ptr.user.password_hash);
            user_ptr.user.password_hash = new_hash;
            new_hash_cached = true;
            user_ptr.user.password_reset_required = false;
            user_ptr.user.auth_version += 1;
        }
    }
    clearUnsavedLocked(username, @intFromEnum(UnsavedRestriction.password));
    bumpAuthInvalidationEpoch();
}

/// The cached `username` a change read with `store_allocator`, if the store
/// is still that one (SONNY-6352). Caller holds `user_store_mutex`.
fn cachedUserForChange(username: []const u8, store_allocator: std.mem.Allocator) ?*CachedUserNode {
    if (user_store) |*store| {
        if (store.allocator.ptr != store_allocator.ptr) return null;
        return store.entries.get(username);
    }
    return null;
}

/// Change a user's role. Idempotent: re-assigning the current role is a no-op
/// (no auth_version bump). On a real change, bumps auth_version to invalidate
/// live sessions (mirrors updateUserPassword). Returns error.Unauthenticated if
/// the user is not present in the store.
// CANARY: REQ=REQ-GQL-AUTH-DDL-003; FEATURE="GQL Auth DDL"; ASPECT=RoleAssignment; STATUS=TESTED; TEST=tests/test_user_management.zig; OWNER=auth; UPDATED=2026-05-11
// CANARY: REQ=REQ-AUTH-ROLE-001; FEATURE="RoleAssignment"; ASPECT=Mutation; STATUS=TESTED; TEST=assignRole_changes_role_and_bumps_version; OWNER=security; UPDATED=2026-05-11
pub fn assignRole(allocator: std.mem.Allocator, username: []const u8, role: Role) !void {
    _ = allocator;
    // SONNY-6352: see `beginUserChange`.
    const ddl_guard = auth_ddl_lock.acquire();
    defer ddl_guard.release();
    if (!try ensureUserCached(username)) return error.Unauthenticated;

    const store_allocator, const old_role, const writer = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (user_store == null) return error.Unauthenticated;
        const user_ptr = user_store.?.entries.get(username) orelse return error.Unauthenticated;
        // CANARY: REQ=REQ-SONNY-6369-SUPERUSER-ROLE-FIXED; FEATURE="RoleAssignment"; ASPECT=SuperuserKeepsAdmin; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
        // SONNY-6369: a superuser always resolves to Admin, so another role
        // would never take effect; refused, nothing changed. It was stored
        // and reported assigned, and the next login resolved Admin again.
        if (user_ptr.user.is_superuser and role != .Admin) return error.SuperuserRoleFixed;
        if (user_ptr.user.role == role) return; // no-op, no version bump
        break :blk .{ user_store.?.allocator, user_ptr.user.role, persistent_writer };
    };

    if (writer) |w| {
        if (w.set_role_fn) |f| {
            // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=RoleChangeFailClosed; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-3038: saved first. A change that could not be saved fails
            // and the stored role stays; a downgrade is enforced by locking
            // the user out (fail closed). It was logged and reported assigned.
            f(w.ctx, username, role) catch |err| {
                log.warn("persistent user writer failed; the role was not changed", &.{ Attr.string("op", "set_role_fn"), Attr.string("error", @errorName(err)) });
                if (roleRank(role) < roleRank(old_role)) recordUnsaved(username, .role);
                return error.UserNotPersisted;
            };
        }
    }
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (cachedUserForChange(username, store_allocator)) |user_ptr| {
        if (user_ptr.user.role == old_role) {
            user_ptr.user.role = role;
            user_ptr.user.auth_version += 1;
        }
    }
    clearUnsavedLocked(username, @intFromEnum(UnsavedRestriction.role));
    bumpAuthInvalidationEpoch();
}

/// Enable or disable a user account. Idempotent: re-setting the same active state is a no-op.
/// On a real change, bumps auth_version to invalidate live sessions (mirrors assignRole).
/// Returns error.Unauthenticated if the user is not present in the store.
// CANARY: REQ=REQ-GQL-AUTH-DDL-004; FEATURE="GQL Auth DDL"; ASPECT=SetUserActive; STATUS=IMPL; OWNER=auth; UPDATED=2026-05-11
pub fn setUserActive(allocator: std.mem.Allocator, username: []const u8, active: bool) !void {
    _ = allocator;
    // SONNY-6352: see `beginUserChange`.
    const ddl_guard = auth_ddl_lock.acquire();
    defer ddl_guard.release();
    if (!try ensureUserCached(username)) return error.Unauthenticated;

    const store_allocator, const writer = blk: {
        user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (user_store == null) return error.Unauthenticated;
        const user_ptr = user_store.?.entries.get(username) orelse return error.Unauthenticated;
        if (user_ptr.user.active == active) return; // no-op
        break :blk .{ user_store.?.allocator, persistent_writer };
    };

    if (writer) |w| {
        if (w.set_active_fn) |f| {
            // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=DisableFailClosed; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-3038: saved first. A change that could not be saved fails
            // and the stored flag stays; a disable is enforced by locking the
            // user out (fail closed). It was logged and reported disabled, and
            // the next lookup reloaded the stored, active, user.
            f(w.ctx, username, active) catch |err| {
                log.warn("persistent user writer failed; the active flag was not changed", &.{ Attr.string("op", "set_active_fn"), Attr.string("error", @errorName(err)) });
                if (!active) recordUnsaved(username, .disabled);
                return error.UserNotPersisted;
            };
        }
    }
    user_store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer user_store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (cachedUserForChange(username, store_allocator)) |user_ptr| {
        if (user_ptr.user.active != active) {
            user_ptr.user.active = active;
            user_ptr.user.auth_version += 1;
        }
    }
    clearUnsavedLocked(username, all_unsaved);
    bumpAuthInvalidationEpoch();
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
/// GAP-0104/GAP-0108 SECURITY FIX: Use crypto random for initial passwords.
/// SONNY-6331: one that meets the password policy.
fn generateSecurePassword(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [geode_auth.max_password_length]u8 = undefined;
    return try allocator.dupe(u8, try geode_auth.PasswordPolicy.geodeSecure().generate(&buf));
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

        // Create admin user. A reset is forced for a generated password and
        // (SONNY-6331, docs/USER_AUTH.md "Reset Triggers") for a seed that
        // does not meet the password policy: it is taken, so an existing
        // deployment still boots, but it only lets the admin set a new one.
        const seed_violation = if (generated_password) null else geode_auth.PasswordPolicy.geodeSecure().check(admin_password);
        if (seed_violation) |v| {
            log.warn("GEODE_ADMIN_PASSWORD does not meet the password policy; the admin must set a new password at first login", &.{
                Attr.string("reason", geode_auth.PasswordPolicy.geodeSecure().message(v)),
            });
        }
        try createUserUnchecked(allocator, admin_user, admin_password, admin_email, .Admin, generated_password or seed_violation != null);

        // Log that a password was generated (without the password itself — S3 security fix).
        // The actual password is printed to stderr via std.debug.print in server_init.zig
        // for one-time retrieval; it must NEVER appear in structured logs that are forwarded
        // to log aggregators (ELK, Datadog, CloudWatch, etc.).
        if (generated_password) {
            log.err("Initial admin password generated - change on first login", &.{
                Attr.string("admin_username", admin_user),
                Attr.string("action_required", "Password was printed to stderr — change on first login"),
            });
        } else {
            // Operator breadcrumb (2026-07-01 incident follow-up): this path
            // only runs when NO persistent auth graph is active
            // (persistentResolverEnabled() returned false above — e.g. HMAC
            // key unavailable or the engine-backed store fell back to
            // in-memory). An env-seeded admin created here lives only in
            // process memory: it is re-read from the environment on every
            // start, and any credential change made at runtime is LOST on
            // restart. Warn loudly so "the admin password tracked the env var
            // across a restart" is diagnosable from the logs.
            log.warn("Admin user seeded from GEODE_ADMIN_PASSWORD into the in-memory user store (no persistent auth graph active); this credential is NOT persisted and will be re-read from the environment on next start", &.{
                Attr.string("admin_username", admin_user),
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
        // NEW-8 residual (#860): skip reserved usernames so geode-cluster cannot
        // be seeded into user_store through the bulk-load resolver path.
        // Uses the module-level RESERVED_USERNAMES constant as the single source
        // of truth; byte-exact comparison, consistent with the createUser gate.
        const is_reserved = blk: {
            for (RESERVED_USERNAMES) |reserved| {
                if (std.mem.eql(u8, user.username, reserved)) break :blk true;
            }
            break :blk false;
        };
        if (is_reserved) {
            var owned = user;
            owned.deinit(cache_allocator);
            continue;
        }
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
    const key = try refreshFlightKey(username);
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
    // SONNY-3038: a security-reducing change that could not be saved.
    if (hasUnsavedRestriction(username)) return false;
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

    // SONNY-3038: a security-reducing change that could not be saved
    // (recording it moved the epoch, so every session comes here).
    if (hasUnsavedRestriction(username)) return false;

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
        // SONNY-3038: an unsaved security-reducing change locks the user out.
        .active = cached.user.active and !hasUnsavedLocked(username),
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
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
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
    release_refresh: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

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
        while (!self.release_refresh.load(.acquire)) testSleepNs(std.time.ns_per_ms);
        for (self.users) |entry| {
            if (std.mem.eql(u8, entry.username, username)) {
                return entry.auth_version;
            }
        }
        return null;
    }
};

test "authenticate uses persistent resolver and caches result" {
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
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
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);
    try setCacheCapacityForTesting(2);

    var users = [_]TestUserDef{
        .{ .username = "alice", .password = "Password1!", .email = "alice@example.com", .role = .Admin, .auth_version = 1 },
    };
    var state = ConcurrentRefreshResolverState{
        .users = users[0..],
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
                // error-policy: A — yield in a test spin-wait; on failure the
                // loop simply spins hotter, which is harmless.
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
    const refresh_key = try refreshFlightKey("alice");
    var start = std.atomic.Value(bool).init(false);
    var ok = std.atomic.Value(u32).init(0);
    var failed = std.atomic.Value(u32).init(0);
    var contexts: [worker_count]Worker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    {
        state.release_refresh.store(false, .release);
        var spawned: usize = 0;
        defer {
            // Release and join even if spawning or the overlap assertion
            // fails; no worker may outlive the resolver or user store.
            start.store(true, .release);
            state.release_refresh.store(true, .release);
            for (threads[0..spawned]) |thread| thread.join();
        }
        for (&contexts, 0..) |*ctx, i| {
            ctx.* = .{ .start = &start, .ok = &ok, .failed = &failed };
            threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ctx});
            spawned += 1;
        }
        start.store(true, .release);

        // A fixed resolver sleep does not prove overlap: a worker scheduled
        // after that sleep legitimately starts a second refresh. Hold the
        // owner until all callers have joined the actual production flight.
        // Bound the wait so a regression fails instead of hanging the shard.
        const io = std.Io.Threaded.global_single_threaded.io();
        const deadline = compat_monotonicNs() +| 30 * std.time.ns_per_s;
        var all_joined = false;
        while (compat_monotonicNs() < deadline) {
            refresh_flight_mutex.lockUncancelable(io);
            if (refresh_flights) |flights| {
                if (flights.get(refresh_key)) |flight| {
                    all_joined = !flight.done and flight.refs == worker_count;
                }
            }
            refresh_flight_mutex.unlock(io);
            if (all_joined) break;
            testSleepNs(std.time.ns_per_ms);
        }
        try testing.expect(all_joined);
    }

    try testing.expectEqual(@as(u32, worker_count), ok.load(.acquire));
    try testing.expectEqual(@as(u32, 0), failed.load(.acquire));
    try testing.expectEqual(baseline_version_lookups + 1, state.auth_version_calls.load(.acquire));
}

test "isSessionAuthCurrent detects persistent auth version bump" {
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
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
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
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
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
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
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
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
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
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
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);

    try createUser(testing.allocator, "ru", "Persistence Test Passphrase", "ru@x.com", .User, false);

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
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
    deinitUserStore();
    defer deinitUserStore();

    try initUserStore(testing.allocator);

    try createUser(testing.allocator, "ru2", "Persistence Test Passphrase", "ru2@x.com", .Admin, false);

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

// ── ENG-3954 / #874 residual R-C: single-flight leak -> permanent auth hang ──
//
// TRIAGE (current HEAD): `authenticateChecked`'s `.owner` branch owns an
// `AuthFlight` and is responsible for calling `finishAuthFlight` on EVERY exit.
// Two of its three exits do (:789 inactive, :793 wrong password, :802 success),
// but the credential check itself is reached through `try`:
//
//     if (!(try verifyPassword(password, user_data.password_hash))) {   // :792
//
// An infrastructure error there (today: `error.FipsUnsupported`, the one error
// `verifyPassword` at :489-497 deliberately re-raises instead of collapsing to
// `false`; tomorrow: anything else added to that error set) propagates straight
// out of the function. `finishAuthFlight` is never called, so the flight stays
// registered in `auth_flights` with `done = false` and `refs = 1` FOREVER.
//
// Every later `authenticate()` that hashes to the same flight key — same
// username, password, stored hash and auth_version, i.e. the legitimate user
// retrying — takes the waiter path and blocks on
//
//     while (!flight.done) flight.cv.waitUncancelable(io, &auth_flight_mutex);  // :536-537
//
// There is no timeout and no cancellation, so those QUIC/gRPC worker threads
// are gone for the life of the process: a single transient fault escalates from
// "one failed login" to "this principal can never authenticate again, and the
// worker pool bleeds a thread per attempt". That is strictly worse than the
// lockout this ticket is about — the lockout at least expires.
//
// CONTRACT PINNED HERE: an owner that leaves without publishing a result must
// NOT strand later authentications. Two ways to satisfy it, and a complete fix
// wants both:
//   1. `errdefer finishAuthFlight(...)` (or equivalent) around the owner branch
//      so the escape publishes a failure result, and
//   2. a BOUNDED wait in `beginAuthFlight`, so no future escape (or a killed
//      owner thread) can ever hang the auth path indefinitely.
//
// WHY THE TEST DRIVES THE FLIGHT PRIMITIVES DIRECTLY: the escape at :792 cannot
// be provoked from `authenticate()` in this build. `verifyPassword`'s only
// non-`false` outcome is `error.FipsUnsupported`, which
// `geode_auth.verifyPasswordArgon2id` raises behind `if (build_options.fips)` —
// a COMPTIME-dead branch here, and under `-Dfips` the whole Argon2 path (and
// therefore any fixture that needs a stored hash) is unavailable. There is no
// verifier-injection seam in production code, and adding one purely for a test
// would be production surface a test file must not invent. So the test
// reproduces the abandoned-owner state through the REAL `beginAuthFlight` /
// `finishAuthFlight` primitives — the same state line 792 leaves behind — and
// asserts the observable that actually matters: a subsequent authentication for
// that key RETURNS (any outcome) instead of blocking forever.
//
// The watchdog makes RED a clean FAILURE, never a hung test runner: the waiter
// runs on a spawned thread, the main thread polls a bounded budget, and it then
// ALWAYS rescues the abandoned flight so the waiter wakes, the thread joins, and
// the flight is destroyed with correct refcounts.
//
// CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-004; FEATURE="AuthOutcomeClassification"; ASPECT=SingleFlightLeak; STATUS=TESTED; TEST=auth_flight_abandoned_owner_does_not_strand_waiters; OWNER=security; UPDATED=2026-08-29

/// Number of flights currently registered (test-only observability).
fn authFlightCountForTest() usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    auth_flight_mutex.lockUncancelable(io);
    defer auth_flight_mutex.unlock(io);
    if (auth_flights) |flights| return flights.count();
    return 0;
}

test "auth_flight_abandoned_owner_does_not_strand_waiters" {
    // The production bound is 30 s; this test needs the waiter to give up
    // inside its 3 s budget, which is what the bound is for.
    const saved_wait_timeout_ns = auth_flight_wait_timeout_ns;
    auth_flight_wait_timeout_ns = 2 * std.time.ns_per_s;
    defer auth_flight_wait_timeout_ns = saved_wait_timeout_ns;

    // Key built exactly as authenticateChecked:780 builds it.
    const key = try authFlightKey("alice", "Password1!", "$argon2id$v=19$stub", 1, authFlightLane());

    const owner_flight = switch (try beginAuthFlight(key)) {
        .owner => |f| f,
        .waited => return error.UnexpectedWaiterOnFreshFlightKey,
    };

    // ...and now the owner ABANDONS it, exactly as the `try verifyPassword`
    // escape at :792 does: no finishAuthFlight, done stays false.

    const Waiter = struct {
        key: AuthFlightKey,
        returned: *std.atomic.Value(bool),

        fn run(ctx: *@This()) void {
            // The legitimate user retrying. Any outcome is acceptable — an
            // error is fine, blocking forever is not.
            if (beginAuthFlight(ctx.key)) |_| {} else |_| {}
            ctx.returned.store(true, .release);
        }
    };

    var returned = std.atomic.Value(bool).init(false);
    var ctx = Waiter{ .key = key, .returned = &returned };
    var thread = try std.Thread.spawn(.{}, Waiter.run, .{&ctx});

    const budget_ns: u64 = 3 * std.time.ns_per_s;
    const step_ns: u64 = 25 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    while (!returned.load(.acquire) and waited_ns < budget_ns) : (waited_ns += step_ns) {
        testSleepNs(step_ns);
    }
    const returned_within_budget = returned.load(.acquire);

    // Rescue unconditionally so the RED run terminates cleanly: this releases a
    // still-blocked waiter and drops the owner's reference either way, leaving
    // `auth_flights` empty for the next test.
    finishAuthFlight(key, owner_flight, .{ .ok = false });
    thread.join();

    if (!returned_within_budget) return error.AbandonedAuthFlightStrandedNextAuthentication;
    try testing.expectEqual(@as(usize, 0), authFlightCountForTest());
}

// Guard (green before AND after): the normal credential paths must never leave a
// flight registered. This is the invariant the `.owner` branch's escape breaks;
// pinning it here keeps a future errdefer from double-finishing or leaking on
// the paths that work today.
test "auth_flight_normal_paths_leave_no_registered_flight" {
    if (build_options.fips) return error.SkipZigTest; // requires Argon2id hashing for test setup
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

    _ = try authenticate("alice", "Password1!");
    try testing.expectEqual(@as(usize, 0), authFlightCountForTest());

    try testing.expectError(error.Unauthenticated, authenticate("alice", "WrongPassword!"));
    try testing.expectEqual(@as(usize, 0), authFlightCountForTest());

    try testing.expectError(error.Unauthenticated, authenticate("nobody", "Password1!"));
    try testing.expectEqual(@as(usize, 0), authFlightCountForTest());
}
