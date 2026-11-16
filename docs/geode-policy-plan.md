# Geode Policy System Design

## Executive Summary

Geode already has substantial security-related code, but it does **not** have one authoritative policy system today. Instead, the repository shows several overlapping layers: a builtin runtime role model in `src/security/user_management.zig`, a richer but separate security manager in `src/security/geode_auth_lib.zig`, a chain-based authentication provider in `src/security/authn.zig`, and a persistent `__geode_security` graph manager in `src/security/auth_graph_manager.zig`. Query execution then consumes a much narrower context (`user`, builtin `role`, `tenant_id`, session graph, optional RLS pointers) than the richer security subsystems can express. That is the central architectural problem: Geode has many security features, but no single policy decision point. citeturn13view0turn13view1turn14view1turn13view3turn17view0

The best implementable direction is to build **GPS, the Geode Policy System**, as a **central authorization façade** over the current code rather than replacing everything at once. GPS should reuse the existing `__geode_security` persistence model and HMAC-sealed security graph, extend the existing RLS expression VM instead of inventing a new evaluator, and progressively convert existing ad hoc checks, graph grants, RLS evaluation, metadata visibility, FLE/TDE decisions, procedure execution, and MCP/LSP access into calls to one canonical `decide()` API. That lets engineering ship incrementally while converging on fail-closed behavior. citeturn13view3turn14view8turn14view10turn17view2

The main risks are not theoretical. They are visible in the current implementation. `execution.checkPermission()` allows everything when auth is disabled and only uses graph grants as an additive fallback on the currently bound graph. The RLS engine defaults to allow when no policies are found, and part of the expression VM also defaults to allow when no expression result is produced. Metadata procedures such as `db.labels()`, `db.relationshipTypes()`, and `db.propertyKeys()` enumerate the full store without tenant or graph filtering. MCP is protected at the server boundary by a bearer token, but MCP tools then call Geode with a process-wide client path rather than a per-caller principal. Procedure access classification exists, but the registry dispatch path does not consult it. Those are the highest-value places to close first. citeturn17view0turn14view8turn15view10turn19view0turn16view2turn16view5turn15view5turn15view6

The implementation sequence should therefore be: make principal/context propagation canonical; introduce the central decision API and wrap existing checks; enforce graph and tenant isolation at all metadata and procedure surfaces; persist full policies in `__geode_security`; then harden MCP/LSP, FLE/TDE, and distributed execution. That order matches where the repository already has reusable building blocks and where it is currently most exposed. citeturn17view0turn17view2turn15view1turn15view10turn19view0turn16view2turn16view5

## Repository Evidence Map

Several Geode source files are highly compressed in raw form. For the line ranges below, I identified functions/types from the current `main` branch snapshot and derived ranges from the reviewed raw sources. Where I cite a named test file that I opened directly, I treat it as **Implemented + tested**. Where a source comment references a named test or geodetestlab spec that I did not independently open, I treat that as weaker evidence.

| Feature | Source file or doc | Current behavior | Status | Tests found | Gap | Design implication |
|---|---|---|---|---|---|---|
| Builtin runtime auth and permissions | `src/security/user_management.zig` `Role`/`Permission`/`User` (63–123), `authenticate` (462–479), `assignRole` (580–600), `setUserActive` (606–621), `isSessionAuthCurrent` (819–821) citeturn13view0turn23view0 | Four builtin roles (`Admin`, `User`, `ReadWrite`, `ReadOnly`) map to `Read`/`Write`/`Schema`; user records carry `auth_version`; role and active-state changes bump `auth_version`. | Implemented + tested | `tests/test_auth_persistence.zig` directly inspected. | No tenant, graph, MFA, API key, or custom-role structure in the runtime authority Geode execution actually uses. | GPS must wrap this path first, not ignore it. |
| Chain-based authentication provider | `src/security/authn.zig` `AuthMethod`/`AuthRequest`/`AuthResult` (61–115), `authenticate` (261–305), session handling (352–449) citeturn13view1 | Supports mTLS, API key, session token, password, MFA/recovery, anonymous; session rotation and step-up state exist. | Implemented, not sufficiently tested | Named tests are referenced in source comments, but I did not inspect `tests/test_authn.zig`. | Not obviously the single source of truth for all transports; returned identity does not include tenant or active graph. | GPS should derive one canonical `Principal` from this layer where available. |
| Rich security manager | `src/security/geode_auth_lib.zig` `Session` and MFA policy structures (179–215), MFA evaluation (632–705), sessions and authorization (867–935), role/permission management (945–998), authentication + MFA (1425–1614) citeturn14view1 | Has users, sessions, RBAC, permissions, ABAC-style evaluation, MFA policies, step-up metadata, superuser behavior. | Partially implemented | Source comments reference tests, but I did not inspect those tests in this pass. | This richer model is **not** the same model consumed by `execution.checkPermission()`. | GPS should absorb the concepts here, but execution must stop bypassing them. |
| Persistent security graph | `src/security/auth_graph_manager.zig` user persistence (725–885), role persistence (896–980), graph grants (960–987), graph visibility helper (989–1035), plus server startup wiring in `src/server/main.zig` (760–770) citeturn13view3turn17view2turn23view0 | Users, roles, and graph grants persist in `__geode_security`; writes reseal an HMAC-backed integrity chain; startup installs persistence callbacks and persistent user resolver. | Implemented + tested | `tests/test_auth_persistence.zig` directly inspected. | Persistence covers grants and auth records, but not a general policy catalog. | Reuse `__geode_security` and its integrity machinery for GPS. |
| Graph grants | `src/security/multi_graph_security.zig` `GraphRBACPolicy` and grant accessors (102–345), `src/execution.zig` `graph_grant_check_fn` and `checkPermission` (814–856) citeturn14view6turn17view0turn23view0 | Per-graph grants are stored separately and loaded at startup, but execution uses them only as a **widening fallback** when builtin role permission fails and a bound graph is present. | Partially implemented | `tests/test_auth_persistence.zig` directly inspected for grant round-trip only. | No explicit deny, no tenant binding, no `BIND_GRAPH` authorization, and no canonical grant object model. | GPS should subsume grants as first-class policies with scoped allow/deny semantics. |
| RLS label and expression engine | `src/security/rls_core.zig` `createPolicy` (313–342), `checkRowAccessByUsername` (1065–1105), VM default allow (1363); `src/security/rls_types.zig` global engine pointers (268–292); `src/execution/match_operations.zig` RLS checks (115–167); `src/server/main.zig` engine wiring (1048–1064) citeturn14view8turn14view10turn15view10turn17view2turn23view1 | Expression compilation and runtime evaluation exist; match operations call the engine; the engine is published globally at startup. | Partially implemented | `tests/test_rls_expr_engine_wiring.zig` directly inspected. | Current behavior is fail-open when no policy exists and also in a VM no-result path; no parser-backed policy DDL or durable persistence was found. | GPS should reuse the VM, but invert default semantics to fail closed at the policy layer. |
| Tenant and graph isolation in storage and reads | `src/graph_store.zig` node/edge tags (120–143), tenant-aware node creation (1450–1555), `getNodesByLabels` (2476–2497), `getAllNodesForTenant` (3189–3208), `getEdgesByType` (4433–4488); `src/execution/match_operations.zig` tenant filtering (102–113, 1688–1803); `src/execution/statement_handlers.zig` `SHOW TABLES` tenant filter (141–163) citeturn17view1turn15view10turn15view1turn23view2 | Nodes and edges carry `graph_name` and `tenant_id`; label index scans and edge scans can filter by tenant; `MATCH` threads the session tenant; `SHOW TABLES` was fixed to filter by tenant. | Partially implemented + tested | `tests/test_gap0509_tenant_isolation.zig` directly inspected. | Tenant isolation is present in important paths, but it is not centralized or non-bypassable at every metadata and admin surface. | GPS must treat tenant scope as mandatory and non-overridable except for explicit audited internal principals. |
| Metadata introspection | `src/execution/meta_dispatch.zig` `db.labels`, `db.relationshipTypes`, `db.propertyKeys`, `db.indexes`, `db.constraints`, `dbms.procedures`, `dbms.functions`; `src/execution/statement_handlers.zig` `SHOW GRAPHS`/`SHOW INDEXES`/`SHOW CONSTRAINTS` (74–165) citeturn19view0turn15view1turn23view4 | `db.labels()` and related `db.*` procedures iterate global store contents; `SHOW GRAPHS`, `SHOW INDEXES`, and `SHOW CONSTRAINTS` are global listings. | Unsafe / fail-open risk | `tests/test_meta_procedures.zig` inspected for dispatch presence, not policy filtering. | These paths can leak labels, edge types, property keys, graphs, indexes, and constraints across tenants or graphs. | GPS must own `SHOW_METADATA` and filter all result rows. |
| Procedure access control | `src/execution/procedure_access.zig` classification table (1–116), `src/execution/procedure_registry.zig` dispatch (94–166) citeturn15view5turn15view6 | A read-only versus mutating procedure classifier exists, but the registry dispatch path does not consult it before executing procedures. | Unsafe / fail-open risk | No inspected enforcement test found. | Classification is dead weight unless invoked at dispatch time. | GPS needs a mandatory `EXECUTE_PROCEDURE` decision point in the registry. |
| Auth DDL and pseudo-policy procedures | `src/gql/parser.zig` auth DDL parsing (6323–6460), `src/gql/ast.zig` auth AST types (665–725), `src/execution/admin_ddl.zig` mapping to `geode.auth.*` (1–174), `src/execution/auth_dispatch.zig` `handlePolicyCreate/List/Delete` (940–995) citeturn16view0turn16view1turn15view3turn15view4 | `CREATE USER`, `ALTER USER`, `DROP USER`, `CREATE ROLE`, `DROP ROLE`, `GRANT`, `REVOKE`, and `SHOW USERS/ROLES/PERMISSIONS` exist. “Policy” procedures only store name/description in an in-memory map. | Partially implemented | Auth DDL parser and execution are present; no parser-backed `CREATE POLICY` or `SHOW POLICIES` statement was found. | There is no real policy DDL today. | GPS needs real policy AST/DDL, not the current placeholder map. |
| API keys | `src/security/authn.zig` API key validation path (288–345); `src/execution/auth_dispatch.zig` API key handlers (1110–1245) citeturn13view1turn15view4 | `authn` expects a real `ApiKeyManager.validateKey()` path, but auth DDL handlers fabricate `gk1.user.name`, return empty lists, and say every checked scope is granted. | Contradictory evidence | No inspected end-to-end API key test found. | Management and enforcement appear to belong to different systems. | GPS should consolidate API key subject storage, scope policy, and revocation. |
| MCP and LSP | `src/mcp/server.zig` bearer-token server auth and handlers (13–217), `src/mcp/tools.zig` generic tool client calls (37–181), `src/mcp/lsp.zig` text-only validate/complete/hover (1–8) citeturn16view2turn16view5turn16view3 | MCP is protected by a server-level bearer token, but query/schema tool calls use a generic client path; LSP validate/complete/hover operate on query text and language metadata, not a per-user principal. | Unsafe / fail-open risk | No inspected per-caller permission test found. | This is not suitable when different callers should see different graphs, labels, or diagnostics. | GPS must thread principal identity into MCP/LSP calls and filter outputs. |
| FLE hooks | `src/execution/fle_hooks.zig` encryption/decryption hooks (21–168); `src/execution.zig` `tenant_id` on context (480–490) citeturn19view2turn17view0 | FLE encryption uses current thread tenant and current user role; required encryption fails secure; decrypt returns `[REDACTED]` on failure. | Implemented, not sufficiently tested | Source comments reference tests, but I did not inspect them directly. | No central action model exists for `DECRYPT_FIELD` or `UNWRAP_KEY`. | GPS should treat encrypted-field access as an explicit policy decision, not just a hook-side role check. |
| Documentation versus code | `docs/FULL_AUDIT_2026_04_06.md`, `docs/TODO.md`, `docs/SECURITY_PROGRESS.md`, and current source paths above citeturn1view1turn1view4turn3view0turn17view1turn15view10 | The documentation still frames tenant isolation and production hardening as unfinished, while the source now contains graph and tenant tags, tenant-aware scans, and RLS wiring. | Contradictory evidence | N/A | The docs understate some progress and do not close all real gaps. | Phase zero should reconcile documentation with actual invariants before policy rollout. |

## Existing Security and Tenant Model

### Identity model

Geode currently exposes **multiple identity shapes**, not one canonical principal. The simplest one is `user_management.User`, which contains `username`, `email`, builtin `role`, `active`, `password_reset_required`, and `auth_version`. That model is what the execution layer’s coarse permission checks are built around. It has no first-class tenant, graph, session, MFA, API key, or mTLS fields. citeturn13view0turn17view0

A second identity path is `authn.AuthRequest` and `authn.AuthResult`. That layer supports mTLS certificates, bearer API keys, session tokens, username/password, TOTP, recovery codes, IP address, user agent, and request path. The result carries `user_id`, `username`, `method`, `roles`, `scopes`, optional `session_token`, `requires_mfa`, `requires_password_reset`, and `elevation_level`. That is closer to the principal GPS needs, but it is not the type that query execution consumes directly. citeturn13view1

A third identity path exists in `geode_auth_lib`. Its `Session` stores `last_mfa_ts` and an elevation expiry, and its MFA policy system can evaluate roles, user attributes, time windows, risk-score thresholds, and reauthentication intervals. That model is materially richer than the builtin runtime role path, which is exactly why a clean-room policy design would be a mistake here: the repository already contains concepts GPS should absorb. citeturn14view1

mTLS is separately modeled in `mtls_provider.zig`. `CertificateIdentity` carries fingerprint, subject CN/DN, SANs, issuer, validity window, and serial number; `MtlsProvider.authenticate()` maps that identity to a `user_id` plus role strings. I did not find tenant or active-graph binding in this certificate mapping model. citeturn14view5turn13view1

Tenant and graph association are mostly carried **outside** the user model today. `ExecutionContext` carries `tenant_id`, optional `session_state`, and graph-binding state, while data records carry `graph_name` and `tenant_id` directly. FLE also pulls the current tenant and current user role from integration context rather than from a canonical principal object. That means identity propagation is fragmented across user records, session state, execution context, and thread-local integration state. citeturn17view0turn17view1turn19view2

### Permission model

The runtime permission model that query execution currently trusts is the small builtin mapping in `user_management`: role to `Read`, `Write`, `Schema`. `execution.checkPermission()` uses that mapping first. If the builtin role does not authorize the action, only then does it optionally fall back to a graph grant callback for the currently bound graph. That proves current enforcement is **role-first and widening-only**, not policy-first. citeturn13view0turn17view0

A richer permission model exists elsewhere. `geode_auth_lib` has role records, permission records, role membership, role grants, and ABAC-style evaluation. `multi_graph_security.GraphRBACPolicy` tracks graph-scoped roles, global roles, role hierarchy, and explicit per-graph grants. `auth_graph_manager` persists roles and graph grants into `__geode_security`. But the execution core does not consume those structures as its canonical decision engine. That is the strongest evidence that GPS should be built as a unification layer over existing parts, not as another parallel subsystem. citeturn14view1turn14view6turn13view3turn17view0

RLS exists in two layers. `rls_types` maintains label-deny and property-predicate structures, and `rls_core` can compile and evaluate expression policies, including a `checkRowAccessByUsername()` helper that match execution currently uses. This is already a policy evaluator, but only for a narrow row-filtering slice, and it defaults to allow when no policies exist. citeturn14view10turn14view8turn15view10turn23view1

Admin DDL is wired through parser/AST support for users, roles, grants, revokes, and `SHOW USERS/ROLES/PERMISSIONS`, then mapped in `admin_ddl.zig` onto `geode.auth.*` procedures. However, there is no parser-backed `CREATE POLICY`, `ALTER POLICY`, `DROP POLICY`, `SHOW POLICIES`, or `SHOW GRANTS` statement in the reviewed AST/parser paths. The existing `geode.auth.policy_*` procedures are placeholders backed by an in-memory `StringHashMap(name -> description)`, not actual authorization policy. citeturn16view0turn16view1turn15view3turn15view4

Field-level encryption is present and important. `fle_hooks.zig` builds encryption contexts from current tenant and user role, fails secure on required-encryption writes, and redacts on read failure. That proves Geode already has the shape of classification-aware data access, but it is not centrally normalized as `DECRYPT_FIELD` or key-access policy today. citeturn19view2turn17view0

### Tenant and graph model

Tenant and graph identity are implemented at the **data plane**. `graph_store.Node` and `graph_store.Edge` include both `graph_name` and `tenant_id`. Node creation uses the active tenant from integration state, and read helpers such as `getNodesByLabels`, `getAllNodesForTenant`, and `getEdgesByType` accept tenant and graph filters. That is solid evidence that multi-tenant and multi-graph awareness is already embedded in storage. citeturn17view1

The main query read path respects those storage-level scopes in important places. `query_execution` extracts the active graph from session state and passes it into match execution, while `match_operations` resolves the session tenant filter and applies both graph and tenant filtering during indexed scans and graph-scoped scans. `SHOW TABLES` was specifically fixed to pass the session tenant into `listNodeLabels()`. The repository’s tenant isolation test directly describes and checks that repair. citeturn15view2turn15view10turn15view1turn23view2

At the same time, tenant membership is **not** first-class in the user principal I found. The reviewed user and auth result structures do not store tenant membership or graph membership as canonical identity attributes. `tenant_quota.zig` adds per-tenant connection and concurrent-query quota management, but that is an operational limiter, not an authorization model. citeturn13view0turn13view1turn14view7

Graph switching is also only partially governed. `USE GRAPH` validates graph existence and respects DSN graph-binding when present, but in the reviewed execution path I did not find a dedicated graph-bind authorization decision before switching. That is a design gap because graph visibility and graph use are not the same thing. citeturn17view0

### Enforcement map

The parser and AST support auth DDL but not real policy DDL. The execution layer has coarse global permission checks, plus tenant and RLS enforcement in `MATCH`, but enforcement is not centralized. Storage is tenant-aware for several indexed and iteration paths, yet metadata surfaces are not uniformly filtered. Procedures dispatch without a mandatory policy gate. MCP/LSP are not principal-aware in the reviewed code. Distributed/sharded comments exist in the storage layer, but I did not find policy-context propagation for cluster execution in the reviewed paths. That last point is an inference from the reviewed files, not proof that no such code exists anywhere else in the repository. citeturn16view0turn15view3turn17view0turn15view10turn17view1turn19view0turn15view5turn15view6turn16view2turn16view5

## Gap Analysis

### Correctness gaps

The largest correctness gap is **authority fragmentation**. The execution plane trusts builtin roles from `user_management`, while richer custom roles, permissions, MFA policies, and ABAC logic live in `geode_auth_lib`, and persistent auth objects live in `auth_graph_manager`. That means “what is stored,” “what can be authenticated,” and “what is actually enforced” are not guaranteed to match. citeturn13view0turn14view1turn13view3turn17view0

There is also a direct contradiction in the API key surface. `authn` authenticates API keys through an `ApiKeyManager.validateKey()` path, but the admin procedures in `auth_dispatch` fabricate deterministic `gk1.user.name` values, return stub lists, and report checked scopes as granted. That is not just incomplete; it is structurally unsafe because management and enforcement can drift. citeturn13view1turn15view4

Procedure access is another correctness gap. `procedure_access.zig` knows which procedures are read-only versus mutating, but `procedure_registry.executeCallProcedure()` dispatches directly by name and does not consult that classifier. In effect, the repository contains the beginnings of procedure policy but not the enforcement path. citeturn15view5turn15view6

### Tenant isolation gaps

Tenant isolation exists in important read paths, but it is not non-bypassable. `MATCH` and `SHOW TABLES` thread tenant filters, yet `db.labels()`, `db.relationshipTypes()`, and `db.propertyKeys()` enumerate full store contents. `SHOW GRAPHS`, `SHOW INDEXES`, and `SHOW CONSTRAINTS` are also global listings in the reviewed execution path. Those are metadata leaks even when row data scans are filtered correctly. citeturn15view10turn15view1turn19view0turn23view2

The graph-grant model is also not tenant-aware. Current graph grants are keyed by `(user_id, graph_name, action)` and execution uses them only as widening fallbacks. I found no binding to tenant membership, no deny semantics, and no dedicated authorization check on graph binding itself. citeturn14view6turn13view3turn17view0

### Policy persistence and DDL gaps

There is no evidence of a durable, parser-backed unified policy catalog. `rls_core` can store policies in memory and compile expressions, but I did not find parser-backed `CREATE POLICY` or persistence logic for that policy set in the reviewed DDL paths. The only “policy” procedures exposed through auth dispatch are an in-memory name/description map. citeturn14view8turn16view0turn15view3turn15view4

That means Geode currently lacks a durable source of truth for ABAC, row filters, write checks, masking rules, metadata visibility rules, procedure policies, or key-access rules. GPS therefore needs not just a decision engine but also a real policy catalog and versioning model. citeturn13view3turn15view4

### Fail-open and metadata gaps

`execution.checkPermission()` returns immediately when auth is disabled. `rls_core.checkRowAccessByUsername()` returns allow when no policies are present. The expression VM also returns allow when no expression result is produced. Those defaults are understandable during development, but they are incompatible with a unified fail-closed policy system. citeturn17view0turn14view8turn23view1

Metadata leakage is especially high-risk because it is low-friction for attackers and tooling alike. The reviewed metadata procedures reveal labels, relationship types, property keys, indexes, constraints, procedure names, and function names without a per-user policy gate. In a multi-tenant or multi-graph deployment, that is reconnaissance exposure even when data queries are filtered. citeturn19view0turn15view1

### Audit, testing, and documentation gaps

Audit logging clearly exists, and server startup installs a global audit logger, but I did not find a single central authorization audit event containing subject, resource, action, decision, policy IDs, obligations, and deny reasons because there is no central decision point yet. GPS should make that event mandatory. citeturn17view2turn13view3

Testing is strongest around point fixes and feature islands: auth persistence callbacks, RLS wiring, tenant label isolation, and meta-procedure dispatch. I did **not** find inspected end-to-end tests proving that tenant isolation, graph grants, procedure access, metadata visibility, MCP, FLE/TDE access, and distributed execution all compose under one authority model. citeturn23view0turn23view1turn23view2turn23view4

The documentation is also stale in ways that matter. `FULL_AUDIT_2026_04_06.md` and `TODO.md` still frame tenant isolation and production hardening as unfinished, while the current source clearly contains tenant tags, tenant-aware scans, SHOW TABLES filtering, and RLS engine wiring. The right conclusion is not that the docs are wrong and the code is done; it is that the repo needs an explicit invariants pass before policy consolidation. citeturn1view1turn1view4turn3view0turn17view1turn15view10

## Unified Policy System Design

### Design intent

GPS should become the **only** place that returns authorization decisions, but it should do so by **adapting** current Geode subsystems rather than replacing them all at once. In practice, that means: keep `user_management` alive as a legacy builtin-role adapter, import persistent users/roles/grants from `auth_graph_manager`, consume graph grants from `multi_graph_security`, reuse `rls_core` for compiled policy predicates, and keep FLE/TDE hooks as enforcement points that call into GPS instead of making their own final decision. That recommendation is grounded in the repository’s existing fragmentation and reusable infrastructure. citeturn13view0turn14view1turn13view3turn14view6turn14view8turn19view2

### Canonical principal, resource, action, and decision models

The central new type should be a typed principal assembled exactly once at the session or request boundary and then threaded through every execution path.

```zig
pub const Principal = struct {
    user_id: ?u64,
    username: ?[]const u8,
    session_id: ?[]const u8,
    tenant_id: ?[]const u8,
    active_graph: ?[]const u8,

    roles: []const []const u8,        // builtin + resolved role names
    custom_roles: []const []const u8, // preserved for compatibility

    auth_method: AuthMethod,
    auth_version: u64,

    mfa_state: MfaState,
    elevation_until: ?i64,

    api_key_id: ?u64,
    certificate_subject: ?[]const u8,

    risk_context: RiskContext,
    attributes: AttributeMap,

    source: PrincipalSource,
};
```

This model is deliberately shaped to subsume what already exists: builtin roles and `auth_version` from `user_management`, auth chain fields from `authn`, session elevation and user attributes from `geode_auth_lib`, certificate-derived identity from `mtls_provider`, and execution graph/tenant fields from `ExecutionContext`. citeturn13view0turn13view1turn14view1turn14view5turn17view0

A canonical resource model should cover database, graph, tenant, node, edge, label, relationship type, property, index, constraint, procedure, function, backup, key, audit log, internal security graph, and metadata result sets. An action model should normalize current Geode operations into `READ`, `MATCH`, `TRAVERSE`, `CREATE`, `UPDATE`, `DELETE`, `MERGE`, `SET_PROPERTY`, `REMOVE_PROPERTY`, `CREATE_SCHEMA`, `ALTER_SCHEMA`, `DROP_SCHEMA`, `EXECUTE_PROCEDURE`, `ADMIN_USER`, `ADMIN_ROLE`, `ADMIN_POLICY`, `ADMIN_TENANT`, `BIND_GRAPH`, `SHOW_METADATA`, `BACKUP`, `RESTORE`, `EXPORT`, `IMPORT`, `DECRYPT_FIELD`, and `UNWRAP_KEY`. Current statement and procedure paths already imply most of those actions; GPS just makes them explicit. citeturn17view0turn15view3turn15view6turn19view0turn19view2

The decision result should be richer than a boolean:

```zig
pub const PolicyDecisionKind = enum {
    allow,
    deny,
    filter,
    mask,
    require_mfa,
    require_elevation,
    audit_only,
    not_applicable,
};

pub const PolicyDecision = struct {
    kind: PolicyDecisionKind,
    reason_code: []const u8,
    policy_ids: []const u64,
    obligations: []const Obligation,
    audit_fields: AuditFields,
    cacheable: bool,
    expires_at_ms: ?i64,
    debug: ?PolicyExplain, // admin-gated
};
```

That shape is necessary because Geode already has disparate behaviors that are not simple allow/deny: graph-grant widening, row filtering, FLE redaction, MFA requirement, and audit logging. GPS must model those directly rather than collapsing them into booleans. citeturn17view0turn14view8turn19view2turn13view1turn14view1

### Evaluation order and expression language

The evaluation order should be deterministic:

1. Session or credential validity.
2. `auth_version` and session invalidation checks.
3. Principal derivation and tenant membership resolution.
4. Graph binding authorization.
5. Non-bypassable tenant isolation.
6. Explicit deny policies.
7. Narrow internal admin overrides, if any.
8. Role grants.
9. Graph grants.
10. ABAC predicates.
11. RLS filters and write checks.
12. Classification and key-access rules.
13. MFA, elevation, and risk checks.
14. Audit obligations.

That order follows the current repository’s realities. Auth/session validity already exists. Graph grants are currently widening-only; GPS should move them earlier as scoped policy facts. RLS already exists and should remain below coarse grant evaluation, but above object return. FLE/TDE should be late-stage obligations on specific resources and fields. citeturn13view0turn13view1turn14view1turn14view6turn14view8turn19view2

The expression language should be minimal and should **reuse the existing `rls_core` compiler/VM**. That is the least risky path because Geode already has `createPolicy`, `compileExpression`, and `checkRowAccessByUsername()` semantics. GPS should extend that VM with a `PolicyEvalContext` that exposes pure, side-effect-free builtins such as `current_user()`, `current_tenant()`, `current_graph()`, `has_role()`, `has_grant()`, `mfa_level()`, `risk_score()`, `auth_method()`, `classification()`, and resource/object fields. The VM should remain deterministic, function-allowlisted, parameter-bound, and cache-keyed by normalized source plus engine version. citeturn14view8turn23view1

### Enforcement architecture

The architecture should look like this:

```text
Policy Administration Point
  parser/AST/admin DDL/MCP admin API
        |
        v
Policy Catalog in __geode_security
  User / Role / Tenant / Policy / GraphGrant / KeyGrant / PolicyVersion
  HMAC-sealed, versioned, startup-hydrated
        |
        +-----------------------------+
        |                             |
        v                             v
Policy Information Point         Audit Sink
  authn / auth graph /           decision logs, deny logs,
  execution context /            break-glass logs, policy drift logs
  graph store metadata /
  FLE/TDE metadata /
  tenant catalog
        |
        v
Central Policy Decision Point
  gps.decide(principal, action, resource, object_ctx)
        |
        +---------------------------------------------------------------+
        |                |                 |              |              |
        v                v                 v              v              v
  auth boundary     query planner     execution      metadata      procedure registry
  graph bind/switch index/scan push   CRUD/MATCH     SHOW/db.*     CALL dispatch
                                      traversal/
                                      aggregation
        |
        +-----------------------+
        |                       |
        v                       v
   FLE/TDE hooks            MCP/LSP bridge
        |
        v
 distributed router / shard worker authorization envelope
```

The key design point is that current Geode already has many PEP candidates, but they are not asking one question from one engine. GPS should make `decide()` the only authority and leave the subsystems as enforcement points and information providers. citeturn17view0turn15view10turn15view1turn19view0turn15view6turn16view2turn16view5turn19view2

### Persistence choice

Policies should live in the existing `__geode_security` graph, not in a separate clean-room store. That is the best fit because `auth_graph_manager` already persists users, roles, graph grants, and HMAC-backed integrity state there, and server startup already knows how to hydrate from it. Reusing that graph avoids state bifurcation and makes policy backup/restore coherent with current auth persistence. citeturn13view3turn17view2

The persisted schema should add `Policy`, `Tenant`, `TenantMembership`, `ApiKey`, `ServiceAccount`, `KeyGrant`, and `PolicyVersion` nodes plus connecting edges such as `MEMBER_OF_ROLE`, `MEMBER_OF_TENANT`, `APPLIES_TO_GRAPH`, `APPLIES_TO_LABEL`, `GRANTS_ACTION`, and `PROTECTS_FIELD`. Store normalized source expressions, an optional compiled blob with `engine_version`, a `source_hash`, and an integrity HMAC. On startup, GPS should hydrate all policies, compile any stale expressions, and bump a process-wide `policy_version`. If hydration fails after the server has detected an existing security graph, external traffic should fail closed except for a tightly scoped local recovery mode. That behavior is stricter than today and should be an explicit compatibility change. citeturn13view3turn17view2turn14view8

## Integration Plan by Module

The unification work should be organized module-by-module rather than by abstract feature set, because the current code already reveals the natural seams.

| Module | Current behavior | Required change | New API | Migration risk | Required tests |
|---|---|---|---|---|---|
| `src/security/user_management.zig` | Builtin roles and `auth_version` are the runtime authority. citeturn13view0 | Keep as legacy user store and builtin-role adapter; stop letting it be the final authorizer. | `gps.resolveLegacyBuiltinRole()` | Medium | Session invalidation, builtin-role compatibility, no-regression auth DDL. |
| `src/security/authn.zig` | Auth chain already derives rich request identity. citeturn13view1 | Make it emit `Principal`; attach `tenant_id`, graph, API key ID, and auth version every time. | `gps.derivePrincipalFromAuth()` | Medium | Principal derivation for password, session, API key, mTLS, MFA. |
| `src/security/auth_graph_manager.zig` | Persists users/roles/graph grants with HMAC sealing. citeturn13view3 | Extend to persist `Policy`, `Tenant`, `TenantMembership`, `ServiceAccount`, `ApiKey`, `PolicyVersion`, key grants. | `persistPolicy`, `persistTenant`, `bumpPolicyVersion` | Medium | Startup hydration, WAL/crash recovery, HMAC integrity, rollback. |
| `src/security/multi_graph_security.zig` | Holds graph-scoped role/grant state, additive style. citeturn14view6 | Recast as one policy source feeding GPS; add deny and tenant-aware scopes. | `enumerateGraphPolicyFacts()` | Low | Grant migration, deny precedence, graph visibility versus graph use. |
| `src/security/rls_core.zig` and `rls_types.zig` | Existing policy VM, globally wired, fail-open defaults. citeturn14view8turn14view10 | Reuse as GPS expression engine; add `PolicyEvalContext`; remove default-allow behavior from GPS caller semantics. | `gps.compilePolicyExpr()`, `gps.evalPolicyExpr()` | High | Parser/evaluator fuzzing, deterministic execution, cache invalidation, fail-closed negatives. |
| `src/execution.zig` | `ExecutionContext` carries fragmented security data; `checkPermission()` is coarse role+grant logic. citeturn17view0 | Add canonical `principal` and `policy_handle`; replace `checkPermission()` with GPS wrapper. | `gps.authorizeStatement()` | High | All statement types, auth-disabled compatibility mode, graph binding checks. |
| `src/execution/match_operations.zig` and `src/execution/query_execution.zig` | Tenant and RLS are manually threaded in read paths. citeturn15view10turn15view2 | Convert to GPS filter obligations; keep pushdown into label/edge scans and graph scans. | `gps.filterNodeRead()`, `gps.filterEdgeRead()` | High | Tenant/RLS regressions, aggregation/traversal leakage, index pushdown correctness. |
| `src/execution/statement_handlers.zig` and `meta_dispatch.zig` | `SHOW TABLES` is tenant-aware, but metadata listings are globally visible. citeturn15view1turn19view0 | Route all metadata through `SHOW_METADATA` decisions and row filters. | `gps.filterMetadataRow()` | High | SHOW/db.* visibility matrix, tenant and graph metadata isolation. |
| `src/execution/procedure_registry.zig` and `procedure_access.zig` | Classifier exists, not enforced. citeturn15view5turn15view6 | Make classification registry-backed and mandatory before dispatch. | `gps.authorizeProcedure()` | Medium | Read-only vs mutating procedures, auth procedures, storage procedures, unknown procedures. |
| `src/execution/auth_dispatch.zig` and `admin_ddl.zig` | Auth DDL exists; “policy” procedures are placeholders. citeturn15view3turn15view4turn16view0turn16view1 | Replace in-memory policy map with real policy catalog and DDL executor. | `policy_dispatch.zig` | Medium | CREATE/ALTER/DROP/SHOW POLICY, SHOW GRANTS, simulation/explain. |
| `src/mcp/server.zig`, `src/mcp/tools.zig`, `src/mcp/lsp.zig` | Boundary bearer auth only; no per-caller principal in DB access path. citeturn16view2turn16view5turn16view3 | Require caller principal mapping and pass it through every tool/resource/LSP action. | `gps.authorizeMcpTool()`, `gps.authorizeLspMetadata()` | High | Cross-user graph visibility, schema completion filtering, diagnostics leakage. |
| `src/execution/fle_hooks.zig` | FLE uses tenant and user-role context, but not central policy. citeturn19view2 | Make decrypt and key unwrap explicit GPS decisions with classification. | `gps.authorizeDecryptField()` | Medium | Field masking, decrypt denial, tenant key isolation, audit obligations. |
| `src/graph_store.zig` | Storage knows graph and tenant, but not principal or policy intent. citeturn17view1 | Add policy-aware access wrappers, not policy logic inside storage internals. | `PolicyBoundStoreView` | Medium | Index-scan pushdown, graph/tenant bypass regression, admin-only cross-tenant views. |

## DDL, Persistence, Testing, and Migration

### DDL and API specification

The parser already uses soft-keyword extensions for auth DDL, so GPS should extend the same style rather than adding a disconnected administration channel. New AST variants should include `CreatePolicyStatement`, `AlterPolicyStatement`, `DropPolicyStatement`, `ShowPoliciesStatement`, `ShowGrantsStatement`, `ExplainPolicyStatement`, tenant membership statements, role membership statements, and policy simulation statements. That is the natural continuation of the existing parser/admin_ddl pattern. citeturn16view0turn16view1turn15view3

A minimal but extensible grammar should look like this (a plan: this is not the
grammar Geode accepts today; see docs/GQL_AUTH_DDL.md for the policy DDL that
is implemented):

```text
CREATE POLICY tenant_isolation
ON GRAPH *
FOR READ, UPDATE, DELETE
TO PUBLIC
USING current_tenant() = resource.tenant_id;

CREATE POLICY employee_read
ON GRAPH hr
FOR MATCH, READ
TO ROLE role_read_hr
USING resource.label = 'Employee'
  AND resource.department_id = principal.attributes.department_id;

CREATE POLICY pii_masking
ON GRAPH customer
FOR READ
TO ROLE analyst
ON PROPERTY ssn
WHEN classification(resource.property) >= 'restricted'
THEN MASK last4;

CREATE POLICY write_own_tenant
ON GRAPH *
FOR CREATE, UPDATE, DELETE
TO PUBLIC
WITH CHECK new.tenant_id = current_tenant();

ALTER POLICY employee_read SET ENABLED false;
DROP POLICY employee_read;

SHOW POLICIES;
SHOW GRANTS FOR alice;
EXPLAIN POLICY FOR MATCH (n:Customer) RETURN n;
```

These statements should compile to catalog objects in `__geode_security`, not to the current in-memory `g_policies` map. Existing `GRANT` and `REVOKE` syntax should remain, but under GPS they should create or remove durable grant policy objects rather than mutating a side map that execution only partially consults. citeturn15view4turn16view0turn15view3

### Policy persistence design

The persisted schema should reuse existing security graph practices. A workable object model is:

| Object | Purpose |
|---|---|
| `(:User)` | Existing persisted users. |
| `(:Role)` | Existing persisted roles. |
| `(:Tenant)` | Tenant catalog, attributes, status. |
| `(:Policy)` | Canonical rule object with scope, effect, action set, normalized expression source, optional compiled blob metadata, enabled flag, classification flags, masking mode, timestamps, HMAC. |
| `(:PolicyVersion)` | Global monotonic policy epoch and integrity checkpoint. |
| `(:ApiKey)` | Real API key subjects and scopes, replacing current placeholder admin procedures. |
| `(:ServiceAccount)` | Internal principals for cluster workers, MCP backends, maintenance jobs. |
| `(:KeyGrant)` | FLE/TDE key-usage and decrypt grants. |
| `(:GraphGrant)` | Legacy grant compatibility object, migratable into policy rows. |

Edges should encode memberships and applicability: `MEMBER_OF_ROLE`, `MEMBER_OF_TENANT`, `APPLIES_TO_GRAPH`, `APPLIES_TO_LABEL`, `PROTECTS_PROPERTY`, `OWNS_KEY`, `GRANTED_ACTION`, and `HAS_POLICY`. Persist normalized expression source plus `source_hash`, `engine_version`, `compiled_blob` optional, and an HMAC included in the existing security-graph chain model. On any mutation, increment `PolicyVersion` and also invalidate any active principal cache entries keyed by the affected `auth_version` or tenant membership. citeturn13view3turn14view8turn17view2

### Testing and CANARY plan

The new policy system should not ship without a dedicated, named test for every new enforcement surface. The current repository already uses CANARY markers heavily; GPS should follow that discipline by introducing a distinct namespace such as `REQ-GPS-*`.

A minimum required matrix is:

| Area | Required tests | Example CANARY |
|---|---|---|
| Parser and AST | `tests/test_policy_ddl_parser.zig`, fuzzed malformed policy expressions | `REQ-GPS-DDL-001` |
| Principal derivation | password, session, API key, mTLS, MCP, internal principal cases | `REQ-GPS-PRINCIPAL-001` |
| Decision engine | allow, deny, filter, mask, MFA, elevation, obligations, explain | `REQ-GPS-PDP-001` |
| Tenant isolation | read, write, metadata, procedures, SHOW, db.* | `REQ-GPS-TENANT-001` |
| Graph grants | additive, deny, graph bind, graph switch, visibility vs use | `REQ-GPS-GRAPH-001` |
| RLS integration | row reads, writes, aggregation, index pushdown, no-policy fail-closed | `REQ-GPS-RLS-001` |
| Procedure access | every domain prefix, read-only versus mutating, unknown procedure | `REQ-GPS-PROC-001` |
| MCP/LSP | per-caller principal propagation, schema completion filtering, diagnostics filtering | `REQ-GPS-MCP-001` |
| FLE/TDE | decrypt denial, mask, per-tenant key access, audit obligations | `REQ-GPS-FLE-001` |
| Audit | central decision audit rows, deny events, break-glass events | `REQ-GPS-AUDIT-001` |
| Cache | policy version invalidation, auth version invalidation, tenant membership invalidation | `REQ-GPS-CACHE-001` |
| Restart and migration | hydration, crash recovery, WAL replay, backup/restore | `REQ-GPS-PERSIST-001` |
| Distributed execution | coordinator to worker principal envelope, shard-local enforcement | `REQ-GPS-DIST-001` |

Performance targets should be explicit. A cached coarse authorization decision should target sub-5 microseconds. An uncached non-row decision based on grants and attributes should target under 100 microseconds. A simple compiled row predicate should target roughly 1 microsecond per row after warmup. Tenant and graph filters must remain pushed down into index scans and graph scans; GPS should not regress to per-row permission checks when a scan-level filter can be proven equivalent. If the decision cache or compiled-expression cache becomes unavailable, the behavior must degrade to correct-but-slower, not to allow-all. citeturn14view8turn15view10turn17view1

### Migration and rollback

The migration path should preserve safe existing behavior and make unsafe defaults explicit. Start by hydrating current users, roles, graph grants, and any live RLS policies into the new catalog. Keep old auth DDL syntax, but dual-write to both legacy structures and GPS catalog objects for one release cycle. In compatibility mode, `execution.checkPermission()` should call GPS first and compare with legacy behavior in audit-only mode. Strict mode should then become the default for server transports, while any “auth disabled means allow all” development behavior must move behind an explicit insecure flag. citeturn17view0turn13view3turn15view4

Rollback should remain possible by versioning policy state in `__geode_security`. Every policy mutation should create a new monotonic policy epoch and a restorable object history. Because the security graph already uses HMAC resealing, GPS can reuse the same integrity boundary for rollback safety. Backups must include policy objects, tenant memberships, key grants, and API key subjects. citeturn13view3turn17view2

## Implementation Roadmap and Appendices

### Implementation roadmap

**Phase 0** should close evidence and invariants. Freeze the authoritative meaning of builtin roles, custom roles, graph grants, tenant IDs, graph IDs, and `auth_version`. Document every current fail-open behavior and decide which ones remain in explicit compatibility mode only.

**Phase 1** should add canonical principal propagation. Every transport and execution entry point should be able to carry a `Principal`, even if some fields are null during the migration period.

**Phase 2** should add the central decision API and wrap the current coarse checks. `execution.checkPermission()` becomes a GPS adapter. Nothing else should perform final authorization on its own.

**Phase 3** should make tenant and graph enforcement non-bypassable. That includes `USE GRAPH`, metadata, graph visibility, graph switch, and all storage-backed read/write paths.

**Phase 4** should persist policies and add real policy DDL. This removes the current in-memory `g_policies` placeholder and makes RLS durable.

**Phase 5** should harden procedures, metadata, MCP, and LSP. This is where many hidden leaks actually are.

**Phase 6** should propagate principals and policy epochs through distributed and shard execution envelopes.

**Phase 7** should harden performance, caches, and audit. That includes cache invalidation, explain tooling, failure-mode drills, and operational dashboards. This phase ordering follows the current repository’s real fault lines: fragmented identity first, central decision second, metadata and remote surfaces third. citeturn17view0turn15view10turn19view0turn16view2turn16view5turn13view3

### Open questions

Only a few questions are genuine blockers:

- Which current module becomes the interim source of truth for user and role facts during migration: `user_management`, `geode_auth_lib`, or the hydrated `__geode_security` graph?
- Is the development-mode “auth disabled means allow all” behavior acceptable to preserve anywhere outside explicitly insecure local testing?
- Should compiled policy bytecode be persisted, or should GPS persist only normalized source and recompile on startup to avoid engine-version drift?
- What exact metadata surfaces should remain visible to admins, tenant admins, graph admins, and MCP/LSP callers by default?

### Sample Zig interfaces

```zig
pub const Action = enum {
    read,
    match_,
    traverse,
    create,
    update,
    delete,
    merge,
    set_property,
    remove_property,
    create_schema,
    alter_schema,
    drop_schema,
    execute_procedure,
    admin_user,
    admin_role,
    admin_policy,
    admin_tenant,
    bind_graph,
    show_metadata,
    backup,
    restore,
    export_,
    import_,
    decrypt_field,
    unwrap_key,
};

pub const ResourceRef = union(enum) {
    database: void,
    graph: []const u8,
    tenant: []const u8,
    node: struct { graph: []const u8, id: u64, labels: []const []const u8, tenant: ?[]const u8 },
    edge: struct { graph: []const u8, id: u64, typ: []const u8, tenant: ?[]const u8 },
    property: struct { graph: []const u8, owner_id: u64, key: []const u8 },
    procedure: []const u8,
    metadata: struct { kind: []const u8, graph: ?[]const u8, tenant: ?[]const u8 },
    key: []const u8,
};

pub const DecisionRequest = struct {
    principal: *const Principal,
    action: Action,
    resource: ResourceRef,
    object_ctx: ?*const std.StringHashMap(Value) = null,
};

pub fn decide(
    allocator: std.mem.Allocator,
    req: *const DecisionRequest,
) !PolicyDecision;
```

### Threat model

| Threat | Current exposure | GPS control |
|---|---|---|
| Cross-tenant metadata reconnaissance | Unfiltered `db.*` and some `SHOW` paths | `SHOW_METADATA` policy with row filtering |
| Cross-graph privilege widening | Additive bound-graph fallback only | Scoped allow/deny with `BIND_GRAPH` check |
| API key drift | Enforcement and admin paths differ | One API key subject store and one scope evaluator |
| Procedure abuse | Classifier exists but not enforced | Mandatory `EXECUTE_PROCEDURE` decision |
| RLS bypass through defaults | No policy and some VM paths allow by default | Fail-closed policy evaluation |
| MCP/LSP identity confusion | Process-wide bearer gate only | Per-caller principal propagation and metadata filters |
| Decrypt/key misuse | Hook-local role checks | Explicit `DECRYPT_FIELD` and `UNWRAP_KEY` actions |
| Cache stale authorization | No unified policy epoch | `auth_version` + `policy_version` keyed invalidation |

### Decision matrix

| Existing concept | Keep | Replace | GPS role |
|---|---|---|---|
| `user_management.Role` builtin mapping | Yes | No | Legacy compatibility grant source |
| `authn.AuthRequest/AuthResult` | Yes | No | Request-bound principal derivation |
| `geode_auth_lib` MFA/session/ABAC ideas | Partly | Partly | Concept source and migration input |
| `auth_graph_manager` persistence and HMAC chain | Yes | No | Policy catalog storage backbone |
| `multi_graph_security` explicit graph grants | Partly | Partly | Grant fact source, then subsumed |
| `rls_core` compiler/VM | Yes | No | Policy expression engine |
| Ad hoc `checkPermission()` logic | No | Yes | Replaced by GPS adapter |
| `g_policies` in-memory map | No | Yes | Replaced by durable policy catalog |
| MCP bearer-only boundary auth | Partly | Partly | Transport auth only, not final principal |
| FLE hook-local decisions | Partly | Partly | Enforcement point under GPS authority |

The bottom line is straightforward: Geode has enough real security code to justify an incremental unification, but not enough centralization to call the current system coherent. GPS should be implemented as a first-class policy spine over the existing auth graph, RLS VM, graph/tenant storage model, and execution context—not as another side subsystem. That is the fastest path to one authority model, fail-closed defaults, auditable decisions, and deployable incremental change. citeturn13view0turn13view1turn14view1turn13view3turn14view8turn17view0turn15view10turn19view0turn16view2turn16view5
