const std = @import("std");
const auth = @import("../src/security/auth.zig");
const mfa = @import("../src/security/mfa.zig");

// Additional MFA coverage tests (reauth interval elapsed, role match any/all, recovery single-use)

fn makeManager() !auth.SecurityManager {
    var gpa = std.heap.DebugAllocator(.{}){};
    // Intentionally leak allocator for test lifetime (Zig test harness ends process)
    return try auth.SecurityManager.init(gpa.allocator());
}

// Validate match_any_role vs match_all_roles logic.
test "TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAnyRole" {
    var sm = try makeManager();
    const uid = try sm.createUser("user1", "u1@example.com", "Password1!");
    // Create roles and assign two roles
    const r1 = try sm.createRole("role_a", "A");
    const r2 = try sm.createRole("role_b", "B");
    try sm.assignRole(uid, r1.id);
    try sm.assignRole(uid, r2.id);
    try sm.addMfaPolicy(.{ .id = 1, .scope = .user, .roles = &[_]auth.RoleId{r1.id}, .condition = .match_any_role });
    const user_ptr = sm.users.getPtr(uid).?;
    const require = sm.evaluateMfaPolicies(user_ptr);
    try std.testing.expect(require == true);
}

test "TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAllRoles" {
    var sm = try makeManager();
    const uid = try sm.createUser("user2", "u2@example.com", "Password1!");
    const r1 = try sm.createRole("role_a", "A");
    const r2 = try sm.createRole("role_b", "B");
    try sm.assignRole(uid, r1.id);
    try sm.assignRole(uid, r2.id);
    try sm.addMfaPolicy(.{ .id = 2, .scope = .user, .roles = &[_]auth.RoleId{ r1.id, r2.id }, .condition = .match_all_roles });
    const user_ptr = sm.users.getPtr(uid).?;
    const require = sm.evaluateMfaPolicies(user_ptr);
    try std.testing.expect(require == true);
}

// Reauth interval elapsed policy requires MFA when last_mfa_ts older than interval.
test "TestCANARY_REQ_GQL_MFA_POLICY_001_ReauthInterval_Elapsed" {
    var sm = try makeManager();
    const uid = try sm.createUser("user3", "u3@example.com", "Password1!");
    try sm.addMfaPolicy(.{ .id = 3, .condition = .reauth_interval_elapsed, .reauth_interval_ms = 10_000 });
    const user_ptr = sm.users.getPtr(uid).?;
    // Create a session with old last_mfa_ts
    const token = try sm.createSession(uid);
    var sess_ptr = sm.sessions.getPtr(token).?;
    sess_ptr.last_mfa_ts = std.time.milliTimestamp() - 11_000; // older than interval
    const need = sm.evaluateMfaPoliciesAdvanced(user_ptr, sess_ptr, std.time.milliTimestamp());
    try std.testing.expect(need == true);
}

// Recovery code is single-use; second attempt fails.
test "TestCANARY_REQ_GQL_MFA_007_RecoverySingleUse" {
    mfa.enableForTests();
    var sm = try makeManager();
    const uid = try sm.createUser("user4", "u4@example.com", "Password1!");
    var user_ptr = sm.users.getPtr(uid).?;
    user_ptr.mfa_enabled = true;
    user_ptr.mfa_secret = try std.testing.allocator.dupe(u8, "ABCDEFGHIJKLMNOP");
    // Add one recovery code
    var codes = std.ArrayList([]const u8).init(std.testing.allocator);
    try codes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "RECOV-CODE-1"));
    user_ptr.recovery_codes = codes;

    // Trigger MFA requirement
    _ = sm.authenticate("user4", "Password1!\n") catch |e| switch (e) {
        error.MFARequired => {},
        else => return e,
    };

    // Use recovery code successfully
    const tok1 = try sm.authenticateWithMFA("user4", "Password1!\n", 0", "RECOV-CODE-1");
    try std.testing.expect(tok1.len > 0);

    // Second use should fail (code removed)
    _ = sm.authenticateWithMFA("user4", "Password1!\n", 0", "RECOV-CODE-1") catch |e| {
        try std.testing.expect(e == error.MFAInvalidCode);
        return; // expected path
    };
    return error.TestExpectedFailureMissing; // should not reach
}
