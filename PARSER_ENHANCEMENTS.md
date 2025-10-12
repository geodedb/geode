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

**Conclusion**: ❌ **AST DOES NOT SUPPORT NESTING** (Initial assessment was incorrect)
- `CallSubquery.query` is a pointer to `Query` (a struct with match/where/return clauses)
- `Query` is a struct type, NOT a Statement type
- `Query` CANNOT contain CALL statements (they're separate variants in the Statement union)
- **The problem is in BOTH the AST design AND the parser**

**Statement union structure**:
```zig
pub const Statement = union(enum) {
    Query: Query,        // ← Query is one type of Statement
    Call: CallStatement, // ← Call is a separate type of Statement
    Create: CreateStatement,
    // ... other statement types
};
```

Query and Call are siblings, not parent-child. Therefore `CallSubquery.query: *Query` cannot represent nested CALL.

#### Step 2: Review Current Parser Implementation ✅ COMPLETED

**File**: `src/gql/parser.zig`
**Goal**: Locate CALL parsing logic and understand limitations

**Findings**:

1. **CALL Parsing Location**: Lines 685-759 in `parseStatement()` function
   - parseStatement() is at line 283, handles all top-level statement types
   - CALL parsing starts at line 685 with `.CALL => blk_call:`

2. **The Problem** (Line 689-695):
   ```zig
   if (self.cur.kind == .l_brace) {
       // CALL { subquery } syntax
       self.advance();

       // Parse the subquery
       const subquery = try self.arena.allocator().create(ast.Query);
       subquery.* = try self.parseQuery();  // ← PROBLEM HERE
   ```

3. **Root Cause**:
   - Line 695 calls `parseQuery()` to parse the content within `CALL { ... }`
   - `parseQuery()` is defined at line 870 and expects MATCH/CREATE/WITH/SELECT keywords
   - `parseQuery()` CANNOT handle CALL statements (not in its switch statement)
   - When encountering nested `CALL`, parseQuery() fails with "Syntax error"

4. **Why This Happens**:
   - The AST defines `CallSubquery.query: *Query` (not Statement)
   - The parser respects this and calls parseQuery()
   - But Query doesn't support CALL statements - it's designed for MATCH-based queries

**Conclusion**: The AST constraint (`query: *Query`) prevents nested CALL blocks. Need to either:
- **Option A**: Change AST to use statement list instead of Query
- **Option B**: Make Query capable of representing CALL (architectural mismatch)

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

## Recommended Solution

### Option 1: Change CallSubquery to Use Statement (RECOMMENDED)

**Rationale**: CALL { ... } should be able to contain any statements, not just queries

**AST Changes** (`src/gql/ast.zig`):
```zig
// BEFORE:
pub const CallSubquery = struct {
    query: *Query,  // Can only contain MATCH-based queries
    imported_vars: ?[][]const u8 = null,
    return_clause: ?ReturnClause = null,
};

// AFTER:
pub const CallSubquery = struct {
    statement: *Statement,  // Can contain any statement including CALL
    imported_vars: ?[][]const u8 = null,
    return_clause: ?ReturnClause = null,
};
```

**Parser Changes** (`src/gql/parser.zig` line 694-695):
```zig
// BEFORE:
const subquery = try self.arena.allocator().create(ast.Query);
subquery.* = try self.parseQuery();

// AFTER:
const stmt = try self.arena.allocator().create(ast.Statement);
stmt.* = try self.parseStatement();
```

**Execution Changes** (`src/execution.zig`):
- Update CallSubquery execution to handle Statement instead of Query
- Statement can be Query, Call, Create, etc.
- Use pattern matching on Statement.tag to dispatch execution

**Pros**:
- Clean architectural design
- Supports arbitrary nesting naturally
- Aligns with GQL spec expectations

**Cons**:
- Requires changes across AST, parser, and executor
- More complex than parser-only fix

### Option 2: Make Query Capable of Containing CALL (NOT RECOMMENDED)

**Approach**: Add a CALL field to the Query struct

**Problems**:
- Architectural mismatch - Query is for MATCH-based queries
- Bloats Query struct with fields not relevant to queries
- Doesn't align with Statement union design

## Implementation Plan

### Part A: Nested CALL Blocks

**Phase A.1**: AST Investigation and Modifications ✅ COMPLETED
- [x] Review CallStatement in ast.zig
- [x] Verify if AST supports nested statements
- [x] Identify required AST changes

**Result**: AST needs modification - `CallSubquery.query: *Query` should be `statement: *Statement`

**Phase A.2**: Parser Investigation ✅ COMPLETED
- [x] Locate CALL parsing in parser.zig (lines 685-759)
- [x] Identify why recursive parsing fails (calls parseQuery() instead of parseStatement())
- [x] Document the fix needed (change to parseStatement())

**Phase A.3**: Implementation (READY TO START)
- [ ] Modify AST: Change `CallSubquery.query: *Query` to `statement: *Statement`
- [ ] Update parser: Change line 695 from `parseQuery()` to `parseStatement()`
- [ ] Update parser: Change line 694 allocation type from `ast.Query` to `ast.Statement`
- [ ] Update parser: Change line 718 from `.query = subquery` to `.statement = stmt`
- [ ] Find and update execution code that accesses `.query` field
- [ ] Update execution: Handle Statement union (Query/Call/Create/etc.)
- [ ] Add depth limit for safety (prevent infinite recursion)
- [ ] Test basic nested CALL: `CALL { CALL { MATCH (n) RETURN n } RETURN 1 }`

**Phase A.4**: Testing and Verification
- [ ] Test multiple nesting levels
- [ ] Verify variable scoping
- [ ] Run full test suite and measure improvement

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

### [2025-10-12 17:00] - Phase A.2 Completed: Parser Investigation Complete
- Located CALL parsing in parseStatement() at lines 685-759
- Identified root cause: Line 695 calls parseQuery() which cannot handle CALL
- Corrected initial assessment: AST does NOT support nesting (Query != Statement)
- Documented recommended solution: Change CallSubquery to use Statement instead of Query
- Ready to proceed with implementation in Phase A.3

### [2025-10-12 14:30] - Phase A.1 Completed: AST Investigation
- Reviewed CallSubquery and CallStatement structures in ast.zig
- Initially thought AST supported nesting via query pointer (incorrect)
- Created detailed tracking document for Phase 3

### [2025-10-12] - Started Phase 3 Investigation
- Created tracking document
- Beginning investigation of CALL statement structure

---

## Key Findings Summary

### ✅ What We Know

1. **Root Cause Identified**
   - CallSubquery has `query: *Query` field but Query cannot represent CALL
   - Parser calls parseQuery() at line 695 which fails on CALL keywords
   - Statement union has Query and Call as separate siblings, not parent-child
   - **Solution**: Change CallSubquery to use `statement: *Statement` instead

2. **Technical Details**
   - Parser location: src/gql/parser.zig lines 685-759 (in parseStatement())
   - Problem line: 695 `subquery.* = try self.parseQuery();`
   - AST location: src/gql/ast.zig lines 271-275 (CallSubquery struct)
   - Execution will need updates to handle Statement union instead of Query

3. **Test Impact**
   - Estimated 20-25 tests affected by nested CALL
   - Estimated 15-20 tests affected by transaction bodies
   - Total potential: 35-45 tests fixed

### ⏸️ What Remains (Ready to Implement)

**Phase A.3**: Implementation (4-6 hours)
1. Modify AST (15 min)
2. Update parser (30 min)
3. Search and update execution code (1-2 hours)
4. Add depth limit (30 min)
5. Test and debug (2-3 hours)

**Phase A.4**: Testing (1 hour)
- Multiple nesting levels
- Variable scoping
- Full test suite

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

*Last Updated: 2025-10-12 17:00*
*Status: Phase A.1 & A.2 Complete - Implementation Ready (Phase A.3)*

**Next Session**: Begin implementation of AST, parser, and execution changes to support nested CALL blocks
