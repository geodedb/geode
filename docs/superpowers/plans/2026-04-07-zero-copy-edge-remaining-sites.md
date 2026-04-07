# Zero-Copy Edge Iteration: Remaining Call Sites

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the remaining 20 `getEdgesFrom`/`getEdgesTo` call sites (10 pairs) in `match_operations.zig` to use the zero-copy `getOutgoingEdgeIds`/`getIncomingEdgeIds` API, eliminating N+1 heap allocations in the MATCH hot path.

**Architecture:** Pure mechanical replacement — each pair follows the same pattern. Group by enclosing function, convert one function at a time, test after each.

**Tech Stack:** Zig 0.15.1, `zig build test` for verification.

---

## Conversion Pattern

Every call site follows this before/after:

**Before:**

```zig
const outgoing_edges = if (rel_dir == .right or rel_dir == .undirected)
    store.getEdgesFrom(allocator, node.id) else &[_]graph_store.Edge{};
defer allocator.free(outgoing_edges);
const incoming_edges = if (rel_dir == .left or rel_dir == .undirected)
    store.getEdgesTo(allocator, node.id) else &[_]graph_store.Edge{};
defer allocator.free(incoming_edges);

for (outgoing_edges) |edge| {
    // ... use edge.id, edge.to, edge.from, etc.
}
```

**After:**

```zig
const outgoing_edge_ids = if (rel_dir == .right or rel_dir == .undirected)
    store.getOutgoingEdgeIds(node.id) orelse &[_]u64{} else &[_]u64{};
const incoming_edge_ids = if (rel_dir == .left or rel_dir == .undirected)
    store.getIncomingEdgeIds(node.id) orelse &[_]u64{} else &[_]u64{};

for (outgoing_edge_ids) |edge_id| {
    const edge = store.edges.getPtr(edge_id) orelse continue;
    // ... use edge.id, edge.to, edge.from via edge.* (it's a pointer now)
}
```

**Key differences:**

- `getEdgesFrom` → `getOutgoingEdgeIds` (returns `?[]const u64`, not `[]Edge`)
- `getEdgesTo` → `getIncomingEdgeIds`
- Add `orelse &[_]u64{}` for the null case
- Remove `defer allocator.free(...)` (no allocation to free)
- Edge loop: `edge_id` is `u64`, look up `store.edges.getPtr(edge_id)` to get `*Edge`
- Where code uses `edge.field`, change to `edge.field` (pointer auto-derefs in Zig)
- Where code passes `edge` by value to a function expecting `Edge`, use `edge.*`
- Where code stores `edge` in a binding map expecting `*Edge`, use `edge` directly (it's already a pointer)

**IMPORTANT:** Some call sites use the char-based direction `'r'`/`'l'`/`'u'` and some use the enum-based `.right`/`.left`/`.undirected`. Match what the existing code uses.

---

### Task 1: Convert `executeSingleHopEdgeTraversal` (1 pair, lines 3843-3844)

**Files:**

- Modify: `src/execution/match_operations.zig`

- [ ] **Step 1: Read lines 3840-3900**

Find the `getEdgesFrom`/`getEdgesTo` pair in `executeSingleHopEdgeTraversal`. Read the surrounding edge iteration loop to understand how `edge` is used.

- [ ] **Step 2: Apply the conversion pattern**

Replace the pair. This function uses char-based direction (`'r'`/`'l'`/`'u'`). Remove the `defer free` lines. Update the loop to use `edge_id` + `getPtr`.

- [ ] **Step 3: Build and test**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 4: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(match): zero-copy edge iteration in executeSingleHopEdgeTraversal"
```

---

### Task 2: Convert `executeMultiHopGroupBy` (1 pair, lines 4216-4218)

**Files:**

- Modify: `src/execution/match_operations.zig`

- [ ] **Step 1: Read lines 4210-4260**

This pair may use a slightly different pattern (could be a single expression without the if/else guard). Read to understand.

- [ ] **Step 2: Apply the conversion pattern**

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "perf(match): zero-copy edge iteration in executeMultiHopGroupBy"
```

---

### Task 3: Convert `executeMatchQueryImpl` (2 pairs, lines 4584-4585, 5218-5219)

**Files:**

- Modify: `src/execution/match_operations.zig`

- [ ] **Step 1: Read around lines 4580-4600 and 5210-5230**

Two separate pairs in the main function. Convert both.

- [ ] **Step 2: Apply the conversion pattern to both pairs**

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "perf(match): zero-copy edge iteration in executeMatchQueryImpl (2 remaining sites)"
```

---

### Task 4: Convert `executeMatchWithOptionalPatterns` (2 pairs, lines 2275-2276, 2655-2656)

**Files:**

- Modify: `src/execution/match_operations.zig`

- [ ] **Step 1: Read around lines 2270-2290 and 2650-2670**

- [ ] **Step 2: Apply the conversion pattern to both pairs**

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "perf(match): zero-copy edge iteration in executeMatchWithOptionalPatterns"
```

---

### Task 5: Convert `executeMultiChainRelationshipMatch` (4 pairs, lines 1572-1829)

**Files:**

- Modify: `src/execution/match_operations.zig`

This is the largest batch — 4 pairs across the multi-chain function.

- [ ] **Step 1: Read lines 1570-1580, 1654-1660, 1765-1770, 1825-1830**

Find all 4 pairs. They may be in different sub-blocks (different hop iterations).

- [ ] **Step 2: Apply the conversion pattern to all 4 pairs**

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "perf(match): zero-copy edge iteration in executeMultiChainRelationshipMatch (4 sites)"
```

---

### Task 6: Verify and deprecate old API

- [ ] **Step 1: Search for any remaining `getEdgesFrom`/`getEdgesTo` calls**

```bash
grep -rn "getEdgesFrom\|getEdgesTo" src/execution/match_operations.zig | grep -v "// "
```

If zero results, all call sites are converted.

- [ ] **Step 2: Check other files**

```bash
grep -rn "store\.getEdgesFrom\|store\.getEdgesTo" src/ | grep -v "match_operations\|test\|// "
```

If there are call sites in other files (e.g., `crud_operations.zig`, `centrality_algorithms.zig`), note them for future conversion but don't convert in this plan.

- [ ] **Step 3: Add deprecation comment**

In `src/graph_store.zig`, add to `getEdgesFrom` and `getEdgesTo`:

```zig
/// Deprecated: prefer getOutgoingEdgeIds for zero-copy access.
/// This function allocates a new slice per call — use in tests only.
pub fn getEdgesFrom(...) ...
```

- [ ] **Step 4: Build, test, commit**

```bash
git commit -m "perf(store): deprecate getEdgesFrom/getEdgesTo in favor of zero-copy API"
```

---

## Execution Order

Tasks 1-5 are independent (each modifies different functions) but all touch the same file, so they must be sequential to avoid conflicts. The order is smallest-to-largest to build confidence:

1. Task 1 (1 pair) — warmup
2. Task 2 (1 pair) — verify pattern works in GROUP BY context
3. Task 3 (2 pairs) — main function
4. Task 4 (2 pairs) — optional patterns
5. Task 5 (4 pairs) — multi-chain (most complex)
6. Task 6 — cleanup and deprecation
