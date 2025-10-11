# Geode Test Failure Analysis - October 11, 2025

## Executive Summary

**Total Test Failures**: 162 out of 1710 tests (87.6% pass rate)

This analysis identifies 5 high-impact failure categories representing opportunities to fix 20-90+ tests with focused implementation efforts. All failures are categorized by root cause with estimated impact and recommended priority order.

---

## Failure Categories

### Category 1: Missing GQL Syntax Features
**Impact**: 91 tests (56% of all failures)
**ISO GQL Compliance**: YES - Core ISO/IEC 39075:2024 features

#### Breakdown by Feature

| Feature | Count | Priority |
|---------|-------|----------|
| CREATE INDEX variations | 15 | HIGH |
| FOR loop/binding | 9 | HIGH |
| CREATE CONSTRAINT | 7 | HIGH |
| Authentication/Security flags | 6 | MEDIUM |
| Graph algorithm patterns | 6 | MEDIUM |
| SET SESSION GRAPH / USE GRAPH | 5 | MEDIUM |
| Complex nested queries | 5 | LOW |
| LET variable binding | 3 | MEDIUM |
| START TRANSACTION modes | 3 | MEDIUM |
| OPTIONAL MATCH | 2 | LOW |
| VALUES clause | 2 | MEDIUM |
| Single-quoted strings | 2 | LOW |
| Map projection (n {.prop}) | 1 | LOW |
| SET node = {...} | 1 | LOW |
| UNION ALL with ORDER BY | 1 | LOW |
| Other miscellaneous | 25 | VARIES |

#### Detailed Feature Analysis

##### 1.1 CREATE INDEX Variations (15 failures)
**Specs Affected**: geode_migrations.yml, geode_advanced_features.yml, geode_index_comprehensive.yml

**Syntax Variants Needed**:
```gql
-- GQL standard syntax for node indexes
CREATE INDEX person_name_idx FOR (p:Person) ON (p.name)

-- Relationship indexes
CREATE INDEX works_for_since_idx FOR ()-[r:WORKS_FOR]-() ON (r.since)

-- With index type specifiers
CREATE INDEX subnet_trie ON Server USING PatriciaTrie (subnet)
CREATE INDEX location_rtree ON POI USING RTree (location)
CREATE INDEX embedding_hnsw ON Document USING HNSW (embedding) WITH (metric = 'cosine')

-- Neo4j compatibility syntax
CREATE INDEX person_name_idx ON :Person(name) USING BTREE
```

**Root Cause**: Parser doesn't support the GQL `FOR (pattern) ON (properties)` syntax, only the simpler `ON :Label(prop)` variant.

##### 1.2 FOR Loop/Binding (9 failures)
**Specs Affected**: gql_query_comprehensive.yml, geode_performance_stress.yml, geode_index_comprehensive.yml

**Syntax**:
```gql
MATCH (p:Person)
WITH p.name AS person_name
FOR name IN person_name
RETURN name
```

**Root Cause**: `FOR` keyword and loop constructs not implemented in parser.

##### 1.3 CREATE CONSTRAINT (7 failures)
**Specs Affected**: geode_advanced_features.yml, geode_migrations.yml

**Syntax**:
```gql
-- UNIQUE constraint
CREATE CONSTRAINT person_email_unique
FOR (p:Person)
REQUIRE p.email IS UNIQUE

-- NODE KEY constraint (composite uniqueness)
CREATE CONSTRAINT company_key
FOR (c:Company)
REQUIRE (c.name, c.founded) IS NODE KEY

-- Property existence constraint
CREATE CONSTRAINT person_name_exists
FOR (p:Person)
REQUIRE p.name IS NOT NULL
```

**Root Cause**: `CONSTRAINT` keyword and constraint DDL not implemented.

##### 1.4 Graph Algorithm Patterns (6 failures)
**Specs Affected**: geode_graph_algorithms.yml

**Syntax**:
```gql
-- Count all relationships connected to a node
MATCH (n:Node)
RETURN n.name, size((n)--()) AS degree
ORDER BY degree DESC

-- Pattern comprehension for degree centrality
MATCH (n)
RETURN n, [(n)--(m) | m] AS neighbors
```

**Root Cause**: `size()` function with pattern argument `(n)--()` not supported.

##### 1.5 LET Variable Binding (3 failures)
**Specs Affected**: gql_query_comprehensive.yml

**Syntax**:
```gql
MATCH (p:Person)
LET age_category = CASE
  WHEN p.age < 30 THEN 'young'
  ELSE 'mature'
END
RETURN p.name, age_category
```

**Root Cause**: `LET` keyword not implemented in parser.

##### 1.6 SET SESSION GRAPH / USE GRAPH (5 failures)
**Specs Affected**: geode_gql_compliance.yml, geode_recent_features.yml

**Syntax**:
```gql
SET SESSION GRAPH = 'test_graph'
USE GRAPH default
```

**Root Cause**: Session-level catalog management not implemented.

##### 1.7 Other Syntax Features

- **VALUES clause** (2 failures): `VALUES (1), (2), (3) AS (number)`
- **Map projection** (1 failure): `RETURN n {.name, .age}`
- **Single-quoted strings** (2 failures): PostgreSQL compatibility `'string'` vs `"string"`
- **SET node = map** (1 failure): `SET n = {name: 'John', age: 30}`
- **START TRANSACTION modes** (3 failures): `READ ONLY` / `READ WRITE`

---

### Category 2: Type System / Expression Evaluation
**Impact**: 13 tests (8% of all failures)

#### Issues

1. **Network type operations** (3 failures)
   - Patricia trie index queries with IPv4/IPv6 types
   - Error: "Type mismatch in expression"
   - Tests: `index-patricia-trie-ip-prefix-match`, `index-patricia-trie-lpm-lookup`

2. **Spatial type operations** (5 failures)
   - R-tree index queries with Point/Polygon types
   - Error: "Type mismatch in expression"
   - Tests: `index-rtree-spatial-intersects`, `index-rtree-spatial-contains`, `index-rtree-spatial-within`

3. **Label test expressions** (3 failures)
   - NOT/OR operators in label tests
   - Tests: `where-with-not`, `string-operations`, `label-test-or-with-property`

4. **Multi-index queries** (2 failures)
   - Complex queries using multiple indexes simultaneously

**Root Cause**: Type coercion/casting issues in expression evaluation, particularly with advanced data types in index operations.

**Example Query**:
```gql
-- This should work but fails with type mismatch
MATCH (s:Server)
WHERE s.subnet @> IPv4('192.168.1.0')
RETURN s.name
```

---

### Category 3: Error Validation
**Impact**: 16 tests (10% of all failures)

These tests **expect failure (exit_code=1)** but **succeed (exit_code=0)**. This indicates missing validation logic.

#### Subcategories

1. **Invalid type conversions** (1 test)
   - `gql_type_system_comprehensive.yml :: type-error-invalid-conversion`

2. **Transaction state errors** (1 test)
   - `gql_transaction_management_comprehensive.yml :: commit-without-transaction`

3. **Invalid index operations** (3 tests)
   - Invalid index type, incompatible data type, duplicate index name
   - `geode_index_comprehensive.yml`

4. **Security/authentication failures** (2 tests)
   - Invalid KMS provider, unauthenticated query should fail
   - `geode_tde_security.yml`, `geode_auth_security.yml`

5. **Schema validation errors** (4 tests)
   - Duplicate schema/graph creation, dropping nonexistent objects
   - `gql_catalog_operations_comprehensive.yml`

6. **Set operation validation** (1 test)
   - UNION with mismatched column counts
   - `gql_set_operations_comprehensive.yml :: union-column-count-mismatch`

7. **Pattern validation** (1 test)
   - Invalid variable-length pattern
   - `gql_pattern_matching_comprehensive.yml`

8. **CDC/Advanced features** (3 tests)
   - Various validation failures in CDC, data types

**Root Cause**: Validation logic not implemented or too permissive. Need to add proper error checking and return appropriate error codes.

---

### Category 4: Incorrect Query Results
**Impact**: 20+ tests (12% of all failures)

Tests execute successfully but return wrong or incomplete data.

#### Subcategories

1. **SKIP/LIMIT ordering issues** (3 failures)
   - Tests: `skip-and-limit`, `limit-then-skip-order`, `with-filtering`
   - **Issue**: SKIP/LIMIT applied in wrong order or without proper ORDER BY

2. **String function results** (2 failures)
   - Tests: `string-functions`, `datetime-operations`
   - **Issue**: Wrong return values from built-in functions

3. **Empty result sets** (10+ failures)
   - Various tests returning empty results when data expected
   - **Common pattern**: Setup succeeds but query returns no rows
   - Examples:
     - Migration transformations: `migrate-relationship-properties`, `change-relationship-direction`
     - Audit logging queries
     - CDC event capture

4. **Index usage verification** (1 failure)
   - Test: `check-index-usage`
   - **Issue**: EXPLAIN output doesn't show "IndexSeek"

5. **Aggregation COUNT issues** (1 failure)
   - Test: `bulk-update-with-index`
   - **Issue**: Expected 500 rows, got different count

**Root Cause**: Logic bugs in query execution engine, incorrect result set construction, or issues with multi-step query processing.

---

### Category 5: Aggregation / GROUP BY Validation
**Impact**: 3 tests (2% of all failures)

**Error Message**: `grouping error: non-aggregated expression not in GROUP BY`

**Failing Tests**:
1. `gql_query_comprehensive.yml :: query-with-count`
2. `gql_query_comprehensive.yml :: complex-query-performance`
3. `geode_performance_stress.yml :: grouping-performance`

**Root Cause**: GROUP BY validation logic may be too strict or incorrectly identifying aggregated vs non-aggregated expressions.

**Example Query Pattern**:
```gql
MATCH (p:Person)-[:KNOWS]->(friend)
RETURN p.name, COUNT(friend) AS friend_count
-- Should this require GROUP BY p.name? GQL spec unclear
```

---

### Category 6: Explicitly Unimplemented Features
**Impact**: 3 tests (2% of all failures)

**Error**: "Feature not yet implemented"

1. `geode_regression_tests.yml :: unique-node-ids`
   - CANARY system for tracking node ID uniqueness

2. `geode_graph_algorithms.yml :: shortest-path-simple`
   - Shortest path algorithm

3. `geode_graph_algorithms.yml :: graph-density`
   - Graph density calculation

**Root Cause**: Features explicitly marked as TODO in codebase.

---

### Category 7: CLI/Test Infrastructure Issues
**Impact**: 3 tests (2% of all failures)

**Error**: `Error: unknown option '--no-quic'`

**Failing Tests**:
- `geode_quic_transport.yml :: shell-quic-connect`
- `geode_quic_transport.yml :: shell-multiple-queries`
- `geode_quic_transport.yml :: quic-graceful-shutdown`

**Root Cause**: The `shell` subcommand doesn't accept the `--no-quic` flag, but tests expect it for compatibility testing.

---

### Category 8: Miscellaneous / Uncategorized
**Impact**: 13 tests (8% of all failures)

Various low-frequency issues:
- Transaction state management edge cases
- Unknown backup/migrate subcommands (`migrate up`, `backup cleanup`)
- OFFSET without ORDER BY validation
- Comment syntax issues (double-hyphen comments)
- EXPLAIN query output format

---

## Top Failing Test Specs

| Spec File | Passed | Failed | Skipped | Pass Rate |
|-----------|--------|--------|---------|-----------|
| geode_regression_tests.yml | 28 | 16 | 0 | 63.6% |
| geode_index_comprehensive.yml | 26 | 15 | 7 | 54.2% |
| geode_migrations.yml | 15 | 15 | 4 | 44.1% |
| geode_advanced_features.yml | 19 | 9 | 8 | 52.8% |
| geode_graph_algorithms.yml | 7 | 9 | 12 | 25.0% |
| geode_advanced.yml | 3 | 9 | 0 | 25.0% |
| geode_audit_logging_enterprise.yml | 32 | 8 | 0 | 80.0% |
| geode_advanced_data_types.yml | 29 | 8 | 0 | 78.4% |

---

## Recommended Fix Priority

### Priority 1: CREATE INDEX Syntax (15+ tests, 9-10%)
**Effort**: Medium (3-5 hours)
**Impact**: High - unblocks migrations, advanced features

**Implementation**:
1. Add `FOR` keyword support in index DDL
2. Support pattern-based index definitions: `FOR (n:Label) ON (n.prop)`
3. Support relationship indexes: `FOR ()-[r:Type]-() ON (r.prop)`
4. Support `USING <type>` and `WITH (options)` clauses
5. Support `OPTIONS {...}` syntax variant

**Rationale**:
- Part of ISO GQL standard (catalog operations)
- Highest single feature impact
- Blocks migration test suite (15 failures)
- Foundation for proper schema management
- Clear, well-specified syntax

### Priority 2: CREATE CONSTRAINT Syntax (7+ tests, 4-5%)
**Effort**: Medium (3-4 hours)
**Impact**: Medium-High - enables data integrity

**Implementation**:
1. Add `CONSTRAINT` keyword to lexer
2. Add `CREATE CONSTRAINT` grammar rules
3. Support `UNIQUE` constraints
4. Support `NODE KEY` constraints (composite uniqueness)
5. Support `IS NOT NULL` constraints
6. Implement constraint storage in catalog
7. Add constraint validation in INSERT/UPDATE/DELETE
8. Implement `DROP CONSTRAINT`

**Rationale**:
- ISO GQL standard feature
- Likely unblocks additional migration tests
- Foundation for data integrity
- Related to CREATE INDEX (similar syntax patterns)

### Priority 3: FOR Loop/Binding (9 tests, 5-6%)
**Effort**: Medium-High (4-6 hours)
**Impact**: Medium

**Implementation**:
1. Add `FOR` keyword to lexer (if not already added for indexes)
2. Add FOR loop grammar rules
3. Implement loop execution in query engine
4. Support `FOR var IN collection` syntax
5. Handle iteration over lists and binding tables

**Rationale**:
- ISO GQL standard feature
- Useful for complex data transformations
- Tests in gql_query_comprehensive.yml

### Priority 4: Type System Fixes (13 tests, 8%)
**Effort**: Medium (2-4 hours)
**Impact**: Medium

**Implementation**:
1. Fix type coercion for network types (IPv4/IPv6) in Patricia trie queries
2. Fix type coercion for spatial types (Point/Polygon) in R-tree queries
3. Fix NOT/OR operators in label test expressions
4. Improve type mismatch error messages
5. Add proper type casting operations

**Rationale**:
- Affects advanced data type functionality
- Relatively isolated fixes
- Important for index operations

### Priority 5: Error Validation (16 tests, 10%)
**Effort**: Low-Medium (1-3 hours per subsystem)
**Impact**: Medium - improves robustness

**Implementation**:
1. Add transaction state validation (commit without transaction)
2. Add schema validation (duplicate names, nonexistent drops)
3. Add index validation (invalid types, duplicate names)
4. Add type conversion validation
5. Add set operation validation (column count matching)
6. Add authentication/security validation

**Rationale**:
- Improves error handling
- Multiple small, independent fixes
- Can be parallelized across subsystems

### Priority 6: Result Correctness (20 tests, 12%)
**Effort**: Varies (1-4 hours per issue)
**Impact**: Medium

**Implementation**:
1. Fix SKIP/LIMIT ordering with ORDER BY
2. Debug and fix string/datetime functions
3. Investigate empty result set issues
4. Fix migration data transformation logic
5. Ensure EXPLAIN includes index usage info

**Rationale**:
- Critical for correctness
- Requires investigation per issue
- Some may be quick fixes, others complex

### Priority 7: LET, VALUES, Other Syntax (10+ tests, 6%)
**Effort**: Medium (2-4 hours each)
**Impact**: Low-Medium

**Implementation**:
- LET variable binding
- VALUES clause
- Map projection syntax
- Single-quoted strings
- SET node = map
- Various other GQL features

**Rationale**:
- Lower individual impact
- Can be implemented incrementally
- Some are nice-to-have compatibility features

---

## Next Immediate Action

### 🎯 Implement CREATE INDEX FOR (pattern) ON (properties) Syntax

**Justification**:
- Highest single-feature impact: 15+ direct failures
- Unblocks migration test suite (15 additional failures)
- Part of ISO GQL standard
- Clear, well-specified syntax
- Foundation for proper schema management
- Natural precursor to CREATE CONSTRAINT (similar syntax patterns)

**Total Potential Impact**: 20-30 tests (12-18% of failures)

**Implementation Steps**:
1. Review ISO GQL spec for CREATE INDEX syntax
2. Add grammar rules to parser for `FOR (pattern) ON (props)` syntax
3. Support both node and relationship index patterns
4. Add `USING <type>` clause support
5. Add `WITH (options)` and `OPTIONS {...}` clause support
6. Update index catalog storage to handle new syntax
7. Ensure backward compatibility with existing `ON :Label(prop)` syntax
8. Add tests for all syntax variants
9. Run geodetestlab to verify fixes

**Estimated Effort**: 3-5 hours

---

## Summary Statistics

| Category | Failures | Percentage |
|----------|----------|------------|
| Missing GQL Syntax | 91 | 56% |
| Type System Issues | 13 | 8% |
| Error Validation | 16 | 10% |
| Result Correctness | 20+ | 12% |
| GROUP BY Validation | 3 | 2% |
| Unimplemented Features | 3 | 2% |
| CLI/Infrastructure | 3 | 2% |
| Miscellaneous | 13 | 8% |
| **TOTAL** | **162** | **100%** |

---

## Conclusion

The test failure analysis reveals that **56% of failures (91 tests)** are due to missing GQL syntax features, with the top 3 features accounting for **31 tests (19%)**:

1. **CREATE INDEX variations** (15 tests)
2. **FOR loop/binding** (9 tests)
3. **CREATE CONSTRAINT** (7 tests)

Implementing these three features in priority order would:
- Reduce failures from 162 to ~131 (19% improvement)
- Improve pass rate from 87.6% to 92.3%
- Unblock migration and advanced feature test suites
- Provide strong ISO GQL compliance foundation

The recommended approach is to tackle high-impact syntax features first, followed by type system fixes and result correctness issues. Error validation improvements can be made incrementally as individual subsystems are worked on.

---

**Analysis Date**: October 11, 2025
**Test Run**: /home/benji/src/spyder/geode/test_logs/run_20251011_091016/
**Geode Version**: main branch (commit 741bb40)
