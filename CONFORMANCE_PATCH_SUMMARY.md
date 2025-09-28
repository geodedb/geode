# GQL Conformance Patch 02 - Implementation Summary

## Files Changed

### Core Language Files
1. **src/gql/token.zig**
   - Added missing ISO reserved words (FILTER, LET, SELECT, FROM, EXISTS, etc.)
   - Integrated Unicode identifier support
   - Added centralized keywordKind() function

2. **src/gql/lexer.zig**
   - Added `--` comment support (GB02)
   - Removed non-standard `#` comment support
   - Added Unicode identifier scanning
   - Added Unicode digit normalization
   - UTF-16 input support (with BOM detection)

3. **src/gql/ast.zig**
   - Added IdentRepr struct with orig/cnf fields for case-insensitive matching
   - Updated Expr.Ident to use IdentRepr

4. **src/gql/parser.zig**
   - Added SELECT statement parsing (maps to RETURN)
   - Implemented identifier CNF conversion
   - Enhanced alias resolution for ORDER BY
   - Removed US001 policy enforcement

5. **src/gql/print.zig**
   - Updated to handle IdentRepr structure

6. **src/gql/main.zig**
   - Integrated structured JSON diagnostics
   - Updated identifier references for CNF

### New Files
1. **src/unicode/unicode_tables.zig**
   - Unicode 15.1 character category support
   - Case folding to uppercase
   - UTF-16 to UTF-8 conversion
   - BOM detection

2. **src/gql/status.zig**
   - GQL Status structure
   - SQLSTATE code definitions
   - JSON diagnostic output with stable key order

3. **src/exec.zig**
   - Added dedupRowsIfDistinct() function
   - DISTINCT deduplication with NULL equality

4. **src/conformance.zig**
   - Updated Features struct with new conformance flags
   - Changed US001PaginationPolicy to UnorderedPaginationAllowed

### Test Files
1. **tests/conformance_tests.zig**
   - Complete test suite for all conformance changes
   - Tests for reserved words, CNF, Unicode, comments, SELECT, DISTINCT, etc.

### Documentation
1. **README_CONFORMANCE_PATCH_02.md**
   - Complete breaking changes documentation
   - Migration guide
   - Testing instructions

## Design Rationale

1. **Enforces ISO semantics** even if it breaks prior behavior
2. **Centralizes identifier handling** (Unicode + CNF) for correctness
3. **Aligns results correctness** (DISTINCT) and ORDER BY alias semantics
4. **Formalizes diagnostics** for client integration
5. **Removes non-standard policy** & comment syntax
6. **Minimal dependencies**: vendored Unicode tables; deterministic JSON
7. **Prepared for future spec features** by reserving full keyword set

## Testing Instructions

```bash
# Build the project
zig build -Drelease-safe

# Run conformance tests
zig build test --test-filter conformance

# Manual testing examples
zig build run -- 'SELECT DISTINCT 1, 1'
zig build run -- 'RETURN "Ann" AS Name ORDER BY Name'
zig build run -- 'MATCH (n) RETURN n LIMIT 10'  # No ORDER BY required
zig build run -- '-- This is a comment\nRETURN 1'
```

## Breaking Changes Summary

1. **Identifiers are now case-insensitive**
2. **LIMIT/OFFSET no longer requires ORDER BY**
3. **`#` comments are now syntax errors**
4. **Error output is now JSON-structured**
5. **Reserved words expanded significantly**
6. **DISTINCT now performs actual deduplication**
7. **Unicode identifiers and digits supported**
8. **SELECT statement added (maps to RETURN)**

## Migration Impact

- **High**: Applications parsing error messages must handle JSON
- **Medium**: Queries using case-sensitive identifiers need quotes
- **Low**: Most valid GQL queries continue to work
- **Positive**: Removal of US001 makes more queries valid