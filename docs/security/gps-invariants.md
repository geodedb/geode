# GPS Phase 0 — Authoritative Current-State Invariants

> Source of truth for the meaning of authority-bearing fields in `main` as of
> 2026-05-20. GPS (the Geode Policy System) Phase 2+ MUST NOT silently change
> any meaning documented here. Any deviation requires updating this file in the
> same commit.

## 1. Builtin roles (`src/security/user_management.zig`)

The runtime authorizer (`checkPermission` in `src/execution.zig:827`) trusts
exactly four builtin roles: `Admin`, `User`, `ReadWrite`, `ReadOnly`. These map
through `Permission.fromRole()` to `Read`, `Write`, `Schema`. Custom roles
defined elsewhere (`geode_auth_lib.zig`, `auth_graph_manager.zig`) are NOT
consulted by the current runtime authorizer — they are persisted but inert at
the execution boundary.

## 2. `User.auth_version` (`src/security/user_management.zig:110`)

Monotonically incremented when any of `role`, `active`, or password changes via
`assignRole`, `setUserActive`, or password reset. A session is "current" iff its
captured `auth_version` equals the live persistent version
(`isSessionAuthCurrent` at `src/security/user_management.zig:819`). GPS reuses
this version as the cache-invalidation key for any principal-keyed decision
cache.

## 3. `ExecutionContext.tenant_id` (`src/execution.zig:484`)

Carries the active session's tenant identifier as resolved from the DSN or the
session config. It is the only authoritative tenant field consumed by the
storage layer's tenant-aware paths (`getAllNodesForTenant`,
`getNodesByLabels(..., tenant)`, `getEdgesByType(..., tenant, graph)`). It is
NOT carried on the `User` record or on `authn.AuthResult`; tenant membership
is connection-bound, not user-bound, today.

## 4. `ExecutionContext.session_state.graph` (the "bound graph")

The graph the current connection is bound to via DSN or `USE GRAPH`. The
`graph_bound` flag at `src/execution.zig:466` indicates DSN-binding (in which
case `USE GRAPH` is rejected). The graph-grant widening fallback in
`checkPermission` consults this field only — if `session_state` is null, the
fallback is unreachable.

## 5. Graph grants (`src/security/multi_graph_security.zig:109`)

Grants are stored keyed by `(user_id, graph_hash, action)` where `action` is
`0=read, 1=write, 2=schema`. They are persisted to `__geode_security` and
hydrated at startup. They are consumed by execution exclusively as an **additive
widening** of the user's builtin-role permission on the currently bound graph.
There is no deny grant. There is no tenant binding on a grant. There is no
`BIND_GRAPH` action.

## 6. Authentication chain (`src/security/authn.zig`)

`AuthProvider.authenticate(AuthRequest) -> AuthResult` is the canonical
authentication chain (mTLS → API key → session). The chain returns rich
identity (user_id, roles, scopes, elevation_level, session_token,
requires_mfa) but does NOT return `tenant_id` or `active_graph` — those are
attached downstream from session config.

## 7. RLS engine (`src/security/rls_core.zig`)

`checkRowAccessByUsername` is the runtime row predicate. It is wired into
match execution at `src/execution/match_operations.zig:130` and the global
engine is published at startup via `setGlobalExprRLSEngine` in
`src/server/main.zig:1063-1064`. Compiled bytecode policies enforce
property-based row-level filtering. The GQL→bytecode pipeline for policy
compilation is still manual (no parser-backed `CREATE POLICY` DDL).

## 8. Procedure classifier (`src/execution/procedure_access.zig`)

A read-only vs mutating classification table exists at
`src/execution/procedure_access.zig:1-164`. **It is not consulted by the
registry dispatch path** (`src/execution/procedure_registry.zig:94-165`).
This is captured in `docs/security/gps-fail-open-sites.md` as one of the
items GPS Phase 5 will close.

## 9. Compatibility mode: "auth disabled means allow all"

`decide()` has no implicit allow branch (GPS Phase 2), and
`checkPermission` is gone (SONNY-2781). Authentication disabled is the
in-process, single-user mode (embedders and tests; `geode serve` always
enables authentication). In it the QUIC and gRPC handlers authorize, and
give the executor, no principal, so no gate refuses a request and GPS
policies, grants and roles are not consulted, on both transports alike
(SONNY-2782). See `docs/security/gps-decide.md`, "Authentication
disabled".

## 10. What this document does NOT promise

It does not promise that the current set is sufficient for production
multi-tenant deployment — CLAUDE.md still lists multi-tenant as requiring
operator review of GAP-0514. It only promises that the fields and behaviors
above are the *current* authoritative meaning. GPS later phases either
preserve these meanings or replace them with explicitly documented stronger
ones.
