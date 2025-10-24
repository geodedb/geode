# Type Validation Fix - Investigation Notes

## Problem Statement

Invalid type conversions currently return `null` instead of causing query failure with exit code 1.

**Test Case:**
```gql
RETURN toInteger('not_a_number') AS invalid_conversion
```

**Current Behavior:**
- Exit code: 0 (success)
- Output: `{"status_class":"00000","columns":["invalid_conversion"],"rows":[[null]],"flagger_findings":[]}`

**Expected Behavior:**
- Exit code: 1 (error)
- Error message about invalid type conversion

## Investigation Steps

### Step 1: Trace the Error Flow

#### A. Function Call Evaluation (`src/eval.zig:2103-2113`)

```zig
} else if (std.mem.eql(u8, function_name, "tointeger")) {
    const result = evaluator_functions.toInteger_val(heap_first_arg) catch |err| {
        // Convert evaluator errors to eval errors
        return switch (err) {
            evaluator_functions.EvaluatorError.InvalidFormat => EvalError.TypeMismatch,
            evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
            evaluator_functions.EvaluatorError.Overflow => EvalError.Unsupported,
            else => EvalError.TypeMismatch,
        };
    };
    return heapValueToEvalValue(result);
}
```

**Analysis:** Error is properly converted to `EvalError.TypeMismatch` and returned.

#### B. Find who calls `evalFunctionCall`

Need to search for callers of `evalFunctionCall` function.

### Step 2: Search for Error Swallowing

```bash
# Find where errors might be caught and converted to null
grep -n "evalFunctionCall" src/eval.zig
grep -n "catch.*null" src/eval.zig
grep -n "orelse.*Null" src/eval.zig
```

### Step 3: Find Return Clause Execution

The RETURN clause executor needs to handle expression errors and propagate them to the query executor.

---

## Investigation Results

### Finding 1: Error Swallowing Location

**File:** `src/eval.zig`
**Line:** 1240-1242
**Code:**
```zig
const result = tryBasicFunction(ally, lowercase_name, call.args, env) catch {
    break :blk_call .{ .Null = {} };
};
```

### Finding 2: Root Cause

The issue is in how basic function errors are handled:

1. **tryBasicFunction (line 2104-2112)** correctly returns `EvalError.TypeMismatch` for invalid toInteger conversions
2. **Extended functions (lines 1214-1236)** properly propagate validation errors like TypeMismatch
3. **Basic functions (lines 1240-1242)** catch ALL errors and convert them to null - THIS IS THE BUG

The extended function handler (lines 1214-1236) shows the correct pattern:
```zig
} else |err| {
    const err_name = @errorName(err);
    if (std.mem.eql(u8, err_name, "TypeMismatch")) {
        return EvalError.TypeMismatch;
    } else if (std.mem.eql(u8, err_name, "DivisionByZero")) {
        return EvalError.DivisionByZero;
    }
    // For other errors, fall back to null
    break :blk_call .{ .Null = {} };
}
```

### Finding 3: Required Changes

**Change line 1240-1242** to handle errors the same way as extended functions - propagate validation errors instead of catching them all.

---

## Implementation Plan

### Change 1: Fix Basic Function Error Propagation
**File:** `src/eval.zig`
**Line:** 1240-1258
**Before:**
```zig
const result = tryBasicFunction(ally, lowercase_name, call.args, env) catch {
    break :blk_call .{ .Null = {} };
};
```

**After:**
```zig
const result = tryBasicFunction(ally, lowercase_name, call.args, env) catch |err| {
    // Propagate validation errors instead of converting to null
    const err_name = @errorName(err);
    if (std.mem.eql(u8, err_name, "TypeMismatch")) {
        return EvalError.TypeMismatch;
    } else if (std.mem.eql(u8, err_name, "InvalidFormat")) {
        return EvalError.TypeMismatch;
    } else if (std.mem.eql(u8, err_name, "Unsupported")) {
        return EvalError.Unsupported;
    } else if (std.mem.eql(u8, err_name, "DivisionByZero")) {
        return EvalError.DivisionByZero;
    } else if (std.mem.eql(u8, err_name, "DecimalDivZero")) {
        return EvalError.DecimalDivZero;
    } else if (std.mem.eql(u8, err_name, "DecimalOverflow")) {
        return EvalError.DecimalOverflow;
    }
    // For other errors, fall back to null
    break :blk_call .{ .Null = {} };
};
```

**Reason:** Match the error handling pattern used for extended functions (lines 1214-1236). This ensures validation errors like TypeMismatch are properly propagated instead of being swallowed and converted to null.

### Change 2: [Location]
**File:**
**Line:**
**Before:**
```zig
```

**After:**
```zig
```

**Reason:**

---

## Testing

### Test Commands
```bash
# Build
make build

# Test single case
./zig-out/bin/geode query --no-quic "RETURN toInteger('not_a_number') AS invalid_conversion"
# Should exit with code 1

# Run all type validation tests
python3 parallel_test_runner.py --specs-dir geodetestlab/specs \
  --binary ./zig-out/bin/geode --timeout 10 --max-workers 8 \
  2>&1 | grep -E "(type-error|type-system)"
```

### Expected Results

**Before Fix:**
- Exit code: 0
- Returns null value

**After Fix:**
- Exit code: 1
- Error message about invalid conversion

### Verification Results

**Test 1: Invalid Conversion**
```bash
$ ./zig-out/bin/geode query --no-quic "RETURN toInteger('not_a_number') AS invalid_conversion"
Exit code: 1
Type mismatch in expression
```
✅ PASS - Properly returns exit code 1 with error message

**Test 2: Valid Conversion**
```bash
$ ./zig-out/bin/geode query --no-quic "RETURN toInteger('42') AS valid_conversion"
{"status_class":"00000","columns":["valid_conversion"],"rows":[[42]],"flagger_findings":[]}
Exit code: 0
```
✅ PASS - Valid conversions still work correctly

---

## Progress Log

### [Timestamp] - Investigation Started
- Created tracking document
- Beginning error flow trace

---

*Last Updated: [Will be updated during implementation]*
