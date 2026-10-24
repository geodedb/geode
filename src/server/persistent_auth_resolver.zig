//! Persistent auth resolver callbacks — the `__geode_security`-backed
//! implementation of `user_management.PersistentUserResolver` installed by the
//! server at startup (`src/server/main.zig`).
//!
//! Extracted from `main.zig` (ENG-3979) so the callbacks can be driven
//! directly by regression tests: they are the exact seam where a mutating
//! `CALL geode.auth.*` re-enters the store lock it is already holding.
//!
//! CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-004; FEATURE="AuthOutcomeClassification"; ASPECT=PersistentResolverModule; STATUS=TESTED; TEST=tests/test_auth_unavailable_classification.zig; OWNER=security; UPDATED=2026-08-30

const std = @import("std");
const geode = @import("geode");
const user_storage = @import("user_storage");

// GPS Phase 4 (Task 4-1): role resolution lives in a dedicated module.
// Use the geode lib re-export rather than a raw file path so that the
// "user_storage" named import inside role_resolver.zig is resolved correctly.
const role_resolver = geode.security.role_resolver;

// CANARY: REQ=REQ-GPS-PDP-008; FEATURE="GPS Decision Engine"; ASPECT=AuthRoleGraphLookup; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
/// Thin shims that delegate to role_resolver — kept for call-site compatibility.
pub fn authRoleFromRecord(record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    return role_resolver.authRoleFromRecord(record);
}

pub fn resolveRoleFromGraph(store: *geode.graph_store.GraphStore, record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    return role_resolver.resolveRoleFromGraph(store, record);
}

fn duplicatePersistentUser(allocator: std.mem.Allocator, store: *geode.graph_store.GraphStore, record: user_storage.UserStorageBackend.UserRecord) !geode.user_management.User {
    return .{
        .username = try allocator.dupe(u8, record.getUsername()),
        .password_hash = try allocator.dupe(u8, record.getPasswordHash()),
        .email = try allocator.dupe(u8, record.getEmail()),
        .role = resolveRoleFromGraph(store, record),
        .created_at = record.created_at,
        .last_login = if (record.last_login != 0) record.last_login else null,
        .active = record.is_active,
        .password_reset_required = record.password_reset_required,
        .auth_version = record.auth_version,
    };
}

/// ENG-3979: obtain synchronized read access to the global store for a
/// resolver callback.
///
/// The callbacks below run on BOTH shapes of caller:
///   * an unlocked transport/auth thread (must take the lock itself), and
///   * a thread already deep inside a store critical section — a mutating
///     `CALL geode.auth.*` runs under the global EXCLUSIVE store lock
///     (`acquireGraphWriteLockCancelable` escalates to global-exclusive when
///     the target graph does not exist yet) and then calls back in here.
///
/// `graph_store.beginStoreRead` distinguishes those from genuine foreign
/// contention: the self-held case reads without re-acquiring (re-acquiring
/// can never succeed against our own exclusive hold), and only a lock held by
/// ANOTHER thread yields `.unavailable`, which every callback reports as
/// `SecurityStoreUnavailable` rather than reading the store unsynchronized or
/// answering "no such user".
fn beginResolverRead() error{SecurityStoreUnavailable}!geode.graph_store.StoreReadAccess {
    const access = geode.graph_store.beginStoreRead();
    if (access == .unavailable) {
        // ENG-3954 RC-4 (latent): count store-unavailable resolver reads so an
        // operator can SEE the "we could not check" outcomes the rate limiter
        // deliberately does not count against a lockout. A monotonic counter
        // only — the locking protocol is unchanged.
        _ = g_store_unavailable_total.fetchAdd(1, .monotonic);
        return user_storage.UserStorageBackend.SecurityStoreUnavailable;
    }
    return access;
}

/// ENG-3954 RC-4: monotonic count of resolver reads refused because the
/// security store lock was held by another thread (`.unavailable`). Registered
/// into the runtime metrics registry at server startup as
/// `geode_security_auth_store_unavailable_total`.
var g_store_unavailable_total = std.atomic.Value(u64).init(0);

/// Accessor for the RC-4 store-unavailable counter (registry registration).
pub fn storeUnavailableCounter() *std.atomic.Value(u64) {
    return &g_store_unavailable_total;
}

pub fn lookupPersistentAuthUser(_: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?geode.user_management.User {
    // NEW-8 residual (#860): block reserved usernames at the resolver boundary.
    // Returning null here means ensureUserCached / authenticate treat the
    // principal as "not found", preventing geode-cluster from being seeded into
    // user_store via the persistent-lookup path regardless of what is stored in
    // the auth graph.  Uses RESERVED_USERNAMES as the single source of truth.
    for (geode.user_management.RESERVED_USERNAMES) |reserved| {
        if (std.mem.eql(u8, username, reserved)) return null;
    }
    // ENG-3954 / #874: when the lock cannot be acquired we must NOT read the
    // store unsynchronized, and we must NOT report "no such user" either — we
    // simply could not look. Reporting absence here made `authenticate` return
    // error.Unauthenticated for a perfectly valid principal, which the per-IP
    // rate limiter counted as a brute-force attempt and, since the contention
    // persisted, re-armed the lockout on every retry. Report unavailability so
    // authenticate() can normalise it to error.AuthUnavailable.
    // CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-003; FEATURE="AuthOutcomeClassification"; ASPECT=PersistentResolver; STATUS=TESTED; TEST=tests/test_auth_unavailable_classification.zig; OWNER=security; UPDATED=2026-08-30
    const access = try beginResolverRead();
    defer geode.graph_store.endStoreRead(access);

    const store = geode.graph_store.getLiveGlobalStore(allocator);
    const record = try user_storage.UserStorageBackend.findUserByUsernameInGraphChecked(store, username) orelse return null;
    return try duplicatePersistentUser(allocator, store, record);
}

pub fn persistentAuthUsersExist(_: ?*anyopaque) anyerror!bool {
    // Same reentrant gate as lookupPersistentAuthUser (ENG-3979).
    const access = try beginResolverRead();
    defer geode.graph_store.endStoreRead(access);

    const store = geode.graph_store.getLiveGlobalStore(std.heap.c_allocator);
    return user_storage.UserStorageBackend.hasUserRecordsInGraph(store);
}

pub fn lookupPersistentAuthVersion(_: ?*anyopaque, username: []const u8) anyerror!?u64 {
    // Same reentrant gate as lookupPersistentAuthUser (ENG-3979).  A foreign
    // holder yields SecurityStoreUnavailable, which authenticate() normalises
    // to error.AuthUnavailable — the staleness probe must never silently read
    // the store unsynchronized to answer it.
    const access = try beginResolverRead();
    defer geode.graph_store.endStoreRead(access);

    const store = geode.graph_store.getLiveGlobalStore(std.heap.c_allocator);
    return user_storage.UserStorageBackend.findUserAuthVersionByUsernameInGraph(store, username);
}

pub fn listPersistentAuthUsers(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]geode.user_management.User {
    // Same reentrant gate as lookupPersistentAuthUser (ENG-3979).
    const access = try beginResolverRead();
    defer geode.graph_store.endStoreRead(access);

    const store = geode.graph_store.getLiveGlobalStore(allocator);
    const records = try user_storage.UserStorageBackend.listUsersFromGraph(allocator, store);
    defer allocator.free(records);

    const users = try allocator.alloc(geode.user_management.User, records.len);
    var initialized: usize = 0;
    errdefer {
        for (users[0..initialized]) |*user| {
            user.deinit(allocator);
        }
        allocator.free(users);
    }

    for (records) |record| {
        // NEW-8 residual (#860): skip reserved usernames at the bulk-list boundary
        // so geode-cluster cannot be injected into user_store via the list path.
        // Uses RESERVED_USERNAMES as the single source of truth.
        const is_reserved = blk: {
            for (geode.user_management.RESERVED_USERNAMES) |reserved| {
                if (std.mem.eql(u8, record.getUsername(), reserved)) break :blk true;
            }
            break :blk false;
        };
        if (is_reserved) continue;
        users[initialized] = try duplicatePersistentUser(allocator, store, record);
        initialized += 1;
    }

    if (initialized == records.len) return users;
    // Some reserved records were skipped — trim the allocation to the actual count.
    // On trim-alloc failure, the errdefer above cleans up users[0..initialized].
    const trimmed = try allocator.alloc(geode.user_management.User, initialized);
    @memcpy(trimmed, users[0..initialized]);
    allocator.free(users); // free the over-allocated array frame; strings are in trimmed
    return trimmed;
}
