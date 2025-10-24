# Test Failure Analysis Summary

## Critical Issues Fixed ✅
1. **Invalid free crash in SET n = {properties}** (execution.zig:4114)
   - Fixed by using `store.allocator` instead of `allocator`
   - Was causing segmentation fault in set-all-properties test
   - **Impact**: 1 test fixed

## Remaining Major Issues

### 1. Missing GQL Syntax Features (~94 tests)

#### CALL Clauses (Subqueries)
- **Examples**: Nested CALL blocks, CALL with WITH clauses
- **Test**: `extremely-deep-nesting`, `nested-transaction-procedure`
- **Complexity**: HIGH - Requires parser, AST, and execution support
- **Impact**: ~50-60 tests

#### FOR Loops
- **Example**: `FOR name IN person_name RETURN name`
- **Test**: `for-binding-table`
- **Complexity**: HIGH - Requires new iteration construct
- **Impact**: ~10-20 tests

#### Other Syntax
- Various advanced GQL features
- **Impact**: ~20-30 tests

### 2. Missing Error Detection (16 tests)
These queries should FAIL but currently PASS:

1. **Type Errors** (2 tests)
   - `type-error-invalid-conversion` - Invalid type conversion not caught
   - `error-char-length-exceeded` - CHAR length validation missing

2. **Transaction Errors** (1 test)
   - `commit-without-transaction` - Should error when no active transaction

3. **Index Errors** (3 tests)
   - `index-error-invalid-index-type` - Invalid index type not validated
   - `index-error-incompatible-data-type` - Data type mismatch not caught
   - `index-error-duplicate-index-name` - Duplicate name not detected

4. **Authentication Errors** (1 test)
   - `unauthenticated-query-failure` - Unauthenticated queries should fail

5. **Catalog Errors** (4 tests)
   - `create-duplicate-schema-error` - Duplicate schema allowed
   - `drop-nonexistent-schema-error` - Dropping nonexistent schema succeeds
   - `create-duplicate-graph-error` - Duplicate graph allowed
   - `drop-nonexistent-graph-error` - Dropping nonexistent graph succeeds

6. **Pattern Matching Errors** (1 test)
   - `pattern-invalid-variable-length` - Invalid variable-length pattern

7. **CDC Errors** (2 tests)
   - `cdc-error-invalid-guardrail`, `cdc-error-malformed-control-command`

8. **Set Operation Errors** (1 test)
   - `union-column-count-mismatch` - Column count mismatch in UNION

9. **TDE Errors** (1 test)
   - `tde-error-invalid-key-provider` - Invalid key provider not validated

**Complexity**: LOW-MEDIUM - Add validation checks
**Impact**: 16 tests

### 3. Output Format Issues (18 tests)
Output exists but doesn't match expected format:

- `merge-with-on-create` - Missing 'created' in output
- `return-list` - List format issue `[1,2,3,4,5]` vs expected
- `explain-query-plan` - Missing 'cost' in EXPLAIN output
- `profile-query-execution` - Missing 'profile' in PROFILE output
- Migration tests - Missing actual migration results

**Complexity**: LOW - Format adjustments
**Impact**: 18 tests

## Recommendations

### Quick Wins (HIGH ROI, LOW EFFORT)
1. ✅ **Fix crash in SET all properties** - DONE
2. **Add validation for error detection** (16 tests) - Add validation checks
3. **Fix output formats** (18 tests) - Adjust formatting logic

### Medium Effort, HIGH Impact
4. **Implement transaction state tracking** - Fix commit-without-transaction
5. **Add index validation** - Catch index errors properly
6. **Add catalog validation** - Prevent duplicate schemas/graphs

### High Effort (Major Features)
7. **Implement CALL clause** - ~50-60 tests, requires significant parser/executor work
8. **Implement FOR loops** - ~10-20 tests, new iteration construct

## Priority Order
1. ✅ Critical crashes (DONE)
2. Error detection validation (16 tests) - Quick wins
3. Output format fixes (18 tests) - Quick wins
4. CALL clause implementation (if time permits) - Major feature
5. FOR loop implementation (if time permits) - Major feature

Total potential fixes with current approach: 1 + 16 + 18 = **35 tests**
With major features: 35 + 60 + 20 = **115 tests** (all remaining failures)
