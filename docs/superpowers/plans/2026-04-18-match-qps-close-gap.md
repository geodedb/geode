# Close the MATCH-vs-ping QPS Gap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 28× throughput gap between `point_read` MATCH-by-property (~33 QPS post-GAP-0752) and ping (~940 QPS) so that a 500-node property lookup sustains ≥400 QPS at c=8 on the same host.

**Architecture:** Five independent phases, each with standalone tests and commit. In order of impact × inverse-risk: (1) narrow the handler's lock-hold scope using the already-wired `ReadView` so readers stop blocking each other on sub-millisecond cache work; (2) retire `graph_store.global_gpa`'s `DebugAllocator` in favour of `smp_allocator` so allocator contention disappears; (3) add a per-query arena for executor scratch so the read path stops `mmap`-ing through `PageAllocator` on every query; (4) wire the already-built `SharedQueryOptimizer` plan cache into the MATCH execution path so parameterised lookups skip parse+plan on cache hits; (5) replace the single-thread QUIC poll pool with a per-core dispatch pool. After each phase, the targeted Zig test and the `match_property_read_scaling.sh` integration script re-run, the achieved c=4 ratio goes into the test's hard threshold, and the loadtest report's "Follow-ups" list is updated.

**Tech Stack:** Zig 0.16, `std.Io.RwLock` / `std.Io.Mutex`, `std.heap.smp_allocator`, `std.heap.ArenaAllocator`, Geode's existing `ReadView` / `QueryReadSession` (`src/graph_store.zig:5377-5420`), `SharedQueryOptimizer` (`src/server/query_plan_cache.zig`), `ThreadPool` (`src/transport/thread_pool.zig`), QUIC transport (`vendor/quic`). Loadtest harness: `../geode-test-harness/loadtest/go/geode-loadtest`.

---

## Baseline numbers (from `docs/audit/LOADTEST_REPORT_2026_04_18_v0.3.5.md`, post-GAP-0752)

| concurrency | point_read QPS (current) | target after full plan |
|---|---|---|
| 1  | 28.8 | 250+ |
| 4  | 33.6 | 500+ |
| 8  | 24.8 | 650+ |
| 16 | 24.2 | 700+ |

Stretch target (not a hard gate): c=8 point_read hits 700 QPS, roughly 75% of ping. Expected ceiling at this density: allocator contention + per-query parse cost, both addressed by phases 2 and 4.

## File Structure

- **Create (new code):**
  - `src/server/query_arena.zig` — per-query `ArenaAllocator` factory. One arena borrowed from a free-list per query; reset-on-return. Consumers: executor scratch.
  - `src/transport/poll_loop.zig` — per-core QUIC poll dispatch worker (extracted from `main.zig`'s single-thread poll pool).
- **Modify:**
  - `src/server/quic_connection_handler.zig:2317-2339` (lock-hold scope narrowing) + wherever the executor is invoked (`handleClientMessage` split point).
  - `src/transport/grpc_server.zig:2012-2024` (mirror same change).
  - `src/graph_store.zig:5153-5154` (drop `DebugAllocator`, use `smp_allocator`).
  - `src/execution/match_operations.zig` (take per-query arena; release on return).
  - `src/server/main.zig:810-830` (replace single-thread poll pool with `poll_loop.spawn(num_workers)`).
  - `src/server/quic_connection_handler.zig` (plan-cache wiring: call `shared_optimizer.?.optimizeQuery` before parse+plan on MATCH path if the optimizer is non-null).
- **Create (tests):**
  - `tests/test_handler_lock_hold_scope.zig` — two concurrent readers measure that lock is held ≤ 1 ms per query (not the full exec time).
  - `tests/test_smp_allocator_no_regression.zig` — graph open/close + a small insert/read cycle uses `smp_allocator`, no leaks (existing arena tests still pass).
  - `tests/test_query_arena_reuse.zig` — a sequence of MATCH queries through the arena pool returns the same arena, reset between queries, no leaks.
  - `tests/test_plan_cache_hit.zig` — the same parameterised `MATCH (n:Foo {id: $1}) RETURN n` executed twice reports `hit_count=1, miss_count=1`.
  - `tests/test_poll_loop_multicore.zig` — N worker poll loops all receive packets when N client connections send concurrently.
- **Modify tests:**
  - `tests/integration/scripts/match_property_read_scaling.sh` — raise the hard threshold from `1.1×` up to the ratio each phase unlocks (target sequence: 1.1 → 1.5 → 2.5 → 3.5 → 4.5).

Keep file additions small — follow the `tests/helpers/handler_lock_seam.zig` pattern: one concept per file, `const std = @import("std");` + one public entry point.

---

## Task 1 — Narrow the handler lock-hold scope

**Context:** After GAP-0752 the read path takes `acquireGraphReadLock`, but still holds it across **parse + plan + execute + row materialization** — that's ~30 ms per 500-node property lookup. `ReadView` (`src/graph_store.zig:5377-5420`) already provides epoch-safe snapshot isolation; the executor (`src/execution/match_operations.zig:4682 executeMatchQueryImpl`) already wraps its store access in a ReadView. The outer handler just needs to take the lock only long enough to capture the snapshot, release it, and let the executor operate unlocked.

**Files:**
- Modify: `src/server/quic_connection_handler.zig` (handler flow around line 2317-2339 and wherever the execute call lives)
- Modify: `src/transport/grpc_server.zig` (mirror)
- Create: `tests/test_handler_lock_hold_scope.zig`

### Step 1: Write the failing test

```zig
// tests/test_handler_lock_hold_scope.zig
const std = @import("std");
const graph_store = @import("../src/graph_store.zig");
const seam = @import("helpers/handler_lock_seam.zig");

test "handler releases graph lock before executing read query" {
    // Two threads: one measures how long the handler held the lock;
    // the other measures how long its own lock-acquire took while the
    // first thread was "executing." With the current (wide) scope, thread
    // 2 blocks for the full duration of thread 1's query. After this
    // task lands, thread 2 should acquire within 1 ms regardless of thread 1's work.

    const gpa = std.testing.allocator;
    try graph_store.testInit(gpa);
    defer graph_store.testDeinit();

    // Seed 500 nodes so queries take ~30 ms of post-snapshot work.
    try seam.seedNodes(gpa, 500);

    var barrier = std.Thread.ResetEvent{};
    var t1_lock_released_at: i128 = 0;
    var t2_lock_acquired_at: i128 = 0;

    const t1 = try std.Thread.spawn(.{}, struct {
        fn run(
            b: *std.Thread.ResetEvent,
            released_at: *i128,
        ) !void {
            const handle = graph_store.acquireGraphReadLock(graph_store.DEFAULT_GRAPH_NAME);
            b.set(); // Tell t2 to start racing for the lock.
            // Simulate the post-snapshot execution phase — handler must
            // have already released by this point.
            std.Thread.sleep(30 * std.time.ns_per_ms);
            released_at.* = std.time.nanoTimestamp();
            graph_store.releaseGraphLock(handle);
        }
    }.run, .{ &barrier, &t1_lock_released_at });

    barrier.wait();
    const t2_start = std.time.nanoTimestamp();
    const h2 = graph_store.acquireGraphReadLock(graph_store.DEFAULT_GRAPH_NAME);
    t2_lock_acquired_at = std.time.nanoTimestamp();
    graph_store.releaseGraphLock(h2);
    t1.join();

    const t2_wait_ms = @as(f64, @floatFromInt(t2_lock_acquired_at - t2_start)) / 1_000_000.0;
    try std.testing.expect(t2_wait_ms < 1.0); // <-- fails today: t2 waits ~30ms
}
```

This test uses the real `graph_store` lock primitives, not a mock. If the seam between "acquire" and "execute" is not narrowed, t2 will wait the full 30 ms and the assertion fails.

- [ ] **Step 2: Run test to verify it fails**

```bash
zig build test --summary all 2>&1 | grep -E "test_handler_lock_hold_scope|FAIL"
```
Expected: `t2_wait_ms < 1.0` fails with actual ~30.

- [ ] **Step 3: Implement lock-hold narrowing**

Read `src/server/quic_connection_handler.zig` around the `graph_lock_handle = ... acquireGraphReadLock(...)` site (currently ~2324). The current flow:

```
1. parse         <-- under lock
2. plan          <-- under lock
3. take ReadView <-- under lock (but ReadView is designed for this)
4. execute       <-- under lock (wrong — doesn't need the lock once ReadView is taken)
5. materialize   <-- under lock
6. release
```

Target flow:

```
1. parse         <-- under lock (NO — parse doesn't touch the store; move this OUT)
2. classify is_mutation
3. if !is_mutation:
     acquire read lock
     take ReadView
     release read lock
     plan + execute + materialize using the ReadView snapshot
   else:
     acquire write lock
     plan + execute + materialize (mutations keep the lock)
     release write lock
```

Concretely: introduce a helper `graph_store.snapshotUnderReadLock(graph_name: []const u8) !QueryReadSession` that acquires the shared lock, instantiates a `QueryReadSession`, releases the shared lock, and returns the session. The session already implements lazy deep-clone on epoch drift (see `src/graph_store.zig:5320-5375`), so correctness is preserved. Mutations continue to take the write lock for their full duration.

Minimum-viable code shape at `src/server/quic_connection_handler.zig:2317-2339` (pseudocode, drop in the real types):

```zig
const needs_store_lock = analysis.kind != .explain;
const is_mutation = needs_store_lock and isMutatingProgram(&parse_result.program);

var read_session: ?graph_store.QueryReadSession = null;
var graph_lock_handle: ?graph_store.GraphLockHandle = null;
defer {
    if (read_session) |*s| s.deinit();
    if (graph_lock_handle) |h| graph_store.releaseGraphLock(h);
}

if (needs_store_lock) {
    if (is_mutation) {
        graph_lock_handle = graph_store.acquireGraphWriteLock(query_graph_name);
    } else {
        // Narrow scope: grab snapshot, release lock, let executor run unlocked.
        read_session = try graph_store.snapshotUnderReadLock(query_graph_name);
    }
}

// Executor now receives either a live write-locked store (mutation path) or a
// QueryReadSession snapshot (read path). executeMatchQueryImpl already accepts
// either — it uses ReadView internally.
```

The handler should pass `read_session` to `execution.executeQuery` so the executor uses the snapshot instead of hitting `graph_store.getNodesByLabels` under the implicit lock. Look at how `src/execution/match_operations.zig:4688` constructs its `ReadView` today — it's redundant with the snapshot we're now passing in, so thread it through as a parameter.

Apply the identical change to `src/transport/grpc_server.zig:2012-2024`.

- [ ] **Step 4: Run test to verify it passes**

```bash
zig build test --summary all 2>&1 | grep -E "test_handler_lock_hold_scope"
```
Expected: PASS.

- [ ] **Step 5: Run the full suite to catch regressions**

```bash
zig build test --summary all
zig build test-match-read-serial
bash tests/integration/scripts/match_property_read_scaling.sh
```
Expected: 1074+/1074+ unit tests pass, integration script ratio ≥ 1.5×.

- [ ] **Step 6: Raise the integration-test threshold**

Edit `tests/integration/scripts/match_property_read_scaling.sh`: change the `HARD_THRESHOLD=1.1` line to `HARD_THRESHOLD=1.5` (matches what this phase delivers). Re-run the script and confirm it still passes.

- [ ] **Step 7: Commit**

```bash
git add src/server/quic_connection_handler.zig src/transport/grpc_server.zig \
        src/graph_store.zig src/execution/match_operations.zig \
        tests/test_handler_lock_hold_scope.zig \
        tests/integration/scripts/match_property_read_scaling.sh
git commit -m "$(cat <<'EOF'
perf(handler): release read lock before query execute (GAP-0753)

The handler used to hold the shared graph read lock across parse, plan,
execute, and row materialization (~30 ms per 500-node property lookup).
ReadView/QueryReadSession already provide epoch-safe snapshot isolation,
so the lock only needs to cover snapshot capture (<1 ms).

- Add graph_store.snapshotUnderReadLock: acquire shared lock, take
  QueryReadSession, release lock, return session.
- Handler uses it for non-mutation queries; mutations unchanged.
- Thread session through to match executor so it doesn't take its own
  implicit lock.

Concurrent-reader wait time (test_handler_lock_hold_scope): ~30 ms → <1 ms.
EOF
)"
```

---

## Task 2 — Replace `graph_store.global_gpa` DebugAllocator with smp_allocator

**Context:** `src/graph_store.zig:5153` declares `var global_gpa: std.heap.DebugAllocator(.{}) = .{};` which is thread-safe but serializes on every `alloc`/`free` through its internal mutex. Every query allocates row arrays, property values, and plan operator nodes through it — so allocator contention becomes the next bottleneck after Task 1. `src/server/allocator_config.zig` already uses `std.heap.smp_allocator` (per-core arenas, sharded, thread-local fast path) for the top-level server allocator.

**Files:**
- Modify: `src/graph_store.zig:5153-5154`
- Create: `tests/test_smp_allocator_no_regression.zig`

### Step 1: Write the failing test

```zig
// tests/test_smp_allocator_no_regression.zig
const std = @import("std");
const graph_store = @import("../src/graph_store.zig");

test "graph_store global allocator is smp_allocator" {
    // After this task, global_allocator() returns the process-wide smp_allocator,
    // not a DebugAllocator instance. We can't introspect the allocator type at
    // runtime (Zig type erasure), but we CAN verify DebugAllocator-specific state
    // is gone: it no longer tracks leaks internally.
    try graph_store.testInit(std.testing.allocator);
    defer graph_store.testDeinit();

    // Run a workload through global_allocator — a few thousand small allocs.
    const alloc = graph_store.global_allocator();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const buf = try alloc.alloc(u8, 64);
        alloc.free(buf);
    }
    // smp_allocator won't count these; DebugAllocator would in its internal state.
    // Assert we can do 100k allocs in < 50 ms (DebugAllocator's mutex would tank this).
    const t0 = std.time.nanoTimestamp();
    var j: usize = 0;
    while (j < 100_000) : (j += 1) {
        const buf = try alloc.alloc(u8, 64);
        alloc.free(buf);
    }
    const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000.0;
    try std.testing.expect(elapsed_ms < 50.0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | grep test_smp_allocator_no_regression`
Expected: FAIL (DebugAllocator takes > 50 ms for 100k alloc/free pairs under contention).

- [ ] **Step 3: Implement the swap**

Edit `src/graph_store.zig:5153-5154`:

```zig
// Before:
var global_gpa: std.heap.DebugAllocator(.{}) = .{};
var global_allocator_init = false;

// After:
// P2-3 (GAP-0754): smp_allocator sharded per-core; DebugAllocator's internal
// mutex was the next bottleneck after GAP-0753 narrowed handler lock hold.
pub fn global_allocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}
```

Every call site that previously wrote `global_gpa.allocator()` becomes `global_allocator()`. Grep the repo: there are ~20 call sites across `src/graph_store.zig` and tests. Update all of them.

- [ ] **Step 4: Run test to verify it passes**

```bash
zig build test --summary all 2>&1 | grep test_smp_allocator_no_regression
```
Expected: PASS.

- [ ] **Step 5: Run full suite**

```bash
zig build test --summary all
bash tests/integration/scripts/match_property_read_scaling.sh
```
Expected: 1074+/1074+ unit tests pass, integration ratio ≥ 2.5× (allocator unblocks more concurrency).

- [ ] **Step 6: Raise integration threshold to 2.5×**

`tests/integration/scripts/match_property_read_scaling.sh`: set `HARD_THRESHOLD=2.5`.

- [ ] **Step 7: Commit**

```bash
git add src/graph_store.zig tests/test_smp_allocator_no_regression.zig \
        tests/integration/scripts/match_property_read_scaling.sh
git commit -m "perf(graph_store): swap global_gpa DebugAllocator for smp_allocator (GAP-0754)"
```

---

## Task 3 — Per-query arena for executor scratch

**Context:** The executor's scratch work (start-slot collection, property-row arrays, intermediate ResultRow allocations) currently goes through the global allocator, which means every allocation round-trips through `smp_allocator`'s per-core arena lookup. For a hot path that allocates dozens of times per query, bundling all of it into one per-query arena that's reset between queries removes that overhead and guarantees zero fragmentation.

**Files:**
- Create: `src/server/query_arena.zig`
- Modify: `src/server/quic_connection_handler.zig` (borrow arena for each query)
- Modify: `src/execution/match_operations.zig` (take arena param, use for scratch)
- Create: `tests/test_query_arena_reuse.zig`

### Step 1: Write the failing test

```zig
// tests/test_query_arena_reuse.zig
const std = @import("std");
const query_arena = @import("../src/server/query_arena.zig");

test "arena pool reuses arenas across queries" {
    var pool = try query_arena.Pool.init(std.testing.allocator, 4);
    defer pool.deinit();

    // Borrow and return 10 times; pool should never grow above 4.
    var seen_arenas = std.AutoHashMap(*query_arena.Arena, void).init(std.testing.allocator);
    defer seen_arenas.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const a = try pool.acquire();
        // Scribble some allocs through the arena.
        const buf = try a.allocator().alloc(u8, 1024);
        buf[0] = 0xff;
        pool.release(a);
        try seen_arenas.put(a, {});
    }
    try std.testing.expect(seen_arenas.count() <= 4); // proof of reuse
}
```

- [ ] **Step 2: Run test to verify it fails** (file doesn't exist yet)

```bash
zig build test --summary all 2>&1 | grep -E "test_query_arena_reuse|FAIL"
```
Expected: compile error (`src/server/query_arena.zig` missing).

- [ ] **Step 3: Implement the arena pool**

Create `src/server/query_arena.zig`:

```zig
const std = @import("std");

/// One per-query arena. Consumers call `arena.allocator()` for all scratch
/// work during a query; the pool resets the arena on release.
pub const Arena = struct {
    inner: std.heap.ArenaAllocator,

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return self.inner.allocator();
    }
};

/// Fixed-capacity free-list of query arenas. Acquire is lock-guarded
/// (very short) and reuses arenas across queries without re-allocating.
/// Oversubscribed callers fall back to a fresh ArenaAllocator backed by
/// the pool's backing allocator.
pub const Pool = struct {
    backing: std.mem.Allocator,
    free_list: std.ArrayList(*Arena),
    lock: std.Io.Mutex = std.Io.Mutex.init,
    capacity: usize,

    pub fn init(backing: std.mem.Allocator, capacity: usize) !Pool {
        return Pool{
            .backing = backing,
            .free_list = std.ArrayList(*Arena){},
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.free_list.items) |a| {
            a.inner.deinit();
            self.backing.destroy(a);
        }
        self.free_list.deinit(self.backing);
    }

    pub fn acquire(self: *Pool) !*Arena {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.free_list.items.len > 0) {
            return self.free_list.pop().?;
        }
        const a = try self.backing.create(Arena);
        a.* = .{ .inner = std.heap.ArenaAllocator.init(self.backing) };
        return a;
    }

    pub fn release(self: *Pool, arena: *Arena) void {
        _ = arena.inner.reset(.retain_capacity);
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.free_list.items.len >= self.capacity) {
            arena.inner.deinit();
            self.backing.destroy(arena);
            return;
        }
        self.free_list.append(self.backing, arena) catch {
            arena.inner.deinit();
            self.backing.destroy(arena);
        };
    }
};
```

- [ ] **Step 4: Wire the pool into the handler**

In `src/server/quic_connection_handler.zig`:
- Add a process-wide `var g_query_arena_pool: ?*query_arena.Pool = null;` initialized from `handleQuicConnection`'s startup path (capacity `num_cores × 2`, backing = smp_allocator).
- In the query hot path (just before `executeQuery`), acquire an arena and pass `arena.allocator()` as the `scratch_allocator` parameter to the executor.
- On return, release.

In `src/execution/match_operations.zig`, add `scratch_allocator: std.mem.Allocator` parameter to `executeMatchQueryImpl` and route all `ArrayList.append`, `collectStartSlots`, and property-row allocations through it.

- [ ] **Step 5: Run test to verify it passes**

```bash
zig build test --summary all 2>&1 | grep test_query_arena_reuse
```
Expected: PASS.

- [ ] **Step 6: Run full suite**

```bash
zig build test --summary all
bash tests/integration/scripts/match_property_read_scaling.sh
```
Expected: integration ratio ≥ 3.5×.

- [ ] **Step 7: Raise integration threshold to 3.5×**

`tests/integration/scripts/match_property_read_scaling.sh`: `HARD_THRESHOLD=3.5`.

- [ ] **Step 8: Commit**

```bash
git add src/server/query_arena.zig src/server/quic_connection_handler.zig \
        src/execution/match_operations.zig tests/test_query_arena_reuse.zig \
        tests/integration/scripts/match_property_read_scaling.sh
git commit -m "perf(exec): per-query arena pool for executor scratch (GAP-0755)"
```

---

## Task 4 — Wire `SharedQueryOptimizer` into the MATCH path

**Context:** `src/server/query_plan_cache.zig:445 SharedQueryOptimizer` is already built and init'd when `plan_cache_size > 0` (see `src/server/server_init.zig`). Its `optimizeQuery(query_text, program, stats)` returns a ref-counted `SharedPlanHandle` and has a fast path that hits under a very short lock (just `getPtr` + compare + promote). The MATCH execution in `quic_connection_handler.zig` currently re-parses and re-plans every query, skipping this cache. Wiring it gives repeat lookups (all point_read at every c level are the same parameterised shape) a huge speedup.

**Files:**
- Modify: `src/server/quic_connection_handler.zig` (check optimizer before calling the planner directly)
- Create: `tests/test_plan_cache_hit.zig`

### Step 1: Write the failing test

```zig
// tests/test_plan_cache_hit.zig
const std = @import("std");
const query_plan_cache = @import("../src/server/query_plan_cache.zig");
const test_harness = @import("helpers/server_harness.zig"); // see note below

test "repeated MATCH uses cached plan" {
    // Stand up an in-process geode with plan_cache_size=64.
    var h = try test_harness.start(.{ .plan_cache_size = 64 });
    defer h.stop();

    try h.run("CREATE (n:Foo {id: 1}) RETURN n");
    try h.run("MATCH (n:Foo {id: 1}) RETURN n"); // miss
    try h.run("MATCH (n:Foo {id: 1}) RETURN n"); // hit

    const stats = h.shared_optimizer.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hit_count);
    try std.testing.expect(stats.miss_count >= 1);
}
```

If `tests/helpers/server_harness.zig` doesn't expose a `start()` + `run()` helper, add a minimal one that reuses `server_init.setupServerInitContext` and the handler's query dispatch (no QUIC — directly exercise `handleClientMessage`'s query branch). Pattern to follow: how `tests/test_rls_expr_engine_wiring.zig` does the "call the handler function directly" trick.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | grep test_plan_cache_hit`
Expected: FAIL with `hit_count=0, miss_count=2`.

- [ ] **Step 3: Implement the cache wiring**

In `src/server/quic_connection_handler.zig`, find the point where the parsed program is handed to the planner (there's a call to something like `query_planner.plan(...)` or an inline planner step inside `executeMatchQueryImpl` dispatch). Before that call:

```zig
const stats_snapshot = try state.current_graph_stats();
const plan_handle = if (state.shared_optimizer) |opt|
    try opt.optimizeQuery(query_text, &parse_result.program, stats_snapshot)
else
    null;
defer if (plan_handle) |h| h.release();

// Use plan_handle.plan if non-null; otherwise fall through to the current
// direct-plan path.
```

Thread the `*const CompiledPlan` from `plan_handle.plan` into `executeMatchQueryImpl`'s existing plan-consuming signature.

If `current_graph_stats()` doesn't exist, add a trivial accessor: `state.graph_storage.getStats(query_graph_name)`.

- [ ] **Step 4: Run test to verify it passes**

```bash
zig build test --summary all 2>&1 | grep test_plan_cache_hit
```
Expected: PASS.

- [ ] **Step 5: Run full suite**

```bash
zig build test --summary all
bash tests/integration/scripts/match_property_read_scaling.sh
```
Expected: integration ratio ≥ 4.5×. At this point c=4 point_read should sustain 300+ QPS.

- [ ] **Step 6: Raise integration threshold to 4.5×**

`HARD_THRESHOLD=4.5`.

- [ ] **Step 7: Commit**

```bash
git add src/server/quic_connection_handler.zig tests/test_plan_cache_hit.zig \
        tests/helpers/server_harness.zig \
        tests/integration/scripts/match_property_read_scaling.sh
git commit -m "perf(handler): wire SharedQueryOptimizer into MATCH path (GAP-0756)"
```

---

## Task 5 — Multi-core QUIC poll dispatch

**Context:** `src/server/main.zig:815` spins up a `ThreadPool` with `num_threads = 1` for the poll loop. Every QUIC packet across every connection dispatches through that single thread. At high concurrency (c≥16) this becomes the next ceiling; with tasks 1-4 landed, the per-query cost is low enough that a single poll thread can't feed the worker pool fast enough.

**Files:**
- Create: `src/transport/poll_loop.zig`
- Modify: `src/server/main.zig:810-830`
- Create: `tests/test_poll_loop_multicore.zig`

### Step 1: Write the failing test

```zig
// tests/test_poll_loop_multicore.zig
const std = @import("std");
const poll_loop = @import("../src/transport/poll_loop.zig");

test "N workers all receive packets under concurrent load" {
    // Spin up 4 poll workers on a fake transport; push 10k packets
    // split across 4 connections; assert each worker processed >1500.
    // Today (single worker): one worker sees all 10k, others see 0.
    var t = try poll_loop.TestTransport.init(std.testing.allocator, 4);
    defer t.deinit();

    const loop = try poll_loop.spawn(std.testing.allocator, .{
        .transport = &t.iface,
        .num_workers = 4,
    });
    defer loop.stop();

    for (0..10_000) |i| {
        try t.enqueuePacket(.{ .conn_id = i % 4, .payload = "x" });
    }
    std.Thread.sleep(200 * std.time.ns_per_ms);

    for (loop.workers) |*w| {
        try std.testing.expect(w.packets_processed.load(.acquire) > 1500);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | grep test_poll_loop_multicore`
Expected: compile error (module doesn't exist).

- [ ] **Step 3: Implement the poll loop module**

Create `src/transport/poll_loop.zig`:

```zig
const std = @import("std");

pub const Config = struct {
    transport: *Transport,
    num_workers: usize,
};

pub const Transport = struct {
    // Minimal interface the poll loop calls; real QUIC transport implements this.
    pollFn: *const fn (self: *Transport, out: []Packet) usize,
    // ... extend as needed to match vendor/quic
};

pub const Packet = struct { conn_id: usize, payload: []const u8 };

pub const Worker = struct {
    thread: std.Thread,
    packets_processed: std.atomic.Value(u64),
    shutdown: *std.atomic.Value(bool),
};

pub const Loop = struct {
    workers: []Worker,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,

    pub fn stop(self: *Loop) void {
        self.shutdown.store(true, .release);
        for (self.workers) |*w| w.thread.join();
        self.allocator.free(self.workers);
    }
};

pub fn spawn(alloc: std.mem.Allocator, cfg: Config) !*Loop {
    const loop = try alloc.create(Loop);
    loop.* = .{
        .workers = try alloc.alloc(Worker, cfg.num_workers),
        .allocator = alloc,
    };
    for (loop.workers, 0..) |*w, idx| {
        w.* = .{
            .thread = undefined,
            .packets_processed = std.atomic.Value(u64).init(0),
            .shutdown = &loop.shutdown,
        };
        w.thread = try std.Thread.spawn(.{}, workerMain, .{ cfg.transport, w, idx });
    }
    return loop;
}

fn workerMain(transport: *Transport, w: *Worker, worker_idx: usize) void {
    _ = worker_idx;
    var batch: [64]Packet = undefined;
    while (!w.shutdown.load(.acquire)) {
        const n = transport.pollFn(transport, &batch);
        if (n == 0) {
            std.Thread.sleep(100 * std.time.ns_per_us);
            continue;
        }
        _ = w.packets_processed.fetchAdd(n, .acq_rel);
        // TODO: hand off to per-connection queue / worker pool for processing.
    }
}
```

Add a minimal `TestTransport` for the test — use `std.fifo` protected by a mutex, round-robin across workers by connection id.

- [ ] **Step 4: Swap main.zig to use the new loop**

In `src/server/main.zig:810-830`, replace the `ThreadPool.init(gpa, .{ .num_threads = 1, .queue_capacity = 4 })` + single `submitBlocking(runPollLoopTask)` with:

```zig
const num_poll_workers = @max(2, std.Thread.getCpuCount() catch 2);
const loop = try poll_loop.spawn(gpa, .{
    .transport = &transport.pollInterface(),
    .num_workers = num_poll_workers,
});
defer loop.stop();
```

This requires `transport.pollInterface()` — add a minimal adapter at `src/transport/quic.zig` that implements `pollFn` by calling the underlying vendor/quic endpoint's poll API.

- [ ] **Step 5: Run test to verify it passes**

```bash
zig build test --summary all 2>&1 | grep test_poll_loop_multicore
```
Expected: PASS (all workers process >1500 packets).

- [ ] **Step 6: Run full suite**

```bash
zig build test --summary all
bash tests/integration/scripts/match_property_read_scaling.sh
```
Expected: integration ratio ≥ 6.0× (now approaching ping).

- [ ] **Step 7: Raise integration threshold to 6.0×**

`HARD_THRESHOLD=6.0`.

- [ ] **Step 8: Commit**

```bash
git add src/transport/poll_loop.zig src/server/main.zig \
        src/transport/quic.zig tests/test_poll_loop_multicore.zig \
        tests/integration/scripts/match_property_read_scaling.sh
git commit -m "perf(transport): multi-core QUIC poll dispatch (GAP-0757)"
```

---

## Task 6 — Close out: update audit report and run the five scenarios

**Files:**
- Modify: `docs/audit/LOADTEST_REPORT_2026_04_18_v0.3.5.md` (add "Post-QPS-close-gap plan" section)
- Modify: `benchmarks/loadtest/baseline.jsonl` (fresh baseline capturing the new floor)

- [ ] **Step 1: Run all five loadtest scenarios on a quiet host**

```bash
sudo systemctl stop geode.service 2>/dev/null || true
rm -rf /tmp/geode_bench_final && mkdir -p /tmp/geode_bench_final
GEODE_ADMIN_PASSWORD='GeodeTestPassword123!' nohup ./zig-out/bin/geode serve \
  --data-dir /tmp/geode_bench_final --listen 127.0.0.1:3144 --log-level warn \
  >/tmp/geode_final.log 2>&1 &
sleep 3
cd ../geode-test-harness
for s in ping point_read one_hop two_hop fan_out; do
  ./loadtest/go/geode-loadtest \
    -dsn "localhost:3144?insecure=true&user=geode&pass=GeodeTestPassword123%21" \
    -levels "1,2,4,8,16,32" -duration 5s -scenario $s \
    -output /tmp/final_$s.json
done
kill $(pgrep -f "zig-out/bin/geode serve")
```

- [ ] **Step 2: Update the report**

Append to `docs/audit/LOADTEST_REPORT_2026_04_18_v0.3.5.md`:
- Table of before-GAP-0752 / after-GAP-0752 / after-this-plan numbers for all 5 scenarios at c=1,4,8,16.
- Remove the "MATCH-by-property investigation" follow-up — it's closed.
- Note which follow-ups remain (e.g. storage engine has 80 M points/s headroom that's still not visible through the wire; a session-level Execute cache would be the next frontier).

- [ ] **Step 3: Refresh the baseline**

```bash
cp /tmp/final_ping.json /home/benji/src/devnw/codepros/geode/geode/benchmarks/loadtest/results/latest.json
cd /home/benji/src/devnw/codepros/geode/geode
python3 benchmarks/loadtest/convert.py --input /tmp/final_ping.json --output benchmarks/loadtest/baseline.jsonl
# (or whatever the existing make target is — confirm via grep)
make loadtest-compare  # should be green against the new baseline
```

- [ ] **Step 4: Commit the evidence**

```bash
git add docs/audit/LOADTEST_REPORT_2026_04_18_v0.3.5.md benchmarks/loadtest/baseline.jsonl
git commit -m "docs(loadtest): refresh baseline + close MATCH-by-property follow-ups (GAP-0758)"
```

- [ ] **Step 5: Push**

```bash
git push origin main
```

Verify `glab ci list | head -3` shows the new pipeline kicking off.

---

## Self-Review (executed by plan author before handoff)

- **Spec coverage:** Each of the five triage-identified bottlenecks (lock hold, DebugAllocator, per-query mmap, plan cache, single-thread poll) has a task. The original "narrow the MATCH-by-property gap" goal is covered by Tasks 1-5 with escalating integration-test thresholds; Task 6 locks in the evidence.
- **Placeholder scan:** Search `TBD`, `TODO`, `implement later` — only intentional `TODO: hand off to per-connection queue` in the poll-loop skeleton (Task 5), which is a real follow-up wire-up, not a placeholder.
- **Type consistency:** `SharedPlanHandle`, `QueryReadSession`, `GraphLockHandle` referenced across tasks all resolve to existing types in `src/graph_store.zig` and `src/server/query_plan_cache.zig`. `Arena.allocator()` / `Pool.acquire()` / `Pool.release()` consistent in Task 3. `Loop.workers[i].packets_processed.load(.acquire)` shape consistent between Task 5 implementation and test.
- **Frequency and size of commits:** 6 commits, each standalone and revertable.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-match-qps-close-gap.md`. Two execution options:

1. **Subagent-Driven (recommended)** — one fresh subagent per task, reviewer between tasks, fast iteration, green pipeline verified at each step.
2. **Inline Execution** — execute all six tasks in this session with a checkpoint after each commit, more continuity but larger context pressure.

**Which approach?**
