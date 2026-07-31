// Reproduction tests for BUG 4 of the geode v0.8.4 blog-post validation sweep
// (docs/@BUGS_731.md §4): `ALTER USER <u> SET PASSWORD '<new>'` — the server's
// OWN documented recovery instruction for the auto-generated first-boot admin
// password — changes the password but never clears `password_reset_required`,
// so every subsequent query with the new, valid password is still rejected with
// "Password reset required". The account is permanently locked out.
//
// These tests are written BEFORE the fix and MUST fail today; they are
// committed first so the failure output is proof they exercise the bug rather
// than the implementation.
//
// ---------------------------------------------------------------------------
// 4a — THE root cause (certain)
//   `AuthGraphManager.updateUserPassword` (src/security/auth_graph_manager.zig:
//   1092-1104) rewrites password_hash / password_changed_at / updated_at /
//   auth_version and re-seals the HMAC chain, but NEVER touches
//   `record.password_reset_required`. The durable flag stays true forever.
//   The flag is fully persisted (src/storage/user_storage.zig:1452), read back
//   (:357 / :470), included in the record HMAC input
//   (auth_graph_manager.zig:1543) and rehydrated into the auth path
//   (src/server/main.zig:305, src/server/server_init.zig:726).
//   The ONLY durable clear anywhere in the tree is the OFFLINE CLI at
//   src/cli/user_mgmt_cli.zig:1004-1015 — a working reference for the correct
//   sequence (mutate record → user_cache.put → upsertUserNode → re-seal).
//   The flag is SET at auth_graph_manager.zig:919
//   (`record.password_reset_required = !password_from_env;`) — which is exactly
//   why the bug is specific to the auto-generated first-boot flow and why an
//   account seeded via GEODE_ADMIN_PASSWORD is unaffected.
//
// 4c — double write-through hypothesis
//   `handleAlterUserSetPassword` (src/server/quic_connection_handler.zig:5344)
//   persists TWICE for one logical ALTER: `user_mgmt.updateUserPassword` at
//   :5393 (→ persistent_writer → AGM.updateUserPassword) and `sm.updatePassword`
//   at :5405-5414 (→ persistPasswordToGraph → AGM.updateUserPassword), while the
//   user_mgmt cache bumps its auth_version only once. The persisted version then
//   leads the cached one, `refreshCachedUserIfStaleOwner` invalidates the cache
//   and re-hydrates from the graph — restoring password_reset_required=true.
//   The tests below drive that EXACT double write-through through the real
//   seams (no fakes) so the hypothesis is settled either way.
//
// 4b — the un-terminable ack
//   The success reply is `ExecutionResponse{ .status = 00000, .payload = null }`
//   (quic_connection_handler.zig:5421-5426) — the only payload=null success
//   response in the server. Client side, `captureExecutionResponse`
//   (src/client/query_result_accumulator.zig:132-138) returns an empty summary
//   for a null payload so `schema_received` never flips, and the FIRST collect
//   loop in src/client/quic_query_runner.zig:203-212 re-blocks on an
//   un-tolerant `try transport.nextEvent(...)` (unlike the catch-tolerant loops
//   at :223-226 and :241-244) until the read times out — surfacing as the
//   generic "Error: query execution failed".
//   NOTE: `handleAlterUserSetPassword` needs a live `*QuicStream` and is
//   file-private, so the SERVER half of 4b is not reachable from a unit test.
//   The CLIENT half is, and is what produces the operator-visible symptom, so
//   that is what is pinned here.
//
// IMPORTANT: 4b must NOT be fixed without 4a — a terminable ack on a still-
// locked account makes the CLI report SUCCESS on an account that is still
// locked out, which is strictly worse than the current error.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const role_resolver = geode.security.role_resolver;
const qr = geode.quic_query_runner;
const schema = @import("schema");

const auth_graph_manager = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const geode_auth = @import("geode_auth");
const user_storage = @import("user_storage");
const UserStorageBackend = user_storage.UserStorageBackend;

// Zig 0.16 removed std.process.setEnvVar / std.posix.setenv; access libc
// directly, matching tests/test_admin_bootstrap_env_and_reset.zig.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const ADMIN_PASSWORD_ENV = "GEODE_ADMIN_PASSWORD";
const DEFAULT_PASSWORD_ENV = "GEODE_DEFAULT_PASSWORD";
const ADMIN_USERNAME_ENV = "GEODE_ADMIN_USERNAME";

fn setEnv(name: [:0]const u8, value: [:0]const u8) !void {
    if (setenv(name.ptr, value.ptr, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name.ptr);
}

/// Drop every bootstrap-influencing env var so a test starts from the
/// auto-generated ("forced reset") first-boot flow — the state the bug is
/// specific to. Test runners frequently inherit these from the dev shell.
fn clearBootstrapEnv() void {
    unsetEnv(ADMIN_PASSWORD_ENV);
    unsetEnv(DEFAULT_PASSWORD_ENV);
    unsetEnv(ADMIN_USERNAME_ENV);
}

/// A password that satisfies the geodeSecure policy the server enforces on
/// ALTER USER (≥20 chars, upper, lower, digit, ≥3 words).
const NEW_PASSWORD = "Bug731 Correct Horse Battery St4ple";
const OTHER_PASSWORD = "Bug731 Another Horse Battery St4ple";

// ===========================================================================
// 1. REGRESSION (RED) — the durable flag must be cleared by the SAME durable
//    seam the server's ALTER USER path uses.
// ===========================================================================

test "ALTER USER SET PASSWORD clears the durable password_reset_required flag (bug 731-4a regression)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();

    const hmac_key = [_]u8{0x71} ** 32;

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    // --- first boot with NO env password: auto-generated credential, and the
    //     record is flagged "must reset on first login". This is the state the
    //     operator lands in on a fresh container.
    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);

    {
        const seeded = mgr.storage.getUser(bootstrap.user_id) orelse return error.UserNotFound;
        // Precondition: the bug only exists from this state.
        try testing.expect(seeded.password_reset_required);
    }

    // --- follow the server's own instruction: change the password. This is the
    //     one durable seam every ALTER USER SET PASSWORD write reaches
    //     (persistent_writer → writerUpdatePassword and SecurityManager →
    //     graphPersistPassword both land here).
    const new_hash = try geode_auth.hashPasswordArgon2id(allocator, NEW_PASSWORD);
    defer allocator.free(new_hash);
    _ = try mgr.updateUserPassword(&hmac_key, bootstrap.user_id, new_hash);

    // --- the in-memory record the auth path consults must be unflagged…
    {
        const cached = mgr.storage.getUser(bootstrap.user_id) orelse return error.UserNotFound;
        try testing.expect(!cached.password_reset_required);
    }

    // --- …and so must the DURABLE record read back out of the graph (this is
    //     what src/server/main.zig:305 rehydrates into the auth path).
    {
        const reloaded = UserStorageBackend.findUserByUsernameInGraph(store, bootstrap.username) orelse
            return error.UserMissingAfterPasswordChange;
        try testing.expect(!reloaded.password_reset_required);
        // The new password must be the one that verifies.
        const hash = reloaded.password_hash[0..reloaded.password_hash_len];
        try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, NEW_PASSWORD, hash));
    }

    // --- clearing the flag must not break the HMAC chain: the flag is part of
    //     the record HMAC input (auth_graph_manager.zig:1543), so a fix that
    //     writes the property without re-sealing would corrupt the chain and
    //     brick the next startup.
    try mgr.verifyChain(&hmac_key);
}

// ===========================================================================
// 2. PERSISTENCE / DURABILITY (RED) — the cleared flag must survive a restart
//    and the new password must authenticate afterwards.
// ===========================================================================

test "password_reset_required stays cleared across a restart and the new password authenticates (bug 731-4a durability)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();

    const hmac_key = [_]u8{0x72} ** 32;

    var autogen_password_buf: [64]u8 = undefined;
    var autogen_password_len: usize = 0;

    // ---- boot 1: auto-generated admin (forced reset), then ALTER USER ----
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        var mgr = try AuthGraphManager.init(allocator, store);

        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        @memcpy(autogen_password_buf[0..bootstrap.password.len], bootstrap.password);
        autogen_password_len = bootstrap.password.len;
        allocator.free(bootstrap.username);
        allocator.free(bootstrap.password);

        const new_hash = try geode_auth.hashPasswordArgon2id(allocator, NEW_PASSWORD);
        defer allocator.free(new_hash);
        _ = try mgr.updateUserPassword(&hmac_key, bootstrap.user_id, new_hash);

        mgr.deinit();
        graph_store.getGlobalStore(allocator).saveIfDirty();
        graph_store.deinitGlobalStore();
    }

    // ---- boot 2: fresh manager over the same data dir (server restart) ----
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        var mgr = try AuthGraphManager.init(allocator, store);
        defer mgr.deinit();

        // The chain must still verify after a restart (server_init refuses to
        // start on error.AuthChainTampered).
        try mgr.verifyChain(&hmac_key);

        const reloaded = UserStorageBackend.findUserByUsernameInGraph(store, "geode") orelse
            return error.UserMissingOnReload;

        // The reported symptom: the password DID change, but the account is
        // still flagged, so every query keeps being refused.
        const hash = reloaded.password_hash[0..reloaded.password_hash_len];
        try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, NEW_PASSWORD, hash));
        const autogen = autogen_password_buf[0..autogen_password_len];
        try testing.expect(!(try geode_auth.verifyPasswordArgon2id(allocator, autogen, hash)));

        try testing.expect(!reloaded.password_reset_required);
    }
}

// ===========================================================================
// 3. NEGATIVE CONTROL (GREEN before and after) — an account seeded via
//    GEODE_ADMIN_PASSWORD is never flagged, and a password change keeps it
//    that way with a valid chain. Pins the report's own isolation of the bug
//    to the forced-first-login-reset state.
// ===========================================================================

test "env-seeded admin is never flagged: password change keeps password_reset_required false (negative control)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();
    try setEnv(ADMIN_PASSWORD_ENV, "bug731-seeded-admin-pw");

    const hmac_key = [_]u8{0x73} ** 32;

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);

    {
        const seeded = mgr.storage.getUser(bootstrap.user_id) orelse return error.UserNotFound;
        try testing.expect(!seeded.password_reset_required);
    }

    const new_hash = try geode_auth.hashPasswordArgon2id(allocator, NEW_PASSWORD);
    defer allocator.free(new_hash);
    _ = try mgr.updateUserPassword(&hmac_key, bootstrap.user_id, new_hash);

    const reloaded = UserStorageBackend.findUserByUsernameInGraph(store, bootstrap.username) orelse
        return error.UserMissingAfterPasswordChange;
    try testing.expect(!reloaded.password_reset_required);
    const hash = reloaded.password_hash[0..reloaded.password_hash_len];
    try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, NEW_PASSWORD, hash));
    try mgr.verifyChain(&hmac_key);
}

// ===========================================================================
// 4. OVER-REACH GUARD (GREEN before and after) — clearing the flag for the
//    user whose password changed must not clear it for anybody else.
//    A fix that blanket-clears the flag (e.g. on every reseal, or across the
//    user_cache) would silently unlock every other flagged account.
// ===========================================================================

test "changing one user's password does not clear password_reset_required for other users (over-reach guard)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();

    const hmac_key = [_]u8{0x74} ** 32;

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);

    // A second account that is explicitly flagged for a forced reset (the
    // durable equivalent of SecurityManager.forcePasswordReset, which only
    // mutates the in-memory users map).
    const other_hash = try geode_auth.hashPasswordArgon2id(allocator, OTHER_PASSWORD);
    defer allocator.free(other_hash);
    const other_id = try mgr.createUser(&hmac_key, "flagged", "flagged@localhost", other_hash, false);
    _ = try mgr.upsertUserState(&hmac_key, .{
        .user_id = other_id,
        .username = "flagged",
        .email = "flagged@localhost",
        .password_hash = other_hash,
        .password_reset_required = true,
    });
    {
        const flagged = mgr.storage.getUser(other_id) orelse return error.UserNotFound;
        try testing.expect(flagged.password_reset_required);
    }

    // Change ONLY the admin's password.
    const new_hash = try geode_auth.hashPasswordArgon2id(allocator, NEW_PASSWORD);
    defer allocator.free(new_hash);
    _ = try mgr.updateUserPassword(&hmac_key, bootstrap.user_id, new_hash);

    // The other account must still be flagged, in cache and on disk.
    {
        const flagged = mgr.storage.getUser(other_id) orelse return error.UserNotFound;
        try testing.expect(flagged.password_reset_required);
    }
    {
        const reloaded = UserStorageBackend.findUserByUsernameInGraph(store, "flagged") orelse
            return error.FlaggedUserMissing;
        try testing.expect(reloaded.password_reset_required);
    }
    try mgr.verifyChain(&hmac_key);
}

// ===========================================================================
// 5. OVER-REACH, second half (RED) — an explicitly flagged user stays flagged
//    until THEIR OWN password changes, and then must be unflagged.
// ===========================================================================

test "an explicitly flagged user is unflagged only by their own password change (bug 731-4a scope)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();

    const hmac_key = [_]u8{0x75} ** 32;

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);

    const other_hash = try geode_auth.hashPasswordArgon2id(allocator, OTHER_PASSWORD);
    defer allocator.free(other_hash);
    const other_id = try mgr.createUser(&hmac_key, "flagged", "flagged@localhost", other_hash, false);
    _ = try mgr.upsertUserState(&hmac_key, .{
        .user_id = other_id,
        .username = "flagged",
        .email = "flagged@localhost",
        .password_hash = other_hash,
        .password_reset_required = true,
    });

    // Somebody else's password change leaves the flag alone (guard).
    const admin_hash = try geode_auth.hashPasswordArgon2id(allocator, NEW_PASSWORD);
    defer allocator.free(admin_hash);
    _ = try mgr.updateUserPassword(&hmac_key, bootstrap.user_id, admin_hash);
    {
        const flagged = mgr.storage.getUser(other_id) orelse return error.UserNotFound;
        try testing.expect(flagged.password_reset_required);
    }

    // Their OWN password change must clear it, durably.
    const own_hash = try geode_auth.hashPasswordArgon2id(allocator, "Bug731 Flagged Horse Battery St4ple");
    defer allocator.free(own_hash);
    _ = try mgr.updateUserPassword(&hmac_key, other_id, own_hash);

    const reloaded = UserStorageBackend.findUserByUsernameInGraph(store, "flagged") orelse
        return error.FlaggedUserMissing;
    try testing.expect(!reloaded.password_reset_required);
    try mgr.verifyChain(&hmac_key);
}

// ===========================================================================
// 6. 4c INVARIANT (primitive level) — one durable password change advances
//    auth_version by EXACTLY ONE. If this passes while the server-path test
//    below fails, the extra bump comes from the double write-through in
//    handleAlterUserSetPassword, not from the AGM primitive.
// ===========================================================================

test "AuthGraphManager.updateUserPassword advances durable auth_version by exactly one (4c invariant)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();

    const hmac_key = [_]u8{0x76} ** 32;

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);

    const before = (UserStorageBackend.findUserByUsernameInGraph(store, bootstrap.username) orelse
        return error.UserNotFound).auth_version;

    const new_hash = try geode_auth.hashPasswordArgon2id(allocator, NEW_PASSWORD);
    defer allocator.free(new_hash);
    const returned = try mgr.updateUserPassword(&hmac_key, bootstrap.user_id, new_hash);

    const after = (UserStorageBackend.findUserByUsernameInGraph(store, bootstrap.username) orelse
        return error.UserNotFound).auth_version;

    try testing.expectEqual(before + 1, after);
    // The returned version is what the caller stamps onto live sessions; it
    // must agree with what landed on disk.
    try testing.expectEqual(after, returned);
}

// ===========================================================================
// SERVER-PATH HARNESS — wires user_management + SecurityManager to a real
// AuthGraphManager over a real data dir with the SAME bridges production
// installs (src/server/server_init.zig:864-869 writerUpdatePassword,
// :797-808 graphPersistPassword, src/server/main.zig:1517-1522 resolver), so
// the two tests below drive the EXACT sequence handleAlterUserSetPassword runs
// at quic_connection_handler.zig:5393 and :5405-5414. No fakes: every callback
// forwards to real product code.
// ===========================================================================

fn bridgeGraphPersistPassword(
    opaque_agm: *anyopaque,
    hmac_key: *const [32]u8,
    user_id: u64,
    new_password_hash: []const u8,
) callconv(.auto) u64 {
    // Mirror of server_init.graphPersistPassword.
    const agm: *AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    return agm.updateUserPassword(hmac_key, user_id, new_password_hash) catch 0;
}

fn bridgeWriterUpdatePassword(ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void {
    // Mirror of server_init.writerUpdatePassword.
    const agm: *AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    const uid = (try agm.findUserIdByName(username)) orelse return;
    _ = try agm.updateUserPassword(&agm.hmac_key, uid, new_password_hash);
    user_mgmt.notePersistentAuthMutation();
}

fn bridgeLookupPersistentUser(_: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?user_mgmt.User {
    // Mirror of main.zig lookupPersistentAuthUser + duplicatePersistentUser:
    // reads the REAL persisted :User record out of __geode_security.
    const store = graph_store.getGlobalStore(allocator);
    const record = UserStorageBackend.findUserByUsernameInGraph(store, username) orelse return null;
    return user_mgmt.User{
        .username = try allocator.dupe(u8, record.getUsername()),
        .password_hash = try allocator.dupe(u8, record.getPasswordHash()),
        .email = try allocator.dupe(u8, record.getEmail()),
        .role = role_resolver.resolveRoleFromGraph(store, record),
        .created_at = record.created_at,
        .last_login = if (record.last_login != 0) record.last_login else null,
        .active = record.is_active,
        .password_reset_required = record.password_reset_required,
        .auth_version = record.auth_version,
    };
}

fn bridgePersistentUsersExist(_: ?*anyopaque) anyerror!bool {
    const store = graph_store.getGlobalStore(std.heap.c_allocator);
    return UserStorageBackend.hasUserRecordsInGraph(store);
}

fn bridgeLookupPersistentAuthVersion(_: ?*anyopaque, username: []const u8) anyerror!?u64 {
    const store = graph_store.getGlobalStore(std.heap.c_allocator);
    return UserStorageBackend.findUserAuthVersionByUsernameInGraph(store, username);
}

const ServerAuthHarness = struct {
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    mgr: AuthGraphManager,
    sm: geode.auth.SecurityManager,
    username: []const u8,
    autogen_password: []const u8,
    user_id: u64,

    const hmac_key = [_]u8{0x77} ** 32;

    fn init(allocator: std.mem.Allocator, data_dir: []const u8) !*ServerAuthHarness {
        const self = try allocator.create(ServerAuthHarness);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.store = try graph_store.initGlobalStore(allocator, data_dir);
        self.mgr = try AuthGraphManager.init(allocator, self.store);
        self.mgr.hmac_key = hmac_key;

        // First boot, no env password: auto-generated credential + forced reset.
        const bootstrap = try self.mgr.bootstrapDefaultAdmin(&hmac_key);
        self.username = bootstrap.username;
        self.autogen_password = bootstrap.password;
        self.user_id = bootstrap.user_id;

        const record = self.mgr.storage.getUser(self.user_id) orelse return error.UserNotFound;

        // SecurityManager hydrated from the graph, exactly as
        // server_init.hydrateSecurityManagerFromGraph does.
        self.sm = try geode.auth.SecurityManager.initEmpty(allocator);
        try self.sm.hydrateUser(
            record.id,
            record.getUsername(),
            record.getEmail(),
            record.getPasswordHash(),
            record.is_superuser,
            record.is_active,
            record.is_default_user,
            record.password_reset_required,
            record.mfa_enabled,
            record.getMFASecret(),
            record.auth_version,
            record.getAttributesJson(),
        );
        self.sm.hmac_key = hmac_key;
        self.sm.auth_graph_mgr = @ptrCast(&self.mgr);
        self.sm.graph_persist_password = &bridgeGraphPersistPassword;

        // user_management store hydrated from the same persisted record. The
        // writer is installed AFTER hydration so hydration itself does not
        // write through (production hydrates via the resolver, not create_fn).
        try user_mgmt.initUserStore(allocator);
        try user_mgmt.createUserWithHash(
            allocator,
            record.getUsername(),
            record.getPasswordHash(),
            record.getEmail(),
            .Admin,
            record.password_reset_required,
        );
        user_mgmt.setPersistentUserWriter(.{
            .ctx = @ptrCast(&self.mgr),
            .update_password_fn = &bridgeWriterUpdatePassword,
        });
        user_mgmt.setPersistentUserResolver(.{
            .lookup_fn = bridgeLookupPersistentUser,
            .has_users_fn = bridgePersistentUsersExist,
            .auth_version_fn = bridgeLookupPersistentAuthVersion,
        });

        return self;
    }

    fn deinit(self: *ServerAuthHarness) void {
        user_mgmt.setPersistentUserWriter(null);
        user_mgmt.setPersistentUserResolver(null);
        user_mgmt.deinitUserStore();
        self.sm.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.autogen_password);
        self.mgr.deinit();
        graph_store.deinitGlobalStore();
        self.allocator.destroy(self);
    }

    /// The two persistence calls handleAlterUserSetPassword makes, in order
    /// (quic_connection_handler.zig:5393 then :5405-5414).
    fn alterUserSetPassword(self: *ServerAuthHarness, new_password: []const u8) !void {
        try user_mgmt.updateUserPassword(self.allocator, self.username, new_password);
        if (self.sm.getUserIdByUsername(self.username)) |uid| {
            try self.sm.updatePassword(uid, new_password);
        } else {
            return error.SecurityManagerUserMissing;
        }
    }

    fn durableRecord(self: *ServerAuthHarness) !UserStorageBackend.UserRecord {
        return UserStorageBackend.findUserByUsernameInGraph(self.store, self.username) orelse
            error.UserMissingInGraph;
    }
};

// ===========================================================================
// 7. END-TO-END REGRESSION (RED) — the operator-visible loop: after following
//    the server's instruction, the next login must NOT demand another reset.
// ===========================================================================

test "server ALTER USER path: the next login no longer requires a password reset (bug 731-4 end-to-end regression)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();

    const h = try ServerAuthHarness.init(allocator, data_dir);
    defer h.deinit();

    // Precondition — the reported starting state: the auto-generated password
    // authenticates, but the session is flagged "password reset required"
    // (quic_connection_handler.zig:5810 copies this into ServerState, :6143
    // gates every query on it).
    {
        const first_login = try user_mgmt.authenticate(h.username, h.autogen_password);
        try testing.expect(first_login.password_reset_required);
    }

    // Follow the server's own instruction.
    try h.alterUserSetPassword(NEW_PASSWORD);

    // The new password must now authenticate WITHOUT the reset demand. On HEAD
    // this still reports password_reset_required=true — the infinite loop.
    const next_login = try user_mgmt.authenticate(h.username, NEW_PASSWORD);
    try testing.expect(!next_login.password_reset_required);

    // …and the durable record backing it must agree.
    const record = try h.durableRecord();
    try testing.expect(!record.password_reset_required);
    try h.mgr.verifyChain(&ServerAuthHarness.hmac_key);
}

// ===========================================================================
// 8. 4c HYPOTHESIS (server path) — one logical ALTER USER must advance the
//    durable auth_version by EXACTLY ONE. Two bumps for one password change
//    leave the persisted version ahead of the user_management cache, which
//    makes refreshCachedUserIfStaleOwner invalidate + re-hydrate the cached
//    user straight back out of the graph.
// ===========================================================================

test "server ALTER USER path advances durable auth_version by exactly one (bug 731-4c)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearBootstrapEnv();
    defer clearBootstrapEnv();

    const h = try ServerAuthHarness.init(allocator, data_dir);
    defer h.deinit();

    const before = (try h.durableRecord()).auth_version;

    try h.alterUserSetPassword(NEW_PASSWORD);

    const after_record = try h.durableRecord();
    const cached = user_mgmt.getUser(h.username) orelse return error.UserMissingInCache;

    // Diagnostic: print all three observations before asserting so the whole
    // picture is visible in the failure output regardless of which assert trips.
    std.debug.print(
        "\n[bug731-4c] durable auth_version {d} -> {d} (expected +1); cached auth_version {d}; durable password_reset_required {}\n",
        .{ before, after_record.auth_version, cached.auth_version, after_record.password_reset_required },
    );

    try testing.expectEqual(before + 1, after_record.auth_version);
    // Persisted and cached versions must not diverge, or every later request
    // re-hydrates the user from the graph.
    try testing.expectEqual(after_record.auth_version, cached.auth_version);
}

// ===========================================================================
// 9. 4b (RED, CLIENT half) — a status-only success response (00000, no
//    payload) must terminate the collect loop instead of blocking until the
//    read times out.
//
//    Scope note: `handleAlterUserSetPassword` is file-private and needs a live
//    *QuicStream, so the server half (making the ack carry a terminable
//    payload) is NOT reachable from a unit test. What IS reachable, and what
//    produces the operator-visible "Error: query execution failed", is the
//    client collect loop at quic_query_runner.zig:203-212, which re-blocks on
//    an un-tolerant `try transport.nextEvent(...)` because a null payload
//    never flips schema_received. This test drives the real
//    consumeQueryWithTransport/ResultAccumulator code through the public
//    QueryTransport seam with the EXACT response shape the server sends.
// ===========================================================================

const AckOnlyTransport = struct {
    events_delivered: usize = 0,
    next_event_calls: usize = 0,

    fn asTransport(self: *AckOnlyTransport) qr.QueryTransport {
        return .{
            .context = self,
            .beginQueryFn = begin,
            .nextEventFn = next,
            .requestNextPageFn = requestNextPage,
        };
    }

    fn begin(_: *qr.QueryTransport, _: std.mem.Allocator, _: qr.QueryOptions) anyerror!void {}

    fn next(transport: *qr.QueryTransport, allocator: std.mem.Allocator, _: u32) anyerror!?qr.QueryEvent {
        const self: *AckOnlyTransport = @ptrCast(@alignCast(transport.context));
        self.next_event_calls += 1;
        if (self.events_delivered == 0) {
            self.events_delivered += 1;
            // The exact shape built at quic_connection_handler.zig:5421-5426.
            return qr.QueryEvent{ .execute = .{
                .status = .{
                    .status_class = try allocator.dupe(u8, "00000"),
                    .additional_statuses = std.ArrayList([]const u8).empty,
                    .flagger_findings = std.ArrayList([]const u8).empty,
                },
                .payload = null,
            } };
        }
        // Nothing else is ever sent for an ALTER USER ack: the real transport
        // blocks here until the receive deadline elapses.
        return error.Timeout;
    }

    fn requestNextPage(
        _: *qr.QueryTransport,
        _: std.mem.Allocator,
        _: schema.PullRequest,
        _: u32,
    ) anyerror!?qr.QueryEvent {
        return error.Timeout;
    }
};

test "status-only success response terminates the collect loop instead of timing out (bug 731-4b)" {
    const allocator = testing.allocator;

    var fake = AckOnlyTransport{};
    var transport = fake.asTransport();

    var result = qr.collectQueryWithTransport(allocator, &transport, .{
        .session_id = "s-bug731",
        .query_text = "ALTER USER geode SET PASSWORD 'Bug731 Correct Horse Battery St4ple'",
        .format = "table",
        .timeout_secs = 1,
        .params = std.ArrayList(schema.Param).empty,
    }) catch |err| {
        // PRE-FIX: error.Timeout — the loop never terminates on a null payload,
        // which the CLI surfaces as the generic "Error: query execution failed"
        // (src/cli/main.zig:2536 -> :1698-1704) even though the write committed.
        std.debug.print(
            "\n[bug731-4b] collectQueryWithTransport returned {s} after {d} nextEvent call(s) for a status-00000 / payload-null ack\n",
            .{ @errorName(err), fake.next_event_calls },
        );
        return err;
    };
    defer result.deinit();

    try testing.expect(!result.has_error);
    try testing.expectEqualStrings("00000", result.status_class);
}

// ===========================================================================
// 10. PATH PIN (GREEN) — ALTER USER SET PASSWORD is handled by the WIRE
//     INTERCEPT, not by the GQL parser path that tests/test_auth_ddl_parser.zig
//     covers. Pinned so the fix lands on the code that actually executes:
//     quic_connection_handler.zig:6133-6141 matches the statement TEXTUALLY
//     before the parser ever sees it, routing to parseAlterUserSetPassword
//     (:5215) -> handleAlterUserSetPassword (:5344). The parser path
//     (src/gql/parser.zig:6516 -> src/execution/admin_ddl.zig:80 ->
//     src/execution/auth_dispatch.zig:837) is SHADOWED over the wire.
// ===========================================================================

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const buf = try allocator.alloc(u8, 4 * 1024 * 1024);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return allocator.realloc(buf, n);
}

test "ALTER USER SET PASSWORD is handled by the wire intercept, not the GQL parser path (path pin)" {
    const allocator = testing.allocator;

    const handler_src = try readSource(allocator, "src/server/quic_connection_handler.zig");
    defer allocator.free(handler_src);

    // The wire handler intercepts the statement text and dispatches to its own
    // handler; this is the code path a real ALTER USER SET PASSWORD executes.
    try testing.expect(std.mem.indexOf(u8, handler_src, "fn parseAlterUserSetPassword(") != null);
    try testing.expect(std.mem.indexOf(u8, handler_src, "fn handleAlterUserSetPassword(") != null);
    const intercept_call = std.mem.indexOf(u8, handler_src, "parseAlterUserSetPassword(query") orelse
        return error.WireInterceptMissing;
    const handler_call = std.mem.indexOf(u8, handler_src, "handleAlterUserSetPassword(gpa") orelse
        return error.WireHandlerCallMissing;
    try testing.expect(handler_call > intercept_call);

    // The shadowed parser path still exists — it is NOT what runs over the
    // wire, so a fix applied only there would not change observed behaviour.
    const dispatch_src = try readSource(allocator, "src/execution/auth_dispatch.zig");
    defer allocator.free(dispatch_src);
    try testing.expect(std.mem.indexOf(u8, dispatch_src, "fn handleUserResetPassword(") != null);
}
