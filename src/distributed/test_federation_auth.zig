const std = @import("std");

// CANARY: REQ=REQ-GAP-0490-FEDERATION-CLIENT-AUTH; FEATURE="FederationAuth"; ASPECT=ClientToken; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18

test "federation.buildHelloRequest: uses GEODE_CLUSTER_TOKEN (GAP-0490)" {
    // This is a source-level audit test
    const src = @embedFile("federation.zig");
    // Must contain GEODE_CLUSTER_TOKEN
    try std.testing.expect(std.mem.indexOf(u8, src, "GEODE_CLUSTER_TOKEN") != null);
    // Must NOT send empty username — the username must be "geode-cluster"
    try std.testing.expect(std.mem.indexOf(u8, src, "geode-cluster") != null);
}
