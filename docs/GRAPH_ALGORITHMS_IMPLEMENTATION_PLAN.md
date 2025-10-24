# Graph Algorithms Implementation Plan
## January 8, 2025 (Evening)

## Executive Summary

**Status**: Graph algorithms ARE FULLY IMPLEMENTED but NOT CONNECTED to the CALL syntax
**Impact**: Connecting existing implementations will fix 26+ test failures immediately
**Complexity**: MEDIUM - Integration work, not new implementation

## Current Situation

### What We Have ✅

1. **Full Algorithm Implementations** (`src/graph/builtin_algorithms.zig`):
   - PageRank (proper power iteration with convergence)
   - Betweenness Centrality (Brandes algorithm)
   - Closeness Centrality (with Wasserman-Faust improvement)
   - Eigenvector Centrality (power iteration)
   - Louvain Community Detection (modularity optimization)
   - Label Propagation (community detection)
   - Shortest Path algorithms
   - All algorithms production-ready with proper implementations

2. **CALL Statement Infrastructure** (`src/execution.zig:3262`):
   - `executeCallStatement()` function exists
   - Parses CALL syntax correctly
   - Extracts procedure names (e.g., "algo.pageRank.stream")
   - Handles YIELD clauses
   - **BUT**: Uses STUB implementations instead of real ones

### The Problem ❌

`executeCallStatement` contains:
- Simple PageRank implementation (lines 3313-3426)
- STUB implementations for other algorithms (lines 3427-3491)
  - Returns dummy scores
  - Simple community assignments (i % 3)
  - Not using the sophisticated implementations

### Test Expectations

Tests use syntax like:
```gql
CALL algo.pageRank.stream({iterations: 20, dampingFactor: 0.85})
YIELD nodeId, score
RETURN algo.asNode(nodeId).name AS node, score
ORDER BY score DESC LIMIT 5
```

Expected algorithm names (from `geode_graph_algorithms.yml`):
- `algo.pageRank.stream` - PageRank centrality
- `algo.betweenness.stream` - Betweenness centrality
- `algo.closeness.stream` - Closeness centrality
- `algo.louvain.stream` - Louvain community detection
- `algo.labelPropagation.stream` - Label propagation
- `algo.unionFind.stream` - Connected components
- `algo.scc.stream` - Strongly connected components
- `algo.bfs.stream` - Breadth-first search
- `algo.dfs.stream` - Depth-first search
- `algo.shortestPath.dijkstra` - Weighted shortest path
- `algo.spanningTree.minimum` - Minimum spanning tree
- `algo.maxFlow` - Maximum flow
- `algo.similarity.jaccard` - Jaccard similarity
- `algo.similarity.cosine` - Cosine similarity
- `algo.asNode` - Convert node ID to node object

## Implementation Plan

### Phase 1: Create Graph Adapter Interface ✅ (Already Exists Partially)

**File**: `src/graph/builtin_algorithms.zig`
**Status**: Interface expects `GraphStorage` with methods:
- `getAllNodes() -> []u64`
- `getNodeCount() -> usize`
- `getNeighbors(node_id) -> []u64`
- `getIncomingEdges(node_id) -> []Edge`
- `getOutgoingEdges(node_id) -> []Edge`
- `getDegree(node_id) -> usize`
- `getEdgeWeight(from, to) -> f64`
- `getAllEdges() -> []Edge`

**Action Required**: Verify `graph_store` implements this interface

### Phase 2: Replace Stub Implementations

**File**: `src/execution.zig` (line 3262-3506)

**Changes Required**:

1. **Import builtin_algorithms**:
```zig
const builtin_algos = @import("graph/builtin_algorithms.zig");
```

2. **Create Graph Adapter**:
   - Wrap `graph_store.getGlobalStore()` to implement `GraphStorage` interface
   - Or verify existing store already implements it

3. **Replace Algorithm Implementations**:

#### Algorithm: PageRank
**Current**: Lines 3313-3426 (custom implementation)
**Replace with**: Call to `builtin_algos.BuiltinAlgorithms.pageRank()`
```zig
var algo = builtin_algos.BuiltinAlgorithms.init(allocator, &graph_adapter);
defer algo.deinit();

// Extract parameters from call_stmt.procedure.Call.args
const damping_factor = extractParamFloat(args, "dampingFactor", 0.85);
const max_iterations = extractParamU32(args, "iterations", 20);
const tolerance = extractParamFloat(args, "tolerance", 0.0001);

const ranks = try algo.pageRank(damping_factor, max_iterations, tolerance);
defer ranks.deinit();
```

#### Algorithm: Betweenness Centrality
**Current**: Lines 3427-3491 (stub returning dummy values)
**Replace with**: Call to `builtin_algos.BuiltinAlgorithms.betweennessCentrality()`
```zig
const normalized = extractParamBool(args, "normalized", true);
const sample_size = extractParamOptionalUsize(args, "sampleSize", null);

const centrality = try algo.betweennessCentrality(normalized, sample_size);
defer centrality.deinit();
```

#### Algorithm: Closeness Centrality
**Current**: Stub
**Replace with**: Call to `builtin_algos.BuiltinAlgorithms.closenessCentrality()`
```zig
const normalized = extractParamBool(args, "normalized", true);
const wf_improved = extractParamBool(args, "wfImproved", true);

const centrality = try algo.closenessCentrality(normalized, wf_improved);
defer centrality.deinit();
```

#### Algorithm: Eigenvector Centrality
**Current**: Stub
**Replace with**: Call to `builtin_algos.BuiltinAlgorithms.eigenvectorCentrality()`
```zig
const max_iterations = extractParamU32(args, "maxIterations", 100);
const tolerance = extractParamFloat(args, "tolerance", 0.0001);

const centrality = try algo.eigenvectorCentrality(max_iterations, tolerance);
// Returns []CentralityResult
```

#### Algorithm: Louvain Communities
**Current**: Stub (returns i % 3)
**Replace with**: Call to `builtin_algos.BuiltinAlgorithms.louvainCommunities()`
```zig
const resolution = extractParamFloat(args, "resolution", 1.0);
const seed = extractParamOptionalU64(args, "seed", null);

const communities = try algo.louvainCommunities(resolution, seed);
defer communities.deinit();
```

#### Algorithm: Label Propagation
**Current**: Stub
**Replace with**: Call to `builtin_algos.BuiltinAlgorithms.labelPropagationCommunities()`
```zig
const max_iterations = extractParamU32(args, "maxIterations", 100);

const labels = try algo.labelPropagationCommunities(max_iterations);
defer labels.deinit();
```

### Phase 3: Add Missing Algorithms

**Not yet in builtin_algorithms.zig**:
- `algo.unionFind.stream` - Union-Find (connected components)
- `algo.scc.stream` - Strongly connected components (Tarjan's or Kosaraju's)
- `algo.bfs.stream` - BFS traversal
- `algo.dfs.stream` - DFS traversal
- `algo.spanningTree.minimum` - Kruskal's or Prim's algorithm
- `algo.maxFlow` - Ford-Fulkerson or Edmonds-Karp
- `algo.similarity.jaccard` - Jaccard similarity
- `algo.similarity.cosine` - Cosine similarity

**Implementation Approach**:
1. Start with algorithms already implemented elsewhere:
   - Check `src/graph/path_algorithms.zig` for shortest paths
   - Check `src/graph/community_*.zig` for community detection variants

2. Implement missing algorithms in `builtin_algorithms.zig`:
   - Union-Find (simple, ~50 lines)
   - SCC (Tarjan's algorithm, ~100 lines)
   - BFS/DFS (simple traversal, ~50 lines each)
   - Spanning Tree (Kruskal's, ~100 lines)
   - Max Flow (Edmonds-Karp, ~150 lines)
   - Similarity metrics (simple, ~30 lines each)

### Phase 4: Parameter Extraction

**Add Helper Functions** (in `execution.zig`):
```zig
fn extractParamFloat(args: []Expr, name: []const u8, default: f64) f64 {
    // Extract named parameter from function call arguments
    // Format: {dampingFactor: 0.85} becomes map lookup
}

fn extractParamU32(args: []Expr, name: []const u8, default: u32) u32 {
    // Extract integer parameter
}

fn extractParamBool(args: []Expr, name: []const u8, default: bool) bool {
    // Extract boolean parameter
}

fn extractParamOptionalUsize(args: []Expr, name: []const u8, default: ?usize) ?usize {
    // Extract optional parameter
}
```

### Phase 5: Helper Function Implementation

**Add `algo.asNode` Helper**:
```zig
if (std.mem.eql(u8, proc_name, "algo.asNode")) {
    // Convert node ID to node object
    // Extract node ID from arguments
    // Return node properties as a record
}
```

## Implementation Order (Maximize Impact)

### Priority 1: High-Impact, Low-Effort (1-2 hours)
1. **Replace PageRank stub** with real implementation
2. **Replace Betweenness stub** with real implementation
3. **Replace Closeness stub** with real implementation
4. **Replace Eigenvector stub** with real implementation
5. **Replace Louvain stub** with real implementation
6. **Replace Label Propagation stub** with real implementation

**Expected Impact**: Fix ~15 tests immediately

### Priority 2: Medium-Impact, Medium-Effort (2-3 hours)
1. **Implement Union-Find** (connected components)
2. **Implement SCC** (strongly connected components)
3. **Implement BFS/DFS** traversals
4. **Add parameter extraction** helpers

**Expected Impact**: Fix ~8 additional tests

### Priority 3: Lower-Impact (3-4 hours)
1. **Implement Spanning Tree**
2. **Implement Max Flow**
3. **Implement Similarity metrics**
4. **Add `algo.asNode` helper**

**Expected Impact**: Fix ~3 additional tests

## Testing Strategy

### Unit Tests
- Test each algorithm independently with known graph structures
- Verify convergence for iterative algorithms
- Check edge cases (empty graphs, disconnected components)

### Integration Tests
Run geodetestlab suite:
```bash
python3 geodetestlab/runner.py specs/geode_graph_algorithms.yml
```

Expected results after each phase:
- **Phase 1-2**: 15/26 tests passing
- **Phase 3**: 23/26 tests passing
- **Phase 4**: 26/26 tests passing

### Verification Commands
```bash
# Test PageRank
./zig-out/bin/geode query "CALL algo.pageRank.stream() YIELD nodeId, score RETURN nodeId, score LIMIT 5"

# Test Betweenness
./zig-out/bin/geode query "CALL algo.betweenness.stream() YIELD nodeId, centrality RETURN nodeId, centrality LIMIT 5"

# Test Louvain
./zig-out/bin/geode query "CALL algo.louvain.stream() YIELD nodeId, community RETURN community, count(*) AS size GROUP BY community"
```

## Expected Outcome

**Before**:
- 26 graph algorithm tests failing
- Stub implementations returning dummy data
- Tests expect real algorithm results

**After**:
- 26 graph algorithm tests passing
- Production-ready algorithm implementations
- Proper parameter handling
- Accurate algorithm results

## Files to Modify

1. **src/execution.zig** (lines 3262-3506)
   - Replace stub implementations
   - Add parameter extraction helpers
   - Import builtin_algorithms

2. **src/graph/builtin_algorithms.zig**
   - Add missing algorithms (Union-Find, SCC, BFS, DFS, etc.)
   - Ensure GraphStorage interface is well-defined

3. **src/graph_store.zig** (if needed)
   - Verify interface compatibility with GraphStorage
   - Add missing methods if required

## Risk Assessment

**LOW RISK**:
- Existing algorithms are well-tested
- No changes to parser or core execution logic
- Only replacing stub code with real implementations

**MEDIUM RISK**:
- Parameter extraction needs careful implementation
- Graph adapter may need interface adjustments
- Memory management for algorithm results

**MITIGATION**:
- Test each algorithm individually before integration
- Use existing test suite for validation
- Ensure proper memory cleanup (defer statements)

## Timeline Estimate

**Total Time**: 6-9 hours
- Phase 1-2 (Replace stubs): 2-3 hours
- Phase 3 (New algorithms): 3-4 hours
- Phase 4 (Testing/debugging): 1-2 hours

**Can be done incrementally** - each algorithm replacement is independent

---

*Document Created*: January 8, 2025 (Evening)
*Status*: Ready for Implementation
*Priority*: HIGH (26 tests will pass)
*Complexity*: MEDIUM (integration, not new development)
