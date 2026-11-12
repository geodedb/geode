// CANARY: REQ=REQ-CLI-AUTH-HELPERS-001; FEATURE="CLI Auth Helpers"; ASPECT=Offline; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
//! Shared helpers for CLI commands that need offline access to auth data.
//!
//! Provides:
//! - `resolveStatePath` — resolve a state file path (for non-auth state files like authn, session, apikey, mtls)
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

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const builtin = @import("builtin");
const geode = @import("geode");
const graph_store = geode.graph_store;
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

// -- State Path Resolution (for non-auth flat files) --

const STATE_DIR_ENV = "GEODE_STATE_DIR";

fn secureChmod(path: []const u8, mode: std.Io.File.Permissions) void {
    if (builtin.os.tag == .windows) return;
    const io_sc = std.Io.Threaded.global_single_threaded.io();
    if (std.Io.Dir.openFileAbsolute(io_sc, path, .{})) |file| {
        defer file.close(io_sc);
        file.setPermissions(io_sc, mode) catch {};
        return;
    } else |_| {}

    if (std.Io.Dir.openDirAbsolute(io_sc, path, .{ .iterate = true })) |opened_dir| {
        var dir = opened_dir;
        defer dir.close(io_sc);
        dir.setPermissions(io_sc, mode) catch {};
    } else |_| {}
}

fn resolveStateDir(allocator: std.mem.Allocator) ![]u8 {
    if (getEnvVarOwned(allocator, STATE_DIR_ENV)) |raw| {
        defer allocator.free(raw);
        if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);

        const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
        defer allocator.free(cwd);
        return std.fs.path.join(allocator, &.{ cwd, raw });
    } else |_| {}

    if (getEnvVarOwned(allocator, "XDG_STATE_HOME")) |xdg_state_home| {
        defer allocator.free(xdg_state_home);
        return std.fs.path.join(allocator, &.{ xdg_state_home, "geode" });
    } else |_| {}

    if (getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "state", "geode" });
    } else |_| {}

    if (builtin.os.tag != .windows) {
        // SONNY-6325: `<TMPDIR or /tmp>/geode-<uid>`, created 0700 and
        // refused when it is not a directory of ours with mode 0700.
        return geode.graph_store.privateUserTmpDir(allocator);
    }
    return std.fs.path.join(allocator, &.{ ".", ".geode", "state" });
}

/// Resolve the full filesystem path for a state file.
/// Used by authn_cli, session_cli, apikey_cli, and mtls_cli for their own
/// flat-file state (NOT user credentials, which live in the graph store).
pub fn resolveStatePath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const state_dir = try resolveStateDir(allocator);
    defer allocator.free(state_dir);

    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), state_dir);
    secureChmod(state_dir, std.Io.File.Permissions.fromMode(0o700));

    return std.fs.path.join(allocator, &.{ state_dir, filename });
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

/// Generate a cryptographically secure random password.
/// Returns a 32-character hex string (16 random bytes converted to hex).
pub fn generateSecurePassword() ![32]u8 {
    var random_bytes: [16]u8 = undefined;
    try cb.Csprng.bytes(&random_bytes);
    return std.fmt.bytesToHex(random_bytes, .lower);
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

/// The key the chain verified with, set by `verifyChainBeforeChange`;
/// `deinitAndSaveCliAuth` seals the command's change with it.
var g_verified_key: ?[32]u8 = null;

/// Why the last `verifyChainBeforeChange` refused (for the message).
var g_verify_failure: ?anyerror = null;

pub const ChainCheckError = error{ AuthChainTampered, HmacKeyUnavailable };

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
    if (mgr.countAuthRecords() == 0 and mgr.storage.loadChainRoot() == null) return;
    const kr = AuthGraphManager.resolveExistingHmacKey(allocator, g_resolved_data_dir) catch |err| {
        g_verify_failure = err;
        return error.HmacKeyUnavailable;
    };
    mgr.verifyChain(&kr.key) catch |err| {
        g_verify_failure = err;
        return error.AuthChainTampered;
    };
    g_verified_key = kr.key;
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
            error.HmacKeyUnavailable => std.debug.print(
                "Error: refusing to run '{s} {s}': there is no HMAC key to verify the __geode_security chain with ({s}); nothing was changed.\n" ++
                    "Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or place .geode_hmac_key in the data directory.\n",
                .{ command, subcommand, why },
            ),
        }
        std.process.exit(1);
    };
}

// -- Offline Auth Manager Initialization --

/// Initialise an AuthGraphManager for CLI offline operations.
///
/// Opens the graph store at the given data directory (from --data-dir flag
/// or GEODE_DATA_DIR env var) and returns a ready-to-use AuthGraphManager.
///
/// The caller must call `deinit()` on the returned manager when done.
pub fn initCliAuthManager(allocator: std.mem.Allocator, data_dir: ?[]const u8) !AuthGraphManager {
    // Resolve the data directory from the flag, env var, or default
    const resolved_dir: []const u8 = if (data_dir) |dir|
        dir
    else if (getEnvVarOwned(allocator, "GEODE_DATA_DIR")) |env_dir|
        env_dir
    else |_|
        "/var/lib/geode";

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

test "generateSecurePassword returns 32 chars" {
    const pw = try generateSecurePassword();
    try std.testing.expectEqual(@as(usize, 32), pw.len);
}
