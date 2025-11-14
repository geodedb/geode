# Geode Expression Evaluation Pipeline

**Document Version**: 1.0
**Last Updated**: 2025-11-13
**Status**: ACTIVE
**Related**: Phase 6 Modularization (Extract Expression Evaluation)

## Executive Summary

This document describes the expression evaluation pipeline in Geode's graph database query engine. After Phase 6 M6.1 modularization, the evaluation system is now organized into focused modules with clear separation of concerns.

**Key Statistics** (as of 2025-11-13):
- **Core Evaluator**: `src/eval.zig` (3,057 lines)
- **Type Promotion**: `src/eval/type_promotion.zig` (257 lines)
- **Total Functions**: 17 core functions + 10 type promotion functions
- **Architecture**: Modular design with dependency injection

## Architecture Overview

### Module Organization

```
src/
├── eval.zig (3,057 lines)              # Core expression evaluator
├── eval/
│   └── type_promotion.zig (257 lines)   # Type conversion & validation utilities
├── value_types.zig                      # Shared value types (from Phase 5)
├── execution/
│   └── evaluator_adapter.zig            # Execution callbacks (from Phase 5)
└── types/
    ├── evaluator_functions.zig          # Built-in function implementations
    ├── eval_extended.zig                # Extended value types
    └── heap_value.zig                   # Heap value representation
```

### Dependency Flow

```
┌─────────────────────────────────────────────────────────────┐
│                         eval.zig                             │
│                  (Core Expression Evaluator)                 │
│                                                              │
│  • evalExpr() - Main entry point                            │
│  • evalBinary() - Binary operations                         │
│  • tryBasicFunction() - Built-in functions                  │
│  • Pattern matching, regex, list operations                 │
└──────────────────┬──────────────────┬───────────────────────┘
                   │                  │
                   ▼                  ▼
      ┌────────────────────┐   ┌──────────────────────┐
      │ type_promotion.zig │   │  value_types.zig     │
      │                    │   │                      │
      │ • Type converters  │   │ • Value union type   │
      │ • Validators       │   │ • Env context        │
      │ • Comparisons      │   │ • Helper functions   │
      │ • Decimal scaling  │   │                      │
      └────────────────────┘   └──────────────────────┘
                   │
                   ▼
      ┌─────────────────────────────┐
      │  evaluator_adapter.zig      │
      │                             │
      │ • ExecutionCallbacks        │
      │ • Dependency injection      │
      │ • Breaks circular deps      │
      └─────────────────────────────┘
                   │
                   ▼
      ┌─────────────────────────────┐
      │     execution.zig           │
      │                             │
      │ • Query execution           │
      │ • Graph operations          │
      │ • Pattern matching          │
      └─────────────────────────────┘
```

## Evaluation Pipeline

### 1. Entry Point: `evalExpr()`

**Function Signature**:
```zig
pub fn evalExpr(allocator: std.mem.Allocator, e: ast.Expr, env: Env) EvalError!Value
```

**Purpose**: Main entry point for expression evaluation. Recursively evaluates AST expressions and returns computed values.

**Flow**:
```
Input: AST Expression + Environment
  │
  ├─→ Literal values (Null, Int, Bool, Str) → Direct Value construction
  ├─→ Variable references → Environment lookup
  ├─→ Binary operations → evalBinary()
  ├─→ Function calls → tryBasicFunction()
  ├─→ List operations → Recursive evaluation
  ├─→ Property access → Node/Edge property lookup
  ├─→ Pattern matching → Pattern comprehension logic
  ├─→ Subqueries → Execution callbacks (via evaluator_adapter)
  └─→ Conditional expressions → Ternary evaluation
  │
Output: Evaluated Value or EvalError
```

**Supported Expression Types**:
1. **Literals**: Null, Integer, Boolean, String, Decimal, List, Map
2. **Variables**: Environment variable lookup with null handling
3. **Binary Operations**: Arithmetic, comparison, logical, string operations
4. **Function Calls**: 50+ built-in functions
5. **Property Access**: Node/edge property navigation
6. **List Operations**: Comprehensions, IN/NOT IN checks
7. **Pattern Matching**: Graph pattern comprehensions, shortest path
8. **Subqueries**: IN subqueries, EXISTS checks
9. **Conditional**: CASE WHEN, ternary operators
10. **Type Conversions**: CAST operations

### 2. Binary Operations: `evalBinary()`

**Function Signature**:
```zig
fn evalBinary(alloc: std.mem.Allocator, op: ast.BinOp, l: Value, r: Value) EvalError!Value
```

**Supported Operations**:

#### Logical Operations (3-valued logic)
- `AND`, `OR`, `XOR` - Three-valued logic with NULL propagation
- Delegates to: `and3()`, `or3()`, `xor3()`

#### Arithmetic Operations
- `Add (+)` - Integer addition with overflow detection, decimal addition, string concatenation
- `Sub (-)` - Integer/decimal subtraction with overflow protection
- `Mul (*)` - Integer/decimal multiplication
- `Div (/)` - Integer/decimal division with zero check
- `Mod (%)` - Integer modulo operation

**Type Promotion Rules**:
```
Int + Int → Int (with overflow check)
Decimal + Int → Decimal (scale alignment via scaleTo)
Int + Decimal → Decimal (scale alignment)
Decimal + Decimal → Decimal (scale to max scale)
Str + Str → Str (optimized memcpy concatenation)
```

#### Comparison Operations
- `Eq (=)`, `Ne (<>)`, `Lt (<)`, `Le (<=)`, `Gt (>)`, `Ge (>=)`
- Type-specific comparisons:
  - **Integers**: Direct comparison via `cmpIntsOp()`
  - **Decimals**: Scale alignment then `cmpI128()` comparison
  - **Strings**: Unicode NFC normalization then byte-wise comparison
  - **Booleans**: Equality/inequality only
  - **NULLs**: NULL = NULL is true, NULL op X is false (except Eq/Ne)

#### String Operations
- `Concat (||)` - String concatenation with type coercion
- `RegexMatch (=~)` - Pattern matching via `matchSimplePattern()`
- `RegexNotMatch (!~)` - Negated pattern matching

**NULL Propagation**:
- All arithmetic operations: `NULL op X = NULL`
- Comparison operations: `NULL = NULL` is `true`, others are `false`
- Logical operations: Three-valued logic (see and3/or3/xor3)

### 3. Function Evaluation: `tryBasicFunction()`

**Function Signature**:
```zig
fn tryBasicFunction(allocator: std.mem.Allocator, function_name: []const u8, args: []*ast.Expr, env: Env) !?Value
```

**Function Categories**:

#### String Functions (15+)
- `length()`, `upper()`, `lower()`, `trim()`, `ltrim()`, `rtrim()`
- `substring()`, `left()`, `right()`, `replace()`
- `concat()`, `reverse()`, `split()`
- Delegates to: `types/evaluator_functions.zig`

#### Mathematical Functions (20+)
- Trigonometric: `sin()`, `cos()`, `tan()`, `asin()`, `acos()`, `atan()`, `atan2()`
- Exponential: `exp()`, `log()`, `log10()`, `pow()`, `sqrt()`
- Rounding: `ceil()`, `floor()`, `round()`, `abs()`
- Special: `pi()`, `e()`, `sign()`, `rand()`

#### Type Conversion Functions
- `toString()`, `tostring()` - Value to string conversion
- `toInteger()`, `tointeger()`, `toint()` - Value to integer
- `toFloat()`, `tofloat()`, `toDouble()`, `todouble()` - Value to decimal
- Uses: `type_promotion` module converters

#### Date/Time Functions (10+)
- `now()`, `date()`, `time()`, `datetime()`
- `year()`, `month()`, `day()`, `hour()`, `minute()`, `second()`
- Temporal arithmetic and formatting

#### Aggregate Functions
- `count()`, `sum()`, `avg()`, `min()`, `max()`
- `collect()`, `percentile()`, `stdev()`

#### Graph Functions
- `id()`, `labels()`, `type()`, `properties()`
- `startNode()`, `endNode()`, `nodes()`, `relationships()`
- `degree()`, `indegree()`, `outdegree()`

#### Security & Context Functions
- `current_user()` - Returns authenticated user from environment
- `has_permission()` - Row-level security check

**Function Resolution**:
1. Check function name (case-insensitive matching)
2. Evaluate arguments recursively via `evalExpr()`
3. Delegate to `evaluator_functions.zig` for implementation
4. Convert between Value types as needed using `type_promotion`

### 4. Type Promotion & Conversion

Handled by `eval/type_promotion.zig` module (extracted in Phase 6 M6.1).

#### Decimal Scale Conversion
```zig
scaleTo(coeff: i128, from: u8, to: u8) -> i128
```
- Upscaling: Multiply by powers of 10 (with overflow check)
- Downscaling: Divide by powers of 10 (truncation)
- Used in all decimal arithmetic operations

#### Type Validators
```zig
expectString(v: Value) -> []const u8
expectInt(v: Value) -> i64
```
- Type-safe extraction with clear error messages
- Used in function argument validation

#### Value Converters
```zig
valueToExtValue(alloc, value) -> ExtValue    # eval.Value → ExtValue
extValueToValue(ext_value) -> Value          # ExtValue → eval.Value
evalValueToHeapValue(value) -> heap.Value    # eval.Value → heap.Value
heapValueToEvalValue(value) -> Value         # heap.Value → eval.Value
```
- **Purpose**: Bridge between different value representations
- **ExtValue**: Extended types (IP addresses, temporal types, crypto types)
- **heap.Value**: Storage layer representation
- **Overflow Protection**: Real/Double → Decimal conversion with NaN/Infinity handling

#### Comparison Helpers
```zig
cmpI128(a, b) -> i2              # Returns -1, 0, or 1
cmpToBool(op, ord) -> bool       # Converts comparison to boolean
cmpIntsOp(op, a, b) -> Value     # Integer comparison with operator
```

### 5. Pattern Matching & Regex

#### Simple Pattern Matching
```zig
pub fn matchSimplePattern(s: []const u8, p_in: []const u8) bool
```

**Supported Patterns**:
- `.` - Match any single character
- `*` - Match zero or more characters (Kleene star)
- `+` - Match one or more characters (converted to `..*`)
- `[abc]` - Character class (match a, b, or c)
- `[^abc]` - Negated character class (match anything except a, b, c)
- `[a-z]` - Character ranges
- `\` - Escape sequences for literal matching

**Implementation**:
- Recursive descent algorithm in `regexRec()`
- Backtracking support for `*` quantifier
- Character class matching in `regexMatchClass()`
- Escape sequence handling in `regexEatEsc()`

**Optimization**:
- `+` quantifier converted to `..*` via `transformPlusQuantifier()`
- Early termination on mismatch
- Stack-based recursion (suitable for typical pattern sizes)

#### Pattern Comprehensions
```
[(a)--(b) WHERE a.age > 30 | b.name]
```
- Delegates to execution callbacks via `evaluator_adapter`
- Calls `executePatternComprehension()` in execution layer
- Supports filtering and projection

### 6. List Operations

#### IN / NOT IN Operations
```zig
fn inList(value: Value, set: []*ast.Expr, allocator: std.mem.Allocator, env: Env) EvalError!Value
```

**Behavior**:
- Evaluates each list element via `evalExpr()`
- Compares using `eqVals()` from `value_types`
- Returns `Value{ .Bool = true/false }`
- NULL handling: `NULL IN [...]` returns NULL

**Subquery Support**:
```
WHERE x IN (SELECT y FROM nodes)
```
- Delegates to `executeQueryWithContext()` via execution callbacks
- Extracts result set
- Performs membership check

### 7. Graph-Specific Operations

#### Property Access
```
node.name
edge.weight
```
- Direct property lookup on Node/Edge values
- Returns property value or NULL if not found
- Type preservation (Int, Str, Bool, etc.)

#### Path Operations
- Shortest path expressions
- Path length calculations
- Node/relationship extraction from paths

## Error Handling

### Error Types (`EvalError`)

Defined in `value_types.zig`:

```zig
pub const EvalError = error{
    TypeMismatch,        // Incompatible types in operation
    DivisionByZero,      // Division or modulo by zero
    IntegerOverflow,     // Integer arithmetic overflow
    OutOfMemory,         // Allocation failure
    Unsupported,         // Operation not supported
    InvalidArgument,     // Invalid function argument
    // ... additional errors
};
```

### Error Propagation

1. **Bottom-Up Propagation**: Errors bubble up the expression tree
2. **Try-Catch Pattern**: All operations use `!` error union return
3. **NULL vs Error**: NULLs are values, errors are exceptional conditions
4. **Context Preservation**: Error context includes operation type

### NULL Handling Strategy

**Three-Valued Logic (3VL)**:
- `true AND NULL` = `NULL`
- `false AND NULL` = `false`
- `true OR NULL` = `true`
- `NULL = NULL` = `true` (GQL/SQL semantics)
- `NULL <> NULL` = `false`
- `NULL < X` = `false` (for all other comparisons)

**Arithmetic**:
- `NULL + X` = `NULL` (propagation)
- `NULL * X` = `NULL`
- All arithmetic operations propagate NULL

## Performance Optimizations

### 1. String Concatenation (Phase 5.1.3)
```zig
// Optimized: Direct memcpy (3-5x faster than allocPrint)
const result = try alloc.alloc(u8, l.Str.len + r.Str.len);
@memcpy(result[0..l.Str.len], l.Str);
@memcpy(result[l.Str.len..], r.Str);
```

**CANARY**: `REQ-PERF-PHASE5-003`

### 2. Overflow Detection
```zig
// Safe arithmetic with builtin overflow detection
const result_tuple = @addWithOverflow(l.Int, r.Int);
if (result_tuple[1] != 0) return EvalError.IntegerOverflow;
```

### 3. Unicode String Comparison
```zig
// NFC normalization for correct Unicode comparison
const ln = unicode.nfcNormalize(gpa_alloc, l.Str);
const rn = unicode.nfcNormalize(gpa_alloc, r.Str);
const ord = std.mem.order(u8, ln, rn);
```

**CANARY**: `REQ-GQL-UNICODE-009`

### 4. Decimal Operations
- Scale alignment minimization
- Coefficient operations on aligned scales
- Overflow protection in scale conversion

## Extension Points

### 1. Adding New Built-in Functions

**Location**: `src/types/evaluator_functions.zig`

**Steps**:
1. Implement function logic in evaluator_functions.zig
2. Add function name check in `tryBasicFunction()`
3. Handle argument evaluation and type conversion
4. Return Value or error

**Example**:
```zig
// In tryBasicFunction()
if (std.mem.eql(u8, function_name, "my_function")) {
    // Evaluate arguments
    const arg1 = try evalExpr(allocator, args[0].*, env);

    // Delegate to implementation
    const result = evaluator_functions.my_function_impl(arg1);

    // Return value
    return result;
}
```

### 2. Adding New Value Types

**Location**: `src/value_types.zig`

**Steps**:
1. Add new variant to `Value` union
2. Update `eqVals()` for equality comparison
3. Update `isNull()` if needed
4. Add type conversion functions in `type_promotion.zig`
5. Update `evalBinary()` for type-specific operations

### 3. Adding New Operators

**Location**: `src/gql/ast.zig` (AST), `src/eval.zig` (evaluation)

**Steps**:
1. Add operator to `ast.BinOp` enum
2. Update parser to recognize operator
3. Add case in `evalBinary()` switch statement
4. Implement operation logic with type handling

## Testing Strategy

### Unit Testing

**Type Promotion Tests** (`tests/type_promotion_test.zig`):
```zig
test "scaleTo upscaling" {
    const result = try scaleTo(123, 2, 5);
    try std.testing.expectEqual(@as(i128, 123000), result);
}

test "scaleTo overflow detection" {
    try std.testing.expectError(EvalError.Unsupported,
        scaleTo(std.math.maxInt(i128) / 5, 0, 3));
}
```

**Comparison Tests**:
```zig
test "cmpI128 ordering" {
    try std.testing.expectEqual(@as(i2, -1), cmpI128(-100, 50));
    try std.testing.expectEqual(@as(i2, 0), cmpI128(42, 42));
    try std.testing.expectEqual(@as(i2, 1), cmpI128(100, 50));
}
```

### Integration Testing

**Expression Evaluation** (via geodetestlab):
```
# Arithmetic
RETURN 1 + 2                    # Expected: 3
RETURN 1.5 + 2                  # Expected: 3.5 (decimal)
RETURN 'hello' + ' world'       # Expected: 'hello world'

# NULL propagation
RETURN NULL + 5                 # Expected: NULL
RETURN NULL AND true            # Expected: NULL
RETURN NULL = NULL              # Expected: true

# Type conversions
RETURN toInteger('42')          # Expected: 42
RETURN toString(123)            # Expected: '123'

# Functions
RETURN length('test')           # Expected: 4
RETURN upper('hello')           # Expected: 'HELLO'
```

### Performance Testing

**Benchmark Scenarios**:
1. **Arithmetic Intensity**: 10,000 additions/multiplications
2. **String Operations**: 1,000 concatenations
3. **Decimal Operations**: 1,000 scale conversions
4. **Function Calls**: 1,000 built-in function invocations
5. **Pattern Matching**: 1,000 regex evaluations

**Success Criteria**:
- No performance regression vs baseline
- Linear scaling with expression complexity
- Memory usage within expected bounds

## Modularization Progress

### Phase 6 Status

**M6.1: Extract Type Promotion** ✅ COMPLETE
- Created `src/eval/type_promotion.zig` (257 lines)
- Extracted 10 functions from eval.zig
- Reduced eval.zig by 119 lines (-3.8%)

**M6.2: Consolidate Evaluation Logic** 🔄 IN PROGRESS
- Documented evaluation pipeline (this document)
- Identified remaining structure
- No further immediate extraction needed

### Remaining Structure

**eval.zig (3,057 lines)**:
1. **Callback Management** (10 lines) - Phase 5 infrastructure
2. **Logical Operations** (38 lines) - and3, or3, xor3
3. **Regex Functions** (86 lines) - Pattern matching primitives
4. **Binary Evaluation** (234 lines) - Core arithmetic/comparison
5. **String Predicates** (32 lines) - startsWith, endsWith, contains
6. **Pattern Matching** (64 lines) - matchSimplePattern, transformPlusQuantifier
7. **Main Evaluator** (1,388 lines) - evalExpr (core logic)
8. **Function Dispatcher** (823 lines) - tryBasicFunction
9. **List Operations** (119 lines) - inList

**Further Extraction Opportunities**:
- Could extract regex functions to `eval/regex.zig` (~150 lines)
- Could extract string predicates to `eval/string_ops.zig` (~50 lines)
- However, current organization is already quite modular
- Further extraction may provide diminishing returns

### Completion Assessment

**Phase 6 Targets**:
- ✅ Type system more modular (type_promotion extracted)
- ⚠️ eval.zig reduced to ~2,500 lines (currently 3,057, ~82% of target)
- ✅ Better test coverage (type promotion testable independently)
- ✅ Documentation complete (this document)

**Recommendation**: Phase 6 is substantially complete. The remaining ~557 lines (18%) to reach 2,500 target could be extracted, but the evaluation system is now well-modularized with clear boundaries.

## References

### Source Files
- `src/eval.zig` - Core expression evaluator
- `src/eval/type_promotion.zig` - Type conversion utilities
- `src/value_types.zig` - Shared value types (Phase 5)
- `src/execution/evaluator_adapter.zig` - Execution callbacks (Phase 5)
- `src/types/evaluator_functions.zig` - Built-in function implementations
- `src/gql/ast.zig` - Abstract syntax tree definitions

### Related Documentation
- `docs/GQL_COMPLIANCE.md` - ISO/IEC 39075:2024 conformance
- `docs/TYPES_AND_FUNCTIONS.md` - Type system reference
- `docs/architecture/ADR_execution_eval_refactor.md` - Phase 5 circular dependency resolution
- `docs/architecture/execution_eval_dependency_analysis.md` - Dependency analysis

### Modularization Documentation
- `docs/MODULARIZATION_PLAN.md` - Complete modularization strategy
- `docs/MODULARIZATION_STATUS.md` - Current implementation status

---

**Document Status**: Complete
**Review Date**: 2025-11-13
**Next Review**: After Phase 7 completion or significant evaluation changes
**Maintainer**: Geode Architecture Team
