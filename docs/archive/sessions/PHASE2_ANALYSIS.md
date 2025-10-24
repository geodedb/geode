# Phase 2 Analysis - Spatial Function Type Mismatch Issue

## Problem

Tests like `index-rtree-spatial-intersects` fail with error:
```
STDERR: Type mismatch in expression
Exit Code: 1
```

## Root Cause

When spatial functions like `st_intersects(poi.geometry, region.boundary)` are called in WHERE clauses:

1. **Function expects**: `args[0]` and `args[1]` to be `.Geometry` ExtValue types
2. **Function receives**: Property values that aren't properly converted to ExtValue

The `stIntersects` implementation at `src/eval_extended.zig:1104`:
```zig
if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;
```

This check fails because property access `poi.geometry` returns a PropertyValue which may contain an ExtValue, but it's not being unwrapped/converted properly when passed to the function.

## Evidence

1. Manual query without data works: `st_intersects(...)` returns empty rows, exit code 0
2. Query with data fails: "Type mismatch in expression", exit code 1
3. Geometry property stores correctly: `CREATE (poi {geom: GeometryFromText(...)})` works
4. Property retrieval shows placeholder: `RETURN poi.geom` outputs "[advanced_type]"

## The Issue

The evaluation path for WHERE clause expressions needs to:
1. Resolve `poi.geometry` to get the PropertyValue from the node
2. Extract the ExtValue from PropertyValue.ExtValue
3. Pass the extracted ExtValue to the st_intersects function

Currently step 2 or 3 is not happening correctly, causing the type mismatch.

## Similar Issues

This affects all spatial functions:
- `st_intersects` - 3+ failing tests
- `st_contains` - 3+ failing tests
- `st_within` - 3+ failing tests

And likely affects vector functions in similar ways:
- `vector_cosine` - may have same issue
- `vector_l2` - may have same issue
- `vector_knn` - needs to be implemented

## Solution Approach

Need to fix the evaluation path in src/eval.zig where PropertyAccess expressions are evaluated to properly unwrap ExtValue types before passing them to extended functions.

Alternatively, could make the spatial functions more lenient and handle PropertyValue wrapping internally.

## Priority

HIGH - This affects ~15-20 tests across spatial and vector operations.
