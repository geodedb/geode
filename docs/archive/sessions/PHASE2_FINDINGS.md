# Phase 2 Findings - Root Cause Analysis

## Spatial Function Failures

### Problem Summary
Tests like `index-rtree-spatial-intersects`, `index-rtree-spatial-contains`, and `index-rtree-spatial-within` all fail with:
```
STDERR: Type mismatch in expression
Exit Code: 1
```

### Root Cause Identified

**File**: `src/eval_extended.zig`
**Function**: `parseWktToWkb` (lines 458-481)

The `GeometryFromText()` function **only supports POINT geometries**:

```zig
fn parseWktToWkb(allocator: std.mem.Allocator, wkt: []const u8) ![]const u8 {
    // Simplified WKT parser for POINT
    if (std.mem.startsWith(u8, wkt, "POINT(") and std.mem.endsWith(u8, wkt, ")")) {
        // ... POINT parsing code ...
        return wkb;
    }

    // TODO: Support more geometry types
    return error.UnsupportedGeometry;  // ← POLYGON/LINESTRING/etc fail here
}
```

### Evidence Chain

1. **Test Query**:
   ```sql
   CREATE (region:Region {boundary: GeometryFromText('POLYGON(...)')})
   MATCH (poi:POI), (region:Region)
   WHERE st_intersects(poi.geometry, region.boundary)
   RETURN ...
   ```

2. **What Happens**:
   - `GeometryFromText('POLYGON(...)')` hits line 480 and returns error
   - Error converted to `null` value
   - Property `region.boundary` stores `null`
   - `st_intersects(poi.geometry, null)` receives `.Null` not `.Geometry`
   - Type check at `eval_extended.zig:1104` fails: `if (args[1] != .Geometry) return error.TypeMismatch`

3. **Verification**:
   ```bash
   $ geode query "RETURN GeometryFromText('POINT(-122 37)')"
   # Returns: [["[advanced_type]"]]  ✓ Works

   $ geode query "RETURN GeometryFromText('POLYGON(...)')"
   # Returns: [[null]]  ✗ Returns null - unsupported
   ```

### Impact

**Failing Tests** (~9 tests):
- `index-rtree-spatial-intersects`
- `index-rtree-spatial-contains`
- `index-rtree-spatial-within`
- Any test using POLYGON, LINESTRING, MULTIPOINT, etc.

**Working Tests**:
- Tests using only POINT geometries work correctly

### Solution Required

Implement POLYGON, LINESTRING, and other WKT geometry type parsing in `parseWktToWkb()`:

```zig
fn parseWktToWkb(allocator: std.mem.Allocator, wkt: []const u8) ![]const u8 {
    // Handle POINT (already implemented)
    if (std.mem.startsWith(u8, wkt, "POINT(")) { ... }

    // TODO: Add POLYGON support
    if (std.mem.startsWith(u8, wkt, "POLYGON(")) {
        // Parse: POLYGON((x1 y1, x2 y2, ..., x1 y1))
        // Convert to WKB format for polygon
        // ...
    }

    // TODO: Add LINESTRING support
    if (std.mem.startsWith(u8, wkt, "LINESTRING(")) { ... }

    // TODO: Add other geometry types as needed

    return error.UnsupportedGeometry;
}
```

### Complexity Estimate

**POLYGON parsing**: Medium complexity
- Parse nested coordinate list: `POLYGON((x1 y1, x2 y2, ...))`
- Convert to WKB binary format
- Handle ring validation (first point = last point)
- Estimated: 50-100 lines of parsing code

**Complete geometry support**: High complexity
- LINESTRING, MULTIPOINT, MULTILINESTRING, MULTIPOLYGON
- WKB format variations for each type
- Coordinate parsing and validation
- Estimated: 200-400 lines total

### Alternative Approach

**Quick Fix**: Make spatial functions return true/false placeholders for MVP:

```zig
fn stIntersects(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;

    // Accept any geometry-like input (including null for unsupported types)
    // Return placeholder results for MVP
    return .{ .Bool = true };
}
```

This would make tests pass but wouldn't provide real spatial functionality.

## Other Phase 2 Issues

### Vector KNN Functions

Similar pattern - tests expect `KNN()` function that doesn't exist yet:
```sql
MATCH (doc:Document)
WHERE KNN(doc.embedding, VectorF32([...]), 3)
RETURN doc
```

**Status**: Function not implemented
**Impact**: ~3-5 tests

### OPTIONAL MATCH Nesting

Test: `optional-match-nested`
**Status**: Parser doesn't support nested OPTIONAL MATCH
**Impact**: ~1-2 tests

### Deep Nesting

Test: `extremely-deep-nesting`
**Status**: Parser recursion limits
**Impact**: ~1 test

### UNION ALL Variable Scoping

Test: `order-by-node-property`
```sql
CREATE (a:Person {...}) RETURN a.name
UNION ALL
SELECT b.name  -- Variable 'b' not in scope
```

**Status**: Complex parser/scoping issue
**Impact**: ~5-10 tests

## Summary

**Phase 2 Core Issue**: Missing geometry type support in WKT parser
- **Root cause**: `GeometryFromText` only handles POINT, not POLYGON/LINESTRING/etc
- **Impact**: ~15-20 tests fail due to null geometry values
- **Fix complexity**: Medium to High (100-400 lines of parsing code)

**Recommendation**:
1. **For production**: Implement proper WKT parsing for all geometry types
2. **For quick test pass**: Make spatial functions more lenient (accept null, return placeholder)
3. **For Phase 2 completion**: Focus on implementing POLYGON support first (highest test impact)

The geode codebase has the infrastructure in place - it just needs the geometry parsing implementation completed.
