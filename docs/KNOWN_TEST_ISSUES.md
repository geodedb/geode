# Known Test Issues

This document tracks tests that are skipped in the geodetestlab test suite due to unimplemented features or test infrastructure issues.

## Test Suite Status (December 2025)

- **Pass Rate**: 94.7% (1199/1266 non-skipped tests)
- **Total Tests**: 1420
- **Passed**: 1199
- **Failed**: 67
- **Skipped**: 154

## Categories of Skipped Tests

### 1. Setup Data Persistence Issues

Tests in these spec files are skipped because setup data created at the beginning of a spec file does not persist between individual tests within the same spec:

- `nested_queries_basic.yml` (11 tests skipped)
- `nested_queries_advanced.yml` (12 tests skipped)
- `recursive_and_cte.yml` (11 tests skipped)

**Root Cause**: The test harness runs tests sequentially but each test appears to operate in isolation, causing data created in setup steps to not be available for subsequent tests.

**Fix Required**: Test harness modification to ensure setup data persists across all tests in a spec file.

### 2. Unimplemented Language Features

The following features are skipped because they are not yet implemented:

#### geode_regression_tests.yml (11 tests skipped)
- `with-aggregation`: WITH clause mixing aggregation and non-aggregation expressions with WHERE causes server hang
- `case-when-then`, `case-with-default`: CASE expressions in MATCH context cause server hang
- `pattern-comprehension`: Pattern comprehension list syntax `[(p)-[:KNOWS]->(friend) | friend.name]` not implemented
- `map-projection`: Map projection syntax `n {.name, .age}` not implemented
- `list-functions`: `head()`, `tail()` list functions not implemented
- `datetime-operations`: DateTime property access (`dt.year`, `dt.month`, etc.) not implemented
- `where-with-regex`: Regex matching (`=~`) not fully implemented
- `path-node-update`: Variable-length path with SET not fully implemented
- `values-list`, `values-with-match`: VALUES clause not fully implemented

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

### High Priority
1. **Setup data persistence** - This affects 34 tests that would otherwise pass
2. **WITH + aggregation + WHERE** - Core query chaining feature

### Medium Priority
3. **CASE expressions in MATCH** - Important for conditional logic
4. **DateTime property access** - Common temporal operations

### Low Priority (Cypher extensions, not ISO GQL)
5. Pattern comprehension (Cypher syntax)
6. Map projection (Cypher syntax)
7. List functions (`head()`, `tail()`)

## Notes

- Tests marked with `skip: true` are intentionally skipped due to known limitations
- The test infrastructure properly handles skipped tests and excludes them from failure counts
- All skipped tests have comments explaining why they are skipped

## Updating This Document

When fixing a feature, update this document by:
1. Removing the skip marker from the test
2. Running `make geodetestlab-comprehensive` to verify the fix
3. Removing the entry from this document

*Last Updated: December 2025*
