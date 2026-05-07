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
