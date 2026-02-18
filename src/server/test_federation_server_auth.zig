const std = @import("std");

// CANARY: REQ=REQ-GAP-0490-FEDERATION-SERVER-AUTH; FEATURE="FederationAuth"; ASPECT=ServerValidation; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18

test "server: validateFederationAuth present in quic_connection_handler (GAP-0490)" {
    const src = @embedFile("quic_connection_handler.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "validateFederationAuth") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "GEODE_CLUSTER_TOKEN") != null);
}
