// GPS Phase 6 (Task 6-3) — Unit tests for the distributed Principal envelope.
//
// Tests cover:
//  - Round-trip: full envelope with all fields populated
//  - Round-trip: null optional fields (user_id, username, tenant_id, active_graph)
//  - Round-trip: empty roles / custom_roles arrays
//  - Round-trip: multiple roles preserved in order
//  - Round-trip: all PrincipalSource enum variants
//  - Error: invalid magic bytes
//  - Error: unsupported version byte
//  - Error: truncated buffer (too short)
//  - Helper: fromPrincipal captures correct fields
//  - Helper: toPrincipal reconstructs identity fields

const std = @import("std");
const geode = @import("geode");
const envelope_mod = geode.distributed.principal_envelope;
const principal_mod = geode.security.principal;

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=RoundTrip; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "envelope round-trip: all fields populated" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const roles = [_][]const u8{ "Admin", "Engineer" };
    const custom_roles = [_][]const u8{"graph:hr:writer"};

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = 42,
        .username = "alice",
        .roles = &roles,
        .custom_roles = &custom_roles,
        .tenant_id = "tenant_a",
        .active_graph = "hr",
        .auth_version = 5,
        .policy_version = 100,
        .source = .quic_handler,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);

    try std.testing.expectEqual(original.user_id.?, decoded.user_id.?);
    try std.testing.expectEqualStrings(original.username.?, decoded.username.?);
    try std.testing.expectEqual(original.roles.len, decoded.roles.len);
    try std.testing.expectEqualStrings(original.roles[0], decoded.roles[0]);
    try std.testing.expectEqualStrings(original.roles[1], decoded.roles[1]);
    try std.testing.expectEqual(original.custom_roles.len, decoded.custom_roles.len);
    try std.testing.expectEqualStrings(original.custom_roles[0], decoded.custom_roles[0]);
    try std.testing.expectEqualStrings(original.tenant_id.?, decoded.tenant_id.?);
    try std.testing.expectEqualStrings(original.active_graph.?, decoded.active_graph.?);
    try std.testing.expectEqual(original.auth_version, decoded.auth_version);
    try std.testing.expectEqual(original.policy_version, decoded.policy_version);
    try std.testing.expectEqual(original.source, decoded.source);
}

// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=NullFields; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "envelope round-trip: null optional fields" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = null,
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 7,
        .source = .internal_service,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);

    try std.testing.expect(decoded.user_id == null);
    try std.testing.expect(decoded.username == null);
    try std.testing.expect(decoded.tenant_id == null);
    try std.testing.expect(decoded.active_graph == null);
    try std.testing.expectEqual(@as(usize, 0), decoded.roles.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.custom_roles.len);
    try std.testing.expectEqual(@as(u64, 0), decoded.auth_version);
    try std.testing.expectEqual(@as(u64, 7), decoded.policy_version);
    try std.testing.expectEqual(principal_mod.PrincipalSource.internal_service, decoded.source);
}

test "envelope round-trip: empty roles arrays" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = 1,
        .username = "bob",
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 1,
        .policy_version = 0,
        .source = .distributed_worker,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);

    try std.testing.expectEqual(@as(usize, 0), decoded.roles.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.custom_roles.len);
    try std.testing.expect(decoded.user_id != null);
    try std.testing.expectEqual(@as(u64, 1), decoded.user_id.?);
}

// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=MultipleRoles; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "envelope round-trip: multiple roles preserved in order" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const roles = [_][]const u8{ "alpha", "beta", "gamma", "delta" };

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = "carol",
        .roles = &roles,
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 3,
        .policy_version = 42,
        .source = .distributed_coordinator,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);

    try std.testing.expectEqual(@as(usize, 4), decoded.roles.len);
    for (roles, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, decoded.roles[i]);
    }
}

test "envelope round-trip: source variant distributed_coordinator" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = null,
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 1,
        .source = .distributed_coordinator,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);
    try std.testing.expectEqual(principal_mod.PrincipalSource.distributed_coordinator, decoded.source);
}

test "envelope round-trip: source variant mcp_handler" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = null,
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 0,
        .source = .mcp_handler,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);
    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, decoded.source);
}

test "envelope round-trip: source variant test_harness" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = 99,
        .username = "tester",
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 99,
        .policy_version = 999,
        .source = .test_harness,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);
    try std.testing.expectEqual(principal_mod.PrincipalSource.test_harness, decoded.source);
    try std.testing.expectEqual(@as(u64, 999), decoded.policy_version);
}

test "envelope round-trip: max auth_version and policy_version" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = std.math.maxInt(u64),
        .username = null,
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = std.math.maxInt(u64),
        .policy_version = std.math.maxInt(u64),
        .source = .unattributed,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    const decoded = try envelope_mod.deserialize(bytes);
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.user_id.?);
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.auth_version);
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.policy_version);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=InvalidMagic; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "envelope rejects invalid magic" {
    var buf = [_]u8{ 'X', 'X', 'X', 'X', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const result = envelope_mod.deserialize(&buf);
    try std.testing.expectError(envelope_mod.EnvelopeError.InvalidMagic, result);
}

// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=UnsupportedVersion; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "envelope rejects unsupported version" {
    // Valid magic, version = 255
    var buf = [_]u8{ 'G', 'P', 'S', 'P', 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const result = envelope_mod.deserialize(&buf);
    try std.testing.expectError(envelope_mod.EnvelopeError.UnsupportedVersion, result);
}

// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=TruncatedBuffer; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "envelope rejects empty buffer" {
    const result = envelope_mod.deserialize(&.{});
    try std.testing.expectError(envelope_mod.EnvelopeError.TruncatedEnvelope, result);
}

test "envelope rejects buffer with only magic" {
    const buf = "GPSP";
    const result = envelope_mod.deserialize(buf);
    try std.testing.expectError(envelope_mod.EnvelopeError.TruncatedEnvelope, result);
}

test "envelope rejects buffer truncated mid-username" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = "alice",
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 0,
        .source = .test_harness,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    // Truncate just before the end of the username payload
    const truncated = bytes[0 .. bytes.len / 2];
    const result = envelope_mod.deserialize(truncated);
    try std.testing.expectError(envelope_mod.EnvelopeError.TruncatedEnvelope, result);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=InvalidSource; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "envelope rejects invalid source ordinal" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    // Build a valid envelope then corrupt the last byte (source ordinal).
    const original = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = null,
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 0,
        .source = .test_harness,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    // Copy to mutable buffer and corrupt source ordinal (last byte).
    const mutable = try allocator.dupe(u8, bytes);
    defer allocator.free(mutable);
    mutable[mutable.len - 1] = 0xFF; // no valid PrincipalSource has ordinal 255

    const result = envelope_mod.deserialize(mutable);
    try std.testing.expectError(envelope_mod.EnvelopeError.InvalidSourceOrdinal, result);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=FromPrincipal; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "fromPrincipal captures expected fields" {
    const roles = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 7,
        .username = "dave",
        .session_id = "sess-xyz",
        .tenant_id = "tenant_b",
        .active_graph = "finance",
        .roles = &roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 12,
        .mfa_state = .verified,
        .elevation_until = 9999,
        .api_key_id = 3,
        .certificate_subject = "CN=dave",
        .risk_context = .{ .score = 5, .ip_address = "10.0.0.1", .user_agent = "curl" },
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .quic_handler,
    };

    const env = envelope_mod.fromPrincipal(&p, 77);

    try std.testing.expectEqual(@as(u64, 7), env.user_id.?);
    try std.testing.expectEqualStrings("dave", env.username.?);
    try std.testing.expectEqualStrings("tenant_b", env.tenant_id.?);
    try std.testing.expectEqualStrings("finance", env.active_graph.?);
    try std.testing.expectEqual(@as(usize, 1), env.roles.len);
    try std.testing.expectEqualStrings("Admin", env.roles[0]);
    try std.testing.expectEqual(@as(u64, 12), env.auth_version);
    try std.testing.expectEqual(@as(u64, 77), env.policy_version);
    try std.testing.expectEqual(principal_mod.PrincipalSource.quic_handler, env.source);
}

// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=ToPrincipal; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "toPrincipal reconstructs identity fields; scrubs session-local state" {
    const roles = [_][]const u8{ "Viewer", "Analyst" };
    const env = envelope_mod.PrincipalEnvelope{
        .user_id = 55,
        .username = "eve",
        .roles = &roles,
        .custom_roles = &.{},
        .tenant_id = "acme",
        .active_graph = "sales",
        .auth_version = 8,
        .policy_version = 200,
        .source = .distributed_worker,
    };

    const p = envelope_mod.toPrincipal(&env);

    try std.testing.expectEqual(@as(u64, 55), p.user_id.?);
    try std.testing.expectEqualStrings("eve", p.username.?);
    try std.testing.expectEqualStrings("acme", p.tenant_id.?);
    try std.testing.expectEqualStrings("sales", p.active_graph.?);
    try std.testing.expectEqual(@as(usize, 2), p.roles.len);
    try std.testing.expectEqualStrings("Viewer", p.roles[0]);
    try std.testing.expectEqualStrings("Analyst", p.roles[1]);
    try std.testing.expectEqual(@as(u64, 8), p.auth_version);
    try std.testing.expectEqual(principal_mod.PrincipalSource.distributed_worker, p.source);

    // Session-local fields must be scrubbed.
    try std.testing.expect(p.session_id == null);
    try std.testing.expect(p.elevation_until == null);
    try std.testing.expect(p.api_key_id == null);
    try std.testing.expect(p.certificate_subject == null);
    try std.testing.expect(p.risk_context.ip_address == null);
}

// ---------------------------------------------------------------------------
// Wire format sanity: magic bytes and version byte are at expected offsets
// ---------------------------------------------------------------------------

test "serialized envelope starts with GPSP magic and version 1" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const original = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = null,
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 0,
        .source = .unattributed,
    };

    const bytes = try envelope_mod.serialize(allocator, original);
    defer allocator.free(bytes);

    try std.testing.expect(bytes.len >= 5);
    try std.testing.expectEqualStrings("GPSP", bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 1), bytes[4]);
}
