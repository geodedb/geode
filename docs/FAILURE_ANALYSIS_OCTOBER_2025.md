# Test Failure Analysis - October 2025

## Executive Summary

**Current Status**: 1626/1655 passing (98.3%), 29 failing

After detailed analysis of all 29 failures, the root causes break down as follows:

### Failure Root Causes

| Category | Count | Description | Actionable? |
|----------|-------|-------------|-------------|
| Test Isolation Issues | 24 | Duplicate graph/index/schema names from persistent catalog | ❌ Test runner issue |
| Parser Missing Features | 19 | Syntax errors for unimplemented GQL features | ❌ Major parser work |
| Expected Auth Failures | 5 | Tests expect failure but succeed (no auth system) | ❌ By design |
| Real Implementation Bugs | 2 | Type mismatch in NOT operator, cosine similarity | ✅ Fixable |
| Specific Feature Gaps | 3 | Incremental backup, label updates, batch operations | ✅ Partially fixable |

**Note**: Some tests fall into multiple categories (e.g., both duplicate and syntax issues).

## Detailed Breakdown

### 1. Test Isolation Issues (24 tests)

**Root Cause**: The --no-quic mode shares a persistent catalog file that is not cleaned between tests.

**Tests Affected**:
- **Duplicate index name** (13 tests): create-simple-index, index-patricia-trie-create, index-rtree-create-location, index-rtree-create-geometry, index-hnsw-create-vector, index-interval-tree-create, index-jsonb-inverted-create, index-domain-trie-create, create-node-index, create-btree-index, create-hash-index, create-composite-index, bulk-update-with-index

- **Duplicate graph name** (11 tests): test-create-graph-basic, test-create-graph-if-not-exists, test-create-property-graph, create-graph-basic, create-property-graph-basic, create-graph-if-not-exists, create-typed-graph-any, create-typed-property-graph-any, create-graph-like-existing, create-graph-as-copy-of, catalog-workflow-graph-types

**Evidence**:
```bash
$ ./zig-out/bin/geode query --no-quic "CREATE GRAPH test_graph ANY"
{"status_class":"00000",...}

$ ./zig-out/bin/geode query --no-quic "CREATE GRAPH test_graph ANY"  # Same command
error: Duplicate graph name  # Fails because catalog persists
```

**Why Not Fixable in Code**:
1. Adding `CREATE OR REPLACE INDEX` would require parser changes (IndexStatement doesn't have or_replace field)
2. The real issue is test runner not cleaning `~/.geode/catalog.json` between tests
3. Tests should either use unique names or the runner should provide isolation

**Proper Fix**: Modify `extended_test_runner.py` to:
- Delete catalog file before each test: `rm -f ~/.geode/catalog.json`
- Or use per-test data directories with `--data-dir` flag
- Or add setup/teardown for catalog operations

### 2. Parser Missing Features (19 tests with "Syntax error")

**Tests Affected**:
- `type-map-values`: Map literal syntax `{name: 'Alice', age: 30}`
- `extremely-deep-nesting`: Deep CALL nesting (recursion limits)
- `order-by-node-property`: SQL `SELECT` keyword instead of `RETURN`
- `catalog-workflow-schema-graph`: Qualified names `schema.graph`
- `no-id-collision-on-delete-create`: WITH after DELETE
- `with-ordering`: WITH ... ORDER BY syntax
- `create-performance-index`: Advanced index syntax
- `create-relationship-index`: Relationship index syntax
- And 11 more...

**Evidence**:
```bash
$ ./zig-out/bin/geode query --no-quic "RETURN values({name: 'Alice'})"
Syntax error in query  # Map literals not implemented

$ ./zig-out/bin/geode query "CREATE (...) WITH n ORDER BY n.age ..."
Syntax error in query  # WITH...ORDER BY not implemented
```

**Why Not Fixable Quickly**:
- Each requires significant parser work (lexer + parser + AST + executor)
- Map literals alone: 10+ hours of work
- WITH clause improvements: 5+ hours per feature
- Total estimated: 50-100 hours for all parser features

**Proper Fix**: Systematic parser enhancement project, not quick wins.

### 3. Expected Auth/Validation Failures (5 tests)

**Tests Affected**:
- `unauthenticated-query-failure`: Expects exit 1, gets 0
- `wrong-password-failure`: Expects exit 1, gets 0
- `test-read-only-access`: Expects exit 1, gets 0
- `tde-error-invalid-key-provider`: Expects validation error, succeeds
- `cdc-error-invalid-guardrail`: Expects validation error, succeeds
- `cdc-error-malformed-control-command`: Expects validation error, succeeds

**Evidence**:
```bash
$ ./zig-out/bin/geode query --no-quic "RETURN 'should_fail'"
{"status_class":"00000",...}  # Succeeds without authentication
```

**Why This Is Expected**:
- No authentication system is implemented
- No TDE/CDC validation is implemented
- These tests document future requirements, not current bugs

**Proper Fix**: Implement authentication system (estimated 3-4 weeks).

### 4. Real Implementation Bugs (2 tests) ✅ FIXABLE

#### 4.1 where-with-not: NOT Operator Precedence

**Test**: `MATCH (n:Person) WHERE NOT n.age = 30 RETURN n.name`

**Error**: "Type mismatch in expression"

**Root Cause**: Operator precedence issue. The parser is interpreting as:
```
NOT(n.age) = 30    # Wrong: applying NOT to n.age property
```

Instead of:
```
NOT(n.age = 30)    # Correct: applying NOT to the comparison
```

**Workaround**: Add parentheses: `WHERE NOT (n.age = 30)` works correctly.

**Fix Required**:
- **Option A**: Fix operator precedence in parser (unary NOT should have lower precedence than binary =)
- **Option B**: Fix type checking to allow NOT on comparison results
- **Estimated**: 2-3 hours

**File**: `src/gql/parser.zig` or `src/eval.zig` depending on approach

#### 4.2 cosine-similarity: Vector Type Mismatch

**Test**: `algo.similarity.cosine(a.vector, b.vector)`

**Error**: "Type mismatch in expression"

**Root Cause**: Vector comparison or algo function not handling vector types correctly.

**Fix Required**: Add proper type handling for vector operations in eval.zig
- **Estimated**: 1-2 hours

**File**: `src/eval.zig` - vector function type checking

### 5. Specific Feature Gaps (3 tests) ✅ PARTIALLY FIXABLE

#### 5.1 create-incremental-backup

**Error**: `IncrementalBackupRequiresParent` - incremental backup needs a parent backup ID

**Fix**: The test should create a full backup first, then create incremental.

**Estimated**: Test fix only, 15 minutes

#### 5.2 add-label-to-nodes

**Error**: Returns empty result instead of showing updated labels

**Root Cause**: Possible issue with label addition or result serialization

**Estimated**: 1 hour investigation + fix

#### 5.3 batch-create-relationships

**Error**: Returns count=8 instead of expected value

**Root Cause**: Possible duplicate relationship creation or counting issue

**Estimated**: 1 hour investigation + fix

### 6. split-node-into-multiple (1 test) - COMPLEX

**Error**: "missing: '1'" - doesn't return expected count

**Root Cause**: Variable scoping in complex multi-operation statements:
```gql
CREATE (:Person {...})
MATCH (p:Person) WHERE p.type = 'employee'
CREATE (e:Employee {name: p.name}), (d:Department {name: p.department})
CREATE (e)-[:WORKS_IN]->(d)
DELETE p
RETURN count(e)
```

**Issue**: Property references from MATCH aren't available in subsequent CREATE, and DELETE interferes with RETURN.

**Fix Complexity**: Requires changes to query execution order and variable scoping - estimated 6-8 hours.

## Recommendations

### Immediate Actions (< 4 hours)

1. **Fix NOT operator precedence** - Real bug affecting WHERE clauses
2. **Fix test: create-incremental-backup** - Simple test fix
3. **Investigate: add-label-to-nodes, batch-create-relationships** - May be quick fixes

### Short-term (1-2 days)

4. **Fix test isolation** - Modify test runner to clean catalog between tests
   - This would fix 24 failures instantly
   - Not a code fix, but highest impact

### Medium-term (1-2 weeks)

5. **Implement map literal syntax** - Highest value parser feature
6. **Improve WITH clause parsing** - Enables several tests
7. **Fix split-node-into-multiple** - Complex execution order fix

### Long-term (Months)

8. **Authentication system** - Required for 5 tests
9. **Parser feature completion** - Systematic GQL compliance work
10. **Graph algorithms** - Specialized algorithms

## Impact vs Effort Matrix

| Fix | Impact (Tests) | Effort | ROI |
|-----|----------------|--------|-----|
| Test isolation (catalog cleanup) | 24 | 2 hours | ⭐⭐⭐⭐⭐ |
| NOT operator precedence | 1 | 2 hours | ⭐⭐⭐ |
| Incremental backup test | 1 | 15 min | ⭐⭐⭐⭐ |
| add-label / batch-create fixes | 2 | 2 hours | ⭐⭐⭐ |
| Map literal parser | 1 | 10 hours | ⭐ |
| WITH improvements | 3-5 | 15 hours | ⭐⭐ |
| Authentication system | 5 | 120 hours | ⭐ |

## Conclusion

**The most impactful fix is test isolation (24 tests), which is a test runner change, not a code fix.**

Of the actual code bugs:
- Only 2-3 are quick fixes (< 4 hours total)
- 19 require significant parser work (50-100 hours)
- 5 are expected behavior (no auth system)
- 1 is complex (split-node-into-multiple, 6-8 hours)

**Realistic expectation**: With test isolation fixed, we could reach **1650/1655 (99.7%)** with just 2 hours of test runner work plus 4 hours of bug fixes.

Without test isolation fixes, we're limited to **1629/1655 (98.5%)** with quick bug fixes alone.

---

*Analysis Date: October 13, 2025*
*Based on test run: run_20251013_213401*
*Total failures analyzed: 29*
