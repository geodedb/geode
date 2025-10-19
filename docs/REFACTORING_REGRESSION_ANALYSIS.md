# Test Refactoring Regression Analysis
October 18, 2025

## Overview
After recent refactoring work, approximately 130-137 tests are failing with exit code issues. These tests expect error conditions to return exit code 1, but are getting exit code 0 instead. This document analyzes the root causes and provides an incremental fix plan.

## Failure Categories

### 1. Exit Code Failures (130+ tests)
**Pattern**: Tests expecting `exit_code: 1` but receiving `exit_code: 0`

#### Primary Cause
The error handling path isn't properly setting exit codes for all error conditions. While some runtime errors (like division by zero) are correctly handled and return exit code 1, others return success status despite encountering errors.

#### Affected Test Categories
- **Error Handling Tests**:
  - `error-handling-division-by-zero` (FIXED)
  - `error-invalid-ip-address`
  - `error-invalid-mac-address`
  - `error-char-length-exceeded`
  - `error-decimal-division-by-zero`

- **Authentication/Authorization Failures**:
  - `unauthenticated-query-failure`
  - `wrong-password-failure`
  - `test-read-only-access`

- **Syntax and Type Errors**:
  - `invalid-gql-syntax`
  - `syntax-error-handling`
  - `type-mismatch-handling`

- **CDC and Control Command Errors**:
  - `cdc-error-invalid-guardrail`
  - `cdc-error-malformed-control-command`

- **Index Operation Errors**:
  - `index-error-invalid-index-type`
  - `index-error-incompatible-data-type`
  - `index-error-duplicate-index-name`

- **Keyword/Parse Errors**:
  - `error-missing-label-name`
  - `error-unclosed-parenthesis`
  - `error-missing-property-in-set`
  - `error-incomplete-remove`

### 2. Missing Tests (1 test)
- **`match-call-dijkstra-optimal`** from `geode_match_call_integration.yml`
  - **Status**: Actually passing now, likely was temporarily missing during test runs

### 3. Timeout Issues (2-3 tests)
- **`match-call-multiple-labels`** from `geode_match_call_integration.yml`
- **`connection-timeout`** from `geode_quic_transport.yml`
- **`connection-refused`** from `geode_quic_transport.yml`

### 4. Setup Command Failures (5 tests)
From `gql_catalog_operations_comprehensive.yml`:
- `create-or-replace-graph-type`
- `create-graph-type-copy-of`
- `drop-graph-type-basic`
- `drop-property-graph-type-basic`
- `drop-graph-type-if-exists`

**Error**: `TypeAlreadyExists` - Likely due to test isolation issues

## Root Cause Analysis

### Primary Issue: Inconsistent Error Propagation

The main issue is in the error handling chain:

1. **`test_harness.zig`**: When errors occur, the test harness returns JSON error responses with appropriate `status_class` codes (like "42000" for syntax errors), but these are being returned as successful function calls.

2. **`cli/main.zig`**: The CLI's `executeEmbeddedQuery` function (lines 2176-2210) correctly checks the status_class and calls `std.process.exit(1)` for error conditions, BUT:
   - Some error types are being caught and converted to success responses before reaching this check
   - Runtime validation errors (invalid IP, invalid MAC) are not throwing errors at all

3. **`eval.zig`**: Division by zero correctly returns `EvalError.DivisionByZero` which propagates properly.

4. **Type Validation**: Functions like `IPv4()` and `MAC()` are not validating input and returning errors for invalid formats.

### Secondary Issues

1. **Test Isolation**: Graph type tests are failing due to persistent state between tests
2. **Timeout Configuration**: Some complex graph operations need longer timeouts
3. **Error Message Consistency**: Some errors go to stderr, others to stdout as JSON

## Incremental Fix Plan

### Phase 1: Fix Type Validation Errors (High Priority)
**Files to modify**:
- `src/types/network/ipaddr.zig`
- `src/types/network/mac.zig`
- `src/types/extended.zig`

**Actions**:
1. Add validation in IPv4/IPv6 constructors to return errors for invalid formats
2. Add validation in MAC constructor to return errors for invalid formats
3. Ensure these errors propagate through eval.zig as proper error types
4. Add CharLengthExceeded validation for CHAR(n) types

**Expected Impact**: ~20-30 test fixes

### Phase 2: Fix Authentication/Authorization Errors
**Files to modify**:
- `src/security/auth.zig`
- `src/security/user_management.zig`

**Actions**:
1. Ensure authentication failures return proper error status codes
2. Fix permission denied errors to propagate correctly
3. Verify role-based access control errors exit with code 1

**Expected Impact**: ~7-10 test fixes

### Phase 3: Fix CDC and Control Command Errors
**Files to modify**:
- `src/cdc/core.zig`
- `src/streaming/cdc.zig`

**Actions**:
1. Add validation for CDC guardrail configurations
2. Add validation for malformed control commands
3. Ensure errors propagate to exit code 1

**Expected Impact**: ~5-10 test fixes

### Phase 4: Fix Index Operation Errors
**Files to modify**:
- `src/index/index_manager.zig`
- `src/execution/catalog.zig`

**Actions**:
1. Validate index types and return errors for invalid types
2. Check data type compatibility for indexes
3. Check for duplicate index names and return appropriate errors

**Expected Impact**: ~10-15 test fixes

### Phase 5: Fix Parse/Syntax Errors
**Files to modify**:
- `src/gql/parser.zig`
- `src/gql/lexer.zig`

**Actions**:
1. Ensure all parse errors return proper status codes
2. Fix error handling for incomplete statements
3. Validate label names, property names, etc.

**Expected Impact**: ~15-20 test fixes

### Phase 6: Fix Test Isolation Issues
**Files to modify**:
- `src/storage/catalog.zig`
- Test runner scripts

**Actions**:
1. Add cleanup between test runs for catalog operations
2. Ensure graph types are properly cleaned up
3. Consider adding a --clean flag to tests

**Expected Impact**: 5 test fixes

### Phase 7: Fix Timeout Issues
**Files to modify**:
- Test configuration files
- `src/graph/algorithms.zig` (optimization)

**Actions**:
1. Increase timeouts for complex graph operations
2. Optimize dijkstra algorithm for multiple labels
3. Fix QUIC connection timeout handling

**Expected Impact**: 2-3 test fixes

## Verification Strategy

After each phase:
1. Run targeted tests: `python3 extended_test_runner.py --pattern "<category>"`
2. Verify exit codes: Check that errors return exit code 1
3. Check error messages: Ensure stderr contains appropriate error text
4. Run full test suite to ensure no regressions

## Summary

The refactoring introduced a regression where error conditions are not consistently returning exit code 1. The issue is primarily in the error propagation chain, where some errors are being caught and converted to successful JSON responses instead of triggering exit code 1.

The fix requires:
1. Adding proper validation to type constructors
2. Ensuring all error types propagate correctly through the execution chain
3. Verifying that cli/main.zig properly detects and exits with code 1 for all error status classes

With the incremental fix plan above, we should be able to restore proper error handling and fix the 130+ failing tests systematically.