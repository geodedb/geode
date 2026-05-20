// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=TypeDefinition; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
//
// Geode Policy System — central decision API.
//
// Phase 2 scope: define decision types and a skeleton decide() that handles
// the empty/unauthenticated case. Later Phase 2 tasks layer in builtin-role
// grants (2-4), graph grants (2-5), the --insecure-allow-all flag (2-9), and
// the RLS-VM IndeterminatePolicy mapping (2-8, COMPLETE). The decision API is
// the only place Phase 3+ code should consult for authorization outcomes.
//
// RLS-VM linkage (task 2-8, complete):
//   rls_core.evaluateCompiledExpressionWithUsername now returns
//   error.IndeterminatePolicy when the bytecode program terminates with an
//   empty stack (no result produced). This propagates up through
//   checkRowAccessByUsername and is caught by match_operations.passesRLSExprFilter
//   via `catch false`, mapping the indeterminate outcome to a row-level deny.
//   In Phase 4, this error will be surfaced through the policy layer here in
//   decide() and map to PolicyDecisionKind.indeterminate, giving callers
//   structured visibility into the reason for denial.
//
// Reference: docs/geode-policy-plan.md "Canonical principal, resource, action,
// and decision models".

const std = @import("std");
const principal_mod = @import("principal.zig");

// CANARY: REQ=REQ-GPS-PDP-007; FEATURE="GPS Decision Engine"; ASPECT=InsecureAllowAll; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
// Process-wide flag enabling the --insecure-allow-all bypass. Written once at
// startup by CLI parsing; read on every decide() call. Uses the same
// std.atomic.Value(bool) pattern as user_management.auth_enabled.
var g_insecure_allow_all: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn setInsecureAllowAll(value: bool) void {
    g_insecure_allow_all.store(value, .release);
}

pub fn isInsecureAllowAll() bool {
    return g_insecure_allow_all.load(.acquire);
}

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

    // CANARY: REQ=REQ-GPS-PDP-007; FEATURE="GPS Decision Engine"; ASPECT=InsecureAllowAll; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
    // --insecure-allow-all: process-wide kill-switch that short-circuits all
    // authorization logic. Set only when the flag is present at CLI startup.
    // This is the canonical bypass path; the legacy auth-disabled short-circuit
    // in checkPermission() is preserved as a Phase 1 compat path (see Task 2-9).
    if (g_insecure_allow_all.load(.acquire)) {
        return PolicyDecision{
            .kind = .allow,
            .reason_code = "insecure_allow_all",
        };
    }

    if (req.principal.username == null) {
        return PolicyDecision{
            .kind = .unauthenticated,
            .reason_code = "no_principal",
        };
    }

    // CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=AdminAllowed; STATUS=TESTED; TEST=tests/test_gps_bind_graph.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=GrantWidening; STATUS=TESTED; TEST=tests/test_gps_bind_graph.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 3 task 3-1: bind_graph — Admin always allowed; non-admin requires a
    // Read grant on the target graph via graph_grant_check_fn. This is the
    // non-bypassable gate for USE GRAPH and any operation that switches the
    // active graph context. Evaluated before generic role/permission mapping so
    // it cannot be widened by a permission-level grant for unrelated actions.
    if (req.action == .bind_graph) {
        for (req.principal.roles) |role_name| {
            if (std.mem.eql(u8, role_name, "Admin")) {
                return PolicyDecision{
                    .kind = .allow,
                    .reason_code = "bind_graph_admin",
                };
            }
        }
        if (req.resource == .graph) {
            const target_graph = req.resource.graph;
            if (execution.graph_grant_check_fn) |grant_fn| {
                if (req.principal.username) |uname| {
                    if (grant_fn(uname, target_graph, 0)) {
                        return PolicyDecision{
                            .kind = .allow,
                            .reason_code = "bind_graph_grant",
                        };
                    }
                }
            }
        }
        return PolicyDecision{
            .kind = .unauthorized,
            .reason_code = "bind_graph_no_evidence",
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
