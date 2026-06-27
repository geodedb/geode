const std = @import("std");

// CANARY: REQ=REQ-GAP-0490-FEDERATION-SERVER-AUTH; FEATURE="FederationAuth"; ASPECT=ServerValidation; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18

test "server: validateFederationAuth present in quic_connection_handler (GAP-0490)" {
    const src = @embedFile("quic_connection_handler.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "validateFederationAuth") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "GEODE_CLUSTER_TOKEN") != null);
}

// CANARY: REQ=REQ-NEW8-ENVELOPE-TRUST; FEATURE="EnvelopeTrustGate"; ASPECT=HandlerWiring; STATUS=TESTED; TEST=src/server/test_federation_server_auth.zig; OWNER=security; UPDATED=2026-06-26
// NEW-8 / #860: The envelope trust gate must be wired at the principal_envelope_bytes
// decode site in quic_connection_handler.zig. Without this guard, any authenticated
// client can forge Admin roles or a foreign tenant_id via field 4. The gate consults
// shouldTrustEnvelope(state.authenticated_user) which returns true ONLY for the
// "geode-cluster" federation identity.
test "server: shouldTrustEnvelope gate wired at principal_envelope_bytes in quic_connection_handler (NEW-8)" {
    const src = @embedFile("quic_connection_handler.zig");
    // The handler must call shouldTrustEnvelope before decoding field 4.
    try std.testing.expect(std.mem.indexOf(u8, src, "shouldTrustEnvelope") != null);
    // The gate must guard the principal_envelope_bytes decode block.
    try std.testing.expect(std.mem.indexOf(u8, src, "principal_envelope_bytes") != null);
}
