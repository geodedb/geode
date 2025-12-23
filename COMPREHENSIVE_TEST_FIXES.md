# Comprehensive Test Fixes - December 2025

This document tracks issues identified during comprehensive GQL testing and their fixes.

## Test Summary

- **Test File**: `testing/shell/comprehensive_test.gql`
- **Statements Executed**: 438
- **Date**: December 23, 2025

## Issues Identified

### Issue 1: UNION Queries Lose Graph Context (HIGH Priority)

**Status**: :white_check_mark: FIXED

**Symptom**: When executing UNION queries within a specific graph context (e.g., `USE GRAPH test_comprehensive`), the MATCH clauses fall back to the `'default'` graph instead of respecting the current graph context.

**Server Log Evidence**:
```
debug(cli): Query text: MATCH (p:Person) WHERE p.age < 30 RETURN p.name AS name UNION MATCH (p:Person) WHERE p.name STARTS WITH 'A' RETURN p.name AS name;
[MATCH] executeMatchQueryImpl filter_graph='default'
[MATCH] executeMatchQueryImpl filter_graph='default'
```

**Expected**: Both MATCH clauses should use `filter_graph='test_comprehensive'`

**Test Query**:
```gql
USE GRAPH test_comprehensive;
MATCH (p:Person) WHERE p.age < 30 RETURN p.name AS name
UNION
MATCH (p:Person) WHERE p.name STARTS WITH 'A' RETURN p.name AS name;
```

**Root Cause**: The UNION execution path doesn't propagate the `current_graph` from `QueryOptions` to sub-queries.

**Fix**: Added `executeQueryNoLimitWithContext()` function to `execution.zig` and updated `set_operations.zig` to use it for UNION sub-queries, ensuring graph context is properly propagated.

---

### Issue 2: Transaction ROLLBACK Not Working (HIGH Priority)

**Status**: :yellow_circle: KNOWN LIMITATION

**Symptom**: After executing `ROLLBACK`, data created within the transaction still persists.

**Test Sequence**:
```gql
START TRANSACTION;
CREATE (t:TransactionRollback {id: 999, status: 'will_rollback'});
MATCH (t:TransactionRollback) RETURN count(t) AS count_before_rollback;  -- Returns 1
ROLLBACK;
MATCH (t:TransactionRollback {id: 999}) RETURN count(t) AS should_be_zero;  -- Returns 1 (WRONG!)
```

**Expected**: After ROLLBACK, `should_be_zero` should be `0`

**Root Cause**: Transaction rollback only updates session state without reverting data modifications. The CLI execution path immediately persists all CREATE/DELETE operations without maintaining a transaction undo log.

**Required Fix**: Implementing proper ROLLBACK requires significant architectural changes:
1. Adding a transaction log to track all modifications (created nodes/edges, deleted items, property changes)
2. Modifying all CRUD operations (CREATE, DELETE, MERGE, SET) to log their changes when in a transaction
3. On ROLLBACK, reversing all logged changes

Note: The server-side transaction handlers (`transaction_handlers.zig`) have MVCC support that marks uncommitted inserts as aborted. The CLI shell execution path does not use this infrastructure.

---

### Issue 3: sum() Aggregation Returns 0 (MEDIUM Priority)

**Status**: :white_check_mark: FIXED

**Symptom**: `sum()` aggregation returns 0 for float/decimal properties in GROUP BY queries.

**Test Query**:
```gql
MATCH (c:Customer)-[:PLACED]->(o:Order)
RETURN c.name, c.tier, count(o) AS order_count, sum(o.total) AS total_spent
GROUP BY c.name, c.tier
ORDER BY total_spent DESC;
```

**Result**:
```
| name    | tier   | order_count  | total_spent  |
|---------|--------|--------------|--------------|
| Alice   | Gold   | 1            | 0            |
| Eve     | Silver | 1            | 0            |
```

**Expected**: `total_spent` should be the actual sum of `o.total` values (e.g., 1349.98, 1949.97)

**Root Cause**: The `sum()` function only handled `.Int` and `.Float` property values, but not `.ExtValue` which contains `.Decimal` values (used for money amounts).

**Fix**: Updated `aggregation_evaluation.zig` to handle `.ExtValue` containing `.Decimal` values in both sum and avg aggregations.

---

### Issue 4: vectori32 Returns Null (MEDIUM Priority)

**Status**: :white_check_mark: FIXED

**Symptom**: The `vectori32()` function returns null instead of an integer vector.

**Test Query**:
```gql
RETURN vectori32('[1, 2, 3, 4, 5]') AS vec_i32;
```

**Result**:
```
| vec_i32 |
|---------|
| null    |
```

**Expected**: Should return an integer vector similar to `vectorf32`

**Note**: `vectorf32()` works correctly:
```gql
RETURN vectorf32('[1.0, 2.0, 3.0, 4.0, 5.0]') AS vec_f32;  -- Returns [vector]
```

**Root Cause**: `vectori32` was not implemented - the function was not registered in the function registry and the `VectorI32` type was missing from `heap.zig` and `ExtValue`.

**Fix**:
- Added `VectorI32` struct to `heap.zig` with encoding/decoding support (tag 0x12)
- Added `VectorI32` variant to `ExtValue` union in `eval_extended.zig`
- Implemented `constructVectorI32` function
- Registered `vectori32` in the function registry
- Added `VectorI32` handling to `graph_store.zig` serialization

---

### Issue 5: Reverse Variable-Length Path Traversal Returns Empty (MEDIUM Priority)

**Status**: :white_check_mark: FIXED

**Symptom**: Reverse direction variable-length paths (`<-[:REL*]-`) return no results.

**Test Query**:
```gql
-- Forward direction works:
MATCH (ancestor:FamilyMember {name: 'Great-Grandparent'})-[:PARENT_OF*]->(descendant:FamilyMember)
RETURN count(DISTINCT descendant) AS total_descendants;  -- Returns 9

-- Reverse direction fails:
MATCH (child:FamilyMember {name: 'Grandchild-1'})<-[:PARENT_OF*]-(ancestor:FamilyMember)
RETURN ancestor.name AS ancestor_name;  -- Returns 0 rows
```

**Expected**: Should return ancestors: Child-1, Parent-1, Grandparent-1, Great-Grandparent

**Root Cause**: The `expandVariableLengthPaths()` function only used `getEdgesFrom()` (outgoing edges) and `edge.to_id`, which only works for forward traversal.

**Fix**:
- Added `rel_direction` parameter to `expandVariableLengthPaths()` function
- Added logic to process incoming edges using `getEdgesTo()` and `edge.from_id` for reverse traversal
- Updated callers in `match_operations.zig` to extract direction from `hop.rel.dir` and pass it to the function

---

### Issue 6: List Comprehension Syntax Not Supported (LOW Priority)

**Status**: :red_circle: Open

**Symptom**: List comprehension syntax causes parse error.

**Test Query**:
```gql
MATCH path = (n:SocialUser)-[:FRIEND*3..6]->(n)
WHERE n.name = 'Alice'
RETURN length(path) AS cycle_length, [node IN nodes(path) | node.name] AS cycle_path
LIMIT 3;
```

**Error**: `Syntax error in query`

**Expected**: Should parse and execute the list comprehension `[node IN nodes(path) | node.name]`

**Root Cause**: List comprehension syntax is not implemented in the GQL parser.

---

### Issue 7: OPTIONAL MATCH count() Returns Null (LOW Priority)

**Status**: :yellow_circle: KNOWN LIMITATION

**Symptom**: `count()` on OPTIONAL MATCH relationships returns null instead of 0.

**Test Query**:
```gql
MATCH (n:SocialUser)
OPTIONAL MATCH (n)-[r:FRIEND]-()
WITH n, count(r) AS connections
RETURN n.name AS user, connections
ORDER BY connections DESC;
```

**Result**:
```
| user  | connections |
|-------|-------------|
| Alice | null        |
| Bob   | null        |
```

**Expected**: `connections` should be numeric (0 for users without friends, >0 for those with friends)

**Root Cause**: Complex interaction between OPTIONAL MATCH variable binding and aggregation in WITH clauses. When OPTIONAL MATCH doesn't find a match, the relationship variable binding and subsequent count() aggregation don't properly handle the null case.

**Required Fix**: Requires investigation into:
1. How OPTIONAL MATCH binds variables when no match is found
2. How WITH clause processes aggregations with null bindings
3. Proper SQL-like behavior where COUNT() of null should return 0

---

## Fix Progress

| Issue | Priority | Status | Fix Details |
|-------|----------|--------|------------|
| UNION graph context | HIGH | :white_check_mark: Fixed | Added context-aware UNION execution |
| Transaction ROLLBACK | HIGH | :yellow_circle: Known Limitation | Requires undo log architecture |
| sum() aggregation | MEDIUM | :white_check_mark: Fixed | Added Decimal handling in ExtValue |
| vectori32 null | MEDIUM | :white_check_mark: Fixed | Implemented VectorI32 type and function |
| Reverse path traversal | MEDIUM | :white_check_mark: Fixed | Added direction parameter to path expansion |
| List comprehension | LOW | :red_circle: Open | Parser enhancement needed |
| OPTIONAL MATCH count | LOW | :yellow_circle: Known Limitation | Complex aggregation binding issue |

## Working Features Confirmed

- Basic literals (integers, floats, strings, booleans, null)
- Lists and maps (including nested)
- Arithmetic operations (+, -, *, /, %)
- Comparison operators (=, <>, <, >, <=, >=, IS NULL, IS NOT NULL)
- Logical operators (AND, OR, NOT, XOR)
- String functions (upper, lower, length, substring, trim, replace, reverse)
- Math functions (abs, sign, ceil, floor, round, sqrt, pow, exp, log, trig functions)
- List functions (size, head, tail, reverse, IN, all, any, range)
- Date/time functions (datetime, date, time, timestamp, duration)
- Type functions (type, toInteger, toFloat, toString, coalesce)
- CASE expressions
- Graph management (CREATE GRAPH, USE GRAPH, DROP GRAPH, SHOW GRAPHS)
- Node/relationship creation
- Basic MATCH queries
- Forward variable-length paths (working)
- **Reverse variable-length paths** (FIXED - now working!)
- OPTIONAL MATCH (basic)
- Filtering (WHERE, STARTS WITH, ENDS WITH, CONTAINS, IN)
- Sorting (ORDER BY ASC/DESC)
- Pagination (LIMIT, SKIP)
- Basic aggregations (count, min, max, avg)
- **sum() with Decimal values** (FIXED - now working!)
- GROUP BY
- DISTINCT
- SET/REMOVE properties and labels
- MERGE
- DELETE/DETACH DELETE
- WITH clause
- Vector operations (vectorf32, **vectori32** (FIXED!), vector_l2, vector_cosine, vector_dot)
- **UNION with graph context** (FIXED - now properly propagates graph context!)
- **Multi-graph isolation** (verified working correctly!)
- Index creation/deletion
- Constraint creation/deletion
- shortestPath and allShortestPaths
- Error handling (division by zero returns error, type mismatch returns error)

## Files Modified

The following files were modified to fix the issues:

### UNION Graph Context Fix
- `src/execution.zig` - Added `executeQueryNoLimitWithContext()` function
- `src/execution/set_operations.zig` - Updated UNION execution to use context-aware function

### vectori32 Fix
- `src/storage/heap.zig` - Added `VectorI32` struct, encoding (tag 0x12), and decoding
- `src/eval_extended.zig` - Added `VectorI32` to ExtValue union, implemented `constructVectorI32`, registered function
- `src/eval.zig` - Added `VectorI32` to type name mapping
- `src/graph_store.zig` - Added `VectorI32` serialization support

### sum() Aggregation Fix
- `src/execution/aggregation_evaluation.zig` - Added Decimal handling in ExtValue for sum() and avg()

### Reverse Path Traversal Fix
- `src/execution.zig` - Added `rel_direction` parameter to `expandVariableLengthPaths()`, added incoming edge handling
- `src/execution/match_operations.zig` - Added direction extraction from `hop.rel.dir`, passed to path expansion function
