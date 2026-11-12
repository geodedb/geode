# GPS — Final Implementation Status (Phases 0–7)

## At a glance

The Geode Policy System ships with a central `gps.decide()` API, a persisted
policy catalog, transport-uniform Principal threading, and 7 of 9 documented
fail-open sites closed (the remaining 2 are PARTIAL by design).

Authenticated principals are threaded through every production request boundary
(QUIC, gRPC, distributed coordinator). Decisions are cached for sub-µs latency
on hot paths. Policies are persisted in the `__geode_security` graph, hydrated
at startup, and mutated via DDL (`CREATE POLICY`, `DROP POLICY`, `ALTER POLICY`).

## Phase-by-phase outcomes

| Phase | Goal | Outcome doc |
|---|---|---|
| 0 | Pin invariants, catalog fail-open sites | `gps-invariants.md`, `gps-fail-open-sites.md` |
| 1 | Canonical Principal type + propagation | `gps-principal.md` |
| 2 | Central `decide()` API + transport wiring | `gps-decide.md` |
| 3 | Non-bypassable tenant/graph enforcement | `gps-isolation.md` |
| 4 | Policy DDL + persistent catalog | `gps-policy-ddl.md` |
| 5 | Procedure/MCP/FLE hardening + expression compilation | `gps-phase5-outcome.md` |
| 6 | Distributed envelope + ABAC + grant migration | `gps-phase6-outcome.md` |
| 7 | Cache + ALTER/SHOW/EXPLAIN + wire forwarding | `gps-phase7-outcome.md` |

## Fail-open site final ledger

| Site | Description | Closing commit(s) | Status |
|---|---|---|---|
| #1 | Auth-disabled early return | `36742374` (Phase 2 — moved behind `--insecure-allow-all`) | PARTIAL (by design) |
| #2 | Graph-grant additive widening | `64ce3940` (Phase 6 migration) + `b7125115` (Phase 7 widening removal) | CLOSED |
| #3 | RLS no-policy default-allow | n/a — row engine permit-by-default is intentional | PARTIAL (by design) |
| #4 | RLS VM no-result | `234e7e9d` (Phase 2) | CLOSED |
| #5 | Procedure classifier | `656710d0` (Phase 5) | CLOSED |
| #6 | Metadata global enumeration | `7246449e`, `c46ab43f`, `1a295c30` (Phase 3) | CLOSED |
| #7 | SHOW GRAPHS global | `fd7586da` (Phase 3) | CLOSED |
| #8 | MCP boundary bearer-only | `306cb3e8` (Phase 5 per-caller principal), `4e08ab5a` (Phase 7 distributed path) | PARTIAL (MCP-client send side blocked on external package) |
| #9 | FLE decryption hook-local | `c56f1d1a` (Phase 5) | CLOSED |

Run `git log --oneline | grep -i 'fail-open\|fle\|metadata\|procedure\|migration\|widening'`
to locate these commits in the local history.

## REQ-GPS-* CANARY families

Run `grep -rho "REQ-GPS-[A-Z]*-[0-9]*" src/ tests/ docs/ | sort -u` for the
live list. As of Phase 7, the shipped families and their coverage are:

| Family | IDs shipped | Description |
|---|---|---|
| PRINCIPAL | 001–007 | Canonical Principal type, derivation, propagation |
| PDP | 001–008 | `decide()` API, insecure bypass, gRPC enforcement, role-graph lookup |
| DERIVE | 001–002 | Principal derivation from auth context |
| BIND | 001–002 | Graph-bind enforcement |
| METADATA | 000–005 | Tenant-filtered db.labels / db.relationshipTypes / db.propertyKeys |
| DDL | 001–004 | CREATE POLICY, DROP POLICY, ALTER POLICY, SHOW GRANTS FOR |
| CATALOG | 001–002 | Policy catalog load/persist |
| POLICY-EVAL | 001 | Policy evaluation loop in `decide()` |
| EXPR | 001 | Expression compiler and evaluator |
| PROC | 001 | Procedure dispatch gate |
| MCP | 001 | MCP per-caller Principal derivation |
| FLE | 001 | FLE decrypt/unwrap GPS gate |
| DIST | 001–002 | Distributed Principal envelope; policy_version counter |
| ABAC | 001 | ABAC attribute predicates |
| MIGRATE | 001 | Legacy graph-grant → Policy migration |
| CACHE | 001 | LRU decision cache |
| EXPLAIN | 001 | EXPLAIN POLICY FOR DDL |
| WIRE | 001–002 | `ExecuteRequest` and `NodeQuery` wire fields for Principal forwarding |
| INVARIANT | 001 | Core GPS invariants |
| AUDIT | 001 | Audit integration |
| PERSIST | 001 | Policy persistence |
| GRAPH | 001 | Per-graph grant enforcement |
| TENANT | 001 | Tenant isolation |
| RLS | 001 | RLS integration |

## What the policy system can do today

- **Authenticated principal on every request.** Derived from QUIC/TLS handshake
  identity and threaded through QUIC, gRPC, distributed coordinator, MCP, and
  REPL paths. Never falls back to an anonymous identity unless
  `--insecure-allow-all` is explicitly set.
- **Single decision point.** `gps.decide(action, resource)` is the only place
  where authorization decisions are made. Tested against legacy `checkPermission`
  for bit-identical outcomes on all existing cases.
- **Persisted policies.** Stored in `__geode_security` graph, hydrated at
  startup via `policy_persistence.zig`, mutated via `CREATE POLICY` /
  `DROP POLICY` / `ALTER POLICY`.
- **Real expression predicates.** `current_user()`, `current_tenant()`,
  `current_graph()`, `resource.label`, `principal.attributes.<key>`, AND, OR,
  and parenthesized expressions. Compiled at `addPolicy` time into a
  `CompiledExpression` IR; evaluated at `decide()` time.
- **ABAC.** `principal.attributes.<key> = '<value>'` predicates evaluate
  directly against the caller's `AttributeMap` with zero extra allocation.
- **Non-bypassable tenant + graph enforcement.** `db.labels`,
  `db.relationshipTypes`, `db.propertyKeys`, `SHOW GRAPHS`, `SHOW INDEXES`,
  `SHOW CONSTRAINTS` — all filtered by `ctx.tenant_id` at execution time.
  Null tenant (admin path) retains full visibility.
- **Procedure gate.** Every procedure dispatch calls
  `gps.decide(.execute_procedure)` before executing the body. Unknown procedures
  fail closed.
- **FLE gate.** `DECRYPT_FIELD` and `UNWRAP_KEY` are explicit GPS actions;
  `fle_hooks.zig` calls `decide()` before returning plaintext.
- **MCP gate.** Per-caller Principal derived from bearer-validated identity;
  tool calls and metadata operations (readResource, listResources) filtered by
  `decide()`.
- **LRU decision cache.** Bounded cache keyed by
  `(auth_version, policy_version, action_tag, resource_hash)`. Auto-invalidated
  on every policy mutation and on ALTER POLICY. Sub-µs cache hits on hot paths.
- **Distributed Principal forwarding.** Coordinator attaches the caller's
  Principal envelope to every `NodeQuery`; workers unpack and enforce locally.
  Policy version is embedded in the envelope so workers can detect stale cache
  entries.
- **Grant migration.** Every legacy `(:GraphGrant)` record was converted to a
  `(:Policy)` row at startup (Phase 6). `decide()` evaluates Policy rows
  exclusively; additive grant widening removed from Phase 7.
- **Operational DDL.**
  - `ALTER POLICY name SET ENABLED true|false` — disable/enable a policy
    without dropping it; bumps policy_version and invalidates the cache.
  - `SHOW GRANTS FOR <user>` — enumerate policies applicable to a user.
  - `EXPLAIN POLICY FOR <query>` — inspect the decision GPS would make for a
    given query without executing it.

## What's deferred (Phase 8+)

- **MCP send-side wire integration.** The `geode-client-zig` external package
  does not yet emit `principal_envelope_bytes` in `ExecuteRequest`. Requires a
  library release tracked separately.
- **ALTER POLICY persistence.** ALTER mutations are in-memory only; a server
  restart resets enabled/disabled state to the persisted value. Needs a
  write-through hook in `policy_persistence.zig`.
- ~~**Multi-step EXPLAIN POLICY.**~~ Done (SONNY-6313): EXPLAIN POLICY
  reports every question the read and write gates ask for the statement,
  per graph and per action (e.g. `MATCH … DELETE`: `match_` then
  `delete`), for the session's graph, and (SONNY-6369) the executor's own
  checks: the procedure gate, the DDL schema gates and the USE GRAPH bind
  check.
- **Remove `graph_grant_check_fn` field entirely.** Phase 7 removed the
  widening consumer inside `decide()`; the function-pointer field itself remains
  for back-compat until all call sites are confirmed dead.
- **Hashmap-backed `AttributeMap`.** The current fixed-size array has a
  compile-time capacity cap. Large attribute sets need a dynamic implementation.

## Where to start as a reader

1. **`gps-invariants.md`** — the invariants the system was built to enforce;
   the original "pinned state" that drove all phase goals.
2. **`gps-decide.md`** — how to call `gps.decide()`, what actions exist, and
   what the return values mean.
3. **`gps-policy-ddl.md`** — how to write, create, alter, and drop a policy;
   expression syntax reference.
4. **`gps-fail-open-sites.md`** — the full table of fail-open sites with live
   status; check here before deploying to understand which sites are still
   PARTIAL and why.
5. **`gps-principal.md`** — the canonical Principal type and how it flows
   through the system.
