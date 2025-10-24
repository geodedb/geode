const std = @import("std");
const geode = @import("geode");

// CANARY: REQ=REQ-GQL-MFA-010; FEATURE="ConfigurableElevationTTL"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_010_ElevationTTL; OWNER=security; UPDATED=2025-09-26

test "custom elevation ttl applied" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;
    var auth = try geode.security.AuthContext.init(alloc); // adjust if different constructor
    defer auth.deinit();
    // Override TTL to 1 second
    auth.security_manager.elevation_ttl_ms = 1000;
    const user_id = try auth.security_manager.createUser("bob", "bob@example.com", "pass123");
    // Force a session with MFA path (simulate success by direct markStepUp)
    const session = try auth.security_manager.createSession(user_id);
    auth.security_manager.markStepUp(session, auth.security_manager.elevation_ttl_ms) catch unreachable;
    try std.testing.expect(!auth.security_manager.requireStepUp(session, "admin_operation"));
    // Simulate expiry by modifying elevation_expires_at backwards
    var s = auth.security_manager.sessions.getPtr(session).?;
    s.elevation_expires_at.? -= 2000; // force expiration
    try std.testing.expect(auth.security_manager.requireStepUp(session, "admin_operation"));
}
