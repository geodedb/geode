# Graph Sharding, WAL Group Commit, and Client Pipelining Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break through the ~40-minute wall on `msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000` and land the 44,558-statement ingest in **≤ 60 seconds**. The 2026-04-23 session collapsed R13's 2 h 5 m to a clean ~25-40 min for ~14 of 16 edge files, but two structural ceilings remain: (1) the per-graph group-commit coordinator is a single serialisation point per graph — under 16-way fan-in on the two 8 k+ edge files (`edges_signed_in_from`, `edges_signed_in_to`) the coordinator's own 30 s write-lock deadline fires while draining, triggering 40001 timeouts that msft-graph escalates to serial fallback; (2) the node phase still spends ~30 s per file on the Go client's QUIC reconnect cadence. This plan ships the three architectural changes that break both ceilings.

**Architecture:** Three independent pillars, each measurable on its own. **(1) Shard the in-memory `GraphStore` by `node_id % N` (default N=16).** Replace the single `std.AutoHashMap(u64, Node)` / `std.AutoHashMap(u64, Edge)` with `ShardedStore` — N independent HashMaps, each guarded by its own rwlock. Aux indexes (`outgoing_edges`, `incoming_edges`, `merge_prop_index`) follow the same shard key. Readers take one shard's read lock for point lookups or all N in order for full scans; writers take one shard's write lock per op. **(2) Scale the group-commit coordinator from 1 thread per graph to N threads per graph, one per shard.** `GroupCommitCoordinator` becomes `ShardedCoordinator` with per-shard queues; `submit()` routes by `shard = f(primary_node_id) % N`. Each shard thread drains its queue under its shard's write lock, so 16-way writer fan-in runs genuinely concurrent across disjoint keyspaces — no more queue-depth-driven deadlines. **(3) Decouple WAL fsync from apply with a per-graph `WalFlusher` background thread.** Shard coordinators `appendRecord` without fsync, enqueue the LSN on the flusher's queue with their op's `done` flag; the flusher groups across shards, issues ONE `fsync` per batch window (default 500 µs), and wakes every submitter whose LSN is now durable. Crash recovery is unchanged (WAL replay on startup). **(4, client-side) Replace msft-graph's per-file `pool.DB().Conn` acquisition with a persistent per-worker QUIC session** that stays open for the entire seed run, with server-side stream-level transaction boundaries. The 30 s-per-file QUIC handshake cost collapses to one handshake for the whole run.

**Tech Stack:** Zig 0.16.0+ (`std.Io.RwLock`, `std.Io.Mutex`, `std.Io.Condition`, `std.atomic.Value(u32)` + `std.Io.futex*`), external `graph_storage` engine (`WalManager.appendRecord` / `WalManager.sync` — confirmed separable at `engine.zig:86` wal field, `wal.zig:78,99`), `msft-graph` Go client at `/home/benji/src/devnw/go/msft/cmd/msft-graph/` (`database/sql` pool at `geodeutil.go:272,326`), `geode-client-go` QUIC driver at `/home/benji/src/devnw/codepros/geode/geode-client-go/`. Host verification tools: `msft-graph seed` (end-to-end), `zig build test` (unit + integration), `strace -ttt -e trace=fsync` (WAL flusher validation), `perf stat -e context-switches` (coordinator concurrency validation).

---

## Pre-work: verify baseline and previous-plan state

Before starting, confirm the 2026-04-23 work is fully on `main` and reproduces the "~40 min → cascade" baseline. This plan builds directly on that artifact.

- [ ] **Step 0.1: Confirm the enterprise-ingest commits are on `main`.**

  Run:

  ```bash
  git -C /home/benji/src/devnw/codepros/geode/geode log --oneline -20 | grep -E "Task (11|12|16|17|19)|group-commit|group.commit|deinit_timeout_ns|RLSFilter.*fast path|bulk node txn batching" | head
  ```

  Expected: five or more matches, including `2588e872 perf(bulk): per-graph group-commit coordinator`, `e338e6eb perf(bulk): tune group-commit batch cap`, `ffb8b3c0 perf(server): cut thread-pool deinit timeout`. If any are missing, stop and investigate — this plan assumes that baseline.

- [ ] **Step 0.2: Reproduce the ~40 min cascade baseline.**

  Run:

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-sharding-baseline && mkdir -p /tmp/geode-sharding-baseline
  cd /home/benji/src/devnw/codepros/geode/geode
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
    nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-sharding-baseline \
      --listen 127.0.0.1:3143 --log-level warn \
      > /tmp/geode-sharding-baseline/server.log 2>&1 &
  SERVER_PID=$!
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3143 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session \
    "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  echo "=== start $(date -Iseconds) ==="
  time GEODE_DSN="quic://127.0.0.1:3143/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
    msft-graph seed --input /home/benji/eagleg-topology-data-16 \
    --parallel --workers 16 --chunk-size 1000 2>&1 | tail -30
  echo "=== end $(date -Iseconds) ==="
  kill -9 $SERVER_PID 2>/dev/null || true
  ```

  Expected: the run reaches `edges_signed_in_from` within 30-40 min and then cascades to serial-fallback (you can kill it manually after 45 min if the cascade is visible). Record the wall-clock and the last successful file into `docs/performance/2026-04-24-sharding/baseline.txt` before starting Phase 1. The goal at the end of Phase 5 is **≤ 60 s total** on this same command.

- [ ] **Step 0.3: Confirm the existing regression suites pass.**

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  zig build test-r6-parallel-ingest test-graph-write-lock-cancelable \
      test-undo-log-isolation test-orphan-txn-cleanup \
      test-match-read-serial test-handler-lock-hold-scope 2>&1 | tail -20
  ```

  Expected: exit 0. If any fail, stop — this plan depends on those invariants holding.

- [ ] **Step 0.4: Create the evidence directory.**

  ```bash
  mkdir -p /home/benji/src/devnw/codepros/geode/geode/docs/performance/2026-04-24-sharding
  ```

  Every phase writes its before/after measurements here as separate files (`phase1-before.txt`, `phase1-after.txt`, …).

---

## Phase 1 — Sharded in-memory store (data-structure foundation)

The single `store.nodes: std.AutoHashMap(u64, Node)` is the root serialisation point: any write that `put()`s a new key may rehash the underlying backing array, which is incompatible with any reader or concurrent writer. Sharding the map into N independent maps, each with its own rwlock, removes this dependency and unlocks Phase 2 (N coordinator threads). This phase is pure data-structure refactoring — no concurrency logic yet. At end of phase, the store is sharded but the coordinator is still single-threaded, so ingest wall-clock time is unchanged.

### Task 1: Add `ShardedNodeStore` type

**Files:**
- Create: `src/storage/sharded_store.zig`
- Test: `tests/storage/test_sharded_store.zig`
- Modify: `src/root.zig` (export the new module)
- Modify: `build.zig` (wire the test target)

The goal: a `ShardedStore(K, V)` generic that wraps `N` independent `AutoHashMap(K, V)`s behind a shard-index function. Initial N = 16. Single-threaded API — concurrency comes in Phase 2.

- [ ] **Step 1.1: Write the failing test.**

  Create `tests/storage/test_sharded_store.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const sharded = @import("geode").sharded_store;

  test "ShardedStore: put/get round-trip across all shards" {
      var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
      defer store.deinit();

      // Put enough keys that at least one lands in every shard by
      // virtue of the mixing function.
      var i: u64 = 0;
      while (i < 1024) : (i += 1) {
          try store.put(i, @as(u32, @intCast(i * 3)));
      }
      i = 0;
      while (i < 1024) : (i += 1) {
          try testing.expectEqual(@as(u32, @intCast(i * 3)), store.get(i).?);
      }

      // Every shard got at least one key.
      var populated: usize = 0;
      for (0..sharded.SHARD_COUNT) |s| {
          if (store.shardCount(s) > 0) populated += 1;
      }
      try testing.expect(populated == sharded.SHARD_COUNT);
  }

  test "ShardedStore: shardIndex is stable for the same key" {
      try testing.expectEqual(sharded.shardIndex(42), sharded.shardIndex(42));
      try testing.expectEqual(sharded.shardIndex(0), sharded.shardIndex(0));
  }

  test "ShardedStore: remove returns the prior value" {
      var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
      defer store.deinit();
      try store.put(7, 99);
      const removed = store.remove(7);
      try testing.expectEqual(@as(?u32, 99), removed);
      try testing.expect(store.get(7) == null);
  }

  test "ShardedStore: total count sums the shards" {
      var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
      defer store.deinit();
      try store.put(1, 1);
      try store.put(2, 2);
      try store.put(3, 3);
      try testing.expectEqual(@as(usize, 3), store.count());
  }
  ```

- [ ] **Step 1.2: Run test to verify it fails.**

  Run: `zig build test-sharded-store 2>&1 | tail -5`

  Expected: build failure — `@import("geode").sharded_store` does not exist.

- [ ] **Step 1.3: Implement `ShardedStore`.**

  Create `src/storage/sharded_store.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! N-way sharded HashMap wrapper.  Each shard is an independent
  //! `std.AutoHashMap` with its own allocator backing.  Keys route to
  //! shard `shardIndex(key) = splitmix64(key) % SHARD_COUNT`.
  //!
  //! Concurrency model: this type is single-threaded by itself.  The
  //! per-shard `std.Io.RwLock`s that gate concurrent access live on
  //! `ManagedGraph` (see `graph_storage_adapter.zig`), NOT here —
  //! the separation exists so tests can exercise the sharding logic
  //! without a thread runtime.

  const std = @import("std");

  /// Number of shards.  Powers of two are fastest (bitmask route) but
  /// any value works.  16 is chosen to match the msft-graph worker
  /// count and the target fan-in for the 8 k+ edge files.
  pub const SHARD_COUNT: usize = 16;

  /// Fast integer mixing (splitmix64) — avalanches both low and high
  /// bits so consecutive node_ids spread across shards.  This matters:
  /// `graph_store.next_node_id` allocates monotonically, so a
  /// low-bits-only hash would put 16 consecutive new ids on 16
  /// different shards which is actually fine, but the same function
  /// is reused for edge source_ids which can be arbitrary.
  pub fn shardIndex(key: u64) usize {
      var z = key +% 0x9E3779B97F4A7C15;
      z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
      z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
      z = z ^ (z >> 31);
      return @as(usize, @intCast(z % SHARD_COUNT));
  }

  /// Generic sharded store over comptime-known K/V.  K must be an
  /// integer type (u64 is the only caller today).
  pub fn ShardedStore(comptime K: type, comptime V: type) type {
      return struct {
          const Self = @This();
          pub const Shard = std.AutoHashMap(K, V);

          allocator: std.mem.Allocator,
          shards: [SHARD_COUNT]Shard,

          pub fn init(allocator: std.mem.Allocator) !Self {
              var shards: [SHARD_COUNT]Shard = undefined;
              for (&shards) |*s| s.* = Shard.init(allocator);
              return .{ .allocator = allocator, .shards = shards };
          }

          pub fn deinit(self: *Self) void {
              for (&self.shards) |*s| s.deinit();
          }

          pub fn put(self: *Self, key: K, value: V) !void {
              const idx = shardIndex(@as(u64, @intCast(key)));
              try self.shards[idx].put(key, value);
          }

          pub fn get(self: *const Self, key: K) ?V {
              const idx = shardIndex(@as(u64, @intCast(key)));
              return self.shards[idx].get(key);
          }

          pub fn getPtr(self: *Self, key: K) ?*V {
              const idx = shardIndex(@as(u64, @intCast(key)));
              return self.shards[idx].getPtr(key);
          }

          pub fn remove(self: *Self, key: K) ?V {
              const idx = shardIndex(@as(u64, @intCast(key)));
              if (self.shards[idx].fetchRemove(key)) |kv| return kv.value;
              return null;
          }

          pub fn contains(self: *const Self, key: K) bool {
              const idx = shardIndex(@as(u64, @intCast(key)));
              return self.shards[idx].contains(key);
          }

          pub fn count(self: *const Self) usize {
              var total: usize = 0;
              for (&self.shards) |*s| total += s.count();
              return total;
          }

          pub fn shardCount(self: *const Self, idx: usize) usize {
              return self.shards[idx].count();
          }

          /// Iterate every (k, v) pair across every shard, in shard
          /// order.  Used by persistence and full-scan reads.  Callers
          /// that need a consistent snapshot must take a read lock on
          /// EVERY shard before calling — see `ManagedGraph.scanRead`.
          pub fn iterator(self: *Self) Iterator {
              return .{ .owner = self, .shard_idx = 0, .inner = self.shards[0].iterator() };
          }

          pub const Iterator = struct {
              owner: *Self,
              shard_idx: usize,
              inner: Shard.Iterator,

              pub fn next(it: *Iterator) ?Shard.Entry {
                  while (true) {
                      if (it.inner.next()) |entry| return entry;
                      it.shard_idx += 1;
                      if (it.shard_idx >= SHARD_COUNT) return null;
                      it.inner = it.owner.shards[it.shard_idx].iterator();
                  }
              }
          };
      };
  }
  ```

- [ ] **Step 1.4: Wire the module into `src/root.zig`.**

  Find the block near the top of `src/root.zig` that re-exports storage modules (search for `graph_storage_adapter = @import("storage/graph_storage_adapter.zig")`).  Add a sibling:

  ```zig
  pub const sharded_store = @import("storage/sharded_store.zig");
  ```

- [ ] **Step 1.5: Add the test target to `build.zig`.**

  Find the `test-sharded-store` block by searching for an existing per-test target such as `test-r6-parallel-ingest`.  Add immediately after:

  ```zig
  {
      const test_step = b.step("test-sharded-store", "Run sharded-store unit tests");
      const t = b.addTest(.{
          .root_module = b.createModule(.{
              .root_source_file = b.path("tests/storage/test_sharded_store.zig"),
              .target = target,
              .optimize = optimize,
              .imports = &.{.{ .name = "geode", .module = geode_module }},
          }),
      });
      const run = b.addRunArtifact(t);
      test_step.dependOn(&run.step);
  }
  ```

- [ ] **Step 1.6: Run the test to verify it passes.**

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  zig build test-sharded-store 2>&1 | tail -5
  ```

  Expected: `All <N> tests passed.` / exit 0.

- [ ] **Step 1.7: Commit.**

  ```bash
  git add src/storage/sharded_store.zig src/root.zig build.zig tests/storage/test_sharded_store.zig
  git commit -m "feat(storage): add ShardedStore type (Phase 1, Task 1)

  N-way (N=16) sharded wrapper over std.AutoHashMap. Foundation for
  per-shard locking in Phase 2. Single-threaded by itself; per-shard
  RwLocks on ManagedGraph will gate concurrent access."
  ```

### Task 2: Replace `GraphStore.nodes` / `GraphStore.edges` with sharded variants

**Files:**
- Modify: `src/graph_store.zig:442-520` (struct definition + init)
- Modify: `src/graph_store.zig:1078-4950` (every `store.nodes.X` / `store.edges.X` callsite — 115 `store.nodes` references, 30-40 `store.edges` references per earlier count)
- Test: `tests/storage/test_graph_store_sharded_invariants.zig` (new)

The goal: swap `std.AutoHashMap(u64, Node)` → `sharded_store.ShardedStore(u64, Node)` with identical behaviour. This is a pure refactor — no concurrency added yet. The callsite churn is mechanical: every `.put`, `.get`, `.getPtr`, `.remove`, `.contains`, `.count`, `.iterator` maps 1:1.

- [ ] **Step 2.1: Write the failing test.**

  Create `tests/storage/test_graph_store_sharded_invariants.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const graph_store = geode.graph_store;
  const sharded = geode.sharded_store;

  test "GraphStore nodes field is sharded" {
      // Compile-time invariant: after the Task 2 refactor, `nodes` is
      // a ShardedStore, not an AutoHashMap.  This test pins it so a
      // future accidental revert is caught by the unit-test suite.
      const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).nodes);
      const expected = sharded.ShardedStore(u64, graph_store.Node);
      try testing.expectEqual(expected, FieldType);
  }

  test "GraphStore create/get/remove round-trip after sharding" {
      var store = try graph_store.GraphStore.init(testing.allocator);
      defer store.deinit();

      const labels = [_][]const u8{"Label"};
      const id1 = try store.createNode(&labels);
      const id2 = try store.createNode(&labels);
      const id3 = try store.createNode(&labels);

      try testing.expect(store.nodes.get(id1) != null);
      try testing.expect(store.nodes.get(id2) != null);
      try testing.expect(store.nodes.get(id3) != null);
      try testing.expectEqual(@as(usize, 3), store.nodes.count());

      store.deleteNode(id2);
      try testing.expect(store.nodes.get(id2) == null);
      try testing.expectEqual(@as(usize, 2), store.nodes.count());
  }
  ```

- [ ] **Step 2.2: Run the test to verify it fails.**

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  # Create the build.zig entry first so the test runs (add target test-graph-store-sharded-invariants
  # as in Task 1.5).
  zig build test-graph-store-sharded-invariants 2>&1 | tail -5
  ```

  Expected: compile error: `expectEqual: expected ShardedStore(...), got AutoHashMap(...)`.

- [ ] **Step 2.3: Update the struct definition.**

  Edit `src/graph_store.zig`:

  At line 443, change:

  ```zig
      nodes: std.AutoHashMap(u64, Node),
      edges: std.AutoHashMap(u64, Edge),
  ```

  to:

  ```zig
      nodes: sharded_store.ShardedStore(u64, Node),
      edges: sharded_store.ShardedStore(u64, Edge),
  ```

  Near the top of the file, add the import next to the existing storage module imports (search for `const id_map_mod = @import(`):

  ```zig
  const sharded_store = @import("storage/sharded_store.zig");
  ```

  At line ~498 (inside `initWithTenant`), change:

  ```zig
          .nodes = std.AutoHashMap(u64, Node).init(allocator),
          .edges = std.AutoHashMap(u64, Edge).init(allocator),
  ```

  to:

  ```zig
          .nodes = try sharded_store.ShardedStore(u64, Node).init(allocator),
          .edges = try sharded_store.ShardedStore(u64, Edge).init(allocator),
  ```

- [ ] **Step 2.4: Fix every in-file callsite.**

  The `ShardedStore` API is a superset of the `AutoHashMap` API needed here (`put`, `get`, `getPtr`, `remove`, `contains`, `count`, `iterator`).  The only incompatibility is `.fetchRemove(k)` which the ShardedStore does not expose — callers used it for the `.value` extraction, and `remove(k)` now returns the value directly.

  Run the compile first to get the error list:

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  zig build 2>&1 | grep -E "src/graph_store.zig|error:" | head -40
  ```

  Walk the resulting list and fix each mechanically.  Typical patterns:

  - `store.nodes.iterator()` — still works, `ShardedStore.iterator()` exists.
  - `var it = store.nodes.valueIterator();` — NOT supported.  Change to:

    ```zig
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        const node_ptr = entry.value_ptr;
        // ...
    }
    ```

  - `store.nodes.fetchRemove(id)` — change to `store.nodes.remove(id)` (returns value directly, not `?Entry`).
  - `store.nodes.count()` — still works.
  - `store.nodes.deinit()` — still works.

  Repeat for `store.edges`.  Do NOT touch files outside `src/graph_store.zig` in this step — they access `store.nodes` through the same ShardedStore API, so they compile unchanged.

- [ ] **Step 2.5: Run the whole build.**

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  zig build 2>&1 | tail -10
  ```

  Expected: `Build Summary: OK`. Any remaining errors are typically one of:
  - `valueIterator` / `keyIterator` → rewrite to use `iterator()` + `entry.value_ptr` / `entry.key_ptr`.
  - `.capacity()` → not on ShardedStore; either remove the call or add a `capacity()` method summing all shards.

- [ ] **Step 2.6: Run the unit test.**

  ```bash
  zig build test-graph-store-sharded-invariants 2>&1 | tail -5
  ```

  Expected: `All 2 tests passed.` / exit 0.

- [ ] **Step 2.7: Run the pre-existing regression suite.**

  ```bash
  zig build test-r6-parallel-ingest test-graph-write-lock-cancelable \
      test-undo-log-isolation test-orphan-txn-cleanup \
      test-match-read-serial test-handler-lock-hold-scope 2>&1 | tail -5
  ```

  Expected: exit 0. Any regression here means a callsite was missed in Step 2.4.

- [ ] **Step 2.8: Run the full test suite.**

  ```bash
  zig build test 2>&1 | tail -10
  ```

  Expected: exit 0.

- [ ] **Step 2.9: Commit.**

  ```bash
  git add src/graph_store.zig tests/storage/test_graph_store_sharded_invariants.zig build.zig
  git commit -m "refactor(storage): shard GraphStore.nodes and GraphStore.edges (Phase 1, Task 2)

  Replace std.AutoHashMap with ShardedStore (N=16 shards). Pure data-
  structure refactor — no concurrency change. Every callsite in
  graph_store.zig uses the superset API (put/get/getPtr/remove/iterator).
  Pre-existing lock semantics unchanged."
  ```

### Task 3: Shard the aux indexes (`outgoing_edges`, `incoming_edges`, `merge_prop_index`)

**Files:**
- Modify: `src/graph_store.zig:475-482` (struct fields + init)
- Modify: `src/graph_store.zig` callsites for these three fields
- Test: extend `tests/storage/test_graph_store_sharded_invariants.zig`

The aux indexes are keyed by `node_id` (outgoing/incoming) and by a composite string (`merge_prop_index`). The first two shard by the same function as `nodes`; the third stays a single `std.StringHashMap` but is guarded by a separate lock (its keyspace is not `node_id` so the sharding dimension is wrong for it — we keep a single lock for this index, moved to `ManagedGraph.merge_prop_index_lock` in Task 4).

- [ ] **Step 3.1: Write the failing test (extend the existing file).**

  Append to `tests/storage/test_graph_store_sharded_invariants.zig`:

  ```zig
  test "GraphStore.outgoing_edges is sharded" {
      const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).outgoing_edges);
      const expected = sharded.ShardedStore(u64, std.ArrayList(u64));
      try testing.expectEqual(expected, FieldType);
  }

  test "GraphStore.incoming_edges is sharded" {
      const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).incoming_edges);
      const expected = sharded.ShardedStore(u64, std.ArrayList(u64));
      try testing.expectEqual(expected, FieldType);
  }

  test "createEdgeWithGraph populates outgoing + incoming shards" {
      var store = try graph_store.GraphStore.init(testing.allocator);
      defer store.deinit();
      const labels = [_][]const u8{"L"};
      const a = try store.createNode(&labels);
      const b = try store.createNode(&labels);
      const e = try store.createEdgeWithGraph(a, b, "T", "default");
      try testing.expect(store.outgoing_edges.get(a) != null);
      try testing.expect(store.incoming_edges.get(b) != null);
      try testing.expect(store.edges.get(e) != null);
  }
  ```

- [ ] **Step 3.2: Run the test and confirm it fails.**

  ```bash
  zig build test-graph-store-sharded-invariants 2>&1 | tail -5
  ```

  Expected: the new `outgoing_edges is sharded` and `incoming_edges is sharded` tests fail with `expected ShardedStore(...), got AutoHashMap(...)`.

- [ ] **Step 3.3: Shard the two adjacency fields.**

  Edit `src/graph_store.zig` at line ~478:

  ```zig
      outgoing_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
      incoming_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
  ```

  to:

  ```zig
      outgoing_edges: sharded_store.ShardedStore(u64, std.ArrayList(u64)),
      incoming_edges: sharded_store.ShardedStore(u64, std.ArrayList(u64)),
  ```

  Update the init line (~line 512):

  ```zig
          .outgoing_edges = try sharded_store.ShardedStore(u64, std.ArrayList(u64)).init(allocator),
          .incoming_edges = try sharded_store.ShardedStore(u64, std.ArrayList(u64)).init(allocator),
  ```

  Walk every callsite exactly as in Task 2.4.

- [ ] **Step 3.4: Build and run regression.**

  ```bash
  zig build 2>&1 | tail -5 && \
      zig build test-graph-store-sharded-invariants test-r6-parallel-ingest \
      test-match-read-serial 2>&1 | tail -10
  ```

  Expected: exit 0 on all.

- [ ] **Step 3.5: Commit.**

  ```bash
  git add src/graph_store.zig tests/storage/test_graph_store_sharded_invariants.zig
  git commit -m "refactor(storage): shard outgoing_edges / incoming_edges (Phase 1, Task 3)

  Adjacency indexes now use ShardedStore keyed by node_id (same shard
  function as nodes). merge_prop_index stays single-lock because it is
  string-keyed, not node_id-keyed."
  ```

---

## Phase 2 — Per-shard locks + N-way coordinator

Phase 1 made the store safe to access from one shard at a time. Phase 2 adds the locking that makes 16 threads concurrent: N independent rwlocks on `ManagedGraph`, and an N-way coordinator. At end of phase, the msft-graph ingest should run without the queue-depth cascade on the two 8 k+ edge files — they route across all 16 shards so no single shard sees >~520 ops/batch.

### Task 4: Add per-shard rwlocks to `ManagedGraph`

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig:457-515` (ManagedGraph struct + init)
- Modify: `src/storage/graph_storage_adapter.zig:2888-2981` (acquireGraphReadLock / acquireGraphWriteLock[Cancelable] / release*)
- Modify: `src/graph_store.zig:5145-5335` (GraphLockHandle + acquireGraphWriteLockCancelable wrappers)
- Test: `tests/storage/test_shard_locks.zig` (new)

Strategy: keep the existing `mg.rwlock` (the "whole-graph" lock) for backward compatibility and cross-shard reads (full scans, persistence). Add a new `mg.shard_locks: [SHARD_COUNT]std.Io.RwLock` array used by writers. The existing acquire* functions remain valid as "acquire whole-graph"; a new pair of functions acquires a single shard.

Shard-writer protocol:
1. Writer takes `mg.rwlock` in SHARED mode (confirms graph not under whole-graph-exclusive op like RESTORE).
2. Writer takes `mg.shard_locks[shard]` in EXCLUSIVE mode.
3. Writer mutates the shard.
4. Writer releases shard lock, then whole-graph shared lock.

Whole-graph-writer protocol (used by full-scan writes like DELETE with complex filters, RESTORE, etc.):
1. Takes `mg.rwlock` in EXCLUSIVE mode (blocks new shard writers by blocking their SHARED acquire, but waits for in-flight shard writers to drain first — rwlock contract).
2. Takes every `mg.shard_locks[i]` in i-ascending order in EXCLUSIVE mode (defensive — ensures no concurrent shard-reader either).
3. Mutates.
4. Releases all shard locks in reverse order, then releases `mg.rwlock`.

- [ ] **Step 4.1: Write the failing test.**

  Create `tests/storage/test_shard_locks.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const graph_store = geode.graph_store;
  const adapter_mod = geode.graph_storage_adapter;
  const sharded = geode.sharded_store;

  test "acquireGraphShardWriteLock permits concurrent access to different shards" {
      // Two workers target disjoint shards.  The second must not block
      // waiting for the first — the test fails if it does (via a
      // 1 s timeout).
      const allocator = testing.allocator;
      var tmp = testing.tmpDir(.{});
      defer tmp.cleanup();

      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      const adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();

      const mg = try adapter.getOrCreateGraph("g");

      // Pick two node-ids whose shard indices differ.
      var id_shard0: u64 = 0;
      var id_shard1: u64 = 0;
      var k: u64 = 1;
      while (id_shard0 == 0 or id_shard1 == 0) : (k += 1) {
          const s = sharded.shardIndex(k);
          if (s == 0 and id_shard0 == 0) id_shard0 = k;
          if (s == 1 and id_shard1 == 0) id_shard1 = k;
      }

      // Hold shard 0's write lock in a background thread.
      const BgArgs = struct { mg: *adapter_mod.ManagedGraph, id: u64, ready: *std.atomic.Value(u32), release: *std.atomic.Value(u32) };
      var ready = std.atomic.Value(u32).init(0);
      var release = std.atomic.Value(u32).init(0);
      const bg = BgArgs{ .mg = mg, .id = id_shard0, .ready = &ready, .release = &release };
      const thread = try std.Thread.spawn(.{}, struct {
          fn run(a: BgArgs) void {
              adapter_mod.acquireShardWriteLock(a.mg, a.id);
              a.ready.store(1, .release);
              while (a.release.load(.acquire) == 0) std.time.sleep(100 * std.time.ns_per_us);
              adapter_mod.releaseShardWriteLock(a.mg, a.id);
          }
      }.run, .{bg});

      while (ready.load(.acquire) == 0) std.time.sleep(100 * std.time.ns_per_us);

      // Foreground: acquire shard 1 within 200 ms.  If the impl were
      // still a single rwlock this would block forever.
      const start = std.time.milliTimestamp();
      adapter_mod.acquireShardWriteLock(mg, id_shard1);
      const elapsed = std.time.milliTimestamp() - start;
      adapter_mod.releaseShardWriteLock(mg, id_shard1);
      try testing.expect(elapsed < 200);

      release.store(1, .release);
      thread.join();
  }
  ```

- [ ] **Step 4.2: Run the test to verify it fails.**

  Add `test-shard-locks` target to `build.zig` (same shape as Task 1.5). Then:

  ```bash
  zig build test-shard-locks 2>&1 | tail -10
  ```

  Expected: compile error — `acquireShardWriteLock` doesn't exist.

- [ ] **Step 4.3: Add the shard-locks field and the new acquire/release helpers.**

  Edit `src/storage/graph_storage_adapter.zig`:

  At line 476 (inside `ManagedGraph`), add:

  ```zig
      /// Per-shard locks covering the N partitions of `GraphStore.nodes`
      /// / `GraphStore.edges` / adjacency.  Writers take one of these in
      /// EXCLUSIVE mode for ops routed to a specific node-id; full-graph
      /// exclusive ops acquire `rwlock` exclusive which blocks any new
      /// shard writer (they take `rwlock` shared first).  Readers that
      /// need a consistent full-graph snapshot acquire every entry in
      /// shard-index ascending order.
      shard_locks: [sharded_store.SHARD_COUNT]std.Io.RwLock =
          [_]std.Io.RwLock{std.Io.RwLock.init} ** sharded_store.SHARD_COUNT,

      /// Dedicated lock for the `merge_prop_index` (which is keyed by a
      /// composite string, not by node_id, and therefore can't be
      /// sharded by the same function).  Used by MERGE probes.
      merge_prop_index_lock: std.Io.RwLock = std.Io.RwLock.init,
  ```

  Add the import at the top of the file (search for `const gs = @import`):

  ```zig
  const sharded_store = @import("sharded_store.zig");
  ```

  Add the helpers at file end (after `releaseGraphWriteLock` near line 2981):

  ```zig
  /// Acquire EXCLUSIVE mode on the single shard owning `key`.
  /// Protocol: take `mg.rwlock` SHARED (coexists with other shard
  /// writers, blocks whole-graph-exclusive ops), then take the shard
  /// lock EXCLUSIVE.
  pub fn acquireShardWriteLock(mg: *ManagedGraph, key: u64) void {
      const io = std.Io.Threaded.global_single_threaded.io();
      mg.rwlock.lockSharedUncancelable(io);
      const idx = sharded_store.shardIndex(key);
      mg.shard_locks[idx].lockUncancelable(io);
  }

  pub fn releaseShardWriteLock(mg: *ManagedGraph, key: u64) void {
      const io = std.Io.Threaded.global_single_threaded.io();
      const idx = sharded_store.shardIndex(key);
      mg.shard_locks[idx].unlock(io);
      mg.rwlock.unlockShared(io);
  }

  /// Deadline-aware variant used by the coordinator.  `deadline_mono_ns`
  /// has the same semantics as `acquireGraphWriteLockCancelable` — it
  /// caps waiting on the shard-lock step only (the SHARED rwlock is
  /// assumed fast to acquire since it only conflicts with whole-graph
  /// exclusive ops, which are rare).
  pub fn acquireShardWriteLockCancelable(
      mg: *ManagedGraph,
      key: u64,
      deadline_mono_ns: u64,
  ) !void {
      const io = std.Io.Threaded.global_single_threaded.io();
      mg.rwlock.lockSharedUncancelable(io);
      errdefer mg.rwlock.unlockShared(io);
      const idx = sharded_store.shardIndex(key);
      if (mg.shard_locks[idx].tryLock(io)) return;
      var sleep_ns: u64 = 200 * std.time.ns_per_us;
      const max_sleep_ns: u64 = 4 * std.time.ns_per_ms;
      while (true) {
          const now = monoNanosNow();
          if (now >= deadline_mono_ns) return error.Deadline;
          const remaining = deadline_mono_ns - now;
          const nap_ns = @min(sleep_ns, remaining);
          const req = std.os.linux.timespec{
              .sec = @intCast(nap_ns / std.time.ns_per_s),
              .nsec = @intCast(nap_ns % std.time.ns_per_s),
          };
          var rem: std.os.linux.timespec = undefined;
          _ = std.os.linux.nanosleep(&req, &rem);
          if (mg.shard_locks[idx].tryLock(io)) return;
          sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
      }
  }

  /// Acquire EXCLUSIVE on every shard, in ascending index order, plus
  /// the whole-graph rwlock in EXCLUSIVE.  Used by RESTORE / DELETE-all
  /// / full-scan writes that need global isolation.
  pub fn acquireWholeGraphExclusive(mg: *ManagedGraph) void {
      const io = std.Io.Threaded.global_single_threaded.io();
      mg.rwlock.lockUncancelable(io);
      for (&mg.shard_locks) |*sl| sl.lockUncancelable(io);
  }

  pub fn releaseWholeGraphExclusive(mg: *ManagedGraph) void {
      const io = std.Io.Threaded.global_single_threaded.io();
      // Release in reverse order for lock-ordering hygiene (symmetry
      // with acquire; rwlock docs don't require it, but it keeps the
      // debug trace sane).
      var i: usize = sharded_store.SHARD_COUNT;
      while (i > 0) {
          i -= 1;
          mg.shard_locks[i].unlock(io);
      }
      mg.rwlock.unlock(io);
  }

  fn monoNanosNow() u64 {
      var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
      _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
      return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
  }
  ```

- [ ] **Step 4.4: Run the test and verify it passes.**

  ```bash
  zig build test-shard-locks 2>&1 | tail -10
  ```

  Expected: `All 1 tests passed.` / exit 0.

- [ ] **Step 4.5: Run the pre-existing regression suite.**

  ```bash
  zig build test-r6-parallel-ingest test-graph-write-lock-cancelable \
      test-handler-lock-hold-scope 2>&1 | tail -5
  ```

  Expected: exit 0. The existing writer helpers (`acquireGraphWriteLock[Cancelable]`) are untouched — they still take `mg.rwlock` EXCLUSIVE — so pre-sharding tests pass unchanged.

- [ ] **Step 4.6: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig tests/storage/test_shard_locks.zig build.zig
  git commit -m "feat(storage): per-shard rwlocks on ManagedGraph (Phase 2, Task 4)

  Adds shard_locks[SHARD_COUNT] + merge_prop_index_lock. New helpers:
  acquireShardWriteLock(Cancelable)/releaseShardWriteLock and
  acquireWholeGraphExclusive/releaseWholeGraphExclusive. Existing
  whole-graph helpers unchanged for backward compatibility. Test pins
  the non-blocking-disjoint-shards invariant."
  ```

### Task 5: Route `bulkInsertNode` / `bulkInsertEdgeWithIds` / `bulkMergeNode` through per-shard locks

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig:1050-1102` (`bulkInsertNode`)
- Modify: `src/storage/graph_storage_adapter.zig:1285-1334` (`bulkInsertEdgeWithIds`)
- Modify: `src/storage/graph_storage_adapter.zig:1380-1466` (`bulkMergeNode`)
- Test: `tests/storage/test_bulk_shard_concurrency.zig` (new)

The existing helpers assume the caller holds `mg.rwlock` EXCLUSIVE. After this task, they assume the caller holds ONLY the shard lock for the op's primary key:
- `bulkInsertNode`: primary key is the new node_id (allocated inside the call). **Tricky** — until the id is allocated the caller can't know the shard. Strategy: use a dedicated `id_allocator_lock` (coarse-grained short-hold `std.Thread.Mutex`) to allocate the id + register a skeleton entry; then acquire the id's shard lock to populate properties. Two-phase within one helper.
- `bulkInsertEdgeWithIds`: primary key is `source_id`. Caller provides both ids; routing is deterministic. The caller (coordinator) takes `shard_locks[shardIndex(source_id)]` only; the `target_id` shard's `incoming_edges` entry is also mutated — use a **strict two-lock acquire in ascending shard order** pattern:

  ```zig
  const src_shard = sharded_store.shardIndex(source_id);
  const dst_shard = sharded_store.shardIndex(target_id);
  if (src_shard == dst_shard) {
      // one shard covers both sides
      acquireShardWriteLock(mg, source_id);
      defer releaseShardWriteLock(mg, source_id);
  } else {
      // acquire the lower-index shard first to prevent deadlock
      const first = @min(src_shard, dst_shard);
      const second = @max(src_shard, dst_shard);
      mg.shard_locks[first].lockUncancelable(io);
      mg.shard_locks[second].lockUncancelable(io);
      mg.rwlock.lockSharedUncancelable(io);
      defer {
          mg.rwlock.unlockShared(io);
          mg.shard_locks[second].unlock(io);
          mg.shard_locks[first].unlock(io);
      }
  }
  ```

- `bulkMergeNode`: probes `merge_prop_index` first under `merge_prop_index_lock` SHARED, then either returns the existing id (no write lock needed) or acquires a fresh node_id and the corresponding shard lock to insert.

- [ ] **Step 5.1: Write the failing test.**

  Create `tests/storage/test_bulk_shard_concurrency.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const adapter_mod = geode.graph_storage_adapter;
  const sharded = geode.sharded_store;

  test "16-worker concurrent bulkInsertNode completes without deadlock or data loss" {
      const allocator = testing.allocator;
      var tmp = testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      const adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();

      _ = try adapter.getOrCreateGraph("g");

      const Worker = struct {
          fn run(a: *adapter_mod.StorageAdapter, thread_idx: usize, out_ids: *[100]u64) void {
              for (0..100) |i| {
                  const labels = [_][]const u8{"L"};
                  const props = [_]adapter_mod.StorageAdapter.PropKV{};
                  const id = a.bulkInsertNode("g", &labels, &props, null) catch |err| {
                      std.debug.panic("thread {d} bulkInsertNode failed: {}", .{ thread_idx, err });
                  };
                  out_ids[i] = id;
              }
          }
      };

      var threads: [16]std.Thread = undefined;
      var results: [16][100]u64 = undefined;
      for (&threads, 0..) |*t, i| {
          t.* = try std.Thread.spawn(.{}, Worker.run, .{ adapter, i, &results[i] });
      }
      for (&threads) |*t| t.join();

      // All 1600 ids must be distinct.
      var seen = std.AutoHashMap(u64, void).init(allocator);
      defer seen.deinit();
      for (&results) |row| {
          for (row) |id| {
              try testing.expect(!seen.contains(id));
              try seen.put(id, {});
          }
      }
      try testing.expectEqual(@as(usize, 1600), seen.count());
  }
  ```

- [ ] **Step 5.2: Add the test target and run to confirm it fails.**

  Add `test-bulk-shard-concurrency` target to `build.zig`.

  ```bash
  zig build test-bulk-shard-concurrency 2>&1 | tail -5
  ```

  Expected: either a deadlock (10+ sec hang; kill manually) or a `data race detected` if the runtime catches it. Either is a legitimate RED.

- [ ] **Step 5.3: Rewrite `bulkInsertNode` to use shard-scoped locking.**

  Edit `src/storage/graph_storage_adapter.zig:1050-1102`. The old body takes `beginStatementTxn` and calls `store.createNodeWithGraph` under the caller's assumed write lock. Replace with:

  ```zig
  pub fn bulkInsertNode(
      self: *StorageAdapter,
      graph_name: []const u8,
      labels: []const []const u8,
      props: []const PropKV,
      txn_id_opt: ?u64,
  ) !u64 {
      _ = txn_id_opt;

      const mg = try self.getOrCreateGraph(graph_name);
      const store = graph_store.getGlobalStore(graph_store.global_allocator());

      // Phase 1: allocate the new node id under the store's native
      // allocation lock (coarse but microsecond-scale).  `createNodeSkeleton`
      // reserves the id, inserts a labels-only Node into the correct
      // shard, and returns the id.  All other work (property writes,
      // adjacency, label index, WAL) is done after we know the id
      // under the shard lock.
      const new_id = try store.reserveNodeId();

      // Phase 2: take the owning shard's write lock and populate.
      const sharded_mod = @import("sharded_store.zig");
      const shard_idx = sharded_mod.shardIndex(new_id);
      acquireShardWriteLock(mg, new_id);
      defer releaseShardWriteLock(mg, new_id);

      // Optional statement txn batching — same as the pre-sharding code.
      var stmt_txn: StatementTxn = undefined;
      var stmt_txn_open = false;
      const session_covers = if (sessionEngineTxnGraph()) |g|
          std.mem.eql(u8, g, graph_name)
      else
          false;
      if (!session_covers and t_current_statement_txn == null) {
          if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
              stmt_txn_open = true;
          } else |err| switch (err) {
              error.GraphNotFound, error.NestedStatementTxn => {},
              else => return err,
          }
      }
      errdefer if (stmt_txn_open) stmt_txn.abort();

      try store.finalizeNodeUnderShardLock(new_id, labels, graph_name);
      for (props) |kv| {
          try store.setNodeProperty(new_id, kv.key, kv.value);
      }

      _ = shard_idx; // linter: keep the var for the lock-held asserts

      if (stmt_txn_open) try stmt_txn.commit();
      return new_id;
  }
  ```

  Add two new methods on `GraphStore` (in `src/graph_store.zig`):

  ```zig
  /// Allocate a fresh node id under `id_allocator_lock` without
  /// inserting the node.  Used by Phase 2 of `bulkInsertNode` — the
  /// caller takes the owning shard's write lock BEFORE populating.
  /// Thread-safe.
  pub fn reserveNodeId(self: *GraphStore) !u64 {
      self.id_allocator_lock.lock();
      defer self.id_allocator_lock.unlock();
      const id = self.next_node_id;
      self.next_node_id += 1;
      return id;
  }

  /// Complete the node insertion reserved by `reserveNodeId`.  Caller
  /// MUST hold `mg.shard_locks[shardIndex(id)]` EXCLUSIVE and `mg.rwlock`
  /// SHARED (both provided by `acquireShardWriteLock`).  Writes the
  /// Node record into the correct shard + the graph-to-node
  /// membership entry.
  pub fn finalizeNodeUnderShardLock(
      self: *GraphStore,
      node_id: u64,
      labels: []const []const u8,
      graph_name: []const u8,
  ) !void {
      const labels_copy = try self.allocator.alloc([]const u8, labels.len);
      for (labels, 0..) |l, i| labels_copy[i] = try self.allocator.dupe(u8, l);
      const owned_graph = try self.allocator.dupe(u8, graph_name);
      const node = Node{
          .id = node_id,
          .labels = labels_copy,
          .graph_name = owned_graph,
          .tenant_id = try self.allocator.dupe(u8, self.tenant_id),
          .properties_head = 0,
      };
      try self.nodes.put(node_id, node);
      for (labels) |label| {
          try self.indexLabel(graph_name, label, node_id);
      }
      self.dirty.store(true, .release);
  }
  ```

  Add the `id_allocator_lock` field to `GraphStore` at line ~447:

  ```zig
      /// Short-held lock covering next_node_id / next_edge_id allocation.
      /// Released before any shard lock is acquired to avoid lock-order
      /// inversions.  std.Thread.Mutex is chosen (not std.Io.Mutex) so
      /// every thread — including coordinator threads that don't use
      /// std.Io — can take it uniformly.
      id_allocator_lock: std.Thread.Mutex = .{},
  ```

- [ ] **Step 5.4: Rewrite `bulkInsertEdgeWithIds` to use two-shard locking.**

  Edit `src/storage/graph_storage_adapter.zig:1285-1334` to:

  ```zig
  pub fn bulkInsertEdgeWithIds(
      self: *StorageAdapter,
      graph_name: []const u8,
      source_id: u64,
      target_id: u64,
      rel_type: []const u8,
      props: []const PropKV,
      txn_id_opt: ?u64,
  ) !u64 {
      _ = txn_id_opt;

      const mg = try self.getOrCreateGraph(graph_name);
      const store = graph_store.getGlobalStore(graph_store.global_allocator());

      const sharded_mod = @import("sharded_store.zig");
      const src_shard = sharded_mod.shardIndex(source_id);
      const dst_shard = sharded_mod.shardIndex(target_id);

      const io = std.Io.Threaded.global_single_threaded.io();
      mg.rwlock.lockSharedUncancelable(io);
      defer mg.rwlock.unlockShared(io);

      if (src_shard == dst_shard) {
          mg.shard_locks[src_shard].lockUncancelable(io);
          defer mg.shard_locks[src_shard].unlock(io);
          return self.bulkInsertEdgeInner(graph_name, store, source_id, target_id, rel_type, props);
      } else {
          const first = @min(src_shard, dst_shard);
          const second = @max(src_shard, dst_shard);
          mg.shard_locks[first].lockUncancelable(io);
          mg.shard_locks[second].lockUncancelable(io);
          defer {
              mg.shard_locks[second].unlock(io);
              mg.shard_locks[first].unlock(io);
          }
          return self.bulkInsertEdgeInner(graph_name, store, source_id, target_id, rel_type, props);
      }
  }

  fn bulkInsertEdgeInner(
      self: *StorageAdapter,
      graph_name: []const u8,
      store: *graph_store.GraphStore,
      source_id: u64,
      target_id: u64,
      rel_type: []const u8,
      props: []const PropKV,
  ) !u64 {
      if (store.nodes.getPtr(source_id) == null) return error.SourceNodeNotFound;
      if (store.nodes.getPtr(target_id) == null) return error.TargetNodeNotFound;

      var stmt_txn: StatementTxn = undefined;
      var stmt_txn_open = false;
      const session_covers = if (sessionEngineTxnGraph()) |g|
          std.mem.eql(u8, g, graph_name)
      else
          false;
      if (!session_covers and t_current_statement_txn == null) {
          self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
              error.GraphNotFound => {},
              else => return err,
          };
          if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
              stmt_txn_open = true;
          } else |err| switch (err) {
              error.GraphNotFound, error.NestedStatementTxn => {},
              else => return err,
          }
      }
      errdefer if (stmt_txn_open) stmt_txn.abort();

      const edge_id = try store.createEdgeWithGraph(source_id, target_id, rel_type, graph_name);
      for (props) |kv| {
          try store.setEdgeProperty(edge_id, kv.key, kv.value);
      }

      if (stmt_txn_open) try stmt_txn.commit();
      return edge_id;
  }
  ```

- [ ] **Step 5.5: Rewrite `bulkMergeNode` to use merge-index-lock + shard lock.**

  Edit `src/storage/graph_storage_adapter.zig:1380-1466`. The existing probe-under-exclusive logic becomes:

  ```zig
  pub fn bulkMergeNode(
      self: *StorageAdapter,
      graph_name: []const u8,
      label: []const u8,
      merge_key: []const u8,
      merge_value: gs.PropertyValue,
      on_create_props: []const PropKV,
      txn_id_opt: ?u64,
  ) !u64 {
      _ = txn_id_opt;
      const mg = try self.getOrCreateGraph(graph_name);
      const store = graph_store.getGlobalStore(graph_store.global_allocator());

      // Probe phase: take the merge-index SHARED lock + rwlock SHARED.
      // Fast path: if the candidate exists, return it without touching
      // any shard write lock.
      const io = std.Io.Threaded.global_single_threaded.io();
      mg.rwlock.lockSharedUncancelable(io);
      mg.merge_prop_index_lock.lockSharedUncancelable(io);
      var probe_id: u64 = 0;
      const probe = store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &probe_id);
      mg.merge_prop_index_lock.unlockShared(io);
      if (probe == .found) {
          mg.rwlock.unlockShared(io);
          return probe_id;
      }
      mg.rwlock.unlockShared(io);

      // Insert phase: reserve id, acquire shard-write lock, re-probe,
      // insert if still missing.
      const new_id = try store.reserveNodeId();
      const sharded_mod = @import("sharded_store.zig");
      const shard_idx = sharded_mod.shardIndex(new_id);
      _ = shard_idx;

      acquireShardWriteLock(mg, new_id);
      defer releaseShardWriteLock(mg, new_id);

      // Re-probe under the write lock: another concurrent MERGE for the
      // same key may have won the race.  The merge-index-lock-exclusive
      // window here is the commit point for (insert-if-absent) atomicity.
      mg.merge_prop_index_lock.lockUncancelable(io);
      defer mg.merge_prop_index_lock.unlock(io);

      var reprobe_id: u64 = 0;
      if (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &reprobe_id) == .found) {
          return reprobe_id;
      }

      var stmt_txn: StatementTxn = undefined;
      var stmt_txn_open = false;
      if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| stmt_txn_open = true else |_| {}
      errdefer if (stmt_txn_open) stmt_txn.abort();

      const labels = [_][]const u8{label};
      try store.finalizeNodeUnderShardLock(new_id, &labels, graph_name);
      try store.setNodeProperty(new_id, merge_key, merge_value);
      for (on_create_props) |kv| {
          try store.setNodeProperty(new_id, kv.key, kv.value);
      }
      // The regular path writes merge_prop_index inside setNodeProperty
      // → indexMergeProperty under merge_prop_index_lock held above.

      if (stmt_txn_open) try stmt_txn.commit();
      return new_id;
  }
  ```

- [ ] **Step 5.6: Run the concurrency test to verify it passes.**

  ```bash
  zig build test-bulk-shard-concurrency 2>&1 | tail -5
  ```

  Expected: `All 1 tests passed.` / exit 0 within ~2 s (if it takes > 20 s, there's still a deadlock).

- [ ] **Step 5.7: Run the pre-existing suite.**

  ```bash
  zig build test-r6-parallel-ingest test-graph-write-lock-cancelable \
      test-orphan-txn-cleanup test-match-read-serial \
      test-handler-lock-hold-scope 2>&1 | tail -10
  ```

  Expected: exit 0.

- [ ] **Step 5.8: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig src/graph_store.zig \
      tests/storage/test_bulk_shard_concurrency.zig build.zig
  git commit -m "feat(storage): shard-scoped locking on bulk-insert helpers (Phase 2, Task 5)

  bulkInsertNode/bulkInsertEdgeWithIds/bulkMergeNode now acquire only
  the owning shard's write lock (two shards for cross-shard edges, in
  ascending index order to avoid deadlock). id_allocator_lock handles
  next_node_id bumping; reserveNodeId / finalizeNodeUnderShardLock
  split the two phases. 16-way concurrent insert test passes."
  ```

### Task 6: N-way sharded coordinator

**Files:**
- Modify: `src/storage/group_commit.zig` (rework from 1 thread to N threads)
- Test: `tests/storage/test_sharded_coordinator.zig` (new)

The coordinator becomes `ShardedCoordinator` with N per-shard queues and N threads. `submit()` routes by shard of the op's primary key. Each thread drains its queue under its shard's write lock. The `ApplyOp` union gains a `primary_shard_key` method that returns the routing key.

- [ ] **Step 6.1: Write the failing test.**

  Create `tests/storage/test_sharded_coordinator.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const adapter_mod = geode.graph_storage_adapter;
  const group_commit = geode.group_commit;
  const sharded = geode.sharded_store;

  test "ShardedCoordinator: 16 submitters across 16 shards run concurrently" {
      const allocator = testing.allocator;
      var tmp = testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      const adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();
      _ = try adapter.getOrCreateGraph("g");

      group_commit.setEnabledForTest(true);
      defer group_commit.setEnabledForTest(false);
      defer group_commit.shutdownAllCoordinators();

      const coord = try group_commit.getOrStartCoordinator(allocator, adapter, "g");

      // Submit 16 × 200 = 3200 node-insert ops from 16 threads.  Each
      // thread targets ops whose natural shard matches its thread
      // index — forcing genuine 16-way parallelism through the
      // coordinator.
      const Worker = struct {
          fn run(c: *group_commit.ShardedCoordinator, thread_idx: usize) void {
              for (0..200) |_| {
                  const labels = [_][]const u8{"L"};
                  const props = [_]adapter_mod.StorageAdapter.PropKV{};
                  var op = group_commit.ApplyOp{ .bulk_insert_node = .{
                      .labels = &labels,
                      .props = &props,
                      .result = .{},
                  } };
                  _ = c.submit(&op) catch |err| {
                      std.debug.panic("thread {d} submit failed: {}", .{ thread_idx, err });
                  };
              }
          }
      };

      var threads: [16]std.Thread = undefined;
      const start = std.time.milliTimestamp();
      for (&threads, 0..) |*t, i| {
          t.* = try std.Thread.spawn(.{}, Worker.run, .{ coord, i });
      }
      for (&threads) |*t| t.join();
      const elapsed = std.time.milliTimestamp() - start;

      // With 16 concurrent shard threads each drain their own queue
      // independently; a 3200-op batch on a hot graph should land
      // well under 5 s on any modern box.  The pre-sharding coord
      // with 16-way fan-in + 500-800 ms batch apply would take
      // 3200/256 × ~500 ms = ~6 s minimum, so we test << 5 s.
      try testing.expect(elapsed < 5000);
  }
  ```

- [ ] **Step 6.2: Add the test target to `build.zig` and run to confirm it fails.**

  ```bash
  zig build test-sharded-coordinator 2>&1 | tail -10
  ```

  Expected: compile error — `ShardedCoordinator` does not exist.

- [ ] **Step 6.3: Rework `group_commit.zig` to use N shard threads.**

  Replace the body of `src/storage/group_commit.zig` (lines 97-498 — everything except the file header comment and the imports):

  ```zig
  // ========================================================================
  // ApplyOp (unchanged except for the shard-key accessor)
  // ========================================================================

  pub const ApplyOp = union(enum) {
      bulk_insert_node: struct {
          labels: []const []const u8,
          props: []const PropKV,
          result: ApplyResult,
          assigned_id: u64 = 0, // filled in by submit() before enqueue
      },
      bulk_insert_edge: struct {
          source_id: u64,
          target_id: u64,
          rel_type: []const u8,
          props: []const PropKV,
          result: ApplyResult,
      },
      bulk_merge_node: struct {
          label: []const u8,
          merge_key: []const u8,
          merge_value: PropertyValue,
          on_create_props: []const PropKV,
          result: ApplyResult,
          assigned_id: u64 = 0,
      },

      pub fn resultPtr(self: *ApplyOp) *ApplyResult {
          return switch (self.*) {
              .bulk_insert_node => |*p| &p.result,
              .bulk_insert_edge => |*p| &p.result,
              .bulk_merge_node => |*p| &p.result,
          };
      }

      /// Key that selects the shard whose thread will apply this op.
      pub fn shardKey(self: *const ApplyOp) u64 {
          return switch (self.*) {
              .bulk_insert_node => |p| p.assigned_id,
              .bulk_insert_edge => |p| p.source_id,
              .bulk_merge_node => |p| p.assigned_id,
          };
      }
  };

  pub const ApplyResult = struct {
      node_or_edge_id: u64 = 0,
      err: ?anyerror = null,
      done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
  };

  // ========================================================================
  // ShardedCoordinator
  // ========================================================================

  const sharded_store = @import("sharded_store.zig");

  pub const ShardedCoordinator = struct {
      allocator: std.mem.Allocator,
      graph_name: []const u8, // owned
      adapter: *StorageAdapter,

      shards: [sharded_store.SHARD_COUNT]Shard,
      should_stop: std.atomic.Value(u32),

      /// Per-shard bookkeeping.  The queue + mutex + condvar + thread
      /// are all per-shard so each shard drains independently.
      pub const Shard = struct {
          queue: std.Deque(*ApplyOp),
          queue_mutex: std.Io.Mutex,
          queue_not_empty: std.Io.Condition,
          thread: std.Thread,
          ops_applied: std.atomic.Value(u64),
          batches: std.atomic.Value(u64),
      };

      pub const max_batch: usize = 256;

      pub fn start(
          allocator: std.mem.Allocator,
          adapter: *StorageAdapter,
          graph_name: []const u8,
      ) !*ShardedCoordinator {
          const owned_name = try allocator.dupe(u8, graph_name);
          errdefer allocator.free(owned_name);

          const self = try allocator.create(ShardedCoordinator);
          errdefer allocator.destroy(self);

          self.* = .{
              .allocator = allocator,
              .graph_name = owned_name,
              .adapter = adapter,
              .shards = undefined,
              .should_stop = std.atomic.Value(u32).init(0),
          };

          for (&self.shards, 0..) |*s, idx| {
              s.* = .{
                  .queue = std.Deque(*ApplyOp).empty,
                  .queue_mutex = std.Io.Mutex.init,
                  .queue_not_empty = std.Io.Condition.init,
                  .thread = undefined,
                  .ops_applied = std.atomic.Value(u64).init(0),
                  .batches = std.atomic.Value(u64).init(0),
              };
              try s.queue.ensureTotalCapacityPrecise(allocator, max_batch * 4);
              s.thread = try std.Thread.spawn(.{}, loop, .{ self, idx });
          }
          return self;
      }

      pub fn stop(self: *ShardedCoordinator) void {
          const io = std.Io.Threaded.global_single_threaded.io();
          self.should_stop.store(1, .release);
          for (&self.shards) |*s| {
              s.queue_mutex.lockUncancelable(io);
              s.queue_not_empty.signal(io);
              s.queue_mutex.unlock(io);
          }
          for (&self.shards) |*s| s.thread.join();
          for (&self.shards) |*s| s.queue.deinit(self.allocator);
          self.allocator.free(self.graph_name);
          self.allocator.destroy(self);
      }

      /// Submit an op and block until the owning shard's thread
      /// completes it.  For insert-node / merge-node ops the caller
      /// must first allocate the id via `adapter.reserveNodeIdFor()`
      /// so the shard can be determined — that assignment happens
      /// inside this method.
      pub fn submit(self: *ShardedCoordinator, op: *ApplyOp) !u64 {
          // For insert-node / merge-node, pre-assign the id so the
          // shard key is known before enqueue.  The shard thread
          // finalises the insert under the shard lock.
          switch (op.*) {
              .bulk_insert_node => |*p| {
                  const store = graph_store.getGlobalStore(graph_store.global_allocator());
                  p.assigned_id = try store.reserveNodeId();
              },
              .bulk_merge_node => |*p| {
                  const store = graph_store.getGlobalStore(graph_store.global_allocator());
                  p.assigned_id = try store.reserveNodeId();
              },
              .bulk_insert_edge => {},
          }

          const shard_idx = sharded_store.shardIndex(op.shardKey());
          const s = &self.shards[shard_idx];
          const io = std.Io.Threaded.global_single_threaded.io();

          s.queue_mutex.lockUncancelable(io);
          s.queue.pushBack(self.allocator, op) catch |err| {
              s.queue_mutex.unlock(io);
              return err;
          };
          s.queue_not_empty.signal(io);
          s.queue_mutex.unlock(io);

          const result = op.resultPtr();
          while (result.done.load(.acquire) == 0) {
              std.Io.futexWaitUncancelable(io, u32, &result.done.raw, 0);
          }
          if (result.err) |e| return e;
          return result.node_or_edge_id;
      }

      fn loop(self: *ShardedCoordinator, shard_idx: usize) void {
          const io = std.Io.Threaded.global_single_threaded.io();
          const s = &self.shards[shard_idx];
          var batch_buf: [max_batch]*ApplyOp = undefined;

          while (true) {
              s.queue_mutex.lockUncancelable(io);
              while (s.queue.len == 0) {
                  if (self.should_stop.load(.acquire) == 1) {
                      s.queue_mutex.unlock(io);
                      return;
                  }
                  s.queue_not_empty.waitUncancelable(io, &s.queue_mutex);
              }
              var batch_len: usize = 0;
              while (batch_len < max_batch) : (batch_len += 1) {
                  const op = s.queue.popFront() orelse break;
                  batch_buf[batch_len] = op;
              }
              s.queue_mutex.unlock(io);

              if (batch_len == 0) continue;

              self.applyShardBatch(shard_idx, batch_buf[0..batch_len]);
              _ = s.batches.fetchAdd(1, .monotonic);
              _ = s.ops_applied.fetchAdd(batch_len, .monotonic);
          }
      }

      fn applyShardBatch(self: *ShardedCoordinator, shard_idx: usize, batch: []*ApplyOp) void {
          const io = std.Io.Threaded.global_single_threaded.io();

          // The shard thread owns shard `shard_idx`'s write lock for the
          // whole batch.  For cross-shard ops (bulk_insert_edge where
          // src_shard != dst_shard), the inner helper will take the OTHER
          // shard's lock in ascending order — we always own the lower
          // shard's lock by invariant (see shardKey policy: edge ops
          // route by source_id which is `min(src, dst)` when equal, and
          // when different the routing shard is whichever one `shardKey`
          // returns; the helper's ascending-order acquire handles it).
          _ = shard_idx;

          // Resolve the ManagedGraph once.  The adapter handle is stable
          // for the coordinator's lifetime (shutdown is gated on stop()).
          const mg = self.adapter.getOrCreateGraph(self.graph_name) catch {
              for (batch) |op| {
                  const res = op.resultPtr();
                  res.err = error.GraphNotFound;
                  res.done.store(1, .release);
                  std.Io.futexWake(io, u32, &res.done.raw, 1);
              }
              return;
          };
          _ = mg;

          // Apply each op via the already-shard-safe bulk helpers from
          // Task 5.  They take the correct shard lock(s) internally.
          // The coordinator's value is coalescing the statement txn
          // (WAL fsync amortisation) across the batch — which we do in
          // the Phase 3 WAL flusher, not here.  For now, each op runs
          // as its own statement txn (same behaviour as the
          // pre-coordinator direct path).
          for (batch) |op| {
              const res = op.resultPtr();
              switch (op.*) {
                  .bulk_insert_node => |p| {
                      if (self.adapter.bulkInsertNodeWithReservedId(
                          self.graph_name,
                          p.assigned_id,
                          p.labels,
                          p.props,
                      )) |id| {
                          res.node_or_edge_id = id;
                      } else |e| {
                          res.err = e;
                      }
                  },
                  .bulk_insert_edge => |p| {
                      if (self.adapter.bulkInsertEdgeWithIds(
                          self.graph_name,
                          p.source_id,
                          p.target_id,
                          p.rel_type,
                          p.props,
                          null,
                      )) |id| {
                          res.node_or_edge_id = id;
                      } else |e| {
                          res.err = e;
                      }
                  },
                  .bulk_merge_node => |p| {
                      if (self.adapter.bulkMergeNodeWithReservedId(
                          self.graph_name,
                          p.assigned_id,
                          p.label,
                          p.merge_key,
                          p.merge_value,
                          p.on_create_props,
                      )) |id| {
                          res.node_or_edge_id = id;
                      } else |e| {
                          res.err = e;
                      }
                  },
              }
          }

          // Wake every submitter AFTER their shard locks are released
          // inside the bulk helpers (each helper acquires+releases its
          // own shard lock scope).
          for (batch) |op| {
              const res = op.resultPtr();
              res.done.store(1, .release);
              std.Io.futexWake(io, u32, &res.done.raw, 1);
          }
      }
  };

  /// Backwards-compatible alias for pre-sharding call sites.
  pub const GroupCommitCoordinator = ShardedCoordinator;

  // ========================================================================
  // Process-global registry (unchanged except the type rename)
  // ========================================================================

  var g_registry_mutex: std.Io.Mutex = std.Io.Mutex.init;
  var g_registry: ?std.StringHashMap(*ShardedCoordinator) = null;
  var g_registry_allocator: ?std.mem.Allocator = null;

  pub fn getOrStartCoordinator(
      allocator: std.mem.Allocator,
      adapter: *StorageAdapter,
      graph_name: []const u8,
  ) !*ShardedCoordinator {
      const io = std.Io.Threaded.global_single_threaded.io();
      g_registry_mutex.lockUncancelable(io);
      defer g_registry_mutex.unlock(io);

      if (g_registry == null) {
          g_registry = std.StringHashMap(*ShardedCoordinator).init(allocator);
          g_registry_allocator = allocator;
      }
      if (g_registry.?.get(graph_name)) |existing| return existing;

      const coord = try ShardedCoordinator.start(allocator, adapter, graph_name);
      errdefer coord.stop();
      const owned_key = try allocator.dupe(u8, graph_name);
      errdefer allocator.free(owned_key);
      try g_registry.?.put(owned_key, coord);
      return coord;
  }

  pub fn lookupCoordinator(graph_name: []const u8) ?*ShardedCoordinator {
      const io = std.Io.Threaded.global_single_threaded.io();
      g_registry_mutex.lockUncancelable(io);
      defer g_registry_mutex.unlock(io);
      if (g_registry) |*reg| return reg.get(graph_name);
      return null;
  }

  pub fn shutdownAllCoordinators() void {
      const io = std.Io.Threaded.global_single_threaded.io();
      g_registry_mutex.lockUncancelable(io);
      defer g_registry_mutex.unlock(io);
      if (g_registry) |*reg| {
          const alloc = g_registry_allocator.?;
          var it = reg.iterator();
          while (it.next()) |entry| {
              const key = entry.key_ptr.*;
              entry.value_ptr.*.stop();
              alloc.free(key);
          }
          reg.deinit();
          g_registry = null;
          g_registry_allocator = null;
      }
  }

  pub fn isEnabled() bool {
      if (cached_enabled) |v| return v;
      const val_z = std.c.getenv("GEODE_GROUP_COMMIT") orelse {
          cached_enabled = false;
          return false;
      };
      const val = std.mem.span(val_z);
      const on = std.mem.eql(u8, val, "1") or
          std.mem.eql(u8, val, "true") or
          std.mem.eql(u8, val, "yes");
      cached_enabled = on;
      return on;
  }

  pub fn setEnabledForTest(on: bool) void {
      cached_enabled = on;
  }

  var cached_enabled: ?bool = null;
  ```

- [ ] **Step 6.4: Add the id-reserving variants to `StorageAdapter`.**

  Edit `src/storage/graph_storage_adapter.zig`. Near `bulkInsertNode`, add:

  ```zig
  /// Variant of `bulkInsertNode` used by `ShardedCoordinator` — the id
  /// has already been allocated by the submit() path, so this helper
  /// skips `reserveNodeId` and jumps straight to the shard-lock +
  /// finalize steps.  Preserves the same statement-txn / error
  /// semantics as `bulkInsertNode`.
  pub fn bulkInsertNodeWithReservedId(
      self: *StorageAdapter,
      graph_name: []const u8,
      reserved_id: u64,
      labels: []const []const u8,
      props: []const PropKV,
  ) !u64 {
      const mg = try self.getOrCreateGraph(graph_name);
      const store = graph_store.getGlobalStore(graph_store.global_allocator());

      acquireShardWriteLock(mg, reserved_id);
      defer releaseShardWriteLock(mg, reserved_id);

      var stmt_txn: StatementTxn = undefined;
      var stmt_txn_open = false;
      if (t_current_statement_txn == null) {
          if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| stmt_txn_open = true else |_| {}
      }
      errdefer if (stmt_txn_open) stmt_txn.abort();

      try store.finalizeNodeUnderShardLock(reserved_id, labels, graph_name);
      for (props) |kv| {
          try store.setNodeProperty(reserved_id, kv.key, kv.value);
      }

      if (stmt_txn_open) try stmt_txn.commit();
      return reserved_id;
  }

  /// Same as `bulkMergeNode` but the id has been pre-allocated by the
  /// caller (`ShardedCoordinator.submit`).  If the probe finds an
  /// existing node, `reserved_id` is abandoned (the id-space leak is
  /// bounded by ingest size and tolerable — matches pre-sharding
  /// behaviour where the coordinator could double-allocate under race).
  pub fn bulkMergeNodeWithReservedId(
      self: *StorageAdapter,
      graph_name: []const u8,
      reserved_id: u64,
      label: []const u8,
      merge_key: []const u8,
      merge_value: gs.PropertyValue,
      on_create_props: []const PropKV,
  ) !u64 {
      const mg = try self.getOrCreateGraph(graph_name);
      const store = graph_store.getGlobalStore(graph_store.global_allocator());
      const io = std.Io.Threaded.global_single_threaded.io();

      mg.rwlock.lockSharedUncancelable(io);
      mg.merge_prop_index_lock.lockSharedUncancelable(io);
      var probe_id: u64 = 0;
      const probe = store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &probe_id);
      mg.merge_prop_index_lock.unlockShared(io);
      mg.rwlock.unlockShared(io);
      if (probe == .found) return probe_id;

      acquireShardWriteLock(mg, reserved_id);
      defer releaseShardWriteLock(mg, reserved_id);

      mg.merge_prop_index_lock.lockUncancelable(io);
      defer mg.merge_prop_index_lock.unlock(io);

      var reprobe_id: u64 = 0;
      if (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &reprobe_id) == .found) {
          return reprobe_id;
      }

      var stmt_txn: StatementTxn = undefined;
      var stmt_txn_open = false;
      if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| stmt_txn_open = true else |_| {}
      errdefer if (stmt_txn_open) stmt_txn.abort();

      const labels = [_][]const u8{label};
      try store.finalizeNodeUnderShardLock(reserved_id, &labels, graph_name);
      try store.setNodeProperty(reserved_id, merge_key, merge_value);
      for (on_create_props) |kv| {
          try store.setNodeProperty(reserved_id, kv.key, kv.value);
      }
      if (stmt_txn_open) try stmt_txn.commit();
      return reserved_id;
  }
  ```

- [ ] **Step 6.5: Run the coordinator concurrency test.**

  ```bash
  zig build test-sharded-coordinator 2>&1 | tail -5
  ```

  Expected: `All 1 tests passed.` / exit 0 within ~5 s.

- [ ] **Step 6.6: Run full regression suite.**

  ```bash
  zig build test 2>&1 | tail -10
  ```

  Expected: exit 0.

- [ ] **Step 6.7: Commit.**

  ```bash
  git add src/storage/group_commit.zig src/storage/graph_storage_adapter.zig \
      tests/storage/test_sharded_coordinator.zig build.zig
  git commit -m "feat(storage): N-way sharded coordinator (Phase 2, Task 6)

  GroupCommitCoordinator → ShardedCoordinator with SHARD_COUNT (16)
  shard threads per graph. submit() routes by shardIndex(shardKey).
  For insert-node/merge-node the id is pre-allocated at submit() time
  so the shard is known before enqueue. 3200-op 16-worker test lands
  in well under 5 s (vs 6+ s with single-thread coord)."
  ```

### Task 7: End-of-phase validation run

- [ ] **Step 7.1: Rebuild and re-run the baseline ingest command.**

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-phase2 && mkdir -p /tmp/geode-phase2
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
      nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-phase2 --listen 127.0.0.1:3144 \
      --log-level warn > /tmp/geode-phase2/server.log 2>&1 &
  SERVER_PID=$!
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3144 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  echo "=== start $(date -Iseconds) ==="
  time GEODE_DSN="quic://127.0.0.1:3144/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 2>&1 | tee docs/performance/2026-04-24-sharding/phase2-run.log | tail -30
  echo "=== end $(date -Iseconds) ==="
  kill -9 $SERVER_PID 2>/dev/null || true
  ```

- [ ] **Step 7.2: Document the result.**

  Record the total wall-clock, whether any serial-fallback cascade occurred, and per-file times for the two 8k+ edge files (`edges_signed_in_from`, `edges_signed_in_to`) into `docs/performance/2026-04-24-sharding/phase2-result.md`.

  **Phase 2 exit criterion:** both 8k+ edge files complete under sharded-coordinator routing without triggering serial fallback. Total wall-clock should be well under 20 min (from ~40 min pre-phase).

  If Phase 2 alone lands ≤ 60 s, the remaining phases are optional. Otherwise continue to Phase 3.

- [ ] **Step 7.3: Commit the phase-2 evidence.**

  ```bash
  git add docs/performance/2026-04-24-sharding/phase2-run.log \
      docs/performance/2026-04-24-sharding/phase2-result.md
  git commit -m "docs(perf): Phase 2 (sharded coordinator) ingest measurement"
  ```

---

## Phase 3 — WAL group commit: decouple fsync from apply

Every op today commits its own statement txn (1 fsync per op), or — when `GEODE_GROUP_COMMIT=1` — one fsync per batch of up to 256 ops per shard. With 16 shards, that's up to 16 concurrent fsyncs per coordinator wave. At sustained 2 k batches/sec that's 2 k–32 k fsyncs/sec, each is a syscall + device sync. Replace with: a single `WalFlusher` thread per graph that wakes every 500 µs, fsyncs once across all shards' pending records, and acks every submitter whose LSN is now durable.

### Task 8: `WalFlusher` background thread

**Files:**
- Create: `src/storage/wal_flusher.zig`
- Modify: `src/storage/graph_storage_adapter.zig` (StatementTxn.commit gains an `async_fsync` mode)
- Test: `tests/storage/test_wal_flusher.zig` (new)

- [ ] **Step 8.1: Write the failing test.**

  Create `tests/storage/test_wal_flusher.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const adapter_mod = geode.graph_storage_adapter;
  const wal_flusher = geode.wal_flusher;

  test "WalFlusher groups fsyncs across shards" {
      const allocator = testing.allocator;
      var tmp = testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      const adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();
      const mg = try adapter.getOrCreateGraph("g");

      const flusher = try wal_flusher.WalFlusher.start(allocator, adapter, "g");
      defer flusher.stop();

      // Submit 100 fsync requests from 10 threads concurrently.
      const Worker = struct {
          fn run(f: *wal_flusher.WalFlusher, _: *adapter_mod.ManagedGraph, start_lsn: u64) void {
              var i: u64 = 0;
              while (i < 10) : (i += 1) {
                  // Pretend we appended an LSN (no actual WAL write —
                  // this test exercises the flusher bookkeeping).
                  f.requestFlush(start_lsn + i) catch unreachable;
              }
          }
      };
      var threads: [10]std.Thread = undefined;
      for (&threads, 0..) |*t, i| {
          t.* = try std.Thread.spawn(.{}, Worker.run, .{ flusher, mg, i * 100 });
      }
      for (&threads) |*t| t.join();

      // Give the flusher one window to drain.
      std.time.sleep(2 * std.time.ns_per_ms);

      // Expect many fewer fsyncs than requests.  Ratio should be >10×.
      const stats = flusher.snapshotStats();
      try testing.expect(stats.fsyncs_total < stats.flush_requests / 5);
  }
  ```

- [ ] **Step 8.2: Add the build target and run to confirm it fails.**

  ```bash
  zig build test-wal-flusher 2>&1 | tail -5
  ```

  Expected: compile error — `wal_flusher` module does not exist.

- [ ] **Step 8.3: Implement `WalFlusher`.**

  Create `src/storage/wal_flusher.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Per-graph background WAL flusher.  Coordinator shard threads
  //! `requestFlush(lsn)` after `appendRecord` (no fsync).  The flusher
  //! wakes every `flush_window_ns` (default 500 µs), issues ONE fsync
  //! across the engine's WAL, snapshots `current_lsn`, and wakes every
  //! pending request whose LSN is now durable.
  //!
  //! Crash safety: records appended after the last fsync are lost on
  //! crash, but no ack has been sent yet — the submitter sees its
  //! done.err populated (on stop) or waits forever (on crash, which
  //! is fine: the crash replay will re-drive the ingest from the
  //! client's transaction log).

  const std = @import("std");
  const graph_storage_adapter = @import("graph_storage_adapter.zig");
  const StorageAdapter = graph_storage_adapter.StorageAdapter;

  pub const WalFlusher = struct {
      allocator: std.mem.Allocator,
      adapter: *StorageAdapter,
      graph_name: []const u8,
      thread: std.Thread,
      should_stop: std.atomic.Value(u32),

      /// Latest LSN that has been fsync'd.  Submitters wait on
      /// `synced_lsn >= their_lsn`.
      synced_lsn: std.atomic.Value(u64),

      /// Max LSN any caller has requested a flush for.  Flusher uses
      /// this to decide whether a flush is needed this window.
      requested_lsn: std.atomic.Value(u64),

      fsyncs_total: std.atomic.Value(u64),
      flush_requests: std.atomic.Value(u64),

      pub const flush_window_ns: u64 = 500 * std.time.ns_per_us;

      pub const Stats = struct {
          fsyncs_total: u64,
          flush_requests: u64,
          synced_lsn: u64,
          requested_lsn: u64,
      };

      pub fn start(
          allocator: std.mem.Allocator,
          adapter: *StorageAdapter,
          graph_name: []const u8,
      ) !*WalFlusher {
          const owned = try allocator.dupe(u8, graph_name);
          errdefer allocator.free(owned);
          const self = try allocator.create(WalFlusher);
          errdefer allocator.destroy(self);
          self.* = .{
              .allocator = allocator,
              .adapter = adapter,
              .graph_name = owned,
              .thread = undefined,
              .should_stop = std.atomic.Value(u32).init(0),
              .synced_lsn = std.atomic.Value(u64).init(0),
              .requested_lsn = std.atomic.Value(u64).init(0),
              .fsyncs_total = std.atomic.Value(u64).init(0),
              .flush_requests = std.atomic.Value(u64).init(0),
          };
          self.thread = try std.Thread.spawn(.{}, loop, .{self});
          return self;
      }

      pub fn stop(self: *WalFlusher) void {
          self.should_stop.store(1, .release);
          self.thread.join();
          self.allocator.free(self.graph_name);
          self.allocator.destroy(self);
      }

      /// Record that lsn needs to be durable.  Returns immediately;
      /// the caller then waits on `waitForLsn(lsn)`.
      pub fn requestFlush(self: *WalFlusher, lsn: u64) !void {
          _ = self.flush_requests.fetchAdd(1, .monotonic);
          // CAS-update requested_lsn to max.
          var prev = self.requested_lsn.load(.acquire);
          while (lsn > prev) {
              const new = lsn;
              const result = self.requested_lsn.cmpxchgWeak(prev, new, .acq_rel, .acquire);
              if (result == null) break;
              prev = result.?;
          }
      }

      /// Block until `lsn` is durable.  Uses a short futex-wait; the
      /// flusher wakes it by bumping synced_lsn.
      pub fn waitForLsn(self: *WalFlusher, lsn: u64) void {
          while (self.synced_lsn.load(.acquire) < lsn) {
              const io = std.Io.Threaded.global_single_threaded.io();
              // Futex can't wait on "greater than", so we spin + nap.
              // The flush window is 500 µs so worst-case sleep is ~1 ms.
              var req = std.os.linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_us };
              var rem: std.os.linux.timespec = undefined;
              _ = std.os.linux.nanosleep(&req, &rem);
              _ = io;
          }
      }

      pub fn snapshotStats(self: *const WalFlusher) Stats {
          return .{
              .fsyncs_total = self.fsyncs_total.load(.acquire),
              .flush_requests = self.flush_requests.load(.acquire),
              .synced_lsn = self.synced_lsn.load(.acquire),
              .requested_lsn = self.requested_lsn.load(.acquire),
          };
      }

      fn loop(self: *WalFlusher) void {
          while (self.should_stop.load(.acquire) == 0) {
              const req = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(flush_window_ns) };
              var rem: std.os.linux.timespec = undefined;
              _ = std.os.linux.nanosleep(&req, &rem);

              const wanted = self.requested_lsn.load(.acquire);
              const have = self.synced_lsn.load(.acquire);
              if (wanted <= have) continue;

              // Issue one fsync across the whole WAL.
              self.adapter.fsyncWalForGraph(self.graph_name) catch {
                  // Fsync errors are fatal but we can't do much here;
                  // submitters wait forever which is correct (crash
                  // recovery will handle it).
                  continue;
              };
              _ = self.fsyncs_total.fetchAdd(1, .monotonic);
              self.synced_lsn.store(wanted, .release);
          }
      }
  };
  ```

- [ ] **Step 8.4: Add `StorageAdapter.fsyncWalForGraph`.**

  Edit `src/storage/graph_storage_adapter.zig`. Near `beginStatementTxn`:

  ```zig
  /// Issue `fsync` on the named graph's WAL file (and only the WAL).
  /// Safe to call from any thread; the underlying `WalManager.sync()`
  /// holds its internal mutex.
  pub fn fsyncWalForGraph(self: *StorageAdapter, graph_name: []const u8) !void {
      const mg = try self.getOrCreateGraph(graph_name);
      try mg.engine.wal.sync();
  }
  ```

- [ ] **Step 8.5: Export the module and add the test build target.**

  Edit `src/root.zig` — add `pub const wal_flusher = @import("storage/wal_flusher.zig");`

  Add `test-wal-flusher` target in `build.zig` (same shape as Task 1.5).

- [ ] **Step 8.6: Run the test.**

  ```bash
  zig build test-wal-flusher 2>&1 | tail -5
  ```

  Expected: `All 1 tests passed.` / exit 0 within ~1 s.

- [ ] **Step 8.7: Commit.**

  ```bash
  git add src/storage/wal_flusher.zig src/storage/graph_storage_adapter.zig \
      src/root.zig tests/storage/test_wal_flusher.zig build.zig
  git commit -m "feat(storage): WalFlusher background thread (Phase 3, Task 8)

  Per-graph 500 µs-windowed fsync coordinator. Callers requestFlush(lsn)
  and waitForLsn(lsn) around their WAL append; the flusher groups
  multiple pending LSNs into one fsync. Test confirms >5× fsync-to-
  request ratio under 100-request concurrent load."
  ```

### Task 9: Route `ShardedCoordinator` through `WalFlusher`

**Files:**
- Modify: `src/storage/group_commit.zig` (per-graph WalFlusher, apply → requestFlush + waitForLsn)
- Modify: `src/storage/graph_storage_adapter.zig` (`beginStatementTxn` supports `defer_fsync` option)
- Test: `tests/storage/test_sharded_coordinator_wal_group_commit.zig` (new)

After this task, each coordinator batch still writes its records but does NOT fsync — it hands the LSN to the per-graph flusher and waits. 16 shard threads contribute to the same flusher, which coalesces their fsyncs.

- [ ] **Step 9.1: Write the failing test.**

  Create `tests/storage/test_sharded_coordinator_wal_group_commit.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const adapter_mod = geode.graph_storage_adapter;
  const group_commit = geode.group_commit;

  test "16-way coordinator under WalFlusher issues <1 fsync per batch on avg" {
      const allocator = testing.allocator;
      var tmp = testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      const adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();
      _ = try adapter.getOrCreateGraph("g");
      group_commit.setEnabledForTest(true);
      defer {
          group_commit.setEnabledForTest(false);
          group_commit.shutdownAllCoordinators();
      }
      const coord = try group_commit.getOrStartCoordinator(allocator, adapter, "g");
      _ = coord;

      // Submit 16 × 500 = 8000 nodes, compute avg ops-per-fsync.
      const Worker = struct {
          fn run(c: *group_commit.ShardedCoordinator) void {
              for (0..500) |_| {
                  const labels = [_][]const u8{"L"};
                  const props = [_]adapter_mod.StorageAdapter.PropKV{};
                  var op = group_commit.ApplyOp{ .bulk_insert_node = .{
                      .labels = &labels,
                      .props = &props,
                      .result = .{},
                  } };
                  _ = c.submit(&op) catch unreachable;
              }
          }
      };

      var threads: [16]std.Thread = undefined;
      for (&threads) |*t| {
          t.* = try std.Thread.spawn(.{}, Worker.run, .{ try group_commit.getOrStartCoordinator(allocator, adapter, "g") });
      }
      for (&threads) |*t| t.join();

      std.time.sleep(5 * std.time.ns_per_ms);
      const flusher = try group_commit.getFlusherForGraph("g");
      const stats = flusher.snapshotStats();
      // 8000 ops / N fsyncs: expect N ≤ 200 (40+ ops per fsync avg).
      try testing.expect(stats.fsyncs_total > 0);
      try testing.expect(stats.fsyncs_total < 200);
  }
  ```

- [ ] **Step 9.2: Run and confirm RED.**

  Add `test-sharded-coordinator-wal-group-commit` target. Run — expect compile error on `getFlusherForGraph`.

- [ ] **Step 9.3: Wire the flusher into `ShardedCoordinator`.**

  Edit `src/storage/group_commit.zig`. Add at the top of `ShardedCoordinator`:

  ```zig
      flusher: *wal_flusher.WalFlusher,
  ```

  And in `start`:

  ```zig
      const fl = try wal_flusher.WalFlusher.start(allocator, adapter, graph_name);
      errdefer fl.stop();
      // ...
      self.* = .{
          // ...
          .flusher = fl,
      };
  ```

  In `stop`, before freeing:

  ```zig
      self.flusher.stop();
  ```

  In `applyShardBatch`, after each bulk-helper call populates the op's LSN (via a new return), call:

  ```zig
      const last_lsn_in_batch = /* track max LSN returned from bulk helpers */;
      self.flusher.requestFlush(last_lsn_in_batch) catch {};
      self.flusher.waitForLsn(last_lsn_in_batch);
  ```

  This requires bulk helpers to return the WAL LSN of their commit. Add a `last_statement_lsn` thread-local (mirroring `t_current_statement_txn`) that `StatementTxn.commit` populates with the LSN and skips the fsync. Commit defers fsync entirely.

  Modify `StatementTxn.commit`:

  ```zig
  pub fn commit(self: *StatementTxn) !void {
      // ... existing engine-side work ...
      const lsn = try self.mg.engine.appendWalCommit(self.txn_id);
      t_last_statement_lsn = lsn;
      // (no sync — flusher handles it)
  }
  ```

  Add exported lookup:

  ```zig
  pub fn getFlusherForGraph(graph_name: []const u8) !*wal_flusher.WalFlusher {
      const coord = lookupCoordinator(graph_name) orelse return error.GraphNotFound;
      return coord.flusher;
  }
  ```

- [ ] **Step 9.4: Run the test.**

  ```bash
  zig build test-sharded-coordinator-wal-group-commit 2>&1 | tail -5
  ```

  Expected: passes within ~5 s. If `fsyncs_total` > 200, tune `flush_window_ns`; if zero, check that the flusher thread is actually scheduled (`sleep(5ms)` may be too short on some kernels — bump to 20ms).

- [ ] **Step 9.5: Run crash-safety regression.**

  ```bash
  zig build test-wal-recovery test-undo-log-isolation 2>&1 | tail -5
  ```

  Expected: exit 0. If `test-wal-recovery` fails, the flusher is acking before fsync lands — fix the ordering in `loop()`: the `synced_lsn.store(wanted, .release)` MUST come strictly after `fsyncWalForGraph`.

- [ ] **Step 9.6: Commit.**

  ```bash
  git add src/storage/group_commit.zig src/storage/graph_storage_adapter.zig \
      tests/storage/test_sharded_coordinator_wal_group_commit.zig build.zig
  git commit -m "feat(storage): route coordinator commits through WalFlusher (Phase 3, Task 9)

  Coordinator apply → appendRecord + requestFlush + waitForLsn instead
  of per-batch fsync. 16 shard threads feed one flusher; 500 µs window
  coalesces fsyncs. 8000-op 16-thread test averages 40+ ops per fsync
  (vs 1 per batch pre-phase). Crash-recovery regression still green."
  ```

### Task 10: Phase 3 validation run

- [ ] **Step 10.1: Rebuild and re-run the baseline ingest.**

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-phase3 && mkdir -p /tmp/geode-phase3
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
      nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-phase3 --listen 127.0.0.1:3145 \
      --log-level warn > /tmp/geode-phase3/server.log 2>&1 &
  SERVER_PID=$!
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3145 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  time GEODE_DSN="quic://127.0.0.1:3145/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 2>&1 | tee docs/performance/2026-04-24-sharding/phase3-run.log | tail -30
  kill -9 $SERVER_PID 2>/dev/null || true
  ```

- [ ] **Step 10.2: Record results and commit evidence.**

  Create `docs/performance/2026-04-24-sharding/phase3-result.md` with the wall-clock + server-side `fsyncs_total` from the flusher stats (add a debug log line in the flusher if needed).

  **Phase 3 exit criterion:** per-op wall-clock down 2-5× vs Phase 2. Edge-phase total should be ≤ 5 min.

  ```bash
  git add docs/performance/2026-04-24-sharding/phase3-run.log \
      docs/performance/2026-04-24-sharding/phase3-result.md
  git commit -m "docs(perf): Phase 3 (WAL group commit) ingest measurement"
  ```

---

## Phase 4 — Client-side pipelining in msft-graph

Node-phase wall-clock is dominated by the ~30 s-per-file QUIC handshake+stream-setup cost paid by `pool.DB().Conn(ctx)` in `batchExecTx` at `/home/benji/src/devnw/go/msft/cmd/msft-graph/geodeutil.go:282`. Each file does `jsonl.Each` → `dispatchSeed` → `pipelineExec` → N workers, each worker takes a NEW conn from the pool. `drainIdle` at `seed.go:143` actively evicts idle conns between files. Replace with: persistent per-worker sessions that survive across files, plus server-side session reuse so the statement-txn boundary is a per-chunk BEGIN/COMMIT, not a per-chunk new-connection.

### Task 11: Replace per-chunk conn acquisition with persistent worker sessions

**Files:**
- Modify: `/home/benji/src/devnw/go/msft/cmd/msft-graph/geodeutil.go:272-324` (`batchExecTx` — take conn from a pre-allocated per-worker slot)
- Modify: `/home/benji/src/devnw/go/msft/cmd/msft-graph/geodeutil.go:326-424` (`pipelineExec` — own a `[]*sql.Conn` of length `workers`, round-robin or channel-pinned)
- Modify: `/home/benji/src/devnw/go/msft/cmd/msft-graph/seed.go:143-151` (`drainIdle` — no-op out between files; retain only on error recovery)
- Test: `/home/benji/src/devnw/go/msft/cmd/msft-graph/pipelineexec_persistent_conn_test.go` (new)

- [ ] **Step 11.1: Write the failing test.**

  Create `/home/benji/src/devnw/go/msft/cmd/msft-graph/pipelineexec_persistent_conn_test.go`:

  ```go
  package main

  import (
      "context"
      "database/sql"
      "testing"
      "time"
  )

  // pipelineExec with persistent conns must not issue a new conn from
  // the pool between chunks of the same file.  We pin that by
  // counting pool.DB().Stats().OpenConnections before and after a
  // 10-chunk synthetic run on a mock driver that tracks opens.
  func TestPipelineExecReusesConnsAcrossChunks(t *testing.T) {
      ctx := context.Background()
      stmts := make([]statement, 1000)
      for i := range stmts {
          stmts[i] = statement{Query: "SELECT 1", Args: nil}
      }
      pool := newTestPool(t) // helper backed by sqlmock
      defer pool.Close()

      // Pre-warm the pool so initial conns are NOT counted against
      // the per-chunk acquisition budget.
      if _, err := pool.DB().ExecContext(ctx, "SELECT 1"); err != nil {
          t.Fatal(err)
      }
      time.Sleep(10 * time.Millisecond)
      beforeOpen := pool.DB().Stats().OpenConnections

      if err := pipelineExec(ctx, pool, stmts, 100, 4, testLogger()); err != nil {
          t.Fatal(err)
      }

      afterOpen := pool.DB().Stats().OpenConnections
      // 4 workers × 10 chunks = 40 potential new conns under the old
      // behaviour.  Persistent behaviour: afterOpen == beforeOpen
      // (all conns are pooled and reused).
      if afterOpen > beforeOpen+4 {
          t.Errorf("pipelineExec opened %d new conns across 10 chunks; want ≤ 4 (one per worker)", afterOpen-beforeOpen)
      }
  }

  // Helper forward decl — implement in a test fixtures file alongside
  // the existing pipelineexec_behavior_test.go helpers.
  func newTestPool(t *testing.T) *geode.Pool {
      t.Helper()
      // sqlmock-backed Pool.  The shape of `geode.Pool` is defined
      // in the geode-client-go; the test pool wraps sqlmock + the
      // same Pool struct with ping driver.
      panic("implement via sqlmock; see pipelineexec_behavior_test.go for pattern")
  }
  func testLogger() *slog.Logger { return slog.Default() }
  ```

- [ ] **Step 11.2: Run to confirm RED.**

  ```bash
  cd /home/benji/src/devnw/go/msft
  go test -run TestPipelineExecReusesConnsAcrossChunks ./cmd/msft-graph/... 2>&1 | tail -10
  ```

  Expected: test fails — `afterOpen - beforeOpen` exceeds the budget (current behaviour opens 40+).

- [ ] **Step 11.3: Rework `pipelineExec` to pin one conn per worker.**

  Edit `/home/benji/src/devnw/go/msft/cmd/msft-graph/geodeutil.go`. Replace the body of `pipelineExec` with:

  ```go
  func pipelineExec(ctx context.Context, pool *geode.Pool, stmts []statement, chunkSize, maxWorkers int, logger *slog.Logger) error {
      if len(stmts) == 0 {
          return nil
      }
      if maxWorkers <= 0 {
          maxWorkers = defaultMaxWorkers
      }
      totalStmts := len(stmts)
      effectiveChunk := planChunkSize(totalStmts, chunkSize, maxWorkers)

      chunks := make([][]statement, 0, (totalStmts/effectiveChunk)+1)
      for i := 0; i < totalStmts; i += effectiveChunk {
          end := min(i+effectiveChunk, totalStmts)
          chunks = append(chunks, stmts[i:end])
      }

      logger.Info("pipeline exec start",
          "total", totalStmts, "chunks", len(chunks),
          "chunk_size", effectiveChunk, "workers", maxWorkers)

      // Channel of persistent conns.  Each worker owns one conn for
      // the lifetime of this pipelineExec call; the conn is RETURNED
      // to the channel between chunks (not to the pool), so the
      // QUIC stream stays warm.
      connCh := make(chan *sql.Conn, maxWorkers)
      for i := 0; i < maxWorkers; i++ {
          conn, err := pool.DB().Conn(ctx)
          if err != nil {
              // Close the ones already drained.
              close(connCh)
              for c := range connCh {
                  _ = c.Close()
              }
              return fmt.Errorf("pipelineExec: pre-warm conn %d: %w", i, err)
          }
          connCh <- conn
      }
      defer func() {
          close(connCh)
          for c := range connCh {
              _ = c.Close()
          }
      }()

      var flushed atomic.Int64
      var (
          wg       sync.WaitGroup
          mu       sync.Mutex
          errs     []error
          slowOnce sync.Once
      )

      for i, chunk := range chunks {
          if ctx.Err() != nil {
              break
          }
          conn := <-connCh
          wg.Add(1)
          go func(idx int, chunk []statement, conn *sql.Conn) {
              defer wg.Done()
              defer func() { connCh <- conn }() // return for reuse

              start := time.Now()
              if err := batchExecTxOnConn(ctx, conn, chunk, logger); err != nil {
                  mu.Lock()
                  errs = append(errs, fmt.Errorf("chunk %d: %w", idx, err))
                  mu.Unlock()
                  logger.Error("chunk failed", "chunk", idx, "error", err)
                  return
              }
              elapsed := time.Since(start)
              n := flushed.Add(int64(len(chunk)))
              logger.Info("pipeline progress",
                  "flushed", min(int(n), totalStmts), "total", totalStmts)
              if rate := chunkRate(len(chunk), elapsed); rate > 0 && rate < slowRateThreshold {
                  slowOnce.Do(func() {
                      logger.Warn("pipeline chunk is slow — consider reducing --workers",
                          "chunk", idx, "statements", len(chunk),
                          "elapsed", elapsed.Round(time.Second),
                          "stmts_per_sec", fmt.Sprintf("%.2f", rate),
                          "suggested_workers", max(1, maxWorkers/2))
                  })
              }
          }(i, chunk, conn)
      }
      wg.Wait()
      if len(errs) > 0 {
          return errors.Join(errs...)
      }
      logger.Info("pipeline exec complete", "statements", totalStmts)
      return nil
  }

  // Variant of batchExecTx that executes on a caller-provided
  // persistent sql.Conn instead of acquiring one from the pool.
  func batchExecTxOnConn(ctx context.Context, conn *sql.Conn, stmts []statement) error {
      timeout := chunkTimeout(len(stmts))
      ctx, cancel := context.WithTimeout(ctx, timeout)
      defer cancel()
      tx, err := conn.BeginTx(ctx, nil)
      if err != nil {
          if isStaleTxErr(err) {
              _, _ = conn.ExecContext(ctx, "ROLLBACK")
              tx, err = conn.BeginTx(ctx, nil)
          }
          if err != nil {
              return fmt.Errorf("batch begin tx: %w", err)
          }
      }
      defer func() {
          if rbErr := tx.Rollback(); rbErr != nil && !errors.Is(rbErr, sql.ErrTxDone) {
              slog.Debug("batch tx rollback error", "error", rbErr)
          }
      }()
      for i, stmt := range stmts {
          if ctx.Err() != nil {
              return ctx.Err()
          }
          if _, err := tx.ExecContext(ctx, stmt.Query, stmt.Args...); err != nil {
              return fmt.Errorf("statement %d: %w", i+1, err)
          }
      }
      return tx.Commit()
  }
  ```

  Remove or gate `drainIdle(pool)` in `seed.go:143` — only keep it on the error-path in `dispatchSeed` (`if !opts.serialFallback { return err }` block, before the fallback).

- [ ] **Step 11.4: Run the Go test.**

  ```bash
  cd /home/benji/src/devnw/go/msft
  go test -run TestPipelineExecReusesConnsAcrossChunks ./cmd/msft-graph/... 2>&1 | tail -5
  ```

  Expected: pass — `afterOpen - beforeOpen` ≤ `workers`.

- [ ] **Step 11.5: Run the full msft-graph test suite.**

  ```bash
  cd /home/benji/src/devnw/go/msft
  go test ./cmd/msft-graph/... 2>&1 | tail -20
  ```

  Expected: exit 0. The pre-existing `TestPipelineExecRetriesOnTransportError` and `TestBatchExecTxEvictsStaleConn` tests MUST still pass — the retry/eviction path still goes through the pool when a conn is declared bad, it just no longer gets a fresh pool-acquired conn between chunks.

- [ ] **Step 11.6: Rebuild msft-graph.**

  ```bash
  cd /home/benji/src/devnw/go/msft
  go install ./cmd/msft-graph
  ```

  Confirm `which msft-graph` still resolves and the new binary is on PATH.

- [ ] **Step 11.7: Commit.**

  ```bash
  cd /home/benji/src/devnw/go/msft
  git add cmd/msft-graph/geodeutil.go cmd/msft-graph/seed.go \
      cmd/msft-graph/pipelineexec_persistent_conn_test.go
  git commit -m "perf(seed): persistent per-worker conns in pipelineExec (Phase 4, Task 11)

  pipelineExec now acquires N conns once and returns them to a local
  channel between chunks instead of the pool. Eliminates the ~30 s
  QUIC handshake cost per file. drainIdle disabled on the happy
  path; still runs on error recovery to evict poisoned conns."
  ```

### Task 12: Cross-file connection reuse

**Files:**
- Modify: `/home/benji/src/devnw/go/msft/cmd/msft-graph/seed.go:257-334` (node + edge seeding loop — pool-level persistence across files)

Task 11 eliminates per-chunk reconnect. This task eliminates per-file reconnect by holding a single set of warmed conns across the whole seed run instead of letting the pool's idle eviction close them between files.

- [ ] **Step 12.1: Write the failing test.**

  Append to `/home/benji/src/devnw/go/msft/cmd/msft-graph/pipelineexec_persistent_conn_test.go`:

  ```go
  func TestRunSeedReusesConnsAcrossFiles(t *testing.T) {
      // End-to-end: seed with N files, expect cumulative openCount
      // per pool remains close to `workers` — not `files * workers`.
      // Uses a local geode server; skipped if GEODE_E2E_BIN is unset.
      t.Skip("wired by Task 12.2; requires local geode + small fixture dir")
  }
  ```

- [ ] **Step 12.2: Size the pool idle budget to `workers` at startup.**

  Edit `connectGeodeWithWorkers` (or the analogous setup in `seed.go`). Ensure:

  ```go
  db := pool.DB()
  db.SetMaxIdleConns(opts.workers)
  db.SetConnMaxIdleTime(0) // no idle eviction during seed
  ```

  This keeps the `workers` warm conns alive across files. The Task 11 `pipelineExec` acquires from the pool, which — now that idle eviction is disabled — reuses the existing QUIC sessions.

- [ ] **Step 12.3: Run the e2e seed against a local server.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-phase4 && mkdir -p /tmp/geode-phase4
  cd /home/benji/src/devnw/codepros/geode/geode
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
      nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-phase4 --listen 127.0.0.1:3146 \
      --log-level warn > /tmp/geode-phase4/server.log 2>&1 &
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3146 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  time GEODE_DSN="quic://127.0.0.1:3146/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 2>&1 | tee docs/performance/2026-04-24-sharding/phase4-run.log | tail -30
  pkill -9 -f "geode serve --data-dir /tmp/geode-phase4" 2>/dev/null || true
  ```

- [ ] **Step 12.4: Verify the node phase dropped.**

  In `docs/performance/2026-04-24-sharding/phase4-run.log`, search for the first and last `seeded nodes` log lines. Compute the node-phase wall-clock:

  ```bash
  grep "seeded nodes\|seeding nodes" docs/performance/2026-04-24-sharding/phase4-run.log | head -5
  grep "seeded nodes\|seeding nodes" docs/performance/2026-04-24-sharding/phase4-run.log | tail -5
  ```

  **Phase 4 exit criterion:** node phase wall-clock drops from ~13 min to ≤ 30 s.

- [ ] **Step 12.5: Commit.**

  ```bash
  cd /home/benji/src/devnw/go/msft
  git add cmd/msft-graph/seed.go cmd/msft-graph/pipelineexec_persistent_conn_test.go
  git commit -m "perf(seed): disable idle eviction during seed (Phase 4, Task 12)

  SetMaxIdleConns(workers) + SetConnMaxIdleTime(0) keeps QUIC
  sessions warm across files. Node phase wall-clock: ~13 min → ≤ 30 s
  on the msft-graph eagleg-topology-data-16 dataset."
  ```

  ```bash
  cd /home/benji/src/devnw/codepros/geode/geode
  git add docs/performance/2026-04-24-sharding/phase4-run.log
  git commit -m "docs(perf): Phase 4 (client persistent-conn) ingest measurement"
  ```

---

## Phase 5 — End-to-end validation and regression coverage

### Task 13: Full-run measurement and ≤ 60 s assertion

- [ ] **Step 13.1: Run the full ingest on a clean server with all phases active.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-final && mkdir -p /tmp/geode-final
  cd /home/benji/src/devnw/codepros/geode/geode
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
      nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-final --listen 127.0.0.1:3147 \
      --log-level warn > /tmp/geode-final/server.log 2>&1 &
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3147 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  echo "=== start $(date -Iseconds) ==="
  time GEODE_DSN="quic://127.0.0.1:3147/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 2>&1 | tee docs/performance/2026-04-24-sharding/final-run.log | tail -30
  echo "=== end $(date -Iseconds) ==="
  pkill -9 -f "geode serve --data-dir /tmp/geode-final" 2>/dev/null || true
  ```

- [ ] **Step 13.2: Check the wall-clock.**

  The `time` output should show `real <= 1m0s`. If not, identify which phase regressed via the per-file timestamps in `final-run.log` and open a follow-up task for that specific file set.

- [ ] **Step 13.3: Verify the data is correct.**

  ```bash
  rm -rf /tmp/geode-verify && mkdir -p /tmp/geode-verify
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
      nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-final --listen 127.0.0.1:3148 \
      --log-level warn > /tmp/geode-verify/server.log 2>&1 &
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3148 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      --graph abs_eagleg \
      "MATCH (n) RETURN count(n) AS nodes"
  zig-out/bin/geode query --server 127.0.0.1:3148 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      --graph abs_eagleg \
      "MATCH ()-[r]->() RETURN count(r) AS edges"
  pkill -9 -f "geode serve --data-dir /tmp/geode-final" 2>/dev/null || true
  ```

  Expected: `nodes = 9350` and `edges = 35208` (matches the R13 baseline).

- [ ] **Step 13.4: Record the final result.**

  Create `docs/performance/2026-04-24-sharding/FINAL.md`:

  ```markdown
  # Graph sharding + WAL group commit + client pipelining — final result

  ## Before
  - R13 baseline (2026-04-22): 2 h 5 m 33 s, 48 chunk failures, serial cascades.
  - 2026-04-23 session (Tasks 1–19 enterprise-ingest): ~40 min to cascade on edges_signed_in_from.

  ## After (this plan)
  - Phase 2 (shard locks + 16 shard threads): <result>
  - Phase 3 (WAL flusher): <result>
  - Phase 4 (client persistent conns): <result>
  - End-to-end: <total>

  ## Data integrity
  - MATCH (n) RETURN count(n) → 9350 ✓
  - MATCH ()-[r]->() RETURN count(r) → 35208 ✓

  ## Scaling claim
  From 125 min (R13) → N s (this plan).  ~<X>× improvement.
  ```

### Task 14: CI regression coverage

- [ ] **Step 14.1: Add a load-test-parity benchmark entry.**

  Edit `benchmarks/loadtest/baseline.jsonl` (or the equivalent baseline file referenced in `CLAUDE.md:164`). Add a line for the msft-graph eagleg-topology seed with the new target QPS / total wall-clock.

- [ ] **Step 14.2: Wire a smaller-scale CI smoke test.**

  Create `tests/integration/test_ingest_smoke.zig` that runs a scaled-down fixture (e.g. 1k nodes + 5k edges via `msft-graph` on a generated mini-dataset) against a local server and asserts completion in < 10 s. Add to `build.zig` as `test-ingest-smoke`.

- [ ] **Step 14.3: Wire the smoke test into the default `zig build test`.**

  Edit `build.zig` so `zig build test` includes `test-sharded-store`, `test-graph-store-sharded-invariants`, `test-shard-locks`, `test-bulk-shard-concurrency`, `test-sharded-coordinator`, `test-wal-flusher`, `test-sharded-coordinator-wal-group-commit`, and `test-ingest-smoke` as dependencies.

- [ ] **Step 14.4: Commit.**

  ```bash
  git add benchmarks/loadtest/baseline.jsonl tests/integration/test_ingest_smoke.zig build.zig \
      docs/performance/2026-04-24-sharding/FINAL.md \
      docs/performance/2026-04-24-sharding/final-run.log
  git commit -m "test(perf): ingest smoke + updated baseline for sharding plan (Phase 5, Task 14)

  Adds test-ingest-smoke (1k nodes + 5k edges < 10 s on CI) and
  wires it into the default test target. Updates loadtest baseline
  to reflect the sharded-coordinator + WAL-flusher + client
  persistent-conns regime. FINAL.md captures before/after numbers."
  ```

---

## Success criteria

At the end of the plan:

1. `zig build test` exits 0, including every new test: `test-sharded-store`, `test-graph-store-sharded-invariants`, `test-shard-locks`, `test-bulk-shard-concurrency`, `test-sharded-coordinator`, `test-wal-flusher`, `test-sharded-coordinator-wal-group-commit`, `test-ingest-smoke`.
2. `msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000` completes in ≤ 60 s total wall-clock.
3. Post-ingest `MATCH (n) RETURN count(n)` returns 9350 and `MATCH ()-[r]->() RETURN count(r)` returns 35208.
4. Pre-existing regression tests (`test-r6-parallel-ingest`, `test-graph-write-lock-cancelable`, `test-undo-log-isolation`, `test-orphan-txn-cleanup`, `test-match-read-serial`, `test-handler-lock-hold-scope`, `test-wal-recovery`) remain green.
5. `docs/performance/2026-04-24-sharding/FINAL.md` documents the before/after with per-phase attribution.

## Stopping early

If Phase 2 alone lands ≤ 60 s on the hardware-of-record:
- Skip Phases 3 and 4.
- Still land Task 14 CI coverage.
- Record the phase-2 wall-clock in `FINAL.md` and note that Phases 3–4 remain as future optimisations.

If Phase 3 lands the server-side budget under 30 s but the node phase is still 10+ min, the bottleneck is confirmed client-side — proceed to Phase 4.
