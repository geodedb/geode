// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=Module; STATUS=TESTED; TEST=tests/test_gps_grant_migration.zig; OWNER=security; UPDATED=2026-05-20
//
// grant_migration.zig — one-shot startup task that converts legacy (:GraphGrant)
// nodes in __geode_security into first-class (:Policy) rows understood by the GPS
// decision engine (gps.decide).
//
// Design:
//   - Reads every GraphGrantRecord via agm.listGraphGrants().
//   - For each grant, resolves the user_id → username via agm.storage.getUser().
//   - Constructs a deterministic policy name:
//       "auto_migrated_grant_<username>_<graph>_<action>"
//   - Idempotent: skips any policy whose name already exists in the catalog.
//   - Writes via policy_persistence.persistPolicy so the HMAC chain stays
//     consistent.  Also adds the policy to the in-memory catalog so decide()
//     picks it up without a restart.
//
// Thread-safety: None.  Must be called before the QUIC listener accepts
// connections (i.e. inside wireGpsPolicyHooks, after hydrateCatalog).
//
// Circular-import note: this file imports both auth_graph_manager and
// policy_persistence.  Both are named build modules (not relative-path
// imports).  If a file in the geode root module needs to reference this
// module it must also be wired as a named module in build.zig — see the
// grant_migration_mod definition there.

const std = @import("std");
// policy_catalog lives in the geode root module.
const policy_catalog = @import("geode").security.policy_catalog;
// policy_persistence and auth_graph_manager are named build modules (cannot be
// relative imports because they themselves import geode, creating a cycle).
const policy_persistence = @import("policy_persistence");
const auth_graph_manager = @import("auth_graph_manager");

const PolicySpec = policy_catalog.PolicySpec;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const Action = policy_catalog.Action;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=MigrateGraphGrantsToPolicies; STATUS=TESTED; TEST=tests/test_gps_grant_migration.zig; OWNER=security; UPDATED=2026-05-20
/// Migrate legacy (:GraphGrant) nodes to (:Policy) rows in __geode_security.
///
/// For every GraphGrantRecord held by `agm`:
///   1. Resolve user_id → username.  Grants whose user_id no longer maps to a
///      live user record are silently skipped (the grant is orphaned).
///   2. Compute a deterministic policy name.  If a policy with that name already
///      exists in the catalog the grant is skipped (idempotent restart).
///   3. Persist the policy via policy_persistence.persistPolicy, which writes the
///      :Policy node to __geode_security and reseals the HMAC chain.
///   4. Add the policy to the in-memory catalog so decide() uses it immediately.
///
/// `hmac_key` must be the same key used to seal the __geode_security chain (i.e.
/// agm.hmac_key at the server — passed explicitly so callers and tests can
/// supply the correct key without mutating agm.hmac_key first).
///
/// Returns the count of grants actually migrated (i.e. not already present).
pub fn migrateGraphGrantsToPolicies(
    allocator: std.mem.Allocator,
    agm: *AuthGraphManager,
    hmac_key: *const [32]u8,
    cat: *PolicyCatalog,
) !u32 {
    var migrated: u32 = 0;

    // Fetch all persisted grants.  Caller owns the slice.
    const grants = try agm.listGraphGrants(allocator);
    defer allocator.free(grants);

    for (grants) |grant| {
        // Resolve user_id → username.
        const user_record = agm.storage.getUser(grant.user_id) orelse {
            // Orphaned grant — user was deleted.  Skip silently.
            continue;
        };
        const username = user_record.getUsername();
        const graph_name = grant.getGraphName();
        const action_str = actionName(grant.action);

        // Build deterministic policy name.
        const policy_name = try std.fmt.allocPrint(
            allocator,
            "auto_migrated_grant_{s}_{s}_{s}",
            .{ username, graph_name, action_str },
        );
        defer allocator.free(policy_name);

        // Idempotency check: skip if already in the catalog.
        var already_exists = false;
        for (cat.listPolicies()) |p| {
            if (std.mem.eql(u8, p.name, policy_name)) {
                already_exists = true;
                break;
            }
        }
        if (already_exists) continue;

        // Build the filter expression: current_user() = '<username>'
        // This matches the pattern used by the GPS expression engine's
        // eq_current_user predicate.
        const expr = try std.fmt.allocPrint(
            allocator,
            "current_user() = '{s}'",
            .{username},
        );
        defer allocator.free(expr);

        const actions = [_]Action{actionFromCode(grant.action)};

        const spec = PolicySpec{
            .name = policy_name,
            .scope_graph = graph_name,
            .actions = &actions,
            .effect = .allow,
            .expression_source = expr,
            .enabled = true,
        };

        // Persist to __geode_security (reseals HMAC chain).
        try policy_persistence.persistPolicy(agm, hmac_key, spec);

        // Add to the live in-memory catalog so decide() uses it immediately.
        try cat.addPolicy(spec);

        migrated += 1;
    }

    return migrated;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn actionFromCode(code: u8) Action {
    return switch (code) {
        0 => .read,
        1 => .write,
        2 => .schema,
        else => .read,
    };
}

fn actionName(code: u8) []const u8 {
    return switch (code) {
        0 => "read",
        1 => "write",
        2 => "schema",
        else => "unknown",
    };
}
