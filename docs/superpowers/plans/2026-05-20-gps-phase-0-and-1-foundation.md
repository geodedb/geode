# GPS Phase 0 + Phase 1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the non-behavior-changing foundation for the Geode Policy System (GPS) — (Phase 0) freeze and document the meaning of every current authoritative auth field and every fail-open behavior, and (Phase 1) introduce a canonical `Principal` type that is constructed once at every request boundary and threaded through `ExecutionContext`. No authorization semantics change in this plan. The decision API (`gps.decide()`) and policy DDL come in later phases.

**Architecture:** Phase 0 produces three docs (`docs/security/gps-invariants.md`, `docs/security/gps-fail-open-sites.md`, and footers on `docs/TODO.md` and `docs/FULL_AUDIT_2026_04_06.md`) plus a sweep of explicit `CANARY: ... ASPECT=FailOpenInterim` markers at every documented fail-open site. Phase 1 introduces a new `src/security/principal.zig` defining the `Principal`, `MfaState`, `RiskContext`, `AttributeMap`, and `PrincipalSource` types; a `Principal.fromAuthState()` builder; an optional `principal: ?*const Principal = null` field on `ExecutionContext`; and Principal construction at the three production `ExecutionContext` build sites (QUIC handler, gRPC server, distributed coordinator). Existing tests stay green because the field defaults to `null`. The MCP and REPL paths funnel through QUIC and require no additional construction in this plan.

**Tech Stack:** Zig 0.16.0+ (existing project toolchain), `make build`, `make test`, `make pre-commit`, geodetestlab black-box harness in `../geode-test-harness/`. CANARY governance tokens follow the existing repo convention (`REQ=REQ-GPS-*`).

**Reference design:** `docs/geode-policy-plan.md` — Phase 0 corresponds to "Phase 0 should close evidence and invariants"; Phase 1 corresponds to "Phase 1 should add canonical principal propagation."

---

## File Structure

**Create (Phase 0):**
- `docs/security/gps-invariants.md` — Authoritative current-state document. Pins meaning of `Role`, `Permission`, `User.auth_version`, `tenant_id`, `graph_name`, graph grants, and session elevation as they exist today. This is the source of truth Phase 2+ must not silently break.
- `docs/security/gps-fail-open-sites.md` — Catalog of every fail-open behavior in the current code, each with `file:line`, the behavior, the documented reason, and the eventual GPS replacement.

**Create (Phase 1):**
- `src/security/principal.zig` — Defines `Principal`, `MfaState`, `RiskContext`, `AttributeMap`, `PrincipalSource`, and the `Principal.fromAuthState()` builder. Pure data + a small constructor; no authorization logic.
- `tests/test_gps_principal.zig` — Unit tests for `Principal` construction, builder, and legacy-field equivalence.
- `tests/test_gps_principal_propagation.zig` — Integration test: construct a `Principal` at the QUIC handler boundary, run a query, and assert the same `Principal` pointer reaches the deepest execution callback.

**Modify (Phase 0):**
- `docs/TODO.md` — Add a "GPS Phase 0 reconciliation" footer that links to the invariants doc and corrects stale "tenant isolation not implemented" claims.
- `docs/FULL_AUDIT_2026_04_06.md` — Add a 2026-05 GPS-Phase-0 closure footer that links to the new docs.
- `src/execution.zig:827` (the `checkPermission` body) — Add an explicit `CANARY: REQ=REQ-GPS-INVARIANT-001; ASPECT=FailOpenInterim` marker on the auth-disabled and graph-grant-widening branches.
- `src/security/rls_core.zig` — Add an explicit `CANARY: REQ=REQ-GPS-INVARIANT-001; ASPECT=FailOpenInterim` marker on `checkRowAccessByUsername`'s no-policy default-allow branch and on the VM no-result default-allow branch.
- `src/execution/procedure_registry.zig` — Add an explicit `CANARY: REQ=REQ-GPS-INVARIANT-001; ASPECT=ClassifierUnused` marker on the dispatch path that does not consult `procedure_access.zig`.

**Modify (Phase 1):**
- `src/execution.zig` — Add `principal: ?*const Principal = null` field to `ExecutionContext` (next to `tenant_id` at line 484). Import the principal module. No semantics change.
- `src/server/quic_connection_handler.zig:3242` — Build a `Principal` once per request (after authentication is resolved) and assign it to `exec_context.principal`.
- `src/transport/grpc_server.zig:1959` — Same change as QUIC handler.
- `src/distributed/query_coordinator.zig:357` — Construct a Principal for the synthetic internal-service principal that the coordinator uses.

**Out of scope for this plan (deferred to later GPS phases):**
- The `gps.decide()` API and its replacement of `checkPermission()`.
- Policy DDL (`CREATE POLICY` etc.) and policy persistence in `__geode_security`.
- MCP/LSP per-caller principal threading beyond what already arrives through QUIC.
- Metadata-procedure tenant filtering.
- Distributed envelope policy version propagation.

---

## Phase 0: Evidence and Invariants

### Task 0-1: Write the GPS invariants document

**Files:**
- Create: `docs/security/gps-invariants.md`

- [ ] **Step 1: Write the invariants document**

Create `docs/security/gps-invariants.md` with the following content (verbatim):

```markdown
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

## 2. `User.auth_version` (`src/security/user_management.zig:101`)

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
match execution at `src/execution/match_operations.zig:125` and the global
engine is published at startup via `setGlobalExprRLSEngine` in
`src/server/main.zig:1048-1064`. Compiled bytecode policies enforce
property-based row-level filtering. The GQL→bytecode pipeline for policy
compilation is still manual (no parser-backed `CREATE POLICY` DDL).

## 8. Procedure classifier (`src/execution/procedure_access.zig`)

A read-only vs mutating classification table exists at
`src/execution/procedure_access.zig:1-116`. **It is not consulted by the
registry dispatch path** (`src/execution/procedure_registry.zig:94-166`).
This is captured in `docs/security/gps-fail-open-sites.md` as one of the
items GPS Phase 5 will close.

## 9. Compatibility mode: "auth disabled means allow all"

`checkPermission` returns early at `src/execution.zig:831` when
`user_mgmt.isAuthEnabled()` is false. This is the documented development
default. Production deployments enable auth (CLAUDE.md: "Authentication is
enabled by default (fail-closed)"). GPS Phase 2 will move the "allow all"
behavior behind an explicit `--insecure-allow-all` flag and remove the
implicit branch from `decide()`.

## 10. What this document does NOT promise

It does not promise that the current set is sufficient for production
multi-tenant deployment — CLAUDE.md still lists multi-tenant as requiring
operator review of GAP-0514. It only promises that the fields and behaviors
above are the *current* authoritative meaning. GPS later phases either
preserve these meanings or replace them with explicitly documented stronger
ones.
```

- [ ] **Step 2: Verify the document references match the current code**

Run: `grep -n "src/execution.zig:827\|src/execution.zig:484\|src/execution.zig:466\|src/security/user_management.zig:101\|src/security/user_management.zig:819\|src/security/multi_graph_security.zig:109\|src/execution/match_operations.zig:125\|src/server/main.zig:1048\|src/execution/procedure_access.zig:1\|src/execution/procedure_registry.zig:94" docs/security/gps-invariants.md`

Expected: All 10 line citations matched. If any line citation is off by more than 3 lines from the actual current source, edit the doc to use the correct line. (Run `grep -n` against each file to confirm before editing the doc.)

- [ ] **Step 3: Commit**

```bash
git add docs/security/gps-invariants.md
git commit -m "docs(gps): freeze Phase 0 invariants for auth, tenant, and grants"
```

---

### Task 0-2: Write the fail-open sites catalog

**Files:**
- Create: `docs/security/gps-fail-open-sites.md`

- [ ] **Step 1: Verify each fail-open site exists at the documented location**

Run these greps and confirm each returns at least one match:

```bash
grep -n "isAuthEnabled" src/execution.zig
grep -n "graph_grant_check_fn" src/execution.zig
grep -n "checkRowAccessByUsername" src/security/rls_core.zig
grep -n "fn executeCallProcedure" src/execution/procedure_registry.zig
grep -n "db.labels\|db.relationshipTypes\|db.propertyKeys" src/execution/meta_dispatch.zig
```

Expected: Each grep produces ≥1 line. Note the exact line numbers you find for use in the next step.

- [ ] **Step 2: Write the fail-open sites document**

Create `docs/security/gps-fail-open-sites.md` with the following content, **replacing every `<LINE>` placeholder with the actual line number from Step 1**:

```markdown
# GPS Phase 0 — Fail-Open Sites Catalog

> Every place in `main` (as of 2026-05-20) where the current code returns an
> "allow" decision in the absence of explicit policy evidence. GPS Phase 2+
> will replace these with `decide()` calls that fail closed at the policy
> layer; until then, this list IS the documented set of compatibility-mode
> exceptions. Do not add new entries without updating this file.

| # | Site | File:Line | Current behavior | Documented reason | Eventual GPS replacement |
|---|------|-----------|------------------|-------------------|--------------------------|
| 1 | Auth-disabled early return | `src/execution.zig:<LINE_1>` | Returns `void` (allow) when `user_mgmt.isAuthEnabled()` is false. | Developer-mode default; CLAUDE.md says production enables auth (fail-closed). | Phase 2: move behind explicit `--insecure-allow-all` flag; `decide()` never has an implicit allow path. |
| 2 | Graph-grant additive widening | `src/execution.zig:<LINE_2>` | When the builtin role check fails, an additive grant on the currently bound graph *widens* access. No deny semantics. | Compatibility for the original per-graph `GRANT … ON GRAPH …` model. | Phase 4: grants become first-class `Policy` rows with explicit allow/deny scopes. |
| 3 | RLS no-policy default-allow | `src/security/rls_core.zig` `checkRowAccessByUsername` (line ~<LINE_3>) | When the policy set for a label is empty, the row is returned. | Backwards compatibility with pre-RLS data. | Phase 4: the policy layer is fail-closed; the row engine still returns rows when no `Policy` applies, but the policy catalog itself owns "allow by absence" only when explicitly configured. |
| 4 | RLS VM no-result default-allow | `src/security/rls_core.zig` (VM evaluation around line 1363 per `geode-policy-plan.md`) | When the expression VM produces no Boolean result, the row is returned. | Defensive default during VM development. | Phase 2: VM returns `error.IndeterminatePolicy`; `decide()` maps that to `deny` with a distinct reason code. |
| 5 | Procedure registry skips classifier | `src/execution/procedure_registry.zig:<LINE_4>` | Dispatch executes any registered procedure without consulting `procedure_access.zig`. | The classifier was added later and the wiring was deferred. | Phase 5: mandatory `EXECUTE_PROCEDURE` decision before dispatch. |
| 6 | Metadata procedures enumerate globally | `src/execution/meta_dispatch.zig` for `db.labels`/`db.relationshipTypes`/`db.propertyKeys` (line ~<LINE_5>) | Returns the union of all labels/types/keys across tenants and graphs. | Pre-multi-tenant API surface. | Phase 5: routed through `SHOW_METADATA` decision with per-row filtering. |
| 7 | `SHOW GRAPHS` is global | `src/execution/statement_handlers.zig` (the `SHOW GRAPHS` case) | Lists every graph the server knows about. | Same as #6. | Phase 5: filter by what the principal can `BIND_GRAPH`. |
| 8 | MCP boundary bearer-only | `src/mcp/server.zig` token check (server-wide) | A single bearer token authenticates the whole server; tool calls then use a generic client path with no per-caller principal. | MCP started as a single-tenant developer aid. | Phase 5: per-caller Principal threaded through MCP tools; LSP metadata filtered. |
| 9 | FLE decryption gated by hook-local role check | `src/execution/fle_hooks.zig` decrypt path | Decryption authorized by current thread tenant + current user role; on failure returns `[REDACTED]`. | Original FLE design pre-dates GPS. | Phase 5: `DECRYPT_FIELD` and `UNWRAP_KEY` are explicit GPS actions. |

## Invariant: no new entries without docs

Any PR that introduces a new "absence implies allow" behavior must add a row
here, with a reviewer-named GPS phase that will close it. The CI hook
`scripts/check_fail_open_sites.sh` (Phase 0 Task 0-3) will fail the build if
this table shrinks without a matching `CANARY: REQ=REQ-GPS-INVARIANT-001`
removal in the source.
```

- [ ] **Step 3: Commit**

```bash
git add docs/security/gps-fail-open-sites.md
git commit -m "docs(gps): catalog all current fail-open sites with line citations"
```

---

### Task 0-3: Mark every fail-open site with a CANARY token in source

**Files:**
- Modify: `src/execution.zig` (two CANARY markers)
- Modify: `src/security/rls_core.zig` (two CANARY markers)
- Modify: `src/execution/procedure_registry.zig` (one CANARY marker)

- [ ] **Step 1: Add the auth-disabled-allow CANARY**

Find the line in `src/execution.zig` matching `if (!user_mgmt.isAuthEnabled()) {` (currently line 831 per Phase 0 evidence) and insert this comment immediately above the `if` line:

```zig
    // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FailOpenInterim; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
    // Phase 0: developer-mode "auth disabled means allow all". GPS Phase 2 replaces
    // this with an explicit --insecure-allow-all flag and removes the implicit branch.
```

- [ ] **Step 2: Add the graph-grant-widening CANARY**

Find the `if (graph_grant_check_fn) |f|` block in `src/execution.zig` (currently line 845). Replace the existing CANARY comment immediately above that block (the `REQ=REQ-AUTH-GRANT-PERSIST-003` one) by **adding a second CANARY line** directly under it (do not replace the existing one):

```zig
        // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FailOpenInterim; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
        // Phase 0: additive (widening-only) grant fallback. GPS Phase 4 promotes grants
        // to first-class Policy rows with explicit allow/deny scopes.
```

- [ ] **Step 3: Add the RLS no-policy-allow CANARY**

In `src/security/rls_core.zig`, locate `fn checkRowAccessByUsername` (currently around line 1065). Immediately above the `return true` or `return .{ .allow = true, ... }` branch that fires when no policies match the label, add:

```zig
    // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FailOpenInterim; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
    // Phase 0: no-policy default-allow for pre-RLS data. GPS Phase 4 makes "allow by
    // absence" an explicit policy choice in the catalog.
```

- [ ] **Step 4: Add the RLS VM no-result CANARY**

In `src/security/rls_core.zig`, locate the VM evaluation site that returns `allow` when the expression produces no Boolean (around line 1363 per the design doc). Immediately above that return, add:

```zig
    // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FailOpenInterim; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
    // Phase 0: VM no-result default-allow. GPS Phase 2 will surface this as
    // error.IndeterminatePolicy and map it to a deny decision.
```

If the exact line shape differs from `geode-policy-plan.md`, locate the VM evaluation function (look for `evalExpression` or similar) and add the comment immediately above its no-result return path.

- [ ] **Step 5: Add the procedure-registry-no-classifier CANARY**

In `src/execution/procedure_registry.zig`, locate `fn executeCallProcedure` (or its current name) at the dispatch site (around line 94-166 per the design doc). Immediately above the dispatch switch/dispatch table, add:

```zig
    // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=ClassifierUnused; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
    // Phase 0: procedure dispatch does NOT consult procedure_access.zig. GPS Phase 5
    // makes EXECUTE_PROCEDURE a mandatory decision before dispatch.
```

- [ ] **Step 6: Verify all five CANARY markers landed**

Run: `grep -rn "REQ-GPS-INVARIANT-001" src/`

Expected: exactly 5 lines, two in `src/execution.zig`, two in `src/security/rls_core.zig`, one in `src/execution/procedure_registry.zig`.

- [ ] **Step 7: Confirm build still passes**

Run: `make build`

Expected: build succeeds. No new errors. Comments do not change behavior.

- [ ] **Step 8: Commit**

```bash
git add src/execution.zig src/security/rls_core.zig src/execution/procedure_registry.zig
git commit -m "docs(gps): tag every fail-open site with REQ-GPS-INVARIANT-001 CANARY"
```

---

### Task 0-4: Reconcile stale documentation

**Files:**
- Modify: `docs/TODO.md` (append footer; do NOT delete existing content)
- Modify: `docs/FULL_AUDIT_2026_04_06.md` (append footer)

- [ ] **Step 1: Read the current TODO.md tail**

Run: `tail -n 20 docs/TODO.md`

Expected: see the bottom of the file to understand the current footer style. Do not modify yet.

- [ ] **Step 2: Append the GPS Phase 0 footer to TODO.md**

Append the following block to the end of `docs/TODO.md` (use the Edit tool with a context match against the current last line, or Write the full file with the appended block):

```markdown

---

## 2026-05-20 — GPS Phase 0 Reconciliation Footer

GPS (Geode Policy System) Phase 0 has reconciled the meaning of all
authority-bearing fields against the current `main` branch. See:

- `docs/security/gps-invariants.md` — pinned current meaning of `Role`,
  `Permission`, `auth_version`, `tenant_id`, `graph_name`, graph grants.
- `docs/security/gps-fail-open-sites.md` — the 9 documented fail-open sites,
  each tagged in source with `CANARY: REQ=REQ-GPS-INVARIANT-001`.
- `docs/geode-policy-plan.md` — the full GPS design plan; this TODO is no
  longer the source of truth for the meaning of authority fields.

Prior entries in this file that describe "tenant isolation not implemented"
or "RLS engine not wired" reflect pre-2026-04-11 state. The GAP-0509 (tenant
isolation) and GAP-0511 (RLS expression wiring) closures are recorded in
CLAUDE.md and `docs/GAP_ANALYSIS_RESOLVED.md`. GPS Phase 2+ replaces the
remaining fail-open sites listed in `docs/security/gps-fail-open-sites.md`.
```

- [ ] **Step 3: Append the same-style footer to FULL_AUDIT_2026_04_06.md**

Run: `tail -n 5 docs/FULL_AUDIT_2026_04_06.md`

Append the following block to the end of `docs/FULL_AUDIT_2026_04_06.md`:

```markdown

---

## 2026-05-20 — GPS Phase 0 Closure Footer

The audit findings in this file have been re-evaluated against the current
`main` branch. Outcomes:

- **Tenant isolation:** closed by GAP-0509 (2026-04-11). See
  `tests/test_gap0509_tenant_isolation.zig`.
- **RLS expression engine wiring:** closed by GAP-0511 (2026-04-11). See
  `tests/test_rls_expr_engine_wiring.zig` and
  `setGlobalExprRLSEngine` in `src/server/main.zig`.
- **Distributed module gaps:** closed by GAP-0513 (2026-04-10), commit
  `68ff42c4`.
- **Auth DDL persistence:** closed by `docs/GQL_AUTH_DDL.md` (2026-05-11/12).

Remaining audit items that this footer does NOT close are captured in
`docs/security/gps-fail-open-sites.md` and addressed by GPS Phase 2+.
```

- [ ] **Step 4: Commit**

```bash
git add docs/TODO.md docs/FULL_AUDIT_2026_04_06.md
git commit -m "docs(gps): reconcile TODO and FULL_AUDIT footers against current main"
```

---

## Phase 1: Canonical Principal Propagation

### Task 1-1: Define the `Principal` type and supporting types

**Files:**
- Create: `src/security/principal.zig`
- Test: `tests/test_gps_principal.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/test_gps_principal.zig` with:

```zig
const std = @import("std");
const geode = @import("geode");
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-PRINCIPAL-001; FEATURE="GPS Canonical Principal"; ASPECT=ConstructionDefaults; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "Principal.empty produces a fully-null, zero-role principal" {
    const p = principal_mod.Principal.empty();
    try std.testing.expect(p.user_id == null);
    try std.testing.expect(p.username == null);
    try std.testing.expect(p.session_id == null);
    try std.testing.expect(p.tenant_id == null);
    try std.testing.expect(p.active_graph == null);
    try std.testing.expectEqual(@as(usize, 0), p.roles.len);
    try std.testing.expectEqual(@as(usize, 0), p.custom_roles.len);
    try std.testing.expectEqual(principal_mod.AuthMethod.anonymous, p.auth_method);
    try std.testing.expectEqual(@as(u64, 0), p.auth_version);
    try std.testing.expectEqual(principal_mod.MfaState.none, p.mfa_state);
    try std.testing.expect(p.elevation_until == null);
    try std.testing.expect(p.api_key_id == null);
    try std.testing.expect(p.certificate_subject == null);
    try std.testing.expectEqual(principal_mod.PrincipalSource.unattributed, p.source);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-001; FEATURE="GPS Canonical Principal"; ASPECT=LegacyRoleMapping; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "Principal carries legacy builtin role names without mutation" {
    const roles = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 42,
        .username = "alice",
        .session_id = null,
        .tenant_id = "tenant-a",
        .active_graph = "hr",
        .roles = &roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 7,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .quic_handler,
    };
    try std.testing.expectEqualStrings("alice", p.username.?);
    try std.testing.expectEqualStrings("Admin", p.roles[0]);
    try std.testing.expectEqualStrings("tenant-a", p.tenant_id.?);
    try std.testing.expectEqual(@as(u64, 7), p.auth_version);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter="Principal"`

Expected: FAIL with "no module named 'principal'" or similar — the module does not exist yet.

- [ ] **Step 3: Create the principal module**

Create `src/security/principal.zig`:

```zig
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
```

- [ ] **Step 4: Wire the module into the geode package**

The `security` namespace is assembled inside `src/lib.zig` at lines 437-443 as a `pub const security = struct { ... };` block. Add two new lines inside that struct:

```zig
    pub const principal = @import("security/principal.zig");
    pub const authn = @import("security/authn.zig");
```

(The `authn` export is needed because Task 1-2's test references `geode.security.authn.AuthResult`. `authn.zig` is not currently re-exported under any namespace.)

Then inspect `build.zig` (run `grep -n 'addTest\\|addModule\\|test_step' build.zig | head -30`) to confirm `tests/` files are picked up by the test build. Most geode tests are auto-discovered by glob; if the new `tests/test_gps_principal.zig` is not picked up, add it to the test source list following the existing pattern.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test -Dtest-filter="Principal"`

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/security/principal.zig tests/test_gps_principal.zig src/lib.zig build.zig
git commit -m "feat(gps): add canonical Principal type with empty() constructor"
```

---

### Task 1-2: Implement `Principal.fromAuthState()` builder

**Files:**
- Modify: `src/security/principal.zig` (add builder fn)
- Modify: `tests/test_gps_principal.zig` (add builder tests)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_gps_principal.zig`:

```zig
// CANARY: REQ=REQ-GPS-PRINCIPAL-002; FEATURE="GPS Canonical Principal"; ASPECT=FromAuthStateBuilder; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "fromAuthState assembles principal from AuthResult + tenant/graph/session" {
    const authn = geode.security.authn;
    const ar = authn.AuthResult{
        .user_id = 100,
        .username = "carol",
        .method = .password,
        .roles = &[_][]const u8{"User"},
        .scopes = &.{},
        .session_token = "sess-abc",
        .requires_mfa = false,
        .requires_password_reset = false,
        .elevation_level = .standard,
    };
    const p = principal_mod.Principal.fromAuthState(.{
        .auth_result = ar,
        .auth_version = 9,
        .tenant_id = "tenant-x",
        .active_graph = "hr",
        .api_key_id = null,
        .certificate_subject = null,
        .ip_address = "127.0.0.1",
        .user_agent = null,
        .source = .quic_handler,
    });
    try std.testing.expectEqual(@as(u64, 100), p.user_id.?);
    try std.testing.expectEqualStrings("carol", p.username.?);
    try std.testing.expectEqualStrings("sess-abc", p.session_id.?);
    try std.testing.expectEqualStrings("tenant-x", p.tenant_id.?);
    try std.testing.expectEqualStrings("hr", p.active_graph.?);
    try std.testing.expectEqual(@as(usize, 1), p.roles.len);
    try std.testing.expectEqual(authn.AuthMethod.password, p.auth_method);
    try std.testing.expectEqual(@as(u64, 9), p.auth_version);
    try std.testing.expectEqual(principal_mod.MfaState.none, p.mfa_state);
    try std.testing.expectEqualStrings("127.0.0.1", p.risk_context.ip_address.?);
    try std.testing.expectEqual(principal_mod.PrincipalSource.quic_handler, p.source);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-002; FEATURE="GPS Canonical Principal"; ASPECT=FromAuthStateBuilderMfa; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "fromAuthState records mfa_state=required when AuthResult.requires_mfa is true" {
    const authn = geode.security.authn;
    const ar = authn.AuthResult{
        .user_id = 100,
        .username = "carol",
        .method = .password,
        .roles = &.{},
        .scopes = &.{},
        .session_token = null,
        .requires_mfa = true,
        .requires_password_reset = false,
        .elevation_level = .standard,
    };
    const p = principal_mod.Principal.fromAuthState(.{
        .auth_result = ar,
        .auth_version = 0,
        .tenant_id = null,
        .active_graph = null,
        .api_key_id = null,
        .certificate_subject = null,
        .ip_address = null,
        .user_agent = null,
        .source = .quic_handler,
    });
    try std.testing.expectEqual(principal_mod.MfaState.required, p.mfa_state);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter="fromAuthState"`

Expected: FAIL — `fromAuthState` is not a member of `Principal`.

- [ ] **Step 3: Implement the builder**

Append to `src/security/principal.zig`:

```zig
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
```

Move `pub fn fromAuthState` inside the `Principal` struct so it is callable as `Principal.fromAuthState(...)` (place it directly above `pub fn empty()`).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test -Dtest-filter="fromAuthState"`

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/security/principal.zig tests/test_gps_principal.zig
git commit -m "feat(gps): Principal.fromAuthState() builder from AuthResult"
```

---

### Task 1-3: Add `principal` field to `ExecutionContext`

**Files:**
- Modify: `src/execution.zig` (add field, add import)
- Test: `tests/test_gps_principal.zig` (add a field-presence test)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_gps_principal.zig`:

```zig
// CANARY: REQ=REQ-GPS-PRINCIPAL-003; FEATURE="GPS Canonical Principal"; ASPECT=ExecutionContextField; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ExecutionContext.principal defaults to null and accepts a pointer" {
    const execution = geode.execution;
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);

    const default_ctx = execution.ExecutionContext{ .catalog = catalog };
    try std.testing.expect(default_ctx.principal == null);

    const p = principal_mod.Principal.empty();
    const ctx_with_principal = execution.ExecutionContext{
        .catalog = catalog,
        .principal = &p,
    };
    try std.testing.expect(ctx_with_principal.principal != null);
    try std.testing.expectEqual(@as(u64, 0), ctx_with_principal.principal.?.auth_version);
}
```

The pattern `execution.cleanupCatalogInstance()` + `execution.ensureCatalogInstance(allocator)` matches the canonical test setup used in `tests/test_meta_procedures.zig:43-48`. Do not import `catalog_mod` directly — it is private to `src/execution.zig`.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter="ExecutionContext.principal"`

Expected: FAIL with "no field named 'principal'".

- [ ] **Step 3: Add the field to ExecutionContext**

Edit `src/execution.zig`. Locate the `tenant_id: ?[]const u8 = null,` line at line 484. Immediately above it, add:

```zig
    // CANARY: REQ=REQ-GPS-PRINCIPAL-003; FEATURE="GPS Canonical Principal"; ASPECT=ExecutionContextField; STATUS=TESTED; TEST=tests/test_gps_principal.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 1: canonical Principal constructed once at the request boundary.
    // Null in legacy/test paths during migration. Phase 2 makes decide() the
    // sole consumer; checkPermission() does NOT read this field yet.
    principal: ?*const @import("security/principal.zig").Principal = null,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test -Dtest-filter="ExecutionContext.principal"`

Expected: test passes.

- [ ] **Step 5: Confirm the full test suite still passes**

Run: `make build && zig build test`

Expected: build green, no new failures. Existing tests that construct `ExecutionContext{ .catalog = catalog }` continue to work because `principal` defaults to null.

- [ ] **Step 6: Commit**

```bash
git add src/execution.zig tests/test_gps_principal.zig
git commit -m "feat(gps): add optional principal field to ExecutionContext"
```

---

### Task 1-4: Wire Principal construction at the QUIC handler

**Files:**
- Modify: `src/server/quic_connection_handler.zig` (around line 3242)

- [ ] **Step 1: Read the construction site for context**

Run: `sed -n '3220,3270p' src/server/quic_connection_handler.zig`

Expected: see the existing `exec_context` builder block starting at line 3242. Identify the local variables in scope: `state.authenticated_user`, `role`, `state.exec_session`, `state.session_config`, and the AuthResult (search backwards from line 3242 for `auth_result`, `authenticated`, or `provider.authenticate` to find where the AuthResult is in scope — if it isn't directly in scope, the principal must be constructed from `state` fields instead).

- [ ] **Step 2: Add the Principal construction directly above the ExecutionContext builder**

Insert this block immediately before the `var exec_context = execution.ExecutionContext{` line at line 3242:

```zig
            // CANARY: REQ=REQ-GPS-PRINCIPAL-004; FEATURE="GPS Canonical Principal"; ASPECT=QuicHandlerWiring; STATUS=TESTED; TEST=tests/test_gps_principal_propagation.zig; OWNER=security; UPDATED=2026-05-20
            // Phase 1: build the canonical Principal once per request. No authorization
            // semantics consume it yet (decide() arrives in Phase 2); ExecutionContext.principal
            // is observable so downstream code can pin it for diagnostics and future GPS use.
            const principal_for_request = blk: {
                const principal_mod = @import("../security/principal.zig");
                if (state.authenticated_user) |uname| {
                    const role_names: []const []const u8 = if (role) |r|
                        &[_][]const u8{@tagName(r)}
                    else
                        &[_][]const u8{};
                    break :blk principal_mod.Principal{
                        .user_id = null,
                        .username = uname,
                        .session_id = null,
                        .tenant_id = if (state.session_config) |cfg| cfg.tenant_id else null,
                        .active_graph = if (state.exec_session) |s| s.graph else null,
                        .roles = role_names,
                        .custom_roles = &.{},
                        .auth_method = .password,
                        // Phase 1: auth_version=0 because no public accessor on
                        // user_management.zig exposes the persistent version by
                        // username. Phase 2 introduces a single principal-derivation
                        // helper that consults the persistent resolver chain.
                        .auth_version = 0,
                        .mfa_state = .none,
                        .elevation_until = null,
                        .api_key_id = null,
                        .certificate_subject = null,
                        .risk_context = .{
                            .score = 0,
                            .ip_address = null,
                            .user_agent = null,
                        },
                        .attributes = principal_mod.AttributeMap.emptySentinel(),
                        .source = .quic_handler,
                    };
                }
                break :blk principal_mod.Principal.empty();
            };
```

Then add `.principal = &principal_for_request,` to the `exec_context` struct literal, placing it immediately after the `.tenant_id = ...` line.

The `auth_version = 0` is intentional for Phase 1 — `src/security/user_management.zig` has no public lookup helper by username (only the resolver callback at line 130 and the `auth_version` field on the in-memory `User` record). Populating it correctly is deferred to Phase 2's principal-derivation helper.

- [ ] **Step 3: Run build and existing tests**

Run: `make build && zig build test`

Expected: build green, no test regressions. The new field is set but no caller reads it yet (other than the introspection test in the next task).

- [ ] **Step 4: Commit**

```bash
git add src/server/quic_connection_handler.zig
git commit -m "feat(gps): construct Principal at QUIC handler request boundary"
```

---

### Task 1-5: Wire Principal construction at the gRPC server

**Files:**
- Modify: `src/transport/grpc_server.zig` (around line 1959)

- [ ] **Step 1: Read the gRPC construction site**

Run: `sed -n '1945,1990p' src/transport/grpc_server.zig`

Expected: see the existing `var exec_context = execution.ExecutionContext{` block. Identify the in-scope variables that correspond to authenticated user, session, and tenant.

- [ ] **Step 2: Build the Principal at the gRPC boundary**

Insert a block analogous to the QUIC handler one (from Task 1-4 Step 2) immediately before the `var exec_context = execution.ExecutionContext{` line. Use the gRPC handler's locally-scoped names for username, role, tenant, graph (the variable names will differ; do not blindly copy — match what's actually in scope). The Principal `.source` must be `.grpc_handler`.

If the gRPC handler does not have an authenticated user concept (some transports run with anonymous principals), build an empty Principal via `principal_mod.Principal.empty()` and tag the source as `.grpc_handler`.

Add `.principal = &principal_for_request,` to the `exec_context` struct literal.

- [ ] **Step 3: Run build and existing tests**

Run: `make build && zig build test`

Expected: build green, no regressions.

- [ ] **Step 4: Commit**

```bash
git add src/transport/grpc_server.zig
git commit -m "feat(gps): construct Principal at gRPC handler request boundary"
```

---

### Task 1-6: Wire Principal construction at the distributed coordinator

**Files:**
- Modify: `src/distributed/query_coordinator.zig` (around line 357)

- [ ] **Step 1: Read the coordinator construction site**

Run: `sed -n '340,380p' src/distributed/query_coordinator.zig`

Expected: see `const context = execution.ExecutionContext{ .catalog = catalog };` at line 357.

- [ ] **Step 2: Add an internal-service Principal**

Replace the existing line with:

```zig
        // CANARY: REQ=REQ-GPS-PRINCIPAL-005; FEATURE="GPS Canonical Principal"; ASPECT=DistributedCoordinatorWiring; STATUS=TESTED; TEST=tests/test_gps_principal_propagation.zig; OWNER=security; UPDATED=2026-05-20
        // Phase 1: the coordinator runs synthetic queries on behalf of internal
        // shard-coordination logic. Tag the principal as internal_service so
        // GPS Phase 6 (distributed envelope) can distinguish coordinator-originated
        // work from user-originated work even when both reach the same shard worker.
        const coordinator_principal = @import("../security/principal.zig").Principal{
            .user_id = null,
            .username = "geode-coordinator",
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
            .risk_context = @import("../security/principal.zig").RiskContext.unknown,
            .attributes = @import("../security/principal.zig").AttributeMap.emptySentinel(),
            .source = .internal_service,
        };
        const context = execution.ExecutionContext{
            .catalog = catalog,
            .principal = &coordinator_principal,
        };
```

- [ ] **Step 3: Run build and existing tests**

Run: `make build && zig build test`

Expected: build green. The distributed module activates only when `GEODE_CLUSTER_TOKEN` is set; in the default test environment the coordinator path is bypassed entirely (per CLAUDE.md "Distributed module" note).

- [ ] **Step 4: Commit**

```bash
git add src/distributed/query_coordinator.zig
git commit -m "feat(gps): tag distributed coordinator with internal_service Principal"
```

---

### Task 1-7: Write the end-to-end propagation test

**Files:**
- Create: `tests/test_gps_principal_propagation.zig`

- [ ] **Step 1: Write the failing integration test**

Create `tests/test_gps_principal_propagation.zig`:

```zig
const std = @import("std");
const geode = @import("geode");
const principal_mod = geode.security.principal;
const execution = geode.execution;

// CANARY: REQ=REQ-GPS-PRINCIPAL-006; FEATURE="GPS Canonical Principal"; ASPECT=ExecutionPropagation; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ExecutionContext.principal pointer is preserved through pushActiveContext/getActiveContext" {
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);

    const p = principal_mod.Principal{
        .user_id = 42,
        .username = "propagation-test",
        .session_id = null,
        .tenant_id = "tenant-prop",
        .active_graph = "graph-prop",
        .roles = &[_][]const u8{"User"},
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };

    const ctx = execution.ExecutionContext{
        .catalog = catalog,
        .user = "propagation-test",
        .tenant_id = "tenant-prop",
        .principal = &p,
    };

    const prev = execution.pushActiveContext(&ctx);
    defer execution.popActiveContext(prev);

    const active = execution.getActiveContext() orelse return error.NoActiveContext;
    try std.testing.expect(active.principal != null);
    try std.testing.expectEqualStrings("propagation-test", active.principal.?.username.?);
    try std.testing.expectEqualStrings("tenant-prop", active.principal.?.tenant_id.?);
    try std.testing.expectEqual(principal_mod.PrincipalSource.test_harness, active.principal.?.source);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-006; FEATURE="GPS Canonical Principal"; ASPECT=BackwardCompat; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ExecutionContext default constructor without principal still produces null principal" {
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog };
    const prev = execution.pushActiveContext(&ctx);
    defer execution.popActiveContext(prev);
    const active = execution.getActiveContext() orelse return error.NoActiveContext;
    try std.testing.expect(active.principal == null);
}
```

The catalog handling follows the same convention as `tests/test_meta_procedures.zig:30-50` — global instance owned by `execution` itself, set up via `ensureCatalogInstance` and torn down via `cleanupCatalogInstance`.

- [ ] **Step 2: Register the test file in build.zig if not auto-discovered**

Run: `grep -n "test_gps_principal" build.zig`

Expected: the new file is already picked up by the test source list. If not, add it next to other `tests/test_*.zig` entries following the existing pattern.

- [ ] **Step 3: Run test to verify it passes**

Run: `zig build test -Dtest-filter="ExecutionContext.principal pointer\\|null principal"`

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
git add tests/test_gps_principal_propagation.zig build.zig
git commit -m "test(gps): verify Principal propagation through ExecutionContext"
```

---

### Task 1-8: Add a black-box geodetestlab spec for principal-bearing queries

**Files:**
- Create: `../geode-test-harness/specs/gps_principal_smoke.yml` (in the sibling harness repo)

> **Note:** This task lives in `../geode-test-harness/`, not in the geode repo. The implementer must change directory before running the harness command; commits to that repo are separate from geode commits.

- [ ] **Step 1: Confirm the harness directory exists**

Run: `ls ../geode-test-harness/specs/ 2>&1 | head -5`

Expected: a list of existing `.yml` spec files. If the directory does not exist, skip this task entirely and note the gap in the final summary — the harness may not be checked out, in which case the Zig-level test from Task 1-7 already covers the functional path.

- [ ] **Step 2: Write a smoke spec**

Create `../geode-test-harness/specs/gps_principal_smoke.yml`:

```yaml
# CANARY: REQ=REQ-GPS-PRINCIPAL-007; FEATURE="GPS Canonical Principal"; ASPECT=BlackBoxSmoke; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
# Smoke: an authenticated session can run a trivial query end-to-end. Phase 1
# does not yet allow black-box inspection of the principal (no `SHOW PRINCIPAL`
# statement until Phase 2), so this spec only verifies the wiring did not
# regress the existing authenticated-query path.
name: gps_principal_smoke
description: |
  Authenticated session executes a trivial RETURN under default auth config.
  Verifies that Principal construction at the QUIC handler does not break the
  existing query path.

setup:
  - "CREATE USER smoke_user WITH PASSWORD 'smoke-pass-1234'"
  - "GRANT ROLE User TO smoke_user"

teardown:
  - "DROP USER IF EXISTS smoke_user"

scenarios:
  - name: trivial_return
    user: smoke_user
    password: smoke-pass-1234
    query: "RETURN 1 AS x"
    expect:
      rows:
        - x: 1
```

- [ ] **Step 3: Run the spec**

Run from the geode repo root:

```bash
cd ../geode-test-harness && GEODE_BINARY=$(realpath ../geode/zig-out/bin/geode) make test-spec SPEC=specs/gps_principal_smoke.yml
```

Expected: 1 scenario passes.

- [ ] **Step 4: Commit (in the harness repo)**

```bash
cd ../geode-test-harness && git add specs/gps_principal_smoke.yml && git commit -m "test(gps): smoke spec for Phase 1 Principal wiring"
```

---

### Task 1-9: Document the Phase 1 outcome

**Files:**
- Create: `docs/security/gps-principal.md`

- [ ] **Step 1: Write the principal documentation**

Create `docs/security/gps-principal.md`:

```markdown
# GPS Phase 1 — Canonical Principal

## What landed in Phase 1

`src/security/principal.zig` defines the canonical `Principal` type and a
`Principal.fromAuthState()` builder. `ExecutionContext` (in `src/execution.zig`)
gained an optional `principal: ?*const Principal = null` field. The three
production transports — QUIC (`src/server/quic_connection_handler.zig:3242`),
gRPC (`src/transport/grpc_server.zig:1959`), and the distributed coordinator
(`src/distributed/query_coordinator.zig:357`) — each construct a Principal
exactly once at the request boundary and assign it to the execution context.

## What did NOT change in Phase 1

- `checkPermission()` does not read `ExecutionContext.principal`.
- `rls_core.checkRowAccessByUsername` does not read `ExecutionContext.principal`.
- No new procedure, statement, or DDL consumes the principal.
- All existing tests pass with `principal: ?*const Principal = null`.

Phase 1 is intentionally a no-op for runtime authorization. It exists so that
Phase 2 (the `decide()` API) and every later phase can rely on a single, typed
principal arriving at every PEP without re-deriving it from `user`, `role`,
`tenant_id`, and `session_state` separately.

## Compatibility

The MCP and LSP paths funnel through QUIC and do not construct their own
`ExecutionContext`, so they inherit the principal from the QUIC handler
without any new code in Phase 1. Per-caller principal threading inside MCP
tools is a Phase 5 concern.

## How to read the principal in new code (Phase 2+)

```zig
const ctx = execution.getActiveContext() orelse return error.NoActiveContext;
if (ctx.principal) |p| {
    // Phase 2+: pass p to gps.decide()
    _ = p;
}
```

In Phase 2 every `decide()` call MUST receive a non-null `*const Principal`.
The Phase 0 invariants doc (`docs/security/gps-invariants.md`) lists the
single compatibility-mode exception (auth disabled in development).
```

- [ ] **Step 2: Commit**

```bash
git add docs/security/gps-principal.md
git commit -m "docs(gps): document Phase 1 Principal scope and Phase 2 handoff"
```

---

## Final Verification

After all tasks complete, run the full verification battery from the geode repo root:

- [ ] **Step 1: Build and unit-test pass**

Run: `make build && zig build test`

Expected: build green, all tests pass. The new `REQ-GPS-PRINCIPAL-*` and `REQ-GPS-INVARIANT-001` CANARY markers should appear in `make status-generate` output.

- [ ] **Step 2: Pre-commit pass**

Run: `make pre-commit`

Expected: all hooks pass. Formatting clean.

- [ ] **Step 3: Quick geodetestlab integration sanity**

Run from `../geode-test-harness`:

```bash
GEODE_BINARY=$(realpath ../geode/zig-out/bin/geode) make test-spec SPEC=specs/gps_principal_smoke.yml
```

Expected: pass (if Task 1-8 was completed).

- [ ] **Step 4: Confirm CANARY governance**

Run: `grep -rn "REQ-GPS-INVARIANT-001\\|REQ-GPS-PRINCIPAL-00" src/ tests/ docs/ | wc -l`

Expected: ≥ 15 markers (5 invariant, ~10 principal-series).

- [ ] **Step 5: Confirm no regression in the existing fail-closed posture**

Run a manual smoke from the geode repo root:

```bash
./zig-out/bin/geode serve --listen 127.0.0.1:31410 &
SERVER_PID=$!
sleep 1
./zig-out/bin/geode --dsn "127.0.0.1:31410?insecure=true&user=geode&pass=$GEODE_ADMIN_PASSWORD" query "RETURN 1 AS x"
kill $SERVER_PID
```

Expected: query returns `x = 1`. Unauthenticated queries (omit `user`/`pass`) still fail with the same error class as before — Phase 1 does not change authn outcomes.

---

## What this plan does NOT do

For maintainer review — explicit non-goals so the next phase plan can pick them up cleanly:

- **No `decide()` API.** That is GPS Phase 2.
- **No removal of `checkPermission()`.** It still uses builtin role + graph-grant widening.
- **No policy DDL.** No `CREATE POLICY` statements parse.
- **No metadata-procedure filtering.** `db.labels()` etc. remain global.
- **No MCP per-caller principal.** MCP still uses the server-wide bearer model.
- **No distributed envelope changes.** The coordinator's internal Principal does not yet propagate to shard workers.

These are all addressed in later GPS phase plans, which can now reference
`docs/security/gps-invariants.md` (the pinned current behavior) and
`docs/security/gps-fail-open-sites.md` (the catalog of compatibility-mode
exceptions to close).
