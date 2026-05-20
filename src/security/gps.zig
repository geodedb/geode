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

// CANARY: REQ=REQ-GPS-PDP-002; FEATURE="GPS Decision Engine"; ASPECT=BuiltinRoleGrants; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
// CANARY: REQ=REQ-GPS-PDP-003; FEATURE="GPS Decision Engine"; ASPECT=GraphGrantWidening; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
const user_mgmt = @import("user_management.zig");
const execution = @import("../execution.zig");

/// Map a GPS Action to the user_management.Permission it requires.
/// Returns null for actions that have no legacy permission analogue (admin-only
/// actions are handled separately in later Phase 2 tasks).
fn actionToPermission(action: Action) ?user_mgmt.Permission {
    return switch (action) {
        .read, .match_, .show_metadata => .Read,
        .write, .create, .update, .delete => .Write,
        .schema => .Schema,
        else => null,
    };
}

pub fn decide(allocator: std.mem.Allocator, req: *const DecisionRequest) !PolicyDecision {
    _ = allocator;
    if (req.principal.username == null) {
        return PolicyDecision{
            .kind = .unauthenticated,
            .reason_code = "no_principal",
        };
    }

    // Phase 2 task 2-4: builtin-role evaluation.
    // Walk the principal's roles slice, resolve each to a user_management.Role,
    // and ask hasPermission() — preserving legacy semantics bit-identically.
    // Task 2-5 layers graph grants; task 2-9 layers the insecure-allow-all flag.
    if (actionToPermission(req.action)) |perm| {
        for (req.principal.roles) |role_name| {
            if (user_mgmt.Role.fromString(role_name)) |role| {
                if (user_mgmt.hasPermission(role, perm)) {
                    return PolicyDecision{
                        .kind = .allow,
                        .reason_code = "builtin_role",
                    };
                }
            }
        }

        // Phase 2 task 2-5: additive graph-grant widening.
        // When builtin-role evaluation produces no allow and the principal has
        // an active_graph, consult graph_grant_check_fn — the same callback that
        // execution.checkPermission() uses. Bit-identical to the legacy fallback.
        // Phase 4 replaces this with first-class Policy rows.
        if (execution.graph_grant_check_fn) |grant_fn| {
            if (req.principal.username) |uname| {
                if (req.principal.active_graph) |graph| {
                    const action_code: u8 = switch (perm) {
                        .Read => 0,
                        .Write => 1,
                        .Schema => 2,
                    };
                    if (grant_fn(uname, graph, action_code)) {
                        return PolicyDecision{
                            .kind = .allow,
                            .reason_code = "graph_grant",
                        };
                    }
                }
            }
        }
    }

    return PolicyDecision{
        .kind = .unauthorized,
        .reason_code = "no_evidence",
    };
}
