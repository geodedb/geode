// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=Module; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
//
// policy_persistence.zig — bridge between the in-memory PolicyCatalog
// (policy_catalog.zig) and the HMAC-chained __geode_security graph managed by
// AuthGraphManager (auth_graph_manager.zig).
//
// Three entry points:
//   persistPolicy   — write a PolicySpec to the security graph and seal.
//   dropPolicy      — remove a policy by name from the security graph and seal.
//   hydrateCatalog  — on startup, load all :Policy nodes from the security
//                     graph into the given PolicyCatalog.
//
// Design: this module owns ONLY the translation layer. All HMAC arithmetic,
// chain sealing, and node I/O live in AuthGraphManager / UserStorageBackend.
// The catalog remains the authoritative in-memory view; the security graph is
// the durable backing store.
//
// Thread-safety: none. Callers must hold any required locks before calling.
// In the server, policy DDL executes serially inside the query executor and
// startup hydration completes before the QUIC listener accepts connections.

const std = @import("std");
// policy_catalog is part of the geode root module.
const policy_catalog = @import("geode").security.policy_catalog;
// auth_graph_manager is a separate named build module (imports geode, so cannot be a relative path).
const auth_graph_manager = @import("auth_graph_manager");

const PolicySpec = policy_catalog.PolicySpec;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

// ---------------------------------------------------------------------------
// Action <-> operation byte mapping
//
// PolicyRecord.operation is a packed byte where each bit represents an Action.
// Bit positions must stay in sync with the Action enum order in policy_catalog.
//   bit 0 = read
//   bit 1 = write
//   bit 2 = match_
//   bit 3 = create
//   bit 4 = update
//   bit 5 = delete
//   bit 6 = schema
//   bit 7 = decrypt_field  (Phase 5 task 5-3)
//
// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=PolicyPersistenceBitMapping; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
//
// Note: unwrap_key does not have a bit slot in the current u8 encoding.
// It is functional in-memory (gps.decide honours it via policyMatchesAction)
// but is silently excluded from durable persistence until a Phase 6 schema
// upgrade widens the operation field.  An in-memory-only unwrap_key policy
// therefore does not survive a server restart.  Operators who need durable
// unwrap_key grants should use Admin role assignment (which is always allowed).
// ---------------------------------------------------------------------------

fn actionsToOperationByte(actions: []const policy_catalog.Action) u8 {
    var op: u8 = 0;
    for (actions) |a| {
        const bit: ?u8 = switch (a) {
            .read => 0,
            .write => 1,
            .match_ => 2,
            .create => 3,
            .update => 4,
            .delete => 5,
            .schema => 6,
            .decrypt_field => 7,
            // unwrap_key has no bit slot in the current u8 encoding.
            // It is silently excluded from persistence (see module comment).
            .unwrap_key => null,
        };
        if (bit) |b| op |= @as(u8, 1) << @truncate(b);
    }
    return op;
}

fn operationByteToActions(allocator: std.mem.Allocator, op: u8) ![]policy_catalog.Action {
    // Zig 0.16: ArrayList is unmanaged — pass allocator per-operation.
    var list: std.ArrayList(policy_catalog.Action) = .{ .items = &.{}, .capacity = 0 };
    errdefer list.deinit(allocator);

    // All actions that have a bit slot in the u8 operation byte.
    const all_actions = [_]policy_catalog.Action{ .read, .write, .match_, .create, .update, .delete, .schema, .decrypt_field };
    for (all_actions, 0..) |a, i| {
        const bit: u3 = @truncate(i);
        if ((op >> bit) & 1 == 1) try list.append(allocator, a);
    }
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=PersistPolicy; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
/// Write a PolicySpec to the __geode_security graph via AuthGraphManager and
/// seal the HMAC chain.  Idempotent: if a policy with the same name already
/// exists the call returns without mutation.
pub fn persistPolicy(
    agm: *AuthGraphManager,
    hmac_key: *const [32]u8,
    spec: PolicySpec,
) !void {
    const op = actionsToOperationByte(spec.actions);
    const permissive = spec.effect == .allow;
    // Only store the filter expression if it is not the trivial "true" sentinel.
    const using: ?[]const u8 = if (std.mem.eql(u8, spec.expression_source, "true"))
        null
    else
        spec.expression_source;

    _ = try agm.createPolicy(
        hmac_key,
        spec.name,
        spec.scope_graph,
        op,
        permissive,
        using,
        spec.enabled,
    );
}

// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropPolicy; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
/// Remove a policy by name from the security graph and reseal the chain.
/// Propagates error.PolicyNotFound if no matching policy exists.
pub fn dropPolicy(
    agm: *AuthGraphManager,
    hmac_key: *const [32]u8,
    name: []const u8,
) !void {
    try agm.dropPolicy(hmac_key, name);
}

// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=AlterPolicy; STATUS=TESTED; TEST=tests/test_gap0858_alter_policy_persist.zig; OWNER=security; UPDATED=2026-06-09
/// GAP-0858: durable ALTER POLICY write-through. Applies an enable/disable
/// toggle and/or rename to the persisted policy located by its CURRENT name,
/// then reseals the HMAC chain. The mutation is an in-place update of the
/// existing :Policy node, so no stale record survives a rename.
/// Propagates error.PolicyNotFound if no matching policy exists.
pub fn alterPolicy(
    agm: *AuthGraphManager,
    hmac_key: *const [32]u8,
    name: []const u8,
    set_enabled: ?bool,
    rename_to: ?[]const u8,
) !void {
    try agm.alterPolicy(hmac_key, name, set_enabled, rename_to);
}

// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=HydrateCatalog; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
/// Load all :Policy nodes from the __geode_security graph into `cat`.
///
/// Called once at server startup, after the PolicyCatalog is initialized and
/// the AuthGraphManager is wired.  Policies found in the security graph are
/// appended to the catalog; any existing in-memory entries are NOT cleared
/// first (callers that want a clean slate must deinit+reinit the catalog).
pub fn hydrateCatalog(
    allocator: std.mem.Allocator,
    agm: *AuthGraphManager,
    cat: *PolicyCatalog,
) !void {
    var it = agm.storage.policyIterator();
    while (it.next()) |record| {
        // Reconstruct actions slice from the packed operation byte.
        const actions = try operationByteToActions(allocator, record.operation);
        defer allocator.free(actions);

        const effect: policy_catalog.Effect = if (record.permissive) .allow else .deny;
        // Reconstruct expression_source: use the stored using_clause if present,
        // otherwise fall back to the trivial "true" sentinel.
        const expr_src: []const u8 = record.getUsingClause() orelse "true";

        // GAP-0923: hydration is tolerant of records persisted BEFORE the
        // uniqueness / malformed-expression validation landed — skip and log a
        // duplicate or an uncompilable expression rather than aborting startup.
        // CANARY: REQ=REQ-RLS-POLICY-COMPILE-ERROR-AT-DDL; FEATURE="GPS Policy Persistence"; ASPECT=HydrationTolerance; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-08-25
        // RLS-POLICY-DDL: DDL now REFUSES an uncompilable USING expression
        // (addPolicyStrict), but hydration deliberately keeps the tolerant
        // `addPolicy` — a record written before a grammar change must not brick
        // startup. PolicyCatalog logs the retained-fail-closed warning; the
        // policy is kept with compiled=null and can never grant access.
        cat.addPolicy(.{
            .name = record.getName(),
            .scope_graph = record.getGraph(),
            .actions = actions,
            .effect = effect,
            .expression_source = expr_src,
            .enabled = record.enabled,
        }) catch |err| switch (err) {
            // GAP-0923: tolerate a duplicate persisted BEFORE the uniqueness
            // check landed (older __geode_security data could hold two rows
            // with the same policy name) — skip and log rather than aborting
            // startup hydration.
            error.PolicyAlreadyExists => {
                std.log.scoped(.gps).warn("skipping duplicate persisted policy '{s}' during hydration", .{record.getName()});
            },
            else => return err,
        };
    }
}
