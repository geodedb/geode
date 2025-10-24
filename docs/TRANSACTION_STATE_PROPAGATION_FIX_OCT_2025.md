# Transaction State Propagation Fix - October 2025

## Date: October 9, 2025

## Overview

Fixed transaction state propagation in multi-statement queries, improving test pass rate from 81.8% to 82.0% (+3 tests).

## Problem

When executing multiple statements in a single query (separated by semicolons), transaction state changes were not propagating between statements.

### Example of the Bug

```gql
-- This should fail but was succeeding:
START TRANSACTION; START TRANSACTION
```

The second `START TRANSACTION` should return `TransactionAlreadyActive` error, but it was succeeding because each statement was executed with the same (immutable) execution context.

### Root Cause

In `/home/benji/src/spyder/geode/src/execution.zig`, the `executeProgramWithContext` function was executing all statements with the same immutable context:

```zig
// BEFORE (buggy):
pub fn executeProgramWithContext(allocator: std.mem.Allocator, program: *const ast.Program, context: ExecutionContext) !ExecutionResult {
    // ...
    var last_result: ?ExecutionResult = null;

    for (program.statements) |stmt| {
        // ...
        last_result = try executeStatementWithContext(allocator, stmt, context);  // <-- same context!
    }
    // ...
}
```

When the first `START TRANSACTION` executed, it modified the transaction_state locally but didn't affect the context passed to subsequent statements.

## Solution

Modified `executeProgramWithContext` to maintain a mutable context and propagate transaction state changes:

**File**: `/home/benji/src/spyder/geode/src/execution.zig:374-399`

```zig
// AFTER (fixed):
pub fn executeProgramWithContext(allocator: std.mem.Allocator, program: *const ast.Program, context: ExecutionContext) !ExecutionResult {
    // ...
    // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StatePropagation; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Maintain mutable context to propagate transaction state changes across statements
    var last_result: ?ExecutionResult = null;
    var current_context = context;  // <-- mutable context

    for (program.statements) |stmt| {
        // ...
        last_result = try executeStatementWithContext(allocator, stmt, current_context);  // <-- updated context

        // Propagate transaction state changes to next statement
        switch (stmt) {
            .StartTransaction => {
                current_context.transaction_state = .Active;  // <-- propagate state!
            },
            .Commit, .Rollback => {
                current_context.transaction_state = .None;
            },
            else => {},
        }
    }
    // ...
}
```

## Testing

### Manual Testing

```bash
# Test 1: Double START TRANSACTION should fail
$ rm -f /tmp/geode_transaction_session.txt
$ ./zig-out/bin/geode query --no-quic "START TRANSACTION; START TRANSACTION"
# Before: Success (bug)
# After: TransactionAlreadyActive (correct!)

# Test 2: START TRANSACTION + COMMIT should succeed
$ rm -f /tmp/geode_transaction_session.txt
$ ./zig-out/bin/geode query --no-quic "START TRANSACTION; COMMIT"
# Before: Success
# After: Success (still works correctly)

# Test 3: COMMIT without START TRANSACTION should fail
$ rm -f /tmp/geode_transaction_session.txt
$ ./zig-out/bin/geode query --no-quic "COMMIT"
# Before: NoActiveTransaction (correct)
# After: NoActiveTransaction (correct)
```

### Automated Testing

```bash
$ python3 parallel_test_runner.py

# Results:
Total tests: 1630
Passed: 1337 (+3 from 1334)
Failed: 274 (-3 from 277)
Skipped: 34
Pass rate: 82.0% (+0.2% from 81.8%)
```

## Impact

**Tests Fixed**: +3 tests
**Pass Rate Improvement**: +0.2% (81.8% → 82.0%)

### Specific Test Improvements

- `session_transaction_fixes.yml`: 16P / 6F (72.7% pass rate)
- Multi-statement transaction queries now work correctly

### Remaining Transaction Issues

**16 tests still failing** in `gql_transaction_management_comprehensive.yml` (20.0% pass rate)

**Why**: These tests require server mode with persistent connections, which is incompatible with `--no-quic` embedded mode:

1. Transaction state is persisted to `/tmp/geode_transaction_session.txt` between process invocations
2. Each test invocation is a separate process
3. Setup/teardown commands are separate invocations that expect stateful server connections
4. Parallel runner uses embedded mode which doesn't maintain persistent connections

**Solution**: These tests should run with the geodetestlab core runner (which has server support), not the parallel runner.

## Code Changes

### Files Modified

```
/home/benji/src/spyder/geode/src/execution.zig
  - Lines 374-399: Added mutable context and transaction state propagation
```

### Lines Changed

```diff
-    // Execute all statements and return the result of the last one
-    var last_result: ?ExecutionResult = null;
-
-    for (program.statements) |stmt| {
-        // Free previous result if any
-        if (last_result) |*result| {
-            result.deinit(allocator);
-        }
-
-        last_result = try executeStatementWithContext(allocator, stmt, context);
-    }
+    // Execute all statements and return the result of the last one
+    // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StatePropagation; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
+    // Maintain mutable context to propagate transaction state changes across statements
+    var last_result: ?ExecutionResult = null;
+    var current_context = context;
+
+    for (program.statements) |stmt| {
+        // Free previous result if any
+        if (last_result) |*result| {
+            result.deinit(allocator);
+        }
+
+        last_result = try executeStatementWithContext(allocator, stmt, current_context);
+
+        // Propagate transaction state changes to next statement
+        // Check if this statement was a transaction control statement
+        switch (stmt) {
+            .StartTransaction => {
+                current_context.transaction_state = .Active;
+            },
+            .Commit, .Rollback => {
+                current_context.transaction_state = .None;
+            },
+            else => {},
+        }
+    }
```

## Related Issues

- [REMAINING_TEST_FAILURES_OCT_2025_FINAL.md](REMAINING_TEST_FAILURES_OCT_2025_FINAL.md) - Documents transaction test architectural mismatch
- [GEODE_BINARY_FIXES_IMPLEMENTATION_PLAN.md](GEODE_BINARY_FIXES_IMPLEMENTATION_PLAN.md) - Implementation plan for remaining fixes

## Next Steps

1. ✅ **Transaction state propagation fixed** (this fix)
2. 📋 **Remaining transaction tests** - Require server mode support or test spec changes
3. 📋 **Keywords as identifiers** - Parser enhancement (~30 tests)
4. 📋 **WITH clause after CREATE** - Parser/execution fix (~24 tests)
5. 🐛 **Memory bugs** - Invalid free and alignment issues (8 tests)

---

*Last Updated: October 9, 2025*
*Status: COMPLETE - Transaction state propagation fixed and tested*
