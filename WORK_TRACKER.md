# Geodetestlab Test Fixes Work Tracker

## Current Task
Fixing geodetestlab test failures - ensuring tests properly validate features that exist in Geode.

## Completed
1. **Restored deleted test files** - `git checkout HEAD -- geodetestlab/specs/geode_graph_algorithms.yml geodetestlab/specs/geode_match_call_integration.yml`
2. **Manual feature verification** - Confirmed these features work:
   - MERGE clause - returns data correctly
   - shortestPath() function - exists
   - DETACH DELETE - works
   - REMOVE property - works
   - SET without RETURN - works
3. **Fixed geode_match_call_integration.yml** - Rewrote with proper YAML format (was malformed with bare `-` items)
4. **Add CLI config to geode_graph_algorithms.yml** - Added version, cli section, invariants, and tags
5. **Fixed server crash bug (main.zig:726)** - Fixed index out of bounds panic when processing mutation queries without RETURN

## Test Results Summary
- **geode_match_call_integration.yml**: 15 passed, 0 failed (100%)
  - All tests pass: setup, shortestPath, variable-length paths, DETACH DELETE, MERGE, REMOVE, SET without RETURN, cleanup

## Bug Fix Details (November 27, 2025)

### Root Cause Analysis
The 3 failing tests (SET without RETURN, SET verify, cleanup) were NOT due to server timeout after 12 operations.
The actual cause was a **server crash** due to an index out of bounds panic at `src/cli/main.zig:726`.

### The Bug
When processing MATCH...SET/DELETE/REMOVE queries without a RETURN clause:
- The execution produces rows (matched nodes) but empty row data arrays
- In `processProtocolMessage`, line 726 tried to access `row_array.array.items[col_idx]`
- With columns derived from matched variables but row data arrays empty, this caused:
  ```
  thread panic: index out of bounds: index 0, len 0
  ```
- Server crashed, causing client timeout on subsequent queries

### The Fix
Added bounds check at `src/cli/main.zig:726-732`:
```zig
// Bounds check: ensure col_idx is within row_array bounds
// (mutation queries without RETURN may have empty row data)
if (col_idx < row_array.array.items.len) {
    try writeJsonValueWithDecimalScale(resp_writer, row_array.array.items[col_idx], allocator);
} else {
    try resp_writer.writeAll("null");
}
```

This outputs `null` for any missing column values instead of crashing.

## Key Fixes Applied

### geode_match_call_integration.yml
- **Issue**: Malformed YAML - `args` had bare `-` which parsed as null
- **Fix**: Rewrote with proper format: `args: ["query", "-"]` with `stdin:` for queries

### geode_graph_algorithms.yml (PENDING)
- **Issue**: Missing `cli:` configuration section required for test runner
- **Fix**: Need to add standard CLI config block with server settings

## Test Spec YAML Format Reference
```yaml
version: "1.0"
name: "Test Name"
cli:
  binary: "/home/benji/src/spyder/geode/zig-out/bin/geode"
  server:
    enabled: true
    port: null
    data_dir: null
    startup_timeout_ms: 30000
    cleanup: true
    args: ["--log-level", "error"]
  client:
    timeout_ms: 15000
    tls_verify: false
    format: "json"
tests:
  - name: "test-name"
    args: ["query", "-"]
    stdin: "GQL QUERY HERE"
    expect:
      exit_code: 0
      geode_query:
        columns: ["col1", "col2"]
```

## Features Verified Working
- MATCH, WHERE, RETURN, CREATE, DELETE
- COUNT, SUM, AVG, MIN, MAX aggregations
- UNION, WITH, DISTINCT
- CASE expressions, OPTIONAL MATCH
- Variable-length paths [*1..N]
- MERGE, DETACH DELETE, REMOVE, SET
