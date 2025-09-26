const std = @import("std");
const auth = @import("../src/security/auth.zig");
const mfa = @import("../src/security/mfa.zig");

// TestCANARY_REQ_GQL_MFA_003_MfaPolicyEval
// Ensures MFA policy evaluation caches results and respects role-based conditions.
// CANARY: REQ=REQ-GQL-MFA-003; FEATURE="MFA admin policy"; ASPECT=SECURITY; STATUS=TESTED; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {}

test "TestCANARY_REQ_GQL_MFA_003_MfaPolicyEval_basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
