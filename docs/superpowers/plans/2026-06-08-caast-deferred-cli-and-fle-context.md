# CaaST Deferred: `geode tenant` CLI + FLE Role Context Binding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two explicitly-deferred pieces of the f26c9110 CaaST findings: (1) GAP-0839's `geode tenant` CLI subcommand (the CALL surface + registry already exist), and (2) GAP-0844's secondary — make the FLE role flow through `ExecutionContext` (not just the OS thread) so a future async executor stays correct.

**Architecture:** Task 1 adds a thin CLI front-end (`src/cli/tenant_cli.zig`) that CONNECTS to a running server and issues `CALL geode.tenant.<op>(...)` — reusing the existing dispatch (`tenant_dispatch.zig`), durable registry, and `admin_tenant` authz; zero new business logic. Task 2 adds an optional `fle_role` field to `ExecutionContext`, sets it at the request boundary that already sets the per-thread role, and has `getCurrentUserRole` prefer the context, falling back to the per-thread map (so the current synchronous path is byte-for-byte unchanged).

**Tech Stack:** Zig 0.16, the geode CLI dispatcher (`src/cli/cli_dispatcher.zig`), the QUIC/gRPC client used by `geode query`/`user`/`role`, `zig build` test steps.

---

## Tasks are independent (CLI vs execution-context) — safe to do in either order.

---

### Task 1: `geode tenant` CLI subcommand (GAP-0839)

**Files:**
- Create: `src/cli/tenant_cli.zig` (`cmdTenant`)
- Modify: `src/cli/cli_dispatcher.zig` (register `tenant` in the commands table + help)
- Test: `tests/test_gap0839_tenant_cli.zig` + wire `test-gap0839-tenant-cli` in `build.zig`

**Pre-flight reads (the implementer MUST do these before coding — copy the exact pattern, don't invent):**
- [ ] **R1:** Read `src/cli/user_mgmt_cli.zig` `cmdUser` end-to-end: how it parses argv/subcommands, how it builds the connection (DSN/`--user`/`--password`/`--insecure-tls-skip-verify` flags), how it issues a query/CALL to the server, how it prints rows, and how it returns exit codes + errors. The `tenant` CLI MUST mirror this exactly (same client, same flag parsing, same error/exit conventions). Note the exact client API used to run a query string.
- [ ] **R2:** Read `src/execution/tenant_dispatch.zig` `execute(...)` to confirm the CALL names + arg shapes: `geode.tenant.create(tenant_id[, parent])`, `geode.tenant.list()`, `geode.tenant.show(tenant_id)`, `geode.tenant.drop(tenant_id)`, `geode.tenant.set_quota(tenant_id, max_connections, max_concurrent_queries, max_graphs, max_nodes_per_graph)` and the YIELD columns each returns — so the CLI prints the right columns.
- [ ] **R3:** Read `src/cli/cli_dispatcher.zig` around the commands table (`.{ .name = "user", .handler = cmdUser, .description = "Manage users" }`, ~line 184) and how handlers are imported/re-exported (e.g. `pub const cmdUser = user_mgmt_cli.cmdUser;` ~line 89). Replicate that for `cmdTenant`.

- [ ] **Step 1: Write the failing test** (`tests/test_gap0839_tenant_cli.zig`)

The CLI connects to a server, so a full e2e test needs a running server (out of scope for a unit test). Instead, test the **arg-parsing + CALL-string construction** layer: factor the CLI's "build the `CALL geode.tenant.<op>(...)` query string from argv" into a pure function `pub fn buildTenantCallQuery(allocator, args: []const []const u8) ![]const u8` in `tenant_cli.zig`, and unit-test THAT (deterministic, no server). Test:
```zig
const std = @import("std");
const tenant_cli = @import("../src/cli/tenant_cli.zig");
test "tenant create builds CALL geode.tenant.create with id + parent" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "create", "acme", "--parent", "root" });
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "CALL geode.tenant.create(") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "'acme'") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "'root'") != null);
}
test "tenant list builds CALL geode.tenant.list()" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{"list"});
    defer a.free(q);
    try std.testing.expectEqualStrings("CALL geode.tenant.list()", q);
}
test "tenant set-quota maps flags to positional args in dispatch order" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "set-quota", "acme", "--max-connections", "10", "--max-concurrent-queries", "4" });
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "CALL geode.tenant.set_quota('acme'") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "4") != null);
}
test "unknown subcommand is an error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownTenantSubcommand, tenant_cli.buildTenantCallQuery(a, &.{"frobnicate"}));
}
```
IMPORTANT: properly escape single quotes in tenant ids (reject or escape `'` to avoid query injection — the ids come from a trusted admin CLI but escape defensively). If `set_quota`'s dispatch requires all 4 quota positional args, default the unspecified ones to a sentinel the dispatch treats as "unchanged"/the registry default — confirm the dispatch's set_quota arity in R2 and match it (if it requires all 4, supply defaults for max_graphs/max_nodes_per_graph).

- [ ] **Step 2: Run it to verify it fails.** Run: `zig build test-gap0839-tenant-cli` → FAIL (`buildTenantCallQuery` undefined / module missing).

- [ ] **Step 3: Implement `src/cli/tenant_cli.zig`.** Implement `buildTenantCallQuery` (pure, tested above) + `pub fn cmdTenant(...)` that: parses the subcommand + the shared connection flags (mirroring `cmdUser` from R1), calls `buildTenantCallQuery`, opens the client connection the same way `cmdUser` does, runs the CALL query, prints the returned rows (columns per R2), and returns the same exit-code/error conventions as `cmdUser`. NO registry/authz logic here — the server's dispatch + admin_tenant gate handle that. Match `cmdUser`'s signature (allocator, argv, etc.) exactly so the dispatcher can call it.

- [ ] **Step 4: Register in `src/cli/cli_dispatcher.zig`.** Add `pub const cmdTenant = tenant_cli.cmdTenant;` next to the other re-exports (~line 89) with `const tenant_cli = @import("tenant_cli.zig");`, and add `.{ .name = "tenant", .handler = cmdTenant, .description = "Manage tenants (create/list/show/drop/set-quota) via CALL geode.tenant.*" }` to the commands table (~line 184). Add a help line if the dispatcher prints per-command help.

- [ ] **Step 5: Wire the test in `build.zig`** mirroring the existing `test-gap0840-strict-tenancy` step (a `b.addTest` on `tests/test_gap0839_tenant_cli.zig`, a `b.step("test-gap0839-tenant-cli", ...)`, and `shardDep(test_step, &run..., <idx>, ...)`). The test module imports `tenant_cli.zig` directly (it's a pure-function test) — set `link_libc` on it ONLY if cli imports require it (build it and see).

- [ ] **Step 6: Run + validate.** `zig build` clean; `zig build test-gap0839-tenant-cli` PASS; `GEODE_SKIP_SUBPROC_CLUSTER=1 CI=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=0` (and 1..3) no failures. Also a manual smoke (optional): boot a server, `./zig-out/bin/geode tenant list --dsn quic://127.0.0.1:PORT --insecure-tls-skip-verify --user geode --password <pw>` returns rows; an unauthorized user gets the admin_tenant denial.

- [ ] **Step 7: Commit.**
```bash
git add src/cli/tenant_cli.zig src/cli/cli_dispatcher.zig tests/test_gap0839_tenant_cli.zig build.zig
git commit -m "feat(cli): geode tenant subcommand over CALL geode.tenant.* (GAP-0839)"
```

---

### Task 2: FLE role flows through ExecutionContext (GAP-0844 secondary)

**Files:**
- Modify: `src/execution.zig` (`ExecutionContext` ~:463/:512 — add `fle_role`)
- Modify: `src/fle_integration.zig` (`getCurrentUserRole` prefers a passed/active context)
- Modify: the production request boundary that calls `fle_integration.setCurrentUserRole` (find it — see R4)
- Test: `tests/test_gap0844_role_context.zig` + wire `test-gap0844-role-context` in `build.zig`

**Pre-flight reads:**
- [ ] **R4:** Find the PRODUCTION caller of `fle_integration.setCurrentUserRole` (NOT the test callers at `fle_integration.zig:719/764/805`): `grep -rn "setCurrentUserRole" src/ | grep -v fle_integration.zig`. It is the QUIC/gRPC request/HELLO boundary that sets the per-thread role at the start of execution. Note where the `ExecutionContext` for that request is constructed (so you can set `ctx.fle_role` at the same point).
- [ ] **R5:** Read `fle_integration.getCurrentUserRole` (the current per-thread reader, ~:115 region) and count its call sites: `grep -rn "getCurrentUserRole" src/`. Determine which call sites have an `ExecutionContext` in hand (those can pass it) vs which don't (those keep the per-thread fallback).

- [ ] **Step 1: Write the failing test** (`tests/test_gap0844_role_context.zig`)
```zig
const std = @import("std");
const geode = @import("geode");
const fle = geode.fle_integration;
const exec = geode.execution; // confirm the import name for ExecutionContext in R4/R5
test "GAP-0844: getCurrentUserRole prefers ExecutionContext fle_role over per-thread" {
    // Per-thread says "thread_role"; the context says "ctx_role"; context wins.
    fle.setCurrentUserRole("thread_role");
    defer fle.clearCurrentThreadState();
    var ctx: exec.ExecutionContext = .{ .fle_role = "ctx_role" };
    try std.testing.expectEqualStrings("ctx_role", fle.getCurrentUserRoleCtx(&ctx).?);
    // With no context (null), falls back to the per-thread map (unchanged behavior).
    try std.testing.expectEqualStrings("thread_role", fle.getCurrentUserRole().?);
    // A context with null fle_role also falls back to per-thread.
    var ctx_empty: exec.ExecutionContext = .{};
    try std.testing.expectEqualStrings("thread_role", fle.getCurrentUserRoleCtx(&ctx_empty).?);
}
```
(Confirm the `ExecutionContext` field-init form + the `geode.execution`/`geode.fle_integration` import names against R4/R5; adjust the literal in the test to match. If `ExecutionContext` requires other fields to construct, build a minimal valid one.)

- [ ] **Step 2: Run it to verify it fails.** `zig build test-gap0844-role-context` → FAIL (`fle_role` field missing / `getCurrentUserRoleCtx` undefined).

- [ ] **Step 3: Add the field.** In `src/execution.zig` `ExecutionContext` (next to `tenant_id: ?[]const u8 = null` at ~:512): `fle_role: ?[]const u8 = null,` with a comment referencing GAP-0844 (request-scoped FLE role; falls back to the per-thread map when null).

- [ ] **Step 4: Add the context-preferring reader.** In `src/fle_integration.zig`, add `pub fn getCurrentUserRoleCtx(ctx: anytype) ?[]const u8 { if (@hasField(@TypeOf(ctx.*), "fle_role")) { if (ctx.fle_role) |r| return r; } return getCurrentUserRole(); }` (use `anytype` to avoid a circular import between fle_integration and execution; or import the concrete type if no cycle — check). Keep `getCurrentUserRole()` (per-thread) exactly as-is so the ~12 existing call sites are unchanged.

- [ ] **Step 5: Set `fle_role` at the request boundary.** At the production site found in R4 (where `setCurrentUserRole(role)` is called on a request), also set `ctx.fle_role = role` on that request's `ExecutionContext`. Then, at the FLE read sites that DO have a context (per R5), switch `getCurrentUserRole()` → `getCurrentUserRoleCtx(ctx)`. Sites WITHOUT a context keep `getCurrentUserRole()` (per-thread). Do the SMALLEST set of call-site changes that makes the context authoritative at the boundary — do not churn all 12 sites if they don't have a context.

- [ ] **Step 6: Run + validate.** `zig build` clean; `zig build test-gap0844-role-context` PASS; `zig build test-gap0844` (the existing GAP-0844 test) still PASS; FLE/tenancy tests green; `GEODE_SKIP_SUBPROC_CLUSTER=1 CI=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=0..3` no failures.

- [ ] **Step 7: Commit.**
```bash
git add src/execution.zig src/fle_integration.zig tests/test_gap0844_role_context.zig build.zig <the-boundary-file>
git commit -m "fix(fle): thread FLE role through ExecutionContext, fall back to per-thread (GAP-0844 secondary)"
```

---

### Task 3: Validate + merge to main

- [ ] `GEODE_SKIP_SUBPROC_CLUSTER=1 CI=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=0..3` all green (ignore the known load-sensitive perf-flake binaries — rerun serially to confirm).
- [ ] `git branch -f main HEAD && git push origin main` — the full pre-push gate (cross-compile + sharded tests + CANARY + match-parity + canaryscan + no-feature-flags) must pass. NOTE the no-feature-flags hook forbids `const feature_<x> =` — don't name a const `feature_*`.
- [ ] Update `docs/GAP_ANALYSIS.md` / the findings doc: GAP-0839 CLI surface now shipped; GAP-0844 secondary now has the context-binding first step (full async-executor migration still future).

## Notes / scope guards
- Task 1 adds NO business logic — it is a client front-end over the existing authorized CALL surface. If R1 shows `cmdUser` operates on a LOCAL data dir instead of connecting to a server, mirror THAT instead (but the admin_tenant authz lives server-side, so a connecting client is strongly preferred; if local-only, the CLI must still go through the same registry + an authz check — flag this in the implementer's report).
- Task 2 is intentionally the SMALL first step, not the full executor refactor. The per-thread path stays the default; the context becomes authoritative only where a context is threaded. Do not attempt to remove the per-thread maps.
