# Implementation Changes - October 2025

## Date/Time Function Implementation

### Overview
Implemented missing date/time functions (`current_date()`, `current_time()`, `current_timestamp()`) to support temporal queries in GQL.

### Files Modified

#### 1. `src/types/evaluator_functions.zig`
- **Added**: `current_timestamp()` function
  - Returns current timestamp as `TimestampTZ` type
  - Uses `std.time.microTimestamp()` for microsecond precision
  - Location: Line ~608

**Existing functions** (already present):
- `current_date()` - Returns current date as `Date` type (days since epoch)
- `current_time()` - Returns current time as `Time` type (microseconds since midnight)

#### 2. `src/eval.zig`
- **Modified**: `tryBasicFunction()` to register date/time functions
  - Added handlers for `current_date()`, `current_time()`, `current_timestamp()`
  - Location: Lines ~1927-1942
  - Functions take no arguments and return temporal values

- **Modified**: `heapValueToEvalValue()` converter
  - Added support for Date, Time, TimestampTZ heap values
  - Wraps temporal types in `ExtValue` for proper type preservation
  - Location: Lines ~1532-1534

#### 3. `src/eval_extended.zig`
- **Modified**: `ExtValue` union type
  - Added temporal type variants: `Date`, `Time`, `TimestampTZ`
  - Imported from `types/datetime.zig`
  - Location: Lines 84-86

#### 4. `src/execution.zig`
- **Modified**: `writeValue()` function to serialize temporal types
  - Added Date formatting as ISO 8601 (YYYY-MM-DD)
  - Added Time formatting as HH:MM:SS.ffffff
  - Added TimestampTZ formatting as ISO 8601 with UTC marker
  - Implemented Gregorian calendar conversion algorithm for dates
  - Location: Lines 352-412

### Implementation Details

#### Gregorian Calendar Conversion
The date serialization uses a standard algorithm to convert days since epoch to Gregorian calendar:
- Handles leap years correctly
- Supports full historical date range
- Produces ISO 8601 compliant date strings

#### Time Precision
- All temporal types maintain microsecond precision
- Time values stored as microseconds since midnight
- Timestamps stored as microseconds since Unix epoch (UTC)

#### Type System Integration
- Temporal values flow through the evaluation system as `ExtValue` wrapped types
- This preserves type information through nested function calls
- Ensures proper serialization in query results

### Testing
Functions are now callable in GQL queries:
```gql
RETURN current_date() AS d, current_time() AS t, current_timestamp() AS ts
```

### Standards Compliance
- ISO/IEC 39075:2024 (GQL) - Temporal function support
- ISO 8601 - Date and time format output

### CANARY Markers
No new CANARY markers added - these functions support existing temporal query requirements.

---

## Date/Time Functions Summary

| Function | Return Type | Description |
|----------|-------------|-------------|
| `current_date()` | Date | Current date (UTC) |
| `current_time()` | Time | Current time (UTC) |
| `current_timestamp()` | TimestampTZ | Current timestamp with UTC timezone |

All functions take no arguments and return current temporal values based on system clock.
