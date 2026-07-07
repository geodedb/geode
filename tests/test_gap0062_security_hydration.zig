// GAP-0062 — ROOT CAUSE of the GAP-0061 auth lockout: the in-memory streaming
// hydration of `__geode_security` raises `error.DataCorruption` on an INTACT
// layout and QUARANTINES the whole graph, so ALL security records (users,
// roles, policies, HAS_ROLE assignments) become unavailable via the in-memory
// path (role_count = user_count = assignment_count = 0 after the quarantine).
//
// EXACT MECHANISM (pinned from the gs v0.2.34 on-disk format):
//   graph-storage v0.2.34 turned ADJACENCY SLAB PACKING on by default
//   (`config.adjacency_slab_packing = true` -> `adj_out.slab_packing = true`).
//   A node with a SMALL out-edge chain (the security graph's one HAS_ROLE edge
//   per user is the canonical case) has its edge run PACKED into a shared
//   adjacency slab block stamped `entry_format = ENTRY_FORMAT_SLAB (2)`, and
//   the node's `out_head` becomes a bit-63-tagged (block, slot) slab head ref
//   (`gs.adj_store.isSlabHead(out_head) == true`).
//
//   The streaming reader `src/storage/hydration_scan.zig` `scanAdjacency`
//   predates adjacency slab packing and understands ONLY legacy v1/v2 chain
//   blocks:
//     1. its sequential page sweep rejects `entry_format > ENTRY_FORMAT_V2`,
//        so a slab block (format 2) => error.DataCorruption; AND
//     2. its per-node chain walk treats `out_head` as a bare page id and does
//        `blocks.get(out_head)` — a tagged slab head is a huge value absent
//        from the block map => error.DataCorruption.
//   The engine-direct read path succeeds (AdjStore.expand handles slab heads),
//   which is why per-node reads work while whole-graph streaming hydration
//   fails — a FALSE POSITIVE over an intact layout, not real corruption.
//
// WHY security-graph-specific (not divelife): divelife's edge side is covered
// by loop2 counters snapshots so `skip_edge_scan == true` and pass 2 is
// skipped entirely; the tiny security graph has no such snapshots, so
// `scanAdjacency` runs and hits the slab block. (The GAP-0061 control test had
// ZERO edges, so its scanAdjacency loop body never executed — which is why
// that test's healthy reopen passed and this class was missed.)
//
// These tests build a FAITHFUL security graph (admin superuser + a NON-superuser
// with its own role + a policy + HAS_ROLE assignments) through the same
// UserStorageBackend the auth manager writes through, reopen (CLEAN and kill-9
// crash), and assert the graph hydrates WITHOUT quarantine: getNodesByLabel
// returns the users/roles/policies, role_count > 0, and the non-superuser's
// role RESOLVES (not just the superuser admin).
//
// RED at HEAD (pre-fix): the reopen's first getNodesByLabel triggers hydration,
// scanAdjacency throws DataCorruption on the slab-packed HAS_ROLE block, the
// graph is quarantined, and getNodesByLabel returns null -> the tests fail with
// error.SecurityGraphQuarantined_*.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;
const user_storage = @import("user_storage");

const SEC = graph_store.SECURITY_GRAPH_NAME;
const USER_LABEL = user_storage.USER_LABEL; // "User" (pub)
const ROLE_LABEL = "Role"; // user_storage.ROLE_LABEL is private
const POLICY_LABEL = "Policy"; // user_storage.POLICY_LABEL is private

// Zig 0.16: std.process.setEnvVar removed; use libc directly (same pattern as
// tests/test_gap0061_crash_auth.zig / tests/test_security_wal_durability.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnv(name: [:0]const u8, value: [:0]const u8) !void {
    if (setenv(name.ptr, value.ptr, 1) != 0) return error.SetEnvFailed;
}
fn unsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name.ptr);
}

const ADMIN_USER_ID: u64 = 1;
const ALICE_USER_ID: u64 = 2;
const ADMIN_ROLE_ID: u64 = 1;
const VIEWER_ROLE_ID: u64 = 2;
const POLICY_ID: u64 = 1;

const admin_hash = "argon2id$v=19$m=65536,t=3,p=4$YWRtaW5zYWx0$adminhashvalue0062A";
const alice_hash = "argon2id$v=19$m=65536,t=3,p=4$YWxpY2VzYWx0$alicehashvalue0062B";

/// Build a faithful `__geode_security` graph: a superuser admin AND a
/// non-superuser with its OWN role, HAS_ROLE assignments for both (each a
/// one-edge chain => slab-packed adjacency), and a policy. Mirrors the real
/// first-boot security graph shape that trips the streaming reader.
fn buildSecurityGraph(store: *graph_store.GraphStore) !void {
    var backend = try user_storage.UserStorageBackend.init(testing.allocator, store);
    defer backend.deinit();

    // Two users: a superuser admin and a non-superuser.
    _ = try backend.upsertManagedUser(.{
        .user_id = ADMIN_USER_ID,
        .username = "geode",
        .email = "admin@localhost",
        .password_hash = admin_hash,
        .is_active = true,
        .is_superuser = true,
    });
    _ = try backend.upsertManagedUser(.{
        .user_id = ALICE_USER_ID,
        .username = "alice",
        .email = "alice@localhost",
        .password_hash = alice_hash,
        .is_active = true,
        .is_superuser = false,
    });

    // Two roles: the system admin role and a custom viewer role.
    try backend.persistRole(ADMIN_ROLE_ID, "admin", "Default administrator role", 0, 100, true);
    try backend.persistRole(VIEWER_ROLE_ID, "viewer", "Read-only role", 0, 10, false);

    // HAS_ROLE assignments (each user->role a one-edge chain => slab-packed).
    try testing.expect(try backend.assignUserRole(ADMIN_USER_ID, ADMIN_ROLE_ID));
    try testing.expect(try backend.assignUserRole(ALICE_USER_ID, VIEWER_ROLE_ID));

    // A row-level-security policy node.
    try backend.persistPolicy(.{
        .policy_id = POLICY_ID,
        .name = "viewer_can_read",
        .description = "viewer read policy",
        .graph = "divelife",
        .table = "Taxon",
        .operation = 0,
        .permissive = true,
        .enabled = true,
        .using_clause = "true",
        .check_clause = null,
        .audit_level = 0,
        .created_by = ADMIN_USER_ID,
    });
}

/// Assert the reopened `store`'s `__geode_security` graph hydrates WITHOUT
/// quarantine: every label surface resolves (null == quarantined), roles load
/// (role_count > 0, not just the superuser), and the NON-superuser's HAS_ROLE
/// assignment resolves through the freshly-hydrated adjacency.
fn expectFullSecurityHydration(store: *graph_store.GraphStore) !void {
    // getNodesByLabel triggers ensureGraphHydrated -> the streaming scan. Under
    // the pre-fix quarantine this returns null; here it must return the nodes.
    const users = store.getNodesByLabel(SEC, USER_LABEL) orelse
        return error.SecurityGraphQuarantined_UsersUnavailable;
    try testing.expectEqual(@as(usize, 2), users.len);

    const roles = store.getNodesByLabel(SEC, ROLE_LABEL) orelse
        return error.SecurityGraphQuarantined_RolesUnavailable;
    try testing.expectEqual(@as(usize, 2), roles.len);

    const policies = store.getNodesByLabel(SEC, POLICY_LABEL) orelse
        return error.SecurityGraphQuarantined_PoliciesUnavailable;
    try testing.expect(policies.len >= 1);

    // Full auth cache reload (the SecurityManager hydration path): role_count
    // and user_count must be > 0, and the non-superuser's role must resolve
    // through the reconstructed HAS_ROLE adjacency edge.
    var backend = try user_storage.UserStorageBackend.init(testing.allocator, store);
    defer backend.deinit();

    try testing.expect(backend.user_cache.count() >= 2);
    try testing.expect(backend.role_cache.count() >= 2); // roles load, not just admin
    try testing.expect(backend.policy_cache.count() >= 1);

    // The NON-superuser's role assignment resolves (HAS_ROLE edge hydrated).
    const alice_roles = try backend.listUserRoleIds(testing.allocator, ALICE_USER_ID);
    defer testing.allocator.free(alice_roles);
    var found_viewer = false;
    for (alice_roles) |rid| {
        if (rid == VIEWER_ROLE_ID) found_viewer = true;
    }
    try testing.expect(found_viewer);
}

// ---------------------------------------------------------------------------
// Test 1 — CLEAN reopen: the intact security graph must hydrate fully (no
// quarantine) after a normal close/checkpoint.
// ---------------------------------------------------------------------------
test "gap0062: security graph with roles/policies/HAS_ROLE hydrates fully on clean reopen (no quarantine)" {
    const ta = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv("GEODE_ADMIN_PASSWORD");
    unsetEnv("GEODE_DEFAULT_PASSWORD");
    unsetEnv("GEODE_DISABLE_STREAMING_HYDRATION");
    // Force a GENUINE streaming scan on reopen (no loop2 snapshot short-circuit
    // makes `skip_edge_scan` true and skips pass 2) so this test deterministically
    // exercises scanAdjacency over the slab-packed HAS_ROLE block — matching the
    // real store, which reproduces on a CLEAN reopen too.
    try setEnv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST", "1");
    defer unsetEnv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST");

    // ---- Phase 1: build the security graph, CLEAN close (durable + slab
    // blocks checkpointed to the page store).
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        try buildSecurityGraph(store);
        graph_store.deinitGlobalStore();
    }

    // ---- Phase 2: reopen; the streaming hydration of __geode_security must
    // NOT quarantine on the slab-packed HAS_ROLE adjacency.
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();
        try expectFullSecurityHydration(store);
    }
}

// ---------------------------------------------------------------------------
// Test 2 — kill-9 crash reopen: the same graph, made durable by a clean
// close, then a hard crash (abandon without checkpoint) mid-session, must
// STILL hydrate fully through real WAL recovery (no quarantine).
// ---------------------------------------------------------------------------
test "gap0062: security graph hydrates fully after a kill-9 crash reopen (no quarantine)" {
    const ta = testing.allocator;
    const pa = std.heap.page_allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv("GEODE_ADMIN_PASSWORD");
    unsetEnv("GEODE_DEFAULT_PASSWORD");
    unsetEnv("GEODE_DISABLE_STREAMING_HYDRATION");
    // The security graph forces sync_each_commit even under a deferred adapter
    // knob, so an acknowledged mutation is on stable storage before the crash.
    try setEnv("GEODE_WAL_SYNC", "deferred");
    defer unsetEnv("GEODE_WAL_SYNC");
    // Force a genuine streaming scan on the crash reopen (see Test 1).
    try setEnv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST", "1");
    defer unsetEnv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST");

    // ---- Phase 1: build the graph, CLEAN close (durable manifest so Phase 3
    // exercises WAL recovery, not a never-checkpointed fresh-graph open).
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        try buildSecurityGraph(store);
        graph_store.deinitGlobalStore();
    }

    // ---- Phase 2: reopen with a leak-tolerant allocator, add one more
    // HAS_ROLE assignment (another slab-touching mutation), then HARD-crash
    // (abandon without close/checkpoint).
    {
        const store = try graph_store.initGlobalStore(pa, data_dir);
        var backend = try user_storage.UserStorageBackend.init(pa, store);
        // Give the non-superuser the admin role too (second slab-packed edge on
        // alice's chain — exercises slab growth + reopen).
        _ = backend.assignUserRole(ALICE_USER_ID, ADMIN_ROLE_ID) catch false;
        backend.deinit();
        graph_store.abandonGlobalStoreForCrashSim();
    }

    // ---- Phase 3: reopen after the crash; hydration must still succeed.
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();
        try expectFullSecurityHydration(store);
    }
}
