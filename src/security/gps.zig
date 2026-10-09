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

// CANARY: REQ=REQ-GAP-0842-INSECURE-BANNER-001; FEATURE="InsecureAllowAllStartupBanner"; ASPECT=BannerText; STATUS=TESTED; TEST=tests/test_gap0842_insecure_allow_all_banner.zig; OWNER=security; UPDATED=2026-06-08
// GAP-0842: prominent, unmistakable startup banner emitted when
// --insecure-allow-all is set. The flag short-circuits gps.decide() for EVERY
// request (see decide() below), which means tenant isolation, row-level
// security (RLS), and field-level-encryption (FLE) authorization are ALL
// disabled — every connection can read every tenant's data.
//
// We deliberately do NOT auto-refuse-to-start when multiple tenants' data is
// present on disk: a tenant is a per-record string tag (graph_store.tenant_id),
// NOT an on-disk directory (storage is laid out per-GRAPH at
// {data_dir}/graphs/{uuid}/...), so "is more than one tenant present?" cannot
// be answered without a full scan of every node/edge across every graph at
// startup. That is neither cheap nor safe (it would force loading/decrypting
// all graph data before the listener is up), so per the GAP-0842 guidance we
// escalate to a prominent banner + documentation rather than inventing a
// fragile heuristic. See docs/security/MULTI_TENANT_HARDENING.md.
//
// Returns a multi-line, comptime-constant banner suitable for logging or
// printing to stderr at startup. Kept as a pure function so it is unit-testable
// without standing up a server.
pub fn insecureAllowAllBanner() []const u8 {
    return (
        \\========================================================================
        \\  SECURITY WARNING: --insecure-allow-all IS ENABLED
        \\------------------------------------------------------------------------
        \\  ALL authorization checks are BYPASSED. This disables:
        \\    * Tenant isolation  (every connection can read EVERY tenant's data)
        \\    * Row-level security (RLS policies are NOT evaluated)
        \\    * Field-level encryption (FLE) decrypt authorization
        \\  NOT FOR PRODUCTION. Never set --insecure-allow-all on a deployment
        \\  that holds more than one tenant's data. See
        \\  docs/security/MULTI_TENANT_HARDENING.md.
        \\========================================================================
    );
}

// CANARY: REQ=REQ-GAP-0850-INSECURE-GUARD-001; FEATURE="InsecureAllowAllProductionGuard"; ASPECT=StartupGuard; STATUS=TESTED; TEST=tests/test_gap0850_insecure_guard.zig; OWNER=security; UPDATED=2026-06-09
// GAP-0850: refuse-to-start guard for --insecure-allow-all in production.
//
// GAP-0842 added a prominent startup banner + docs for --insecure-allow-all,
// but nothing PREVENTED it from being enabled on a production deployment. This
// guard escalates that to a hard refuse-to-start when production conditions are
// detected, with an explicit break-glass override for the rare legitimate
// recovery scenario.
//
// "Production conditions" are intentionally OR'd so either signal is sufficient:
//   * `is_release` — a non-Debug optimize build (release-safe/fast/small). A
//     debug build is assumed to be a developer/test workstation.
//   * `env_production` — `GEODE_ENV=production` (case-insensitive) set in the
//     environment, which operators can assert independently of the build mode.
//
// Break-glass override: `GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND=1`. The verbose,
// unmistakable variable name is deliberate — it cannot be set by accident and
// documents acknowledgement of the bypass in the deployment manifest. When the
// override is present the guard permits startup (the GAP-0842 banner still
// fires loudly elsewhere).
//
// Kept as a pure function (mode/env/override are PARAMETERS, not read from the
// process here) so it is fully unit-testable in a Debug test binary without
// mutating real environment state. The startup call site in
// `src/server/main.zig` supplies the live values.
pub const InsecureModeError = error{InsecureAllowAllRefusedInProduction};

/// Name of the break-glass override environment variable. Exported so the
/// startup fatal-log message and tests reference the exact same string.
pub const insecure_override_env = "GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND";

/// Validate that `--insecure-allow-all` is permitted under the current
/// conditions. Returns `error.InsecureAllowAllRefusedInProduction` when the
/// flag is enabled AND a production condition holds AND the break-glass
/// override is not set. All other combinations return cleanly.
///
///   * `insecure_allow_all` — the parsed `--insecure-allow-all` flag.
///   * `is_release`        — `builtin.mode != .Debug` at the call site.
///   * `env_production`    — `GEODE_ENV` resolves to "production".
///   * `override`          — `GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND` is truthy.
pub fn validateInsecureMode(
    insecure_allow_all: bool,
    is_release: bool,
    env_production: bool,
    override: bool,
) InsecureModeError!void {
    if (!insecure_allow_all) return; // flag off — nothing to guard.
    if (override) return; // explicit break-glass acknowledgement.
    if (is_release or env_production) {
        return error.InsecureAllowAllRefusedInProduction;
    }
    // Debug build, non-production env, flag on: allowed (dev/test).
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

// CANARY: REQ=REQ-GPS-PDP-002; FEATURE="GPS Decision Engine"; ASPECT=BuiltinRoleGrants; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-21
// Phase 6 (Task 6-6): Site #2 CLOSED via grant_migration.zig (commit 64ce3940).
// All existing (:GraphGrant) records are migrated to (:Policy) rows at startup.
// Phase 7 (Task 7-7): The generic graph_grant_check_fn widening shim has been
// removed from decide(). The policy_catalog evaluation path below handles all
// grant cases via migrated Policy rows. graph_grant_check_fn is still declared
// in execution.zig for the bind_graph-specific path (Phase 3 Task 3-1).
// REQ-GPS-INVARIANT-001 ASPECT=FailOpenInterim STATUS=COMPLETE for site #2.
const user_mgmt = @import("user_management.zig");
const execution = @import("../execution.zig");
const tenancy = @import("../execution/tenancy.zig");

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
            // CANARY: REQ=REQ-GPS-CACHE-002; FEATURE="GPS Decision Cache"; ASPECT=PrincipalIdentityKey; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_phase7_alter_show_explain.yml; OWNER=security; UPDATED=2026-05-21
            // Mix the principal's username (or user_id) into the cache key so a
            // decision for one principal is never served to another. Without this
            // mix bob's "unauthorized" decision could be returned to alice when
            // both share the same (auth_version, policy_version) tuple.
            const principal_hash: u64 = blk: {
                var h = std.hash.Wyhash.init(0);
                if (req.principal.username) |u| h.update(u);
                if (req.principal.user_id) |uid| h.update(std.mem.asBytes(&uid));
                break :blk h.final();
            };
            const key = decision_cache.Key{
                .auth_version = req.principal.auth_version,
                .policy_version = policy_version.getPolicyVersion(),
                .action_tag = @intFromEnum(req.action),
                .resource_hash = hashResource(req.resource),
                .principal_hash = principal_hash,
            };
            cache_key = key;
            if (cache.lookup(key)) |cached| {
                return cached;
            }
        }
    }

    // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=DecideInsert; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
    // Helper: insert a decision into the cache (if cache_key was set) then return it.
    // error-policy: A — allocation errors from cache.insert are swallowed; a cache
    // failure must never block an authorization decision (decision still returned).
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

    // CANARY: REQ=REQ-SONNY-2744-GPS-DENY-OVERRIDES; FEATURE="GPS Policy Evaluation"; ASPECT=DenyOverridesAllow; STATUS=TESTED; TEST=tests/test_sonny2744_gps_deny.zig; OWNER=security; UPDATED=2026-09-25
    // SONNY-2744: a matching deny-effect policy refuses the request, whatever
    // would allow it below: a builtin role, an Admin shortcut (decrypt_field,
    // unwrap_key) or an allow policy. The policy catalog below used to skip
    // deny policies, so a deny never denied. Only actions a policy can name
    // (`policyMatchesAction`) can be denied; --insecure-allow-all, above,
    // still overrides everything.
    if (denyPolicyApplies(allocator, req)) {
        return cacheAndReturn(cache_key, PolicyDecision{
            .kind = .deny,
            .reason_code = "policy_deny",
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
        // CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=ReadWritePermissiveSingleTenant; STATUS=TESTED; TEST=geodetestlab/specs/rls_cross_tenant_query_shapes.yml; OWNER=security; UPDATED=2026-07-08
        // Additive/permissive per-graph binding in the default single-tenant config.
        // The per-graph grant is ADDITIVE, not mandatory, for a ReadWrite principal
        // in a non-strict deployment: ReadWrite already holds a baseline write
        // capability over the single tenant's graphs (the QUIC HELLO path lets it
        // auto-create and bind brand-new graphs with no grant), so denying it an
        // *existing* ungranted graph is inconsistent and breaks the documented
        // permissive-single-tenant model — RLS/ABAC/FLE govern row/field access,
        // NOT graph-bind (see CLAUDE.md "Auth DDL persistence"). ReadOnly holds NO
        // baseline graph capability, so it still requires an explicit grant: this
        // preserves the NEW-1 (#861) cross-graph BOLA fix, whose regression test
        // (tests/test_new1_cross_graph_bola.zig) denies a *ReadOnly* user an
        // ungranted graph. When strict tenancy is in effect (auto-enabled for any
        // multi-tenant deployment — GAP-0848), the grant is mandatory for every
        // non-admin role, so this permissive path is gated on !isStrictTenancy().
        if (!tenancy.isStrictTenancy()) {
            for (req.principal.roles) |role_name| {
                if (std.mem.eql(u8, role_name, "ReadWrite")) {
                    return cacheAndReturn(cache_key, PolicyDecision{
                        .kind = .allow,
                        .reason_code = "bind_graph_readwrite_permissive_single_tenant",
                    });
                }
            }
        }
        return cacheAndReturn(cache_key, PolicyDecision{
            .kind = .unauthorized,
            .reason_code = "bind_graph_no_evidence",
        });
    }

    // CANARY: REQ=REQ-GPS-ADMIN-TENANT-001; FEATURE="GPS AdminTenant Action"; ASPECT=AdminAllowed; STATUS=TESTED; TEST=tests/test_gap0839_tenant_lifecycle.zig; OWNER=security; UPDATED=2026-06-08
    // GAP-0839: admin_tenant — the authorization gate for tenant lifecycle
    // administration (CALL geode.tenant.create/list/show/drop/set_quota).
    // Admin is always allowed; any non-Admin principal is denied (fail-closed).
    // There is no permission-level analogue (actionToPermission returns null for
    // admin_tenant), so without this branch every caller — including Admin —
    // would fall through to the policy catalog and be denied, leaving tenant
    // administration unreachable. Tenant admin is intentionally admin-only and
    // is NOT widenable by a graph/Read/Write grant; only the Admin builtin role
    // (or, in a future iteration, an explicit admin_tenant Policy) authorizes it.
    if (req.action == .admin_tenant) {
        for (req.principal.roles) |role_name| {
            if (std.mem.eql(u8, role_name, "Admin")) {
                return cacheAndReturn(cache_key, PolicyDecision{
                    .kind = .allow,
                    .reason_code = "admin_tenant_admin",
                });
            }
        }
        return cacheAndReturn(cache_key, PolicyDecision{
            .kind = .unauthorized,
            .reason_code = "admin_tenant_not_admin",
        });
    }

    // Phase 2 task 2-4: builtin-role evaluation.
    // Walk the principal's roles slice, resolve each to a user_management.Role,
    // and ask hasPermission() — preserving legacy semantics bit-identically.
    // Task 2-9 layers the insecure-allow-all flag (handled above).
    // Phase 7 task 7-7: graph-grant widening shim removed; policy_catalog below
    // is the sole path for grant-based widening after builtin-role evaluation.
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
    }

    // CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=ExplicitAllow; STATUS=TESTED; TEST=tests/test_gps_policy_evaluation.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=DecideEvalExpression; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 4: explicit policy match via the global PolicyCatalog.
    // Phase 5 (Task 5-4): attribute-based expression predicates are now
    // evaluated via the compiled CompiledExpression stored on each Policy.
    const pc = @import("policy_catalog.zig");
    if (pc.getGlobalCatalog()) |cat| {
        for (cat.listPolicies()) |*policy| {
            // SONNY-2744: deny policies were applied above.
            if (policy.effect != .allow) continue;
            if (!policy.enabled) continue;
            if (!policyMatchesAction(policy.*, req.action)) continue;
            if (!policyMatchesResource(policy.*, req.resource)) continue;
            if (policyExpressionHolds(allocator, policy, req)) {
                return cacheAndReturn(cache_key, PolicyDecision{
                    .kind = .allow,
                    .reason_code = "policy_match",
                });
            }
        }
    }

    return cacheAndReturn(cache_key, PolicyDecision{
        .kind = .unauthorized,
        .reason_code = "no_evidence",
    });
}

/// SONNY-2744: is there an enabled deny-effect policy that matches `req`
/// (action, resource and USING expression)? Resources match as for allow
/// policies (`policyMatchesResource`): a policy scoped to one graph matches
/// that graph, and also every database-, tenant-, node-, edge-, procedure- and
/// metadata-scoped request, so a deny covers at least what the same allow
/// would have granted.
fn denyPolicyApplies(allocator: std.mem.Allocator, req: *const DecisionRequest) bool {
    const pc = @import("policy_catalog.zig");
    const cat = pc.getGlobalCatalog() orelse return false;
    for (cat.listPolicies()) |*policy| {
        if (policy.effect != .deny) continue;
        if (!policy.enabled) continue;
        if (!policyMatchesAction(policy.*, req.action)) continue;
        if (!policyMatchesResource(policy.*, req.resource)) continue;
        if (policyExpressionHolds(allocator, policy, req)) return true;
    }
    return false;
}

/// Does `policy`'s USING expression hold for `req`? The trivial "true" holds.
/// A policy whose expression failed to compile when it was loaded
/// (`PolicyCatalog.policyIsValid` false) is kept fail-closed: as an allow it
/// never holds (it grants nothing), and, SONNY-2744, as a deny it always holds
/// (it keeps refusing) until an operator rewrites it.
fn policyExpressionHolds(allocator: std.mem.Allocator, policy: *const @import("policy_catalog.zig").Policy, req: *const DecisionRequest) bool {
    const policy_expression = @import("policy_expression.zig");
    const cexpr = if (policy.compiled) |*compiled| compiled else {
        if (std.mem.eql(u8, policy.expression_source, "true")) return true;
        return policy.effect == .deny;
    };

    // CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=DecidePopulateAttributes; STATUS=TESTED; TEST=tests/test_gps_abac_predicates.zig; OWNER=security; UPDATED=2026-05-22
    // Build an evaluation context from the current request.
    // Phase 6 (Task 6-2): principal_attributes is populated from the
    // caller's AttributeMap so that eq_principal_attr predicates can
    // match ABAC key/value pairs without any additional allocation.
    //
    // GAP-0284 (2026-05-22): the principal carried by every transport
    // (QUIC, gRPC, MCP, distributed) is currently constructed with
    // attributes=emptySentinel() because derivePrincipal() runs without
    // an allocator. To make ABAC predicates actually fire, fall back
    // to the security/user_attribute_store snapshot keyed by the
    // authenticated username when the principal's own attribute slice
    // is empty.
    comptime std.debug.assert(@sizeOf(principal_mod.AttributeMap.Entry) == @sizeOf(policy_expression.AttributeEntry));
    const raw_entries = req.principal.attributes.entries;
    var owned_snapshot: ?[]policy_expression.AttributeEntry = null;
    defer if (owned_snapshot) |snap| {
        for (snap) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        allocator.free(snap);
    };
    const attr_entries: []const policy_expression.AttributeEntry = if (raw_entries.len > 0) blk: {
        break :blk @as(
            [*]const policy_expression.AttributeEntry,
            @ptrCast(raw_entries.ptr),
        )[0..raw_entries.len];
    } else if (req.principal.username) |uname| blk: {
        const snap = @import("user_attr_store").snapshotEntries(
            allocator,
            uname,
            policy_expression.AttributeEntry,
        ) catch {
            // The principal's attributes cannot be read. Fail closed: a deny
            // holds, and an allow sees no attributes (so grants on none).
            if (policy.effect == .deny) return true;
            break :blk &[_]policy_expression.AttributeEntry{};
        };
        if (snap.len > 0) owned_snapshot = snap;
        break :blk snap;
    } else &[_]policy_expression.AttributeEntry{};
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
    return policy_expression.evaluate(cexpr, ctx);
}

// CANARY: REQ=REQ-SONNY-2743-WHOLE-PROGRAM-GATE; FEATURE="StatementAuthorization"; ASPECT=WriteGate; STATUS=TESTED; TEST=tests/test_sonny2743_whole_program_gate.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2743: the QUIC and gRPC handlers' write-permission gate: may
/// `principal` run a program that changes the store
/// (`query_traits.statementPlan(..).is_mutation`)? `decide(write, database)`
/// answers; an error answers no. A builtin role with WRITE is allowed by
/// `decide` itself, so this is what QUIC's inline role check followed by
/// `decide` answered; both handlers now run this one function.
pub fn writePermitted(allocator: std.mem.Allocator, principal: *const principal_mod.Principal) bool {
    const req = DecisionRequest{
        .principal = principal,
        .action = .write,
        .resource = .{ .database = {} },
    };
    const decision = decide(allocator, &req) catch return false;
    return decision.kind == .allow;
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
