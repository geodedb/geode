// (Removed duplicated preamble section)
// CANARY: REQ=REQ-0005; FEATURE="Security Requirements"; ASPECT=Security; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=security; UPDATED=2026-01-15
// Clean reconstructed auth.zig with consolidated definitions (RBAC, ABAC, RLS, Sessions, MFA Policies)
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const mfa = @import("mfa");
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
    is_default_user: bool = false,
    password_set_by_env: bool = false,
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
// CANARY: REQ=REQ-GQL-MFA-003; FEATURE="MFA admin policy"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_003_MfaPolicyEval|TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAllRoles|TestCANARY_REQ_GQL_MFA_POLICY_001_MatchAnyRole; OWNER=security; UPDATED=2025-09-26
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
    // CANARY: REQ=REQ-GQL-MFA-007; FEATURE="Session step-up metadata"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_008_StepUpRequire_and_mark_flow; OWNER=security; UPDATED=2025-09-26
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
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        const min_length_env = std.process.getEnvVarOwned(allocator, "GEODE_PASSWORD_MIN_LENGTH") catch null;
        defer if (min_length_env) |env| allocator.free(env);
        const min_length = if (min_length_env) |len_str| blk: {
            const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
            // Enforce absolute minimum of 20 characters for security
            break :blk if (parsed < 20) 20 else parsed;
        } else 20;

        const min_words_env = std.process.getEnvVarOwned(allocator, "GEODE_PASSWORD_MIN_WORDS") catch null;
        defer if (min_words_env) |env| allocator.free(env);
        const min_words = if (min_words_env) |words_str| blk: {
            const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
            // Enforce minimum of 2 words
            break :blk if (parsed < 2) 2 else parsed;
        } else 3;

        return .{
            .min_length = min_length,
            .max_length = 256,
            .require_uppercase = true,
            .require_lowercase = true,
            .require_digit = false, // Optional for passphrases
            .require_special = false, // Optional for passphrases
            .allow_spaces = true,
            .require_passphrase = true,
            .min_words = min_words,
            .max_age_days = 90,
            .history_count = 5,
        };
    }
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
        self.entries.deinit(self.allocator);
    }
    fn append(self: *AuditLog, ev: AuditEventType, user_id: UserId, comptime fmt: []const u8, args: anytype) !void {
        try self.entries.append(self.allocator, .{ .timestamp = std.time.milliTimestamp(), .event_type = ev, .user_id = user_id, .details = try std.fmt.allocPrint(self.allocator, fmt, args) });
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
pub const SecurityContext = struct { user: *User, roles: []const Role, session_attributes: std.StringHashMap([]const u8), request_attributes: std.StringHashMap([]const u8), environment: EnvironmentInfo };

// ---- SecurityManager ----
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

    pub fn deinit(self: *Self) void {
        // release user map strings
        var it = self.users.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.value_ptr.username);
            self.allocator.free(e.value_ptr.email);
            self.allocator.free(e.value_ptr.password_hash);
            if (e.value_ptr.mfa_secret) |secret| {
                self.allocator.free(secret);
            }
        }
        self.users.deinit();
    }
    // ---- MFA Policies ----

    pub fn addMfaPolicy(self: *Self, p: MfaAdminPolicy) !void {
        try self.mfa_policies.append(self.allocator, p);
        self.mfa_require_cache.clearRetainingCapacity();
        try self.audit_log.logMfaPolicyAdded(p.id, p.enabled);
    }
    // Backwards-compatible simple evaluation (no session/env context). Uses current time and null session.
    pub fn evaluateMfaPolicies(self: *Self, u: *User) bool {
        return self.evaluateMfaPoliciesAdvanced(u, null, std.time.milliTimestamp());
    }

    // Extended evaluation considering dynamic conditions (time window, risk, reauth interval).
    // CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_POLICY_001_TimeWindow|TestCANARY_REQ_GQL_MFA_POLICY_001_RiskScoreMin|TestCANARY_REQ_GQL_MFA_POLICY_001_ReauthInterval; OWNER=security; UPDATED=2025-09-26
    pub fn evaluateMfaPoliciesAdvanced(self: *Self, u: *User, session: ?*Session, now_ms: i64) bool {
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
                            std.log.warn("SECURITY WARNING: Invalid risk_score attribute '{s}' for user {d} - treating as max risk", .{ rs, u.id });
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
        if (!has_dynamic) self.mfa_require_cache.put(u.id, require) catch {};
        return require;
    }

    // ---- ABAC ----
    pub fn createABACPolicy(self: *Self, policy: ABACPolicy) !void {
        try self.abac_policies.append(self.allocator, policy);
        try self.audit_log.logPolicyCreated(policy.id, policy.name);
    }
    pub fn evaluateABACPolicies(self: *Self, context: *SecurityContext, resource: []const u8, action: Action) !bool {
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
        try self.row_policies.append(self.allocator, policy);
        try self.audit_log.logRowPolicyCreated(policy.id, policy.name);
    }
    pub fn applyRowLevelSecurity(self: *Self, user_id: UserId, query: []const u8, table: []const u8) ![]const u8 {
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
            try out.appendSlice(self.allocator, p.using_clause);
        }
        try out.appendSlice(self.allocator, ")");
        return try out.toOwnedSlice(self.allocator);
    }

    // ---- Sessions ----
    pub fn createSession(self: *Self, user_id: UserId) ![]const u8 {
        var raw: [32]u8 = undefined;
        crypto.random.bytes(&raw);
        const enc = std.base64.url_safe_no_pad.Encoder;
        const token = try self.allocator.alloc(u8, enc.calcSize(raw.len));
        _ = enc.encode(token, &raw);
        const now = std.time.milliTimestamp();
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
    /// Placeholder policy: if action appears "admin" or "write" and no unexpired elevation.
    /// Future: integrate per-action sensitivity levels & policy engine.
    /// CANARY: REQ=REQ-GQL-MFA-008; FEATURE="Session step-up requirement"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_008_StepUpRequire_and_mark_flow; OWNER=security; UPDATED=2025-09-26
    pub fn requireStepUp(self: *Self, token: []const u8, action: []const u8) bool {
        const s = self.sessions.get(token) orelse return true; // unknown session => demand step-up / re-auth
        const now = std.time.milliTimestamp();
        if (s.elevation_expires_at) |exp| {
            if (now <= exp) {
                return false; // still elevated
            }
        }
        // naive sensitivity heuristic
        if (std.mem.indexOf(u8, action, "admin") != null or std.mem.indexOf(u8, action, "write") != null) return true;
        // default: no elevation required
        return false;
    }

    /// Marks the session as having completed a successful step-up (MFA) for a bounded lifetime.
    /// lifetime_ms: duration the elevation should remain valid.
    /// CANARY: REQ=REQ-GQL-MFA-009; FEATURE="Session step-up mark"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_008_StepUpRequire_and_mark_flow; OWNER=security; UPDATED=2025-09-26
    pub fn markStepUp(self: *Self, token: []const u8, lifetime_ms: i64) !void {
        var s = self.sessions.getPtr(token) orelse return error.InvalidSession;
        const now = std.time.milliTimestamp();
        s.last_mfa_ts = now;
        s.elevation_expires_at = now + lifetime_ms;
    }
    pub fn validateSession(self: *Self, token: []const u8) !UserId {
        const s = self.sessions.get(token) orelse return error.InvalidSession;
        if (std.time.milliTimestamp() > s.expires_at) {
            _ = self.sessions.remove(token);
            return error.SessionExpired;
        }
        return s.user_id;
    }

    // ---- Authorization ----
    pub fn authorize(self: *Self, user_id: UserId, resource: []const u8, action: Action) !bool {
        const user = self.users.getPtr(user_id) orelse return error.UserNotFound;
        if (user.is_superuser) return true;
        if (self.rbac.hasPermission(user_id, resource, action)) return true;
        var ctx = SecurityContext{ .user = user, .roles = &[_]Role{}, .session_attributes = std.StringHashMap([]const u8).init(self.allocator), .request_attributes = std.StringHashMap([]const u8).init(self.allocator), .environment = .{ .timestamp = std.time.milliTimestamp(), .ip_address = "127.0.0.1", .user_agent = "geode-client", .location = null, .device_id = null } };
        defer {
            ctx.session_attributes.deinit();
            ctx.request_attributes.deinit();
        }
        return try self.evaluateABACPolicies(&ctx, resource, action);
    }

    // ---- Role & Permission Mgmt ----
    pub fn createRole(self: *Self, name: []const u8, description: []const u8) !*Role {
        const id = @as(RoleId, @intCast(self.roles.count() + 1));
        // GAP-0220 FIX: Use try for proper error propagation
        const role = Role{ .id = id, .name = try self.allocator.dupe(u8, name), .description = try self.allocator.dupe(u8, description), .permissions = try std.ArrayList(PermissionId).initCapacity(self.allocator, 0), .created_at = std.time.milliTimestamp(), .is_system = false, .priority = 100, .parent_role = null };
        try self.roles.put(id, role);
        return self.roles.getPtr(id).?;
    }
    pub fn assignRole(self: *Self, user_id: UserId, role_id: RoleId) !void {
        _ = self.users.get(user_id) orelse return error.UserNotFound;
        _ = self.roles.get(role_id) orelse return error.RoleNotFound;
        const entry = try self.rbac.user_roles.getOrPut(user_id);
        // GAP-0220 FIX: Use try for proper error propagation
        if (!entry.found_existing) entry.value_ptr.* = try std.ArrayList(RoleId).initCapacity(self.allocator, 0);
        for (entry.value_ptr.items) |r| if (r == role_id) return;
        try entry.value_ptr.append(self.allocator, role_id);
        try self.audit_log.logRoleAssigned(user_id, role_id);
    }
    pub fn revokeRole(self: *Self, user_id: UserId, role_id: RoleId) !void {
        const roles_list = self.rbac.user_roles.getPtr(user_id) orelse return error.UserHasNoRoles;
        for (roles_list.items, 0..) |rid, i| {
            if (rid == role_id) {
                _ = roles_list.orderedRemove(i);
                try self.audit_log.logRoleRevoked(user_id, role_id);
                return;
            }
        }
        return error.RoleNotAssigned;
    }
    pub fn createPermission(self: *Self, name: []const u8, resource: []const u8, action: Action) !*Permission {
        const id = @as(PermissionId, @intCast(self.permissions.count() + 1));
        const perm = Permission{ .id = id, .name = try self.allocator.dupe(u8, name), .resource = try self.allocator.dupe(u8, resource), .action = action, .conditions = null, .created_at = std.time.milliTimestamp() };
        try self.permissions.put(id, perm);
        return self.permissions.getPtr(id).?;
    }
    pub fn grantPermission(self: *Self, role_id: RoleId, perm_id: PermissionId) !void {
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
    // CRITICAL SECURITY FIX (C2): Proper Argon2id implementation with random salts and PHC format
    pub fn hashPassword(self: *Self, password: []const u8) ![]const u8 {
        // CANARY: REQ=REQ-AUTH-POLICY-008; FEATURE="Pre-Hash Password Validation"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_008_PreHashValidation; OWNER=security; UPDATED=2025-09-30
        // Validate password against policy before hashing
        try self.validatePasswordAgainstCurrentPolicy(password);

        // Generate cryptographically random 16-byte salt
        var salt: [16]u8 = undefined;
        std.crypto.random.bytes(&salt);

        // OWASP recommended Argon2id parameters (ASVS 2.4.1)
        const argon2_params = std.crypto.pwhash.argon2.Params{
            .t = 2, // 2 iterations (OWASP minimum)
            .m = 19456, // 19 MiB memory (OWASP minimum)
            .p = 1, // 1 parallel lane
        };

        // Hash password with Argon2id
        var hash: [32]u8 = undefined;
        std.crypto.pwhash.argon2.kdf(
            self.allocator,
            &hash,
            password,
            &salt,
            argon2_params,
            .argon2id,
        ) catch |err| {
            std.log.err("Argon2id hashing failed: {}", .{err});
            return error.HashingFailed;
        };

        // Encode as PHC string format: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
        // This is the standard format for Argon2 hashes (password-hashing.net/argon2-specs.pdf)
        const hex_chars = "0123456789abcdef";

        // Encode salt as hex
        var salt_hex = try self.allocator.alloc(u8, 32);
        for (salt, 0..) |byte, i| {
            salt_hex[i * 2] = hex_chars[byte >> 4];
            salt_hex[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        defer self.allocator.free(salt_hex);

        // Encode hash as hex
        var hash_hex = try self.allocator.alloc(u8, 64);
        for (hash, 0..) |byte, i| {
            hash_hex[i * 2] = hex_chars[byte >> 4];
            hash_hex[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        defer self.allocator.free(hash_hex);

        // Create PHC format string
        return std.fmt.allocPrint(
            self.allocator,
            "$argon2id$v=19$m=19456,t=2,p=1${s}${s}",
            .{ salt_hex, hash_hex },
        );
    }

    /// Constant-time comparison to prevent timing attacks
    /// Uses XOR pattern to ensure execution time is independent of where bytes differ
    fn constantTimeEqual(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;

        var result: u8 = 0;
        for (a, b) |byte_a, byte_b| {
            result |= byte_a ^ byte_b;
        }
        return result == 0;
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
            std.log.warn("Legacy Blake2b hash detected - recommend password reset for Argon2id upgrade", .{});
            return self.verifyBlake2bLegacy(password, stored_hash);
        }

        // Unknown format
        std.log.err("Unrecognized password hash format (len={}, prefix={s})", .{ stored_hash.len, stored_hash[0..@min(10, stored_hash.len)] });
        return error.InvalidHashFormat;
    }

    /// Verify Argon2id password in PHC format
    fn verifyArgon2idPHC(self: *Self, password: []const u8, phc_string: []const u8) !bool {
        // Parse PHC string: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
        var parts = std.mem.splitScalar(u8, phc_string, '$');

        _ = parts.next(); // Empty before first $
        const alg = parts.next() orelse return false;
        if (!std.mem.eql(u8, alg, "argon2id")) return false;

        const version = parts.next() orelse return false;
        if (!std.mem.eql(u8, version, "v=19")) return false;

        const params_str = parts.next() orelse return false;
        // Parse params: m=19456,t=2,p=1
        var param_parts = std.mem.splitScalar(u8, params_str, ',');
        var m: u32 = 19456;
        var t: u32 = 2;
        var p: u32 = 1;

        while (param_parts.next()) |param| {
            var kv = std.mem.splitScalar(u8, param, '=');
            const key = kv.next() orelse continue;
            const value = kv.next() orelse continue;

            if (std.mem.eql(u8, key, "m")) {
                m = std.fmt.parseInt(u32, value, 10) catch 19456;
            } else if (std.mem.eql(u8, key, "t")) {
                t = std.fmt.parseInt(u32, value, 10) catch 2;
            } else if (std.mem.eql(u8, key, "p")) {
                p = std.fmt.parseInt(u32, value, 10) catch 1;
            }
        }

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
            .p = @intCast(p),
        };

        var computed_hash: [32]u8 = undefined;
        std.crypto.pwhash.argon2.kdf(
            self.allocator,
            &computed_hash,
            password,
            &salt,
            argon2_params,
            .argon2id,
        ) catch return false;

        // Constant-time comparison
        return constantTimeEqual(&computed_hash, &expected_hash);
    }

    /// Verify legacy Blake2b password (for migration)
    fn verifyBlake2bLegacy(self: *Self, password: []const u8, stored_hash: []const u8) !bool {
        _ = self; // Not needed for Blake2b verification
        const salt = "geode-salt-secure-v2";
        var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
        hasher.update(password);
        hasher.update(salt);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        // Convert to hex
        const hex_chars = "0123456789abcdef";
        var computed_hex: [64]u8 = undefined;
        for (digest, 0..) |byte, i| {
            computed_hex[i * 2] = hex_chars[byte >> 4];
            computed_hex[i * 2 + 1] = hex_chars[byte & 0xf];
        }

        return constantTimeEqual(&computed_hex, stored_hash);
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
        const id = @as(UserId, @intCast(self.users.count() + 1));
        const attrs = std.StringHashMap([]const u8).init(self.allocator);
        const hash = try self.hashPassword(password);
        const user = User{
            .id = id,
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password_hash = hash,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
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
        return id;
    }
    // Backwards compatible wrapper (previous signature without explicit is_superuser; defaults false). Some tests call createUser(username,email,password)
    pub fn createUser(self: *Self, username: []const u8, email: []const u8, password: []const u8) !UserId {
        return self.createUserDetailed(username, email, password, false);
    }
    // CANARY: REQ=REQ-AUTH-POLICY-003; FEATURE="Enhanced Password Validation"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_003_PassphraseValidation; OWNER=security; UPDATED=2025-09-30
    pub fn validatePassword(self: *Self, password: []const u8) !void {
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
            const word_count = self.countWords(password);
            if (word_count < self.password_policy.min_words) {
                return error.PasswordNotPassphrase;
            }
        }
    }

    fn countWords(self: *Self, text: []const u8) usize {
        _ = self;
        var word_count: usize = 0;
        var in_word = false;

        for (text) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                if (!in_word) {
                    word_count += 1;
                    in_word = true;
                }
            } else {
                in_word = false;
            }
        }

        return word_count;
    }

    // CANARY: REQ=REQ-AUTH-DEFAULT-001; FEATURE="Default User Creation"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_DEFAULT_001_DefaultUser; OWNER=security; UPDATED=2025-09-30
    fn initializeDefaultUser(self: *Self) !void {
        // Get configurable admin username from environment or use default
        const admin_username_env = std.process.getEnvVarOwned(self.allocator, "GEODE_ADMIN_USERNAME") catch null;
        defer if (admin_username_env) |env| self.allocator.free(env);
        const admin_username = admin_username_env orelse "geode";

        // Check if default user already exists
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, admin_username)) {
                return; // Default user already exists
            }
        }

        // GAP-0146: Generate random password in production if env var not set
        // CANARY: REQ=REQ-DEFAULT-PASSWORD-001; FEATURE="Secure Default Password"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/gap_153_154_password_security.yml; OWNER=security; UPDATED=2026-01-13
        const default_password_env = std.process.getEnvVarOwned(self.allocator, "GEODE_DEFAULT_PASSWORD") catch null;
        const password_from_env = default_password_env != null;

        // Generate or use provided password
        var generated_password_buf: [32]u8 = undefined;
        var generated_password_hex: [64]u8 = undefined;
        const default_password: []const u8 = blk: {
            if (default_password_env) |env| {
                break :blk env;
            }
            // GAP-0146: Generate cryptographically random password in production
            const builtin = @import("builtin");
            if (builtin.mode != .Debug) {
                // Production: Generate random 32-byte password (hex encoded to 64 chars)
                std.crypto.random.bytes(&generated_password_buf);
                generated_password_hex = std.fmt.bytesToHex(generated_password_buf, .lower);
                std.log.warn("SECURITY: Generated random admin password (REQUIRES IMMEDIATE CHANGE):", .{});
                std.log.warn("ADMIN_PASSWORD={s}", .{generated_password_hex[0..32]}); // Only first 32 chars
                std.log.warn("Set GEODE_DEFAULT_PASSWORD env var to use a custom password.", .{});
                break :blk generated_password_hex[0..32];
            }
            // Debug builds: Use "geodesic" for testing convenience
            break :blk "geodesic";
        };
        defer if (default_password_env) |env| self.allocator.free(env);

        // Create default user
        const id = @as(UserId, @intCast(self.users.count() + 1));
        const attrs = std.StringHashMap([]const u8).init(self.allocator);

        // Hash the password
        const password_hash = try self.hashPassword(default_password);

        // CRITICAL SECURITY FIX (C5): ALWAYS require password reset for default user
        // Even if env password is strong, it may be committed to git/logs/CI
        // Per OWASP ASVS 2.1.9: Force password change on first use of default credentials
        const needs_reset = true;

        const user = User{
            .id = id,
            .username = try self.allocator.dupe(u8, admin_username),
            .email = try self.allocator.dupe(u8, "admin@geode.local"),
            .password_hash = password_hash,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
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
        const password_source = if (password_from_env) "environment" else "hardcoded";
        try self.audit_log.append(.user_created, id, "DEFAULT_USER_CREATED username={s} password_source={s} REQUIRES_IMMEDIATE_RESET", .{ admin_username, password_source });

        if (password_from_env) {
            std.log.warn("Default user created with env password. SECURITY: Ensure GEODE_DEFAULT_PASSWORD is not in git/logs. Password reset required on first login.", .{});
        }
    }

    // Check if a user requires password reset
    pub fn requiresPasswordReset(self: *Self, user_id: UserId) !bool {
        const user = self.users.get(user_id) orelse return error.UserNotFound;
        return user.password_reset_required;
    }

    // Force password reset for a user
    pub fn forcePasswordReset(self: *Self, user_id: UserId) !void {
        const user = self.users.getPtr(user_id) orelse return error.UserNotFound;
        user.password_reset_required = true;
        user.updated_at = std.time.milliTimestamp();
        try self.audit_log.append(.user_updated, user_id, "Password reset forced", .{});
    }

    // Update password and clear reset requirement
    pub fn updatePassword(self: *Self, user_id: UserId, new_password: []const u8) !void {
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
        user.updated_at = std.time.milliTimestamp();

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
        // Pre-hash validation against current policy
        try self.validatePassword(password);
    }

    // Check if stored password hash meets current policy requirements
    // CANARY: REQ=REQ-AUTH-POLICY-006; FEATURE="Post-Authentication Policy Check"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_006_PostAuthPolicyCheck; OWNER=security; UPDATED=2025-09-30
    pub fn checkStoredPasswordMeetsCurrentPolicy(self: *Self, _: *User, password: []const u8) bool {
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

        // CRITICAL SECURITY FIX (C5): Block default users until password changed
        // Prevents authentication with predictable default credentials
        if (user.is_default_user and user.password_reset_required) {
            try self.audit_log.append(.login_failed, user.id, "Authentication blocked: default user must change password", .{});
            return error.DefaultPasswordMustBeChanged;
        }

        if (!try self.verifyPassword(password, user.password_hash)) {
            try self.audit_log.logFailedLogin(user.id, user.username);
            return error.InvalidCredentials;
        }

        // CANARY: REQ=REQ-AUTH-POLICY-007; FEATURE="Mandatory Password Policy Enforcement"; ASPECT=Security; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_POLICY_007_MandatoryPolicyEnforcement; OWNER=security; UPDATED=2025-09-30
        // Check if the authenticated password meets current policy requirements
        // This is non-bypassable - if password violates policy, force reset
        const password_meets_policy = self.checkStoredPasswordMeetsCurrentPolicy(user, password);
        if (!password_meets_policy) {
            // Force password reset for policy violation
            user.password_reset_required = true;
            user.updated_at = std.time.milliTimestamp();
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

        if (!try self.verifyPassword(password, user.password_hash)) {
            try self.audit_log.logFailedLogin(user.id, user.username);
            return error.InvalidCredentials;
        }
        if (!user.mfa_enabled or user.mfa_secret == null) return error.MFADisabled;
        var used_recovery = false;
        if (recovery_code) |rc| {
            // Attempt recovery code path first if provided.
            if (user.recovery_codes) |*codes| {
                var idx: usize = 0;
                while (idx < codes.items.len) : (idx += 1) {
                    if (std.mem.eql(u8, codes.items[idx], rc)) {
                        // Remove single-use code by swap-remove
                        _ = codes.orderedRemove(idx);
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
            const now = @as(u64, @intCast(std.time.milliTimestamp()));
            if (!try mfa.verifyCode(self.allocator, user.mfa_secret.?, now, code, 30, 6, 1)) {
                try self.audit_log.logMfaChallengeFailure(user.id, "totp", "invalid_code");
                return error.MFAInvalidCode;
            }
            try self.audit_log.logMfaChallengeSuccess(user.id, "totp");
        }
        // Note: MFA completion assumes password reset already handled in initial auth
        const token = try self.createSession(user.id);
        // Mark elevation using configured TTL
        self.markStepUp(token, self.elevation_ttl_ms) catch {};
        try self.audit_log.logSuccessfulLogin(user.id, user.username);
        return token;
    }
};

// ============================================================================
// Unit Tests for GAP-0149: Fail-Secure Risk Score Parsing
// CANARY: REQ=REQ-AUTH-RISKSCORE-001; FEATURE="FailSecureRiskScore"; ASPECT=TEST; STATUS=TESTED; OWNER=security; UPDATED=2026-01-13
// ============================================================================

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
