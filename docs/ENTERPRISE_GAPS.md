# Enterprise Gaps

Last updated: 2026-07-10
Source: black-box spec-coverage expansion of the Geode test harness
(`geode-test-harness` branch `spec-expansion-2026-07-09`). Building 50+
negative/regression specs surfaced the defects below by probing the release
binary (`zig-out/bin/geode`, ReleaseSafe) over QUIC/CLI/GQL. Each defect is
pinned by a harness spec that either asserts today's wrong-but-real behavior as
a self-activating `*-limitation-pin` (flips to a failure once fixed) or
documents it where reproducing it would crash the shared server.

**IDs** continue the plain `GAP-09NN` register (max prior id was GAP-0900).
**Test** points to the harness spec (`geodetestlab/specs/…`) that covers each.
Fix a gap → the paired limitation-pin fails → convert it to a positive assertion.

## Summary

| Tier | Count | IDs |
|---|---|---|
| Critical (server crash / DoS, auth bypass, wholesale-broken, silent wrong results) | 16 | GAP-0901 … GAP-0916 |
| High (data-integrity risk, audit blind spots) | 4 | GAP-0917 … GAP-0920 |
| Medium (missing input validation — silent-accept, no corruption) | 6 | GAP-0921 … GAP-0926 |
| Low (operability / config / UX) | 3 | GAP-0927 … GAP-0929 |

Harness/test-framework issues discovered alongside these (dead assertion keys,
no-op config keys, unparsed DDL forms) are tracked in the harness repo at
`docs/superpowers/research/2026-07-10-geode-bugs-found.md`, not here.

---

# Critical

## GAP-0901 — gRPC transport is wholesale non-functional
**Severity:** Critical · **Status:** OPEN · **Area:** Transport / gRPC · **Found:** 2026-07-10
**Symptom:** every gRPC invocation times out; `make test-grpc` cannot pass any
managed-server spec. Even the proven `--server <addr> --grpc` form hangs.
**Root cause (probe):** the gRPC handler globals are only initialized inside the
QUIC-listen branch of `src/server/main.zig`; when the server is driven over gRPC
those globals are never set up.
**Reproduction:** run any spec under `--transport grpc`; the client hangs and the
managed-server tests time out.
**Test:** `security_graph_bind_authorization_861.yml` (self-activating
gRPC-liveness gate), `security_grpc_cdc_admin_gate_849.yml`.

## GAP-0902 — `geode migrate run --server` hangs and crashes the server
**Severity:** Critical · **Status:** OPEN · **Area:** Migrations · **Found:** 2026-07-10
**Symptom:** `migrate run` against a live server hangs indefinitely (client
killed by timeout) AND crashes the managed server ("Server died") for BOTH valid
and invalid migrations; when it returns it exits without applying (ledger
`Applied` stays 0). An unreachable host hangs instead of a clean connection error.
**Root cause (code read):** `src/cli/backup_cli.zig::execMigrationScript` /
`connectMigrationClient`, invoked by `src/migration/apply.zig::applyUpMigrations`.
Migrate-path-specific: the same malformed GQL via `geode query` exits 0 and the
server survives; thousands of `geode query` tests pass over the identical TLS/auth
setup. Signing is not the cause (`--allow-unsigned` bypasses the only signature
step, which precedes the hang).
**Reproduction:** `geode migrate create` a migration, then
`geode migrate run --dir <d> --server <live> …` — client hangs, server dies.
**Test:** `migration_failure_handling.yml` (local surface tested; live run
documented-only + a safe dead-port `migrate run` pin).

## GAP-0903 — repeated failing `CREATE INDEX` double-frees (segfault)
**Severity:** Critical · **Status:** OPEN · **Area:** Storage / catalog · **Found:** 2026-07-10
**Symptom:** issuing the same duplicate `CREATE INDEX <name> ON <L>(<p>)` 4–5×
in a row segfaults the server via a double-free.
**Root cause:** `src/…/catalog.zig:777 addIndex` (the duplicate-name error path
frees a structure that is then freed again on the next attempt).
**Reproduction:** `CREATE INDEX foo ON L(k)` once (succeeds), then repeat the
identical statement 4–5 times.
**Test:** `index_ddl_errors.yml` (single duplicate attempt is safe/tested; the
repeat-crash is documented, not exercised).

## GAP-0904 — `ORDER BY 0` (non-positive ordinal) panics via integer underflow
**Severity:** Critical · **Status:** FIXED (2026-07-10) · **Area:** Query / sorting · **Found:** 2026-07-10
**Fix:** non-positive ordinals now sort as a NULL key (same policy as the
pre-existing out-of-range-high ordinal). Regression: `zig build test-gap0904`
(`tests/test_gap0904_order_by_ordinal.zig`).
**Symptom:** `… ORDER BY 0` (or any non-positive positional ordinal) panics and
kills the process.
**Root cause:** integer underflow in `getValueForKey`,
`src/…/return_and_sorting.zig:203` (`ordinal - 1` on a 0/negative ordinal).
**Reproduction:** `MATCH (n:L) RETURN n.v ORDER BY 0`.
**Test:** `order_by_negative.yml` (executes only the safe `ORDER BY 99`; the crash
is documented, not exercised).

## GAP-0905 — `CAST(<huge-float> AS INTEGER)` panics (out-of-bounds)
**Severity:** Critical · **Status:** FIXED (2026-07-10) · **Area:** Query / CAST · **Found:** 2026-07-10
**Fix:** two panic sites guarded — the parser's scientific-notation
float-literal → scale-15 Decimal conversion (huge literals now fall back to a
scale-0 decimal when representable, else a clean `error.Overflow` parse
error), and the Decimal → INTEGER cast's i128→i64 narrowing (now
`EvalError.IntegerOverflow`, SQLSTATE 22003). Regression:
`zig build test-gap0905` (`tests/test_gap0905_cast_float_overflow.zig`).
**Symptom:** `RETURN CAST(1.0e308 AS INTEGER)` panics with "integer part of
floating point value out of bounds" and kills the server.
**Reproduction:** `RETURN CAST(1.0e308 AS INTEGER)`.
**Test:** `cast_invalid.yml` (uses a safe string-literal overflow that errors
cleanly; the float-overflow crash is documented, not exercised).

## GAP-0906 — `Interval('P999999999Y')` panics (i32 multiply overflow)
**Severity:** Critical · **Status:** FIXED (2026-07-10) · **Area:** Types / interval · **Found:** 2026-07-10
**Fix:** `Interval.fromStr` accumulates every component with checked
arithmetic; overflow reports `ParseError` (mapped to `EvalError.TimeParse` at
the query layer), matching the 10-digit forms. Regression:
`zig build test-gap0906` (`tests/test_gap0906_interval_overflow.zig`).
**Symptom:** constructing a large year-interval panics via signed multiply
overflow.
**Root cause:** `src/…/datetime.zig:282` (i32 multiply, no overflow guard).
**Reproduction:** `RETURN Interval('P999999999Y')`.
**Test:** `advanced_types_boundary.yml` (executes the cleanly-erroring 10-digit
`P9999999999Y`; the 9-digit crash form is documented, not exercised).

## GAP-0907 — `MakeInterval(2147483648, …)` panics (unchecked `@intCast`)
**Severity:** Critical · **Status:** FIXED (2026-07-10) · **Area:** Types / interval · **Found:** 2026-07-10
**Fix:** months/days narrowing is checked; out-of-range arguments raise
`EvalError.IntegerOverflow` (SQLSTATE 22003). Regression:
`zig build test-gap0907` (`tests/test_gap0907_makeinterval_overflow.zig`).
**Symptom:** `MakeInterval` with an argument exceeding i32 range panics on an
unchecked narrowing cast.
**Root cause:** `src/…/call_handlers.zig:1755` (`@intCast` without a range check).
**Reproduction:** `RETURN MakeInterval(2147483648, 1, 1)`.
**Test:** `advanced_types_boundary.yml` (documented, not exercised).

## GAP-0908 — unwritable audit sink at startup crashes the server
**Severity:** Critical · **Status:** OPEN · **Area:** Audit / startup · **Found:** 2026-07-10
**Symptom:** starting the server with an audit sink whose file/dir is unwritable
(EACCES) crashes it with an unhandled error, plus a leak-on-error-path artifact.
Expected: a graceful "cannot open audit log" refusal (fail-closed, clean exit).
**Root cause:** `src/server/main.zig:1447` does a bare `try` on
`audit.AuditLogger.init` (which returns EACCES from `createFile` at
`src/security/audit.zig:270`); the process unwinds and dies, leaking the
`gpa.create(AuditLogger)` allocation on the error path.
**Reproduction:** `chmod 000` the audit sink file, restart the server.
**Test:** `audit_sink_failclosed_policy.yml` (self-activating crash pin; verifies
the audit chain stays clean after recovery).

## GAP-0909 — missing `--data-dir` crashes the server at startup
**Severity:** Critical · **Status:** OPEN · **Area:** Startup · **Found:** 2026-07-10
**Symptom:** starting the server with a `--data-dir` path that does not exist
crashes instead of creating it or erroring cleanly.
**Reproduction:** `geode serve --data-dir /path/that/does/not/exist`.
**Test:** `audit_sink_failclosed_policy.yml` (documented alongside GAP-0908).

## GAP-0910 — `labels(n), properties(n)` after crash+restart segfaults
**Severity:** Critical · **Status:** OPEN · **Area:** Query / value lifetime · **Found:** 2026-07-10
**Symptom:** `MATCH (n) RETURN labels(n), properties(n)` after an unclean crash +
reopen segfaults the server (map double-free / dangling pointer in result deinit).
**Root cause:** `src/execution/value_utilities.zig:235 freeValue`.
**Reproduction:** SIGKILL the server, restart on the same data dir, run
`MATCH (n) RETURN labels(n), properties(n)`.
**Test:** `wal_corrupt_record_recovery.yml` (documented; the spec deliberately
avoids this query).

## GAP-0911 — non-admin can `CREATE POLICY` (authorization bypass)
**Severity:** Critical · **Status:** OPEN · **Area:** Security / GPS · **Found:** 2026-07-10
**Symptom:** a readonly, unprivileged user with zero grants can `CREATE POLICY`
and it persists (visible in `SHOW POLICIES`). A policy-injection /
privilege-escalation vector.
**Root cause:** `src/execution.zig:2153` (`.CreatePolicy` dispatch arm) calls
`pol_cat.addPolicy(...)` with only a cluster-replication gate — no
`checkPermission()` / `gps.decide()`. `checkPermission()` (defined at
`src/execution.zig:915`) is never called anywhere in dispatch. Same dispatch-layer
class as the pre-existing CREATE GRAPH / CREATE INDEX authorization gaps noted in
`geodetestlab/specs/gps_phase2_decide_comprehensive.yml`.
**Reproduction:** as a non-admin readonly user, `CREATE POLICY p …` → exit 0,
"Policy created", persists. (Contrast: `USE GRAPH` on an ungranted graph is
correctly denied with exit 3.)
**Test:** `gps_decide_negative.yml` (asserts the wrong-but-real ALLOW,
self-activating).

## GAP-0912 — same-variable path endpoints not unified at match time
**Severity:** Critical · **Status:** OPEN · **Area:** Query / pattern match · **Found:** 2026-07-10
**Symptom:** reusing one variable at both ends of a variable-length pattern
(`(n)-[*]->(n)`) does NOT constrain start == end. A non-aggregated
`MATCH p = (n {id:'F'})-[:R*]->(n) RETURN nodes(p)` over an acyclic DAG returns
rows whose endpoints differ. Consequently the standard cycle-detection idiom
`MATCH p = (n)-[*]-(n) WHERE length(p) > 0 RETURN p` (used in
`geode_graph_algorithms.yml`) is broken — it returns non-cycles as cycles.
**Reproduction:** build an acyclic chain F→G→H; run
`MATCH p = (n {id:'F'})-[:R*]->(n) RETURN [x IN nodes(p) | x.id]` → returns
`["F","G"]`, `["F","H"]`, `["F","G","H"]` (start ≠ end).
**Test:** `graph_algorithm_edge_cases.yml` (committed non-aggregated evidence
asserting the wrong endpoint rows).

## GAP-0913 — aggregate over a variable-length pattern silently drops WHERE
**Severity:** Critical · **Status:** OPEN · **Area:** Query / aggregation · **Found:** 2026-07-10
**Symptom:** `count(...)` (and other aggregates) over a variable-length
relationship pattern silently ignore an attached `WHERE` clause, returning wrong
counts. The non-aggregated `RETURN p` form respects the filter correctly.
**Reproduction:** with a graph where a filtered var-length match yields 0 paths,
`… count(p)` returns 2 while `… RETURN p` returns 0 rows.
**Test:** `graph_algorithm_edge_cases.yml` (before/after/control triad).

## GAP-0914 — GROUP BY on an unresolvable identifier collapses to one null group
**Severity:** Critical · **Status:** OPEN · **Area:** Query / aggregation · **Found:** 2026-07-10
**Symptom:** `RETURN n.cat AS s, count(*) AS c GROUP BY nosuch` (unresolvable
group key) silently collapses every row into a single null group instead of
erroring — a silent wrong result.
**Reproduction:** the query above over a multi-category dataset returns one row
`{"s":null,"c":<total>}`.
**Test:** `groupby_return_alias_correctness.yml` (limitation-pin;
`groupby-unknown-alias-limitation-pin`).

## GAP-0915 — label index not rebuilt after an unclean crash
**Severity:** Critical · **Status:** OPEN · **Area:** Storage / recovery · **Found:** 2026-07-10
**Symptom:** after a SIGKILL crash + reopen, `MATCH (n:Label) RETURN count(n)`
returns 0 while `MATCH (n) RETURN count(n)` and property lookups return the full
committed set — the row data survives but the label index is not reconstructed on
the unclean-crash reopen path. A graceful restart returns the correct count 4/4.
Distinct from the graceful-path fix in commit `9a255a83`.
**Reproduction:** create N `:Label` nodes, SIGKILL, restart, run
`MATCH (n:Label) RETURN count(n)` → 0 (should be N).
**Test:** `wal_corrupt_record_recovery.yml`
(`label-index-after-crash-limitation-pin`; committed-prefix survival is verified
via a label-less oracle).

## GAP-0916 — `sum()` of a string column silently returns 0
**Severity:** Critical · **Status:** OPEN · **Area:** Query / aggregation · **Found:** 2026-07-10
**Symptom:** `sum(<string column>)` silently returns `0` (wrong numeric data),
while `avg(<same column>)` returns `NULL` — inconsistent, and neither raises a
type error.
**Reproduction:** over nodes with a string property `s`, `RETURN sum(n.s)` → 0.
**Test:** `group_by_aggregation_negative.yml` (limitation-pin with the
`avg`→NULL contrast).

---

# High

## GAP-0917 — statement after a mid-transaction error is not rejected
**Severity:** High · **Status:** OPEN · **Area:** Transactions · **Found:** 2026-07-10
**Symptom:** in `BEGIN; CREATE …; <runtime-type-error>; CREATE …; COMMIT`, the
engine does NOT reject statements after the error — both CREATEs commit. ISO/IEC
39075 requires post-error statements be rejected until ROLLBACK. No corruption,
but a conformance/isolation gap.
**Reproduction:** the multi-statement batch above → post-COMMIT `count` == 2.
**Test:** `transaction_conflict_abort.yml` (asserts both rows landed).

## GAP-0918 — wrong-dimension vector silently accepted into an HNSW index
**Severity:** High · **Status:** OPEN · **Area:** Vector index · **Found:** 2026-07-10
**Symptom:** inserting a dim-3 vector into a dim-4 HNSW-indexed property is
silently accepted (data-integrity risk). Also: an invalid distance metric
(`'banana'`) is accepted at `CREATE INDEX`, and a malformed vector literal
(`[1.0,'x',2.0]`) silently resolves to NULL with no diagnostic.
**Reproduction:** create a dim-4 vector index, insert a dim-3 vector → exit 0,
00000.
**Test:** `vector_index_errors.yml` (three limitation-pins).

## GAP-0919 — denied DDL-escalation attempts emit no audit record
**Severity:** High · **Status:** OPEN · **Area:** Security / audit · **Found:** 2026-07-10
**Symptom:** non-admin GRANT / CREATE USER / REVOKE denials (SQLSTATE 42501) are
not audited — the admin-only gate returns `error.Unauthorized` before the
`logSecurityGraphMutation` / `access_denied` audit path. Successful GRANTs ARE
audited; denials are not, leaving an authz-attack blind spot.
**Reproduction:** as a non-admin, attempt `CREATE USER x …` → denied 42501, but
no audit entry is written.
**Test:** `rbac_privilege_escalation_denied.yml` (audit case dropped + documented).

## GAP-0920 — mid-run audit write failure produces no diagnostic
**Severity:** High · **Status:** OPEN · **Area:** Audit · **Found:** 2026-07-10
**Symptom:** a genuine mid-run audit-write failure (e.g. under `prlimit --fsize`)
produces zero diagnostic anywhere — a silent audit gap (worse than the
GAP-0908 startup crash, because it is invisible). Note: on Linux, a mid-run
`chmod 000` of the sink is a no-op because the fd is already open — the sink
failure policy is only reachable at restart.
**Test:** `audit_sink_failclosed_policy.yml` (documented; mid-run no-op recorded).

---

# Medium (missing input validation — silent-accept, no data corruption)

## GAP-0921 — CAST performs no semantic value validation
**Severity:** Medium · **Status:** OPEN · **Area:** Query / CAST · **Found:** 2026-07-10
**Symptom:** `CAST('abc' AS INTEGER)`, casts to unsupported target types, and
numeric overflow all silently return NULL / 00000 rather than 22018 / 0A000.
CAST rejects only at parse time (missing type name → 42000). Confirmed across
int/decimal/boolean/timestamp/list/map targets.
**Test:** `cast_invalid.yml`.

## GAP-0922 — fulltext index on a numeric property silently accepted
**Severity:** Medium · **Status:** OPEN · **Area:** FTS · **Found:** 2026-07-10
**Symptom:** `CREATE INDEX … ON L(int_prop) USING fulltext` is accepted, builds
an index that matches nothing, and issues no diagnostic.
**Test:** `fulltext_search_negative.yml`.

## GAP-0923 — malformed and duplicate ABAC policies silently accepted
**Severity:** Medium · **Status:** OPEN · **Area:** Security / ABAC · **Found:** 2026-07-10
**Symptom:** (a) a syntactically invalid `USING` expression is silently accepted
— `src/security/policy_catalog.zig:97` compiles lazily and swallows the error via
`catch null`. NOT a privilege bug: `src/security/gps.zig::decide()` fail-closes a
null-compiled policy (verified end-to-end). (b) duplicate policy names are
accepted (no uniqueness check); `SHOW POLICIES` lists two rows and a single
`DROP POLICY` removes only the first (`policy_catalog.zig:133`), leaving a ghost
duplicate.
**Test:** `abac_malformed_policy_rejection.yml` (two limitation-pins + a
fail-closed verification with teeth).

## GAP-0924 — spatial functions swallow bad geometry to NULL; no bowtie check
**Severity:** Medium · **Status:** OPEN · **Area:** Spatial · **Found:** 2026-07-10
**Symptom:** malformed WKT, a nonexistent constructor, or a degenerate polygon
ring silently resolve to NULL at the bare-call level (a real TypeMismatch/58000
is only raised when composed with a geometry consumer like `ST_AsText`).
Self-intersecting "bowtie" polygons are accepted with no simple-polygon
validation. (Wrong-arity `ST_Point` and inverted bboxes are handled correctly.)
**Test:** `spatial_geometry_errors.yml`.

## GAP-0925 — `decimal_add` has no precision ceiling (unlike `decimal_mul`)
**Severity:** Medium · **Status:** OPEN · **Area:** Types / decimal · **Found:** 2026-07-10
**Symptom:** `decimal_add` silently produces a 39-digit result past the 38-digit
ceiling, whereas `decimal_mul` correctly rejects overflow with 58000
DecimalOverflow — inconsistent enforcement.
**Test:** `advanced_types_boundary.yml` (limitation-pin with the `decimal_mul`
contrast).

## GAP-0926 — silent-accept family: WHERE-unbound, MERGE-null-key, params, index-target, aggregation edges
**Severity:** Medium · **Status:** OPEN · **Area:** Query / GQL semantics · **Found:** 2026-07-10
Several ISO-39075 negatives are silently accepted (0 rows / NULL / 00000) rather
than raising an error. Each is a self-activating limitation-pin:
- **WHERE unbound variable** (`WHERE m.i = 1`, `m` undefined) → filters to 0 rows
  instead of "unknown variable m". Test: `where_clause_negative.yml`.
- **MERGE unbound-var / null key** (`MERGE (n {k: m.v})` / `MERGE (n {k: null})`)
  → silently creates a `k=null` node (dedups correctly, so no duplicates).
  Test: `merge_conflict_negative.yml`.
- **Parameter binding** — out-of-range positional (`$2` with one param) and
  missing named params → NULL; extra params silently ignored. (Type-mismatch IS
  correctly rejected, 58000.) Test: `parameter_binding_negative.yml`.
- **Index on nonexistent label/property** → `CREATE INDEX` silently succeeds and
  registers in `SHOW INDEXES`. Test: `index_ddl_errors.yml`.
- **Aggregation edges** — non-grouped column → first-inserted-row value; nested
  aggregate `sum(avg())` → NULL; HAVING on an unknown alias → NULL filters all
  rows. Test: `group_by_aggregation_negative.yml`.

---

# Low (operability / config / UX)

## GAP-0927 — `--idle-timeout` decoupled from the per-connection idle reap
**Severity:** Low · **Status:** OPEN · **Area:** Transport / connection pool · **Found:** 2026-07-10
**Symptom:** the `--idle-timeout` flag only feeds the QUIC transport's
`max_idle_timeout_ms`; the per-connection idle-reap deadline is a hardcoded
300000 ms (`src/…/quic_connection_handler.zig:1720`), so an abrupt client SIGKILL
does not reclaim its connection slot on the flag's schedule.
**Test:** `connection_pool_rejection.yml`.

## GAP-0928 — over-cap connections have no explicit `POOL_EXHAUSTED` signal
**Severity:** Low · **Status:** OPEN · **Area:** Transport / connection pool · **Found:** 2026-07-10
**Symptom:** with `--max-connections N`, the N+1-th connection is not rejected
with a server-side admission error; the QUIC accept loop futex-parks on
backpressure (`src/server/main.zig:3090`) and the operator only observes the
client's own `--timeout` firing. A clear `POOL_EXHAUSTED`-style rejection would
be more diagnosable.
**Test:** `connection_pool_rejection.yml`.

## GAP-0929 — `GEODE_PORT` environment variable is inert
**Severity:** Low · **Status:** OPEN · **Area:** Config · **Found:** 2026-07-10
**Symptom:** `GEODE_PORT` has zero references in `src/` — only `--listen` sets the
bind address. Setting `GEODE_PORT` silently has no effect; it should either bind
or be rejected/documented.
**Test:** `env_var_invalid_values.yml`
(`GEODE_PORT_ENV_VAR_INERT` evidence).
