// CANARY: REQ=REQ-GPS-PRINCIPAL-001; FEATURE="GPS Canonical Principal"; ASPECT=TypeDefinition; STATUS=TESTED; TEST=tests/test_gps_principal.zig; OWNER=security; UPDATED=2026-05-20
//
// The canonical Principal type for the Geode Policy System.
//
// Phase 1 contract: this type is constructed exactly once at every request
// boundary and threaded through ExecutionContext. It carries no authorization
// logic. The decision API (decide()) arrives in Phase 2 and consumes this
// type as its `principal` argument.
//
// See docs/geode-policy-plan.md ("Canonical principal, resource, action, and
// decision models") and docs/security/gps-invariants.md for the field
// semantics this type pins.

const std = @import("std");
const authn = @import("authn.zig");

pub const AuthMethod = authn.AuthMethod;

pub const MfaState = enum {
    none,
    required,
    verified,
};

pub const PrincipalSource = enum {
    unattributed,
    quic_handler,
    grpc_handler,
    distributed_coordinator,
    distributed_worker,
    mcp_handler,
    repl,
    internal_service,
    test_harness,
};

pub const RiskContext = struct {
    score: u8,
    ip_address: ?[]const u8,
    user_agent: ?[]const u8,

    pub const unknown: RiskContext = .{
        .score = 0,
        .ip_address = null,
        .user_agent = null,
    };
};

pub const AttributeMap = struct {
    entries: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn emptySentinel() AttributeMap {
        return .{ .entries = &.{} };
    }

    pub fn get(self: AttributeMap, key: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

pub const Principal = struct {
    user_id: ?u64,
    username: ?[]const u8,
    session_id: ?[]const u8,
    tenant_id: ?[]const u8,
    active_graph: ?[]const u8,

    roles: []const []const u8,
    custom_roles: []const []const u8,

    auth_method: AuthMethod,
    auth_version: u64,

    mfa_state: MfaState,
    elevation_until: ?i64,

    api_key_id: ?u64,
    certificate_subject: ?[]const u8,

    risk_context: RiskContext,
    attributes: AttributeMap,

    source: PrincipalSource,

    pub const FromAuthStateArgs = struct {
        auth_result: authn.AuthResult,
        auth_version: u64,
        tenant_id: ?[]const u8,
        active_graph: ?[]const u8,
        api_key_id: ?u64,
        certificate_subject: ?[]const u8,
        ip_address: ?[]const u8,
        user_agent: ?[]const u8,
        source: PrincipalSource,
    };

    pub fn fromAuthState(args: FromAuthStateArgs) Principal {
        return .{
            .user_id = args.auth_result.user_id,
            .username = args.auth_result.username,
            .session_id = args.auth_result.session_token,
            .tenant_id = args.tenant_id,
            .active_graph = args.active_graph,
            .roles = args.auth_result.roles,
            .custom_roles = &.{},
            .auth_method = args.auth_result.method,
            .auth_version = args.auth_version,
            .mfa_state = if (args.auth_result.requires_mfa) MfaState.required else MfaState.none,
            .elevation_until = null,
            .api_key_id = args.api_key_id,
            .certificate_subject = args.certificate_subject,
            .risk_context = .{
                .score = 0,
                .ip_address = args.ip_address,
                .user_agent = args.user_agent,
            },
            .attributes = AttributeMap.emptySentinel(),
            .source = args.source,
        };
    }

    pub fn empty() Principal {
        return .{
            .user_id = null,
            .username = null,
            .session_id = null,
            .tenant_id = null,
            .active_graph = null,
            .roles = &.{},
            .custom_roles = &.{},
            .auth_method = .anonymous,
            .auth_version = 0,
            .mfa_state = .none,
            .elevation_until = null,
            .api_key_id = null,
            .certificate_subject = null,
            .risk_context = RiskContext.unknown,
            .attributes = AttributeMap.emptySentinel(),
            .source = .unattributed,
        };
    }
};
