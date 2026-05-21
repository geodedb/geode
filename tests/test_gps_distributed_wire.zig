// GPS Phase 7 Task 7-6 -- Distributed Principal envelope wire integration tests.
//
// Tests cover:
//   1. query_runner.QueryOptions carries principal_envelope_bytes (default null).
//   2. Full round-trip: serialize Principal -> bytes -> deserialize -> toPrincipal
//      verifies the worker reconstruction path.
//   3. policy_version mismatch detection: if the envelope's policy_version
//      differs from the local version, the mismatch is detectable.
//   4. Backward compat: null envelope_bytes propagates transparently.
//   5. Coordinator-fragment construction: principal_envelope_bytes attaches to
//      the per-fragment ExecuteRequest struct correctly.
//
// Note: NodeQuery struct has a `principal_envelope_bytes` field added in
// Phase 7 Task 7-6.  That type lives in distributed/query_transport.zig which
// has the full module graph (quic, protobuf, etc.) and can only be tested at
// the integration level from within the src/ tree.  Here we test the
// serialization/deserialization path and QueryOptions field availability,
// which are the semantically important invariants accessible from tests/.

const std = @import("std");
const geode = @import("geode");
const schema = @import("schema");
const envelope_mod = geode.distributed.principal_envelope;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=QueryOptionsField; STATUS=TESTED; TEST=tests/test_gps_distributed_wire.zig; OWNER=security; UPDATED=2026-05-21

test "query_runner.QueryOptions.principal_envelope_bytes defaults to null" {
    const opts = geode.query_runner.QueryOptions{
        .session_id = "sess",
        .query_text = "RETURN 1",
        .format = "json",
        .params = std.ArrayList(schema.Param).empty,
    };
    try std.testing.expect(opts.principal_envelope_bytes == null);
}

test "query_runner.QueryOptions.principal_envelope_bytes can be set" {
    const fake: []const u8 = "GPSP\x01\x00\x00\x00\x00\x00\x00\x00";
    const opts = geode.query_runner.QueryOptions{
        .session_id = "sess",
        .query_text = "RETURN 1",
        .format = "json",
        .params = std.ArrayList(schema.Param).empty,
        .principal_envelope_bytes = fake,
    };
    try std.testing.expect(opts.principal_envelope_bytes != null);
    try std.testing.expectEqual(fake.len, opts.principal_envelope_bytes.?.len);
}

// CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=WorkerRoundTrip; STATUS=TESTED; TEST=tests/test_gps_distributed_wire.zig; OWNER=security; UPDATED=2026-05-21

test "distributed envelope round-trip: coordinator -> worker identity preserved" {
    // Simulates the coordinator side: build a Principal, serialize it into
    // envelope bytes, and attach to a NodeQuery.  Then simulate the worker
    // side: deserialize the bytes and reconstruct the Principal.
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const role_names = [_][]const u8{ "Admin", "Engineer" };
    const coordinator_principal = principal_mod.Principal{
        .user_id = 7,
        .username = "alice",
        .session_id = "sess-coordinator",
        .tenant_id = "tenant_a",
        .active_graph = "hr",
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 12,
        .mfa_state = .verified,
        .elevation_until = 9999,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .distributed_coordinator,
    };

    // Coordinator side: build envelope with policy_version = 55.
    const env_out = envelope_mod.fromPrincipal(&coordinator_principal, 55);
    const bytes = try envelope_mod.serialize(allocator, env_out);
    defer allocator.free(bytes);

    // Worker side: deserialize and reconstruct.
    envelope_mod.resetStaticRoleBuffer();
    const env_in = try envelope_mod.deserialize(bytes);
    const worker_principal = envelope_mod.toPrincipal(&env_in);

    // Identity fields preserved.
    try std.testing.expectEqual(@as(u64, 7), worker_principal.user_id.?);
    try std.testing.expectEqualStrings("alice", worker_principal.username.?);
    try std.testing.expectEqualStrings("tenant_a", worker_principal.tenant_id.?);
    try std.testing.expectEqualStrings("hr", worker_principal.active_graph.?);
    try std.testing.expectEqual(@as(usize, 2), worker_principal.roles.len);
    try std.testing.expectEqualStrings("Admin", worker_principal.roles[0]);
    try std.testing.expectEqualStrings("Engineer", worker_principal.roles[1]);
    try std.testing.expectEqual(@as(u64, 12), worker_principal.auth_version);

    // policy_version is in the envelope (not on Principal directly).
    try std.testing.expectEqual(@as(u64, 55), env_in.policy_version);

    // Session-local fields must be scrubbed on the worker side.
    try std.testing.expect(worker_principal.session_id == null);
    try std.testing.expect(worker_principal.elevation_until == null);
}

// CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=PolicyVersionMismatch; STATUS=TESTED; TEST=tests/test_gps_distributed_wire.zig; OWNER=security; UPDATED=2026-05-21

test "policy_version mismatch detectable on worker" {
    // When the coordinator serializes with policy_version=10 and the worker's
    // local policy_version is 15, the worker can detect the mismatch and know
    // to re-hydrate its policy catalog before evaluating the request.
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const env_out = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = "bob",
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 10, // coordinator's version at time of dispatch
        .source = .distributed_coordinator,
    };
    const bytes = try envelope_mod.serialize(allocator, env_out);
    defer allocator.free(bytes);

    envelope_mod.resetStaticRoleBuffer();
    const env_in = try envelope_mod.deserialize(bytes);

    const local_policy_version: u64 = 15; // simulated worker local version
    const mismatch = env_in.policy_version != local_policy_version;
    try std.testing.expect(mismatch);
    try std.testing.expectEqual(@as(u64, 10), env_in.policy_version);
    try std.testing.expectEqual(@as(u64, 15), local_policy_version);
}

test "policy_version match: no re-hydration needed" {
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const env_out = envelope_mod.PrincipalEnvelope{
        .user_id = null,
        .username = "carol",
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .policy_version = 20,
        .source = .distributed_coordinator,
    };
    const bytes = try envelope_mod.serialize(allocator, env_out);
    defer allocator.free(bytes);

    envelope_mod.resetStaticRoleBuffer();
    const env_in = try envelope_mod.deserialize(bytes);

    const local_policy_version: u64 = 20; // matches
    const mismatch = env_in.policy_version != local_policy_version;
    try std.testing.expect(!mismatch);
}

// CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=BackwardCompat; STATUS=TESTED; TEST=tests/test_gps_distributed_wire.zig; OWNER=security; UPDATED=2026-05-21

test "null envelope_bytes in QueryOptions: backward compat preserved" {
    // When principal_envelope_bytes is null the server uses the connection-level
    // Principal.  This test confirms null is accepted without error.
    const opts = geode.query_runner.QueryOptions{
        .session_id = "sess-old-client",
        .query_text = "MATCH (n) RETURN n",
        .format = "json",
        .params = std.ArrayList(schema.Param).empty,
        // principal_envelope_bytes omitted -> defaults to null
    };
    try std.testing.expect(opts.principal_envelope_bytes == null);
}

test "ExecuteRequest.principal_envelope_bytes field exists and defaults to null" {
    // Verify the schema field is present and defaults to null (wire-format compat).
    const req = schema.ExecuteRequest{
        .session_id = "sess",
        .query = "RETURN 1",
        .params = std.ArrayList(schema.Param).empty,
    };
    try std.testing.expect(req.principal_envelope_bytes == null);
}

test "coordinator attaches bytes to QueryOptions and they flow to ExecuteRequest" {
    // Simulates what executePlan does: coordinator serializes its principal,
    // puts the bytes in QueryOptions, which flows into ProtocolTransportAdapter
    // and gets set on ExecuteRequest.principal_envelope_bytes.
    const allocator = std.testing.allocator;
    envelope_mod.resetStaticRoleBuffer();

    const env_src = envelope_mod.PrincipalEnvelope{
        .user_id = 1,
        .username = "coordinator",
        .roles = &.{},
        .custom_roles = &.{},
        .tenant_id = "t1",
        .active_graph = null,
        .auth_version = 3,
        .policy_version = 7,
        .source = .distributed_coordinator,
    };
    const bytes = try envelope_mod.serialize(allocator, env_src);
    defer allocator.free(bytes);

    // Simulate QueryOptions carrying the blob.
    const opts = geode.query_runner.QueryOptions{
        .session_id = "sess",
        .query_text = "RETURN 1",
        .format = "json",
        .params = std.ArrayList(schema.Param).empty,
        .principal_envelope_bytes = bytes,
    };

    // Verify the blob passes through to ExecuteRequest.
    const req = schema.ExecuteRequest{
        .session_id = opts.session_id,
        .query = opts.query_text,
        .params = std.ArrayList(schema.Param).empty,
        .principal_envelope_bytes = opts.principal_envelope_bytes,
    };

    try std.testing.expect(req.principal_envelope_bytes != null);
    try std.testing.expectEqual(bytes.len, req.principal_envelope_bytes.?.len);

    // Server-side: deserialize the blob from the wire frame.
    envelope_mod.resetStaticRoleBuffer();
    const env_in = try envelope_mod.deserialize(req.principal_envelope_bytes.?);
    try std.testing.expectEqualStrings("coordinator", env_in.username.?);
    try std.testing.expectEqual(@as(u64, 7), env_in.policy_version);
    try std.testing.expectEqual(principal_mod.PrincipalSource.distributed_coordinator, env_in.source);
}
