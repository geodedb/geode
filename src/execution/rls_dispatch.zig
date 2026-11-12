/// RLS Dispatch Module
///
/// Handles routing for all `geode.rls.*` procedure calls — the public surface
/// that gives the CLI / GQL layer access to the label-level deny-policy
/// engine living in src/server/rls_filter.zig.
///
/// The handlers exposed here are the missing piece for three harness specs
/// (rls_fle_no_decrypt_on_deny, rls_cross_tenant_query_shapes,
/// rls_policy_cache_invalidation): all three need to install a per-user,
/// per-label deny without piggy-backing on the GPS allow-by-default
/// catalog wired into geode.auth.policy_create.
///
/// Because rls_filter.zig lives in the `root` Zig module (imported directly
/// from server/main.zig) and execution/* lives in the `geode` Zig module,
/// this dispatcher cannot import rls_filter directly without violating the
/// one-module-per-source-file rule. Instead it uses the same callback /
/// hooks pattern that auth_dispatch already uses for grant persistence:
/// server/main.zig calls setCallbacks() at startup, pointing the function
/// pointers at the rls_filter engine. In CLI / test contexts the callbacks
/// remain null and the dispatcher returns a clear error.
///
/// CANARY: REQ=REQ-RLS-DDL-001; FEATURE="RLS deny-policy procedure"; ASPECT=AddDenyPolicy; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/rls_cross_tenant_query_shapes.yml; OWNER=security; UPDATED=2026-05-22
const std = @import("std");

const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");

const logging = @import("logging");
const log = logging.scoped("rls");
const Attr = logging.Attr;

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

const Value = value_types.Value;

const user_mgmt = @import("../security/user_management.zig");
const audit_mod = @import("../security/audit.zig");

// REQ=GAP-0284: the expression RLS engine and its global publisher. The
// `geode.rls.add_attribute_policy` handler installs a compiled property-vs-
// principal-attribute policy directly on the process-global expr engine that
// the match loop already consults via `passesRLSExprFilter`.
const rls_core = @import("rls");
const rls_types = @import("rls_types");
const RLSEngine = rls_core.RLSEngine;

// ---------------------------------------------------------------------------
// Callback / hooks pattern. The server wires these at startup; CLI / test
// contexts leave them null.
// ---------------------------------------------------------------------------

pub const ListedPolicy = struct {
    graph: []const u8,
    label: []const u8,
    username: []const u8,
};

pub const RLSFilterCallbacks = struct {
    ctx: ?*anyopaque = null,
    add_deny_fn: ?*const fn (ctx: ?*anyopaque, graph: []const u8, label: []const u8, username: []const u8) anyerror!void = null,
    /// Returns the number of policies removed.
    remove_deny_fn: ?*const fn (ctx: ?*anyopaque, graph: []const u8, label: []const u8, username: []const u8) usize = null,
    /// Caller frees the returned slice and each entry's strings.
    list_deny_fn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]ListedPolicy = null,
    policy_count_fn: ?*const fn (ctx: ?*anyopaque) usize = null,
};

var g_callbacks: RLSFilterCallbacks = .{};

/// Install the runtime callbacks. Called once at server startup from code
/// that lives in the `root` module and can therefore import rls_filter.zig
/// directly (typically src/server/main.zig).
pub fn setCallbacks(cb: RLSFilterCallbacks) void {
    g_callbacks = cb;
}

/// Reset to defaults — typically used by tests.
pub fn resetCallbacks() void {
    g_callbacks = .{};
}

// ---------------------------------------------------------------------------
// StaticStringMap dispatch table
// ---------------------------------------------------------------------------
const RlsHandler = *const fn (std.mem.Allocator, []const u8, ast.CallProcedure, ExecutionContext) anyerror!ExecutionResult;

const dispatch_table = std.StaticStringMap(RlsHandler).initComptime(.{
    .{ "geode.rls.add_deny_policy", handleAddDenyPolicy },
    .{ "geode.rls.remove_deny_policy", handleRemoveDenyPolicy },
    .{ "geode.rls.list_deny_policies", handleListDenyPolicies },
    .{ "geode.rls.policy_count", handlePolicyCount },
    .{ "geode.rls.add_attribute_policy", handleAddAttributePolicy },
    .{ "geode.rls.remove_attribute_policy", handleRemoveAttributePolicy },
});

const read_only_set = std.StaticStringMap(void).initComptime(.{
    .{ "geode.rls.list_deny_policies", {} },
    .{ "geode.rls.policy_count", {} },
});

/// Execute a geode.rls.* procedure. Returns null if not recognized.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    if (!std.mem.startsWith(u8, proc_name, "geode.rls.")) return null;

    if (user_mgmt.isAuthEnabled()) {
        if (context.role == null) {
            return error.Unauthenticated;
        }
        const is_read_only = read_only_set.has(proc_name);
        if (!is_read_only and context.role.? != .Admin) {
            return error.Unauthorized;
        }
    }

    if (dispatch_table.get(proc_name)) |handler| {
        return try handler(allocator, proc_name, call_stmt, context);
    }
    return null;
}

// ===========================================================================
// Handlers
// ===========================================================================

fn argStr(call_stmt: ast.CallProcedure, idx: usize) []const u8 {
    if (call_stmt.procedure != .Call) return "";
    const args = call_stmt.procedure.Call.args;
    if (idx >= args.len) return "";
    if (args[idx].* != .String) return "";
    return args[idx].String;
}

/// SONNY-2746: frees what it allocated when a later allocation fails, and
/// the result owns its status string (`owns_value_memory`, as the meta, auth
/// and tenant dispatchers' results do), so `deinit` frees it too.
fn singleStatusRow(allocator: std.mem.Allocator, status: []const u8) !ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(columns);
    columns[0] = try allocator.dupe(u8, "status");
    errdefer allocator.free(columns[0]);
    const row = try allocator.alloc(Value, 1);
    errdefer allocator.free(row);
    const status_copy = try allocator.dupe(u8, status);
    errdefer allocator.free(status_copy);
    row[0] = Value{ .Str = status_copy };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty, .owns_value_memory = true };
}

/// CALL geode.rls.add_deny_policy(graph, label, username)
/// Empty username applies to all users on (graph, label).
fn handleAddDenyPolicy(
    allocator: std.mem.Allocator,
    _: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) anyerror!ExecutionResult {
    const graph = argStr(call_stmt, 0);
    const label = argStr(call_stmt, 1);
    const username = argStr(call_stmt, 2);

    if (graph.len == 0 or label.len == 0) {
        return try singleStatusRow(allocator, "error: graph and label are required (positional args: graph, label, username)");
    }

    const add_fn = g_callbacks.add_deny_fn orelse {
        log.warn("RLS deny-policy callback not installed — server started without RLS dispatch wiring", &.{});
        return try singleStatusRow(allocator, "error: RLS filter engine not initialized (server started with no RLS support)");
    };

    try add_fn(g_callbacks.ctx, graph, label, username);

    log.info("RLS deny policy added", &.{
        Attr.string("graph", graph),
        Attr.string("label", label),
        Attr.string("username", username),
    });

    {
        const detail_str = std.fmt.allocPrint(
            allocator,
            "graph={s} label={s} username={s}",
            .{ graph, label, username },
        ) catch null;
        defer if (detail_str) |s| allocator.free(s);
        const actor_user_id: u64 = if (context.principal) |p| (p.user_id orelse 0) else 0;
        const actor_username: []const u8 = if (context.principal) |p| (p.username orelse "") else "";
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .configuration_change,
            .action = "RLS_ADD_DENY_POLICY",
            .user_id = actor_user_id,
            .username = actor_username,
            .details = detail_str,
        });
    }

    const msg = try std.fmt.allocPrint(
        allocator,
        "deny policy added: graph={s} label={s} username={s}",
        .{ graph, label, if (username.len == 0) "*" else username },
    );
    defer allocator.free(msg);
    return try singleStatusRow(allocator, msg);
}

/// CALL geode.rls.remove_deny_policy(graph, label, username)
fn handleRemoveDenyPolicy(
    allocator: std.mem.Allocator,
    _: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) anyerror!ExecutionResult {
    const graph = argStr(call_stmt, 0);
    const label = argStr(call_stmt, 1);
    const username = argStr(call_stmt, 2);

    if (graph.len == 0 or label.len == 0) {
        return try singleStatusRow(allocator, "error: graph and label are required (positional args: graph, label, username)");
    }

    const remove_fn = g_callbacks.remove_deny_fn orelse {
        return try singleStatusRow(allocator, "error: RLS filter engine not initialized");
    };

    const removed = remove_fn(g_callbacks.ctx, graph, label, username);

    log.info("RLS deny policy removed", &.{
        Attr.string("graph", graph),
        Attr.string("label", label),
        Attr.string("username", username),
        Attr.uint("removed_count", @as(u64, removed)),
    });

    if (removed > 0) {
        const detail_str = std.fmt.allocPrint(
            allocator,
            "graph={s} label={s} username={s} removed={d}",
            .{ graph, label, username, removed },
        ) catch null;
        defer if (detail_str) |s| allocator.free(s);
        const actor_user_id: u64 = if (context.principal) |p| (p.user_id orelse 0) else 0;
        const actor_username: []const u8 = if (context.principal) |p| (p.username orelse "") else "";
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .configuration_change,
            .action = "RLS_REMOVE_DENY_POLICY",
            .user_id = actor_user_id,
            .username = actor_username,
            .details = detail_str,
        });
    }

    const msg = try std.fmt.allocPrint(
        allocator,
        "deny policy removed: graph={s} label={s} username={s} removed_count={d}",
        .{ graph, label, if (username.len == 0) "*" else username, removed },
    );
    defer allocator.free(msg);
    return try singleStatusRow(allocator, msg);
}

/// CALL geode.rls.list_deny_policies() -> rows of (graph, label, username)
fn handleListDenyPolicies(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: ast.CallProcedure,
    _: ExecutionContext,
) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "graph");
    columns[1] = try allocator.dupe(u8, "label");
    columns[2] = try allocator.dupe(u8, "username");

    var rows_list = std.ArrayList([]Value).empty;
    if (g_callbacks.list_deny_fn) |list_fn| {
        const listed = try list_fn(g_callbacks.ctx, allocator);
        defer {
            for (listed) |p| {
                allocator.free(p.graph);
                allocator.free(p.label);
                allocator.free(p.username);
            }
            allocator.free(listed);
        }
        for (listed) |p| {
            const row = try allocator.alloc(Value, 3);
            row[0] = Value{ .Str = try allocator.dupe(u8, p.graph) };
            row[1] = Value{ .Str = try allocator.dupe(u8, p.label) };
            row[2] = Value{ .Str = try allocator.dupe(u8, if (p.username.len == 0) "*" else p.username) };
            try rows_list.append(allocator, row);
        }
    }

    return .{
        .columns = columns,
        .rows = try rows_list.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ===========================================================================
// REQ=GAP-0284: ABAC attribute-based row-level policies.
// ===========================================================================

// CANARY: REQ=REQ-SONNY-2732-RLS-STRICT-POLICIES; FEATURE="RLS deny-policy procedure"; ASPECT=AttributePolicyIdentifiers; STATUS=TESTED; TEST=tests/test_sonny2709_rls_range_fail_closed.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2732: is `name` a plain identifier (`[A-Za-z_][A-Za-z0-9_]*`, at
/// most 128 bytes)? `add_attribute_policy` pastes the row property and the
/// attribute key into the policy's text (`row.<prop> = principal.attribute.<key>`),
/// so anything else would be compiled as part of the expression: a property
/// of `x = 'a' OR TRUE OR row.y` yielded a policy that admits every row.
fn isPolicyIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

/// Deterministic policy id derived from (graph, label, row_property,
/// attribute_key) so `remove_attribute_policy` can locate the same policy
/// `add_attribute_policy` installed.
fn attributePolicyId(graph: []const u8, label: []const u8, row_property: []const u8, attribute_key: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0xABACABAC);
    hasher.update(graph);
    hasher.update("\x00");
    hasher.update(label);
    hasher.update("\x00");
    hasher.update(row_property);
    hasher.update("\x00");
    hasher.update(attribute_key);
    return hasher.final();
}

/// CALL geode.rls.add_attribute_policy(graph, label, row_property, attribute_key)
///
/// Installs a restrictive expression RLS policy on (graph, label) that, per
/// row, allows the row only when `row.<row_property>` equals the querying
/// principal's ABAC attribute `<attribute_key>`. This is real per-row ABAC
/// filtering: the bytecode VM resolves `principal.attribute.<key>` against the
/// global user attribute store at evaluation time.
fn handleAddAttributePolicy(
    allocator: std.mem.Allocator,
    _: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) anyerror!ExecutionResult {
    const graph = argStr(call_stmt, 0);
    const label = argStr(call_stmt, 1);
    const row_property = argStr(call_stmt, 2);
    const attribute_key = argStr(call_stmt, 3);

    if (graph.len == 0 or label.len == 0 or row_property.len == 0 or attribute_key.len == 0) {
        return try singleStatusRow(allocator, "error: graph, label, row_property and attribute_key are required");
    }
    // SONNY-2732: both are pasted into the policy text; refuse anything but
    // an identifier, and install nothing.
    if (!isPolicyIdentifier(row_property) or !isPolicyIdentifier(attribute_key)) {
        return error.InvalidPolicyIdentifier;
    }

    const engine_ptr = rls_types.getGlobalExprRLSEngine() orelse {
        log.warn("RLS attribute-policy: expr engine not initialized — server started without RLS support", &.{});
        return try singleStatusRow(allocator, "error: RLS expression engine not initialized");
    };
    const engine: *RLSEngine = @ptrCast(@alignCast(engine_ptr));

    // SONNY-2746: build the reply first. Installing the policy is then the
    // last step that can fail, so a call that fails (OutOfMemory anywhere,
    // or an expression the engine refuses) changes nothing and leaks nothing.
    const msg = try std.fmt.allocPrint(
        allocator,
        "attribute policy added: graph={s} label={s} row.{s}=principal.attribute.{s}",
        .{ graph, label, row_property, attribute_key },
    );
    defer allocator.free(msg);
    var reply = try singleStatusRow(allocator, msg);
    errdefer reply.deinit(allocator);

    try installAttributePolicy(engine, graph, label, row_property, attribute_key);

    log.info("RLS attribute policy added", &.{
        Attr.string("graph", graph),
        Attr.string("label", label),
        Attr.string("row_property", row_property),
        Attr.string("attribute_key", attribute_key),
    });

    {
        const detail_str = std.fmt.allocPrint(
            allocator,
            "graph={s} label={s} row_property={s} attribute_key={s}",
            .{ graph, label, row_property, attribute_key },
        ) catch null;
        defer if (detail_str) |s| allocator.free(s);
        const actor_user_id: u64 = if (context.principal) |p| (p.user_id orelse 0) else 0;
        const actor_username: []const u8 = if (context.principal) |p| (p.username orelse "") else "";
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .configuration_change,
            .action = "RLS_ADD_ATTRIBUTE_POLICY",
            .user_id = actor_user_id,
            .username = actor_username,
            .details = detail_str,
        });
    }

    return reply;
}

// CANARY: REQ=REQ-SONNY-2746-RLS-ATTRIBUTE-POLICY-OOM; FEATURE="RLS deny-policy procedure"; ASPECT=AttributePolicyOomCleanup; STATUS=TESTED; TEST=tests/test_sonny2746_rls_attribute_policy_oom.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2746: copy the attribute policy into the expression engine's
/// allocator and install it. Once `createPolicy` accepts the policy its
/// strings are the engine's (`owns_strings`, SONNY-2773: freed when the
/// policy is removed and at the engine's deinit); until then they
/// are this function's, and an error (OutOfMemory at any copy or inside
/// `createPolicy`) frees every one of them. They used to leak. On failure the
/// engine keeps no pointer to them either (`RLSEngine.installPolicy`).
fn installAttributePolicy(
    engine: *RLSEngine,
    graph: []const u8,
    label: []const u8,
    row_property: []const u8,
    attribute_key: []const u8,
) !void {
    const eng_alloc = engine.allocator;

    // The policy expression: row.<prop> = principal.attribute.<key>.
    const raw_expr = try std.fmt.allocPrint(
        eng_alloc,
        "row.{s} = principal.attribute.{s}",
        .{ row_property, attribute_key },
    );
    errdefer eng_alloc.free(raw_expr);
    const name = try eng_alloc.dupe(u8, "abac_attribute_policy");
    errdefer eng_alloc.free(name);
    const description = try eng_alloc.dupe(u8, "ABAC: row property must equal principal attribute");
    errdefer eng_alloc.free(description);
    const policy_graph = try eng_alloc.dupe(u8, graph);
    errdefer eng_alloc.free(policy_graph);
    const policy_table = try eng_alloc.dupe(u8, label);
    errdefer eng_alloc.free(policy_table);

    const now: i64 = 0; // metadata only; not load-bearing for enforcement
    try engine.createPolicy(.{
        .id = attributePolicyId(graph, label, row_property, attribute_key),
        .name = name,
        .description = description,
        .graph = policy_graph,
        .table = policy_table,
        .operation = .select,
        .permissive = false, // restrictive: row must satisfy the expression
        .roles = &[_]u64{},
        .using_expr = RLSEngine.Expression{
            .raw = raw_expr,
            .parsed = null,
            .compiled = null, // createPolicy compiles it
            .parameters = &[_]RLSEngine.Expression.Parameter{},
        },
        .check_expr = null,
        .enabled = true,
        .created_at = now,
        .updated_at = now,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .denials,
        // SONNY-2773: the engine frees them on remove_attribute_policy and
        // at deinit (they leaked for the server's life).
        .owns_strings = true,
    });
}

/// CALL geode.rls.remove_attribute_policy(graph, label, row_property, attribute_key)
fn handleRemoveAttributePolicy(
    allocator: std.mem.Allocator,
    _: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) anyerror!ExecutionResult {
    const graph = argStr(call_stmt, 0);
    const label = argStr(call_stmt, 1);
    const row_property = argStr(call_stmt, 2);
    const attribute_key = argStr(call_stmt, 3);

    if (graph.len == 0 or label.len == 0 or row_property.len == 0 or attribute_key.len == 0) {
        return try singleStatusRow(allocator, "error: graph, label, row_property and attribute_key are required");
    }

    const engine_ptr = rls_types.getGlobalExprRLSEngine() orelse {
        return try singleStatusRow(allocator, "error: RLS expression engine not initialized");
    };
    const engine: *RLSEngine = @ptrCast(@alignCast(engine_ptr));

    const policy_id = attributePolicyId(graph, label, row_property, attribute_key);
    var removed = true;
    engine.deletePolicy(policy_id) catch {
        removed = false;
    };

    if (removed) {
        log.info("RLS attribute policy removed", &.{
            Attr.string("graph", graph),
            Attr.string("label", label),
            Attr.string("row_property", row_property),
            Attr.string("attribute_key", attribute_key),
        });
        const detail_str = std.fmt.allocPrint(
            allocator,
            "graph={s} label={s} row_property={s} attribute_key={s}",
            .{ graph, label, row_property, attribute_key },
        ) catch null;
        defer if (detail_str) |s| allocator.free(s);
        const actor_user_id: u64 = if (context.principal) |p| (p.user_id orelse 0) else 0;
        const actor_username: []const u8 = if (context.principal) |p| (p.username orelse "") else "";
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .configuration_change,
            .action = "RLS_REMOVE_ATTRIBUTE_POLICY",
            .user_id = actor_user_id,
            .username = actor_username,
            .details = detail_str,
        });
    }

    const msg = try std.fmt.allocPrint(
        allocator,
        "attribute policy removed: graph={s} label={s} removed={s}",
        .{ graph, label, if (removed) "true" else "false" },
    );
    defer allocator.free(msg);
    return try singleStatusRow(allocator, msg);
}

/// CALL geode.rls.policy_count() -> single-row int.
fn handlePolicyCount(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: ast.CallProcedure,
    _: ExecutionContext,
) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "count");
    const row = try allocator.alloc(Value, 1);
    const count: i64 = if (g_callbacks.policy_count_fn) |cnt| @intCast(cnt(g_callbacks.ctx)) else 0;
    row[0] = Value{ .Int = count };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}
