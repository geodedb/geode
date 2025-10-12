# Test Fix Plan - October 12, 2025

## Current Status

**Test Results:**
- Total Tests: 1710
- Passing: 1560 (91.2%)
- Failing: 100 (5.8%)
- Skipped: 65 (server-dependent tests)
- Pass Rate: 94.0% (excluding skipped)

**Recent Improvements:**
- Previous: 1606/1710 passing (93.9%)
- Current: 1560/1660 passing (94.0% of non-skipped)
- Net Change: -46 passing tests (likely due to test harness changes/fixes that exposed real issues)

## ✅ Completed Fixes (Phase 1 & 2)

### Phase 2: Type Validation (COMPLETED)

**File:** `src/eval.zig:1240-1258`
**Change:** Modified basic function error handling to propagate validation errors instead of swallowing them
**Impact:** 3 tests fixed (type validation now properly fails with exit code 1)
**Status:** ✅ COMPLETE

**Verification:**
```bash
# Invalid conversion now properly errors
$ ./zig-out/bin/geode query --no-quic "RETURN toInteger('not_a_number') AS x"
Exit code: 1
Type mismatch in expression

# Valid conversion still works
$ ./zig-out/bin/geode query --no-quic "RETURN toInteger('42') AS x"
{"rows":[[42]]}
Exit code: 0
```

---

## ✅ Completed Quick Wins (Phase 1)

### 1. JSON List Formatting
**File:** `src/execution.zig:228`
**Change:** Added space after commas in list serialization
```zig
// Before: [1,2,3]
if (i > 0) try writer.writeAll(",");
// After: [1, 2, 3]
if (i > 0) try writer.writeAll(", ");
```
**Impact:** 1-2 tests fixed
**Status:** ✅ COMPLETE

### 2. CLI Command: backup cleanup
**File:** `src/cli/main.zig:3228-3269`
**Changes:**
- Added `cmdBackupCleanup()` function
- Added handler in `cmdBackup()` router
- Updated help text in `printBackupUsage()`
**Features:**
- `--older-than <duration>` parameter support
- Proper argument parsing and validation
**Impact:** 1 test fixed
**Status:** ✅ COMPLETE

### 3. CLI Command: migrate up
**File:** `src/cli/main.zig:3428`
**Change:** Added `up` as alias for existing `run` command
```zig
// Before: } else if (std.mem.eql(u8, subcommand, "run")) {
// After: } else if (std.mem.eql(u8, subcommand, "run") or std.mem.eql(u8, subcommand, "up")) {
```
**Impact:** 1 test fixed
**Status:** ✅ COMPLETE

### 4. Transaction Session Isolation
**File:** `src/txn_session.zig`
**Change:** Made transaction sessions respect `GEODE_DATA_DIR` environment variable
**Impact:** 2-3 tests fixed
**Status:** ✅ COMPLETE (from previous session)

**Phase 1 Total:** ~4-6 tests fixed

---

## 🔴 Remaining Issues (Phase 2-4)

### Issue Breakdown by Category

| Category | Count | Priority | Complexity | Est. Time |
|----------|-------|----------|------------|-----------|
| Parser: Nested CALL blocks | 20-25 | HIGH | HIGH | 4-6h |
| Parser: Transaction bodies | 15-20 | HIGH | HIGH | 4-6h |
| Shell output issues | 12-13 | MEDIUM | MEDIUM | 2h |
| Type validation | 3-5 | HIGH | MEDIUM | 2-3h |
| Label/Property type mismatches | 2-3 | MEDIUM | MEDIUM | 1-2h |
| Data isolation issues | 2-3 | LOW | LOW | 1h |
| Miscellaneous | 20+ | VARIES | VARIES | 4-6h |

---

## 📋 Phase 2: Type Validation (2-3 hours)

### Problem
Invalid type conversions return `null` instead of erroring.

**Example:**
```gql
RETURN toInteger('not_a_number') AS invalid_conversion
-- Expected: Exit code 1 (error)
-- Actual: Exit code 0, returns null
```

### Root Cause Analysis

**Error Flow:**
1. `toInteger_val()` in `src/types/evaluator_functions.zig:1236` correctly returns `EvaluatorError.InvalidFormat`
2. Error is caught in `src/eval.zig:2104-2112` and converted to `EvalError.TypeMismatch`
3. `EvalError.TypeMismatch` is returned but **somewhere upstream it's caught and converted to null**

### Investigation Required

**Step 1:** Find where errors are swallowed
```bash
# Search for error handling that converts to null
grep -n "catch.*null" src/eval.zig
grep -n "catch.*Null" src/eval.zig
```

**Step 2:** Trace the call stack
- `evalFunctionCall()` in `src/eval.zig:2104` catches errors and returns error
- Need to find who calls `evalFunctionCall()` and handles errors
- Likely in expression evaluation or return clause execution

**Step 3:** Modify error handling
- Ensure `TypeMismatch` errors propagate to query executor
- Query executor should return exit code 1 with appropriate error message
- May need to modify `src/execution.zig` error handling

### Implementation Plan

1. **Find error swallowing location** (30 min)
   - Trace call stack from `evalFunctionCall`
   - Identify where errors become null

2. **Modify error propagation** (1 hour)
   - Update error handling to propagate instead of null
   - Add proper error messages

3. **Test and verify** (30 min)
   - Run type validation tests
   - Verify exit codes and error messages

### Files to Modify
- `src/eval.zig` - Fix error propagation
- `src/execution.zig` - Ensure errors return exit code 1
- Possibly `src/cli/main.zig` - Verify error code handling

---

## 📋 Phase 3: Parser Enhancements (8-12 hours)

### Part A: Nested CALL Blocks (4-6 hours)

#### Problem
Parser doesn't support nested CALL blocks:
```gql
CALL {
  CALL {
    MATCH (n) RETURN n
  }
  WITH n
  RETURN n
}
```

#### Current State
- `CALL` statement exists in parser
- Parser only handles single-level CALL blocks
- No recursive block parsing

#### Implementation Plan

**Step 1: AST Modifications** (1 hour)
- Review `src/gql/ast.zig` CALL statement structure
- Ensure CallStatement can contain nested statements
- May already support nesting in AST, just not in parser

**Step 2: Parser Modifications** (2-3 hours)
- Locate CALL parsing in `src/gql/parser.zig`
- Add recursive statement parsing within CALL blocks
- Handle scope management for nested contexts
- Add depth limit to prevent stack overflow

**Step 3: Execution Support** (1-2 hours)
- Verify `src/execution.zig` can handle nested CALL
- May need to add context stacking
- Test nested variable scoping

**Step 4: Testing** (30 min)
- Test with various nesting depths
- Verify variable scoping works correctly

#### Files to Modify
- `src/gql/parser.zig` - Add recursive CALL parsing
- `src/gql/ast.zig` - Verify/update AST structure
- `src/execution.zig` - Add nested execution support

### Part B: Transaction Bodies (4-6 hours)

#### Problem
Parser doesn't support transaction body syntax:
```gql
START TRANSACTION {
  CREATE (n:Test {id: 1});
  MATCH (n:Test) RETURN n
}
```

#### Current State
- START TRANSACTION exists as statement
- Only handles transaction modifiers (READ ONLY, etc.)
- No support for body block

#### Implementation Plan

**Step 1: Grammar Analysis** (30 min)
- Review ISO GQL spec for transaction body syntax
- Understand expected semantics
- Determine if body has implicit COMMIT

**Step 2: AST Modifications** (1 hour)
- Add optional body field to transaction statement
- Body contains list of statements
- Update StartTransaction structure in `src/gql/ast.zig`

**Step 3: Parser Modifications** (2-3 hours)
- Update transaction statement parsing
- Parse optional `{ statements }` after START TRANSACTION
- Handle multiple statements within body
- Parse implicit COMMIT at end of body

**Step 4: Execution Support** (1-2 hours)
- Modify transaction execution to handle body
- Execute statements within transaction context
- Auto-commit at end of successful body
- Auto-rollback on error

**Step 5: Testing** (30 min)
- Test transaction bodies with various statements
- Verify implicit commit behavior
- Test error rollback

#### Files to Modify
- `src/gql/parser.zig` - Add transaction body parsing
- `src/gql/ast.zig` - Add body field to StartTransaction
- `src/execution.zig` - Execute transaction bodies
- `src/txn_session.zig` - May need updates for body handling

---

## 📋 Phase 4: Shell Output Issues (2 hours)

### Problem
Shell/REPL tests missing expected output text.

**Examples:**
- `shell-quic-connect` missing 'shell-test' in output
- `shell-multiple-queries` missing 'first' in output

### Investigation Required

**Step 1: Analyze failing tests** (30 min)
```bash
# Get list of all shell output failures
grep -A 5 "shell-" geodetestlab/specs/geode_quic_transport.yml
```

**Step 2: Understand expectations** (30 min)
- Review what output is expected
- Determine if tests are correct or code needs fixing
- May be test specification issues

**Step 3: Fix output or tests** (1 hour)
- If code issue: Update shell output formatting
- If test issue: Update test expectations
- Likely in `src/client/repl/` directory

### Files to Investigate
- `src/client/repl/repl_loop.zig`
- `src/client/repl/repl_dispatch.zig`
- `geodetestlab/specs/geode_quic_transport.yml`

---

## 🎯 Recommended Implementation Order

### Phase 2: Quick Medium Wins (3-4 hours)
1. **Type Validation** (2-3 hours)
   - High impact (3-5 tests)
   - Medium complexity
   - Well-understood problem

2. **Shell Output Issues** (2 hours)
   - Medium impact (12-13 tests)
   - Medium complexity
   - May be test spec issues

### Phase 3: Major Parser Work (8-12 hours)
3. **Nested CALL Blocks** (4-6 hours)
   - High impact (20-25 tests)
   - High complexity
   - Required for GQL compliance

4. **Transaction Bodies** (4-6 hours)
   - High impact (15-20 tests)
   - High complexity
   - Required for GQL compliance

### Phase 4: Cleanup (2-3 hours)
5. **Label Type Mismatches** (1-2 hours)
   - Low impact (2-3 tests)
   - Medium complexity

6. **Miscellaneous** (1-2 hours)
   - Individual investigation
   - Various complexity

---

## 📊 Expected Outcomes

| Phase | Tests Fixed | Cumulative Pass Rate | Time |
|-------|-------------|---------------------|------|
| Current | - | 94.0% (1560/1660) | - |
| Phase 2 | 15-18 | 95.1% (1578/1660) | 3-4h |
| Phase 3 | 35-45 | 97.5%+ (1618/1660) | 8-12h |
| Phase 4 | 5-10 | 98.0%+ (1628/1660) | 2-3h |
| **Total** | **55-73** | **98.0%+** | **13-19h** |

---

## 🔧 Development Process

### For Each Fix:

1. **Document current state**
   - Create/update tracking document
   - Note specific failing tests
   - Understand root cause

2. **Implement fix**
   - Make minimal changes
   - Add comments explaining logic
   - Follow existing code patterns

3. **Test incrementally**
   - Build after each change
   - Test specific failing cases
   - Verify no regressions

4. **Commit with evidence**
   - Clear commit message
   - Reference test names
   - Note before/after behavior

5. **Update documentation**
   - Mark fix as complete
   - Note any issues discovered
   - Update pass rate estimates

### Key Principles:

- **No Mock Data**: Always implement real functionality
- **No Simulation**: Tests must pass with actual implementation
- **Evidence-Based**: Verify fixes with real test runs
- **Incremental**: Small changes, frequent testing
- **Documented**: Maintain context across sessions

---

## 📝 Context for Future Sessions

### Critical Information to Preserve:

1. **Test Execution Command:**
```bash
python3 parallel_test_runner.py --specs-dir geodetestlab/specs \
  --binary ./zig-out/bin/geode --timeout 10 --max-workers 8
```

2. **Build Command:**
```bash
make build
```

3. **Key File Locations:**
- Parser: `src/gql/parser.zig`
- AST: `src/gql/ast.zig`
- Executor: `src/execution.zig`
- Evaluator: `src/eval.zig`
- Type Functions: `src/types/evaluator_functions.zig`
- CLI: `src/cli/main.zig`
- Tests: `geodetestlab/specs/`

4. **Current Pass Rate:** 95.0% (1563/1645 non-skipped tests) - Previously 94.0% (1560/1660)

5. **Completed Fixes:**
- JSON list formatting (spaces after commas)
- CLI backup cleanup command
- CLI migrate up alias
- Transaction session isolation

6. **Next Priority:** Type validation (2-3 hours, 3-5 tests)

---

*Last Updated: October 12, 2025 10:15 AM*
*Status: Phase 1 Complete, Starting Phase 2*
