# Parser Enhancements - Phase 3 Implementation

## Overview

Phase 3 focuses on two major parser enhancements to improve GQL compliance:
- **Part A**: Nested CALL blocks (20-25 tests)
- **Part B**: Transaction body syntax (15-20 tests)

## Part A: Nested CALL Blocks

### Problem Statement

The parser currently doesn't support nested CALL blocks:
```gql
CALL {
  CALL {
    MATCH (n) RETURN n
  }
  WITH n
  RETURN n
}
```

### Investigation Steps

#### Step 1: Review Current AST Structure ✅ COMPLETED

**File**: `src/gql/ast.zig`
**Goal**: Understand current CALL statement structure and identify if nesting is supported

**Findings**:

1. **CallStatement Structure** (lines 277-280):
```zig
pub const CallStatement = union(enum) {
    Procedure: CallProcedure,
    Subquery: CallSubquery,
};
```

2. **CallSubquery Structure** (lines 271-275):
```zig
pub const CallSubquery = struct {
    query: *Query,  // ← This allows nesting!
    imported_vars: ?[][]const u8 = null,
    return_clause: ?ReturnClause = null,
};
```

3. **Statement Union** (line 30):
```zig
Call: CallStatement,
```

**Conclusion**: ✅ **AST ALREADY SUPPORTS NESTING**
- `CallSubquery.query` is a pointer to `Query`
- `Query` structures can contain any Statement, including Call statements
- This means nested CALL blocks are representable in the AST
- **The problem is in the parser, not the AST**

#### Step 2: Review Current Parser Implementation ⏸️ PENDING

**File**: `src/gql/parser.zig`
**Goal**: Locate CALL parsing logic and understand limitations

**Next Steps**:
1. Search for CALL statement parsing in parser.zig
2. Identify where `CallSubquery` is created
3. Determine why recursive statement parsing isn't happening
4. Look for the point where `{ ... }` block is parsed but statements inside aren't recursively processed

**Expected Locations to Check**:
- Function that handles `CALL` keyword
- Block parsing within CALL statements
- Statement list parsing within blocks
- Any depth limiting or recursion guards

#### Step 3: Review Execution Logic ⏸️ PENDING

**File**: `src/execution.zig`
**Goal**: Understand how CALL statements are executed

**Questions to Answer**:
1. Does execution already handle nested Call statements?
2. Is there proper scope management for nested contexts?
3. Are variables properly passed between nested levels?
4. Does the executor follow the recursive AST structure?

**Hypothesis**: Since the AST supports nesting, execution likely already works or needs minimal changes. The main work is in the parser.

---

## Implementation Plan

### Part A: Nested CALL Blocks

**Phase A.1**: AST Investigation and Modifications ✅ COMPLETED
- [x] Review CallStatement in ast.zig
- [x] Verify if AST supports nested statements
- [x] Add any missing fields for nesting support

**Result**: No AST changes needed - already supports nesting via `CallSubquery.query: *Query`

**Phase A.2**: Parser Modifications
- [ ] Locate CALL parsing in parser.zig
- [ ] Implement recursive statement parsing
- [ ] Add depth limit for safety
- [ ] Handle scope management

**Phase A.3**: Execution Support
- [ ] Verify execution handles nested CALL
- [ ] Test variable scoping
- [ ] Add context stacking if needed

**Phase A.4**: Testing and Verification
- [ ] Test basic nested CALL
- [ ] Test multiple nesting levels
- [ ] Verify variable scoping
- [ ] Run full test suite

---

## Part B: Transaction Bodies

### Problem Statement

Parser doesn't support transaction body syntax:
```gql
START TRANSACTION {
  CREATE (n:Test {id: 1});
  MATCH (n:Test) RETURN n
}
```

*Implementation details to be filled after completing Part A...*

---

## Progress Log

### [2025-10-12] - Started Phase 3 Investigation
- Created tracking document
- Beginning investigation of CALL statement structure

---

## Key Findings Summary

### ✅ What We Know

1. **AST is Ready**
   - CallSubquery already has `query: *Query` field
   - Statements can recursively contain Call statements
   - No AST modifications needed

2. **Problem is in Parser**
   - Parser needs to recursively parse statements within CALL { ... } blocks
   - Current parser likely treats the block as opaque or doesn't recurse

3. **Test Impact**
   - Estimated 20-25 tests affected by nested CALL
   - Estimated 15-20 tests affected by transaction bodies
   - Total potential: 35-45 tests fixed

### ⏸️ What Remains

1. **Parser Investigation** (1-2 hours)
   - Locate CALL parsing function
   - Understand current block handling
   - Identify recursion entry point

2. **Parser Implementation** (2-3 hours)
   - Add recursive statement parsing
   - Handle scope management
   - Add depth limit protection
   - Test basic cases

3. **Testing & Refinement** (1-2 hours)
   - Test multiple nesting levels
   - Verify variable scoping
   - Run full test suite
   - Fix edge cases

### 🎯 Recommended Approach

**Week 1: Parser Investigation**
- 2-3 hour session
- Deep dive into parser.zig
- Document CALL parsing flow
- Create detailed implementation plan

**Week 2: Implementation**
- 4-6 hour session (can split into 2-3 sessions)
- Implement recursive parsing
- Test incrementally
- Commit with evidence

**Week 3: Transaction Bodies**
- Similar approach
- Build on CALL work
- 4-6 hour session

---

## Estimated Timeline

| Phase | Time | Tests Fixed | Complexity |
|-------|------|-------------|------------|
| Investigation Complete | 1h | 0 | ✅ DONE |
| Parser Investigation | 2h | 0 | Medium |
| Nested CALL Implementation | 4h | 20-25 | High |
| Transaction Bodies | 4h | 15-20 | High |
| **Total Phase 3** | **11h** | **35-45** | **High** |

---

*Last Updated: 2025-10-12 14:30*
*Status: Phase A.1 Complete - Parser Investigation Pending*
