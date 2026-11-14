# EXPLAIN and PROFILE Commands

This document describes the EXPLAIN and PROFILE commands for query analysis and performance profiling in Geode.

## Overview

Geode provides two commands for understanding query execution:

- **EXPLAIN**: Shows the query execution plan without executing the query
- **PROFILE**: Executes the query and returns execution statistics

These commands are essential for query optimization, performance tuning, and understanding how Geode processes your queries.

## EXPLAIN Command

The EXPLAIN command displays the execution plan for a query without actually running it. This is useful for understanding how Geode will execute a query before committing to the execution.

### Syntax

```gql
EXPLAIN <statement>
```

### Basic Examples

**Explain a Simple MATCH Query:**

```gql
EXPLAIN MATCH (p:Person) RETURN p.name
```

**Output:**

```
| plan              |
|-------------------|
| EXPLAIN           |
| MATCH             |
|   NodeScan        |
| RETURN            |
|   Project         |
```

**Explain with WHERE Clause:**

```gql
EXPLAIN MATCH (p:Person) WHERE p.age > 25 RETURN p.name, p.age
```

**Output:**

```
| plan              |
|-------------------|
| EXPLAIN           |
| MATCH             |
|   NodeScan        |
|   Filter          |
| RETURN            |
|   Project         |
```

**Explain Relationship Traversal:**

```gql
EXPLAIN MATCH (p:Person)-[:WORKS_FOR]->(c:Company) RETURN p.name, c.name
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| MATCH                   |
|   NodeScan              |
|   ExpandRelationships   |
| RETURN                  |
|   Project               |
```

### Understanding Plan Output

The execution plan shows the logical operators Geode will use:

- **NodeScan**: Scans all nodes in the graph (or nodes matching a label)
- **ExpandRelationships**: Traverses relationships from source nodes
- **Filter**: Applies WHERE clause predicates to filter results
- **Filter (FILTER clause)**: Applies FILTER clause predicates
- **Project**: Selects and transforms columns for RETURN clause
- **Sort**: Orders results for ORDER BY clause
- **Limit**: Restricts output rows for LIMIT clause
- **Aggregate**: Groups and aggregates data for aggregation functions

### EXPLAIN with Different Statement Types

**CREATE Statement:**

```gql
EXPLAIN CREATE (p:Person {name: 'Alice', age: 30})
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| CREATE                  |
|   CreateNodes           |
|   CreateRelationships   |
```

**DELETE Statement:**

```gql
EXPLAIN MATCH (p:Person) WHERE p.temp = true DELETE p
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| DELETE                  |
|   DeleteNodes           |
```

**MERGE Statement:**

```gql
EXPLAIN MERGE (p:Person {email: 'user@example.com'})
ON CREATE SET p.created = datetime()
ON MATCH SET p.accessed = datetime()
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| ExecuteStatement        |
```

### Advanced Examples

**Complex Query with Aggregation:**

```gql
EXPLAIN MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE p.age > 25
RETURN c.name, count(p) AS employee_count
ORDER BY employee_count DESC
LIMIT 10
```

**Union Query:**

```gql
EXPLAIN
MATCH (p:Person) RETURN p.name AS name
UNION
MATCH (c:Company) RETURN c.name AS name
```

## PROFILE Command

The PROFILE command executes a query and returns execution statistics. Unlike EXPLAIN, PROFILE actually runs the query and provides real metrics about the execution.

### Syntax

```gql
PROFILE <statement>
```

### Basic Examples

**Profile a Simple Query:**

```gql
PROFILE MATCH (p:Person) RETURN p.name
```

**Output:**

```
| metric   | value                 |
|----------|-----------------------|
| profile  | planned_query_profile |
| rows     | 42                    |
| columns  | 1                     |
| time_ns  | 184213                |
| operators| 2                     |
```

### Profiling Metrics

PROFILE has two result shapes, both real measurements (GAP-0868, 2026-06-10):

**Planned reads** (`profile = planned_query_profile`) — storage-native read
queries execute through the planned runtime, which carries a per-operator
`RuntimeTrace` (each operator records `input_rows`, `rows`, and `time_ns`):

1. **rows**: Number of rows returned by the query
2. **columns**: Number of columns in the result set
3. **time_ns**: Total measured execution time in nanoseconds (sum of the
   per-operator trace)
4. **operators**: Number of operators in the executed plan

**Statement fallback** (`profile = query_profile`) — non-query statements
under PROFILE (e.g. `PROFILE SHOW TABLES`) and reads demoted to the legacy
tenant-aware executor by a concrete tenant scope (GAP-0846/GAP-0509):

1. **rows**: Number of rows returned by the statement
2. **columns**: Number of columns in the result set
3. **time_ms**: Real wall-clock execution time in milliseconds, measured with
   `CLOCK_MONOTONIC` around the wrapped statement's execution (parse time and
   profile-row construction are excluded)

The QUIC wire protocol additionally emits a richer per-operator profile
payload (`profile_version`, per-op `time_ns`, `rows`, memory totals) for
profiled queries — see `src/server/profile_payload.zig`.

### Index names in the profile payload

The wire payload names an index only when the executor used it, and the name
is always a catalog index (one SHOW INDEXES lists). There is no placeholder
name (SONNY-1335).

- **`profile_version` 2** (planned reads, from the runtime trace): the scan
  operator is set from how the executor collected the start nodes. It is
  `IndexSeek`, with `index_name` the catalog index, only when they came from
  an index seek on a label and property that a `btree` or `hash` catalog
  index covers (the first indexed property; when several such indexes exist,
  the smallest name). Otherwise it is `LabelScan` or `AllNodesScan`: no
  catalog index on that label and property, an index on another label or
  property, a `fulltext`, vector or spatial index (they do not serve an
  equality), a dropped index, or a WHERE whose equality is not the whole
  WHERE (the executor seeks on `WHERE n.p = v` and on an inline property
  map, and scans for `WHERE n.q > 1 AND n.p = v`). An equality the engine's
  internal exact-property lookup answers without a declared index reports
  a scan, as EXPLAIN does. `selectivity_est` is 0 (not estimated).
- **`profile_version` 1** (tenant-bound and RLS-evaluating sessions, data
  changes, statement targets the planned runtime declines): the payload
  comes from the legacy executor, which never consults the index catalog
  and scans, so it has no index operator. Before SONNY-1335 it put a
  `NodeIndexScan` named `"heuristic_index"` first for any WHERE or FILTER
  equality. Its per-operator timings and memory figures remain the
  synthetic model described under Current Limitations, so a version-1
  payload is not evidence of an access path; a client that needs that
  evidence should require version 2.

Catalog index rows carry no graph: the name reported is the catalog's row
for the label and property, whichever graph the session is on.

### Examples by Query Type

**Profile with Aggregation:**

```gql
PROFILE MATCH (p:Person) RETURN count(p) AS person_count
```

**Profile with WHERE Clause:**

```gql
PROFILE MATCH (p:Person) WHERE p.age > 30 RETURN p.name, p.age
```

**Profile Relationship Traversal:**

```gql
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE c.industry = 'Technology'
RETURN p.name, c.name
```

**Profile CREATE Statement:**

```gql
PROFILE CREATE (p:Person {name: 'Bob', age: 35})
```

**Output:**

```
| metric   | value                 |
|----------|-----------------------|
| profile  | planned_query_profile |
| rows     | 0                     |
| columns  | 0                     |
| time_ns  | 91342                 |
| operators| 1                     |
```

**Profile Empty Result:**

```gql
PROFILE MATCH (p:NonExistent) RETURN p
```

**Output:**

```
| metric   | value                 |
|----------|-----------------------|
| profile  | planned_query_profile |
| rows     | 0                     |
| columns  | 1                     |
| time_ns  | 47012                 |
| operators| 2                     |
```

(`time_ns` values are real measurements and will vary run to run.)

### Performance Analysis Examples

**Compare Different Query Approaches:**

```gql
-- Approach 1: Filter in WHERE
PROFILE MATCH (p:Person) WHERE p.age > 30 RETURN p.name

-- Approach 2: Filter with label test
PROFILE MATCH (n) WHERE n:Person AND n.age > 30 RETURN n.name
```

**Analyze Join Performance:**

```gql
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company),
              (p)-[:LIVES_IN]->(city:City)
WHERE c.industry = 'Tech' AND city.country = 'USA'
RETURN p.name, c.name, city.name
```

**Test Pagination Impact:**

```gql
-- Without LIMIT
PROFILE MATCH (p:Person) RETURN p.name ORDER BY p.name

-- With LIMIT
PROFILE MATCH (p:Person) RETURN p.name ORDER BY p.name LIMIT 100
```

## Implementation Details

### Parser

Both EXPLAIN and PROFILE are parsed as top-level statements that wrap another statement.

**Parser Functions (parser.zig:2554-2572):**

```zig
fn parseExplainStatement(self: *Parser) ParserError!ast.Statement {
    _ = try self.expect(.EXPLAIN);
    const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
    query_stmt_ptr.* = try self.parseStatement();
    return .{ .Explain = .{ .query = query_stmt_ptr } };
}

fn parseProfileStatement(self: *Parser) ParserError!ast.Statement {
    _ = try self.expect(.PROFILE);
    const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
    query_stmt_ptr.* = try self.parseStatement();
    return .{ .Profile = .{ .query = query_stmt_ptr } };
}
```

### AST Structures

**AST (ast.zig:46-47):**

```zig
pub const Statement = union(enum) {
    // ... other statements ...
    Explain: ExplainStatement,
    Profile: ProfileStatement,
    // ... other statements ...
};

pub const ExplainStatement = struct {
    query: *Statement,
};

pub const ProfileStatement = struct {
    query: *Statement,
};
```

### Execution

**EXPLAIN Execution (execution.zig:863-940):**

The `executeExplain` function analyzes the wrapped statement and generates a plan description based on the query structure:

- **Query statements**: Show MATCH, NodeScan, ExpandRelationships, Filter, RETURN, Project operators
- **CREATE statements**: Show CREATE, CreateNodes, CreateRelationships
- **DELETE statements**: Show DELETE, DeleteNodes
- **Other statements**: Show generic ExecuteStatement

**PROFILE Execution (execution.zig:942-988):**

The `executeProfile` function:

1. Executes the wrapped query using `executeStatementWithContext`
2. Collects execution metrics (rows returned, column count)
3. Returns statistics as a result set with two columns: metric and value

**Execution Handlers (execution.zig:646-651):**

```zig
.Explain => |exp| {
    return executeExplain(allocator, exp, context);
},
.Profile => |prof| {
    return executeProfile(allocator, prof, context);
},
```

## Use Cases

### Query Optimization

Use EXPLAIN to understand which operators are being used and identify potential bottlenecks:

```gql
-- Check if index is being used
EXPLAIN MATCH (p:Person {email: 'user@example.com'}) RETURN p

-- Verify filter order
EXPLAIN MATCH (p:Person)-[:KNOWS]->(f:Person)
WHERE p.age > 25 AND f.age > 25
RETURN p.name, f.name
```

### Performance Tuning

Use PROFILE to measure actual execution performance:

```gql
-- Measure query before optimization
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE c.name = 'Acme'
RETURN p.name

-- Measure after adding index
-- CREATE INDEX ON :Company(name)
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE c.name = 'Acme'
RETURN p.name
```

### Understanding Behavior

Use both commands to understand how Geode processes complex queries:

```gql
-- Understand plan
EXPLAIN MATCH (p:Person)
WHERE p.age > 30 OR p.department = 'Engineering'
RETURN p.name, p.age
ORDER BY p.age DESC
LIMIT 50

-- Verify actual execution
PROFILE MATCH (p:Person)
WHERE p.age > 30 OR p.department = 'Engineering'
RETURN p.name, p.age
ORDER BY p.age DESC
LIMIT 50
```

## Testing

Comprehensive unit tests are available in:

- `geodetestlab/specs/explain_profile_unit_tests.yml`

Test coverage includes:

- EXPLAIN with various query types (MATCH, CREATE, DELETE, MERGE)
- EXPLAIN with WHERE, ORDER BY, LIMIT clauses
- EXPLAIN with relationships and complex patterns
- PROFILE execution with metric validation
- PROFILE with aggregation and filtering
- Edge cases (empty results, union queries)

## GQL Compliance

These features implement ISO/IEC 39075:2024 GQL standard query explanation capabilities:

- EXPLAIN statement for query plan visualization
- PROFILE statement for execution profiling
- Query optimization hints and analysis

## What Is Estimated vs Heuristic (GAP-0867, 2026-06-10)

Be precise about provenance when reading any cost or row number Geode reports:

- **GQL `EXPLAIN` statement costs are fixed heuristic constants**, not measured
  statistics: NodeScan=100, IndexSeek=10, ExpandRelationships=50/hop,
  Filter=10, Aggregate=200, Sort=150, Limit=5, Distinct=100, Project=5
  (`src/execution/statement_handlers.zig:executeExplain`). The IndexSeek vs
  NodeScan decision IS real — it checks the live index catalog for an index
  matching the pattern's label+property (including WHERE equality predicates) —
  but the cost numbers attached are model constants.
- **Index selection at runtime is rule-based, not cost-based.** A pattern
  with a UNIQUE-indexed literal-equality property is seeked through the merge
  index (`src/execution/match_operations.zig`,
  `zig build test-multi-pattern-index-seek`); otherwise the label is scanned.
  `chooseIndexForPredicate` (`src/server/index_catalog.zig`) only considers an
  index when the predicate references the indexed property, but no query path
  calls it (only `zig build test-gap0867` does). The cost-based
  `src/server/index_optimizer.zig` this paragraph used to cite was never
  compiled and was removed (SONNY-6298).
- **`StatsRegistry` row statistics are real when collected**:
  `analyzeTable()` counts live rows from the graph store (per-label counts via
  `GraphStore.countNodesByLabel`); `analyzeTableWithProvider()` /
  `injectTableStats()` record caller-supplied values.
  `cbo.explainEstimateJSON()` (`src/planner/cbo.zig`) emits per-scan-node
  `estimated_rows` and labels each one with its provenance:
  `"statistics"` (collected), `"default_heuristic"` (no stats for the label),
  or `"heuristic_avg_degree"`/`"heuristic_selectivity"` (documented model
  constants for expand/filter). Regression: `zig build test-gap0867`.
- **Calibration objects are only emitted when actual row counts exist**:
  `explainChainWithCalibration` (`src/planner/cost_explain.zig`) omits the
  `calibration` block entirely when no runtime actuals are supplied (it
  previously emitted a stub `{"mape":0,"entries":[]}` that looked like a
  perfect calibration). Runtime calibration feedback into the planner is a
  documented future item, not a current feature.

## Current Limitations

1. **Heuristic EXPLAIN costs**: the GQL `EXPLAIN` statement's per-operator costs are the fixed constants listed above, not statistics-derived estimates
2. **Statement-fallback PROFILE has no per-operator breakdown**: real
   per-operator timing exists for planned reads (`RuntimeTrace` per-op
   `time_ns`/`rows`, surfaced in the QUIC profile payload), but the
   statement-level fallback path (non-query statements under PROFILE, and
   reads demoted by a concrete tenant scope) executes through the generic
   dispatcher, which exposes no operator hooks — it reports real
   statement-level wall-clock `time_ms` only (GAP-0868 residual)
3. **No Memory Usage in statement-level PROFILE rows**: memory totals are
   only available in the QUIC wire profile payload, not the metric/value rows
4. **QUIC wire profile memory numbers are a deterministic synthetic model,
   not measured allocations** (GAP-0874 decision, 2026-06-10): the fallback
   profile path (`src/server/profile_payload.zig:buildProfilePayload`) derives
   per-op `bytes_alloc`, `peak_bytes`, `total_alloc_bytes`, `net_bytes`, and
   the `mem_curve` from a fixed per-op model so the wire shape and its
   internal invariants stay deterministic and testable (pinned by
   `tests/e2e_protocol_profile_schema_validate.zig`,
   `e2e_protocol_profile_memcurve_invariants.zig` and
   `profile_allocator_sums.zig` in `zig build test-sonny6542-revived`; the
   rest of the `e2e_protocol_profile_*` battery never ran and was removed,
   SONNY-6548); the trace-backed v2 path reports
   honest zeros for memory. Real per-op attribution would require
   per-operator allocator threading — a PROFILE redesign, not planned. Real
   process-level memory telemetry is available via the OTel
   `process.runtime.zig.memory.resident_set` gauge (`/proc/self`-backed)
5. **No automatic ANALYZE**: `StatsRegistry.analyzeTable()` must be invoked by the caller; statistics are not refreshed automatically on write

## Future Enhancements

- **Cost-Based Plans**: Include estimated costs and row counts per operator
- **Per-Operator Stats in the fallback path**: per-operator metrics for non-query statements and tenant-demoted reads (planned reads already have them)
- **Memory Profiling**: Track memory allocation and usage
- **Index Usage**: Show which indexes are being used in the plan
- **Warnings**: Detect and warn about potential performance issues
- **Visual Plans**: Tree or graph visualization of query plans
- **Comparison Mode**: Compare plans for different query formulations

## See Also

- [Session Management](SESSION_MANAGEMENT.md)
- [Transaction Management](TRANSACTION_MANAGEMENT.md)
- [MERGE Operations](MERGE_AND_LABEL_TESTS.md)
- [GQL Compliance](GQL_COMPLIANCE.md)
