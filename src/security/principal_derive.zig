// CANARY: REQ=REQ-GPS-DERIVE-001; FEATURE="GPS Principal Derivation"; ASPECT=Builder; STATUS=TESTED; TEST=tests/test_gps_principal_derive.zig; OWNER=security; UPDATED=2026-05-20
//
// Transport-agnostic Principal builder for GPS. Each transport (QUIC, gRPC,
// distributed coordinator) calls derivePrincipal() instead of writing its
// own struct literal. Phase 2 reduces duplication; Phase 3+ may extend the
// argument set with risk fields and attribute maps.

const std = @import("std");
const principal_mod = @import("principal.zig");
const authn = @import("authn.zig");

pub const DeriveArgs = struct {
    username: ?[]const u8,
    role_names: []const []const u8,
    tenant_id: ?[]const u8,
    active_graph: ?[]const u8,
    auth_version: u64,
    auth_method: authn.AuthMethod,
    source: principal_mod.PrincipalSource,

    ip_address: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    api_key_id: ?u64 = null,
    certificate_subject: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    mfa_state: principal_mod.MfaState = .none,
};

pub fn derivePrincipal(args: DeriveArgs) principal_mod.Principal {
    return .{
        .user_id = null,
        .username = args.username,
        .session_id = args.session_id,
        .tenant_id = args.tenant_id,
        .active_graph = args.active_graph,
        .roles = args.role_names,
        .custom_roles = &.{},
        .auth_method = args.auth_method,
        .auth_version = args.auth_version,
        .mfa_state = args.mfa_state,
        .elevation_until = null,
        .api_key_id = args.api_key_id,
        .certificate_subject = args.certificate_subject,
        .risk_context = .{
            .score = 0,
            .ip_address = args.ip_address,
            .user_agent = args.user_agent,
        },
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = args.source,
    };
}
