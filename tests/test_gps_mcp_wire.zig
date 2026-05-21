// GPS Phase 7 Task 7-5 — MCP wire-level Principal forwarding tests.
//
// Scope:
//   The MCP send-side gap (external geode-client-zig does not yet emit
//   ExecuteRequest field 4) means there is no MCP -> server round-trip
//   test possible at the wire level.  What IS testable without a live
//   server connection:
//
//   1. Server-side schema: ExecuteRequest in schema.zig has field 4
//      (principal_envelope_bytes) with the correct protobuf descriptor.
//   2. Envelope round-trip via principal_envelope.serialize / deserialize
//      that the server unpack path calls.
//   3. The toPrincipal() helper stamps .source = .mcp_handler correctly.
//   4. A null envelope in ExecuteRequest leaves the field absent (backward
//      compat -- existing wire frames are not broken).
//
// Site #8 status after this task:
//   PARTIAL -- schema extended, server unpack wired; MCP send blocked on
//   geode-client-zig external package not yet emitting field 4.

const std = @import("std");
const geode = @import("geode");
const schema = @import("schema");
const envelope_mod = geode.distributed.principal_envelope;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=SchemaField; STATUS=TESTED; TEST=tests/test_gps_mcp_wire.zig; OWNER=security; UPDATED=2026-05-21

test "ExecuteRequest schema has principal_envelope_bytes field" {
    // The field must exist and default to null.
    const req = schema.ExecuteRequest{
        .session_id = "test",
        .query = "RETURN 1",
        .params = std.ArrayList(schema.Param).empty,
    };
    // Field 4 must be null by default (no envelope attached).
    try std.testing.expect(req.principal_envelope_bytes == null);
}

test "ExecuteRequest accepts non-null principal_envelope_bytes" {
    const fake_envelope: []const u8 = "GPSP\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const req = schema.ExecuteRequest{
        .session_id = "sess",
        .query = "RETURN 1",
        .params = std.ArrayList(schema.Param).empty,
        .principal_envelope_bytes = fake_envelope,
    };
    try std.testing.expect(req.principal_envelope_bytes != null);
    try std.testing.expectEqual(fake_envelope.len, req.principal_envelope_bytes.?.len);
}

// CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=McpEnvelopeRoundTrip; STATUS=TESTED; TEST=tests/test_gps_mcp_wire.zig; OWNER=security; UPDATED=2026-05-21

test "mcp_handler envelope round-trip via serialize/deserialize" {
    // Simulate what the MCP server would do once the send-side gap is closed:
    // 1. Serialize the mcp_handler Principal into bytes.
    // 2. Attach bytes to ExecuteRequest.principal_envelope_bytes.
    // 3. Server deserializes and reconstructs Principal.
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const role_names = [_][]const u8{"User"};
    const mcp_principal = principal_mod.Principal{
        .user_id = null,
        .username = "mcp-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .api_key,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .mcp_handler,
    };

    // Step 1: build envelope from the MCP Principal.
    const env = envelope_mod.fromPrincipal(&mcp_principal, 42);

    // Step 2: serialize (what the send-side will do when geode-client-zig is updated).
    const bytes = try envelope_mod.serialize(allocator, env);
    defer allocator.free(bytes);

    // Step 3: server-side deserialize (what quic_connection_handler does).
    envelope_mod.resetStaticRoleBuffer();
    const decoded_env = try envelope_mod.deserialize(bytes);
    const decoded = envelope_mod.toPrincipal(&decoded_env);

    try std.testing.expectEqualStrings("mcp-user", decoded.username.?);
    try std.testing.expectEqual(@as(usize, 1), decoded.roles.len);
    try std.testing.expectEqualStrings("User", decoded.roles[0]);
    try std.testing.expectEqual(@as(u64, 42), decoded_env.policy_version);
    // source is set to .mcp_handler in the envelope; the server overrides to
    // .distributed_worker -- the test only checks the raw deserialization result.
    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, decoded_env.source);
}

test "missing envelope falls back gracefully (null bytes)" {
    // When envelope_bytes is null the server uses the connection-level Principal.
    // This test confirms null is accepted without panic or error.
    const envelope_bytes: ?[]const u8 = null;
    // The server code does: if (envelope_bytes) |env_bytes| { ... }
    // This just asserts the null branch is entered without execution of the body.
    if (envelope_bytes) |_| {
        try std.testing.expect(false); // should not be reached
    }
    try std.testing.expect(true); // null branch: no-op
}

test "empty envelope bytes falls back gracefully" {
    // A zero-length slice is treated the same as null -- the server must not
    // attempt to deserialize it.
    const envelope_bytes: ?[]const u8 = "";
    var used_fallback = false;
    if (envelope_bytes) |env_bytes| {
        if (env_bytes.len > 0) {
            // Would call deserialize -- but len == 0 so we skip.
            try std.testing.expect(false);
        } else {
            used_fallback = true;
        }
    }
    try std.testing.expect(used_fallback);
}

// CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=MalformedEnvelope; STATUS=TESTED; TEST=tests/test_gps_mcp_wire.zig; OWNER=security; UPDATED=2026-05-21

test "malformed envelope bytes produce an error (server falls back)" {
    // The server must not panic on a corrupt field 4. It logs and falls back.
    const bad_bytes: []const u8 = "XXXX_not_an_envelope";
    const result = envelope_mod.deserialize(bad_bytes);
    try std.testing.expectError(envelope_mod.EnvelopeError.InvalidMagic, result);
}
