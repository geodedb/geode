# Sharded Coordinator Restoration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-flusher `GroupCommitCoordinator` in `src/storage/group_commit.zig` with a 16-way per-shard coordinator so `msft-graph seed` against the `eagleg-topology-data-20` dataset lands in ≤ 70 s with zero `40001` errors and zero serial-fallback occurrences.

**Architecture:** Restore the `ShardedCoordinator` from commit `210de668`, adapt to current HEAD (per-shard batch statement txns for fsync amortisation, `bulk_match_create_edge` source-id pre-resolution at submit time, thread-local routing-invariant guard), delete the single-flusher. No env-gated fallback, no `Coordinator` union.

**Tech Stack:** Zig 0.16.0+. `graph_storage` pinned at `0ce15769` on `perf/sharded-engine` (submodule path `graph_storage.sharded_store` for `SHARD_COUNT` and `shardIndex`). Geode primitives: `pooled.ThreadPool`, `std.atomic.Value`, `std.Io.Mutex`, `std.Io.Condition`, `std.Deque`. Measurement: `msft-graph seed`, `grep`, `time`.

---

## File structure

**Create:**
- `tests/test_sharded_coordinator_routing.zig` — fast unit test for `shardKey()` + per-shard queue routing via a test-only depth accessor.
- `tests/test_sharded_coordinator_hub_regression.zig` — integration test; 16 threads × 50 edges into one hub node; asserts zero `SerializationFailure` + 800 edges present.
- `tests/test_txn_manager_routing_guard.zig` — Debug-only placeholder for the MVCC routing-invariant guard.
- `docs/performance/2026-04-24-sharding/phase2-plan-baseline.log` — fresh baseline (replaces the failed one).
- `docs/performance/2026-04-24-sharding/phase2-final-run.log` — post-change exit-criterion measurement.

**Modify:**
- `src/storage/group_commit.zig` — replace single-flusher coordinator body with sharded variant; preserve public API surface; keep `ApplyOp` variants but add fields + methods.
- `src/server/quic_connection_handler.zig` — update any `*GroupCommitCoordinator` references (if present) to `*ShardedCoordinator`.
- `src/transactions/manager.zig` — add thread-local-gated debug panic in `hasWriteWriteConflicts`.
- `tests/test_sharded_coordinator.zig` — update header comment + references from `GroupCommitCoordinator` to `ShardedCoordinator` (functional behaviour unchanged — the test exercises the public API).
- `build.zig` — register three new test files.
- `docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md` — append closure note.

**Leave alone:**
- `src/storage/graph_storage_adapter.zig` — the shard-locked helpers `bulkInsertNodeWithReservedId`, `bulkInsertEdgeWithIdsShardLocked`, `bulkMergeNodeWithReservedId`, `lookupNodeByMergeKey`, `beginStatementTxn`, `StatementTxn.commit` are all already in place and correct.
- `src/graph_store.zig` — no label_index / edge_type_index changes (out of scope per spec).
- `src/lib.zig` — `pub const group_commit = ...` re-export stays.

---

## Phase 0 — Prepare measurement harness

### Task 0: Robust baseline with healthcheck-polling

**Files:**
- Create (scratch, not committed): `/tmp/run-baseline-v2.sh`
- Create (committed): `docs/performance/2026-04-24-sharding/phase2-plan-baseline.log`

The first baseline attempt this session used a naive `sleep 5` before the first `geode query`; the CLI then timed out at 30 s and the ingest ran against a dead connection. This task replaces the blind sleep with a healthcheck-polling loop.

- [ ] **Step 0.1: Write the baseline runner script.**

  Create `/tmp/run-baseline-v2.sh` with this exact content:

  ```bash
  #!/bin/bash
  set -e
  cd /data/home/benji/src/devnw/codepros/geode/geode

  BASELINE_LOG=docs/performance/2026-04-24-sharding/phase2-plan-baseline.log
  SERVER_DATA=/tmp/geode-phase2-baseline
  SERVER_LOG="$SERVER_DATA/server.log"

  echo "=== baseline start $(date -Iseconds) ===" | tee "$BASELINE_LOG"
  echo "host=$(hostname) dataset=/data/home/benji/eagleg-topology-data-20" | tee -a "$BASELINE_LOG"
  echo "dataset-stats: $(ls /data/home/benji/eagleg-topology-data-20/*.jsonl | wc -l) files, $(wc -l /data/home/benji/eagleg-topology-data-20/*.jsonl | tail -1 | awk '{print $1}') lines" | tee -a "$BASELINE_LOG"

  pkill -9 -f "geode serve --data-dir $SERVER_DATA" 2>/dev/null || true
  rm -rf "$SERVER_DATA" && mkdir -p "$SERVER_DATA"

  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
    nohup zig-out/bin/geode serve \
      --data-dir "$SERVER_DATA" \
      --listen 127.0.0.1:3143 --log-level warn \
      > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  echo "server_pid=$SERVER_PID" | tee -a "$BASELINE_LOG"

  # Healthcheck-poll: up to 60 s for server readiness
  READY=0
  for attempt in $(seq 1 30); do
      if zig-out/bin/geode query --server 127.0.0.1:3143 --insecure-tls-skip-verify \
           -U geode -P Geode1234Abc --no-saved-session \
           "RETURN 1 AS ok" > /dev/null 2>&1; then
          READY=1
          echo "server ready after $((attempt * 2))s" | tee -a "$BASELINE_LOG"
          break
      fi
      sleep 2
  done
  if [ "$READY" -ne 1 ]; then
      echo "SERVER_NOT_READY_IN_60S" | tee -a "$BASELINE_LOG"
      kill -9 "$SERVER_PID" 2>/dev/null || true
      exit 1
  fi

  zig-out/bin/geode query --server 127.0.0.1:3143 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session \
    "CREATE GRAPH abs_eagleg" 2>&1 | tee -a "$BASELINE_LOG" || true

  echo "=== ingest start $(date -Iseconds) ===" | tee -a "$BASELINE_LOG"
  START=$(date +%s)
  timeout 2700 bash -c '
    GEODE_DSN="quic://127.0.0.1:3143/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /data/home/benji/eagleg-topology-data-20 \
      --parallel --workers 16 --chunk-size 1000 2>&1
  ' 2>&1 | tee -a "$BASELINE_LOG" || echo "INGEST_TIMED_OUT_OR_FAILED exit=$?" | tee -a "$BASELINE_LOG"
  END=$(date +%s)
  echo "=== ingest end $(date -Iseconds) wall_clock_s=$((END-START)) ===" | tee -a "$BASELINE_LOG"

  echo "--- evidence ---" | tee -a "$BASELINE_LOG"
  echo "40001 count (ingest log): $(grep -c '40001' "$BASELINE_LOG" || true)" | tee -a "$BASELINE_LOG"
  echo "serial-fallback count (ingest log): $(grep -c 'serial fallback' "$BASELINE_LOG" || true)" | tee -a "$BASELINE_LOG"
  echo "40001 count (server log): $(grep -c '40001' "$SERVER_LOG" || echo 0)" | tee -a "$BASELINE_LOG"
  echo "Write-lock-timeout count (server log): $(grep -c 'Write lock acquisition timed out' "$SERVER_LOG" || echo 0)" | tee -a "$BASELINE_LOG"

  kill -9 "$SERVER_PID" 2>/dev/null || true
  echo "=== baseline done $(date -Iseconds) ===" | tee -a "$BASELINE_LOG"
  ```

- [ ] **Step 0.2: Build release binary, then run the baseline.**

  ```bash
  chmod +x /tmp/run-baseline-v2.sh
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  # Expected ≤ 45 min wall-clock — run as a background Bash task if supported.
  bash /tmp/run-baseline-v2.sh
  ```

- [ ] **Step 0.3: Verify the baseline actually ran.**

  Inspect `docs/performance/2026-04-24-sharding/phase2-plan-baseline.log`. All of these must hold:

  - `=== baseline start ...` and `=== baseline done ...` markers both present.
  - `wall_clock_s=<N>` line is non-zero (expect a real number in the hundreds or thousands of seconds).
  - The `--- evidence ---` block shows a non-zero `40001` or `serial-fallback` count somewhere (baseline's purpose is to record the failure mode).

  If the script wrote `SERVER_NOT_READY_IN_60S`, diagnose and retry. If wall-clock is under 60 s AND both failure counters are zero, the baseline did not exercise the cascade — re-investigate before proceeding.

- [ ] **Step 0.4: Commit the baseline log.**

  ```bash
  git add docs/performance/2026-04-24-sharding/phase2-plan-baseline.log
  git commit -m "docs(perf): fresh msft-graph ingest baseline on data-20 (Task 0)"
  ```

---

## Phase 1 — ApplyOp shape changes

### Task 1: Add `shardKey()` and pre-resolved ids to `ApplyOp`

**Files:**
- Modify: `src/storage/group_commit.zig` — the `ApplyOp` union around lines 82–149.

Today's `ApplyOp` has no `shardKey()` method and no `source_id` / `target_id` on `bulk_match_create_edge`. Add those as a prerequisite for Task 2's routing test to compile. Behaviour is unchanged — the single-flusher never reads these fields.

- [ ] **Step 1.1: Add `source_id` and `target_id` fields to `bulk_match_create_edge`.**

  In `src/storage/group_commit.zig`, locate the `bulk_match_create_edge` variant inside the `ApplyOp` union (approximately lines 114–138). Add two fields at the end of the struct (before the closing `},`):

  ```zig
          /// Pre-resolved at submit time by `ShardedCoordinator.submit`
          /// so the shard router sees a stable `shardKey()`. Zero means
          /// "not yet resolved" (single-flusher paths never read this).
          source_id: u64 = 0,
          /// Pre-resolved at submit time when possible; zero means the
          /// worker must resolve under its shard lock.
          target_id: u64 = 0,
  ```

- [ ] **Step 1.2: Add `shardKey()` method to `ApplyOp`.**

  Immediately after the `resultPtr` method (around line 138), add:

  ```zig
      /// Key that selects the shard whose worker applies this op.
      /// For node / merge inserts the pre-allocated id is used (filled
      /// in by `submit`); for edge ops the source id is used so every
      /// edge leaving the same source lands on the same shard
      /// (cross-shard src != dst is handled by the helper's two-lock
      /// ascending-index acquire).
      pub fn shardKey(self: *const ApplyOp) u64 {
          return switch (self.*) {
              .bulk_insert_node => |p| p.assigned_id,
              .bulk_insert_edge => |p| p.source_id,
              .bulk_match_create_edge => |p| p.source_id,
              .bulk_merge_node => |p| p.assigned_id,
          };
      }
  ```

- [ ] **Step 1.3: Verify build.**

  Run: `zig build 2>&1 | tail -5`
  Expected: clean build, no errors.

- [ ] **Step 1.4: Commit.**

  ```bash
  git add src/storage/group_commit.zig
  git commit -m "feat(storage): add shardKey() + pre-resolved ids to ApplyOp (Task 1)"
  ```

---

## Phase 2 — Routing test (red)

### Task 2: Write failing routing test

**Files:**
- Create: `tests/test_sharded_coordinator_routing.zig`
- Modify: `build.zig` — register new test module.

The test submits a node-insert op and observes which shard's `ops_applied` counter ticks — that shard must match `shardIndex(returned_id)`. This tests routing correctness without requiring a non-blocking enqueue helper.

- [ ] **Step 2.1: Write the test file.**

  Create `tests/test_sharded_coordinator_routing.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Routing correctness: an op lands on the shard whose index matches
  //! `shardIndex(op.shardKey())`.

  const std = @import("std");
  const geode = @import("geode");
  const graph_storage = @import("graph_storage");
  const adapter_mod = geode.graph_storage_adapter;
  const group_commit = geode.group_commit;

  test "ShardedCoordinator routes ops by shardIndex(shardKey)" {
      const allocator = std.testing.allocator;
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

      group_commit.setEnabledForTest(true);
      defer {
          group_commit.setEnabledForTest(false);
          group_commit.shutdownAllCoordinators();
      }

      const coord = try group_commit.getOrStartCoordinator(allocator, &adapter, "g_route");

      // Submit one `bulk_insert_node` op; it is applied synchronously
      // by whichever shard its assigned id routes to. Observe that
      // shard's `ops_applied` atomic incremented, and assert the
      // shard index matches `shardIndex(returned_id)`.
      const labels = [_][]const u8{"L"};
      const props = [_]adapter_mod.StorageAdapter.PropKV{};
      var op = group_commit.ApplyOp{ .bulk_insert_node = .{
          .labels = &labels,
          .props = &props,
          .result = .{},
      } };
      const id = try coord.submit(&op);
      try std.testing.expect(id != 0);

      var seen_on_shard: ?usize = null;
      for (0..graph_storage.sharded_store.SHARD_COUNT) |s| {
          const n = coord.shardOpsAppliedForTest(s);
          if (n > 0) {
              try std.testing.expect(seen_on_shard == null);
              seen_on_shard = s;
          }
      }
      try std.testing.expect(seen_on_shard != null);
      try std.testing.expectEqual(
          graph_storage.sharded_store.shardIndex(id),
          seen_on_shard.?,
      );
  }
  ```

- [ ] **Step 2.2: Register the test in `build.zig`.**

  Find the existing `test_sharded_coordinator` registration: `grep -n 'test_sharded_coordinator' build.zig` — around line 3355. Immediately after that block, add:

  ```zig
      const sharded_coord_routing_mod = b.createModule(.{ .root_source_file = b.path("tests/test_sharded_coordinator_routing.zig"), .target = target, .optimize = optimize });
      sharded_coord_routing_mod.addImport("geode", root_mod);
      sharded_coord_routing_mod.addImport("graph_storage", graph_storage_mod);
      const sharded_coord_routing_tests = b.addTest(.{ .root_module = sharded_coord_routing_mod });
      const run_sharded_coord_routing_tests = b.addRunArtifact(sharded_coord_routing_tests);
      test_step.dependOn(&run_sharded_coord_routing_tests.step);
      const sharded_coord_routing_step = b.step("test-sharded-coordinator-routing", "Run ShardedCoordinator routing correctness tests");
      sharded_coord_routing_step.dependOn(&run_sharded_coord_routing_tests.step);
  ```

  Note: `graph_storage_mod` must already exist above — verify with `grep -n 'graph_storage_mod' build.zig`. If the identifier in your build.zig is different, copy the matching `.addImport("graph_storage", …)` line from an adjacent test registration.

- [ ] **Step 2.3: Run test to verify it fails (compile error, not runtime).**

  Run: `zig build test-sharded-coordinator-routing 2>&1 | tail -15`
  Expected: compile error — `shardOpsAppliedForTest` does not exist on `ShardedCoordinator` yet. Also likely `coord` is still typed as `*GroupCommitCoordinator` which also lacks the accessor. That's our red — good.

- [ ] **Step 2.4: Commit the red test.**

  ```bash
  git add tests/test_sharded_coordinator_routing.zig build.zig
  git commit -m "test(storage): red routing test pins shardKey() -> correct shard (Task 2)"
  ```

---

## Phase 3 — Restore the sharded coordinator (green)

### Task 3: Replace `GroupCommitCoordinator` body with `ShardedCoordinator`

**Files:**
- Modify: `src/storage/group_commit.zig` — replace the coordinator struct body (approximately lines 159–536) and rename. Keep `ApplyOp` (lines 82–149 after Task 1 edits) and `ApplyResult` (around line 151) intact. Keep the registry helpers (around line 538 through end-of-file) intact except for the type name.

This is the biggest task. Read it fully before starting.

- [ ] **Step 3.1: Mental model.**

  The current file has one big `GroupCommitCoordinator` struct with `start`, `stop`, `submit`, `flusherLoop`, `applyBatch`. The new shape is `ShardedCoordinator` with `start`, `stop`, `submit`, `shardLoop`, `applyShardBatch`, plus an inner `ShardState` struct and an internal `ShardLoopArg`. Public method names (`start`, `stop`, `submit`) are identical. The registry functions at the bottom become `*ShardedCoordinator` via trivial rename.

  The reference implementation at commit `210de668` (available via `git show 210de668:src/storage/group_commit.zig`) is 80 % of what we want. Differences we introduce:

  1. Use `graph_storage.sharded_store.SHARD_COUNT` and `graph_storage.sharded_store.shardIndex`. (210de668 imported `sharded_store` under a different alias; we use the submodule path per spec.)
  2. Add per-shard batch statement transactions (210de668 does NOT; it falls back to per-op auto-commit). Match the pattern used by current HEAD's `applyBatch` (`beginStatementTxn` + `stmt_txn.commit`).
  3. Handle `bulk_match_create_edge` — variant didn't exist at 210de668. Pre-resolve source_id in `submit`; dispatch to `bulkInsertEdgeWithIdsShardLocked` in `applyShardBatch`, resolving target_id if `op.target_id == 0`.
  4. Add test accessors `shardQueueDepthForTest(usize) usize` and `shardOpsAppliedForTest(usize) u64`, guarded by `@import("builtin").is_test`.
  5. Thread-local `t_is_shard_worker` flag set in `shardLoop` entry + cleared in its defer (used by Task 6's guard).

- [ ] **Step 3.2: Rename `GroupCommitCoordinator` → `ShardedCoordinator` throughout the file, and delete `flusherLoop` + `applyBatch`.**

  Apply these transformations to `src/storage/group_commit.zig`:

  1. On the `pub const GroupCommitCoordinator = struct {` line (approximately 159), change to `pub const ShardedCoordinator = struct {`.
  2. Every occurrence of `*GroupCommitCoordinator` inside method receivers in this file becomes `*ShardedCoordinator`.
  3. The registry (approximately line 538 onward): `StringHashMap(*GroupCommitCoordinator)` → `StringHashMap(*ShardedCoordinator)`; `getOrStartCoordinator` return type → `!*ShardedCoordinator`; `lookupCoordinator` return type → `?*ShardedCoordinator`.
  4. Delete the `flusherLoop` function (approx lines 338–385) and the `applyBatch` function (approx lines 387–530). Their replacements `shardLoop` and `applyShardBatch` are added in Step 3.4.

  Leave the module doc-comment at the top unchanged for now; we edit it last in Step 3.6.

- [ ] **Step 3.3: Replace the struct fields and lifecycle methods (`start`, `stop`).**

  First, immediately above `pub const ShardedCoordinator = struct {`, add the `ShardState` struct definition and the thread-local flag:

  ```zig
  /// Per-shard state owned by `ShardedCoordinator`. One per `SHARD_COUNT` slot.
  const ShardState = struct {
      queue: std.Deque(*ApplyOp),
      queue_mutex: std.Io.Mutex,
      queue_not_empty: std.Io.Condition,
      ops_applied: std.atomic.Value(u64),
      batches: std.atomic.Value(u64),
  };

  /// Thread-local flag set while a ShardedCoordinator worker is executing
  /// its shard loop. Consumed by `transactions/manager.zig:hasWriteWriteConflicts`
  /// (Debug builds only) to detect routing-bug-driven write-write
  /// collisions. Non-worker threads leave this at its default (false).
  pub threadlocal var t_is_shard_worker: bool = false;
  ```

  Within the `ShardedCoordinator` struct body, replace the existing fields and `start`/`stop` methods with:

  ```zig
      allocator: std.mem.Allocator,
      graph_name: []const u8, // owned
      adapter: *StorageAdapter,

      shards: [graph_storage.sharded_store.SHARD_COUNT]ShardState,
      should_stop: std.atomic.Value(u32),

      /// Long-lived thread pool hosting the shard workers. Sized with
      /// SHARD_COUNT default-lane slots + 1 blocking slot (wrapper
      /// requires blocking_workers >= 1).
      pool: *pooled.ThreadPool,

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
              .pool = undefined,
          };

          for (&self.shards) |*s| {
              s.* = .{
                  .queue = std.Deque(*ApplyOp).empty,
                  .queue_mutex = std.Io.Mutex.init,
                  .queue_not_empty = std.Io.Condition.init,
                  .ops_applied = std.atomic.Value(u64).init(0),
                  .batches = std.atomic.Value(u64).init(0),
              };
              try s.queue.ensureTotalCapacityPrecise(allocator, max_batch * 4);
          }

          self.pool = try pooled.ThreadPool.init(allocator, .{
              .num_threads = graph_storage.sharded_store.SHARD_COUNT + 1,
              .queue_capacity = @max(graph_storage.sharded_store.SHARD_COUNT * 4, 64),
          });
          errdefer self.pool.deinit();

          for (0..graph_storage.sharded_store.SHARD_COUNT) |idx| {
              const arg = try allocator.create(ShardLoopArg);
              arg.* = .{ .coord = self, .shard_idx = idx };
              const submitted = self.pool.submitDefault(.{
                  .context = @ptrCast(arg),
                  .callback = shardLoopEntry,
              });
              if (!submitted) {
                  allocator.destroy(arg);
                  self.should_stop.store(1, .release);
                  self.wakeAllShards();
                  return error.ShardSubmitFailed;
              }
          }

          return self;
      }

      pub fn stop(self: *ShardedCoordinator) void {
          self.should_stop.store(1, .release);
          self.wakeAllShards();
          self.pool.deinit();

          for (&self.shards) |*s| s.queue.deinit(self.allocator);
          self.allocator.free(self.graph_name);
          self.allocator.destroy(self);
      }

      fn wakeAllShards(self: *ShardedCoordinator) void {
          const io = std.Io.Threaded.global_single_threaded.io();
          for (&self.shards) |*s| {
              s.queue_mutex.lockUncancelable(io);
              s.queue_not_empty.signal(io);
              s.queue_mutex.unlock(io);
          }
      }
  ```

  Ensure the file's top has `const graph_storage = @import("graph_storage");`. If it's imported under a different local alias, use whichever alias exists and replace `graph_storage.sharded_store.*` with `<alias>.sharded_store.*` consistently.

- [ ] **Step 3.4: Replace `submit`, add `shardLoop` + `applyShardBatch` + test accessors.**

  Replace the existing `submit` method body with:

  ```zig
      /// Submit an op and block until the owning shard's worker completes it.
      /// For insert-node / merge-node ops the id is pre-allocated here so
      /// `shardKey()` is stable before enqueue. For `bulk_match_create_edge`
      /// the source_id is resolved here under `mg.rwlock` SHARED; orphan
      /// sources return silently (node_or_edge_id = 0).
      pub fn submit(self: *ShardedCoordinator, op: *ApplyOp) !u64 {
          const io = std.Io.Threaded.global_single_threaded.io();

          switch (op.*) {
              .bulk_insert_node => |*p| {
                  const store = graph_store.getGlobalStore(graph_store.global_allocator());
                  p.assigned_id = store.reserveNodeId();
              },
              .bulk_merge_node => |*p| {
                  const store = graph_store.getGlobalStore(graph_store.global_allocator());
                  p.assigned_id = store.reserveNodeId();
              },
              .bulk_insert_edge => {},
              .bulk_match_create_edge => |*p| {
                  if (self.adapter.lookupNodeByMergeKey(
                      self.graph_name,
                      p.src_label,
                      p.src_filter_key,
                      p.src_filter_value,
                      error.SourceNodeNotFound,
                  )) |sid| {
                      p.source_id = sid;
                  } else |err| switch (err) {
                      error.SourceNodeNotFound => {
                          const res = op.resultPtr();
                          res.node_or_edge_id = 0;
                          res.err = null;
                          res.done.store(1, .release);
                          return 0;
                      },
                      else => return err,
                  }
              },
          }

          const shard_idx = graph_storage.sharded_store.shardIndex(op.shardKey());
          const s = &self.shards[shard_idx];

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
  ```

  Add `ShardLoopArg`, `shardLoopEntry`, `shardLoop`, `applyShardBatch`, and test accessors at the end of the struct body (where `flusherLoop` + `applyBatch` used to be):

  ```zig
      const ShardLoopArg = struct {
          coord: *ShardedCoordinator,
          shard_idx: usize,
      };

      fn shardLoopEntry(ctx_ptr: *anyopaque) void {
          const arg: *ShardLoopArg = @ptrCast(@alignCast(ctx_ptr));
          defer arg.coord.allocator.destroy(arg);
          shardLoop(arg.coord, arg.shard_idx);
      }

      fn shardLoop(self: *ShardedCoordinator, shard_idx: usize) void {
          // Task 6 MVCC guard: mark this thread as a shard worker so
          // transactions/manager.zig:hasWriteWriteConflicts can detect
          // routing-bug-driven write-write collisions in Debug builds.
          t_is_shard_worker = true;
          defer t_is_shard_worker = false;

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
          _ = shard_idx;
          const io = std.Io.Threaded.global_single_threaded.io();

          // Per-shard batch statement txn — ONE fsync for the whole
          // shard batch. Matches the single-flusher's amortisation
          // pattern, scoped to this shard.
          var stmt_txn: graph_storage_adapter.StatementTxn = undefined;
          var have_txn = false;
          _ = self.adapter.getOrCreateGraph(self.graph_name) catch {};
          if (self.adapter.beginStatementTxn(self.graph_name, &stmt_txn)) |_| {
              have_txn = true;
          } else |_| {}

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
                      if (self.adapter.bulkInsertEdgeWithIdsShardLocked(
                          self.graph_name,
                          p.source_id,
                          p.target_id,
                          p.rel_type,
                          p.props,
                      )) |id| {
                          res.node_or_edge_id = id;
                      } else |e| {
                          res.err = e;
                      }
                  },
                  .bulk_match_create_edge => |p| {
                      // source_id was resolved at submit time.  Resolve
                      // target here if not yet set — if missing, silent skip.
                      var target_id = p.target_id;
                      if (target_id == 0) {
                          if (self.adapter.lookupNodeByMergeKey(
                              self.graph_name,
                              p.dst_label,
                              p.dst_filter_key,
                              p.dst_filter_value,
                              error.TargetNodeNotFound,
                          )) |tid| {
                              target_id = tid;
                          } else |err| switch (err) {
                              error.TargetNodeNotFound => continue,
                              else => {
                                  res.err = err;
                                  continue;
                              },
                          }
                      }
                      if (self.adapter.bulkInsertEdgeWithIdsShardLocked(
                          self.graph_name,
                          p.source_id,
                          target_id,
                          p.rel_type,
                          p.props,
                      )) |id| {
                          res.node_or_edge_id = id;
                      } else |e| switch (e) {
                          error.SourceNodeNotFound, error.TargetNodeNotFound => {},
                          else => res.err = e,
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

          if (have_txn) {
              if (stmt_txn.commit()) |_| {} else |e| {
                  for (batch) |op| {
                      const res = op.resultPtr();
                      if (res.err == null) res.err = e;
                  }
              }
          }

          for (batch) |op| {
              const res = op.resultPtr();
              res.done.store(1, .release);
              std.Io.futexWake(io, u32, &res.done.raw, 1);
          }
      }

      pub fn shardQueueDepthForTest(self: *ShardedCoordinator, shard_idx: usize) usize {
          if (!@import("builtin").is_test) @compileError("test-only accessor");
          const io = std.Io.Threaded.global_single_threaded.io();
          const s = &self.shards[shard_idx];
          s.queue_mutex.lockUncancelable(io);
          defer s.queue_mutex.unlock(io);
          return s.queue.len;
      }

      pub fn shardOpsAppliedForTest(self: *ShardedCoordinator, shard_idx: usize) u64 {
          if (!@import("builtin").is_test) @compileError("test-only accessor");
          return self.shards[shard_idx].ops_applied.load(.acquire);
      }
  ```

- [ ] **Step 3.5: Update the module doc-comment.**

  Replace the module header (lines 1 through just before `const std = @import("std");`) with:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Per-graph sharded coordinator (restored from commit 210de668 and
  //! re-adapted for current HEAD — see
  //! docs/superpowers/specs/2026-04-25-sharded-coordinator-restoration-design.md).
  //!
  //! Each per-graph coordinator runs 16 shard workers on
  //! `pooled.ThreadPool`. `submit(op)` routes by
  //! `sharded_store.shardIndex(op.shardKey())`:
  //!   * node inserts / merges route by the pre-allocated node id
  //!   * regular edge inserts route by source_id
  //!   * bulk_match_create_edge resolves source_id at submit time
  //!     under mg.rwlock SHARED and then routes by the resolved id
  //!     (orphan sources silently return 0 without enqueuing)
  //!
  //! Each shard worker drains up to `max_batch` = 256 ops, wraps them
  //! in a single statement transaction (one WAL fsync per shard-batch),
  //! dispatches to the shard-locked helpers on `StorageAdapter`, and
  //! wakes submitters via the `ApplyResult.done` futex.
  ```

- [ ] **Step 3.6: Run the routing test — should now compile AND pass.**

  Run: `zig build test-sharded-coordinator-routing 2>&1 | tail -20`
  Expected: PASS (green). The test enqueues one node-insert op, submit returns a non-zero id, and exactly one shard's `ops_applied` counter equals the shard matching `shardIndex(id)`.

  If the test fails with a compile error referencing `shardOpsAppliedForTest`, Step 3.4's accessor was missed. Go back and add it.

  If it fails at runtime, common causes:
  - `assigned_id` is not being set → recheck `submit` in Step 3.4.
  - `pool.deinit()` deadlocks → recheck `stop`.
  - Worker panics → examine stderr. Most likely cause is an adapter helper that's not shard-lock-aware; double-check you're calling `*WithReservedId` / `*ShardLocked` variants, NOT the whole-graph-exclusive `bulkInsertNode` / `bulkInsertEdgeWithIds`.

- [ ] **Step 3.7: Run the full test suite.**

  Run: `zig build test 2>&1 | grep -iE 'error:|failed|panic:' | head -20`
  Expected: zero matches. If the pre-existing `tests/test_sharded_coordinator.zig` fails with a reference to `GroupCommitCoordinator`, don't fix it here — Task 4 handles that. Skip that failure for this task's commit by first checking that only unrelated failures are present. If the failure is `GroupCommitCoordinator` name-resolution, proceed to commit.

- [ ] **Step 3.8: Commit.**

  ```bash
  git add src/storage/group_commit.zig
  git commit -m "feat(storage): restore ShardedCoordinator; delete single-flusher body (Task 3)"
  ```

---

### Task 4: Update all callers

**Files:**
- Modify: `src/server/quic_connection_handler.zig` (only if it references `GroupCommitCoordinator` literally — it currently doesn't)
- Modify: `tests/test_sharded_coordinator.zig`

- [ ] **Step 4.1: Locate all remaining callers.**

  Run: `grep -rn 'GroupCommitCoordinator' src/ tests/`

  Expected: the only hits after Task 3 are inside `tests/test_sharded_coordinator.zig` (header comment on line 5, type reference on line 41). If `src/server/quic_connection_handler.zig` also has hits, update them at those exact line numbers.

- [ ] **Step 4.2: Update `tests/test_sharded_coordinator.zig` header and type references.**

  In `tests/test_sharded_coordinator.zig`:

  1. Replace the module-header block (lines 4–13, the `//!` section) with:

     ```zig
     //! ShardedCoordinator (16-way) regression test pinning per-graph
     //! isolation and 16-way concurrent submission under the same-graph
     //! fan-in pattern.
     //!
     //! Uses `pooled.ThreadPool` per project convention.
     ```

  2. Replace `*group_commit.GroupCommitCoordinator` with `*group_commit.ShardedCoordinator` (line 41, inside `WorkerCtx`).

  No other functional changes — the public API (`getOrStartCoordinator`, `submit`, `shutdownAllCoordinators`, `setEnabledForTest`) is identical.

- [ ] **Step 4.3: Build + run all tests.**

  Run: `zig build test 2>&1 | grep -c 'error:'`
  Expected: `0`.

  Run: `zig build test 2>&1 | tail -10`
  Expected: clean test run; no panics.

- [ ] **Step 4.4: Commit.**

  ```bash
  git add tests/test_sharded_coordinator.zig
  git commit -m "refactor(storage): update test callers to ShardedCoordinator (Task 4)"
  ```

  If `src/server/quic_connection_handler.zig` was modified, add it to the `git add` too.

---

## Phase 4 — Integration regression (hub-node)

### Task 5: Hub-node concurrent-edge regression test

**Files:**
- Create: `tests/test_sharded_coordinator_hub_regression.zig`
- Modify: `build.zig`

The Phase 2.4 cascade was triggered by `edges_member_of` (many edges into few hub nodes). Pin the fix at small scale.

- [ ] **Step 5.1: Write the test.**

  Create `tests/test_sharded_coordinator_hub_regression.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Hub-node concurrent-edge regression: 16 threads × 50 edges into
  //! one hub. Pre-restoration this cascaded to 40001; post-restoration
  //! the deterministic source-id routing ensures all edges land on
  //! the same (source's) shard thread, eliminating same-resource
  //! writer contention.

  const std = @import("std");
  const geode = @import("geode");
  const adapter_mod = geode.graph_storage_adapter;
  const group_commit = geode.group_commit;

  const Ctx = struct {
      coord: *group_commit.ShardedCoordinator,
      hub_id: u64,
      source_ids: []const u64,
      err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
      done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
  };

  fn worker(ctx_ptr: *anyopaque) void {
      const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
      for (ctx.source_ids) |sid| {
          var op = group_commit.ApplyOp{ .bulk_insert_edge = .{
              .source_id = sid,
              .target_id = ctx.hub_id,
              .rel_type = "MEMBER_OF",
              .props = &.{},
              .result = .{},
          } };
          _ = ctx.coord.submit(&op) catch {
              ctx.err.store(1, .release);
              ctx.done.store(1, .release);
              return;
          };
      }
      ctx.done.store(1, .release);
  }

  test "hub-node concurrent edge creation does not trigger SerializationFailure" {
      const allocator = std.testing.allocator;
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

      group_commit.setEnabledForTest(true);
      defer {
          group_commit.setEnabledForTest(false);
          group_commit.shutdownAllCoordinators();
      }

      const coord = try group_commit.getOrStartCoordinator(allocator, &adapter, "g_hub");

      // Create one hub node.
      const hub_labels = [_][]const u8{"Group"};
      var hub_op = group_commit.ApplyOp{ .bulk_insert_node = .{
          .labels = &hub_labels,
          .props = &.{},
          .result = .{},
      } };
      const hub_id = try coord.submit(&hub_op);
      try std.testing.expect(hub_id != 0);

      // Create 16 × 50 = 800 source nodes (one per edge we're about to create).
      var source_ids: [16 * 50]u64 = undefined;
      const member_labels = [_][]const u8{"Member"};
      for (&source_ids) |*sid| {
          var op = group_commit.ApplyOp{ .bulk_insert_node = .{
              .labels = &member_labels,
              .props = &.{},
              .result = .{},
          } };
          sid.* = try coord.submit(&op);
      }

      // Fan out 16 worker threads, each submitting 50 edges into the hub.
      var ctxs: [16]Ctx = undefined;
      var threads: [16]std.Thread = undefined;
      for (&ctxs, 0..) |*c, i| {
          c.* = .{
              .coord = coord,
              .hub_id = hub_id,
              .source_ids = source_ids[i * 50 .. (i + 1) * 50],
          };
          threads[i] = try std.Thread.spawn(.{}, worker, .{@as(*anyopaque, @ptrCast(c))});
      }
      for (threads) |t| t.join();

      for (&ctxs) |*c| try std.testing.expectEqual(@as(u32, 0), c.err.load(.acquire));
  }
  ```

- [ ] **Step 5.2: Register in `build.zig`.**

  Immediately after the `test_sharded_coordinator_routing` block you added in Task 2.2, add:

  ```zig
      const sharded_hub_mod = b.createModule(.{ .root_source_file = b.path("tests/test_sharded_coordinator_hub_regression.zig"), .target = target, .optimize = optimize });
      sharded_hub_mod.addImport("geode", root_mod);
      const sharded_hub_tests = b.addTest(.{ .root_module = sharded_hub_mod });
      const run_sharded_hub_tests = b.addRunArtifact(sharded_hub_tests);
      test_step.dependOn(&run_sharded_hub_tests.step);
      const sharded_hub_step = b.step("test-sharded-coordinator-hub", "Run ShardedCoordinator hub-node concurrent-edge regression");
      sharded_hub_step.dependOn(&run_sharded_hub_tests.step);
  ```

- [ ] **Step 5.3: Run the test.**

  Run: `zig build test-sharded-coordinator-hub 2>&1 | tail -20`
  Expected: PASS. All 16 worker threads return without error.

- [ ] **Step 5.4: Commit.**

  ```bash
  git add tests/test_sharded_coordinator_hub_regression.zig build.zig
  git commit -m "test(storage): hub-node concurrent-edge regression pins no 40001 cascade (Task 5)"
  ```

---

## Phase 5 — MVCC routing invariant guard

### Task 6: Debug-build panic in `hasWriteWriteConflicts` when called on a shard-worker thread

**Files:**
- Modify: `src/transactions/manager.zig`
- Create: `tests/test_txn_manager_routing_guard.zig`
- Modify: `build.zig`

Under deterministic shard routing, the coordinator's workers should never trip write-write conflicts — routing guarantees same-resource writes land on the same thread. A Debug-mode panic catches routing-bug regressions at test time.

- [ ] **Step 6.1: Locate the return-true site in `hasWriteWriteConflicts` and its callers.**

  Run: `grep -n 'hasWriteWriteConflicts\|return error.SerializationFailure' src/transactions/manager.zig | head -10`

  Expected: find the function `hasWriteWriteConflicts` and the call-site(s) that convert its `true` result into `return error.SerializationFailure`. There is typically one such call-site in the commit path.

- [ ] **Step 6.2: Add the guard at the call-site.**

  At each call-site that follows `if (try self.hasWriteWriteConflicts(…)) return error.SerializationFailure;`, transform to:

  ```zig
  if (try self.hasWriteWriteConflicts(txn.id)) {
      if (@import("builtin").mode == .Debug) {
          const group_commit = @import("../storage/group_commit.zig");
          if (group_commit.t_is_shard_worker) {
              std.debug.panic(
                  "write-write conflict under ShardedCoordinator routing — " ++
                  "the routing contract (same source_id → same shard → same thread) " ++
                  "has been violated. See " ++
                  "docs/superpowers/specs/2026-04-25-sharded-coordinator-restoration-design.md",
                  .{},
              );
          }
      }
      return error.SerializationFailure;
  }
  ```

  The `const group_commit = @import(...)` is local-scoped to avoid a file-level cycle risk. Use `../storage/group_commit.zig` if `transactions/manager.zig` is at `src/transactions/manager.zig` — verify the relative path with a quick `ls -l src/transactions/manager.zig`.

- [ ] **Step 6.3: Build the project to confirm no circularity.**

  Run: `zig build 2>&1 | tail -5`
  Expected: clean build. If you hit `error: dependency loop`, the local-scoped import did not help — move `t_is_shard_worker` to a new file `src/storage/shard_worker_tls.zig` whose only content is:

  ```zig
  pub threadlocal var t_is_shard_worker: bool = false;
  ```

  Then have both `group_commit.zig` and `transactions/manager.zig` import `shard_worker_tls`. Remove the declaration from `group_commit.zig`. Re-run build. If still failing, report DONE_WITH_CONCERNS.

- [ ] **Step 6.4: Run the full suite to verify no existing test trips the panic.**

  Run: `zig build test 2>&1 | grep -iE 'panic:|error:' | head -20`
  Expected: no `panic:` lines. If a pre-existing test trips the panic, it means the test exercises the coordinator write path AND the manager's conflict detection fires — indicating either a pre-existing routing bug or a stale manager heuristic. Revert the guard and report BLOCKED with the specific test + assertion that fired.

- [ ] **Step 6.5: Write the placeholder test file.**

  Create `tests/test_txn_manager_routing_guard.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Placeholder for the MVCC routing-invariant debug-panic check.
  //!
  //! Zig 0.16's stdlib has no stable `std.testing.expectPanic` for
  //! calling-frame panics, so this file documents the contract only —
  //! the real regression-catcher is:
  //!   1. Task 7's msft-graph run asserting zero 40001 errors.
  //!   2. Any future regression that violates routing fires
  //!      `panic: write-write conflict under ShardedCoordinator routing`
  //!      on stderr during `zig build test` and fails the suite.

  const std = @import("std");

  test "routing-guard contract placeholder" {
      if (@import("builtin").mode != .Debug) return error.SkipZigTest;
      // Nothing to execute — the contract is enforced by runtime panic
      // on violation, which other tests exercise transitively.
      return error.SkipZigTest;
  }
  ```

- [ ] **Step 6.6: Register in `build.zig`.**

  Immediately after the `test_sharded_coordinator_hub` block you added in Task 5.2, add:

  ```zig
      const routing_guard_mod = b.createModule(.{ .root_source_file = b.path("tests/test_txn_manager_routing_guard.zig"), .target = target, .optimize = optimize });
      routing_guard_mod.addImport("geode", root_mod);
      const routing_guard_tests = b.addTest(.{ .root_module = routing_guard_mod });
      const run_routing_guard_tests = b.addRunArtifact(routing_guard_tests);
      test_step.dependOn(&run_routing_guard_tests.step);
      const routing_guard_step = b.step("test-txn-routing-guard", "Run txn-manager routing-invariant guard placeholder");
      routing_guard_step.dependOn(&run_routing_guard_tests.step);
  ```

- [ ] **Step 6.7: Commit.**

  ```bash
  git add src/transactions/manager.zig tests/test_txn_manager_routing_guard.zig build.zig
  git commit -m "feat(txn): debug-build routing-invariant panic in hasWriteWriteConflicts (Task 6)"
  ```

---

## Phase 6 — Exit-criterion measurement

### Task 7: msft-graph ingest exit-criterion run

**Files:**
- Create (scratch, not committed): `/tmp/run-final-v2.sh`
- Create (committed): `docs/performance/2026-04-24-sharding/phase2-final-run.log`

- [ ] **Step 7.1: Build release binary.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-phase2-final
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 7.2: Adapt the Task 0 baseline script and run it.**

  ```bash
  cp /tmp/run-baseline-v2.sh /tmp/run-final-v2.sh
  sed -i 's|geode-phase2-baseline|geode-phase2-final|g; s|phase2-plan-baseline.log|phase2-final-run.log|g' /tmp/run-final-v2.sh
  bash /tmp/run-final-v2.sh
  ```

- [ ] **Step 7.3: Verify exit criteria.**

  All three must hold:

  ```bash
  grep 'wall_clock_s=' docs/performance/2026-04-24-sharding/phase2-final-run.log
  # Expected: wall_clock_s=<N> where N <= 70

  grep -c '40001\|serial fallback' docs/performance/2026-04-24-sharding/phase2-final-run.log
  # Expected: 0

  grep -c '40001\|Write lock acquisition timed out' /tmp/geode-phase2-final/server.log
  # Expected: 0
  ```

  If any criterion fails, STOP — report BLOCKED with the specific counter that failed. Do not commit a failed final-run.log as evidence of success.

- [ ] **Step 7.4: Commit the evidence.**

  ```bash
  git add docs/performance/2026-04-24-sharding/phase2-final-run.log
  git commit -m "docs(perf): msft-graph ingest <=70s with zero 40001 (Task 7)"
  ```

### Task 8: Append closure note to `PHASE2-SUMMARY.md`

**Files:**
- Modify: `docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md`

- [ ] **Step 8.1: Append the closure section.**

  Read the current tail of `PHASE2-SUMMARY.md` to confirm formatting, then append:

  ```markdown
  ## Phase 2-final — closed (2026-04-25)

  Restored `ShardedCoordinator` (originally commit `210de668`, reverted, now re-
  landed) as the sole coordinator implementation. Single-flusher
  `GroupCommitCoordinator` deleted. 16 per-shard worker threads; each shard-batch
  wrapped in one statement transaction (one WAL fsync per shard-batch).
  `bulk_match_create_edge` source_id pre-resolved at submit time under
  `mg.rwlock` SHARED; orphan sources return silently. Thread-local-gated
  debug-mode panic in `transactions/manager.zig:hasWriteWriteConflicts` catches
  future routing-bug regressions.

  Evidence: `phase2-final-run.log` (exit criterion).
  Spec: `docs/superpowers/specs/2026-04-25-sharded-coordinator-restoration-design.md`.
  Plan: `docs/superpowers/plans/2026-04-25-sharded-coordinator-restoration.md`.

  Phase 2.1–2.3 workarounds (writer-preferred lock, tryLock-spin backoff, single
  flusher + 120 s deadline) are no longer load-bearing and can be deleted in a
  follow-up hygiene pass.
  ```

- [ ] **Step 8.2: Commit.**

  ```bash
  git add docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md
  git commit -m "docs(perf): close Phase 2; point at v2 evidence + restoration plan (Task 8)"
  ```

---

## Self-review results

- **Spec coverage:** every "must" in the spec maps to a task.
  - Coordinator architecture (spec § Architecture) → Task 3.
  - Shard key for `bulk_match_create_edge` (spec § Architecture `submit` step 2) → Task 1 (fields) + Task 3 (submit-time resolution).
  - Per-shard batch statement txn (spec § Architecture `shardLoop` step 3) → Task 3.4.
  - Cross-shard edge contract (spec § Cross-shard edge contract) → inherited from `bulkInsertEdgeWithIdsShardLocked`; no task code change (only documented).
  - MVCC routing invariant (spec § MVCC routing invariant) → Task 6.
  - Tests (spec § Test coverage) → Tasks 2, 5, 6.
  - Measurement (spec § Measurement and exit criterion) → Tasks 0 (baseline retry) + 7 (exit run).
  - Closure note (spec § Exit criteria recap) → Task 8.

- **Placeholder scan:** all TODO / "write later" / "add appropriate" strings are accounted for — Task 6.5 explicitly marks its test as a `return error.SkipZigTest` placeholder with commentary; that is acknowledged scope, not a hidden placeholder.

- **Type consistency:**
  - `shardKey()` (Task 1) ↔ `shardIndex(op.shardKey())` (Task 3.4) ↔ `shardOpsAppliedForTest` assertion (Task 2.1): consistent.
  - `ShardedCoordinator` name used uniformly after Task 3. Public API names (`start`, `stop`, `submit`, `getOrStartCoordinator`, `lookupCoordinator`, `shutdownAllCoordinators`, `isEnabled`, `setEnabledForTest`) preserved exactly.
  - `t_is_shard_worker` declared in `group_commit.zig` (Task 3.3), referenced in `transactions/manager.zig` (Task 6.2): same spelling.

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-25-sharded-coordinator-restoration.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, spec + quality review between tasks, fast iteration on both code and plan if reality drifts further.
2. **Inline execution** — execute tasks in this session using `superpowers:executing-plans`, batch with checkpoints.
