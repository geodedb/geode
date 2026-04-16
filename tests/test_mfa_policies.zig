const std = @import("std");
const auth = @import("../src/security/auth.zig");
const mfa = @import("../src/security/mfa.zig");

// TestCANARY_REQ_GQL_MFA_003_MfaPolicyEval
// Ensures MFA policy evaluation caches results and respects role-based conditions.
// CANARY: REQ=REQ-GQL-MFA-003; FEATURE="MFA admin policy"; ASPECT=SECURITY; STATUS=TESTED; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {}

test "TestCANARY_REQ_GQL_MFA_003_MfaPolicyEval_basic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    mfa.enableForTests();

    var sm = try auth.SecurityManager.init(alloc);
    defer {
        // TODO: add cleanup once deinit implemented
    }

    // Create user and role assignment
    const uid = try sm.createUser("alice", "alice@example.com", "Password1!", false);
    try sm.assignRole(uid, 1); // role 1 = user

    // Add policy requiring MFA for any user with role 1
    const pol = auth.MfaAdminPolicy{ .id = 1, .enabled = true, .scope = .role, .roles = &[_]auth.RoleId{1}, .condition = .match_any_role };
    try sm.addMfaPolicy(pol);

    var user_ptr = sm.users.getPtr(uid).?;
    user_ptr.mfa_enabled = true;
    // Emulate enrollment secret
    const secret = try alloc.dupe(u8, "BASE32SECRET");
    user_ptr.mfa_secret = secret;

    const first_eval = sm.evaluateMfaPolicies(user_ptr);
    try std.testing.expect(first_eval == true);
    // Cache should now store requirement; flipping policy enable should not change until cache cleared
    sm.mfa_policies.items[0].enabled = false;
    const second_eval = sm.evaluateMfaPolicies(user_ptr);
    try std.testing.expect(second_eval == true); // cached value
}

// Additional dynamic MFA policy tests for time window, risk score, reauth interval.
// CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_security.yml; OWNER=security; UPDATED=2025-09-26

fn makeUser(sm: *auth.SecurityManager, alloc: std.mem.Allocator, name: []const u8) !*auth.User {
    const uid = try sm.createUser(name, "test@example.com", "Password1!", false);
    return sm.users.getPtr(uid).?;
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_TimeWindow" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var sm = try auth.SecurityManager.init(alloc);
    var u = try makeUser(&sm, alloc, "time");
    u.mfa_enabled = true;
    try sm.addMfaPolicy(.{ .id = 10, .enabled = true, .scope = .global, .roles = &[_]auth.RoleId{}, .condition = .time_window, .attribute_key = null, .attribute_value = null, .time_start_minute = 10, .time_end_minute = 20, .risk_min_score = null, .reauth_interval_ms = null });
    const minute15 = 15 * 60 * 1000; // inside
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, null, minute15));
    const minute30 = 30 * 60 * 1000; // outside
    try std.testing.expect(!sm.evaluateMfaPoliciesAdvanced(u, null, minute30));
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_RiskScoreMin" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var sm = try auth.SecurityManager.init(alloc);
    var u = try makeUser(&sm, alloc, "risk");
    u.mfa_enabled = true;
    try u.attributes.put("risk_score", "7");
    try sm.addMfaPolicy(.{ .id = 11, .enabled = true, .scope = .global, .roles = &[_]auth.RoleId{}, .condition = .risk_score_min, .attribute_key = null, .attribute_value = null, .time_start_minute = null, .time_end_minute = null, .risk_min_score = 5, .reauth_interval_ms = null });
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, null, 0));
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_ReauthInterval" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var sm = try auth.SecurityManager.init(alloc);
    var u = try makeUser(&sm, alloc, "reauth");
    u.mfa_enabled = true;
    try sm.addMfaPolicy(.{ .id = 12, .enabled = true, .scope = .global, .roles = &[_]auth.RoleId{}, .condition = .reauth_interval_elapsed, .attribute_key = null, .attribute_value = null, .time_start_minute = null, .time_end_minute = null, .risk_min_score = null, .reauth_interval_ms = 10_000 });
    var session = auth.Session{ .id = "sess", .user_id = u.id, .created_at_ms = 0, .last_mfa_ts = 0, .elevated_until_ms = 0, .attributes = std.StringHashMap([]const u8).init(alloc) };
    // Not elapsed at 5s
    try std.testing.expect(!sm.evaluateMfaPoliciesAdvanced(u, &session, 5_000));
    // Elapsed at 10s
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, &session, 10_000));
}
