# GPS Phase 5 — Procedure / MCP / FLE Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Close the three remaining low-blast-radius fail-open sites by routing procedure dispatch, MCP tool calls, and FLE decrypt operations through `gps.decide()`. Closes fail-open sites #5 (procedure classifier unused), #8 (MCP bearer-only), and #9 (FLE hook-local role check). Also adds real expression compilation to the policy catalog so policies can carry meaningful predicates beyond the `"true"` placeholder.

**Architecture:** Three independent enforcement migrations + one cross-cutting feature:

1. **Procedure enforcement** (`src/execution/procedure_registry.zig`): The dispatch path consults `procedure_access.zig`'s classifier to determine the procedure's action class (READ/WRITE/SCHEMA), then calls `gps.decide(.execute_procedure, .{ .procedure = name })` before executing the procedure body. Bit-identical legacy outcomes preserved for admin/non-admin paths.

2. **MCP per-caller principal** (`src/mcp/server.zig` + `src/mcp/tools.zig`): MCP tools that perform queries derive a per-caller Principal (rather than using the process-wide bearer-authenticated client) and attach it to the underlying ExecutionContext. Phase 5 supports a single MCP user identity (mapped from the bearer token); multi-user MCP is Phase 6+.

3. **FLE explicit actions** (`src/execution/fle_hooks.zig`): The decrypt and key-unwrap paths call `gps.decide(.decrypt_field, .{ .property = ... })` and `gps.decide(.unwrap_key, .{ .key = ... })` before performing the operation. `decide()` gains evaluation for these two new actions (Phase 5 keeps them simple: admin allowed, others require explicit policy match).

4. **Real expression compilation** (`src/security/policy_catalog.zig` + `src/security/rls_core.zig`): The Phase 4 placeholder `expression_source = "true"` is replaced with real compilation through the existing RLS VM. When `addPolicy` is called with non-`"true"` source, the catalog calls `rls_core.compileExpression(source)` and stores the bytecode. `decide()`'s policy match step evaluates the bytecode against the principal+resource context. Expression syntax stays minimal: `current_user()`, `current_tenant()`, `current_graph()`, `resource.label`, `resource.property("name")`, and basic equality/AND/OR.

**Tech Stack:** Zig 0.16.0+, CANARY governance (`REQ=REQ-GPS-PROC-*`, `REQ=REQ-GPS-MCP-*`, `REQ=REQ-GPS-FLE-*`, `REQ=REQ-GPS-EXPR-*`).

**Reference design:** `docs/geode-policy-plan.md` — sections on procedure access, MCP/LSP, FLE.

**Reference foundation:** `docs/security/gps-invariants.md`, `docs/security/gps-fail-open-sites.md` (sites #5, #8, #9), `docs/security/gps-policy-ddl.md`.

---

## Carry-forward from Phase 4

1. **Expression compilation pipeline** — Phase 4 left `expression_source = "true"` as the only supported predicate. Phase 5 task 5-7 closes this.

---

## File Structure

**Modify:**
- `src/security/gps.zig` — Add `Action.execute_procedure` evaluation (admin allow, others via policy), `Action.decrypt_field`, `Action.unwrap_key`.
- `src/execution/procedure_registry.zig` — Insert `gps.decide(.execute_procedure)` before dispatch.
- `src/execution/procedure_access.zig` — Confirm or extend the classifier to map procedure name → action class.
- `src/mcp/server.zig` — Derive a per-caller Principal from the bearer token at connection acceptance. Attach to subsequent tool-call execution contexts.
- `src/mcp/tools.zig` — Each tool that runs queries threads the per-caller Principal through. (If the file doesn't exist as-is in current main, locate the analogue.)
- `src/execution/fle_hooks.zig` — Decrypt path calls `gps.decide(.decrypt_field)`; key-unwrap path calls `gps.decide(.unwrap_key)`.
- `src/security/policy_catalog.zig` — Add `compiled_expression: ?CompiledExpression` field; `addPolicy` compiles when `expression_source != "true"`. Cache the compiled bytecode.
- `src/security/rls_core.zig` (or a new `src/security/policy_expression.zig`) — Wrap the existing RLS VM with a `compileExpression` + `evaluateExpression(principal, resource)` pair tailored to policy semantics.
- `docs/security/gps-fail-open-sites.md` — Mark sites #5, #8, #9 CLOSED.

**Create:**
- `src/security/policy_expression.zig` — A thin adapter over `rls_core`'s VM that exposes a `PolicyEvalContext` with builtins for policy evaluation (current_user(), current_tenant(), current_graph(), resource.label, resource.property("name")).
- `tests/test_gps_procedure_enforcement.zig` — Tests covering admin allow, ReadOnly denied for write procedures, classifier-driven action mapping.
- `tests/test_gps_mcp_principal.zig` — Tests for per-caller MCP principal derivation (decision-layer only).
- `tests/test_gps_fle_enforcement.zig` — Tests for decrypt/unwrap action denial.
- `tests/test_gps_policy_expression.zig` — Tests for compile + eval of simple predicates like `resource.label = 'Employee'` and `current_user() = 'alice'`.
- `docs/security/gps-phase5-outcome.md` — Phase 5 outcome doc.

**Out of scope:**
- Multi-user MCP (defer to Phase 6+).
- ABAC predicate map / `principal.attributes.X` access (defer to Phase 6).
- Distributed envelope policy-version propagation (Phase 6).
- Decision cache (Phase 7).

---

## Phase 5 Tasks

### Task 5-1: Procedure registry `EXECUTE_PROCEDURE` decision

**Files:** `src/execution/procedure_registry.zig`, `src/security/gps.zig`, `tests/test_gps_procedure_enforcement.zig`

- [ ] **Step 1: Locate the dispatch site**

```bash
grep -n "fn executeCallProcedure\|REQ-GPS-INVARIANT-001\|procedure_access\|fn execute" src/execution/procedure_registry.zig | head -10
grep -n "isReadOnly\|isMutating\|classify" src/execution/procedure_access.zig | head -10
```

Identify the function that the dispatch path lands on, and the classifier API.

- [ ] **Step 2: Add `.execute_procedure` evaluation in `src/security/gps.zig`**

```zig
    if (req.action == .execute_procedure) {
        // Admin always allowed
        for (req.principal.roles) |role_name| {
            if (std.mem.eql(u8, role_name, "Admin")) {
                return PolicyDecision{ .kind = .allow, .reason_code = "execute_procedure_admin" };
            }
        }
        // Other users: defer to standard role evaluation
        // (read-only procedures map to .read, mutating to .write — see Task 5-1 step 4 in registry)
    }
```

- [ ] **Step 3: Write failing test**

```zig
test "decide(.execute_procedure) allows Admin" { ... }
test "decide(.execute_procedure) denies ReadOnly when procedure is mutating" { ... }
```

- [ ] **Step 4: Insert the gate in `procedure_registry.zig`**

Before dispatching to the procedure body, do:

```zig
    if (context.principal) |p| {
        const access_class = procedure_access.classify(procedure_name); // returns .read_only | .mutating | .unknown
        const action_for_proc: gps.Action = switch (access_class) {
            .read_only => .read,
            .mutating => .write,
            .unknown => .execute_procedure,
        };
        const req = gps.DecisionRequest{
            .principal = p,
            .action = action_for_proc,
            .resource = .{ .procedure = procedure_name },
        };
        const decision = try gps.decide(std.heap.smp_allocator, &req);
        if (decision.kind != .allow) return error.Unauthorized;
    }
```

If `procedure_access.classify` doesn't exist exactly with that signature, search for the actual API (it's around lines 1-116 of `src/execution/procedure_access.zig` per the invariants doc) and adapt.

- [ ] **Step 5: Flip CANARY**

The Phase 0 `REQ-GPS-INVARIANT-001 ASPECT=ClassifierUnused` CANARY in `src/execution/procedure_registry.zig` flips from `STATUS=EXEMPT` to `STATUS=COMPLETE`.

- [ ] **Step 6: Build + test + commit**

```bash
make build
zig build test-gps-procedure-enforcement
zig build test-gps-decide
git commit -m "feat(gps): mandatory decide(.execute_procedure) before procedure dispatch"
```

---

### Task 5-2: MCP per-caller principal derivation

**Files:** `src/mcp/server.zig`, `src/mcp/tools.zig` (or analogous), `tests/test_gps_mcp_principal.zig`

- [ ] **Step 1: Inspect current MCP auth**

```bash
sed -n '1,80p' src/mcp/server.zig
grep -n "bearer\|Bearer\|authorization\|tool_call\|callTool" src/mcp/server.zig src/mcp/tools.zig 2>/dev/null | head -10
```

Understand how the bearer token is validated and where tool calls dispatch.

- [ ] **Step 2: Derive a Principal at connection acceptance**

When the bearer token is validated, also resolve the corresponding user's role + auth_version and construct a Principal via `principal_derive.derivePrincipal(.{ ..., .source = .mcp_handler })`. Attach to per-connection state.

- [ ] **Step 3: Thread the Principal through tool calls**

Each tool that runs a query needs to populate `ExecutionContext.principal` with the per-connection Principal. Update the tool dispatch code accordingly.

- [ ] **Step 4: Write tests**

A decision-layer test for `Principal{ .source = .mcp_handler }` flowing through `decide()` and yielding the expected outcome for a non-admin MCP user.

- [ ] **Step 5: Build + test + commit**

```bash
git commit -m "feat(gps): MCP derives per-caller Principal and threads through tool calls"
```

---

### Task 5-3: FLE explicit DECRYPT_FIELD / UNWRAP_KEY decisions

**Files:** `src/execution/fle_hooks.zig`, `src/security/gps.zig`, `tests/test_gps_fle_enforcement.zig`

- [ ] **Step 1: Locate the decrypt and unwrap-key sites**

```bash
grep -n "decrypt\|unwrap\|tenant\|role\|encryption_context" src/execution/fle_hooks.zig | head -20
```

- [ ] **Step 2: Add `.decrypt_field` and `.unwrap_key` evaluation in `decide()`**

For Phase 5, the simplest correct behavior: admin allow, others denied unless a matching `(:Policy)` row exists with the action. Phase 6+ adds key grants.

```zig
    if (req.action == .decrypt_field or req.action == .unwrap_key) {
        for (req.principal.roles) |role_name| {
            if (std.mem.eql(u8, role_name, "Admin")) {
                return PolicyDecision{ .kind = .allow, .reason_code = "fle_admin" };
            }
        }
        // Fall through to policy-catalog evaluation (Phase 4 step) which may grant
    }
```

- [ ] **Step 3: Insert the gate in fle_hooks**

Before decrypting / unwrapping, call `gps.decide()`. On denial, return the same `[REDACTED]` placeholder the legacy code returns (to preserve compat behavior).

- [ ] **Step 4: Write tests** verifying Admin allowed, non-admin denied, policy-granted allowed.

- [ ] **Step 5: Build + test + commit**

```bash
git commit -m "feat(gps): explicit decide(.decrypt_field/.unwrap_key) in fle_hooks"
```

---

### Task 5-4: Real expression compilation in policy_catalog

**Files:** `src/security/policy_expression.zig` (new), `src/security/policy_catalog.zig`, `tests/test_gps_policy_expression.zig`

- [ ] **Step 1: Locate the RLS VM compile/eval functions**

```bash
grep -n "pub fn compile\|pub fn eval\|CompiledExpression" src/security/rls_core.zig | head -10
```

The existing RLS VM has compilation and evaluation. We're wrapping it.

- [ ] **Step 2: Create `src/security/policy_expression.zig`**

```zig
const std = @import("std");
const rls_core = @import("rls_core.zig");

pub const PolicyEvalContext = struct {
    current_user: ?[]const u8,
    current_tenant: ?[]const u8,
    current_graph: ?[]const u8,
    resource_label: ?[]const u8,
    // resource property accessor — Phase 5: simple key-value map
    resource_properties: []const struct { key: []const u8, value: []const u8 } = &.{},
};

pub fn compileExpression(allocator: std.mem.Allocator, source: []const u8) !rls_core.CompiledExpression {
    // Phase 5: delegate to rls_core.compile or hand-write a minimal parser
    // for the supported subset: current_user() = 'x', resource.label = 'X', AND, OR
    return try rls_core.compileExpressionFromSource(allocator, source);
}

pub fn evaluate(expr: *const rls_core.CompiledExpression, ctx: PolicyEvalContext) !bool {
    // Inject ctx fields into the VM environment and run
    return try rls_core.evaluateWithContext(expr, ctx);
}
```

If the RLS VM API doesn't quite match — particularly if `compileExpressionFromSource` is not directly exposed — write a thin parser for the supported subset (literal string comparisons, AND, OR) that emits the same bytecode shape the existing VM uses. The "minimal" target: `resource.label = 'X'` and `current_user() = 'Y'` only. More complex expressions are Phase 6+.

- [ ] **Step 3: Update `policy_catalog.zig`**

Add `compiled_expression: ?*rls_core.CompiledExpression = null` to Policy. In `addPolicy`, if `expression_source != "true"`, compile and store the result.

- [ ] **Step 4: Update `decide()`'s policy match step**

For policies with non-null `compiled_expression`, build a `PolicyEvalContext` from req.principal+resource and call `policy_expression.evaluate`. If result is `true`, return allow; if `false`, continue (no match).

- [ ] **Step 5: Tests**

Cover: `expression_source = "current_user() = 'alice'"`, `expression_source = "resource.label = 'Employee'"`, AND/OR combinations.

- [ ] **Step 6: Build + test + commit**

```bash
git commit -m "feat(gps): real expression compilation for policy predicates"
```

---

### Task 5-5: Close fail-open sites #5, #8, #9

**Files:** `docs/security/gps-fail-open-sites.md`, source CANARY updates.

- [ ] Mark all three as **CLOSED** with closing commits. Site #5 closes via Task 5-1; #8 via 5-2; #9 via 5-3.

- [ ] Source CANARY markers for these sites flip from `STATUS=EXEMPT` to `STATUS=COMPLETE`.

- [ ] Commit — `docs(gps): close fail-open sites #5, #8, #9`

---

### Task 5-6: Phase 5 outcome doc

**Files:** `docs/security/gps-phase5-outcome.md` (new)

- [ ] Document Phase 5: procedure enforcement, MCP principal threading, FLE actions, real expression compilation. List which fail-open sites closed. Phase 6 handoff (distributed envelope + ABAC + decision cache).

- [ ] Commit — `docs(gps): Phase 5 outcome — procedure/MCP/FLE hardening`

---

## Final Verification

- [ ] `make build && zig build test`.
- [ ] All three sites #5/#8/#9 marked CLOSED.
- [ ] CANARY count ≥ 280.
- [ ] Smoke: invoke a mutating procedure as ReadOnly user — must fail with Unauthorized.
