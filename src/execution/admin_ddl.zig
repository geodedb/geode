//! Geode extension: execution of auth DDL statements (CREATE/ALTER/DROP USER,
//! CREATE/DROP ROLE, GRANT/REVOKE) plus SHOW USERS/ROLES/PERMISSIONS/VERSION/
//! CAPABILITIES. Each DDL variant maps onto an existing geode.auth.* procedure
//! handler via auth_dispatch.callAuthProcedure, inheriting authorization,
//! audit, password policy, and __geode_security persistence. SHOW VERSION and
//! SHOW CAPABILITIES build their results locally (no auth handler exists).
// CANARY: REQ=REQ-GQL-AUTH-DDL-001; FEATURE="GQL Auth DDL"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=parser; UPDATED=2026-05-11

const std = @import("std");
const ast = @import("../gql/ast.zig");
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const auth_dispatch = @import("auth_dispatch.zig");
// A7 (2026-05-26): cluster module is read-only here — `getGlobalClusterCoordinator`
// returns a `?*ClusterCoordinator` set by `cluster_bootstrap.maybeStart` after
// the coordinator finishes initializing.  Null in standalone mode (no
// GEODE_CLUSTER_TOKEN), in which case `executeShowClusterStatus` returns a
// single synthetic row instead of failing.
const cluster_mod = @import("../distributed/cluster.zig");

// Step 1 finding: execution.zig does NOT re-export Value; it imports from value_types.zig
// using a module-local `const Value = value_types.Value`. We must import directly.
const value_types = @import("../value_types.zig");
const Value = value_types.Value;

// Step 1 finding: build_options IS wired into root_mod (build.zig:543) which includes
// all execution submodules. The fallback in src/build_options.zig is "dev"; at build time
// addOption("version", ...) injects the real value from build.zig.zon ("0.1.4").
const build_options = @import("build_options");

fn emptyResult(allocator: std.mem.Allocator) !ExecutionResult {
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn oneRowResult(
    allocator: std.mem.Allocator,
    column: []const u8,
    value_str: []const u8,
) !ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, column);
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try allocator.dupe(u8, value_str) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ---------- DDL: user/role/grant/revoke ----------

pub fn executeCreateUser(allocator: std.mem.Allocator, s: ast.CreateUserStatement, ctx: ExecutionContext) !ExecutionResult {
    // Cluster fail-closed: auth state persists to the per-node __geode_security
    // graph with no Raft slice — an ungated CREATE USER exists on ONE node only
    // (security-relevant divergence). Same gate on every mutating handler below;
    // auth_dispatch.execute() gates the direct CALL geode.auth.* route too
    // (the DDL route double-fires there — identical error, harmless).
    // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateAuthDDL; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
    try cluster_mod.gateUnreplicatedWrite();
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_create", &.{
        s.name,
        s.password,
        s.email orelse "",
        // "user" (lowercase) is what user_mgmt.Role.fromString accepts for the default role.
        s.role orelse "user",
    });
}

pub fn executeAlterUser(allocator: std.mem.Allocator, s: ast.AlterUserStatement, ctx: ExecutionContext) !ExecutionResult {
    try cluster_mod.gateUnreplicatedWrite(); // cluster fail-closed (see executeCreateUser)
    return switch (s.action) {
        .set_password => |pw| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_reset_password", &.{ s.name, pw }),
        .set_role => |r| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_assign_role", &.{ s.name, r }),
        // #832: ALTER USER ... SET ATTRIBUTE <k> = <v> routes to a new procedure
        // that writes into the per-user attribute store consumed by ABAC.
        .set_attribute => |kv| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_set_attribute", &.{ s.name, kv.key, kv.value }),
        .remove_attribute => |k| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_remove_attribute", &.{ s.name, k }),
        .enable => auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_enable", &.{s.name}),
        .disable => auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_disable", &.{s.name}),
    };
}

pub fn executeDropUser(allocator: std.mem.Allocator, s: ast.DropUserStatement, ctx: ExecutionContext) !ExecutionResult {
    // handleUserDelete answers status="deleted <name>" for a user that does
    // not exist, so IF EXISTS changes nothing: DROP USER IF EXISTS on a
    // missing user returns status="deleted <name>". The one error it
    // propagates is a delete that could not be saved (SONNY-3038,
    // UserNotPersisted, 58030), with or without IF EXISTS.
    _ = s.if_exists;
    try cluster_mod.gateUnreplicatedWrite(); // cluster fail-closed (see executeCreateUser)
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_delete", &.{s.name});
}

pub fn executeCreateRole(allocator: std.mem.Allocator, s: ast.CreateRoleStatement, ctx: ExecutionContext) !ExecutionResult {
    try cluster_mod.gateUnreplicatedWrite(); // cluster fail-closed (see executeCreateUser)
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.role_create", &.{
        s.name,
        s.description orelse "",
    });
}

pub fn executeDropRole(allocator: std.mem.Allocator, s: ast.DropRoleStatement, ctx: ExecutionContext) !ExecutionResult {
    // handleRoleDelete answers status="deleted <name>" for a missing role
    // (fetchRemove is a no-op), so IF EXISTS changes nothing. It propagates a
    // removal that could not be saved (SONNY-3038, RoleNotPersisted, 58030).
    _ = s.if_exists;
    try cluster_mod.gateUnreplicatedWrite(); // cluster fail-closed (see executeCreateUser)
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.role_delete", &.{s.name});
}

pub fn executeGrant(allocator: std.mem.Allocator, s: ast.GrantStatement, ctx: ExecutionContext) !ExecutionResult {
    try cluster_mod.gateUnreplicatedWrite(); // cluster fail-closed (see executeCreateUser)
    return switch (s.subject) {
        .role => |role_name| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_assign_role", &.{ s.grantee, role_name }),
        .privilege => |p| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.grant", &.{
            ast.grantPrivilegeName(p),
            s.grantee,
            s.on_graph orelse "",
        }),
    };
}

pub fn executeRevoke(allocator: std.mem.Allocator, s: ast.RevokeStatement, ctx: ExecutionContext) !ExecutionResult {
    try cluster_mod.gateUnreplicatedWrite(); // cluster fail-closed (see executeCreateUser)
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.revoke", &.{
        ast.grantPrivilegeName(s.privilege),
        s.grantee,
        s.on_graph orelse "",
    });
}

// ---------- SHOW ----------

pub fn executeShowUsers(allocator: std.mem.Allocator, ctx: ExecutionContext) !ExecutionResult {
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_list", &.{});
}

pub fn executeShowRoles(allocator: std.mem.Allocator, ctx: ExecutionContext) !ExecutionResult {
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.role_list", &.{});
}

pub fn executeShowPermissions(allocator: std.mem.Allocator, target: ?[]const u8, ctx: ExecutionContext) !ExecutionResult {
    // When target is null and ctx.user is null, we pass "" which causes user_permissions
    // to fall through to Permission.fromRole(.User) — the default-User fallback in
    // handleUserPermissions. This is acceptable: a query with no auth context sees the
    // minimum permission set, not an error.
    const username = target orelse (ctx.user orelse "");
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_permissions", &.{username});
}

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ShowGrantsColumns; STATUS=TESTED; TEST=tests/test_gps_show_grants_for.zig; OWNER=security; UPDATED=2026-05-21
// CANARY: REQ=REQ-SONNY-1333-SHOW-GRANTS; FEATURE="GQL Auth DDL"; ASPECT=ShowGrants; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
/// SHOW GRANTS [ FOR <username> ]: columns policy_name, graph, actions,
/// effect, enabled. First the GPS policies that apply to the user, then
/// (SONNY-1333) one row per graph the user holds per-graph grants on (GRANT
/// ... ON GRAPH), as stored in __geode_security, with a null policy_name and
/// the granted privileges in `actions`. Without FOR, the current user. The
/// grants come from `geode.auth.grant_list`, which carries the authorization:
/// a user may list its own; another user's need the Admin role.
pub fn executeShowGrants(allocator: std.mem.Allocator, target: ?[]const u8, ctx: ExecutionContext) !ExecutionResult {
    const user_name = target orelse (ctx.user orelse "");
    var grants = try auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.grant_list", &.{user_name});
    defer grants.deinit(allocator);

    const column_list = [_][]const u8{ "policy_name", "graph", "actions", "effect", "enabled" };
    const columns = try allocator.alloc([]const u8, column_list.len);
    for (column_list, 0..) |col, i| columns[i] = try allocator.dupe(u8, col);
    var rows_list = std.ArrayList([]Value).empty;

    // CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ShowGrantsRows; STATUS=TESTED; TEST=tests/test_gps_show_grants_for.zig; OWNER=security; UPDATED=2026-05-21
    // Policies applicable to the user: (a) expression_source == "true"
    // (universally applicable), or (b) expression_source containing the
    // literal "current_user() = '<username>'" (a text match).
    const policy_catalog_mod = @import("../security/policy_catalog.zig");
    if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
        const user_expr = try std.fmt.allocPrint(allocator, "current_user() = '{s}'", .{user_name});
        defer allocator.free(user_expr);
        // SONNY-2756: copied under a shared hold of the catalog.
        const view = pol_cat.acquireRead();
        defer view.release();
        for (view.policies()) |pol| {
            const is_universal = std.mem.eql(u8, pol.expression_source, "true");
            const is_user_specific = std.mem.indexOf(u8, pol.expression_source, user_expr) != null;
            if (!is_universal and !is_user_specific) continue;

            var actions_buf = std.ArrayList(u8).empty;
            for (pol.actions, 0..) |a, ai| {
                if (ai > 0) try actions_buf.appendSlice(allocator, ", ");
                try actions_buf.appendSlice(allocator, @tagName(a));
            }
            const row = try allocator.alloc(Value, 5);
            row[0] = Value{ .Str = try allocator.dupe(u8, pol.name) };
            row[1] = Value{ .Str = try allocator.dupe(u8, pol.scope_graph) };
            row[2] = Value{ .Str = try actions_buf.toOwnedSlice(allocator) };
            row[3] = Value{ .Str = try allocator.dupe(u8, @tagName(pol.effect)) };
            row[4] = Value{ .Bool = pol.enabled };
            try rows_list.append(allocator, row);
        }
    }

    // The per-graph grants: grant_list rows are (username, graph, action),
    // by graph then action; one row per graph.
    var i: usize = 0;
    while (i < grants.rows.len) {
        const graph = grants.rows[i][1].Str;
        var actions_buf = std.ArrayList(u8).empty;
        while (i < grants.rows.len and std.mem.eql(u8, grants.rows[i][1].Str, graph)) : (i += 1) {
            if (actions_buf.items.len > 0) try actions_buf.appendSlice(allocator, ", ");
            try actions_buf.appendSlice(allocator, grants.rows[i][2].Str);
        }
        const row = try allocator.alloc(Value, 5);
        row[0] = .Null;
        row[1] = Value{ .Str = try allocator.dupe(u8, graph) };
        row[2] = Value{ .Str = try actions_buf.toOwnedSlice(allocator) };
        row[3] = Value{ .Str = try allocator.dupe(u8, "allow") };
        row[4] = Value{ .Bool = true };
        try rows_list.append(allocator, row);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try rows_list.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
}

pub fn executeShowVersion(allocator: std.mem.Allocator) !ExecutionResult {
    // build_options.version is injected by build.zig addOption("version", ...) at build time.
    // In debug/dev builds where the option is not overridden, the fallback from
    // src/build_options.zig is "dev".
    return oneRowResult(allocator, "version", build_options.version);
}

// CANARY: REQ=REQ-CAPABILITY-DISCOVERY-001; FEATURE="SHOW CAPABILITIES"; ASPECT=DiscoveryRows; STATUS=TESTED; TEST=tests/test_show_capabilities.zig; OWNER=execution; UPDATED=2026-08-28
pub fn executeShowCapabilities(allocator: std.mem.Allocator) !ExecutionResult {
    // Two string columns: feature, supported. The wire label is retained for
    // compatibility; sonny_profile_version is typed metadata rather than a
    // boolean. This is a static truthful snapshot for the current release.
    // The geode-ui consumes this for admin_writable feature detection; every
    // legacy row name below MUST keep its name and only become more truthful.
    const CapabilityValue = union(enum) {
        boolean: bool,
        profile_version: void,

        fn wireValue(self: @This()) []const u8 {
            return switch (self) {
                .boolean => |supported| if (supported) "true" else "false",
                .profile_version => "1",
            };
        }
    };
    const Feature = struct { name: []const u8, value: CapabilityValue };
    const features = [_]Feature{
        // --- legacy rows (Geode Auth DDL, GAP-0858 admin surface) ---
        .{ .name = "auth_ddl", .value = .{ .boolean = true } },
        .{ .name = "admin_writable", .value = .{ .boolean = true } },
        .{ .name = "role_ddl", .value = .{ .boolean = true } },
        .{ .name = "grant_ddl", .value = .{ .boolean = true } },
        .{ .name = "show_permissions", .value = .{ .boolean = true } },
        .{ .name = "show_version", .value = .{ .boolean = true } },
        // GAP-0858 (2026-06-xx): durable GPS policy DDL persistence landed —
        // CREATE/ALTER/DROP POLICY (incl. RENAME TO) write through to
        // __geode_security and survive restart. The residual is the manual
        // GQL->bytecode expression-compilation path (see CLAUDE.md Known
        // Limitations), not policy DDL persistence itself, so this flips true.
        .{ .name = "policy_ddl", .value = .{ .boolean = true } },
        .{ .name = "fle_ddl", .value = .{ .boolean = false } },
        .{ .name = "tenant_ddl", .value = .{ .boolean = false } },
        // --- discovery rows added for hybrid-RAG capability discovery
        // (Task 7): every feature below landed in Tasks 1-6 of that plan. ---
        .{ .name = "vector_knn", .value = .{ .boolean = true } },
        .{ .name = "vector_index_metrics", .value = .{ .boolean = true } },
        .{ .name = "knn_metric_validation", .value = .{ .boolean = true } },
        .{ .name = "fts_search", .value = .{ .boolean = true } },
        .{ .name = "fts_phrase_proximity", .value = .{ .boolean = true } },
        .{ .name = "fts_rebuild", .value = .{ .boolean = true } },
        .{ .name = "fts_bulk_merge_live_maintenance", .value = .{ .boolean = true } },
        .{ .name = "fts_row_visibility", .value = .{ .boolean = true } },
        .{ .name = "ts_procedures", .value = .{ .boolean = true } },
        .{ .name = "read_only_execute", .value = .{ .boolean = true } },
        .{ .name = "mcp_read_only", .value = .{ .boolean = true } },
        .{ .name = "explain", .value = .{ .boolean = true } },
        .{ .name = "profile", .value = .{ .boolean = true } },
        .{ .name = "explain_policy", .value = .{ .boolean = true } },
        // GEO-UP-001 (ENG-4653): Sonny GraphRAG capability profile rows.
        // CANARY: REQ=REQ-SONNY-CAPABILITY-PROFILE-001; FEATURE="SonnyCapabilityProfile"; ASPECT=DiscoveryRows; STATUS=TESTED; TEST=tests/test_sonny_capability_profile.zig; OWNER=execution; UPDATED=2026-09-08
        .{ .name = "sonny_profile_version", .value = .{ .profile_version = {} } },
        // SONNY-2751: a read-only request refuses the security DDL (users,
        // roles, grants, policies, a password change) and every procedure not
        // on the read-only list (tenant, FLE, TDE, CDC mutators), as it
        // refuses data and schema changes.
        .{ .name = "read_only_covers_admin_ddl", .value = .{ .boolean = true } },
        .{ .name = "strict_tenancy_production_default", .value = .{ .boolean = false } },
        .{ .name = "tenant_scope_fail_closed", .value = .{ .boolean = false } },
        .{ .name = "tenant_binding_server_verified", .value = .{ .boolean = false } },
        .{ .name = "fts_strict_tenancy", .value = .{ .boolean = false } },
        .{ .name = "fts_multi_graph", .value = .{ .boolean = false } },
        .{ .name = "knn_row_visibility", .value = .{ .boolean = false } },
        .{ .name = "knn_delete_liveness", .value = .{ .boolean = false } },
        .{ .name = "knn_filtered_ann_pushdown", .value = .{ .boolean = false } },
        // SONNY-1326 (GEO-UP-005): flipped to `true` once the EXPRESSION path
        // (`graph_algorithms.zig`: shortestPath(), COUNT{}, EXISTS{}, pattern
        // comprehensions) joined `CALL algo.*` (SONNY-1318), MATCH (GAP-0279 /
        // 0509 / 0846 / 0891) and LSP schema introspection (SONNY-1318) in
        // applying the shared, hierarchy-aware, fail-closed tenant predicate
        // from `tenant_visibility.zig`.
        // Evidence: `zig build test-sonny1326-expression-tenancy` +
        // `test-sonny1318-procedure-tenancy`.
        .{ .name = "graph_procedure_tenancy", .value = .{ .boolean = true } },
        .{ .name = "embedding_space_pinning", .value = .{ .boolean = false } },
        .{ .name = "vector_index_generations", .value = .{ .boolean = false } },
        .{ .name = "vector_generation_rollback", .value = .{ .boolean = false } },
        .{ .name = "vector_build_bounded", .value = .{ .boolean = false } },
        .{ .name = "vector_index_restart_rebuild", .value = .{ .boolean = false } },
        .{ .name = "bulk_vector_index_maintenance", .value = .{ .boolean = false } },
        .{ .name = "bulk_create_fts_maintenance", .value = .{ .boolean = false } },
        .{ .name = "bulk_delete_batch", .value = .{ .boolean = false } },
        .{ .name = "index_build_telemetry", .value = .{ .boolean = false } },
        .{ .name = "retrieval_ready", .value = .{ .boolean = false } },
        .{ .name = "traversal_multi_edge_type", .value = .{ .boolean = false } },
        .{ .name = "traversal_bounded_nodes_cost_time", .value = .{ .boolean = false } },
        .{ .name = "traversal_cycle_hub_control", .value = .{ .boolean = false } },
        .{ .name = "traversal_cancellation", .value = .{ .boolean = false } },
        .{ .name = "traversal_deterministic_ties", .value = .{ .boolean = false } },
        .{ .name = "traversal_path_provenance", .value = .{ .boolean = false } },
        .{ .name = "weighted_path_raw_property", .value = .{ .boolean = false } },
        .{ .name = "temporal_traversal_predicates", .value = .{ .boolean = false } },
        .{ .name = "cdc_ordered_resumable", .value = .{ .boolean = false } },
        .{ .name = "cdc_tenant_bound", .value = .{ .boolean = false } },
        .{ .name = "cdc_backpressure_dlq_observable", .value = .{ .boolean = false } },
        .{ .name = "federation_authorization_preserved", .value = .{ .boolean = false } },
        .{ .name = "federation_deterministic_topk", .value = .{ .boolean = false } },
        .{ .name = "federation_partial_shard_errors", .value = .{ .boolean = false } },
        .{ .name = "graph_community_summary_layer", .value = .{ .boolean = false } },
    };
    const columns = try allocator.alloc([]const u8, 2);
    var initialized_columns: usize = 0;
    errdefer {
        for (columns[0..initialized_columns]) |column| allocator.free(column);
        allocator.free(columns);
    }
    columns[0] = try allocator.dupe(u8, "feature");
    initialized_columns += 1;
    columns[1] = try allocator.dupe(u8, "supported");
    initialized_columns += 1;

    const rows = try allocator.alloc([]Value, features.len);
    var initialized_rows: usize = 0;
    errdefer {
        for (rows[0..initialized_rows]) |row| {
            for (row) |value| execution.freeValue(allocator, value);
            allocator.free(row);
        }
        allocator.free(rows);
    }
    for (features, 0..) |f, i| {
        const row = try allocator.alloc(Value, 2);
        var initialized_values: usize = 0;
        errdefer {
            for (row[0..initialized_values]) |value| execution.freeValue(allocator, value);
            allocator.free(row);
        }
        row[0] = Value{ .Str = try allocator.dupe(u8, f.name) };
        initialized_values += 1;
        row[1] = Value{ .Str = try allocator.dupe(u8, f.value.wireValue()) };
        initialized_values += 1;
        rows[i] = row;
        initialized_rows += 1;
    }
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        // Row values are heap-duped strings (allocator.dupe above) — without
        // this flag ExecutionResult.deinit skips freeValue on each row and
        // every feature/value string leaks. The legacy ownership regression
        // and the profile's exhaustive allocation-failure sweep both drive
        // the real builder under std.testing.allocator.
        .owns_value_memory = true,
    };
}

// CANARY: REQ=REQ-DIST-SHOW-CLUSTER-STATUS; FEATURE="SHOW CLUSTER STATUS"; ASPECT=ExecuteHandler; STATUS=TESTED; TEST=tests/test_show_cluster_status.zig; OWNER=distributed; UPDATED=2026-05-26
//
// SHOW CLUSTER STATUS handler.  Returns one row per cluster member with
// columns (node_id, role, term, leader_id, endpoint, last_contact_ms).
//
// In standalone mode (no ClusterCoordinator wired via
// `cluster.setGlobalClusterCoordinator` during boot), returns exactly one
// synthetic row representing this process:
//
//   node_id=0, role=standalone, term=0, leader_id=0, endpoint=0.0.0.0:0,
//   last_contact_ms=0
//
// This shape is what the harness B2 readiness probe and operator
// diagnostics consume; row count of zero would force every caller to
// special-case "is the coordinator wired?" so we always return at least
// one row.
pub fn executeShowClusterStatus(allocator: std.mem.Allocator, ctx: ExecutionContext) !ExecutionResult {
    _ = ctx; // unused — SHOW CLUSTER STATUS does not gate on principal /
    // session yet (parity with SHOW VERSION / SHOW CAPABILITIES).

    // Column schema is fixed regardless of standalone-vs-cluster.
    const column_names = [_][]const u8{ "node_id", "role", "term", "leader_id", "endpoint", "last_contact_ms" };
    var columns = try allocator.alloc([]const u8, column_names.len);
    for (column_names, 0..) |c, i| columns[i] = try allocator.dupe(u8, c);

    const maybe_coord = cluster_mod.getGlobalClusterCoordinator();
    if (maybe_coord == null) {
        // Standalone mode — single synthetic row.  Every Str value here is
        // freshly allocated via `dupe`, so we set `owns_value_memory=true`
        // so `ExecutionResult.deinit` walks each row and frees the string
        // backing storage instead of leaking it.
        const rows = try allocator.alloc([]Value, 1);
        rows[0] = try allocator.alloc(Value, column_names.len);
        rows[0][0] = Value{ .Int = 0 };
        rows[0][1] = Value{ .Str = try allocator.dupe(u8, "standalone") };
        rows[0][2] = Value{ .Int = 0 };
        rows[0][3] = Value{ .Int = 0 };
        rows[0][4] = Value{ .Str = try allocator.dupe(u8, "0.0.0.0:0") };
        rows[0][5] = Value{ .Int = 0 };
        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
            .owns_value_memory = true,
        };
    }

    const coord = maybe_coord.?;

    // Snapshot the raft mirror state once so the row set is internally
    // consistent.  role()/currentTerm() each grab the inner raft mutex;
    // taking them once minimizes the window where a tick could shift
    // the term mid-row.
    const my_role_state = coord.role();
    const my_term = coord.currentTerm();
    const my_id = coord.node_id;

    // Resolve the leader_id.  We only know it directly if THIS node is the
    // leader; otherwise the inner raft library tracks the leader id learned
    // from AppendEntries (followers) or self-promotion (candidates that won).
    // `coord.cluster_state.leader_node` is a separate mirror updated by
    // membership messages; fall back to it before reporting 0. `0` means
    // "no leader observed yet" (election in flight, fresh cluster, partition).
    const leader_id: u64 = blk: {
        if (my_role_state == .leader) break :blk my_id;
        if (coord.raft.leaderId()) |id| break :blk id;
        if (coord.cluster_state.leader_node) |id| break :blk id;
        break :blk 0;
    };

    const now_ms = compat_milliTimestamp();

    // Emit one row for this node, plus one per peer in coord.raft.peers.
    // raft.peers is the authoritative cluster membership populated from
    // PeerConfig at init time (resolvePeers in cluster.zig). The previous
    // implementation read cluster_state.nodes, which is mutated at runtime
    // by handleJoinCluster and was observed empty in subprocess runs even
    // though raft.peers was populated correctly. Using raft.peers guarantees
    // SHOW CLUSTER STATUS reflects the configured membership immediately.
    // Self is intentionally NOT in that list so we emit it explicitly.
    const peer_count = coord.raft.peers.len;
    const total_rows = peer_count + 1;

    var rows = try allocator.alloc([]Value, total_rows);
    errdefer allocator.free(rows);

    // Row 0: self.
    rows[0] = try allocator.alloc(Value, column_names.len);
    rows[0][0] = Value{ .Int = @intCast(my_id) };
    rows[0][1] = Value{ .Str = try allocator.dupe(u8, roleName(my_role_state)) };
    rows[0][2] = Value{ .Int = @intCast(my_term) };
    rows[0][3] = Value{ .Int = @intCast(leader_id) };
    // Self-endpoint: synthesize from `listen_address:cluster_port` rather
    // than chasing the network_transport's bound address; the coordinator
    // already mirrors these into top-level fields exactly for this kind of
    // operator-facing readout.
    const self_endpoint = try std.fmt.allocPrint(
        allocator,
        "{s}:{d}",
        .{ coord.listen_address, coord.cluster_port },
    );
    rows[0][4] = Value{ .Str = self_endpoint };
    // last_contact_ms for self is always 0 — we're talking to ourselves.
    rows[0][5] = Value{ .Int = 0 };

    // Rows 1..N: peers as recorded in coord.raft.peers.
    for (coord.raft.peers, 0..) |peer, i| {
        const row = try allocator.alloc(Value, column_names.len);
        row[0] = Value{ .Int = @intCast(peer.id) };

        // Peer role classification: if this peer matches the observed
        // leader_id and we have a non-zero leader, it's the leader;
        // otherwise we report `follower` as the default. Tests assert
        // "exactly one role=leader" — they should not depend on
        // follower-vs-candidate distinction for peers.
        const peer_role_str = if (leader_id != 0 and peer.id == leader_id)
            "leader"
        else
            "follower";
        row[1] = Value{ .Str = try allocator.dupe(u8, peer_role_str) };

        // We do not track per-peer term; report our term as a best-effort
        // approximation (followers converge to leader term on first
        // append-entries).
        row[2] = Value{ .Int = @intCast(my_term) };
        row[3] = Value{ .Int = @intCast(leader_id) };

        // Endpoint comes from raft.peers as "host:port".
        const peer_endpoint = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ peer.endpoint, peer.port });
        row[4] = Value{ .Str = peer_endpoint };

        // last_contact_ms = now - last_contact (raft.peers tracks this
        // separately from cluster_state).
        const delta_ms: i64 = if (peer.last_contact == 0) 0 else now_ms - peer.last_contact;
        row[5] = Value{ .Int = @max(@as(i64, 0), delta_ms) };
        rows[i + 1] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        // All Str values in every row were freshly dupe()'d or allocPrint()'d
        // above; flag this so ExecutionResult.deinit walks each row and frees
        // the backing strings.
        .owns_value_memory = true,
    };
}

/// Map raft_consensus.State enum to operator-facing strings.  Matches the
/// vocabulary the harness B2 probe expects (leader / follower / candidate /
/// shutdown).  Standalone is NEVER produced here — only the no-coordinator
/// branch of `executeShowClusterStatus` emits that token.
fn roleName(state: anytype) []const u8 {
    return switch (state) {
        .leader => "leader",
        .follower => "follower",
        .candidate => "candidate",
        .shutdown => "shutdown",
    };
}

/// Zig 0.16 compat: std.time.milliTimestamp was removed.  Mirror the helper
/// used by src/distributed/cluster.zig (intentionally not exported across
/// modules — the function is small enough to duplicate without creating
/// import noise).
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
