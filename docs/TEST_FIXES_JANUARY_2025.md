# Test Specification Fixes - January 8, 2025

## Summary

Fixed geodetestlab test specifications to comply with ISO/IEC 39075:2024 GQL standard requirements for explicit GROUP BY clauses.

## Background

**Issue**: Multiple geodetestlab tests were written expecting SQL-style implicit GROUP BY behavior, where non-aggregated columns in a RETURN clause with aggregation functions would automatically be grouped.

**GQL Standard**: ISO/IEC 39075:2024 requires explicit GROUP BY clauses when mixing aggregation and non-aggregated expressions.

**Conformance**: Test T19 in `tests/gql_conformance.zig` verifies this behavior and must continue to pass to maintain 98.6% GQL compliance.

## Files Modified

### 1. geode_gql_operations.yml

**Test**: `group-by`  
**Line**: 111

**Before**:
```yaml
args: ["query", "--server", "${server_address}", "MATCH (p:Person)-[:WORKS_FOR]->(c:Company) RETURN c.name AS company, count(p) AS employee_count ORDER BY company"]
```

**After**:
```yaml
args: ["query", "--server", "${server_address}", "MATCH (p:Person)-[:WORKS_FOR]->(c:Company) RETURN c.name AS company, count(p) AS employee_count GROUP BY c.name ORDER BY company"]
```

**Impact**: Test will now pass instead of failing with "grouping error: non-aggregated expression not in GROUP BY"

### 2. geode_advanced_math_algorithms.yml

**Test**: `Degree Centrality Calculation`  
**Line**: 135

**Before**:
```yaml
args: ["MATCH (c:City)-[r:ROAD]-() RETURN c.name, count(r) AS degree ORDER BY degree DESC LIMIT 3"]
```

**After**:
```yaml
args: ["MATCH (c:City)-[r:ROAD]-() RETURN c.name, count(r) AS degree GROUP BY c.name ORDER BY degree DESC LIMIT 3"]
```

**Impact**: Test will now execute correctly per GQL standard

### 3. geode_functions_comprehensive.yml

**Test**: `Degree Centrality`  
**Line**: 276

**Before**:
```yaml
args: ["MATCH (p:Person)-[r]-() RETURN p.name, count(r) AS degree ORDER BY degree DESC"]
```

**After**:
```yaml
args: ["MATCH (p:Person)-[r]-() RETURN p.name, count(r) AS degree GROUP BY p.name ORDER BY degree DESC"]
```

**Impact**: Test will now execute correctly per GQL standard

## Verification

All fixes follow the same pattern - adding explicit `GROUP BY <column>` where `<column>` is the non-aggregated expression in the RETURN clause.

```bash
# Example verification
./zig-out/bin/geode query --no-quic \
  "MATCH (p:Person)-[r]-() \
   RETURN p.name, count(r) AS degree \
   GROUP BY p.name \
   ORDER BY degree DESC"
# ✅ Success: {"status_class":"00000",...}
```

## Expected Impact

- **Before**: 3 tests failing with GROUP BY errors
- **After**: 3 tests passing
- **GQL Compliance**: Maintained at 98.6%
- **Standard Conformance**: T19 continues to pass

## Additional Notes

### Tests NOT Modified

Many tests use aggregation functions but were NOT modified because they:
1. Use only aggregation functions (no mixed expressions)
   - Example: `RETURN count(n)` - Valid without GROUP BY
2. Use WITH clauses which handle grouping differently
   - Example: `WITH category, count(a) AS num RETURN category, num` - Valid
3. Use window functions (OVER clause)
   - Example: `sum(...) OVER (...)` - Different semantics

### Future Work

A comprehensive audit of all geodetestlab tests may reveal additional GROUP BY issues, but these 3 were the most obvious violations found in commonly-used test suites.

## Related Documentation

- GQL Standard: `docs/kb/gql/ISO_IEC_39075_2024.md`
- Conformance Tests: `tests/gql_conformance.zig` (T19)
- Implementation Fixes: `docs/IMPLEMENTATION_FIXES_JANUARY_2025.md`

---

*Document Created*: January 8, 2025 (Evening)
*Tests Fixed*: 3 specifications
*Status*: Committed and Ready for Testing
