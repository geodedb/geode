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
const geode_cb = @import("crypto_backend");
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
        // SONNY-6609: a secret stored in plaintext (before SONNY-6609) is
        // sealed first.
        _ = try agm.sealPlaintextMfaSecretWriteThrough(&agm.hmac_key, id);
        const rec = agm.storage.getUser(id) orelse continue;
        var buf: [AuthGraphManager.mfa_secret_max_plain]u8 = undefined;
        defer geode_cb.secureZero(&buf);
        const secret = (try agm.openMfaSecret(id, &buf)) orelse continue;
        const digests = try agm.mfaRecoveryDigests(allocator, id);
        defer if (digests) |d| allocator.free(d);
        try auth_dispatch.loadMfaEnrollment(rec.getUsername(), secret, digests orelse &.{});
        // SONNY-6619: a stored lockout (or offline count) survives a restart.
        if (agm.mfaAttempts(id)) |a| try auth_dispatch.loadMfaAttempts(rec.getUsername(), a.fail_count, a.lockout_until_ms);
        loaded += 1;
    }
    return loaded;
}

// CANARY: REQ=REQ-SONNY-6609-SM-MFA-HYDRATION; FEATURE="MFA authentication"; ASPECT=StartupLoadsSecurityManagerMfa; STATUS=TESTED; TEST=tests/test_sonny6609_mfa_at_rest.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6609: load every hydrated SecurityManager user's stored MFA state:
/// its TOTP secret (opened) and its recovery codes (from their digests).
/// Returns how many users have either. A secret that does not open fails
/// the load.
pub fn hydrateSecurityManagerMfa(allocator: std.mem.Allocator, agm: *AuthGraphManager, sm: *geode.auth.SecurityManager) !usize {
    const ids = try agm.storage.cachedUserIds(allocator);
    defer allocator.free(ids);
    var loaded: usize = 0;
    for (ids) |id| {
        if (!sm.users.contains(id)) continue;
        var buf: [AuthGraphManager.mfa_secret_max_plain]u8 = undefined;
        defer geode_cb.secureZero(&buf);
        const secret = try agm.openMfaSecret(id, &buf);
        const digests = try agm.mfaRecoveryDigests(allocator, id);
        defer if (digests) |d| allocator.free(d);
        if (secret == null and digests == null) continue;
        try sm.loadMfaState(id, secret, digests orelse &.{});
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
        .set_attempts_fn = &mfaSetAttempts,
    };
}

fn mfaEnroll(ctx: ?*anyopaque, username: []const u8, secret_base32: []const u8, recovery_digests: []const [32]u8) anyerror!void {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.enrollMfaWriteThrough(&agm.hmac_key, username, secret_base32, recovery_digests);
}

fn mfaSetAttempts(ctx: ?*anyopaque, username: []const u8, fail_count: u32, lockout_until_ms: i64) anyerror!void {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.setMfaAttemptsWriteThrough(&agm.hmac_key, username, .{ .fail_count = fail_count, .lockout_until_ms = lockout_until_ms });
}

fn mfaSetEnabled(ctx: ?*anyopaque, username: []const u8, enabled: bool) anyerror!void {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.setMfaEnabledWriteThrough(&agm.hmac_key, username, enabled);
}

/// SONNY-6614: SecurityManager as the server builds it at startup
/// (`server_init.hydrateSecurityManagerFromGraph`), and what it loaded.
pub const LoadedSecurityManager = struct {
    sm: geode.auth.SecurityManager,
    role_count: usize,
    user_count: usize,
    assignment_count: usize,
};

/// Build SecurityManager from the stored records: the roles, the users
/// (their MFA state with `hydrateSecurityManagerMfa`), the role
/// memberships. `hmac_key`: the security graph's key, for the runtime
/// write-through and for opening the MFA secrets.
pub fn hydrateSecurityManager(allocator: std.mem.Allocator, agm: *AuthGraphManager, hmac_key: ?[32]u8) !LoadedSecurityManager {
    const geode_auth = geode.auth;
    var sm = try geode_auth.SecurityManager.initEmpty(allocator);
    // CANARY: REQ=REQ-SONNY-6614-SM-LOAD-ERRDEFER; FEATURE="AuthGraphManager Integration"; ASPECT=LoadFreesOnFailure; STATUS=TESTED; TEST=tests/test_sonny6614_auth_residuals.zig; OWNER=security; UPDATED=2026-11-15
    // SONNY-6614: a load that fails part way frees everything (it leaked the
    // SecurityManager and every record it had copied).
    errdefer sm.deinit();

    // Hydrate roles first so user-role memberships can be restored without side effects.
    var role_count: usize = 0;
    var role_it = agm.storage.roleIterator();
    while (role_it.next()) |record| {
        // SONNY-6614: copies the map did not take are freed.
        const name = try allocator.dupe(u8, record.getName());
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, record.getDescription());
        errdefer allocator.free(description);
        const role = geode_auth.Role{
            .id = record.id,
            .name = name,
            .description = description,
            .permissions = std.ArrayList(geode_auth.PermissionId).empty,
            .created_at = record.created_at,
            .is_system = record.is_system,
            .priority = record.priority,
            .parent_role = if (record.parent_role == 0) null else record.parent_role,
        };
        try sm.roles.put(record.id, role);
        role_count += 1;
    }

    var user_count: usize = 0;
    var it = agm.storage.userIterator();
    while (it.next()) |record| {
        try sm.hydrateUser(
            record.id,
            record.getUsername(),
            record.getEmail(),
            record.getPasswordHash(),
            record.is_superuser,
            record.is_active,
            record.is_default_user,
            record.password_reset_required,
            record.mfa_enabled,
            null, // SONNY-6609: the secret is stored sealed; loaded below
            record.auth_version,
            record.getAttributesJson(),
        );
        user_count += 1;
    }
    // SONNY-6609: each user's TOTP secret (opened) and recovery codes.
    if (hmac_key) |k| agm.hmac_key = k;
    _ = try hydrateSecurityManagerMfa(allocator, agm, &sm);

    var assignment_count: usize = 0;
    var membership_it = agm.storage.userIterator();
    while (membership_it.next()) |record| {
        const role_ids = try agm.storage.listUserRoleIds(allocator, record.id);
        defer allocator.free(role_ids);

        if (role_ids.len == 0) continue;
        var entry = try sm.rbac.user_roles.getOrPut(record.id);
        if (!entry.found_existing) {
            // SONNY-6614: an entry whose list could not be made is removed
            // (its value was undefined, and the deinit freed it).
            entry.value_ptr.* = std.ArrayList(geode_auth.RoleId).initCapacity(allocator, role_ids.len) catch |err| {
                _ = sm.rbac.user_roles.remove(record.id);
                return err;
            };
        }
        for (role_ids) |role_id| {
            try entry.value_ptr.append(allocator, role_id);
            assignment_count += 1;
        }
    }

    if (hmac_key) |k| sm.hmac_key = k;
    return .{ .sm = sm, .role_count = role_count, .user_count = user_count, .assignment_count = assignment_count };
}

/// SONNY-6614 / SONNY-6619: SecurityManager's hooks for the auth procedures
/// (`auth_dispatch.setSecurityManagerHooks`).
pub fn securityManagerHooks(sm: *geode.auth.SecurityManager) auth_dispatch.SecurityManagerHooks {
    return .{
        .ctx = @ptrCast(sm),
        .remove_user_fn = &smRemoveUser,
        .load_mfa_fn = &smLoadMfa,
        .set_mfa_enabled_fn = &smSetMfaEnabled,
    };
}

fn smOf(ctx: ?*anyopaque) *geode.auth.SecurityManager {
    return @ptrCast(@alignCast(ctx.?));
}

fn smRemoveUser(ctx: ?*anyopaque, username: []const u8) void {
    smOf(ctx).removeUserByName(username);
}

fn smLoadMfa(ctx: ?*anyopaque, username: []const u8, secret: []const u8, digests: []const [32]u8) anyerror!void {
    try smOf(ctx).loadMfaStateByName(username, secret, digests, false);
}

fn smSetMfaEnabled(ctx: ?*anyopaque, username: []const u8, enabled: bool) void {
    smOf(ctx).setMfaEnabledByName(username, enabled);
}
