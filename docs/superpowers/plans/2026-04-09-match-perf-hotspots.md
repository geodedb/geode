# MATCH Performance Hotspot Fixes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the top 3 allocation-heavy hotspots in MATCH execution and improve label candidate selection, based on the findings in `docs/perf-review-geode-26-04-09.md`.

**Architecture:** Replace per-candidate heap allocations with stack-based fixed buffers in single-hop, variable-length, and multi-hop traversals. Replace linear label matching with sorted posting-list intersection. Cache pinned node pages in adapter label scans.

**Tech Stack:** Zig 0.15.1, geode graph database

---

## Scope

This plan covers the **immediate wins** (Ranks 1, 2, 5, 7) and one **near-term refactor** (Rank 4) from the performance review. Out of scope for this plan:

- Rank 3: Streaming variable-length path traversal (structural redesign — needs its own plan)
- Rank 6: Snapshot/read-view fix (UAF memory ownership — needs its own plan)
- Ranks 8-10: graph-storage layer fixes (separate repo — needs its own plan)

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/execution/match_operations.zig` | Modify lines 3855-4096 | Task 1: Stack-env for single-hop |
| `src/execution/match_operations.zig` | Modify lines 3625-3849 | Task 2: Stack-env for var-len paths |
| `src/execution/match_operations.zig` | Modify lines 4101-4435 | Task 3: Binding arena for multi-hop GROUP BY |
| `src/execution/match_operations.zig` | Modify lines 507-726 | Task 4: Label-driven candidates for MATCH+CALL |
| `src/graph_store.zig` | Modify lines 1310-1349 | Task 5: Posting-list intersection |
| `src/storage/graph_storage_adapter.zig` | Modify lines 1056-1095 | Task 6: Pinned-page caching |

---

### Task 1: Stack-env refactor for `executeSingleHopEdgeTraversal`

**Perf review rank:** 1 (Huge impact)
**Why:** This function allocates `env_names` + `env_values` on the heap for *every candidate edge*, then frees them if the candidate is rejected by WHERE/FILTER. Single-hop MATCH is the most common traversal pattern. The env size is always ≤3 (left_node_var, rel_var, right_node_var).

**Files:**

- Modify: `src/execution/match_operations.zig:3855-4096`

- [ ] **Step 1: Read the current function and confirm the allocation pattern**

Open `src/execution/match_operations.zig` and read lines 3855-4096. Confirm:

- Lines 3955-3978: `env_count` is computed from 3 optional vars, then `allocator.alloc([]const u8, env_count)` and `allocator.alloc(Value, env_count)` are called
- Lines 3989-4021: WHERE/FILTER evaluation frees the arrays on rejection
- Lines 4072-4093: Row creation happens after all filters pass
- The filtering chain (rel type, tenant, edge props, right labels, right props) runs BEFORE env allocation at lines 3892-3950

- [ ] **Step 2: Replace heap allocation with stack buffers**

In `executeSingleHopEdgeTraversal`, move the env buffer declarations OUTSIDE the edge loop (before the outgoing/incoming iteration) and change them from heap-allocated to stack-allocated:

Replace the per-candidate allocation block (lines ~3955-3978) with:

```zig
// Stack env buffers: single-hop binds at most 3 values (left, rel, right).
// Declared outside loop; rewritten each iteration (no alloc/free needed).
var env_names_buf: [3][]const u8 = undefined;
var env_values_buf: [3]Value = undefined;
```

Move these declarations to just before the edge iteration begins (before the outgoing edges loop). Then inside the loop, after all cheap filters pass (after right-node label/property checks around line 3950), replace the alloc block with:

```zig
var env_idx: usize = 0;
if (left_node_var) |v| {
    env_names_buf[env_idx] = v;
    env_values_buf[env_idx] = Value{ .Node = left_node };
    env_idx += 1;
}
if (rel_var) |v| {
    env_names_buf[env_idx] = v;
    env_values_buf[env_idx] = Value{ .Edge = edge };
    env_idx += 1;
}
if (right_node_var) |v| {
    env_names_buf[env_idx] = v;
    env_values_buf[env_idx] = Value{ .Node = right_node };
    env_idx += 1;
}

const env = Env{
    .names = env_names_buf[0..env_idx],
    .values = env_values_buf[0..env_idx],
    .param_names = param_names,
    .param_values = param_values,
    .allocator = allocator,
    .owned = false, // critical: stack buffers, no free needed
};
```

- [ ] **Step 3: Remove all per-candidate free calls**

Remove the `allocator.free(env_names)` and `allocator.free(env_values)` calls that currently appear in the WHERE/FILTER rejection paths (around lines 3997-3998 and 4014-4015) and at the end of the loop iteration. Since `.owned = false` and the buffers are on the stack, no cleanup is needed per-candidate.

- [ ] **Step 4: Adjust row creation to copy from stack env**

In the row creation block (lines 4072-4093), the current code uses `env_values` directly. Since those are now stack buffers that get overwritten each iteration, the row must copy the values it needs. The current pattern already allocates a new row:

For the `has_with` path (~line 4076):

```zig
const row = try allocator.alloc(Value, env_idx);
@memcpy(row, env_values_buf[0..env_idx]);
try rows.append(row);
```

For the `!has_with` RETURN-expression path (~line 4083), the existing `eval.evalExpr` calls already produce new Values — no change needed there, just make sure the `env` passed to `evalExpr` uses the stack slices.

- [ ] **Step 5: Handle the outgoing AND incoming edge iteration**

The function iterates outgoing edges then incoming edges (for undirected patterns). Confirm both loops use the same stack buffers and that the buffers are safely overwritten each iteration. The stack arrays are declared once; each iteration writes fresh values into them before creating the `Env`. No special handling needed since Zig stack arrays have no destructor.

- [ ] **Step 6: Run the existing test suite**

Run:

```bash
zig build test 2>&1 | tail -40
```

Expected: All existing tests pass. The behavior is identical — only the allocation strategy changed. If any test fails, check whether it was relying on `env.owned = true` for cleanup; those tests may need adjustment.

- [ ] **Step 7: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): replace per-candidate heap env with stack buffers in single-hop traversal

Eliminates O(candidates) allocator.alloc/free calls in executeSingleHopEdgeTraversal.
Env buffers are now [3][]const u8 / [3]Value on the stack, reused each iteration.
Addresses perf-review Rank 1 hotspot."
```

---

### Task 2: Stack-env refactor for `executeVariableLengthPathTraversal`

**Perf review rank:** 3 (partial — allocation reduction only; streaming is out of scope)
**Why:** Same pattern as Task 1 but with up to 4 env variables (left_node_var, right_node_var, rel_var, chain_path_var). The `rel_var` and `chain_path_var` cases allocate edge lists and Path structs that do require heap — but the env arrays themselves can be stack-based.

**Files:**

- Modify: `src/execution/match_operations.zig:3625-3849`

- [ ] **Step 1: Read the current function and identify allocations**

Read lines 3625-3849. Confirm:

- Lines 3722-3730: `env_count` computed from 4 optional vars, then heap-allocated
- Lines 3743-3758: `rel_var` case allocates `edge_values` slice (this MUST stay heap-allocated since it's variable-length per path)
- Lines 3759-3784: `chain_path_var` case allocates Path node/edge lists (MUST stay heap-allocated)
- Lines 3786-3793: Env created with `.owned = true`
- Lines 3805-3826: WHERE/FILTER frees env on rejection

- [ ] **Step 2: Replace env_names/env_values heap allocation with stack buffers**

Before the path iteration loop (before `for (paths.items)`), declare:

```zig
// Stack env buffers: var-len path binds at most 4 values.
var env_names_buf: [4][]const u8 = undefined;
var env_values_buf: [4]Value = undefined;
```

Inside the loop, replace the `allocator.alloc` calls for env_names/env_values with direct writes into the stack buffers. Keep the heap allocations for `edge_values` (when `rel_var` is present) and Path node/edge lists (when `chain_path_var` is present) — those are variable-sized and must remain on the heap.

```zig
var env_idx: usize = 0;
if (left_node_var) |v| {
    env_names_buf[env_idx] = v;
    env_values_buf[env_idx] = Value{ .Node = left_node };
    env_idx += 1;
}
if (right_node_var) |v| {
    env_names_buf[env_idx] = v;
    env_values_buf[env_idx] = Value{ .Node = right_node };
    env_idx += 1;
}
if (rel_var) |v| {
    // edge_values is variable-length per path — heap allocation stays
    var edge_values = try allocator.alloc(Value, path.edges.items.len);
    for (path.edges.items, 0..) |eid, j| {
        edge_values[j] = if (store.edges.getPtr(eid)) |ep| Value{ .Edge = ep } else Value{ .Null = {} };
    }
    env_names_buf[env_idx] = v;
    env_values_buf[env_idx] = Value{ .List = edge_values };
    env_idx += 1;
}
if (chain_path_var) |v| {
    // Path struct allocation stays on heap (variable node/edge counts)
    // ... existing path construction code ...
    env_names_buf[env_idx] = v;
    env_values_buf[env_idx] = Value{ .Path = .{ .nodes = path_nodes, .edges = path_edges } };
    env_idx += 1;
}

const env = Env{
    .names = env_names_buf[0..env_idx],
    .values = env_values_buf[0..env_idx],
    .param_names = param_names,
    .param_values = param_values,
    .allocator = allocator,
    .owned = false,
};
```

- [ ] **Step 3: Fix cleanup on WHERE/FILTER rejection**

When WHERE/FILTER rejects a path, the old code frees `env_names` and `env_values`. Remove those frees. BUT: if `rel_var` or `chain_path_var` were present, their heap-allocated inner data (edge_values, path node/edge slices) still needs cleanup. Add targeted cleanup:

```zig
if (!passes_where or !passes_filter) {
    // Free heap-allocated inner values (edge list, path struct) but NOT the env arrays
    if (rel_var != null) {
        // Free the edge_values slice stored in env_values_buf
        // (it was heap-allocated above)
        for (env_values_buf[0..env_idx]) |val| {
            if (val == .List) allocator.free(val.List);
        }
    }
    // Path struct cleanup if chain_path_var was set
    // ... free path_nodes, path_edges if allocated ...
    continue;
}
```

- [ ] **Step 4: Adjust row creation similarly to Task 1**

Copy env values into a new row slice when producing output, since the stack buffers are reused per path.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test 2>&1 | tail -40
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): stack-based env buffers for variable-length path traversal

Eliminates per-path env_names/env_values heap allocation in
executeVariableLengthPathTraversal. Inner values (edge lists, Path structs)
remain heap-allocated as they are variable-sized.
Addresses perf-review Rank 3 hotspot (allocation portion)."
```

---

### Task 3: Binding arena for `executeMultiHopGroupBy`

**Perf review rank:** 4 (Large impact on analytics queries)
**Why:** Each hop copies all previous bindings into new, larger arrays. With branching factor B and H hops, this produces O(B^H) binding copies, each allocating fresh arrays. An arena allocator amortizes this to bulk-free at the end.

**Files:**

- Modify: `src/execution/match_operations.zig:4101-4435`

- [ ] **Step 1: Read the current multi-hop binding pattern**

Read lines 4101-4435. Confirm:

- Lines 4119-4122: `MultiHopBinding` struct holds `env_names`/`env_values`
- Lines 4292-4314: Per-hop, allocates `new_env_names_mh` and `new_env_values_mh` with size = previous + new_var_count, copies old entries
- Lines 4318-4323: After each hop, frees all old bindings
- Lines 4366-4372: Grouping phase copies names/values again

- [ ] **Step 2: Add an arena allocator for binding arrays**

At the top of `executeMultiHopGroupBy`, create an arena that will own all binding arrays:

```zig
var arena_state = std.heap.ArenaAllocator.init(allocator);
defer arena_state.deinit();
const arena = arena_state.allocator();
```

- [ ] **Step 3: Replace binding allocations with arena allocations**

Change all `allocator.alloc` calls for `env_names_mh`, `env_values_mh`, `new_env_names_mh`, `new_env_values_mh`, `copy_names`, and `copy_values` to use `arena.alloc` instead. This means:

Lines ~4175 (initial binding): `arena.alloc([]const u8, 1)` and `arena.alloc(Value, 1)`
Lines ~4292-4300 (per-hop copy): `arena.alloc([]const u8, binding.env_names.len + new_var_count)` etc.
Lines ~4366-4372 (grouping copy): `arena.alloc([]const u8, binding.env_names.len)` etc.

- [ ] **Step 4: Remove all manual free calls for binding arrays**

Remove the `allocator.free(binding.env_names)` and `allocator.free(binding.env_values)` calls at lines 4318-4323 (after each hop) and similar cleanup in the defer blocks. The arena handles all cleanup via `arena_state.deinit()`.

Also remove the cleanup loop at the bottom of the function that frees remaining bindings.

- [ ] **Step 5: Keep the result row allocation on the original allocator**

The final row slices returned in `ExecutionResult` must outlive the arena. Ensure that `allocator.alloc(Value, ...)` (not `arena.alloc`) is used for the output rows and column names at lines 4392-4435.

- [ ] **Step 6: Run tests**

Run:

```bash
zig build test 2>&1 | tail -40
```

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): arena allocator for multi-hop GROUP BY binding arrays

Replaces per-hop alloc/copy/free cycle with arena-allocated binding arrays.
All binding memory is freed in bulk at function exit. Output rows still use
the caller's allocator to outlive the arena.
Addresses perf-review Rank 4 hotspot."
```

---

### Task 4: Label-driven candidates for `executeMatchCallQuery`

**Perf review rank:** 5 (Large where it triggers)
**Why:** `executeMatchCallQuery` iterates `read_store.nodes.iterator()` (full HashMap scan) and filters afterward. When labels are present, it should use `getNodesByLabels` instead.

**Files:**

- Modify: `src/execution/match_operations.zig:507-726`

- [ ] **Step 1: Read the current function**

Read lines 507-726. Confirm:

- Lines 545-605: Full node scan via `read_store.nodes.iterator()`
- Lines 556-570: Label check on `labels[0]` only (single label)
- The function extracts `labels` from the chain's left node pattern earlier

- [ ] **Step 2: Add label-index fast path before the iterator loop**

Before the `var node_iter = read_store.nodes.iterator()` line, add a fast path that uses the label index when labels are present:

```zig
// Fast path: use label index when labels are available
if (labels.len > 0) {
    var label_node_ids = try read_store.getNodesByLabels(allocator, filter_graph, labels, filter_tenant);
    defer label_node_ids.deinit(allocator);

    for (label_node_ids.items) |node_id| {
        const node = read_store.nodes.getPtr(node_id) orelse continue;

        // GAP-0510: RLS filter
        if (!passesRLSFilter(allocator, node.*)) continue;

        // Check properties
        var matches_props = true;
        if (props) |properties| {
            const empty_env = Env{
                .names = &.{},
                .values = &.{},
                .allocator = allocator,
            };
            for (properties) |prop| {
                if (node.properties.get(prop.key)) |node_prop_val| {
                    const node_val = propertyValueToValue(node_prop_val);
                    const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                    if (!valuesEqual(node_val, prop_val)) {
                        matches_props = false;
                        break;
                    }
                } else {
                    matches_props = false;
                    break;
                }
            }
        }

        if (matches_props) {
            if (node_var) |var_name| {
                try chain_match.put(var_name, node_id);
            }
            found = true;
            break;
        }
    }
} else {
    // Existing full scan path for label-less patterns
    var node_iter = read_store.nodes.iterator();
    // ... existing code ...
}
```

- [ ] **Step 3: Wrap the existing full-scan in the else branch**

Move the existing `node_iter` loop into the `else` block. This preserves correctness for queries without label constraints while avoiding the full scan when labels are available.

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test 2>&1 | tail -40
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): use label index for MATCH+CALL when labels available

Adds fast path in executeMatchCallQuery that uses getNodesByLabels
instead of full node scan when the pattern has label constraints.
Falls back to full scan only when no labels are specified.
Addresses perf-review Rank 5 hotspot."
```

---

### Task 5: Posting-list intersection for `getNodesByLabels`

**Perf review rank:** 2 (Huge for multi-label filters)
**Why:** Current implementation uses `labels[0]` as the seed and then scans each candidate node's `labels` array to check remaining labels. It doesn't pick the smallest posting list first, and the per-node label scan is O(k × m) where k = remaining labels and m = avg labels per node.

**Files:**

- Modify: `src/graph_store.zig:1310-1349`

- [ ] **Step 1: Read the current implementation**

Read lines 1310-1349 of `src/graph_store.zig`. Confirm:

- Line 1318: Seeds from `labels[0]` (first label, regardless of selectivity)
- Lines 1328-1341: Nested loop checking remaining labels per node via `node.labels`
- `getNodesByLabel` at lines 1295-1305 returns `list.items` (the posting list as a slice)

- [ ] **Step 2: Implement smallest-label-first selection**

Replace the body of `getNodesByLabels` with a selectivity-aware implementation:

```zig
pub fn getNodesByLabels(
    self: *const GraphStore,
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    labels: []const []const u8,
    tenant_id: ?[]const u8,
) !std.ArrayList(u64) {
    var result = std.ArrayList(u64).init(allocator);
    if (labels.len == 0) return result;

    // Single-label fast path: no intersection needed
    if (labels.len == 1) {
        const posting = self.getNodesByLabel(graph_name, labels[0]) orelse return result;
        try result.ensureTotalCapacity(posting.len);
        for (posting) |nid| {
            if (tenant_id) |tid| {
                const node = self.nodes.get(nid) orelse continue;
                if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
            }
            result.appendAssumeCapacity(nid);
        }
        return result;
    }

    // Gather posting lists and find the smallest
    var smallest_idx: usize = 0;
    var smallest_len: usize = std.math.maxInt(usize);
    var any_empty = false;

    for (labels, 0..) |label, i| {
        const posting = self.getNodesByLabel(graph_name, label);
        const len = if (posting) |p| p.len else 0;
        if (len == 0) {
            any_empty = true;
            break;
        }
        if (len < smallest_len) {
            smallest_len = len;
            smallest_idx = i;
        }
    }

    // If any label has zero nodes, intersection is empty
    if (any_empty) return result;

    // Use smallest posting list as seed
    const seed = self.getNodesByLabel(graph_name, labels[smallest_idx]).?;

    // For each candidate in the seed, verify it has ALL other labels
    try result.ensureTotalCapacity(seed.len);
    for (seed) |nid| {
        const node = self.nodes.get(nid) orelse continue;

        // Tenant filter
        if (tenant_id) |tid| {
            if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
        }

        // Check remaining labels via node.labels scan
        var has_all = true;
        for (labels, 0..) |required_label, i| {
            if (i == smallest_idx) continue; // already matched by seed
            var found = false;
            for (node.labels) |node_label| {
                if (std.mem.eql(u8, required_label, node_label)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                has_all = false;
                break;
            }
        }

        if (has_all) {
            result.appendAssumeCapacity(nid);
        }
    }

    return result;
}
```

This is a minimal change: same algorithm but picks the smallest posting list instead of always using `labels[0]`. A full sorted-merge intersection of posting lists would be even faster but requires sorted posting lists (which they currently are for the adapter path but not guaranteed for the in-memory GraphStore). The per-node label scan remains as fallback.

- [ ] **Step 3: Run tests**

Run:

```bash
zig build test 2>&1 | tail -40
```

Expected: All tests pass. Behavior is identical — only the candidate set shrinks.

- [ ] **Step 4: Commit**

```bash
git add src/graph_store.zig
git commit -m "perf(graph_store): smallest-label-first selection in getNodesByLabels

Selects the posting list with fewest entries as the intersection seed
instead of always using labels[0]. Prevents label-order-dependent
worst-case candidate explosion on multi-label MATCH patterns.
Addresses perf-review Rank 2 hotspot."
```

---

### Task 6: Pinned-page caching in adapter `getNodesByLabel`

**Perf review rank:** 7 (Big for label-heavy MATCH)
**Why:** The adapter's `getNodesByLabel` pins and unpins a node page for every single node ID in the posting list, even though IDs are sorted and adjacent IDs often share the same page. Caching the pinned page eliminates redundant pin/unpin calls.

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig:1056-1095`

- [ ] **Step 1: Read the current implementation**

Read lines 1056-1095 of `src/storage/graph_storage_adapter.zig`. Confirm:

- Line 1081: `buffer_pool.pin(.nodes, page_id)` called per node ID
- Lines 1084-1087: `buffer_pool.unpin(...)` called immediately after reading
- Node IDs from the label index are sorted, so page_id values are monotonically non-decreasing
- `npp` (nodes per page) and `hdr_size` are computed once before the loop

- [ ] **Step 2: Add pinned-page cache variables**

Before the `while (try iter.next())` loop, add:

```zig
var cached_page_id: ?u64 = null;
var cached_frame: ?@TypeOf(try mg.engine.node_store.buffer_pool.pin(.nodes, 0)) = null;
// Note: determine the frame type from the existing pin call at line 1081

defer {
    // Unpin the last cached frame on exit
    if (cached_frame) |frame| {
        mg.engine.node_store.buffer_pool.unpin(
            mg.engine.node_store.buffer_pool.frameIndex(frame),
            false,
        );
    }
}
```

The actual frame type can be inferred from the existing code. Look at what `buffer_pool.pin()` returns — it's likely a struct or pointer. Use the same type.

- [ ] **Step 3: Replace per-ID pin/unpin with cached pin**

Inside the loop, replace the pin/read/unpin sequence:

```zig
while (try iter.next()) |nid| {
    const page_id: u64 = nid / npp;

    if (!mg.engine.node_store.free_space.isAllocated(page_id)) continue;

    // Repin only when page changes
    if (cached_page_id == null or cached_page_id.? != page_id) {
        // Unpin previous page
        if (cached_frame) |frame| {
            mg.engine.node_store.buffer_pool.unpin(
                mg.engine.node_store.buffer_pool.frameIndex(frame),
                false,
            );
        }
        cached_frame = try mg.engine.node_store.buffer_pool.pin(.nodes, page_id);
        cached_page_id = page_id;
    }

    const slot: u32 = @intCast(nid % npp);
    const slot_offset = hdr_size + slot * @sizeOf(NodeRec);
    const data = cached_frame.?.dataSlice();
    const rec = std.mem.bytesToValue(NodeRec, data[slot_offset..][0..@sizeOf(NodeRec)]);

    if (node_mod.isDeleted(&rec)) continue;
    if (node_mod.isEmpty(&rec)) continue;

    try result.append(allocator, nid);
}
```

- [ ] **Step 4: Handle error paths**

The `defer` block handles cleanup on both success and error. Verify that if `buffer_pool.pin` fails (returns error), `cached_frame` remains at its previous value (or null) and the defer still works correctly. Since we assign `cached_frame` only after a successful pin, this is safe.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test 2>&1 | tail -40
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "perf(storage): cache pinned node pages in adapter label scan

Reuses the pinned node page frame across consecutive node IDs that share
the same page, reducing pin/unpin calls from O(node_count) to O(page_count).
Node IDs from label index are sorted, so page transitions are monotonic.
Addresses perf-review Rank 7 hotspot."
```

---

## Validation

After all 6 tasks are complete:

- [ ] **Run the full unit test suite**

```bash
zig build test 2>&1 | tail -40
```

Expected: All tests pass (exit code 0). The Zig 0.15.1 `f128` bug may cause `make build` to fail, but `zig build test` should pass.

- [ ] **Run the geodetestlab integration suite** (if available)

```bash
cd ../geode-test-harness && make test GEODE_BINARY=$(pwd)/../geode/zig-out/bin/geode
```

Expected: No regressions from baseline pass rate.

- [ ] **Manual smoke test with high-degree expansion**

Start geode and run queries that exercise the hotspots:

```sql
-- Multi-label selective MATCH (Task 5)
MATCH (n:Person:Employee) RETURN count(n) AS cnt

-- Single-hop expansion (Task 1)
MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN count(r) AS cnt

-- Variable-length path (Task 2)
MATCH (a:Person)-[*1..3]->(b:Person) RETURN count(*) AS cnt
```

---

## Future Work (Out of Scope)

These items from the perf review need their own plans:

1. **Streaming variable-length path traversal** (Rank 3 structural) — convert `expandVariableLengthPaths` to an iterator/generator with LIMIT pushdown
2. **Snapshot/read-view fix** (Rank 6) — fix the UAF in arena-backed snapshot so MATCH can use a read view instead of holding the global lock
3. **graph-storage checkpoint amplification** (Rank 9) — per-index dirty tracking, conditional snapshot writes
4. **graph-storage property-value index** (Rank 8) — real (key, value) → NodeId posting lists to replace adapter's rebuild-on-open index
5. **graph-storage property view decoding** (Rank 10) — zero-copy property access tied to pinned page lifetime
