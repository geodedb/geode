# Streaming Variable-Length Path Traversal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert variable-length path expansion from full materialization to a streaming BFS iterator, enabling LIMIT pushdown and early termination.

**Architecture:** Replace `expandVariableLengthPaths` (returns `ArrayList(VariableLengthPath)`) with a `PathIterator` struct that yields one path at a time via `next()`. The caller loop in `executeVariableLengthPathTraversal` consumes paths incrementally and stops early when LIMIT is reached (only when no ORDER BY requires seeing all rows).

**Tech Stack:** Zig 0.15.1, geode graph database

---

## Background

**Perf review Rank 3** identified that `expandVariableLengthPaths` materializes ALL paths before `executeVariableLengthPathTraversal` begins filtering. On high-degree graphs this is worst-case exponential in path count and memory. The BFS queue itself is bounded (10K iterations, 5K queue items), but every qualifying path is cloned into `result_paths` before the caller can apply right-node filters, WHERE, or LIMIT.

**Current flow:**

1. `expandVariableLengthPathsWithMode` runs BFS, clones every qualifying path into `result_paths: ArrayList(VariableLengthPath)`
2. Returns the full list to `executeVariableLengthPathTraversal`
3. Caller iterates, filters (right labels/props, WHERE, FILTER), builds rows
4. LIMIT is applied post-hoc at lines 6356-6378, after ORDER BY

**New flow:**

1. `PathIterator` holds BFS state (queue, visited, bounds)
2. `next()` advances BFS until it finds the next qualifying path, returns it
3. `executeVariableLengthPathTraversal` consumes paths one at a time, filters, builds rows
4. When LIMIT is reached (and no ORDER BY), breaks out of the loop early
5. `PathIterator.deinit()` cleans up remaining BFS state

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/execution.zig` | Modify lines 1711-2018 | Tasks 1-2: PathIterator struct + next() |
| `src/execution/match_operations.zig` | Modify lines 3655-3891 | Task 3: Consume iterator instead of ArrayList |
| `src/execution/match_operations.zig` | Modify line 6532 | Task 4: Pass LIMIT to var-len traversal |

---

### Task 1: Create `PathIterator` struct

**Why:** The BFS state currently lives as local variables inside `expandVariableLengthPathsWithMode`. Moving them into a struct allows the caller to advance the BFS one result at a time instead of running it to completion.

**Files:**

- Modify: `src/execution.zig:1711-1753` (after `VariableLengthPath`, before `expandVariableLengthPaths`)

- [ ] **Step 1: Read the current BFS implementation**

Read `src/execution.zig` lines 1756-2018 (`expandVariableLengthPathsWithMode`). Note these state variables that must move into the struct:

- `result_paths` — remove entirely (caller handles results)
- `queue: ArrayList(struct { path: VariableLengthPath, depth: u32 })` — BFS frontier
- `visited_states: AutoHashMap(u64, u32)` — (node, depth) dedup
- `iteration_count: u64` — safety counter
- `min_len`, `max_len`, `rel_type`, `rel_direction`, `path_mode` — BFS config
- `start_node_id` — for simple path mode
- `allocator` — for path cloning

- [ ] **Step 2: Define the PathIterator struct**

Add after `VariableLengthPath` (after line 1733), before `expandVariableLengthPaths`:

```zig
/// BFS iterator that yields variable-length paths one at a time.
/// Holds BFS state (queue, visited set) and advances on each `next()` call.
/// Caller owns each yielded path and must deinit it.
pub const PathIterator = struct {
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    queue: std.ArrayList(struct { path: VariableLengthPath, depth: u32 }),
    visited_states: std.AutoHashMap(u64, u32),
    iteration_count: u64,
    min_len: u32,
    max_len: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
    path_mode: ast.PathMode,
    start_node_id: u64,
    /// Pending zero-length path (emitted before BFS starts when min_len == 0)
    pending_zero_path: bool,
    /// Set to true when BFS is exhausted or safety limits hit
    done: bool,

    const max_iterations: u64 = 10_000;
    const max_queue_size: usize = 5_000;

    pub fn init(
        allocator: std.mem.Allocator,
        store: *graph_store.GraphStore,
        start_node_id: u64,
        min_len: u32,
        max_len: ?u32,
        rel_type: ?[]const u8,
        rel_direction: u8,
        path_mode: ast.PathMode,
    ) !PathIterator {
        var queue = try std.ArrayList(struct { path: VariableLengthPath, depth: u32 }).initCapacity(allocator, 16);
        errdefer {
            for (queue.items) |*item| item.path.deinit(allocator);
            queue.deinit(allocator);
        }

        // Seed with start node
        var initial_path = VariableLengthPath.init(allocator);
        try initial_path.nodes.append(allocator, start_node_id);
        try queue.append(allocator, .{ .path = initial_path, .depth = 0 });

        return PathIterator{
            .allocator = allocator,
            .store = store,
            .queue = queue,
            .visited_states = std.AutoHashMap(u64, u32).init(allocator),
            .iteration_count = 0,
            .min_len = min_len,
            .max_len = max_len,
            .rel_type = rel_type,
            .rel_direction = rel_direction,
            .path_mode = path_mode,
            .start_node_id = start_node_id,
            .pending_zero_path = (min_len == 0),
            .done = false,
        };
    }

    pub fn deinit(self: *PathIterator) void {
        for (self.queue.items) |*item| {
            item.path.deinit(self.allocator);
        }
        self.queue.deinit(self.allocator);
        self.visited_states.deinit();
    }

    /// Returns the next qualifying path, or null when exhausted.
    /// Caller owns the returned VariableLengthPath and must call deinit on it.
    pub fn next(self: *PathIterator) !?VariableLengthPath {
        // Emit zero-length path first if min_len == 0
        if (self.pending_zero_path) {
            self.pending_zero_path = false;
            var zero_path = VariableLengthPath.init(self.allocator);
            try zero_path.nodes.append(self.allocator, self.start_node_id);
            return zero_path;
        }

        if (self.done) return null;

        while (self.queue.items.len > 0) {
            self.iteration_count += 1;
            if (self.iteration_count > max_iterations or self.queue.items.len > max_queue_size) {
                self.done = true;
                return null;
            }

            const current = self.queue.orderedRemove(0);
            var current_path = current.path;
            const depth = current.depth;

            // If at max_len, yield if meets min_len, else discard
            if (self.max_len) |max| {
                if (depth >= max) {
                    if (depth >= self.min_len) {
                        return current_path;
                    } else {
                        current_path.deinit(self.allocator);
                        continue;
                    }
                }
            }

            const last_node_id = current_path.nodes.items[current_path.nodes.items.len - 1];

            // Visited-state dedup
            const state_key = last_node_id + (@as(u64, depth) << 32);
            if (self.visited_states.get(state_key)) |_| {
                current_path.deinit(self.allocator);
                continue;
            }
            try self.visited_states.put(state_key, depth);

            // Expand edges and collect results to yield
            // We may produce 0..N result paths from this dequeue.
            // Yield the first one; buffer the rest in a temporary list.
            var yielded: ?VariableLengthPath = null;

            const outgoing_edges = if (self.rel_direction == 'r' or self.rel_direction == 'u')
                self.store.getEdgesFrom(self.allocator, last_node_id)
            else
                &[_]graph_store.Edge{};
            const incoming_edges = if (self.rel_direction == 'l' or self.rel_direction == 'u')
                self.store.getEdgesTo(self.allocator, last_node_id)
            else
                &[_]graph_store.Edge{};

            // Process both edge sets
            const edge_sets = [_]struct { edges: []const graph_store.Edge, use_from: bool }{
                .{ .edges = outgoing_edges, .use_from = false },
                .{ .edges = incoming_edges, .use_from = true },
            };

            for (edge_sets) |edge_set| {
                for (edge_set.edges) |edge| {
                    if (self.rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }

                    const next_node_id = if (edge_set.use_from) edge.from_id else edge.to_id;

                    // Path mode filtering
                    if (self.shouldSkipByPathMode(&current_path, next_node_id, edge.id)) continue;

                    var new_path = try current_path.clone(self.allocator);
                    try new_path.edges.append(self.allocator, edge.id);
                    try new_path.nodes.append(self.allocator, next_node_id);

                    const new_depth = depth + 1;
                    const meets_min = new_depth >= self.min_len;
                    const reached_max = self.max_len != null and new_depth >= self.max_len.?;

                    if (meets_min) {
                        if (yielded == null) {
                            // First result from this expansion — will be yielded
                            if (!reached_max) {
                                // Also need to continue expanding, so clone for queue
                                const queue_path = try new_path.clone(self.allocator);
                                try self.queue.append(self.allocator, .{ .path = queue_path, .depth = new_depth });
                            }
                            yielded = new_path;
                        } else {
                            // Additional results — clone for yield, maybe queue
                            const result_path = try new_path.clone(self.allocator);
                            if (!reached_max) {
                                try self.queue.append(self.allocator, .{ .path = new_path, .depth = new_depth });
                            } else {
                                new_path.deinit(self.allocator);
                            }
                            // Buffer this extra result by re-inserting at front of queue
                            // as a "depth >= max_len" item so it gets yielded next iteration
                            // Actually: simpler approach — push to a pending results list.
                            // For now, just append as a depth=max_len item:
                            const forced_depth = self.max_len orelse new_depth;
                            try self.queue.insert(self.allocator, 0, .{ .path = result_path, .depth = forced_depth });
                        }
                    } else {
                        // Doesn't meet min yet — continue expanding
                        if (!reached_max) {
                            try self.queue.append(self.allocator, .{ .path = new_path, .depth = new_depth });
                        } else {
                            new_path.deinit(self.allocator);
                        }
                    }
                }
            }

            current_path.deinit(self.allocator);

            if (yielded) |path| return path;
        }

        self.done = true;
        return null;
    }

    fn shouldSkipByPathMode(self: *const PathIterator, current_path: *const VariableLengthPath, next_node_id: u64, edge_id: u64) bool {
        switch (self.path_mode) {
            .walk => return false,
            .trail => {
                for (current_path.edges.items) |visited_edge| {
                    if (visited_edge == edge_id) return true;
                }
                return false;
            },
            .acyclic => {
                for (current_path.nodes.items) |visited_node| {
                    if (visited_node == next_node_id) return true;
                }
                return false;
            },
            .simple => {
                if (next_node_id == self.start_node_id) return false;
                for (current_path.nodes.items) |visited_node| {
                    if (visited_node == next_node_id) return true;
                }
                return false;
            },
        }
    }
};
```

- [ ] **Step 3: Run tests**

Run:

```bash
zig build test 2>&1 | tail -20
```

Expected: All tests pass. The struct is defined but not yet called — existing code still uses the old function.

- [ ] **Step 4: Commit**

```bash
git add src/execution.zig
git commit -m "feat(execution): add PathIterator struct for streaming BFS path expansion"
```

---

### Task 2: Add convenience constructor and keep backward compat

**Why:** The old `expandVariableLengthPaths` function is called from one site. We'll keep it as a backward-compat wrapper that drains the iterator into an ArrayList (same behavior as before). This lets us land the iterator without changing the caller yet.

**Files:**

- Modify: `src/execution.zig:1742-1753`

- [ ] **Step 1: Rewrite `expandVariableLengthPaths` to use PathIterator**

Replace lines 1742-2018 (both `expandVariableLengthPaths` and `expandVariableLengthPathsWithMode`) with:

```zig
// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=BFSExpansion; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
// CANARY: REQ=REQ-GQL-VARLEN-REVERSE-001; FEATURE="VariableLengthPaths"; ASPECT=ReverseTraversal; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
// CANARY: REQ=REQ-GQL-PATH-MODES-004; FEATURE="GQL Path Mode Execution"; ASPECT=PathExpansion; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2026-01-08
/// Backward-compat wrapper: materializes all paths from the iterator into an ArrayList.
/// New code should use PathIterator directly for streaming consumption.
pub fn expandVariableLengthPaths(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    start_node_id: u64,
    min_len: u32,
    max_len: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
) !std.ArrayList(VariableLengthPath) {
    return expandVariableLengthPathsWithMode(allocator, store, start_node_id, min_len, max_len, rel_type, rel_direction, .acyclic);
}

pub fn expandVariableLengthPathsWithMode(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    start_node_id: u64,
    min_len: u32,
    max_len: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
    path_mode: ast.PathMode,
) !std.ArrayList(VariableLengthPath) {
    var iter = try PathIterator.init(allocator, store, start_node_id, min_len, max_len, rel_type, rel_direction, path_mode);
    defer iter.deinit();

    var result_paths = try std.ArrayList(VariableLengthPath).initCapacity(allocator, 0);
    errdefer {
        for (result_paths.items) |*p| p.deinit(allocator);
        result_paths.deinit(allocator);
    }

    while (try iter.next()) |path| {
        try result_paths.append(allocator, path);
    }

    return result_paths;
}
```

- [ ] **Step 2: Run tests**

Run:

```bash
zig build test 2>&1 | tail -20
```

Expected: All tests pass. The backward-compat wrapper produces identical results to the old implementation. This is the critical correctness checkpoint — if any test fails here, the iterator has a bug.

- [ ] **Step 3: Commit**

```bash
git add src/execution.zig
git commit -m "refactor(execution): rewrite expandVariableLengthPaths to drain PathIterator

Backward-compatible: same function signatures, same return types.
The old BFS loop is now encapsulated in PathIterator.next()."
```

---

### Task 3: Convert `executeVariableLengthPathTraversal` to use PathIterator

**Why:** This is where the streaming win happens. Instead of materializing all paths first, we consume them one at a time from the iterator.

**Files:**

- Modify: `src/execution/match_operations.zig:3655-3891`

- [ ] **Step 1: Read the current function**

Read lines 3655-3891. The key change: replace the `expandVariableLengthPaths` call + `for (paths.items)` loop with a `PathIterator` + `while (iter.next())` loop.

- [ ] **Step 2: Add `limit` parameter to the function signature**

Add a `limit: ?usize` parameter at the end of the signature:

```zig
fn executeVariableLengthPathTraversal(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    left_node: *graph_store.Node,
    rows: *std.ArrayList([]Value),
    var_len_min: ?u32,
    var_len_max: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
    right_labels: [][]const u8,
    right_props: ?[]ast.Property,
    left_node_var: ?[]const u8,
    right_node_var: ?[]const u8,
    rel_var: ?[]const u8,
    chain_path_var: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    where_clause: ?ast.Expr,
    filter_clause: ?ast.Expr,
    has_with: bool,
    items: []const ast.ReturnItem,
    limit: ?usize,
) !void {
```

- [ ] **Step 3: Replace the ArrayList-based loop with PathIterator**

Replace lines 3682-3693 (the `expandVariableLengthPaths` call and `for` loop header) with:

```zig
    const min_len = var_len_min orelse 0;
    const max_len = var_len_max;

    var path_iter = try execution_mod.PathIterator.init(allocator, store, left_node.id, min_len, max_len, rel_type, rel_direction, .acyclic);
    defer path_iter.deinit();

    // Stack env buffers (already present from Task 2 of previous plan)
    var stack_env_names: [4][]const u8 = undefined;
    var stack_env_values: [4]Value = undefined;

    while (try path_iter.next()) |raw_path| {
        var path = raw_path; // mutable copy for deinit
        defer path.deinit(allocator);

        if (path.nodes.items.len == 0) continue;

        // LIMIT pushdown: stop early when enough rows collected
        // (only safe when no ORDER BY will reorder — caller controls this)
        if (limit) |lim| {
            if (rows.items.len >= lim) break;
        }
```

The rest of the loop body (right-node filtering, env building, WHERE/FILTER, row creation) stays the same but operates on `path` instead of indexing into `paths.items`.

- [ ] **Step 4: Remove the old paths ArrayList and defer**

Delete the old:

```zig
var paths = try expandVariableLengthPaths(allocator, store, left_node.id, min_len, max_len, rel_type, rel_direction);
defer {
    for (paths.items) |*path| {
        path.deinit(allocator);
    }
    paths.deinit(allocator);
}
```

The iterator's `defer path_iter.deinit()` handles cleanup of unconsumed BFS state.

- [ ] **Step 5: Fix the import for PathIterator**

At the top of `match_operations.zig`, ensure `execution_mod` or equivalent gives access to `PathIterator`. Check how other types from `execution.zig` are imported. Look at the existing import of `expandVariableLengthPaths` at the top of the file — `PathIterator` lives in the same module.

- [ ] **Step 6: Run tests**

Run:

```bash
zig build test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): stream var-len paths via PathIterator with LIMIT pushdown

Replaces full-materialization expandVariableLengthPaths call with
PathIterator.next() loop. Paths are consumed one at a time and
cleaned up immediately after filtering. When LIMIT is provided,
the loop breaks early once enough rows are collected."
```

---

### Task 4: Pass resolved LIMIT from call site

**Why:** The LIMIT value needs to flow from the query into `executeVariableLengthPathTraversal`. Currently LIMIT is resolved and applied post-hoc at lines 6356-6378. We pass it as a hint for early termination. The post-hoc LIMIT still applies (for ORDER BY correctness), but the hint prevents unbounded path expansion.

**Files:**

- Modify: `src/execution/match_operations.zig:6530-6536` (call site)

- [ ] **Step 1: Resolve LIMIT before the traversal call**

At the call site (line 6532), the query's limit is available via `q.limit` and `q.limit_param`. Add LIMIT resolution before the call:

```zig
if (var_len_min != null or var_len_max != null) {
    // Resolve LIMIT hint for early termination.
    // Only safe to push down when no ORDER BY will reorder results.
    const limit_hint: ?usize = if (q.order_by == null)
        resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
    else
        null;
    try executeVariableLengthPathTraversal(allocator, store, left_node, &rows, var_len_min, var_len_max, rel_type, rel_direction, right_labels, right_props, left_node_var, right_node_var, rel_var, chain_path_var, param_names, param_values, q.where_clause, q.filter_clause, has_with, items, limit_hint);
} else {
```

**Key detail:** `limit_hint` is `null` when ORDER BY is present, because ORDER BY needs all rows before truncating. Without ORDER BY, we can safely stop after collecting `limit` rows.

- [ ] **Step 2: Run tests**

Run:

```bash
zig build test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): pass LIMIT hint to var-len path traversal for early termination

Resolves LIMIT from query and passes it to executeVariableLengthPathTraversal.
Only pushed down when no ORDER BY is present (ORDER BY requires all rows).
Post-hoc LIMIT still applies for correctness."
```

---

## Validation

After all 4 tasks:

- [ ] **Run unit tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Run integration tests** (if available)

```bash
cd ../geode-test-harness && make test GEODE_BINARY=$(pwd)/../geode/zig-out/bin/geode
```

- [ ] **Smoke test with LIMIT on var-len paths**

```sql
-- Should terminate early (LIMIT pushdown)
MATCH (a:Person)-[*1..5]->(b:Person) RETURN a.name, b.name LIMIT 3

-- Should NOT terminate early (ORDER BY present)
MATCH (a:Person)-[*1..5]->(b:Person) RETURN a.name, b.name ORDER BY a.name LIMIT 3
```

---

## Out of Scope

These items were identified in the perf review but are separate efforts:

### Snapshot/Read-View Fix (Rank 6)

**Status:** The UAF is already fixed — `cloneNodesFrom` in `graph_store.zig:739-808` now deep-copies all PropertyValue.String slices via `copyPropertyValue`. The `skip_snapshot = true` at `match_operations.zig:4475` remains because snapshot creation is O(graph_size) in time and memory — worse than holding the lock for most workloads.

**What would fix it:** A lightweight read view that doesn't clone the entire graph. Options include:

- COW (copy-on-write) semantics on the GraphStore — only clone nodes/edges that are modified during query execution
- Using graph-storage's buffer pool directly for reads (page-level isolation via pin/unpin)
- Proper MVCC with version chains in the in-memory store

This needs its own brainstorming session — multiple valid approaches with different tradeoffs.

### graph-storage Fixes (Ranks 8-10)

**Status:** graph-storage is a separate remote repository (`gitlab.com/devnw/zig/graph-storage`), pinned at commit `7adde34` in `build.zig.zon`. Changes require:

1. Clone the graph-storage repo
2. Implement changes there (checkpoint dirty tracking, property-value index, view-based decoding)
3. Push and update the dependency hash in geode's `build.zig.zon`

Three specific fixes needed (separate plan in graph-storage repo):

- **Rank 8:** Persist adapter's exact property index (or make `rebuildExactNodePropertyIndex` lazy)
- **Rank 9:** Conditional/periodic derived index snapshots in `engine_persist.checkpoint`
- **Rank 10:** View-based property decoding to avoid string allocation during scans
