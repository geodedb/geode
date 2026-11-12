// MFA admin-policy evaluation (`SecurityManager.evaluateMfaPolicies` /
// `evaluateMfaPoliciesAdvanced` in src/security/geode_auth_lib.zig; the
// former is what `authenticateWithMFA` consults).
//
// SONNY-6430 (4): this file was cited by TESTED markers but no build step
// compiled it (it imported ../src/security/auth.zig, which no longer
// exists, and a SecurityManager API that changed). It now drives the real
// SecurityManager and runs as `zig build test-mfa-policies`.
//
// CANARY: REQ=REQ-GQL-MFA-003; FEATURE="MFA admin policy"; ASPECT=RoleMatchAndCache; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_003_MfaPolicyEval|TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAnyRole|TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAllRoles; OWNER=security; UPDATED=2026-11-12
// CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=DynamicConditions; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_POLICY_001_TimeWindow|TestCANARY_REQ_GQL_MFA_POLICY_001_RiskScoreMin|TestCANARY_REQ_GQL_MFA_POLICY_001_ReauthInterval; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const auth = @import("geode_auth");

const SecurityManager = auth.SecurityManager;
const passphrase = "Mfa Policy Test Passphrase";

fn newUser(sm: *SecurityManager, name: []const u8) !*auth.User {
    const id = try sm.createUser(name, "mfa-policy@example.com", passphrase);
    const u = sm.users.getPtr(id).?;
    u.mfa_enabled = true;
    return u;
}

fn newRole(sm: *SecurityManager, name: []const u8) !auth.RoleId {
    return (try sm.createRole(name, "mfa policy test role")).id;
}

test "TestCANARY_REQ_GQL_MFA_003_MfaPolicyEval" {
    var sm = try SecurityManager.init(std.testing.allocator);
    defer sm.deinit();
    const admins = try newRole(&sm, "mfa_admins");
    const alice = try newUser(&sm, "alice");
    const bob = try newUser(&sm, "bob");
    try sm.assignRole(alice.id, admins);

    // No policy: nobody is required to use MFA.
    try std.testing.expect(!sm.evaluateMfaPolicies(alice));

    const roles = [_]auth.RoleId{admins};
    try sm.addMfaPolicy(.{ .id = 1, .scope = .role, .roles = &roles, .condition = .match_any_role });
    try std.testing.expect(sm.evaluateMfaPolicies(alice));
    try std.testing.expect(!sm.evaluateMfaPolicies(bob));

    // The answer is cached per user until the policy set changes:
    // addMfaPolicy clears the cache.
    sm.mfa_policies.items[0].enabled = false;
    try std.testing.expect(sm.evaluateMfaPolicies(alice));
    try sm.addMfaPolicy(.{ .id = 2, .enabled = false, .condition = .always });
    try std.testing.expect(!sm.evaluateMfaPolicies(alice));
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAnyRole" {
    var sm = try SecurityManager.init(std.testing.allocator);
    defer sm.deinit();
    const r1 = try newRole(&sm, "r1");
    const r2 = try newRole(&sm, "r2");
    const u = try newUser(&sm, "carol");
    try sm.assignRole(u.id, r2);
    const roles = [_]auth.RoleId{ r1, r2 };
    try sm.addMfaPolicy(.{ .id = 3, .scope = .role, .roles = &roles, .condition = .match_any_role });
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, null, 0));
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAllRoles" {
    var sm = try SecurityManager.init(std.testing.allocator);
    defer sm.deinit();
    const r1 = try newRole(&sm, "r1");
    const r2 = try newRole(&sm, "r2");
    const one = try newUser(&sm, "dave");
    const both = try newUser(&sm, "erin");
    try sm.assignRole(one.id, r1);
    try sm.assignRole(both.id, r1);
    try sm.assignRole(both.id, r2);
    const roles = [_]auth.RoleId{ r1, r2 };
    try sm.addMfaPolicy(.{ .id = 4, .scope = .role, .roles = &roles, .condition = .match_all_roles });
    try std.testing.expect(!sm.evaluateMfaPoliciesAdvanced(one, null, 0));
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(both, null, 0));
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_TimeWindow" {
    var sm = try SecurityManager.init(std.testing.allocator);
    defer sm.deinit();
    const u = try newUser(&sm, "frank");
    try sm.addMfaPolicy(.{ .id = 10, .condition = .time_window, .time_start_minute = 10, .time_end_minute = 20 });
    const ms_per_min: i64 = 60 * 1000;
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, null, 15 * ms_per_min));
    try std.testing.expect(!sm.evaluateMfaPoliciesAdvanced(u, null, 30 * ms_per_min));
    // The next day, same minute: inside again.
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, null, (24 * 60 + 15) * ms_per_min));
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_RiskScoreMin" {
    var sm = try SecurityManager.init(std.testing.allocator);
    defer sm.deinit();
    const low = try newUser(&sm, "gina");
    const high = try newUser(&sm, "hank");
    const bad = try newUser(&sm, "ivan");
    try low.attributes.put("risk_score", "3");
    try high.attributes.put("risk_score", "7");
    try bad.attributes.put("risk_score", "not-a-number");
    defer {
        low.attributes.clearRetainingCapacity();
        high.attributes.clearRetainingCapacity();
        bad.attributes.clearRetainingCapacity();
    }
    try sm.addMfaPolicy(.{ .id = 11, .condition = .risk_score_min, .risk_min_score = 5 });
    try std.testing.expect(!sm.evaluateMfaPoliciesAdvanced(low, null, 0));
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(high, null, 0));
    // GAP-0149: an unparsable score is the highest risk.
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(bad, null, 0));
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_ReauthInterval" {
    var sm = try SecurityManager.init(std.testing.allocator);
    defer sm.deinit();
    const u = try newUser(&sm, "judy");
    try sm.addMfaPolicy(.{ .id = 12, .condition = .reauth_interval_elapsed, .reauth_interval_ms = 10_000 });
    var session = auth.Session{
        .token = "sess",
        .user_id = u.id,
        .created_at = 0,
        .expires_at = 60_000,
        .ip_address = null,
        .user_agent = null,
        .last_mfa_ts = 0,
        .elevation_expires_at = null,
    };
    try std.testing.expect(!sm.evaluateMfaPoliciesAdvanced(u, &session, 5_000));
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, &session, 10_000));
    // No MFA in this session yet: required.
    session.last_mfa_ts = null;
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, &session, 1));
    // No session at all: required.
    try std.testing.expect(sm.evaluateMfaPoliciesAdvanced(u, null, 1));
}
