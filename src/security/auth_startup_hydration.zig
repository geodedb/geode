// CANARY: REQ=REQ-SONNY-6567-AUTH-HYDRATION; FEATURE="AuthDDLPersistence"; ASPECT=StartupHydrationFailsClosed; STATUS=TESTED; TEST=tests/test_sonny6567_auth_hydration.zig; OWNER=security; UPDATED=2026-11-15
//! SONNY-6567 (5): the server's startup loads of the stored auth state into
//! the live tables, each loading every record or failing.
//!
//! `server_init.wireAuthDDLCallbacks` loaded the per-graph grants into the
//! live `GraphRBACPolicy` and the FLE role grants into `fle_role_grants`
//! inline, and logged and went on when a step failed: an empty or partial
//! live table, so a user lost (or, for a policy, a deny lost its effect) what
//! the stored state says, with nothing but a log line. Startup now fails
//! instead (`main.zig` propagates the error). The loads live here, a named
//! module, so the regression suite drives the code the server runs.
//!
//! Named build module ("auth_startup_hydration"): it imports
//! `auth_graph_manager`, which imports geode (as `policy_persistence` does).

const std = @import("std");
const geode = @import("geode");
const auth_graph_manager = @import("auth_graph_manager");

const multi_graph_security = geode.multi_graph_security;
const fle_role_grants = geode.security.fle_role_grants;
const auth_dispatch = geode.auth_dispatch;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

/// Load every stored per-graph grant into `policy`. Returns how many.
pub fn hydrateGraphGrants(
    allocator: std.mem.Allocator,
    agm: *AuthGraphManager,
    policy: *multi_graph_security.GraphRBACPolicy,
) !usize {
    const grants = try agm.listGraphGrants(allocator);
    defer allocator.free(grants);
    if (grants.len == 0) return 0;
    const entries = try allocator.alloc(multi_graph_security.GraphGrantLoadEntry, grants.len);
    defer allocator.free(entries);
    // By pointer: `getGraphName` slices the record's own buffer, which must
    // outlive the loop. The by-value capture this replaced (in
    // server_init.zig) sliced a per-iteration stack copy, so every entry's
    // graph name was whatever that stack slot held at `loadGraphGrants`: a
    // grant was loaded under another graph's name (or garbage) at startup.
    for (grants, 0..) |*g, i| {
        entries[i] = .{ .user_id = g.user_id, .graph_name = g.getGraphName(), .action = g.action };
    }
    try policy.loadGraphGrants(entries);
    return grants.len;
}

/// Load every stored FLE role grant into `fle_role_grants`. Returns how many.
/// A grant whose user no longer exists is not loaded: it names no one (the
/// user's deletion is what removed them; it is not a read failure).
pub fn hydrateFleRoleGrants(allocator: std.mem.Allocator, agm: *AuthGraphManager) !usize {
    const list = try agm.listFleRoleGrants(allocator);
    defer allocator.free(list);
    var loaded: usize = 0;
    for (list) |g| {
        const user = agm.storage.getUser(g.user_id) orelse continue;
        try fle_role_grants.load(user.getUsername(), g.role);
        loaded += 1;
    }
    return loaded;
}

// CANARY: REQ=REQ-SONNY-6608-MFA-HYDRATION; FEATURE="MFA authentication"; ASPECT=StartupLoadsEnrollments; STATUS=TESTED; TEST=tests/test_sonny6608_mfa_persist.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6608: load every stored MFA enrollment (a user record's
/// `mfa_secret`, its `MfaRecoveryCodes` digests) into the mfa_* procedures'
/// store. Returns how many. A recovery-code record that does not parse fails
/// the load (the chain verified, so it is a bug, not tampering). They were
/// process memory only: a restart lost every enrollment.
pub fn hydrateMfaEnrollments(allocator: std.mem.Allocator, agm: *AuthGraphManager) !usize {
    const ids = try agm.storage.cachedUserIds(allocator);
    defer allocator.free(ids);
    var loaded: usize = 0;
    for (ids) |id| {
        const rec = agm.storage.getUser(id) orelse continue;
        const secret = rec.getMFASecret() orelse continue;
        const digests = try agm.mfaRecoveryDigests(allocator, id);
        defer if (digests) |d| allocator.free(d);
        try auth_dispatch.loadMfaEnrollment(rec.getUsername(), secret, digests orelse &.{});
        loaded += 1;
    }
    return loaded;
}

/// SONNY-6608: the mfa_* procedures' write-through to `agm`
/// (`auth_dispatch.setMfaPersistCallbacks`).
pub fn mfaPersistCallbacks(agm: *AuthGraphManager) auth_dispatch.MfaPersistCallbacks {
    return .{
        .ctx = @ptrCast(agm),
        .enroll_fn = &mfaEnroll,
        .set_enabled_fn = &mfaSetEnabled,
    };
}

fn mfaEnroll(ctx: ?*anyopaque, username: []const u8, secret_base32: []const u8, recovery_digests: []const [32]u8) anyerror!void {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.enrollMfaWriteThrough(&agm.hmac_key, username, secret_base32, recovery_digests);
}

fn mfaSetEnabled(ctx: ?*anyopaque, username: []const u8, enabled: bool) anyerror!void {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.setMfaEnabledWriteThrough(&agm.hmac_key, username, enabled);
}
