# Test Failure Analysis - October 12, 2025

## Summary
- **Total Failed**: 90 tests
- **Exit Code Failures**: 79 tests
- **Missing Output Failures**: 11 tests
- **Pass Rate**: 91.8%

## Failure Categories

### 1. Exit Code Failures (Expected 0, Got 1) - Empty STDOUT
These tests fail to execute (empty STDOUT), indicating parsing or execution errors:

- geode_fuzz.yml: extremely-deep-nesting
- gql_query_comprehensive.yml: optional-match-nested
- gql_transaction_management_comprehensive.yml: nested-transaction-procedure
- geode_performance_stress.yml: create-performance-index
- geode_index_comprehensive.yml: index-rtree-spatial-* (multiple)
- geode_index_comprehensive.yml: index-hnsw-knn-* (multiple)

**Root Cause**: Query parsing or execution failures causing early exit
**Action**: Need to check stderr output and fix parser/executor bugs

### 2. Exit Code Failures (Expected 1, Got 0) - Error Validation Missing
These tests should fail but succeed, indicating missing error validation:

- nested-start-transaction (should error on nested transactions)
- index-error-duplicate-index-name (should error on duplicate index)
- tde-error-invalid-key-provider (should validate TDE key provider)
- unauthenticated-query-failure (should require authentication)
- pattern-invalid-variable-length (should validate pattern syntax)
- cdc-error-invalid-guardrail (should validate CDC guardrails)

**Root Cause**: Missing validation logic for error cases
**Action**: Implement proper error checking and return non-zero exit codes

### 3. Missing Output Failures
These tests execute but don't produce expected output text:

- merge-with-on-create: missing 'created'
- profile-query-execution: missing 'profile'
- Various tests missing specific counts or values

**Root Cause**: Output formatting or incomplete feature implementation
**Action**: Review output generation for these specific commands

## Top Failing Test Files

1. **geode_regression_tests.yml** (11 failures)
2. **geode_advanced.yml** (9 failures)
3. **geode_graph_algorithms.yml** (8 failures, 12 skipped)
4. **geode_index_comprehensive.yml** (7 failures, 7 skipped)
5. **geode_auth_security.yml** (7 failures)

## Recommended Fix Priority

### High Priority (Blocking Features)
1. Fix parser/execution failures causing empty STDOUT
2. Implement missing error validation (exit code 1 cases)
3. Fix MERGE ON CREATE output

### Medium Priority (Feature Completeness)
4. Fix PROFILE command output
5. Fix index operations (R-tree, HNSW)
6. Fix authentication error handling

### Low Priority (Edge Cases)
7. Deep nesting limits
8. Complex pattern matching edge cases

## Next Steps
1. Examine specific failing test queries to identify parser issues
2. Add stderr logging to parallel_test_runner for better diagnostics
3. Implement missing validation checks
4. Fix output formatting for MERGE and PROFILE commands
