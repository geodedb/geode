# Geode Fixes and Known Issues

## Successfully Fixed Issues

### 1. ✅ Multiple MATCH Clauses Support
**Previous Issue:** Multiple MATCH clauses were not supported  
**Fix Applied:** Parser now supports chaining multiple MATCH clauses  
**Status:** WORKING

Example:
```gql
MATCH (a) MATCH (b) WHERE a <> b RETURN a, b
MATCH (a) MATCH (b) MATCH (c) RETURN a, b, c
```

### 2. ✅ OPTIONAL MATCH Support  
**Previous Issue:** OPTIONAL MATCH after MATCH didn't work  
**Fix Applied:** Parser now properly handles OPTIONAL MATCH in various positions  
**Status:** WORKING

Example:
```gql
OPTIONAL MATCH (n) RETURN n
MATCH (a) OPTIONAL MATCH (b:NonExistent) RETURN a, b
```

### 3. ✅ Quoted Property Names Support
**Previous Issue:** Numeric and specially formatted property names didn't work  
**Fix Applied:** Parser now accepts string_lit tokens as property keys  
**Status:** WORKING (with single quotes)

Example:
```gql
CREATE (p {'123': 'numeric_key'})
CREATE (p {'full name': 'John Doe'})
```

### 4. ✅ Long String Handling
**Previous Issue:** Reserved keywords in property names caused issues  
**Fix Applied:** Proper keyword handling, avoiding conflicts  
**Status:** WORKING

Note: 'desc' is a reserved keyword, use 'description' instead.

### 5. ✅ Property-Based Ordering (Previously Fixed)
**Status:** WORKING - Regression tests confirm still functional

### 6. ✅ Count Aggregation (Previously Fixed)  
**Status:** WORKING - Regression tests confirm still functional

## Known Issues with Workarounds

### 1. ⚠️ Double Quote String Literals
**Issue:** Double quotes cause the parser/server to hang indefinitely  
**Workaround:** Use single quotes for all string literals  
**Severity:** HIGH - Can cause process hangs

❌ **Don't use:**
```gql
RETURN "hello world"
CREATE (p {name: "Alice"})
```

✅ **Use instead:**
```gql
RETURN 'hello world'
CREATE (p {name: 'Alice'})
```

### 2. ⚠️ QUIC TLS Handshake Inconsistency
**Issue:** Inconsistent behavior with --insecure flag  
**Workaround:** Use --no-quic flag for local testing  
**Severity:** MEDIUM - Affects transport reliability

## Test Coverage

### Regression Test Suite
A comprehensive regression test suite has been created:
- **File:** `/tests/fixes_regression_test.sh`
- **Coverage:** Tests all fixed features and known issues
- **Usage:** `./tests/fixes_regression_test.sh`

The test suite verifies:
- Multiple MATCH clauses functionality
- OPTIONAL MATCH support
- Property name formats (with single quotes)
- Long string handling
- Property-based ordering
- Count aggregation
- Known issues and workarounds

## Development Notes

### Parser Modifications
1. **File:** `src/gql/parser.zig`
   - Added support for multiple MATCH/OPTIONAL MATCH clauses
   - Modified `parsePropertyMap` to accept string_lit tokens as keys
   - Chains multiple MATCH patterns into combined GraphPattern

### Lexer Status
1. **File:** `src/gql/lexer.zig`
   - Double quote handling attempted but still has issues
   - Single quotes work correctly for all string contexts
   - Property names can use single quotes for special characters

## Recommendations

1. **For Production Use:**
   - Always use single quotes for string literals
   - Test thoroughly with --no-quic flag before deploying with QUIC
   - Run regression tests before deployment

2. **For Development:**
   - Continue investigation of double quote parsing issue
   - The issue appears to be in the server's handling of the parsed tokens
   - Consider deeper debugging of the server-side query processing

3. **Future Work:**
   - Complete fix for double quote string literals
   - Resolve QUIC TLS handshake issues
   - Add more comprehensive error messages for known limitations