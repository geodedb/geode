// NEW-8 / #860 — Principal Envelope Auth-Bypass: TDD tests.
//
// RED phase (module-level): @hasDecl checks fail (return false) before
// shouldTrustEnvelope is added to principal_envelope.zig and before
// RESERVED_USERNAMES is added to user_management.zig. The tests turn GREEN
// once the fix is wired (fix(security) commit).
//
// Handler gate source-audit (verifying shouldTrustEnvelope is called in
// quic_connection_handler.zig) is done in src/server/test_federation_server_auth.zig
// following the existing @embedFile("quic_connection_handler.zig") pattern.
//
// Security context:
//   field 4 (principal_envelope_bytes) is trusted on ANY authenticated QUIC
//   connection pre-fix, so a ReadWrite or Viewer user can forge Admin roles or a
//   foreign tenant_id. The fix gates the envelope trust behind
//   shouldTrustEnvelope(state.authenticated_user), which returns true ONLY for
//   the federation node identity ("geode-cluster").
//
//   The gate relies on "geode-cluster" being a RESERVED username. Without that
//   reservation, an attacker could CREATE USER "geode-cluster", authenticate
//   normally (validateFederationAuth fails on token mismatch, falls through to
//   user_mgmt.authenticate which succeeds), set state.authenticated_user =
//   "geode-cluster", and bypass the gate.

const std = @import("std");
const geode = @import("geode");
const envelope_mod = geode.distributed.principal_envelope;
// user_management is exported directly from geode (not geode.security)
const user_mgmt = geode.user_management;

// ---------------------------------------------------------------------------
// Module-level RED/GREEN checks (RED until fix lands; GREEN after)
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-NEW8-ENVELOPE-TRUST; FEATURE="EnvelopeTrustGate"; ASPECT=PureFunction; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
test "security(NEW-8): shouldTrustEnvelope exported from principal_envelope" {
    try std.testing.expect(@hasDecl(envelope_mod, "shouldTrustEnvelope"));
}

// CANARY: REQ=REQ-NEW8-RESERVED-USERNAME; FEATURE="GeodeClusterReserved"; ASPECT=UserManagement; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
// "geode-cluster" must be reserved in user_management so the gate cannot be
// bypassed by creating a user with the federation identity name.
test "security(NEW-8): RESERVED_USERNAMES exported from user_management" {
    try std.testing.expect(@hasDecl(user_mgmt, "RESERVED_USERNAMES"));
}

test "security(NEW-8): geode-cluster is in RESERVED_USERNAMES" {
    if (comptime !@hasDecl(user_mgmt, "RESERVED_USERNAMES")) return error.SkipZigTest;
    var found = false;
    for (user_mgmt.RESERVED_USERNAMES) |name| {
        if (std.mem.eql(u8, name, "geode-cluster")) found = true;
    }
    try std.testing.expect(found);
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

    // Gate returns false — envelope must be ignored by the handler.
    try std.testing.expect(!envelope_mod.shouldTrustEnvelope("alice"));

    // Confirm what the forged envelope would have injected if the gate were absent
    // (evidence for the pre-fix bug): toPrincipal on a forged blob yields Admin
    // role + foreign tenant_id unchecked.
    const forged_principal = envelope_mod.toPrincipal(&forged_env);
    try std.testing.expectEqualStrings("Admin", forged_principal.roles[0]);
    try std.testing.expectEqualStrings("foreign-tenant", forged_principal.tenant_id.?);
    // shouldTrustEnvelope("alice") == false is the enforcement: the handler
    // must never call toPrincipal() for non-federation connections.
}

// Confirm legitimate federation principal propagation still works: the
// coordinator authenticates as "geode-cluster", so shouldTrustEnvelope returns
// true and the deserialized envelope is used as the worker's principal.
test "shouldTrustEnvelope: federation user trusts envelope (coordinator forwarding preserved)" {
    if (comptime !@hasDecl(envelope_mod, "shouldTrustEnvelope")) return error.SkipZigTest;
    try std.testing.expect(envelope_mod.shouldTrustEnvelope("geode-cluster"));
}
