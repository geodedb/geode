# Geode GQL Conformance Patch 02

## Breaking Changes

This patch brings Geode into alignment with ISO/IEC 39075:2024 (GQL) specification. Several non-standard behaviors have been removed and spec-compliant features added.

### 1. Case-Insensitive Identifiers

**Before:** Identifiers were case-sensitive (`Foo` ≠ `foo`)
**After:** Identifiers are case-insensitive per ISO spec (`Foo` = `FOO` = `foo`)

- Unquoted identifiers are folded to uppercase canonical name form (CNF)
- Quoted identifiers preserve case
- Duplicate identifiers differing only in case now raise `SQLSTATE 42712`

### 2. Unordered Pagination Allowed

**Before:** `LIMIT`/`OFFSET` required `ORDER BY` (US001 policy)
**After:** `LIMIT`/`OFFSET` allowed without `ORDER BY` (implementation-dependent order)

```gql
-- Now valid (was previously rejected)
MATCH (n) RETURN n LIMIT 10 OFFSET 5
```

### 3. Comment Syntax Changes

**Before:** Supported `//` and `#` for single-line comments
**After:** Supports `//` (GB03) and `--` (GB02); `#` is now a syntax error

```gql
-- This is a valid comment (ISO GB02)
// This is also valid (ISO GB03)
# This is now a SYNTAX ERROR
```

### 4. SELECT Statement Support

**New:** `SELECT` statement maps to `RETURN` semantics

```gql
SELECT 1, 2           -- equivalent to RETURN 1, 2
SELECT DISTINCT 1, 1  -- with deduplication
```

### 5. RETURN/SELECT DISTINCT Deduplication

**Before:** `DISTINCT` flag parsed but not executed
**After:** Full duplicate elimination after projection

- NULLs compare equal for deduplication
- Maintains sort order when used with ORDER BY

### 6. ORDER BY Alias Resolution

**Enhanced:** ORDER BY now properly resolves projection aliases

```gql
RETURN "Ann" AS Name ORDER BY Name  -- Name resolves to alias
```

### 7. Unicode Support

**New:** Full Unicode identifier and input support

- Unicode letter categories (L*) allowed in identifiers
- Unicode decimal digits (Nd) normalized to ASCII
- UTF-8 and UTF-16 (LE/BE) input with BOM detection
- Mixed digit scripts in numbers raise `SQLSTATE 22018`

```gql
MATCH (変量) RETURN 変量  -- Unicode identifiers
RETURN ٢٣                -- Arabic-Indic "23" = 23
```

### 8. Structured Diagnostics

**Before:** Plain text error messages to stderr
**After:** JSON-structured SQLSTATE diagnostics

```json
{"sqlstate":"42601","class":"ERROR","message":"syntax error","line":3,"column":12,"token":"MATCH","diagnostics":[]}
```

Common SQLSTATE codes:
- `00000` - Success
- `0A000` - Feature not supported
- `22018` - Invalid character
- `42601` - Syntax error
- `42703` - Undefined identifier
- `42712` - Duplicate alias

### 9. Reserved Words Expansion

**Added:** Complete ISO reserved word set including:
- `FILTER`, `LET`, `SELECT`, `FROM`, `EXISTS`
- `DETACH`, `REMOVE`, `FOR`, `FOREACH`, `UNWIND`
- `USE`, `USING`, `INDEX`, `JOIN`, `KEY`, `KEYS`
- `LABELS`, `LOAD`, `CSV`, `PERIODIC`, `PROPERTIES`
- `RELATIONSHIPS`, `START_NODE`, `END_NODE`, `TYPE`, `TYPES`

Reserved words cannot be used as unquoted identifiers.

## Migration Guide

### Update Identifier References

If your queries rely on case-sensitive identifiers:

```gql
-- Old (would create two bindings)
MATCH (Foo), (foo)

-- New (creates one binding - use quotes to preserve case)
MATCH (Foo), ("foo")
```

### Remove ORDER BY for Simple Pagination

```gql
-- Old (required)
MATCH (n) RETURN n ORDER BY n.id LIMIT 10

-- New (ORDER BY optional)
MATCH (n) RETURN n LIMIT 10
```

### Update Comment Syntax

```gql
# Old comment style     --> REPLACE WITH: -- New comment style
```

### Handle Structured Errors

Update error handling to parse JSON diagnostics:

```zig
const stderr_json = ...; // Read from stderr
const parsed = try std.json.parseFromSlice(DiagnosticJson, allocator, stderr_json, .{});
if (std.mem.eql(u8, parsed.value.sqlstate, "42601")) {
    // Handle syntax error
}
```

## Testing

```bash
# Run conformance tests
zig build test --test-filter conformance

# Manual testing
zig build run -- 'SELECT DISTINCT 1, 1'
zig build run -- 'RETURN "Ann" AS Name ORDER BY Name'
zig build run -- 'MATCH (n) RETURN n LIMIT 10'  # No ORDER BY required
```

## Conformance Profile

Run `--conformance-json` to see the updated conformance profile:

```bash
zig build run -- --conformance-json query.gql
```

Key additions:
- `select_statement`: true
- `return_distinct`: true
- `unicode_identifiers`: true
- `case_insensitive_identifiers`: true
- `comment_double_dash`: true
- `unordered_pagination`: true
- `structured_diagnostics`: true