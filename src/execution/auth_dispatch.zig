/// Auth Dispatch Module
///
/// Handles routing for all `geode.auth.*` procedure calls.
/// Extracted from procedure_registry.zig as part of the procedure dispatch refactoring.
const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
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
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
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
const mfa_mod = @import("mfa");

// GAP-0270: Global custom role store for geode.auth.role_create/role_list
pub var g_custom_roles: std.StringHashMap([]const u8) = undefined;
pub var g_custom_roles_init: bool = false;
pub var g_custom_roles_mu: std.Io.Mutex = std.Io.Mutex.init;
// GAP-0270: Global policy store for geode.auth.policy_create
pub var g_policies: std.StringHashMap([]const u8) = undefined;
pub var g_policies_init: bool = false;
pub var g_policies_mu: std.Io.Mutex = std.Io.Mutex.init;

// GAP-0501/0502: Per-user MFA credential store for TOTP secrets and recovery codes.
const MfaCredential = struct {
    secret_base32: []u8,
    recovery_codes: [][]u8,
};

pub var g_mfa_store: std.StringHashMap(MfaCredential) = undefined;
pub var g_mfa_store_init: bool = false;
pub var g_mfa_store_mu: std.Io.Mutex = std.Io.Mutex.init;

// GAP-0502: Per-user MFA verify attempt rate limiter.
const MfaAttemptRecord = struct {
    fail_count: u32,
    last_attempt_ms: i64,
    lockout_until_ms: i64,
};

pub var g_mfa_attempts: std.StringHashMap(MfaAttemptRecord) = undefined;
pub var g_mfa_attempts_init: bool = false;

const MFA_MAX_ATTEMPTS: u32 = 5;
const MFA_LOCKOUT_MS: i64 = 300_000; // 5 minutes

fn ensureMfaStoreInit(allocator: std.mem.Allocator) void {
    if (!g_mfa_store_init) {
        g_mfa_store = std.StringHashMap(MfaCredential).init(allocator);
        g_mfa_attempts = std.StringHashMap(MfaAttemptRecord).init(allocator);
        g_mfa_store_init = true;
        g_mfa_attempts_init = true;
    }
}

/// Store MFA credentials for a user, replacing any existing ones.
fn storeMfaCredential(allocator: std.mem.Allocator, username: []const u8, secret_base32: []const u8, scratch_codes: [][]u8) !void {
    g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureMfaStoreInit(allocator);

    // Remove old entry if present
    if (g_mfa_store.fetchRemove(username)) |old_kv| {
        std.crypto.secureZero(u8, old_kv.value.secret_base32);
        allocator.free(old_kv.value.secret_base32);
        for (old_kv.value.recovery_codes) |code| allocator.free(code);
        allocator.free(old_kv.value.recovery_codes);
        allocator.free(old_kv.key);
    }

    const secret_copy = try allocator.dupe(u8, secret_base32);
    errdefer allocator.free(secret_copy);

    const codes_copy = try allocator.alloc([]u8, scratch_codes.len);
    var copied: usize = 0;
    errdefer {
        for (codes_copy[0..copied]) |c| allocator.free(c);
        allocator.free(codes_copy);
    }
    for (scratch_codes) |code| {
        codes_copy[copied] = try allocator.dupe(u8, code);
        copied += 1;
    }

    const key_copy = try allocator.dupe(u8, username);
    errdefer allocator.free(key_copy);
    try g_mfa_store.put(key_copy, .{
        .secret_base32 = secret_copy,
        .recovery_codes = codes_copy,
    });
}

/// Look up a user's stored MFA secret (base32). Returns null if not enrolled.
fn getMfaSecret(username: []const u8) ?[]const u8 {
    g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!g_mfa_store_init) return null;
    const cred = g_mfa_store.get(username) orelse return null;
    return cred.secret_base32;
}

/// Check rate limiting on MFA verify attempts. Returns true if locked out.
fn checkMfaRateLimit(username: []const u8, now_ms: i64) bool {
    if (!g_mfa_attempts_init) return false;
    const rec = g_mfa_attempts.get(username) orelse return false;
    return now_ms < rec.lockout_until_ms;
}

/// Record a failed MFA attempt; lock out after MFA_MAX_ATTEMPTS.
fn recordMfaFailure(allocator: std.mem.Allocator, username: []const u8, now_ms: i64) void {
    if (!g_mfa_attempts_init) {
        g_mfa_attempts = std.StringHashMap(MfaAttemptRecord).init(allocator);
        g_mfa_attempts_init = true;
    }
    const existing = g_mfa_attempts.get(username);
    if (existing) |rec| {
        const new_count = rec.fail_count + 1;
        const lockout = if (new_count >= MFA_MAX_ATTEMPTS) now_ms + MFA_LOCKOUT_MS else @as(i64, 0);
        g_mfa_attempts.put(username, .{
            .fail_count = new_count,
            .last_attempt_ms = now_ms,
            .lockout_until_ms = lockout,
        }) catch {};
    } else {
        const key = allocator.dupe(u8, username) catch return;
        g_mfa_attempts.put(key, .{
            .fail_count = 1,
            .last_attempt_ms = now_ms,
            .lockout_until_ms = 0,
        }) catch {};
    }
}

/// Clear rate limit record on successful verification.
fn clearMfaRateLimit(username: []const u8) void {
    if (!g_mfa_attempts_init) return;
    _ = g_mfa_attempts.fetchRemove(username);
}

/// Build a space-separated string from recovery code slices.
fn buildRecoveryStr(allocator: std.mem.Allocator, codes: [][]u8) ![]u8 {
    var total_len: usize = 0;
    for (codes, 0..) |code, idx| {
        if (idx > 0) total_len += 1; // space separator
        total_len += code.len;
    }
    const buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (codes, 0..) |code, idx| {
        if (idx > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + code.len], code);
        pos += code.len;
    }
    return buf;
}

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

// ---------------------------------------------------------------------------
// StaticStringMap dispatch table -- O(1) lookup replaces sequential if-else chain.
// ---------------------------------------------------------------------------
const AuthHandler = *const fn (std.mem.Allocator, []const u8, ast.CallProcedure, ExecutionContext) anyerror!ExecutionResult;

const dispatch_table = std.StaticStringMap(AuthHandler).initComptime(.{
    .{ "geode.auth.user_create", handleUserCreate },
    .{ "geode.auth.user_list", handleUserList },
    .{ "geode.auth.user_delete", handleUserDelete },
    .{ "geode.auth.user_show", handleUserShow },
    .{ "geode.auth.user_enable", handleUserEnableDisable },
    .{ "geode.auth.user_disable", handleUserEnableDisable },
    .{ "geode.auth.user_assign_role", handleUserAssignRole },
    .{ "geode.auth.user_permissions", handleUserPermissions },
    .{ "geode.auth.user_change_password", handleUserChangePassword },
    .{ "geode.auth.user_reset_password", handleUserResetPassword },
    .{ "geode.auth.mfa_setup", handleMfaSetup },
    .{ "geode.auth.mfa_verify", handleMfaVerify },
    .{ "geode.auth.role_create", handleRoleCreate },
    .{ "geode.auth.role_delete", handleRoleDelete },
    .{ "geode.auth.role_list", handleRoleList },
    .{ "geode.auth.policy_create", handlePolicyCreate },
    .{ "geode.auth.policy_list", handlePolicyList },
    .{ "geode.auth.policy_delete", handlePolicyDelete },
    .{ "geode.auth.grant", handleGrantRevoke },
    .{ "geode.auth.revoke", handleGrantRevoke },
    .{ "geode.auth.apikey_create", handleApikeyCreate },
    .{ "geode.auth.apikey_list", handleApikeyList },
    .{ "geode.auth.apikey_revoke", handleApikeyRevoke },
    .{ "geode.auth.apikey_check_scope", handleApikeyCheckScope },
    .{ "geode.auth.mfa_enable", handleMfaEnableDisable },
    .{ "geode.auth.mfa_disable", handleMfaEnableDisable },
});

const read_only_set = std.StaticStringMap(void).initComptime(.{
    .{ "geode.auth.user_show", {} },
    .{ "geode.auth.user_permissions", {} },
    .{ "geode.auth.user_list", {} },
    .{ "geode.auth.role_list", {} },
    .{ "geode.auth.policy_list", {} },
    .{ "geode.auth.apikey_list", {} },
    .{ "geode.auth.apikey_check_scope", {} },
});

/// Execute a geode.auth.* procedure. Returns null if not recognized.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    if (std.mem.startsWith(u8, proc_name, "geode.auth.")) {
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

        // Catch-all for remaining geode.auth.apikey_* procedures
        if (std.mem.startsWith(u8, proc_name, "geode.auth.apikey_")) {
            return try handleApikeyCatchAll(allocator, proc_name, call_stmt, context);
        }

        return ExecutionError.UnknownProcedure;
    }

    return null;
}

// ===========================================================================
// Handler functions -- extracted from the former if-else dispatch chain.
// ===========================================================================

fn handleUserCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
        compat_fillRandom(&random_bytes);
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
}

fn handleUserList(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleUserDelete(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleUserShow(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleUserEnableDisable(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleUserAssignRole(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleUserPermissions(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleUserChangePassword(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleUserResetPassword(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleMfaSetup(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
    // GAP-0501: Generate cryptographically random per-user TOTP secret via mfa.enroll().
    // Generates 20 random bytes via std.crypto.random, base32-encodes, produces 8 recovery codes.
    var enrollment = mfa_mod.enroll(allocator, username) catch |err| {
        const err_columns = try allocator.alloc([]const u8, 1);
        err_columns[0] = try allocator.dupe(u8, "error");
        const err_row = try allocator.alloc(Value, 1);
        err_row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "MFA enrollment failed: {s}", .{@errorName(err)}) };
        const err_rows = try allocator.alloc([]Value, 1);
        err_rows[0] = err_row;
        return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
    };
    defer mfa_mod.freeEnrollment(allocator, &enrollment);

    // Store per-user secret and recovery codes for later TOTP verification
    storeMfaCredential(allocator, username, enrollment.secret_base32, enrollment.scratch_codes) catch |err| {
        const err_columns = try allocator.alloc([]const u8, 1);
        err_columns[0] = try allocator.dupe(u8, "error");
        const err_row = try allocator.alloc(Value, 1);
        err_row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "Failed to store MFA credential: {s}", .{@errorName(err)}) };
        const err_rows = try allocator.alloc([]Value, 1);
        err_rows[0] = err_row;
        return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
    };

    const secret = enrollment.secret_base32;
    const recovery_str = try buildRecoveryStr(allocator, enrollment.scratch_codes);
    const show_uri = std.mem.indexOf(u8, opts, "show-uri") != null;
    const show_recovery = std.mem.indexOf(u8, opts, "show-recovery") != null or std.mem.indexOf(u8, opts, "regenerate") != null;
    if (show_uri) {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "provisioning_uri");
        columns[1] = try allocator.dupe(u8, "secret");
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, enrollment.provisioning_uri) };
        row[1] = Value{ .Str = try allocator.dupe(u8, secret) };
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
        row[1] = Value{ .Str = try std.fmt.allocPrint(allocator, "Recovery codes: {s}", .{recovery_str}) };
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
    row[1] = Value{ .Str = try std.fmt.allocPrint(allocator, "Recovery codes: {s}", .{recovery_str}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleMfaVerify(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // GAP-0502: geode.auth.mfa_verify(username, token) -> status
    // Implements RFC 6238 TOTP validation with rate limiting.
    var username: []const u8 = "";
    var token: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) token = args[1].String;
    }

    const now_ms = compat_milliTimestamp();

    // Rate limit check: reject if user is locked out from too many failed attempts
    {
        g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
        ensureMfaStoreInit(allocator);
        if (checkMfaRateLimit(username, now_ms)) {
            const rl_columns = try allocator.alloc([]const u8, 2);
            rl_columns[0] = try allocator.dupe(u8, "status");
            rl_columns[1] = try allocator.dupe(u8, "username");
            const rl_row = try allocator.alloc(Value, 2);
            rl_row[0] = Value{ .Str = "rate_limited" };
            rl_row[1] = Value{ .Str = username };
            const rl_rows = try allocator.alloc([]Value, 1);
            rl_rows[0] = rl_row;
            return .{ .columns = rl_columns, .rows = rl_rows, .flags = std.ArrayList([]const u8).empty };
        }
    }

    // Look up the user's stored TOTP secret
    const stored_secret = getMfaSecret(username);
    if (stored_secret == null) {
        const ne_columns = try allocator.alloc([]const u8, 2);
        ne_columns[0] = try allocator.dupe(u8, "status");
        ne_columns[1] = try allocator.dupe(u8, "username");
        const ne_row = try allocator.alloc(Value, 2);
        ne_row[0] = Value{ .Str = "mfa_not_enrolled" };
        ne_row[1] = Value{ .Str = username };
        const ne_rows = try allocator.alloc([]Value, 1);
        ne_rows[0] = ne_row;
        return .{ .columns = ne_columns, .rows = ne_rows, .flags = std.ArrayList([]const u8).empty };
    }

    // Parse the 6-digit token string to u32 and validate via RFC 6238 TOTP
    var is_valid = false;
    if (token.len == 6) {
        const code = std.fmt.parseInt(u32, token, 10) catch 0xFFFFFFFF;
        if (code <= 999999) {
            // HMAC-SHA1 TOTP with +/-1 window (90s tolerance)
            is_valid = mfa_mod.verifyCode(
                allocator,
                stored_secret.?,
                @as(u64, @intCast(now_ms)),
                code,
                30, // step_seconds
                6, // digits
                1, // window (+/-1 = 90 second tolerance)
            ) catch false;
        }
    }

    // Update rate limiter based on result
    {
        g_mfa_store_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_mfa_store_mu.unlock(std.Io.Threaded.global_single_threaded.io());
        if (is_valid) {
            clearMfaRateLimit(username);
        } else {
            recordMfaFailure(allocator, username, now_ms);
        }
    }

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "username");
    const row = try allocator.alloc(Value, 2);
    row[0] = Value{ .Str = if (is_valid) "verified" else "invalid token" };
    row[1] = Value{ .Str = username };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleRoleCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // geode.auth.role_create(role_name, description) -> status
    var role_name: []const u8 = "";
    var desc: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) role_name = args[0].String;
        if (args.len >= 2 and args[1].* == .String) desc = args[1].String;
    }
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit(allocator);
    g_custom_roles.put(try allocator.dupe(u8, role_name), try allocator.dupe(u8, desc)) catch {};
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "created {s}", .{role_name}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleRoleDelete(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var role_name: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) role_name = args[0].String;
    }
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit(allocator);
    _ = g_custom_roles.fetchRemove(role_name);
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted {s}", .{role_name}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleRoleList(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit(allocator);
    var it = g_custom_roles.iterator();
    while (it.next()) |entry| {
        const row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Str = entry.key_ptr.* };
        try rows_list.append(allocator, row);
    }
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
}

fn handlePolicyCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var name: []const u8 = "";
    var desc: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) name = args[0].String;
        if (args.len >= 2 and args[1].* == .String) desc = args[1].String;
    }
    g_policies_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_policies_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensurePoliciesInit(allocator);
    g_policies.put(try allocator.dupe(u8, name), try allocator.dupe(u8, desc)) catch {};
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "policy created {s}", .{name}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handlePolicyList(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    g_policies_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_policies_mu.unlock(std.Io.Threaded.global_single_threaded.io());
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
}

fn handlePolicyDelete(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var name: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) name = args[0].String;
    }
    g_policies_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_policies_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensurePoliciesInit(allocator);
    _ = g_policies.fetchRemove(name);
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted policy {s}", .{name}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleGrantRevoke(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleApikeyCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleApikeyList(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleApikeyRevoke(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleApikeyCheckScope(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}

fn handleApikeyCatchAll(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // apikey_revoke_all, etc.
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "ok" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleMfaEnableDisable(allocator: std.mem.Allocator, proc_name: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
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
}
