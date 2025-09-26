const std = @import("std");
const auth = @import("../src/security/auth.zig");

// CANARY: REQ=REQ-GQL-MFA-008; FEATURE="Session step-up requirement"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_008_StepUpRequire; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-MFA-009; FEATURE="Session step-up mark"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_009_StepUpMark; OWNER=security; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_MFA_008_StepUpRequire_and_mark_flow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var sm = try auth.SecurityManager.init(alloc);
    const uid = try sm.createUser("eve", "eve@example.com", "Password1!", false);
    const token = try sm.createSession(uid);

    // Non-sensitive action should not require step-up
    try std.testing.expect(sm.requireStepUp(token, "read_graph") == false);

    // Sensitive heuristic (contains 'admin') should require
    try std.testing.expect(sm.requireStepUp(token, "admin_panel") == true);

    // Mark elevation for short window (simulated 1000ms)
    try sm.markStepUp(token, 1000);
    try std.testing.expect(sm.requireStepUp(token, "admin_panel") == false);

    // Simulate expiry by manually editing session (since we don't have a clock mock)
    var sess_ptr = sm.sessions.getPtr(token).?;
    sess_ptr.elevation_expires_at = @as(i64, @intCast(std.time.milliTimestamp() - 1));
    try std.testing.expect(sm.requireStepUp(token, "admin_panel") == true);
}
