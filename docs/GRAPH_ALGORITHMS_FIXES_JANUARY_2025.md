# Graph Algorithms Implementation - January 8, 2025 (Evening)

## Summary

Fixed critical bug in CALL statement algorithm name extraction that was causing ALL algorithm calls to be misidentified as PageRank.

## Changes Made

### 1. Fixed Member Access Path Extraction (`src/execution.zig`)

**Problem**: Line 3273 had a hardcoded placeholder `"algo.pageRank.stream"` for all member access expressions, causing all algorithm CALL statements (betweenness, closeness, louvain, etc.) to be incorrectly identified as PageRank.

**Solution**:
- Added `buildMemberPath()` helper function (lines 3261-3281) to recursively build the full member access path
- Properly extracts paths like `algo.betweenness.stream`, `algo.louvain.stream`, etc.

**Code Added**:
```zig
// Helper to build member access path (e.g., algo.betweenness.stream)
fn buildMemberPath(allocator: std.mem.Allocator, expr: *ast.Expr, result: *std.ArrayList(u8)) !void {
    switch (expr.*) {
        .Member => |member| {
            // Recursively build the target path first
            try buildMemberPath(allocator, member.target, result);
            // Add dot separator
            try result.append(allocator, '.');
            // Add this field name
            try result.appendSlice(allocator, member.field);
        },
        .Ident => |ident| {
            // Base case: identifier
            try result.appendSlice(allocator, ident.orig);
        },
        else => {
            // Unknown expression type
            try result.appendSlice(allocator, "unknown");
        },
    }
}
```

**Updated Call**:
```zig
// Before:
break :blk "algo.pageRank.stream"; // Hardcoded!

// After:
var name_parts = try std.ArrayList(u8).initCapacity(allocator, 0);
defer name_parts.deinit(allocator);
try buildMemberPath(allocator, call.callee, &name_parts);
break :blk try name_parts.toOwnedSlice(allocator);
```

### 2. Fixed Algorithm Name Comparisons (`src/execution.zig`)

**Problem**: Code was checking for algorithm names like `"betweennessCentrality"`, `"louvainCommunities"`, etc., but the actual parsed names from test queries are `"betweenness"`, `"louvain"`, etc.

**Solution**: Updated all algorithm name comparisons to match the actual syntax used in tests.

**Changes**:
```zig
// Before (lines 3427-3436):
std.mem.eql(u8, algo_name, "betweennessCentrality")
std.mem.eql(u8, algo_name, "louvainCommunities")
std.mem.eql(u8, algo_name, "stronglyConnectedComponents")
// ... etc

// After (lines 3453-3463):
std.mem.eql(u8, algo_name, "betweenness")
std.mem.eql(u8, algo_name, "louvain")
std.mem.eql(u8, algo_name, "scc")
std.mem.eql(u8, algo_name, "unionFind")  // Added
// ... etc
```

### 3. Updated Algorithm-Specific Logic (`src/execution.zig`)

**Changes**:
- Line 3491: `"degreeCentrality"` → `"degree"`
- Lines 3501-3504: Updated community algorithm names and added `"unionFind"`

## Test Expectations

Tests from `geodetestlab/specs/geode_graph_algorithms.yml` use syntax like:
- `CALL algo.betweenness.stream() YIELD nodeId, centrality`
- `CALL algo.pageRank.stream({iterations: 20, dampingFactor: 0.85}) YIELD nodeId, score`
- `CALL algo.louvain.stream() YIELD nodeId, community`
- `CALL algo.unionFind.stream() YIELD nodeId, setId`
- `CALL algo.scc.stream() YIELD nodeId, partition`

These now correctly extract algorithm names:
- `algo.betweenness.stream` → `"betweenness"` ✅
- `algo.pageRank.stream` → `"pageRank"` ✅
- `algo.louvain.stream` → `"louvain"` ✅
- `algo.unionFind.stream` → `"unionFind"` ✅

## Current Status

### ✅ Fixed
1. Algorithm name extraction from CALL member access expressions
2. Algorithm name comparisons to match test syntax
3. Build compiles successfully
4. Binary generated: `./zig-out/bin/geode` (46MB, 19:28)

### ⚠️  Outstanding Issues

1. **CALL Syntax Parsing**: Standalone CALL statements (without preceding MATCH) may have parser issues
   - Error: "Syntax error in query" when running `CALL algo.betweenness.stream() ...`
   - May need to investigate parser to ensure CALL can be a standalone statement

2. **Stub Implementations Still Active**: The algorithm implementations still return stub/dummy data:
   - Betweenness/Closeness/Eigenvector: Return dummy decimal scores
   - Louvain/LabelPropagation/SCC/UnionFind: Return `i % 3` as community ID
   - These are not real algorithm results, just placeholder data

3. **Missing Real Implementations**: Need to connect to `src/graph/builtin_algorithms.zig`:
   - PageRank: Has custom implementation (lines 3313-3426) - could be replaced with builtin version
   - Betweenness: Needs proper Brandes algorithm (available in builtin_algorithms.zig)
   - Closeness: Needs proper implementation (available in builtin_algorithms.zig)
   - Eigenvector: Needs power iteration (available in builtin_algorithms.zig)
   - Louvain: Needs modularity optimization (available in builtin_algorithms.zig)
   - Label Propagation: Needs proper implementation (available in builtin_algorithms.zig)

4. **Missing Helper Functions**:
   - `algo.asNode(nodeId)` - Convert node ID to node object (used in many tests)
   - Parameter extraction from function arguments (e.g., `{iterations: 20, dampingFactor: 0.85}`)

## Next Steps

### Priority 1: Parser Investigation (if needed)
- Test if CALL can be a standalone statement
- If not, update parser to allow CALL without preceding MATCH
- Check if the issue is with our query or with parser support

### Priority 2: Connect Real Implementations
- Create adapter between `graph_store.GraphStore` and `builtin_algorithms.BuiltinAlgorithms`
- Replace stub implementations with calls to real algorithms
- Implement parameter extraction from CALL arguments

### Priority 3: Add Helper Functions
- Implement `algo.asNode(nodeId)` to return node properties
- Add support for function parameters in CALL expressions

### Priority 4: Test & Verify
- Run geodetestlab graph algorithm tests
- Verify algorithm results are reasonable
- Check test pass rate improvement

## Expected Impact

Once all fixes are complete:
- **Before**: 26 graph algorithm tests failing (all misidentified as PageRank)
- **After Name Fix**: Algorithm routing works correctly
- **After Real Implementations**: Tests should pass with accurate algorithm results

## Files Modified

1. **src/execution.zig** (lines 3261-3510)
   - Added `buildMemberPath()` helper
   - Fixed algorithm name extraction
   - Updated algorithm name comparisons

## Related Documentation

- [Implementation Plan](GRAPH_ALGORITHMS_IMPLEMENTATION_PLAN.md) - Comprehensive plan for full implementation
- [Test Analysis](TEST_ANALYSIS_JANUARY_2025_EVENING.md) - Overall test failure analysis

---

*Document Created*: January 8, 2025 (Evening)
*Status*: Name extraction fixed, awaiting full algorithm implementation
*Next*: Investigate parser, connect real algorithms
