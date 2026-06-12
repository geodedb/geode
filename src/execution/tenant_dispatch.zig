/// Tenant Lifecycle Dispatch Module (GAP-0839)
///
/// Handles routing for the `geode.tenant.*` procedure family — the native GQL
/// surface for tenant provisioning / lifecycle. This is the direct analog of
/// `ts_dispatch.zig` (`geode.ts.*`) and `fts_dispatch.zig` (`geode.fts.*`):
/// row-returning and mutating operations are exposed via the ISO/IEC
/// 39075:2024 `CALL <proc>(args) [YIELD …]` surface, returning ordinary
/// `ExecutionResult{ columns, rows }` tables that flow over the same in-process
/// / QUIC / gRPC result encoder as every other procedure — no client or
/// transport change, no grammar change (runtime dotted-name dispatch).
///
/// Before this family, a tenant only "existed" implicitly by data being tagged
/// with its `tenant_id`. There was NO create/list/show/drop lifecycle, no
/// production seam to populate the GAP-0838 tenant hierarchy, and no production
/// path to configure per-tenant quotas (GAP-0289 `setQuota` was tests-only).
///
/// Procedures:
///   - geode.tenant.create(tenant_id[, parent])   → YIELD tenant_id, parent, created
///   - geode.tenant.list()                         → YIELD tenant_id, parent, active,
///                                                          max_connections, max_concurrent_queries
///   - geode.tenant.show(tenant_id)                → YIELD tenant_id, parent, active,
///                                                          max_connections, max_concurrent_queries
///   - geode.tenant.drop(tenant_id)                → YIELD tenant_id, dropped
///   - geode.tenant.set_quota(tenant_id, max_connections, max_concurrent_queries,
///                            max_graphs, max_nodes_per_graph) → YIELD tenant_id, updated
///
/// Wiring (the load-bearing integrations):
///   - create / create-with-parent registers the tenant in the DURABLE
///     `tenant_registry` (survives restart) AND calls GAP-0838's
///     `HierarchyManager.addTenant(tenant_id, parent)` on the global expr-RLS
///     engine — this is the production population seam GAP-0838 deferred.
///   - set_quota (and create with a later set_quota) calls
///     `tenant_quota.setQuota(...)` on the global quota manager, so per-tenant
///     quotas become configurable in PRODUCTION (closing the tests-only gap).
///
/// Authorization + audit (fail-closed): EVERY procedure in this family — read
/// AND write — is gated on the `admin_tenant` GPS action via `gps.decide()`
/// before any registry mutation or read. Tenant administration is admin-only;
/// an unauthorized caller is rejected with `error.Unauthorized`. This is in
/// ADDITION to the generic procedure gate in procedure_registry (which only
/// maps to .read/.write and would wrongly admit any Write user to a mutating
/// tenant op). The explicit admin_tenant gate here is the real control.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");

const execution = @import("../execution.zig");
const execution_helpers = @import("execution_helpers.zig");
const filterYieldColumns = execution_helpers.filterYieldColumns;
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

const gps = @import("../security/gps.zig");
const principal_mod = @import("../security/principal.zig");
const user_mgmt = @import("../security/user_management.zig");
const tenant_registry = @import("../security/tenant_registry.zig");
const tenant_quota = @import("../security/tenant_quota.zig");
const graph_store = @import("../graph_store.zig");
const cluster_mod = @import("../distributed/cluster.zig");
const rls_core = @import("rls");
const rls_types = @import("rls_types");

const logging = @import("logging");
const log = logging.scoped("tenant_dispatch");
const Attr = logging.Attr;

const Value = value_types.Value;

/// Execute a `geode.tenant.*` procedure. Returns null if the procedure name is
/// not recognized by this dispatcher (the router falls through to
/// UnknownProcedure).
///
/// `proc_name` is the ASCII-lowercased, dotted procedure name (e.g.
/// "geode.tenant.create") produced by `extractNormalizedProcName`.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    // Recognize the family up-front so unknown geode.tenant.* names produce a
    // clear UnknownProcedure (null) AFTER the family is confirmed, not before.
    const is_create = std.mem.eql(u8, proc_name, "geode.tenant.create");
    const is_list = std.mem.eql(u8, proc_name, "geode.tenant.list");
    const is_show = std.mem.eql(u8, proc_name, "geode.tenant.show");
    const is_drop = std.mem.eql(u8, proc_name, "geode.tenant.drop");
    const is_set_quota = std.mem.eql(u8, proc_name, "geode.tenant.set_quota");
    if (!(is_create or is_list or is_show or is_drop or is_set_quota)) return null;

    // ── Authorization gate (fail-closed): admin_tenant on every op. ──────────
    try requireAdminTenant(allocator, context, proc_name);

    // ── Cluster fail-closed gate (mutating ops only) ─────────────────────────
    // The durable tenant_registry + GAP-0838 hierarchy + quota manager are all
    // per-node with no Raft slice — an ungated create/drop/set_quota lands on
    // ONE node and silently diverges. Placed AFTER requireAdminTenant so an
    // unauthorized caller still sees the authz error first; for an authorized
    // caller the gate error name (ClusterNotLeader / ClusterWriteNotReplicable)
    // reaches the wire unmasked. Reads (list/show) stay open.
    // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateTenantOps; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
    if (is_create or is_drop or is_set_quota) try cluster_mod.gateUnreplicatedWrite();

    if (is_create) return try handleCreate(allocator, call_stmt);
    if (is_list) return try handleList(allocator, call_stmt);
    if (is_show) return try handleShow(allocator, call_stmt);
    if (is_drop) return try handleDrop(allocator, call_stmt);
    if (is_set_quota) return try handleSetQuota(allocator, call_stmt);
    unreachable;
}

// ---------------------------------------------------------------------------
// Authorization
// ---------------------------------------------------------------------------

/// Gate tenant administration on the `admin_tenant` GPS action. Mirrors
/// `execution.checkPermission`'s synth-principal + `gps.decide()` pattern but
/// for the admin_tenant action. Fail-closed: a missing principal/role yields
/// Unauthenticated; a non-admin yields Unauthorized.
///
/// When auth is disabled (single-tenant dev / CLI / tests), the operation is
/// permitted — identical posture to checkPermission's auth-disabled short
/// circuit — so the in-process test path and `--insecure-allow-all` continue to
/// work exactly as every other admin op does.
fn requireAdminTenant(
    allocator: std.mem.Allocator,
    context: ExecutionContext,
    proc_name: []const u8,
) !void {
    if (!user_mgmt.isAuthEnabled()) return;

    var synth_principal: principal_mod.Principal = undefined;
    const principal_ptr: *const principal_mod.Principal = if (context.principal) |p| p else blk: {
        if (context.role == null) return error.Unauthenticated;
        const role_name = @tagName(context.role.?);
        synth_principal = principal_mod.Principal{
            .user_id = null,
            .username = context.user,
            .session_id = null,
            .tenant_id = context.tenant_id,
            .active_graph = if (context.session_state) |ss| ss.graph else null,
            .roles = &[_][]const u8{role_name},
            .custom_roles = &.{},
            .auth_method = .password,
            .auth_version = 0,
            .mfa_state = .none,
            .elevation_until = null,
            .api_key_id = null,
            .certificate_subject = null,
            .risk_context = principal_mod.RiskContext.unknown,
            .attributes = principal_mod.AttributeMap.emptySentinel(),
            .source = .unattributed,
        };
        break :blk &synth_principal;
    };

    if (principal_ptr.username == null) return error.Unauthenticated;

    const req = gps.DecisionRequest{
        .principal = principal_ptr,
        .action = .admin_tenant,
        .resource = .{ .database = {} },
    };
    const decision = try gps.decide(allocator, &req);

    // Audit trail: every tenant-admin decision is logged with subject + outcome.
    log.info("tenant_admin.authz", &.{
        Attr.string("procedure", proc_name),
        Attr.string("subject", principal_ptr.username orelse "<none>"),
        Attr.string("decision", @tagName(decision.kind)),
        Attr.string("reason", decision.reason_code),
    });

    switch (decision.kind) {
        .allow => return,
        .unauthenticated => return error.Unauthenticated,
        else => return error.Unauthorized,
    }
}

// ---------------------------------------------------------------------------
// Argument extraction (literal-only, mirrors ts_dispatch's contract)
// ---------------------------------------------------------------------------

fn args(call_stmt: ast.CallProcedure) ![]*ast.Expr {
    return switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => error.InvalidArgs,
    };
}

fn literalString(expr: *const ast.Expr) ![]const u8 {
    return switch (expr.*) {
        .String => |s| s,
        else => error.TypeMismatch,
    };
}

fn literalInt(expr: *const ast.Expr) error{ TypeMismatch, IntegerOverflow }!i64 {
    return switch (expr.*) {
        .Int => |n| n,
        .Unary => |u| switch (u.op) {
            .Neg => blk: {
                const inner = try literalInt(u.expr);
                break :blk std.math.negate(inner) catch return error.IntegerOverflow;
            },
            .Pos => try literalInt(u.expr),
            else => error.TypeMismatch,
        },
        else => error.TypeMismatch,
    };
}

fn literalBool(expr: *const ast.Expr) !bool {
    return switch (expr.*) {
        .Bool => |b| b,
        else => error.TypeMismatch,
    };
}

fn literalU32(expr: *const ast.Expr) !u32 {
    const v = try literalInt(expr);
    if (v < 0 or v > std.math.maxInt(u32)) return error.InvalidArgs;
    return @intCast(v);
}

fn literalU64(expr: *const ast.Expr) !u64 {
    const v = try literalInt(expr);
    if (v < 0) return error.InvalidArgs;
    return @intCast(v);
}

/// Apply an optional YIELD projection. Our result rows hold OWNED values
/// (duped `.Str`, plus scalar `.Bool`/`.Int`/`.Null`), so the base result is
/// built with `owns_value_memory = true` and freed value-by-value by
/// `ExecutionResult.deinit`.
///
/// `filterYieldColumns` (the shared helper) shallow-copies the kept columns but
/// (a) does NOT free the DROPPED columns' values and (b) returns a result with
/// `owns_value_memory = false`. Both would leak our owned `.Str` values, so we
/// free the dropped values here and re-assert ownership on the filtered result.
fn maybeYield(allocator: std.mem.Allocator, result: ExecutionResult, call_stmt: ast.CallProcedure) !ExecutionResult {
    const yield_items = call_stmt.yield_items orelse return result;

    // Which original column indices survive the YIELD (by name, case-sensitive —
    // the dispatcher emits canonical lowercase column names)?
    var keep = try allocator.alloc(bool, result.columns.len);
    defer allocator.free(keep);
    @memset(keep, false);
    for (yield_items) |item| {
        const col_name = item.alias orelse switch (item.expr) {
            .Ident => |ident| ident.orig,
            .Member => |member| member.field,
            else => "column",
        };
        for (result.columns, 0..) |res_col, idx| {
            if (std.mem.eql(u8, col_name, res_col)) {
                keep[idx] = true;
                break;
            }
        }
    }

    // Free the values in dropped columns before filterYieldColumns discards
    // them (it frees the row backing array but never the Values themselves).
    for (result.rows) |row| {
        for (row, 0..) |val, idx| {
            if (!keep[idx]) freeValue(allocator, val);
        }
    }

    var r = try filterYieldColumns(allocator, result, yield_items);
    r.owns_value_memory = true; // kept Str values are still owned by us
    return r;
}

/// Free a single Value's owned heap memory (only `.Str` carries an allocation in
/// our result tables; scalars are no-ops).
fn freeValue(allocator: std.mem.Allocator, val: Value) void {
    switch (val) {
        .Str => |s| allocator.free(s),
        else => {},
    }
}

/// Resolve the durable global tenant registry. A null registry (server started
/// without one wired) is a hard, honest failure rather than a silent no-op.
fn resolveRegistry() !*tenant_registry.TenantRegistry {
    return tenant_registry.getGlobalRegistry() orelse error.Unsupported;
}

/// Best-effort: populate the GAP-0838 production hierarchy from a create. The
/// registry is the source of truth; the hierarchy is an authz-acceleration
/// structure. A duplicate (already-present) tenant in the hierarchy is benign.
fn addToHierarchy(tenant_id: []const u8, parent: ?[]const u8) void {
    const engine_ptr = rls_types.getGlobalExprRLSEngine() orelse return;
    const engine: *rls_core.RLSEngine = @ptrCast(@alignCast(engine_ptr));
    engine.hierarchy_manager.addTenant(tenant_id, parent) catch |err| switch (err) {
        error.TenantAlreadyExists => {}, // already populated — fine
        else => log.warn("tenant_admin.hierarchy_add_failed", &.{
            Attr.string("tenant", tenant_id),
            Attr.string("error", @errorName(err)),
        }),
    };
}

/// Push a quota override into the PRODUCTION quota manager (GAP-0289). No-op if
/// no global quota manager is wired (CLI/test).
fn applyQuotaToManager(
    tenant_id: []const u8,
    max_connections: u32,
    max_concurrent_queries: u32,
    max_graphs: u32,
    max_nodes_per_graph: u64,
) void {
    const qm = tenant_quota.getGlobalQuotaManager() orelse return;
    qm.setQuota(tenant_id, .{
        .max_connections = max_connections,
        .max_concurrent_queries = max_concurrent_queries,
        .max_graphs = max_graphs,
        .max_nodes_per_graph = max_nodes_per_graph,
    }) catch |err| log.warn("tenant_admin.quota_apply_failed", &.{
        Attr.string("tenant", tenant_id),
        Attr.string("error", @errorName(err)),
    });
}

// ---------------------------------------------------------------------------
// Procedure handlers
// ---------------------------------------------------------------------------

/// `geode.tenant.create(tenant_id[, parent])` → 1 row (tenant_id, parent, created).
/// Registers in the durable registry AND populates the GAP-0838 hierarchy.
fn handleCreate(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 1 and a.len != 2) return error.InvalidArgs;
    const tenant_id = try literalString(a[0]);
    const parent: ?[]const u8 = if (a.len == 2) try literalString(a[1]) else null;

    const reg = try resolveRegistry();
    try reg.create(tenant_id, parent);

    // GAP-0838 seam: populate the production hierarchy. Parent must already be
    // in the hierarchy for a non-null parent to attach; create() above already
    // verified the parent exists in the registry, and registry creates mirror
    // into the hierarchy, so the parent is present unless the server started
    // with pre-existing registry rows (hydrated) but an empty hierarchy. In
    // that hydrate-without-rehydrate case the hierarchy add is best-effort and
    // logged; the registry remains authoritative.
    addToHierarchy(tenant_id, parent);

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "tenant_id");
    columns[1] = try allocator.dupe(u8, "parent");
    columns[2] = try allocator.dupe(u8, "created");
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 3);
    rows[0][0] = Value{ .Str = try allocator.dupe(u8, tenant_id) };
    rows[0][1] = if (parent) |p| Value{ .Str = try allocator.dupe(u8, p) } else Value{ .Null = {} };
    rows[0][2] = Value{ .Bool = true };

    const result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
    return try maybeYield(allocator, result, call_stmt);
}

/// `geode.tenant.list()` → one row per registered tenant.
fn handleList(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 0) return error.InvalidArgs;

    const reg = try resolveRegistry();
    const recs = try reg.list(allocator);
    defer tenant_registry.TenantRegistry.freeRecordSlice(allocator, recs);

    const result = try recordsToTable(allocator, recs);
    return try maybeYield(allocator, result, call_stmt);
}

/// `geode.tenant.show(tenant_id)` → 0 or 1 row. A missing tenant returns 0 rows
/// (the spec-clean "no result"), not an error.
fn handleShow(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 1) return error.InvalidArgs;
    const tenant_id = try literalString(a[0]);

    const reg = try resolveRegistry();
    var recs_buf: [1]tenant_registry.TenantRecord = undefined;
    var n: usize = 0;
    if (reg.get(allocator, tenant_id)) |rec| {
        recs_buf[0] = rec;
        n = 1;
    } else |err| switch (err) {
        tenant_registry.RegistryError.TenantNotFound => {},
        else => return err,
    }
    const recs = recs_buf[0..n];
    defer for (recs) |rec| {
        allocator.free(rec.tenant_id);
        if (rec.parent) |p| allocator.free(p);
    };

    const result = try recordsToTable(allocator, recs);
    return try maybeYield(allocator, result, call_stmt);
}

/// `geode.tenant.drop(tenant_id[, cascade])` → 1 row (tenant_id, dropped, nodes_deleted, edges_deleted).
///
/// GAP-0847 safe drop semantics. The pre-GAP-0847 drop removed ONLY the registry
/// record and ORPHANED the tenant's data (nodes/edges stayed tagged with a
/// tenant id that no longer existed) AND left the GAP-0838 hierarchy node
/// dangling. The corrected semantics:
///
///   • `cascade` (2nd arg) defaults to FALSE.
///   • A NON-cascade drop is REFUSED (`error.TenantHasData`) when the tenant
///     still has data rows (nodes or edges tagged with its id), and REFUSED
///     (`error.TenantHasChildren`) when it has child tenants in the hierarchy —
///     so an operator never silently orphans data or descendants.
///   • A `cascade = true` drop deletes the tenant's edges FIRST, then its nodes
///     (referential consistency), recursively drops child tenants bottom-up,
///     removes the hierarchy node, and finally removes the registry record.
///
/// Deletion uses the existing per-tenant scan primitives (`getAllEdgesForTenant`
/// / `getAllNodesForTenant`) and the existing `deleteEdge`/`deleteNode` store
/// methods, which route through the storage adapter vtable (WAL + durable
/// segment delete) when one is wired — so a cascade drop is durable and audited
/// exactly like any other delete, with an additional summary audit line here.
/// Other tenants' rows are never touched (the scan filters strictly on tenant id).
fn handleDrop(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 1 and a.len != 2) return error.InvalidArgs;
    const tenant_id = try literalString(a[0]);
    const cascade: bool = if (a.len == 2) try literalBool(a[1]) else false;

    // ── Reserved-tenant guard (GAP-0847 follow-up). ─────────────────────────
    // The reserved DEFAULT_TENANT_ID ("default") is the implicit scope for every
    // untagged row in the store. A cascade drop of "default" would scan-match and
    // delete every such row, then remove the sentinel registry record — i.e. wipe
    // the whole single-tenant store. Refuse before touching any data, regardless
    // of cascade. (The registry-side drop also enforces this, but we fail fast and
    // with a tenant-specific error here, before scanning.)
    if (std.mem.eql(u8, tenant_id, graph_store.DEFAULT_TENANT_ID)) {
        return tenant_registry.RegistryError.TenantReserved;
    }

    const reg = try resolveRegistry();
    // The tenant must exist before we touch any data — surface TenantNotFound.
    if (!reg.contains(tenant_id)) return tenant_registry.RegistryError.TenantNotFound;

    // ── Child-tenant guard (hierarchy). ──────────────────────────────────────
    // A parent with children may only be dropped with cascade (which drops the
    // children first, bottom-up). Without cascade we refuse rather than orphan.
    const engine_ptr = rls_types.getGlobalExprRLSEngine();
    if (engine_ptr) |ep| {
        const engine: *rls_core.RLSEngine = @ptrCast(@alignCast(ep));
        if (engine.hierarchy_manager.hasChildren(tenant_id)) {
            if (!cascade) return error.TenantHasChildren;
            try dropChildrenCascade(allocator, engine, tenant_id);
        }
    }

    // ── Data guard + cascade deletion. ───────────────────────────────────────
    var nodes_deleted: usize = 0;
    var edges_deleted: usize = 0;
    if (graph_store.getCurrentGlobalStore()) |store| {
        // Count first so a non-cascade drop can refuse without mutating anything.
        const edge_ids = try store.getAllEdgesForTenant(allocator, tenant_id);
        defer allocator.free(edge_ids);
        const node_ids = try store.getAllNodesForTenant(allocator, tenant_id);
        defer allocator.free(node_ids);

        if ((edge_ids.len > 0 or node_ids.len > 0) and !cascade) {
            return error.TenantHasData;
        }

        if (cascade) {
            const counts = deleteTenantRows(store, edge_ids, node_ids);
            edges_deleted = counts.edges;
            nodes_deleted = counts.nodes;
        }
    }

    // ── Hierarchy cleanup (self). ────────────────────────────────────────────
    if (engine_ptr) |ep| {
        const engine: *rls_core.RLSEngine = @ptrCast(@alignCast(ep));
        engine.hierarchy_manager.removeTenant(tenant_id) catch |err| switch (err) {
            error.TenantNotFound => {}, // never populated — benign
            else => log.warn("tenant_admin.hierarchy_remove_failed", &.{
                Attr.string("tenant", tenant_id),
                Attr.string("error", @errorName(err)),
            }),
        };
    }

    // ── Registry record removal (last — data + hierarchy already gone). ──────
    try reg.drop(tenant_id);

    // Summary audit: subject is logged by the authz gate; here we record the
    // destructive outcome (counts) so a cascade drop is attributable.
    log.info("tenant_admin.drop", &.{
        Attr.string("tenant", tenant_id),
        Attr.string("cascade", if (cascade) "true" else "false"),
        Attr.int("nodes_deleted", @intCast(nodes_deleted)),
        Attr.int("edges_deleted", @intCast(edges_deleted)),
    });

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "tenant_id");
    columns[1] = try allocator.dupe(u8, "dropped");
    columns[2] = try allocator.dupe(u8, "nodes_deleted");
    columns[3] = try allocator.dupe(u8, "edges_deleted");
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 4);
    rows[0][0] = Value{ .Str = try allocator.dupe(u8, tenant_id) };
    rows[0][1] = Value{ .Bool = true };
    rows[0][2] = Value{ .Int = @intCast(nodes_deleted) };
    rows[0][3] = Value{ .Int = @intCast(edges_deleted) };

    const result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
    return try maybeYield(allocator, result, call_stmt);
}

/// GAP-0847: shared scan-result deletion for a single tenant. Deletes EDGES
/// before NODES (deleting a node first would leave dangling adjacency entries
/// the edge delete relies on for slot routing), returning the count actually
/// issued. The caller owns / frees the id slices.
///
/// Failure posture (residual, documented in GAP_ANALYSIS.md): `deleteEdge` /
/// `deleteNode` are infallible at this seam — adapter-tier delete failures are
/// logged-and-swallowed by the store per the codebase-wide delete posture, so a
/// cascade under adapter failure can OVER-report deleted counts and still proceed
/// to registry removal. In-memory / OOM failures surface earlier (during the scan
/// `getAll*ForTenant`, which is `try`) and abort cleanly BEFORE registry removal.
fn deleteTenantRows(
    store: *graph_store.GraphStore,
    edge_ids: []const u64,
    node_ids: []const u64,
) struct { edges: usize, nodes: usize } {
    var edges: usize = 0;
    var nodes: usize = 0;
    for (edge_ids) |eid| {
        store.deleteEdge(eid);
        edges += 1;
    }
    for (node_ids) |nid| {
        store.deleteNode(nid);
        nodes += 1;
    }
    return .{ .edges = edges, .nodes = nodes };
}

/// GAP-0847: recursively cascade-drop every descendant of `tenant_id`,
/// bottom-up. For each direct child we recurse first (so grandchildren go
/// before children), then delete the child's data rows, then remove the child
/// from the hierarchy AND the registry. The parent itself is handled by the
/// caller. Children are snapshotted before mutation so we don't iterate a list
/// we are concurrently shrinking.
fn dropChildrenCascade(
    allocator: std.mem.Allocator,
    engine: *rls_core.RLSEngine,
    tenant_id: []const u8,
) !void {
    const children = try engine.hierarchy_manager.getChildrenAlloc(allocator, tenant_id);
    defer rls_core.HierarchyManager.freeChildren(allocator, children);

    for (children) |child| {
        // Recurse first: grandchildren before this child.
        try dropChildrenCascade(allocator, engine, child);

        // Delete the child's data rows (edges before nodes).
        var c_nodes: usize = 0;
        var c_edges: usize = 0;
        if (graph_store.getCurrentGlobalStore()) |store| {
            const edge_ids = try store.getAllEdgesForTenant(allocator, child);
            defer allocator.free(edge_ids);
            const node_ids = try store.getAllNodesForTenant(allocator, child);
            defer allocator.free(node_ids);
            const counts = deleteTenantRows(store, edge_ids, node_ids);
            c_edges = counts.edges;
            c_nodes = counts.nodes;
        }

        // error-policy: A — children were dropped depth-first above, so
        // removeTenant(child) can only fail with TenantNotFound here — both
        // members of its error set are benign (the node is already gone / has
        // no descendants left).
        engine.hierarchy_manager.removeTenant(child) catch {};

        // Registry record for the child (best-effort: a child registered in the
        // hierarchy may or may not also be in the registry).
        const reg = resolveRegistry() catch null;
        if (reg) |r| r.drop(child) catch |err| switch (err) {
            tenant_registry.RegistryError.TenantNotFound => {},
            else => return err,
        };

        log.info("tenant_admin.drop", &.{
            Attr.string("tenant", child),
            Attr.string("cascade", "true"),
            Attr.int("nodes_deleted", @intCast(c_nodes)),
            Attr.int("edges_deleted", @intCast(c_edges)),
        });
    }
}

/// `geode.tenant.set_quota(tenant_id, max_connections, max_concurrent_queries,
/// max_graphs, max_nodes_per_graph)` → 1 row (tenant_id, updated). Persists the
/// override in the registry AND pushes it to the live quota manager.
fn handleSetQuota(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 5) return error.InvalidArgs;
    const tenant_id = try literalString(a[0]);
    const max_connections = try literalU32(a[1]);
    const max_concurrent_queries = try literalU32(a[2]);
    const max_graphs = try literalU32(a[3]);
    const max_nodes_per_graph = try literalU64(a[4]);

    const reg = try resolveRegistry();
    try reg.setQuota(tenant_id, max_connections, max_concurrent_queries, max_graphs, max_nodes_per_graph);

    // GAP-0289 seam: make the override live in PRODUCTION.
    applyQuotaToManager(tenant_id, max_connections, max_concurrent_queries, max_graphs, max_nodes_per_graph);

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "tenant_id");
    columns[1] = try allocator.dupe(u8, "updated");
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 2);
    rows[0][0] = Value{ .Str = try allocator.dupe(u8, tenant_id) };
    rows[0][1] = Value{ .Bool = true };

    const result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
    return try maybeYield(allocator, result, call_stmt);
}

// ---------------------------------------------------------------------------
// Result shaping
// ---------------------------------------------------------------------------

/// Render a slice of tenant records as a 5-column table:
/// (tenant_id, parent, active, max_connections, max_concurrent_queries).
/// The quota columns reflect the registry override when present, else the
/// tenant_quota defaults so a `list()` row is always a complete, truthful view
/// of the effective limits.
fn recordsToTable(allocator: std.mem.Allocator, recs: []const tenant_registry.TenantRecord) !ExecutionResult {
    const default_quota = tenant_quota.TenantQuota{};

    const columns = try allocator.alloc([]const u8, 5);
    columns[0] = try allocator.dupe(u8, "tenant_id");
    columns[1] = try allocator.dupe(u8, "parent");
    columns[2] = try allocator.dupe(u8, "active");
    columns[3] = try allocator.dupe(u8, "max_connections");
    columns[4] = try allocator.dupe(u8, "max_concurrent_queries");

    const rows = try allocator.alloc([]Value, recs.len);
    for (recs, 0..) |rec, i| {
        const row = try allocator.alloc(Value, 5);
        row[0] = Value{ .Str = try allocator.dupe(u8, rec.tenant_id) };
        row[1] = if (rec.parent) |p| Value{ .Str = try allocator.dupe(u8, p) } else Value{ .Null = {} };
        row[2] = Value{ .Bool = rec.active };
        const conns: u32 = if (rec.has_quota) rec.max_connections else default_quota.max_connections;
        const queries: u32 = if (rec.has_quota) rec.max_concurrent_queries else default_quota.max_concurrent_queries;
        row[3] = Value{ .Int = @intCast(conns) };
        row[4] = Value{ .Int = @intCast(queries) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
}
