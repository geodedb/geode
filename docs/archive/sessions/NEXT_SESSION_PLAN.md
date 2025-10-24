# Next Session Plan: Path to 90% Pass Rate
**Target**: Achieve 90%+ pass rate (1530+ passing tests)
**Current**: 87.8% pass rate (1501P/159F/65S)
**Required**: +29-50 passing tests
**Estimated Effort**: 10-15 hours

---

## Strategic Overview

### Priority Matrix

| Target | Failures | Effort | ROI | Expected Gain | Priority |
|--------|----------|--------|-----|---------------|----------|
| geode_regression_tests | 16 | 2-3h | ⭐⭐⭐⭐⭐ | +10-15 | **CRITICAL** |
| geode_advanced | 9 | 3-5h | ⭐⭐⭐⭐ | +5-8 | **HIGH** |
| geode_migrations | 13 | 3-6h | ⭐⭐⭐ | +8-12 | **HIGH** |
| Type system fixes | 13 | 2-4h | ⭐⭐⭐⭐ | +10-13 | **HIGH** |
| Result correctness | 20+ | 4-8h | ⭐⭐⭐ | +15-20 | **MEDIUM** |

### Recommended Sequence

**Phase 1: Quick Wins (3-4 hours)**
1. geode_regression_tests.yml - Likely simple bug fixes
2. Type system fixes - Targeted improvements

**Phase 2: Medium Complexity (5-7 hours)**
3. geode_advanced.yml - Advanced features
4. geode_migrations.yml - Schema migrations

**Phase 3: Deep Debugging (3-5 hours)**
5. Result correctness - Execution bugs

---

## Phase 1: Quick Wins (Target: +20-25 tests)

### Task 1.1: geode_regression_tests.yml Analysis

**Current Status**: 28P/16F (63.6%)
**Target**: 38P/6F (86.4%)
**Expected Gain**: +10 tests
**Estimated Effort**: 2-3 hours

**Approach**:
1. Run individual failing tests to identify patterns
2. Check test logs in `test_logs/run_20251011_093803/`
3. Categorize failures by type:
   - Parser errors (likely quick fixes)
   - Execution errors (medium complexity)
   - Result mismatches (need investigation)

**Commands**:
```bash
# Run single test suite with detailed output
python3 parallel_test_runner.py -s geode_regression_tests.yml

# Check detailed logs
cd test_logs/run_20251011_093803
cat geode_regression_tests.yml.log | grep -A 10 "FAILED"

# Run specific failing test
./zig-out/bin/geode query --no-quic "SPECIFIC QUERY FROM TEST"
```

**Common Regression Patterns to Check**:
- OFFSET without ORDER BY (strict validation mode)
- Transaction state management
- Session parameter handling
- Edge cases in basic operations

**Expected Fixes**:
- 4-6 parser/syntax fixes (1-2 hours)
- 3-4 execution bugs (30-60 minutes)
- 2-3 validation errors (30 minutes)

**Success Criteria**: 86%+ pass rate on this suite

---

### Task 1.2: Type System Coercion Fixes

**Current Issues**: 13 tests failing across multiple suites
**Target**: Fix IPv4/IPv6 and Point/Polygon coercion
**Expected Gain**: +10-13 tests
**Estimated Effort**: 2-4 hours

**Known Issues**:
1. **Network Type Coercion** (IPv4/IPv6 in Patricia trie)
   - Location: Patricia trie query handling
   - Issue: Type mismatch when querying with different formats
   - Files to check: `src/index/patricia_trie.zig`, `src/types/network.zig`

2. **Spatial Type Coercion** (Point/Polygon in R-tree)
   - Location: R-tree spatial queries
   - Issue: Geometry type coercion not working
   - Files to check: `src/index/rtree.zig`, `src/types/spatial.zig`

3. **Label Test Expression Operators** (NOT/OR)
   - Location: Label filtering logic
   - Issue: Complex boolean expressions failing
   - Files to check: `src/execution.zig`, `src/eval.zig`

**Implementation Steps**:

**Step 1: Network Type Fixes** (1 hour)
```bash
# Find IPv4/IPv6 handling code
rg "IPv[46]" src/types/ src/index/

# Test current behavior
./zig-out/bin/geode query --no-quic \
  "MATCH (n) WHERE n.ip = IPv4('192.168.1.1') RETURN n"
```

**Expected Changes**:
- Add type coercion in Patricia trie query path
- Handle both IPv4 and IPv6 formats uniformly
- Add conversion functions if needed

**Step 2: Spatial Type Fixes** (1-2 hours)
```bash
# Find spatial type handling
rg "Point|Polygon" src/types/ src/index/

# Test current behavior
./zig-out/bin/geode query --no-quic \
  "MATCH (n) WHERE n.location = Point(1.0, 2.0) RETURN n"
```

**Expected Changes**:
- Add geometry type coercion in R-tree
- Handle Point/LineString/Polygon conversions
- Validate spatial predicates correctly

**Step 3: Label Test Operators** (30-60 minutes)
```bash
# Find label test expression code
rg "label.*test|hasLabel" src/

# Test current behavior
./zig-out/bin/geode query --no-quic \
  "MATCH (n) WHERE n:Person OR n:Company RETURN count(n)"
```

**Expected Changes**:
- Fix NOT operator in label tests
- Fix OR operator in label tests
- Ensure proper boolean logic

**Success Criteria**: All type coercion tests passing

---

## Phase 2: Medium Complexity (Target: +13-20 tests)

### Task 2.1: geode_advanced.yml Investigation

**Current Status**: 3P/9F (25.0%)
**Target**: 9P/3F (75.0%)
**Expected Gain**: +6 tests
**Estimated Effort**: 3-5 hours

**Analysis Strategy**:
```bash
# Get detailed failure information
python3 parallel_test_runner.py -s geode_advanced.yml 2>&1 | tee /tmp/advanced_analysis.log

# Check test definitions
cat geodetestlab/specs/geode_advanced.yml | grep -A 10 "name:"
```

**Likely Issues**:
1. Advanced pattern matching (variable length paths)
2. Complex aggregations
3. Nested subqueries
4. Advanced temporal operations
5. Complex graph traversals

**Investigation Process**:
1. Run each failing test individually
2. Compare actual vs expected output
3. Identify common failure patterns
4. Group fixes by component

**Estimated Breakdown**:
- 2-3 parser extensions (1-2 hours)
- 2-3 execution bugs (1-2 hours)
- 1-2 eval/aggregation issues (1 hour)

**Success Criteria**: 75%+ pass rate on this suite

---

### Task 2.2: geode_migrations.yml Analysis

**Current Status**: 17P/13F/4S (50.0%)
**Target**: 25P/5F/4S (83.3%)
**Expected Gain**: +8 tests
**Estimated Effort**: 3-6 hours

**Known Migration Issues**:
1. Schema evolution commands
2. Data migration queries
3. Index migration
4. Constraint migration (now that we have parsing!)

**Investigation**:
```bash
# Run migrations suite
python3 parallel_test_runner.py -s geode_migrations.yml

# Check for schema-related code
rg "schema|migration" src/storage/ src/execution.zig
```

**Likely Fixes**:
1. **Schema Change Detection** (1-2 hours)
   - Add/drop labels dynamically
   - Add/drop properties
   - Schema versioning

2. **Data Migration** (1-2 hours)
   - Bulk property updates
   - Label changes on existing nodes
   - Type conversions

3. **Index Migration** (1-2 hours)
   - Rebuild indexes after schema change
   - Handle index creation on existing data
   - Drop indexes cleanly

**Success Criteria**: 80%+ pass rate on this suite

---

## Phase 3: Deep Debugging (Target: +15-20 tests)

### Task 3.1: Result Correctness Issues

**Current**: 20+ tests failing across multiple suites
**Target**: Fix common result bugs
**Expected Gain**: +15-20 tests
**Estimated Effort**: 4-8 hours

**Known Issues**:

**Issue 1: SKIP/LIMIT with ORDER BY** (2-3 hours)
```gql
-- Failing pattern
MATCH (n:Person)
RETURN n.name
ORDER BY n.age
SKIP 5 LIMIT 10
```

**Symptoms**:
- Wrong rows returned
- Incorrect ordering after pagination
- Off-by-one errors

**Files to Check**:
- `src/execution.zig` - Query execution
- SKIP/LIMIT handling
- ORDER BY integration

**Fix Strategy**:
1. Verify ORDER BY is applied before SKIP/LIMIT
2. Check offset calculation
3. Validate limit boundaries

**Issue 2: Empty Result Sets** (1-2 hours)
```gql
-- Unexpectedly returns empty
MATCH (n) WHERE n.prop = value RETURN n
```

**Symptoms**:
- Queries return empty when data exists
- Null handling issues
- Type mismatch causing filter failures

**Fix Strategy**:
1. Add debug logging to understand why matches fail
2. Check null value handling
3. Verify type conversions in WHERE clauses

**Issue 3: Aggregation Discrepancies** (2-3 hours)
```gql
-- COUNT returns wrong values
MATCH (n:Person)
RETURN COUNT(n), COUNT(DISTINCT n.name)
```

**Symptoms**:
- COUNT off by one or more
- DISTINCT not working correctly
- GROUP BY producing wrong counts

**Fix Strategy**:
1. Review aggregation logic in eval.zig
2. Check DISTINCT implementation
3. Verify GROUP BY handling

**Success Criteria**: Result correctness tests at 90%+

---

## Implementation Guidelines

### Investigation Workflow

For each failing test:

```bash
# 1. Identify the failing test
python3 parallel_test_runner.py -s [suite].yml 2>&1 | grep FAILED

# 2. Extract the test query
cat geodetestlab/specs/[suite].yml | grep -A 5 "name: [test-name]"

# 3. Run query manually
./zig-out/bin/geode query --no-quic "[QUERY]" --format json

# 4. Compare with expected output
# (from test spec file)

# 5. Add debug logging if needed
# Edit relevant source files, rebuild:
zig build

# 6. Re-run test
python3 parallel_test_runner.py -s [suite].yml

# 7. Iterate until fixed
```

### Code Change Best Practices

1. **One Fix at a Time**: Don't batch unrelated changes
2. **Test Immediately**: Run tests after each fix
3. **Document Changes**: Add comments explaining why
4. **Check Regressions**: Run full suite periodically
5. **Commit Frequently**: Small, focused commits

### Testing Strategy

```bash
# After each fix:
# 1. Run affected test suite
python3 parallel_test_runner.py -s [specific-suite].yml

# After 3-5 fixes:
# 2. Run full test suite
python3 parallel_test_runner.py

# Check for regressions
# 3. Compare pass rates
tail -30 /tmp/test_run_*.log | grep "Pass rate"
```

---

## Expected Outcomes by Phase

### After Phase 1 (3-4 hours)
```
Current:  1501P/159F/65S (87.8%)
Expected: 1521P/139F/65S (89.2%)
Gain:     +20 tests
```

### After Phase 2 (8-11 hours)
```
Current:  1521P/139F/65S (89.2%)
Expected: 1535P/125F/65S (90.3%)
Gain:     +14 tests
```

### After Phase 3 (12-18 hours)
```
Current:  1535P/125F/65S (90.3%)
Expected: 1550P/110F/65S (91.5%)
Gain:     +15 tests
```

### Final Target
```
Start:    1501P/159F/65S (87.8%)
End:      1550P/110F/65S (91.5%)
Total:    +49 tests
Time:     12-18 hours
```

---

## Risk Assessment

### High-Risk Areas

**1. Deep Execution Bugs** (Medium Risk)
- **Risk**: May require extensive refactoring
- **Mitigation**: Start with simple fixes, escalate if needed
- **Fallback**: Document and defer complex issues

**2. Type System Changes** (Low Risk)
- **Risk**: Could break existing functionality
- **Mitigation**: Test thoroughly after each change
- **Fallback**: Revert if regressions detected

**3. Migration Features** (Medium-High Risk)
- **Risk**: May need significant new infrastructure
- **Mitigation**: Check for existing migration support first
- **Fallback**: Mark tests as "needs infrastructure" if too complex

### Low-Risk, High-Reward Opportunities

1. **Parser Extensions**: Usually straightforward
2. **Validation Fixes**: Often one-line changes
3. **Type Coercion**: Well-isolated changes
4. **Error Message Fixes**: No functional impact

---

## Success Criteria

### Minimum Success (Phase 1 Only)
- ✅ 89%+ pass rate (1520+ passing tests)
- ✅ geode_regression_tests at 85%+
- ✅ Type coercion issues resolved
- ✅ +20 tests passing

### Target Success (Phases 1-2)
- ✅ 90%+ pass rate (1535+ passing tests)
- ✅ geode_advanced at 75%+
- ✅ geode_migrations at 80%+
- ✅ +35 tests passing

### Stretch Goal (All Phases)
- ✅ 91.5%+ pass rate (1550+ passing tests)
- ✅ Result correctness at 90%+
- ✅ All high-priority suites at 80%+
- ✅ +50 tests passing

---

## Handoff Notes

### Before Starting

1. ✅ Build and verify: `zig build`
2. ✅ Run baseline tests: `python3 parallel_test_runner.py`
3. ✅ Check current status matches: 1501P/159F/65S
4. ✅ Review this plan completely

### During Work

1. ✅ Update todo list as you progress
2. ✅ Commit after each successful fix
3. ✅ Document any discoveries
4. ✅ Note any deferred issues

### After Session

1. ✅ Run full test suite
2. ✅ Document final status
3. ✅ Update plan for next session
4. ✅ Commit all changes

---

## Tools and Commands Reference

### Essential Commands

```bash
# Build
zig build

# Run all tests
python3 parallel_test_runner.py

# Run specific suite
python3 parallel_test_runner.py -s [suite-name].yml

# Run single query
./zig-out/bin/geode query --no-quic "[QUERY]"

# Check test logs
tail -100 test_logs/run_*/summary.log

# Search codebase
rg "pattern" src/

# Find files
fd "pattern" src/
```

### Debugging Commands

```bash
# Add verbose output
./zig-out/bin/geode query --no-quic --verbose "[QUERY]"

# Check AST
./zig-out/bin/gql --ast "[QUERY]"

# Profile query
./zig-out/bin/geode query --no-quic "[QUERY]" --profile
```

---

## Conclusion

This plan provides a clear roadmap from 87.8% to 90%+ pass rate through systematic investigation and targeted fixes. The phased approach allows for early wins while tackling progressively more complex issues.

**Key Success Factors**:
1. Start with high-ROI targets (regression tests)
2. Fix type system issues early (affects multiple suites)
3. Investigate before implementing (avoid wasted effort)
4. Test frequently (catch regressions early)
5. Document everything (enable future sessions)

**Next Steps**:
1. Read this plan completely
2. Start with Phase 1, Task 1.1
3. Follow the investigation workflow
4. Track progress with todo list
5. Achieve 90%+ pass rate!

---

**Plan Status**: ✅ READY
**Estimated Total Effort**: 12-18 hours
**Expected Outcome**: 90-91.5% pass rate
**Confidence Level**: HIGH

**Recommended Start**: Phase 1, Task 1.1 (geode_regression_tests)

---

*Generated: October 11, 2025*
*For: Next ISO GQL Compliance Session*
