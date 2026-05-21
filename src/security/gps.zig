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
const decision_cache = @import("decision_cache.zig");
const policy_version = @import("policy_version.zig");

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
// CANARY: REQ=REQ-GPS-PDP-003; FEATURE="GPS Decision Engine"; ASPECT=GraphGrantWidening; STATUS=EXEMPT; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
// Phase 6 (Task 6-6): Site #2 CLOSED via grant_migration.zig (commit 64ce3940).
// All existing (:GraphGrant) records are migrated to (:Policy) rows at startup;
// the graph_grant_check_fn path below is now a deprecated shim that will be
// removed in Phase 7 once no grants remain in the legacy format.
// REQ-GPS-INVARIANT-001 ASPECT=FailOpenInterim STATUS=COMPLETE for site #2.
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

// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=ResourceHash; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
/// Hash a ResourceRef into a u64 for use as a decision-cache key component.
fn hashResource(r: ResourceRef) u64 {
    var hasher = std.hash.Wyhash.init(0);
    switch (r) {
        .database => hasher.update("db"),
        .graph => |g| {
            hasher.update("graph:");
            hasher.update(g);
        },
        .tenant => |t| {
            hasher.update("tenant:");
            hasher.update(t);
        },
        .node => |n| {
            hasher.update("node:");
            hasher.update(n.graph);
        },
        .edge => |e| {
            hasher.update("edge:");
            hasher.update(e.graph);
        },
        .procedure => |p| {
            hasher.update("proc:");
            hasher.update(p);
        },
        .metadata => |m| {
            hasher.update("meta:");
            hasher.update(m.kind);
        },
    }
    return hasher.final();
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

    // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=DecideLookup; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
    // Cache lookup: only cache authenticated principals (auth_version != 0).
    // Anonymous / legacy paths use auth_version = 0 and are never cached so that
    // unauthenticated decisions can never be served from stale cache entries.
    const should_cache = req.principal.auth_version != 0;
    var cache_key: ?decision_cache.Key = null;
    if (should_cache) {
        if (decision_cache.getGlobalCache()) |cache| {
            const key = decision_cache.Key{
                .auth_version = req.principal.auth_version,
                .policy_version = policy_version.getPolicyVersion(),
                .action_tag = @intFromEnum(req.action),
                .resource_hash = hashResource(req.resource),
            };
            cache_key = key;
            if (cache.lookup(key)) |cached| {
                return cached;
            }
        }
    }

    // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=DecideInsert; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
    // Helper: insert a decision into the cache (if cache_key was set) then return it.
    // Allocation errors from cache.insert are swallowed — a cache failure must never
    // block an authorization decision.
    const cacheAndReturn = struct {
        fn f(key: ?decision_cache.Key, d: PolicyDecision) PolicyDecision {
            if (key) |k| {
                if (decision_cache.getGlobalCache()) |cache| {
                    cache.insert(k, d) catch {};
                }
            }
            return d;
        }
    }.f;

    if (req.principal.username == null) {
        // Do not cache unauthenticated decisions — auth_version is 0 for these
        // paths, so cache_key is already null and cacheAndReturn is a no-op.
        return cacheAndReturn(cache_key, PolicyDecision{
            .kind = .unauthenticated,
            .reason_code = "no_principal",
        });
    }

    // CANARY: REQ=REQ-GPS-METADATA-000; FEATURE="GPS Metadata Isolation"; ASPECT=DecideShowMetadata; STATUS=TESTED; TEST=tests/test_gps_show_metadata.zig; OWNER=security; UPDATED=2026-05-20
    // show_metadata is always allowed at the decision layer for authenticated
    // principals. The actual metadata handlers filter rows by tenant and
    // accessible graphs (Phase 3 tasks 3-4 through 3-8). Evaluated after the
    // unauthenticated check so anonymous callers still receive .unauthenticated.
    if (req.action == .show_metadata) {
        return cacheAndReturn(cache_key, PolicyDecision{
            .kind = .allow,
            .reason_code = "show_metadata_audit_only",
        });
    }

    // CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=AdminAllowed; STATUS=TESTED; TEST=tests/test_gps_procedure_enforcement.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=ReadOnlyForMutatingDenied; STATUS=TESTED; TEST=tests/test_gps_procedure_enforcement.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 5 task 5-1: execute_procedure — Admin is always allowed. For other
    // principals the registry remaps the action to .read (read_only procedures)
    // or .write (mutating procedures) before calling decide(), so this branch
    // handles only the unknown-classification fallback where the raw
    // .execute_procedure action arrives. Without a builtin-role that maps to
    // Read or Write (e.g., ReadOnly has Read, Admin has all), this falls through
    // to the policy catalog. A bare .execute_procedure action with no policy
    // match produces .unauthorized — preserving the fail-closed default.
    if (req.action == .execute_procedure) {
        for (req.principal.roles) |role_name| {
            if (std.mem.eql(u8, role_name, "Admin")) {
                return cacheAndReturn(cache_key, PolicyDecision{
                    .kind = .allow,
                    .reason_code = "execute_procedure_admin",
                });
            }
        }
        // Fall through: no builtin-role shortcut for the raw execute_procedure
        // action — the policy catalog below is the last resort.
    }

    // CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptFieldGate; STATUS=TESTED; TEST=tests/test_gps_fle_enforcement.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=UnwrapKeyGate; STATUS=TESTED; TEST=tests/test_gps_fle_enforcement.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 5 task 5-3: explicit GPS gates for FLE decrypt_field and unwrap_key.
    // Admin is always allowed. Other principals must have an explicit Policy in
    // the catalog with action = .decrypt_field or .unwrap_key respectively.
    // If no matching policy exists, decide() returns .unauthorized (fail-closed).
    // The fallthrough to the policy catalog below handles the explicit-allow case.
    if (req.action == .decrypt_field or req.action == .unwrap_key) {
        for (req.principal.roles) |role_name| {
            if (std.mem.eql(u8, role_name, "Admin")) {
                return cacheAndReturn(cache_key, PolicyDecision{
                    .kind = .allow,
                    .reason_code = "fle_admin",
                });
            }
        }
        // Non-admin: fall through to policy catalog. If a Policy row with
        // action = .decrypt_field (or .unwrap_key) and expression_source = "true"
        // exists, the catalog loop below grants access. Without such a policy,
        // decide() returns .unauthorized after the catalog loop.
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
                return cacheAndReturn(cache_key, PolicyDecision{
                    .kind = .allow,
                    .reason_code = "bind_graph_admin",
                });
            }
        }
        if (req.resource == .graph) {
            const target_graph = req.resource.graph;
            if (execution.graph_grant_check_fn) |grant_fn| {
                if (req.principal.username) |uname| {
                    if (grant_fn(uname, target_graph, 0)) {
                        return cacheAndReturn(cache_key, PolicyDecision{
                            .kind = .allow,
                            .reason_code = "bind_graph_grant",
                        });
                    }
                }
            }
        }
        return cacheAndReturn(cache_key, PolicyDecision{
            .kind = .unauthorized,
            .reason_code = "bind_graph_no_evidence",
        });
    }

    // Phase 2 task 2-4: builtin-role evaluation.
    // Walk the principal's roles slice, resolve each to a user_management.Role,
    // and ask hasPermission() — preserving legacy semantics bit-identically.
    // Task 2-5 layers graph grants; task 2-9 layers the insecure-allow-all flag.
    if (actionToPermission(req.action)) |perm| {
        for (req.principal.roles) |role_name| {
            if (user_mgmt.Role.fromString(role_name)) |role| {
                if (user_mgmt.hasPermission(role, perm)) {
                    return cacheAndReturn(cache_key, PolicyDecision{
                        .kind = .allow,
                        .reason_code = "builtin_role",
                    });
                }
            }
        }

        // Phase 2 task 2-5: additive graph-grant widening (DEPRECATED — Phase 7 removal).
        // When builtin-role evaluation produces no allow and the principal has
        // an active_graph, consult graph_grant_check_fn — the same callback that
        // execution.checkPermission() uses. Bit-identical to the legacy fallback.
        // Phase 6 (commit 64ce3940): grant_migration.zig converts all existing
        // (:GraphGrant) records to (:Policy) rows at startup; the Policy-eval path
        // below already handles them.  This shim is kept so that any grant not yet
        // migrated (e.g. written after the migration ran) still evaluates correctly;
        // it will be removed in Phase 7 once the legacy grant format is retired.
        if (execution.graph_grant_check_fn) |grant_fn| {
            if (req.principal.username) |uname| {
                if (req.principal.active_graph) |graph| {
                    const action_code: u8 = switch (perm) {
                        .Read => 0,
                        .Write => 1,
                        .Schema => 2,
                    };
                    if (grant_fn(uname, graph, action_code)) {
                        return cacheAndReturn(cache_key, PolicyDecision{
                            .kind = .allow,
                            .reason_code = "graph_grant",
                        });
                    }
                }
            }
        }
    }

    // CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=ExplicitAllow; STATUS=TESTED; TEST=tests/test_gps_policy_evaluation.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=DecideEvalExpression; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 4: explicit policy match via the global PolicyCatalog.
    // Phase 5 (Task 5-4): attribute-based expression predicates are now
    // evaluated via the compiled CompiledExpression stored on each Policy.
    const pc = @import("policy_catalog.zig");
    const policy_expression = @import("policy_expression.zig");
    if (pc.getGlobalCatalog()) |cat| {
        for (cat.listPolicies()) |*policy| {
            if (!policy.enabled) continue;
            if (!policyMatchesAction(policy.*, req.action)) continue;
            if (!policyMatchesResource(policy.*, req.resource)) continue;

            // CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=DecidePopulateAttributes; STATUS=TESTED; TEST=tests/test_gps_abac_predicates.zig; OWNER=security; UPDATED=2026-05-20
            // Build an evaluation context from the current request.
            // Phase 6 (Task 6-2): principal_attributes is populated from the
            // caller's AttributeMap so that eq_principal_attr predicates can
            // match ABAC key/value pairs without any additional allocation.
            // Both principal.AttributeMap.Entry and policy_expression.AttributeEntry
            // are { key: []const u8, value: []const u8 } — same layout.
            // We map through the entries to build the attribute slice.
            const raw_entries = req.principal.attributes.entries;
            // Comptime layout assert: both types are identical structs.
            comptime std.debug.assert(@sizeOf(principal_mod.AttributeMap.Entry) == @sizeOf(policy_expression.AttributeEntry));
            // Safe slice reinterpret: same element size and layout.
            const attr_entries: []const policy_expression.AttributeEntry = @as(
                [*]const policy_expression.AttributeEntry,
                @ptrCast(raw_entries.ptr),
            )[0..raw_entries.len];
            const ctx = policy_expression.PolicyEvalContext{
                .current_user = req.principal.username,
                .current_tenant = req.principal.tenant_id,
                .current_graph = req.principal.active_graph,
                .resource_label = switch (req.resource) {
                    // For node resources, use the first label as resource_label.
                    // Phase 5: a richer label-set predicate can land in Phase 6.
                    else => null,
                },
                .principal_attributes = attr_entries,
            };

            // Evaluate the expression: compiled expression takes priority;
            // the trivial "true" string is the fast-path fallback.
            const expr_result = if (policy.compiled) |*cexpr|
                policy_expression.evaluate(cexpr, ctx)
            else
                std.mem.eql(u8, policy.expression_source, "true");

            if (expr_result and policy.effect == .allow) {
                return cacheAndReturn(cache_key, PolicyDecision{
                    .kind = .allow,
                    .reason_code = "policy_match",
                });
            }
            // deny-effect or expression evaluated to false: continue scan.
        }
    }

    return cacheAndReturn(cache_key, PolicyDecision{
        .kind = .unauthorized,
        .reason_code = "no_evidence",
    });
}

fn policyMatchesAction(policy: @import("policy_catalog.zig").Policy, action: Action) bool {
    const pc = @import("policy_catalog.zig");
    for (policy.actions) |a| {
        const matches = switch (action) {
            .read => a == .read,
            .match_ => a == .read or a == .match_,
            .write => a == .write,
            .create => a == .write or a == .create,
            .update => a == .write or a == .update,
            .delete => a == .write or a == .delete,
            .schema => a == .schema,
            // CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=PolicyMatchAction; STATUS=TESTED; TEST=tests/test_gps_fle_enforcement.zig; OWNER=security; UPDATED=2026-05-20
            // Phase 5 task 5-3: FLE-specific actions are expressible in the policy catalog.
            // A Policy with action = .decrypt_field grants non-admin principals the ability
            // to decrypt FLE-protected fields. Similarly for .unwrap_key.
            .decrypt_field => a == .decrypt_field,
            .unwrap_key => a == .unwrap_key,
            // Remaining actions have no policy_catalog.Action analogue; they rely on
            // builtin-role or special-case paths in decide().
            else => false,
        };
        _ = pc;
        if (matches) return true;
    }
    return false;
}

fn policyMatchesResource(policy: @import("policy_catalog.zig").Policy, resource: ResourceRef) bool {
    // "*" scope is a wildcard that matches any resource.
    if (std.mem.eql(u8, policy.scope_graph, "*")) return true;
    return switch (resource) {
        // Named graph: compare against policy scope directly.
        .graph => |g| std.mem.eql(u8, policy.scope_graph, g),
        // Non-graph resources (database, tenant, node, edge, procedure, metadata)
        // are matched by any non-wildcard scope in Phase 4.  A more precise
        // resource-type filter arrives with the Phase 5 expression engine.
        .database, .tenant, .node, .edge, .procedure, .metadata => true,
    };
}
