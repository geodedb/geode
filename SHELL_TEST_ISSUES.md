# Shell Test Issues - December 2025

Issues discovered during comprehensive shell testing (`./testing/shell/comprehensive_test.gql`).

## Issue Summary

| # | Issue | Priority | Status | Root Cause |
|---|-------|----------|--------|------------|
| 1 | Transaction ROLLBACK server-side | HIGH | Pending | Undo log not integrated with server |
| 2 | GROUP BY not grouping correctly | CRITICAL | **FIXED** | Relationship pattern not handled in GROUP BY |
| 3 | sum() returns 0 for Order totals | MEDIUM | Likely Fixed | GROUP BY fix should resolve this |
| 4 | OPTIONAL MATCH count() returns null | MEDIUM | Pending | Aggregation detection issue |
| 5 | List comprehension with nodes(path) | LOW | Pending | Path variable resolution |
| 6 | Friends of friends returns null | MEDIUM | Pending | Multi-hop pattern not supported |
| 7 | Products ordered together returns 0 | LOW | Pending | Complex pattern matching |

---

## Issue 1: Transaction ROLLBACK Server-Side Integration (HIGH)

**Symptom**: Transaction ROLLBACK works in CLI mode but not in server mode. After ROLLBACK, created nodes still persist.

**Test Sequence**:
```gql
START TRANSACTION;
CREATE (t:TransactionRollback {id: 999, status: 'will_rollback'});
MATCH (t:TransactionRollback) RETURN count(t) AS count_before_rollback;  -- Returns 1
ROLLBACK;
MATCH (t:TransactionRollback {id: 999}) RETURN count(t) AS should_be_zero;  -- Returns 1 (WRONG!)
```

**Expected**: `should_be_zero` should return 0 after ROLLBACK

**Investigation Needed**: Check if `txn_undo_log.zig` is properly integrated with server-side query execution path.

---

## Issue 2: GROUP BY Not Grouping Correctly (CRITICAL) - FIXED

**Status**: :white_check_mark: **FIXED** (2025-12-23)

**Symptom**: GROUP BY appears to group by wrong columns or not at all. This affects multiple queries.

**Test Query**:
```gql
MATCH (c:Company)<-[:WORKS_AT]-(e:Employee)
RETURN c.name AS company, collect(e.name) AS employees, count(e) AS emp_count
GROUP BY c.name
ORDER BY emp_count DESC;
```

**Root Cause**: The GROUP BY handling code in `executeMatchQueryImpl` only handled simple node patterns (iterating over nodes), not relationship patterns. When a query had both `has_aggregation=true` and `has_relationship=true`, the code incorrectly processed only nodes instead of relationship bindings.

**Fix Applied**:
1. Added new code path in `src/execution/match_operations.zig` for `has_aggregation AND has_relationship AND group_by` case
2. Collects relationship pattern bindings (left node, right node, edge) properly respecting edge direction
3. Groups bindings by GROUP BY key expression evaluated in full environment context
4. Added `computeBindingGroupAggregation()` function in `src/execution/aggregation_evaluation.zig` to compute aggregations over binding groups
5. Handles edge direction (`<-` vs `->`) correctly using `getEdgesTo()` vs `getEdgesFrom()`

**Files Modified**:
- `src/execution/match_operations.zig` - Added relationship pattern GROUP BY handling (~300 lines)
- `src/execution/aggregation_evaluation.zig` - Added `computeBindingGroupAggregation()` (~180 lines)
- `src/execution.zig` - Added export for new function

---

## Issue 3: sum() Returns 0 for Order Totals (MEDIUM)

**Symptom**: `sum(o.total)` returns 0 even when orders have total values.

**Test Query**:
```gql
MATCH (c:Customer)-[:PLACED]->(o:Order)
RETURN c.name, c.tier, count(o) AS order_count, sum(o.total) AS total_spent
GROUP BY c.name, c.tier
ORDER BY total_spent DESC;
```

**Result**:
```
| name  | tier   | order_count | total_spent |
|-------|--------|-------------|-------------|
| Alice | Gold   | 1           | 0           |
| Eve   | Silver | 1           | 0           |
```

**Expected**: `total_spent` should be actual sum values (e.g., 1349.98, 1949.97)

**Note**: A fix was previously applied to `aggregation_evaluation.zig` to handle Decimal ExtValues. Need to verify this fix is complete.

**Likely Related To**: Issue 2 (GROUP BY) - if grouping is wrong, aggregations will compute over wrong sets.

---

## Issue 4: OPTIONAL MATCH count() Returns Null (MEDIUM)

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
| user    | connections |
|---------|-------------|
| Alice   | null        |
| Bob     | null        |
```

**Expected**: `connections` should be numeric (0 for no friends, >0 for those with friends)

**Note**: A fix was claimed for this in execution.zig (aggregation detection in WITH clause), but it's still not working.

---

## Issue 5: List Comprehension with nodes(path) Fails (LOW)

**Symptom**: List comprehension `[node IN nodes(path) | node.name]` returns empty or fails.

**Test Query**:
```gql
MATCH path = (n:SocialUser)-[:FRIEND*3..6]->(n)
WHERE n.name = 'Alice'
RETURN length(path) AS cycle_length, [node IN nodes(path) | node.name] AS cycle_path
LIMIT 3;
```

**Result**: Empty or null for `cycle_path`

**Expected**: List of node names along the path

**Note**: Basic list comprehension `[x IN [1,2,3] | x * 2]` works. Issue is specific to path variable resolution.

---

## Issue 6: Friends of Friends Returns Null (MEDIUM)

**Symptom**: Two-hop relationship pattern returns null values.

**Test Query**:
```gql
MATCH (u:SocialUser {name: 'Alice'})-[:FRIEND]->(friend)-[:FRIEND]->(fof)
WHERE fof <> u
RETURN friend.name AS friend, fof.name AS friend_of_friend;
```

**Result**: Returns rows but `friend` and `friend_of_friend` are null

**Expected**: Actual names of friends and friends-of-friends

---

## Issue 7: Products Ordered Together Returns 0 Rows (LOW)

**Symptom**: Complex pattern with multiple relationships returns no results.

**Test Query**:
```gql
MATCH (p1:Product)<-[:CONTAINS]-(o:Order)-[:CONTAINS]->(p2:Product)
WHERE p1.id < p2.id
RETURN p1.name AS product1, p2.name AS product2, count(o) AS times_together
GROUP BY p1.name, p2.name
ORDER BY times_together DESC;
```

**Result**: 0 rows

**Expected**: Product pairs that appear in the same orders

---

## Investigation Priority

1. **Issue 2 (GROUP BY)** - CRITICAL - Root cause of multiple failures
2. **Issue 1 (ROLLBACK)** - HIGH - Server integration needed
3. **Issues 3, 4, 6** - MEDIUM - May be side effects of Issue 2
4. **Issues 5, 7** - LOW - Complex pattern/path handling

## Files to Investigate

- `src/execution.zig` - GROUP BY handling, aggregation execution
- `src/execution/aggregation_evaluation.zig` - sum(), count(), collect() evaluation
- `src/execution/match_operations.zig` - Pattern matching and binding
- `src/txn_undo_log.zig` - Transaction rollback (server integration)
- `src/server/query_executor.zig` - Server-side query execution path
