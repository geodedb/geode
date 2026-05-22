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

fn singleStatusRow(allocator: std.mem.Allocator, status: []const u8) !ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try allocator.dupe(u8, status) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
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
