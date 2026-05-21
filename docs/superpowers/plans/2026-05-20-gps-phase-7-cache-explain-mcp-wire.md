# GPS Phase 7 — Decision Cache + MCP Wire + ALTER/SHOW GRANTS + EXPLAIN POLICY Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`. This is the final phase plan.

**Goal:** Land the closing pieces of the GPS implementation:
1. **Decision cache** keyed by `(auth_version, policy_version, action, resource_hash)` for sub-5µs cached decisions.
2. **MCP wire-level Principal forwarding** to close Site #8 fully (Phase 6 took the local closure; Phase 7 extends the QUIC wire format).
3. **`ALTER POLICY`** DDL for enabling/disabling and updating expression source without DROP/CREATE.
4. **`SHOW GRANTS FOR <user>`** — enumerate which Policies match a given principal.
5. **`EXPLAIN POLICY FOR <gql_query>`** — return the decisions GPS would make for the query.
6. **Deprecation removal of legacy `graph_grant_check_fn`** — Site #2 was CLOSED in Phase 6 by migration; this phase removes the redundant widening shim.
7. **Distributed envelope wire integration** — Phase 6 landed the serializer; Phase 7 integrates it into coordinator/worker dispatch.

**Architecture:**

1. **Cache**: `src/security/decision_cache.zig` provides a process-global cache. Each decision request computes a stable key from the principal's `auth_version`, the global `policy_version`, the action, and a hash of the resource ref. On hit, returns the cached `PolicyDecision`. On miss, evaluates and inserts. Capacity-bounded (LRU). Skipped when `principal.auth_version == 0` (legacy/unauthenticated path).

2. **MCP wire**: Geode's QUIC client protocol gains a new `principal_envelope_bytes` field on the request frame. MCP server-side toolcalls construct an envelope (via Phase 6's `principal_envelope.zig`) and attach it. Geode's QUIC handler unpacks the envelope, derives a Principal, and threads it through ExecutionContext (overriding the connection-bound principal for that request).

3. **ALTER/SHOW/EXPLAIN**: Three new parser+executor branches. Mostly mechanical extension of the Phase 4 DDL plumbing.

4. **Deprecation**: Remove the `graph_grant_check_fn` widening branch from `decide()`. Tests must continue to pass because Phase 6 migration ensured Policy rows now cover the legacy grants.

5. **Distributed wire integration**: Coordinator attaches envelope at outbound dispatch; worker unpacks at inbound entry; ExecutionContext gets the deserialized Principal with `source = .distributed_worker`. Policy_version mismatch forces shard to re-hydrate the catalog.

**Tech Stack:** Zig 0.16.0+, CANARY (`REQ=REQ-GPS-CACHE-*`, `REQ=REQ-GPS-MCP-WIRE-*`, `REQ=REQ-GPS-ALTER-*`, `REQ=REQ-GPS-EXPLAIN-*`).

---

## File Structure

**Create:**
- `src/security/decision_cache.zig` — bounded LRU cache + lookup/insert.
- `tests/test_gps_decision_cache.zig` — hit/miss/invalidation tests.
- `tests/test_gps_alter_policy.zig` — DDL tests.
- `tests/test_gps_show_grants_for.zig` — enumeration tests.
- `tests/test_gps_explain_policy.zig` — EXPLAIN execution tests.
- `tests/test_gps_mcp_wire.zig` — wire-level forwarding tests.
- `tests/test_gps_distributed_wire.zig` — coordinator-worker round-trip.
- `docs/security/gps-phase7-outcome.md` — final phase outcome doc.
- `docs/security/gps-final-status.md` — overarching final status (every site, every CANARY, every commit).

**Modify:**
- `src/security/gps.zig` — `decide()` consults the cache; insert results.
- `src/security/policy_catalog.zig` — invalidate cache on `addPolicy`/`removePolicy`.
- `src/gql/ast.zig` — `AlterPolicyStatement`, `ShowGrantsForStatement`, `ExplainPolicyStatement`.
- `src/gql/parser.zig` — parse the three new DDL statements.
- `src/execution.zig` — dispatch the three new statement types.
- `src/mcp/server.zig` / `tools.zig` — attach envelope to outbound QUIC requests.
- `src/server/quic_connection_handler.zig` — unpack envelope on inbound; override per-request Principal.
- `src/distributed/query_coordinator.zig` — attach envelope to outbound shard dispatch.
- The shard worker entry — deserialize envelope, check policy_version, attach Principal to ctx.
- `docs/security/gps-fail-open-sites.md` — final close on Site #8.

**Remove:**
- `src/execution.zig` — drop the `graph_grant_check_fn` widening fallback (legacy compat — Phase 6 migration replaced it).

---

## Phase 7 Tasks

### Task 7-1: Decision cache

**Files:** `src/security/decision_cache.zig` (new), `src/security/gps.zig`, `src/security/policy_catalog.zig`, `tests/test_gps_decision_cache.zig`

- [ ] **Step 1: Implement bounded LRU cache**

```zig
// src/security/decision_cache.zig
const std = @import("std");
const gps = @import("gps.zig");

pub const Key = struct {
    auth_version: u64,
    policy_version: u64,
    action_tag: u8,
    resource_hash: u64,
};

pub const Entry = struct {
    key: Key,
    decision: gps.PolicyDecision,
    last_access_ns: i128,
};

pub const DecisionCache = struct {
    // Use std.AutoHashMap for storage, std.DoublyLinkedList for LRU order
    // Capacity bounded; evict LRU on insert when full
    // Cache hit threshold: any cache that returns sub-5µs is fine for Phase 7
};

var g_cache: ?*DecisionCache = null;

pub fn setGlobalCache(c: *DecisionCache) void { g_cache = c; }
pub fn getGlobalCache() ?*DecisionCache { return g_cache; }

pub fn lookup(req_key: Key) ?gps.PolicyDecision { ... }
pub fn insert(key: Key, decision: gps.PolicyDecision) void { ... }
pub fn invalidateAll() void { ... }
```

- [ ] **Step 2: Wire cache lookup at top of `decide()`**

After the `insecure_allow_all` check, compute the key + try the cache. On hit return cached. On miss, evaluate normally then insert.

Skip caching when `principal.auth_version == 0` (legacy/anonymous paths) — they shouldn't pollute the cache.

- [ ] **Step 3: Invalidate cache on policy mutation**

In `policy_catalog.addPolicy` / `removePolicy`, after the policy_version increment, call `decision_cache.invalidateAll()`.

- [ ] **Step 4: Tests**

- Hit returns cached decision without re-evaluation.
- Miss evaluates + inserts.
- Cache invalidated after addPolicy.
- LRU eviction when capacity exceeded.
- Skipped when auth_version is 0.

- [ ] **Step 5: Build + test + commit** — `feat(gps): bounded LRU decision cache`.

---

### Task 7-2: ALTER POLICY DDL

**Files:** `src/gql/ast.zig`, `src/gql/parser.zig`, `src/execution.zig`, `src/security/policy_catalog.zig`, `tests/test_gps_alter_policy.zig`

- [ ] **Step 1: Add AST variant**

```zig
pub const AlterPolicyStatement = struct {
    name: []const u8,
    set_enabled: ?bool = null, // null = don't change
    set_expression_source: ?[]const u8 = null,
};
```

Grammar: `ALTER POLICY name SET ENABLED true|false [, EXPRESSION = '<source>'] ;`

- [ ] **Step 2: Parser support** in `src/gql/parser.zig`

Mirror DROP POLICY's pattern.

- [ ] **Step 3: `policy_catalog.alterPolicy(name, args)` method**

Find the policy by name. Update only the fields specified. Increment policy_version. Persist via write-through hook.

- [ ] **Step 4: Wire executor dispatch** in `src/execution.zig`'s `.AlterPolicy` branch.

- [ ] **Step 5: Tests + commit** — `feat(gps): ALTER POLICY DDL for enable/disable and expression update`.

---

### Task 7-3: SHOW GRANTS FOR <user>

**Files:** `src/gql/ast.zig`, `src/gql/parser.zig`, `src/execution/statement_handlers.zig`, `tests/test_gps_show_grants_for.zig`

- [ ] **Step 1: Add the AST variant** — extend `Show` with a `.grants_for: []const u8` case.

- [ ] **Step 2: Parser** — `SHOW GRANTS FOR <identifier> ;`

- [ ] **Step 3: Handler** — given the username, iterate policies and report which ones grant (i.e., match) the user. For each policy that has `expression_source` containing `current_user() = '<username>'` OR has no user-specific predicate (wildcard), include it. Columns: `policy_name`, `graph`, `actions`, `effect`, `enabled`.

- [ ] **Step 4: Tests + commit** — `feat(gps): SHOW GRANTS FOR <user> enumerates matching policies`.

---

### Task 7-4: EXPLAIN POLICY FOR <gql_query>

**Files:** `src/gql/ast.zig`, `src/gql/parser.zig`, `src/execution.zig`, `tests/test_gps_explain_policy.zig`

- [ ] **Step 1: Add the AST variant** — `ExplainPolicyStatement{ inner_query: []const u8 }`.

- [ ] **Step 2: Parser** — `EXPLAIN POLICY FOR <gql_text_until_semicolon> ;`. Treat the inner text as opaque source.

- [ ] **Step 3: Handler** — parse the inner query, identify each action it would take (e.g., a MATCH is `.match_`, a CREATE is `.create`), and for each action call `gps.decide()` with the current principal. Return rows: `step`, `action`, `resource_summary`, `decision`, `reason_code`.

  For Phase 7, support the simplest case: top-level statement classification. Don't try to enumerate every implicit decision the query makes — just the major ones.

- [ ] **Step 4: Tests + commit** — `feat(gps): EXPLAIN POLICY shows the decisions GPS would make`.

---

### Task 7-5: MCP wire-level Principal forwarding

**Files:** `src/mcp/server.zig`, `src/mcp/tools.zig`, `src/server/quic_connection_handler.zig`, the QUIC client/zig_client request frame schema, tests

- [ ] **Step 1: Identify the request-frame schema**

```bash
ls src/zig_client*/
grep -n "Request\|RequestFrame\|fn buildQueryRequest\|fn execute" src/zig_client.zig src/client*.zig src/mcp/tools.zig 2>/dev/null | head -20
```

Find where the outbound QUIC query is built. Identify where a new field could be added.

- [ ] **Step 2: Extend the frame**

Add an optional `principal_envelope_bytes: []const u8 = ""` field (or analogous extension point) to the outbound request. Use the existing `principal_envelope.serialize` from Phase 6 to produce the bytes.

- [ ] **Step 3: Server-side unpack**

In `src/server/quic_connection_handler.zig` near the `ExecutionContext` build site, look for the new field on the incoming request. If non-empty, deserialize and `principal_derive.derivePrincipal` from it — overriding the connection's default. The MCP-forwarded Principal takes precedence over the connection identity.

Validate the envelope's HMAC or rely on transport-level mutual auth (Phase 6's envelope didn't include integrity — Phase 7 may need to add an HMAC seal if cross-tenancy concerns surface).

- [ ] **Step 4: Tests**

- Round-trip: MCP attaches envelope → server unpacks → ExecutionContext.principal matches.
- Missing envelope → server falls back to connection identity.

- [ ] **Step 5: Close Site #8**

Mark Site #8 **CLOSED** in `gps-fail-open-sites.md` and flip relevant CANARYs.

- [ ] **Step 6: Build + test + commit** — `feat(gps): MCP wire-level Principal forwarding closes Site #8`.

If extending the QUIC frame schema is structurally complex (requires protocol versioning + backward-compat with existing clients), STOP and document the structural deferral. Site #8 remains PARTIAL.

---

### Task 7-6: Distributed envelope wire integration

**Files:** `src/distributed/query_coordinator.zig`, the shard worker entry, tests

- [ ] **Step 1: Locate the outbound shard dispatch**

In `query_coordinator.zig`, find where shard requests are sent. Attach the envelope bytes.

- [ ] **Step 2: Locate the worker inbound**

Find where shards receive incoming queries. Deserialize envelope, build Principal, check policy_version. On version mismatch, hydrate the catalog from `__geode_security` and retry. If still mismatched, return an error.

- [ ] **Step 3: Tests**

- Coordinator → worker round-trip preserves Principal identity.
- Stale policy_version forces re-hydration.

- [ ] **Step 4: Build + test + commit** — `feat(gps): distributed Principal envelope wire integration`.

If the cluster RPC schema is hard to extend, scope-limit similar to Task 7-5.

---

### Task 7-7: Deprecate `graph_grant_check_fn` legacy widening

**Files:** `src/execution.zig`, `src/security/gps.zig`, tests

- [ ] **Step 1: Remove the widening branch in `decide()`**

Phase 6 migrated existing grants to Policy rows. The legacy `graph_grant_check_fn` widening (the additive fallback in `decide()`) can now be removed.

Keep the function pointer field itself (`pub var graph_grant_check_fn` in `src/execution.zig`) for backward compatibility — just don't consult it in `decide()` anymore. (Phase 8+ may remove the pointer entirely.)

Update related tests: any test that relied on the widening must now express the same grant via a Policy row.

- [ ] **Step 2: Build + test + commit** — `refactor(gps): drop legacy graph_grant_check_fn widening from decide()`.

If pre-existing tests fail due to expecting the widening, fix them to use Policy rows. If breakage is widespread, this task may need to revert and document as Phase 8+ work.

---

### Task 7-8: Phase 7 outcome doc + final status doc

**Files:** `docs/security/gps-phase7-outcome.md`, `docs/security/gps-final-status.md`

- [ ] **Step 1: Phase 7 outcome doc** — summarize the cache, ALTER/SHOW/EXPLAIN, wire forwarding, deprecations.

- [ ] **Step 2: Final status doc** — comprehensive summary across all 7 phases:
  - All 9 fail-open sites with final status + closing commits.
  - All `REQ-GPS-*` requirement IDs and their CANARY counts.
  - Each Phase's outcome doc cross-referenced.
  - Open items (none, ideally) for future phases.

- [ ] Commit each.

---

## Final Verification

- [ ] `make build && zig build test` — all GPS test steps pass.
- [ ] Sites #1, #3 remain PARTIAL (by design); all others CLOSED.
- [ ] CANARY count ≥ 420.
- [ ] Smoke: ALTER POLICY p1 SET ENABLED false; SHOW POLICIES — p1 shows as disabled. EXPLAIN POLICY FOR "MATCH (n) RETURN n" — outputs a decision row.
- [ ] Cache smoke: identical decide() requests should report cache hits via internal counters (add diagnostic logging if needed).
