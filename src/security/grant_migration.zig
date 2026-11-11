// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=Module; STATUS=TESTED; TEST=tests/test_gps_grant_migration.zig; OWNER=security; UPDATED=2026-10-11
//
// grant_migration.zig — startup task that retires the (:Policy) rows earlier
// versions migrated legacy (:GraphGrant) nodes into.
//
// History: GPS Phase 6 (Task 6-4) turned every (:GraphGrant) into an allow
// Policy named "auto_migrated_grant_<username>_<graph>_<action>" at startup,
// and gps.decide() read grants only through those rows. That was wrong three
// ways (REQ-SEC-PER-GRAPH-GRANTS, 2026-10):
//   - a runtime GRANT updated the live GraphRBACPolicy, which decide() did not
//     read for most actions, so it took effect only after a restart;
//   - REVOKE removed the (:GraphGrant) but never the migrated Policy row, so
//     once a restart had migrated a grant, revoking it changed nothing, at
//     once or after any later restart;
//   - the row was scoped to the grant's graph, but a graph-scoped allow policy
//     matched database-wide requests, so a WRITE grant on one graph allowed
//     writes on every graph.
//
// Now decide() reads grants from the live GraphRBACPolicy (hydrated from the
// (:GraphGrant) nodes at startup, updated at once by GRANT and REVOKE), scoped
// to the request's graph. The (:GraphGrant) nodes stay the only record of a
// grant. Each startup drops the migrated rows (catalog and __geode_security)
// so a stale one cannot keep a revoked grant alive. Nothing else writes
// policies with the prefix; a policy an operator created under that name is
// dropped too (documented in docs/GQL_AUTH_DDL.md).
//
// Thread-safety: None. Must be called before the QUIC listener accepts
// connections (inside wireGpsPolicyHooks, after hydrateCatalog).
//
// Circular-import note: this file imports both auth_graph_manager and
// policy_persistence. Both are named build modules (not relative-path
// imports). If a file in the geode root module needs to reference this
// module it must also be wired as a named module in build.zig — see the
// grant_migration_mod definition there.

const std = @import("std");
// policy_catalog lives in the geode root module.
const policy_catalog = @import("geode").security.policy_catalog;
// policy_persistence and auth_graph_manager are named build modules (cannot be
// relative imports because they themselves import geode, creating a cycle).
const policy_persistence = @import("policy_persistence");
const auth_graph_manager = @import("auth_graph_manager");

const PolicyCatalog = policy_catalog.PolicyCatalog;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

/// The name prefix of the Policy rows earlier versions migrated grants into.
pub const migrated_policy_prefix = "auto_migrated_grant_";

// CANARY: REQ=REQ-SEC-PER-GRAPH-GRANTS; FEATURE="PerGraphGrants"; ASPECT=RetireMigratedGrantPolicies; STATUS=TESTED; TEST=tests/test_gps_grant_migration.zig; OWNER=security; UPDATED=2026-10-11
/// Drop every policy named `migrated_policy_prefix`* from `cat` and from
/// __geode_security (resealing the HMAC chain). Returns how many were
/// dropped. Grants are not touched: they live on as (:GraphGrant) nodes and
/// in the live GraphRBACPolicy, which gps.decide() reads.
///
/// `hmac_key` must be the key that seals the __geode_security chain
/// (agm.hmac_key at the server).
///
/// SONNY-4877: fails closed. Every migrated allow is disabled in `cat` (and
/// cached decisions invalidated) before anything that can fail, so when this
/// returns an error — which the server logs and starts anyway — no migrated
/// allow can keep a revoked grant in force. Migrated denies stay in force
/// until they are dropped. Rows not yet dropped stay disabled in the catalog
/// and in the store; the next run (the next startup) drops them.
pub fn retireMigratedGrantPolicies(
    allocator: std.mem.Allocator,
    agm: *AuthGraphManager,
    hmac_key: *const [32]u8,
    cat: *PolicyCatalog,
) !u32 {
    _ = cat.disableAllowPoliciesWithPrefix(migrated_policy_prefix);

    // Collect first: removePolicy reorders the catalog's list.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    for (cat.listPolicies()) |p| {
        if (!std.mem.startsWith(u8, p.name, migrated_policy_prefix)) continue;
        const name = try allocator.dupe(u8, p.name);
        names.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
    }

    var retired: u32 = 0;
    var missing_from_store = false;
    for (names.items) |name| {
        // The stored record first: a row left in the store would come back at
        // the next restart. A row missing from the store (only ever in the
        // catalog) is still dropped from the catalog.
        policy_persistence.dropPolicy(agm, hmac_key, name) catch |err| switch (err) {
            error.PolicyNotFound => missing_from_store = true,
            else => return err,
        };
        // PolicyNotFound is removePolicy's only error, and cannot happen:
        // the name was just read from the catalog.
        cat.removePolicy(name) catch {};
        retired += 1;
    }
    // SONNY-4877: dropPolicy removes the record, then reseals. When an
    // earlier run failed between the two, the record is gone but the chain
    // still counts it; this run finds no record to drop, so nothing would
    // reseal. Reseal once so the chain verifies again.
    if (missing_from_store) try agm.sealChain(hmac_key);
    return retired;
}
