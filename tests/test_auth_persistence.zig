// tests/test_auth_persistence.zig
//
// Unit tests for auth DDL persistence write-through callbacks and per-graph grants.
// Three test groups:
//   1. PersistentUserWriter invocation — verifies all 5 callbacks fire (or don't fire) correctly.
//   2. setUserActive semantics — idempotency + auth_version bumping.
//   3. GraphRBACPolicy grant round-trip — grantGraphPermission / hasGraphGrant /
//      revokeGraphPermission / loadGraphGrants.
//
// CANARY: REQ=REQ-AUTH-PERSIST-UNIT-001; FEATURE="AuthDDLPersistence"; ASPECT=WriterCallbacks; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-11
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-022; FEATURE="AuthDDLPersistence"; ASPECT=GrantGraphPermission; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const user_mgmt = geode.user_management;
const multi_graph = geode.multi_graph_security;

// ============================================================================
// Fake writer state — tracks all callback invocations.
// ============================================================================

const FakeWriterState = struct {
    creates: u32 = 0,
    deletes: u32 = 0,
    pw_updates: u32 = 0,
    role_sets: u32 = 0,
    active_sets: u32 = 0,
    last_username: [128]u8 = [_]u8{0} ** 128,
    last_username_len: usize = 0,
    last_active: bool = true,
    last_role: user_mgmt.Role = .User,

    fn setLastUsername(self: *FakeWriterState, username: []const u8) void {
        const len = @min(username.len, self.last_username.len);
        @memcpy(self.last_username[0..len], username[0..len]);
        self.last_username_len = len;
    }

    fn lastUsernameSlice(self: *const FakeWriterState) []const u8 {
        return self.last_username[0..self.last_username_len];
    }
};

fn fakeCreate(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    _ = email;
    _ = password_hash;
    const state: *FakeWriterState = @ptrCast(@alignCast(ctx orelse return));
    state.creates += 1;
    state.setLastUsername(username);
    state.last_role = role;
}

fn fakeDelete(ctx: ?*anyopaque, username: []const u8) anyerror!void {
    const state: *FakeWriterState = @ptrCast(@alignCast(ctx orelse return));
    state.deletes += 1;
    state.setLastUsername(username);
}

fn fakeUpdatePassword(ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void {
    _ = new_password_hash;
    const state: *FakeWriterState = @ptrCast(@alignCast(ctx orelse return));
    state.pw_updates += 1;
    state.setLastUsername(username);
}

fn fakeSetRole(ctx: ?*anyopaque, username: []const u8, role: user_mgmt.Role) anyerror!void {
    const state: *FakeWriterState = @ptrCast(@alignCast(ctx orelse return));
    state.role_sets += 1;
    state.setLastUsername(username);
    state.last_role = role;
}

fn fakeSetActive(ctx: ?*anyopaque, username: []const u8, active: bool) anyerror!void {
    const state: *FakeWriterState = @ptrCast(@alignCast(ctx orelse return));
    state.active_sets += 1;
    state.setLastUsername(username);
    state.last_active = active;
}

// ============================================================================
// Test 1: PersistentUserWriter — all 5 callbacks invoked correctly
// ============================================================================

// CANARY: REQ=REQ-AUTH-PERSIST-UNIT-001; FEATURE="AuthDDLPersistence"; ASPECT=WriterCallbacks; STATUS=TESTED; TEST=persistent_writer_all_callbacks; OWNER=security; UPDATED=2026-05-11
test "persistent_writer_all_callbacks" {
    user_mgmt.deinitUserStore();
    defer user_mgmt.deinitUserStore();
    defer user_mgmt.setPersistentUserWriter(null);

    try user_mgmt.initUserStore(testing.allocator);

    var state = FakeWriterState{};
    user_mgmt.setPersistentUserWriter(.{
        .ctx = &state,
        .create_fn = fakeCreate,
        .delete_fn = fakeDelete,
        .update_password_fn = fakeUpdatePassword,
        .set_role_fn = fakeSetRole,
        .set_active_fn = fakeSetActive,
    });

    // --- create ---
    try user_mgmt.createUser(testing.allocator, "ptu", "Passw0rd1!", "p@x", .User, false);
    try testing.expectEqual(@as(u32, 1), state.creates);
    try testing.expectEqualStrings("ptu", state.lastUsernameSlice());

    // --- update password (new != old, so should succeed) ---
    try user_mgmt.updateUserPassword(testing.allocator, "ptu", "NewPassw0rd2!");
    try testing.expectEqual(@as(u32, 1), state.pw_updates);

    // --- assign role (User -> Admin: real change) ---
    try user_mgmt.assignRole(testing.allocator, "ptu", .Admin);
    try testing.expectEqual(@as(u32, 1), state.role_sets);
    try testing.expectEqual(user_mgmt.Role.Admin, state.last_role);

    // --- assign same role again (no-op — no version bump, no writer call) ---
    try user_mgmt.assignRole(testing.allocator, "ptu", .Admin);
    try testing.expectEqual(@as(u32, 1), state.role_sets); // still 1

    // --- set active false ---
    try user_mgmt.setUserActive(testing.allocator, "ptu", false);
    try testing.expectEqual(@as(u32, 1), state.active_sets);
    try testing.expect(!state.last_active);

    // --- delete ---
    try user_mgmt.deleteUser("ptu");
    try testing.expectEqual(@as(u32, 1), state.deletes);
    try testing.expectEqualStrings("ptu", state.lastUsernameSlice());
}

// ============================================================================
// Test 2: setUserActive semantics (idempotency + auth_version)
// ============================================================================

// CANARY: REQ=REQ-GQL-AUTH-DDL-004; FEATURE="GQL Auth DDL"; ASPECT=SetUserActive; STATUS=TESTED; TEST=set_user_active_semantics; OWNER=auth; UPDATED=2026-05-11
test "set_user_active_semantics" {
    user_mgmt.deinitUserStore();
    defer user_mgmt.deinitUserStore();

    try user_mgmt.initUserStore(testing.allocator);

    // Create a user (active=true, auth_version=1)
    try user_mgmt.createUser(testing.allocator, "suat", "Passw0rd1!", "suat@x.com", .User, false);
    {
        const u = user_mgmt.getUser("suat") orelse return error.TestSetupFailed;
        try testing.expect(u.active);
        try testing.expectEqual(@as(u64, 1), u.auth_version);
    }

    // disable -> real change, version bumps to 2
    try user_mgmt.setUserActive(testing.allocator, "suat", false);
    {
        const u = user_mgmt.getUser("suat") orelse return error.TestSetupFailed;
        try testing.expect(!u.active);
        try testing.expectEqual(@as(u64, 2), u.auth_version);
    }

    // disable again -> no-op, version stays at 2
    try user_mgmt.setUserActive(testing.allocator, "suat", false);
    {
        const u = user_mgmt.getUser("suat") orelse return error.TestSetupFailed;
        try testing.expect(!u.active);
        try testing.expectEqual(@as(u64, 2), u.auth_version);
    }

    // enable -> real change, version bumps to 3
    try user_mgmt.setUserActive(testing.allocator, "suat", true);
    {
        const u = user_mgmt.getUser("suat") orelse return error.TestSetupFailed;
        try testing.expect(u.active);
        try testing.expectEqual(@as(u64, 3), u.auth_version);
    }
}

// ============================================================================
// Test 3: GraphRBACPolicy grant round-trip
// ============================================================================

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-022; FEATURE="AuthDDLPersistence"; ASPECT=GrantGraphPermission; STATUS=TESTED; TEST=graph_rbac_policy_grant_round_trip; OWNER=security; UPDATED=2026-05-11
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-023; FEATURE="AuthDDLPersistence"; ASPECT=RevokeGraphPermission; STATUS=TESTED; TEST=graph_rbac_policy_grant_round_trip; OWNER=security; UPDATED=2026-05-11
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-024; FEATURE="AuthDDLPersistence"; ASPECT=HasGraphGrant; STATUS=TESTED; TEST=graph_rbac_policy_grant_round_trip; OWNER=security; UPDATED=2026-05-11
test "graph_rbac_policy_grant_round_trip" {
    var pol = multi_graph.GraphRBACPolicy.init(testing.allocator);
    defer pol.deinit();

    // Grant user 42 READ (action=0) on "sales"
    try pol.grantGraphPermission(42, "sales", 0);
    try testing.expect(pol.hasGraphGrant(42, "sales", 0));

    // Same user, different action — should NOT be present
    try testing.expect(!pol.hasGraphGrant(42, "sales", 1));

    // Different user, same graph + action — should NOT be present
    try testing.expect(!pol.hasGraphGrant(43, "sales", 0));

    // Revoke — returns true (was present)
    try testing.expect(pol.revokeGraphPermission(42, "sales", 0));

    // After revoke, grant is gone
    try testing.expect(!pol.hasGraphGrant(42, "sales", 0));

    // Revoke again — returns false (already absent)
    try testing.expect(!pol.revokeGraphPermission(42, "sales", 0));
}

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-025; FEATURE="AuthDDLPersistence"; ASPECT=LoadGraphGrants; STATUS=TESTED; TEST=graph_rbac_policy_load_graph_grants; OWNER=security; UPDATED=2026-05-11
test "graph_rbac_policy_load_graph_grants" {
    var pol = multi_graph.GraphRBACPolicy.init(testing.allocator);
    defer pol.deinit();

    const records = [_]multi_graph.GraphGrantLoadEntry{
        .{ .user_id = 10, .graph_name = "analytics", .action = 0 },
        .{ .user_id = 10, .graph_name = "analytics", .action = 1 },
        .{ .user_id = 20, .graph_name = "reporting", .action = 0 },
    };
    try pol.loadGraphGrants(records[0..]);

    try testing.expect(pol.hasGraphGrant(10, "analytics", 0));
    try testing.expect(pol.hasGraphGrant(10, "analytics", 1));
    try testing.expect(pol.hasGraphGrant(20, "reporting", 0));

    // Not loaded entries must be absent
    try testing.expect(!pol.hasGraphGrant(10, "reporting", 0));
    try testing.expect(!pol.hasGraphGrant(20, "analytics", 0));
    try testing.expect(!pol.hasGraphGrant(10, "analytics", 2));
}
