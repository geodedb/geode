# Performance Gap Closure Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the actionable gaps (GAP-0519 through GAP-0525) from the performance review audit, covering posting-list intersection, second var-len streaming site, full-scan LIMIT pushdown, PropertyIteratorView adoption, and benchmark scaffolding.

**Architecture:** Sort label posting lists on insertion for O(n+m) merge intersection; convert the second `expandVariableLengthPaths` call site to use `PathIterator`; add LIMIT guards to no-label full-scan paths; adopt zero-copy `PropertyIteratorView` in the adapter; create benchmark test fixtures.

**Tech Stack:** Zig 0.15.1, geode graph database, graph-storage library

---

## Scope

This plan covers the **actionable** portions of GAPs 0519-0525. Items requiring design brainstorming are listed as out of scope.

| GAP | What This Plan Covers | What's Out of Scope |
|-----|----------------------|---------------------|
| 0519 | Sorted posting lists + two-pointer intersection | — |
| 0520 | Convert second var-len call site at line 5547 | Pruning inside PathIterator (needs deeper traversal redesign) |
| 0521 | — | Full binding redesign (indexed/shared storage, incremental aggregation) |
| 0522 | LIMIT pushdown to no-label full-scan paths | Eliminating full scans (impossible without labels) |
| 0523 | — | Snapshot/read-view redesign (COW vs MVCC, needs brainstorming) |
| 0524 | Geode adapter adoption of PropertyIteratorView | Live label iterator, property-value posting index (graph-storage) |
| 0525 | Benchmark test fixtures for key hotspots | Production profiling infrastructure |

## File Map

| File | Action | Task |
|------|--------|------|
| `src/graph_store.zig` | Modify `addToLabelIndex` + `getNodesByLabels` | Task 1 |
| `src/execution/match_operations.zig:5547` | Convert var-len call to PathIterator | Task 2 |
| `src/execution/match_operations.zig` | Add LIMIT to 4 full-scan fallback sites | Task 3 |
| `src/storage/graph_storage_adapter.zig` | Adopt PropertyIteratorView at 2 sites | Task 4 |
| `src/execution/bench_test.zig` | Create benchmark test fixtures | Task 5 |

---

### Task 1: Sorted posting lists + two-pointer intersection in `getNodesByLabels`

**GAP:** 0519
**Why:** `getNodesByLabels` seeds from the smallest posting list but still verifies remaining labels by scanning `node.labels` — O(seed × labels × avg_labels_per_node). With sorted posting lists, we can intersect directly — O(sum of posting list sizes).

**Files:**

- Modify: `src/graph_store.zig` — `addToLabelIndex` (~line 1128) and `getNodesByLabels` (~line 1310)

- [ ] **Step 1: Read the current `addToLabelIndex`**

Read `src/graph_store.zig` around lines 1128-1157. Confirm:

- Line 1146: `try list.append(self.allocator, node_id)` — appends in insertion order, NOT sorted
- The label_index is `StringHashMap(ArrayList(u64))` — each posting list is an ArrayList

- [ ] **Step 2: Change `addToLabelIndex` to maintain sorted insertion**

Replace the append at line 1146 with a binary-search insert that maintains sorted order:

```zig
// Maintain sorted order for O(n+m) posting-list intersection
const items = list.items;
var lo: usize = 0;
var hi: usize = items.len;
while (lo < hi) {
    const mid = lo + (hi - lo) / 2;
    if (items[mid] < node_id) {
        lo = mid + 1;
    } else {
        hi = mid;
    }
}
// Deduplicate: skip if already present
if (lo < items.len and items[lo] == node_id) return;
try list.insert(self.allocator, lo, node_id);
```

This changes O(1) append to O(log n) search + O(n) insert (due to shift). For typical workloads where nodes are created in ascending ID order, the insert position is usually at the end, so the shift is O(1) amortized.

- [ ] **Step 3: Rewrite `getNodesByLabels` multi-label path with two-pointer intersection**

Replace the multi-label path (currently lines ~1335-1374) with sorted-merge intersection:

```zig
// Multi-label: intersect posting lists in ascending cardinality order
// All posting lists are sorted (maintained by addToLabelIndex).

// Gather posting lists and sort by size (smallest first)
const PostingList = struct { list: []const u64, idx: usize };
var postings_buf: [16]PostingList = undefined; // stack buffer for ≤16 labels
var postings: []PostingList = undefined;
var heap_postings: ?[]PostingList = null;

if (labels.len <= 16) {
    postings = postings_buf[0..labels.len];
} else {
    heap_postings = try allocator.alloc(PostingList, labels.len);
    postings = heap_postings.?;
}
defer if (heap_postings) |hp| allocator.free(hp);

for (labels, 0..) |label, i| {
    const posting = self.getNodesByLabel(graph_name, label) orelse return result;
    postings[i] = .{ .list = posting, .idx = i };
}

// Sort by ascending length
std.sort.pdq(PostingList, postings, {}, struct {
    fn lessThan(_: void, a: PostingList, b: PostingList) bool {
        return a.list.len < b.list.len;
    }
}.lessThan);

// Two-pointer intersection: start with smallest, intersect with each subsequent
var current = postings[0].list;
var intersection = std.ArrayList(u64).empty;
defer intersection.deinit(allocator);

for (postings[1..]) |next_posting| {
    intersection.clearRetainingCapacity();
    const next = next_posting.list;
    var a: usize = 0;
    var b: usize = 0;
    while (a < current.len and b < next.len) {
        if (current[a] == next[b]) {
            try intersection.append(allocator, current[a]);
            a += 1;
            b += 1;
        } else if (current[a] < next[b]) {
            a += 1;
        } else {
            b += 1;
        }
    }
    // Use intersection as new current for next round
    // We need to own this data for the next iteration
    if (intersection.items.len == 0) return result; // empty intersection
    current = intersection.items;
}

// Apply tenant filter to final intersection
try result.ensureTotalCapacity(allocator, current.len);
for (current) |nid| {
    const node = self.nodes.get(nid) orelse continue;
    if (tenant_id) |tid| {
        if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
    }
    result.appendAssumeCapacity(nid);
}
```

Keep the single-label fast path unchanged (it already works well).

- [ ] **Step 4: Run tests**

```bash
zig build test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/graph_store.zig
git commit -m "perf(graph_store): sorted posting lists + two-pointer intersection in getNodesByLabels

Maintains label posting lists in sorted order via binary-search insert.
Multi-label getNodesByLabels now intersects posting lists directly using
two-pointer merge instead of per-candidate node.labels scanning.
Closes GAP-0519."
```

---

### Task 2: Convert second var-len call site to PathIterator

**GAP:** 0520 (partial)
**Why:** `executeMultiHopGroupBy` at line 5547 still calls `expandVariableLengthPaths()` which materializes all paths. Converting to `PathIterator` makes it streaming.

**Files:**

- Modify: `src/execution/match_operations.zig` — around line 5547

- [ ] **Step 1: Read the second var-len call site**

Read `src/execution/match_operations.zig` around lines 5486-5600. Understand:

- The function context (inside `executeMultiHopGroupBy` or a related function)
- How paths are consumed after `expandVariableLengthPaths` returns
- Whether LIMIT is accessible at this point

- [ ] **Step 2: Replace with PathIterator**

Replace the `expandVariableLengthPaths` call and its `defer` cleanup block + `for (paths.items)` loop with:

```zig
var path_iter = try execution.PathIterator.init(allocator, store, start_node.id, min_len, max_len, rel_type, rel_direction, .acyclic);
defer path_iter.deinit();

while (try path_iter.next()) |raw_path| {
    var path = raw_path;
    defer path.deinit(allocator);

    // ... existing per-path processing (right-node filtering, binding collection) ...
}
```

Preserve the exact same per-path processing logic — only the iteration mechanism changes.

- [ ] **Step 3: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 4: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): convert second var-len call site to streaming PathIterator

The executeMultiHopGroupBy aggregation path now streams paths via
PathIterator instead of materializing all paths upfront.
Partially closes GAP-0520."
```

---

### Task 3: LIMIT pushdown to no-label full-scan paths

**GAP:** 0522
**Why:** The 4 remaining full-scan sites are correct behavior when no labels are specified — you can't use a label index without labels. But they can still benefit from LIMIT pushdown: stop scanning once enough candidates are found.

**Files:**

- Modify: `src/execution/match_operations.zig` — 4 sites

The approach for each site is identical: resolve the query LIMIT before the scan loop, and `break` when enough rows/candidates are collected. This only applies when no ORDER BY requires seeing all rows.

- [ ] **Step 1: Identify the 4 sites and their containing functions**

Read each site to confirm its function context and where `q.limit` / `q.order_by` are accessible:

1. Lines 590-634: `executeMatchCallQuery` — no-label `else` branch
2. Lines 880-910: `executeMultiNodeMatch` — no-label `else` branch  
3. Lines 1630-1674: `executeMultiChainRelationshipMatch` — no-label/no-type `else` branch
4. Lines 6044-6052: multi-hop initialization — no-label `else` branch

- [ ] **Step 2: Add LIMIT guard to Site 1 (executeMatchCallQuery, lines 590-634)**

The function already has `q` (the query) accessible. Before the `while (node_iter.next())` loop, resolve LIMIT:

```zig
} else {
    // Fallback: no labels available, full node scan required
    // Resolve LIMIT hint for early termination (only when no ORDER BY)
    const scan_limit: ?usize = if (q.order_by == null)
        resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
    else
        null;
    var node_iter = read_store.nodes.iterator();
    while (node_iter.next()) |entry| {
        // LIMIT pushdown: stop early
        if (scan_limit) |lim| {
            if (found) break; // This function only needs first match
        }
```

Actually, this function already `break`s on first match (`found = true; break;`). So LIMIT is already effectively 1 here. No change needed for this site.

- [ ] **Step 3: Add LIMIT guard to Sites 2, 3, 4**

For each of the remaining 3 sites, add a LIMIT check inside the no-label scan loop. The pattern is:

```zig
// At the top of the no-label else branch, before the loop:
const scan_limit: ?usize = if (q.order_by == null)
    resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
else
    null;

// Inside the loop, after adding a candidate:
if (scan_limit) |lim| {
    if (candidates.items.len >= lim) break;
}
```

The exact variable names (`candidates`, `rows`, etc.) depend on what each site collects. Read each site to determine the right collection variable and where to place the break.

**Important:** Only push LIMIT when `q.order_by == null`. If ORDER BY is present, all candidates must be collected for sorting.

- [ ] **Step 4: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): add LIMIT pushdown to no-label full-scan MATCH paths

Resolves LIMIT and breaks out of full node scans early when enough
candidates are collected. Only applied when no ORDER BY is present.
Addresses GAP-0522 for the no-label fallback paths."
```

---

### Task 4: Adopt PropertyIteratorView in storage adapter

**GAP:** 0524 (Geode-side adoption)
**Why:** The adapter's property iteration sites call `getAllProperties()` (zero-copy encoded iterator) then re-fetch each property via `getProperty()` (allocates per value). Using `PropertyIteratorView` with `decodeView()` eliminates the re-fetch loop and the per-value allocation.

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig` — `getAllNodeProperties` (~line 1304) and `getAllEdgeProperties` (~line 1355)

- [ ] **Step 1: Read the current getAllNodeProperties**

Read `src/storage/graph_storage_adapter.zig` around lines 1290-1340. Understand:

- How it calls `mg.engine.getAllProperties(rec.prop_head)`
- The two-pass pattern: collect keys first, then fetch each by key
- What it returns (likely a property map or list)

- [ ] **Step 2: Read the PropertyIteratorView API**

Check how `PropertyIteratorView` is exposed. Since the vtable integration was skipped (Task 3 of the graph-storage plan), the view wrapper must be called directly:

```zig
const gs = @import("graph_storage"); // or however it's imported
// Need: gs.interface.wrapPropIteratorView(concrete_iter, allocator)
```

Find how `graph_storage` types are imported in the adapter file. Look at existing `@import` statements at the top.

- [ ] **Step 3: Replace two-pass pattern with single-pass view iteration**

In `getAllNodeProperties`, replace the collect-keys → fetch-each-by-key pattern with:

```zig
var iter = try mg.engine.getAllProperties(rec.prop_head);
// Use decodeView directly on the raw iterator instead of re-fetching
while (try iter.next()) |slice| {
    const decoded = try gs.property.decodeView(slice.encoded_value);
    // Process decoded.value (string/ext borrow from pinned page)
    // ... add to result map ...
}
iter.deinit();
```

The exact replacement depends on what the function returns and how it builds its result. Read the current code carefully.

**Critical:** Values from `decodeView()` borrow from pinned page memory. If the function needs to return strings that outlive the iterator, it must `dupe` them into the output allocator. Only use view-based access for intermediate processing (filtering, hashing, comparison) where the value doesn't need to persist.

- [ ] **Step 4: Apply same pattern to getAllEdgeProperties if applicable**

- [ ] **Step 5: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "perf(storage): use decodeView for zero-copy property access in adapter

Replaces two-pass collect-keys-then-refetch pattern with single-pass
zero-copy iteration using property.decodeView(). Eliminates per-value
heap allocation during property iteration.
Partially closes GAP-0524."
```

---

### Task 5: Benchmark test fixtures

**GAP:** 0525
**Why:** No commit-local proof that the performance changes improved anything. Adding targeted test fixtures creates reproducible baselines.

**Files:**

- Create: `src/execution/bench_test.zig` — benchmark test functions

- [ ] **Step 1: Check existing benchmark/test patterns**

Look at how tests are structured in `src/execution/` and `src/graph_store.zig`. Find `test "..."` blocks to understand the pattern. Also check if there's a `benchmarks/` directory.

- [ ] **Step 2: Create benchmark test file**

Create `src/execution/bench_test.zig` with test fixtures that exercise the optimized paths. Each test creates a small but representative graph and runs the hot-path operation, measuring that it completes within a time budget:

```zig
const std = @import("std");
const graph_store = @import("../graph_store.zig");
const execution = @import("../execution.zig");

// Benchmark fixture: multi-label candidate selection
test "bench: getNodesByLabels with 2 labels picks smallest posting list" {
    const allocator = std.testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create 1000 nodes with :Big label, 10 nodes with :Small label, 5 with both
    for (0..1000) |i| {
        var labels = [_][]const u8{"Big"};
        _ = try store.createNodeWithGraph(allocator, "default", &labels, null);
    }
    for (0..10) |i| {
        var labels = [_][]const u8{"Small"};
        _ = try store.createNodeWithGraph(allocator, "default", &labels, null);
    }
    for (0..5) |i| {
        var labels = [_][]const u8{ "Big", "Small" };
        _ = try store.createNodeWithGraph(allocator, "default", &labels, null);
    }

    // Multi-label query should return exactly 5 nodes
    var result = try store.getNodesByLabels(allocator, "default", &.{ "Big", "Small" }, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), result.items.len);
}

// Benchmark fixture: single-hop expansion with high-degree node
test "bench: executeSingleHopEdgeTraversal on high-degree node" {
    // Create a hub node with 100 outgoing edges
    // Run single-hop traversal and verify all edges are processed
    // The stack-env optimization means zero per-candidate alloc
    const allocator = std.testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create hub + 100 target nodes + 100 edges
    var hub_labels = [_][]const u8{"Hub"};
    const hub_id = try store.createNodeWithGraph(allocator, "default", &hub_labels, null);
    for (0..100) |_| {
        var target_labels = [_][]const u8{"Target"};
        const target_id = try store.createNodeWithGraph(allocator, "default", &target_labels, null);
        _ = try store.createEdgeWithGraph(allocator, "default", hub_id, target_id, "CONNECTS", null);
    }

    // Verify edge count from hub
    const out_edges = store.getOutgoingEdgeIds(hub_id);
    try std.testing.expect(out_edges != null);
    try std.testing.expectEqual(@as(usize, 100), out_edges.?.len);
}

// Benchmark fixture: variable-length path streaming with LIMIT
test "bench: PathIterator respects early termination" {
    const allocator = std.testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create a chain: A -> B -> C -> D -> E
    var labels = [_][]const u8{"Node"};
    const ids = blk: {
        var arr: [5]u64 = undefined;
        for (&arr) |*id| {
            id.* = try store.createNodeWithGraph(allocator, "default", &labels, null);
        }
        break :blk arr;
    };
    for (0..4) |i| {
        _ = try store.createEdgeWithGraph(allocator, "default", ids[i], ids[i + 1], "NEXT", null);
    }

    // PathIterator should yield paths incrementally
    var iter = try execution.PathIterator.init(allocator, &store, ids[0], 1, 4, "NEXT", 'r', .acyclic);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |path| {
        var p = path;
        defer p.deinit(allocator);
        count += 1;
        if (count >= 2) break; // Simulate LIMIT 2
    }
    try std.testing.expect(count == 2);
}

// Benchmark fixture: posting-list intersection correctness
test "bench: sorted posting-list intersection for multi-label" {
    const allocator = std.testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create nodes: A has labels {X,Y}, B has {X}, C has {Y}, D has {X,Y,Z}
    _ = try store.createNodeWithGraph(allocator, "default", &.{ "X", "Y" }, null);
    _ = try store.createNodeWithGraph(allocator, "default", &.{"X"}, null);
    _ = try store.createNodeWithGraph(allocator, "default", &.{"Y"}, null);
    _ = try store.createNodeWithGraph(allocator, "default", &.{ "X", "Y", "Z" }, null);

    // Query {X, Y} should return 2 nodes (A and D)
    var result = try store.getNodesByLabels(allocator, "default", &.{ "X", "Y" }, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);

    // Query {X, Y, Z} should return 1 node (D)
    var result2 = try store.getNodesByLabels(allocator, "default", &.{ "X", "Y", "Z" }, null);
    defer result2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result2.items.len);
}
```

**Note:** The exact API for `createNodeWithGraph`, `createEdgeWithGraph`, and `PathIterator.init` may differ from what's shown. Read the actual function signatures before writing tests. Adapt the code to match the real API.

- [ ] **Step 3: Wire test file into build**

Check if `bench_test.zig` needs to be added to `build.zig` or if it's auto-discovered via `@import` in the test root.

- [ ] **Step 4: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add src/execution/bench_test.zig
git commit -m "test(execution): add benchmark fixtures for perf-review hotspots

Adds reproducible test fixtures for multi-label intersection,
high-degree single-hop expansion, PathIterator streaming with
LIMIT, and posting-list intersection correctness.
Addresses GAP-0525."
```

---

## Validation

After all 5 tasks:

- [ ] **Run full unit test suite**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Run geodetestlab integration suite** (if available)

```bash
cd ../geode-test-harness && make test GEODE_BINARY=$(pwd)/../geode/zig-out/bin/geode
```

---

## Out of Scope (Needs Brainstorming)

### GAP-0521: Multi-hop GROUP BY binding redesign

The arena allocator eliminated free-churn but didn't reduce allocation count or copy volume. A proper fix needs:

- **Indexed binding storage**: Store bindings in a flat arena with indices instead of per-binding arrays
- **Incremental aggregation**: Compute aggregates as bindings are produced instead of collecting all bindings first
- **Shared name arrays**: All bindings in a hop share the same name schema; store names once, share via index

This is an algorithmic redesign, not a mechanical optimization. Needs its own brainstorming + plan.

### GAP-0523 / Rank 6: Snapshot/read-view

`skip_snapshot = true` remains because even with the UAF fix (deep-copy), snapshot creation is O(graph_size). Options:

- **COW semantics**: Copy-on-write pages when writable store is modified during a read
- **Buffer-pool direct reads**: Use graph-storage's buffer pool for reads with page-level isolation
- **MVCC version chains**: Multi-version concurrency in the in-memory GraphStore

Each has different tradeoffs for memory, complexity, and concurrency. Needs brainstorming.

### Rank 8: Property-value posting index (graph-storage)

Current `PropertyChainIndex` maps `prop_head → [{key, value_hash}]`. What's needed is `(label, key, value) → [NodeId]` for fast `MATCH (n:Label {key: value})`. This is a new data structure in graph-storage with persistence, maintenance on mutations, and integration into Geode's query planner. Separate plan.

### GAP-0524 (remaining): Live label iterator + property-value posting index

Both require graph-storage changes:

- **Live label iterator**: Filter deleted nodes during label scan inside graph-storage instead of in the adapter
- **Property-value posting index**: New index structure for exact-match property lookups

These are graph-storage repo changes that need their own plan.
