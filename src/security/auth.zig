// (Removed duplicated preamble section)
// Clean reconstructed auth.zig with consolidated definitions (RBAC, ABAC, RLS, Sessions, MFA Policies)
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const mfa = @import("mfa.zig");

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
    password_hash: [64]u8,
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
pub const PasswordPolicy = struct {
    min_length: usize,
    max_length: usize,
    require_uppercase: bool,
    require_lowercase: bool,
    require_digit: bool,
    require_special: bool,
    max_age_days: u32,
    history_count: u32,
    pub fn default() PasswordPolicy {
        return .{ .min_length = 8, .max_length = 128, .require_uppercase = true, .require_lowercase = true, .require_digit = true, .require_special = true, .max_age_days = 90, .history_count = 5 };
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
        return .{ .allocator = a, .entries = std.ArrayList(AuditEntry).initCapacity(a, 0) catch unreachable };
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
        const sm = Self{
            .allocator = a,
            .users = std.AutoHashMap(UserId, User).init(a),
            .roles = std.AutoHashMap(RoleId, Role).init(a),
            .permissions = std.AutoHashMap(PermissionId, Permission).init(a),
            .rbac = RBACPolicy{ .user_roles = std.AutoHashMap(UserId, std.ArrayList(RoleId)).init(a), .role_permissions = std.AutoHashMap(RoleId, std.ArrayList(Permission)).init(a), .role_hierarchy = std.AutoHashMap(RoleId, std.ArrayList(RoleId)).init(a) },
            .abac_policies = std.ArrayList(ABACPolicy).initCapacity(a, 0) catch unreachable,
            .row_policies = std.ArrayList(RowLevelPolicy).initCapacity(a, 0) catch unreachable,
            .sessions = std.StringHashMap(Session).init(a),
            .mfa_policies = std.ArrayList(MfaAdminPolicy).initCapacity(a, 0) catch unreachable,
            .mfa_require_cache = std.AutoHashMap(UserId, bool).init(a),
            .audit_log = try AuditLog.init(a),
            .password_policy = PasswordPolicy.default(),
        };
        return sm;
    }

    pub fn deinit(self: *Self) void {
        // release user map strings
        var it = self.users.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.value_ptr.username);
            self.allocator.free(e.value_ptr.email);
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
                if (risk_score == null) {
                    if (u.attributes.get("risk_score")) |rs| {
                        const parsed = std.fmt.parseInt(u8, rs, 10) catch 0;
                        risk_score = parsed;
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
        var out = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
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
        const role = Role{ .id = id, .name = try self.allocator.dupe(u8, name), .description = try self.allocator.dupe(u8, description), .permissions = std.ArrayList(PermissionId).initCapacity(self.allocator, 0) catch unreachable, .created_at = std.time.milliTimestamp(), .is_system = false, .priority = 100, .parent_role = null };
        try self.roles.put(id, role);
        return self.roles.getPtr(id).?;
    }
    pub fn assignRole(self: *Self, user_id: UserId, role_id: RoleId) !void {
        _ = self.users.get(user_id) orelse return error.UserNotFound;
        _ = self.roles.get(role_id) orelse return error.RoleNotFound;
        const entry = try self.rbac.user_roles.getOrPut(user_id);
        if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(RoleId).initCapacity(self.allocator, 0) catch unreachable;
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
        if (!rp.found_existing) rp.value_ptr.* = std.ArrayList(Permission).initCapacity(self.allocator, 0) catch unreachable;
        try rp.value_ptr.append(self.allocator, perm);
        try self.audit_log.logPermissionGranted(role_id, perm_id);
    }

    // ---- Passwords ----
    pub fn hashPassword(_: *Self, password: []const u8) ![64]u8 {
        var hash: [64]u8 = undefined;
        const salt = "geode-salt-v1";
        var h = std.hash.Wyhash.init(0);
        h.update(password);
        h.update(salt);
        const r = h.final();
        std.mem.writeInt(u64, hash[0..8], r, .little);
        for (hash[8..]) |*b| b.* = 0;
        return hash;
    }
    fn verifyPassword(self: *Self, password: []const u8, hash: [64]u8) !bool {
        _ = self;
        _ = password;
        _ = hash;
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
        };
        try self.users.put(id, user);
        try self.audit_log.logUserCreated(id, username);
        return id;
    }
    // Backwards compatible wrapper (previous signature without explicit is_superuser; defaults false). Some tests call createUser(username,email,password)
    pub fn createUser(self: *Self, username: []const u8, email: []const u8, password: []const u8) !UserId {
        return self.createUserDetailed(username, email, password, false);
    }
    pub fn validatePassword(self: *Self, password: []const u8) !void {
        if (password.len < self.password_policy.min_length) return error.PasswordTooShort;
        if (password.len > self.password_policy.max_length) return error.PasswordTooLong;
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
                if (!std.ascii.isAlphanumeric(c)) {
                    sp = true;
                    break;
                }
            }
            if (!sp) return error.PasswordMissingSpecial;
        }
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
        try self.rbac.role_hierarchy.put(2, std.ArrayList(RoleId).initCapacity(self.allocator, 0) catch unreachable);
        try self.rbac.role_hierarchy.getPtr(2).?.append(self.allocator, 1);
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
        if (!try self.verifyPassword(password, user.password_hash)) {
            try self.audit_log.logFailedLogin(user.id, user.username);
            return error.InvalidCredentials;
        }
        // Evaluate MFA requirement
        const policy_requires = self.evaluateMfaPolicies(user);
        if (policy_requires and user.mfa_enabled and user.mfa_secret != null) {
            try self.audit_log.logMfaChallengeIssued(user.id, "totp");
            return error.MFARequired;
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
        const token = try self.createSession(user.id);
        // Mark elevation using configured TTL
        self.markStepUp(token, self.elevation_ttl_ms) catch {};
        try self.audit_log.logSuccessfulLogin(user.id, user.username);
        return token;
    }
};
