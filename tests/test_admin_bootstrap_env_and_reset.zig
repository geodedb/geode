// Reproduction tests for two admin-bootstrap bugs reported on geode v0.5.11
// (HEAD commit bccd5bff). These tests are written BEFORE the fix and MUST
// fail today; they are committed first so the failure output is captured as
// proof that they exercise the bug, not the implementation.
//
// Bug 1 — environment-variable mismatch in `bootstrapDefaultAdmin`
//   src/security/auth_graph_manager.zig:618 reads only `GEODE_ADMIN_PASSWORD`,
//   while CLI usage strings (src/cli/main.zig:291,303) and the legacy auth
//   library (src/security/geode_auth_lib.zig:1235) advertise / consume
//   `GEODE_DEFAULT_PASSWORD`. Operators following the docs end up with a
//   server that ignored their seed password and minted a random one instead.
//   The triager recommends widening (not replacing) env-var support: prefer
//   `GEODE_ADMIN_PASSWORD` for backward compatibility, fall back to
//   `GEODE_DEFAULT_PASSWORD`. These tests pin that policy.
//
// Bug 1 (security follow-on)
//   src/server/server_init.zig:382 prints the generated admin password to
//   stderr via `std.debug.print`. Tests assert this disclosure does not
//   leak the password text.
//
// Bug 2 — offline `geode user reset-password` does not reach `serve` reload
//   The repro on disk shows two competing graph trees:
//     <data_dir>/graphs/<id>/...
//     <data_dir>/<id>/graphs/<id2>/...
//   so on a clean restart the engine sees an empty `__geode_security` graph
//   and re-bootstraps the admin from scratch. The mirror in this file
//   exercises the same code path the CLI uses (initCliAuthManager →
//   updateUserPassword → deinitAndSaveCliAuth), then re-opens the data dir
//   the same way `serve` does (initGlobalStore → loadUsersFromGraph) and
//   asserts the new hash survived.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;

const auth_graph_manager = @import("auth_graph_manager");
const geode_auth = @import("geode_auth");
const user_storage = @import("user_storage");
const cli_auth = @import("cli_auth_helpers");

// Zig 0.16 removed std.process.setEnvVar / std.posix.setenv; access libc
// directly to mutate the test process environment, matching the pattern
// the rest of the geode codebase uses for std.c.getenv.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const ADMIN_PASSWORD_ENV = "GEODE_ADMIN_PASSWORD";
const DEFAULT_PASSWORD_ENV = "GEODE_DEFAULT_PASSWORD";

fn setEnv(name: [:0]const u8, value: [:0]const u8) !void {
    if (setenv(name.ptr, value.ptr, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name.ptr);
}

// Drop both env vars so a test starts from a clean slate. Some test runners
// inherit these from the developer's shell.
fn clearAdminPasswordEnv() void {
    unsetEnv(ADMIN_PASSWORD_ENV);
    unsetEnv(DEFAULT_PASSWORD_ENV);
}

// -- Bug 1, Test 1 ---------------------------------------------------------
//
// `GEODE_DEFAULT_PASSWORD` (the documented variable) MUST be honoured by
// `bootstrapDefaultAdmin`. The persisted password hash must verify against
// the supplied plaintext.
//
// Today this test fails: the function only reads `GEODE_ADMIN_PASSWORD` and
// generates a random password instead, so verification of the documented
// password fails.
test "bootstrapDefaultAdmin honours documented GEODE_DEFAULT_PASSWORD env (regression)" {
    const allocator = testing.allocator;

    clearAdminPasswordEnv();
    try setEnv(DEFAULT_PASSWORD_ENV, "doc-seeded-pw-12345");
    defer unsetEnv(DEFAULT_PASSWORD_ENV);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        allocator.free(result.username);
        allocator.free(result.password);
    }

    const user = mgr.storage.getUser(result.user_id) orelse return error.UserNotFound;
    const stored_hash = user.password_hash[0..user.password_hash_len];

    const ok = try geode_auth.verifyPasswordArgon2id(allocator, "doc-seeded-pw-12345", stored_hash);
    try testing.expect(ok);
}

// -- Bug 1, Test 2 ---------------------------------------------------------
//
// Backward-compatibility test. `GEODE_ADMIN_PASSWORD` must still work after
// the fix (the triager's recommendation is to widen, not replace, env var
// support). This test passes today; it must continue to pass post-fix.
test "bootstrapDefaultAdmin still honours legacy GEODE_ADMIN_PASSWORD env" {
    const allocator = testing.allocator;

    clearAdminPasswordEnv();
    try setEnv(ADMIN_PASSWORD_ENV, "legacy-seeded-pw-67890");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        allocator.free(result.username);
        allocator.free(result.password);
    }

    const user = mgr.storage.getUser(result.user_id) orelse return error.UserNotFound;
    const stored_hash = user.password_hash[0..user.password_hash_len];

    const ok = try geode_auth.verifyPasswordArgon2id(allocator, "legacy-seeded-pw-67890", stored_hash);
    try testing.expect(ok);
}

// -- Bug 1, Test 3 ---------------------------------------------------------
//
// When BOTH env vars are set with different values, precedence MUST be
// deterministic. Per the triager's recommendation we pin
// `GEODE_ADMIN_PASSWORD` as the winner (backward compatibility for existing
// deployments). This test pins the policy so future drift is caught.
test "bootstrapDefaultAdmin: GEODE_ADMIN_PASSWORD wins when both env vars are set (regression)" {
    const allocator = testing.allocator;

    clearAdminPasswordEnv();
    try setEnv(ADMIN_PASSWORD_ENV, "winner-from-admin-env");
    try setEnv(DEFAULT_PASSWORD_ENV, "loser-from-default-env");
    defer unsetEnv(ADMIN_PASSWORD_ENV);
    defer unsetEnv(DEFAULT_PASSWORD_ENV);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        allocator.free(result.username);
        allocator.free(result.password);
    }

    const user = mgr.storage.getUser(result.user_id) orelse return error.UserNotFound;
    const stored_hash = user.password_hash[0..user.password_hash_len];

    // The admin-env password must verify…
    const wins = try geode_auth.verifyPasswordArgon2id(allocator, "winner-from-admin-env", stored_hash);
    try testing.expect(wins);

    // …and the default-env password must NOT.
    const loses = try geode_auth.verifyPasswordArgon2id(allocator, "loser-from-default-env", stored_hash);
    try testing.expect(!loses);
}

// -- Bug 1, Test 4 (security) ----------------------------------------------
//
// `BootstrapResult.password` must not be leaked to stderr by the bootstrap
// path itself. The pre-fix server-init code (server_init.zig:382) prints
// the generated password via `std.debug.print`. We can't easily intercept
// that print from a unit test, so we pin the SECONDARY contract that the
// bootstrap function does not contain a generated-password print-format
// string — the only operator-readable surface should be the structured
// `log.info` call (which redacts the value).
//
// This test fails today because server_init.zig still contains the
// `*** Generated admin password:` literal.
test "generated admin password is never printed to stderr (security regression)" {
    const allocator = testing.allocator;

    // Read the source of server_init.zig and assert the offending literal
    // is NOT present.  The triager's recommendation: route the password
    // through a structured (and redacted) channel, never std.debug.print.
    const src_path = "src/server/server_init.zig";
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, src_path, .{});
    defer file.close(io);

    // Read up to 1 MiB — server_init.zig is well under that today.
    const buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);

    // Pin the exact literal seen on HEAD (server_init.zig:382).
    const offender = "*** Generated admin password:";
    const found = std.mem.indexOf(u8, buf[0..n], offender) != null;
    try testing.expect(!found);
}

// -- Bug 2, Test 1 ---------------------------------------------------------
//
// Mirror the offline → reload sequence: bootstrap an admin in a temp dir,
// rotate the password via the same `updateUserPassword` call site that
// `geode user reset-password` uses, flush via `deinitAndSaveCliAuth`, then
// re-open the data dir the way `serve` does and assert the NEW hash is
// what `findUserByUsernameInGraph("geode")` returns.
test "offline reset-password persists across serve reload (regression)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build the absolute data-dir path the same way other adapter tests do.
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    try setEnv(ADMIN_PASSWORD_ENV, "initialpass1");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    const hmac_key = [_]u8{0xcd} ** 32;

    // ------ Step 1: bootstrap admin via the offline CLI path ------
    {
        var mgr = try cli_auth.initCliAuthManager(allocator, data_dir);
        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(bootstrap.username);
        allocator.free(bootstrap.password);
        cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
        graph_store.deinitGlobalStore();
    }

    // ------ Step 2: simulate `geode user reset-password geode` ------
    {
        var mgr = try cli_auth.initCliAuthManager(allocator, data_dir);
        const existing = mgr.storage.getUserByUsername("geode") orelse return error.UserMissingAfterBootstrap;

        const new_hash = try geode_auth.hashPasswordArgon2id(allocator, "newpass1234567");
        defer allocator.free(new_hash);

        _ = try mgr.updateUserPassword(&hmac_key, existing.id, new_hash);
        cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
        graph_store.deinitGlobalStore();
    }

    // ------ Step 3: re-open the data dir as `serve` would ------
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();

        const reloaded = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, "geode") orelse return error.UserMissingOnReload;
        const reloaded_hash = reloaded.password_hash[0..reloaded.password_hash_len];

        // The freshly-reloaded hash must verify against the NEW password,
        // not the bootstrap one.
        const new_ok = try geode_auth.verifyPasswordArgon2id(allocator, "newpass1234567", reloaded_hash);
        try testing.expect(new_ok);

        const old_ok = try geode_auth.verifyPasswordArgon2id(allocator, "initialpass1", reloaded_hash);
        try testing.expect(!old_ok);
    }
}

// -- Bug 2, Test 2 ---------------------------------------------------------
//
// Storage-layout invariant. The triager observed two competing graph trees
// — one at `<data_dir>/graphs/...` and one at `<data_dir>/<id>/graphs/<id2>/...`.
// This test asserts that after the offline reset path runs to completion,
// the data-dir contains exactly ONE `graphs/` root (the one a reload picks
// up). If a future regression re-introduces the divergent layout, this test
// fails fast.
test "offline reset-password writes a single graphs root (storage layout invariant)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    try setEnv(ADMIN_PASSWORD_ENV, "initialpass1");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    const hmac_key = [_]u8{0xee} ** 32;

    {
        var mgr = try cli_auth.initCliAuthManager(allocator, data_dir);
        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(bootstrap.username);
        allocator.free(bootstrap.password);
        cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
        graph_store.deinitGlobalStore();
    }

    {
        var mgr = try cli_auth.initCliAuthManager(allocator, data_dir);
        const existing = mgr.storage.getUserByUsername("geode") orelse return error.UserMissingAfterBootstrap;
        const new_hash = try geode_auth.hashPasswordArgon2id(allocator, "newpass1234567");
        defer allocator.free(new_hash);
        _ = try mgr.updateUserPassword(&hmac_key, existing.id, new_hash);
        cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
        graph_store.deinitGlobalStore();
    }

    // Walk the data_dir and count `graphs/` directories.
    var graph_root_count: usize = 0;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.basename, "graphs")) {
            graph_root_count += 1;
        }
    }

    // There should be exactly one `graphs/` root tree under data_dir. The
    // pre-fix bug produces two competing trees.
    try testing.expectEqual(@as(usize, 1), graph_root_count);
}

// -- Bug 2, Test 3 ---------------------------------------------------------
//
// Atomicity / chain-integrity: after an offline reset-password the chain
// must still verify on reload. This pins the property that geode does NOT
// half-commit the password rotation (record HMAC updated but chain seal
// stale, or vice-versa).
test "offline reset-password leaves a verifiable HMAC chain on reload (atomicity)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    try setEnv(ADMIN_PASSWORD_ENV, "initialpass1");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    const hmac_key = [_]u8{0xfa} ** 32;

    {
        var mgr = try cli_auth.initCliAuthManager(allocator, data_dir);
        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(bootstrap.username);
        allocator.free(bootstrap.password);
        cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
        graph_store.deinitGlobalStore();
    }

    {
        var mgr = try cli_auth.initCliAuthManager(allocator, data_dir);
        const existing = mgr.storage.getUserByUsername("geode") orelse return error.UserMissingAfterBootstrap;
        const new_hash = try geode_auth.hashPasswordArgon2id(allocator, "newpass1234567");
        defer allocator.free(new_hash);
        _ = try mgr.updateUserPassword(&hmac_key, existing.id, new_hash);
        cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
        graph_store.deinitGlobalStore();
    }

    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();

        var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
        defer mgr.deinit();

        // Chain must verify cleanly after reload — no manual reseal.
        try mgr.verifyChain(&hmac_key);
    }
}

// ===========================================================================
// -- Admin-password persistence across restart (2026-07-01 live incident) --
//
// Observed live: a geode server whose persisted admin password was A (set at
// first boot, later used successfully) was cleanly SIGTERM-shut-down while
// the serve script's environment carried GEODE_ADMIN_PASSWORD=B. After
// reopen only B authenticated — the persisted admin credential had been
// silently rotated to the env value.
//
// Mechanism: the first-boot bootstrap decision is gated ONLY on the
// IN-MEMORY view (`AuthGraphManager.hasAuthRecords()`, i.e. the user_cache
// populated by `loadUsersFromGraph`). Any boot where that load comes up
// empty while persisted records still exist on disk (hydration failure,
// storage-layout drift, partial crash recovery) is indistinguishable from a
// genuine first boot, so server-init re-runs `bootstrapDefaultAdmin` and
// re-seeds the admin from whatever GEODE_ADMIN_PASSWORD holds at restart
// time — destroying the persisted credential without any warning.
//
// Contract pinned here (persisted-credential precedence):
//   1. env password seeds the admin ONLY when no persisted admin exists;
//   2. an existing persisted credential survives restarts regardless of env;
//   3. when the in-memory load is empty but the ENGINE (on-disk label index,
//      load-independent) still reports persisted :User records,
//      `bootstrapDefaultAdmin` must REFUSE (error.PersistedAdminExists)
//      instead of silently rotating the credential.
// ===========================================================================

// Model of the degraded reload the live server hit: the on-disk state is
// intact but the in-memory caches loaded nothing. Wiping the caches after a
// healthy AGM.init reproduces exactly the state `hasAuthRecords()` sees when
// `loadUsersFromGraph` returns empty (getNodesByLabel -> null) while the
// engine still holds the records.
fn wipeInMemoryAuthCaches(mgr: *auth_graph_manager.AuthGraphManager) void {
    mgr.storage.user_cache.clearRetainingCapacity();
    mgr.storage.user_nodes.clearRetainingCapacity();
    mgr.storage.role_cache.clearRetainingCapacity();
    mgr.storage.role_nodes.clearRetainingCapacity();
    mgr.storage.permission_cache.clearRetainingCapacity();
    mgr.storage.permission_nodes.clearRetainingCapacity();
    mgr.storage.policy_cache.clearRetainingCapacity();
    mgr.storage.policy_nodes.clearRetainingCapacity();
    mgr.storage.graph_grant_nodes.clearRetainingCapacity();
}

// -- Persistence Test 1 (RED pre-fix) ---------------------------------------
//
// Degraded reload + changed env must NOT re-seed the admin from env.
test "bootstrapDefaultAdmin refuses env re-seed when persisted admin records exist on disk (restart rotation regression)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    defer clearAdminPasswordEnv();

    const hmac_key = [_]u8{0x11} ** 32;

    // ---- Boot 1: genuine first boot with env password A ----
    try setEnv(ADMIN_PASSWORD_ENV, "restartpassA1");
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
        try testing.expect(!mgr.hasAuthRecords());
        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(bootstrap.username);
        allocator.free(bootstrap.password);
        mgr.deinit();
        graph_store.getGlobalStore(allocator).saveIfDirty();
        graph_store.deinitGlobalStore(); // clean shutdown
    }

    // ---- Boot 2: restart with env password B; in-memory load degraded ----
    try setEnv(ADMIN_PASSWORD_ENV, "restartpassB2");
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
        defer {
            mgr.deinit();
            graph_store.deinitGlobalStore();
        }

        // Sanity: a HEALTHY reload sees the persisted records.
        try testing.expect(mgr.hasAuthRecords());

        // Degrade the in-memory view (see wipeInMemoryAuthCaches doc).
        wipeInMemoryAuthCaches(&mgr);
        try testing.expect(!mgr.hasAuthRecords());

        // PRE-FIX: this call succeeded and silently rotated the persisted
        // admin credential to "restartpassB2". POST-FIX: the engine-level
        // guard sees persisted :User records on disk and refuses.
        try testing.expectError(error.PersistedAdminExists, mgr.bootstrapDefaultAdmin(&hmac_key));
    }

    // ---- Boot 3: healthy reload — persisted credential must still be A ----
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();

        const reloaded = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, "geode") orelse return error.UserMissingOnReload;
        const hash = reloaded.password_hash[0..reloaded.password_hash_len];

        try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, "restartpassA1", hash));
        try testing.expect(!(try geode_auth.verifyPasswordArgon2id(allocator, "restartpassB2", hash)));
    }
}

// -- Persistence Test 2 ------------------------------------------------------
//
// Healthy restart with a CHANGED env password: records load, env is ignored,
// the persisted credential keeps authenticating (and the env value does not).
// This is the exact operator-visible contract from the incident report.
test "healthy restart with changed GEODE_ADMIN_PASSWORD keeps the persisted admin credential" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    defer clearAdminPasswordEnv();

    const hmac_key = [_]u8{0x22} ** 32;

    // Boot 1: first boot, env A.
    try setEnv(ADMIN_PASSWORD_ENV, "keeppassA1");
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(bootstrap.username);
        allocator.free(bootstrap.password);
        mgr.deinit();
        graph_store.getGlobalStore(allocator).saveIfDirty();
        graph_store.deinitGlobalStore();
    }

    // Boot 2: env changed to B. Mirror the server-init decision: records
    // exist -> env ignored -> NO bootstrap call. Persisted hash must still
    // verify A and reject B.
    try setEnv(ADMIN_PASSWORD_ENV, "keeppassB2");
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
        defer mgr.deinit();

        try testing.expect(mgr.hasAuthRecords()); // server-init takes the verify path, not bootstrap

        const reloaded = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, "geode") orelse return error.UserMissingOnReload;
        const hash = reloaded.password_hash[0..reloaded.password_hash_len];
        try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, "keeppassA1", hash));
        try testing.expect(!(try geode_auth.verifyPasswordArgon2id(allocator, "keeppassB2", hash)));
    }
}

// -- Persistence Test 3 ------------------------------------------------------
//
// The refusal guard must NOT false-positive on a genuine first boot with an
// ENGINE-BACKED store (fresh data dir): env password seeds the admin, no
// forced reset.
test "engine-backed first boot with env password still bootstraps (guard does not false-positive)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    defer clearAdminPasswordEnv();
    try setEnv(ADMIN_PASSWORD_ENV, "firstbootpass1");

    const hmac_key = [_]u8{0x33} ** 32;

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);

    try testing.expectEqualStrings("firstbootpass1", bootstrap.password);

    const user = mgr.storage.getUser(bootstrap.user_id) orelse return error.UserNotFound;
    // Env-seeded password: operator already knows it — no forced reset.
    try testing.expect(!user.password_reset_required);
    const hash = user.password_hash[0..user.password_hash_len];
    try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, "firstbootpass1", hash));
}

// -- Persistence Test 4 ------------------------------------------------------
//
// First boot with NO env password: a random 32-hex password is generated and
// the record demands a reset on first login. (The secret-free operator
// breadcrumb for this path is covered end-to-end by
// tests/test_first_boot_admin_password_breadcrumb.zig.)
test "first boot without env password autogenerates a 32-hex password with forced reset" {
    const allocator = testing.allocator;

    clearAdminPasswordEnv();
    defer clearAdminPasswordEnv();

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0x44} ** 32;
    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);

    try testing.expectEqual(@as(usize, 32), bootstrap.password.len);
    for (bootstrap.password) |c| {
        try testing.expect(std.ascii.isHex(c));
    }

    const user = mgr.storage.getUser(bootstrap.user_id) orelse return error.UserNotFound;
    try testing.expect(user.password_reset_required);
}

// ===========================================================================
// -- Review-0016 hardening: the guard's own failure modes -------------------
//
// Important-1: `countNodesByLabel(...) catch 0` treated ANY engine error as
// "first boot", so an open/IO failure on a REGISTERED security graph — the
// exact degraded-storage class the guard defends against — bypassed the guard
// and let the env re-seed the admin credential. Only error.GraphNotFound (the
// graph was never registered) may map to 0; everything else must REFUSE.
//
// Important-2 (half): bootstrap is not atomic — the :User node commits in its
// own engine txn before any credential property is written. A crash in that
// window used to make every subsequent boot refuse FOREVER with no working
// credential. Counting only credential-bearing records turns that artifact
// back into a recoverable first boot.
// ===========================================================================

// -- Review-0016 Test 1 (RED pre-fix) ----------------------------------------
//
// Engine error on a REGISTERED security graph must fail CLOSED, not read as
// first boot. Model: boot 1 persists an admin normally; then the security
// graph's on-disk directory (`{data_dir}/{uuid_hex}/`) is replaced with a
// plain FILE so every engine open fails with a real I/O-class error while the
// graph remains registered in graph_registry.dat. PRE-FIX: `catch 0` swallowed
// the error and bootstrap proceeded (env re-seed). POST-FIX: refusal.
test "bootstrapDefaultAdmin fails CLOSED when the registered security graph cannot be opened (engine error != first boot)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    defer clearAdminPasswordEnv();

    const hmac_key = [_]u8{0x55} ** 32;
    const io = std.Io.Threaded.global_single_threaded.io();

    // ---- Boot 1: genuine first boot with env password A ----
    try setEnv(ADMIN_PASSWORD_ENV, "enginefailpassA1");
    var security_uuid: [16]u8 = undefined;
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(bootstrap.username);
        allocator.free(bootstrap.password);
        security_uuid = graph_store.GraphStore.getGraphUuid(graph_store.SECURITY_GRAPH_NAME) orelse return error.SecurityGraphUuidMissing;
        mgr.deinit();
        graph_store.getGlobalStore(allocator).saveIfDirty();
        graph_store.deinitGlobalStore(); // clean shutdown
    }

    // ---- Corrupt: replace the security graph's engine directory with a
    // plain file. The registry still lists the graph, so the guard's count
    // hits `openGraphLocked` → ShardedGraphEngine.open → NotDir-class error. ----
    const hex = std.fmt.bytesToHex(security_uuid, .lower);
    {
        const engine_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, &hex });
        defer allocator.free(engine_dir);
        try std.Io.Dir.cwd().deleteTree(io, engine_dir);
        const f = try std.Io.Dir.cwd().createFile(io, engine_dir, .{});
        f.close(io);
    }

    // ---- Boot 2: restart with env password B against the degraded store ----
    try setEnv(ADMIN_PASSWORD_ENV, "enginefailpassB2");
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();

        // Two production shapes, both must fail CLOSED:
        //  (a) AGM.init survives with an empty in-memory view → the
        //      bootstrapDefaultAdmin guard must map the engine error to a
        //      refusal (PRE-FIX: `catch 0` bypassed it and env re-seeded).
        //  (b) AGM.init itself fails on the degraded store → server main
        //      takes the agm==null fallback, whose engine-level probe must
        //      fail CLOSED so ensureDefaultUser never seeds the env password.
        if (auth_graph_manager.AuthGraphManager.init(allocator, store)) |mgr_val| {
            var mgr = mgr_val;
            defer mgr.deinit();
            try testing.expect(!mgr.hasAuthRecords());
            try testing.expectError(error.PersistedAdminExists, mgr.bootstrapDefaultAdmin(&hmac_key));
        } else |init_err| {
            if (comptime @hasDecl(auth_graph_manager, "persistedSecurityUserCountOnDisk")) {
                try testing.expectError(error.PersistedAdminExists, auth_graph_manager.persistedSecurityUserCountOnDisk());
            } else {
                // PRE-FIX: no fail-closed probe exists — server main falls
                // through to ensureDefaultUser and activates the env
                // credential. Fail RED.
                std.debug.print("PRE-FIX fail-open: AGM.init failed ({s}) and no engine-level fail-closed probe exists for the agm==null fallback\n", .{@errorName(init_err)});
                return error.FailOpenNoProbe;
            }
        }
    }
}

// -- Review-0016 Test 2 (RED pre-fix) ----------------------------------------
//
// Half-bootstrap crash artifact: persisted :User record(s) that carry NO
// usable credential (bootstrap is not atomic — the :User node commits before
// `setNodePropertiesBatch` writes the credential; a crash in that window
// leaves label-indexed :User state with no password_hash anywhere).
//
// Fixture note: a STRICTLY propertyless node turned out not to resurface in
// the engine label index after a CLEAN-shutdown reopen (verified empirically
// — the pre-remodel fixture read count==0 at boot 2), so this test models the
// crash artifact as a persisted :User node whose password_hash is EMPTY while
// it IS visible to the label count and the in-memory load is degraded — the
// same credential-less class the WAL-replay path can produce after a real
// crash.
//
// PRE-FIX: the guard counted raw :User records → 1 → refuse FOREVER, with no
// credential that could ever log in and a reset-password escape hatch that
// cannot find the user. POST-FIX: the guard sees zero CREDENTIAL-BEARING
// records, treats the state as first boot, and re-seeds a working admin.
test "half-bootstrap artifact (credential-less :User records) is recoverable: bootstrap re-seeds instead of refusing forever" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    clearAdminPasswordEnv();
    defer clearAdminPasswordEnv();

    const hmac_key = [_]u8{0x66} ** 32;

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();

    // Persist an admin normally so the :User node is fully label-indexed…
    try setEnv(ADMIN_PASSWORD_ENV, "halfbootseedA1");
    var mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
    defer mgr.deinit();
    const seeded = try mgr.bootstrapDefaultAdmin(&hmac_key);
    const seeded_user_id = seeded.user_id;
    allocator.free(seeded.username);
    allocator.free(seeded.password);

    // …then destroy the credential on disk (empty password_hash) to model the
    // crash artifact, and wipe the in-memory view (degraded load).
    const user_node_id = mgr.storage.user_nodes.get(seeded_user_id) orelse return error.UserNodeMissing;
    try store.setNodeProperty(user_node_id, "password_hash", .{ .String = "" });
    wipeInMemoryAuthCaches(&mgr);
    try testing.expect(!mgr.hasAuthRecords());

    // Precondition: the ENGINE still reports the :User record (this is what
    // made the pre-refinement guard refuse forever).
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoGlobalAdapter;
    try testing.expectEqual(@as(u64, 1), try adapter.countNodesByLabel(graph_store.SECURITY_GRAPH_NAME, user_storage.USER_LABEL));

    // PRE-FIX: error.PersistedAdminExists (refuse forever — no credential
    // exists anywhere, so the operator is locked out with no escape).
    // POST-FIX: zero credential-bearing records → treated as first boot; the
    // env password seeds a REAL, working admin credential.
    try setEnv(ADMIN_PASSWORD_ENV, "halfbootpassB2");
    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(bootstrap.username);
    defer allocator.free(bootstrap.password);
    try testing.expectEqualStrings("halfbootpassB2", bootstrap.password);

    const user = mgr.storage.getUser(bootstrap.user_id) orelse return error.UserNotFound;
    const hash = user.password_hash[0..user.password_hash_len];
    try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, "halfbootpassB2", hash));
}

// -- Review-0016 Test 3 --------------------------------------------------------
//
// Unit-level pin of the fail-closed error mapping itself: ONLY GraphNotFound
// (never-registered security graph = genuine first boot) maps to zero; every
// other error refuses; successful counts pass through untouched.
test "failClosedPersistedUserCount: only GraphNotFound means first boot; all other errors refuse" {
    // The comptime @hasDecl gate lets this test FILE compile against the
    // PRE-FIX sources (where the helper does not exist) so the two behavioral
    // RED tests above can run and fail as bug proof; post-fix the helper
    // exists and the full body is analyzed and executed.
    if (comptime !@hasDecl(auth_graph_manager, "failClosedPersistedUserCount")) {
        return error.SkipZigTest;
    } else {
        // Genuine first boot: the registry has no __geode_security entry.
        try testing.expectEqual(@as(u64, 0), try auth_graph_manager.failClosedPersistedUserCount(error.GraphNotFound));

        // Successful counts pass through.
        try testing.expectEqual(@as(u64, 3), try auth_graph_manager.failClosedPersistedUserCount(@as(anyerror!u64, 3)));
        try testing.expectEqual(@as(u64, 0), try auth_graph_manager.failClosedPersistedUserCount(@as(anyerror!u64, 0)));

        // Degraded-storage class: open/IO/resource failures on a REGISTERED
        // graph must REFUSE (fail closed), never read as first boot.
        try testing.expectError(error.PersistedAdminExists, auth_graph_manager.failClosedPersistedUserCount(error.InputOutput));
        try testing.expectError(error.PersistedAdminExists, auth_graph_manager.failClosedPersistedUserCount(error.AccessDenied));
        try testing.expectError(error.PersistedAdminExists, auth_graph_manager.failClosedPersistedUserCount(error.NotDir));
        try testing.expectError(error.PersistedAdminExists, auth_graph_manager.failClosedPersistedUserCount(error.OutOfMemory));
        try testing.expectError(error.PersistedAdminExists, auth_graph_manager.failClosedPersistedUserCount(error.SystemFdQuotaExceeded));
    }
}
