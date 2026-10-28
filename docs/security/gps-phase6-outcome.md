# GPS Phase 6 — Distributed Envelope + ABAC + Grant Migration

## What landed

### Policy Version Counter (`src/security/policy_version.zig`)

- Atomic `u64` counter incremented on every catalog mutation (add / remove / enable /
  disable policy, clear catalog).
- Exported via `policy_version.getVersion()` and `policy_version.bumpVersion()`.
- Will key the Phase 7 decision cache: a cache entry is valid only while the cached
  `policy_version` matches the current counter value.
- CANARY: `REQ-GPS-DIST-001` (commit `4321a903`)

### ABAC Attribute Predicates (`src/security/policy_expression.zig`)

- Extended the expression compiler with an `eq_principal_attr` predicate:
  `principal.attributes.<key> = '<literal>'`.
- Evaluation reads the caller's `Principal.attributes` (an `AttributeMap`) directly
  in `decide()` without additional allocation — the `AttributeMap.Entry` layout is
  identical to `policy_expression.AttributeEntry` (verified with a comptime assert).
- Phase 4 introduced trivial-true; Phase 5 introduced builtin-equality predicates;
  Phase 6 adds full ABAC key/value matching.  Together these form the minimum ABAC
  capability required by the GPS invariants.
- CANARY: `REQ-GPS-ABAC-001` (commit `0ab8d5d5`)

### Distributed Principal Envelope (`src/distributed/principal_envelope.zig`)

- Binary serialization format for the Principal identity + policy_version snapshot,
  ready for integration into cluster RPC frames.
- Encodes: `username`, `tenant_id`, `active_graph`, `roles[]`, `auth_method`,
  `auth_version`, `source`, `policy_version`.
- Full round-trip (serialize → deserialize → re-serialize) is regression-tested in
  `tests/test_gps_principal_envelope.zig`.
- Wire-level integration into the existing coordinator/worker dispatch is Phase 7
  work; Phase 6 lands the serializer and its tests so Phase 7 can drop it in without
  a format break.
- CANARY: `REQ-GPS-DIST-002` (commit `7e7febad`)

### Grant Migration (`src/security/grant_migration.zig`)

> **Superseded (2026-10, REQ-SEC-PER-GRAPH-GRANTS).** The migrated rows made
> a runtime GRANT wait for a restart, outlived REVOKE, and, scoped to one
> graph, matched database-wide write checks, so a WRITE grant on one graph
> allowed writes on every graph. Grants are no longer migrated: `gps.decide`
> reads them from the live grant table, and `grant_migration.zig` now retires
> the `auto_migrated_grant_*` rows at startup. See
> [gps-decide.md](gps-decide.md#per-graph-grants-req-sec-per-graph-grants-2026-10-security-fix).

- One-shot startup migration that converts every existing `(:GraphGrant)` record in
  the `__geode_security` graph to a `(:Policy)` row with a
  `current_user() = '<user>'` predicate.
- Idempotent: a migrated record is tombstoned with `migrated_to_policy = true` so
  re-running migration on the same data is a safe no-op.
- `decide()` in `gps.zig` now evaluates the Policy catalog as the authoritative
  source; the legacy `graph_grant_check_fn` shim is kept only for grants written
  after the migration ran (a transient window) and is marked deprecated for Phase 7
  removal.
- Closes fail-open Site #2 (graph-grant additive widening).
- CANARY: `REQ-GPS-MIGRATE-001` (commit `64ce3940`)

### MCP Principal — Local-Closure Assessment (Task 6-5)

- Investigated whether MCP tools could route through `executeProgramWithContext()`
  (local executor, no QUIC hop) so that `ExecutionContext.principal` carries the
  caller identity directly.
- **Conclusion: Option B (Phase 7 deferral).**  All MCP tool calls route through
  `GeodeClient` → QUIC → remote executor.  There is no safe in-process path because
  `executeProgramWithContext()` requires the full server globals (catalog singleton,
  WAL, store handles) that are not available in the MCP binary context.
- The `caller` Principal IS used for local pre-flight `decide()` calls at the MCP
  boundary in `server.zig`.  Wire-level forwarding requires a principal-forwarding
  header in the `zig_client` QUIC frame — that is Phase 7 work.
- Expanded the block comment in `src/mcp/tools.zig` to document the infeasibility
  of Option A and the Phase 7 plan (commit `9e7a543e`).

## What did NOT change

- Wire-level distributed Principal envelope integration into coordinator/worker
  dispatch — Phase 7.
- Decision cache keyed by `(auth_version, policy_version, action, resource_id)` —
  Phase 7.
- `ALTER POLICY`, `SHOW GRANTS FOR <user>`, `EXPLAIN POLICY` DDL — Phase 7.
- Removal of the deprecated `graph_grant_check_fn` widening shim — Phase 7.
- Multi-user MCP (per-connection Principal instead of per-server) — Phase 7.

## Fail-open site final status (post-Phase 6)

| # | Site | Status | Notes |
|---|------|--------|-------|
| 1 | Auth-disabled early return | **PARTIAL** | Legacy `isAuthEnabled()` compat shim; `--insecure-allow-all` is the canonical bypass. By design. |
| 2 | Graph-grant additive widening | **CLOSED** | `grant_migration.zig` converts all grants to Policy rows at startup (commit `64ce3940`). Legacy shim deprecated; Phase 7 removes it. |
| 3 | RLS no-policy default-allow | **PARTIAL** | Row engine returns rows when no policies match — by design for backward compat. Policy catalog layer is fail-closed. |
| 4 | RLS VM no-result default-allow | **CLOSED** | Phase 2 (commit `234e7e9d`). |
| 5 | Procedure registry skips classifier | **CLOSED** | Phase 5 (commit `656710d0`). |
| 6 | Metadata procedures enumerate globally | **CLOSED** | Phase 3. |
| 7 | `SHOW GRAPHS` is global | **CLOSED** | Phase 3. |
| 8 | MCP boundary bearer-only | **PARTIAL** | Phase 5 closed server-side Principal derivation. Phase 6 confirmed wire-level forwarding is Phase 7 structural work. |
| 9 | FLE decryption hook-local role check | **CLOSED** | Phase 5 (commit `c56f1d1a`). |

## CANARY markers landed in Phase 6

| CANARY REQ | ASPECT | STATUS | Source | Commit |
|---|---|---|---|---|
| `REQ-GPS-DIST-001` | PolicyVersionCounter | TESTED | `src/security/policy_version.zig` | `4321a903` |
| `REQ-GPS-ABAC-001` | ABACAttributePredicates | TESTED | `src/security/policy_expression.zig` | `0ab8d5d5` |
| `REQ-GPS-DIST-002` | PrincipalEnvelopeSerialization | TESTED | `src/distributed/principal_envelope.zig` | `7e7febad` |
| `REQ-GPS-MIGRATE-001` | MigrateGraphGrantsToPolicies | TESTED | `src/security/grant_migration.zig` | `64ce3940` |
| `REQ-GPS-PDP-003` | GraphGrantWidening | EXEMPT | `src/security/gps.zig` (deprecated shim) | `acadc635` |

## Phase 7 handoff

- **Decision cache**: keyed by `(auth_version, policy_version, action, resource_id)`.
  `policy_version` counter from Phase 6 is the invalidation signal.
- **Wire-level distributed Principal**: integrate `principal_envelope.zig` serializer
  into coordinator dispatch and worker entry-point QUIC frame headers.
- **MCP wire forwarding**: add `X-Geode-Principal` header to `zig_client` QUIC frame
  so the remote executor reconstructs `ExecutionContext.principal` from the wire
  identity.  Closes Site #8 fully.
- **DDL surface**: `ALTER POLICY`, `SHOW GRANTS FOR <user>`, `EXPLAIN POLICY`.
- **Deprecation removal**: delete legacy `graph_grant_check_fn` widening shim from
  `gps.zig` once all deployments have run migration (Phase 6 landing gives a full
  release cycle as buffer).
- **Audit dashboards** and performance profiling for the new policy evaluation path.
