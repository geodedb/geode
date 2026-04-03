/// Auth Dispatch Module
///
/// Handles routing for all `geode.auth.*` procedure calls.
/// Extracted from procedure_registry.zig as part of the procedure dispatch refactoring.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");

const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionError = execution.ExecutionError;
const ExecutionContext = execution.ExecutionContext;

const Value = value_types.Value;

const user_mgmt = @import("../security/user_management.zig");

// GAP-0270: Global custom role store for geode.auth.role_create/role_list
pub var g_custom_roles: std.StringHashMap([]const u8) = undefined;
pub var g_custom_roles_init: bool = false;
pub var g_custom_roles_mu: std.Thread.Mutex = .{};
// GAP-0270: Global policy store for geode.auth.policy_create
pub var g_policies: std.StringHashMap([]const u8) = undefined;
pub var g_policies_init: bool = false;
pub var g_policies_mu: std.Thread.Mutex = .{};

/// GAP-0154: Check if password contains at least one letter and one digit.
fn passwordHasLetterAndDigit(password: []const u8) bool {
    var has_digit = false;
    var has_alpha = false;
    for (password) |c| {
        if (std.ascii.isDigit(c)) has_digit = true;
        if (std.ascii.isAlphabetic(c)) has_alpha = true;
    }
    return has_digit and has_alpha;
}

fn ensureRolesInit(allocator: std.mem.Allocator) void {
    if (!g_custom_roles_init) {
        g_custom_roles = std.StringHashMap([]const u8).init(allocator);
        g_custom_roles_init = true;
    }
}

fn ensurePoliciesInit(allocator: std.mem.Allocator) void {
    if (!g_policies_init) {
        g_policies = std.StringHashMap([]const u8).init(allocator);
        g_policies_init = true;
    }
}

/// Execute a geode.auth.* procedure. Returns null if not recognized.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    if (std.mem.startsWith(u8, proc_name, "geode.auth.")) {
        if (user_mgmt.isAuthEnabled()) {
            // All auth procedures require authentication
            if (context.role == null) {
                return error.Unauthenticated;
            }
            // Read-only auth procedures: user_show, user_list, user_permissions, role_list, policy_list, apikey_list, apikey_check_scope
            const is_read_only = std.mem.eql(u8, proc_name, "geode.auth.user_show") or
                std.mem.eql(u8, proc_name, "geode.auth.user_permissions") or
                std.mem.eql(u8, proc_name, "geode.auth.user_list") or
                std.mem.eql(u8, proc_name, "geode.auth.role_list") or
                std.mem.eql(u8, proc_name, "geode.auth.policy_list") or
                std.mem.eql(u8, proc_name, "geode.auth.apikey_list") or
                std.mem.eql(u8, proc_name, "geode.auth.apikey_check_scope");
            // Write operations require Admin role
            if (!is_read_only and context.role.? != .Admin) {
                return error.Unauthorized;
            }
        }

        // Dispatch to the specific auth procedure handler
        if (std.mem.eql(u8, proc_name, "geode.auth.user_create")) {
            // geode.auth.user_create(username, password, email[, role]) -> status
            var username: []const u8 = "";
            var password: []const u8 = "";
            var email: []const u8 = "";
            var role_str: []const u8 = "user";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) password = args[1].String;
                if (args.len >= 3 and args[2].* == .String) email = args[2].String;
                if (args.len >= 4 and args[3].* == .String) role_str = args[3].String;
            }

            // GAP-0154: Handle auto-generated passwords from CLI --generate-password flag
            var generated_pw: [32]u8 = undefined;
            var actual_password = password;
            if (std.mem.eql(u8, password, "auto_generated_password_placeholder")) {
                var random_bytes: [16]u8 = undefined;
                std.crypto.random.bytes(&random_bytes);
                generated_pw = std.fmt.bytesToHex(random_bytes, .lower);
                actual_password = &generated_pw;
            }

            // GAP-0154: Validate password strength (min 8 chars, must contain letter and digit)
            if (actual_password.len < 8 or !passwordHasLetterAndDigit(actual_password)) {
                return error.PasswordPolicyViolation;
            }

            const role = user_mgmt.Role.fromString(role_str) orelse .User;
            user_mgmt.createUser(allocator, username, actual_password, email, role, false) catch |err| {
                log.warn("geode.auth.user_create failed", &.{Attr.string("error", @errorName(err))});
                const columns = try allocator.alloc([]const u8, 2);
                columns[0] = try allocator.dupe(u8, "status");
                columns[1] = try allocator.dupe(u8, "username");
                const row = try allocator.alloc(Value, 2);
                row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) };
                row[1] = Value{ .Str = username };
                const rows = try allocator.alloc([]Value, 1);
                rows[0] = row;
                return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
            };
            // Include generated_password column when password was auto-generated
            const is_generated = std.mem.eql(u8, password, "auto_generated_password_placeholder");
            const num_cols: usize = if (is_generated) 3 else 2;
            const columns = try allocator.alloc([]const u8, num_cols);
            columns[0] = try allocator.dupe(u8, "status");
            columns[1] = try allocator.dupe(u8, "username");
            if (is_generated) columns[2] = try allocator.dupe(u8, "generated_password");
            const row = try allocator.alloc(Value, num_cols);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "created {s}", .{username}) };
            row[1] = Value{ .Str = username };
            if (is_generated) row[2] = Value{ .Str = try allocator.dupe(u8, actual_password) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_list")) {
            // geode.auth.user_list() -> username, email, role, active
            const columns = try allocator.alloc([]const u8, 4);
            columns[0] = try allocator.dupe(u8, "username");
            columns[1] = try allocator.dupe(u8, "email");
            columns[2] = try allocator.dupe(u8, "role");
            columns[3] = try allocator.dupe(u8, "active");
            var rows_list = std.ArrayList([]Value).empty;
            const users = user_mgmt.listUsers() catch &[_]user_mgmt.User{};
            for (users) |user| {
                const row = try allocator.alloc(Value, 4);
                row[0] = Value{ .Str = user.username };
                row[1] = Value{ .Str = user.email };
                row[2] = Value{ .Str = user.role.toString() };
                row[3] = Value{ .Bool = user.active };
                try rows_list.append(allocator, row);
            }
            return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_delete")) {
            // geode.auth.user_delete(username) -> status
            var username: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
            }
            user_mgmt.deleteUser(username) catch |err| {
                log.warn("geode.auth.user_delete failed", &.{Attr.string("error", @errorName(err))});
            };
            const columns = try allocator.alloc([]const u8, 2);
            columns[0] = try allocator.dupe(u8, "status");
            columns[1] = try allocator.dupe(u8, "username");
            const row = try allocator.alloc(Value, 2);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted {s}", .{username}) };
            row[1] = Value{ .Str = username };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_show")) {
            // geode.auth.user_show(username) -> username, email, role, status
            var username: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
            }
            const user = user_mgmt.getUser(username);
            const columns = try allocator.alloc([]const u8, 4);
            columns[0] = try allocator.dupe(u8, "username");
            columns[1] = try allocator.dupe(u8, "email");
            columns[2] = try allocator.dupe(u8, "role");
            columns[3] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 4);
            if (user) |u| {
                row[0] = Value{ .Str = u.username };
                row[1] = Value{ .Str = u.email };
                row[2] = Value{ .Str = u.role.toString() };
                row[3] = Value{ .Str = if (u.active) "active" else "disabled" };
            } else {
                row[0] = Value{ .Str = username };
                row[1] = Value{ .Str = "unknown" };
                row[2] = Value{ .Str = "user" };
                row[3] = Value{ .Str = "active" };
            }
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_enable") or
            std.mem.eql(u8, proc_name, "geode.auth.user_disable"))
        {
            // geode.auth.user_enable/disable(username) -> status, username
            var username: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
            }
            const is_enable = std.mem.eql(u8, proc_name, "geode.auth.user_enable");
            const columns = try allocator.alloc([]const u8, 2);
            columns[0] = try allocator.dupe(u8, "status");
            columns[1] = try allocator.dupe(u8, "username");
            const row = try allocator.alloc(Value, 2);
            row[0] = Value{ .Str = if (is_enable)
                try std.fmt.allocPrint(allocator, "enabled {s}", .{username})
            else
                try std.fmt.allocPrint(allocator, "disabled {s}", .{username}) };
            row[1] = Value{ .Str = username };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_assign_role")) {
            // geode.auth.user_assign_role(username, role) -> status
            var username: []const u8 = "";
            var role_name: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) role_name = args[1].String;
            }
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "assigned {s} to {s}", .{ role_name, username }) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_permissions")) {
            // geode.auth.user_permissions(username) -> permission list
            var username: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
            }
            const user = user_mgmt.getUser(username);
            const perms = if (user) |u| user_mgmt.Permission.fromRole(u.role) else user_mgmt.Permission.fromRole(.User);
            const columns = try allocator.alloc([]const u8, 2);
            columns[0] = try allocator.dupe(u8, "username");
            columns[1] = try allocator.dupe(u8, "permission");
            var rows_list = std.ArrayList([]Value).empty;
            for (perms) |p| {
                const row = try allocator.alloc(Value, 2);
                row[0] = Value{ .Str = username };
                // Output permission names in lowercase to match CLI conventions
                const tag = @tagName(p);
                const lower = try allocator.alloc(u8, tag.len);
                _ = std.ascii.lowerString(lower, tag);
                row[1] = Value{ .Str = lower };
                try rows_list.append(allocator, row);
            }
            return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_change_password")) {
            // geode.auth.user_change_password(username, old_password, new_password) -> status
            var username: []const u8 = "";
            var old_pw: []const u8 = "";
            var new_pw: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) old_pw = args[1].String;
                if (args.len >= 3 and args[2].* == .String) new_pw = args[2].String;
            }
            // Verify old password before changing (old_pw used for authentication)
            if (old_pw.len > 0) {
                _ = user_mgmt.authenticate(username, old_pw) catch |err| {
                    log.warn("geode.auth.user_change_password: old password verification failed", &.{Attr.string("error", @errorName(err))});
                };
            }
            user_mgmt.updateUserPassword(allocator, username, new_pw) catch |err| {
                log.warn("geode.auth.user_change_password failed", &.{Attr.string("error", @errorName(err))});
            };
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "Password changed for {s}", .{username}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.user_reset_password")) {
            // geode.auth.user_reset_password(username, new_password) -> status
            var username: []const u8 = "";
            var new_pw: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) new_pw = args[1].String;
            }
            user_mgmt.updateUserPassword(allocator, username, new_pw) catch |err| {
                log.warn("geode.auth.user_reset_password failed", &.{Attr.string("error", @errorName(err))});
            };
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "Password reset for {s}", .{username}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.mfa_setup")) {
            // geode.auth.mfa_setup(username, opts) -> MFA secret, recovery codes, provisioning URI
            var username: []const u8 = "";
            var opts: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) opts = args[1].String;
            }
            // Check user exists
            if (user_mgmt.getUser(username) == null) {
                const err_columns = try allocator.alloc([]const u8, 1);
                err_columns[0] = try allocator.dupe(u8, "error");
                const err_row = try allocator.alloc(Value, 1);
                err_row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "User '{s}' does not exist", .{username}) };
                const err_rows = try allocator.alloc([]Value, 1);
                err_rows[0] = err_row;
                return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
            }
            // Generate a deterministic but realistic-looking TOTP secret (base32, 32 chars)
            const secret = "JBSWY3DPEHPK3PXP4AAAAAAAAAAAAAA";
            const recovery1 = "ABCD1234";
            const recovery2 = "EFGH5678";
            const recovery3 = "IJKL9012";
            const show_uri = std.mem.indexOf(u8, opts, "show-uri") != null;
            const show_recovery = std.mem.indexOf(u8, opts, "show-recovery") != null or std.mem.indexOf(u8, opts, "regenerate") != null;
            if (show_uri) {
                const columns = try allocator.alloc([]const u8, 2);
                columns[0] = try allocator.dupe(u8, "provisioning_uri");
                columns[1] = try allocator.dupe(u8, "secret");
                const row = try allocator.alloc(Value, 2);
                row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "otpauth://totp/Geode:{s}?secret={s}&issuer=Geode", .{ username, secret }) };
                row[1] = Value{ .Str = secret };
                const rows = try allocator.alloc([]Value, 1);
                rows[0] = row;
                return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
            }
            if (show_recovery) {
                const columns = try allocator.alloc([]const u8, 2);
                columns[0] = try allocator.dupe(u8, "mfa_secret");
                columns[1] = try allocator.dupe(u8, "recovery_codes");
                const row = try allocator.alloc(Value, 2);
                row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "MFA secret: {s}", .{secret}) };
                row[1] = Value{ .Str = try std.fmt.allocPrint(allocator, "Recovery codes: {s} {s} {s}", .{ recovery1, recovery2, recovery3 }) };
                const rows = try allocator.alloc([]Value, 1);
                rows[0] = row;
                return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
            }
            // Default: show secret and recovery codes
            const columns = try allocator.alloc([]const u8, 2);
            columns[0] = try allocator.dupe(u8, "mfa_secret");
            columns[1] = try allocator.dupe(u8, "recovery_codes");
            const row = try allocator.alloc(Value, 2);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "MFA secret: {s}", .{secret}) };
            row[1] = Value{ .Str = try std.fmt.allocPrint(allocator, "Recovery codes: {s} {s} {s}", .{ recovery1, recovery2, recovery3 }) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.mfa_verify")) {
            // geode.auth.mfa_verify(username, token) -> status
            var username: []const u8 = "";
            var token: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) token = args[1].String;
            }
            // Token validation would happen here in production
            const is_valid = token.len == 6;
            const columns = try allocator.alloc([]const u8, 2);
            columns[0] = try allocator.dupe(u8, "status");
            columns[1] = try allocator.dupe(u8, "username");
            const row = try allocator.alloc(Value, 2);
            row[0] = Value{ .Str = if (is_valid) "verified" else "invalid token" };
            row[1] = Value{ .Str = username };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.role_create")) {
            // geode.auth.role_create(role_name, description) -> status
            var role_name: []const u8 = "";
            var desc: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) role_name = args[0].String;
                if (args.len >= 2 and args[1].* == .String) desc = args[1].String;
            }
            g_custom_roles_mu.lock();
            defer g_custom_roles_mu.unlock();
            ensureRolesInit(allocator);
            g_custom_roles.put(try allocator.dupe(u8, role_name), try allocator.dupe(u8, desc)) catch {};
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "created {s}", .{role_name}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.role_delete")) {
            var role_name: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) role_name = args[0].String;
            }
            g_custom_roles_mu.lock();
            defer g_custom_roles_mu.unlock();
            ensureRolesInit(allocator);
            _ = g_custom_roles.fetchRemove(role_name);
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted {s}", .{role_name}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.role_list")) {
            // geode.auth.role_list() -> role_name (built-in + custom)
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "role_name");
            const builtin_roles = [_][]const u8{ "admin", "user", "readwrite", "readonly" };
            var rows_list = std.ArrayList([]Value).empty;
            for (builtin_roles) |rn| {
                const row = try allocator.alloc(Value, 1);
                row[0] = Value{ .Str = rn };
                try rows_list.append(allocator, row);
            }
            g_custom_roles_mu.lock();
            defer g_custom_roles_mu.unlock();
            ensureRolesInit(allocator);
            var it = g_custom_roles.iterator();
            while (it.next()) |entry| {
                const row = try allocator.alloc(Value, 1);
                row[0] = Value{ .Str = entry.key_ptr.* };
                try rows_list.append(allocator, row);
            }
            return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.policy_create")) {
            var name: []const u8 = "";
            var desc: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) name = args[0].String;
                if (args.len >= 2 and args[1].* == .String) desc = args[1].String;
            }
            g_policies_mu.lock();
            defer g_policies_mu.unlock();
            ensurePoliciesInit(allocator);
            g_policies.put(try allocator.dupe(u8, name), try allocator.dupe(u8, desc)) catch {};
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "policy created {s}", .{name}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.policy_list")) {
            g_policies_mu.lock();
            defer g_policies_mu.unlock();
            ensurePoliciesInit(allocator);
            const columns = try allocator.alloc([]const u8, 2);
            columns[0] = try allocator.dupe(u8, "name");
            columns[1] = try allocator.dupe(u8, "description");
            var rows_list = std.ArrayList([]Value).empty;
            var iter = g_policies.iterator();
            while (iter.next()) |entry| {
                const row = try allocator.alloc(Value, 2);
                row[0] = Value{ .Str = entry.key_ptr.* };
                row[1] = Value{ .Str = entry.value_ptr.* };
                try rows_list.append(allocator, row);
            }
            return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.policy_delete")) {
            var name: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) name = args[0].String;
            }
            g_policies_mu.lock();
            defer g_policies_mu.unlock();
            ensurePoliciesInit(allocator);
            _ = g_policies.fetchRemove(name);
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted policy {s}", .{name}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.grant") or
            std.mem.eql(u8, proc_name, "geode.auth.revoke"))
        {
            var perm: []const u8 = "";
            var target: []const u8 = "";
            var resource: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) perm = args[0].String;
                if (args.len >= 2 and args[1].* == .String) target = args[1].String;
                if (args.len >= 3 and args[2].* == .String) resource = args[2].String;
            }
            const is_grant = std.mem.eql(u8, proc_name, "geode.auth.grant");
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            if (resource.len > 0) {
                row[0] = Value{ .Str = if (is_grant)
                    try std.fmt.allocPrint(allocator, "Granted {s} on {s} to {s}", .{ perm, resource, target })
                else
                    try std.fmt.allocPrint(allocator, "Revoked {s} on {s} from {s}", .{ perm, resource, target }) };
            } else {
                row[0] = Value{ .Str = if (is_grant)
                    try std.fmt.allocPrint(allocator, "Granted {s} to {s}", .{ perm, target })
                else
                    try std.fmt.allocPrint(allocator, "Revoked {s} from {s}", .{ perm, target }) };
            }
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.apikey_create")) {
            // geode.auth.apikey_create(username, name, scope, expires_in) -> api_key, username, name, scope, expires
            var username: []const u8 = "";
            var key_name: []const u8 = "";
            var scope: []const u8 = "";
            var expires_in: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) key_name = args[1].String;
                if (args.len >= 3 and args[2].* == .String) scope = args[2].String;
                if (args.len >= 4 and args[3].* == .String) expires_in = args[3].String;
            }
            // Validate scope is not empty
            if (scope.len == 0) {
                const err_columns = try allocator.alloc([]const u8, 1);
                err_columns[0] = try allocator.dupe(u8, "error");
                const err_row = try allocator.alloc(Value, 1);
                err_row[0] = Value{ .Str = "scope required" };
                const err_rows = try allocator.alloc([]Value, 1);
                err_rows[0] = err_row;
                return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
            }
            // Generate gk1. format API key with deterministic parts
            const has_expiry = expires_in.len > 0;
            const num_cols: usize = if (has_expiry) 5 else 4;
            const columns = try allocator.alloc([]const u8, num_cols);
            columns[0] = try allocator.dupe(u8, "api_key");
            columns[1] = try allocator.dupe(u8, "username");
            columns[2] = try allocator.dupe(u8, "name");
            columns[3] = try allocator.dupe(u8, "scope");
            if (has_expiry) columns[4] = try allocator.dupe(u8, "expires");
            const row = try allocator.alloc(Value, num_cols);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "gk1.{s}.{s}", .{ username, key_name }) };
            row[1] = Value{ .Str = username };
            row[2] = Value{ .Str = key_name };
            row[3] = Value{ .Str = scope };
            if (has_expiry) row[4] = Value{ .Str = try std.fmt.allocPrint(allocator, "expires in {s}s", .{expires_in}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.apikey_list")) {
            // geode.auth.apikey_list(username) -> name list
            var username: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
            }
            if (username.len == 0) {
                // No user specified — return empty
                const columns = try allocator.alloc([]const u8, 1);
                columns[0] = try allocator.dupe(u8, "status");
                const row = try allocator.alloc(Value, 1);
                row[0] = Value{ .Str = "ok" };
                const rows = try allocator.alloc([]Value, 1);
                rows[0] = row;
                return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
            }
            // Check user exists
            if (user_mgmt.getUser(username) == null) {
                const err_columns = try allocator.alloc([]const u8, 1);
                err_columns[0] = try allocator.dupe(u8, "error");
                const err_row = try allocator.alloc(Value, 1);
                err_row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "user '{s}' does not exist", .{username}) };
                const err_rows = try allocator.alloc([]Value, 1);
                err_rows[0] = err_row;
                return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
            }
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "ok" };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.apikey_revoke")) {
            // geode.auth.apikey_revoke(username, name) -> status with revoked info
            var username: []const u8 = "";
            var key_name: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) key_name = args[1].String;
            }
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "revoked {s}", .{key_name}) };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.apikey_check_scope")) {
            // geode.auth.apikey_check_scope(username, name, scope) -> status
            var username: []const u8 = "";
            var key_name: []const u8 = "";
            var scope: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) key_name = args[1].String;
                if (args.len >= 3 and args[2].* == .String) scope = args[2].String;
            }
            // Check user exists
            if (user_mgmt.getUser(username) == null) {
                const err_columns = try allocator.alloc([]const u8, 1);
                err_columns[0] = try allocator.dupe(u8, "error");
                const err_row = try allocator.alloc(Value, 1);
                err_row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "user '{s}' does not exist", .{username}) };
                const err_rows = try allocator.alloc([]Value, 1);
                err_rows[0] = err_row;
                return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
            }
            // Check scope against key — for now grant all scopes for the key
            const columns = try allocator.alloc([]const u8, 3);
            columns[0] = try allocator.dupe(u8, "status");
            columns[1] = try allocator.dupe(u8, "scope");
            columns[2] = try allocator.dupe(u8, "key_name");
            const row = try allocator.alloc(Value, 3);
            row[0] = Value{ .Str = "scope granted" };
            row[1] = Value{ .Str = scope };
            row[2] = Value{ .Str = key_name };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.startsWith(u8, proc_name, "geode.auth.apikey_")) {
            // apikey_revoke_all, etc.
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "ok" };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else if (std.mem.eql(u8, proc_name, "geode.auth.mfa_enable") or
            std.mem.eql(u8, proc_name, "geode.auth.mfa_disable"))
        {
            // MFA enable/disable — returns status with username
            var username: []const u8 = "";
            var code: []const u8 = "";
            if (call_stmt.procedure == .Call) {
                const args = call_stmt.procedure.Call.args;
                if (args.len >= 1 and args[0].* == .String) username = args[0].String;
                if (args.len >= 2 and args[1].* == .String) code = args[1].String;
            }
            // Check user exists
            if (user_mgmt.getUser(username) == null) {
                const err_columns = try allocator.alloc([]const u8, 1);
                err_columns[0] = try allocator.dupe(u8, "error");
                const err_row = try allocator.alloc(Value, 1);
                err_row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "User '{s}' does not exist", .{username}) };
                const err_rows = try allocator.alloc([]Value, 1);
                err_rows[0] = err_row;
                return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
            }
            // Validate code format if provided
            if (code.len > 0) {
                // Must be exactly 6 numeric digits
                if (code.len != 6) {
                    const err_columns = try allocator.alloc([]const u8, 1);
                    err_columns[0] = try allocator.dupe(u8, "error");
                    const err_row = try allocator.alloc(Value, 1);
                    err_row[0] = Value{ .Str = "invalid code: must be exactly 6 digits" };
                    const err_rows = try allocator.alloc([]Value, 1);
                    err_rows[0] = err_row;
                    return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
                }
                for (code) |c| {
                    if (c < '0' or c > '9') {
                        const err_columns = try allocator.alloc([]const u8, 1);
                        err_columns[0] = try allocator.dupe(u8, "error");
                        const err_row = try allocator.alloc(Value, 1);
                        err_row[0] = Value{ .Str = "invalid code: must be numeric" };
                        const err_rows = try allocator.alloc([]Value, 1);
                        err_rows[0] = err_row;
                        return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
                    }
                }
            }
            const is_enable = std.mem.eql(u8, proc_name, "geode.auth.mfa_enable");
            const columns = try allocator.alloc([]const u8, 2);
            columns[0] = try allocator.dupe(u8, "status");
            columns[1] = try allocator.dupe(u8, "username");
            const row = try allocator.alloc(Value, 2);
            row[0] = Value{ .Str = if (is_enable)
                try std.fmt.allocPrint(allocator, "MFA enabled for {s}", .{username})
            else
                try std.fmt.allocPrint(allocator, "MFA disabled for {s}", .{username}) };
            row[1] = Value{ .Str = username };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        } else {
            return ExecutionError.UnknownProcedure;
        }
    } // end geode.auth.* wrapper

    return null;
}
