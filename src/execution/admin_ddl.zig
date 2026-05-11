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
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_create", &.{
        s.name,
        s.password,
        s.email orelse "",
        // "user" (lowercase) is what user_mgmt.Role.fromString accepts for the default role.
        s.role orelse "user",
    });
}

pub fn executeAlterUser(allocator: std.mem.Allocator, s: ast.AlterUserStatement, ctx: ExecutionContext) !ExecutionResult {
    return switch (s.action) {
        .set_password => |pw| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_reset_password", &.{ s.name, pw }),
        .set_role => |r| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_assign_role", &.{ s.name, r }),
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
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_delete", &.{s.name});
}

pub fn executeCreateRole(allocator: std.mem.Allocator, s: ast.CreateRoleStatement, ctx: ExecutionContext) !ExecutionResult {
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
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.role_delete", &.{s.name});
}

pub fn executeGrant(allocator: std.mem.Allocator, s: ast.GrantStatement, ctx: ExecutionContext) !ExecutionResult {
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

pub fn executeShowCapabilities(allocator: std.mem.Allocator) !ExecutionResult {
    // Two columns: feature, supported. Static snapshot for the current release.
    // The geode-ui consumes this for admin_writable feature detection.
    const Feature = struct { name: []const u8, supported: bool };
    const features = [_]Feature{
        .{ .name = "auth_ddl", .supported = true },
        .{ .name = "admin_writable", .supported = true },
        .{ .name = "role_ddl", .supported = true },
        .{ .name = "grant_ddl", .supported = true },
        .{ .name = "show_permissions", .supported = true },
        .{ .name = "show_version", .supported = true },
        .{ .name = "policy_ddl", .supported = false },
        .{ .name = "fle_ddl", .supported = false },
        .{ .name = "tenant_ddl", .supported = false },
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
    };
}
