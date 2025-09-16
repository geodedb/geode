# Numeric Promotion Matrix

This document defines the numeric type promotion rules for Geode's expression evaluator, following ISO/IEC 39075:2024 GQL numeric semantics.

## Type Promotion Rules

### Basic Types
- `Int`: 64-bit signed integer (`i64`)
- `Decimal`: Fixed-point decimal with coefficient and scale (`i128` coefficient, `u8` scale)

### Promotion Matrix

| Left Type | Right Type | Operation | Result Type | Notes |
|-----------|------------|-----------|-------------|-------|
| Int       | Int        | +, -, *   | Int         | Standard integer arithmetic |
| Int       | Int        | /         | Int         | Integer division (truncated) |
| Int       | Decimal    | +, -, *, / | Decimal     | Int promoted to Decimal(coeff=int, scale=0) |
| Decimal   | Int        | +, -, *, / | Decimal     | Int promoted to Decimal(coeff=int, scale=0) |
| Decimal   | Decimal    | +, -, *, / | Decimal     | Scale normalization applied |

### Comparison Operations

| Left Type | Right Type | Operations | Result | Notes |
|-----------|------------|------------|--------|-------|
| Int       | Int        | =, <>, <, <=, >, >= | Bool | Direct integer comparison |
| Int       | Decimal    | =, <>, <, <=, >, >= | Bool | Int promoted to Decimal for comparison |
| Decimal   | Int        | =, <>, <, <=, >, >= | Bool | Int promoted to Decimal for comparison |
| Decimal   | Decimal    | =, <>, <, <=, >, >= | Bool | Scale normalization applied |
| Int       | Str        | =, <>      | Bool | String-decimal conversion attempted |
| Str       | Int        | =, <>      | Bool | String-decimal conversion attempted |
| Any       | Any        | <, <=, >, >= | TypeMismatch | Cross-type ordering illegal |

### Scale Normalization

When operating on decimals with different scales:
1. Determine target scale: `max(left.scale, right.scale)`
2. Scale up coefficients: `coeff * 10^(target_scale - current_scale)`
3. Perform operation on normalized coefficients
4. Result has target scale

### Error Conditions

| Condition | Error Code | ISO Anchor | Example |
|-----------|------------|------------|---------|
| Division by zero | TypeMismatch.DivZero | 16.x | `RETURN 1/0` |
| Cross-type ordering | TypeMismatch | 16.x | `RETURN 1 < "abc"` |
| Invalid string-to-decimal | TypeMismatch | 16.x | `RETURN 1 = "not_a_number"` |

### Implementation-Defined Behaviors

- **I:NumericPromotion**: Int→Decimal promotion uses scale=0
- **I:DecimalPrecision**: Maximum coefficient is `i128` range
- **I:StringDecimalConversion**: Decimal string format follows standard decimal notation

### Examples

```gql
-- Integer arithmetic
RETURN 5 + 3        -- Result: Int(8)
RETURN 10 / 3       -- Result: Int(3) - truncated

-- Mixed arithmetic (promotion)
RETURN 5 + 3.14     -- Result: Decimal(coeff=814, scale=2)
RETURN 10.5 * 2     -- Result: Decimal(coeff=210, scale=1)

-- Comparisons
RETURN 5 = 5.0      -- Result: Bool(true) - after promotion
RETURN 3.14 > 3     -- Result: Bool(true) - after promotion

-- Error cases
RETURN 1/0          -- Error: TypeMismatch.DivZero
RETURN 1 < "abc"    -- Error: TypeMismatch
```

### Test Coverage

The promotion rules are validated by:
- `tests/e2e_protocol_decimal.zig` - Basic decimal operations
- `tests/e2e_protocol_decimal_fuzz.zig` - 10k randomized mixed-type operations
- `tests/e2e_protocol_div_zero.zig` - Division by zero handling
- `tests/e2e_protocol_decimal_order.zig` - Mixed-type ordering

### References

- ISO/IEC 39075:2024 clause 16.x (numeric expressions)
- ISO/IEC 39075:2024 clause 23.2 (diagnostics)
- `src/eval.zig` - Implementation
- `src/diagnostics.zig` - Error code definitions