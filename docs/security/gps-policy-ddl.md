# GPS Phase 4 — Policy DDL + Persistent Catalog

## What landed

- **`src/security/role_resolver.zig`** — Extracted from `main.zig` (carry-forward from Phase 3); isolated unit test for HAS_ROLE traversal (`tests/test_gps_role_resolver.zig`).
- **`src/security/policy_catalog.zig`** — In-memory PolicyCatalog with add/list/remove and WriteThroughHooks for external state synchronization.
- **`src/security/policy_persistence.zig`** — Persists Policy nodes in `__geode_security` graph with HMAC chain (mirrors `auth_graph_manager` design).
- **Parser support** — `CREATE POLICY name ON GRAPH * FOR READ;`, `DROP POLICY [IF EXISTS] name;`, `SHOW POLICIES;` — full AST representation.
- **DDL dispatch** — Routed through `auth_dispatch` module; reuses existing authorization framework.
- **Catalog hydration at startup** — Server reads persisted Policy nodes from `__geode_security` at startup and populates PolicyCatalog.
- **Write-through hooks** — Installed in `main.zig`; every add/remove operation syncs to persistent storage.
- **`decide()` policy evaluation** — Consults the catalog after builtin-role and graph-grant evaluation. When a policy with `expression_source = "true"` matches a query binding, returns `.allow` with reason `policy_match`.

## USING conditions

`CREATE POLICY <name> ON GRAPH (<graph> | *) FOR <actions> USING <condition>`
and `CALL geode.auth.policy_create('<name>', '<graph>', '<condition>')` take a
condition in this grammar:

```text
condition  ::= or_expr
or_expr    ::= and_expr ( OR and_expr )*
and_expr   ::= atom ( AND atom )*
atom       ::= ( condition )
             | true
             | session_fn = 'literal'
             | resource.label = 'literal'
             | principal.attributes.<key> = 'literal'
             | row_prop cmp_op session_fn          -- row condition
             | session_fn cmp_op row_prop          -- row condition
session_fn ::= current_user() | current_tenant() | current_graph()
row_prop   ::= [A-Za-z_][A-Za-z0-9_]*
cmp_op     ::= = | <>
```

`AND` binds tighter than `OR`. Comparisons are case-sensitive. Anything else,
including `!=`, `<>` against a literal, a property compared with a literal, a
qualified property such as `n.owner`, and functions geode does not have (for
example `current_user_id()`), is refused when the policy is created, with
SQLSTATE 42000 and nothing stored. A policy with no `USING` clause is `true`.

The session functions return the reading session's values: `current_user()`
is the authenticated user (a forwarded principal's user when there is one),
`current_tenant()` the session's tenant, and `current_graph()` the
principal's active graph (otherwise the session's graph). geode has no
`current_role()`.

### Row conditions

A row condition compares a property of the row being read with a session
function, for example:

```gql
CREATE POLICY own_rows ON GRAPH documents FOR READ USING owner = current_user();
```

A policy with a row condition filters rows. It does not grant access by
itself; the session still needs read access (its builtin role, or another
policy).

- **Where it applies.** It applies to nodes read in the policy's graph (or
  every graph, for `*`), through every read path: scans, label scans, hops,
  aggregates, and the procedures that apply row-level security. A row
  condition is accepted only on a policy `FOR READ` or `FOR MATCH`. On a
  policy for any other action it is refused with 42000, because no write path
  evaluates it. Edges are not filtered by row conditions; a traversal reaches
  an edge only from a node that passed.
- **How policies combine.** If no enabled row-condition policy applies to the
  row's graph, the row is visible. Otherwise, as in PostgreSQL, the row is
  visible only if at least one applicable allow policy's condition holds for
  it, and no deny policy's condition does.
- **Evaluated per session, at read time.** The function is evaluated when the
  row is read, for the session reading it, never when the policy is created.
  So one policy, `owner = current_user()`, shows each user their own rows.
- **Fail closed.** A condition holds only when both sides are known strings. A
  missing or null property, a non-string property (for example an integer
  `owner`), or a session function with no value (an empty or absent user,
  tenant or graph) makes the comparison false, for `=` and for `<>`, so the row
  is denied.
- **Not cached.** Each row is decided for the session in hand. A row verdict
  is never put in the GPS decision cache. That cache holds statement-level
  decisions only, and its key includes the user, tenant and active graph.
- **Who is exempt.** An admin session bypasses row conditions, as it bypasses
  the expression RLS policies. A session with no authenticated user, which is
  possible only with authentication disabled, is not subject to any RLS policy.
- **Statement-level decisions.** In `decide()` a row condition has no row, so
  it is false. For example, `owner = current_user() OR current_user() =
  'auditor'` grants statement access only to `auditor`.
- **Listing.** `SHOW POLICIES` shows the condition text in its `using` column,
  and `CALL geode.auth.policy_list()` in its `condition` column.
- **Persistence.** The condition text is stored with the policy in
  `__geode_security` and compiled again at startup.

Policies stored before row conditions existed, such as `owner = current_user()`
written before 42000 refusals began (b5130bf4), were loaded fail-closed and
granted nothing. They now compile at startup and filter rows as described above.

## Stored lengths and validity (SONNY-2731, SONNY-2732)

`__geode_security` keeps each policy in a fixed-size record:

| Field | Longest value stored |
|---|---|
| name | 63 bytes |
| scope graph | 63 bytes |
| USING expression | 511 bytes |

`CREATE POLICY` and `ALTER POLICY … RENAME TO` refuse anything longer, with
`PolicyFieldTooLong`, and change nothing. Before SONNY-2731 such a policy was
accepted and kept in memory only, and it disappeared at the next restart. A
`CREATE POLICY` whose durable write fails for any reason is now rolled back,
and the statement fails.

At startup, a stored value longer than its field could only have come from
an older or foreign writer. It used to be cut to fit, and the cut text was
compiled as a different policy. Now it is loaded fail-closed: the policy is
kept, grants nothing, and lists as invalid.

`SHOW POLICIES` (fifth column) and `CALL geode.auth.policy_list()` (third
column) show `valid`. It is false for a stored policy whose USING expression
no longer compiles, which is kept fail-closed until it is rewritten. Startup
logs how many stored policies are invalid.

## Record kinds (SONNY-2750)

GPS policies and RLS policies are stored as the same `:Policy` records in
`__geode_security`. GPS policies come from `CREATE POLICY`, `ALTER POLICY`
and the grant migration. RLS policies come from the `geode-auth` tool
(`geode-auth policy create`) and from `geode auth policy create`. The two
systems give some properties different meanings. For example, `operation`
is a set of GPS actions in a GPS record, but the number of one RLS
operation in an RLS record.

Before SONNY-2750, GPS loaded every record at startup as a GPS policy.
`geode-auth policy create p orders update` therefore came back after a
restart as "allow write on `default`, for everyone". The RLS `update` (2)
was read as the GPS action write, and the missing USING text as `true`.
That policy also passed the database-level write check.

Each record now has a `kind` property, `"gps"` or `"rls"`, and every writer
must set it. The record HMAC covers it. At startup, GPS loads only records
of kind `gps`. It refuses these records and grants nothing through them:

- a record of any other kind, including a `kind` that is not exactly
  `"gps"` or `"rls"`;
- a record with a missing or mistyped property the policy needs: `name`,
  `graph`, `operation`, `permissive`, `enabled`, and, for a `gps` record,
  its USING text, which is now stored even when it is `true`.

It never reads a refused record as something else. For each refusal it logs
a warning and writes a `REFUSE_POLICY_RECORD` audit event. `ALTER POLICY`
does not rewrite a GPS record that was refused for a missing property, and
`DROP POLICY IF EXISTS` removes it.

Records written before SONNY-2750 have no `kind`. GPS still loads one if it
has the properties GPS wrote: a scope graph, an empty description and table,
no CHECK clause, and a zero audit level and creator. Such a record stored no
USING text for `true`. The RLS writers always stored a description or a
table, and `geode auth policy create` also stored an empty graph. A record
without a `kind` that has any other shape, or that is missing a property
this check reads, is not loaded. The HMAC of a record without a `kind` is
computed as before, so a chain sealed before the upgrade still verifies. The
next `ALTER POLICY` on such a record stores its kind and USING text.

The `geode auth policy list`, `show` and `delete` commands see RLS records
only. `CREATE`, `ALTER` and `DROP POLICY` see GPS records only, so an RLS
policy with the same name as a GPS policy is left alone.

The chain check at startup does not tell the two kinds apart. The RLS tools
write their records without an HMAC and do not reseal, so the server refuses
to start until an operator runs `geode auth reseal` (or sets
`GEODE_AUTH_RESEAL_CHAIN=1`). The reseal signs every record as it is, RLS
records included. The `kind` check is what keeps those records out of GPS.

**Seals and records without a kind (SONNY-2791).** No seal signs a policy
record that has no `kind` and whose HMAC does not verify: not the recovery
reseal (`geode auth reseal`, or `GEODE_AUTH_RESEAL_CHAIN=1` at startup), and
not the seal after every auth change.

- Such a record claims to predate record kinds, but this key never signed
  it. It may have been planted in the pre-kind GPS shape: with no USING text,
  GPS would load it as an unconditional allow.
- An auth change seals the chain after it. An offline command such as
  `geode user reset-password` loads the security graph as it is, so its seal
  used to sign a planted record. On a store holding one, the change now
  fails at its seal.
- The recovery reseal logs each such record's id and name, and signs
  nothing. Check each record, then decide it by id:
  - drop it (delete it): `geode auth reseal --drop-legacy-policy <id>`, or
    `GEODE_AUTH_RESEAL_DROP_LEGACY=<id>,<id>` for the startup reseal;
  - accept it (sign it): `geode auth reseal --accept-legacy-policy <id>`, or
    `GEODE_AUTH_RESEAL_ACCEPT_LEGACY=<id>,<id>`.

  Each flag can be repeated. An id given both decisions is refused.
- An accepted record is stored with its kind and, for GPS, its USING text
  (`true` when it had none), so nothing loads "true by absence".
- A record without a kind whose HMAC verifies was signed before the upgrade.
  Seals keep it as it is.

Statements cannot write the security graph directly: no statement or HELLO
selects, creates or drops a `__geode_*` graph (SONNY-2791).

## What did NOT change

- **Real expression compilation** — Phase 4 only supports the literal `"true"` predicate. Phase 5+ compiles real expressions through the RLS VM.
- **`ALTER POLICY`** — Deferred; would require mutation of Policy nodes and rehydration.
- **`SHOW GRANTS FOR <user>`** — Query-time grant enumeration; deferred to Phase 5+.
- **`EXPLAIN POLICY`** — Policy evaluation tracing; deferred.
- **ABAC attribute predicates** — Attribute map plumbing and context threading; deferred to Phase 5+.
- **`WITH CHECK` / `MASK` / classification obligations** — Data modification scopes and redaction; deferred.
- **`(:Tenant)`, `(:ApiKey)`, `(:ServiceAccount)`, `(:KeyGrant)` catalog objects** — Additional principal types and their authorization models; deferred to later phases.

## Fail-open site status

### Site #2: Graph-grant additive widening — **PARTIAL**

- **What changed**: Phase 4 introduces a real `(:Policy)` catalog as the new authoritative model for explicit access decisions.
- **What remains**: Legacy `graph_grant_check_fn` widening still active in `decide()` for back-compat with existing deployments.
- **Closing rationale**: The policy catalog now owns graph-level grant decisions. Phase 5 will migrate existing grants to Policy rows and disable legacy widening.
- **Commits**: `fb67fbb0` (catalog), `13d99fd0` (DDL), `c2832c26` (persistence), `c3c62059` (evaluation).

### Site #3: RLS no-policy default-allow — **PARTIAL**

- **What changed**: Phase 4 introduces explicit policy evaluation. The policy *layer* is fail-closed: no policy match → no allow from the policy layer.
- **What remains**: The row-level RLS engine still returns rows when no `Policy` applies in its scope — that's by design (backward compat with pre-policy row access).
- **Closing rationale**: The policy *catalog* is fail-closed. The row *engine* default is deferred pending Phase 5+ expression compilation, which can override per-policy. Policies themselves own "allow by absence" configuration.
- **Design note**: This layering is intentional: policies are an opt-in *overlay* on existing row access; they don't retroactively deny pre-existing data.

## CANARY markers landed in Phase 4

- **`REQ-GPS-PDP-008`** (AuthRoleGraphLookupIsolated) — Coverage gap from Phase 3 closed; isolated unit test verifies HAS_ROLE traversal.
- **`REQ-GPS-CATALOG-001`** — In-memory catalog operations (add/list/remove/lookup).
- **`REQ-GPS-CATALOG-002`** — Persistence module with HMAC chain synchronization.
- **`REQ-GPS-DDL-001`** — Parser, AST, and DDL dispatch for CREATE/DROP/SHOW POLICY.
- **`REQ-GPS-DDL-002`** — Hydration at server startup (loading persisted policies).
- **`REQ-GPS-POLICY-EVAL-001`** — `decide()` policy evaluation (literal "true" support).

## Phase 5 handoff

1. **Compile `expression_source` through RLS VM** — Replace hardcoded `"true"` with real bytecode evaluation.
2. **ABAC predicates + attribute map plumbing** — Thread principal attributes (tenant, user, roles, context) for predicate evaluation.
3. **Procedure registry mandatory EXECUTE_PROCEDURE decision** — Close fail-open site #5.
4. **MCP per-caller principal threading** — Close fail-open site #8.
5. **FLE explicit DECRYPT_FIELD / UNWRAP_KEY actions** — Close fail-open site #9.
6. **Migration tooling** — Script to convert legacy `graph_grant_check_fn` results to Policy rows.
7. **`ALTER POLICY` support** — Mutation and re-persistence.
8. **`EXPLAIN POLICY`** — Tracing and debugging.

## Implementation notes

### PolicyCatalog design

- Keyed by policy name (string).
- Stores `{name, expression_source, description, created_at, modified_at}`.
- WriteThroughHooks enable external audit/persistence without blocking the critical path.
- Lookup is O(1) in-memory; persistence is handled asynchronously by the hook.

### Persistence layer

- Mirrors `auth_graph_manager`: Policy nodes are stored in `__geode_security` graph with property `policy_data_json`.
- HMAC chain integrity (properties set in order, no gaps).
- Hydration at startup reads all `(:Policy)` nodes and reconstructs the catalog.
- Write-through hooks serialize Policy → node, persist to `__geode_security`, verify HMAC.

### `decide()` integration

- Policy evaluation happens *after* builtin-role and graph-grant checks.
- If a policy matches the query binding (e.g., `ON GRAPH *` for a `match` query), the decision is `.allow` with reason `policy_match`.
- If no policy matches, the decision falls through to legacy graph-grant widening (for now).
- Future: replace legacy widening with explicit deny.

### Backward compatibility

- Existing deployments without `CREATE POLICY` statements continue to work (empty catalog, no policy-layer filtering).
- Legacy `graph_grant_check_fn` widening remains active during Phase 4 to ensure seamless upgrade.
- Phase 5 migration tooling will convert grants to Policy rows; Phase 6+ can disable legacy widening.

---

**Closing commit**: `40e0f151` (fail-open sites #2 and #3 marked PARTIAL)  
**GPS Phase 4 status**: Complete (DDL, catalog, persistence, evaluation)  
**Next**: Phase 5 — Real expression compilation and Phase 5 handoff items.
