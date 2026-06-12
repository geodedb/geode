# GQL Expression Operators

This document describes the implemented expression operators in Geode's GQL parser and evaluator.

## Arithmetic Operators

### Modulo Operator (`%`)

**Status:** ✅ Implemented (October 2025)

**Requirements:** REQ-GQL-EXPR-MOD-001 through REQ-GQL-EXPR-MOD-004

**Syntax:**

```gql
RETURN dividend % divisor AS result
```

**Description:**
Computes the remainder of integer division. The modulo operator has the same precedence as multiplication and division.

**Examples:**

```gql
// Basic modulo
RETURN 17 % 5 AS result;  // Returns: 2

// Negative operands
RETURN -17 % 5 AS result;  // Returns: -2
RETURN 17 % -5 AS result;  // Returns: 2

// Combined with other operators
RETURN 10 + 17 % 5 AS result;  // Returns: 12 (precedence: 10 + (17 % 5))

// Using in WHERE clauses
MATCH (n:Number)
WHERE n.value % 2 = 0
RETURN n.value AS even_numbers;
```

**Error Handling:**

- Division by zero: Returns `EvalError.DivisionByZero` at runtime
- Type mismatch: Returns `EvalError.TypeMismatch` for non-integer operands

**Implementation:**

- AST: Added `Mod` to `BinOp` enum in `src/gql/ast.zig:200`
- Parser: Updated `parseMulExpr()` in `src/gql/parser.zig:1410-1424`
- Evaluator: Added modulo evaluation in `src/eval.zig:307-314`
- Printer: Added print support in `src/gql/print.zig:525`

---

## Unary Operators

### Unary Plus Operator (`+`)

**Status:** ✅ Implemented (October 2025)

**Requirements:** REQ-GQL-EXPR-UNARY-PLUS-001 through REQ-GQL-EXPR-UNARY-PLUS-004

**Syntax:**

```gql
RETURN +expression AS result
```

**Description:**
The unary plus operator returns its operand unchanged. It is primarily used for symmetry with unary minus and to explicitly indicate positive numbers.

**Examples:**

```gql
// Basic unary plus
RETURN +42 AS result;  // Returns: 42

// With decimals
RETURN +3.14 AS result;  // Returns: 3.14

// Double application
RETURN + +42 AS result;  // Returns: 42

// Mixed with unary minus
RETURN +-42 AS result;  // Returns: -42 (parsed as +(−42))
RETURN -+42 AS result;  // Returns: -42 (parsed as −(+42))
```

**Type Support:**

- Integers: Returns value unchanged
- Decimals: Returns value unchanged
- Other types: Returns `EvalError.TypeMismatch`

**Implementation:**

- AST: Added `Pos` to `UnaryOp` enum in `src/gql/ast.zig:201`
- Parser: Updated `parseUnaryExpr()` in `src/gql/parser.zig:1454-1461`
- Evaluator: Added unary plus evaluation in `src/eval.zig:576-579`
- Printer: Added print support in `src/gql/print.zig:506`

---

## Postfix Operators

### Array Index Access (`[index]`)

**Status:** ✅ Implemented (October 2025)

**Requirements:** REQ-GQL-EXPR-INDEX-001 through REQ-GQL-EXPR-INDEX-005

**Syntax:**

```gql
array_expression[index_expression]
```

**Description:**
Accesses an element from a list/array by its zero-based index. The index must be an integer expression.

**Examples:**

```gql
// Basic array indexing
RETURN [1, 2, 3][0] AS first;  // Returns: 1
RETURN [1, 2, 3][2] AS third;  // Returns: 3

// Function result indexing
MATCH (n)
RETURN labels(n)[0] AS primary_label;

// Chained indexing
RETURN [[1, 2], [3, 4]][0][1] AS result;  // Returns: 2

// Dynamic index expression
RETURN [10, 20, 30][1 + 1] AS result;  // Returns: 30

// Combined with other operators
RETURN [10, 20, 30][17 % 3] AS result;  // Returns: 30 (17 % 3 = 2)

// Property access on indexed element
MATCH (n:Person)
RETURN n.friends[0].name AS best_friend;
```

**Behavior:**

- **Out of bounds:** Returns `null` (no error)
- **Negative indices:** Returns `null` (does not wrap around)
- **Non-list target:** Returns `null`
- **Non-integer index:** Returns `EvalError.TypeMismatch`

**Implementation:**

- AST: Added `Index` expression variant in `src/gql/ast.zig:179`
- Parser: Implemented in `parsePostfixExpr()` in `src/gql/parser.zig:1537-1549`
- Evaluator: Added array indexing with bounds checking in `src/eval.zig:1223-1244`
- Printer: Added print and walk support in `src/gql/print.zig:502-507,226-229`

---

## Operator Precedence

From highest to lowest precedence:

1. **Postfix operators:** `.` (member access), `[index]` (array index), `()` (function call)
2. **Unary operators:** `NOT`, `-` (unary minus), `+` (unary plus)
3. **Multiplicative:** `*`, `/`, `%`
4. **Additive:** `+`, `-`
5. **Comparison:** `<`, `<=`, `>`, `>=`, `=`, `<>`
6. **Logical:** `AND`, `OR`

**Example:**

```gql
RETURN 10 + labels(n)[0].length * 2 % 3 AS result
```

Evaluation order:

1. `labels(n)` - function call
2. `[0]` - array index
3. `.length` - member access
4. `* 2` - multiplication
5. `% 3` - modulo
6. `10 +` - addition

---

## Testing

All operators have comprehensive unit tests in `src/test_arithmetic_operators.zig`:

- **Modulo tests:** 4 tests covering basic operations, negative operands, division by zero, and precedence
- **Unary plus tests:** 4 tests covering basic usage, decimals, chaining, and mixing with unary minus
- **Array index tests:** 6 tests covering basic indexing, function results, chaining, dynamic indices, out-of-bounds, and combinations

**Run tests:**

```bash
zig build test --summary all
```

---

## ISO/IEC 39075:2024 (GQL) Compliance

These implementations comply with the GQL standard:

- **Modulo operator:** Part of standard arithmetic expressions (Section 5.3)
- **Unary plus:** Part of standard unary expressions (Section 5.3)
- **Array indexing:** Part of standard value expressions (Section 5.2)

---

## Performance Notes

- **Modulo:** Uses Zig's `@rem` builtin for optimal performance
- **Unary plus:** Zero-cost at evaluation (returns value unchanged)
- **Array indexing:** O(1) access with bounds checking

---

## Future Enhancements

Potential improvements for future versions:

1. **Modulo for decimals:** Support floating-point modulo operations
2. **Negative array indices:** Python-style negative indexing from end
3. **Slice notation:** Support `array[start..end]` syntax for sub-arrays
4. **Multi-dimensional arrays:** Optimize `array[i][j]` to avoid intermediate allocations

---

*Last Updated: October 2025*
*Implementation Status: Implemented and regression-tested (see [GAP_ANALYSIS.md](GAP_ANALYSIS.md) for open gaps)*
