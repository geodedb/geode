# GPS Phase 6 — Distributed Envelope + ABAC + Grant Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`.

**Goal:** Propagate Principal + policy_version through distributed execution envelopes; introduce a minimal ABAC attribute model on the Principal; migrate legacy `graph_grant_check_fn` widening into first-class Policy rows so Phase 4's Site #2 PARTIAL can move to CLOSED.

**Architecture:**

1. **`policy_version` global counter** in `policy_catalog.zig`: incremented atomically on every `addPolicy` / `removePolicy`. Surfaces via `getPolicyVersion() u64`. Future decision cache (Phase 7) will key on this.

2. **Distributed envelope**: When the coordinator dispatches a shard fragment, it serializes the originating Principal's identity-bearing fields + the current `policy_version`. The shard worker receives the envelope, reconstructs a Principal via `principal_derive.derivePrincipal(.{ ..., .source = .distributed_worker })`, and refuses execution if the local `policy_version` differs from the envelope's (forces shard to re-sync catalog before execution).

3. **ABAC attribute map**: Extend the Principal's `attributes` field to be populated from authenticated user record. Add new expression syntax `principal.attributes.<key>` (e.g., `principal.attributes.department`). Policies can then express `principal.attributes.department = 'engineering'`.

4. **Grant migration**: A one-shot startup task that reads existing `(:GraphGrant)` nodes from `__geode_security` and inserts equivalent `(:Policy)` rows. Legacy `graph_grant_check_fn` continues to widen for back-compat (kept as a fallback for now); migrated grants ALSO live as Policy rows. Site #2 transitions to CLOSED after this migration, with a deprecation path for the legacy widening (removed in Phase 7).

5. **MCP wire forwarding closure**: Geode wire protocol extended with an optional `principal_envelope` field. When MCP server forwards a tool call to the local executor, it sets this field. The QUIC handler unpacks it. Closes Site #8 fully.

**Tech Stack:** Zig 0.16.0+, CANARY governance (`REQ=REQ-GPS-DIST-*`, `REQ=REQ-GPS-ABAC-*`, `REQ=REQ-GPS-MIGRATE-*`, `REQ=REQ-GPS-MCP-WIRE-*`).

**Reference design:** `docs/geode-policy-plan.md` — distributed, ABAC, MCP sections.

---

## Carry-forward from Phase 5

1. **Multi-user MCP / wire forwarding** — closes Site #8 fully.
2. **Migration of legacy graph grants to Policy rows** — closes Site #2 fully.

---

## File Structure

**Create:**
- `src/security/policy_version.zig` — Global atomic counter + accessors.
- `src/distributed/principal_envelope.zig` — Serialization of Principal identity-bearing fields for cluster RPCs.
- `src/security/grant_migration.zig` — One-shot startup task to migrate `(:GraphGrant)` → `(:Policy)`.
- `tests/test_gps_policy_version.zig` — Counter invariants.
- `tests/test_gps_distributed_envelope.zig` — Envelope round-trip + version-mismatch rejection.
- `tests/test_gps_abac_predicates.zig` — `principal.attributes.X` predicate evaluation.
- `tests/test_gps_grant_migration.zig` — Migration round-trip.
- `docs/security/gps-phase6-outcome.md` — Phase 6 outcome doc.

**Modify:**
- `src/security/policy_catalog.zig` — Increment policy_version on every mutation.
- `src/security/principal.zig` — `AttributeMap` becomes hash-map-backed (currently a slice); add `getEntry()` / `setEntry()` helpers. Phase 1's empty-sentinel pattern continues to work.
- `src/security/policy_expression.zig` — Parser gains support for `principal.attributes.<key>` and equality comparison against literals.
- `src/security/gps.zig` — `PolicyEvalContext` carries attribute map; evaluation passes through.
- `src/distributed/query_coordinator.zig` — Dispatch attaches `principal_envelope` to outbound shard RPC.
- `src/distributed/worker.zig` (or analogous shard worker file) — Receive envelope, reconstruct Principal, check policy_version, attach to ExecutionContext.
- `src/mcp/tools.zig` — In-process call sites set `ExecutionContext.principal` from the per-server Principal (closes the remaining Site #8 gap for in-process MCP-to-executor calls).
- `docs/security/gps-fail-open-sites.md` — Mark Sites #2 and #8 CLOSED.

**Out of scope:**
- Decision cache (Phase 7).
- ALTER POLICY (Phase 7).
- SHOW GRANTS FOR <user> (Phase 7).
- EXPLAIN POLICY (Phase 7).

---

## Phase 6 Tasks

### Task 6-1: `policy_version` global counter

**Files:** `src/security/policy_version.zig` (new), `src/security/policy_catalog.zig`, `tests/test_gps_policy_version.zig`, `build.zig`

- [ ] **Step 1: Create `src/security/policy_version.zig`**

```zig
const std = @import("std");

var g_policy_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn getPolicyVersion() u64 {
    return g_policy_version.load(.acquire);
}

pub fn incrementPolicyVersion() u64 {
    return g_policy_version.fetchAdd(1, .acq_rel) + 1;
}

pub fn resetPolicyVersionForTesting(v: u64) void {
    g_policy_version.store(v, .release);
}
```

- [ ] **Step 2: Wire into `src/security/policy_catalog.zig`**

After every `addPolicy` / `removePolicy` body, call `policy_version.incrementPolicyVersion()`.

- [ ] **Step 3: Wire into `src/lib.zig`**

- [ ] **Step 4: Write tests** — initial value 0; increments by 1 per mutation; concurrent increments are correct (use threads).

- [ ] **Step 5: Add build step; build + test + commit** — `feat(gps): atomic policy_version counter for cache invalidation`.

---

### Task 6-2: ABAC attribute map on Principal

**Files:** `src/security/principal.zig`, `src/security/policy_expression.zig`, `tests/test_gps_abac_predicates.zig`

- [ ] **Step 1: Extend `AttributeMap`** in `src/security/principal.zig`

The current `AttributeMap` is a `[]const Entry` slice (Phase 1 sentinel). For Phase 6, keep the slice representation but add a `lookup(key) ?[]const u8` helper. The map is small and lookup is linear — fine for Phase 6. (Phase 7 may upgrade to hashmap.)

- [ ] **Step 2: Extend parser in `policy_expression.zig`**

Add a new predicate variant `Predicate.eq_principal_attr: struct { key: []const u8, value: []const u8 }`. Parser recognises `principal.attributes.<identifier> = '<lit>'`.

- [ ] **Step 3: Extend `PolicyEvalContext`** to carry the attribute map (a slice of Entries).

- [ ] **Step 4: Update `gps.decide()`** to populate `attributes` field of PolicyEvalContext from `req.principal.attributes`.

- [ ] **Step 5: Write tests**

```zig
test "ABAC: principal.attributes.department = 'engineering' grants access" {
    // Build principal with attributes = [{department: engineering}]
    // Compile policy "principal.attributes.department = 'engineering'"
    // decide() returns allow with policy_match
}

test "ABAC: missing attribute → no match" { ... }
test "ABAC: wrong value → no match" { ... }
```

- [ ] **Step 6: Build + test + commit** — `feat(gps): ABAC predicates on Principal.attributes`.

---

### Task 6-3: Distributed principal envelope

**Files:** `src/distributed/principal_envelope.zig` (new), `src/distributed/query_coordinator.zig`, the shard-worker counterpart, tests

- [ ] **Step 1: Define the envelope schema**

```zig
pub const PrincipalEnvelope = struct {
    user_id: ?u64,
    username: ?[]const u8,
    roles: []const []const u8,
    tenant_id: ?[]const u8,
    active_graph: ?[]const u8,
    auth_version: u64,
    policy_version: u64,
    source: PrincipalSource,
    // Phase 6: omit attributes for now; Phase 7 if needed
};

pub fn serialize(allocator: std.mem.Allocator, env: PrincipalEnvelope) ![]u8 { ... }
pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !PrincipalEnvelope { ... }
```

Use the existing serialization conventions (protobuf, JSON, or whatever the cluster RPC uses today — check `src/distributed/protocol.zig` or similar).

- [ ] **Step 2: Coordinator attaches envelope to outbound RPC**

In `src/distributed/query_coordinator.zig`, when dispatching to a shard:

```zig
const envelope = principal_envelope.PrincipalEnvelope{
    .user_id = context.principal.?.user_id,
    .username = context.principal.?.username,
    .roles = context.principal.?.roles,
    .tenant_id = context.principal.?.tenant_id,
    .active_graph = context.principal.?.active_graph,
    .auth_version = context.principal.?.auth_version,
    .policy_version = policy_version.getPolicyVersion(),
    .source = .distributed_coordinator,
};
const env_bytes = try principal_envelope.serialize(allocator, envelope);
defer allocator.free(env_bytes);
// Attach to the outbound RPC
```

- [ ] **Step 3: Shard worker deserializes**

In the shard worker code path:

```zig
const local_pv = policy_version.getPolicyVersion();
if (envelope.policy_version != local_pv) {
    // Re-hydrate catalog from __geode_security
    try policy_persistence.hydrateCatalog(allocator, agm, getGlobalCatalog().?);
    if (policy_version.getPolicyVersion() != envelope.policy_version) {
        return error.PolicyVersionMismatch;
    }
}
const principal = principal_derive.derivePrincipal(.{
    .username = envelope.username,
    .role_names = envelope.roles,
    .tenant_id = envelope.tenant_id,
    .active_graph = envelope.active_graph,
    .auth_version = envelope.auth_version,
    .auth_method = .session_token, // best-effort tag
    .source = .distributed_worker,
});
const ctx = execution.ExecutionContext{
    .catalog = catalog,
    .principal = &principal,
    .tenant_id = envelope.tenant_id,
};
```

- [ ] **Step 4: Write round-trip + mismatch tests**

```zig
test "envelope serialize/deserialize round-trips all fields" { ... }
test "shard rejects request with stale policy_version" { ... }
```

- [ ] **Step 5: Build + test + commit** — `feat(gps): distributed Principal envelope with policy_version`.

If the distributed dispatch layer doesn't have an obvious "shard worker entry point" with a clear deserialization hook, scope-limit Phase 6-3 to just the envelope serialization + tests, and mark wire-level integration as Phase 7. Mark DONE_WITH_CONCERNS noting the structural deferral.

---

### Task 6-4: Grant migration to Policy rows

**Files:** `src/security/grant_migration.zig` (new), `src/server/main.zig` (call migration at startup), `tests/test_gps_grant_migration.zig`

- [ ] **Step 1: Locate existing GraphGrant nodes**

```bash
grep -n "GraphGrant\|graph_grant_nodes" src/security/auth_graph_manager.zig | head -10
```

The persistent grants live as `(:GraphGrant)` nodes (or in a `graph_grant_nodes` map). Find the read API.

- [ ] **Step 2: Implement migration**

```zig
pub fn migrateGraphGrantsToPolices(allocator: std.mem.Allocator, agm: *AuthGraphManager) !void {
    // Read all (:GraphGrant) nodes
    // For each, construct an equivalent Policy:
    //   name = "auto_migrated_grant_" ++ user ++ "_" ++ graph
    //   scope_graph = graph_name
    //   actions = [.read|.write|.schema based on grant action_code]
    //   effect = .allow
    //   expression_source = "current_user() = '<user>'"
    //   enabled = true
    // Call policy_persistence.persistPolicy()
}
```

Skip migration if the policy with the auto-generated name already exists (idempotent on restart).

- [ ] **Step 3: Wire at server startup**

In `src/server/main.zig`, after `wireGpsPolicyHooks`, call `grant_migration.migrateGraphGrantsToPolicies` once. Log how many grants were migrated.

- [ ] **Step 4: Tests**

```zig
test "grant migration: GraphGrant becomes a Policy with current_user() predicate" { ... }
test "grant migration: idempotent (running twice doesn't duplicate)" { ... }
test "grant migration: decide() allows via the migrated policy_match" { ... }
```

- [ ] **Step 5: Build + test + commit** — `feat(gps): migrate legacy graph grants to Policy rows`.

---

### Task 6-5: MCP wire forwarding closure for Site #8

**Files:** `src/mcp/tools.zig`, the QUIC client/server wire schema, tests

- [ ] **Step 1: Audit how MCP tools call the executor**

The Phase 5 implementer noted that `tools.callTool` accepts a `caller: *const Principal` but cannot forward it over the QUIC wire because the `zig_client` protocol doesn't have a principal field. Read `tools.zig` to confirm.

- [ ] **Step 2: Decide scope**

Two options:
1. **Local-only closure**: when MCP runs in-process with the executor (same Geode instance), the tools call into the local execution path directly (not via QUIC). In that case, set `ExecutionContext.principal = caller` and skip QUIC entirely. This closes Site #8 for the common case.
2. **Full wire closure**: extend the QUIC protocol with a `principal_envelope` field. This is significantly more work (protocol versioning, backward compatibility).

For Phase 6, do option (1). Document option (2) as Phase 7+ work if needed.

- [ ] **Step 3: Update `src/mcp/tools.zig`**

In `callTool`, instead of going through `GeodeClient.query(...)`, call the local executor path directly (e.g., `execution.executeProgramWithContext(allocator, &program, ctx)` where `ctx.principal = caller`).

This requires the tool code to have access to the local executor's interfaces — verify by tracing the existing call path.

If the existing tools strictly require the wire path (e.g., MCP runs as a separate process from Geode), option (2) is the only path — and that's a Phase 7 protocol-versioning task. Mark Task 6-5 DONE_WITH_CONCERNS and defer.

- [ ] **Step 4: Build + test + commit** — `feat(gps): MCP tools set ExecutionContext.principal directly for local executor`.

---

### Task 6-6: Close sites #2 and #8

**Files:** `docs/security/gps-fail-open-sites.md`, source CANARYs

- [ ] Mark sites #2 and #8 as **CLOSED** (or PARTIAL if Task 6-5 deferred wire-level forwarding).

- [ ] Update source CANARY markers accordingly.

- [ ] Commit — `docs(gps): close fail-open sites #2 and #8`

---

### Task 6-7: Phase 6 outcome doc

**Files:** `docs/security/gps-phase6-outcome.md`

- [ ] Write Phase 6 outcome covering policy_version, ABAC, distributed envelope, grant migration, MCP wire closure. Phase 7 handoff: decision cache, ALTER POLICY, EXPLAIN POLICY, full multi-user MCP (if Task 6-5 deferred).

- [ ] Commit.

---

## Final Verification

- [ ] `make build && zig build test`. All GPS tests pass.
- [ ] All originally-OPEN fail-open sites are now CLOSED or PARTIAL with documented residual.
- [ ] CANARY count ≥ 350.
- [ ] Smoke: `CREATE POLICY p1 ON GRAPH * FOR READ;` then `policy_version.getPolicyVersion()` reflects the increment.
