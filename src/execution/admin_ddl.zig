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
    // Step 1 finding: handleUserDelete in auth_dispatch.zig swallows all errors internally
    // (logs via log.warn then continues) and always returns a result row with status="deleted <name>".
    // It never propagates a Zig error. Therefore IF EXISTS is structurally a no-op at the Zig
    // error level — there is no error to catch. We pass through the result in both cases.
    // This means DROP USER IF EXISTS on a non-existent user still returns status="deleted <name>",
    // which is safe and idempotent — the handler already degrades gracefully.
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
    // Step 1 finding: handleRoleDelete also never propagates a Zig error — it uses
    // fetchRemove (which is a no-op on missing keys) and always returns status="deleted <name>".
    // IF EXISTS is structurally a no-op; pass through.
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

pub fn executeShowVersion(allocator: std.mem.Allocator) !ExecutionResult {
    // build_options.version is injected by build.zig addOption("version", ...) at build time.
    // In debug/dev builds where the option is not overridden, the fallback from
    // src/build_options.zig is "dev".
    return oneRowResult(allocator, "version", build_options.version);
}

// CANARY: REQ=REQ-CAPABILITY-DISCOVERY-001; FEATURE="SHOW CAPABILITIES"; ASPECT=DiscoveryRows; STATUS=TESTED; TEST=tests/test_show_capabilities.zig; OWNER=execution; UPDATED=2026-08-28
pub fn executeShowCapabilities(allocator: std.mem.Allocator) !ExecutionResult {
    // Two columns: feature, supported. Static truthful snapshot for the
    // current release — this surface's documented design is a fixed list
    // reflecting what has actually landed, not a live introspection query.
    // The geode-ui consumes this for admin_writable feature detection; every
    // legacy row name below MUST keep its name and only become more truthful.
    const Feature = struct { name: []const u8, supported: bool };
    const features = [_]Feature{
        // --- legacy rows (Geode Auth DDL, GAP-0858 admin surface) ---
        .{ .name = "auth_ddl", .supported = true },
        .{ .name = "admin_writable", .supported = true },
        .{ .name = "role_ddl", .supported = true },
        .{ .name = "grant_ddl", .supported = true },
        .{ .name = "show_permissions", .supported = true },
        .{ .name = "show_version", .supported = true },
        // GAP-0858 (2026-06-xx): durable GPS policy DDL persistence landed —
        // CREATE/ALTER/DROP POLICY (incl. RENAME TO) write through to
        // __geode_security and survive restart. The residual is the manual
        // GQL->bytecode expression-compilation path (see CLAUDE.md Known
        // Limitations), not policy DDL persistence itself, so this flips true.
        .{ .name = "policy_ddl", .supported = true },
        .{ .name = "fle_ddl", .supported = false },
        .{ .name = "tenant_ddl", .supported = false },
        // --- discovery rows added for hybrid-RAG capability discovery
        // (Task 7): every feature below landed in Tasks 1-6 of that plan. ---
        .{ .name = "vector_knn", .supported = true },
        .{ .name = "vector_index_metrics", .supported = true },
        .{ .name = "knn_metric_validation", .supported = true },
        .{ .name = "fts_search", .supported = true },
        .{ .name = "fts_phrase_proximity", .supported = true },
        .{ .name = "fts_rebuild", .supported = true },
        .{ .name = "fts_bulk_merge_live_maintenance", .supported = true },
        .{ .name = "fts_row_visibility", .supported = true },
        .{ .name = "ts_procedures", .supported = true },
        .{ .name = "read_only_execute", .supported = true },
        .{ .name = "mcp_read_only", .supported = true },
        .{ .name = "explain", .supported = true },
        .{ .name = "profile", .supported = true },
        .{ .name = "explain_policy", .supported = true },
    };
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "feature");
    columns[1] = try allocator.dupe(u8, "supported");
    const rows = try allocator.alloc([]Value, features.len);
    for (features, 0..) |f, i| {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, f.name) };
        row[1] = Value{ .Str = try allocator.dupe(u8, if (f.supported) "true" else "false") };
        rows[i] = row;
    }
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        // Row values are heap-duped strings (allocator.dupe above) — without
        // this flag ExecutionResult.deinit skips freeValue on each row and
        // every feature/supported string leaks. Pre-existing bug, surfaced
        // now because this row set grew from 9 to 23 (Task 7) and
        // tests/test_show_capabilities.zig drives the real dispatch under
        // std.testing.allocator's strict leak checking.
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
