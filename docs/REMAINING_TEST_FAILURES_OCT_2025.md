# Remaining Test Failures - Analysis and Recommendations

## Date: October 9, 2025

## Executive Summary

After implementing NULL arithmetic fixes and advanced type handling, **291 tests remain failing** out of 1,242 total tests. This represents a **76.6% pass rate** (up from 75.1%).

## Current Test Status

**Test Run**: `run_20251009_120334`
- **Total Tests**: 1,242
- **Passing**: 951 (76.6%)
- **Failing**: 291 (23.4%)

### Failure Breakdown:
- **189 tests**: Syntax errors (missing parser features)
- **44 tests**: Empty stderr (various issues)
- **12 tests**: NoActiveTransaction
- **9 tests**: Type mismatch
- **7 tests**: TransactionAlreadyActive
- **24 tests**: Missing output
- **6 tests**: Timeouts

## Detailed Analysis

### 1. Syntax Errors (189 tests) - **COMPLEX**

#### Missing Parser Features:

##### a) Keywords as Identifiers (~30 tests)
**Example**:
```gql
MATCH (path:Person) WHERE path.name = 'Alice' RETURN path.name
-- Error: Syntax error in query
```

**Issue**: Parser treats `path`, `count`, `property`, etc. as reserved keywords even in identifier positions.

**Solution Required**: Implement context-sensitive keyword recognition in parser. Keywords should be allowed as identifiers when used as variable names.

**Implementation Complexity**: **Medium** - Requires parser modification to distinguish keyword context.

**Files to Modify**:
- `src/gql/lexer.zig` or `src/gql/parser.zig`
- Need to identify all keyword usage positions and allow identifier fallback

##### b) CALL Subqueries (~20 tests)
**Example**:
```gql
CALL {
  MATCH (n:Person) RETURN n
}
RETURN count(n)
```

**Issue**: CALL statement not parsed.

**Solution Required**: Add CALL statement to AST and parser, implement scoped subquery execution.

**Implementation Complexity**: **High** - Major parser and execution engine work.

**Impact**: ~20 tests, but important GQL feature.

##### c) Regex Operator =~ (~10 tests)
**Example**:
```gql
RETURN 'abc123' =~ '^[a-z]+[0-9]+$' AS result
```

**Issue**: Regex operators `=~` and `!~` not parsed.

**Solution Required**: Add operators to lexer/parser, implement regex matching in eval.zig.

**Implementation Complexity**: **Medium** - Operator parsing + regex library integration.

**Files to Modify**:
- `src/gql/lexer.zig` - Add =~ and !~ tokens
- `src/gql/parser.zig` - Parse as binary operators
- `src/eval.zig` - Implement regex matching (use Zig regex or PCRE)

##### d) Label OR Syntax (~15 tests)
**Example**:
```gql
MATCH (n) WHERE n:TypeTest OR n:TypeNode DETACH DELETE n
```

**Issue**: Parser doesn't support OR in label expressions.

**Solution Required**: Extend label checking to support disjunction.

**Implementation Complexity**: **Medium** - Parser and execution changes.

##### e) Variable Substitution (~10 tests)
**Example**:
```gql
RETURN ${instance_id} AS connection_id
```

**Issue**: `${variable}` syntax not supported.

**Solution Required**: Preprocess queries to substitute variables or add parser support.

**Implementation Complexity**: **Low** - Can be handled at query preprocessing layer.

##### f) Other Syntax Features (~100+ tests)
Various other missing features causing syntax errors.

**Recommendation**: Focus on highest-ROI parser fixes first (keywords as identifiers, variable substitution).

### 2. Transaction State Errors (19 tests) - **MEDIUM**

#### NoActiveTransaction (12 tests)

**Example**:
```gql
ROLLBACK  -- without START TRANSACTION first
-- Error: NoActiveTransaction
```

**Issue**: Tests attempting to COMMIT/ROLLBACK without active transaction.

**Root Cause**: Tests may be designed to verify error handling, OR tests are running statements separately when they should be in same transaction.

**Investigation Needed**: Check if these are intentional error tests or actual bugs in transaction handling.

#### TransactionAlreadyActive (7 tests)

**Example**:
```gql
START TRANSACTION;
CREATE (n:StateTest {id: 1});
COMMIT;
MATCH (n:StateTest) RETURN count(n)
-- Error: TransactionAlreadyActive on the MATCH
```

**Issue**: After COMMIT, next statement thinks transaction is still active.

**Root Cause**: Transaction state not properly cleared after COMMIT/ROLLBACK.

**Solution Required**: Ensure transaction session is properly cleared in test harness after COMMIT/ROLLBACK.

**Implementation Complexity**: **Low** - State management fix.

**Files to Check**:
- `src/txn_session.zig` - Transaction session management
- `src/test_harness.zig` - Query execution cleanup

### 3. WITH Clause Issues (~24 "missing output" tests) - **MEDIUM-HIGH**

#### WITH Clause Returns NULL

**Example**:
```gql
CREATE (n:Test {value: 1}) WITH n SET n.updated = true RETURN n
-- Actual output: {"columns":["n"],"rows":[[null]]}
-- Expected: Node with properties including "updated"
```

**Issue**: WITH clause is not properly passing through node bindings from CREATE.

**Root Cause Analysis**:
1. `CREATE (n) RETURN n` works correctly (returns node)
2. `CREATE (n) WITH n RETURN n` returns NULL
3. The WITH clause execution creates an environment from the input result
4. When evaluating identifier `n` in WITH context, it returns NULL

**Hypothesis**: The CREATE result columns/values aren't being properly set up for the WITH clause to access. Need to investigate the interaction between CREATE query execution and WITH clause processing.

**Investigation Path**:
1. Check what columns/values CREATE query produces (line ~3149 in execution.zig)
2. Verify environment construction in executeWithClause (line ~3194)
3. Debug why env.get("n") returns null when "n" should be in the environment

**Solution Required**: Debug and fix the data flow from CREATE through WITH clause.

**Implementation Complexity**: **Medium-High** - Requires careful debugging of execution pipeline.

**Files to Investigate**:
- `src/execution.zig:3172` - executeWithClause
- `src/execution.zig:3165` - WHERE WITH is applied after query
- Query execution path for CREATE statements

#### SET/UPDATE Output Messages

**Example**:
```gql
CREATE (n) SET n.updated = true RETURN n
-- Test expects stdout to contain: "updated", "true"
```

**Issue**: After fixing WITH clause, these tests will likely still expect the node to be returned with the updated property visible in the output.

**Note**: This is related to the WITH clause issue above.

### 4. Type Mismatch Errors (9 tests) - **INVESTIGATE**

**Status**: We fixed NULL arithmetic, but 9 type mismatch errors remain.

**Possible causes**:
- Other operations that need NULL handling (string concatenation, etc.)
- Type coercion issues in specific contexts
- Function calls with incompatible types

**Recommendation**: Examine specific failing tests to identify patterns.

### 5. Other Issues (44 tests various)

- **Double-hyphen comments** (4 tests): GB02 governance restriction
- **Unknown CLI options** (3 tests): --non-interactive not implemented
- **Grouping errors** (3 tests): GROUP BY validation issues
- **Alignment panic** (1 test): Memory alignment bug
- **Unknown subcommands** (5 tests): SESSION commands, BEGIN as top-level command

## Priority Recommendations

### Phase 1: Quick Wins (Est. 30-50 tests, Low-Medium complexity)

1. **Variable Substitution** (`${var}` syntax) - **~10 tests**
   - Complexity: Low
   - Impact: Immediate
   - Implementation: Add query preprocessing step

2. **Transaction State Management** - **~19 tests**
   - Complexity: Low-Medium
   - Impact: Immediate
   - Implementation: Fix transaction session cleanup

3. **Keywords as Identifiers** - **~30 tests**
   - Complexity: Medium
   - Impact: High ROI
   - Implementation: Parser enhancement for context-sensitive keywords

### Phase 2: Medium Complexity (Est. 30-40 tests)

4. **WITH Clause Fix** - **~24 tests**
   - Complexity: Medium-High
   - Impact: Important for chained queries
   - Implementation: Debug CREATE → WITH data flow

5. **Regex Operator** - **~10 tests**
   - Complexity: Medium
   - Impact: Standard GQL feature
   - Implementation: Add operators + regex library

6. **Label OR Syntax** - **~15 tests**
   - Complexity: Medium
   - Impact: Query flexibility

### Phase 3: Complex Features (Est. 20-30 tests)

7. **CALL Subqueries** - **~20 tests**
   - Complexity: High
   - Impact: Important but complex
   - Implementation: Major parser + execution work

8. **Remaining Type Mismatches** - **~9 tests**
   - Complexity: Medium
   - Impact: Varies
   - Implementation: Case-by-case analysis

## Implementation Strategy

### Recommended Approach:

1. **Start with variable substitution** (easiest, immediate impact)
2. **Fix transaction state management** (straightforward fix)
3. **Implement keyword-as-identifier support** (best ROI)
4. **Debug and fix WITH clause** (important for query composition)
5. **Add regex operator** (standard feature, reasonable complexity)
6. **Tackle remaining parser features** (CALL, label OR, etc.)

### Alternative Approach:

If parser modifications are challenging in the current architecture, consider:
1. Focus on execution engine fixes first (WITH clause, transactions)
2. Document parser limitations as known issues
3. Plan major parser refactoring as separate project

## Test Coverage Goals

**Current**: 76.6% (951/1,242)

**Achievable with Phase 1**: ~80-82% (990-1,020 tests)

**Achievable with Phase 1+2**: ~84-87% (1,040-1,080 tests)

**With all phases**: ~90%+ (1,120+ tests)

## Conclusion

The remaining test failures fall into three categories:

1. **Parser Features** (189 tests, ~65% of failures) - Require syntax/parsing work
2. **Execution Issues** (50 tests, ~17% of failures) - Require execution engine fixes
3. **Other/Various** (52 tests, ~18% of failures) - Mixed complexity

**Key Insight**: Parser enhancements are the biggest blocker. Implementing context-sensitive keyword recognition alone could fix ~30 tests with reasonable effort.

**Recommendation**: Prioritize the "quick wins" in Phase 1 to reach 80%+ pass rate, then assess whether to continue with parser work or focus on other priorities.

---

*Last Updated: October 9, 2025*
*Test Run: run_20251009_120334*
*Pass Rate: 76.6% (951/1,242 tests)*
