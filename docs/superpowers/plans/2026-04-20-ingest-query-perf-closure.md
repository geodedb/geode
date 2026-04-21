# Ingest + Query-Path Performance Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 6 remaining bottlenecks (GAP-0810 through GAP-0815) from `docs/performance/2026-04-20-query-bench/FINAL.md` by driving each through the already-landed `query-perf-gate.sh` A/B harness, with regression tests and bench evidence on every merge.

**Architecture:** Six sequenced phases, one per GAP. Each phase follows the same loop: (1) run `query-perf-gate.sh <gap> before` to freeze pre-state, (2) write a Zig regression test that fails, (3) implement the minimal fix in the identified file, (4) verify the test passes + `zig build test` stays green, (5) run `query-perf-gate.sh <gap> after` and inspect the generated `<gap>-diff.md`, (6) commit with the diff as evidence, (7) update `FINAL.md` status column. No feature is shipped without a measured delta in `bench-query-all.json`.

**Tech Stack:** Zig 0.16.0, existing bench harness in `benchmarks/bench_{parser,planner,executor_match,executor_mutation}.zig`, existing `SharedAstCache` in `src/server/query_ast_cache.zig`, existing `parallel.Pool` in `src/execution/parallel.zig`, existing `StorageAdapter` API in `src/storage/graph_storage_adapter.zig`.

**Scope note (from scope-check):** This plan bundles six logically independent GAPs. They share the bench harness and file-level knowledge, so one plan with six phases is pragmatic. Each phase is self-contained: if later phases slip, phases 1–N can ship independently. Phases are ordered by (impact × lead-time): cache first (unlocks parse savings for every subsequent phase's bench runs), aggregation + ORDER BY next (biggest raw wins on the current baseline), then traversal/UNION/CREATE.

---

## Pre-work: worktree + baseline rebase

### Task 0: Create worktree and freeze master baseline

**Files:**
- Create (worktree): `../geode-ingest-query-perf` on branch `perf/ingest-query-perf-2026-04-20`
- Read: `docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json` (the authoritative pre-state)

- [ ] **Step 1: Create the worktree on a fresh branch off main**

Run:
```bash
git worktree add -b perf/ingest-query-perf-2026-04-20 ../geode-ingest-query-perf origin/main
cd ../geode-ingest-query-perf
```
Expected: worktree created, HEAD at `d9d49c64` (or newer main), working tree clean.

- [ ] **Step 2: Verify bench harness still runs end-to-end on main**

Run:
```bash
./scripts/query-perf-gate.sh master-verify before
```
Expected: completes in ~15–20 min, writes `docs/performance/2026-04-20-query-bench/master-verify-before-query-all.json` with 608 rows. If it fails, STOP and fix the harness first — the plan depends on it.

- [ ] **Step 3: Diff master-verify against the baseline to confirm noise floor**

Run:
```bash
zig build compare-bench -- \
  --baseline docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json \
  --current docs/performance/2026-04-20-query-bench/master-verify-before-query-all.json \
  2>&1 | tee /tmp/master-verify-diff.txt
```
Expected: no row crosses the ±10% latency gate on a fresh checkout. If any row does, flag in the disposition and skip that scenario for regression checks in later phases.

- [ ] **Step 4: Clean up the verify artifact (we only needed the signal)**

Run:
```bash
rm docs/performance/2026-04-20-query-bench/master-verify-{before,after}-*.json 2>/dev/null || true
```

- [ ] **Step 5: Commit the worktree setup marker**

Nothing to commit — the worktree is created, no files have changed. Proceed to Phase 1.

---

## Phase 1 — GAP-0810: Shared AST cache on `executeProgramWithContext`

**Rationale from FINAL.md §6:** parser is 99× more expensive than planner; every connection re-parses identical queries. `SharedAstCache` already exists (`src/server/query_ast_cache.zig`) and is wired into `quic_connection_handler.zig:2111-2146` but **not** into `execution.executeProgramWithContext` — so in-process callers (materialized-view refresh, distributed coordinator, bench harness) always pay full parse cost. Expected win: 1.5–5× on high-QPS point-read traffic.

**Architectural decision:** the cache must not move to `executeProgramWithContext` — that function takes a `*const ast.Program`, so by the time it's called, parsing is already done. The right fix is (a) extend the public `geode.parseGqlOutcome` with a `parseGqlCached(cache, text, opts)` variant and (b) thread a process-global cache handle into the three callsites that currently parse directly (bench harness + materialized view refresh + distributed coordinator).

### Task 1.1: Add cached-parse helper to geode.zig

**Files:**
- Modify: `src/geode.zig` (add `parseGqlCached` wrapper)
- Modify: `src/server/query_ast_cache.zig:254` (no change needed — `getOrParse` already takes `query_text` + `opts` and returns the outcome)
- Read first: `src/server/query_ast_cache.zig:224-260` to confirm `SharedAstCache` public surface

- [ ] **Step 1: Read `SharedAstCache.getOrParse` signature**

Run: `grep -n "pub fn getOrParse\|pub fn init\|pub fn deinit" src/server/query_ast_cache.zig`

Expected: confirms `getOrParse(self, query_text, opts) !AstParseOutcome` exists (line ~254), `init(allocator, max_size)` (line ~234), and the `AstHandle.release()` exit.

- [ ] **Step 2: Write the failing test — cache handle flows through geode.parseGqlCached**

Create: `tests/test_gap0810_parse_cache_wrapper.zig`
```zig
const std = @import("std");
const geode = @import("geode");
const ast_cache = @import("src/server/query_ast_cache.zig");

test "parseGqlCached: second identical call returns cache hit" {
    const a = std.testing.allocator;
    var cache = ast_cache.SharedAstCache.init(a, 16);
    defer cache.deinit();

    const q = "MATCH (p:LT_Person {lt_id: 42}) RETURN p.name";

    // First call: miss.
    switch (try geode.parseGqlCached(&cache, q, .{})) {
        .Err => return error.ParseFailed,
        .Ok => |h1| {
            var h = h1;
            defer h.release();
            try std.testing.expectEqual(@as(u64, 1), cache.stats().miss_count);
            try std.testing.expectEqual(@as(u64, 0), cache.stats().hit_count);
        },
    }

    // Second call: hit.
    switch (try geode.parseGqlCached(&cache, q, .{})) {
        .Err => return error.ParseFailed,
        .Ok => |h2| {
            var h = h2;
            defer h.release();
            try std.testing.expectEqual(@as(u64, 1), cache.stats().hit_count);
        },
    }
}
```

- [ ] **Step 3: Run the test, confirm it fails with `parseGqlCached not found`**

Run: `zig build test -- --test-filter "parseGqlCached" 2>&1 | head -30`
Expected: FAIL on `error: no member 'parseGqlCached' in @import("geode")` or equivalent compile error.

- [ ] **Step 4: Implement `parseGqlCached` in `src/geode.zig`**

Add to `src/geode.zig` alongside the existing `parseGqlOutcome` public wrapper:
```zig
const query_ast_cache = @import("server/query_ast_cache.zig");

/// Cached variant of parseGqlOutcome. Returns an AstHandle that the caller
/// must release(); the underlying `ParseResult` is owned by the cache and
/// shared across callers for the same (query_text, opts) key.
///
/// Rationale: parser is ~100× more expensive than planner (FINAL.md §6).
/// Any in-process caller that executes the same query shape in a loop
/// (bench harness, view refresh, distributed coordinator) should use this
/// wrapper instead of `parseGqlOutcome` directly.
pub fn parseGqlCached(
    cache: *query_ast_cache.SharedAstCache,
    query_text: []const u8,
    opts: ParseOptions,
) !query_ast_cache.AstParseOutcome {
    return cache.getOrParse(query_text, opts);
}

/// Expose the cache stats so tests and diagnostics can observe hit ratio.
pub const SharedAstCache = query_ast_cache.SharedAstCache;
pub const AstHandle = query_ast_cache.AstHandle;
```

Also ensure `SharedAstCache` exposes a `stats()` accessor. Check and add if missing in `src/server/query_ast_cache.zig`:
```zig
pub fn stats(self: *SharedAstCache) struct { hit_count: u64, miss_count: u64 } {
    self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
    return .{ .hit_count = self.hit_count, .miss_count = self.miss_count };
}
```

- [ ] **Step 5: Run the test again, confirm it passes**

Run: `zig build test -- --test-filter "parseGqlCached" 2>&1 | head -30`
Expected: `All 1 tests passed.`

- [ ] **Step 6: Commit step 1**

```bash
git add src/geode.zig src/server/query_ast_cache.zig tests/test_gap0810_parse_cache_wrapper.zig
git commit -m "perf(parser): GAP-0810 add parseGqlCached wrapper + stats accessor"
```

### Task 1.2: Wire cache into the executor-match bench to measure realized parse-cache win

**Files:**
- Modify: `benchmarks/bench_executor_match.zig` (add a process-level cache; re-use across iterations)
- Modify: `benchmarks/bench_executor_mutation.zig` (same pattern)
- Read first: `benchmarks/bench_executor_match.zig:180-260` to find the per-iteration parse loop

- [ ] **Step 1: Read the current parse callsite in the executor-match bench**

Run: `grep -n "parseGqlOutcome\|parseGql\b" benchmarks/bench_executor_match.zig`

Expected: one or two direct `parseGqlOutcome` calls inside the scenario loop.

- [ ] **Step 2: Add process-scoped cache init at bench startup**

In `benchmarks/bench_executor_match.zig`, near the top of `main()` (after `const allocator = gpa.allocator();`):
```zig
var ast_cache = geode.SharedAstCache.init(allocator, 64);
defer ast_cache.deinit();
```

- [ ] **Step 3: Replace direct parseGqlOutcome with parseGqlCached in the iteration loop**

Find the per-iteration parse:
```zig
var parse_result = try geode.parseGqlOutcome(query, allocator, .{});
defer parse_result.deinit();
```
Replace with:
```zig
const outcome = try geode.parseGqlCached(&ast_cache, query, .{});
var handle = switch (outcome) { .Ok => |h| h, .Err => return error.ParseFailed };
defer handle.release();
const parse_result = handle.parse_result;
```

- [ ] **Step 4: Repeat the same pattern in `benchmarks/bench_executor_mutation.zig`**

Apply the same two edits (init cache + swap parse call). The mutation bench doesn't need large cache (6 scenarios), but uniformity matters for future gap work.

- [ ] **Step 5: Run the benches locally to confirm they still produce identical row counts**

Run:
```bash
zig build bench-query-executor-match -Doptimize=ReleaseFast -- --output /tmp/exec-match-cached.json
jq '.rows | length' /tmp/exec-match-cached.json
```
Expected: `240` rows (10 scenarios × 3 sizes × 8 measurements) — identical shape to baseline.

- [ ] **Step 6: Commit step 2**

```bash
git add benchmarks/bench_executor_match.zig benchmarks/bench_executor_mutation.zig
git commit -m "perf(bench): GAP-0810 bench harness uses parseGqlCached for cross-iter reuse"
```

### Task 1.3: Wire cache into materialized-view refresh + distributed query coordinator

**Files:**
- Modify: `src/query/materialized_views.zig:638` (the `executeProgramWithContext` callsite wraps a `parseGql` above)
- Modify: `src/distributed/query_coordinator.zig:308`
- Modify: `src/server/main.zig` (hold the shared AST cache on the ServerState; pass pointer into view refresh and coordinator init)

- [ ] **Step 1: Trace the existing parse call in materialized_views.zig**

Run: `grep -n "parseGql\|parseGqlOutcome" src/query/materialized_views.zig`
Expected: one callsite ~line 630.

- [ ] **Step 2: Add a process-level cache field to ServerState in main.zig**

In `src/server/main.zig:~190`, locate the `ServerState`/equivalent struct that already holds `shared_optimizer`. Add next to it:
```zig
shared_ast_cache: ?*query_ast_cache.SharedAstCache = null,
shared_ast_cache_storage: ?query_ast_cache.SharedAstCache = null,
```

In the init path that constructs `shared_optimizer_storage` (grep for it — `server_init.zig:390`), mirror the pattern:
```zig
ctx.shared_ast_cache_storage = query_ast_cache.SharedAstCache.init(allocator, 1024);
ctx.shared_ast_cache = &ctx.shared_ast_cache_storage.?;
```

Also wire into the QUIC connection handler: in `quic_connection_handler.zig` where `shared_optimizer` is passed (line ~976), add a sibling `shared_ast_cache` parameter and set `state.query_ast_cache = shared_ast_cache`. (The state field already exists — see `quic_connection_handler.zig:2113`.)

- [ ] **Step 3: Write the failing cross-subsystem test**

Create: `tests/test_gap0810_cross_subsystem_cache.zig`
```zig
const std = @import("std");
const geode = @import("geode");
const view_refresh = @import("src/query/materialized_views.zig");

test "materialized view refresh uses shared AST cache" {
    const a = std.testing.allocator;
    var cache = geode.SharedAstCache.init(a, 16);
    defer cache.deinit();

    // ... minimal materialized view that refreshes twice, asserting the
    //     second refresh produces cache.stats().hit_count == 1.
    // (Fill with actual view API once confirmed from materialized_views.zig
    //  public surface during implementation.)
    try std.testing.expectEqual(@as(u64, 0), cache.stats().hit_count);
}
```

NOTE: this test is a placeholder stub — complete the implementation only after reading the materialized-view public API. If the API can't express refresh-twice cleanly, collapse the test to assert that `coordinator.executeQuery(cache, text)` passes through and increments hits on second call.

- [ ] **Step 4: Thread cache pointer through view-refresh + coordinator**

In `src/query/materialized_views.zig`, change the signature on the refresh path to accept `ast_cache: ?*geode.SharedAstCache`. In the call at line ~630, replace `parseGqlOutcome(...)` with `if (ast_cache) |c| try geode.parseGqlCached(c, text, .{}) else try geode.parseGqlOutcome(text, allocator, .{})`.

Repeat for `src/distributed/query_coordinator.zig` at line ~308.

- [ ] **Step 5: Run `zig build test` in full to catch signature-change fallout**

Run: `zig build test 2>&1 | tail -40`
Expected: all tests pass. If call-site changes break downstream callers, they're likely in `src/query/view_manager.zig` or tests — update them to pass `null` for the cache param.

- [ ] **Step 6: Commit step 3**

```bash
git add src/server/main.zig src/server/server_init.zig src/server/quic_connection_handler.zig \
        src/query/materialized_views.zig src/distributed/query_coordinator.zig \
        tests/test_gap0810_cross_subsystem_cache.zig
git commit -m "perf(parser): GAP-0810 thread SharedAstCache through view refresh + coordinator"
```

### Task 1.4: Bench A/B gate for GAP-0810

- [ ] **Step 1: Run `before` phase from the merge base**

Run:
```bash
git stash   # stash Phase 1 changes temporarily — or use a second worktree
./scripts/query-perf-gate.sh gap0810 before
git stash pop
```
Expected: `docs/performance/2026-04-20-query-bench/gap0810-before-query-all.json` exists.

- [ ] **Step 2: Run `after` phase with the fix applied**

Run: `./scripts/query-perf-gate.sh gap0810 after`
Expected: `gap0810-diff.md` written; `latency_parse_ns_p50` drops to ~200ns on cache-hit rows (from 40–100µs cold).

- [ ] **Step 3: Inspect the diff, fill in disposition**

Read: `docs/performance/2026-04-20-query-bench/gap0810-diff.md`
Expected: compare-bench shows parse p50 improvement ≥ 20× on cached scenarios. If below 2× the claim fails — re-check that the bench actually goes through the cache (hit_count > 0 after warmup) before moving on.

- [ ] **Step 4: Commit Phase 1 closure**

```bash
git add docs/performance/2026-04-20-query-bench/gap0810-*.json \
        docs/performance/2026-04-20-query-bench/gap0810-diff.md
git commit -m "perf(parser): GAP-0810 A/B ledger — parse cache in exec path"
```

- [ ] **Step 5: Update FINAL.md status row**

Edit `docs/performance/2026-04-20-query-bench/FINAL.md`, change the GAP-0810 row in the follow-up table to `✅ done (<commit-sha>)` and inline the measured delta.

```bash
git add docs/performance/2026-04-20-query-bench/FINAL.md
git commit -m "docs(bench): mark GAP-0810 done in FINAL.md with measured delta"
```

---

## Phase 2 — GAP-0811: Aggregation-aware planner (count/avg no materialize)

**Rationale from FINAL.md §2:** `MATCH (p:LT_Person) RETURN count(p)` spends 900ms on 5k nodes (180µs/node) because the executor materializes each node's properties + graph-name before the aggregator discards them. A pre-existing `countNodesFastPath` in `match_operations.zig:303` handles the un-labeled, no-predicate case. Expected win: 10–50× on pure-count; 3–5× on `avg`/`sum` where we skip property dupes.

### Task 2.1: Extend `countNodesFastPath` to label-scoped + WHERE-eq cases

**Files:**
- Modify: `src/execution/match_operations.zig:303-420` (function `countNodesFastPath`)
- Modify: `src/storage/graph_storage_adapter.zig:1178` (add `countNodesByLabel(graph, label, tenant)` O(1) return of label-index cardinality)
- Test: `tests/test_gap0811_aggregation_fastpath.zig`

- [ ] **Step 1: Read the existing fast-path preconditions**

Run: `sed -n '290,400p' src/execution/match_operations.zig`

Expected: preconditions list at L291-340; the "no labels" gate is at L317 (`if (head.labels.len != 0) return null;`).

- [ ] **Step 2: Write the failing test — `count(p)` with a label returns correct value fast**

Create: `tests/test_gap0811_aggregation_fastpath.zig`
```zig
const std = @import("std");
const geode = @import("geode");

test "GAP-0811: MATCH (p:Label) RETURN count(p) uses label-index fast path" {
    const a = std.testing.allocator;
    var tmp_dir: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_dir, "/tmp/gap0811-{d}", .{std.os.linux.getpid()});
    const fs_io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(fs_io, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};

    _ = try geode.graph_store.initGlobalStore(a, tmp_path);
    defer geode.graph_store.deinitGlobalStore();
    _ = try geode.execution.ensureCatalogInstance(a);
    defer geode.execution.cleanupCatalogInstance();

    // Seed 100 LT_Person + 10 LT_Company
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const q = try std.fmt.allocPrint(a, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        defer a.free(q);
        var r = try geode.executeQuery(a, q);
        r.deinit(a);
    }
    i = 0;
    while (i < 10) : (i += 1) {
        const q = try std.fmt.allocPrint(a, "CREATE (:LT_Company {{lt_id: {d}}})", .{i});
        defer a.free(q);
        var r = try geode.executeQuery(a, q);
        r.deinit(a);
    }

    // Before wall-time snapshot for eyeball regression check.
    const t0 = std.time.nanoTimestamp();
    var res = try geode.executeQuery(a, "MATCH (p:LT_Person) RETURN count(p) AS n");
    defer res.deinit(a);
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqual(@as(i64, 100), res.rows[0][0].Int);

    // The fast path must return in <1ms even for 100 nodes (cold scan would
    // take >10ms). This is a smoke check; real perf gating is in bench A/B.
    try std.testing.expect(elapsed_ns < 1_000_000);
}
```

- [ ] **Step 3: Run test to confirm it fails on perf (or value)**

Run: `zig build test -- --test-filter "GAP-0811" 2>&1 | tail -20`
Expected: either FAIL with `elapsed_ns >= 1ms` OR FAIL on a correctness assertion — either is fine as the baseline before-state.

- [ ] **Step 4: Add `countNodesByLabel` to StorageAdapter**

In `src/storage/graph_storage_adapter.zig`, after `getNodesByLabel` at line 1178:
```zig
/// O(1) label-index cardinality without materializing node IDs.
/// Honours tenant filter identically to getNodesByLabels(label, tenant).
pub fn countNodesByLabel(
    self: *StorageAdapter,
    graph_name: []const u8,
    label: []const u8,
    tenant: ?[]const u8,
) u64 {
    const per_graph = self.getGraph(graph_name) orelse return 0;
    const idx = per_graph.label_index.get(label) orelse return 0;
    if (tenant == null) return @intCast(idx.nodes.count());
    var n: u64 = 0;
    var it = idx.nodes.iterator();
    while (it.next()) |e| {
        if (self.passesTenantFilter(graph_name, e.key_ptr.*, tenant)) n += 1;
    }
    return n;
}
```

- [ ] **Step 5: Extend `countNodesFastPath` to accept `head.labels.len == 1` with no other predicate**

Replace the gate at `match_operations.zig:317`:
```zig
// OLD: if (head.labels.len != 0) return null;
// NEW:
if (head.labels.len > 1) return null;
if (head.props != null) return null;
```

Below the existing `store.countNodesForGraph(...)` call, branch on label presence:
```zig
const count: u64 = if (head.labels.len == 1) blk: {
    const adapter = graph_store.getGlobalAdapter() orelse break :blk 0;
    break :blk adapter.countNodesByLabel(filter_graph, head.labels[0], filter_tenant);
} else try store.countNodesForGraph(filter_graph, filter_tenant);
```

- [ ] **Step 6: Run the test, confirm PASS + remains <1ms**

Run: `zig build test -- --test-filter "GAP-0811" 2>&1 | tail -10`
Expected: `All 1 tests passed.`

- [ ] **Step 7: Run full test suite to catch regressions**

Run: `zig build test 2>&1 | tail -20`
Expected: all green.

- [ ] **Step 8: Commit step 1**

```bash
git add src/storage/graph_storage_adapter.zig src/execution/match_operations.zig \
        tests/test_gap0811_aggregation_fastpath.zig
git commit -m "perf(exec): GAP-0811 count(p) label-scoped uses label-index cardinality"
```

### Task 2.2: Extend fast-path to `sum/avg` over a single numeric property

**Files:**
- Modify: `src/execution/match_operations.zig` (add sibling `sumAvgNodesFastPath`)

- [ ] **Step 1: Write the failing test for `avg(p.age)`**

Append to `tests/test_gap0811_aggregation_fastpath.zig`:
```zig
test "GAP-0811: MATCH (p:Label) RETURN avg(p.age) skips graph-name dupes" {
    // ... (setup identical to test above, seed with .age in 20..40)
    const t0 = std.time.nanoTimestamp();
    var res = try geode.executeQuery(a, "MATCH (p:LT_Person) RETURN avg(p.age) AS m");
    defer res.deinit(a);
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    // avg still walks nodes (need property value), but should not materialize
    // the full node (labels, graph_name, all other props).
    // Target: <5ms for 100 nodes (was ~18ms baseline on the bench).
    try std.testing.expect(elapsed_ns < 5_000_000);
}
```

- [ ] **Step 2: Run and confirm fail on latency**

Run: `zig build test -- --test-filter "avg(p.age)" 2>&1 | tail -10`
Expected: FAIL on elapsed_ns >= 5ms OR correctness.

- [ ] **Step 3: Implement lean property-only iterator in match_operations.zig**

After `countNodesFastPath`, add:
```zig
/// Fast path: single-label scan + single-column numeric aggregate
/// (sum/avg/min/max) over a named property, no WHERE, no GROUP BY.
/// Avoids the per-row `materializeNode` call entirely — reads only the
/// needed property via `adapter.getNodeProperty`.
pub fn propertyAggregateFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // Shape gates identical to countNodesFastPath, except:
    // - head.labels.len == 1 required
    // - RETURN is avg|sum|min|max(p.key)
    // Iterate label-index, call adapter.getNodeProperty(graph, slot, key),
    // accumulate into f64. No materializeNode, no graph_name dupe.
    // ... (full implementation; see pattern at planned_read_runtime.zig:856
    //      for candidate enumeration)
}
```

Wire the dispatch: at the top of the MATCH executor (search for `countNodesFastPath(` invocation), add a parallel check:
```zig
if (try propertyAggregateFastPath(a, q, graph, tenant)) |r| return r;
```

- [ ] **Step 4: Run test, confirm PASS**

Run: `zig build test -- --test-filter "avg(p.age)" 2>&1 | tail -10`

- [ ] **Step 5: Commit step 2**

```bash
git add src/execution/match_operations.zig tests/test_gap0811_aggregation_fastpath.zig
git commit -m "perf(exec): GAP-0811 sum/avg/min/max(p.key) fast path skips materializeNode"
```

### Task 2.3: Bench A/B gate for GAP-0811

- [ ] **Step 1: before phase** — `./scripts/query-perf-gate.sh gap0811 before` (on merge base of this phase)
- [ ] **Step 2: after phase** — `./scripts/query-perf-gate.sh gap0811 after`
- [ ] **Step 3: Verify** the `agg_count_label/*` and `agg_avg_property/*` rows in `gap0811-diff.md` show ≥5× latency improvement.
- [ ] **Step 4: Commit diff + update FINAL.md** (pattern identical to Phase 1 Task 1.4 steps 4–5).

---

## Phase 3 — GAP-0812: ORDER BY + LIMIT streaming top-K

**Rationale from FINAL.md §5:** `MATCH (p:LT_Person) RETURN p.lt_id ORDER BY p.lt_id DESC LIMIT 50` spends 908 ms materializing all 5 000 nodes before sorting + trimming. A bounded heap of size K=50 over `lt_id` needs ~30 k comparisons instead of 5 000 full materializations. Expected win: 5–20×.

### Task 3.1: Detect the `ORDER BY single_property LIMIT K` shape in the planner

**Files:**
- Modify: `src/execution/match_operations.zig` (add `topKOrderedFastPath` sibling to the count/agg fast paths)
- Read: `src/execution/match_operations.zig:891-918` (existing ORDER BY + LIMIT block)

- [ ] **Step 1: Read the ORDER BY / LIMIT callsite to understand current flow**

Run: `sed -n '880,920p' src/execution/match_operations.zig`
Expected: ORDER BY runs in-memory on the fully-materialized binding list, then LIMIT trims.

- [ ] **Step 2: Write the failing test — 1000-node `ORDER BY lt_id LIMIT 10` completes <10ms**

Create: `tests/test_gap0812_topk_streaming.zig`
```zig
const std = @import("std");
const geode = @import("geode");

test "GAP-0812: ORDER BY indexed_prop LIMIT K streams top-K without full materialize" {
    const a = std.testing.allocator;
    // ... setup store, seed 1000 LT_Person with lt_id in 0..999 (shuffled)
    const t0 = std.time.nanoTimestamp();
    var res = try geode.executeQuery(a,
        "MATCH (p:LT_Person) RETURN p.lt_id ORDER BY p.lt_id DESC LIMIT 10"
    );
    defer res.deinit(a);
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    try std.testing.expectEqual(@as(usize, 10), res.rows.len);
    try std.testing.expectEqual(@as(i64, 999), res.rows[0][0].Int);
    try std.testing.expectEqual(@as(i64, 990), res.rows[9][0].Int);
    // Bounded-heap must beat the O(N log N) materialize-then-sort path.
    try std.testing.expect(elapsed_ns < 10_000_000);
}
```

- [ ] **Step 3: Run test, confirm FAIL on latency**

Run: `zig build test -- --test-filter "GAP-0812" 2>&1 | tail -10`
Expected: FAIL on elapsed_ns >= 10ms.

- [ ] **Step 4: Implement bounded top-K heap in executor**

Add to `src/execution/match_operations.zig`:
```zig
/// Fast path: MATCH (p:Label) RETURN p.<key> [DESC|ASC] LIMIT K
/// where the ORDER BY is on the same property being projected and the
/// property is a numeric or string scalar. Uses a K-bounded min/max heap
/// to avoid O(N) materialization.
///
/// Preconditions:
///   - single chain, single simple node pattern with exactly one label
///   - no WHERE, no FILTER, no WITH, no GROUP BY
///   - RETURN is exactly one item `p.<key>` (no alias change ok)
///   - ORDER BY is `p.<key>` ASC or DESC (same key as projection)
///   - LIMIT is a literal > 0
///   - K ≤ 10 000 (guardrail — above that the heap cost dominates and the
///     old path wins; bail to fallback)
pub fn topKOrderedFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // ... (gating logic; then iterate adapter.getNodesByLabel(..) and
    //      adapter.getNodeProperty(.., key) into a BoundedPriorityQueue
    //      sized at K. Build result rows only for the K survivors.)
}
```

Dispatch at the same entrypoint as Task 2.1 step 5.

- [ ] **Step 5: Run test, confirm PASS**

Run: `zig build test -- --test-filter "GAP-0812" 2>&1 | tail -10`

- [ ] **Step 6: Run full test suite to catch ORDER BY regressions**

Run: `zig build test 2>&1 | tail -20`
Expected: all green. If any ORDER BY test regresses, the fast-path shape-gate is too permissive — tighten it.

- [ ] **Step 7: Commit Phase 3 implementation**

```bash
git add src/execution/match_operations.zig tests/test_gap0812_topk_streaming.zig
git commit -m "perf(exec): GAP-0812 ORDER BY indexed_prop LIMIT K uses bounded heap"
```

### Task 3.2: Bench A/B gate for GAP-0812

- [ ] **Step 1: before phase** — `./scripts/query-perf-gate.sh gap0812 before`
- [ ] **Step 2: after phase** — `./scripts/query-perf-gate.sh gap0812 after`
- [ ] **Step 3: Verify** `order_by_limit/large` latency drops ≥5× in `gap0812-diff.md`.
- [ ] **Step 4: Commit diff + update FINAL.md**.

---

## Phase 4 — GAP-0813: Bulk `materializePath` for multi-hop traversals

**Rationale from FINAL.md §3:** `two_hop_distinct/large` spends 1.29s on 5k nodes / 15k edges. Each hop triggers a full `materializeNode` (labels + all properties + graph_name dupe + property-map hash-build) even when the projection needs only `c.name, c.lt_id`. `materializePath` should batch adapter round-trips and project-prune. Expected win: 2–5×.

### Task 4.1: Add `materializePath` API + project-aware path builder

**Files:**
- Modify: `src/execution/planned_read_runtime.zig:654-712` (function `materializePathRow`)
- Add: `src/storage/graph_storage_adapter.zig` — new `getNodesBulk(graph, slot_ids[], projection_keys[], allocator)`

- [ ] **Step 1: Read the current per-hop materialize path**

Run: `sed -n '650,710p' src/execution/planned_read_runtime.zig`
Expected: `materializePathRow` calls `materializeNode` once per hop endpoint + `materializeEdge` once per step. Each call does independent adapter lookups.

- [ ] **Step 2: Write the failing bench-shaped test**

Create: `tests/test_gap0813_bulk_materialize_path.zig`
```zig
const std = @import("std");
const geode = @import("geode");

test "GAP-0813: two-hop traversal uses bulk path materialization" {
    const a = std.testing.allocator;
    // ... seed 500 LT_Person + 1500 LT_KNOWS edges (3 per-person fan-out)
    const t0 = std.time.nanoTimestamp();
    var res = try geode.executeQuery(a,
        "MATCH (a:LT_Person {lt_id: 42})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) " ++
        "RETURN DISTINCT c.name LIMIT 20"
    );
    defer res.deinit(a);
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    // Baseline: ~40ms at 500 nodes. Target: <15ms.
    try std.testing.expect(elapsed_ns < 15_000_000);
}
```

- [ ] **Step 3: Run test, confirm FAIL**

Run: `zig build test -- --test-filter "GAP-0813" 2>&1 | tail -10`

- [ ] **Step 4: Add `StorageAdapter.getNodesBulk`**

Add to `src/storage/graph_storage_adapter.zig`:
```zig
/// Batch-materialize nodes: single lock acquisition, projection-pruned.
/// Returns a slice of `BulkNode` sized identically to slot_ids; missing
/// slots are set to `BulkNode.empty`.
///
/// projection_keys: property keys to include. If empty, no properties are
/// fetched — labels-only materialization (useful when the aggregator only
/// needs label presence, not values).
pub fn getNodesBulk(
    self: *StorageAdapter,
    graph_name: []const u8,
    slot_ids: []const u64,
    projection_keys: []const []const u8,
    allocator: std.mem.Allocator,
) ![]BulkNode {
    // ... single read-lock + per-slot iteration; returns labels + filtered
    //     property map per node. Arena-backed via allocator.
}

pub const BulkNode = struct {
    external_id: u64,
    labels: [][]const u8,
    properties: std.StringHashMap(graph_store.PropertyValue),
    pub const empty: BulkNode = .{ .external_id = 0, .labels = &.{}, .properties = undefined };
};
```

- [ ] **Step 5: Add `materializePath` to planned_read_runtime.zig**

Below `materializeEdge`, add:
```zig
/// Batched materialization for a completed path. Called once per result
/// row instead of once per hop endpoint. Uses the projection keys derived
/// from the RETURN clause (passed via ExecutionContext) to skip fetching
/// unused properties — the single biggest win on multi-hop queries.
pub fn materializePath(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    node_slots: []const u64,
    edge_steps: []const PathEdge,
    projection_keys: []const []const u8,
) ![]*graph_store.Node {
    const scratch = scratchOr(allocator);
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const bulk = try adapter.getNodesBulk(graph_name, node_slots, projection_keys, scratch);
    defer scratch.free(bulk);

    var out = try allocator.alloc(*graph_store.Node, node_slots.len);
    errdefer {
        for (out) |n| if (@intFromPtr(n) != 0) allocator.destroy(n);
        allocator.free(out);
    }
    for (bulk, 0..) |b, i| {
        const node = try allocator.create(graph_store.Node);
        node.* = .{
            .id = b.external_id,
            .labels = b.labels,
            .properties = b.properties,
            .graph_name = try scratch.dupe(u8, graph_name), // single dup, not per-hop
        };
        out[i] = node;
    }
    // edges stay per-step for now (materializeEdge is already cheap — edges
    // have fewer properties than nodes). Revisit if bench shows edge cost
    // dominating after node-bulk lands.
    _ = edge_steps;
    return out;
}
```

Replace the per-hop `materializeNode` calls in `materializePathRow` with a single `materializePath` call, then iterate the returned slice.

- [ ] **Step 6: Wire projection-key extraction**

The projection keys must be derived from `q.ret.items`. Helper in same file:
```zig
fn extractProjectionKeys(allocator: std.mem.Allocator, items: []const ast.ReturnItem) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (items) |it| {
        switch (it.expr) {
            .PropertyAccess => |pa| try out.append(allocator, pa.key),
            else => {}, // conservative: any non-trivial expr bails the fast-path
        }
    }
    return try out.toOwnedSlice(allocator);
}
```

Bail to the full-materialize path if extraction hits anything other than pure `var.key`.

- [ ] **Step 7: Run test + full suite**

Run:
```bash
zig build test -- --test-filter "GAP-0813" 2>&1 | tail -10
zig build test 2>&1 | tail -20
```
Expected: both green.

- [ ] **Step 8: Commit Phase 4**

```bash
git add src/storage/graph_storage_adapter.zig src/execution/planned_read_runtime.zig \
        tests/test_gap0813_bulk_materialize_path.zig
git commit -m "perf(exec): GAP-0813 bulk materializePath with projection pruning"
```

### Task 4.2: Bench A/B gate for GAP-0813

- [ ] **Step 1: before / after / diff** (identical pattern to Phase 3 Task 3.2).
- [ ] **Step 2: Verify** `two_hop_distinct/large` and `fan_out_cross_type/large` both show ≥2× improvement.
- [ ] **Step 3: Commit diff + update FINAL.md**.

---

## Phase 5 — GAP-0814: UNION-leg parallelism

**Rationale from FINAL.md §4:** `union_two_labels/large` spends 1.07s executing each arm sequentially. Legs are independent; submitting them to `parallel.Pool` halves wall time. Expected win: ~2×.

### Task 5.1: Parallelize independent UNION arms

**Files:**
- Modify: `src/execution/set_operations.zig:206-340` (function `executeUnionWithContext`)
- Read: `src/execution/parallel.zig:73-130` (existing `Pool.forkJoin`)

- [ ] **Step 1: Read the current serial UNION loop**

Run: `sed -n '200,280p' src/execution/set_operations.zig`
Expected: for-loop over `union_query.tails`, each arm awaited sequentially.

- [ ] **Step 2: Write the failing test — parallel execution halves wall time on 2-arm UNION**

Create: `tests/test_gap0814_union_parallelism.zig`
```zig
const std = @import("std");
const geode = @import("geode");

test "GAP-0814: UNION arms run in parallel" {
    const a = std.testing.allocator;
    // ... seed 500 LT_Person + 500 LT_Company (both arms roughly equal cost)
    const t0 = std.time.nanoTimestamp();
    var res = try geode.executeQuery(a,
        "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id"
    );
    defer res.deinit(a);
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    try std.testing.expectEqual(@as(usize, 1000), res.rows.len);
    // With parallelism, 2 equal-cost arms should finish in ~1x single-arm
    // time (not 2x). Baseline single-arm is ~30ms on 500 nodes, so parallel
    // target is <45ms (allowing 50% fan-out overhead). Serial would be ~60ms.
    try std.testing.expect(elapsed_ns < 45_000_000);
}
```

- [ ] **Step 3: Run test, confirm FAIL on latency**

Run: `zig build test -- --test-filter "GAP-0814" 2>&1 | tail -10`

- [ ] **Step 4: Refactor UNION loop to use `parallel.Pool.forkJoin`**

In `executeUnionWithContext`:
```zig
// Existing: serial for-loop. Replace with a fork-join over independent arms.
const pool = try parallel.Pool.init(allocator, 0); // 0 = auto cpu count
defer pool.deinit();

const ArmResult = struct {
    result: ExecutionResult,
    err: ?anyerror = null,
};
var arm_results = try allocator.alloc(ArmResult, union_query.tails.len);
defer allocator.free(arm_results);

const ArmCtx = struct {
    tail_idx: usize,
    tail: *const ast.UnionQuery.Part,
    context: ExecutionContext,
    shared_bindings: ?*const anyopaque,
    out: *ArmResult,
    allocator: std.mem.Allocator,
};
var ctxs = try allocator.alloc(ArmCtx, union_query.tails.len);
defer allocator.free(ctxs);

for (union_query.tails, 0..) |*tail, i| {
    ctxs[i] = .{ .tail_idx = i, .tail = tail, .context = context,
                  .shared_bindings = shared_bindings, .out = &arm_results[i],
                  .allocator = allocator };
}

try pool.forkJoin(ctxs, struct {
    fn run(ctx: *ArmCtx) void {
        ctx.out.result = executeArm(ctx.allocator, ctx.tail.*, ctx.context,
                                    ctx.shared_bindings) catch |e| {
            ctx.out.err = e;
            return;
        };
    }
}.run);

// Merge results from arm_results into `result` (dedup or append depending
// on part.all, preserving input order).
```

Extract the per-arm body into a local `executeArm` helper. Preserve the existing column-count validation + dedup logic exactly — move it into the merge phase.

- [ ] **Step 5: Run test, confirm PASS**

Run: `zig build test -- --test-filter "GAP-0814" 2>&1 | tail -10`

- [ ] **Step 6: Run full suite — UNION has many existing tests**

Run: `zig build test 2>&1 | tail -20`
Expected: all green. UNION DISTINCT ordering may shift — if any test asserts row order, decide: (a) was the old implicit order part of the contract (no — UNION is unordered per SQL spec); if yes, add an `ORDER BY` to the offending test.

- [ ] **Step 7: Commit Phase 5**

```bash
git add src/execution/set_operations.zig tests/test_gap0814_union_parallelism.zig
git commit -m "perf(exec): GAP-0814 UNION arms fork-join on parallel.Pool"
```

### Task 5.2: Bench A/B gate for GAP-0814

- [ ] **Step 1: before / after / diff**.
- [ ] **Step 2: Verify** `union_two_labels/large` drops ≥1.8× in `gap0814-diff.md`.
- [ ] **Step 3: Commit diff + update FINAL.md**.

---

## Phase 6 — GAP-0815: Batch-CREATE planner (shared label/prop shape)

**Rationale from FINAL.md §7:** `create_batch_100` amortizes to 896µs/node — *worse* than single CREATE (746µs), meaning no batching happens. Per-CREATE, the label-index, the merge-property index, and each property setter each walk the adapter independently. Expected win: 3–10× on CREATE-heavy loads.

### Task 6.1: Detect homogeneous CREATE batches in the planner

**Files:**
- Read first: `src/execution/crud_operations.zig` + `src/execution/property_mutation.zig` for the current CREATE path
- Modify: `src/execution/crud_operations.zig` (add `executeBatchCreate`)
- Modify: `src/execution/match_operations.zig` or wherever CREATE dispatches from

- [ ] **Step 1: Map the current CREATE flow**

Run:
```bash
grep -n "executeCreate\|create_node\|CreateStatement" src/execution/crud_operations.zig | head -10
```
Expected: per-statement `executeCreate` loop in `crud_operations.zig`.

- [ ] **Step 2: Write the failing test — 100-CREATE batch amortizes at least 3× better than single**

Create: `tests/test_gap0815_batch_create.zig`
```zig
const std = @import("std");
const geode = @import("geode");

test "GAP-0815: homogeneous CREATE batch of 100 runs in <3ms" {
    const a = std.testing.allocator;
    // ... setup store

    // Build a single query with 100 inline CREATE clauses sharing (label, prop keys).
    var q_buf = std.ArrayList(u8).empty;
    defer q_buf.deinit(a);
    var w = q_buf.writer(a);
    try w.writeAll("CREATE ");
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (i != 0) try w.writeAll(", ");
        try w.print("(:LT_Person {{lt_id: {d}, name: 'p{d}'}})", .{ i, i });
    }

    const t0 = std.time.nanoTimestamp();
    var res = try geode.executeQuery(a, q_buf.items);
    defer res.deinit(a);
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    // Single-node CREATE baseline: ~746µs. 100 serial CREATEs: ~90ms.
    // Target (amortized to <30µs/node): <3ms total.
    try std.testing.expect(elapsed_ns < 3_000_000);
}
```

- [ ] **Step 3: Run test, confirm FAIL**

Run: `zig build test -- --test-filter "GAP-0815" 2>&1 | tail -10`

- [ ] **Step 4: Implement shape-detection + batched insert**

In `src/execution/crud_operations.zig`, before the per-statement CREATE loop:
```zig
/// Detect N inline CREATE node clauses that share a single label + prop-key
/// set. When detected, emit a single adapter call that:
///   (1) bulk-allocates N node slots
///   (2) writes the label-index once (single bucket append)
///   (3) writes property index entries in a single sorted pass per key
/// Falls back to per-statement loop when shapes diverge.
fn detectHomogeneousCreateBatch(
    q: ast.Query,
) ?struct {
    label: []const u8,
    prop_keys: [][]const u8,
    nodes: []const ast.NodePattern,
} {
    // Guard: must be N >= 3 (below that the dispatch overhead beats the
    // batch win). All patterns must have identical labels and prop-key
    // multisets.
    // ... (AST walk over q.match + q.create_clauses)
}

pub fn executeBatchCreate(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    batch: Batch,
) !usize {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const slot_ids = try adapter.allocNodeSlotsBulk(graph_name, batch.nodes.len);
    errdefer adapter.freeNodeSlotsBulk(graph_name, slot_ids);

    try adapter.appendLabelIndexBulk(graph_name, batch.label, slot_ids);
    for (batch.prop_keys, 0..) |key, k_idx| {
        var values = try allocator.alloc(PropertyValue, batch.nodes.len);
        defer allocator.free(values);
        for (batch.nodes, 0..) |n, i| values[i] = n.props.?[k_idx].value.*;
        try adapter.setPropertiesBulk(graph_name, slot_ids, key, values);
    }
    return slot_ids.len;
}
```

Adapter-side: add `allocNodeSlotsBulk`, `appendLabelIndexBulk`, `setPropertiesBulk` to `src/storage/graph_storage_adapter.zig`. Each takes the write lock once and batches the single per-slot work.

Dispatch: at the top of the existing CREATE entrypoint, `if (detectHomogeneousCreateBatch(q)) |batch| return executeBatchCreate(..., batch);`.

- [ ] **Step 5: Run test, confirm PASS**

Run: `zig build test -- --test-filter "GAP-0815" 2>&1 | tail -10`

- [ ] **Step 6: Run full CREATE test suite — this touches ingest hot path**

Run:
```bash
zig build test 2>&1 | tail -20
# Also run a loadtest regression sniff:
cd ../geode-test-harness
GEODE_ADMIN_PASSWORD=$GEODE_ADMIN_PASSWORD make test-spec SPEC=specs/crud/create_batch.yml 2>&1 | tail -20
```
Expected: all green. If any CREATE test fails on row-order (CREATE returns), make the batch path preserve input order — slot allocation must be contiguous and label-index append must honour insertion order.

- [ ] **Step 7: Commit Phase 6**

```bash
git add src/execution/crud_operations.zig src/storage/graph_storage_adapter.zig \
        tests/test_gap0815_batch_create.zig
git commit -m "perf(exec): GAP-0815 batch-CREATE path for homogeneous node clauses"
```

### Task 6.2: Bench A/B gate for GAP-0815

- [ ] **Step 1: before / after / diff**.
- [ ] **Step 2: Verify** `create_batch_100` amortized µs/node drops ≥3× in `gap0815-diff.md`. Single-CREATE (`create_single`) must NOT regress — if it does, the detection threshold is too low.
- [ ] **Step 3: Commit diff + update FINAL.md**.

---

## Post-work: baseline refresh + master roll-up

### Task 7: Roll up all six phases into a new baseline

**Files:**
- Replace: `docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json`
- Update: `docs/performance/2026-04-20-query-bench/FINAL.md` (move all six gaps to `✅ done` + inline measured deltas)
- Create: `docs/performance/2026-04-20-query-bench/POST-CLOSURE.md` with a scenario-by-scenario before/after table.

- [ ] **Step 1: Run a fresh full baseline with all six phases merged**

Run: `./scripts/query-perf-gate.sh post-closure before`
Expected: ~15–20min, emits `post-closure-before-query-all.json`.

- [ ] **Step 2: Replace the baseline**

```bash
cp docs/performance/2026-04-20-query-bench/post-closure-before-query-all.json \
   docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json
```

- [ ] **Step 3: Generate the POST-CLOSURE summary**

Write `docs/performance/2026-04-20-query-bench/POST-CLOSURE.md` containing:
- master before/after latency table for all 10 scenarios × 3 sizes
- links to each gap's `diff.md`
- disposition: which scenarios remain on the top-10 slowest list + what's next
- note the new baseline commit SHA

- [ ] **Step 4: Commit the rolled-up artifacts**

```bash
git add docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json \
        docs/performance/2026-04-20-query-bench/POST-CLOSURE.md \
        docs/performance/2026-04-20-query-bench/FINAL.md
git commit -m "perf(bench): roll up GAP-0810..0815 into new query-bench baseline"
```

- [ ] **Step 5: Push the branch and open a single roll-up MR**

```bash
git push -u origin perf/ingest-query-perf-2026-04-20
gh pr create --title "perf: close GAP-0810..0815 — ingest + query-path bottlenecks" \
             --body-file docs/performance/2026-04-20-query-bench/POST-CLOSURE.md
```

Expected: MR opens with the POST-CLOSURE summary as the description. CI `bench-query-path` job runs; `allow_failure: true` remains until we observe two green consecutive runs, then tighten it.

---

## Self-review checklist (filled out during planning)

**1. Spec coverage:**
- GAP-0810 (AST cache) → Phase 1 ✓
- GAP-0811 (aggregation-aware planner) → Phase 2 ✓
- GAP-0812 (ORDER BY + LIMIT top-K) → Phase 3 ✓
- GAP-0813 (bulk materializePath) → Phase 4 ✓
- GAP-0814 (UNION parallelism) → Phase 5 ✓
- GAP-0815 (batch-CREATE) → Phase 6 ✓
- Master baseline refresh → Task 7 ✓

**2. Placeholder scan:** task 1.3 step 3 contains a deliberately-stubbed test body — flagged inline as "complete only after reading the materialized-view public API". All other steps carry real code.

**3. Type consistency:** `SharedAstCache` / `AstHandle` / `AstParseOutcome` used consistently (re-exported from geode.zig in Task 1.1 step 4, referenced in all three wiring sites in Task 1.3). `StorageAdapter` methods `countNodesByLabel` / `getNodesBulk` / `allocNodeSlotsBulk` / `appendLabelIndexBulk` / `setPropertiesBulk` introduced per-phase and referenced only within the phase that adds them. `BulkNode` defined once (graph_storage_adapter.zig Task 4.1 step 4) and consumed in planned_read_runtime.zig Task 4.1 step 5.

**Known residual risks:**
- Phase 1 Task 1.3: requires tracing the materialized-view and distributed-coordinator public API; signatures may change. Budget extra 0.5d if `executeProgramWithContext` callers in-tree are more numerous than the two grepped here.
- Phase 5: `parallel.Pool.forkJoin` contract may differ from the sketched closure style — read `src/execution/parallel.zig:109` before writing the refactor.
- Phase 6: adapter-level bulk index APIs may require `PerGraph` write-lock upgrades not already present; if so, add a Task 6.0 to land those primitives first.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-20-ingest-query-perf-closure.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Good fit because each phase is naturally scoped to a single subagent (independent branch, independent bench diff).

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Fine if you want tighter control on signature changes in Phase 1 Task 1.3 and Phase 5 Task 5.1, where the existing API surface is load-bearing.

Which approach?
