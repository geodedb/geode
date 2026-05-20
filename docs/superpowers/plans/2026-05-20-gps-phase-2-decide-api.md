# GPS Phase 2 — Central `decide()` API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the central `gps.decide()` decision point and migrate the existing permission-check call sites to consume it. Phase 2 makes the *decision flow* observable, fail-closed, and uniform across transports, but it deliberately does NOT add new policy semantics — every current allow/deny outcome is preserved bit-identical, modulo two intentional fail-closed conversions (RLS VM no-result and a removed implicit "auth disabled = allow").

**Architecture:** A new `src/security/gps.zig` defines `DecisionRequest`, `PolicyDecision`, `PolicyDecisionKind`, `Action`, `ResourceRef`, `Obligation`, `AuditFields`, plus the `decide()` entry point. `decide()` runs a deterministic evaluation order: session/auth-version validity → tenant/graph binding → builtin-role grants → graph grants (now first-class facts, not widening-only) → audit. It reuses existing primitives (`user_management.hasPermission`, `multi_graph_security.GraphRBACPolicy`) as *evidence sources*, not final authorizers. A new `src/security/principal_derive.zig` centralizes Principal construction so the three transport sites stop duplicating logic. `execution.checkPermission()` becomes a thin adapter that calls `decide()`. The two direct `user_mgmt.hasPermission()` call sites at `src/transport/grpc_server.zig:1506` and `:2077` are replaced with `gps.decide()` calls. `--insecure-allow-all` becomes the only path that bypasses `decide()`; the implicit branch from `checkPermission()` is removed.

**Tech Stack:** Zig 0.16.0+, existing CANARY governance (`REQ=REQ-GPS-PDP-*`, `REQ=REQ-GPS-CACHE-*`, `REQ=REQ-GPS-DERIVE-*`), existing test runners.

**Reference design:** `docs/geode-policy-plan.md` — sections "Canonical principal, resource, action, and decision models" and "Evaluation order and expression language."

**Reference foundation:** `docs/security/gps-invariants.md` (the locked current-state contract that `decide()` must preserve), `docs/security/gps-fail-open-sites.md` (the 9 documented sites; Phase 2 closes sites #1 and #4 only — others land in later phases), `docs/security/gps-principal.md` (Phase 1 outcome doc).

---

## Carry-forward findings from Phase 0+1 folded into this plan

Each is addressed by a specific task below:

1. **Three-transport Principal duplication** — Task 2-2 introduces `principal_derive.derivePrincipal()` and the three sites switch to it.
2. **`AttributeMap.get()` is dead code** — Task 2-7 (ABAC predicates) is the first real consumer; if Task 2-7 doesn't use it, Task 2-13 (final pass) removes it.
3. **`call_operations.zig:145` test-only `ExecutionContext` construction** — Task 2-1's review explicitly audits this site; if it turns out to be a production path under any flag, it's added to the Principal-wiring list.
4. **`SITE=` field stripped by canary normalizer** — Task 2-13 documents the alternate cross-reference convention (shared `REQ=` between source and catalog) in `docs/security/gps-canary-conventions.md`.
5. **Geodetestlab smoke spec skipped in Phase 1** — Task 2-12 writes a real black-box spec exercising `decide()`-observable behavior (deny outcomes, audit obligations, MFA-required outcomes).
6. **Fail-open site #1 (`auth disabled = allow`)** — Task 2-9 moves it behind the explicit `--insecure-allow-all` flag and removes the implicit branch.
7. **Fail-open site #4 (RLS VM no-result returns allow)** — Task 2-8 converts the VM to `error.IndeterminatePolicy` and maps that to a `deny` decision in `decide()`.
8. **Phase 1's `auth_version = 0` hardcoding** — already closed by commit `9654cde6`. Task 2-2's `derivePrincipal()` adopts the same `state.authenticated_auth_version` source so the three sites converge.

---

## File Structure

**Create:**
- `src/security/gps.zig` — Defines `Action`, `ResourceRef`, `DecisionRequest`, `PolicyDecision`, `PolicyDecisionKind`, `Obligation`, `AuditFields`, `decide()` entry point, and the deterministic evaluation order. Pure logic; reads evidence from `user_management`, `multi_graph_security`, `rls_core`. No new persistent state.
- `src/security/principal_derive.zig` — Single helper `derivePrincipal(args)` that builds a `Principal` from transport-agnostic inputs. Consumed by all three transport sites and any future PEP that needs a Principal.
- `tests/test_gps_decide.zig` — Decision-engine unit tests covering allow / deny / unauthenticated / unauthorized / graph-grant widening / fail-closed defaults.
- `tests/test_gps_principal_derive.zig` — Tests for the shared derivation helper.
- `docs/security/gps-decide.md` — Phase 2 outcome doc: what `decide()` is, when to call it, evaluation order, what *did not* change (most outcomes are bit-identical), what *did* (the two intentional fail-closed conversions).
- `docs/security/gps-canary-conventions.md` — Records the convention for cross-referencing source ↔ catalog via shared `REQ=` IDs after the normalizer stripped `SITE=`.
- A black-box harness spec under `../geode-test-harness/geodetestlab-cli/specs/gps_decide_smoke.yml` — exercises a deny outcome (e.g., ReadOnly user attempts CREATE) and confirms the error class matches pre-Phase-2 behavior.

**Modify:**
- `src/execution.zig` — `checkPermission()` becomes a 5-line adapter that builds a `DecisionRequest` and calls `gps.decide()`. The Phase 0 `REQ-GPS-INVARIANT-001` `STATUS=EXEMPT` markers on this function are flipped to `STATUS=COMPLETE` because the underlying sites are closed.
- `src/transport/grpc_server.zig` — The two direct `user_mgmt.hasPermission()` calls at lines 1506 and 2077 are replaced with `gps.decide()`.
- `src/server/quic_connection_handler.zig` — Principal construction block replaced with a call to `principal_derive.derivePrincipal(.{...})`. The body of the Principal struct literal moves into the derivation helper.
- `src/transport/grpc_server.zig` — Same Principal-derivation switch.
- `src/distributed/query_coordinator.zig` — Same Principal-derivation switch (with `source = .internal_service`).
- `src/security/user_management.zig` — Add a new `--insecure-allow-all` runtime flag (probably an `setInsecureAllowAll(bool)` + accessor pair) so `decide()` has one explicit knob instead of the current implicit `isAuthEnabled()` short-circuit.
- `src/security/rls_core.zig` — The VM no-result return path changes from `return true` to `return error.IndeterminatePolicy`. The `REQ-GPS-INVARIANT-001` CANARY on that site flips to `STATUS=COMPLETE`.

**Out of scope for this plan (Phase 3+ territory):**
- Real policy DDL (`CREATE POLICY` etc.) — Phase 4.
- Persistent policy catalog in `__geode_security` — Phase 4.
- Mandatory `EXECUTE_PROCEDURE` decision before procedure dispatch — Phase 5.
- Metadata procedure tenant filtering — Phase 5.
- MCP per-caller principal propagation — Phase 5.
- Distributed envelope policy-version propagation — Phase 6.
- Decision cache — Phase 7. (Phase 2 keeps `cacheable=false` on every decision.)

---

## Phase 2 Tasks

### Task 2-1: Decision types and skeleton `decide()`

**Files:**
- Create: `src/security/gps.zig`
- Create: `tests/test_gps_decide.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/test_gps_decide.zig` with:

```zig
const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=DecisionTypes; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "PolicyDecision kinds are distinct" {
    try std.testing.expect(gps.PolicyDecisionKind.allow != gps.PolicyDecisionKind.deny);
    try std.testing.expect(gps.PolicyDecisionKind.unauthenticated != gps.PolicyDecisionKind.unauthorized);
}

// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=DefaultDeny; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() with an empty Principal returns unauthenticated" {
    const p = principal_mod.Principal.empty();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const decision = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthenticated, decision.kind);
}
```

- [ ] **Step 2: Run test to verify it fails** — `zig build test-gps-decide` should fail with module-resolution error.

- [ ] **Step 3: Create `src/security/gps.zig`** with `Action` (read, write, schema, match, create, update, delete, execute_procedure, admin_user, admin_role, admin_tenant, bind_graph, show_metadata, decrypt_field, unwrap_key — enough for the call sites Phase 2 touches), `ResourceRef` (database, graph, tenant, node, edge, procedure, metadata — same minimal set), `DecisionRequest`, `PolicyDecisionKind` (allow, deny, unauthenticated, unauthorized, indeterminate, audit_only — six values for Phase 2; mask/filter/require_mfa come in later phases), `Obligation` (empty struct for Phase 2), `AuditFields`, `PolicyDecision`, and a `decide()` that currently only handles the empty/unauthenticated case. Use the minimal type definitions from `docs/geode-policy-plan.md` "Sample Zig interfaces" but trim every field Phase 2 does not need.

- [ ] **Step 4: Wire `gps` into `src/lib.zig`** — add `pub const gps = @import("security/gps.zig");` next to `pub const principal` and `pub const authn` inside the existing `security` struct.

- [ ] **Step 5: Add a `test-gps-decide` step to `build.zig`** — copy the existing `test-gps-principal` step pattern.

- [ ] **Step 6: Run test to verify it passes** — `zig build test-gps-decide` exits 0.

- [ ] **Step 7: Commit**

```bash
git add src/security/gps.zig tests/test_gps_decide.zig src/lib.zig build.zig
git commit -m "feat(gps): decision types and skeleton decide() entry point"
```

---

### Task 2-2: Principal derivation helper

**Files:**
- Create: `src/security/principal_derive.zig`
- Create: `tests/test_gps_principal_derive.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/test_gps_principal_derive.zig`:

```zig
const std = @import("std");
const geode = @import("geode");
const derive = geode.security.principal_derive;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-DERIVE-001; FEATURE="GPS Principal Derivation"; ASPECT=QuicArgs; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "derivePrincipal from QUIC-shaped args yields source=.quic_handler" {
    const role_names = [_][]const u8{"User"};
    const p = derive.derivePrincipal(.{
        .username = "alice",
        .role_names = &role_names,
        .tenant_id = "t1",
        .active_graph = "hr",
        .auth_version = 7,
        .auth_method = .password,
        .source = .quic_handler,
    });
    try std.testing.expectEqual(principal_mod.PrincipalSource.quic_handler, p.source);
    try std.testing.expectEqualStrings("alice", p.username.?);
    try std.testing.expectEqual(@as(u64, 7), p.auth_version);
}

// CANARY: REQ=REQ-GPS-DERIVE-001; FEATURE="GPS Principal Derivation"; ASPECT=EmptyArgs; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "derivePrincipal with null username returns the source-tagged empty principal" {
    const p = derive.derivePrincipal(.{
        .username = null,
        .role_names = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .auth_method = .anonymous,
        .source = .grpc_handler,
    });
    try std.testing.expectEqual(principal_mod.PrincipalSource.grpc_handler, p.source);
    try std.testing.expect(p.username == null);
}
```

- [ ] **Step 2: Run test to verify it fails** — module not found.

- [ ] **Step 3: Implement `src/security/principal_derive.zig`** — define `DeriveArgs` (the union of fields the three transports currently use: `username`, `role_names`, `tenant_id`, `active_graph`, `auth_version`, `auth_method`, `source`, plus optionals `ip_address`, `user_agent`, `api_key_id`, `certificate_subject`) and `derivePrincipal(args)` that returns a `Principal`. The empty-args case must still tag the source correctly (Phase 1's `Principal.empty()` left source as `.unattributed` — this helper does not, because the caller always knows which transport they are).

- [ ] **Step 4: Wire into `src/lib.zig`** — `pub const principal_derive = @import("security/principal_derive.zig");` inside the existing `security` struct.

- [ ] **Step 5: Add `test-gps-principal-derive` to `build.zig`**.

- [ ] **Step 6: Run test** — `zig build test-gps-principal-derive` passes.

- [ ] **Step 7: Commit**

```bash
git add src/security/principal_derive.zig tests/test_gps_principal_derive.zig src/lib.zig build.zig
git commit -m "feat(gps): principal derivation helper for transport-agnostic Principal builds"
```

---

### Task 2-3: Migrate QUIC, gRPC, and distributed coordinator to `derivePrincipal()`

**Files:**
- Modify: `src/server/quic_connection_handler.zig`
- Modify: `src/transport/grpc_server.zig`
- Modify: `src/distributed/query_coordinator.zig`

- [ ] **Step 1: Read each current Principal block**

```bash
sed -n '3240,3300p' src/server/quic_connection_handler.zig
sed -n '1955,2010p' src/transport/grpc_server.zig
sed -n '355,385p'   src/distributed/query_coordinator.zig
```

- [ ] **Step 2: Replace each block with a call to `derivePrincipal()`**

For QUIC, the new block is roughly:

```zig
            // CANARY: REQ=REQ-GPS-DERIVE-002; FEATURE="GPS Principal Derivation"; ASPECT=QuicHandlerWiring; STATUS=TESTED; TEST=tests/test_gps_principal_propagation.zig; OWNER=security; UPDATED=2026-05-20
            const principal_for_request = blk: {
                const derive = geode.security.principal_derive;
                const role_names: []const []const u8 = if (role) |r|
                    &[_][]const u8{@tagName(r)}
                else
                    &.{};
                break :blk derive.derivePrincipal(.{
                    .username = state.authenticated_user,
                    .role_names = role_names,
                    .tenant_id = if (state.session_config) |cfg| cfg.tenant_id else null,
                    .active_graph = if (state.exec_session) |s| s.graph else null,
                    .auth_version = state.authenticated_auth_version,
                    .auth_method = .password,
                    .source = .quic_handler,
                });
            };
```

For gRPC, identical but with `.source = .grpc_handler` and the local in-scope auth-version field. For the distributed coordinator, all fields null/zero with `.source = .internal_service` and `.username = "geode-coordinator"`.

The point is the same struct-literal noise disappears from each transport site.

- [ ] **Step 3: Build and run all 7 existing principal tests**

```bash
make build
zig build test-gps-principal
zig build test-gps-principal-propagation
zig build test-gps-principal-derive
```

All must pass.

- [ ] **Step 4: Commit**

```bash
git add src/server/quic_connection_handler.zig src/transport/grpc_server.zig src/distributed/query_coordinator.zig
git commit -m "refactor(gps): use derivePrincipal() at all three transport sites"
```

---

### Task 2-4: Implement `decide()` for builtin-role allow/deny

**Files:**
- Modify: `src/security/gps.zig`
- Modify: `tests/test_gps_decide.zig`

- [ ] **Step 1: Add tests covering Admin/User/ReadWrite/ReadOnly outcomes**

For each builtin role + each Permission (Read, Write, Schema), assert the `decide()` outcome matches the legacy `user_management.hasPermission` outcome (so we know we haven't regressed). One concise test using a 12-case table is fine.

- [ ] **Step 2: Implement the builtin-role evaluation step in `decide()`** — read `principal.roles[]`, map each role name back to the legacy `Role` enum, call `user_management.hasPermission(role, perm)` as the evidence source, and return `.allow` if any role permits the action. Otherwise fall through to deny.

- [ ] **Step 3: Run tests** — all 14+ tests pass.

- [ ] **Step 4: Commit** — `feat(gps): decide() honors builtin role grants identically to user_management.hasPermission`

---

### Task 2-5: Implement `decide()` for graph grants

**Files:** Same as Task 2-4 plus a few new test cases.

- [ ] **Step 1: Tests covering the additive graph-grant widening case**

A user with `ReadOnly` builtin role + a `GRANT WRITE ON GRAPH hr` should get `.allow` for write on graph `hr` and `.deny` for write on graph `sales` (no grant there).

- [ ] **Step 2: Implement** — call `multi_graph_security.graph_grant_check_fn` (the same callback `checkPermission` currently uses) inside `decide()` when the builtin-role check produced a deny *and* the principal has an `active_graph`. This preserves the current additive-widening semantics bit-identically. Note in the comment that Phase 4 will replace this with first-class policy rows.

- [ ] **Step 3: Run tests** — pass.

- [ ] **Step 4: Commit** — `feat(gps): decide() consults graph_grant_check_fn for widening`

---

### Task 2-6: Replace `execution.checkPermission()` body with a `decide()` adapter

**Files:**
- Modify: `src/execution.zig`

- [ ] **Step 1: Write a test** that calls `execution.checkPermission` with a context whose `principal` field is set, and assert the outcome matches `gps.decide` for the same principal. (The test goes in `tests/test_gps_decide.zig` since the existing checkPermission tests live in security tests.)

- [ ] **Step 2: Replace the body of `checkPermission()`** with:

```zig
pub fn checkPermission(context: ExecutionContext, permission: @import("security/user_management.zig").Permission) !void {
    const gps = @import("security/gps.zig");
    const action: gps.Action = switch (permission) {
        .Read => .read,
        .Write => .write,
        .Schema => .schema,
    };
    const principal = context.principal orelse {
        if (!@import("security/user_management.zig").isAuthEnabled() and gps.insecureAllowAllEnabled()) return;
        return error.Unauthenticated;
    };
    const req = gps.DecisionRequest{
        .principal = principal,
        .action = action,
        .resource = .{ .database = {} },
    };
    const decision = try gps.decide(std.heap.page_allocator, &req);
    switch (decision.kind) {
        .allow => return,
        .unauthenticated => return error.Unauthenticated,
        else => return error.Unauthorized,
    }
}
```

Note: `insecureAllowAllEnabled()` is introduced in Task 2-9. For Task 2-6 you can stub it to return `!isAuthEnabled()` temporarily so the legacy behavior is preserved bit-identically. Task 2-9 then introduces the explicit flag.

- [ ] **Step 3: Update CANARY markers** — flip the `REQ-GPS-INVARIANT-001` markers on the auth-disabled and graph-grant branches from `STATUS=EXEMPT` to `STATUS=COMPLETE` once the implicit branch is no longer reachable through `checkPermission`.

- [ ] **Step 4: Run full test suite** — `make build && zig build test`. All pre-Phase-2 tests must still pass. Pay attention to `tests/test_user_management.zig` and `tests/test_auth_persistence.zig`.

- [ ] **Step 5: Commit** — `refactor(gps): checkPermission() now calls gps.decide()`

---

### Task 2-7: Replace direct `user_mgmt.hasPermission` calls in transports

**Files:**
- Modify: `src/transport/grpc_server.zig` (lines 1506 and 2077)

- [ ] **Step 1: Identify both call sites**

```bash
grep -n "hasPermission" src/transport/grpc_server.zig
```

- [ ] **Step 2: Replace each call with `gps.decide()`** — at the `grpc_server.zig:2077` write check, construct a `DecisionRequest` with `action = .write`, `resource = .database` (or `.graph` if the call site has a graph in scope), and the request's Principal. Map the decision back to the legacy boolean check the surrounding code expects.

The line 1506 call uses `rbac.hasPermission(uid, requested_graph, "graph", .read)` — that's a different code path (graph-scoped read). Convert it to `gps.decide({.principal = ..., .action = .read, .resource = .{ .graph = requested_graph }})`.

- [ ] **Step 3: Add a regression test** — write a tiny test that exercises an unauthorized write through a synthesized DecisionRequest and asserts deny.

- [ ] **Step 4: Build + test** — green.

- [ ] **Step 5: Commit** — `refactor(gps): gRPC permission checks now go through gps.decide()`

---

### Task 2-8: Close fail-open site #4 — RLS VM no-result returns `error.IndeterminatePolicy`

**Files:**
- Modify: `src/security/rls_core.zig`
- Modify: `src/execution/match_operations.zig` (the call site at line ~125-130 that consumes the VM result)
- Modify: `src/security/gps.zig` (decide() maps the new error to `.indeterminate` decision)

- [ ] **Step 1: Audit the current call sites**

Run `grep -rn "checkRowAccessByUsername\|evalExpression" src/ --include="*.zig" | head -20` to find every consumer of the VM result.

- [ ] **Step 2: Add a test** — a synthesized policy that produces no Boolean result must cause the consumer to deny (or skip) the row.

- [ ] **Step 3: Convert the VM no-result return** — change `return true;` (the path tagged with `REQ-GPS-INVARIANT-001` ASPECT=FailOpenInterim CANARY) to `return error.IndeterminatePolicy`. Update the CANARY `STATUS=EXEMPT` → `STATUS=COMPLETE`.

- [ ] **Step 4: Update every consumer** — convert the consumers that previously got a `bool` to `!bool` and explicitly map `error.IndeterminatePolicy` to a deny outcome.

- [ ] **Step 5: Run full test suite** — `zig build test`. The RLS expr-wiring test (`tests/test_rls_expr_engine_wiring.zig`) must still pass; if any policy that previously passed now fails, it means there's a real malformed policy that was being silently allowed — investigate and fix that policy.

- [ ] **Step 6: Commit** — `fix(gps): RLS VM no-result is now IndeterminatePolicy, not implicit allow`

---

### Task 2-9: Add explicit `--insecure-allow-all` flag

**Files:**
- Modify: `src/security/user_management.zig` (or a new small module) — add `setInsecureAllowAll(b: bool)` + `isInsecureAllowAll() bool` accessor pair, default false.
- Modify: `src/security/gps.zig` — `insecureAllowAllEnabled()` consults the accessor.
- Modify: `src/server/cli_args.zig` — parse `--insecure-allow-all` and call `setInsecureAllowAll(true)` at startup if present. Emit a `WARN` log line.
- Modify: `src/security/user_management.zig` `isAuthEnabled()` — Phase 0 site #1 CANARY flips to `STATUS=COMPLETE` once `decide()` no longer treats `!isAuthEnabled()` as implicit allow.

- [ ] **Step 1: Tests**

A test that sets `insecure_allow_all = true` and runs `gps.decide()` on an empty principal must return `.allow` with `reason_code = "insecure_allow_all"`.

A test that sets `insecure_allow_all = false` (the default) and does the same must return `.unauthenticated`.

- [ ] **Step 2: Implement the flag, accessor, and CLI parsing.**

- [ ] **Step 3: Update `decide()`** — the first branch becomes:

```zig
if (insecureAllowAllEnabled()) return PolicyDecision{ .kind = .allow, .reason_code = "insecure_allow_all", ... };
```

This replaces Task 2-6's temporary stub.

- [ ] **Step 4: Confirm legacy "auth disabled" behavior is unchanged** — `make build && zig build test`. Tests that ran without auth before must continue to pass (because the CLI now sets the flag implicitly when auth is disabled, OR — better — the tests explicitly call `setInsecureAllowAll(true)` in their setup).

  **Decision point during implementation:** if the project's test fixture default is "auth disabled", do the tests need to opt-in explicitly to `insecure_allow_all`? Read `tests/test_user_management.zig` and the test harness setup to decide.

- [ ] **Step 5: Commit** — `feat(gps): explicit --insecure-allow-all flag replaces implicit auth-disabled branch`

---

### Task 2-10: Audit & document `call_operations.zig:145` ExecutionContext usage

**Files:**
- Read-only audit of `src/execution/call_operations.zig`.
- If a production path is found: modify it to thread Principal through.
- Either way: append a sentence to `docs/security/gps-principal.md` noting the outcome.

- [ ] **Step 1: Read `src/execution/call_operations.zig` line 145 and its surrounding function.**

Determine whether the `ExecutionContext{ .catalog = catalog }` literal is hit only from tests (current assumption) or from any production path. Look at all callers of the containing function.

- [ ] **Step 2: If production-reachable:** add Principal threading. If test-only: leave as-is.

- [ ] **Step 3: Document the outcome** in `docs/security/gps-principal.md` (append to the "Compatibility" section).

- [ ] **Step 4: Commit** — `audit(gps): document call_operations.zig:145 ExecutionContext usage`

---

### Task 2-11: Decision-engine end-to-end test

**Files:**
- Modify: `tests/test_gps_decide.zig`

- [ ] **Step 1: Write an E2E scenario test** — start an `ExecutionContext` with a built Principal (using `derivePrincipal()`), call `execution.checkPermission` AND `gps.decide` for the same action, and assert they agree (allow=allow, deny=deny). Iterate across all four builtin roles, both Read and Write permissions, with and without a bound graph.

- [ ] **Step 2: Build + run** — green.

- [ ] **Step 3: Commit** — `test(gps): e2e parity between checkPermission and decide()`

---

### Task 2-12: Black-box geodetestlab spec for `decide()`-observable behavior

**Files:**
- Create: `../geode-test-harness/geodetestlab-cli/specs/gps_decide_smoke.yml` (in the sibling harness repo).

- [ ] **Step 1: Pattern-match an existing spec** — read `../geode-test-harness/geodetestlab-cli/specs/shell_enterprise_tests.yml` (or another spec touching auth) to learn the actual harness DSL (cli config, secrets, invariants, tests with args).

- [ ] **Step 2: Write a real spec** — at minimum:
  1. Create a `ReadOnly`-role user.
  2. Authenticate as that user, attempt `CREATE (n:X)`, expect exit code != 0 and error message containing the legacy "Unauthorized" class.
  3. Drop the user in teardown.

  The point is to prove `decide()` produces the SAME observable failure as the legacy path. Phase 2 makes no UX-visible change.

- [ ] **Step 3: Run** — `cd ../geode-test-harness && make test-spec SPEC=geodetestlab-cli/specs/gps_decide_smoke.yml GEODE_BINARY=$(realpath ../geode/zig-out/bin/geode)`.

- [ ] **Step 4: Commit in the harness repo** — `cd ../geode-test-harness && git add ... && git commit -m "test(gps): black-box smoke for decide() outcomes match legacy"`

---

### Task 2-13: Cleanup, conventions doc, and `AttributeMap.get()` final decision

**Files:**
- Create: `docs/security/gps-canary-conventions.md`
- Create: `docs/security/gps-decide.md`
- Possibly modify: `src/security/principal.zig` (if `AttributeMap.get()` is removed)

- [ ] **Step 1: Write `docs/security/gps-canary-conventions.md`** — document the convention discovered in Phase 0: the canary normalizer strips non-standard fields like `SITE=`, so the cross-reference between source CANARY markers and the fail-open catalog uses the shared `REQ=REQ-GPS-INVARIANT-001` ID plus the `ASPECT=` tag. Catalog rows enumerate the sites by `ASPECT`.

- [ ] **Step 2: Write `docs/security/gps-decide.md`** — Phase 2 outcome doc covering: the new types, the deterministic evaluation order, what bit-identically matches the legacy path, what intentionally changed (the two fail-closed conversions in sites #1 and #4), how to read decisions in Phase 3+ code, what remains in `--insecure-allow-all` compat mode.

- [ ] **Step 3: `AttributeMap.get()` decision**

If Tasks 2-1..2-11 ended up using `AttributeMap.get()` anywhere (e.g., for an ABAC predicate that reads an attribute), leave it in. If not, REMOVE it — Phase 1 left it as dead code on the bet Phase 2 would consume it; if that bet was wrong, the YAGNI fix is to remove it now. Update `tests/test_gps_principal.zig` if any test asserted its existence.

- [ ] **Step 4: Final markdown pass on all docs/security/gps-*.md** — make sure cross-references resolve and Phase 2's outcome aligns with `gps-invariants.md`.

- [ ] **Step 5: Commit** — `docs(gps): Phase 2 outcome, canary conventions, and dead-code cleanup`

---

## Final Verification

- [ ] **Step 1: Full build + test** — `make build && zig build test`. Pre-existing flake (`test_sharded_coordinator_hub_regression`, GAP-825) may still surface — note but do not fix in this plan.

- [ ] **Step 2: CANARY governance** — `grep -rn "REQ-GPS" src/ tests/ docs/ | wc -l` should be ≥ 30 markers. The Phase 0 `REQ-GPS-INVARIANT-001` entries on sites #1 and #4 should now show `STATUS=COMPLETE`.

- [ ] **Step 3: Smoke** — manual end-to-end query through the running server using an authenticated session. Run `./zig-out/bin/geode serve --listen 127.0.0.1:31410 &` and a query as a `ReadOnly` user attempting `CREATE` — must still fail in the same error class as before Phase 2.

- [ ] **Step 4: Fail-open catalog sync** — `docs/security/gps-fail-open-sites.md` must show sites #1 and #4 as CLOSED, with the closing commit SHA linked. Sites #2, #3, #5, #6, #7, #8, #9 remain.

---

## Phase 3+ Preview (NOT part of this plan)

For maintainer planning:

- **Phase 3 (Tenant + graph non-bypassable enforcement):** make `decide()` reject any action that crosses tenant or active-graph boundaries unless explicitly authorized. Tightens metadata and storage surfaces. Closes fail-open sites #6, #7.
- **Phase 4 (Policy DDL + persistent catalog):** real `CREATE POLICY`, `ALTER POLICY`, etc. Stores policies in `__geode_security`. Closes fail-open sites #2, #3.
- **Phase 5 (Procedure, MCP, LSP, FLE hardening):** mandatory `EXECUTE_PROCEDURE` decision. Per-caller principal threading inside MCP tools. `DECRYPT_FIELD` and `UNWRAP_KEY` as explicit actions. Closes fail-open sites #5, #8, #9.
- **Phase 6 (Distributed envelope):** principal + `policy_version` propagated to shard workers.
- **Phase 7 (Cache + perf):** decision cache keyed by `(principal.auth_version, policy_version, action, resource_id)`, sub-5µs cached decisions. Audit dashboards.

Each becomes its own plan when prerequisites land.

---

## Carry-forward findings checklist (close-out at end of Phase 2)

These were the explicit Phase 0+1 findings that this plan was asked to address. Verify each is closed:

- [ ] **Three-transport Principal duplication** — Task 2-2 + 2-3.
- [ ] **`AttributeMap.get()` YAGNI** — Task 2-13 Step 3 (use OR remove).
- [ ] **`call_operations.zig:145` audit** — Task 2-10.
- [ ] **`SITE=` field stripped by normalizer** — Task 2-13 Step 1.
- [ ] **Geodetestlab smoke spec deferred from Phase 1** — Task 2-12.
- [ ] **Fail-open site #1 (auth-disabled)** — Task 2-9.
- [ ] **Fail-open site #4 (RLS VM no-result)** — Task 2-8.
- [ ] **Phase 1's `auth_version = 0` hardcoding** — already closed by `9654cde6`; Task 2-2's helper carries it forward.

Phase 2 leaves fail-open sites #2, #3, #5, #6, #7, #8, #9 OPEN — they're explicitly Phase 3+ territory.
