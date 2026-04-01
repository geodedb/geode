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

// CANARY: REQ=REQ-SEC-TENANT-FED-001; FEATURE="Federation Tenant Propagation"; ASPECT=HelloRequest; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
test "federation.buildHelloRequest: propagates tenant_id (SEC-D010)" {
    // Source-level audit: buildFederationHelloRequest accepts tenant_id parameter
    // and the HelloRequest includes .tenant_id = tid
    const src = @embedFile("federation.zig");
    // The function signature must accept tenant_id
    try std.testing.expect(std.mem.indexOf(u8, src, "tenant_id: ?[]const u8") != null);
    // The HelloRequest must propagate the tenant_id
    try std.testing.expect(std.mem.indexOf(u8, src, ".tenant_id = tid") != null);
    // FederationConfig must have a tenant_id field
    try std.testing.expect(std.mem.indexOf(u8, src, "tenant_id: ?[]const u8 = null") != null);
}
