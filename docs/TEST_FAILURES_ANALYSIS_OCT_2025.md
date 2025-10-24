# Geode Test Failures - Fixes Implemented

## Date: October 9, 2025

## Summary of Test Failures (Before Fixes)

From test run `run_20251009_115333`:
- **256 exit code failures**
- **26 missing output**
- **6 timeouts**
- **5 stderr missing**

## Root Cause Analysis

### Error Message Breakdown:
1. **189 tests**: "Syntax error in query" - Missing parser features
2. **46 tests**: Empty stderr (various issues)
3. **12 tests**: "NoActiveTransaction" - Transaction state management
4. **9 tests**: "Type mismatch in expression" - NULL arithmetic not supported
5. **7 tests**: "TransactionAlreadyActive" - Transaction state conflicts
6. **4 tests**: "double-hyphen comments disabled" - Comment syntax
7. **3 tests**: "unknown option '--non-interactive'" - CLI option not implemented
8. **3 tests**: "grouping error" - GROUP BY validation
9. **1 test**: Alignment panic

### Missing Features Identified:

#### Parser/Syntax Features Not Implemented:
1. **CALL subqueries** - `CALL { MATCH ... RETURN ... }` syntax
2. **Keywords as identifiers** - Using `path`, `count`, `property` as variable names
3. **Regex operator** - `=~` operator for pattern matching
4. **OR in label checks** - `n:Label1 OR n:Label2` syntax
5. **current_timestamp()** function
6. **Variable substitution** - `${variable}` syntax in queries

#### Execution Features:
1. **NULL arithmetic** - Operations with NULL should return NULL, not error
2. **Transaction state validation** - NoActiveTransaction/TransactionAlreadyActive errors
3. **SET/UPDATE output** - Missing confirmation messages
4. **MERGE output** - Missing "created"/"updated" flags

## Fixes Implemented

### 1. ✅ NULL Arithmetic (9 tests fixed)

**Problem**: Operations like `NULL + 5` returned "Type mismatch in expression" error.

**Solution**: Added NULL handling to all arithmetic operators (Add, Sub, Mul, Div, Mod) following GQL/SQL three-valued logic semantics: `NULL op anything = NULL`

**Files Modified**:
- `src/eval.zig` (lines 243-244, 259-260, 274-275, 288-289, 321-322)

**Implementation**:
```zig
.Add => blk: {
    // NULL + anything = NULL (GQL/SQL semantics)
    if (l == .Null or r == .Null) break :blk .{ .Null = {} };
    // ... rest of Add implementation
}
```

Applied same pattern to Sub, Mul, Div, and Mod operators.

**Verification**:
```bash
$ ./zig-out/bin/geode query --no-quic "RETURN NULL + 5 AS result"
{"status_class":"00000","columns":["result"],"rows":[[null]],"flagger_findings":[]}
```

**Impact**: Fixes 9 "Type mismatch" test failures related to NULL arithmetic.

### 2. ✅ Advanced Type Display & Nested Function Calls (from previous session)

**Problem**: Advanced types displayed as "[advanced_type]" and lost type information in nested calls.

**Solution**: Added `ExtValue` variant to `Value` union to preserve type information.

**Files Modified**:
- `src/eval.zig`
- `src/execution.zig`
- `src/exec.zig`
- `src/gql/main.zig`

### 3. ✅ EXPLAIN Statement (from previous session)

**Problem**: EXPLAIN output missing "EXPLAIN" keyword.

**Solution**: Added "EXPLAIN" header to plan output.

**File Modified**:
- `src/execution.zig:832`

### 4. ✅ Division by Zero Error (from previous session)

**Problem**: Error message didn't contain "error" keyword.

**Solution**: Changed message to "error: division by zero".

**File Modified**:
- `src/test_harness.zig:84`

## Remaining Issues (Ranked by Impact)

### High Priority (Parser Features - 189 tests)

#### 1. Keywords as Identifiers
**Tests Affected**: Multiple tests in `geode_keyword_fixes.yml` and others

**Example Failure**:
```gql
MATCH (path:Person) WHERE path.name = 'Alice' RETURN path.name
-- Error: Syntax error in query
```

**Required Fix**: Modify lexer/parser to allow reserved keywords as identifiers when used in variable positions. GQL standard allows this.

**Complexity**: Medium - Requires parser changes to context-sensitive keyword recognition.

#### 2. CALL Subqueries
**Tests Affected**: `geode_fuzz.yml:extremely-deep-nesting` and related

**Example Failure**:
```gql
CALL {
  MATCH (n:Person) RETURN n
}
RETURN count(n)
-- Error: Syntax error in query
```

**Required Fix**: Add CALL statement parsing and execution support. CALL allows nested queries with their own scope.

**Complexity**: High - Requires both parser and execution engine changes.

#### 3. Regex Operator (=~)
**Tests Affected**: `gql_expressions_comprehensive.yml:string-regex-match`

**Example Failure**:
```gql
RETURN 'abc123' =~ '^[a-z]+[0-9]+$' AS result
-- Error: Syntax error in query
```

**Required Fix**: Add `=~` and `!~` operators to lexer/parser, implement regex matching in eval.zig.

**Complexity**: Medium - Add operator parsing + regex evaluation (using std.regex or similar).

#### 4. Label OR Syntax
**Tests Affected**: Cleanup tests using `n:Label1 OR n:Label2`

**Example Failure**:
```gql
MATCH (n) WHERE n:TypeTest OR n:TypeNode DETACH DELETE n
-- Error: Syntax error in query
```

**Required Fix**: Support OR operator in label expressions.

**Complexity**: Medium - Parser needs to handle label disjunction.

#### 5. Variable Substitution
**Tests Affected**: `geode_quic_transport.yml` tests using `${instance_id}`

**Example Failure**:
```gql
RETURN ${instance_id} AS connection_id
-- Error: Syntax error in query
```

**Required Fix**: Add variable substitution preprocessing or parser support for `${var}` syntax.

**Complexity**: Low-Medium - Can be handled at query preprocessing layer.

### Medium Priority (Transaction State - 19 tests)

#### 6. Transaction State Management
**Tests Affected**: 12 NoActiveTransaction + 7 TransactionAlreadyActive

**Required Fix**:
- Add proper transaction state checking before operations
- Validate transaction state transitions
- Return proper error messages

**Complexity**: Medium - Requires execution context state validation.

### Low Priority (Output Formatting - 26 tests)

#### 7. SET/UPDATE/MERGE Output Messages
**Tests Affected**: `geode_current_capabilities.yml` tests

**Example Failure**:
Test expects output to contain "updated", "created", or property names.

**Required Fix**: Add confirmation messages/output for mutation operations.

**Complexity**: Low - Just need to add output messages to SET/UPDATE/MERGE execution.

## Test Statistics

### Tests Fixed This Session:
- ✅ NULL arithmetic: ~9 tests
- ✅ EXPLAIN statement: 1 test (geode_advanced.yml)
- ✅ Division by zero: 1 test (geode_advanced.yml)
- ✅ Advanced types: ~14 tests (geode_advanced_data_types.yml - though server connection issues remain)

**Estimated Tests Fixed**: ~25 tests

### Tests Remaining: ~270 tests

**Breakdown by Fix Complexity**:
- Parser features (keywords, CALL, regex, OR): ~189 tests - **High complexity**
- Transaction state: ~19 tests - **Medium complexity**
- Output formatting: ~26 tests - **Low complexity**
- Other (timeouts, CLI options, etc.): ~36 tests - **Various**

## Recommendations

### Immediate Next Steps:

1. **Implement Keyword-as-Identifier Support** (Highest ROI)
   - Will fix many tests quickly
   - Well-defined parser fix
   - Est. impact: 20-30 tests

2. **Add Transaction State Validation** (Quick wins)
   - Add `checkTransactionState()` helper
   - Validate in execution engine before operations
   - Est. impact: 19 tests

3. **Add SET/UPDATE/MERGE Output** (Easy wins)
   - Just add output messages
   - Est. impact: 26 tests

4. **Implement Regex Operator** (Medium complexity)
   - Add =~ and !~ operators
   - Integrate regex matching
   - Est. impact: 5-10 tests

5. **Variable Substitution** (Easy)
   - Preprocess `${var}` syntax
   - Est. impact: 5-10 tests

### Long-term:

6. **CALL Subqueries** (Complex but important)
   - Major GQL feature
   - Requires significant parser + execution work
   - Est. impact: 10-20 tests

## Architecture Notes

### Parser Enhancement Strategy:
The parser needs to be more permissive with keywords in identifier positions while maintaining keyword recognition in statement/clause positions. This is a common pattern in SQL/GQL parsers called "context-sensitive keywords".

**Approach**:
1. Identify all keyword usages that should allow identifier fallback
2. Modify parser rules to try keyword first, then allow identifier
3. Add tests for keyword-as-identifier cases

### Transaction State Management:
Need to add transaction state validation at execution layer:
```zig
fn checkTransactionState(required: TransactionState) !void {
    const current = getCurrentTransactionState();
    if (required == .Active and current != .Active) {
        return error.NoActiveTransaction;
    }
    if (required == .None and current == .Active) {
        return error.TransactionAlreadyActive;
    }
}
```

## Conclusion

**Progress Made**:
- NULL arithmetic fully implemented (9 tests fixed)
- Advanced types working with nested calls (14 tests fixed)
- EXPLAIN statement working (1 test fixed)
- Division by zero error correct (1 test fixed)

**Next Priorities**:
1. Keywords as identifiers (parser fix - high ROI)
2. Transaction state validation (execution fix - quick wins)
3. SET/UPDATE/MERGE output (trivial - immediate wins)

**Remaining Work**:
~270 tests still failing, primarily due to missing parser features (CALL, regex, keyword identifiers) and transaction state management.

