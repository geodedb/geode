# Known Test Issues

This document tracks tests that are skipped in the geodetestlab test suite due to unimplemented features or test infrastructure issues.

> **Note**: This is the authoritative source for test status. Run `make geodetestlab-comprehensive` for current results. Other documentation files reference this document rather than containing their own test numbers.

## Test Suite Status (January 2026)

**Last Updated**: January 9, 2026

> Numbers below are from the last documented test run. Run tests locally for current results.

- **Pass Rate**: ~97% (varies by test run)
- **Skipped**: ~120 tests (intentionally skipped due to known limitations documented below)

## Test Suite Drift — Pre-existing, Tracked for Re-baseline

The items below were observed during validation of unrelated MRs and have
been confirmed to reproduce at the parent commit (no regression from the
MR being validated). They are recorded here so future runs don't chase
them as new failures; each block carries enough context to triage cheaply
when the underlying issue is finally addressed.

### `extended_test_runner.py` — ~200 failures including `gql_pattern_matching_comprehensive` 0/35 (2026-05-07)

Running `python3 scripts/test/extended_test_runner.py` against the harness
specs in `../geode-test-harness/geodetestlab-cli/specs/` produces ~200
failures, dominated by a 0/35 wipeout in
`gql_pattern_matching_comprehensive.yml`. Verified pre-existing by
reverting all fix files for the active MR and re-running on the parent
commit — same 0/35 reproduces.

**Status:** Pre-existing environmental drift in the in-tree Python
runner, not the harness's `geodetestlab` CLI. The harness CLI runner
(invoked via `make test-everything-otel` / `make geodetestlab-comprehensive`)
remains green for these specs.

**Likely cause:** Setup / persistence / server-lifecycle handling has
diverged between the two runners (`extended_test_runner.py` and
`geodetestlab` CLI) since the harness was extracted to its own repo.
`extended_test_runner.py` uses `test_runner_core.start_server` /
`stop_server`; the geodetestlab CLI has its own server-manager path.

**Re-baseline action (follow-up sprint):**

1. Decide whether `extended_test_runner.py` is still authoritative or
   should be deprecated in favour of the harness CLI for spec runs.
2. If keeping it: re-baseline by aligning the runner's setup path with
   the harness CLI (per-spec data dir, persistence reset between tests,
   stdin handling — see `docs/TEST_RUNNER_FIXES_OCTOBER_2025.md` for the
   parallel runner fix history).
3. If deprecating: remove the runner and update CLAUDE.md /
   `make`-target references that still point at it.

### Load-induced 30 s timeouts in `make test-everything-otel` runs (2026-05-07)

Several specs intermittently fail with `Test timed out after 30000ms`
when the harness is run under heavy concurrent load (other CI work
happening on the host, or the harness running with `PARALLEL_WORKERS=1`
back-to-back with shell + load-test phases):

- `gap_0193_priority_categories.yml :: metadata-relationship-types`
  (`CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType LIMIT 10`)
- `gap_153_154_password_security.yml :: gap-0154-user-create-with-explicit-password`
  (`geode user create gap154test gap154@test.com --password SecurePass123!`)
- `geode_migrations.yml :: check-index-usage` setup-0
  (multi-statement `CREATE (:TestNode {id: 1}), ... ; CREATE INDEX IF NOT EXISTS ...`)

**Status:** Confirmed flaky, not deterministic. Re-running each spec in
isolation via `make test-spec SPEC=<file>.yml` produces 52/52, 19/19,
and 30/30 PASS respectively. The `output` field of the failed test is empty, which
is consistent with the geode subprocess still warming up (server
startup, cache hydration, FLE bootstrap) when the per-test 30 s wall
elapses.

**Likely cause:** The harness's `client.timeout_ms: 30000` is the same
as the geode `server.startup_timeout_ms: 30000` for `cli.server.enabled:
true` specs. Under CPU pressure, the server startup path can consume
most of that budget, leaving the first per-test invocation insufficient
runway. The cause is environmental, not a regression in the MR being
validated.

**Re-baseline action (follow-up sprint):**

1. Decouple per-test timeouts from the cli server startup timeout for
   `cli.server.enabled: true` specs — the test-level wall should start
   when the server reports ready, not when the harness records the
   spec start.
2. Optionally bump `client.timeout_ms` to 60 s for these two specs
   while the underlying timeout decoupling lands; revert once the
   harness layer fix is in.
3. Audit any spec that hits the wall by >50% of the test's isolated
   duration — it's the same pattern under load.

## Recently Fixed — Concurrency

### `test-two-phase-edge-lock` :: "two-phase lock: 16 threads beat single-thread by >= 4x" ✅ FIXED (2026-04-27)

- **Test**: `tests/bulk_ingest/test_two_phase_edge_lock.zig:207`
- **Was**: `error.EdgeSlotMappingMissing` from `requireEdgeSlot`; `expected 800, found 434–663` under 16-thread contention
- **Two-part fix landed in the same commit**:
  1. `GraphStore.createEdgeWithGraphAndTenant` (`src/graph_store.zig:2975`) no longer swallows errors from `vt.createEdgeFn` — the silent `catch break :blk null` arms are now `try` / `return error.{Source,Target}NodeNotFound`.
  2. `StorageAdapter.createEdge` (`src/storage/graph_storage_adapter.zig:2105`) only takes the per-shard `addEdgeTxn` fast path when `shardOfNode(from) == shardOfNode(to)`; cross-shard edges fall through to `ShardedGraphEngine.addEdge` → `crossShardAddEdge` (2PC) instead of the broken per-shard route.
- **Verification**: 3/3 tests pass deterministically; 800/800 parallel edges; throughput within 1.5× of the single-thread baseline.
- **Full bug report**: [docs/bugs/2026-04-27-bulk-edge-id-map-silent-fallback.md](bugs/2026-04-27-bulk-edge-id-map-silent-fallback.md) (now marked RESOLVED).

## Recently Fixed Issues

### WITH + Aggregation + WHERE ✅ FIXED (January 2026)

- `with-aggregation`: WITH clause with aggregation and WHERE filter now works correctly
- Test verified: `MATCH (n:Person) WITH n.age AS age, count(*) AS count WHERE count > 0 RETURN age, count`

### CASE Expressions in MATCH ✅ FIXED (January 2026)

- `case-when-then`, `case-with-default`: CASE expressions now work in MATCH context
- Test verified: `MATCH (n:Person) RETURN n.name, CASE WHEN n.age < 30 THEN 'young' ELSE 'senior' END AS category`

### DateTime Property Access ✅ FIXED (January 2026)

- `datetime-operations`: DateTime property access now works
- Test verified: `RETURN datetime('2024-01-15T14:30:00').year AS year, datetime('2024-01-15T14:30:00').month AS month`

### List Functions head()/tail() ✅ FIXED (January 2026)

- `list-functions`: head(), tail(), last() list functions now work correctly
- Test verified: `WITH [1, 2, 3, 4, 5] AS list RETURN head(list) AS first, tail(list) AS rest, size(list) AS length`
- Returns: `{"first":1,"rest":[2,3,4,5],"length":5}`

### Regex Matching (=~) ✅ FIXED (January 2026)

- `where-with-regex`: Regex matching with =~ operator now works
- Test verified: `MATCH (n:Person) WHERE n.name =~ 'A.*' RETURN n.name`
- Supports: anchors (^, $), wildcards (., .*), character classes ([...]), optional (?), escapes (\)

### VALUES Clause ✅ FIXED (January 2026)

- `values-list`, `values-with-match`: VALUES clause now fully implemented
- Test verified: `VALUES (1), (2), (3), (4), (5) AS (number) RETURN number * 2 AS doubled`
- Returns: `{"doubled":2},{"doubled":4},{"doubled":6},{"doubled":8},{"doubled":10}`

### Setup Data Persistence ✅ FIXED (December 2025)

The test harness was modified to ensure setup data persists across all tests within a spec file:

- Persistence files are now cleared once at the start of each spec (before spec-level setup)
- Setup data created in spec-level setup is now available to all tests within that spec
- **34 tests re-enabled** across `nested_queries_basic.yml`, `nested_queries_advanced.yml`, and `recursive_and_cte.yml`

## Categories of Skipped Tests

### 1. Unimplemented Language Features

The following features are skipped because they are not yet implemented:

#### geode_regression_tests.yml (3 tests skipped)

- `pattern-comprehension`: Pattern comprehension list syntax `[(p)-[:KNOWS]->(friend) | friend.name]` not implemented (Cypher extension, not ISO GQL)
- `map-projection`: Map projection syntax `n {.name, .age}` not implemented (Cypher extension, not ISO GQL)
- `path-node-update`: Variable-length path with SET not fully implemented

### 2. Recursive CTEs (WITH RECURSIVE)

Recursive Common Table Expressions are **not currently supported**. The syntax is recognized by the parser but execution is not implemented.

**Workarounds:**

- Use variable-length path patterns: `MATCH (a)-[*1..10]->(b) RETURN a, b`
- Use SHORTEST path mode: `MATCH SHORTEST (a)-[:KNOWS*]->(b) RETURN a, b`
- For hierarchical data, use multiple MATCH patterns with explicit depth limits

**Affected operations:**

- Transitive closure queries
- Hierarchical queries with arbitrary depth
- Path finding with complex conditions

### 3. Remaining Test Failures (67 tests)

The remaining failures are in these spec files:

| Spec File | Failures | Notes |
|-----------|----------|-------|
| gql_expressions_comprehensive.yml | 15 | Expression evaluation edge cases |
| geode_audit_logging_enterprise.yml | 11 | Audit logging features |
| geode_advanced.yml | 10 | Advanced query features |
| gql_pattern_matching_comprehensive.yml | 7 | Pattern matching edge cases |
| gql_type_system_comprehensive.yml | 6 | Type system features |
| geode_functions_comprehensive.yml | 5 | Function implementation gaps |
| geode_quic_transport.yml | 3 | QUIC transport edge cases |
| geode_recent_features.yml | 3 | Recently added features |
| multi_graph.yml | 2 | Multi-graph operations |
| geode_auth_security.yml | 2 | Authentication features |
| geode_index_comprehensive.yml | 1 | Index operations |
| geode_advanced_math_algorithms.yml | 1 | Math algorithm edge cases |
| gql_catalog_operations_comprehensive.yml | 1 | Catalog operations |

## Priority for Fixes

### Completed ✅

1. **WITH + aggregation + WHERE** - Fixed January 2026
2. **CASE expressions in MATCH** - Fixed January 2026
3. **DateTime property access** - Fixed January 2026
4. **List functions (head/tail)** - Fixed January 2026
5. **Regex matching (=~)** - Fixed January 2026
6. **VALUES clause** - Fixed January 2026

### Medium Priority (Remaining)

1. **Recursive CTEs** - Complex feature, use workarounds documented above

### Low Priority (Cypher extensions, not ISO GQL)

1. Pattern comprehension (Cypher syntax)
2. Map projection (Cypher syntax)

## Notes

- Tests marked with `skip: true` are intentionally skipped due to known limitations
- The test infrastructure properly handles skipped tests and excludes them from failure counts
- All skipped tests have comments explaining why they are skipped

## Updating This Document

When fixing a feature, update this document by:

1. Removing the skip marker from the test
2. Running `make geodetestlab-comprehensive` to verify the fix
3. Removing the entry from this document

*Last Updated: 2026-05-07*
