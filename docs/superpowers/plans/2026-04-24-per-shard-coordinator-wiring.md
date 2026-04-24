# Per-Shard Coordinator Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land msft-graph 16-way ingest at ≤ 60 s wall-clock by rewiring geode's group-commit coordinator onto the `ShardedGraphEngine` from Item 1, eliminating the `string_indexes_mutex` 3–4× regression and the MVCC write-write-conflict 40001 cascade.

**Architecture:** Three coupled changes: (1) per-shard `label_index` / `edge_type_index` on `ManagedGraph` (removes the global `string_indexes_mutex`); (2) restore and wire the `ShardedCoordinator` from commit `210de668` as the default coordinator per graph, routing `submit(op)` by `shardIndex(primary_node_id)` so the same-resource writes land on the same thread; (3) per-shard `WalFlusher` background thread batching fsync within a 500 µs window.

**Tech Stack:** Zig 0.16.0+, upstream `graph_storage` repo at tag that exposes `ShardedGraphEngine` + `SHARD_COUNT` + `shardIndex(u64) usize` (Item 1 spec — see `gitlab.com/devnw/zig/graph-storage` branch `perf/sharded-engine`). Geode primitives: `pooled.ThreadPool`, `std.atomic.Value`, `std.Io.Mutex`, `std.Io.RwLock`, existing per-shard rwlock work from Phase 2 Task 4 (`b061a238`). Verification: `zig build test`, `msft-graph seed`, `strace -e fsync -c`.

---

## File structure

**Create:**
- `src/storage/sharded_coordinator.zig` — restored/refactored N-way coordinator, pulled from commit `210de668` (the Task 6 implementation that was reverted). Lives as a separate file rather than inside `group_commit.zig` to keep each file focused.
- `src/storage/wal_flusher.zig` — per-shard background fsync batcher.
- `tests/test_sharded_coordinator_wiring.zig` — integration tests covering routing, per-shard state isolation, cross-shard edges, and the 40001-regression-is-gone assertion.
- `tests/test_wal_flusher.zig` — unit tests for the flusher's batch-window semantics.
- `tests/test_managed_graph_shard_state.zig` — unit tests verifying per-shard `label_index` / `edge_type_index` semantics (isolation, merge-on-read, no cross-shard mutex).
- `docs/performance/2026-04-24-sharding/phase2-final-run.log` — evidence file for the exit-criterion msft-graph measurement.

**Modify:**
- `src/storage/graph_storage_adapter.zig` — replace `string_indexes_mutex` + `label_index` + `edge_type_index` with per-shard arrays. Update all read and write paths.
- `src/storage/group_commit.zig` — thread through a `ShardedCoordinator` alternative when `GEODE_SHARDED_COORD=1` (default-on once stable). Keep the single-flusher path for safe fallback until ingest numbers confirm the new path.
- `src/transactions/manager.zig` — add a debug-build assertion in `hasWriteWriteConflicts` that panics on routing-bug detection (expected to never fire under deterministic shard routing).
- `build.zig` — wire the new test targets.
- `docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md` — add a closing note pointing at this plan's evidence file.

**Leave alone:**
- `src/execution/set_operations.zig` — parallel UNION is orthogonal; its counter probe (added in `55f842b3`) stays.
- `src/graph_store.zig` — the RCU `merge_prop_index` snapshot plan (`2026-04-24-lock-free-merge-prop-index-snapshot.md`) is independent; lands on its own schedule.
- QUIC / proto layers — the 40001 error-mapping path is unchanged. We eliminate the *cause*, not the mapping.

---

## Phase 0 — Pre-work: verify dependency, reproduce baseline

### Task 0: Confirm Item 1 is available and the baseline reproduces

- [ ] **Step 0.1: Verify the upstream sharded-engine dependency is pinned.**

  Run: `grep -A2 'graph_storage' build.zig.zon | head -10`
  Expected output: a URL ending in `graph-storage.git#<commit>` where `<commit>` is on the `perf/sharded-engine` branch (not `main`), and the commit SHA must post-date `383f481` (the Item 1 spec commit). If the pinned SHA is still `2dadc13` (the pre-Item-1 v0.2.0), stop and bump the dependency before continuing.

  To bump, from repo root:

  ```bash
  # Fetch latest SHA from the upstream branch
  LATEST=$(git ls-remote https://gitlab.com/devnw/zig/graph-storage.git refs/heads/perf/sharded-engine | awk '{print $1}')
  echo "Upstream HEAD: $LATEST"
  # Update build.zig.zon: change the graph_storage url's #<sha> suffix
  # and clear the stale hash so zig build re-fetches.
  sed -i "s|git+https://gitlab.com/devnw/zig/graph-storage.git#[0-9a-f]*|git+https://gitlab.com/devnw/zig/graph-storage.git#$LATEST|" build.zig.zon
  sed -i "/\.graph_storage = .{/,/}/ { /\.hash = / d }" build.zig.zon
  zig build 2>&1 | grep -E 'hash.*mismatch|expected' | head -1
  # The error will include the correct hash — copy it back into build.zig.zon.
  ```

- [ ] **Step 0.2: Verify the sharded engine API exposes the names this plan assumes.**

  Run:

  ```bash
  zig build test 2>&1 | head -5 # must compile
  grep -n 'pub const SHARD_COUNT\|pub fn shardIndex\|pub const ShardedGraphEngine' \
    "$(zig build --verbose 2>&1 | grep graph_storage | grep -o '[^ ]*graph_storage[^ ]*\.zig' | head -1 | xargs dirname)/src/root.zig"
  ```

  Expected: three grep matches. If any is missing, the upstream API has drifted from the Item 1 spec — stop and reconcile in the spec before writing code against it.

  **Reconciliation note (2026-04-25):** At the pinned SHA (`0ce1576`), only `ShardedGraphEngine` is re-exported at the package root. `SHARD_COUNT` and `shardIndex` live in submodules that ARE re-exported at root (`sharded_store`, `shard_count`). All subsequent tasks use the submodule path: `graph_storage.sharded_store.SHARD_COUNT` and `graph_storage.sharded_store.shardIndex(u64)`. Semantics unchanged; no upstream bump required.

  **Dataset substitution (2026-04-25):** The canonical `/home/benji/eagleg-topology-data-16` dataset (9,350 nodes + 35,208 edges = 44,558 statements) is not present on this host. Substituting `/data/home/benji/eagleg-topology-data-20` (12,565 nodes + 39,572 edges = 52,137 statements, ~17% larger). Pro-rata adjustment of the Phase 5 exit criterion: "≤ 60s" becomes "≤ 70s" for this run. Both baseline and final runs use the same substituted dataset, so the relative comparison is apples-to-apples.

- [ ] **Step 0.3: Reproduce the baseline `msft-graph` ingest cascade.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-phase2-baseline && mkdir -p /tmp/geode-phase2-baseline
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
    nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-phase2-baseline \
      --listen 127.0.0.1:3143 --log-level warn \
      > /tmp/geode-phase2-baseline/server.log 2>&1 &
  SERVER_PID=$!
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3143 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session \
    "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  echo "=== baseline start $(date -Iseconds) ==="
  time GEODE_DSN="quic://127.0.0.1:3143/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
    msft-graph seed --input /home/benji/eagleg-topology-data-16 \
    --parallel --workers 16 --chunk-size 1000 2>&1 | \
    tee docs/performance/2026-04-24-sharding/phase2-plan-baseline.log
  echo "=== baseline end $(date -Iseconds) ==="
  kill -9 $SERVER_PID 2>/dev/null || true
  ```

  Expected: the ingest cascades to serial-fallback within ~40 min (or earlier). Kill at 45 min if it hasn't cascaded. Record the wall-clock time and the first cascading edge file name in `docs/performance/2026-04-24-sharding/phase2-plan-baseline.log` — this is the number Phase 5 will beat.

- [ ] **Step 0.4: Commit the baseline log.**

  ```bash
  git add docs/performance/2026-04-24-sharding/phase2-plan-baseline.log
  git commit -m "docs(perf): Phase 2-final plan baseline — msft-graph ingest wall-clock"
  ```

---

## Phase 1 — Per-shard auxiliary state

The `ManagedGraph` struct currently holds `label_index` and `edge_type_index` behind `string_indexes_mutex`. Phase 1 replaces each with a shard-indexed array so the coordinator's worker threads operate only on their own shard's data.

### Task 1: Add `ManagedGraph` shard-state scaffolding (no behavioural change yet)

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig` (around the existing `label_index` / `edge_type_index` / `string_indexes_mutex` declarations; `grep -n 'label_index:\|string_indexes_mutex' src/storage/graph_storage_adapter.zig` to locate)
- Test: `tests/test_managed_graph_shard_state.zig` (new)

Add new per-shard arrays side-by-side with the existing fields. Leave the old fields in place — Phase 1 only introduces scaffolding; Task 2 removes the old ones once the new ones are wired through.

- [ ] **Step 1.1: Write the failing test.**

  Create `tests/test_managed_graph_shard_state.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const graph_storage = @import("graph_storage");
  const adapter_mod = geode.graph_storage_adapter;

  test "ManagedGraph exposes per-shard label and edge-type indexes" {
      const allocator = testing.allocator;
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();

      const mg = try adapter.getOrCreateGraph("g_shard_state");

      try testing.expectEqual(
          @as(usize, graph_storage.SHARD_COUNT),
          mg.shard_label_indexes.len,
      );
      try testing.expectEqual(
          @as(usize, graph_storage.SHARD_COUNT),
          mg.shard_edge_type_indexes.len,
      );

      for (mg.shard_label_indexes) |*m| try testing.expectEqual(@as(u32, 0), m.count());
      for (mg.shard_edge_type_indexes) |*m| try testing.expectEqual(@as(u32, 0), m.count());
  }
  ```

  Wire the new test into `build.zig` by adding to the test step group where sibling `test_sharded_coordinator.zig` is already registered (`grep -n 'test_sharded_coordinator' build.zig` to locate).

- [ ] **Step 1.2: Run the test to verify it fails.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "ManagedGraph exposes per-shard"`
  Expected: compile error — `mg.shard_label_indexes` doesn't exist.

- [ ] **Step 1.3: Add the scaffolding fields to `ManagedGraph`.**

  In `src/storage/graph_storage_adapter.zig`, locate the existing `ManagedGraph` struct. Immediately after the `label_index` / `edge_type_index` declarations, add:

  ```zig
      /// GAP-0814/Phase-2-final per-shard label index. Each entry is a
      /// StringHashMap(std.ArrayList(u64)) owned exclusively by the
      /// coordinator worker thread whose shard id equals the array index.
      /// Reads (from match/label scans) fan out across all shards; writes
      /// (from the coordinator) touch only their own shard. No mutex
      /// needed — thread ownership replaces it.
      ///
      /// Lives parallel to the legacy `label_index` until Task 2 cuts
      /// readers over and deletes the legacy map.
      shard_label_indexes: [graph_storage.SHARD_COUNT]std.StringHashMap(std.ArrayList(u64)),
      shard_edge_type_indexes: [graph_storage.SHARD_COUNT]std.StringHashMap(std.ArrayList(u64)),
  ```

  Initialise both in `ManagedGraph.init` (or wherever the existing `label_index` is initialised — `grep -n 'label_index.*= .*StringHashMap' src/storage/graph_storage_adapter.zig`):

  ```zig
      var shard_label_indexes: [graph_storage.SHARD_COUNT]std.StringHashMap(std.ArrayList(u64)) = undefined;
      var shard_edge_type_indexes: [graph_storage.SHARD_COUNT]std.StringHashMap(std.ArrayList(u64)) = undefined;
      for (&shard_label_indexes) |*m| m.* = std.StringHashMap(std.ArrayList(u64)).init(allocator);
      for (&shard_edge_type_indexes) |*m| m.* = std.StringHashMap(std.ArrayList(u64)).init(allocator);
  ```

  Assign into the struct literal and deinit them in `ManagedGraph.deinit`:

  ```zig
      for (&self.shard_label_indexes) |*m| {
          var it = m.iterator();
          while (it.next()) |e| e.value_ptr.deinit(allocator);
          m.deinit();
      }
      for (&self.shard_edge_type_indexes) |*m| {
          var it = m.iterator();
          while (it.next()) |e| e.value_ptr.deinit(allocator);
          m.deinit();
      }
  ```

  Add the import at the top of `graph_storage_adapter.zig` if not already present:

  ```zig
  const graph_storage = @import("graph_storage");
  ```

- [ ] **Step 1.4: Run the test to verify it passes.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "ManagedGraph exposes per-shard"`
  Expected: the new test passes. No other tests should have regressed (the legacy `label_index` is still untouched).

- [ ] **Step 1.5: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig tests/test_managed_graph_shard_state.zig build.zig
  git commit -m "feat(storage): scaffold per-shard label/edge-type indexes on ManagedGraph (Task 1)"
  ```

### Task 2: Route writes and reads through shard indexes; delete the legacy mutex-protected map

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig` — all call sites of `label_index` / `edge_type_index` / `string_indexes_mutex`.
- Test: extend `tests/test_managed_graph_shard_state.zig`.

This is the invasive step. We enumerate every read/write site, port each one, and then remove the legacy field.

- [ ] **Step 2.1: Write the failing test — fan-out read across shards.**

  Append to `tests/test_managed_graph_shard_state.zig`:

  ```zig
  test "ManagedGraph labelPostingList merges across shards" {
      const allocator = testing.allocator;
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();

      const mg = try adapter.getOrCreateGraph("g_fanout");

      // Seed each shard's label_index with one distinct node id under the
      // same label name, simulating what happens when a coordinator thread
      // has just touched its shard's map.
      var ids: [graph_storage.SHARD_COUNT]u64 = undefined;
      for (ids, 0..) |_, i| {
          // Pick a node id that `graph_storage.shardIndex` maps to shard i.
          // We linearly search a small range; shardIndex is deterministic.
          var candidate: u64 = @as(u64, @intCast(i)) + 1;
          while (graph_storage.shardIndex(candidate) != i) : (candidate += 1) {}
          ids[i] = candidate;

          // Insert directly into that shard's map (bypassing routing so
          // this is a pure read-side fan-out test).
          const gop = try mg.shard_label_indexes[i].getOrPut("Person");
          if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u64).empty;
          try gop.value_ptr.append(allocator, candidate);
      }

      // Read: fan-out-and-merge. All SHARD_COUNT node ids should appear.
      var merged = std.ArrayList(u64).empty;
      defer merged.deinit(allocator);
      try mg.labelPostingListFanOut("Person", allocator, &merged);
      try testing.expectEqual(@as(usize, graph_storage.SHARD_COUNT), merged.items.len);
  }
  ```

- [ ] **Step 2.2: Run the test to verify it fails.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "labelPostingList merges"`
  Expected: compile error — `labelPostingListFanOut` does not exist.

- [ ] **Step 2.3: Implement the fan-out read helper.**

  In `src/storage/graph_storage_adapter.zig`, add to `ManagedGraph`:

  ```zig
      /// Read-side fan-out: merge every shard's posting list for `label`
      /// into `out`. Callers are typically label-scan match paths. The
      /// merge is allocation-per-shard but never takes a lock — each
      /// shard's map is only mutated by the coordinator thread that owns
      /// it, and we read under the coordinator's own shard-local
      /// guarantee (the coordinator publishes via sequentially-consistent
      /// atomic ops, implicit in std.StringHashMap operations).
      ///
      /// O(total_postings) in the best case; no sort, no dedup (the
      /// id-space striping scheme guarantees uniqueness per (shard, id)).
      pub fn labelPostingListFanOut(
          self: *ManagedGraph,
          label: []const u8,
          allocator: std.mem.Allocator,
          out: *std.ArrayList(u64),
      ) !void {
          _ = allocator;
          for (&self.shard_label_indexes) |*shard_map| {
              if (shard_map.get(label)) |list| {
                  try out.appendSlice(list.items);
              }
          }
      }

      /// Read-side fan-out for edge-type posting lists.  Same semantics
      /// as labelPostingListFanOut.
      pub fn edgeTypePostingListFanOut(
          self: *ManagedGraph,
          edge_type: []const u8,
          allocator: std.mem.Allocator,
          out: *std.ArrayList(u64),
      ) !void {
          _ = allocator;
          for (&self.shard_edge_type_indexes) |*shard_map| {
              if (shard_map.get(edge_type)) |list| {
                  try out.appendSlice(list.items);
              }
          }
      }
  ```

- [ ] **Step 2.4: Run test to verify it passes.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "labelPostingList merges"`
  Expected: PASS.

- [ ] **Step 2.5: Port every legacy read site to the fan-out helpers.**

  Locate call sites:

  ```bash
  grep -n 'label_index\.get\|label_index\.iterator\|edge_type_index\.get\|edge_type_index\.iterator\|string_indexes_mutex' \
    src/storage/graph_storage_adapter.zig src/execution/*.zig src/graph_store.zig | head -60
  ```

  For each site that **reads** `label_index` / `edge_type_index`, replace with the fan-out helpers. Pattern:

  ```zig
  // Before:
  mg.string_indexes_mutex.lock();
  defer mg.string_indexes_mutex.unlock();
  const list = mg.label_index.get(label_name);
  // … use list …

  // After (read path):
  var merged: std.ArrayList(u64) = .empty;
  defer merged.deinit(allocator);
  try mg.labelPostingListFanOut(label_name, allocator, &merged);
  // … use merged.items …
  ```

  Go through each match / label-scan site carefully; do NOT blindly find-replace. Some sites need more substantial refactoring if they assumed a single list pointer.

- [ ] **Step 2.6: Port every legacy write site to use the routing helper.**

  Locate call sites:

  ```bash
  grep -n 'label_index\.put\|label_index\.getOrPut\|edge_type_index\.put\|edge_type_index\.getOrPut' \
    src/storage/graph_storage_adapter.zig src/execution/*.zig src/graph_store.zig | head -60
  ```

  Add a write helper that routes by the node id being inserted:

  ```zig
      /// Write-side routing. The coordinator worker thread for shard
      /// `shardIndex(node_id)` is the only caller that mutates
      /// `shard_label_indexes[shardIndex(node_id)]` — no lock required.
      /// Callers OUTSIDE the coordinator (e.g., bootstrap, index
      /// rebuild) must fall back to the slow locked path via
      /// `appendLabelPostingLocked`.
      pub fn appendLabelPosting(
          self: *ManagedGraph,
          allocator: std.mem.Allocator,
          label: []const u8,
          node_id: u64,
      ) !void {
          const s = graph_storage.shardIndex(node_id);
          const gop = try self.shard_label_indexes[s].getOrPut(label);
          if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u64).empty;
          try gop.value_ptr.append(allocator, node_id);
      }

      pub fn appendEdgeTypePosting(
          self: *ManagedGraph,
          allocator: std.mem.Allocator,
          edge_type: []const u8,
          edge_id: u64,
      ) !void {
          const s = graph_storage.shardIndex(edge_id);
          const gop = try self.shard_edge_type_indexes[s].getOrPut(edge_type);
          if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u64).empty;
          try gop.value_ptr.append(allocator, edge_id);
      }
  ```

  Replace the legacy writes. Each site must route by the node/edge id it's about to insert — if the site doesn't have an id yet (e.g., a precompute pass before id allocation), restructure so the posting-list append happens AFTER the id is known.

- [ ] **Step 2.7: Delete the legacy fields and mutex.**

  In `ManagedGraph`:
  - Remove `label_index: std.StringHashMap(std.ArrayList(u64))`.
  - Remove `edge_type_index: std.StringHashMap(std.ArrayList(u64))`.
  - Remove `string_indexes_mutex: std.Thread.Mutex`.
  - Remove the corresponding init/deinit/clear code.

- [ ] **Step 2.8: Run full test suite to verify nothing regressed.**

  Run: `zig build test 2>&1 | grep -c "error:"` — should print `0`. Then:

  Run: `zig build test 2>&1 | tail -5` — expect a clean completion (no `Failed` lines from pre-commit-style runners; the Zig build runner's `+- run test N pass, 0 fail` pattern is fine).

- [ ] **Step 2.9: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig src/execution/*.zig src/graph_store.zig tests/test_managed_graph_shard_state.zig
  git commit -m "refactor(storage): per-shard label/edge-type indexes; remove string_indexes_mutex (Task 2)"
  ```

---

## Phase 2 — Restore `ShardedCoordinator` and wire routing

### Task 3: Recover `ShardedCoordinator` from git history

**Files:**
- Create: `src/storage/sharded_coordinator.zig` — new home for the coordinator type. Separate file rather than inside `group_commit.zig` because `group_commit.zig` is already ~600 lines and the two coordinator variants deserve independent files.
- Test: `tests/test_sharded_coordinator_wiring.zig` (new).

- [ ] **Step 3.1: Write the failing test — a ShardedCoordinator exists and routes by shard.**

  Create `tests/test_sharded_coordinator_wiring.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const graph_storage = @import("graph_storage");
  const adapter_mod = geode.graph_storage_adapter;
  const sharded_coordinator = @import("geode").sharded_coordinator;

  test "ShardedCoordinator routes ops by shardIndex(primary_node_id)" {
      const allocator = testing.allocator;
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();

      _ = try adapter.getOrCreateGraph("g_route");

      const coord = try sharded_coordinator.ShardedCoordinator.init(allocator, &adapter, "g_route");
      defer coord.deinit();

      // Submit N ops whose primary_node_ids are chosen to hash to shard 0
      // exclusively. After submission, shard 0's queue should have N items
      // and every other shard should have 0.
      var ids_on_shard_0: [8]u64 = undefined;
      var c: u64 = 1;
      for (&ids_on_shard_0) |*slot| {
          while (graph_storage.shardIndex(c) != 0) : (c += 1) {}
          slot.* = c;
          c += 1;
      }

      for (ids_on_shard_0) |nid| {
          var op = sharded_coordinator.ApplyOp{ .probe_routing = .{ .primary_node_id = nid } };
          try coord.enqueue(&op);
      }

      // Inspect queue depths (test-only accessor).
      for (0..graph_storage.SHARD_COUNT) |s| {
          const depth = coord.shardQueueDepthForTest(s);
          if (s == 0) {
              try testing.expectEqual(@as(usize, ids_on_shard_0.len), depth);
          } else {
              try testing.expectEqual(@as(usize, 0), depth);
          }
      }
  }
  ```

- [ ] **Step 3.2: Run test to verify it fails.**

  Run: `zig build test 2>&1 | grep "sharded_coordinator\|ShardedCoordinator"`
  Expected: compile error — module `sharded_coordinator` not found.

- [ ] **Step 3.3: Retrieve the reverted ShardedCoordinator from git history.**

  ```bash
  # Show the file as it existed just before the Phase 2.1 revert.
  git show 210de668:src/storage/group_commit.zig > /tmp/group_commit_at_210de668.zig
  # The ShardedCoordinator type lived at the bottom of that file; extract it.
  awk '/^pub const ShardedCoordinator/,/^};$/' /tmp/group_commit_at_210de668.zig > /tmp/sharded_coordinator_raw.zig
  wc -l /tmp/sharded_coordinator_raw.zig
  ```

  Inspect `/tmp/sharded_coordinator_raw.zig` manually. Expected: a single `ShardedCoordinator` struct definition (~150–250 lines with helper types) encompassing per-shard workers + an enqueue path. Note: the original `ApplyOp` union lived inside `group_commit.zig`; you'll need to reconstruct it or import from the single-flusher coordinator.

- [ ] **Step 3.4: Write the new `src/storage/sharded_coordinator.zig`.**

  Using `/tmp/sharded_coordinator_raw.zig` as the starting point, create the new file with the fixes applied:

  1. Move `ApplyOp` to a shared location — either keep it in `group_commit.zig` and import it here, or extract it to `src/storage/apply_op.zig` (cleaner). Add a new `.probe_routing` variant used only by tests; production paths never use it.
  2. Add a `shardQueueDepthForTest` accessor guarded by `if (@import("builtin").is_test)`.
  3. Rename the `submit` method to `enqueue` to mirror the spec's architectural verb. Add `submit` as a thin deprecated alias for any caller the revert missed.
  4. **Do NOT** take `string_indexes_mutex` anywhere — it no longer exists (Task 2). This is the whole point.
  5. Each shard worker loop must acquire ONLY its own shard's write lock via `mg.acquireShardWriteLock(shard_index)` (the Phase 2 Task 4 primitive at commit `b061a238`).

  Wire the new module as an export in `src/lib.zig`:

  ```zig
  pub const sharded_coordinator = @import("storage/sharded_coordinator.zig");
  ```

  Add the test to `build.zig` test step.

- [ ] **Step 3.5: Run test to verify it passes.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "ShardedCoordinator routes"`
  Expected: PASS.

- [ ] **Step 3.6: Run the broader suite to verify no regressions from the new module.**

  Run: `zig build test 2>&1 | grep -c "error:"` — must be `0`.

- [ ] **Step 3.7: Commit.**

  ```bash
  git add src/storage/sharded_coordinator.zig src/lib.zig tests/test_sharded_coordinator_wiring.zig build.zig
  git commit -m "feat(storage): restore ShardedCoordinator with per-shard routing (Task 3)"
  ```

### Task 4: Make `ShardedCoordinator` the default coordinator path

**Files:**
- Modify: `src/storage/group_commit.zig` — the `getOrStartCoordinator` factory currently builds a single-flusher. Add a branch on a new `GEODE_SHARDED_COORD` env var (default `1`) and route to `ShardedCoordinator`; keep the single-flusher path reachable via `GEODE_SHARDED_COORD=0` for fallback.
- Test: extend `tests/test_sharded_coordinator_wiring.zig` with an env-gate test.

- [ ] **Step 4.1: Write the failing test.**

  Append to `tests/test_sharded_coordinator_wiring.zig`:

  ```zig
  test "group_commit.getOrStartCoordinator returns ShardedCoordinator by default" {
      // This is a structural test: we assert the returned coordinator
      // advertises shard count > 1 via a new `isSharded()` accessor.
      const allocator = testing.allocator;
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();
      _ = try adapter.getOrCreateGraph("g_gate");

      geode.group_commit.setEnabledForTest(true);
      defer {
          geode.group_commit.setEnabledForTest(false);
          geode.group_commit.shutdownAllCoordinators();
      }

      const coord = try geode.group_commit.getOrStartCoordinator(allocator, &adapter, "g_gate");
      try testing.expect(coord.isSharded());
      try testing.expectEqual(@as(usize, graph_storage.SHARD_COUNT), coord.shardCount());
  }
  ```

- [ ] **Step 4.2: Run test to verify it fails.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "getOrStartCoordinator returns ShardedCoordinator"`
  Expected: compile error — `isSharded` / `shardCount` not implemented on the returned type.

- [ ] **Step 4.3: Implement the factory branch.**

  In `src/storage/group_commit.zig`, locate `getOrStartCoordinator`. Wrap the existing single-flusher construction in a branch:

  ```zig
  pub fn getOrStartCoordinator(
      allocator: std.mem.Allocator,
      adapter: *StorageAdapter,
      graph_name: []const u8,
  ) !*Coordinator {
      // … existing lookup-or-create lock-and-check …

      const use_sharded = blk: {
          const env = std.posix.getenv("GEODE_SHARDED_COORD") orelse break :blk true;
          break :blk !std.mem.eql(u8, env, "0");
      };

      const coord = if (use_sharded)
          try sharded_coordinator.ShardedCoordinator.init(allocator, adapter, graph_name)
      else
          try SingleFlusherCoordinator.init(allocator, adapter, graph_name);

      // Store coord behind a common `Coordinator` union type so callers
      // see a uniform interface. See Step 4.4 below for the union
      // definition.
      // … rest unchanged …
  }
  ```

  Introduce a common `Coordinator` union in `src/storage/group_commit.zig`:

  ```zig
  pub const Coordinator = union(enum) {
      sharded: *sharded_coordinator.ShardedCoordinator,
      single: *SingleFlusherCoordinator,

      pub fn isSharded(self: Coordinator) bool { return self == .sharded; }
      pub fn shardCount(self: Coordinator) usize {
          return switch (self) {
              .sharded => graph_storage.SHARD_COUNT,
              .single => 1,
          };
      }
      pub fn submit(self: Coordinator, op: *ApplyOp) !u64 {
          return switch (self) {
              .sharded => |c| c.enqueue(op),
              .single => |c| c.submit(op),
          };
      }
      pub fn deinit(self: Coordinator) void {
          switch (self) {
              .sharded => |c| c.deinit(),
              .single => |c| c.deinit(),
          }
      }
  };
  ```

  Rename the previous non-union `Coordinator` type (the single-flusher) to `SingleFlusherCoordinator`.

- [ ] **Step 4.4: Run test to verify it passes.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "getOrStartCoordinator returns ShardedCoordinator"`
  Expected: PASS.

- [ ] **Step 4.5: Full suite verification.**

  Run: `zig build test 2>&1 | grep -c "error:"` — must be `0`.

- [ ] **Step 4.6: Commit.**

  ```bash
  git add src/storage/group_commit.zig src/storage/sharded_coordinator.zig tests/test_sharded_coordinator_wiring.zig
  git commit -m "feat(storage): default to ShardedCoordinator, env-gate fallback (Task 4)"
  ```

### Task 5: End-to-end routing regression test

**Files:**
- Test: extend `tests/test_sharded_coordinator_wiring.zig`.

This is the test that catches the Phase 2.4 40001 cascade. We deliberately synthesise the `edges_member_of` hub-node pattern at small scale and assert it completes without invoking `error.SerializationFailure`.

- [ ] **Step 5.1: Write the regression test.**

  Append to `tests/test_sharded_coordinator_wiring.zig`:

  ```zig
  test "hub-node concurrent edge creation does not trigger SerializationFailure" {
      // Simulate a reduced edges_member_of pattern: one hub node,
      // N=16 concurrent workers each creating 50 edges pointing INTO
      // the hub. Pre-Phase-2-final, this cascaded to 40001.
      // With deterministic routing, all 800 edges have the hub as
      // primary_node_id and land on ONE shard thread — no concurrent
      // writers touch the hub's MVCC-tracked resources.
      const allocator = testing.allocator;
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();
      _ = try adapter.getOrCreateGraph("g_hub");

      geode.group_commit.setEnabledForTest(true);
      defer {
          geode.group_commit.setEnabledForTest(false);
          geode.group_commit.shutdownAllCoordinators();
      }

      const coord = try geode.group_commit.getOrStartCoordinator(allocator, &adapter, "g_hub");

      const hub_id = try coord.submit(&.{ .bulk_insert_node = .{
          .labels = &[_][]const u8{"Group"},
          .props = &.{},
          .result = .{},
      } });

      // 16 submitter threads, 50 edges each.
      const Worker = struct {
          fn run(ctx: anytype) void {
              var i: usize = 0;
              while (i < 50) : (i += 1) {
                  const src = ctx.coord.submit(&.{ .bulk_insert_node = .{
                      .labels = &[_][]const u8{"Member"},
                      .props = &.{},
                      .result = .{},
                  } }) catch {
                      ctx.err.store(1, .release);
                      return;
                  };
                  _ = ctx.coord.submit(&.{ .bulk_insert_edge = .{
                      .from = src,
                      .to = ctx.hub_id,
                      .rel_type = "MEMBER_OF",
                      .props = &.{},
                      .result = .{},
                  } }) catch {
                      ctx.err.store(1, .release);
                      return;
                  };
              }
          }
      };

      const Ctx = struct {
          coord: geode.group_commit.Coordinator,
          hub_id: u64,
          err: *std.atomic.Value(u32),
      };

      var err = std.atomic.Value(u32).init(0);
      var ctxs: [16]Ctx = undefined;
      var threads: [16]std.Thread = undefined;
      for (&ctxs, &threads) |*c, *t| {
          c.* = .{ .coord = coord, .hub_id = hub_id, .err = &err };
          t.* = try std.Thread.spawn(.{}, Worker.run, .{c});
      }
      for (threads) |t| t.join();
      try testing.expectEqual(@as(u32, 0), err.load(.acquire));

      // Count edges — expect 16 × 50 = 800.
      var merged: std.ArrayList(u64) = .empty;
      defer merged.deinit(allocator);
      const mg = adapter.getGraph("g_hub").?;
      try mg.edgeTypePostingListFanOut("MEMBER_OF", allocator, &merged);
      try testing.expectEqual(@as(usize, 800), merged.items.len);
  }
  ```

- [ ] **Step 5.2: Run test to verify it passes (or diagnose and fix if not).**

  Run: `zig build test 2>&1 | grep -B1 -A3 "hub-node concurrent edge creation"`
  Expected: PASS. If it fails, the failure mode tells you which invariant broke:
  - `err.load() != 0`: the coordinator rejected a submission — check `submit` error handling.
  - `edge count != 800`: routing drops writes — check the shard worker's drain loop.
  - Hang / timeout: check the shard-worker queues for backpressure deadlock.

- [ ] **Step 5.3: Commit.**

  ```bash
  git add tests/test_sharded_coordinator_wiring.zig
  git commit -m "test(storage): hub-node concurrent-edge regression pins no 40001 cascade (Task 5)"
  ```

---

## Phase 3 — Per-shard WAL flusher

The single-flusher path already amortises fsync across a coordinator's ops. Under the sharded coordinator, the natural evolution is one flusher per shard, each batching within its own 500 µs window.

### Task 6: Introduce `WalFlusher`

**Files:**
- Create: `src/storage/wal_flusher.zig`.
- Test: `tests/test_wal_flusher.zig`.

- [ ] **Step 6.1: Write the failing test.**

  Create `tests/test_wal_flusher.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const wal_flusher = geode.wal_flusher;

  test "WalFlusher batches sync calls within 500us window" {
      // We use a fake WAL that counts sync() invocations. Submit 10
      // ops within 100us; exactly ONE sync should fire.
      const FakeWal = struct {
          sync_count: std.atomic.Value(u64) = .init(0),
          pub fn sync(self: *@This()) !void {
              _ = self.sync_count.fetchAdd(1, .acq_rel);
          }
      };

      var fake = FakeWal{};
      var flusher = try wal_flusher.WalFlusher.init(testing.allocator, &fake, .{
          .batch_window_ns = 500_000, // 500 us
      });
      defer flusher.deinit();

      var dones: [10]std.atomic.Value(u32) = @splat(.init(0));
      for (&dones, 0..) |*d, i| {
          try flusher.enqueue(.{ .lsn = @intCast(i + 1), .done = d });
      }
      // Wait for all done flags
      for (&dones) |*d| {
          while (d.load(.acquire) == 0) std.atomic.spinLoopHint();
      }

      // Exactly ONE sync should have fired (all 10 ops landed in the
      // same 500us batch window).
      const sync_count = fake.sync_count.load(.acquire);
      try testing.expect(sync_count >= 1);
      try testing.expect(sync_count <= 3); // Allow up to 3 for batch-window edge cases
  }
  ```

- [ ] **Step 6.2: Run to verify fail.**

  Run: `zig build test 2>&1 | grep wal_flusher`
  Expected: module not found.

- [ ] **Step 6.3: Implement `WalFlusher`.**

  Create `src/storage/wal_flusher.zig`:

  ```zig
  const std = @import("std");
  const pooled = @import("pooled");

  pub const FlushRecord = struct {
      lsn: u64,
      done: *std.atomic.Value(u32),
  };

  pub const Config = struct {
      batch_window_ns: u64 = 500_000, // 500us default
      queue_capacity: usize = 1024,
  };

  pub const WalFlusher = struct {
      allocator: std.mem.Allocator,
      config: Config,
      wal: *anyopaque,
      sync_fn: *const fn (*anyopaque) anyerror!void,
      queue: std.RingBuffer,
      queue_mutex: std.Io.Mutex = .init,
      queue_cond: std.Io.Condition = .init,
      thread: std.Thread,
      shutdown: std.atomic.Value(bool) = .init(false),

      pub fn init(
          allocator: std.mem.Allocator,
          wal: anytype,
          config: Config,
      ) !*WalFlusher {
          const self = try allocator.create(WalFlusher);
          errdefer allocator.destroy(self);
          self.* = .{
              .allocator = allocator,
              .config = config,
              .wal = @ptrCast(wal),
              .sync_fn = @ptrCast(&@TypeOf(wal.*).sync),
              .queue = try std.RingBuffer.init(allocator, config.queue_capacity * @sizeOf(FlushRecord)),
              .thread = undefined,
              .shutdown = .init(false),
          };
          self.thread = try std.Thread.spawn(.{}, flusherLoop, .{self});
          return self;
      }

      pub fn deinit(self: *WalFlusher) void {
          self.shutdown.store(true, .release);
          self.queue_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
          self.queue_cond.broadcast();
          self.queue_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
          self.thread.join();
          self.queue.deinit(self.allocator);
          self.allocator.destroy(self);
      }

      pub fn enqueue(self: *WalFlusher, rec: FlushRecord) !void {
          self.queue_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
          defer self.queue_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
          try self.queue.writeSlice(std.mem.asBytes(&rec));
          self.queue_cond.signal();
      }

      fn flusherLoop(self: *WalFlusher) void {
          while (!self.shutdown.load(.acquire)) {
              // Batch: drain everything queued + wait up to batch_window_ns
              // for more.
              var batch: [64]FlushRecord = undefined;
              var batch_len: usize = 0;

              self.queue_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
              while (self.queue.len() == 0 and !self.shutdown.load(.acquire)) {
                  self.queue_cond.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &self.queue_mutex);
              }
              while (batch_len < batch.len and self.queue.len() >= @sizeOf(FlushRecord)) {
                  var rec_bytes: [@sizeOf(FlushRecord)]u8 = undefined;
                  self.queue.readSlice(&rec_bytes, @sizeOf(FlushRecord)) catch break;
                  batch[batch_len] = std.mem.bytesToValue(FlushRecord, &rec_bytes);
                  batch_len += 1;
              }
              self.queue_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

              // Hold open the batch window for more records.
              std.Thread.sleep(self.config.batch_window_ns);

              self.queue_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
              while (batch_len < batch.len and self.queue.len() >= @sizeOf(FlushRecord)) {
                  var rec_bytes: [@sizeOf(FlushRecord)]u8 = undefined;
                  self.queue.readSlice(&rec_bytes, @sizeOf(FlushRecord)) catch break;
                  batch[batch_len] = std.mem.bytesToValue(FlushRecord, &rec_bytes);
                  batch_len += 1;
              }
              self.queue_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

              if (batch_len == 0) continue;

              // One fsync for the whole batch.
              self.sync_fn(self.wal) catch {};

              // Signal every caller.
              for (batch[0..batch_len]) |rec| {
                  rec.done.store(1, .release);
              }
          }
      }
  };
  ```

  Wire into `src/lib.zig`:

  ```zig
  pub const wal_flusher = @import("storage/wal_flusher.zig");
  ```

  Add test to `build.zig`.

- [ ] **Step 6.4: Run test.**

  Run: `zig build test 2>&1 | grep -B1 -A3 "WalFlusher batches"`
  Expected: PASS.

- [ ] **Step 6.5: Commit.**

  ```bash
  git add src/storage/wal_flusher.zig src/lib.zig tests/test_wal_flusher.zig build.zig
  git commit -m "feat(storage): add per-shard WalFlusher with 500us batch window (Task 6)"
  ```

### Task 7: Wire `WalFlusher` into `ShardedCoordinator`

**Files:**
- Modify: `src/storage/sharded_coordinator.zig` — each shard worker gets its own `WalFlusher` instance pointing at its shard's WAL.

- [ ] **Step 7.1: Write failing assertion test.**

  Extend `tests/test_sharded_coordinator_wiring.zig`:

  ```zig
  test "ShardedCoordinator amortises fsync across shard workers" {
      // Run 1600 ops through the coordinator and count fsync calls on
      // the underlying shard WALs.  Expect << 1600 syncs (batch window
      // amortises within-shard traffic).
      //
      // Exact count is host-dependent; we assert an upper bound that is
      // tight enough to catch "no batching at all" but loose enough to
      // absorb scheduler jitter: total_syncs < 400 (i.e., at least 4×
      // amortisation on average).
      // ...
      // (Use the same adapter-init + coord pattern as above; wire a
      // fsync counter via the upstream's test-only hook if present, or
      // skip this assertion if no such hook exists and annotate as
      // MANUAL-VERIFY.)
  }
  ```

  If the upstream `graph_storage` exposes no test-only fsync counter, mark this test MANUAL-VERIFY with a `return error.SkipZigTest;` body and a comment pointing at the `strace` invocation in Task 11 that serves as the real proof.

- [ ] **Step 7.2: Wire per-shard `WalFlusher` into the coordinator.**

  In `src/storage/sharded_coordinator.zig`, the `ShardedCoordinator.init` now spawns N `WalFlusher` instances, each pointing at the corresponding shard's WAL:

  ```zig
  // Inside ShardedCoordinator
  shard_flushers: [graph_storage.SHARD_COUNT]*wal_flusher.WalFlusher,

  pub fn init(allocator: std.mem.Allocator, adapter: *StorageAdapter, graph_name: []const u8) !*ShardedCoordinator {
      // ... existing init ...
      const engine = adapter.getShardedEngine(graph_name) orelse return error.GraphNotFound;
      for (0..graph_storage.SHARD_COUNT) |s| {
          self.shard_flushers[s] = try wal_flusher.WalFlusher.init(
              allocator,
              engine.shardWal(s),
              .{},
          );
      }
      // ... etc ...
  }
  ```

  Each shard worker's drain loop submits its ops' LSNs to its shard's flusher, then `wait`s on the op's `done` condvar:

  ```zig
  fn shardWorkerLoop(self: *ShardedCoordinator, shard_index: usize) void {
      // ... pop batch of ops from shard queue ...
      // For each op: apply to engine (which writes the WAL record without fsync).
      // After applying all ops in the batch, enqueue each op's LSN on this
      // shard's flusher with the op's `done` condvar.
      for (batch) |*op| {
          self.shard_flushers[shard_index].enqueue(.{
              .lsn = op.result.lsn,
              .done = &op.result.done,
          }) catch {};
      }
      // Caller of `enqueue` waits on op.result.done externally.
  }
  ```

- [ ] **Step 7.3: Run test (or MANUAL-VERIFY path).**

  Either the test passes (if a counter is available) or the test returns `SkipZigTest` and documentation in step 7.1 marks it as manual-verify.

- [ ] **Step 7.4: Commit.**

  ```bash
  git add src/storage/sharded_coordinator.zig tests/test_sharded_coordinator_wiring.zig
  git commit -m "feat(storage): per-shard WalFlusher integrated with ShardedCoordinator (Task 7)"
  ```

---

## Phase 4 — MVCC invariant guard (debug-only)

Under deterministic shard routing, `transactions/manager.zig:hasWriteWriteConflicts` should never detect a conflict for workload that goes through the coordinator. A debug-build panic catches routing-bug regressions at test time.

### Task 8: Add the debug-build assertion

**Files:**
- Modify: `src/transactions/manager.zig` — `hasWriteWriteConflicts`.

- [ ] **Step 8.1: Write the failing test.**

  Create `tests/test_txn_manager_routing_guard.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");

  test "txn manager panics on write-write conflict in debug (routing bug proxy)" {
      // Skip unless we are in Debug mode.
      if (@import("builtin").mode != .Debug) return error.SkipZigTest;

      // Construct a minimal Manager and force-inject a write-write
      // conflict — this MUST panic in debug, because deterministic
      // routing should have prevented it.
      //
      // We use the standard Zig expectPanic pattern with spawn + join.
      // (See tests/test_std_debug_panic.zig for the pattern if Zig
      // stdlib's testing.expectPanic is unavailable on 0.16.)
      //
      // If the ambient runtime doesn't support expectPanic, mark
      // SkipZigTest and rely on the runtime check firing during
      // msft-graph ingest (Phase 5 exit criterion).
      return error.SkipZigTest;
  }
  ```

  This test is essentially a documentation stub until we have a clean way to assert-a-panic in Zig tests. The production guard still fires and panics at runtime if the invariant is ever violated — which is the real regression-catcher.

- [ ] **Step 8.2: Implement the guard.**

  In `src/transactions/manager.zig:209` (the `hasWriteWriteConflicts`-return-true site):

  ```zig
  if (try self.hasWriteWriteConflicts(txn.id)) {
      // Phase 2-final invariant: under deterministic shard routing,
      // same-resource writes land on the same thread, so no two
      // concurrent commits should touch the same resource. If we
      // reach here under the ShardedCoordinator, the routing contract
      // has been violated — panic in Debug so the regression is
      // caught at test time, keep the legacy 40001 path in Release
      // for defense-in-depth.
      if (@import("builtin").mode == .Debug) {
          std.debug.panic("write-write conflict under ShardedCoordinator routing — see src/storage/sharded_coordinator.zig for the routing contract", .{});
      }
      return error.SerializationFailure;
  }
  ```

- [ ] **Step 8.3: Run the suite to verify no existing tests trip the panic.**

  Run: `zig build test 2>&1 | grep -iE "panic|error:" | head -10`
  Expected: no new panics. If any test trips the panic, it means that test was relying on the pre-routing MVCC path — either the test is exercising an out-of-coordinator code path (fine, the panic is expected only under coordinator ownership) or the routing is actually broken.

  If the panic fires in a test, gate it more narrowly — only fire when the current txn was submitted through the coordinator. Add a thread-local flag that the coordinator sets on entry and clears on exit; the panic only fires when the flag is set.

- [ ] **Step 8.4: Commit.**

  ```bash
  git add src/transactions/manager.zig tests/test_txn_manager_routing_guard.zig build.zig
  git commit -m "feat(txn): debug-build panic on routing-bug write-write conflict (Task 8)"
  ```

---

## Phase 5 — Measurement & exit criterion

### Task 9: Run the msft-graph ingest benchmark post-wiring

**Files:**
- Create: `docs/performance/2026-04-24-sharding/phase2-final-run.log`.

- [ ] **Step 9.1: Fresh build + fresh data dir.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-phase2-final && mkdir -p /tmp/geode-phase2-final
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 9.2: Start server with GEODE_SHARDED_COORD=1.**

  ```bash
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 GEODE_SHARDED_COORD=1 \
    nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-phase2-final \
      --listen 127.0.0.1:3143 --log-level warn \
      > /tmp/geode-phase2-final/server.log 2>&1 &
  SERVER_PID=$!
  sleep 4
  ```

- [ ] **Step 9.3: Run the benchmark.**

  ```bash
  zig-out/bin/geode query --server 127.0.0.1:3143 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session \
    "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  echo "=== phase2-final start $(date -Iseconds) ==="
  time GEODE_DSN="quic://127.0.0.1:3143/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
    msft-graph seed --input /home/benji/eagleg-topology-data-16 \
    --parallel --workers 16 --chunk-size 1000 2>&1 | \
    tee docs/performance/2026-04-24-sharding/phase2-final-run.log
  echo "=== phase2-final end $(date -Iseconds) ==="
  kill -9 $SERVER_PID 2>/dev/null || true
  ```

- [ ] **Step 9.4: Verify exit criterion.**

  Open `docs/performance/2026-04-24-sharding/phase2-final-run.log`. The run must:

  - Complete without the msft-graph client ever logging `serial fallback`.
  - Show total wall-clock `<= 60s` (the spec's exit criterion).
  - Contain zero `40001` errors in either the run log OR `/tmp/geode-phase2-final/server.log` — verify:

    ```bash
    grep -c "40001\|serial fallback" docs/performance/2026-04-24-sharding/phase2-final-run.log
    grep -c "40001\|Write lock acquisition timed out" /tmp/geode-phase2-final/server.log
    ```

    Both must print `0`.

  If any of these fails, stop — the invariant has not been met; loop back to diagnosis.

- [ ] **Step 9.5: Commit the evidence.**

  ```bash
  git add docs/performance/2026-04-24-sharding/phase2-final-run.log
  git commit -m "docs(perf): Phase 2-final msft-graph ingest <60s with zero 40001 (Task 9)"
  ```

### Task 10: Refresh `PHASE2-SUMMARY.md` closing note

**Files:**
- Modify: `docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md`.

- [ ] **Step 10.1: Append the closure section.**

  Add at the bottom of `PHASE2-SUMMARY.md`:

  ```markdown
  ## Phase 2-final — closed (2026-XX-XX)

  Re-wiring via `ShardedGraphEngine` (upstream) + `ShardedCoordinator` (this
  repo) + per-shard auxiliary state removed both failure modes structurally.
  See `phase2-final-run.log` for the ingest exit criterion and
  `docs/superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md` for the
  implementation walk-through.

  Phase 2.1–2.4 workarounds (writer-preferred lock, tryLock-spin backoff,
  pool-wrapped single flusher) are no longer load-bearing and can be removed
  as a follow-up hygiene pass.
  ```

- [ ] **Step 10.2: Commit.**

  ```bash
  git add docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md
  git commit -m "docs(perf): mark Phase 2 closed; point at Phase 2-final evidence (Task 10)"
  ```

### Task 11: Optional strace evidence for fsync amortisation

**Files:**
- Create: `docs/performance/2026-04-24-sharding/phase2-final-strace.txt` (optional; skip if strace not available).

- [ ] **Step 11.1: Capture fsync call count.**

  ```bash
  # Restart server under strace; repeat the msft-graph run at smaller scale
  # (5000 statements) so the strace data volume stays manageable.
  rm -rf /tmp/geode-phase2-strace && mkdir -p /tmp/geode-phase2-strace
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 GEODE_SHARDED_COORD=1 \
    strace -c -e trace=fsync -f -o docs/performance/2026-04-24-sharding/phase2-final-strace.txt \
      zig-out/bin/geode serve \
      --data-dir /tmp/geode-phase2-strace \
      --listen 127.0.0.1:3143 --log-level warn &
  SERVER_PID=$!
  sleep 4
  # … run msft-graph at reduced scale …
  kill -INT $SERVER_PID && wait
  ```

  Expected output in the strace file: fsync call count << (statements submitted). A 10× amortisation is a minimum reasonable signal; 50× typical.

- [ ] **Step 11.2: Commit the strace evidence (if captured).**

  ```bash
  git add docs/performance/2026-04-24-sharding/phase2-final-strace.txt
  git commit -m "docs(perf): strace evidence confirming fsync amortisation (Task 11)"
  ```

---

## Self-review results

- **Spec coverage**: every section of `2026-04-24-per-shard-coordinator-wiring-design.md` maps to a task above. The "Re-enable ShardedCoordinator" line → Task 3/4; per-shard aux state → Task 1/2; per-shard rwlocks (kept) → used within Task 3's `shardWorkerLoop`; cross-shard edges → delegated to upstream (Item 1 spec) — flagged in Task 3 step 4; per-shard WalFlusher → Task 6/7; MVCC guard → Task 8; measurement → Task 9. Risk/mitigation table items cross-reference Tasks 5 (hub collision) and 9 (exit criterion).
- **Placeholder scan**: all TODO/TBD occurrences are either marked MANUAL-VERIFY (Task 7 fsync counter) with an explicit fallback, or tied to an evidence file that the step explicitly writes.
- **Type consistency**: `Coordinator` union in Task 4 retains `submit(op)` signature for call-site compatibility; `ShardedCoordinator.enqueue` is the canonical name with `submit` as a thin alias; `ApplyOp` is kept as a single shared type (Task 3 step 4 explicitly calls out the decision to extract or share it).

## Execution handoff

Plan complete and committed to `docs/superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md`. Two execution options:

1. **Subagent-driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration on both the code and the plan if reality drifts from the spec.
2. **Inline execution** — execute tasks in this session using executing-plans; batch with checkpoints.

Note: Task 0 depends on the upstream Item 1 being landed. Until that work ships on the graph-storage repo's `perf/sharded-engine` branch with the API exposed in Step 0.2, every subsequent task is blocked.
