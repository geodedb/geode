// SONNY-6708: a first boot killed (SIGKILL, OOM kill, crash, power loss) after
// the admin credential is persisted and before the HMAC chain is sealed left a
// data directory every later start refused with AuthChainTampered
// (MissingChainRoot): `bootstrapDefaultAdmin` is not atomic - it persists the
// admin :User, the `admin` role and the HAS_ROLE edge, and only then seals the
// chain (writes the AuthChainRoot). The next start finds auth records, sees
// no root, and reports tampering although nothing was tampered with.
//
// The contract pinned here:
//   * a store holding exactly the records a first boot writes before its seal
//     (the one admin user, optionally the bootstrap's `admin` role) and no
//     AuthChainRoot is an INTERRUPTED BOOTSTRAP: `recoverInterruptedBootstrap`
//     discards those records and reports true, so the start proceeds as a
//     first boot (a fresh admin is seeded and the chain seals and verifies);
//   * a missing root over ANY other state - a second user, a grant, a policy -
//     is not that artifact: nothing is discarded, and verifyChain still
//     reports MissingChainRoot (the tamper signal stays loud);
//   * a store that has its root is untouched.
//
// CANARY: REQ=REQ-SONNY-6708-INTERRUPTED-FIRST-BOOT; FEATURE="AuthGraphManager Bootstrap"; ASPECT=CrashSafeFirstBoot; STATUS=TESTED; TEST=tests/test_sonny6708_interrupted_first_boot.zig; OWNER=security; UPDATED=2026-11-17

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;

const auth_graph_manager = @import("auth_graph_manager");
const geode_auth = @import("geode_auth");
const user_storage = @import("user_storage");

const AuthGraphManager = auth_graph_manager.AuthGraphManager;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const ADMIN_PASSWORD_ENV = "GEODE_ADMIN_PASSWORD";
const hmac_key = [_]u8{0x6d} ** 32;

fn setAdminPassword(value: [:0]const u8) !void {
    if (setenv(ADMIN_PASSWORD_ENV, value.ptr, 1) != 0) return error.SetEnvFailed;
}

fn clearAdminPassword() void {
    _ = unsetenv(ADMIN_PASSWORD_ENV);
}

fn dataDir(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

/// A full first boot in `data_dir`, then the crash artifact: the process died
/// after the admin was persisted and before the seal wrote the AuthChainRoot.
fn firstBootKilledBeforeSeal(allocator: std.mem.Allocator, data_dir: []const u8, keep_role: bool) !void {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();

    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    try setAdminPassword("Interrupted Boot Seed Pass A1");
    const seeded = try mgr.bootstrapDefaultAdmin(&hmac_key);
    allocator.free(seeded.username);
    allocator.free(seeded.password);

    // The kill: no root was written.
    const roots = store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, "AuthChainRoot") orelse return error.NoChainRoot;
    const owned = try allocator.dupe(u64, roots);
    defer allocator.free(owned);
    for (owned) |id| store.deleteNode(id);

    if (!keep_role) {
        // Killed even earlier: after the credential, before the role.
        const role_nodes = store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, "Role") orelse return error.NoRole;
        const owned_roles = try allocator.dupe(u64, role_nodes);
        defer allocator.free(owned_roles);
        for (owned_roles) |id| store.deleteNode(id);
    }
}

test "SONNY-6708: an interrupted first boot (admin persisted, chain never sealed) is recovered, not reported as tampering" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try dataDir(allocator, &tmp);
    defer allocator.free(dir);
    defer clearAdminPassword();

    try firstBootKilledBeforeSeal(allocator, dir, true);

    // The next start, as server_init does it.
    const store = try graph_store.initGlobalStore(allocator, dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    // Precondition: the artifact - records on disk, no root, the tamper verdict.
    try testing.expect(mgr.hasAuthRecords());
    try testing.expectError(error.MissingChainRoot, mgr.verifyChain(&hmac_key));

    // PRE-FIX: nothing recovers it (the start refuses forever with
    // AuthChainTampered). POST-FIX: the interrupted bootstrap is discarded.
    const recovered = if (comptime @hasDecl(AuthGraphManager, "recoverInterruptedBootstrap"))
        try mgr.recoverInterruptedBootstrap()
    else
        false;
    try testing.expect(recovered);
    try testing.expect(!mgr.hasAuthRecords());

    // ...and the start goes on as a first boot: a working admin is seeded and
    // the chain seals and verifies.
    try setAdminPassword("Interrupted Boot Seed Pass B2");
    const boot = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(boot.username);
    defer allocator.free(boot.password);
    try testing.expectEqualStrings("Interrupted Boot Seed Pass B2", boot.password);
    const user = mgr.storage.getUser(boot.user_id) orelse return error.UserNotFound;
    try testing.expect(try geode_auth.verifyPasswordArgon2id(allocator, "Interrupted Boot Seed Pass B2", user.password_hash[0..user.password_hash_len]));
    try mgr.verifyChain(&hmac_key);
}

test "SONNY-6708: a boot killed between the credential and the role is recovered too" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try dataDir(allocator, &tmp);
    defer allocator.free(dir);
    defer clearAdminPassword();

    try firstBootKilledBeforeSeal(allocator, dir, false);

    const store = try graph_store.initGlobalStore(allocator, dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    try testing.expect(mgr.hasAuthRecords());
    const recovered = if (comptime @hasDecl(AuthGraphManager, "recoverInterruptedBootstrap"))
        try mgr.recoverInterruptedBootstrap()
    else
        false;
    try testing.expect(recovered);
    try testing.expect(!mgr.hasAuthRecords());

    try setAdminPassword("Interrupted Boot Seed Pass C3");
    const boot = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer allocator.free(boot.username);
    defer allocator.free(boot.password);
    try mgr.verifyChain(&hmac_key);
}

test "SONNY-6708: a missing root over more than the bootstrap's own records stays the tamper signal" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try dataDir(allocator, &tmp);
    defer allocator.free(dir);
    defer clearAdminPassword();

    {
        // A healthy first boot, then a second user: real auth state.
        const store = try graph_store.initGlobalStore(allocator, dir);
        defer graph_store.deinitGlobalStore();
        var mgr = try AuthGraphManager.init(allocator, store);
        defer mgr.deinit();
        try setAdminPassword("Interrupted Boot Seed Pass D4");
        const seeded = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(seeded.username);
        allocator.free(seeded.password);
        const hash = try geode_auth.hashPasswordArgon2id(allocator, "Second User Pass Phrase E5");
        defer allocator.free(hash);
        _ = try mgr.createUser(&hmac_key, "second", "second@localhost", hash, false);
        // Somebody deletes the root.
        const roots = store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, "AuthChainRoot") orelse return error.NoChainRoot;
        const owned = try allocator.dupe(u64, roots);
        defer allocator.free(owned);
        for (owned) |id| store.deleteNode(id);
    }

    const store = try graph_store.initGlobalStore(allocator, dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const recovered = if (comptime @hasDecl(AuthGraphManager, "recoverInterruptedBootstrap"))
        try mgr.recoverInterruptedBootstrap()
    else
        false;
    try testing.expect(!recovered);
    try testing.expect(mgr.hasAuthRecords());
    try testing.expectError(error.MissingChainRoot, mgr.verifyChain(&hmac_key));
}

test "SONNY-6708: a store with its chain root is left alone" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try dataDir(allocator, &tmp);
    defer allocator.free(dir);
    defer clearAdminPassword();

    {
        const store = try graph_store.initGlobalStore(allocator, dir);
        defer graph_store.deinitGlobalStore();
        var mgr = try AuthGraphManager.init(allocator, store);
        defer mgr.deinit();
        try setAdminPassword("Interrupted Boot Seed Pass F6");
        const seeded = try mgr.bootstrapDefaultAdmin(&hmac_key);
        allocator.free(seeded.username);
        allocator.free(seeded.password);
    }

    const store = try graph_store.initGlobalStore(allocator, dir);
    defer graph_store.deinitGlobalStore();
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const recovered = if (comptime @hasDecl(AuthGraphManager, "recoverInterruptedBootstrap"))
        try mgr.recoverInterruptedBootstrap()
    else
        false;
    try testing.expect(!recovered);
    try testing.expect(mgr.hasAuthRecords());
    try mgr.verifyChain(&hmac_key);
}
