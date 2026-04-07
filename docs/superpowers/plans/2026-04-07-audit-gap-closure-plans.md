# Audit Gap Closure Implementation Plans

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 5 remaining audit findings from the 2026-04-07 full codebase audit, each as an independent plan.

**Architecture:** Each finding is a self-contained project. Plans are ordered by complexity (simplest first). Each produces working, tested code independently.

**Tech Stack:** Zig 0.15.1, `zig build test` for verification.

---

## Plan A: MCP `--no-auth` Release Guard

**Complexity:** 15 minutes | **Files:** 1 | **Risk:** Low

### Task A1: Block MCP `--no-auth` in Release Builds

**Files:**

- Modify: `src/cli/cli_dispatcher.zig:947-948`

- [ ] **Step 1: Read the current `--no-auth` handling**

Read `src/cli/cli_dispatcher.zig` around lines 928-978 to understand the `handleMcpCommand` flow.

- [ ] **Step 2: Add release-build guard**

After `no_auth = true` is set (line 948), add:

```zig
} else if (std.mem.eql(u8, arg, "--no-auth")) {
    if (@import("builtin").mode != .Debug) {
        std.debug.print("Error: --no-auth is only available in debug builds. Use --token for production.\n", .{});
        std.process.exit(1);
    }
    no_auth = true;
```

- [ ] **Step 3: Build and verify**

Run: `zig build 2>&1 | head -5; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 4: Commit**

```bash
git add src/cli/cli_dispatcher.zig
git commit -m "fix(security): block MCP --no-auth flag in release builds"
```

---

## Plan B: Catch {} Systematic Triage (Top 6 Files)

**Complexity:** 2-3 hours | **Files:** 6 | **Risk:** Medium

The 673 `catch {}` sites fall into categories:

- **I/O output** (stderr/stdout writes): Safe to keep — output failure is non-critical
- **Transaction undo log**: Should propagate — silent undo failure means broken rollback
- **QUIC transport**: Mixed — poll/close can suppress, stream I/O should log

### Task B1: Fix crud_operations.zig Transaction Undo Log (16 sites)

**Files:**

- Modify: `src/execution/crud_operations.zig`

- [ ] **Step 1: Read the file and find all `catch {}`**

Search for `catch {}` or `catch{}` in `src/execution/crud_operations.zig`. These are all in transaction undo log calls: `undo_log.logCreateNode(...)`, `undo_log.logCreateEdge(...)`, etc.

- [ ] **Step 2: Replace undo log catch {} with logging**

For each `undo_log.log*(...) catch {}`, replace with:

```zig
undo_log.logCreateNode(new_id, current_graph) catch |err| {
    log.err("undo log failed: {}", .{@errorName(err)});
};
```

Ensure there's a scoped logger at the top of the file: `const log = std.log.scoped(.crud_operations);` or similar. If one exists, use it. If not, add it.

- [ ] **Step 3: Build and run tests**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 4: Commit**

```bash
git add src/execution/crud_operations.zig
git commit -m "fix(execution): log transaction undo errors instead of catch {}"
```

### Task B2: Fix transport/quic.zig Critical Path (16 sites)

**Files:**

- Modify: `src/transport/quic.zig`

- [ ] **Step 1: Read and categorize each catch {} site**

Read `src/transport/quic.zig` and find all `catch {}`. Categorize each:

- **Keep (safe):** poll condvar timedWait, stream.close(), connection destroy — these are best-effort cleanup
- **Fix (log):** certificate path creation, stream read errors in handler paths
- **Fix (propagate):** anything on the write path that affects data delivery

- [ ] **Step 2: Fix the "log" category**

For certificate/directory creation: replace `catch {}` with `catch |err| { log.warn("...", .{@errorName(err)}); }`

For I/O operations that silently discard: add `log.warn` or `log.err`.

Leave best-effort cleanup calls (close, destroy, poll condvar) as `catch {}` but add a comment: `// Best-effort cleanup — failure is non-critical`

- [ ] **Step 3: Build and run tests**

- [ ] **Step 4: Commit**

```bash
git add src/transport/quic.zig
git commit -m "fix(transport): log QUIC transport errors instead of catch {} on critical paths"
```

### Task B3: Document Safe catch {} Sites in Output Formatting

**Files:**

- Modify: `src/cli/main.zig` (58 sites)
- Modify: `src/cli/transport_response.zig` (28 sites)
- Modify: `src/client/repl/repl_dispatch.zig` (34 sites)
- Modify: `src/execution/result_utils.zig` (44 sites)

These files use `catch {}` for stdout/stderr writes during output formatting. Failure to write output is non-critical — the query still succeeds, the result just isn't displayed.

- [ ] **Step 1: Add a block comment at the top of each file**

In each of the 4 files, add near the top (after imports):

```zig
// NOTE: This file uses `catch {}` for stdout/stderr I/O operations.
// Output write failures are non-critical — the query result is correct
// even if display fails. Propagating these errors would abort output
// mid-render, which is worse than partial output. See FULL_AUDIT_2026_04_07.md.
```

- [ ] **Step 2: Commit**

```bash
git add src/cli/main.zig src/cli/transport_response.zig src/client/repl/repl_dispatch.zig src/execution/result_utils.zig
git commit -m "docs: document intentional catch {} in output formatting files"
```

---

## Plan C: executeMatchQueryImpl Decomposition

**Complexity:** 2-3 days | **Files:** 2-4 new + 1 modify | **Risk:** High

The 3,469-line function has 5 natural split points identified in the research.

### Task C1: Extract `applyOrderByAndDistinct` Helper

**Files:**

- Modify: `src/execution/match_operations.zig`

This is the simplest extraction — the final 30 lines of the function that apply ORDER BY and DISTINCT.

- [ ] **Step 1: Read the end of executeMatchQueryImpl**

Read `src/execution/match_operations.zig` from line ~7000 to the end of the function (~7031). Identify the ORDER BY sort and DISTINCT dedup blocks.

- [ ] **Step 2: Extract helper function**

Create a new function directly above `executeMatchQueryImpl`:

```zig
fn applyOrderByAndDistinct(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
) !void {
    // Move the ORDER BY and DISTINCT code here
}
```

- [ ] **Step 3: Replace inline code with helper call**

In `executeMatchQueryImpl`, replace the ORDER BY / DISTINCT block with:

```zig
try applyOrderByAndDistinct(allocator, &result, q, param_names.items, param_values.items);
```

- [ ] **Step 4: Run tests**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(match): extract applyOrderByAndDistinct from executeMatchQueryImpl"
```

### Task C2: Extract `executeSimpleRelationshipMatch` (lines 4140-4830)

**Files:**

- Modify: `src/execution/match_operations.zig`

- [ ] **Step 1: Read lines 4140-4830**

Identify the parameters needed from the enclosing scope. These typically include: allocator, store, q, param_names, param_values, filter_graph, filter_tenant, and any hop/chain state.

- [ ] **Step 2: Create function signature**

```zig
fn executeSimpleRelationshipMatch(
    allocator: std.mem.Allocator,
    store: *const GraphStore,
    q: ast.Query,
    hop: ast.Hop,
    left_nodes: []*graph_store.Node,
    param_names: []const []const u8,
    param_values: []const Value,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !ExecutionResult {
    // Move lines 4140-4830 here
}
```

Adapt parameter list based on actual variables captured from the enclosing scope.

- [ ] **Step 3: Replace in executeMatchQueryImpl**

- [ ] **Step 4: Run tests, commit**

### Task C3: Extract `executeVariableLengthPath` (lines 5100-6500)

Same pattern as C2. This is the largest extracted block (~1400 lines) and handles variable-length path traversal (`*1..5` patterns).

### Task C4: Extract `executeMultiHopGroupBy` (lines 3644-3700)

Smallest extraction (~56 lines) but handles the GROUP BY dispatch for multi-hop patterns.

### Task C5: Integration Test Verification

- [ ] **Step 1: Run full geodetestlab suite**

```bash
cd ../geode-test-harness && make test GEODE_BINARY=../geode/zig-out/bin/geode
```

Verify no regressions in MATCH query behavior.

---

## Plan D: RLS Expression Engine Wiring

**Complexity:** 2-3 days | **Files:** 4 modify | **Risk:** High

### Task D1: Initialize Global Expression RLS Engine

**Files:**

- Modify: `src/server/main.zig`

- [ ] **Step 1: Find where RLS filter engine is initialized**

Search for `setGlobalRLSFilterEngine` or `RLSFilterEngine` initialization in `src/server/main.zig` or `src/server/server_init.zig`.

- [ ] **Step 2: Add expression engine initialization alongside it**

```zig
// After existing RLS filter engine init:
const rls_types = @import("rls_types");
const rls_core = @import("rls");
var expr_engine = try rls_core.RLSEngine.init(allocator);
rls_types.setGlobalExprRLSEngine(@ptrCast(&expr_engine));
```

- [ ] **Step 3: Build and verify**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(rls): initialize global expression RLS engine at server startup"
```

### Task D2: Wire Expression Check into passesRLSFilter

**Files:**

- Modify: `src/execution/match_operations.zig:91-98`

- [ ] **Step 1: Read current passesRLSFilter**

The function currently only checks label-deny. Add property expression evaluation after the label check.

- [ ] **Step 2: Add expression evaluation**

```zig
fn passesRLSFilter(node: graph_store.Node) bool {
    const ctx = execution.getActiveContext() orelse return true;
    const username = ctx.user orelse return true;
    const graph_name = if (ctx.session_state) |s| (s.graph orelse "default") else "default";

    // Existing: Label-deny check
    const filter_engine = rls_types.getGlobalRLSFilterEngine() orelse return true;
    for (node.labels) |label| {
        if (filter_engine.isLabelDenied(graph_name, label, username)) return false;
    }

    // NEW: Expression-based property check
    const expr_engine_ptr = rls_types.getGlobalExprRLSEngine() orelse return true;
    const expr_engine: *rls_core.RLSEngine = @ptrCast(@alignCast(expr_engine_ptr));
    // Convert node properties to RLS row format
    const rls_row = rls_value_bridge.nodePropertiesToRLSRow(
        // Need allocator — use ctx or a thread-local arena
    ) catch return true; // Fail-open on OOM (documented choice)
    defer rls_row.deinit();

    return expr_engine.checkRowAccess(rls_row, username, graph_name);
}
```

**NOTE:** This requires careful design around allocator availability in `passesRLSFilter` (currently takes no allocator). Options: (a) add allocator parameter and update all 20+ call sites, or (b) use a thread-local arena.

- [ ] **Step 3: Update all passesRLSFilter call sites**

If option (a), update every `passesRLSFilter(node.*)` call to `passesRLSFilter(allocator, node.*)`.

- [ ] **Step 4: Write test**

```zig
test "RLS expression filter denies node with restricted property" {
    // Create a node with property status="classified"
    // Create RLS policy denying access when status="classified"
    // Verify passesRLSFilter returns false
}
```

- [ ] **Step 5: Build, test, commit**

### Task D3: Wire Expression Check for Edges

Same pattern as D2, but for edge traversal paths.

### Task D4: Integration Test with Policy CRUD

End-to-end test: create RLS policy via CALL procedure, query data, verify filtered results.

---

## Plan E: Batch Edge Fetching (N+1 Elimination)

**Complexity:** 1-2 days | **Files:** 2 modify | **Risk:** Medium

### Task E1: Add Zero-Copy Edge Iteration API

**Files:**

- Modify: `src/graph_store.zig`

Instead of a batch API that still allocates, add a zero-copy iterator that references the adjacency list directly:

- [ ] **Step 1: Read existing getEdgesFrom/getEdgesTo**

Read `src/graph_store.zig` around lines 2624-2646. Note the allocation pattern.

- [ ] **Step 2: Add getOutgoingEdgeIds / getIncomingEdgeIds**

```zig
/// Return the edge ID list for a node's outgoing edges WITHOUT allocation.
/// Returns null if the node has no outgoing edges.
/// The returned slice is valid as long as the graph store is not mutated.
pub fn getOutgoingEdgeIds(self: *const GraphStore, node_id: u64) ?[]const u64 {
    const list = self.outgoing_edges.get(node_id) orelse return null;
    return list.items;
}

pub fn getIncomingEdgeIds(self: *const GraphStore, node_id: u64) ?[]const u64 {
    const list = self.incoming_edges.get(node_id) orelse return null;
    return list.items;
}
```

- [ ] **Step 3: Write test**

```zig
test "getOutgoingEdgeIds returns edge list without allocation" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    // Create nodes and edges
    // Verify getOutgoingEdgeIds returns correct IDs
    // Verify no allocations occurred (testing allocator tracks this)
}
```

- [ ] **Step 4: Build, test, commit**

```bash
git commit -m "perf(store): add zero-copy edge ID lookup (getOutgoingEdgeIds/getIncomingEdgeIds)"
```

### Task E2: Use Zero-Copy API in Match Hot Path

**Files:**

- Modify: `src/execution/match_operations.zig`

- [ ] **Step 1: Identify a single call site to convert**

Start with the standard single-hop match (around line 6169). Replace:

```zig
const outgoing_edges_std = store.getEdgesFrom(allocator, left_node.id);
defer allocator.free(outgoing_edges_std);
```

With:

```zig
const outgoing_edge_ids = store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{};
// Iterate edge IDs directly, look up Edge only when needed:
for (outgoing_edge_ids) |edge_id| {
    const edge = store.edges.getPtr(edge_id) orelse continue;
    // ... existing edge matching logic, but using edge pointer instead of copy
}
```

- [ ] **Step 2: Verify test passes**

- [ ] **Step 3: Convert remaining call sites one at a time**

There are ~16 call sites. Convert each, test after each conversion.

- [ ] **Step 4: Remove getEdgesFrom/getEdgesTo if no longer used**

Or keep them for backward compatibility and mark with `// Deprecated: prefer getOutgoingEdgeIds for zero-copy access`.

- [ ] **Step 5: Commit**

```bash
git commit -m "perf(match): use zero-copy edge iteration to eliminate N+1 allocation"
```

---

## Execution Order

1. **Plan A** (15 min) — MCP auth guard, zero risk
2. **Plan B** (2-3 hours) — catch {} triage, medium risk
3. **Plan E** (1-2 days) — batch edge API, medium risk, high performance impact
4. **Plan C** (2-3 days) — function decomposition, high risk, needs integration tests
5. **Plan D** (2-3 days) — RLS wiring, high risk, security-critical

Plans A and B can be executed in one session. Plans C, D, E each need their own session with integration test verification.
