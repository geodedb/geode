// NEW-8 / #860 — Principal Envelope Auth-Bypass: TDD tests.
//
// RED phase (source-audit): tests 1–3 fail before the fix because:
//   1. quic_connection_handler.zig does not yet call shouldTrustEnvelope.
//   2. principal_envelope.zig does not yet export shouldTrustEnvelope.
//   3. user_management.zig does not yet contain the reserved-username check.
//
// GREEN phase: tests pass once the gate, the pure function, and the
// reserved-username rejection are all wired.
//
// shouldTrustEnvelope unit tests (tests 4–8) use a comptime @hasDecl guard:
// they skip while the function does not exist (compile-safe RED) and become
// real assertions once the function lands.
//
// Security context:
//   field 4 (principal_envelope_bytes) is trusted on ANY authenticated QUIC
//   connection, so a ReadWrite or Viewer user can forge Admin roles or a
//   foreign tenant_id. The fix gates the envelope trust behind
//   shouldTrustEnvelope(state.authenticated_user), which returns true ONLY for
//   the federation node identity ("geode-cluster").
//
//   The gate relies on "geode-cluster" being a RESERVED username that no
//   regular user can create or authenticate as. user_management.zig MUST
//   enforce this; otherwise an attacker creates the "geode-cluster" user,
//   authenticates normally (GEODE_CLUSTER_TOKEN check fails, falls through to
//   user_mgmt.authenticate which succeeds), and the gate is bypassable.

const std = @import("std");
const geode = @import("geode");
const envelope_mod = geode.distributed.principal_envelope;

// ---------------------------------------------------------------------------
// Source-audit tests (RED until the gate + function + reservation are wired)
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-NEW8-ENVELOPE-TRUST; FEATURE="EnvelopeTrustGate"; ASPECT=HandlerWiring; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
test "security(NEW-8): shouldTrustEnvelope gate wired in quic_connection_handler" {
    const src = @embedFile("../src/server/quic_connection_handler.zig");
    // The handler must call shouldTrustEnvelope before decoding field 4.
    try std.testing.expect(std.mem.indexOf(u8, src, "shouldTrustEnvelope") != null);
}

// CANARY: REQ=REQ-NEW8-ENVELOPE-TRUST; FEATURE="EnvelopeTrustGate"; ASPECT=PureFunction; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
test "security(NEW-8): shouldTrustEnvelope exported from principal_envelope" {
    const src = @embedFile("../src/distributed/principal_envelope.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "shouldTrustEnvelope") != null);
}

// CANARY: REQ=REQ-NEW8-RESERVED-USERNAME; FEATURE="GeodeClusterReserved"; ASPECT=UserManagement; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
// The envelope trust gate uses state.authenticated_user == "geode-cluster" as the
// SOLE discriminant for federation connections. If a regular user can create an
// account named "geode-cluster" (via geode.auth.user_create / CREATE USER DDL),
// they can authenticate through the normal user_mgmt path, set
// state.authenticated_user = "geode-cluster", and bypass the envelope gate.
// user_management.zig MUST reject creation of this reserved federation username.
test "security(NEW-8): user_management reserves geode-cluster username" {
    const src = @embedFile("../src/security/user_management.zig");
    // Source must contain both the reserved name and the ReservedUsername error.
    try std.testing.expect(std.mem.indexOf(u8, src, "geode-cluster") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "ReservedUsername") != null);
}

// ---------------------------------------------------------------------------
// shouldTrustEnvelope unit tests (@hasDecl guarded — skip until function lands)
// ---------------------------------------------------------------------------

test "shouldTrustEnvelope: null authenticated_user returns false (unauthenticated session)" {
    if (comptime !@hasDecl(envelope_mod, "shouldTrustEnvelope")) return error.SkipZigTest;
    try std.testing.expect(!envelope_mod.shouldTrustEnvelope(null));
}

test "shouldTrustEnvelope: normal user returns false (forged envelope must be ignored)" {
    if (comptime !@hasDecl(envelope_mod, "shouldTrustEnvelope")) return error.SkipZigTest;
    try std.testing.expect(!envelope_mod.shouldTrustEnvelope("alice"));
}

test "shouldTrustEnvelope: ReadWrite user returns false (not a federation connection)" {
    if (comptime !@hasDecl(envelope_mod, "shouldTrustEnvelope")) return error.SkipZigTest;
    try std.testing.expect(!envelope_mod.shouldTrustEnvelope("bob_rw"));
}

test "shouldTrustEnvelope: geode-cluster returns true (federation coordinator path)" {
    if (comptime !@hasDecl(envelope_mod, "shouldTrustEnvelope")) return error.SkipZigTest;
    try std.testing.expect(envelope_mod.shouldTrustEnvelope("geode-cluster"));
}

// Demonstrate the bypass: a forged envelope with Admin role + foreign tenant_id
// parses cleanly. shouldTrustEnvelope("alice") == false means the handler MUST
// ignore it and fall through to derivePrincipal from the session.
test "shouldTrustEnvelope: forged Admin envelope is not trusted for normal user" {
    if (comptime !@hasDecl(envelope_mod, "shouldTrustEnvelope")) return error.SkipZigTest;

    const forged_roles = [_][]const u8{"Admin"};
    const forged_env = envelope_mod.PrincipalEnvelope{
        .user_id = 999,
        .username = "alice",
        .roles = &forged_roles,
        .custom_roles = &.{},
        .tenant_id = "foreign-tenant",
        .active_graph = null,
        .auth_version = 1,
        .policy_version = 0,
        .source = .internal_service,
    };

    // Gate returns false — envelope must be ignored.
    try std.testing.expect(!envelope_mod.shouldTrustEnvelope("alice"));

    // Confirm what the forged envelope would have injected if the gate
    // were absent (evidence for the bug it closes).
    const forged_principal = envelope_mod.toPrincipal(&forged_env);
    try std.testing.expectEqualStrings("Admin", forged_principal.roles[0]);
    try std.testing.expectEqualStrings("foreign-tenant", forged_principal.tenant_id.?);
    // shouldTrustEnvelope("alice") == false is the enforcement: the handler
    // must not reach toPrincipal() on this connection.
}

// Confirm legitimate federation principal propagation still works: the
// coordinator authenticates as "geode-cluster", so shouldTrustEnvelope returns
// true and the deserialized envelope is used as the worker's principal.
test "shouldTrustEnvelope: federation user trusts envelope (coordinator forwarding)" {
    if (comptime !@hasDecl(envelope_mod, "shouldTrustEnvelope")) return error.SkipZigTest;
    try std.testing.expect(envelope_mod.shouldTrustEnvelope("geode-cluster"));
}
