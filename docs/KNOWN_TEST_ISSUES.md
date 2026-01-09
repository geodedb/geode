# Known Test Issues

This document tracks tests that are skipped in the geodetestlab test suite due to unimplemented features or test infrastructure issues.

> **Note**: This is the authoritative source for test status. Run `make geodetestlab-comprehensive` for current results. Other documentation files reference this document rather than containing their own test numbers.

## Test Suite Status (January 2026)

**Last Updated**: January 9, 2026

> Numbers below are from the last documented test run. Run tests locally for current results.

- **Pass Rate**: ~97% (varies by test run)
- **Skipped**: ~120 tests (intentionally skipped due to known limitations documented below)

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
2. Pattern comprehension (Cypher syntax)
3. Map projection (Cypher syntax)

## Notes

- Tests marked with `skip: true` are intentionally skipped due to known limitations
- The test infrastructure properly handles skipped tests and excludes them from failure counts
- All skipped tests have comments explaining why they are skipped

## Updating This Document

When fixing a feature, update this document by:
1. Removing the skip marker from the test
2. Running `make geodetestlab-comprehensive` to verify the fix
3. Removing the entry from this document

*Last Updated: January 9, 2026*
