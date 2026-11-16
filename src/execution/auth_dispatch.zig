/// Auth Dispatch Module
///
/// Handles routing for all `geode.auth.*` procedure calls.
/// Extracted from procedure_registry.zig as part of the procedure dispatch refactoring.
const std = @import("std");
const build_options = @import("build_options");
const crypto_backend = @import("crypto_backend");

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
const ast = @import("../gql/ast.zig");
const procedure_access = @import("procedure_access.zig");
const value_types = @import("../value_types.zig");

const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionError = execution.ExecutionError;
const ExecutionContext = execution.ExecutionContext;
// Task 9: fire schema-change notifications after GRANT/REVOKE so LSP
// SchemaProviders re-fetch the user's visible-graph/label set.
const schema_change_notifier = @import("schema_change_notifier.zig");

const Value = value_types.Value;

const user_mgmt = @import("../security/user_management.zig");
const geode_auth = @import("geode_auth");
const auth_ddl_lock = @import("../security/auth_ddl_lock.zig");
// SONNY-6586: the grant rule offline `geode grant` applies too.
const graph_grant_rules = @import("../security/graph_grant_rules.zig");
const mfa_mod = @import("mfa");
const cluster_mod = @import("../distributed/cluster.zig");

// GAP-0270: Global custom role store for geode.auth.role_create/role_list
pub var g_custom_roles: std.StringHashMap([]const u8) = undefined;
pub var g_custom_roles_init: bool = false;
pub var g_custom_roles_mu: std.Io.Mutex = std.Io.Mutex.init;

// SONNY-6292: there is no custom-role membership. `GRANT ROLE <custom role>`
// recorded the name in an in-memory side-table that DROP ROLE did not clear
// (a re-created role went back to its old members), that was never saved,
// and that no authorization path read (a custom role carries no
// privileges), and reported the grant: it is refused now
// (`error.CustomRoleMembershipNotSupported`, 0A000).

// CANARY: REQ=REQ-SONNY-6278-CUSTOM-ROLE-LIFETIME; FEATURE="GQL Auth DDL"; ASPECT=CustomRoleStoreOwnsMemory; STATUS=TESTED; TEST=tests/test_sonny6278_custom_role_lifetime.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6278: the allocator that owns the custom-role store (the table,
/// every key and every value). It outlives every request, so it is process-lifetime, as for the ABAC
/// attribute store (GAP-0284) and the user store's side-tables. They used
/// the allocator of whichever request (or the startup hydration) came
/// first, and copied names with the request's arena: once the request
/// ended the store held freed memory, which SHOW ROLES, role lookups,
/// GRANT ROLE and DROP ROLE then read.
var g_role_store_alloc: std.mem.Allocator = std.heap.c_allocator;

/// SONNY-6278: free the custom-role store with everything it owns (process
/// teardown, tests).
pub fn deinitCustomRoleStore() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const a = g_role_store_alloc;
    g_custom_roles_mu.lockUncancelable(io);
    defer g_custom_roles_mu.unlock(io);
    if (g_custom_roles_init) {
        var it = g_custom_roles.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        g_custom_roles.deinit();
        g_custom_roles_init = false;
    }
}

/// SONNY-6278: let a test own the custom-role store with its own allocator
/// (to check what DROP ROLE frees). Only while the store is empty
/// (`deinitCustomRoleStore` first).
pub fn setCustomRoleStoreAllocatorForTesting(a: std.mem.Allocator) void {
    std.debug.assert(!g_custom_roles_init);
    g_role_store_alloc = a;
}

// GAP-0270 / GPS Phase 4 (Task 4-4): g_policies replaced by policy_catalog.PolicyCatalog.
// The geode.auth.policy_* procedure handlers below now delegate to the global
// PolicyCatalog singleton (bootstrapped in server/main.zig at startup).
// The old StringHashMap fields are removed to avoid duplication.

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-019; FEATURE="AuthDDLPersistence"; ASPECT=RolePersistCallbacks; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
/// Callbacks for persisting role DDL to __geode_security. Wired at server
/// startup (P7) from code that can import auth_graph_manager. auth_dispatch.zig
/// is part of root_mod and cannot import auth_graph_manager directly (circular).
pub const RolePersistCallbacks = struct {
    ctx: ?*anyopaque = null,
    /// Create a role node (idempotent). Returns role id.
    create_fn: ?*const fn (ctx: ?*anyopaque, name: []const u8, description: []const u8) anyerror!u64 = null,
    /// Remove a role node by id.
    remove_fn: ?*const fn (ctx: ?*anyopaque, role_id: u64) anyerror!void = null,
    /// Find a role id by name. Returns null if not found.
    find_id_fn: ?*const fn (ctx: ?*anyopaque, name: []const u8) anyerror!?u64 = null,
    /// List all role entries as name/description pairs. Caller frees the slice.
    list_fn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]RoleEntry = null,
};

/// A single role entry returned by the list callback.
pub const RoleEntry = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
};

var g_role_persist: RolePersistCallbacks = .{};

/// Install role persistence callbacks. Called once at server startup from
/// server_init (after the AuthGraphManager is at its final location).
pub fn setRolePersistCallbacks(cb: RolePersistCallbacks) void {
    g_role_persist = cb;
}

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-026; FEATURE="AuthDDLPersistence"; ASPECT=GrantPersistCallbacks; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
/// Callbacks for persisting per-graph privilege grants to __geode_security and
/// the in-memory GraphRBACPolicy. Wired at server startup (P7) from code that
/// can import auth_graph_manager / multi_graph_security. auth_dispatch.zig is
/// part of root_mod and cannot import those modules directly (module diamond).
pub const GrantPersistCallbacks = struct {
    ctx: ?*anyopaque = null,
    /// Resolve a username to a graph User-node id. Returns null if unknown / not
    /// in server context (e.g. CLI or test without a live server).
    resolve_user_id_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8) ?u64 = null,
    /// Persist grants to the __geode_security graph and in-memory RBAC.
    /// actions: 0=read, 1=write, 2=schema. SONNY-1333: all of them or none;
    /// an error means nothing was granted.
    grant_fn: ?*const fn (ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, actions: []const u8) anyerror!void = null,
    /// Remove a grant from the in-memory RBAC and the __geode_security graph.
    /// Returns true if the grant was present and removed. SONNY-1333: the
    /// in-memory grant goes first; an error means the stored one remains.
    revoke_fn: ?*const fn (ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, action: u8) anyerror!bool = null,
    /// SONNY-1333: the user's stored grants, for SHOW GRANTS. The caller
    /// frees them with `freeGrantEntries`.
    list_fn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, user_id: u64) anyerror![]GrantEntry = null,
};

/// One stored per-graph grant (SONNY-1333, SHOW GRANTS).
pub const GrantEntry = struct {
    graph_name: []const u8,
    /// 0=read, 1=write, 2=schema
    action: u8,
};

/// `GrantEntry`s for stored grant records (anything with `getGraphName()`
/// and `action`), each graph name copied.
pub fn grantEntriesFrom(allocator: std.mem.Allocator, records: anytype) ![]GrantEntry {
    const out = try allocator.alloc(GrantEntry, records.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |e| allocator.free(e.graph_name);
        allocator.free(out);
    }
    for (records, 0..) |*r, i| {
        out[i] = .{ .graph_name = try allocator.dupe(u8, r.getGraphName()), .action = r.action };
        made = i + 1;
    }
    return out;
}

pub fn freeGrantEntries(allocator: std.mem.Allocator, entries: []GrantEntry) void {
    for (entries) |e| allocator.free(e.graph_name);
    allocator.free(entries);
}

var g_grant_persist: GrantPersistCallbacks = .{};

/// Install grant persistence callbacks. Called once at server startup from
/// server_init (after the AuthGraphManager is at its final location).
pub fn setGrantPersistCallbacks(cb: GrantPersistCallbacks) void {
    g_grant_persist = cb;
}

// GAP-0501/0502: Per-user MFA credential store for TOTP secrets and recovery codes.
// SONNY-6600: the recovery codes are held as SHA-256 digests
// (`mfa.hashRecoveryCode`), never in plaintext.
const MfaCredential = struct {
    secret_base32: []u8,
    recovery_codes: [][32]u8,
};

pub var g_mfa_store: std.StringHashMap(MfaCredential) = undefined;
pub var g_mfa_store_init: bool = false;
pub var g_mfa_store_mu: std.Io.Mutex = std.Io.Mutex.init;

// GAP-0502: Per-user MFA verify attempt rate limiter.
const MfaAttemptRecord = struct {
    fail_count: u32,
    last_attempt_ms: i64,
    lockout_until_ms: i64,
    /// SONNY-6619: the security graph holds a non-zero MfaAttempts record
    /// for the user (a lockout stored, or loaded at startup), so a success
    /// must store the reset.
    stored: bool = false,
};

/// SONNY-6619: an attempt state to store (`MfaPersistCallbacks.set_attempts_fn`).
pub const MfaAttemptsToStore = struct { fail_count: u32, lockout_until_ms: i64 };

// SONNY-6602: unmanaged, so the allocations of a new record can be routed
// through `mfaAttemptAllocator` (the test-only fault hook); everything is
// freed with `g_mfa_store_alloc`.
pub var g_mfa_attempts: std.StringHashMapUnmanaged(MfaAttemptRecord) = .empty;
pub var g_mfa_attempts_init: bool = false;

// CANARY: REQ=REQ-SONNY-6600-MFA-STORE-LIFETIME; FEATURE="MFA authentication"; ASPECT=StoreOwnsItsMemory; STATUS=TESTED; TEST=tests/test_sonny6600_mfa.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6600: the MFA store and the MFA attempt records live for the
/// process, so they allocate from a process allocator (as the custom-role
/// store, SONNY-6278). They were created with the allocator of the first
/// mfa_* request and kept it: a request-scoped allocator left the store in
/// freed memory once that request was answered.
const g_mfa_store_alloc: std.mem.Allocator = std.heap.c_allocator;

const MFA_MAX_ATTEMPTS: u32 = 5;
const MFA_LOCKOUT_MS: i64 = 300_000; // 5 minutes
/// SONNY-6614: the limit the offline `geode user mfa-verify` applies too.
pub const mfa_max_attempts = MFA_MAX_ATTEMPTS;
pub const mfa_lockout_ms = MFA_LOCKOUT_MS;

fn ensureMfaStoreInit() void {
    if (!g_mfa_store_init) {
        g_mfa_store = std.StringHashMap(MfaCredential).init(g_mfa_store_alloc);
        g_mfa_store_init = true;
    }
    if (!g_mfa_attempts_init) {
        g_mfa_attempts = .empty;
        g_mfa_attempts_init = true;
    }
}

/// SONNY-6602 test-only fault hook: the next `n` attempt records
/// `reserveMfaAttemptRecord` makes are made with an allocator that fails
/// every allocation, as under memory pressure. It can only make a
/// verification be refused, never verify one. Not compiled outside tests.
pub const mfa_attempt_fault_hook_available = @import("builtin").is_test;
var mfa_attempt_alloc_faults = std.atomic.Value(u32).init(0);

pub fn injectMfaAttemptAllocFailures(n: u32) error{FaultHookUnavailable}!void {
    if (comptime !mfa_attempt_fault_hook_available) return error.FaultHookUnavailable;
    mfa_attempt_alloc_faults.store(n, .release);
}

/// SONNY-6623 test-only: forget `username`'s in-memory attempt count, so a
/// test that checks one wrong code many times (SONNY-6600's re-enrollment
/// race) is not stopped by the lockout it is not testing. Not compiled
/// outside tests.
pub fn resetMfaAttemptsForTests(username: []const u8) error{FaultHookUnavailable}!void {
    if (comptime !mfa_attempt_fault_hook_available) return error.FaultHookUnavailable;
    g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    _ = clearMfaRateLimit(username);
}

/// The allocator a new attempt record is made with: the store's, or (fault
/// hook armed) one that fails.
fn mfaAttemptAllocator() std.mem.Allocator {
    if (comptime mfa_attempt_fault_hook_available) {
        var n = mfa_attempt_alloc_faults.load(.acquire);
        while (n > 0) {
            n = mfa_attempt_alloc_faults.cmpxchgWeak(n, n - 1, .acq_rel, .acquire) orelse return std.mem.Allocator.failing;
        }
    }
    return g_mfa_store_alloc;
}

fn freeMfaCredential(key: []const u8, cred: MfaCredential) void {
    crypto_backend.secureZero(cred.secret_base32);
    g_mfa_store_alloc.free(cred.secret_base32);
    g_mfa_store_alloc.free(cred.recovery_codes);
    g_mfa_store_alloc.free(key);
}

/// SONNY-6600: free the MFA store and the attempt records (process teardown,
/// tests).
pub fn deinitMfaStore() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_mfa_store_mu.lockUncancelable(io);
    defer g_mfa_store_mu.unlock(io);
    if (g_mfa_store_init) {
        var it = g_mfa_store.iterator();
        while (it.next()) |e| freeMfaCredential(e.key_ptr.*, e.value_ptr.*);
        g_mfa_store.deinit();
        g_mfa_store_init = false;
    }
    if (g_mfa_attempts_init) {
        var it = g_mfa_attempts.keyIterator();
        while (it.next()) |k| g_mfa_store_alloc.free(k.*);
        g_mfa_attempts.deinit(g_mfa_store_alloc);
        g_mfa_attempts = .empty;
        g_mfa_attempts_init = false;
    }
}

/// Store MFA credentials for a user, replacing any existing ones. The
/// recovery codes arrive as their digests (`mfa.hashRecoveryCode`).
fn storeMfaCredential(username: []const u8, secret_base32: []const u8, recovery_digests: []const [32]u8) !void {
    const a = g_mfa_store_alloc;
    const secret_copy = try a.dupe(u8, secret_base32);
    errdefer {
        crypto_backend.secureZero(secret_copy);
        a.free(secret_copy);
    }
    const digests = try a.dupe([32]u8, recovery_digests);
    errdefer a.free(digests);
    const key_copy = try a.dupe(u8, username);
    errdefer a.free(key_copy);

    g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureMfaStoreInit();
    try g_mfa_store.ensureUnusedCapacity(1);
    // Replace the old entry, if any.
    if (g_mfa_store.fetchRemove(username)) |old_kv| freeMfaCredential(old_kv.key, old_kv.value);
    g_mfa_store.putAssumeCapacityNoClobber(key_copy, .{
        .secret_base32 = secret_copy,
        .recovery_codes = digests,
    });
}

// CANARY: REQ=REQ-SONNY-6608-MFA-PERSIST-CALLBACKS; FEATURE="MFA authentication"; ASPECT=EnrollmentWriteThrough; STATUS=TESTED; TEST=tests/test_sonny6608_mfa_persist.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6608: how the mfa_* procedures store what they change in
/// `__geode_security` (`auth_startup_hydration.mfaPersistCallbacks`,
/// installed by `server_init.wireAuthDDLCallbacks`). Each is all or nothing;
/// an error means nothing was changed, and the procedure is refused. Unset
/// (no auth graph, as in unit tests) the procedures change process memory
/// only, as grants do.
pub const MfaPersistCallbacks = struct {
    ctx: ?*anyopaque = null,
    /// Store `username`'s enrollment (secret, recovery-code digests) with
    /// MFA turned off until a code verifies against it.
    enroll_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, secret_base32: []const u8, recovery_digests: []const [32]u8) anyerror!void = null,
    /// Set `username`'s stored `mfa_enabled`.
    set_enabled_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, enabled: bool) anyerror!void = null,
    /// SONNY-6619: store `username`'s attempt state (MfaAttempts).
    set_attempts_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, fail_count: u32, lockout_until_ms: i64) anyerror!void = null,
};

var g_mfa_persist: MfaPersistCallbacks = .{};

/// SONNY-6614: SecurityManager's copy of the users' MFA state
/// (`auth_startup_hydration.securityManagerHooks`, installed by
/// `server_init` once SecurityManager is at its final address). Unset: no
/// SecurityManager.
pub const SecurityManagerHooks = struct {
    ctx: ?*anyopaque = null,
    /// SONNY-6619: remove `username` and everything held for it (DROP USER;
    /// SONNY-6614 cleared its MFA state only).
    remove_user_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8) void = null,
    /// SONNY-6619: `username`'s new enrollment (mfa_setup): secret, recovery
    /// code digests, MFA off.
    load_mfa_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, secret: []const u8, digests: []const [32]u8) anyerror!void = null,
    /// SONNY-6619: `username`'s MFA flag (mfa_enable / mfa_disable).
    set_mfa_enabled_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, enabled: bool) void = null,
};

var g_sm_hooks: SecurityManagerHooks = .{};

pub fn setSecurityManagerHooks(h: SecurityManagerHooks) void {
    g_sm_hooks = h;
}

pub fn setMfaPersistCallbacks(cb: MfaPersistCallbacks) void {
    g_mfa_persist = cb;
}

/// SONNY-6608: load a stored enrollment into the MFA store (startup,
/// `auth_startup_hydration.hydrateMfaEnrollments`).
pub fn loadMfaEnrollment(username: []const u8, secret_base32: []const u8, recovery_digests: []const [32]u8) !void {
    try storeMfaCredential(username, secret_base32, recovery_digests);
}

/// SONNY-6608: forget `username`'s enrollment and attempt record (DROP
/// USER): a user made again under the name is not enrolled.
pub fn forgetMfaEnrollment(username: []const u8) void {
    g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (g_mfa_store_init) {
        if (g_mfa_store.fetchRemove(username)) |kv| freeMfaCredential(kv.key, kv.value);
    }
    if (g_mfa_attempts_init) {
        if (g_mfa_attempts.fetchRemove(username)) |kv| g_mfa_store_alloc.free(kv.key);
    }
}

// CANARY: REQ=REQ-SONNY-6600-MFA-SECRET-COPY; FEATURE="MFA authentication"; ASPECT=SecretCopiedUnderLock; STATUS=TESTED; TEST=tests/test_sonny6600_mfa.zig; OWNER=security; UPDATED=2026-11-15
/// Look up a user's stored MFA secret (base32). Returns null if not enrolled.
/// SONNY-6600: a copy taken under the store's lock (it returned a slice of
/// the store after releasing the lock, which a re-enrollment frees); the
/// caller zeroes and frees it with `freeMfaSecret`.
fn getMfaSecret(allocator: std.mem.Allocator, username: []const u8) !?[]u8 {
    g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!g_mfa_store_init) return null;
    const cred = g_mfa_store.get(username) orelse return null;
    return try allocator.dupe(u8, cred.secret_base32);
}

fn freeMfaSecret(allocator: std.mem.Allocator, secret: []u8) void {
    crypto_backend.secureZero(secret);
    allocator.free(secret);
}

/// Check rate limiting on MFA verify attempts. Returns true if locked out.
fn checkMfaRateLimit(username: []const u8, now_ms: i64) bool {
    if (!g_mfa_attempts_init) return false;
    const rec = g_mfa_attempts.get(username) orelse return false;
    return now_ms < rec.lockout_until_ms;
}

// CANARY: REQ=REQ-SONNY-6602-MFA-LIMITER-FAIL-CLOSED; FEATURE="MFA authentication"; ASPECT=AttemptRecordBeforeCheck; STATUS=TESTED; TEST=tests/test_sonny6602_mfa.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6602: make `username`'s attempt record, if it has none, before its
/// code is checked. A record that cannot be made refuses the verification
/// (AuthUnavailable, 53000): a check that could not be counted toward the
/// lockout is not run. Counting the failure afterwards (`recordMfaFailure`)
/// then allocates nothing. The record was made after a failed check, and an
/// allocation failure there was logged and the attempt left uncounted: the
/// limiter failed open. Caller holds `g_mfa_store_mu`.
fn reserveMfaAttemptRecord(username: []const u8) error{AuthUnavailable}!void {
    ensureMfaStoreInit();
    if (g_mfa_attempts.contains(username)) return;
    const a = mfaAttemptAllocator();
    const key = a.dupe(u8, username) catch return mfaAttemptRecordUnavailable(username);
    // A key from the failing allocator is never made, so a key always
    // belongs to `g_mfa_store_alloc`.
    g_mfa_attempts.put(a, key, .{
        .fail_count = 0,
        .last_attempt_ms = 0,
        .lockout_until_ms = 0,
    }) catch {
        g_mfa_store_alloc.free(key);
        return mfaAttemptRecordUnavailable(username);
    };
}

fn mfaAttemptRecordUnavailable(username: []const u8) error{AuthUnavailable} {
    log.err("geode.auth.mfa_verify refused: the MFA attempt record could not be made, so the attempt could not be counted toward the lockout", &.{Attr.string("user", username)});
    return error.AuthUnavailable;
}

/// Record a failed MFA attempt; lock out after MFA_MAX_ATTEMPTS. The record
/// is the one `reserveMfaAttemptRecord` made before the check (SONNY-6602).
/// Caller holds `g_mfa_store_mu`.
/// SONNY-6619: the state to store when this failure locks the user out (the
/// transition into lockout), else null: a failure below the limit is
/// counted in memory only.
fn recordMfaFailure(username: []const u8, now_ms: i64) error{AuthUnavailable}!?MfaAttemptsToStore {
    // The record is gone only if the store was torn down mid-check: make it
    // again, or refuse.
    try reserveMfaAttemptRecord(username);
    const rec = g_mfa_attempts.getPtr(username).?;
    const new_count = rec.fail_count +| 1;
    const locks = new_count >= MFA_MAX_ATTEMPTS;
    rec.* = .{
        .fail_count = new_count,
        .last_attempt_ms = now_ms,
        .lockout_until_ms = if (locks) now_ms + MFA_LOCKOUT_MS else 0,
        .stored = rec.stored or locks,
    };
    if (!locks) return null;
    return .{ .fail_count = rec.fail_count, .lockout_until_ms = rec.lockout_until_ms };
}

/// Reset the attempt record on successful verification. SONNY-6602: the
/// record is kept (reset), so the user's next failure is counted without an
/// allocation.
/// SONNY-6619: true when the stored record must be reset too (the
/// transition out of a stored lockout or count).
fn clearMfaRateLimit(username: []const u8) bool {
    if (!g_mfa_attempts_init) return false;
    const rec = g_mfa_attempts.getPtr(username) orelse return false;
    const was_stored = rec.stored;
    rec.* = .{
        .fail_count = 0,
        .last_attempt_ms = 0,
        .lockout_until_ms = 0,
        .stored = false,
    };
    return was_stored;
}

// CANARY: REQ=REQ-SONNY-6619-SERVER-LOCKOUT-STORED; FEATURE="MFA authentication"; ASPECT=LockoutSurvivesRestart; STATUS=TESTED; TEST=tests/test_sonny6619_mfa_limits.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6619: load a stored MfaAttempts record (startup,
/// `auth_startup_hydration.hydrateMfaEnrollments`): a lockout survives a
/// restart. The count also loads (the offline commands store every attempt).
pub fn loadMfaAttempts(username: []const u8, fail_count: u32, lockout_until_ms: i64) !void {
    g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    try reserveMfaAttemptRecord(username);
    const rec = g_mfa_attempts.getPtr(username).?;
    rec.* = .{
        .fail_count = fail_count,
        .last_attempt_ms = 0,
        .lockout_until_ms = lockout_until_ms,
        .stored = fail_count != 0 or lockout_until_ms != 0,
    };
}

/// SONNY-6619: store `to_store` for `username` (outside `g_mfa_store_mu`:
/// the write-through takes graph locks). A lockout that cannot be stored
/// still holds in this process; it is logged, as is a reset that cannot be
/// stored (the stored lockout then outlives a restart: fail closed).
fn storeMfaAttempts(username: []const u8, to_store: MfaAttemptsToStore) void {
    const f = g_mfa_persist.set_attempts_fn orelse return;
    f(g_mfa_persist.ctx, username, to_store.fail_count, to_store.lockout_until_ms) catch |err| {
        log.err("geode.auth.mfa_verify/mfa_enable: the MFA attempt state could not be stored in the security graph", &.{ Attr.string("user", username), Attr.string("error", @errorName(err)) });
    };
}

/// Build a space-separated string from recovery code slices.
fn buildRecoveryStr(allocator: std.mem.Allocator, codes: [][]u8) ![]u8 {
    var total_len: usize = 0;
    for (codes, 0..) |code, idx| {
        if (idx > 0) total_len += 1; // space separator
        total_len += code.len;
    }
    const buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (codes, 0..) |code, idx| {
        if (idx > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + code.len], code);
        pos += code.len;
    }
    return buf;
}

fn ensureRolesInit() void {
    if (!g_custom_roles_init) {
        g_custom_roles = std.StringHashMap([]const u8).init(g_role_store_alloc);
        g_custom_roles_init = true;
    }
}

/// Returns true if `name` matches one of the four built-in role names
/// (case-insensitive). Used to prevent CREATE ROLE from shadowing built-ins
/// and to deduplicate SHOW ROLES output.
pub fn isBuiltinRoleName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "admin") or
        std.ascii.eqlIgnoreCase(name, "user") or
        std.ascii.eqlIgnoreCase(name, "readwrite") or
        std.ascii.eqlIgnoreCase(name, "readonly");
}

// ensurePoliciesInit removed — GPS Phase 4 (Task 4-4) delegates to policy_catalog.

// ---------------------------------------------------------------------------
// StaticStringMap dispatch table -- O(1) lookup replaces sequential if-else chain.
// ---------------------------------------------------------------------------
const AuthHandler = *const fn (std.mem.Allocator, []const u8, ast.CallProcedure, ExecutionContext) anyerror!ExecutionResult;

const dispatch_table = std.StaticStringMap(AuthHandler).initComptime(.{
    .{ "geode.auth.user_create", handleUserCreate },
    // ENG-3979: pre-computed-hash migration import (offline `geode user
    // import`'s wire counterpart — the offline path is refused by the
    // ENG-3921 data-dir lock while a server owns the directory).
    .{ "geode.auth.user_import", handleUserImport },
    .{ "geode.auth.user_list", handleUserList },
    .{ "geode.auth.user_delete", handleUserDelete },
    .{ "geode.auth.user_show", handleUserShow },
    .{ "geode.auth.user_enable", handleUserEnableDisable },
    .{ "geode.auth.user_disable", handleUserEnableDisable },
    .{ "geode.auth.user_assign_role", handleUserAssignRole },
    // #832: ABAC attribute mutators -- ALTER USER ... SET/REMOVE ATTRIBUTE.
    .{ "geode.auth.user_set_attribute", handleUserSetAttribute },
    .{ "geode.auth.user_remove_attribute", handleUserRemoveAttribute },
    .{ "geode.auth.user_permissions", handleUserPermissions },
    .{ "geode.auth.user_change_password", handleUserChangePassword },
    .{ "geode.auth.user_reset_password", handleUserResetPassword },
    .{ "geode.auth.mfa_setup", handleMfaSetup },
    .{ "geode.auth.mfa_verify", handleMfaVerify },
    .{ "geode.auth.role_create", handleRoleCreate },
    .{ "geode.auth.role_delete", handleRoleDelete },
    .{ "geode.auth.role_list", handleRoleList },
    .{ "geode.auth.policy_create", handlePolicyCreate },
    .{ "geode.auth.policy_list", handlePolicyList },
    .{ "geode.auth.policy_delete", handlePolicyDelete },
    .{ "geode.auth.grant", handleGrantRevoke },
    .{ "geode.auth.revoke", handleGrantRevoke },
    .{ "geode.auth.grant_list", handleGrantList },
    // SONNY-6291: not supported (no server-side key store).
    .{ "geode.auth.apikey_create", handleApikeyNotSupported },
    .{ "geode.auth.apikey_list", handleApikeyNotSupported },
    .{ "geode.auth.apikey_revoke", handleApikeyNotSupported },
    .{ "geode.auth.apikey_check_scope", handleApikeyNotSupported },
    .{ "geode.auth.mfa_enable", handleMfaEnableDisable },
    .{ "geode.auth.mfa_disable", handleMfaEnableDisable },
});

const read_only_set = std.StaticStringMap(void).initComptime(.{
    .{ "geode.auth.user_show", {} },
    // SONNY-6269: any user, for itself; another user's need Admin (checked
    // in the handler, as grant_list's).
    .{ "geode.auth.user_permissions", {} },
    .{ "geode.auth.user_list", {} },
    .{ "geode.auth.role_list", {} },
    .{ "geode.auth.policy_list", {} },
    // SONNY-1333: any user, for itself; another user's grants need Admin
    // (checked in the handler).
    .{ "geode.auth.grant_list", {} },
    .{ "geode.auth.apikey_list", {} },
    .{ "geode.auth.apikey_check_scope", {} },
});

// SONNY-2751: the geode.auth.* procedures that skip the Admin check here are
// exactly the ones `procedure_access` classifies read-only (the read-only
// floors, the lock and the write gate go by that list). `geode.auth.grant_list`
// was in this set only, so a read-only request could not call it.
comptime {
    @setEvalBranchQuota(100_000);
    for (read_only_set.keys()) |name| {
        if (procedure_access.classifyProcedureName(name) != .read_only)
            @compileError("SONNY-2751: " ++ name ++ " is read-only here but not in procedure_access.read_only_procedure_names");
    }
    for (procedure_access.read_only_procedure_names) |name| {
        if (std.mem.startsWith(u8, name, "geode.auth.") and !read_only_set.has(name))
            @compileError("SONNY-2751: " ++ name ++ " is read-only in procedure_access but needs Admin in auth_dispatch.read_only_set");
    }
}

/// Execute a geode.auth.* procedure. Returns null if not recognized.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    if (std.mem.startsWith(u8, proc_name, "geode.auth.")) {
        if (user_mgmt.isAuthEnabled()) {
            // Phase C2: this is the REAL RBAC decision point for geode.auth.*
            // admin procedures — the role check below grants or denies access.
            // Emit geode.security.authorization.check.* with the bounded
            // decision (allow/deny) + policy_type (rbac) + measured latency.
            // Only reached when auth is enabled (a genuine decision is made).
            const om = @import("otel_metrics");
            const audit_mod = @import("../security/audit.zig");
            const duration = om.DurationTimer.start();
            if (context.role == null) {
                const d = duration.seconds();
                om.recordAuthzCheck(.deny, .rbac, d);
                // CANARY: REQ=REQ-GAP-0919-DENIED-DDL-AUDIT; FEATURE="AuditDenials"; ASPECT=UnauthenticatedAuthDDL; STATUS=TESTED; TEST=tests/test_gap0919_denied_ddl_audit.zig; OWNER=security; UPDATED=2026-07-10
                // GAP-0919: denied escalation attempts were an audit blind
                // spot — the gate returned before any audit path ran.
                audit_mod.logSecurityGraphEvent(allocator, .{
                    .event_type = .access_denied,
                    .action = proc_name,
                    .username = context.user orelse "",
                    .details = "auth procedure denied: unauthenticated",
                    .result_failure = true,
                });
                return error.Unauthenticated;
            }
            const is_read_only = read_only_set.has(proc_name);
            if (!is_read_only and context.role.? != .Admin) {
                const d = duration.seconds();
                om.recordAuthzCheck(.deny, .rbac, d);
                // GAP-0919: audit the denial (see above).
                audit_mod.logSecurityGraphEvent(allocator, .{
                    .event_type = .access_denied,
                    .action = proc_name,
                    .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
                    .username = context.user orelse "",
                    .details = "auth procedure denied: admin role required",
                    .result_failure = true,
                });
                return error.Unauthorized;
            }
            const d = duration.seconds();
            om.recordAuthzCheck(.allow, .rbac, d);
        }

        // Cluster fail-closed: auth state persists to the per-node
        // __geode_security graph with no Raft slice — an ungated mutation
        // creates users/roles/grants on exactly ONE node (a security-relevant
        // divergence). Reads (user_list/role_list/user_show/...) stay open.
        // Covers the direct CALL geode.auth.* route; the auth DDL route
        // (admin_ddl.zig) gates at its own entry points and double-fires here
        // via callAuthProcedure — identical error, harmless.
        // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateAuthProcedures; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
        if (!read_only_set.has(proc_name)) try cluster_mod.gateUnreplicatedWrite();

        // SONNY-6329: one security change at a time, its write-through and
        // undo included (auth_ddl_lock.zig has the lock order).
        const ddl_guard: ?auth_ddl_lock.Guard = if (read_only_set.has(proc_name)) null else auth_ddl_lock.acquire();
        defer if (ddl_guard) |g| g.release();

        if (dispatch_table.get(proc_name)) |handler| {
            return try handler(allocator, proc_name, call_stmt, context);
        }

        // SONNY-6291: every other geode.auth.apikey_* (it answered "ok").
        if (std.mem.startsWith(u8, proc_name, "geode.auth.apikey_")) {
            return try handleApikeyNotSupported(allocator, proc_name, call_stmt, context);
        }

        return ExecutionError.UnknownProcedure;
    }

    return null;
}

// ===========================================================================
// Handler functions -- extracted from the former if-else dispatch chain.
// ===========================================================================

// CANARY: REQ=REQ-SONNY-6345-AUTH-RESULT-OWNERSHIP; FEATURE="GQL Auth DDL"; ASPECT=StatusRowsOwned; STATUS=TESTED; TEST=tests/test_sonny6345_auth_cli_and_grant.zig; OWNER=security; UPDATED=2026-11-12
// SONNY-6345: this handler's result, and those of user_delete,
// user_enable / user_disable, user_assign_role, user_change_password,
// user_reset_password, grant and revoke, own their status rows
// (`owns_value_memory`, the username copied): a caller that frees the
// result with a general-purpose allocator leaked them.
fn handleUserCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_create(username, password, email[, role]) -> status
    var username: []const u8 = "";
    var password: []const u8 = "";
    var email: []const u8 = "";
    var role_str: []const u8 = "user";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) password = args[1].String;
        if (args.len >= 3 and args[2].* == .String) email = args[2].String;
        if (args.len >= 4 and args[3].* == .String) role_str = args[3].String;
    }

    // GAP-0154: Handle auto-generated passwords from CLI --generate-password flag.
    // SONNY-6331: generated to meet the password policy.
    var generated_pw: [geode_auth.max_password_length]u8 = undefined;
    var actual_password = password;
    if (std.mem.eql(u8, password, "auto_generated_password_placeholder")) {
        actual_password = try geode_auth.PasswordPolicy.geodeSecure().generate(&generated_pw);
    }

    // CANARY: REQ=REQ-SONNY-6331-ONE-PASSWORD-POLICY; FEATURE="Unified Password Policy Validation"; ASPECT=CreateUserPolicy; STATUS=TESTED; TEST=tests/test_sonny6331_password_policy_paths.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6331: the password policy (user_management.createUser applies
    // it; a refusal is an error status, 22000, naming the rule). This
    // applied an older rule: 8 characters, a letter and a digit.
    const role = user_mgmt.Role.fromString(role_str) orelse .User;
    // SONNY-6359: every failure is an error status (a duplicate 42710, a
    // reserved name 42939, a failed save 58030); the others answered 00000
    // with a status row "error: <name>".
    user_mgmt.createUser(allocator, username, actual_password, email, role, false) catch |err| {
        log.warn("geode.auth.user_create failed", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    // Include generated_password column when password was auto-generated
    const is_generated = std.mem.eql(u8, password, "auto_generated_password_placeholder");
    const num_cols: usize = if (is_generated) 3 else 2;
    const columns = try allocator.alloc([]const u8, num_cols);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "username");
    if (is_generated) columns[2] = try allocator.dupe(u8, "generated_password");
    const row = try allocator.alloc(Value, num_cols);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "created {s}", .{username}) };
    row[1] = Value{ .Str = try allocator.dupe(u8, username) };
    if (is_generated) row[2] = Value{ .Str = try allocator.dupe(u8, actual_password) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// CANARY: REQ=REQ-AUTH-USER-IMPORT-002; FEATURE="AdminUserImport"; ASPECT=WireProcedure; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/authn_blake2b_migration.yml; OWNER=security; UPDATED=2026-08-30
/// `geode.auth.user_import(username, hash[, algorithm][, email][, role])`
///
/// Server-side counterpart of the offline `geode user import` subcommand
/// (`src/cli/user_mgmt_cli.zig`). Seeds a principal with a PRE-COMPUTED
/// password hash — the migration path for importing users out of a legacy
/// store — instead of hashing a plaintext password.
///
/// Why it exists (ENG-3979): the offline path opens the data dir read-write,
/// so ENG-3921's data-dir lock correctly refuses it while a server is running.
/// An operator migrating users into a LIVE server had no route at all. This
/// procedure is that route, and it carries the same posture as every other
/// mutating `geode.auth.*` entry point: admin-only (not in `read_only_set`),
/// cluster fail-closed via `gateUnreplicatedWrite`, and persisted through the
/// AuthGraphManager write-through into the HMAC-chained `__geode_security`
/// graph (`createUserWithHash` -> `persistent_writer.create_fn`).
///
/// The hash is stored VERBATIM — no re-hashing, and no format validation
/// beyond non-emptiness, exactly like the offline path. The login verifies an
/// Argon2id PHC string or a legacy BLAKE2b hash (`user_management.verifyPassword`,
/// SONNY-6367); a stored hash in neither format never authenticates, so an
/// unusable import is fail-closed, never fail-open. SONNY-6598: the login
/// answers such a user a server-side credential error, not "Authentication
/// failed", and does not count it toward the lockout.
fn handleUserImport(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var username: []const u8 = "";
    var hash: []const u8 = "";
    var algorithm: []const u8 = "argon2id";
    var email: []const u8 = "";
    var role_str: []const u8 = "user";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) hash = args[1].String;
        if (args.len >= 3 and args[2].* == .String and args[2].String.len > 0) algorithm = args[2].String;
        if (args.len >= 4 and args[3].* == .String) email = args[3].String;
        if (args.len >= 5 and args[4].* == .String and args[4].String.len > 0) role_str = args[4].String;
    }

    // SONNY-6367: every refusal is an error status (an argument 22023, an
    // existing user 42710, FIPS 0A000); they answered 00000 with a status
    // row "error: <message>".
    if (username.len == 0 or hash.len == 0) return error.InvalidArgs;
    // Same accepted set as the offline import (user_mgmt_cli.zig).
    if (!std.mem.eql(u8, algorithm, "argon2id") and !std.mem.eql(u8, algorithm, "blake2b")) {
        return error.InvalidArgs;
    }
    // FIPS parity with the offline path: neither primitive is FIPS-approved.
    if (build_options.fips) return error.FipsUnsupported;
    // Import refuses to overwrite — a silent credential replacement on an
    // existing principal is an account-takeover primitive.
    if (user_mgmt.getUser(username) != null) return error.UserAlreadyExists;

    const role = user_mgmt.Role.fromString(role_str) orelse .User;
    user_mgmt.createUserWithHash(allocator, username, hash, email, role, false) catch |err| {
        log.warn("geode.auth.user_import failed", &.{Attr.string("error", @errorName(err))});
        // SONNY-3038: not saved, so not imported.
        return err;
    };

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "username");
    columns[2] = try allocator.dupe(u8, "algorithm");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Str = try allocator.dupe(u8, "imported successfully") };
    row[1] = Value{ .Str = try allocator.dupe(u8, username) };
    row[2] = Value{ .Str = try allocator.dupe(u8, algorithm) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    // SONNY-6377: the result owns the strings it copied (they leaked).
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// CANARY: REQ=REQ-SONNY-6312-USER-LIST-OWNERSHIP; FEATURE="GQL Auth DDL"; ASPECT=UserListOwnsRows; STATUS=TESTED; TEST=tests/test_sonny6312_user_list_ownership.zig; OWNER=security; UPDATED=2026-11-12
fn handleUserList(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_list() -> username, email, role, active
    // SONNY-6312: the listing is a copy this request owns (it leaked the
    // store's snapshot array on every call and its rows borrowed the store's
    // strings, which a concurrent DROP USER freed). A listing that cannot be
    // made is an error, not an empty list.
    const users = try user_mgmt.listUsers(allocator);
    defer allocator.free(users);
    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "username");
    columns[1] = try allocator.dupe(u8, "email");
    columns[2] = try allocator.dupe(u8, "role");
    columns[3] = try allocator.dupe(u8, "active");
    var rows_list = std.ArrayList([]Value).empty;
    for (users) |user| {
        const row = try allocator.alloc(Value, 4);
        // The row takes the copied strings over.
        row[0] = Value{ .Str = user.username };
        row[1] = Value{ .Str = user.email };
        row[2] = Value{ .Str = try allocator.dupe(u8, user.role.toString()) };
        row[3] = Value{ .Bool = user.active };
        try rows_list.append(allocator, row);
    }
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// CANARY: REQ=REQ-SONNY-6609-USER-DELETE-ERRORS; FEATURE="GQL Auth DDL"; ASPECT=DropUserReportsErrors; STATUS=TESTED; TEST=tests/test_sonny6609_mfa_at_rest.zig; OWNER=security; UPDATED=2026-11-15
fn handleUserDelete(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_delete(username) -> status
    var username: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
    }
    // SONNY-6609: every failure is an error status. Only UserNotPersisted
    // was (SONNY-3038); a user that does not exist (deleteUser's
    // Unauthenticated) and any other error answered "deleted <name>".
    // No such user: 42704 for an Admin (42501 otherwise), as the other
    // geode.auth.* procedures; DROP USER IF EXISTS answers it as a no-op.
    user_mgmt.deleteUser(username) catch |err| {
        log.warn("geode.auth.user_delete failed", &.{ Attr.string("user", username), Attr.string("error", @errorName(err)) });
        if (err == error.Unauthenticated) return missingUser(allocator, proc_name, context);
        return err;
    };
    // SONNY-6608: the user's MFA enrollment goes with it (the stored one
    // with the user record); a user made again under the name is not
    // enrolled.
    forgetMfaEnrollment(username);
    // SONNY-6614 / SONNY-6619: and SecurityManager's copy of the user,
    // removed entirely (it kept the dropped user, its secret and codes).
    if (g_sm_hooks.remove_user_fn) |f| f(g_sm_hooks.ctx, username);
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "username");
    const row = try allocator.alloc(Value, 2);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted {s}", .{username}) };
    row[1] = Value{ .Str = try allocator.dupe(u8, username) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// CANARY: REQ=REQ-SONNY-6291-APIKEY-USER-SHOW; FEATURE="GQL Auth DDL"; ASPECT=UserShowSelfOrAdmin; STATUS=TESTED; TEST=tests/test_sonny6291_apikey_user_show.zig; OWNER=security; UPDATED=2026-11-12
fn handleUserShow(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_show([username]) -> username, email, role, status.
    // Without a username, the caller's. SONNY-6291: another user's needs the
    // Admin role (SONNY-6269's rule; 42501, audited): any authenticated user
    // read any user's email, role and status.
    const username = targetUserOrSelf(call_stmt, context);
    try requireSelfOrAdmin(allocator, proc_name, context, username, "auth procedure denied: admin role required to show another user");
    // SONNY-6312: a copy this request owns (it borrowed the store's strings,
    // which a concurrent DROP USER freed). SONNY-6291: a user that does not
    // exist is an error; a row was made up for it (unknown / user / active).
    const user = try user_mgmt.getUserSummary(allocator, username) orelse return missingUser(allocator, proc_name, context);
    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "username");
    columns[1] = try allocator.dupe(u8, "email");
    columns[2] = try allocator.dupe(u8, "role");
    columns[3] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Str = user.username };
    row[1] = Value{ .Str = user.email };
    row[2] = Value{ .Str = try allocator.dupe(u8, user.role.toString()) };
    row[3] = Value{ .Str = try allocator.dupe(u8, if (user.active) "active" else "disabled") };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

fn handleUserEnableDisable(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_enable/disable(username) -> status, username
    var username: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
    }
    const is_enable = std.mem.eql(u8, proc_name, "geode.auth.user_enable");
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "username");
    const row = try allocator.alloc(Value, 2);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    // CANARY: REQ=REQ-AUTH-GRANT-PERSIST-029; FEATURE="GQL Auth DDL Persistence"; ASPECT=UserEnableDisable; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-05-12
    // Mutate + persist the active flag.
    user_mgmt.setUserActive(allocator, username, is_enable) catch |err| switch (err) {
        // SONNY-6367: setUserActive answers error.Unauthenticated when no
        // such user is stored (it loads a stored user that is not cached):
        // 42704 for an Admin (SONNY-6291's rule). It answered "enabled X".
        error.Unauthenticated => {
            freeStatusScaffold(allocator, columns, row, rows);
            return missingUser(allocator, proc_name, context);
        },
        // SONNY-3038: the change could not be saved (a disable is enforced
        // by locking the user out).
        error.UserNotPersisted => {
            for (columns) |c| allocator.free(c);
            allocator.free(columns);
            allocator.free(row);
            allocator.free(rows);
            return err;
        },
        // SONNY-6359: any other failure (the security graph could not be
        // read) is an error status; it answered 00000 with an "error:" row.
        else => {
            log.warn("geode.auth.user_enable/disable failed", &.{
                Attr.string("username", username),
                Attr.string("error", @errorName(err)),
            });
            freeStatusScaffold(allocator, columns, row, rows);
            return err;
        },
    };
    row[0] = Value{ .Str = if (is_enable)
        try std.fmt.allocPrint(allocator, "enabled {s}", .{username})
    else
        try std.fmt.allocPrint(allocator, "disabled {s}", .{username}) };
    row[1] = Value{ .Str = try allocator.dupe(u8, username) };
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

fn handleUserAssignRole(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_assign_role(username, role) -> status
    var username: []const u8 = "";
    var role_name: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) role_name = args[1].String;
    }

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    // SONNY-6359: the failures below are error statuses; they answered 00000
    // with a status row "error: ...".
    if (username.len == 0 or role_name.len == 0) {
        freeStatusScaffold(allocator, columns, row, rows);
        return error.InvalidArgs;
    }

    // Try built-in roles first.
    if (user_mgmt.Role.fromString(role_name)) |builtin_role| {
        user_mgmt.assignRole(allocator, username, builtin_role) catch |err| {
            // SONNY-3038: the change could not be saved (a downgrade is
            // enforced by locking the user out).
            freeStatusScaffold(allocator, columns, row, rows);
            // No such user: 42704 for an Admin (SONNY-6291's rule).
            if (err == error.Unauthenticated) return missingUser(allocator, proc_name, context);
            return err;
        };
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "assigned {s} to {s}", .{ role_name, username }) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
    }

    // CANARY: REQ=REQ-SONNY-6292-CUSTOM-ROLE-GRANT-REFUSED; FEATURE="GQL Auth DDL"; ASPECT=CustomRoleGrantRefused; STATUS=TESTED; TEST=tests/test_sonny6292_custom_role_membership.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6292: a custom role cannot be granted to a user. It carries no
    // privileges (CREATE ROLE stores a name and a description; GRANT ... ON
    // GRAPH grants to users), so a membership would confer nothing; the
    // statement is refused (0A000) instead of reporting a grant. It answered
    // "assigned custom role" and kept the name in an in-memory side-table
    // that was never saved, survived DROP ROLE and was read by nothing.
    const is_custom = blk: {
        g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
        ensureRolesInit();
        break :blk g_custom_roles.contains(role_name);
    };
    if (is_custom) {
        allocator.free(row);
        allocator.free(rows);
        allocator.free(columns[0]);
        allocator.free(columns);
        return error.CustomRoleMembershipNotSupported;
    }
    // #835: unknown role must NOT silently retain the prior role. Free the
    // pre-allocated success-row scaffolding and return a Zig error so the
    // CLI exits non-zero and any caller's transactional logic aborts.
    allocator.free(row);
    allocator.free(rows);
    allocator.free(columns[0]);
    allocator.free(columns);
    return error.UnknownRole;
}

// #832 / GAP-0284: ABAC user-attribute store. Storage lives in
// src/security/user_attribute_store.zig so that the security layer
// (principal_derive, gps.decide) can read the same side-table without
// importing execution/.
const user_attr_store = @import("user_attr_store");

/// Public accessor for ABAC policy evaluation. Returns the attribute map
/// for `username`, or null if no attributes are set. The map is owned by
/// the side-table; callers must not free.
pub fn getUserAttributes(username: []const u8) ?*const std.StringHashMap([]const u8) {
    return user_attr_store.get(username);
}

fn handleUserSetAttribute(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    var username: []const u8 = "";
    var key: []const u8 = "";
    var value: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) key = args[1].String;
        if (args.len >= 3 and args[2].* == .String) value = args[2].String;
    }
    // SONNY-6367: no username or key (22023), no such user (42704 for an
    // Admin) are error statuses; they answered 00000 with an "error:" row.
    if (username.len == 0 or key.len == 0) return error.InvalidArgs;
    if (user_mgmt.getUser(username) == null) return missingUser(allocator, proc_name, context);
    // SONNY-6369: the reply is built first, so a failed allocation leaves
    // the attribute unchanged, and the result owns it (it leaked).
    const status = try std.fmt.allocPrint(allocator, "set attribute {s}={s} for {s}", .{ key, value, username });
    var reply = try statusResult(allocator, status);
    errdefer reply.deinit(allocator);
    try user_attr_store.setAttribute(allocator, username, key, value);
    return reply;
}

// CANARY: REQ=REQ-SONNY-6369-USER-ATTRIBUTE-RESULTS; FEATURE="GQL Auth DDL"; ASPECT=RemoveAttributeErrors; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
// SONNY-6369: missing arguments (22023), a user that does not exist (42704
// for an Admin) and an attribute that is not set (42704) are errors; the last
// answered 00000 with "attribute ... not set on ...", and none of the
// results owned their rows.
fn handleUserRemoveAttribute(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    var username: []const u8 = "";
    var key: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) key = args[1].String;
    }
    if (username.len == 0 or key.len == 0) return error.InvalidArgs;
    if (user_mgmt.getUser(username) == null) return missingUser(allocator, proc_name, context);
    const status = try std.fmt.allocPrint(allocator, "removed attribute {s} from {s}", .{ key, username });
    var reply = try statusResult(allocator, status);
    errdefer reply.deinit(allocator);
    if (!user_attr_store.removeAttribute(username, key, allocator)) return error.UserAttributeNotSet;
    return reply;
}

/// A one-row `status` result that owns `status` (allocated with
/// `allocator`) and everything else it holds; `status` is freed on failure.
fn statusResult(allocator: std.mem.Allocator, status: []const u8) !ExecutionResult {
    errdefer allocator.free(status);
    const columns = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(columns);
    columns[0] = try allocator.dupe(u8, "status");
    errdefer allocator.free(columns[0]);
    const row = try allocator.alloc(Value, 1);
    errdefer allocator.free(row);
    const rows = try allocator.alloc([]Value, 1);
    row[0] = Value{ .Str = status };
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// CANARY: REQ=REQ-SONNY-6269-PERMISSIONS-ADMIN-GATE; FEATURE="GQL Auth DDL"; ASPECT=UserPermissionsGate; STATUS=TESTED; TEST=tests/test_sonny6269_permissions_admin_gate.zig; OWNER=security; UPDATED=2026-11-11
fn handleUserPermissions(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_permissions([username]) -> permission list. Without a
    // username, the caller's. SONNY-6269: another user's need the Admin role
    // (as SHOW GRANTS, SONNY-1333); any authenticated user listed anyone's.
    const username = targetUserOrSelf(call_stmt, context);
    try requireSelfOrAdmin(allocator, proc_name, context, username, "auth procedure denied: admin role required to list another user's permissions");
    // SONNY-6291: a user that does not exist is an error; it was answered
    // with the `user` role's permissions. The caller asking about itself
    // with no stored record (a session principal the user store does not
    // hold) gets its session's role, the permissions it actually has.
    const own = if (context.user) |u| std.mem.eql(u8, u, username) else false;
    const role: user_mgmt.Role = if (user_mgmt.getUser(username)) |u|
        u.role
    else if (own and context.role != null)
        context.role.?
    else
        return missingUser(allocator, proc_name, context);
    const perms = user_mgmt.Permission.fromRole(role);
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "username");
    columns[1] = try allocator.dupe(u8, "permission");
    var rows_list = std.ArrayList([]Value).empty;
    for (perms) |p| {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, username) };
        // Output permission names in lowercase to match CLI conventions
        const tag = @tagName(p);
        const lower = try allocator.alloc(u8, tag.len);
        _ = std.ascii.lowerString(lower, tag);
        row[1] = Value{ .Str = lower };
        try rows_list.append(allocator, row);
    }
    // SONNY-6312: the result owns its strings (each permission name leaked).
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

fn handleUserChangePassword(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_change_password(username, old_password, new_password) -> status
    var username: []const u8 = "";
    var old_pw: []const u8 = "";
    var new_pw: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) old_pw = args[1].String;
        if (args.len >= 3 and args[2].* == .String) new_pw = args[2].String;
    }
    // Verify old password before changing (old_pw used for authentication).
    // Bug 731 (same family) / MULTI_TENANCY_AUDIT_REPORT S6: a FAILED
    // verification used to be logged and then ignored, so the change went
    // through anyway and the caller was told "Password changed". Propagate.
    // CANARY: REQ=REQ-SONNY-6359-CHANGE-PASSWORD-OLD-REQUIRED; FEATURE="GQL Auth DDL"; ASPECT=OldPasswordAlwaysChecked; STATUS=TESTED; TEST=tests/test_sonny6359_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6359: always, an empty old password included (it skipped the
    // check, so '' changed any user's password); a reset without the old
    // password is user_reset_password.
    _ = user_mgmt.authenticate(username, old_pw) catch |err| {
        log.warn("geode.auth.user_change_password: old password verification failed", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    // Bug 731 (same family): a failed password update used to be swallowed and
    // still reported "Password changed for <user>" — a silent success on a
    // failed change. Propagate so the caller sees the failure.
    user_mgmt.updateUserPassword(allocator, username, new_pw) catch |err| {
        log.warn("geode.auth.user_change_password failed", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "Password changed for {s}", .{username}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

fn handleUserResetPassword(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.user_reset_password(username, new_password) -> status
    var username: []const u8 = "";
    var new_pw: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) new_pw = args[1].String;
    }
    // Bug 731 (same family): a failed reset used to be swallowed and still
    // reported "Password reset for <user>". This is also the GQL-parser route
    // for `ALTER USER <u> SET PASSWORD` (admin_ddl.executeAlterUser), which the
    // wire intercept shadows — both must agree, and both must fail honestly.
    // The durable `password_reset_required` clear happens in
    // AuthGraphManager.updateUserPassword, which this path reaches through the
    // user_management persistent writer.
    user_mgmt.updateUserPassword(allocator, username, new_pw) catch |err| {
        log.warn("geode.auth.user_reset_password failed", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "Password reset for {s}", .{username}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// CANARY: REQ=REQ-SONNY-6602-MFA-NOT-ENFORCED-WARNING; FEATURE="MFA authentication"; ASPECT=ProcedureWarning; STATUS=TESTED; TEST=tests/test_sonny6602_mfa.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6602: MFA is not enforced at login. HELLO (QUIC and gRPC) never
/// asks for a TOTP code or a recovery code, and nothing redeems the recovery
/// codes mfa_setup issues; wiring MFA into login is SONNY-6604. mfa_setup
/// and mfa_enable answer this in a `warning` column, next to the secret and
/// the codes, so no operator takes an enrollment for a protected login.
pub const mfa_setup_not_enforced_warning = "MFA is not enforced at login yet (SONNY-6604): HELLO does not ask for a TOTP code or a recovery code, so this enrollment protects no login, and no procedure redeems these recovery codes. geode.auth.mfa_verify only checks a code when it is called.";
pub const mfa_enable_not_enforced_warning = "MFA is not enforced at login yet (SONNY-6604): the code was checked against the user's TOTP secret, but HELLO does not ask for one, so the user's logins are not protected by MFA.";

fn handleMfaSetup(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.mfa_setup(username, opts) -> MFA secret, recovery codes, provisioning URI
    var username: []const u8 = "";
    var opts: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) opts = args[1].String;
    }
    // SONNY-6367: no such user (42704 for an Admin) and a failed enrollment
    // or store are error statuses; they answered 00000 with an "error" row.
    if (user_mgmt.getUser(username) == null) return missingUser(allocator, proc_name, context);
    // GAP-0501: Generate cryptographically random per-user TOTP secret via mfa.enroll().
    // Generates 20 random bytes via std.crypto.random, base32-encodes, produces 8 recovery codes.
    var enrollment = mfa_mod.enroll(allocator, username) catch |err| {
        log.warn("geode.auth.mfa_setup enrollment failed", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    defer mfa_mod.freeEnrollment(allocator, &enrollment);

    const digests = try allocator.alloc([32]u8, enrollment.scratch_codes.len);
    defer allocator.free(digests);
    for (enrollment.scratch_codes, digests) |code, *d| d.* = mfa_mod.hashRecoveryCode(code);

    // SONNY-6608: stored first (secret, recovery-code digests, MFA off until
    // a code verifies), then the in-memory store; a store that fails refuses
    // the enrollment and changes nothing.
    if (g_mfa_persist.enroll_fn) |f| {
        f(g_mfa_persist.ctx, username, enrollment.secret_base32, digests) catch |err| {
            log.err("geode.auth.mfa_setup could not store the enrollment in the security graph; refused", &.{ Attr.string("user", username), Attr.string("error", @errorName(err)) });
            return error.MfaChangeNotPersisted;
        };
    }
    // Store per-user secret and recovery codes for later TOTP verification
    storeMfaCredential(username, enrollment.secret_base32, digests) catch |err| {
        log.warn("geode.auth.mfa_setup could not store the credential", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    // SONNY-6619: SecurityManager's copy follows (it kept the old state).
    // The enrollment is stored; a copy that cannot be updated (out of
    // memory) is turned off instead, so the old secret cannot pass there.
    if (g_sm_hooks.load_mfa_fn) |f| f(g_sm_hooks.ctx, username, enrollment.secret_base32, digests) catch |err| {
        log.err("geode.auth.mfa_setup: SecurityManager's copy of the MFA state could not be updated; MFA turned off there", &.{ Attr.string("user", username), Attr.string("error", @errorName(err)) });
        if (g_sm_hooks.set_mfa_enabled_fn) |off| off(g_sm_hooks.ctx, username, false);
    };

    const secret = enrollment.secret_base32;
    const recovery_str = try buildRecoveryStr(allocator, enrollment.scratch_codes);
    defer allocator.free(recovery_str);
    const show_uri = std.mem.indexOf(u8, opts, "show-uri") != null;
    if (show_uri) {
        return ownedRow(allocator, &.{ "provisioning_uri", "secret", "warning" }, &.{ enrollment.provisioning_uri, secret, mfa_setup_not_enforced_warning });
    }
    // Default and show-recovery / regenerate: the secret and recovery codes.
    const secret_text = try std.fmt.allocPrint(allocator, "MFA secret: {s}", .{secret});
    defer allocator.free(secret_text);
    const codes_text = try std.fmt.allocPrint(allocator, "Recovery codes: {s}", .{recovery_str});
    defer allocator.free(codes_text);
    return ownedRow(allocator, &.{ "mfa_secret", "recovery_codes", "warning" }, &.{ secret_text, codes_text, mfa_setup_not_enforced_warning });
}

/// SONNY-6609: DROP USER IF EXISTS of a user that does not exist: nothing
/// dropped, said so.
pub fn dropUserAbsentResult(allocator: std.mem.Allocator, username: []const u8) !ExecutionResult {
    const status = try std.fmt.allocPrint(allocator, "no user {s}; nothing dropped", .{username});
    defer allocator.free(status);
    return ownedRow(allocator, &.{ "status", "username" }, &.{ status, username });
}

// CANARY: REQ=REQ-SONNY-6608-MFA-RESULT-OWNERSHIP; FEATURE="MFA authentication"; ASPECT=ResultOwnsValues; STATUS=TESTED; TEST=tests/test_sonny6608_mfa_persist.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6608: a one-row result that owns everything in it (columns and
/// values copied, `owns_value_memory` set), so the result's deinit frees it.
/// The mfa_* results did not own their strings: over gRPC each call leaked
/// them, and mfa_setup its recovery-code buffer.
fn ownedRow(allocator: std.mem.Allocator, names: []const []const u8, values: []const []const u8) !ExecutionResult {
    std.debug.assert(names.len == values.len);
    var result: ExecutionResult = .{
        .columns = try allocator.alloc([]const u8, names.len),
        .rows = &.{},
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
    var made_cols: usize = 0;
    errdefer {
        for (result.columns[0..made_cols]) |c| allocator.free(c);
        allocator.free(result.columns);
    }
    for (names, 0..) |n, i| {
        result.columns[i] = try allocator.dupe(u8, n);
        made_cols = i + 1;
    }
    const row = try allocator.alloc(Value, values.len);
    var made_vals: usize = 0;
    errdefer {
        for (row[0..made_vals]) |v| allocator.free(v.Str);
        allocator.free(row);
    }
    for (values, 0..) |v, i| {
        row[i] = .{ .Str = try allocator.dupe(u8, v) };
        made_vals = i + 1;
    }
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    result.rows = rows;
    return result;
}

// CANARY: REQ=REQ-SONNY-6623-SHARED-MFA-LIMITER; FEATURE="MFA authentication"; ASPECT=OneLimiterForEveryCodeCheck; STATUS=TESTED; TEST=tests/test_sonny6623_mfa_enable_limit.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6623: who checks a code (`limitedMfaCodeCheck`).
const MfaCodeCheck = enum { verify, enable };

/// Check `token` against `username`'s stored TOTP secret under the MFA
/// attempt limiter (GAP-0502, SONNY-6602, SONNY-6619), for mfa_verify and
/// mfa_enable alike (SONNY-6623: mfa_enable had no limit): one per-user
/// count and lockout, the attempt record made before the check, the
/// transitions into and out of a stored lockout written through.
///
/// - locked out: MfaRateLimited (53400), nothing checked;
/// - not enrolled: MfaNotEnrolled (55000), not counted (no secret to guess
///   against) - for mfa_enable a malformed code is still InvalidArgs (22023);
/// - a malformed code (not six digits) is a wrong code, counted; mfa_enable
///   answers it InvalidArgs (22023), mfa_verify false (28000);
/// - a check that could not run (MFA turned off, an unusable secret, out of
///   memory) is that error, not counted (SONNY-6598).
///
/// True when the code verifies.
fn limitedMfaCodeCheck(allocator: std.mem.Allocator, username: []const u8, token: []const u8, who: MfaCodeCheck) !bool {
    const now_ms = compat_milliTimestamp();
    {
        g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
        ensureMfaStoreInit();
        if (checkMfaRateLimit(username, now_ms)) return error.MfaRateLimited;
        // SONNY-6602: the record this attempt is counted in exists before
        // the code is checked, or the attempt is refused.
        try reserveMfaAttemptRecord(username);
    }

    const well_formed = isSixDigitCode(token);
    const stored_secret = (try getMfaSecret(allocator, username)) orelse {
        if (who == .enable and !well_formed) return error.InvalidArgs;
        return error.MfaNotEnrolled;
    };
    defer freeMfaSecret(allocator, stored_secret);

    var is_valid = false;
    if (well_formed) {
        const code = std.fmt.parseInt(u32, token, 10) catch unreachable; // six digits
        // HMAC-SHA1 TOTP with +/-1 window (90s tolerance)
        // CANARY: REQ=REQ-SONNY-6598-MFA-VERIFY-ERRORS; FEATURE="AuthOutcomeClassification"; ASPECT=MfaVerifyErrors; STATUS=TESTED; TEST=tests/test_sonny6598_verify_outcomes.zig; OWNER=security; UPDATED=2026-11-15
        // SONNY-6598: a check the server could not run (MFA turned off, an
        // unusable stored secret, out of memory) is that error, not counted
        // toward the MFA lockout. It was `catch false`: 28000 "invalid
        // code", counted.
        is_valid = mfa_mod.verifyCode(allocator, stored_secret, @as(u64, @intCast(now_ms)), code, 30, 6, 1) catch |err| {
            log.err("geode.auth.mfa_* : the TOTP check could not run; not counted as a failed attempt", &.{ Attr.string("user", username), Attr.string("error", @errorName(err)) });
            return err;
        };
    }

    // SONNY-6619: the transitions into lockout and out of a stored state
    // are stored (after the lock is released); a failure below the limit is
    // counted in memory only, so a guess does not cost a chain seal.
    var to_store: ?MfaAttemptsToStore = null;
    {
        g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
        if (is_valid) {
            if (clearMfaRateLimit(username)) to_store = .{ .fail_count = 0, .lockout_until_ms = 0 };
        } else {
            to_store = try recordMfaFailure(username, now_ms);
        }
    }
    if (to_store) |st| storeMfaAttempts(username, st);

    if (!well_formed and who == .enable) return error.InvalidArgs;
    return is_valid;
}

fn handleMfaVerify(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // GAP-0502: geode.auth.mfa_verify(username, token) -> status
    // Implements RFC 6238 TOTP validation with rate limiting.
    var username: []const u8 = "";
    var token: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) token = args[1].String;
    }

    // SONNY-6367: every outcome but "verified" is an error status: no such
    // user (42704 for an Admin), locked out (53400), not enrolled (55000), a
    // code that does not verify (28000). They answered 00000 with a status
    // row ("rate_limited", "mfa_not_enrolled", "invalid token"), which a
    // caller that checks the status read as a pass.
    if (user_mgmt.getUser(username) == null) return missingUser(allocator, proc_name, context);

    // SONNY-6623: the check is the limiter shared with mfa_enable.
    const is_valid = try limitedMfaCodeCheck(allocator, username, token, .verify);
    if (!is_valid) return error.InvalidMfaCode;

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "username");
    const row = try allocator.alloc(Value, 2);
    row[0] = Value{ .Str = "verified" };
    row[1] = Value{ .Str = username };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleRoleCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.role_create(role_name, description) -> status
    var role_name: []const u8 = "";
    var desc: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) role_name = args[0].String;
        if (args.len >= 2 and args[1].* == .String) desc = args[1].String;
    }
    // SONNY-6367: no name is an error status (22023); it answered 00000
    // with an "error:" row.
    if (role_name.len == 0) return error.InvalidArgs;
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    // Built-in role names are idempotent — acknowledge without touching g_custom_roles.
    if (isBuiltinRoleName(role_name)) {
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "already exists: {s} (built-in)", .{role_name}) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
    }

    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit();
    // error-policy: C — the procedure reports "created"; a failed in-memory
    // registration must propagate instead of lying to the client (and the
    // dupes must not leak on the error path).
    // SONNY-6278: the store owns its key and value (g_role_store_alloc),
    // not this request's allocator. Re-creating a role replaces its
    // description and keeps its key.
    const store_alloc = g_role_store_alloc;
    const desc_copy = try store_alloc.dupe(u8, desc);
    const gop = g_custom_roles.getOrPut(role_name) catch |err| {
        store_alloc.free(desc_copy);
        return err;
    };
    const previous_desc: ?[]const u8 = if (gop.found_existing) gop.value_ptr.* else null;
    if (!gop.found_existing) {
        gop.key_ptr.* = store_alloc.dupe(u8, role_name) catch |err| {
            g_custom_roles.removeByPtr(gop.key_ptr);
            store_alloc.free(desc_copy);
            return err;
        };
    }
    gop.value_ptr.* = desc_copy;
    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-021; FEATURE="AuthDDLPersistence"; ASPECT=RoleCreatePersist; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
    // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=CreateRoleFailureReported; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
    // SONNY-3038: a role that could not be saved is not created (as CREATE
    // USER, SONNY-1333). It was logged and reported created, and was gone at
    // the next start.
    if (g_role_persist.create_fn) |f| {
        _ = f(g_role_persist.ctx, role_name, desc) catch |e| {
            log.warn("role_create graph persist failed; the role was not created", &.{ Attr.string("role", role_name), Attr.string("error", @errorName(e)) });
            // The store as it was: a role held before keeps its description.
            if (previous_desc) |old| {
                g_custom_roles.getPtr(role_name).?.* = old;
            } else if (g_custom_roles.fetchRemove(role_name)) |kv| {
                store_alloc.free(kv.key);
            }
            store_alloc.free(desc_copy);
            allocator.free(columns[0]);
            allocator.free(columns);
            allocator.free(row);
            allocator.free(rows);
            return error.RoleNotPersisted;
        };
    }
    if (previous_desc) |old| store_alloc.free(old);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "created {s}", .{role_name}) };
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

fn handleRoleDelete(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var role_name: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) role_name = args[0].String;
    }
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit();
    // SONNY-6278: the store's key and description are freed (they leaked).
    if (g_custom_roles.fetchRemove(role_name)) |kv| {
        g_role_store_alloc.free(kv.key);
        g_role_store_alloc.free(kv.value);
    }
    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-022; FEATURE="AuthDDLPersistence"; ASPECT=RoleDeletePersist; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
    // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=DropRoleFailClosed; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
    // SONNY-3038: the role goes from memory first (fail closed, as REVOKE);
    // a stored record that could not be removed fails the call
    // (`RoleNotPersisted`): it is loaded again at the next start unless DROP
    // ROLE is retried. It was logged and reported deleted.
    if (!isBuiltinRoleName(role_name)) {
        if (g_role_persist.find_id_fn) |find_f| {
            const rid_opt = find_f(g_role_persist.ctx, role_name) catch |e| {
                log.warn("role_delete graph lookup failed", &.{ Attr.string("role", role_name), Attr.string("error", @errorName(e)) });
                return error.RoleNotPersisted;
            };
            if (rid_opt) |rid| {
                if (g_role_persist.remove_fn) |rem_f| {
                    rem_f(g_role_persist.ctx, rid) catch |e| {
                        log.warn("role_delete graph persist failed; the stored role remains", &.{ Attr.string("role", role_name), Attr.string("error", @errorName(e)) });
                        return error.RoleNotPersisted;
                    };
                }
            }
        }
    }
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted {s}", .{role_name}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

fn handleRoleList(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.role_list() -> role_name (built-in + custom)
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "role_name");
    const builtin_roles = [_][]const u8{ "admin", "user", "readwrite", "readonly" };
    var rows_list = std.ArrayList([]Value).empty;
    for (builtin_roles) |rn| {
        const row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Str = try allocator.dupe(u8, rn) };
        try rows_list.append(allocator, row);
    }
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit();
    var it = g_custom_roles.iterator();
    while (it.next()) |entry| {
        // Defensive dedup: skip any custom entry whose name collides with a built-in
        // (guards against state left over before hardening was in place).
        if (isBuiltinRoleName(entry.key_ptr.*)) continue;
        const row = try allocator.alloc(Value, 1);
        // SONNY-6312: copied under the lock; the row borrowed the store's
        // key, which a DROP ROLE frees.
        row[0] = Value{ .Str = try allocator.dupe(u8, entry.key_ptr.*) };
        try rows_list.append(allocator, row);
    }
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// GPS Phase 4 (Task 4-4): geode.auth.policy_* procedures now delegate to the
// global PolicyCatalog singleton (mirrors the GQL DDL path via execution.zig).
// The old g_policies StringHashMap is removed.
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=AuthDispatchPolicyCreate; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
fn handlePolicyCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // Positional: (name, table, condition).  table defaults to "*" (any
    // graph/table) and condition defaults to "true" (allow everything).
    // #831: the handler used to ignore args[1]/args[2] and always install
    //       expression_source="true" with scope_graph="*".  Now both are
    //       honored.
    var name: []const u8 = "";
    var table: []const u8 = "*";
    var condition: []const u8 = "true";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) name = args[0].String;
        if (args.len >= 2 and args[1].* == .String and args[1].String.len > 0) table = args[1].String;
        if (args.len >= 3 and args[2].* == .String and args[2].String.len > 0) condition = args[2].String;
    }

    // #833: reject pathological condition strings before they reach the
    // expression compiler.  The crash was reproducible with a `;` (and
    // likely other syntax-significant chars) embedded in the condition;
    // root cause was unknown but the safe action is to refuse anything
    // that doesn't look like an expression.  Allowed chars: alnum, space,
    // and the operators that valid GPS expressions need.
    for (condition) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == ' ' or c == '_' or c == '.' or
            c == '=' or c == '!' or c == '<' or c == '>' or
            c == '(' or c == ')' or c == ',' or
            c == '+' or c == '-' or c == '*' or c == '/' or
            c == '\'' or c == '"' or c == '?';
        if (!ok) {
            const ec = try allocator.alloc([]const u8, 1);
            ec[0] = try allocator.dupe(u8, "error");
            const er = try allocator.alloc(Value, 1);
            er[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "invalid character {x:0>2} in condition; refusing to install (see #833)", .{c}) };
            const ers = try allocator.alloc([]Value, 1);
            ers[0] = er;
            return .{ .columns = ec, .rows = ers, .flags = std.ArrayList([]const u8).empty };
        }
    }

    // SONNY-2757 (P26): the checks and the write-through of CREATE POLICY
    // (`policy_ddl.create`). This used the tolerant `addPolicy`: no length
    // limits, a condition that does not compile installed fail-closed, and
    // nothing persisted, so the policy was gone at the next restart. With no
    // catalog it reported success and created nothing.
    const policy_catalog_mod = @import("../security/policy_catalog.zig");
    const pol_cat = policy_catalog_mod.getGlobalCatalog() orelse return error.PolicyCatalogNotInitialized;
    const actions = [_]policy_catalog_mod.Action{.read};
    try execution.policy_ddl.create(pol_cat, .{
        .name = name,
        .scope_graph = table,
        .actions = &actions,
        .effect = .allow,
        .expression_source = condition,
        .enabled = true,
    });
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "policy created {s} on {s}", .{ name, table }) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=AuthDispatchPolicyList; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
fn handlePolicyList(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    const policy_catalog_mod = @import("../security/policy_catalog.zig");
    // SONNY-2732: `valid` is false for a stored policy whose expression no
    // longer compiles (kept fail-closed until rewritten).
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "scope_graph");
    columns[2] = try allocator.dupe(u8, "valid");
    var rows_list = std.ArrayList([]Value).empty;
    if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
        // SONNY-2756: copied under a shared hold of the catalog.
        const view = pol_cat.acquireRead();
        defer view.release();
        for (view.policies()) |*pol| {
            const row = try allocator.alloc(Value, 3);
            row[0] = Value{ .Str = try allocator.dupe(u8, pol.name) };
            row[1] = Value{ .Str = try allocator.dupe(u8, pol.scope_graph) };
            row[2] = Value{ .Bool = policy_catalog_mod.PolicyCatalog.policyIsValid(pol) };
            try rows_list.append(allocator, row);
        }
    }
    // The result owns its duplicated strings (they were leaked before).
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

// CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=AuthDispatchPolicyDelete; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
fn handlePolicyDelete(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var name: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) name = args[0].String;
    }
    const policy_catalog_mod = @import("../security/policy_catalog.zig");
    if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
        // Idempotent: a missing policy is not an error. SONNY-2757: the stored
        // record goes first, as for DROP POLICY (`policy_ddl.drop`); the
        // procedure used to drop the policy from the catalog only, and it came
        // back at the next restart.
        _ = try execution.policy_ddl.drop(pol_cat, name, true);
    }
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted policy {s}", .{name}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-027; FEATURE="AuthDDLPersistence"; ASPECT=HandleGrantRevoke; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
fn handleGrantRevoke(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    var perm: []const u8 = "";
    var target: []const u8 = "";
    var resource: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) perm = args[0].String;
        if (args.len >= 2 and args[1].* == .String) target = args[1].String;
        if (args.len >= 3 and args[2].* == .String) resource = args[2].String;
    }
    const is_grant = std.mem.eql(u8, proc_name, "geode.auth.grant");

    // Build the single-column result we always return.
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    // CANARY: REQ=REQ-SONNY-6359-AUTH-FAILURES-ARE-ERRORS; FEATURE="GQL Auth DDL"; ASPECT=GrantRevokeRefusals; STATUS=TESTED; TEST=tests/test_sonny6359_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6359: no resource: there is no global per-privilege grant model
    // (global privilege is the user's role), so it is refused (0A000) with
    // nothing changed. It answered 00000 with a "note:" status row.
    graph_grant_rules.checkGraph(resource, is_grant) catch |err| {
        freeStatusScaffold(allocator, columns, row, rows);
        return err;
    };
    // CANARY: REQ=REQ-SONNY-3135-GRANT-WILDCARD-REFUSED; FEATURE="GQL Auth DDL"; ASPECT=GrantOnStarRefused; STATUS=TESTED; TEST=tests/test_sonny3135_policy_cache_keys_grant_wildcard.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-3135 (N7d): a per-graph grant is matched by the graph a request
    // is on, and a request on `*` matches none, so a grant on graph `*`
    // conferred nothing and was reported granted (before the 2026-10 grant
    // rework a restart turned it into a wildcard policy). Refused (0A000),
    // nothing stored. A revoke of `*` still runs, to remove such a grant an
    // older release stored.
    // (graph_grant_rules.checkGraph, above.)

    // Action codes 0=read, 1=write, 2=schema (graph_grant_rules.actionsOf).
    // SONNY-6359: an unknown privilege is an error status (22023); it
    // answered 00000 with a row "error: unknown privilege".
    const actions = graph_grant_rules.actionsOf(perm) orelse {
        freeStatusScaffold(allocator, columns, row, rows);
        return error.UnknownPrivilege;
    };

    // Resolve target username -> user_id via callback (null in CLI / test contexts).
    // CANARY: REQ=REQ-SONNY-6345-GRANT-MISSING-USER; FEATURE="GQL Auth DDL"; ASPECT=GrantMissingUserIsError; STATUS=TESTED; TEST=tests/test_sonny6345_auth_cli_and_grant.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6345: a user that does not exist is an error, 42704 for an Admin
    // (SONNY-6291's rule; only an Admin reaches here with authorization on).
    // It answered SQLSTATE 00000 with a row "error: user not found". With no
    // security graph to resolve users in, nothing can be granted or revoked.
    const uid = blk: {
        if (g_grant_persist.resolve_user_id_fn) |f| {
            if (f(g_grant_persist.ctx, target)) |id| break :blk id;
            freeStatusScaffold(allocator, columns, row, rows);
            return missingUser(allocator, proc_name, context);
        }
        freeStatusScaffold(allocator, columns, row, rows);
        return if (is_grant) error.GrantNotPersisted else error.RevokeNotPersisted;
    };

    // CANARY: REQ=REQ-SONNY-3038-REVOKE-DURABLE; FEATURE="GQL Auth DDL Persistence"; ASPECT=RevokeFailureReported; STATUS=TESTED; TEST=tests/test_sonny3038_revoke_and_schema_ddl.zig; OWNER=security; UPDATED=2026-09-27
    // SONNY-3038: a revoke that could not be saved fails the call
    // (`RevokeNotPersisted`). It reported "Revoked", and the privilege came
    // back at the next start.
    // CANARY: REQ=REQ-SONNY-1333-GRANT-PERSIST-FAIL-CLOSED; FEATURE="GQL Auth DDL Persistence"; ASPECT=GrantFailureReported; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
    // SONNY-1333: and a grant that could not be saved fails the call
    // (`GrantNotPersisted`) having granted nothing: the callback adds every
    // action or none. It logged the failure and reported "Granted". With no
    // persistence callback installed nothing can be saved, and the call fails.
    var persist_failure: ?anyerror = null;
    // SONNY-6647: whether the revoke took away a privilege the user held.
    var held = false;
    if (is_grant) {
        if (g_grant_persist.grant_fn) |f| {
            f(g_grant_persist.ctx, uid, resource, actions) catch |e| {
                log.warn("grant persist failed; nothing was granted", &.{
                    Attr.string("err", @errorName(e)),
                    Attr.string("user", target),
                    Attr.string("graph", resource),
                });
                persist_failure = e;
            };
        } else persist_failure = error.NoGrantPersistence;
    } else if (g_grant_persist.revoke_fn) |f| {
        // Every action is attempted; each revoke takes its privilege away
        // in memory first, so a failed save leaves nothing in force.
        for (actions) |action| {
            const was_held = f(g_grant_persist.ctx, uid, resource, action) catch |e| {
                log.warn("revoke persist failed", &.{
                    Attr.string("err", @errorName(e)),
                    Attr.string("user", target),
                    Attr.string("graph", resource),
                    Attr.uint("action", @as(u64, action)),
                });
                if (persist_failure == null) persist_failure = e;
                continue;
            };
            held = held or was_held;
        }
    } else persist_failure = error.NoGrantPersistence;

    if (persist_failure != null) {
        // The in-memory RBAC state may have moved; tell the LSP providers.
        schema_change_notifier.notify();
        freeStatusScaffold(allocator, columns, row, rows);
        return if (is_grant) error.GrantNotPersisted else error.RevokeNotPersisted;
    }
    // CANARY: REQ=REQ-SONNY-6647-REVOKE-NOT-HELD; FEATURE="GQL Auth DDL"; ASPECT=RevokeOfNothingRefused; STATUS=TESTED; TEST=tests/test_sonny6647_revoke_not_held.zig; OWNER=security; UPDATED=2026-11-15
    // SONNY-6647: a revoke that took nothing away (the user holds none of
    // the privileges on the graph) is refused (42704), as offline `geode
    // revoke` refuses it. It answered "Revoked ..." whatever was held.
    if (!is_grant and !held) {
        freeStatusScaffold(allocator, columns, row, rows);
        return error.GrantNotHeld;
    }

    // Return the status row with wording the geodetestlab spec asserts.
    // grant uses "to", revoke uses "from" — matches the existing spec assertions.
    row[0] = Value{ .Str = if (is_grant)
        try std.fmt.allocPrint(allocator, "Granted {s} on {s} to {s}", .{ perm, resource, target })
    else
        try std.fmt.allocPrint(allocator, "Revoked {s} on {s} from {s}", .{ perm, resource, target }) };

    // Task 9: a grant/revoke changes which graphs a user can see, which
    // changes the LSP SchemaProvider's user-visible label/edge-type set.
    schema_change_notifier.notify();

    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

/// Free a status result's columns, row and rows that an error path does not
/// return (the row holds no value yet).
fn freeStatusScaffold(allocator: std.mem.Allocator, columns: [][]const u8, row: []Value, rows: [][]Value) void {
    for (columns) |c| allocator.free(c);
    allocator.free(columns);
    allocator.free(row);
    allocator.free(rows);
}

/// The user a read-only procedure about one user's security state is asked
/// about: its first argument, or the caller when there is none (or it is
/// empty).
fn targetUserOrSelf(call_stmt: ast.CallProcedure, context: ExecutionContext) []const u8 {
    var username: []const u8 = context.user orelse "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String and args[0].String.len > 0) username = args[0].String;
    }
    return username;
}

// CANARY: REQ=REQ-SONNY-6269-PERMISSIONS-ADMIN-GATE; FEATURE="GQL Auth DDL"; ASPECT=SelfOrAdminGate; STATUS=TESTED; TEST=tests/test_sonny6269_permissions_admin_gate.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-1333 / SONNY-6269: the gate of the read-only procedures that list
/// one user's security state (`grant_list`, `user_permissions`). With
/// authorization on, a user may ask about itself; about another user only
/// with the Admin role. A refusal answers error.Unauthorized (42501) and is
/// audited as the admin-only procedures' are. (An unauthenticated request
/// never gets here: `execute` refuses it first.)
fn requireSelfOrAdmin(allocator: std.mem.Allocator, proc_name: []const u8, context: ExecutionContext, username: []const u8, details: []const u8) !void {
    if (!user_mgmt.isAuthEnabled()) return;
    const own = if (context.user) |u| std.mem.eql(u8, u, username) else false;
    const is_admin = if (context.role) |r| r == .Admin else false;
    if (own or is_admin) return;
    const audit_mod = @import("../security/audit.zig");
    audit_mod.logSecurityGraphEvent(allocator, .{
        .event_type = .access_denied,
        .action = proc_name,
        .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
        .username = context.user orelse "",
        .details = details,
        .result_failure = true,
    });
    return error.Unauthorized;
}

/// SONNY-6291: the answer of a one-user read procedure about a user that does
/// not exist. An Admin is told so (`error.UserNotFound`, 42704). Anyone else
/// gets what `requireSelfOrAdmin` answers about another user (42501,
/// audited): a non-admin can only be asking about itself here, and must not
/// learn more from a missing user than from a forbidden one.
fn missingUser(allocator: std.mem.Allocator, proc_name: []const u8, context: ExecutionContext) anyerror {
    const is_admin = if (context.role) |r| r == .Admin else false;
    if (is_admin or !user_mgmt.isAuthEnabled()) return error.UserNotFound;
    const audit_mod = @import("../security/audit.zig");
    audit_mod.logSecurityGraphEvent(allocator, .{
        .event_type = .access_denied,
        .action = proc_name,
        .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
        .username = context.user orelse "",
        .details = "auth procedure denied: no such user",
        .result_failure = true,
    });
    return error.Unauthorized;
}

// CANARY: REQ=REQ-SONNY-1333-SHOW-GRANTS; FEATURE="GQL Auth DDL"; ASPECT=GrantListProcedure; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
/// `geode.auth.grant_list([username])` -> username, graph, action: the user's
/// per-graph grants as stored in __geode_security, one row per grant, by
/// graph then action (SONNY-1333; `SHOW GRANTS` reads it). Without a username,
/// the caller's own. Read-only, so any authenticated user may call it, but
/// for itself only: another user's grants need the Admin role, and a refusal
/// is audited as the admin-only procedures' are.
fn handleGrantList(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    const username = targetUserOrSelf(call_stmt, context);
    try requireSelfOrAdmin(allocator, proc_name, context, username, "auth procedure denied: admin role required to list another user's grants");

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "username");
    columns[1] = try allocator.dupe(u8, "graph");
    columns[2] = try allocator.dupe(u8, "action");
    var rows_list = std.ArrayList([]Value).empty;

    const uid_opt: ?u64 = if (username.len == 0) null else if (g_grant_persist.resolve_user_id_fn) |f| f(g_grant_persist.ctx, username) else null;
    // No such user, or no security graph (CLI / tests): no stored grants.
    if (uid_opt) |uid| {
        const list = g_grant_persist.list_fn orelse return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
        const entries = try list(g_grant_persist.ctx, allocator, uid);
        defer freeGrantEntries(allocator, entries);
        std.mem.sort(GrantEntry, entries, {}, struct {
            fn lessThan(_: void, a: GrantEntry, b: GrantEntry) bool {
                return switch (std.mem.order(u8, a.graph_name, b.graph_name)) {
                    .lt => true,
                    .gt => false,
                    .eq => a.action < b.action,
                };
            }
        }.lessThan);
        for (entries) |e| {
            const row = try allocator.alloc(Value, 3);
            row[0] = Value{ .Str = try allocator.dupe(u8, username) };
            row[1] = Value{ .Str = try allocator.dupe(u8, e.graph_name) };
            row[2] = Value{ .Str = try allocator.dupe(u8, grantActionName(e.action)) };
            try rows_list.append(allocator, row);
        }
    }
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

/// The privilege name of a stored grant action code.
pub fn grantActionName(action: u8) []const u8 {
    return switch (action) {
        0 => "read",
        1 => "write",
        2 => "schema",
        else => "unknown",
    };
}

// CANARY: REQ=REQ-SONNY-6291-APIKEY-USER-SHOW; FEATURE="GQL Auth DDL"; ASPECT=ApiKeysNotSupported; STATUS=TESTED; TEST=tests/test_sonny6291_apikey_user_show.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6291: the server has no API-key store. No procedure creates,
/// stores, hashes or revokes a key, and the QUIC / gRPC handshake does not
/// authenticate by one (the `geode apikey` CLI keeps its own local state
/// file). Every `geode.auth.apikey_*` procedure answers 0A000. They were
/// stubs: `apikey_check_scope` answered "scope granted" for any key,
/// `apikey_revoke` answered "revoked" and revoked nothing, `apikey_create`
/// printed a key derived from its arguments, and `apikey_list` /
/// `apikey_check_scope` told any caller whether a user exists.
fn handleApikeyNotSupported(_: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    return error.ApiKeysNotSupported;
}

/// Exactly six ASCII digits (a TOTP code).
fn isSixDigitCode(code: []const u8) bool {
    if (code.len != 6) return false;
    for (code) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn handleMfaEnableDisable(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, context: ExecutionContext) anyerror!ExecutionResult {
    // MFA enable/disable — returns status with username
    var username: []const u8 = "";
    var code: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) code = args[1].String;
    }
    // SONNY-6367: every refusal is an error status: no such user (42704 for
    // an Admin), a missing or malformed code (22023), no TOTP secret (55000),
    // a code that does not verify (28000). They answered 00000 with an
    // "error" row.
    if (user_mgmt.getUser(username) == null) return missingUser(allocator, proc_name, context);
    const is_enable = std.mem.eql(u8, proc_name, "geode.auth.mfa_enable");

    // #838: MFA enable used to accept any 6-digit code with no HMAC verification
    // against the user's stored TOTP secret — admins could "enable" MFA without
    // proving authenticator possession. Require a valid TOTP code on enable.
    if (is_enable) {
        // A missing code is an argument error, not a guess: not counted.
        if (code.len == 0) return error.InvalidArgs;
        // SONNY-6623: under the attempt limiter shared with mfa_verify (it
        // had none): the same count, lockout and stored transitions.
        if (!try limitedMfaCodeCheck(allocator, username, code, .enable)) return error.InvalidMfaCode;
    } else if (code.len > 0) {
        // Disable path still validates format if a code is provided, but
        // does NOT require HMAC verification (separate concern — admins may
        // need to disable MFA for recovery without a valid TOTP).
        if (!isSixDigitCode(code)) return error.InvalidArgs;
    }
    // SONNY-6608: the change is stored (the user's `mfa_enabled`); a store
    // that fails refuses it. It answered "MFA enabled / disabled" and
    // changed nothing.
    if (g_mfa_persist.set_enabled_fn) |f| {
        f(g_mfa_persist.ctx, username, is_enable) catch |err| {
            log.err("geode.auth.mfa_enable/mfa_disable could not store the change in the security graph; refused", &.{ Attr.string("user", username), Attr.string("error", @errorName(err)) });
            if (err == error.MfaNotEnrolled) return err;
            return error.MfaChangeNotPersisted;
        };
    }
    // SONNY-6619: SecurityManager's copy follows.
    if (g_sm_hooks.set_mfa_enabled_fn) |f| f(g_sm_hooks.ctx, username, is_enable);
    // CANARY: REQ=REQ-SONNY-6624-MFA-RESET-AUDIT; FEATURE="MFA authentication"; ASPECT=ResetByAdminAudited; STATUS=TESTED; TEST=tests/test_sonny6624_mfa_reset_audit.zig; OWNER=security; UPDATED=2026-11-15
    // SONNY-6624: no mfa_disable proves possession of the second factor (no
    // code, or one checked for its format only), so every one is an MFA
    // reset by the Admin who called it, and is audited as such, with the
    // actor and the target. The security graph's MFA_DISABLE record names
    // the target only. A supplied code does not make it an ordinary
    // disable: it was not verified.
    if (!is_enable) {
        const audit_mod = @import("../security/audit.zig");
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .configuration_change,
            .action = "MFA_RESET_BY_ADMIN",
            .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
            .username = context.user orelse "",
            .target_username = username,
            .details = if (code.len == 0) "MFA disabled without proof of possession: no code" else "MFA disabled without proof of possession: code checked for format only, not verified",
        });
    }
    const status = try std.fmt.allocPrint(allocator, "MFA {s} for {s}", .{ if (is_enable) "enabled" else "disabled", username });
    defer allocator.free(status);
    // SONNY-6602: enable answers the not-enforced warning as well.
    if (is_enable) return ownedRow(allocator, &.{ "status", "username", "warning" }, &.{ status, username, mfa_enable_not_enforced_warning });
    return ownedRow(allocator, &.{ "status", "username" }, &.{ status, username });
}

// ---------------------------------------------------------------------------
// DDL bridge: lets src/execution/admin_ddl.zig invoke the existing geode.auth.*
// handlers with plain string arguments. Authorization (Admin-required for write
// procedures), audit, password policy, and __geode_security persistence all run
// through the unchanged execute() path -- nothing is reimplemented here.
// ---------------------------------------------------------------------------

/// Build a synthetic `CALL <proc_name>(arg0, arg1, ...)` with String-literal
/// arguments and dispatch it through `execute()`. Caller owns the returned
/// ExecutionResult (free with `result.deinit(allocator)`).
///
/// Safety note: some handlers store borrowed slices from string_args directly
/// into the result (e.g. `Value{ .Str = username }` without duping). This is
/// safe because string_args is caller-owned and outlives the result. The
/// temporary *ast.Expr heap nodes are freed by the defers below, but the slice
/// headers they contained (ptr + len) are already copied into the result values
/// and continue to point into the caller-owned string_args data.
pub fn callAuthProcedure(
    allocator: std.mem.Allocator,
    context: ExecutionContext,
    proc_name: []const u8,
    string_args: []const []const u8,
) !ExecutionResult {
    const arg_ptrs = try allocator.alloc(*ast.Expr, string_args.len);
    defer allocator.free(arg_ptrs);
    var made: usize = 0;
    defer {
        var i: usize = 0;
        while (i < made) : (i += 1) allocator.destroy(arg_ptrs[i]);
    }
    for (string_args, 0..) |s, i| {
        const e = try allocator.create(ast.Expr);
        e.* = .{ .String = s };
        arg_ptrs[i] = e;
        made = i + 1;
    }

    const callee = try allocator.create(ast.Expr);
    defer allocator.destroy(callee);
    callee.* = .{ .Ident = .{ .orig = "", .cnf = "" } };

    const call_proc = ast.CallProcedure{
        .procedure = .{ .Call = .{ .callee = callee, .args = arg_ptrs } },
    };

    const maybe = try execute(allocator, proc_name, call_proc, context);
    return maybe orelse error.UnknownProcedure;
}

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-024; FEATURE="AuthDDLPersistence"; ASPECT=CustomRoleHydration; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
// CANARY: REQ=REQ-SONNY-6567-AUTH-HYDRATION; FEATURE="AuthDDLPersistence"; ASPECT=CustomRoleHydrationFailsClosed; STATUS=TESTED; TEST=tests/test_sonny6567_auth_hydration.zig; OWNER=security; UPDATED=2026-11-15
/// Called once at server startup (from server_init) after the AGM is ready
/// and role persistence callbacks are installed.
/// Loads custom (non-built-in) Role node names from __geode_security into
/// g_custom_roles so that the in-memory role store is consistent with what was
/// persisted in a prior run. `allocator` is for the listing only; the store
/// owns what it keeps (SONNY-6278, `g_role_store_alloc`).
///
/// SONNY-6567 (5): every stored role is loaded, or the error is returned and
/// startup fails. A failed listing loaded nothing and a role whose copy could
/// not be made was skipped (`catch continue`), each with at most a warning,
/// and the server ran with part of its roles.
pub fn hydrateCustomRolesFromGraph(allocator: std.mem.Allocator) !void {
    const list_f = g_role_persist.list_fn orelse return;
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit();
    const entries = list_f(g_role_persist.ctx, allocator) catch |e| {
        log.err("hydrateCustomRolesFromGraph: the stored roles could not be listed", &.{Attr.string("error", @errorName(e))});
        return e;
    };
    defer allocator.free(entries);
    const store_alloc = g_role_store_alloc;
    for (entries) |entry| {
        if (isBuiltinRoleName(entry.name)) continue;
        // A role already in the store is kept as it is (its copies are not
        // replaced, so nothing leaks).
        if (g_custom_roles.contains(entry.name)) continue;
        // dupe the name and description so g_custom_roles owns its keys/values
        const key = try store_alloc.dupe(u8, entry.name);
        errdefer store_alloc.free(key);
        const val = try store_alloc.dupe(u8, entry.description);
        errdefer store_alloc.free(val);
        try g_custom_roles.put(key, val);
    }
}

// CANARY: REQ=REQ-AUTH-ROLE-002; FEATURE="BuiltinRoleHardening"; ASPECT=Validation; STATUS=TESTED; TEST=isBuiltinRoleName_recognizes_all_variants; OWNER=security; UPDATED=2026-05-11
test "isBuiltinRoleName_recognizes_all_variants" {
    const testing = std.testing;
    // All four built-in names, both cases.
    try testing.expect(isBuiltinRoleName("admin"));
    try testing.expect(isBuiltinRoleName("Admin"));
    try testing.expect(isBuiltinRoleName("ADMIN"));
    try testing.expect(isBuiltinRoleName("user"));
    try testing.expect(isBuiltinRoleName("User"));
    try testing.expect(isBuiltinRoleName("readwrite"));
    try testing.expect(isBuiltinRoleName("ReadWrite"));
    try testing.expect(isBuiltinRoleName("readonly"));
    try testing.expect(isBuiltinRoleName("ReadOnly"));

    // Custom role name is not a built-in.
    try testing.expect(!isBuiltinRoleName("auditor"));
    try testing.expect(!isBuiltinRoleName(""));
    try testing.expect(!isBuiltinRoleName("superuser"));
}
