# Geodetestlab Test Failures Analysis

**Date**: October 12, 2025
**Total Tests**: 1710
**Passing**: 1606 (93.9%)
**Failing**: 104 (6.1%)

## ✅ Recently Fixed

### Transaction Session Isolation (Completed)
**Issue**: Tests were sharing a global transaction session file at `/tmp/geode_transaction_session.txt`, causing cross-contamination between parallel tests.

**Fix**: Modified `src/txn_session.zig` to respect `GEODE_DATA_DIR` environment variable, allowing each test spec to use its own isolated transaction session file.

**Files Modified**:
- `src/txn_session.zig`: Added `getSessionFilePath()` function
- `src/test_harness.zig`: Updated function calls to pass allocator

**Impact**: Fixed COMMIT/ROLLBACK without transaction validation (~2-3 tests)

---

## 🔴 Remaining Failures (104 tests)

### Category 1: Exit Code Failures (87 tests)

#### 1A. Syntax Errors - Unsupported Features (47 tests) 🔥 HIGH PRIORITY

**Root Cause**: Parser doesn't support several GQL syntax patterns that tests expect.

**Examples**:
- `[geode_fuzz.yml] extremely-deep-nesting` - Nested CALL blocks
  ```gql
  CALL {
    CALL {
      CALL {
        CALL {
          MATCH (n:FuzzTest) RETURN n
        }
      }
    }
  }
  ```
  **Error**: "Syntax error in query"

- `[gql_transaction_management_comprehensive.yml] nested-transaction-procedure`
  ```gql
  START TRANSACTION {
    CREATE (n:NestedNode {id: 1, type: 'nested'});
    MATCH (n:NestedNode) RETURN count(n) AS node_count
  }
  ```
  **Error**: "Syntax error in query"

- 45+ more tests with complex syntax patterns

**Priority**: HIGH - Affects 47 tests (45% of failures)

**Fix Complexity**: MEDIUM-HIGH - Requires parser enhancements

---

#### 1B. Type Validation Missing (3-5 tests) 🔥 HIGH PRIORITY

**Root Cause**: Invalid type conversions should fail but succeed instead.

**Example**:
- `[gql_type_system_comprehensive.yml] type-error-invalid-conversion`
  - **Expected**: Exit code 1 (error)
  - **Actual**: Exit code 0, returns `{"columns":["invalid_conversion"],"rows":[[null]]}`
  - **Issue**: Should reject invalid type conversions, not return null

**Priority**: HIGH - Core type safety issue

**Fix Complexity**: MEDIUM - Add validation in expression evaluator

**Location**: `src/eval.zig` or `src/execution.zig`

---

#### 1C. Missing CLI Subcommands (3 tests) 🟡 MEDIUM PRIORITY

**Issues**:

1. **backup cleanup** - Not implemented
   ```bash
   geode backup cleanup
   # Error: Unknown backup subcommand 'cleanup'
   ```

2. **migrate up** - Not implemented
   ```bash
   geode migrate up
   # Error: Unknown migrate subcommand 'up'
   ```

3. **Incremental backup parent validation**
   - `[geode_advanced_features.yml] create-incremental-backup`
   - **Error**: "IncrementalBackupRequiresParent"
   - **Issue**: Should either create with parent reference or provide better error

**Priority**: MEDIUM - Feature completeness

**Fix Complexity**: LOW-MEDIUM - Add CLI command handlers

**Location**: `src/cli/main.zig`

---

#### 1D. Label/Property Type Mismatches (2-3 tests) 🟡 MEDIUM PRIORITY

**Example**:
- `[label_test_unit_tests.yml] label-test-or-with-property`
  - **Expected**: Exit code 0
  - **Actual**: Exit code 1, "Type mismatch in expression"
  - **Issue**: OR expressions with labels and properties not properly typed

**Priority**: MEDIUM

**Fix Complexity**: MEDIUM - Type system refinement

**Location**: `src/eval.zig`, `src/types.zig`

---

#### 1E. Data Isolation Issues (2-3 tests) 🟢 LOW PRIORITY

**Examples**:
- `[transaction_state_unit_tests.yml] transaction-with-delete`
  - **Error**: "Transaction already active"
  - **Likely Cause**: Cross-test contamination despite per-spec data dirs

- `[geode_recent_features.yml] test-drop-graph`
  - **Error**: "Graph does not exist"
  - **Likely Cause**: Test expects graph from setup but not found

**Priority**: LOW - May be test specification issues

**Fix Complexity**: LOW - Investigate test setup/teardown

---

#### 1F. Other Exit Code Issues (~20 tests) 🟡 MEDIUM PRIORITY

Various one-off issues requiring individual investigation.

---

### Category 2: Missing Output (15 tests) 🟡 MEDIUM PRIORITY

#### 2A. JSON List Formatting (1-2 tests)

**Issue**: Tests expect spaces in JSON arrays, but output has no spaces.

**Example**:
- `[geode_current_capabilities.yml] return-list`
  - **Expected**: `[1, 2, 3, 4, 5]` (with spaces)
  - **Actual**: `[1,2,3,4,5]` (no spaces)

**Priority**: MEDIUM

**Fix Complexity**: LOW - JSON serialization formatting

**Location**: Wherever JSON arrays are serialized (likely `src/execution.zig` or JSON serialization code)

---

#### 2B. Shell Output Missing Expected Text (12-13 tests)

**Examples**:
- `[geode_quic_transport.yml] shell-quic-connect`
  - **Missing**: 'shell-test' in output
  - **Actual stderr**: "Geode Shell v0.16.0\nConnected to 127.0.0.1:3141..."

- `[geode_quic_transport.yml] shell-multiple-queries`
  - **Missing**: 'first' in output

**Priority**: MEDIUM

**Fix Complexity**: LOW-MEDIUM - Shell output formatting or test expectations

**Location**: Shell/REPL code, possibly `src/cli/main.zig`

---

#### 2C. Profile/MERGE Output Missing Keywords (2 tests)

**Examples**:
- `[geode_advanced_features.yml] profile-query-execution`
  - **Missing**: 'profile' keyword in output

- `[geode_current_capabilities.yml] merge-with-on-create`
  - **Missing**: 'created' in output
  - **Issue**: MERGE ON CREATE should indicate what was created

**Priority**: MEDIUM

**Fix Complexity**: MEDIUM - Output format enhancement

**Location**: Profile/MERGE execution code

---

### Category 3: Stderr Missing (1 test) 🟢 LOW PRIORITY

**Test**: `[geode_quic_transport.yml] connection-timeout`

**Issue**:
- **Expected stderr**: Contains 'timeout'
- **Actual stderr**: "Syntax error in query"

**Priority**: LOW

**Fix Complexity**: LOW - Likely a syntax error in the test query, not a real timeout test

---

### Category 4: Timeout (1 test) 🟢 LOW PRIORITY

**Test**: `[geode_index_comprehensive.yml] index-performance-automatic-selection`

**Issue**: Test times out after 10 seconds

**Priority**: LOW

**Fix Complexity**: UNKNOWN - Could be performance issue, infinite loop, or test configuration

---

## 📊 Priority Summary

### 🔥 HIGH PRIORITY (Fix First)
1. **Syntax Errors (47 tests)** - Parser enhancements for nested structures
2. **Type Validation (3-5 tests)** - Add type conversion validation

**Impact if fixed**: ~50 tests (48% of failures)

### 🟡 MEDIUM PRIORITY (Fix Second)
1. **JSON List Formatting (1-2 tests)** - Add spaces in arrays
2. **Missing CLI Subcommands (3 tests)** - Add backup cleanup, migrate up
3. **Shell Output Issues (12-13 tests)** - Fix output formatting
4. **Profile/MERGE Output (2 tests)** - Add missing keywords
5. **Label Type Mismatches (2-3 tests)** - Type system fixes
6. **Other Exit Code Issues (~20 tests)** - Individual investigation

**Impact if fixed**: ~40 tests (39% of failures)

### 🟢 LOW PRIORITY (Fix Last)
1. **Data Isolation Issues (2-3 tests)** - Test setup investigation
2. **Stderr Missing (1 test)** - Likely test issue
3. **Timeout (1 test)** - Performance investigation

**Impact if fixed**: ~5 tests (5% of failures)

---

## 🎯 Recommended Fix Order

1. **JSON List Formatting** (LOW complexity, MEDIUM impact) - Quick win
2. **Type Validation** (MEDIUM complexity, HIGH impact)
3. **Missing CLI Subcommands** (LOW-MEDIUM complexity, MEDIUM impact)
4. **Syntax Error Parsing** (MEDIUM-HIGH complexity, HIGH impact) - Biggest fix
5. **Shell Output Issues** (LOW-MEDIUM complexity, MEDIUM impact)
6. **Remaining issues** (As time permits)

---

## 📈 Expected Outcome

If all HIGH and MEDIUM priority issues are fixed:
- **Current**: 1606/1710 passing (93.9%)
- **Projected**: 1690+/1710 passing (98.8%+)
- **Remaining**: <20 tests (mostly edge cases and low-priority issues)
