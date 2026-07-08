// GAP-0061 — CRITICAL crash-recovery auth lockout.
//
// Found by the fresh 14.27M close-out: after a kill -9 crash + reopen, the
// persisted admin credential FAILS TO LOAD and every query returns
// "Authentication failed" — the database is inaccessible (a hard enterprise
// blocker). Reproduced on /var/tmp/geode-14m-fresh-slab (g-2b56ad9f, gs
// v0.2.34): it fires on a CLEAN reopen too, so it is not a crash-tail loss.
//
// Root cause: the in-memory GraphStore hydration of `__geode_security` raises
// `error.DataCorruption` in the streaming slab reader (hydration_scan.zig),
// so `loadOneGraphFromAdapterFull` catches it and QUARANTINES the graph
// (pending_hydration entry done=true, failed=true). After that,
// `store.getNodesByLabel(__geode_security, "User")` returns null even though
// the storage ENGINE still holds intact, individually-readable :User records
// — proven at 14.27M by the admin-bootstrap guard, which read the same
// records engine-direct and REFUSED to re-seed
// (`persisted_user_records=1 usable_admin_records=1`). The server login
// resolver (`server/main.zig lookupPersistentAuthUser` ->
// `findUserByUsernameInGraph`) went through the SAME quarantined in-memory
// path and returned null, so the persisted credential could never load.
//
// Fix under test: `UserStorageBackend.findUserByUsernameInGraph` /
// `hasUserRecordsInGraph` / `listUsersFromGraph` fall back to an engine-direct
// (slot-space, IdMap-independent) read when the in-memory hydration is
// quarantined/empty — the exact reads the bootstrap guard already proves
// succeed post-crash. The persisted-credential-wins policy is unchanged; the
// fix only makes that credential reliably LOADABLE after a crash/degraded
// hydration.
//
// The quarantine is reproduced deterministically via
// `store.forceHydrationQuarantineForTest` (a test-only hook that puts the
// security graph into the exact done+failed terminal state the streaming
// DataCorruption produces, without needing the specific 14.27M slab layout
// that triggers it). Both tests persist the credential DURABLY (clean close /
// per-graph sync_each_commit) first, matching the real store, so the reopen
// exercises recovery — not a never-checkpointed fresh-graph open.
//
// RED at HEAD (pre-fix): `findUserByUsernameInGraph` returns null under the
// quarantine and the tests fail with `AdminCredentialLostAfterCrashQuarantine`.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;
const user_storage = @import("user_storage");

// Zig 0.16: std.process.setEnvVar removed; use libc directly (same pattern as
// tests/test_security_wal_durability.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const WAL_SYNC_ENV = "GEODE_WAL_SYNC";
const ADMIN_PASSWORD_ENV = "GEODE_ADMIN_PASSWORD";
const DEFAULT_PASSWORD_ENV = "GEODE_DEFAULT_PASSWORD";

fn setEnv(name: [:0]const u8, value: [:0]const u8) !void {
    if (setenv(name.ptr, value.ptr, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name.ptr);
}

fn captureWalBaseline(alloc: std.mem.Allocator, mg: anytype) ![]u64 {
    const base = try alloc.alloc(u64, mg.engine.shards.len);
    for (mg.engine.shards, 0..) |shard, i| {
        base[i] = shard.wal.inner.file_end;
    }
    return base;
}

/// Total WAL growth across `mg`'s shards since `base_end` — a sanity
/// observable that the credential write actually went through the engine WAL
/// (otherwise a crash-recovery test would be vacuous).
fn walGrowthSince(mg: anytype, base_end: []const u64) u64 {
    var growth: u64 = 0;
    for (mg.engine.shards, 0..) |shard, i| {
        growth += shard.wal.inner.file_end - @min(shard.wal.inner.file_end, base_end[i]);
    }
    return growth;
}

/// Assert every observable the server login resolver + bootstrap guard rely on
/// still resolve the admin from `store` under a quarantined security graph.
fn expectAdminLoadsUnderQuarantine(store: *graph_store.GraphStore, expect_hash: []const u8) !void {
    // Reproduce the streaming-hydration DataCorruption quarantine.
    try testing.expect(store.forceHydrationQuarantineForTest(graph_store.SECURITY_GRAPH_NAME));

    // Precondition: the in-memory label path is now null/empty — the exact
    // condition that locked admins out (getNodesByLabel returns null while the
    // engine still holds the record).
    const in_mem = store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, user_storage.USER_LABEL);
    try testing.expect(in_mem == null or in_mem.?.len == 0);

    // The persisted admin credential MUST still load (engine-direct fallback).
    // This is the login resolver's call site (lookupPersistentAuthUser).
    const reloaded = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, "geode") orelse
        return error.AdminCredentialLostAfterCrashQuarantine;
    try testing.expectEqualStrings(expect_hash, reloaded.password_hash[0..reloaded.password_hash_len]);
    // is_superuser must round-trip (role_resolver maps superuser -> Admin).
    try testing.expect(reloaded.is_superuser);
    try testing.expectEqualStrings("geode", reloaded.username[0..reloaded.username_len]);

    // hasUserRecordsInGraph (persistentAuthUsersExist) must also see it, so the
    // server keeps persistent-auth enabled instead of falling back.
    try testing.expect(user_storage.UserStorageBackend.hasUserRecordsInGraph(store));

    // listUsersFromGraph must enumerate the admin engine-direct too.
    const listed = try user_storage.UserStorageBackend.listUsersFromGraph(testing.allocator, store);
    defer testing.allocator.free(listed);
    var found = false;
    for (listed) |u| {
        if (std.mem.eql(u8, u.username[0..u.username_len], "geode")) found = true;
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------------
// Test 1 — clean-persisted admin (durable, like the real 14.27M store) must
// still LOAD after a reopen whose security-graph hydration is quarantined.
// ---------------------------------------------------------------------------
test "gap0061: durable admin credential loads after reopen when security-graph hydration is quarantined" {
    const ta = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv(ADMIN_PASSWORD_ENV);
    unsetEnv(DEFAULT_PASSWORD_ENV);
    try setEnv(WAL_SYNC_ENV, "deferred");
    defer unsetEnv(WAL_SYNC_ENV);

    const admin_hash = "argon2id$v=19$m=65536,t=3,p=4$YWRtaW5zYWx0$adminhashvalue0001";

    // ---- Phase 1: persist a SUPERUSER admin, CLEAN close (durable baseline).
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        var backend = try user_storage.UserStorageBackend.init(ta, store);
        _ = try backend.upsertManagedUser(.{
            .user_id = 1,
            .username = "geode",
            .email = "admin@localhost",
            .password_hash = admin_hash,
            .is_active = true,
            .is_superuser = true,
        });
        backend.deinit();
        graph_store.deinitGlobalStore();
    }

    // ---- Phase 2: reopen, quarantine the security-graph hydration, assert the
    // persisted admin credential STILL loads.
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();
        try expectAdminLoadsUnderQuarantine(store, admin_hash);
    }
}

// ---------------------------------------------------------------------------
// Test 2 — deferred-WAL + crash-tail: a credential rotation acknowledged under
// GEODE_WAL_SYNC=deferred survives a HARD crash (the security graph's per-graph
// sync_each_commit carve-out keeps it durable), and STILL loads after a reopen
// whose hydration is quarantined.
// ---------------------------------------------------------------------------
test "gap0061: rotated credential survives hard crash + quarantined reopen (deferred WAL)" {
    const ta = testing.allocator;
    const pa = std.heap.page_allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv(ADMIN_PASSWORD_ENV);
    unsetEnv(DEFAULT_PASSWORD_ENV);
    try setEnv(WAL_SYNC_ENV, "deferred");
    defer unsetEnv(WAL_SYNC_ENV);

    const initial_hash = "argon2id$v=19$m=65536,t=3,p=4$YWRtaW5zYWx0$adminhashvalue000A";
    const rotated_hash = "argon2id$v=19$m=65536,t=3,p=4$cm90YXRlc2FsdA$adminhashvalue000B";

    // ---- Phase 1: bootstrap admin, CLEAN close (durable manifest so the
    // Phase 3 reopen exercises WAL recovery, not a never-checkpointed open).
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        var backend = try user_storage.UserStorageBackend.init(ta, store);
        _ = try backend.upsertManagedUser(.{
            .user_id = 1,
            .username = "geode",
            .email = "admin@localhost",
            .password_hash = initial_hash,
            .is_active = true,
            .is_superuser = true,
        });
        backend.deinit();
        graph_store.deinitGlobalStore();
    }

    // ---- Phase 2: rotate the credential under deferred WAL, then HARD-crash
    // (abandon without checkpoint). The security graph is sync_each_commit, so
    // the acknowledged rotation is already on stable storage.
    {
        const store = try graph_store.initGlobalStore(pa, data_dir);
        var backend = try user_storage.UserStorageBackend.init(pa, store);

        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        const mg_sec = try adapter.getOrCreateGraph(graph_store.SECURITY_GRAPH_NAME);
        const base_end = try captureWalBaseline(pa, mg_sec);

        _ = try backend.upsertManagedUser(.{
            .user_id = 1,
            .username = "geode",
            .email = "admin@localhost",
            .password_hash = rotated_hash,
            .is_active = true,
            .is_superuser = true,
            .bump_auth_version = true,
        });

        // Sanity: the rotation went through the engine WAL.
        try testing.expect(walGrowthSince(mg_sec, base_end) > 0);

        backend.deinit();
        graph_store.abandonGlobalStoreForCrashSim();
    }

    // ---- Phase 3: reopen (real WAL recovery), quarantine the hydration, and
    // assert the ROTATED credential loaded (old rejected implicitly — only the
    // rotated hash is present).
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();
        try expectAdminLoadsUnderQuarantine(store, rotated_hash);
    }
}

// ---------------------------------------------------------------------------
// Control — a HEALTHY (non-quarantined) reopen still loads the admin via the
// in-memory path: the engine-direct fallback must not regress the normal path.
// ---------------------------------------------------------------------------
test "gap0061: healthy reopen still loads the admin via the in-memory path" {
    const ta = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv(ADMIN_PASSWORD_ENV);
    unsetEnv(DEFAULT_PASSWORD_ENV);
    try setEnv(WAL_SYNC_ENV, "deferred");
    defer unsetEnv(WAL_SYNC_ENV);

    const admin_hash = "argon2id$v=19$m=65536,t=3,p=4$YWRtaW5zYWx0$adminhashvalue0002";

    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        var backend = try user_storage.UserStorageBackend.init(ta, store);
        _ = try backend.upsertManagedUser(.{
            .user_id = 1,
            .username = "geode",
            .email = "admin@localhost",
            .password_hash = admin_hash,
            .is_active = true,
            .is_superuser = true,
        });
        backend.deinit();
        graph_store.deinitGlobalStore();
    }

    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();

        // No quarantine: normal hydration serves the record.
        const reloaded = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, "geode") orelse
            return error.AdminMissingOnHealthyReopen;
        try testing.expectEqualStrings(admin_hash, reloaded.password_hash[0..reloaded.password_hash_len]);
        try testing.expect(reloaded.is_superuser);
    }
}
