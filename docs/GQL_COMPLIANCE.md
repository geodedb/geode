# GQL ISO/IEC 39075:2024 Compliance Guide

Geode passes **96/96 cases of its ISO/IEC 39075:2024 GQL conformance suite** (parse-only scope) (`tests/gql_iso_conformance.zig`), making it one of the most standards-aligned GQL implementations available. "100%" below refers to that named conformance suite — not a blanket claim of full ISO coverage; documented residual limits (e.g. recursive-CTE working-set model, no `SEARCH`/`CYCLE`, Cypher-only extensions intentionally excluded) are listed in this guide.

## 📊 Compliance Overview

- **Conformance suite**: 96/96 cases pass (the named `tests/gql_iso_conformance.zig` suite; parse-only scope — it asserts the parser accepts/rejects each form, not executed-query results)
- **Standard**: ISO/IEC 39075:2024 Graph Query Language
- **Scope**: this is the curated conformance suite, not exhaustive ISO coverage; see residual limits in this guide
- **How to run**: `zig build test-iso-conformance --summary all` (dedicated named step; 96/96 verified 2026-06-11). The executed-query `gql_conformance` harness suite is 20/20 after GAP-0892 (`zig build test-gql-conformance`)
- **Last Updated**: 2026-06-10 (GAP-0861 claim rebaseline)

## ✅ Fully Supported Features

### Core Keywords (105+ supported)

All ISO GQL reserved keywords are recognized and functional:

```gql
-- Query keywords
MATCH, OPTIONAL, WHERE, RETURN, WITH, ORDER, BY, LIMIT, OFFSET, DISTINCT

-- Data manipulation
CREATE, DELETE, DETACH, SET, REMOVE, MERGE, ON, MATCH

-- Aggregation
COUNT, SUM, AVG, MIN, MAX, GROUP, HAVING

-- Transactions
START, TRANSACTION, COMMIT, ROLLBACK

-- Session management
USE, GRAPH, SESSION

-- Path quantifiers
ANY, SHORTEST, ALL, WALK, TRAIL, ACYCLIC, SIMPLE

-- And many more...
```

### Case-Sensitivity Contract

Per **ISO/IEC 39075:2024 RQ-0022**, GQL reserved keywords are recognized
case-insensitively. Geode extends the same contract to built-in functions
and stored procedures so the entire language surface behaves uniformly.
User-defined identifiers (labels, property keys, variable names) remain
case-sensitive — `:Person` and `:person` are distinct labels and `p.Name`
and `p.name` are distinct properties, matching the convention used by
SQL, Cypher, and Neo4j.

| Surface                      | Case Behavior     | Examples that resolve identically                          |
|------------------------------|-------------------|-------------------------------------------------------------|
| Reserved keywords            | **Insensitive**   | `MATCH` / `match` / `MaTcH`, `RETURN` / `return`            |
| Type names                   | **Insensitive**   | `INTEGER` / `integer`, `STRING` / `string`, `BOOLEAN`       |
| Boolean / null literals      | **Insensitive**   | `TRUE` / `true`, `FALSE` / `false`, `NULL` / `null`         |
| Built-in functions           | **Insensitive**   | `count()` / `COUNT()` / `Count()`, `abs(-5)` / `ABS(-5)`    |
| Stored procedures (CALL)     | **Insensitive**   | `algo.pageRank.stream()` / `ALGO.PAGERANK.STREAM()`         |
| Procedure aliases            | **Insensitive**   | `pagerank` / `PAGERANK` / `PageRank` (all map to the alias) |
| **User identifiers** below — |                   |                                                             |
| Labels                       | **Sensitive**     | `:Person` ≠ `:person` (two different labels)                |
| Property keys                | **Sensitive**     | `n.name` ≠ `n.Name` (two different properties)              |
| Variable / alias names       | **Sensitive**     | `(p)` ≠ `(P)` (two different bindings)                      |
| Role names (RBAC)            | **Sensitive**     | `ADMIN` ≠ `admin` (security policy decision)                |
| FLE field names              | **Sensitive**     | encrypted-field metadata is matched verbatim                |

**Where this is enforced:**

- **Lexer** — `src/gql/lexer.zig:keywordKind` calls `std.ascii.toUpper`
  on every identifier and looks the result up in a comptime `KeywordMap`
  whose entries are uppercase, so all 150+ keywords match any case.
- **Function registry** — `src/gql/language_metadata.zig:findFunction`
  uses `std.ascii.eqlIgnoreCase` (matches `findKeyword` and `findType`
  which were already case-insensitive).
- **Procedure registry** — `src/execution/procedure_registry.zig:executeCallProcedure`
  calls `extractNormalizedProcName` which ASCII-lowercases the procedure
  name once at the dispatch entry point, so every domain dispatcher
  (`algo_dispatch`, `audit_dispatch`, `storage_dispatch`, `auth_dispatch`)
  can keep its existing exact-match comparisons against canonical
  lowercase literals.
- **Function evaluator** — `src/eval.zig` uses `std.ascii.eqlIgnoreCase`
  throughout the function dispatch path so any uppercase or mixed-case
  spelling that escapes the first-pass handler still resolves correctly.
- **Tests** — `tests/test_procedure_case_insensitive.zig` covers
  ABS/COALESCE/SUBSTRING/TRIM (eval path), `findFunction`/`findProcedure`
  (metadata path), and `extractNormalizedProcName` (dispatch path) with
  uppercase, lowercase, and mixed-case inputs.

### Data Types & Literals

```gql
-- Primitive types
RETURN true, false, null
RETURN 42, -123, 3.14, 'hello world'

-- Temporal types
RETURN date('2024-01-15')
RETURN datetime('2024-01-15T14:30:00')
RETURN time('14:30:00')

-- Collections
RETURN [1, 2, 3]
RETURN {name: 'Alice', age: 30}
```

### Graph Pattern Matching

```gql
-- Basic patterns
MATCH (person:Person) RETURN person

-- Relationship patterns
MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a, b

-- Variable-length paths
MATCH (a)-[*1..3]->(b) RETURN a, b
MATCH (a)-[*..5]->(b) RETURN a, b
MATCH (a)-[*2..]->(b) RETURN a, b

-- Path variables
MATCH path = (a)-[:KNOWS]->(b) RETURN path

-- Multiple patterns
MATCH (a)-[]->(b), (b)-[]->(c) RETURN a, b, c

-- Optional matching
OPTIONAL MATCH (n)-[]->(m) RETURN n, m
```

### Operators & Expressions

```gql
-- Comparison operators
RETURN 1 = 1, 2 <> 2, 3 < 4, 5 >= 5

-- Logical operators  
RETURN true AND false, true OR false, NOT true

-- Arithmetic operators
RETURN 1 + 2 - 3 * 4 / 5

-- String operators
RETURN 'hello' || ' world'
RETURN 'hello' STARTS WITH 'he'
RETURN 'world' ENDS WITH 'ld'
RETURN 'hello world' CONTAINS 'lo wo'

-- Pattern matching
RETURN text =~ 'pattern.*'

-- Set operations
RETURN 1 IN [1, 2, 3]
RETURN x IS NULL
```

### Built-in Functions

#### Aggregation Functions

```gql
RETURN COUNT(*), COUNT(DISTINCT n.id)
RETURN SUM(n.value), AVG(n.age)
RETURN MIN(n.score), MAX(n.score)
```

#### String Functions

```gql
RETURN length('hello'), upper('world'), lower('HELLO')
RETURN substring('hello', 1, 3), replace('hello world', 'world', 'universe')
RETURN trim(' text '), reverse('hello'), split('a,b,c', ',')
```

#### Math Functions

```gql
RETURN abs(-5), sqrt(16), ceil(3.2), floor(3.8), round(3.5)
RETURN sign(-5), log(10), exp(2), rand()
```

#### List Functions

```gql
RETURN size([1,2,3]), head([1,2,3]), tail([1,2,3]), last([1,2,3])
RETURN range(1, 10)
```

#### Type Functions

```gql
RETURN type(value), exists(n.property)
RETURN toString(123), toInteger('456')
```

#### Utility Functions

```gql
RETURN now(), rand()
```

### Data Manipulation Language (DML)

```gql
-- Creating nodes and relationships
CREATE (alice:Person {name: 'Alice', age: 30})
CREATE (alice)-[:KNOWS]->(bob)

-- Setting properties
MATCH (n:Person) SET n.updated = now()
MATCH (n) SET n.property = value

-- Removing properties
MATCH (n) REMOVE n.temporary_field

-- Deleting elements
MATCH (n:Person) DELETE n
MATCH (n) DETACH DELETE n

-- Merge (upsert) operations
MERGE (person:Person {email: 'alice@example.com'})
ON CREATE SET person.created = datetime()
ON MATCH SET person.last_seen = now()
```

### Query Composition

```gql
-- WITH clauses for query chaining
MATCH (person:Person)
WITH person.name AS name, count(person) AS count
WHERE count > 1
RETURN name, count

-- Ordering and pagination
MATCH (n:Person)
RETURN n.name, n.age
ORDER BY n.age DESC, n.name ASC
LIMIT 10 OFFSET 20

-- Grouping and aggregation
MATCH (person:Person)-[:WORKS_AT]->(company:Company)
RETURN company.name, COUNT(person) AS employees
ORDER BY employees DESC
```

### Common Table Expressions (`WITH [RECURSIVE]`)

Geode executes both simple and recursive Common Table Expressions
(ISO/IEC 39075:2024 §7.18). A CTE's result is bound under its name as a list
value (one map per produced row) and is reachable from the main query and, for
recursive CTEs, from the recursive term via `UNWIND <cte> AS x`.

```gql
-- Simple (non-recursive) CTE: body runs once, bound as a named list value.
WITH evens AS (RETURN 2 AS n)
RETURN evens

-- Recursive CTE: anchor seeds the working set; the recursive term self-
-- references it with UNWIND and is re-run to a fixpoint. A WHERE in the
-- recursive term bounds the recursion (terminates by predicate). This yields
-- n = 1..5:
WITH RECURSIVE nums AS (
  RETURN 1 AS n
  UNION ALL
  UNWIND nums AS prev WHERE prev.n < 5 RETURN prev.n + 1 AS n
)
RETURN nums

-- Reachability / transitive closure: encode the successor relation in the
-- recursive term. Over a 1->2->3->4 chain, reachability from node 1 (anchor =
-- first hop, node 2) yields {2, 3, 4}:
WITH RECURSIVE reach AS (
  RETURN 2 AS node
  UNION
  UNWIND reach AS r WHERE r.node < 4 RETURN r.node + 1 AS node
)
RETURN reach
```

Verified semantics (regression-covered by `tests/e2e_recursive_queries.zig`,
the `test-recursive-cte` build step):

- **Fixpoint evaluation** — execute the anchor, then re-run the recursive term
  against only the previous iteration's NEW rows (the delta working set),
  accumulating each iteration's output into the final result, until an iteration
  produces no new rows (or the iteration cap is reached).
- **`WHERE` in the recursive term IS applied** — it bounds/terminates the
  recursion by predicate (transitive closure, bounded depth).
- **`UNION ALL` vs `UNION`** — `UNION ALL` keeps every produced row; `UNION`
  deduplicates against the accumulated set, which also terminates a cycle whose
  step only revisits already-seen rows.
- **Cycle safety via an iteration cap** — a cyclic `UNION ALL` recursion with no
  predicate is bounded by a hard cap of **100 iterations** (the
  `RECURSIVE_CTE_MAX_ITERATIONS` constant in
  `src/execution/query_execution.zig`); it terminates with a finite, capped
  result rather than hanging.

Residual limits (not yet supported / not covered):

- The recursive term operates on the working-set **list value** (consumed with
  `UNWIND`), not directly on live graph nodes. Graph reachability is modeled by
  encoding the successor relation (arithmetic / `CASE`) in the recursive term.
  Driving a recursive CTE off live `MATCH`-ed graph edges, and SQL-style
  `SEARCH` / `CYCLE` clauses, are not implemented.
- Property access on the bound CTE value (`RETURN cte.col`) returns the list,
  not per-row columns; use `UNWIND <cte> AS x` to project rows.
- For arbitrary-depth graph traversal prefer variable-length path patterns
  (`MATCH (a)-[:REL*1..10]->(b)`) or `MATCH SHORTEST`.

### Session & Transaction Management

```gql
-- Session management
USE GRAPH social_network
SET SESSION GRAPH = 'production'

-- Transaction control
START TRANSACTION
MATCH (n:Person) SET n.processed = true
COMMIT

-- Alternative rollback
START TRANSACTION
CREATE (n:Test)
ROLLBACK
```

### Procedure Calls

```gql
-- Basic procedure calls
CALL db.labels()
CALL db.propertyKeys()

-- With YIELD clause
CALL db.labels() YIELD label
RETURN label ORDER BY label

-- With RETURN clause
CALL db.schema.nodeTypeProperties()
YIELD nodeType, propertyName, propertyTypes
RETURN nodeType, collect(propertyName) AS properties
```

## 🔧 Advanced Features

### Path Quantifiers

Variable-length path patterns with full quantifier support:

```gql
-- Any length
MATCH (a)-[*]->(b) RETURN a, b

-- Exact length
MATCH (a)-[*3]->(b) RETURN a, b

-- Range with both bounds
MATCH (a)-[*2..5]->(b) RETURN a, b

-- Range with lower bound only
MATCH (a)-[*3..]->(b) RETURN a, b

-- Range with upper bound only  
MATCH (a)-[*..4]->(b) RETURN a, b
```

### Error Handling

Comprehensive syntax validation with clear error messages:

```gql
-- Invalid syntax examples (will fail with clear errors)
MATCH (n:) RETURN n           -- Missing label name
RETURN (1 + 2                 -- Unclosed parenthesis
RETURN MATCH                  -- Reserved keyword as identifier
```

## ✅ Complex Path Variable Assignment (Fixed January 2026)

Complex path variable assignment with labels, relationship types, and variable-length patterns now works correctly:

```gql
-- This pattern now works (GAP-0182 resolved)
MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person)
RETURN a.name, b.name, length(path)

-- All variations work correctly:
MATCH path = (a)-[*2..4]->(b) RETURN path
MATCH path = (a:Person)-[:KNOWS]->(b:Person) RETURN path
MATCH path = (a:Person)-[:KNOWS*1..3]->(b:Person) RETURN length(path) AS hops, b.name AS reachable
```

**Implementation Evidence:**

- Path variable binding in `src/execution/match_operations.zig:5320-5380`
- `length(path)` function in `src/eval.zig:3197-3205`
- Comprehensive tests in `geodetestlab/specs/gap_0180_0182_fixes.yml`

### Path Mode Specifiers

**Fully implemented as of January 2026** per ISO/IEC 39075:2024:

```gql
-- All path modes parsed AND executed with correct semantics
MATCH SHORTEST (a)-[*]->(b) RETURN a, b      -- Shortest path (Dijkstra-based)
MATCH ANY SHORTEST (a)-[*]->(b) RETURN a, b  -- Any shortest path
MATCH WALK (a)-[*]->(b) RETURN a, b          -- No restrictions (can revisit nodes/edges)
MATCH TRAIL (a)-[*]->(b) RETURN a, b         -- Edges cannot repeat
MATCH ACYCLIC (a)-[*]->(b) RETURN a, b       -- No repeated nodes (no cycles)
MATCH SIMPLE (a)-[*]->(b) RETURN a, b        -- No repeated nodes except start=end allowed
```

**Implementation Details**:

- Path modes stored in AST `Chain.path_mode` field
- `expandVariableLengthPathsWithMode()` in execution.zig handles all modes
- WALK allows full revisitation for graph exploration
- TRAIL ensures edge uniqueness for traversal analysis
- ACYCLIC prevents all cycles (default for backward compatibility)
- SIMPLE enables cycle detection (start node can equal end node)

## 🧪 Testing & Validation

### Running Compliance Tests

```bash
# Run the full compliance test suite
zig run test_gql_compliance.zig

# Debug specific syntax issues
zig run debug_set_parsing.zig

# Run all tests including compliance
make test
```

### Test Categories

The compliance suite tests these areas:

1. **Keywords**: All 105+ ISO GQL reserved words
2. **Data Types**: Primitive and complex type literals
3. **Graph Patterns**: Node, relationship, and path patterns
4. **Operators**: Comparison, logical, arithmetic, string
5. **Functions**: Aggregation, string, math, list, type functions
6. **Query Clauses**: WITH, ORDER BY, LIMIT, DISTINCT, etc.
7. **DML Operations**: CREATE, DELETE, SET, REMOVE, MERGE
8. **Session Management**: USE GRAPH, SET SESSION
9. **Transactions**: START, COMMIT, ROLLBACK
10. **Complex Queries**: Multi-clause and nested patterns

### Expected Output

```
🔍 GQL ISO/IEC 39075:2024 Compliance Test Suite
================================================

✅ MATCH keyword
✅ WHERE keyword
✅ CREATE keyword
... (96 passing tests)

==================================================
COMPLIANCE SUMMARY
==================================================
✅ Passed: 96
❌ Failed: 0
📊 Total:  96

🟢 Named conformance suite green (parse-only scope)
See residual limits in this guide — not a blanket full-ISO claim
```

## 📚 Additional Resources

- **ISO/IEC 39075:2024**: Official Graph Query Language standard
- **Test Files**:
  - `test_gql_compliance.zig` - Main compliance test suite
  - `debug_set_parsing.zig` - Debug utilities for syntax testing
- **Implementation Files**:
  - `src/gql/token.zig` - Lexer with all GQL keywords
  - `src/gql/parser.zig` - Parser with complete syntax support
  - `src/gql/ast.zig` - AST structures for all GQL constructs

## 🚫 Residual Limits — Intentionally Unsupported Statements (GAP-0871)

These forms parse but are refused with a **stable, documented contract** — not
silently ignored and not a moving target:

- **GQL `BACKUP ... TO` / `RESTORE ... FROM` statements are unsupported.** The
  parser accepts the forms (including `WITH INCREMENTAL/COMPRESSED/ENCRYPTED`,
  `VERIFY ONLY`, and `TO TIMESTAMP '<ts>'`), and the executor refuses every one
  with the named error `GqlBackupRestoreUnsupported`, surfaced on the wire as
  SQLSTATE **`0A000`** ("feature not supported") with a message naming the
  supported alternative. **The supported surface is the engine-backed CLI:**
  `geode backup create --output <file>` and `geode restore <file>` (S3 /
  DigitalOcean Spaces targets included). Regression:
  `tests/test_gap0871_gql_backup_refusal.zig` (`zig build test-gap0871`).
- **Recursive CTE `SEARCH` / `CYCLE` clauses are not implemented.**
  `WITH RECURSIVE` follows the working-set list-value model documented under
  [Common Table Expressions](#common-table-expressions-with-recursive) above:
  the recursive term operates on the accumulated working-set value (consumed
  with `UNWIND`), cycle safety comes from the 100-iteration hard cap
  (`RECURSIVE_CTE_MAX_ITERATIONS`), and depth/breadth ordering (`SEARCH`) or
  explicit cycle-mark columns (`CYCLE`) are unavailable. For arbitrary-depth
  graph traversal prefer variable-length path patterns
  (`MATCH (a)-[:REL*1..10]->(b)`) or `MATCH SHORTEST`.

## 🚀 Future Enhancements

All core GQL features are now fully implemented. Future work focuses on:

1. **Advanced Functions**: Additional built-in functions as they are standardized
2. **Performance Optimization**: Continued query execution performance improvements
3. **Extended Compliance**: Support for future GQL standard extensions
4. **GPU Acceleration**: Hardware-accelerated graph traversal operations

Geode's 96/96 ISO conformance-suite pass rate (parse-only scope) and broad GQL feature coverage make it a strong choice for graph applications that need standards-aligned query language support. Single-tenant deployments are development-ready; review the [Known Limitations](../CLAUDE.md#known-limitations) (multi-tenant, distributed cluster, backup) before production deployment.
