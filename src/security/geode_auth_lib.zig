// (Removed duplicated preamble section)
// CANARY: REQ=REQ-0005; FEATURE="Security Requirements"; ASPECT=Security; STATUS=IMPL; OWNER=security; UPDATED=2026-11-14
// Clean reconstructed auth.zig with consolidated definitions (RBAC, ABAC, RLS, Sessions, MFA Policies)
const std = @import("std");
const build_options = @import("build_options");
const crypto_backend = @import("crypto_backend");

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

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const ext_mfa = @import("auth_lib").mfa;
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;
const mfa_policy = @import("mfa_policy");
// Note: hash_module import will need to be configured via build.zig module system
// For now, use std.crypto.pwhash.argon2 directly

// ---- Core Aliases ----
pub const UserId = u64;
pub const RoleId = u64;
pub const PermissionId = u64;
pub const PolicyId = u64;

// ---- Entities ----
pub const Action = enum { create, read, update, delete, execute, grant, revoke, all };
pub const Resource = enum { graph, node, edge, property, index, user, role, permission, query, transaction, system };

// ---- MFA step-up operation classification (GAP-0884) ----
// Replaces the old substring heuristic (`"admin"`/`"write"` anywhere in the
// action string) with an explicit classification of REAL operation
// identifiers: dotted procedure names (the `CALL geode.*` dispatch names from
// src/execution/procedure_access.zig / auth_dispatch.zig / admin_ddl.zig /
// storage_dispatch.zig) and legacy snake_case session-action identifiers.
//
// Matching rules are exact names or ANCHORED namespace prefixes (the same
// convention procedure_registry.zig dispatches on, e.g. "geode.auth.") —
// never substring scans, so a read-only operation whose name merely contains
// "admin" is not misclassified.
//
// Fail-closed posture: an identifier that matches no rule classifies as
// `.write` — every class except `.read` requires step-up, so unknown
// operations always demand fresh MFA elevation.
// CANARY: REQ=REQ-SEC-MFA-STEPUP-CLASS-001; FEATURE="MFA step-up operation classification"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_gap0884_stepup_classification.zig; OWNER=security; UPDATED=2026-06-10
pub const OperationClass = enum { read, write, admin, security_admin };

/// Read-only procedure names (mirrors the read-only classification in
/// src/execution/procedure_access.zig for the security-relevant namespaces).
const stepup_read_operations = [_][]const u8{
    // FTS / time-series read procedures
    "geode.fts.search",
    "geode.ts.range",
    "geode.ts.last",
    "geode.ts.bucket_avg",
    "geode.ts.sample_by",
    // FLE metadata reads
    "geode.fle.getFieldConfig",
    "geode.fle.listEncryptedFields",
    // auth introspection (list/show only — every other geode.auth.* mutates)
    "geode.auth.user_list",
    "geode.auth.user_show",
    "geode.auth.user_permissions",
    "geode.auth.role_list",
    "geode.auth.policy_list",
    "geode.auth.apikey_list",
    "geode.auth.apikey_check_scope",
    // RLS introspection
    "geode.rls.list_deny_policies",
    "geode.rls.policy_count",
    // storage / catalog introspection
    "geode.storage.stats",
    "geode.storage.integrity",
    "db.labels",
    "db.relationshipTypes",
    "db.propertyKeys",
    "db.indexes",
    "db.constraints",
    "dbms.procedures",
    "dbms.functions",
};

/// Data-write procedure names (mutating but not privilege-changing).
///
/// Task 3 (geode-vectorization-and-reranking): `geode.fts.rebuild` drops and
/// rebuilds a fulltext engine — a write — and belongs HERE, not in
/// `stepup_read_operations` alongside `geode.fts.search`. Listing it
/// explicitly (rather than relying on the `classifyOperation` fail-closed
/// `.write` default for unknown identifiers) keeps the step-up posture
/// self-documenting, matching `geode.ts.insert` below.
// CANARY: REQ=REQ-FTS-REBUILD-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=StepUpClassification; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=index; UPDATED=2026-08-28
const stepup_write_operations = [_][]const u8{
    "geode.ts.insert",
    "geode.ts.insert_many",
    "geode.fts.rebuild",
};

/// Security-administration namespaces: auth DDL handlers, FLE catalog
/// mutation, RLS policy mutation, TDE/audit administration. Anchored
/// prefixes — the read-only exceptions are matched exactly above, first.
const stepup_security_admin_prefixes = [_][]const u8{
    "geode.auth.",
    "geode.fle.",
    "geode.rls.",
    "tde.",
    "audit.",
};

/// Legacy snake_case session-action identifier prefixes (anchored).
const stepup_admin_prefixes = [_][]const u8{ "admin_", "admin." };
const stepup_read_prefixes = [_][]const u8{ "read_", "show_", "list_" };

fn matchesAnyPrefix(op: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.ascii.startsWithIgnoreCase(op, p)) return true;
    }
    return false;
}

/// Classify a real operation identifier into an explicit OperationClass.
/// Unknown identifiers fail closed as `.write` (step-up required).
pub fn classifyOperation(operation: []const u8) OperationClass {
    // 1. Exact known-operation tables (case-insensitive, matching the
    //    case-insensitive procedure dispatch in procedure_access.zig).
    for (stepup_read_operations) |n| {
        if (std.ascii.eqlIgnoreCase(operation, n)) return .read;
    }
    for (stepup_write_operations) |n| {
        if (std.ascii.eqlIgnoreCase(operation, n)) return .write;
    }
    // 2. Anchored namespace / identifier-prefix rules (never substring).
    if (matchesAnyPrefix(operation, &stepup_security_admin_prefixes)) return .security_admin;
    if (matchesAnyPrefix(operation, &stepup_admin_prefixes)) return .admin;
    if (matchesAnyPrefix(operation, &stepup_read_prefixes)) return .read;
    // 3. Fail closed: unknown operations classify as write (=> step-up).
    return .write;
}

/// Step-up policy per class: only `.read` is exempt. `.write` keeps parity
/// with the pre-GAP-0884 intent (write-class actions stepped up) and makes
/// the unknown->write fallback fail-closed.
pub fn operationRequiresStepUp(class: OperationClass) bool {
    return switch (class) {
        .read => false,
        .write, .admin, .security_admin => true,
    };
}

pub const User = struct {
    id: UserId,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8, // Argon2id PHC string format
    created_at: i64,
    updated_at: i64,
    last_login: ?i64,
    is_active: bool,
    is_superuser: bool,
    mfa_enabled: bool,
    mfa_secret: ?[]const u8,
    // Single-use recovery codes (strings) consumed on successful use. Optional.
    recovery_codes: ?std.ArrayList([]const u8) = null,
    attributes: std.StringHashMap([]const u8),
    // CANARY: REQ=REQ-AUTH-POLICY-001; FEATURE="Password Reset Tracking"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_001_ForceReset; OWNER=security; UPDATED=2025-09-30
    password_reset_required: bool = false,
    auth_version: u64 = 1,
    is_default_user: bool = false,
    password_set_by_env: bool = false,
    // Rate limiting fields for brute force protection
    failed_login_attempts: u16 = 0,
    lockout_until: i64 = 0, // epoch millis; 0 = not locked
};

pub const Role = struct {
    id: RoleId,
    name: []const u8,
    description: []const u8,
    permissions: std.ArrayList(PermissionId),
    created_at: i64,
    is_system: bool,
    priority: u32,
    parent_role: ?RoleId,
};

pub const Permission = struct {
    id: PermissionId,
    name: []const u8,
    resource: []const u8,
    action: Action,
    conditions: ?[]const u8,
    created_at: i64,
};

// ---- RBAC ----
pub const RBACPolicy = struct {
    user_roles: std.AutoHashMap(UserId, std.ArrayList(RoleId)),
    role_permissions: std.AutoHashMap(RoleId, std.ArrayList(Permission)),
    role_hierarchy: std.AutoHashMap(RoleId, std.ArrayList(RoleId)),

    pub fn hasPermission(self: *RBACPolicy, user_id: UserId, resource: []const u8, action: Action) bool {
        const roles = self.user_roles.get(user_id) orelse return false;
        for (roles.items) |rid| if (self.checkRolePermission(rid, resource, action)) return true;
        return false;
    }
    fn checkRolePermission(self: *RBACPolicy, role_id: RoleId, resource: []const u8, action: Action) bool {
        if (self.role_permissions.get(role_id)) |perms| {
            for (perms.items) |perm| if (std.mem.eql(u8, perm.resource, resource) and (perm.action == action or perm.action == .all)) return true;
        }
        if (self.role_hierarchy.get(role_id)) |parents| for (parents.items) |p| if (self.checkRolePermission(p, resource, action)) return true;
        return false;
    }
};

// ---- ABAC ----
pub const Effect = enum { allow, deny };
pub const ComparisonOperator = enum { equals, not_equals, contains, not_contains, greater_than, less_than, in, not_in, matches };
pub const ConditionType = enum { time_range, ip_range, location, device_type, request_rate };
pub const AttributeCondition = struct { attribute: []const u8, operator: ComparisonOperator, value: std.json.Value };
pub const EnvironmentCondition = struct { type_: ConditionType, parameters: std.json.Value };
pub const ABACPolicy = struct {
    id: PolicyId,
    name: []const u8,
    description: []const u8,
    effect: Effect,
    subjects: []const AttributeCondition,
    resources: []const AttributeCondition,
    actions: []const Action,
    conditions: []const EnvironmentCondition,
    priority: u32,
    enabled: bool,
};

// ---- Row Level Security ----
pub const Operation = enum { select, insert, update, delete, all };
pub const RowLevelPolicy = struct { id: PolicyId, name: []const u8, table: []const u8, operation: Operation, using_clause: []const u8, check_clause: ?[]const u8, roles: []const RoleId, enabled: bool };

// ---- MFA Admin Policy ----
// CANARY: REQ=REQ-GQL-MFA-003; FEATURE="MFA admin policy"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mfa_policies.zig; OWNER=security; UPDATED=2026-11-12
pub const MfaScope = enum { user, role, attribute };
pub const MfaConditionType = enum {
    match_any_role,
    match_all_roles,
    user_attribute_equals,
    always,
    time_window, // active only within [time_start_minute, time_end_minute]
    risk_score_min, // requires user attribute "risk_score" >= risk_min_score
    reauth_interval_elapsed, // requires re-auth if last_mfa_ts older than reauth_interval_ms
};
pub const MfaAdminPolicy = struct {
    id: u64,
    enabled: bool = true,
    scope: MfaScope = .user,
    roles: []const RoleId = &[_]RoleId{},
    condition: MfaConditionType = .always,
    attribute_key: ?[]const u8 = null,
    attribute_value: ?[]const u8 = null,
    time_start_minute: ?u16 = null, // minutes since midnight UTC
    time_end_minute: ?u16 = null,
    risk_min_score: ?u8 = null,
    reauth_interval_ms: ?i64 = null,
};

// ---- Environment / Session / Password Policy ----
pub const EnvironmentInfo = struct { timestamp: i64, ip_address: []const u8, user_agent: []const u8, location: ?[]const u8, device_id: ?[]const u8 };
pub const Session = struct {
    token: []const u8,
    user_id: UserId,
    created_at: i64,
    expires_at: i64,
    ip_address: ?[]const u8,
    user_agent: ?[]const u8,
    // High-assurance / step-up metadata. Null when no recent MFA elevation.
    last_mfa_ts: ?i64, // timestamp of last successful MFA event applied to this session
    elevation_expires_at: ?i64, // boundary after which high-assurance privileges lapse
    // CANARY: REQ=REQ-GQL-MFA-007; FEATURE="Session step-up metadata"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-14
};
// CANARY: REQ=REQ-AUTH-POLICY-002; FEATURE="Enhanced Password Policy"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_002_PassphrasePolicy; OWNER=security; UPDATED=2025-09-30
pub const PasswordPolicy = struct {
    min_length: usize,
    max_length: usize,
    require_uppercase: bool,
    require_lowercase: bool,
    require_digit: bool,
    require_special: bool,
    allow_spaces: bool,
    require_passphrase: bool, // Enforce passphrase style (multiple words)
    min_words: usize, // Minimum number of words for passphrase
    max_age_days: u32,
    history_count: u32,

    pub fn default() PasswordPolicy {
        // CANARY: REQ=REQ-AUTH-POLICY-004; FEATURE="Unified Password Policy"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_004_UnifiedPolicy; OWNER=security; UPDATED=2025-09-30
        // All users now follow the same minimum security standard as admins
        return geodeSecure();
    }

    pub fn geodeSecure() PasswordPolicy {
        // CANARY: REQ=REQ-AUTH-CONFIG-001; FEATURE="Configurable Password Policy"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_CONFIG_001_ConfigurablePolicy; OWNER=security; UPDATED=2025-09-30
        // Zig 0.16: std.process.getEnvVarOwned removed; use std.c.getenv (no allocation)
        const min_length_env: ?[:0]const u8 = if (std.c.getenv("GEODE_PASSWORD_MIN_LENGTH")) |p| std.mem.span(p) else null;
        const min_length = if (min_length_env) |len_str| blk: {
            const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
            // Enforce absolute minimum of 20 characters for security
            break :blk if (parsed < 20) 20 else parsed;
        } else 20;

        const min_words_env: ?[:0]const u8 = if (std.c.getenv("GEODE_PASSWORD_MIN_WORDS")) |p| std.mem.span(p) else null;
        const min_words = if (min_words_env) |words_str| blk: {
            const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
            // Enforce minimum of 2 words
            break :blk if (parsed < 2) 2 else parsed;
        } else 3;

        // SONNY-6331: no limit above what a password can meet (256
        // characters hold at most 128 words); a larger setting meant no
        // password was accepted.
        return .{
            .min_length = @min(min_length, max_password_length),
            .max_length = max_password_length,
            .require_uppercase = true,
            .require_lowercase = true,
            .require_digit = false, // Optional for passphrases
            .require_special = false, // Optional for passphrases
            .allow_spaces = true,
            .require_passphrase = true,
            .min_words = @min(min_words, max_password_words),
            .max_age_days = 90,
            .history_count = 5,
        };
    }

    /// SONNY-6331: the rule a password broke.
    pub const Violation = enum {
        too_short,
        too_long,
        missing_uppercase,
        missing_lowercase,
        missing_digit,
        contains_spaces,
        too_few_words,
    };

    /// The error a refused password is answered with, one per rule
    /// (SQLSTATE 22000 on the wire, with `message` as its text).
    pub const PolicyError = error{
        PasswordTooShort,
        PasswordTooLong,
        PasswordMissingUppercase,
        PasswordMissingLowercase,
        PasswordMissingDigit,
        PasswordContainsSpaces,
        PasswordNotPassphrase,
    };

    // CANARY: REQ=REQ-AUTH-POLICY-005; FEATURE="Unified Password Policy Validation"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_bug731_password_policy.zig; OWNER=security; UPDATED=2026-07-31
    /// Validate a candidate password against this policy.
    ///
    /// Returns `null` when the password is acceptable, or a human-readable
    /// reason when it is not.
    ///
    /// This is the SINGLE source of truth for password strength. It used to
    /// be duplicated: the QUIC handler enforced this policy while the offline
    /// `geode user` CLI enforced a different, *mutually incompatible* one
    /// (>=8 chars, must contain a digit). The documented recovery passphrase
    /// `Correct horse battery staple` was rejected by the CLI for having no
    /// digit, while a CLI-valid `abc12345` was rejected by the server for
    /// being too short and not a passphrase. Every entry point now calls
    /// this. See docs/@BUGS_731.md bug 4.
    ///
    /// The message wording is deliberately stable — it is quoted verbatim in
    /// docs and in operator-facing error output. SONNY-6331: it names the
    /// configured limit (GEODE_PASSWORD_MIN_LENGTH / _MIN_WORDS), not the
    /// default, and never contains the password.
    pub fn validate(self: PasswordPolicy, password: []const u8) ?[]const u8 {
        const v = self.check(password) orelse return null;
        return self.message(v);
    }

    // CANARY: REQ=REQ-SONNY-6331-ONE-PASSWORD-POLICY; FEATURE="Unified Password Policy Validation"; ASPECT=PolicyCheck; STATUS=TESTED; TEST=tests/test_sonny6331_password_policy_paths.zig; OWNER=security; UPDATED=2026-11-12
    /// The first rule `password` breaks, or null when it meets the policy.
    pub fn check(self: PasswordPolicy, password: []const u8) ?Violation {
        if (password.len < self.min_length) return .too_short;
        if (password.len > self.max_length) return .too_long;
        if (self.require_uppercase and !containsWhere(password, std.ascii.isUpper)) return .missing_uppercase;
        if (self.require_lowercase and !containsWhere(password, std.ascii.isLower)) return .missing_lowercase;
        if (self.require_digit and !containsWhere(password, std.ascii.isDigit)) return .missing_digit;
        if (!self.allow_spaces and std.mem.indexOfScalar(u8, password, ' ') != null) return .contains_spaces;
        if (self.require_passphrase and countPassphraseWords(password) < self.min_words) return .too_few_words;
        return null;
    }

    /// `check` as an error (`PolicyError`), for the paths that set a password.
    pub fn enforce(self: PasswordPolicy, password: []const u8) PolicyError!void {
        const v = self.check(password) orelse return;
        return errorOf(v);
    }

    pub fn errorOf(v: Violation) PolicyError {
        return switch (v) {
            .too_short => error.PasswordTooShort,
            .too_long => error.PasswordTooLong,
            .missing_uppercase => error.PasswordMissingUppercase,
            .missing_lowercase => error.PasswordMissingLowercase,
            .missing_digit => error.PasswordMissingDigit,
            .contains_spaces => error.PasswordContainsSpaces,
            .too_few_words => error.PasswordNotPassphrase,
        };
    }

    /// The rule a `PolicyError` (also `SecurityManager.validatePassword`'s
    /// errors of the same names) stands for; null for any other error.
    pub fn violationOf(err: anyerror) ?Violation {
        return switch (err) {
            error.PasswordTooShort => .too_short,
            error.PasswordTooLong => .too_long,
            error.PasswordMissingUppercase => .missing_uppercase,
            error.PasswordMissingLowercase => .missing_lowercase,
            error.PasswordMissingDigit => .missing_digit,
            error.PasswordContainsSpaces => .contains_spaces,
            error.PasswordNotPassphrase => .too_few_words,
            else => null,
        };
    }

    /// The operator-facing text of a broken rule, with this policy's limits.
    /// A static string: never the password.
    pub fn message(self: PasswordPolicy, v: Violation) []const u8 {
        return switch (v) {
            .too_short => too_short_messages[@min(self.min_length, max_password_length)],
            .too_long => too_long_messages[@min(self.max_length, max_password_length)],
            .missing_uppercase => "Password must contain at least one uppercase letter",
            .missing_lowercase => "Password must contain at least one lowercase letter",
            .missing_digit => "Password must contain at least one digit",
            .contains_spaces => "Password must not contain spaces",
            .too_few_words => too_few_words_messages[@min(self.min_words, max_password_words)],
        };
    }

    // CANARY: REQ=REQ-SONNY-6331-ONE-PASSWORD-POLICY; FEATURE="Unified Password Policy Validation"; ASPECT=GeneratedPasswordsComply; STATUS=TESTED; TEST=tests/test_sonny6331_password_policy_paths.zig; OWNER=security; UPDATED=2026-11-12
    /// SONNY-6331: a random password that meets this policy, written into
    /// `out` (which must hold `max_password_length` bytes). Words of eight
    /// characters (an uppercase letter, a lowercase letter, six lowercase
    /// letters or digits; about 40 bits each), as many as the length and word
    /// limits need. The generated passwords (first-boot admin, `geode user
    /// --generate-password`, `user_create`'s placeholder) were hex strings that
    /// the policy refused.
    pub fn generate(self: PasswordPolicy, out: []u8) ![]const u8 {
        const word_len = 8;
        const tail = "abcdefghijklmnopqrstuvwxyz0123456789";
        var len: usize = 0;
        var words: usize = 0;
        while (len < self.min_length or words < self.min_words) {
            const need: usize = if (words == 0) word_len else word_len + 1;
            if (len + need > @min(out.len, self.max_length)) return error.PolicyUnsatisfiable;
            if (words > 0) {
                out[len] = ' ';
                len += 1;
            }
            var raw: [word_len]u8 = undefined;
            try crypto_backend.Csprng.bytes(&raw);
            out[len] = 'A' + raw[0] % 26;
            out[len + 1] = 'a' + raw[1] % 26;
            for (raw[2..], 2..) |r, i| out[len + i] = tail[r % tail.len];
            len += word_len;
            words += 1;
        }
        const pw = out[0..len];
        std.debug.assert(self.check(pw) == null);
        return pw;
    }

    fn containsWhere(s: []const u8, comptime pred: fn (u8) bool) bool {
        for (s) |c| if (pred(c)) return true;
        return false;
    }

    // CANARY: REQ=REQ-SONNY-6359-ONE-WORD-COUNT; FEATURE="Unified Password Policy Validation"; ASPECT=WordCount; STATUS=TESTED; TEST=tests/test_sonny6359_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
    /// The words of a passphrase: runs of characters other than a space.
    /// SONNY-6359: the one definition; SecurityManager.validatePassword
    /// counted runs of letters and digits, so `Alpha-Beta-Gamma` was three
    /// words to it and one to the policy.
    pub fn countPassphraseWords(password: []const u8) usize {
        var word_count: usize = 0;
        var in_word = false;
        for (password) |c| {
            if (c == ' ') {
                in_word = false;
            } else {
                if (!in_word) word_count += 1;
                in_word = true;
            }
        }
        return word_count;
    }
};

/// The longest password any policy accepts, and the most words it holds.
pub const max_password_length: usize = 256;
pub const max_password_words: usize = max_password_length / 2;

const too_short_messages = blk: {
    @setEvalBranchQuota(200_000);
    var msgs: [max_password_length + 1][]const u8 = undefined;
    for (&msgs, 0..) |*m, n| m.* = std.fmt.comptimePrint("Password too short (minimum {d} characters)", .{n});
    break :blk msgs;
};

const too_long_messages = blk: {
    @setEvalBranchQuota(200_000);
    var msgs: [max_password_length + 1][]const u8 = undefined;
    for (&msgs, 0..) |*m, n| m.* = std.fmt.comptimePrint("Password too long (maximum {d} characters)", .{n});
    break :blk msgs;
};

const too_few_words_messages = blk: {
    @setEvalBranchQuota(200_000);
    var msgs: [max_password_words + 1][]const u8 = undefined;
    for (&msgs, 0..) |*m, n| m.* = std.fmt.comptimePrint("Password must be a passphrase with at least {d} words", .{n});
    break :blk msgs;
};

// ---- Audit ----
pub const AuditEventType = enum {
    user_created,
    user_updated,
    user_deleted,
    login_success,
    login_failed,
    logout,
    role_assigned,
    role_revoked,
    permission_granted,
    permission_revoked,
    policy_created,
    policy_updated,
    policy_deleted,
    row_policy_created,
    row_policy_updated,
    row_policy_deleted,
    access_granted,
    access_denied,
    mfa_challenge_issued,
    mfa_challenge_success,
    mfa_challenge_failure,
    password_migration_needed,
};
pub const AuditEntry = struct { timestamp: i64, event_type: AuditEventType, user_id: UserId, details: []const u8 };
pub const AuditLog = struct {
    allocator: Allocator,
    entries: std.ArrayList(AuditEntry),
    pub fn init(a: Allocator) !AuditLog {
        // GAP-0220 FIX: Use try for proper error propagation
        return .{ .allocator = a, .entries = try std.ArrayList(AuditEntry).initCapacity(a, 0) };
    }
    pub fn deinit(self: *AuditLog) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.details);
        }
        self.entries.deinit(self.allocator);
    }
    fn append(self: *AuditLog, ev: AuditEventType, user_id: UserId, comptime fmt: []const u8, args: anytype) !void {
        try self.entries.append(self.allocator, .{ .timestamp = compat_milliTimestamp(), .event_type = ev, .user_id = user_id, .details = try std.fmt.allocPrint(self.allocator, fmt, args) });
    }
    pub fn logMfaPolicyAdded(self: *AuditLog, id: u64, enabled: bool) !void {
        try self.append(.policy_created, 0, "MFA policy added id={} enabled={}", .{ id, enabled });
    }
    pub fn logUserCreated(self: *AuditLog, user_id: UserId, username: []const u8) !void {
        try self.append(.user_created, user_id, "User created: {s}", .{username});
    }
    pub fn logSuccessfulLogin(self: *AuditLog, user_id: UserId, username: []const u8) !void {
        try self.append(.login_success, user_id, "Successful login: {s}", .{username});
    }
    pub fn logFailedLogin(self: *AuditLog, user_id: UserId, username: []const u8) !void {
        try self.append(.login_failed, user_id, "Failed login: {s}", .{username});
    }
    pub fn logRoleAssigned(self: *AuditLog, user_id: UserId, role_id: RoleId) !void {
        try self.append(.role_assigned, user_id, "Role {} assigned", .{role_id});
    }
    pub fn logRoleRevoked(self: *AuditLog, user_id: UserId, role_id: RoleId) !void {
        try self.append(.role_revoked, user_id, "Role {} revoked", .{role_id});
    }
    pub fn logPermissionGranted(self: *AuditLog, role_id: RoleId, perm: PermissionId) !void {
        try self.append(.permission_granted, 0, "Permission {} granted to role {}", .{ perm, role_id });
    }
    pub fn logPolicyCreated(self: *AuditLog, policy_id: PolicyId, name: []const u8) !void {
        try self.append(.policy_created, 0, "Policy created: {} - {s}", .{ policy_id, name });
    }
    pub fn logRowPolicyCreated(self: *AuditLog, policy_id: PolicyId, name: []const u8) !void {
        try self.append(.row_policy_created, 0, "Row policy created: {} - {s}", .{ policy_id, name });
    }
    // MFA audit events
    // CANARY: REQ=REQ-GQL-MFA-004; FEATURE="MFA challenge issued"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_004_IssuedFlow; OWNER=security; UPDATED=2025-09-26
    pub fn logMfaChallengeIssued(self: *AuditLog, user_id: UserId, method: []const u8) !void {
        try self.append(.mfa_challenge_issued, user_id, "MFA challenge issued method={s}", .{method});
    }
    // CANARY: REQ=REQ-GQL-MFA-005; FEATURE="MFA challenge success"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_005_SuccessFlow|TestCANARY_REQ_GQL_MFA_005_SuccessFlow_complete; OWNER=security; UPDATED=2025-09-26
    pub fn logMfaChallengeSuccess(self: *AuditLog, user_id: UserId, method: []const u8) !void {
        try self.append(.mfa_challenge_success, user_id, "MFA challenge success method={s}", .{method});
    }
    // CANARY: REQ=REQ-GQL-MFA-006; FEATURE="MFA challenge failure"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_006_FailureFlow; OWNER=security; UPDATED=2025-09-26
    pub fn logMfaChallengeFailure(self: *AuditLog, user_id: UserId, method: []const u8, reason: []const u8) !void {
        try self.append(.mfa_challenge_failure, user_id, "MFA challenge failure method={s} reason={s}", .{ method, reason });
    }
    // CANARY: REQ=REQ-GQL-MFA-007; FEATURE="MFA recovery code used"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_007_RecoveryAudit|TestCANARY_REQ_GQL_MFA_007_RecoverySingleUse; OWNER=security; UPDATED=2025-09-26
    pub fn logMfaRecoveryCodeUsed(self: *AuditLog, user_id: UserId) !void {
        try self.append(.mfa_challenge_success, user_id, "MFA recovery code consumed", .{});
    }
};

// ---- Security Context ----
// CANARY: REQ=REQ-SONNY-2778-ADMIN-PASSWORD-FILE; FEATURE="Secure Default Password"; ASPECT=ExclusiveNoFollow0600; STATUS=TESTED; TEST=tests/test_sonny2778_admin_password_file.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2778: the file a generated admin password is written to, in the data
/// directory (docs/USER_AUTH.md, "The generated admin password").
pub const admin_password_file_name = ".geode_admin_password";

/// SONNY-2778: write a generated admin password to
/// `<data_dir>/.geode_admin_password`, the one documented place for it. Every
/// writer (`SecurityManager.init`, the server's first boot, `geode auth init`)
/// goes through here.
///
/// The file is opened with O_CREAT | O_EXCL | O_NOFOLLOW and mode 0600, and
/// its mode is set to 0600 again once open, so no umask changes it. Nothing is
/// written when anything is already at the path: a file, or a symbolic link,
/// dangling or not (error.AdminPasswordFileExists). The writers used
/// O_CREAT | O_TRUNC without O_EXCL: an existing file kept its mode and owner,
/// so a world-readable file planted there received the password, and a
/// symbolic link planted there was followed. `SecurityManager.init` also wrote
/// into the current working directory when no data directory was set. A file
/// that cannot be completed is removed. Returns the path; the caller frees it.
pub fn writeAdminPasswordFile(allocator: std.mem.Allocator, data_dir: []const u8, password: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/" ++ admin_password_file_name, .{data_dir});
    errdefer allocator.free(path);
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AdminPasswordFileExists,
        else => return err,
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    try file.writeStreamingAll(io, password);
    return path;
}

/// SONNY-2778: whether anything is at `<data_dir>/.geode_admin_password`: a
/// file, a directory, or a symbolic link, dangling or not. A writer that can
/// look before it creates the admin (`geode auth init`) refuses then and
/// changes nothing, rather than creating an admin whose password it cannot
/// record. `writeAdminPasswordFile` stays the guard; this is only the early
/// answer.
pub fn adminPasswordFilePresent(data_dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/" ++ admin_password_file_name, .{data_dir}) catch return false;
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

pub const SecurityContext = struct { user: *User, roles: []const Role, session_attributes: std.StringHashMap([]const u8), request_attributes: std.StringHashMap([]const u8), environment: EnvironmentInfo };

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-005; FEATURE="Runtime Auth Graph Persistence"; ASPECT=SingleDurableWriter; STATUS=TESTED; TEST=tests/test_bug731_password_reset.zig; OWNER=security; UPDATED=2026-07-31
/// Bug 731-4c: `ALTER USER ... SET PASSWORD` persists through TWO seams for one
/// logical change — `user_management.updateUserPassword` (write-through via its
/// persistent writer) and `SecurityManager.updatePassword` (graph_persist_password
/// callback) — and both land on `AuthGraphManager.updateUserPassword`, which bumps
/// `auth_version` per call. Two bumps for one change leave the persisted version
/// ahead of the user_management cache, so every later request sees a stale cache,
/// invalidates it and re-hydrates the user straight back out of the graph.
///
/// `user_management` publishes ownership here when a persistent user writer with an
/// `update_password_fn` is installed (the server always installs one). While owned,
/// SecurityManager mirrors the password change in memory but skips its own durable
/// write, so one logical change advances the persisted `auth_version` exactly once.
/// When no external writer is installed (offline CLI, unit tests wiring only the
/// SecurityManager), SecurityManager remains the durable writer as before.
var external_password_persistence_owner = std.atomic.Value(bool).init(false);

/// Declare (or withdraw) an external owner of durable password persistence.
/// Called by `user_management.setPersistentUserWriter` / `deinitUserStore`.
pub fn setExternalPasswordPersistenceOwner(owned: bool) void {
    external_password_persistence_owner.store(owned, .release);
}

pub fn externalPasswordPersistenceOwned() bool {
    return external_password_persistence_owner.load(.acquire);
}

// ---- SecurityManager ----
// CANARY: REQ=REQ-SONNY-2410-SECURITY-MANAGER-LOCKING; FEATURE="SecurityManagerThreadSafety"; ASPECT=ReentrantLock; STATUS=TESTED; TEST=tests/test_sonny2410_security_manager_locking.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-2410: a mutex the owning thread may take again (each `lock` paired
/// with an `unlock`). Per instance: two managers on one thread lock
/// independently.
pub const ReentrantMutex = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// The holding thread's id; 0 when free (no thread has id 0).
    owner: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0),
    /// Written only by the holder.
    depth: u32 = 0,

    pub fn lock(self: *ReentrantMutex) void {
        const me = std.Thread.getCurrentId();
        if (self.owner.load(.acquire) == me) {
            self.depth += 1;
            return;
        }
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        self.owner.store(me, .release);
        self.depth = 1;
    }

    pub fn unlock(self: *ReentrantMutex) void {
        std.debug.assert(self.depth > 0 and self.owner.load(.acquire) == std.Thread.getCurrentId());
        self.depth -= 1;
        if (self.depth != 0) return;
        self.owner.store(0, .release);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }
};

pub const SecurityManager = struct {
    const Self = @This();
    allocator: Allocator,
    users: std.AutoHashMap(UserId, User),
    roles: std.AutoHashMap(RoleId, Role),
    permissions: std.AutoHashMap(PermissionId, Permission),
    rbac: RBACPolicy,
    abac_policies: std.ArrayList(ABACPolicy),
    row_policies: std.ArrayList(RowLevelPolicy),
    // Sessions keyed by opaque token string. Use StringHashMap to avoid slice autoHash limitations.
    sessions: std.StringHashMap(Session),
    mfa_policies: std.ArrayList(MfaAdminPolicy),
    mfa_require_cache: std.AutoHashMap(UserId, bool),
    audit_log: AuditLog,
    password_policy: PasswordPolicy,
    elevation_ttl_ms: i64 = 5 * 60 * 1000, // default 5 minutes; configurable
    /// SONNY-2394: serialized the credential entry points -- `authenticate`,
    /// `authenticateWithMFA` and `updatePassword`. One SecurityManager is
    /// shared by every connection thread (server_init), and these paths mutate
    /// shared state with no other synchronization: a user's single-use
    /// recovery-code list (orderedRemove), password hashes and lockout
    /// counters, the `sessions` map and the `audit_log` entries. Concurrent MFA
    /// recovery-code redemption crashed on the unsynchronized audit-log /
    /// session-map growth (DebugAllocator: "Double free detected") and could
    /// redeem one code twice.
    ///
    /// SONNY-2410: every public method that reads or changes the users,
    /// roles, permissions, role memberships, sessions, policies, MFA cache or
    /// audit log takes it (`init`, `initEmpty` and `deinit` excepted: nothing
    /// else holds the manager then). Re-entrant on one thread, so a locked
    /// method may call another (`createUser` -> `createUserDetailed` ->
    /// `hashPassword`). It is held across the auth-graph persistence
    /// callbacks, as `updatePassword` already held it. Pointers the manager
    /// answers (`createRole`, `createPermission`) point into its maps and
    /// are moved by the next create on any thread: read them at once, or
    /// only where no other thread changes the manager.
    auth_mu: ReentrantMutex = .{},
    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-001; FEATURE="AuthGraphManager Integration"; ASPECT=SecurityManager; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
    // Opaque pointer to AuthGraphManager for runtime mutation persistence (set by server_init).
    // Uses anyopaque because geode_auth_lib cannot import auth_graph_manager (circular dep).
    auth_graph_mgr: ?*anyopaque = null,
    // HMAC key for chain signing (set by server_init after auth graph verification).
    hmac_key: ?[32]u8 = null,

    // -- Graph persistence callbacks (set by server wiring code) --
    // These function pointers allow SecurityManager to persist mutations to the auth graph
    // without importing auth_graph_manager (which would create a circular dependency).
    // All callbacks are best-effort: failures are logged but do not block in-memory operations.

    /// Callback to persist a new user to the auth graph.
    /// Args: opaque_ctx, hmac_key, username, email, password_hash, is_superuser
    /// Returns: user ID in graph store, or error.
    graph_persist_user_create: ?*const fn (*anyopaque, *const [32]u8, []const u8, []const u8, []const u8, bool) callconv(.auto) u64 = null,

    /// Callback to persist login state changes (failed_attempts, lockout_until) to the auth graph.
    /// Args: opaque_ctx, hmac_key, user_id, failed_attempts, lockout_until
    graph_persist_login_state: ?*const fn (*anyopaque, *const [32]u8, u64, u16, i64) callconv(.auto) void = null,

    /// Callback to persist password change to the auth graph.
    /// Args: opaque_ctx, hmac_key, user_id, new_password_hash
    /// Returns the new auth_version, or 0 on failure.
    graph_persist_password: ?*const fn (*anyopaque, *const [32]u8, u64, []const u8) callconv(.auto) u64 = null,

    /// Callback to persist role membership changes to the auth graph.
    /// Args: opaque_ctx, hmac_key, user_id, role_id, assign
    /// Returns the new auth_version, or 0 on failure.
    graph_persist_role_membership: ?*const fn (*anyopaque, *const [32]u8, u64, u64, bool) callconv(.auto) u64 = null,

    pub fn init(a: Allocator) !Self {
        var sm = Self{
            .allocator = a,
            .users = std.AutoHashMap(UserId, User).init(a),
            .roles = std.AutoHashMap(RoleId, Role).init(a),
            .permissions = std.AutoHashMap(PermissionId, Permission).init(a),
            .rbac = RBACPolicy{ .user_roles = std.AutoHashMap(UserId, std.ArrayList(RoleId)).init(a), .role_permissions = std.AutoHashMap(RoleId, std.ArrayList(Permission)).init(a), .role_hierarchy = std.AutoHashMap(RoleId, std.ArrayList(RoleId)).init(a) },
            // GAP-0220 FIX: Use try for proper error propagation
            .abac_policies = try std.ArrayList(ABACPolicy).initCapacity(a, 0),
            .row_policies = try std.ArrayList(RowLevelPolicy).initCapacity(a, 0),
            .sessions = std.StringHashMap(Session).init(a),
            .mfa_policies = try std.ArrayList(MfaAdminPolicy).initCapacity(a, 0),
            .mfa_require_cache = std.AutoHashMap(UserId, bool).init(a),
            .audit_log = try AuditLog.init(a),
            .password_policy = PasswordPolicy.geodeSecure(),
        };
        // Initialize with default user
        try sm.initializeDefaultUser();
        return sm;
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-002; FEATURE="AuthGraphManager Integration"; ASPECT=InitEmpty; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
    /// Create a SecurityManager with empty user/role maps.
    /// Does NOT call initializeDefaultUser — use when hydrating from AuthGraphManager.
    pub fn initEmpty(a: Allocator) !Self {
        return Self{
            .allocator = a,
            .users = std.AutoHashMap(UserId, User).init(a),
            .roles = std.AutoHashMap(RoleId, Role).init(a),
            .permissions = std.AutoHashMap(PermissionId, Permission).init(a),
            .rbac = RBACPolicy{ .user_roles = std.AutoHashMap(UserId, std.ArrayList(RoleId)).init(a), .role_permissions = std.AutoHashMap(RoleId, std.ArrayList(Permission)).init(a), .role_hierarchy = std.AutoHashMap(RoleId, std.ArrayList(RoleId)).init(a) },
            .abac_policies = try std.ArrayList(ABACPolicy).initCapacity(a, 0),
            .row_policies = try std.ArrayList(RowLevelPolicy).initCapacity(a, 0),
            .sessions = std.StringHashMap(Session).init(a),
            .mfa_policies = try std.ArrayList(MfaAdminPolicy).initCapacity(a, 0),
            .mfa_require_cache = std.AutoHashMap(UserId, bool).init(a),
            .audit_log = try AuditLog.init(a),
            .password_policy = PasswordPolicy.geodeSecure(),
        };
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-003; FEATURE="AuthGraphManager Integration"; ASPECT=HydrateUser; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
    /// Add a user to in-memory maps from external data (e.g. AuthGraphManager).
    /// The password_hash is already hashed; no policy validation is performed.
    pub fn hydrateUser(
        self: *Self,
        id: UserId,
        username: []const u8,
        email: []const u8,
        password_hash: []const u8,
        is_superuser: bool,
        is_active: bool,
        is_default_user: bool,
        password_reset_required: bool,
        mfa_enabled: bool,
        mfa_secret: ?[]const u8,
        auth_version: u64,
        attributes_json: ?[]const u8,
    ) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        var attrs = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = attrs.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            attrs.deinit();
        }

        if (attributes_json) |raw_attrs| {
            var parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, self.allocator, raw_attrs, .{}) catch |err| blk: {
                log.warn("Failed to parse hydrated user attributes", &.{
                    Attr.uint("user_id", id),
                    Attr.string("error", @errorName(err)),
                });
                break :blk null;
            };
            defer if (parsed) |*p| p.deinit();

            if (parsed) |p| {
                if (p.value == .object) {
                    var it = p.value.object.iterator();
                    while (it.next()) |entry| {
                        if (entry.value_ptr.* != .string) continue;
                        try attrs.put(
                            try self.allocator.dupe(u8, entry.key_ptr.*),
                            try self.allocator.dupe(u8, entry.value_ptr.string),
                        );
                    }
                }
            }
        }

        const user = User{
            .id = id,
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password_hash = try self.allocator.dupe(u8, password_hash),
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
            .last_login = null,
            .is_active = is_active,
            .is_superuser = is_superuser,
            .mfa_enabled = mfa_enabled,
            .mfa_secret = if (mfa_secret) |s| try self.allocator.dupe(u8, s) else null,
            .attributes = attrs,
            .password_reset_required = password_reset_required,
            .auth_version = @max(@as(u64, 1), auth_version),
            .is_default_user = is_default_user,
            .password_set_by_env = false,
        };
        try self.users.put(id, user);
    }

    // -- Graph Persistence Helpers (best-effort, log-and-continue) --

    /// Persist a newly created user to the auth graph store.
    fn persistUserCreateToGraph(self: *Self, username: []const u8, email: []const u8, password_hash: []const u8, is_superuser: bool) void {
        const agm_ptr = self.auth_graph_mgr orelse return;
        const hk = &(self.hmac_key orelse return);
        const cb = self.graph_persist_user_create orelse return;
        _ = cb(agm_ptr, hk, username, email, password_hash, is_superuser);
    }

    /// Persist login state changes (failed attempts, lockout) to the auth graph store.
    fn persistLoginStateToGraph(self: *Self, user_id: u64, failed_attempts: u16, lockout_until: i64) void {
        const agm_ptr = self.auth_graph_mgr orelse return;
        const hk = &(self.hmac_key orelse return);
        const cb = self.graph_persist_login_state orelse return;
        cb(agm_ptr, hk, user_id, failed_attempts, lockout_until);
    }

    /// Persist a password change to the auth graph store.
    /// Bug 731-4c: skipped while an external durable owner (the user_management
    /// persistent writer) is installed, so one logical password change performs
    /// exactly one durable write and one auth_version bump.
    fn persistPasswordToGraph(self: *Self, user_id: u64, new_password_hash: []const u8) ?u64 {
        if (externalPasswordPersistenceOwned()) return null;
        const agm_ptr = self.auth_graph_mgr orelse return null;
        const hk = &(self.hmac_key orelse return null);
        const cb = self.graph_persist_password orelse return null;
        const version = cb(agm_ptr, hk, user_id, new_password_hash);
        return if (version == 0) null else version;
    }

    fn persistRoleMembershipToGraph(self: *Self, user_id: u64, role_id: u64, assign: bool) ?u64 {
        const agm_ptr = self.auth_graph_mgr orelse return null;
        const hk = &(self.hmac_key orelse return null);
        const cb = self.graph_persist_role_membership orelse return null;
        const version = cb(agm_ptr, hk, user_id, role_id, assign);
        return if (version == 0) null else version;
    }

    pub fn deinit(self: *Self) void {
        // Release user map strings
        var it = self.users.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.value_ptr.username);
            self.allocator.free(e.value_ptr.email);
            self.allocator.free(e.value_ptr.password_hash);
            if (e.value_ptr.mfa_secret) |secret| {
                self.allocator.free(secret);
            }
            if (e.value_ptr.recovery_codes) |*codes| {
                for (codes.items) |code| {
                    self.allocator.free(code);
                }
                codes.deinit(self.allocator);
            }
            var attr_it = e.value_ptr.attributes.iterator();
            while (attr_it.next()) |attr| {
                self.allocator.free(attr.key_ptr.*);
                self.allocator.free(attr.value_ptr.*);
            }
            e.value_ptr.attributes.deinit();
        }
        self.users.deinit();

        // Release role map strings and ArrayLists
        var role_it = self.roles.iterator();
        while (role_it.next()) |e| {
            self.allocator.free(e.value_ptr.name);
            self.allocator.free(e.value_ptr.description);
            e.value_ptr.permissions.deinit(self.allocator);
        }
        self.roles.deinit();

        // Release permission map strings.
        var perm_it = self.permissions.iterator();
        while (perm_it.next()) |e| {
            self.allocator.free(e.value_ptr.name);
            self.allocator.free(e.value_ptr.resource);
            if (e.value_ptr.conditions) |conditions| {
                self.allocator.free(conditions);
            }
        }
        self.permissions.deinit();

        // Release RBAC user-role assignment ArrayLists
        var rbac_it = self.rbac.user_roles.iterator();
        while (rbac_it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.rbac.user_roles.deinit();

        var role_perm_it = self.rbac.role_permissions.iterator();
        while (role_perm_it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.rbac.role_permissions.deinit();

        var hierarchy_it = self.rbac.role_hierarchy.iterator();
        while (hierarchy_it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.rbac.role_hierarchy.deinit();

        var session_it = self.sessions.iterator();
        while (session_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.ip_address) |ip| {
                self.allocator.free(ip);
            }
            if (entry.value_ptr.user_agent) |user_agent| {
                self.allocator.free(user_agent);
            }
        }
        self.sessions.deinit();

        self.abac_policies.deinit(self.allocator);
        self.row_policies.deinit(self.allocator);
        self.mfa_policies.deinit(self.allocator);
        self.mfa_require_cache.deinit();
        self.audit_log.deinit();
    }
    // ---- MFA Policies ----

    pub fn addMfaPolicy(self: *Self, p: MfaAdminPolicy) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        try self.mfa_policies.append(self.allocator, p);
        self.mfa_require_cache.clearRetainingCapacity();
        try self.audit_log.logMfaPolicyAdded(p.id, p.enabled);
    }
    // Backwards-compatible simple evaluation (no session/env context). Uses current time and null session.
    pub fn evaluateMfaPolicies(self: *Self, u: *User) bool {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        return self.evaluateMfaPoliciesAdvanced(u, null, compat_milliTimestamp());
    }

    // Extended evaluation considering dynamic conditions (time window, risk, reauth interval).
    // CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mfa_policies.zig; OWNER=security; UPDATED=2026-11-12
    pub fn evaluateMfaPoliciesAdvanced(self: *Self, u: *User, session: ?*Session, now_ms: i64) bool {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        if (self.mfa_policies.items.len == 0) return false;
        // Dynamic conditions invalidate cache; detect presence.
        var has_dynamic = false;
        for (self.mfa_policies.items) |p| switch (p.condition) {
            .time_window, .risk_score_min, .reauth_interval_elapsed => has_dynamic = true,
            else => {},
        };
        if (!has_dynamic) {
            if (self.mfa_require_cache.get(u.id)) |v| return v;
        }
        var require = false;
        var user_role_ids: []RoleId = &[_]RoleId{};
        if (self.rbac.user_roles.get(u.id)) |rl| user_role_ids = rl.items;
        // Attempt to parse risk score from user attribute "risk_score" if needed.
        var risk_score: ?u8 = null;
        for (self.mfa_policies.items) |p| {
            if (!p.enabled) continue;
            const cond = p.condition;
            if (cond == .always) {
                require = true;
            } else if (cond == .match_any_role) {
                for (user_role_ids) |rid| {
                    for (p.roles) |pr| {
                        if (rid == pr) {
                            require = true;
                            break;
                        }
                    }
                    if (require) break;
                }
            } else if (cond == .match_all_roles) {
                var all = true;
                for (p.roles) |pr| {
                    var found = false;
                    for (user_role_ids) |rid| {
                        if (rid == pr) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        all = false;
                        break;
                    }
                }
                if (all and p.roles.len > 0) require = true;
            } else if (cond == .user_attribute_equals) {
                if (p.attribute_key) |k| {
                    if (p.attribute_value) |v| {
                        if (u.attributes.get(k)) |val| {
                            if (std.mem.eql(u8, val, v)) require = true;
                        }
                    }
                }
            } else if (cond == .time_window) {
                if (p.time_start_minute) |start| {
                    if (p.time_end_minute) |end| {
                        const minutes_per_day: i64 = 24 * 60;
                        const ms_per_min: i64 = 60 * 1000;
                        const minutes_since_epoch: i64 = @divTrunc(now_ms, ms_per_min);
                        const minute_of_day: u16 = @as(u16, @intCast(@mod(minutes_since_epoch, minutes_per_day)));
                        if (start <= end) {
                            if (minute_of_day >= start and minute_of_day <= end) require = true;
                        } else {
                            if (minute_of_day >= start or minute_of_day <= end) require = true;
                        }
                    }
                }
            } else if (cond == .risk_score_min) {
                // CANARY: REQ=REQ-AUTH-RISKSCORE-001; FEATURE="FailSecureRiskScore"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_security.yml; OWNER=security; UPDATED=2026-01-13
                // GAP-0149 SECURITY FIX: Fail-secure on invalid risk_score - treat as max risk (255)
                if (risk_score == null) {
                    if (u.attributes.get("risk_score")) |rs| {
                        risk_score = std.fmt.parseInt(u8, rs, 10) catch blk: {
                            // GAP-0149: Invalid risk_score treated as HIGH risk (fail-secure)
                            log.warn("Invalid risk_score attribute - treating as max risk (fail-secure)", &.{
                                Attr.string("risk_score_value", rs),
                                Attr.int("user_id", @intCast(u.id)),
                            });
                            break :blk 255; // Max risk = always require MFA
                        };
                    } else risk_score = 0;
                }
                if (p.risk_min_score) |thr| {
                    if (risk_score orelse 0 >= thr) require = true;
                }
            } else if (cond == .reauth_interval_elapsed) {
                if (session) |s| {
                    if (p.reauth_interval_ms) |intv| {
                        if (s.last_mfa_ts) |last| {
                            if (now_ms - last >= intv) require = true;
                        } else {
                            require = true; // no MFA yet
                        }
                    }
                } else {
                    if (p.reauth_interval_ms != null) require = true;
                }
            }
            if (require) break;
        }
        if (!has_dynamic) self.mfa_require_cache.put(u.id, require) catch |err| {
            log.warn("MFA cache update failed", &.{Attr.string("error", @errorName(err))});
        };
        return require;
    }

    // ---- ABAC ----
    pub fn createABACPolicy(self: *Self, policy: ABACPolicy) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        try self.abac_policies.append(self.allocator, policy);
        try self.audit_log.logPolicyCreated(policy.id, policy.name);
    }
    pub fn evaluateABACPolicies(self: *Self, context: *SecurityContext, resource: []const u8, action: Action) !bool {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        var allow = false;
        var explicit_deny = false;
        for (self.abac_policies.items) |policy| {
            if (!policy.enabled) continue;
            var action_matches = false;
            for (policy.actions) |a2| {
                if (a2 == action or a2 == .all) {
                    action_matches = true;
                    break;
                }
            }
            if (!action_matches) continue;
            if (!self.evaluateAttributeConditions(policy.subjects, context.user.attributes)) continue;
            var resource_attrs = std.StringHashMap([]const u8).init(self.allocator);
            defer resource_attrs.deinit();
            try resource_attrs.put("name", resource);
            if (!self.evaluateAttributeConditions(policy.resources, resource_attrs)) continue;
            if (!try self.evaluateEnvironmentConditions(policy.conditions, context.environment)) continue;
            switch (policy.effect) {
                .allow => allow = true,
                .deny => {
                    explicit_deny = true;
                    break;
                },
            }
        }
        return !explicit_deny and allow;
    }
    fn evaluateAttributeConditions(self: *Self, conds: []const AttributeCondition, attrs: std.StringHashMap([]const u8)) bool {
        _ = self;
        for (conds) |c| {
            const val = attrs.get(c.attribute) orelse return false;
            switch (c.operator) {
                .equals => if (c.value == .string and !std.mem.eql(u8, val, c.value.string)) return false,
                .contains => if (c.value == .string and std.mem.indexOf(u8, val, c.value.string) == null) return false,
                else => return false,
            }
        }
        return true;
    }
    fn evaluateEnvironmentConditions(self: *Self, conds: []const EnvironmentCondition, env: EnvironmentInfo) !bool {
        _ = self;
        for (conds) |c| {
            switch (c.type_) {
                .time_range => {
                    if (c.parameters == .object) {
                        const start = c.parameters.object.get("start").?.integer;
                        const end = c.parameters.object.get("end").?.integer;
                        if (env.timestamp < start or env.timestamp > end) return false;
                    }
                },
                .ip_range => {
                    if (c.parameters == .string) {
                        if (!std.mem.startsWith(u8, env.ip_address, c.parameters.string)) return false;
                    }
                },
                else => {},
            }
        }
        return true;
    }

    // ---- RLS ----
    pub fn createRowLevelPolicy(self: *Self, policy: RowLevelPolicy) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        try self.row_policies.append(self.allocator, policy);
        try self.audit_log.logRowPolicyCreated(policy.id, policy.name);
    }
    pub fn applyRowLevelSecurity(self: *Self, user_id: UserId, query: []const u8, table: []const u8) ![]const u8 {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const roles_list = self.rbac.user_roles.get(user_id) orelse return query;
        var applicable = std.ArrayList(RowLevelPolicy).init(self.allocator);
        defer applicable.deinit();
        for (self.row_policies.items) |p| {
            if (!(p.enabled and std.mem.eql(u8, p.table, table))) continue;
            var match = false;
            for (p.roles) |rr| {
                for (roles_list.items) |ur| {
                    if (rr == ur) {
                        match = true;
                        break;
                    }
                }
                if (match) break;
            }
            if (match) try applicable.append(p);
        }
        if (applicable.items.len == 0) return query;
        // GAP-0220 FIX: Use try for proper error propagation
        var out = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        try out.appendSlice(self.allocator, query);
        try out.appendSlice(self.allocator, " WHERE (");
        for (applicable.items, 0..) |p, i| {
            if (i > 0) try out.appendSlice(self.allocator, " OR ");
            // Sanitize using_clause: reject clauses containing statement terminators
            // or comment sequences that could allow GQL injection.
            if (std.mem.indexOf(u8, p.using_clause, ";") != null or
                std.mem.indexOf(u8, p.using_clause, "--") != null or
                std.mem.indexOf(u8, p.using_clause, "/*") != null)
            {
                return error.InvalidRlsPolicy;
            }
            try out.append(self.allocator, '(');
            try out.appendSlice(self.allocator, p.using_clause);
            try out.append(self.allocator, ')');
        }
        try out.appendSlice(self.allocator, ")");
        return try out.toOwnedSlice(self.allocator);
    }

    // ---- Sessions ----
    pub fn createSession(self: *Self, user_id: UserId) ![]const u8 {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        var raw: [32]u8 = undefined;
        std.Io.Threaded.global_single_threaded.io().random(&raw);
        const enc = std.base64.url_safe_no_pad.Encoder;
        const token = try self.allocator.alloc(u8, enc.calcSize(raw.len));
        _ = enc.encode(token, &raw);
        const now = compat_milliTimestamp();
        const session = Session{
            .token = token,
            .user_id = user_id,
            .created_at = now,
            .expires_at = now + 86_400_000, // 24h default lifetime
            .ip_address = null,
            .user_agent = null,
            .last_mfa_ts = null,
            .elevation_expires_at = null,
        };
        try self.sessions.put(token, session);
        return token;
    }

    /// Returns true when a privileged action requires a fresh step-up (MFA) before proceeding.
    /// GAP-0884: explicit OperationClass-based policy — `classifyOperation` maps the real
    /// operation identifier (procedure name / auth DDL handler / legacy session-action id)
    /// to read | write | admin | security_admin; only `read` is exempt from step-up.
    /// Unknown identifiers fail closed (classified as write => step-up required).
    /// CANARY: REQ=REQ-GQL-MFA-008; FEATURE="Session step-up requirement"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_gap0884_stepup_classification.zig; OWNER=security; UPDATED=2026-06-10
    pub fn requireStepUp(self: *Self, token: []const u8, action: []const u8) bool {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const s = self.sessions.get(token) orelse return true; // unknown session => demand step-up / re-auth
        const now = compat_milliTimestamp();
        if (s.elevation_expires_at) |exp| {
            if (now <= exp) {
                return false; // still elevated
            }
        }
        // GAP-0884: explicit operation classification (no substring scans).
        // Only read-class operations are exempt; unknown identifiers
        // classify as write and therefore fail closed (step-up required).
        return operationRequiresStepUp(classifyOperation(action));
    }

    /// Marks the session as having completed a successful step-up (MFA) for a bounded lifetime.
    /// lifetime_ms: duration the elevation should remain valid.
    /// CANARY: REQ=REQ-GQL-MFA-009; FEATURE="Session step-up mark"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-14
    pub fn markStepUp(self: *Self, token: []const u8, lifetime_ms: i64) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        var s = self.sessions.getPtr(token) orelse return error.InvalidSession;
        const now = compat_milliTimestamp();
        s.last_mfa_ts = now;
        s.elevation_expires_at = now + lifetime_ms;
    }
    pub fn validateSession(self: *Self, token: []const u8) !UserId {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const s = self.sessions.get(token) orelse return error.InvalidSession;
        if (compat_milliTimestamp() > s.expires_at) {
            _ = self.sessions.remove(token);
            return error.SessionExpired;
        }
        return s.user_id;
    }

    // ---- Authorization ----
    pub fn authorize(self: *Self, user_id: UserId, resource: []const u8, action: Action) !bool {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const user = self.users.getPtr(user_id) orelse return error.UserNotFound;
        if (user.is_superuser) return true;
        if (self.rbac.hasPermission(user_id, resource, action)) return true;
        var ctx = SecurityContext{ .user = user, .roles = &[_]Role{}, .session_attributes = std.StringHashMap([]const u8).init(self.allocator), .request_attributes = std.StringHashMap([]const u8).init(self.allocator), .environment = .{ .timestamp = compat_milliTimestamp(), .ip_address = "127.0.0.1", .user_agent = "geode-client", .location = null, .device_id = null } };
        defer {
            ctx.session_attributes.deinit();
            ctx.request_attributes.deinit();
        }
        return try self.evaluateABACPolicies(&ctx, resource, action);
    }

    // ---- Role & Permission Mgmt ----
    pub fn createRole(self: *Self, name: []const u8, description: []const u8) !*Role {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const id = @as(RoleId, @intCast(self.roles.count() + 1));
        // GAP-0220 FIX: Use try for proper error propagation
        const role = Role{ .id = id, .name = try self.allocator.dupe(u8, name), .description = try self.allocator.dupe(u8, description), .permissions = try std.ArrayList(PermissionId).initCapacity(self.allocator, 0), .created_at = compat_milliTimestamp(), .is_system = false, .priority = 100, .parent_role = null };
        try self.roles.put(id, role);
        return self.roles.getPtr(id).?;
    }
    pub fn assignRole(self: *Self, user_id: UserId, role_id: RoleId) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        _ = self.users.get(user_id) orelse return error.UserNotFound;
        _ = self.roles.get(role_id) orelse return error.RoleNotFound;
        const entry = try self.rbac.user_roles.getOrPut(user_id);
        // GAP-0220 FIX: Use try for proper error propagation
        if (!entry.found_existing) entry.value_ptr.* = try std.ArrayList(RoleId).initCapacity(self.allocator, 0);
        for (entry.value_ptr.items) |r| if (r == role_id) return;
        try entry.value_ptr.append(self.allocator, role_id);
        if (self.users.getPtr(user_id)) |user| {
            if (self.persistRoleMembershipToGraph(user_id, role_id, true)) |version| {
                user.auth_version = version;
            } else {
                user.auth_version += 1;
            }
            user.updated_at = compat_milliTimestamp();
        }
        try self.audit_log.logRoleAssigned(user_id, role_id);
    }
    pub fn revokeRole(self: *Self, user_id: UserId, role_id: RoleId) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const roles_list = self.rbac.user_roles.getPtr(user_id) orelse return error.UserHasNoRoles;
        for (roles_list.items, 0..) |rid, i| {
            if (rid == role_id) {
                _ = roles_list.orderedRemove(i);
                if (self.users.getPtr(user_id)) |user| {
                    if (self.persistRoleMembershipToGraph(user_id, role_id, false)) |version| {
                        user.auth_version = version;
                    } else {
                        user.auth_version += 1;
                    }
                    user.updated_at = compat_milliTimestamp();
                }
                try self.audit_log.logRoleRevoked(user_id, role_id);
                return;
            }
        }
        return error.RoleNotAssigned;
    }
    pub fn createPermission(self: *Self, name: []const u8, resource: []const u8, action: Action) !*Permission {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const id = @as(PermissionId, @intCast(self.permissions.count() + 1));
        const perm = Permission{ .id = id, .name = try self.allocator.dupe(u8, name), .resource = try self.allocator.dupe(u8, resource), .action = action, .conditions = null, .created_at = compat_milliTimestamp() };
        try self.permissions.put(id, perm);
        return self.permissions.getPtr(id).?;
    }
    pub fn grantPermission(self: *Self, role_id: RoleId, perm_id: PermissionId) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const role = self.roles.getPtr(role_id) orelse return error.RoleNotFound;
        const perm = self.permissions.get(perm_id) orelse return error.PermissionNotFound;
        for (role.permissions.items) |p| if (p == perm_id) return;
        try role.permissions.append(self.allocator, perm_id);
        const rp = try self.rbac.role_permissions.getOrPut(role_id);
        // GAP-0220 FIX: Use try for proper error propagation
        if (!rp.found_existing) rp.value_ptr.* = try std.ArrayList(Permission).initCapacity(self.allocator, 0);
        try rp.value_ptr.append(self.allocator, perm);
        try self.audit_log.logPermissionGranted(role_id, perm_id);
    }

    // ---- Passwords ----
    // CANARY: REQ=REQ-AUTH-HASH-001; FEATURE="Argon2id Password Hashing"; ASPECT=PostQuantumSecurity; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_HASH_001_Argon2id; OWNER=security; UPDATED=2025-10-16
    // Delegates to the canonical standalone hashPasswordArgon2id after policy validation.
    pub fn hashPassword(self: *Self, password: []const u8) ![]const u8 {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        // CANARY: REQ=REQ-AUTH-POLICY-008; FEATURE="Pre-Hash Password Validation"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_008_PreHashValidation; OWNER=security; UPDATED=2025-09-30
        // Validate password against policy before hashing
        try self.validatePasswordAgainstCurrentPolicy(password);

        // Delegate to the canonical standalone implementation
        return hashPasswordArgon2id(self.allocator, password);
    }

    /// Update the stored password hash for a user (used for hash migration).
    /// GAP-0489: Called after Blake2b verification succeeds to upgrade to Argon2id.
    fn updateStoredHash(self: *Self, user_id: UserId, new_hash: []const u8) !void {
        const entry = self.users.getPtr(user_id) orelse return error.UserNotFound;
        self.allocator.free(entry.password_hash);
        entry.password_hash = try self.allocator.dupe(u8, new_hash);
        entry.updated_at = compat_milliTimestamp();
    }

    /// Constant-time comparison for 32-byte arrays (Argon2id/Blake2b digests). GAP-0440.
    /// Uses std.crypto.timing_safe.eql to prevent compiler optimisation of the comparison.
    fn constantTimeEqual32(a: *const [32]u8, b: *const [32]u8) bool {
        return crypto_backend.timingSafeEql(a, b);
    }

    fn verifyPassword(self: *Self, password: []const u8, stored_hash: []const u8) !bool {
        // SECURITY FIX (C2): Support both Argon2id (PHC format) and legacy Blake2b
        // This enables gradual migration from Blake2b to Argon2id

        // Check if hash is PHC format (starts with $argon2id$)
        if (std.mem.startsWith(u8, stored_hash, "$argon2id$")) {
            // Parse PHC string: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
            return self.verifyArgon2idPHC(password, stored_hash);
        }

        // Legacy Blake2b format (64 hex chars) - for migration only
        if (stored_hash.len == 64 and isHexString(stored_hash)) {
            log.warn("Legacy Blake2b hash detected - recommend password reset for Argon2id upgrade", &.{});
            return self.verifyBlake2bLegacy(password, stored_hash);
        }

        // Unknown format
        log.err("Unrecognized password hash format", &.{
            Attr.int("hash_length", @intCast(stored_hash.len)),
            Attr.string("prefix", stored_hash[0..@min(10, stored_hash.len)]),
        });
        return error.InvalidHashFormat;
    }

    /// Verify Argon2id password in PHC format.
    /// Delegates to the canonical standalone verifyPasswordArgon2id.
    fn verifyArgon2idPHC(self: *Self, password: []const u8, phc_string: []const u8) !bool {
        return verifyPasswordArgon2id(self.allocator, password, phc_string);
    }

    /// Verify legacy Blake2b password (for migration only — deprecated).
    /// SECURITY NOTE: This uses a static salt which is weaker than Argon2id.
    /// Accounts verified via this path should be flagged for password_reset_required
    /// to force migration to Argon2id on next login.
    fn verifyBlake2bLegacy(self: *Self, password: []const u8, stored_hash: []const u8) !bool {
        // SONNY-6367: the one legacy BLAKE2b verifier (the wire login uses it
        // too); FIPS fails closed there.
        const matches = try verifyPasswordBlake2bLegacy(password, stored_hash);
        if (matches) {
            // Flag for migration: legacy Blake2b accounts must re-hash with Argon2id
            self.audit_log.append(.password_migration_needed, 0, "Legacy Blake2b hash verified — account should migrate to Argon2id", .{}) catch |err| {
                log.warn("Audit log append failed for password migration event", &.{Attr.string("error", @errorName(err))});
            };
        }
        return matches;
    }

    /// Check if string is valid hexadecimal
    fn isHexString(s: []const u8) bool {
        for (s) |c| {
            const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
            if (!is_hex) return false;
        }
        return true;
    }
    // Create user helper
    // CANARY: REQ=REQ-GQL-AUTH-001; FEATURE="User creation"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_AUTH_001_CreateUser; OWNER=security; UPDATED=2025-09-26
    pub fn createUserDetailed(self: *Self, username: []const u8, email: []const u8, password: []const u8, is_superuser: bool) !UserId {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const id = @as(UserId, @intCast(self.users.count() + 1));
        const attrs = std.StringHashMap([]const u8).init(self.allocator);
        const hash = try self.hashPassword(password);
        const user = User{
            .id = id,
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password_hash = hash,
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
            .last_login = null,
            .is_active = true,
            .is_superuser = is_superuser,
            .mfa_enabled = false,
            .mfa_secret = null,
            .attributes = attrs,
            .password_reset_required = false,
            .is_default_user = false,
            .password_set_by_env = false,
        };
        try self.users.put(id, user);
        try self.audit_log.logUserCreated(id, username);

        // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-001; FEATURE="Runtime Auth Graph Persistence"; ASPECT=UserCreate; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
        // Best-effort: persist new user to auth graph store for durability across restarts.
        self.persistUserCreateToGraph(username, email, hash, is_superuser);

        return id;
    }
    // Backwards compatible wrapper (previous signature without explicit is_superuser; defaults false). Some tests call createUser(username,email,password)
    pub fn createUser(self: *Self, username: []const u8, email: []const u8, password: []const u8) !UserId {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        return self.createUserDetailed(username, email, password, false);
    }
    // CANARY: REQ=REQ-AUTH-POLICY-003; FEATURE="Enhanced Password Validation"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_003_PassphraseValidation; OWNER=security; UPDATED=2025-09-30
    pub fn validatePassword(self: *Self, password: []const u8) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        if (password.len < self.password_policy.min_length) return error.PasswordTooShort;
        if (password.len > self.password_policy.max_length) return error.PasswordTooLong;

        // Check for spaces if not allowed
        if (!self.password_policy.allow_spaces) {
            for (password) |c| {
                if (c == ' ') return error.PasswordContainsSpaces;
            }
        }

        if (self.password_policy.require_uppercase) {
            var up = false;
            for (password) |c| {
                if (std.ascii.isUpper(c)) {
                    up = true;
                    break;
                }
            }
            if (!up) return error.PasswordMissingUppercase;
        }
        if (self.password_policy.require_lowercase) {
            var lo = false;
            for (password) |c| {
                if (std.ascii.isLower(c)) {
                    lo = true;
                    break;
                }
            }
            if (!lo) return error.PasswordMissingLowercase;
        }
        if (self.password_policy.require_digit) {
            var dig = false;
            for (password) |c| {
                if (std.ascii.isDigit(c)) {
                    dig = true;
                    break;
                }
            }
            if (!dig) return error.PasswordMissingDigit;
        }
        if (self.password_policy.require_special) {
            var sp = false;
            for (password) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != ' ') {
                    sp = true;
                    break;
                }
            }
            if (!sp) return error.PasswordMissingSpecial;
        }

        // Passphrase validation
        if (self.password_policy.require_passphrase) {
            const word_count = PasswordPolicy.countPassphraseWords(password);
            if (word_count < self.password_policy.min_words) {
                return error.PasswordNotPassphrase;
            }
        }
    }

    // CANARY: REQ=REQ-AUTH-DEFAULT-001; FEATURE="Default User Creation"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_DEFAULT_001_DefaultUser; OWNER=security; UPDATED=2025-09-30
    fn initializeDefaultUser(self: *Self) !void {
        // Get configurable admin username from environment or use default
        // Zig 0.16: std.process.getEnvVarOwned removed; use std.c.getenv (no allocation)
        const admin_username: []const u8 = if (std.c.getenv("GEODE_ADMIN_USERNAME")) |p| std.mem.span(p) else "geode";

        // Check if default user already exists
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, admin_username)) {
                return; // Default user already exists
            }
        }

        // GAP-0146: Generate random password in production if env var not set
        // CANARY: REQ=REQ-DEFAULT-PASSWORD-001; FEATURE="Secure Default Password"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/gap_153_154_password_security.yml; OWNER=security; UPDATED=2026-01-13
        const default_password_env = getEnvVarOwned(self.allocator, "GEODE_DEFAULT_PASSWORD") catch null;
        const password_from_env = default_password_env != null;

        // Generate or use provided password
        var generated_password_buf: [32]u8 = undefined;
        var generated_password_hex: [64]u8 = undefined;
        const default_password: []const u8 = blk: {
            if (default_password_env) |env| {
                break :blk env;
            }
            // SEC-04: Generate cryptographically random password in ALL build modes.
            // No hardcoded fallback — always random when env var is not set.
            try crypto_backend.Csprng.bytes(&generated_password_buf);
            generated_password_hex = std.fmt.bytesToHex(generated_password_buf, .lower);

            // SEC-05: Write generated password to a file instead of stderr.
            // This prevents password leakage into log aggregators or terminal scrollback.
            // SONNY-2778: only under an explicit data directory
            // (GEODE_DATA_DIR), with `writeAdminPasswordFile`. It was written
            // to the current working directory when none was set: a test run
            // left one in a source worktree.
            const data_dir = getEnvVarOwned(self.allocator, "GEODE_DATA_DIR") catch null;
            defer if (data_dir) |d| self.allocator.free(d);
            if (data_dir) |dir| {
                if (writeAdminPasswordFile(self.allocator, dir, generated_password_hex[0..64])) |pw_path| {
                    defer self.allocator.free(pw_path);
                    std.debug.print("\n[GEODE SECURITY] WARNING: Auto-generated admin password written to disk: {s} (mode 0600)\n" ++
                        "[GEODE SECURITY] WARNING: Set GEODE_DEFAULT_PASSWORD env var for production.\n\n", .{pw_path});
                } else |err| {
                    log.warn("Failed to create admin password file", &.{
                        Attr.string("data_dir", dir),
                        Attr.string("error", @errorName(err)),
                    });
                    // Fallback: print location hint only (no password) so operator knows something went wrong
                    std.debug.print("\n[GEODE SECURITY] Could not write the admin password file in {s}: {s}\n" ++
                        "[GEODE SECURITY] An existing file is never overwritten. Set GEODE_DEFAULT_PASSWORD env var to configure the admin password.\n\n", .{ dir, @errorName(err) });
                }
            } else {
                std.debug.print("\n[GEODE SECURITY] No data directory (GEODE_DATA_DIR) is set, so the generated admin password was not written anywhere.\n" ++
                    "[GEODE SECURITY] Set GEODE_DEFAULT_PASSWORD env var to configure the admin password.\n\n", .{});
            }

            log.warn("Generated random admin password — see password file in data directory", &.{
                Attr.string("action", "Set GEODE_DEFAULT_PASSWORD env var to use a custom password"),
            });
            break :blk generated_password_hex[0..64];
        };
        defer if (default_password_env) |env| self.allocator.free(env);

        // Create default user
        const id = @as(UserId, @intCast(self.users.count() + 1));
        const attrs = std.StringHashMap([]const u8).init(self.allocator);

        // Hash the password.
        // SONNY-2394: only an OPERATOR-supplied password (GEODE_DEFAULT_PASSWORD)
        // goes through the human-password policy (`hashPassword` validates
        // first). The generated fallback is 32 CSPRNG bytes rendered as 64
        // lowercase hex -- a single "word" with no uppercase -- so the
        // passphrase policy (upper+lower, >=3 words) rejected it and
        // `SecurityManager.init` failed whenever GEODE_DEFAULT_PASSWORD was
        // unset (breaking the `geode-auth` tool and every init() caller).
        // Hash the random secret directly, exactly as the production
        // first-boot path (AuthGraphManager bootstrap) already does.
        const password_hash = if (password_from_env)
            try self.hashPassword(default_password)
        else
            try hashPasswordArgon2id(self.allocator, default_password);

        // Default user bootstrap:
        // - Allow login when an explicit password is provided (env or debug default),
        //   otherwise the system is unusable without a separate reset workflow.
        // - We still log a high-severity warning so operators rotate credentials promptly.
        const needs_reset = false;

        const user = User{
            .id = id,
            .username = try self.allocator.dupe(u8, admin_username),
            .email = try self.allocator.dupe(u8, "admin@geode.local"),
            .password_hash = password_hash,
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
            .last_login = null,
            .is_active = true,
            .is_superuser = true,
            .mfa_enabled = false,
            .mfa_secret = null,
            .attributes = attrs,
            .password_reset_required = needs_reset,
            .is_default_user = true,
            .password_set_by_env = password_from_env,
        };

        try self.users.put(id, user);
        try self.audit_log.logUserCreated(id, admin_username);

        // SECURITY FIX (C5): Log with HIGH severity - default credentials are critical security event
        const password_source = if (password_from_env)
            "environment"
        else if (builtin.mode != .Debug)
            "generated"
        else
            "debug_default";
        try self.audit_log.append(.user_created, id, "DEFAULT_USER_CREATED username={s} password_source={s} RECOMMENDED_ROTATION", .{ admin_username, password_source });

        if (password_from_env) {
            log.warn("Default user created with env password - rotate after bootstrap", &.{
                Attr.string("warning", "Ensure GEODE_DEFAULT_PASSWORD is not in git/logs"),
            });
        }
    }

    // Check if a user requires password reset
    pub fn requiresPasswordReset(self: *Self, user_id: UserId) !bool {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const user = self.users.get(user_id) orelse return error.UserNotFound;
        return user.password_reset_required;
    }

    // Force password reset for a user
    pub fn forcePasswordReset(self: *Self, user_id: UserId) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        const user = self.users.getPtr(user_id) orelse return error.UserNotFound;
        user.password_reset_required = true;
        user.updated_at = compat_milliTimestamp();
        try self.audit_log.append(.user_updated, user_id, "Password reset forced", .{});
    }

    /// Look up a user's ID by username. Returns null if no matching user found.
    pub fn getUserIdByUsername(self: *Self, username: []const u8) ?UserId {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    // Update password and clear reset requirement
    pub fn updatePassword(self: *Self, user_id: UserId, new_password: []const u8) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        return self.updatePasswordLocked(user_id, new_password);
    }

    fn updatePasswordLocked(self: *Self, user_id: UserId, new_password: []const u8) !void {
        // CANARY: REQ=REQ-AUTH-POLICY-009; FEATURE="Password Update Policy Validation"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_009_UpdateValidation; OWNER=security; UPDATED=2025-09-30
        // Validate new password against current policy before accepting
        try self.validatePasswordAgainstCurrentPolicy(new_password);

        const user = self.users.getPtr(user_id) orelse return error.UserNotFound;

        // Hash new password
        const new_hash = try self.hashPassword(new_password);

        // Free old password hash
        self.allocator.free(user.password_hash);

        // Update user
        user.password_hash = new_hash;
        user.password_reset_required = false;
        user.updated_at = compat_milliTimestamp();
        user.auth_version += 1;

        // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-005; FEATURE="Runtime Auth Graph Persistence"; ASPECT=PasswordChange; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
        // Best-effort: persist new password hash to auth graph store for durability.
        if (self.persistPasswordToGraph(user_id, new_hash)) |version| {
            user.auth_version = version;
        }

        try self.audit_log.append(.user_updated, user_id, "Password updated", .{});
    }
    fn initializeDefaultRoles(self: *Self) !void {
        _ = try self.createRole("user", "Default user role");
        _ = try self.createRole("admin", "Administrator role");
        _ = try self.createRole("viewer", "Read-only role");
        const readp = try self.createPermission("read_all", "graph", .read);
        _ = try self.createPermission("write_all", "graph", .update);
        const adminp = try self.createPermission("admin_all", "system", .all);
        try self.grantPermission(1, readp.id);
        try self.grantPermission(2, adminp.id);
        try self.grantPermission(3, readp.id);
        // GAP-0220 FIX: Use try for proper error propagation
        try self.rbac.role_hierarchy.put(2, try std.ArrayList(RoleId).initCapacity(self.allocator, 0));
        try self.rbac.role_hierarchy.getPtr(2).?.append(self.allocator, 1);
    }
    // CANARY: REQ=REQ-AUTH-POLICY-005; FEATURE="Password Policy Validation Before Hashing"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_005_PreHashValidation; OWNER=security; UPDATED=2025-09-30
    pub fn validatePasswordAgainstCurrentPolicy(self: *Self, password: []const u8) !void {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        // Pre-hash validation against current policy
        try self.validatePassword(password);
    }

    // Check if stored password hash meets current policy requirements
    // CANARY: REQ=REQ-AUTH-POLICY-006; FEATURE="Post-Authentication Policy Check"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_006_PostAuthPolicyCheck; OWNER=security; UPDATED=2025-09-30
    pub fn checkStoredPasswordMeetsCurrentPolicy(self: *Self, _: *User, password: []const u8) bool {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        // Since we can't reverse the hash, we validate the plaintext password
        // that was just successfully authenticated against current policy
        self.validatePassword(password) catch return false;
        return true;
    }

    // ---- Authentication ----
    // Basic password authentication. Returns session token if successful and MFA not required or already satisfied.
    // If MFA required, returns error.MFARequired after logging issuance.
    // CANARY: REQ=REQ-GQL-AUTH-002; FEATURE="Password authentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_AUTH_002_AuthPassword; OWNER=security; UPDATED=2025-09-26
    pub fn authenticate(self: *Self, username: []const u8, password: []const u8) ![]const u8 {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        return self.authenticateLocked(username, password);
    }

    fn authenticateLocked(self: *Self, username: []const u8, password: []const u8) ![]const u8 {
        // Locate user
        var user_opt: ?*User = null;
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                user_opt = entry.value_ptr;
                break;
            }
        }
        const user = user_opt orelse return error.UserNotFound;
        if (!user.is_active) return error.UserDisabled;

        // Rate limiting: check if account is currently locked out
        const now_ms = compat_milliTimestamp();
        if (user.lockout_until > 0 and now_ms < user.lockout_until) {
            try self.audit_log.append(.login_failed, user.id, "Authentication blocked: account temporarily locked due to too many failed attempts", .{});
            return error.AccountLocked;
        }

        // If lockout period has expired, reset the counter
        if (user.lockout_until > 0 and now_ms >= user.lockout_until) {
            user.failed_login_attempts = 0;
            user.lockout_until = 0;
            // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-002; FEATURE="Runtime Auth Graph Persistence"; ASPECT=LoginState; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
            self.persistLoginStateToGraph(user.id, 0, 0);
        }

        // CRITICAL SECURITY FIX (C5): Block default users until password changed
        // Prevents authentication with predictable default credentials
        if (user.is_default_user and user.password_reset_required) {
            try self.audit_log.append(.login_failed, user.id, "Authentication blocked: default user must change password", .{});
            return error.DefaultPasswordMustBeChanged;
        }

        // Capture whether this is a legacy Blake2b hash before verifyPassword consumes it,
        // so we can trigger migration after a successful verify.
        const is_legacy_blake2b = user.password_hash.len == 64 and isHexString(user.password_hash);
        if (!try self.verifyPassword(password, user.password_hash)) {
            // Increment failed attempts and potentially lock out
            user.failed_login_attempts += 1;
            if (user.failed_login_attempts >= 5) {
                // Lock account for 5 minutes (300,000 ms)
                user.lockout_until = now_ms + 300_000;
                try self.audit_log.append(.login_failed, user.id, "Account locked: 5 failed login attempts, locked for 5 minutes", .{});
            }
            // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-003; FEATURE="Runtime Auth Graph Persistence"; ASPECT=FailedLogin; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
            self.persistLoginStateToGraph(user.id, user.failed_login_attempts, user.lockout_until);
            try self.audit_log.logFailedLogin(user.id, user.username);
            return error.InvalidCredentials;
        }

        // GAP-0489: Auto-migrate legacy Blake2b accounts to Argon2id on successful login.
        // CWE-760: The Blake2b path uses a static salt; upgrading to Argon2id eliminates this.
        // Migration is best-effort — a failure is logged but does not block the login.
        if (is_legacy_blake2b) {
            if (self.hashPassword(password)) |new_hash| {
                defer self.allocator.free(new_hash);
                self.updateStoredHash(user.id, new_hash) catch |migrate_err| {
                    log.warn("Blake2b migration: failed to update stored hash for user", &.{
                        Attr.string("err", @errorName(migrate_err)),
                    });
                };
                try self.audit_log.append(.user_updated, user.id, "GAP-0489: Migrated legacy Blake2b hash to Argon2id on login", .{});
            } else |hash_err| {
                log.warn("Blake2b migration: failed to hash new password", &.{
                    Attr.string("err", @errorName(hash_err)),
                });
            }
        }

        // Successful login: reset failed attempt counter
        user.failed_login_attempts = 0;
        user.lockout_until = 0;
        // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-004; FEATURE="Runtime Auth Graph Persistence"; ASPECT=SuccessfulLogin; STATUS=TESTED; TEST="SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)"; OWNER=security; UPDATED=2026-06-11
        self.persistLoginStateToGraph(user.id, 0, 0);

        // CANARY: REQ=REQ-AUTH-POLICY-007; FEATURE="Mandatory Password Policy Enforcement"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_007_MandatoryPolicyEnforcement; OWNER=security; UPDATED=2025-09-30
        // Check if the authenticated password meets current policy requirements
        // This is non-bypassable - if password violates policy, force reset
        const password_meets_policy = self.checkStoredPasswordMeetsCurrentPolicy(user, password);
        if (!password_meets_policy) {
            // Force password reset for policy violation
            user.password_reset_required = true;
            user.updated_at = compat_milliTimestamp();
            try self.audit_log.append(.user_updated, user.id, "Password reset forced due to policy violation after successful authentication", .{});
        }

        // Evaluate MFA requirement
        const policy_requires = self.evaluateMfaPolicies(user);
        if (policy_requires and user.mfa_enabled and user.mfa_secret != null) {
            try self.audit_log.logMfaChallengeIssued(user.id, "totp");
            return error.MFARequired;
        }
        // Check if password reset is required (includes policy violations)
        if (user.password_reset_required) {
            try self.audit_log.append(.login_success, user.id, "Login successful but password reset required", .{});
            return error.PasswordResetRequired;
        }

        const token = try self.createSession(user.id);
        try self.audit_log.logSuccessfulLogin(user.id, user.username);
        return token;
    }
    // Complete authentication with MFA code after password stage.
    // Expects that authenticate returned error.MFARequired previously.
    // Returns a new session token on success.
    // CANARY: REQ=REQ-GQL-AUTH-003; FEATURE="MFA authentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_AUTH_003_AuthMFA; OWNER=security; UPDATED=2025-09-26
    // Enhanced to allow either a TOTP code (code param) or a recovery code (if code==0 and recovery_code provided).
    // Recovery codes are single-use; upon successful use it is removed and audited.
    // CANARY: REQ=REQ-GQL-AUTH-004; FEATURE="MFA recovery code"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_AUTH_004_Recovery|TestCANARY_REQ_GQL_MFA_007_RecoverySingleUse; OWNER=security; UPDATED=2025-09-26
    pub fn authenticateWithMFA(self: *Self, username: []const u8, password: []const u8, code: u32, recovery_code: ?[]const u8) ![]const u8 {
        self.auth_mu.lock();
        defer self.auth_mu.unlock();
        return self.authenticateWithMFALocked(username, password, code, recovery_code);
    }

    fn authenticateWithMFALocked(self: *Self, username: []const u8, password: []const u8, code: u32, recovery_code: ?[]const u8) ![]const u8 {
        var user_opt: ?*User = null;
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                user_opt = entry.value_ptr;
                break;
            }
        }
        const user = user_opt orelse return error.UserNotFound;
        if (!user.is_active) return error.UserDisabled;

        // SECURITY FIX (C5): Block default users in MFA path too
        if (user.is_default_user and user.password_reset_required) {
            try self.audit_log.append(.login_failed, user.id, "MFA authentication blocked: default user must change password", .{});
            return error.DefaultPasswordMustBeChanged;
        }

        // Capture whether this is a legacy Blake2b hash before verifyPassword consumes it.
        const is_legacy_blake2b_mfa = user.password_hash.len == 64 and isHexString(user.password_hash);
        if (!try self.verifyPassword(password, user.password_hash)) {
            try self.audit_log.logFailedLogin(user.id, user.username);
            return error.InvalidCredentials;
        }
        // GAP-0489: Auto-migrate legacy Blake2b accounts to Argon2id on successful MFA login.
        if (is_legacy_blake2b_mfa) {
            if (self.hashPassword(password)) |new_hash| {
                defer self.allocator.free(new_hash);
                self.updateStoredHash(user.id, new_hash) catch |migrate_err| {
                    log.warn("Blake2b migration (MFA): failed to update stored hash", &.{
                        Attr.string("err", @errorName(migrate_err)),
                    });
                };
                try self.audit_log.append(.user_updated, user.id, "GAP-0489: Migrated legacy Blake2b hash to Argon2id on MFA login", .{});
            } else |hash_err| {
                log.warn("Blake2b migration (MFA): failed to hash new password", &.{
                    Attr.string("err", @errorName(hash_err)),
                });
            }
        }
        if (!user.mfa_enabled or user.mfa_secret == null) return error.MFADisabled;
        var used_recovery = false;
        if (recovery_code) |rc| {
            // Attempt recovery code path first if provided.
            if (user.recovery_codes) |*codes| {
                var idx: usize = 0;
                while (idx < codes.items.len) : (idx += 1) {
                    if (std.mem.eql(u8, codes.items[idx], rc)) {
                        // Remove the single-use code. SONNY-2394: free it too
                        // -- the removed string used to be discarded (leaked
                        // once per redemption).
                        self.allocator.free(codes.orderedRemove(idx));
                        try self.audit_log.logMfaRecoveryCodeUsed(user.id);
                        used_recovery = true;
                        break;
                    }
                }
            }
            if (!used_recovery and code == 0) {
                try self.audit_log.logMfaChallengeFailure(user.id, "recovery", "invalid_code");
                return error.MFAInvalidCode;
            }
        }
        if (!used_recovery) {
            // Verify TOTP code (30s step, 6 digits, +/-1 window)
            const now = @as(u64, @intCast(compat_milliTimestamp()));
            if (!try ext_mfa.verifyCode(self.allocator, user.mfa_secret.?, now, code, mfa_policy.codeConfig(30, 6, 1))) {
                try self.audit_log.logMfaChallengeFailure(user.id, "totp", "invalid_code");
                return error.MFAInvalidCode;
            }
            try self.audit_log.logMfaChallengeSuccess(user.id, "totp");
        }
        // Note: MFA completion assumes password reset already handled in initial auth
        const token = try self.createSession(user.id);
        // Mark elevation using configured TTL
        self.markStepUp(token, self.elevation_ttl_ms) catch |err| {
            log.warn("Step-up auth marking failed", &.{Attr.string("error", @errorName(err))});
        };
        try self.audit_log.logSuccessfulLogin(user.id, user.username);
        return token;
    }
};

// ============================================================================
// Standalone Argon2id Password Hashing (canonical implementation)
// CANARY: REQ=REQ-AUTH-HASH-002; FEATURE="Canonical Argon2id Hashing"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_HASH_002_StandaloneArgon2id; OWNER=security; UPDATED=2026-02-24
// ============================================================================

/// Canonical Argon2id password hashing with OWASP recommended parameters.
/// Returns a PHC format string: $argon2id$v=19$m=19456,t=2,p=1$<salt_hex>$<hash_hex>
///
/// This is the single source of truth for password hashing in Geode.
/// All components (SecurityManager, user_management, auth_graph_manager) must
/// use this function rather than maintaining their own implementations.
///
/// Parameters (OWASP ASVS 2.4.1):
///   - t=2: 2 iterations (OWASP minimum)
///   - m=19456: 19 MiB memory (OWASP minimum)
///   - p=1: 1 parallel lane
pub fn hashPasswordArgon2id(allocator: Allocator, password: []const u8) ![]const u8 {
    // FIPS: Argon2id is not FIPS-approved — fail closed under -Dfips
    if (build_options.fips) {
        log.err("password hashing unavailable under FIPS: Argon2id is not a FIPS-approved primitive", &.{});
        return error.FipsUnsupported;
    }
    // Generate cryptographically random 16-byte salt
    var salt: [16]u8 = undefined;
    try crypto_backend.Csprng.bytes(&salt);

    // OWASP recommended Argon2id parameters (ASVS 2.4.1)
    const argon2_params = std.crypto.pwhash.argon2.Params{
        .t = 2, // 2 iterations (OWASP minimum)
        .m = 19456, // 19 MiB memory (OWASP minimum)
        .p = 1, // 1 parallel lane
    };

    // Hash password with Argon2id
    var hash: [32]u8 = undefined;
    std.crypto.pwhash.argon2.kdf(
        allocator,
        &hash,
        password,
        &salt,
        argon2_params,
        .argon2id,
        std.Io.Threaded.global_single_threaded.io(),
    ) catch |err| {
        log.err("Argon2id hashing failed", &.{
            Attr.string("error", @errorName(err)),
        });
        return error.HashingFailed;
    };

    // Encode as PHC string format: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
    const hex_chars = "0123456789abcdef";

    // Encode salt as hex
    var salt_hex: [32]u8 = undefined;
    for (salt, 0..) |byte, i| {
        salt_hex[i * 2] = hex_chars[byte >> 4];
        salt_hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }

    // Encode hash as hex
    var hash_hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        hash_hex[i * 2] = hex_chars[byte >> 4];
        hash_hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }

    // Create PHC format string
    return std.fmt.allocPrint(
        allocator,
        "$argon2id$v=19$m=19456,t=2,p=1${s}${s}",
        .{ &salt_hex, &hash_hex },
    );
}

// SONNY-6378: bounds on the parameters of a stored Argon2id hash. A stored
// hash is untrusted input; without bounds a corrupt `t` (up to 2^32-1
// passes) or `m` (up to 4 TiB) made every login against it burn CPU or
// memory. The bounds admit the hashes Geode writes (m=19456, t=2, p=1) and
// RFC 9106's second recommended option (m=64 MiB, t=3, p=4).
pub const argon2_max_t: u32 = 10;
pub const argon2_max_m_kib: u32 = 256 * 1024;
pub const argon2_max_p: u24 = 16;

/// The static salt of the legacy BLAKE2b password format.
const legacy_blake2b_salt = "geode-salt-secure-v2";

/// SONNY-6367: whether `stored_hash` is in the legacy BLAKE2b format: 64 hex
/// digits (BLAKE2b-256 of the password followed by a static salt), the format
/// `geode user import --algorithm blake2b` and `geode.auth.user_import(...,
/// 'blake2b')` take for migration.
pub fn isLegacyBlake2bHash(stored_hash: []const u8) bool {
    if (stored_hash.len != 64) return false;
    for (stored_hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// CANARY: REQ=REQ-SONNY-6367-BLAKE2B-LOGIN; FEATURE="AdminUserImport"; ASPECT=LegacyBlake2bVerify; STATUS=TESTED; TEST=tests/test_sonny6367_offline_user_cli.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6367: verify `password` against a legacy BLAKE2b hash
/// (`isLegacyBlake2bHash`; hex digits of either case), comparing the digests
/// in constant time. The wire login verified only Argon2id, so a user
/// imported with a BLAKE2b hash could never log in. `error.FipsUnsupported`
/// under FIPS (BLAKE2b is not a FIPS-approved primitive);
/// `error.InvalidHashFormat` for any other format.
pub fn verifyPasswordBlake2bLegacy(password: []const u8, stored_hash: []const u8) !bool {
    if (build_options.fips) {
        log.err("password verification unavailable under FIPS: BLAKE2b is not a FIPS-approved primitive", &.{});
        return error.FipsUnsupported;
    }
    if (!isLegacyBlake2bHash(stored_hash)) return error.InvalidHashFormat;
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, stored_hash) catch return error.InvalidHashFormat;
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    hasher.update(password);
    hasher.update(legacy_blake2b_salt);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return crypto_backend.timingSafeEql(&digest, &expected);
}

/// Canonical Argon2id password verification against PHC format strings.
/// Parses the PHC string to extract parameters, salt, and expected hash,
/// then re-derives the hash and compares using constant-time equality.
///
/// Supports Argon2id PHC strings with parameters other than the OWASP ones
/// Geode writes, enabling verification of hashes created with different
/// parameter sets during migration, within the bounds below.
pub fn verifyPasswordArgon2id(allocator: Allocator, password: []const u8, phc_string: []const u8) !bool {
    // FIPS: Argon2id is not FIPS-approved — fail closed under -Dfips
    if (build_options.fips) {
        log.err("password verification unavailable under FIPS: Argon2id is not a FIPS-approved primitive", &.{});
        return error.FipsUnsupported;
    }
    // Parse PHC string: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
    var parts = std.mem.splitScalar(u8, phc_string, '$');

    _ = parts.next(); // Empty before first $
    const alg = parts.next() orelse return false;
    if (!std.mem.eql(u8, alg, "argon2id")) return false;

    const version = parts.next() orelse return false;
    if (!std.mem.eql(u8, version, "v=19")) return false;

    const params_str = parts.next() orelse return false;
    // Parse params: m=19456,t=2,p=1
    // SONNY-6374: a stored hash is untrusted input. An unparseable or
    // out-of-range parameter refuses the hash (it used to fall back to the
    // default), and `p` is parsed straight into Argon2's u24 lane count: a
    // corrupt p above 2^24-1 panicked the @intCast below in safe builds.
    var param_parts = std.mem.splitScalar(u8, params_str, ',');
    var m: u32 = 19456;
    var t: u32 = 2;
    var p: u24 = 1;

    while (param_parts.next()) |param| {
        var kv = std.mem.splitScalar(u8, param, '=');
        const key = kv.next() orelse continue;
        const value = kv.next() orelse continue;

        if (std.mem.eql(u8, key, "m")) {
            m = std.fmt.parseInt(u32, value, 10) catch return false;
        } else if (std.mem.eql(u8, key, "t")) {
            t = std.fmt.parseInt(u32, value, 10) catch return false;
        } else if (std.mem.eql(u8, key, "p")) {
            p = std.fmt.parseInt(u24, value, 10) catch return false;
        }
    }

    // SONNY-6378: refuse out-of-bounds parameters before running Argon2.
    // Argon2 needs at least 8 KiB of memory per lane.
    if (t < 1 or t > argon2_max_t) return false;
    if (p < 1 or p > argon2_max_p) return false;
    if (m > argon2_max_m_kib or m < 8 * @as(u32, p)) return false;

    const salt_hex = parts.next() orelse return false;
    const hash_hex = parts.next() orelse return false;

    // Decode salt from hex
    if (salt_hex.len != 32) return false; // 16 bytes = 32 hex chars
    var salt: [16]u8 = undefined;
    for (0..16) |i| {
        const hi = std.fmt.charToDigit(salt_hex[i * 2], 16) catch return false;
        const lo = std.fmt.charToDigit(salt_hex[i * 2 + 1], 16) catch return false;
        salt[i] = @as(u8, hi) * 16 + @as(u8, lo);
    }

    // Decode expected hash from hex
    if (hash_hex.len != 64) return false; // 32 bytes = 64 hex chars
    var expected_hash: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = std.fmt.charToDigit(hash_hex[i * 2], 16) catch return false;
        const lo = std.fmt.charToDigit(hash_hex[i * 2 + 1], 16) catch return false;
        expected_hash[i] = @as(u8, hi) * 16 + @as(u8, lo);
    }

    // Re-hash password with same salt and params
    const argon2_params = std.crypto.pwhash.argon2.Params{
        .t = t,
        .m = m,
        .p = p,
    };

    var computed_hash: [32]u8 = undefined;
    std.crypto.pwhash.argon2.kdf(
        allocator,
        &computed_hash,
        password,
        &salt,
        argon2_params,
        .argon2id,
        std.Io.Threaded.global_single_threaded.io(),
    ) catch return false;

    // Constant-time comparison to prevent timing attacks
    return crypto_backend.timingSafeEql(&computed_hash, &expected_hash);
}

// ============================================================================
// Unit Tests for GAP-0149: Fail-Secure Risk Score Parsing
// CANARY: REQ=REQ-AUTH-RISKSCORE-001; FEATURE="FailSecureRiskScore"; ASPECT=TEST; STATUS=TESTED; OWNER=security; UPDATED=2026-01-13
// ============================================================================

test "SecurityManager.deinit releases default startup allocations" {
    // Zig 0.16 removed std.posix.setenv; use libc directly (test-scoped).
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;

        fn save(a: Allocator, name: [*:0]const u8) !?[:0]u8 {
            return if (std.c.getenv(name)) |v| try a.dupeZ(u8, std.mem.span(v)) else null;
        }
        fn restore(a: Allocator, name: [*:0]const u8, saved: ?[:0]u8) void {
            if (saved) |v| {
                _ = setenv(name, v.ptr, 1);
                a.free(v);
            } else _ = unsetenv(name);
        }
    };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Hermetic env. SONNY-2394 regression: with GEODE_DEFAULT_PASSWORD unset,
    // init() generates a random admin secret, which the human-password
    // passphrase policy used to reject (init() failed with
    // PasswordMissingUppercase). GEODE_DATA_DIR points the generated-password
    // file at a tmp dir so the test never writes `.geode_admin_password` into
    // the build root.
    //
    // Memoize Zig's own view of the environment FIRST. Zig 0.16 scans its
    // startup envp lazily (first std.debug.print, first spawn, ...) and
    // panics on a NULL inside the captured slice -- which an in-place libc
    // unsetenv of a variable present at startup leaves behind; the panic
    // handler then deadlocks re-taking the environ mutex (SONNY-2394: this
    // test hung whenever GEODE_DEFAULT_PASSWORD was exported by the caller).
    _ = std.Io.Threaded.global_single_threaded.environString("PATH");
    const saved_pw = try c.save(allocator, "GEODE_DEFAULT_PASSWORD");
    defer c.restore(allocator, "GEODE_DEFAULT_PASSWORD", saved_pw);
    const saved_dir = try c.save(allocator, "GEODE_DATA_DIR");
    defer c.restore(allocator, "GEODE_DATA_DIR", saved_dir);
    _ = c.unsetenv("GEODE_DEFAULT_PASSWORD");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer allocator.free(data_dir);
    try std.testing.expect(c.setenv("GEODE_DATA_DIR", data_dir.ptr, 1) == 0);

    var sm = try SecurityManager.init(allocator);
    defer sm.deinit();

    // The generated secret was handed to the operator via the password file
    // and is the credential actually stored for the default admin.
    const written = try tmp.dir.readFileAlloc(std.testing.io, ".geode_admin_password", allocator, .limited(256));
    defer allocator.free(written);
    try std.testing.expectEqual(@as(usize, 64), written.len);
    var admin: ?*User = null;
    var it = sm.users.valueIterator();
    while (it.next()) |u| {
        if (u.is_default_user) admin = u;
    }
    try std.testing.expect(admin != null);
    try std.testing.expect(try verifyPasswordArgon2id(allocator, written, admin.?.password_hash));
}

test "SecurityManager.deinit releases hydrated runtime state" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var sm = try SecurityManager.initEmpty(allocator);
    defer sm.deinit();

    const role = try sm.createRole("reader", "Hydrated role");
    const perm = try sm.createPermission("read_graph", "graph", .read);
    perm.conditions = try allocator.dupe(u8, "tenant_id = 7");
    try sm.grantPermission(role.id, perm.id);

    var parents = std.ArrayList(RoleId).empty;
    try parents.append(allocator, role.id);
    try sm.rbac.role_hierarchy.put(role.id, parents);

    try sm.hydrateUser(
        42,
        "alice",
        "alice@example.com",
        "$argon2id$v=19$m=19456,t=2,p=1$00112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        false,
        true,
        false,
        false,
        true,
        "SECRET42",
        7,
        "{\"risk_score\":\"77\",\"department\":\"eng\"}",
    );
    try sm.assignRole(42, role.id);

    if (sm.users.getPtr(42)) |user| {
        user.recovery_codes = std.ArrayList([]const u8).empty;
        try user.recovery_codes.?.append(allocator, try allocator.dupe(u8, "recover-1"));
        try user.recovery_codes.?.append(allocator, try allocator.dupe(u8, "recover-2"));
    } else {
        return error.TestUnexpectedResult;
    }

    const session_token = try sm.createSession(42);
    if (sm.sessions.getPtr(session_token)) |session| {
        session.ip_address = try allocator.dupe(u8, "127.0.0.1");
        session.user_agent = try allocator.dupe(u8, "zig-test");
    } else {
        return error.TestUnexpectedResult;
    }

    const subject_conditions = [_]AttributeCondition{
        .{
            .attribute = "department",
            .operator = .equals,
            .value = .{ .string = "eng" },
        },
    };
    const resource_conditions = [_]AttributeCondition{
        .{
            .attribute = "name",
            .operator = .equals,
            .value = .{ .string = "graph" },
        },
    };
    const actions = [_]Action{.read};
    const env_conditions = [_]EnvironmentCondition{};
    try sm.createABACPolicy(.{
        .id = 1,
        .name = "allow-eng-read",
        .description = "Allow readers from engineering",
        .effect = .allow,
        .subjects = &subject_conditions,
        .resources = &resource_conditions,
        .actions = &actions,
        .conditions = &env_conditions,
        .priority = 1,
        .enabled = true,
    });

    const row_roles = [_]RoleId{role.id};
    try sm.createRowLevelPolicy(.{
        .id = 2,
        .name = "tenant-read-filter",
        .table = "nodes",
        .operation = .select,
        .using_clause = "n.tenant_id = 7",
        .check_clause = null,
        .roles = &row_roles,
        .enabled = true,
    });

    const mfa_roles = [_]RoleId{role.id};
    try sm.addMfaPolicy(.{
        .id = 3,
        .enabled = true,
        .scope = .role,
        .roles = &mfa_roles,
        .condition = .match_any_role,
    });
    try sm.mfa_require_cache.put(42, true);
}

test "parseRiskScore: valid numeric string parses correctly" {
    const parsed = std.fmt.parseInt(u8, "50", 10) catch 255;
    try std.testing.expectEqual(@as(u8, 50), parsed);
}

test "parseRiskScore: invalid string returns 255 (max risk)" {
    const parsed = std.fmt.parseInt(u8, "invalid", 10) catch 255;
    try std.testing.expectEqual(@as(u8, 255), parsed);
}

test "parseRiskScore: empty string returns 255 (max risk)" {
    const parsed = std.fmt.parseInt(u8, "", 10) catch 255;
    try std.testing.expectEqual(@as(u8, 255), parsed);
}

test "parseRiskScore: overflow value returns 255 (max risk)" {
    // 256 is too large for u8
    const parsed = std.fmt.parseInt(u8, "256", 10) catch 255;
    try std.testing.expectEqual(@as(u8, 255), parsed);
}

test "parseRiskScore: negative value returns 255 (max risk)" {
    const parsed = std.fmt.parseInt(u8, "-1", 10) catch 255;
    try std.testing.expectEqual(@as(u8, 255), parsed);
}

test "parseRiskScore: boundary value 0 parses correctly" {
    const parsed = std.fmt.parseInt(u8, "0", 10) catch 255;
    try std.testing.expectEqual(@as(u8, 0), parsed);
}

test "parseRiskScore: boundary value 255 parses correctly" {
    const parsed = std.fmt.parseInt(u8, "255", 10) catch 255;
    try std.testing.expectEqual(@as(u8, 255), parsed);
}
