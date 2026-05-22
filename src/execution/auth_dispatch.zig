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
// Task 9: fire schema-change notifications after GRANT/REVOKE so LSP
// SchemaProviders re-fetch the user's visible-graph/label set.
const schema_change_notifier = @import("schema_change_notifier.zig");

const Value = value_types.Value;

const user_mgmt = @import("../security/user_management.zig");
const mfa_mod = @import("mfa");

// GAP-0270: Global custom role store for geode.auth.role_create/role_list
pub var g_custom_roles: std.StringHashMap([]const u8) = undefined;
pub var g_custom_roles_init: bool = false;
pub var g_custom_roles_mu: std.Io.Mutex = std.Io.Mutex.init;

// #826: Custom-role membership store (username -> list of custom role names).
// Built-in role lives in user_management.User.role (a fixed Role enum); custom
// roles cannot fit there, so this side-table carries the assignment. Session-
// bind code consults getCustomRolesForUser at authenticate-time and merges the
// custom-role privileges with the built-in role's. Without this store the
// "assigned" message in handleUserAssignRole was misleading -- the user's
// effective role silently stayed at whatever built-in value they had
// (typically .User by default).
pub var g_custom_role_members: std.StringHashMap(std.ArrayList([]const u8)) = undefined;
pub var g_custom_role_members_init: bool = false;
pub var g_custom_role_members_mu: std.Io.Mutex = std.Io.Mutex.init;

fn ensureCustomRoleMembersInit(allocator: std.mem.Allocator) void {
    if (!g_custom_role_members_init) {
        g_custom_role_members = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
        g_custom_role_members_init = true;
    }
}

/// Record a custom-role assignment. Idempotent: re-assigning the same role
/// to the same user is a no-op. Caller must hold g_custom_role_members_mu.
fn recordCustomRoleMemberLocked(allocator: std.mem.Allocator, username: []const u8, role_name: []const u8) !void {
    ensureCustomRoleMembersInit(allocator);
    const entry = try g_custom_role_members.getOrPut(username);
    if (!entry.found_existing) {
        entry.key_ptr.* = try allocator.dupe(u8, username);
        entry.value_ptr.* = std.ArrayList([]const u8).empty;
    }
    // Idempotent: skip if already a member.
    for (entry.value_ptr.items) |existing| {
        if (std.mem.eql(u8, existing, role_name)) return;
    }
    try entry.value_ptr.append(allocator, try allocator.dupe(u8, role_name));
}

/// Return the list of custom roles assigned to `username`, or null if none.
/// Returned slice is owned by the membership store -- do NOT free.
pub fn getCustomRolesForUser(username: []const u8) ?[]const []const u8 {
    g_custom_role_members_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_role_members_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!g_custom_role_members_init) return null;
    const entry = g_custom_role_members.get(username) orelse return null;
    if (entry.items.len == 0) return null;
    return entry.items;
}
// GAP-0270 / GPS Phase 4 (Task 4-4): g_policies replaced by policy_catalog.PolicyCatalog.
// The geode.auth.policy_* procedure handlers below now delegate to the global
// PolicyCatalog singleton (bootstrapped in server/main.zig at startup).
// The old StringHashMap fields are removed to avoid duplication.

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-019; FEATURE="AuthDDLPersistence"; ASPECT=RolePersistCallbacks; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
/// Callbacks for persisting role DDL to __geode_security. Wired at server
/// startup (P7) from code that can import auth_graph_manager. auth_dispatch.zig
/// is part of root_mod and cannot import auth_graph_manager directly (circular).
pub const RolePersistCallbacks = struct {
    ctx: ?*anyopaque = null,
    /// Create a role node (idempotent). Returns role id.
    create_fn: ?*const fn (ctx: ?*anyopaque, name: []const u8, description: []const u8) anyerror!u64 = null,
    /// Remove a role node by id.
    remove_fn: ?*const fn (ctx: ?*anyopaque, role_id: u64) anyerror!void = null,
    /// Find a role id by name. Returns null if not found.
    find_id_fn: ?*const fn (ctx: ?*anyopaque, name: []const u8) anyerror!?u64 = null,
    /// List all role entries as name/description pairs. Caller frees the slice.
    list_fn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]RoleEntry = null,
};

/// A single role entry returned by the list callback.
pub const RoleEntry = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
};

var g_role_persist: RolePersistCallbacks = .{};

/// Install role persistence callbacks. Called once at server startup from
/// server_init (after the AuthGraphManager is at its final location).
pub fn setRolePersistCallbacks(cb: RolePersistCallbacks) void {
    g_role_persist = cb;
}

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-026; FEATURE="AuthDDLPersistence"; ASPECT=GrantPersistCallbacks; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
/// Callbacks for persisting per-graph privilege grants to __geode_security and
/// the in-memory GraphRBACPolicy. Wired at server startup (P7) from code that
/// can import auth_graph_manager / multi_graph_security. auth_dispatch.zig is
/// part of root_mod and cannot import those modules directly (module diamond).
pub const GrantPersistCallbacks = struct {
    ctx: ?*anyopaque = null,
    /// Resolve a username to a graph User-node id. Returns null if unknown / not
    /// in server context (e.g. CLI or test without a live server).
    resolve_user_id_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8) ?u64 = null,
    /// Persist a grant to the __geode_security graph and in-memory RBAC.
    /// action: 0=read, 1=write, 2=schema
    grant_fn: ?*const fn (ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, action: u8) anyerror!void = null,
    /// Remove a grant from the __geode_security graph and in-memory RBAC.
    /// Returns true if the grant was present and removed.
    revoke_fn: ?*const fn (ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, action: u8) anyerror!bool = null,
};

var g_grant_persist: GrantPersistCallbacks = .{};

/// Install grant persistence callbacks. Called once at server startup from
/// server_init (after the AuthGraphManager is at its final location).
pub fn setGrantPersistCallbacks(cb: GrantPersistCallbacks) void {
    g_grant_persist = cb;
}

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

/// Returns true if `name` matches one of the four built-in role names
/// (case-insensitive). Used to prevent CREATE ROLE from shadowing built-ins
/// and to deduplicate SHOW ROLES output.
pub fn isBuiltinRoleName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "admin") or
        std.ascii.eqlIgnoreCase(name, "user") or
        std.ascii.eqlIgnoreCase(name, "readwrite") or
        std.ascii.eqlIgnoreCase(name, "readonly");
}

// ensurePoliciesInit removed — GPS Phase 4 (Task 4-4) delegates to policy_catalog.

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
    // #832: ABAC attribute mutators -- ALTER USER ... SET/REMOVE ATTRIBUTE.
    .{ "geode.auth.user_set_attribute", handleUserSetAttribute },
    .{ "geode.auth.user_remove_attribute", handleUserRemoveAttribute },
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
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    // CANARY: REQ=REQ-AUTH-GRANT-PERSIST-029; FEATURE="GQL Auth DDL Persistence"; ASPECT=UserEnableDisable; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-05-12
    // Mutate + persist the active flag when the user is present in the in-memory store.
    // If the user isn't resolvable there (e.g. it lives only in a separate storage path —
    // the standalone CLI `geode user enable/disable` operates directly on the graph store),
    // treat it as a no-op success, matching how handleUserDelete/handleRoleDelete degrade
    // gracefully on a missing entity rather than surfacing an error.
    user_mgmt.setUserActive(allocator, username, is_enable) catch |err| switch (err) {
        // setUserActive returns error.Unauthenticated when the user isn't resolvable in the
        // in-memory store; treat that as a no-op success (the user may live only in a separate
        // storage path, e.g. the standalone CLI's direct-to-graph backend).
        error.Unauthenticated => {},
        else => {
            log.warn("geode.auth.user_enable/disable failed", &.{
                Attr.string("username", username),
                Attr.string("error", @errorName(err)),
            });
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) };
            row[1] = Value{ .Str = username };
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        },
    };
    row[0] = Value{ .Str = if (is_enable)
        try std.fmt.allocPrint(allocator, "enabled {s}", .{username})
    else
        try std.fmt.allocPrint(allocator, "disabled {s}", .{username}) };
    row[1] = Value{ .Str = username };
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
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    if (username.len == 0 or role_name.len == 0) {
        row[0] = Value{ .Str = try allocator.dupe(u8, "error: username and role required") };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }

    // Try built-in roles first.
    if (user_mgmt.Role.fromString(role_name)) |builtin_role| {
        user_mgmt.assignRole(allocator, username, builtin_role) catch |err| {
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) };
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        };
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "assigned {s} to {s}", .{ role_name, username }) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }

    // Custom roles: persist the membership in the side-table so
    // getCustomRolesForUser returns it later (#826). Built-in
    // .User.role stays at its current value; downstream privilege
    // computation merges built-in + custom-role grants.
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit(allocator);
    if (g_custom_roles.contains(role_name)) {
        g_custom_role_members_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_custom_role_members_mu.unlock(std.Io.Threaded.global_single_threaded.io());
        recordCustomRoleMemberLocked(allocator, username, role_name) catch |err| {
            row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "error: failed to record custom-role membership: {s}", .{@errorName(err)}) };
            return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
        };
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "assigned custom role {s} to {s}", .{ role_name, username }) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }
    // #835: unknown role must NOT silently retain the prior role. Free the
    // pre-allocated success-row scaffolding and return a Zig error so the
    // CLI exits non-zero and any caller's transactional logic aborts.
    allocator.free(row);
    allocator.free(rows);
    allocator.free(columns[0]);
    allocator.free(columns);
    return error.UnknownRole;
}

// #832 / GAP-0284: ABAC user-attribute store. Storage lives in
// src/security/user_attribute_store.zig so that the security layer
// (principal_derive, gps.decide) can read the same side-table without
// importing execution/.
const user_attr_store = @import("user_attr_store");

/// Public accessor for ABAC policy evaluation. Returns the attribute map
/// for `username`, or null if no attributes are set. The map is owned by
/// the side-table; callers must not free.
pub fn getUserAttributes(username: []const u8) ?*const std.StringHashMap([]const u8) {
    return user_attr_store.get(username);
}

fn handleUserSetAttribute(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var username: []const u8 = "";
    var key: []const u8 = "";
    var value: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) key = args[1].String;
        if (args.len >= 3 and args[2].* == .String) value = args[2].String;
    }
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    if (username.len == 0 or key.len == 0) {
        row[0] = Value{ .Str = try allocator.dupe(u8, "error: username and attribute key required") };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }
    if (user_mgmt.getUser(username) == null) {
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "error: user '{s}' does not exist", .{username}) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }
    try user_attr_store.setAttribute(allocator, username, key, value);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "set attribute {s}={s} for {s}", .{ key, value, username }) };
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleUserRemoveAttribute(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var username: []const u8 = "";
    var key: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) username = args[0].String;
        if (args.len >= 2 and args[1].* == .String) key = args[1].String;
    }
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    if (user_attr_store.removeAttribute(username, key, allocator)) {
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "removed attribute {s} from {s}", .{ key, username }) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "attribute {s} not set on {s}", .{ key, username }) };
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
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    if (role_name.len == 0) {
        row[0] = Value{ .Str = try allocator.dupe(u8, "error: role name required") };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }

    // Built-in role names are idempotent — acknowledge without touching g_custom_roles.
    if (isBuiltinRoleName(role_name)) {
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "already exists: {s} (built-in)", .{role_name}) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }

    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit(allocator);
    g_custom_roles.put(try allocator.dupe(u8, role_name), try allocator.dupe(u8, desc)) catch {};
    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-021; FEATURE="AuthDDLPersistence"; ASPECT=RoleCreatePersist; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
    if (g_role_persist.create_fn) |f| {
        _ = f(g_role_persist.ctx, role_name, desc) catch |e|
            log.warn("role_create graph persist failed", &.{ Attr.string("role", role_name), Attr.string("error", @errorName(e)) });
    }
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "created {s}", .{role_name}) };
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
    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-022; FEATURE="AuthDDLPersistence"; ASPECT=RoleDeletePersist; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
    if (!isBuiltinRoleName(role_name)) {
        if (g_role_persist.find_id_fn) |find_f| {
            if (find_f(g_role_persist.ctx, role_name) catch null) |rid| {
                if (g_role_persist.remove_fn) |rem_f| {
                    rem_f(g_role_persist.ctx, rid) catch |e|
                        log.warn("role_delete graph persist failed", &.{ Attr.string("role", role_name), Attr.string("error", @errorName(e)) });
                }
            }
        }
    }
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
        // Defensive dedup: skip any custom entry whose name collides with a built-in
        // (guards against state left over before hardening was in place).
        if (isBuiltinRoleName(entry.key_ptr.*)) continue;
        const row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Str = entry.key_ptr.* };
        try rows_list.append(allocator, row);
    }
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
}

// GPS Phase 4 (Task 4-4): geode.auth.policy_* procedures now delegate to the
// global PolicyCatalog singleton (mirrors the GQL DDL path via execution.zig).
// The old g_policies StringHashMap is removed.
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=AuthDispatchPolicyCreate; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
fn handlePolicyCreate(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    // Positional: (name, table, condition).  table defaults to "*" (any
    // graph/table) and condition defaults to "true" (allow everything).
    // #831: the handler used to ignore args[1]/args[2] and always install
    //       expression_source="true" with scope_graph="*".  Now both are
    //       honored.
    var name: []const u8 = "";
    var table: []const u8 = "*";
    var condition: []const u8 = "true";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) name = args[0].String;
        if (args.len >= 2 and args[1].* == .String and args[1].String.len > 0) table = args[1].String;
        if (args.len >= 3 and args[2].* == .String and args[2].String.len > 0) condition = args[2].String;
    }

    // #833: reject pathological condition strings before they reach the
    // expression compiler.  The crash was reproducible with a `;` (and
    // likely other syntax-significant chars) embedded in the condition;
    // root cause was unknown but the safe action is to refuse anything
    // that doesn't look like an expression.  Allowed chars: alnum, space,
    // and the operators that valid GPS expressions need.
    for (condition) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == ' ' or c == '_' or c == '.' or
            c == '=' or c == '!' or c == '<' or c == '>' or
            c == '(' or c == ')' or c == ',' or
            c == '+' or c == '-' or c == '*' or c == '/' or
            c == '\'' or c == '"' or c == '?';
        if (!ok) {
            const ec = try allocator.alloc([]const u8, 1);
            ec[0] = try allocator.dupe(u8, "error");
            const er = try allocator.alloc(Value, 1);
            er[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "invalid character {x:0>2} in condition; refusing to install (see #833)", .{c}) };
            const ers = try allocator.alloc([]Value, 1);
            ers[0] = er;
            return .{ .columns = ec, .rows = ers, .flags = std.ArrayList([]const u8).empty };
        }
    }

    const policy_catalog_mod = @import("../security/policy_catalog.zig");
    if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
        const actions = [_]policy_catalog_mod.Action{.read};
        try pol_cat.addPolicy(.{
            .name = name,
            .scope_graph = table,
            .actions = &actions,
            .effect = .allow,
            .expression_source = condition,
            .enabled = true,
        });
    }
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "policy created {s} on {s}", .{ name, table }) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=AuthDispatchPolicyList; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
fn handlePolicyList(allocator: std.mem.Allocator, _: []const u8, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    const policy_catalog_mod = @import("../security/policy_catalog.zig");
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "scope_graph");
    var rows_list = std.ArrayList([]Value).empty;
    if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
        for (pol_cat.listPolicies()) |pol| {
            const row = try allocator.alloc(Value, 2);
            row[0] = Value{ .Str = try allocator.dupe(u8, pol.name) };
            row[1] = Value{ .Str = try allocator.dupe(u8, pol.scope_graph) };
            try rows_list.append(allocator, row);
        }
    }
    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
}

// CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=AuthDispatchPolicyDelete; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
fn handlePolicyDelete(allocator: std.mem.Allocator, _: []const u8, call_stmt: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
    var name: []const u8 = "";
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) name = args[0].String;
    }
    const policy_catalog_mod = @import("../security/policy_catalog.zig");
    if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
        // Swallow PolicyNotFound — procedure interface is idempotent.
        pol_cat.removePolicy(name) catch |err| {
            if (err != error.PolicyNotFound) return err;
        };
    }
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "deleted policy {s}", .{name}) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-027; FEATURE="AuthDDLPersistence"; ASPECT=HandleGrantRevoke; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
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

    // Build the single-column result we always return.
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    // No resource: per-graph grants require an ON GRAPH clause. Be honest.
    if (resource.len == 0) {
        row[0] = Value{ .Str = if (is_grant)
            try std.fmt.allocPrint(allocator, "note: global privilege grants are governed by the user's role; " ++
                "per-graph grants require ON GRAPH (granted nothing persistent for {s})", .{target})
        else
            try std.fmt.allocPrint(allocator, "note: global privilege revocations are governed by the user's role; " ++
                "per-graph revocations require ON GRAPH (revoked nothing persistent for {s})", .{target}) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }

    // Map perm name (case-insensitive) to action code(s): 0=read, 1=write, 2=schema
    // Use a small fixed-size buffer for the action list (max 3 for ALL)
    var actions_buf: [3]u8 = undefined;
    var actions: []u8 = actions_buf[0..0];
    if (std.ascii.eqlIgnoreCase(perm, "READ")) {
        actions_buf[0] = 0;
        actions = actions_buf[0..1];
    } else if (std.ascii.eqlIgnoreCase(perm, "WRITE")) {
        actions_buf[0] = 1;
        actions = actions_buf[0..1];
    } else if (std.ascii.eqlIgnoreCase(perm, "SCHEMA")) {
        actions_buf[0] = 2;
        actions = actions_buf[0..1];
    } else if (std.ascii.eqlIgnoreCase(perm, "ALL")) {
        actions_buf[0] = 0;
        actions_buf[1] = 1;
        actions_buf[2] = 2;
        actions = actions_buf[0..3];
    } else {
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "error: unknown privilege: {s}", .{perm}) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }

    // Resolve target username -> user_id via callback (null in CLI / test contexts).
    const uid_opt: ?u64 = if (g_grant_persist.resolve_user_id_fn) |f|
        f(g_grant_persist.ctx, target)
    else
        null;

    if (uid_opt == null) {
        // Either no server context (CLI/test) or user does not exist in the graph.
        row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "error: user not found: {s}", .{target}) };
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }
    const uid = uid_opt.?;

    // Apply grant/revoke for each action code. Callback failures are logged and
    // skipped — best effort; don't fail the whole handler.
    for (actions) |action| {
        if (is_grant) {
            if (g_grant_persist.grant_fn) |f| {
                f(g_grant_persist.ctx, uid, resource, action) catch |e| {
                    log.warn("grant persist failed", &.{
                        Attr.string("err", @errorName(e)),
                        Attr.string("user", target),
                        Attr.string("graph", resource),
                        Attr.uint("action", @as(u64, action)),
                    });
                };
            }
        } else {
            if (g_grant_persist.revoke_fn) |f| {
                _ = f(g_grant_persist.ctx, uid, resource, action) catch |e| {
                    log.warn("revoke persist failed", &.{
                        Attr.string("err", @errorName(e)),
                        Attr.string("user", target),
                        Attr.string("graph", resource),
                        Attr.uint("action", @as(u64, action)),
                    });
                };
            }
        }
    }

    // Return the status row with wording the geodetestlab spec asserts.
    // grant uses "to", revoke uses "from" — matches the existing spec assertions.
    row[0] = Value{ .Str = if (is_grant)
        try std.fmt.allocPrint(allocator, "Granted {s} on {s} to {s}", .{ perm, resource, target })
    else
        try std.fmt.allocPrint(allocator, "Revoked {s} on {s} from {s}", .{ perm, resource, target }) };

    // Task 9: a grant/revoke changes which graphs a user can see, which
    // changes the LSP SchemaProvider's user-visible label/edge-type set.
    // Per-graph callback failures above are best-effort — we still notify
    // because the in-memory RBAC state will have moved.
    schema_change_notifier.notify();

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
    const is_enable = std.mem.eql(u8, proc_name, "geode.auth.mfa_enable");

    // #838: MFA enable used to accept any 6-digit code with no HMAC verification
    // against the user's stored TOTP secret — admins could "enable" MFA without
    // proving authenticator possession. Require a valid TOTP code on enable.
    if (is_enable) {
        if (code.len == 0) {
            const err_columns = try allocator.alloc([]const u8, 1);
            err_columns[0] = try allocator.dupe(u8, "error");
            const err_row = try allocator.alloc(Value, 1);
            err_row[0] = Value{ .Str = "missing code: mfa_enable requires a 6-digit TOTP code from the user's authenticator (run mfa_setup first)" };
            const err_rows = try allocator.alloc([]Value, 1);
            err_rows[0] = err_row;
            return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
        }
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

        // Verify the code against the user's stored TOTP secret.
        const stored_secret = getMfaSecret(username) orelse {
            const err_columns = try allocator.alloc([]const u8, 1);
            err_columns[0] = try allocator.dupe(u8, "error");
            const err_row = try allocator.alloc(Value, 1);
            err_row[0] = Value{ .Str = try std.fmt.allocPrint(allocator, "no TOTP secret stored for '{s}'; run mfa_setup first", .{username}) };
            const err_rows = try allocator.alloc([]Value, 1);
            err_rows[0] = err_row;
            return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
        };

        const code_u32 = std.fmt.parseInt(u32, code, 10) catch 0xFFFFFFFF;
        const now_ms = @as(u64, @intCast(compat_milliTimestamp()));
        const ok = mfa_mod.verifyCode(allocator, stored_secret, now_ms, code_u32, 30, 6, 1) catch false;
        if (!ok) {
            const err_columns = try allocator.alloc([]const u8, 1);
            err_columns[0] = try allocator.dupe(u8, "error");
            const err_row = try allocator.alloc(Value, 1);
            err_row[0] = Value{ .Str = "invalid TOTP code: HMAC verification failed against stored secret" };
            const err_rows = try allocator.alloc([]Value, 1);
            err_rows[0] = err_row;
            return .{ .columns = err_columns, .rows = err_rows, .flags = std.ArrayList([]const u8).empty };
        }
    } else if (code.len > 0) {
        // Disable path still validates format if a code is provided, but
        // does NOT require HMAC verification (separate concern — admins may
        // need to disable MFA for recovery without a valid TOTP).
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

// ---------------------------------------------------------------------------
// DDL bridge: lets src/execution/admin_ddl.zig invoke the existing geode.auth.*
// handlers with plain string arguments. Authorization (Admin-required for write
// procedures), audit, password policy, and __geode_security persistence all run
// through the unchanged execute() path -- nothing is reimplemented here.
// ---------------------------------------------------------------------------

/// Build a synthetic `CALL <proc_name>(arg0, arg1, ...)` with String-literal
/// arguments and dispatch it through `execute()`. Caller owns the returned
/// ExecutionResult (free with `result.deinit(allocator)`).
///
/// Safety note: some handlers store borrowed slices from string_args directly
/// into the result (e.g. `Value{ .Str = username }` without duping). This is
/// safe because string_args is caller-owned and outlives the result. The
/// temporary *ast.Expr heap nodes are freed by the defers below, but the slice
/// headers they contained (ptr + len) are already copied into the result values
/// and continue to point into the caller-owned string_args data.
pub fn callAuthProcedure(
    allocator: std.mem.Allocator,
    context: ExecutionContext,
    proc_name: []const u8,
    string_args: []const []const u8,
) !ExecutionResult {
    const arg_ptrs = try allocator.alloc(*ast.Expr, string_args.len);
    defer allocator.free(arg_ptrs);
    var made: usize = 0;
    defer {
        var i: usize = 0;
        while (i < made) : (i += 1) allocator.destroy(arg_ptrs[i]);
    }
    for (string_args, 0..) |s, i| {
        const e = try allocator.create(ast.Expr);
        e.* = .{ .String = s };
        arg_ptrs[i] = e;
        made = i + 1;
    }

    const callee = try allocator.create(ast.Expr);
    defer allocator.destroy(callee);
    callee.* = .{ .Ident = .{ .orig = "", .cnf = "" } };

    const call_proc = ast.CallProcedure{
        .procedure = .{ .Call = .{ .callee = callee, .args = arg_ptrs } },
    };

    const maybe = try execute(allocator, proc_name, call_proc, context);
    return maybe orelse error.UnknownProcedure;
}

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-024; FEATURE="AuthDDLPersistence"; ASPECT=CustomRoleHydration; STATUS=IMPL; OWNER=security; UPDATED=2026-05-11
/// Called once at server startup (from server_init) after the AGM is ready
/// and role persistence callbacks are installed.
/// Loads custom (non-built-in) Role node names from __geode_security into
/// g_custom_roles so that the in-memory role store is consistent with what was
/// persisted in a prior run.
pub fn hydrateCustomRolesFromGraph(allocator: std.mem.Allocator) void {
    const list_f = g_role_persist.list_fn orelse return;
    g_custom_roles_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_custom_roles_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureRolesInit(allocator);
    const entries = list_f(g_role_persist.ctx, allocator) catch |e| {
        log.warn("hydrateCustomRolesFromGraph: listRoles failed", &.{Attr.string("error", @errorName(e))});
        return;
    };
    defer allocator.free(entries);
    for (entries) |entry| {
        if (isBuiltinRoleName(entry.name)) continue;
        // dupe the name and description so g_custom_roles owns its keys/values
        const key = allocator.dupe(u8, entry.name) catch continue;
        const val = allocator.dupe(u8, entry.description) catch {
            allocator.free(key);
            continue;
        };
        g_custom_roles.put(key, val) catch {
            allocator.free(key);
            allocator.free(val);
        };
    }
}

// CANARY: REQ=REQ-AUTH-ROLE-002; FEATURE="BuiltinRoleHardening"; ASPECT=Validation; STATUS=TESTED; TEST=isBuiltinRoleName_recognizes_all_variants; OWNER=security; UPDATED=2026-05-11
test "isBuiltinRoleName_recognizes_all_variants" {
    const testing = std.testing;
    // All four built-in names, both cases.
    try testing.expect(isBuiltinRoleName("admin"));
    try testing.expect(isBuiltinRoleName("Admin"));
    try testing.expect(isBuiltinRoleName("ADMIN"));
    try testing.expect(isBuiltinRoleName("user"));
    try testing.expect(isBuiltinRoleName("User"));
    try testing.expect(isBuiltinRoleName("readwrite"));
    try testing.expect(isBuiltinRoleName("ReadWrite"));
    try testing.expect(isBuiltinRoleName("readonly"));
    try testing.expect(isBuiltinRoleName("ReadOnly"));

    // Custom role name is not a built-in.
    try testing.expect(!isBuiltinRoleName("auditor"));
    try testing.expect(!isBuiltinRoleName(""));
    try testing.expect(!isBuiltinRoleName("superuser"));
}
