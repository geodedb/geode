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

/// `geode.tenant.drop(tenant_id)` → 1 row (tenant_id, dropped).
fn handleDrop(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 1) return error.InvalidArgs;
    const tenant_id = try literalString(a[0]);

    const reg = try resolveRegistry();
    try reg.drop(tenant_id);

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "tenant_id");
    columns[1] = try allocator.dupe(u8, "dropped");
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
