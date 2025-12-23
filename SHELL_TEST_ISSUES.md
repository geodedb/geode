# Shell Test Issues - December 2025

Issues discovered during comprehensive shell testing (`./testing/shell/comprehensive_test.gql`).

## Current Test Run: 2025-12-23

**Statements Executed**: 438
**Explicit Errors**: 3 (2 expected, 1 syntax limitation)

## Issue Summary

| # | Issue | Priority | Status | Section |
|---|-------|----------|--------|---------|
| 1 | Transaction ROLLBACK not undoing changes | P0 | FIXED | 38.4 |
| 2 | Multiple pattern PURCHASED returns NULL | P0 | FIXED | 15.9 |
| 3 | Friends of Friends returns 0 rows | P1 | FIXED | 37.3 |
| 4 | OPTIONAL MATCH count(r) returns NULL | P1 | FIXED | 37.6 |
| 5 | Variable-length path returns wrong categories | P1 | FIXED | 43.4 |
| 6 | WITH + LIMIT chain returns too many rows | P1 | FIXED | 23.3 |
| 7 | ORDER BY not sorting correctly | P2 | FIXED | 34.5 |
| 8 | Cleanup leaves 2 remaining nodes | P3 | FIXED | 46.10 |

---

## Issue 1: Transaction ROLLBACK Not Undoing Changes (P0)

**Section**: 38.4

**Symptom**: After ROLLBACK, created nodes still persist.

**Test Sequence**:
```gql
START TRANSACTION;
CREATE (t:TransactionRollback {id: 999, status: 'will_rollback'});
MATCH (t:TransactionRollback) RETURN count(t) AS count_before_rollback;  -- Returns 1
ROLLBACK;
MATCH (t:TransactionRollback {id: 999}) RETURN count(t) AS should_be_zero;  -- Returns 1 (WRONG!)
```

**Expected**: `should_be_zero` should return 0 after ROLLBACK

**Actual**: Returns 1

**Root Cause**: TBD - Need to verify undo log integration with server-side execution.

---

## Issue 2: Multiple Pattern PURCHASED Returns NULL (P0)

**Section**: 15.9

**Symptom**: When matching multiple patterns in a single MATCH, the PURCHASED relationship returns NULL for product names even though the relationships exist.

**Test Query**:
```gql
-- Setup: Alice purchased Widget, Bob purchased Gadget (created in Section 14.3)
MATCH (p:Person)-[:WORKS_FOR]->(c:Company), (p)-[:PURCHASED]->(pr:Product)
RETURN p.name AS person, c.name AS employer, pr.name AS purchased;
```

**Expected**:
```
| person | employer | purchased |
|--------|----------|-----------|
| Alice  | TechCorp | Widget    |
| Bob    | TechCorp | Gadget    |
```

**Actual**:
```
| person  | employer   | purchased |
|---------|------------|-----------|
| Diana   | StartupXYZ | null      |
| Alice   | TechCorp   | null      |
| Charlie | DataInc    | null      |
| Bob     | TechCorp   | null      |
```

**Root Cause**: Multiple pattern matching doesn't properly intersect results. Returns all WORKS_FOR matches with NULL for the second pattern.

---

## Issue 3: Friends of Friends Returns 0 Rows (P1)

**Section**: 37.3

**Symptom**: Two-hop pattern matching returns no results when it should.

**Test Query**:
```gql
-- Setup: Alice-[:FRIEND]->Bob-[:FRIEND]->Dave, Alice-[:FRIEND]->Carol-[:FRIEND]->Dave
MATCH (a:SocialUser {name: 'Alice'})-[:FRIEND]->()-[:FRIEND]->(fof:SocialUser)
WHERE fof <> a
RETURN DISTINCT fof.name AS friends_of_friends ORDER BY fof.name;
```

**Expected**: Should return Dave (reached via Bob and Carol)

**Actual**: `(0 rows)`

**Root Cause**: Anonymous intermediate node `()` in multi-hop pattern not being handled correctly.

---

## Issue 4: OPTIONAL MATCH count(r) Returns NULL (P1)

**Section**: 37.6 (Degree Centrality)

**Symptom**: `count(r)` in OPTIONAL MATCH context returns NULL instead of numeric values.

**Test Query**:
```gql
MATCH (n:SocialUser)
OPTIONAL MATCH (n)-[r:FRIEND]-()
WITH n, count(r) AS connections
RETURN n.name AS user, connections ORDER BY connections DESC;
```

**Expected**:
```
| user  | connections |
|-------|-------------|
| Dave  | 4           |
| Alice | 3           |
...
```

**Actual**:
```
| user  | connections |
|-------|-------------|
| Dave  | null        |
| Alice | null        |
...
```

**Root Cause**: Aggregation in WITH clause after OPTIONAL MATCH not computing correctly.

---

## Issue 5: Variable-Length Path Returns Wrong Categories (P1)

**Section**: 43.4

**Symptom**: Variable-length path match returns nodes that don't match the pattern.

**Test Query**:
```gql
-- Should return only subcategories of Electronics
MATCH (sub:Category)-[:SUBCATEGORY_OF*]->(electronics:Category {name: 'Electronics'})
RETURN sub.name AS subcategory, sub.level ORDER BY sub.level;
```

**Expected**: Phones, Computers, Laptops, Desktops, Gaming Laptops

**Actual**:
```
| subcategory    | level |
|----------------|-------|
| Phones         | 2     |
| Laptops        | 3     |
| Desktops       | 3     |
| Clothing       | 1     |      <-- WRONG
| Gaming Laptops | 4     |
| Products       | 0     |      <-- WRONG
| Computers      | 2     |
```

**Root Cause**: Variable-length path is not filtering by the end node constraint `{name: 'Electronics'}`.

---

## Issue 6: WITH + LIMIT Chain Returns Too Many Rows (P1)

**Section**: 23.3

**Symptom**: LIMIT in WITH clause is not being respected in subsequent MATCH.

**Test Query**:
```gql
MATCH (p:Person)
WITH p ORDER BY p.age DESC LIMIT 3
MATCH (p)-[:WORKS_FOR]->(c:Company)
RETURN p.name, c.name;
```

**Expected**: At most 3 people (the 3 oldest) with their companies

**Actual**: 12 rows (all people × companies, ignoring LIMIT)

**Root Cause**: WITH clause LIMIT not being applied before the second MATCH.

---

## Issue 7: ORDER BY Not Sorting Correctly (P2)

**Section**: 34.5 (Graph Isolation Test)

**Symptom**: ORDER BY n.id returns results in wrong order.

**Test Query**:
```gql
USE GRAPH isolation_graph_a;
MATCH (n:IsolationNode) RETURN n.id, n.graph, n.name ORDER BY n.id;
```

**Expected**:
```
| id | graph | name  |
|----|-------|-------|
| 1  | A     | Alice |
| 2  | A     | Bob   |
```

**Actual**:
```
| id | graph | name  |
|----|-------|-------|
| 2  | A     | Bob   |
| 1  | A     | Alice |
```

**Root Cause**: ORDER BY ASC not sorting integers correctly (may be string comparison).

---

## Issue 8: Cleanup Leaves 2 Remaining Nodes (P3)

**Section**: 46.10

**Symptom**: After comprehensive cleanup, 2 nodes still remain.

**Test Sequence**:
```gql
-- After all DETACH DELETE operations...
MATCH (n) RETURN count(n) AS remaining_nodes;
```

**Expected**: 0

**Actual**: 2

**Root Cause**: Graph isolation issue in test file. After isolation graph tests (lines 867-868), the current graph is `isolation_graph_b`. The final cleanup (lines 1340-1368) didn't switch back to `test_comprehensive` before deleting, so nodes remained in the original graph.

**Fix**: Added `USE GRAPH test_comprehensive;` before final cleanup section in test file.

**Status**: FIXED

---

## Expected Behaviors (Not Bugs)

1. **Division by Zero** (Section 32.1): `Error: error: division by zero` - Correct error
2. **Invalid Type Conversion** (Section 32.2): `Error: Type mismatch in expression` - Correct error

## Known Limitations

1. **List Comprehension Syntax** (Section 37.5): `[node IN nodes(path) | node.name]` - Cypher-style syntax not fully supported

---

## Investigation Log

### 2025-12-23 Analysis - ALL ISSUES RESOLVED

**Issue 1 (P0): Transaction ROLLBACK** - FIXED
- Root cause: Server-side CREATE wasn't logging to undo log
- Fix: Added undo log integration in `query_executor.zig`, added `removeNode`/`removeEdge` in `graph_common.zig`, added `rollbackGraphStorage` in `txn_undo_log.zig`

**Issue 2 (P0): Multiple Pattern NULL** - FIXED
- Root cause: Only first chain processed in multi-chain MATCH
- Fix: Added `executeMultiChainRelationshipMatch` function in `match_operations.zig` to join chains on shared variables

**Issue 3 (P1): Friends of Friends 0 rows** - FIXED
- Root cause: Anonymous intermediate nodes not added to bindings
- Fix: Modified multi-hop pattern handling to add anonymous nodes with name `_anon_right`

**Issue 4 (P1): OPTIONAL MATCH count NULL** - FIXED
- Root cause: WITH clause aggregation not handled in optional match context
- Fix: Added WITH clause handling with aggregation support to `executeMatchWithOptionalPatterns`

**Issue 5 (P1): Variable-length path wrong categories** - FIXED
- Root cause: End node constraints not applied when collecting path targets
- Fix: Added right_labels and right_props filtering in path target collection (line 2576+)

**Issue 6 (P1): WITH + LIMIT too many rows** - FIXED
- Root cause: Bound variable from WITH clause not used to constrain relationship matching
- Fix: Added check for bound left node variable in param_values, use only that node instead of all nodes

**Issue 7 (P2): ORDER BY not sorting** - FIXED
- Root cause: Member expressions (n.id) couldn't be resolved as column lookups
- Fix: Added Member expression handling in `sortRows` to lookup by property name

**Issue 8 (P3): Cleanup 2 remaining** - FIXED
- Root cause: After isolation graph tests, current graph is wrong for cleanup
- Fix: Added `USE GRAPH test_comprehensive;` before final cleanup in test file

