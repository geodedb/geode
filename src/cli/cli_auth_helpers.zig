// CANARY: REQ=REQ-CLI-AUTH-HELPERS-001; FEATURE="CLI Auth Helpers"; ASPECT=Offline; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
//! Shared helpers for CLI commands that need offline access to auth data.
//!
//! Provides:
//! - `isPasswordStrong` — password strength validation
//! - `initCliAuthManager` — initialise AuthGraphManager for offline CLI operations
//! - `generateSecurePassword` — generate a cryptographically secure random password

const std = @import("std");
const cb = @import("crypto_backend");
const geode_auth = @import("geode_auth");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

const builtin = @import("builtin");
const geode = @import("geode");
pub const graph_store = geode.graph_store;
const auth_graph_manager = @import("auth_graph_manager");
const data_dir_lock = @import("data_dir_lock");
pub const AuthGraphManager = auth_graph_manager.AuthGraphManager;

// CANARY: REQ=REQ-SONNY-2777-POLICY-IDS; FEATURE="GPS Policy Persistence"; ASPECT=CliRlsPolicyCreate; STATUS=TESTED; TEST=tests/test_sonny2777_policy_ids.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2777: the record `geode auth policy create <name> --table <t>
/// --condition <c>` writes: an RLS policy (`kind = rls`) under a new id from
/// the policy id sequence. It took `next_user_id` (the next *user* id), so it
/// could reuse a GPS policy's id and overwrite that record. The write refuses
/// an id in use (`PolicyIdInUse`). Returns the new id.
pub fn createRlsPolicyRecord(mgr: *AuthGraphManager, name: []const u8, table: []const u8, condition: []const u8) !u64 {
    const policy_id = mgr.storage.nextPolicyId();
    try mgr.storage.persistPolicy(.{
        .policy_id = policy_id,
        .name = name,
        .description = "",
        .graph = "",
        .table = table,
        .operation = 0,
        .permissive = false,
        .enabled = true,
        .using_clause = condition,
        .check_clause = null,
        .audit_level = 0,
        .created_by = 0,
        // SONNY-2750: an RLS record, which GPS never loads.
        .kind = .rls,
        .mode = .create,
    });
    return policy_id;
}

// -- Offline record removal (SONNY-6352) --

pub const RemoveOutcome = enum { removed, not_found };

// CANARY: REQ=REQ-SONNY-6352-CLI-REMOVAL-ERRORS; FEATURE="OfflineAuthStoreSafety"; ASPECT=RemovalErrorsReported; STATUS=TESTED; TEST=tests/test_sonny6352_auth_writer_and_removals.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6352: `geode user delete <username>`'s removal. `geode user
/// delete`, `geode role delete` and `geode policy delete` dropped the
/// removal's error (`catch {}`) and reported the record deleted while it
/// stayed stored (a node delete that fails leaves the record, SONNY-6293).
/// An error here means nothing was removed.
pub fn removeUserByName(mgr: *AuthGraphManager, username: []const u8) !RemoveOutcome {
    const id = mgr.storage.findUserIdByUsername(username) orelse return .not_found;
    try mgr.storage.removeUser(id);
    return .removed;
}

/// SONNY-6352: `geode role delete <rolename>`'s removal (see
/// `removeUserByName`).
pub fn removeRoleByName(mgr: *AuthGraphManager, name: []const u8) !RemoveOutcome {
    const role = mgr.storage.getRoleByName(name) orelse return .not_found;
    try mgr.storage.removeRole(role.id);
    return .removed;
}

/// SONNY-6352: `geode policy delete <name>`'s removal: the RLS policy of
/// that name, never a GPS policy (SONNY-2750; see `removeUserByName`).
pub fn removeRlsPolicyByName(mgr: *AuthGraphManager, name: []const u8) !RemoveOutcome {
    const id = blk: {
        var it = mgr.storage.policy_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.effectiveKind() != .rls) continue;
            if (std.mem.eql(u8, entry.value_ptr.getName(), name)) break :blk entry.key_ptr.*;
        }
        return .not_found;
    };
    try mgr.storage.removePolicy(id);
    return .removed;
}

// -- Offline role assignment (SONNY-6367) --

/// The built-in roles, as `server_init.writerSetRole` stores them.
pub const builtin_role_names = [_][]const u8{ "admin", "readwrite", "user", "readonly" };

/// The stored (lower-case) name of the built-in role `name` names, matched
/// without regard to case as `user_management.Role.fromString` matches it;
/// null for any other name.
pub fn builtinRoleName(name: []const u8) ?[]const u8 {
    for (builtin_role_names) |b| {
        if (std.ascii.eqlIgnoreCase(b, name)) return b;
    }
    return null;
}

// CANARY: REQ=REQ-SONNY-6369-SUPERUSER-ROLE-FIXED; FEATURE="OfflineAuthStoreSafety"; ASPECT=OfflineSuperuserKeepsAdmin; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6369: `error.SuperuserRoleFixed` when `username` is a stored
/// superuser and `role` is not admin: a superuser always resolves to admin
/// (`role_resolver`), so the role would be stored and never take effect.
pub fn requireRoleTakesEffect(mgr: *AuthGraphManager, username: []const u8, role: []const u8) !void {
    const record = mgr.storage.getUserByUsername(username) orelse return;
    if (record.is_superuser and !std.ascii.eqlIgnoreCase(role, "admin")) return error.SuperuserRoleFixed;
}

// CANARY: REQ=REQ-SONNY-6367-OFFLINE-ROLE-ASSIGN; FEATURE="OfflineAuthStoreSafety"; ASPECT=BuiltinRoleAssigned; STATUS=TESTED; TEST=tests/test_sonny6367_offline_user_cli.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6367: give `username` the built-in role `role` offline, as ALTER
/// USER ... SET ROLE does (`AuthGraphManager.setBuiltinRoleWriteThrough`:
/// its HAS_ROLE edges to the other built-in roles revoked, one to `role`
/// assigned, sealed with the key the chain verified with). `geode user
/// create --role`, `user update --role` and `user assign-role` stored a role
/// node and no edge, so the user had no role. `error.CustomRoleMembershipNotSupported`
/// for a role that is not built in (SONNY-6292: a custom role carries no
/// privileges); `error.UserNotFound` when the user is not stored.
pub fn assignBuiltinRole(allocator: std.mem.Allocator, mgr: *AuthGraphManager, username: []const u8, role: []const u8) !void {
    const name = builtinRoleName(role) orelse return error.CustomRoleMembershipNotSupported;
    if (mgr.storage.findUserIdByUsername(username) == null) return error.UserNotFound;
    try requireRoleTakesEffect(mgr, username, name);
    const key = try changeKey(allocator);
    try mgr.setBuiltinRoleWriteThrough(&key, username, name, &builtin_role_names);
}

// -- Password Strength Validation --

/// Check whether a password meets the server's configured policy.
///
/// This used to enforce its own rules (>=8 chars, one letter, one digit),
/// which were *mutually incompatible* with the policy the server enforces on
/// `ALTER USER ... SET PASSWORD`: the documented recovery passphrase
/// `Correct horse battery staple` was rejected here for containing no digit,
/// while an `abc12345` accepted here was rejected by the server for being too
/// short and not a passphrase. An operator therefore could not set one
/// password that both entry points would take.
///
/// It now defers to the same `PasswordPolicy.geodeSecure()` the server uses,
/// so the offline CLI and the wire agree. See docs/@BUGS_731.md bug 4.
pub fn isPasswordStrong(password: []const u8) bool {
    return passwordPolicyError(password) == null;
}

/// Like `isPasswordStrong`, but returns the operator-facing reason the
/// password was rejected (or `null` when it is acceptable), so callers can
/// tell the user *why* instead of just failing.
pub fn passwordPolicyError(password: []const u8) ?[]const u8 {
    return geode_auth.PasswordPolicy.geodeSecure().validate(password);
}

// -- Secure Password Generation --

/// A generated password: `slice()` is the password.
pub const GeneratedPassword = struct {
    buf: [geode_auth.max_password_length]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const GeneratedPassword) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Generate a cryptographically secure random password. SONNY-6331: one
/// that meets the password policy (`PasswordPolicy.generate`); it was a
/// 32-character hex string the policy refuses, so `change-password
/// --generate-password` failed its own policy check.
pub fn generateSecurePassword() !GeneratedPassword {
    var out: GeneratedPassword = .{};
    out.len = (try geode_auth.PasswordPolicy.geodeSecure().generate(&out.buf)).len;
    return out;
}

// -- Offline Data Directory Lock (ENG-3921) --

/// The CLI is a short-lived single-shot process, so one process-wide guard is
/// enough: `initCliAuthManager` takes it and `deinitAndSaveCliAuth` drops it.
var g_cli_data_dir_lock: ?data_dir_lock.DataDirLock = null;

fn acquireCliDataDirLock(allocator: std.mem.Allocator, resolved_dir: []const u8) !void {
    if (g_cli_data_dir_lock != null) return; // already held by this process
    const budget_ms = data_dir_lock.timeoutFromEnv();
    g_cli_data_dir_lock = data_dir_lock.DataDirLock.acquireWithTimeout(
        allocator,
        resolved_dir,
        budget_ms,
    ) catch |err| switch (err) {
        error.DataDirLocked => {
            const holder = data_dir_lock.readHolderPid(allocator, resolved_dir) orelse -1;
            // Wording is load-bearing: operators and the e2e test both key
            // off "data directory is locked by pid".
            std.debug.print(
                "Error: data directory is locked by pid {d} ({s}); refusing to modify it while it is in use.\n" ++
                    "Stop the running server (or point --data-dir elsewhere) and retry.\n",
                .{ holder, resolved_dir },
            );
            return error.DataDirLocked;
        },
        else => return err,
    };
}

fn releaseCliDataDirLock() void {
    if (g_cli_data_dir_lock) |*lock| {
        lock.release();
        g_cli_data_dir_lock = null;
    }
}

// -- Offline chain verification (SONNY-2798) --

/// The data directory `initCliAuthManager` resolved (flag, GEODE_DATA_DIR, or
/// the default); the HMAC key file lives there.
var g_resolved_data_dir: ?[]const u8 = null;
/// The allocator `initCliAuthManager` copied it with (SONNY-6345);
/// `deinitAndSaveCliAuth` frees it.
var g_resolved_data_dir_alloc: ?std.mem.Allocator = null;

/// The key the chain verified with, set by `verifyChainBeforeChange`;
/// `deinitAndSaveCliAuth` seals the command's change with it.
var g_verified_key: ?[32]u8 = null;

/// Why the last `verifyChainBeforeChange` refused (for the message).
var g_verify_failure: ?anyerror = null;

/// SONNY-6358: `verifyChainBeforeChange` found a store with no auth records
/// and no chain root, so there was nothing to verify and no key was kept.
/// `deinitAndSaveCliAuth` then seals what the command stored with the key
/// the server would use (`changeKey`).
var g_empty_store: bool = false;

pub const ChainCheckError = error{ AuthChainTampered, AuthChainUnverifiable, HmacKeyUnavailable };

// CANARY: REQ=REQ-SONNY-2798-OFFLINE-VERIFY-FIRST; FEATURE="OfflineAuthStoreSafety"; ASPECT=VerifyBeforeChange; STATUS=TESTED; TEST=tests/test_sonny2798_offline_verify.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2798: may an offline command change this auth store? Only when its
/// `__geode_security` HMAC chain verifies. Offline commands re-signed the
/// whole chain after their change (`sealChain`) without checking it first,
/// so a record planted at rest (an allow-write GPS policy, a superuser user,
/// a graph grant) was signed by the next `geode user reset-password` and
/// took effect at the next server start. Since SONNY-2791 no seal signs a
/// planted record without a kind; this refuses the planted records that
/// carry one. An empty store has nothing to verify. On success the key is
/// kept, and `deinitAndSaveCliAuth` seals the command's change.
///
/// SONNY-3035: a store is empty only with no records AND no chain root. A
/// store whose records were all removed at rest kept its chain root, skipped
/// verification, and `geode auth init` bootstrapped a new admin into it and
/// sealed it. And the key is looked up, never generated
/// (`resolveExistingHmacKey`): a missing `.geode_hmac_key` was written with a
/// new key, which then failed to verify, although the refusal said nothing
/// was changed.
pub fn verifyChainBeforeChange(allocator: std.mem.Allocator, mgr: *AuthGraphManager) ChainCheckError!void {
    g_empty_store = false;
    if (mgr.countAuthRecords() == 0 and mgr.storage.loadChainRoot() == null) {
        g_empty_store = true;
        return;
    }
    const kr = AuthGraphManager.resolveExistingHmacKey(allocator, g_resolved_data_dir) catch |err| {
        g_verify_failure = err;
        return error.HmacKeyUnavailable;
    };
    mgr.verifyChain(&kr.key) catch |err| {
        g_verify_failure = err;
        // SONNY-6598: a verification that could not run is no tampering verdict.
        if (!AuthGraphManager.isChainTamperVerdict(err)) return error.AuthChainUnverifiable;
        return error.AuthChainTampered;
    };
    g_verified_key = kr.key;
}

// CANARY: REQ=REQ-SONNY-6358-OFFLINE-PASSWORD-HASH; FEATURE="OfflineAuthStoreSafety"; ASPECT=ChangeKey; STATUS=TESTED; TEST=tests/test_sonny6358_offline_password_hash.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6358: the key an offline command signs its change with, once
/// `verifyChainBeforeChange` has let it change the store: the key the chain
/// verified with, or, on a store with no auth records and no chain root, the
/// key the server would use there (`resolveHmacKey`: the environment, else
/// `.geode_hmac_key`, written as the server's first start would when there is
/// none). Kept for `deinitAndSaveCliAuth`'s seal. `error.ChainNotVerified`
/// when the chain was not checked.
pub fn changeKey(allocator: std.mem.Allocator) ![32]u8 {
    if (g_verified_key) |key| return key;
    if (!g_empty_store) return error.ChainNotVerified;
    const kr = try AuthGraphManager.resolveHmacKey(allocator, g_resolved_data_dir);
    g_verified_key = kr.key;
    return kr.key;
}

/// `verifyChainBeforeChange` for a CLI command (`command` and `subcommand`
/// name it in the message): on a refusal it says why and what to do, and
/// exits without changing anything.
pub fn requireIntactChain(allocator: std.mem.Allocator, mgr: *AuthGraphManager, command: []const u8, subcommand: []const u8) void {
    verifyChainBeforeChange(allocator, mgr) catch |err| {
        const why = if (g_verify_failure) |e| @errorName(e) else "unknown";
        switch (err) {
            error.AuthChainTampered => std.debug.print(
                "Error: refusing to run '{s} {s}': the __geode_security HMAC chain does not verify ({s}); nothing was changed.\n" ++
                    "A security record was changed or added without the HMAC key, or the key is not the one the chain was sealed with\n" ++
                    "(set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY as the server does). Check the records ('geode auth verify', 'geode user list',\n" ++
                    "'geode auth policy list'); then accept them with 'geode auth reseal', or restore the data directory from a backup.\n",
                .{ command, subcommand, why },
            ),
            error.AuthChainUnverifiable => std.debug.print(
                "Error: refusing to run '{s} {s}': the __geode_security HMAC chain could not be verified ({s}); nothing was changed.\n" ++
                    "This is not a tampering verdict (the check itself failed, e.g. out of memory or a store read error). Retry once the cause is fixed.\n",
                .{ command, subcommand, why },
            ),
            error.HmacKeyUnavailable => std.debug.print(
                "Error: refusing to run '{s} {s}': there is no HMAC key to verify the __geode_security chain with ({s}); nothing was changed.\n" ++
                    "Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or place .geode_hmac_key in the data directory.\n",
                .{ command, subcommand, why },
            ),
        }
        std.process.exit(1);
    };
}

// CANARY: REQ=REQ-SONNY-6345-CLI-DEFAULT-DATA-DIR; FEATURE="OfflineAuthStoreSafety"; ASPECT=ServerDefaultDataDir; STATUS=TESTED; TEST=tests/test_sonny6345_auth_cli_and_grant.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6345: the data directory the offline auth CLI (`geode auth init |
/// reseal | verify | policy | grant`, `geode user`, `geode role`) opens:
/// `--data-dir`, else the directory `geode serve` opens with no flag
/// (`graph_store.getPersistenceFilePath`: GEODE_DATA_DIR, else the per-user
/// `graph_store.defaultDataDir`). It was GEODE_DATA_DIR, else /var/lib/geode,
/// so with neither set the CLI inspected and changed a different store than
/// the server's. Caller owns the result.
pub fn resolveCliDataDir(allocator: std.mem.Allocator, flag: ?[]const u8) ![]u8 {
    if (flag) |dir| return allocator.dupe(u8, dir);
    return graph_store.getPersistenceFilePath(allocator);
}

/// The data directory `initCliAuthManager` opened, once it has.
pub fn resolvedDataDir() ?[]const u8 {
    return g_resolved_data_dir;
}

/// SONNY-6345: whether `data_dir` holds auth state (a registered
/// `__geode_security` graph), read without creating or locking anything.
pub fn hasAuthState(allocator: std.mem.Allocator, data_dir: []const u8) !bool {
    return geode.graph_storage_adapter.graphRegisteredOnDisk(allocator, data_dir, graph_store.SECURITY_GRAPH_NAME);
}

// -- Offline Auth Manager Initialization --

/// Initialise an AuthGraphManager for CLI offline operations.
///
/// Opens the graph store at the given data directory (from --data-dir flag
/// or GEODE_DATA_DIR env var) and returns a ready-to-use AuthGraphManager.
///
/// The caller must call `deinit()` on the returned manager when done.
pub fn initCliAuthManager(allocator: std.mem.Allocator, data_dir: ?[]const u8) !AuthGraphManager {
    // SONNY-6345: the flag, else the directory `geode serve` opens (it was
    // GEODE_DATA_DIR, else /var/lib/geode). Kept until
    // `deinitAndSaveCliAuth` (`resolvedDataDir` reads it).
    const resolved_dir: []const u8 = try resolveCliDataDir(allocator, data_dir);
    errdefer allocator.free(resolved_dir);

    // CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-002; FEATURE="DataDirLock"; ASPECT=OfflineCliWriter; STATUS=TESTED; TEST=tests/test_datadir_lock_subprocess.zig; OWNER=storage; UPDATED=2026-08-29
    // ENG-3921: these offline CLI entry points open the data directory
    // read-write and mutate the `__geode_security` graph. Run against a LIVE
    // server's data dir they used to succeed, rewriting the HMAC chain out
    // from under the running process. Take the SAME `.geode.lock` the server
    // holds, so exactly one writer owns the directory at a time. Every
    // offline auth/apikey/tenant command routes through here.
    try acquireCliDataDirLock(allocator, resolved_dir);
    errdefer releaseCliDataDirLock();
    // SONNY-2798: where `requireIntactChain` finds the HMAC key.
    g_resolved_data_dir = resolved_dir;
    g_resolved_data_dir_alloc = allocator;
    errdefer {
        g_resolved_data_dir = null;
        g_resolved_data_dir_alloc = null;
    }

    // Use initGlobalStore which initializes the storage adapter so that
    // saveIfDirty actually persists node/edge data to disk.  Without the
    // adapter, saveToFile is a no-op and user mutations are lost between
    // CLI invocations (GAP-0266).
    // SONNY-6422: a data directory that cannot be opened is an error. This
    // fell back to an empty in-memory store, so the command ran against no
    // users and its changes were discarded at exit.
    const store = graph_store.initGlobalStore(allocator, resolved_dir) catch |err| {
        std.debug.print("Error: cannot open the data directory {s} ({s}); nothing was changed.\n", .{ resolved_dir, @errorName(err) });
        return err;
    };
    return AuthGraphManager.init(allocator, store);
}

/// Persist any dirty graph-store state and deinitialise the CLI auth manager.
///
/// CLI commands run as short-lived processes without a persistence thread.
/// This function ensures that mutations (user create, role create, etc.) are
/// flushed to disk before the process exits.  Call this instead of (or in
/// addition to) `mgr.deinit()` from every CLI command that may mutate auth
/// state.
pub fn deinitAndSaveCliAuth(allocator: std.mem.Allocator, mgr: *AuthGraphManager) void {
    // SONNY-2798: the chain verified before this command changed anything
    // (`requireIntactChain`), so the records it does not sign are the
    // command's own: seal them, so the next command and the next server start
    // verify the change. Most offline writers stored their records unsigned,
    // and the server refused to start until someone ran `geode auth reseal`.
    // SONNY-6358: on a store that had no auth records there was no chain to
    // verify and no key; what the command stored was left unsealed, and the
    // server refused to start (no chain root). Seal it with the server's key.
    if (g_verified_key == null and g_empty_store and mgr.countAuthRecords() > 0) {
        _ = changeKey(allocator) catch |err| {
            std.debug.print(
                "Warning: the change was saved but could not be sealed into the __geode_security HMAC chain: no HMAC key ({s}); set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY as the server does, then run 'geode auth reseal'.\n",
                .{@errorName(err)},
            );
        };
    }
    g_empty_store = false;
    if (g_verified_key) |key| {
        g_verified_key = null;
        mgr.sealChain(&key) catch |err| {
            std.debug.print(
                "Warning: the change was saved but could not be sealed into the __geode_security HMAC chain ({s}); check it with 'geode auth verify'.\n",
                .{@errorName(err)},
            );
        };
    }
    // Flush any in-memory changes to disk before tearing down.
    graph_store.getGlobalStore(allocator).saveIfDirty();
    mgr.deinit();
    // ENG-3921: drop the data-dir lock only after the flush has landed, so a
    // server starting up behind us never reads a half-written store.
    releaseCliDataDirLock();
    if (g_resolved_data_dir_alloc) |a| {
        if (g_resolved_data_dir) |d| a.free(d);
        g_resolved_data_dir = null;
        g_resolved_data_dir_alloc = null;
    }
}

/// SONNY-6359: `deinitAndSaveCliAuth` for a command that changes nothing
/// (`geode auth verify`): no seal and no save, then the same teardown.
/// Opening the store still has its own side effects on disk (the storage
/// engine checkpoints and truncates each graph's WAL, rewrites the graph
/// registry and records the lock holder): the store has no read-only open.
pub fn deinitCliAuthWithoutSaving(allocator: std.mem.Allocator, mgr: *AuthGraphManager) void {
    _ = allocator;
    g_verified_key = null;
    g_empty_store = false;
    mgr.deinit();
    releaseCliDataDirLock();
    if (g_resolved_data_dir_alloc) |a| {
        if (g_resolved_data_dir) |d| a.free(d);
        g_resolved_data_dir = null;
        g_resolved_data_dir_alloc = null;
    }
}

// -- Tests --

// These tests previously encoded the CLI's own policy (>=8 chars, one letter,
// one digit). That policy was mutually incompatible with the one the server
// enforces, so `abc12345` passed here and was then rejected over the wire.
// The CLI now defers to PasswordPolicy.geodeSecure(); these cases were
// updated to the unified policy rather than kept pinned to the old one.
// See docs/@BUGS_731.md bug 4.

test "isPasswordStrong rejects short passwords" {
    try std.testing.expect(!isPasswordStrong("abc123"));
    try std.testing.expect(!isPasswordStrong("abcdefg"));
    // Previously accepted by the CLI, rejected by the server: too short and
    // not a passphrase.
    try std.testing.expect(!isPasswordStrong("abc12345"));
    try std.testing.expect(!isPasswordStrong("SecureP4ss!"));
}

test "isPasswordStrong requires a passphrase, not just length" {
    // Long enough (>=20) and mixed case, but a single word.
    try std.testing.expect(!isPasswordStrong("Supercalifragilistic"));
}

test "isPasswordStrong requires mixed case" {
    try std.testing.expect(!isPasswordStrong("correct horse battery staple"));
    try std.testing.expect(!isPasswordStrong("CORRECT HORSE BATTERY STAPLE"));
}

test "isPasswordStrong accepts the documented recovery passphrase" {
    // The exact form the server's own error message tells operators to use.
    // The old CLI policy rejected this for containing no digit.
    try std.testing.expect(isPasswordStrong("Correct horse battery staple"));
}

test "passwordPolicyError explains the rejection" {
    try std.testing.expect(passwordPolicyError("Correct horse battery staple") == null);
    const reason = passwordPolicyError("short") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, reason, "too short") != null);
}

test "generateSecurePassword meets the password policy" {
    const pw = try generateSecurePassword();
    try std.testing.expect(passwordPolicyError(pw.slice()) == null);
}
