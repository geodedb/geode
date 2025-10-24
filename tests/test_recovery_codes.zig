const std = @import("std");
const geode = @import("geode");

// Basic test for MFA recovery code consumption.
// CANARY: REQ=REQ-GQL-AUTH-004; FEATURE="MFA recovery code"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_AUTH_004_Recovery; OWNER=security; UPDATED=2025-09-26

test "recovery code single-use" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;

    var auth = try geode.security.AuthContext.init(alloc);
    defer auth.deinit();

    // Create user with password and MFA secret + recovery codes
    const user = try auth.createUser("alice", "password123");
    try auth.enableMFAForUser(user.id, "JBSWY3DPEHPK3PXP"); // dummy base32 secret
    try auth.addRecoveryCodes(user.id, &[_][]const u8{ "RCODE1", "RCODE2" });

    // First stage: password triggers MFARequired
    const tok1 = auth.authenticate("alice", "password123") catch |e| switch (e) {
        error.MFARequired => {},
        else => return e,
    };
    _ = tok1; // not expected to be returned when MFA required

    // Use recovery code RCODE1 (pass code=0, recovery_code set)
    const session1 = try auth.authenticateWithMFA("alice", "password123", 0, "RCODE1");
    try std.testing.expect(auth.requireStepUp(session1) == false);
    // Verify audit log includes recovery code consumption marker
    var found_recovery = false;
    var it = auth.audit_log.entries.iterator();
    while (it.next()) |entry| {
        if (std.mem.indexOf(u8, entry.message, "recovery code consumed") != null) {
            found_recovery = true;
            break;
        }
    }
    try std.testing.expect(found_recovery);

    // Attempt reuse of same recovery code should fail
    const reuse_err = auth.authenticateWithMFA("alice", "password123", 0, "RCODE1");
    try std.testing.expectError(error.MFAInvalidCode, reuse_err);

    // Use second recovery code
    const session2 = try auth.authenticateWithMFA("alice", "password123", 0, "RCODE2");
    try std.testing.expect(auth.requireStepUp(session2) == false);
}
