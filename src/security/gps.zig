// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=TypeDefinition; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
//
// Geode Policy System — central decision API.
//
// Phase 2 scope: define decision types and a skeleton decide() that handles
// the empty/unauthenticated case. Later Phase 2 tasks layer in builtin-role
// grants (2-4), graph grants (2-5), the --insecure-allow-all flag (2-9), and
// the RLS-VM IndeterminatePolicy mapping (2-8). The decision API is the only
// place Phase 3+ code should consult for authorization outcomes.
//
// Reference: docs/geode-policy-plan.md "Canonical principal, resource, action,
// and decision models".

const std = @import("std");
const principal_mod = @import("principal.zig");

pub const Action = enum {
    read,
    write,
    schema,
    match_,
    create,
    update,
    delete,
    execute_procedure,
    admin_user,
    admin_role,
    admin_tenant,
    bind_graph,
    show_metadata,
    decrypt_field,
    unwrap_key,
};

pub const ResourceRef = union(enum) {
    database: void,
    graph: []const u8,
    tenant: []const u8,
    node: struct { graph: []const u8, id: u64 },
    edge: struct { graph: []const u8, id: u64 },
    procedure: []const u8,
    metadata: struct { kind: []const u8 },
};

pub const PolicyDecisionKind = enum {
    allow,
    deny,
    unauthenticated,
    unauthorized,
    indeterminate,
    audit_only,
};

pub const Obligation = struct {};

pub const AuditFields = struct {
    subject: ?[]const u8 = null,
    action_name: ?[]const u8 = null,
    resource_summary: ?[]const u8 = null,
    decision_reason: ?[]const u8 = null,
};

pub const PolicyDecision = struct {
    kind: PolicyDecisionKind,
    reason_code: []const u8,
    obligations: []const Obligation = &.{},
    audit_fields: AuditFields = .{},
    cacheable: bool = false,
};

pub const DecisionRequest = struct {
    principal: *const principal_mod.Principal,
    action: Action,
    resource: ResourceRef,
};

pub fn decide(allocator: std.mem.Allocator, req: *const DecisionRequest) !PolicyDecision {
    _ = allocator;
    if (req.principal.username == null) {
        return PolicyDecision{
            .kind = .unauthenticated,
            .reason_code = "no_principal",
        };
    }
    // Phase 2 task 2-4 layers builtin-role evaluation; task 2-5 layers graph
    // grants; task 2-9 layers the insecure-allow-all flag. For now, an
    // authenticated principal with no other evidence returns unauthorized.
    return PolicyDecision{
        .kind = .unauthorized,
        .reason_code = "no_evidence",
    };
}
