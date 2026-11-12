// Security-graph WAL durability under GEODE_WAL_SYNC=deferred (gap 0026,
// data-ingest security review, 2026-07-01).
//
// GAP-0900 introduced `GEODE_WAL_SYNC=deferred`: the adapter-wide
// `GraphConfig.sync_mode = .deferred` skips the per-commit WAL fsync so bulk
// ingest is not fsync-bound. The mode's contract is "replayable loads only" —
// but it applied to EVERY graph, including `__geode_security`. A security
// mutation (admin credential rotation, user/role/policy/grant change, HMAC
// chain reseal) is NOT replayable: if the commit is acknowledged but the WAL
// tail never reaches stable storage before a hard crash, the mutation is
// silently lost and the OLD credential works again after restart. This was
// observed live: persisted admin hash == env seed with an EMPTY
// security-graph WAL after an unclean restart.
//
// Fix under test: per-graph carve-out in the storage adapter
// (`createGraphLocked` / `openGraphLocked`) that forces the
// `__geode_security` engines to `.sync_each_commit` regardless of the
// operator knob. Bulk graphs keep the adapter-wide mode.
//
// These tests are written RED-first at HEAD (pre-fix):
//   1. mechanism  — security-graph shard TxnManagers must report
//      `sync_each_commit` under a deferred adapter config (create AND reopen
//      paths); bulk graphs must still report `deferred` (the bulk-ingest
//      "unaffected" observable: the carve-out is per-graph by construction —
//      each graph engine gets its own `GraphConfig` copy, and only the
//      `__geode_security` copy is overridden).
//   2. storage-level crash — create a security user under deferred WAL,
//      HARD-crash with a power-loss simulation, reopen: the user must exist.
//   3. crash e2e  — bootstrap admin (clean close), rotate the credential via
//      the same `updateUserPassword` call site the CLI reset-password path
//      uses, HARD-crash, reopen: the rotation must have survived (new
//      password verifies, old rejected).
//
// Power-loss simulation honesty (`simulatePowerLossOnGraph`): a power loss
// destroys exactly the WAL bytes that were never fsynced. The graph WAL runs
// `manual_sync = true` — the ONLY fsyncs are the per-commit `wal.sync()`
// under `sync_each_commit` and the checkpoint barrier (none runs in these
// short phases). So per shard:
//   * `.deferred`         — no commit ever fsynced; ALL growth past the
//     phase-open baseline is un-fsynced and is destroyed (truncated).
//   * `.sync_each_commit` — every acknowledged commit was fsynced before its
//     call returned (the WAL library contract, pinned upstream by
//     graph-storage's PERF-0045 durability gate tests); stable storage
//     already holds the tail, so nothing is destroyed.
// The reopen after the crash then exercises REAL recovery: the store is
// abandoned without close/checkpoint, so the reloaded state comes from
// page-store + WAL replay only.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;

const geode_auth = @import("geode_auth");
const user_storage = @import("user_storage");
const cli_auth = @import("cli_auth_helpers");

// Zig 0.16: std.process.setEnvVar/std.posix.setenv removed; use libc directly
// (same pattern as tests/test_admin_bootstrap_env_and_reset.zig).
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

fn clearAdminPasswordEnv() void {
    unsetEnv(ADMIN_PASSWORD_ENV);
    unsetEnv(DEFAULT_PASSWORD_ENV);
}

/// Capture the per-shard WAL sizes of `mg` — the durability-barrier baseline
/// for a subsequent `simulatePowerLossOnGraph`. Allocated with `alloc`
/// (crash phases pass a leak-tolerant allocator; the abandoned store leaks
/// by design, mirroring a hard kill).
fn captureWalBaseline(alloc: std.mem.Allocator, mg: anytype) ![]u64 {
    const base = try alloc.alloc(u64, mg.engine.shards.len);
    for (mg.engine.shards, 0..) |shard, i| {
        base[i] = shard.wal.inner.file_end;
    }
    return base;
}

/// Destroy exactly the WAL bytes a real power loss would destroy — see the
/// file header for the honesty argument. Must be called BEFORE
/// `graph_store.abandonGlobalStoreForCrashSim` (the shard WAL handles must
/// still be live) and after the last mutation of the crash phase.
fn simulatePowerLossOnGraph(mg: anytype, base_end: []const u64) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    for (mg.engine.shards, 0..) |shard, i| {
        if (std.mem.eql(u8, @tagName(shard.txn_manager.sync_mode), "deferred")) {
            if (shard.wal.inner.file_end > base_end[i]) {
                try shard.wal.inner.file.setLength(io, base_end[i]);
            }
        }
    }
}

/// Total WAL growth across `mg`'s shards since `base_end` — sanity
/// observable that the mutation under test actually went through the
/// engine WAL (otherwise the power-loss simulation would be vacuous).
fn walGrowthSince(mg: anytype, base_end: []const u64) u64 {
    var growth: u64 = 0;
    for (mg.engine.shards, 0..) |shard, i| {
        growth += shard.wal.inner.file_end - @min(shard.wal.inner.file_end, base_end[i]);
    }
    return growth;
}

// ---------------------------------------------------------------------------
// Test 1 — mechanism: per-graph sync-mode carve-out (create + reopen paths)
// ---------------------------------------------------------------------------
//
// RED at HEAD: the adapter copies its global config verbatim into every
// graph engine, so the security-graph shards report `deferred`.
test "gap0026: security graph forces sync_each_commit under deferred adapter config (create + reopen); bulk graphs stay deferred" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    try setEnv(WAL_SYNC_ENV, "deferred");
    defer unsetEnv(WAL_SYNC_ENV);

    // Phase A — fresh CREATE path (createGraphLocked).
    {
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();

        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        const mg_sec = try adapter.getOrCreateGraph(graph_store.SECURITY_GRAPH_NAME);
        const mg_bulk = try adapter.getOrCreateGraph("bulk_ingest_graph");

        for (mg_sec.engine.shards) |shard| {
            try testing.expectEqualStrings("sync_each_commit", @tagName(shard.txn_manager.sync_mode));
        }
        // Bulk-ingest regression observable: normal graphs must keep the
        // operator-selected deferred mode — the carve-out is per-graph.
        for (mg_bulk.engine.shards) |shard| {
            try testing.expectEqualStrings("deferred", @tagName(shard.txn_manager.sync_mode));
        }
    }

    // Phase B — REOPEN path (openGraphLocked): the carve-out must also hold
    // for a security graph loaded from the on-disk registry.
    {
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();

        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        const mg_sec = try adapter.getOrCreateGraph(graph_store.SECURITY_GRAPH_NAME);
        const mg_bulk = try adapter.getOrCreateGraph("bulk_ingest_graph");

        for (mg_sec.engine.shards) |shard| {
            try testing.expectEqualStrings("sync_each_commit", @tagName(shard.txn_manager.sync_mode));
        }
        for (mg_bulk.engine.shards) |shard| {
            try testing.expectEqualStrings("deferred", @tagName(shard.txn_manager.sync_mode));
        }
    }
}

// ---------------------------------------------------------------------------
// Test 2 — storage-level crash: a security user CREATED under deferred WAL
// survives a hard crash before any checkpoint barrier.
// ---------------------------------------------------------------------------
//
// Exercises the `UserStorageBackend.persistUser` entry point (the same
// backend the auth manager writes through) without the CLI/bootstrap layers.
//
// RED at HEAD: the security graph runs `.deferred`, the acknowledged
// `persistUser` commit never reached stable storage, the power-loss
// simulation destroys it, and the reopened store has no such user.
test "gap0026: security user created under deferred WAL survives hard crash" {
    const ta = testing.allocator;
    const pa = std.heap.page_allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    try setEnv(WAL_SYNC_ENV, "deferred");
    defer unsetEnv(WAL_SYNC_ENV);

    const fake_hash = "argon2id$v=19$m=65536,t=3,p=4$fakesalt$fakehash";

    // ---- Crash phase (leak-tolerant allocator: a hard kill frees nothing).
    {
        const store = try graph_store.initGlobalStore(pa, data_dir);
        var backend = try user_storage.UserStorageBackend.init(pa, store);

        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        const mg_sec = try adapter.getOrCreateGraph(graph_store.SECURITY_GRAPH_NAME);
        const base_end = try captureWalBaseline(pa, mg_sec);

        // Security mutation, acknowledged to the caller.
        try backend.persistUser(41, "wal_durability_user", "wal@example.com", fake_hash, "salt1234");

        // Sanity: the mutation went through the engine WAL (otherwise the
        // power-loss simulation below would be vacuous).
        try testing.expect(walGrowthSince(mg_sec, base_end) > 0);

        backend.deinit();
        try simulatePowerLossOnGraph(mg_sec, base_end);
        graph_store.abandonGlobalStoreForCrashSim();
    }

    // ---- Restart: the acknowledged security mutation MUST still exist.
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();

        const reloaded = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, "wal_durability_user") orelse return error.SecurityMutationLostAfterCrash;
        try testing.expectEqualStrings(fake_hash, reloaded.password_hash[0..reloaded.password_hash_len]);
    }
}

// ---------------------------------------------------------------------------
// Test 3 — end-to-end: credential rotation survives a hard crash under
// deferred WAL; the old credential is rejected after restart.
// ---------------------------------------------------------------------------
//
// Mirrors the live forensic sequence: bootstrap admin (clean close, durable),
// rotate the password via the same `updateUserPassword` call site the CLI
// reset-password path uses, then HARD-crash before any checkpoint. The crash
// phase uses `std.heap.page_allocator` because the abandoned store/adapter
// intentionally leak (a hard kill frees nothing);
// `graph_store.abandonGlobalStoreForCrashSim` drops the globals without the
// `checkpointAll` that the ordinary teardown paths run (which would mask the
// loss window). Power-loss simulation per the file header.
//
// RED at HEAD: the rotation commit was acknowledged without fsync, the WAL
// tail is lost, and the reopened store still authenticates the OLD password.
test "gap0026: credential rotation survives hard crash under deferred WAL (old credential rejected)" {
    const ta = testing.allocator;
    const pa = std.heap.page_allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    clearAdminPasswordEnv();
    try setEnv(WAL_SYNC_ENV, "deferred");
    defer unsetEnv(WAL_SYNC_ENV);
    try setEnv(ADMIN_PASSWORD_ENV, "Initial Admin Seed Passphrase");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    const hmac_key = [_]u8{0x5a} ** 32;

    // ---- Phase 1: bootstrap admin, CLEAN close (durable baseline even
    // under deferred WAL — clean close checkpoints). ----
    {
        var mgr = try cli_auth.initCliAuthManager(pa, data_dir);
        const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
        pa.free(bootstrap.username);
        pa.free(bootstrap.password);
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
    }

    // ---- Phase 2: rotate the credential under deferred WAL, then
    // HARD-crash with power-loss simulation. ----
    {
        var mgr = try cli_auth.initCliAuthManager(pa, data_dir);
        const existing = mgr.storage.getUserByUsername("geode") orelse return error.UserMissingAfterBootstrap;

        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        const mg_sec = try adapter.getOrCreateGraph(graph_store.SECURITY_GRAPH_NAME);

        // Pre-rotation WAL sizes per shard (the durability-barrier state:
        // phase 1 closed cleanly, so everything before this point is
        // checkpointed/durable).
        const base_end = try captureWalBaseline(pa, mg_sec);

        const new_hash = try geode_auth.hashPasswordArgon2id(pa, "rotatedpass99");
        _ = try mgr.updateUserPassword(&hmac_key, existing.id, new_hash);
        pa.free(new_hash);

        // Sanity: the rotation went through the engine WAL (otherwise the
        // power-loss simulation below would be vacuous).
        try testing.expect(walGrowthSince(mg_sec, base_end) > 0);

        // Auth manager teardown only (no persistence side effects) so the
        // storage backend caches are not left running; the STORE is what
        // crashes, below.
        mgr.deinit();

        // POWER-LOSS SIMULATION + HARD CRASH: destroy exactly the WAL bytes
        // that never reached stable storage, then drop all globals with no
        // close / checkpoint / free.
        try simulatePowerLossOnGraph(mg_sec, base_end);
        graph_store.abandonGlobalStoreForCrashSim();
    }

    // ---- Phase 3: restart as `serve` would. The rotation must have
    // survived: new password verifies, old is rejected. ----
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();

        const reloaded = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, "geode") orelse return error.UserMissingOnReload;
        const reloaded_hash = reloaded.password_hash[0..reloaded.password_hash_len];

        const new_ok = try geode_auth.verifyPasswordArgon2id(ta, "rotatedpass99", reloaded_hash);
        try testing.expect(new_ok);

        const old_ok = try geode_auth.verifyPasswordArgon2id(ta, "Initial Admin Seed Passphrase", reloaded_hash);
        try testing.expect(!old_ok);
    }
}
