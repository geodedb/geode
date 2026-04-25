# edges_contains Cascade Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify the actual root cause of the simultaneous-stream-failure cascade on `edges_contains.jsonl` (~10 min into the file, statement ~105/106 across all 17 chunks) under 16-worker msft-graph ingest, and apply the smallest correct fix that lets the file complete in parallel-pipeline mode.

**Architecture:** Three candidate causes (QUIC stream/data flow-control limits, server-side memory or scheduler stall, per-graph rwlock starvation). The plan first instruments the server with **concrete telemetry** for each candidate (Tasks 1–4), then runs a single edges_contains-only repro under that telemetry (Task 5) to determine which cause is real, then applies the smallest targeted fix that the diagnosis points to (Task 6), then re-runs the full msft-graph workload to confirm (Task 7).

**Tech Stack:** Zig 0.16; vendored QUIC at `zig-pkg/quic-0.1.11`; `std.Io.Mutex` / `std.Io.RwLock` / `std.atomic.Value` / `pooled.ThreadPool`. Server CLI in `src/server/cli_args.zig` + `src/server/main.zig`. Transport in `src/transport/quic.zig`. Coordinator in `src/storage/group_commit.zig`. Adapter in `src/storage/graph_storage_adapter.zig`. Per-graph rwlock acquire helpers in `src/graph_store.zig:5399-5500`.

---

## File structure

**Create:**
- `src/server/runtime_metrics.zig` — small periodic-emit helper that walks a registered list of `*std.atomic.Value(u64)` counters and emits one log line every N seconds. New file with one clear responsibility.
- `tests/test_runtime_metrics.zig` — unit test for the counter-registration + snapshot shape.
- `docs/performance/2026-04-25-edges-contains/repro-server.log` — captured server log from the diagnostic repro run.
- `docs/performance/2026-04-25-edges-contains/repro-ingest.log` — captured msft-graph log from the diagnostic repro run.
- `docs/performance/2026-04-25-edges-contains/diagnosis.md` — short markdown documenting which candidate is confirmed by the captured artifacts.
- `docs/performance/2026-04-25-edges-contains/post-fix-run.log` — full-msft-graph re-run after the targeted fix lands.

**Modify:**
- `src/transport/quic.zig` — bump `Config.max_data` (per-connection flow-control window) from 100 MB to 1 GB and `Config.max_stream_data` from 10 MB to 100 MB so a single connection / stream can carry sustained 10-min ingest traffic without flow-control stall. (See Task 6A — only applied if Task 5 diagnosis names QUIC flow-control as the cause.)
- `src/storage/graph_storage_adapter.zig` — add three `std.atomic.Value(u64)` counters on `ManagedGraph`: `rwlock_shared_acquired_total`, `rwlock_shared_wait_ns_total`, `rwlock_exclusive_wait_ns_total`. Wired around the existing acquire helpers — no functional change.
- `src/storage/group_commit.zig` — add `apply_batches_total`, `apply_ops_total`, `apply_errors_total` counters on `ShardedCoordinator` and register with `runtime_metrics`.
- `src/server/main.zig` — initialise `runtime_metrics` at startup, spawn the periodic-emit task on `pooled.ThreadPool`, shut it down on server exit.
- `src/lib.zig` — re-export `runtime_metrics` so tests can import it.
- `build.zig` — register the new `test-runtime-metrics` target.

**Leave alone:**
- The `ShardedCoordinator` core path (already correct after Phase 2-final).
- The `ShardedGraphEngine` and per-shard adapters.
- The MVCC routing-guard (orthogonal).

---

## Phase 0 — Add a small `runtime_metrics` helper

### Task 1: Counter registry + snapshot helper

**Files:**
- Create: `src/server/runtime_metrics.zig`
- Create: `tests/test_runtime_metrics.zig`
- Modify: `src/lib.zig` (re-export)
- Modify: `build.zig` (test registration)

This is a focused single-purpose module that owns the registry of named counters plus the snapshot helper. Used by Tasks 2 and 3 to make telemetry visible.

- [ ] **Step 1.1: Write the failing test.**

  Create `tests/test_runtime_metrics.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Unit test for `runtime_metrics`: register counters, emit a snapshot
  //! string, verify the format includes every registered name + value.

  // CANARY: REQ=REQ-PERF-DIAG-RUNTIME-METRICS; FEATURE="RuntimeMetricsHelper"; ASPECT=CounterRegistry; STATUS=TESTED; TEST=tests/test_runtime_metrics.zig; OWNER=perf; UPDATED=2026-04-25

  const std = @import("std");
  const geode = @import("geode");
  const runtime_metrics = geode.runtime_metrics;

  test "register + snapshot emits all counters" {
      const allocator = std.testing.allocator;
      var registry = try runtime_metrics.Registry.init(allocator);
      defer registry.deinit();

      var ops = std.atomic.Value(u64).init(7);
      var batches = std.atomic.Value(u64).init(2);
      try registry.register("apply_ops_total", &ops);
      try registry.register("apply_batches_total", &batches);

      var buf: std.ArrayList(u8) = .empty;
      defer buf.deinit(allocator);
      try registry.snapshotInto(allocator, &buf);

      const out = buf.items;
      try std.testing.expect(std.mem.indexOf(u8, out, "apply_ops_total=7") != null);
      try std.testing.expect(std.mem.indexOf(u8, out, "apply_batches_total=2") != null);
  }
  ```

- [ ] **Step 1.2: Run to verify the test fails on a missing module.**

  Run: `zig build test-runtime-metrics 2>&1 | tail -10`
  Expected: compile error — `runtime_metrics` not found (registered later in Step 1.5).

- [ ] **Step 1.3: Implement the module.**

  Create `src/server/runtime_metrics.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Runtime metrics helper: a small append-only registry of named
  //! `*std.atomic.Value(u64)` counters plus a snapshot helper. Used to
  //! surface coordinator throughput, lock-wait timing, and allocator
  //! usage during heavy-load reproductions.

  const std = @import("std");

  pub const Counter = struct {
      name: []const u8,
      ptr: *std.atomic.Value(u64),
  };

  pub const Registry = struct {
      allocator: std.mem.Allocator,
      counters: std.ArrayList(Counter),
      mutex: std.Io.Mutex = std.Io.Mutex.init,

      pub fn init(allocator: std.mem.Allocator) !*Registry {
          const self = try allocator.create(Registry);
          self.* = .{
              .allocator = allocator,
              .counters = std.ArrayList(Counter).empty,
          };
          return self;
      }

      pub fn deinit(self: *Registry) void {
          self.counters.deinit(self.allocator);
          self.allocator.destroy(self);
      }

      pub fn register(self: *Registry, name: []const u8, ptr: *std.atomic.Value(u64)) !void {
          const io = std.Io.Threaded.global_single_threaded.io();
          self.mutex.lockUncancelable(io);
          defer self.mutex.unlock(io);
          try self.counters.append(self.allocator, .{ .name = name, .ptr = ptr });
      }

      pub fn snapshotInto(
          self: *Registry,
          allocator: std.mem.Allocator,
          out: *std.ArrayList(u8),
      ) !void {
          _ = allocator;
          const io = std.Io.Threaded.global_single_threaded.io();
          self.mutex.lockUncancelable(io);
          defer self.mutex.unlock(io);

          var first = true;
          for (self.counters.items) |c| {
              if (!first) try out.append(self.allocator, ' ');
              first = false;
              try out.writer(self.allocator).print("{s}={d}", .{ c.name, c.ptr.load(.acquire) });
          }
      }
  };

  /// Process-global registry; nullable so tests can swap one in without
  /// the periodic-emit task. Initialised by the server `main` at startup.
  var g_registry: ?*Registry = null;

  pub fn globalRegistry() ?*Registry {
      return g_registry;
  }

  pub fn setGlobalRegistry(r: ?*Registry) void {
      g_registry = r;
  }
  ```

- [ ] **Step 1.4: Re-export from `src/lib.zig`.**

  Find a good insertion point near other server re-exports (`grep -n 'pub const ' src/lib.zig | head`). Add:

  ```zig
  pub const runtime_metrics = @import("server/runtime_metrics.zig");
  ```

- [ ] **Step 1.5: Register the test in `build.zig`.**

  Find the `test_txn_routing_guard` block (added by the previous plan): `grep -n 'test-txn-routing-guard' build.zig`. Immediately after that block, add:

  ```zig
      const runtime_metrics_mod = b.createModule(.{ .root_source_file = b.path("tests/test_runtime_metrics.zig"), .target = target, .optimize = optimize });
      runtime_metrics_mod.addImport("geode", root_mod);
      const runtime_metrics_tests = b.addTest(.{ .root_module = runtime_metrics_mod });
      const run_runtime_metrics_tests = b.addRunArtifact(runtime_metrics_tests);
      test_step.dependOn(&run_runtime_metrics_tests.step);
      const runtime_metrics_step = b.step("test-runtime-metrics", "Run runtime_metrics registry tests");
      runtime_metrics_step.dependOn(&run_runtime_metrics_tests.step);
  ```

- [ ] **Step 1.6: Run the test to verify GREEN.**

  Run: `zig build test-runtime-metrics 2>&1 | tail -5`
  Expected: PASS.

- [ ] **Step 1.7: Commit.**

  ```bash
  git add src/server/runtime_metrics.zig src/lib.zig tests/test_runtime_metrics.zig build.zig
  git commit -m "feat(server): runtime_metrics counter registry + snapshot helper (Task 1)"
  ```

---

## Phase 1 — Per-candidate telemetry

### Task 2: Coordinator throughput counters

**Files:**
- Modify: `src/storage/group_commit.zig` — add three counters on `ShardedCoordinator` and register them with `runtime_metrics`.

These counters answer "is the coordinator making forward progress?" — directly relevant to candidate 2 (server-side stall).

- [ ] **Step 2.1: Add the counter fields to `ShardedCoordinator`.**

  Inside `pub const ShardedCoordinator = struct { ... }` (around the existing fields), add:

  ```zig
      /// Cumulative number of shard-batches applied across all 16 shard workers.
      apply_batches_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      /// Cumulative number of ops applied across all shard-batches.
      apply_ops_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      /// Cumulative count of ops whose ApplyResult.err was set.
      apply_errors_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
  ```

- [ ] **Step 2.2: Increment the counters in `applyShardBatch`.**

  At the END of `applyShardBatch`, after the existing `for (batch) |op| { res.done.store(...); ... }` wake-up loop, add:

  ```zig
      _ = self.apply_batches_total.fetchAdd(1, .monotonic);
      _ = self.apply_ops_total.fetchAdd(@intCast(batch.len), .monotonic);
      var errs: u64 = 0;
      for (batch) |op| if (op.resultPtr().err != null) { errs += 1; };
      if (errs > 0) _ = self.apply_errors_total.fetchAdd(errs, .monotonic);
  ```

- [ ] **Step 2.3: Register the counters with the global registry.**

  In `ShardedCoordinator.start` (just before the final `return self;`), add:

  ```zig
      const runtime_metrics = @import("../server/runtime_metrics.zig");
      if (runtime_metrics.globalRegistry()) |reg| {
          reg.register("coord_apply_batches_total", &self.apply_batches_total) catch {};
          reg.register("coord_apply_ops_total", &self.apply_ops_total) catch {};
          reg.register("coord_apply_errors_total", &self.apply_errors_total) catch {};
      }
  ```

- [ ] **Step 2.4: Verify build + sharded-coord tests.**

  ```bash
  zig build 2>&1 | tail -5
  zig build test-sharded-coordinator-routing test-sharded-coordinator test-sharded-coordinator-hub 2>&1 | tail -10
  ```
  Expected: clean build, all three sharded-coord tests pass.

- [ ] **Step 2.5: Commit.**

  ```bash
  git add src/storage/group_commit.zig
  git commit -m "feat(storage): coordinator throughput counters wired to runtime_metrics (Task 2)"
  ```

### Task 3: mg.rwlock wait-time counters

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig` — add three counters on `ManagedGraph`, increment around the existing rwlock acquire sites.

These counters answer "are shard workers spending wall-time waiting on `mg.rwlock`?" — directly relevant to candidate 3 (rwlock starvation).

- [ ] **Step 3.1: Add the counter fields to `ManagedGraph`.**

  Inside `pub const ManagedGraph = struct { ... }`, add (alongside the existing `rwlock` / `shard_locks` fields):

  ```zig
      /// Diagnostic: cumulative count of SHARED acquires on `rwlock`.
      rwlock_shared_acquired_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      /// Diagnostic: cumulative wall-time (ns) all SHARED acquires waited
      /// before locking. A growing value with steady acquired count signals
      /// EXCLUSIVE-side starvation.
      rwlock_shared_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      /// Diagnostic: cumulative wall-time (ns) all EXCLUSIVE acquires waited.
      rwlock_exclusive_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
  ```

- [ ] **Step 3.2: Wrap SHARED + EXCLUSIVE acquire sites with timing.**

  Find every acquire site in this file: `grep -n 'rwlock\.lockShared\|rwlock\.lockUncancelable' src/storage/graph_storage_adapter.zig`.

  At each SHARED acquire site, replace:

  ```zig
  mg.rwlock.lockSharedUncancelable(io);
  ```

  with:

  ```zig
  const _t_start = std.time.nanoTimestamp();
  mg.rwlock.lockSharedUncancelable(io);
  _ = mg.rwlock_shared_wait_ns_total.fetchAdd(@intCast(@max(0, std.time.nanoTimestamp() - _t_start)), .monotonic);
  _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
  ```

  Apply the same pattern to EXCLUSIVE (`lockUncancelable` without `Shared`) sites — increment `rwlock_exclusive_wait_ns_total` only (no count counter — wait time is sufficient).

  Note: `_t_start` is a per-block local; if any function has multiple acquires in the same scope, rename to `_t_start_<n>` to avoid re-declaration.

- [ ] **Step 3.3: Register the counters with the global registry on `getOrCreateGraph` create branch.**

  Find `getOrCreateGraph` (`grep -n 'pub fn getOrCreateGraph' src/storage/graph_storage_adapter.zig`). At the end of the create branch (right after the `engines.put(name, mg)` call), add:

  ```zig
      const runtime_metrics = @import("../server/runtime_metrics.zig");
      if (runtime_metrics.globalRegistry()) |reg| {
          reg.register("mg_rwlock_shared_acquired_total", &mg.rwlock_shared_acquired_total) catch {};
          reg.register("mg_rwlock_shared_wait_ns_total", &mg.rwlock_shared_wait_ns_total) catch {};
          reg.register("mg_rwlock_exclusive_wait_ns_total", &mg.rwlock_exclusive_wait_ns_total) catch {};
      }
  ```

- [ ] **Step 3.4: Verify build + sharded-coord tests.**

  ```bash
  zig build 2>&1 | tail -5
  zig build test-sharded-coordinator-hub 2>&1 | tail -5
  ```
  Expected: clean.

- [ ] **Step 3.5: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig
  git commit -m "feat(storage): mg.rwlock wait-time counters wired to runtime_metrics (Task 3)"
  ```

### Task 4: Periodic emit task on server startup

**Files:**
- Modify: `src/server/main.zig`

- [ ] **Step 4.1: Initialise the registry at startup.**

  Find where the server completes core init (`grep -n 'thread pool initialized' src/server/main.zig`). Just before that line, add:

  ```zig
      const runtime_metrics_mod = @import("runtime_metrics.zig");
      const metrics_registry = try runtime_metrics_mod.Registry.init(gpa);
      runtime_metrics_mod.setGlobalRegistry(metrics_registry);
      defer {
          runtime_metrics_mod.setGlobalRegistry(null);
          metrics_registry.deinit();
      }
  ```

- [ ] **Step 4.2: Spawn a periodic-emit task on the existing thread pool.**

  Just after the registry init (still before the `[startup] thread pool initialized` line), add:

  ```zig
      var metrics_should_stop = std.atomic.Value(u32).init(0);
      const MetricsCtx = struct {
          registry: *runtime_metrics_mod.Registry,
          should_stop: *std.atomic.Value(u32),
          allocator: std.mem.Allocator,
      };
      const metrics_ctx = try gpa.create(MetricsCtx);
      defer gpa.destroy(metrics_ctx);
      metrics_ctx.* = .{
          .registry = metrics_registry,
          .should_stop = &metrics_should_stop,
          .allocator = gpa,
      };

      const metricsLoop = struct {
          fn run(ctx_ptr: *anyopaque) void {
              const ctx: *MetricsCtx = @ptrCast(@alignCast(ctx_ptr));
              while (ctx.should_stop.load(.acquire) == 0) {
                  std.Thread.sleep(5 * std.time.ns_per_s);
                  if (ctx.should_stop.load(.acquire) != 0) break;
                  var buf: std.ArrayList(u8) = .empty;
                  defer buf.deinit(ctx.allocator);
                  ctx.registry.snapshotInto(ctx.allocator, &buf) catch continue;
                  std.log.info("metrics: {s}", .{buf.items});
              }
          }
      }.run;

      _ = pool.submitDefault(.{ .context = @ptrCast(metrics_ctx), .callback = metricsLoop });
      defer metrics_should_stop.store(1, .release);
  ```

  Note: `pool` is the existing `pooled.ThreadPool` already initialised earlier in `main.zig` for the QUIC server. Use whatever local name it has (`grep -n 'pooled.ThreadPool' src/server/main.zig`).

- [ ] **Step 4.3: Verify build.**

  Run: `zig build 2>&1 | tail -5`
  Expected: clean.

- [ ] **Step 4.4: Smoke test — start server, verify metrics line appears.**

  ```bash
  mkdir -p /tmp/geode-metrics-smoke-$$
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
    nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-metrics-smoke-$$ \
      --listen 127.0.0.1:3170 --log-level info \
      > /tmp/geode-metrics-smoke-$$.log 2>&1 &
  PID=$!
  sleep 8
  grep 'metrics:' /tmp/geode-metrics-smoke-$$.log | head -3
  kill -9 $PID 2>/dev/null || true
  ```

  Expected: at least one `metrics: ...` line. Counter values may be all zero (no traffic yet) — that's fine.

- [ ] **Step 4.5: Commit.**

  ```bash
  git add src/server/main.zig
  git commit -m "feat(server): runtime_metrics periodic-emit task started from main (Task 4)"
  ```

---

## Phase 2 — Reproduce + diagnose

### Task 5: Capture an edges_contains-only repro under telemetry

**Files:**
- Create (scratch, not committed): `/tmp/run-edges-contains-repro.sh`
- Create (committed): `docs/performance/2026-04-25-edges-contains/repro-server.log`
- Create (committed): `docs/performance/2026-04-25-edges-contains/repro-ingest.log`
- Create (committed): `docs/performance/2026-04-25-edges-contains/diagnosis.md`

This reproduces the failure on `edges_contains.jsonl` alone (after seeding only the node files it references) so the diagnostic logs are clean and focused.

- [ ] **Step 5.1: Build release.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 5.2: Write the repro script.**

  Create `/tmp/run-edges-contains-repro.sh`:

  ```bash
  #!/bin/bash
  set -e
  cd /data/home/benji/src/devnw/codepros/geode/geode

  REPRO_DIR=docs/performance/2026-04-25-edges-contains
  mkdir -p "$REPRO_DIR"
  SERVER_LOG="$REPRO_DIR/repro-server.log"
  INGEST_LOG="$REPRO_DIR/repro-ingest.log"

  pkill -9 -f "geode serve --data-dir /tmp/geode-edges-contains" 2>/dev/null || true
  rm -rf /tmp/geode-edges-contains && mkdir -p /tmp/geode-edges-contains

  # Subset the dataset to only the files msft-graph processes up to and
  # including edges_contains. msft-graph processes edge files in
  # alphabetical order; keep only those at or before edges_contains.
  rm -rf /tmp/edges-contains-data && mkdir -p /tmp/edges-contains-data
  cp /data/home/benji/eagleg-topology-data-20/*.jsonl /tmp/edges-contains-data/
  for f in /tmp/edges-contains-data/edges_*.jsonl; do
      base=$(basename "$f")
      if [[ "$base" > edges_contains.jsonl ]]; then
          rm -f "$f"
      fi
  done
  ls /tmp/edges-contains-data/edges_*.jsonl > /dev/null

  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
    nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-edges-contains \
      --listen 127.0.0.1:3171 --log-level info \
      --idle-timeout 600000 \
      > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  echo "server_pid=$SERVER_PID" > "$INGEST_LOG"
  echo "server start: $(date -Iseconds)" >> "$INGEST_LOG"

  for attempt in $(seq 1 30); do
      if zig-out/bin/geode query --server 127.0.0.1:3171 --insecure-tls-skip-verify \
           -U geode -P Geode1234Abc --no-saved-session \
           "RETURN 1 AS ok" > /dev/null 2>&1; then
          echo "server ready after $((attempt * 2))s" >> "$INGEST_LOG"
          break
      fi
      sleep 2
  done

  zig-out/bin/geode query --server 127.0.0.1:3171 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session \
    "CREATE GRAPH abs_eagleg" >> "$INGEST_LOG" 2>&1 || true

  echo "ingest start: $(date -Iseconds)" >> "$INGEST_LOG"
  START=$(date +%s)
  timeout 1500 bash -c '
    GEODE_DSN="quic://127.0.0.1:3171/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /tmp/edges-contains-data \
      --parallel --workers 16 --chunk-size 1000 2>&1
  ' >> "$INGEST_LOG" 2>&1 || echo "INGEST_TIMED_OUT_OR_FAILED exit=$?" >> "$INGEST_LOG"
  END=$(date +%s)
  echo "ingest end: $(date -Iseconds) wall_clock_s=$((END-START))" >> "$INGEST_LOG"

  echo "--- post-run server process state ---" >> "$INGEST_LOG"
  if ps -p $SERVER_PID > /dev/null; then
      echo "server still running" >> "$INGEST_LOG"
      cat /proc/$SERVER_PID/status | grep -E 'VmRSS|VmPeak|Threads|FDSize' >> "$INGEST_LOG"
      ls /proc/$SERVER_PID/fd 2>/dev/null | wc -l | xargs -I{} echo "open fds: {}" >> "$INGEST_LOG"
  else
      echo "SERVER_PROCESS_DIED — check $SERVER_LOG tail" >> "$INGEST_LOG"
  fi

  kill -9 $SERVER_PID 2>/dev/null || true
  ```

- [ ] **Step 5.3: Run the repro.**

  ```bash
  chmod +x /tmp/run-edges-contains-repro.sh
  bash /tmp/run-edges-contains-repro.sh
  ```

  Expected wall-clock: 10–25 minutes. Will end either with successful ingest (fix already applied somehow) or — much more likely — with the cascade.

- [ ] **Step 5.4: Inspect the captured artifacts and write `diagnosis.md`.**

  Examine five things:

  1. **Did the server crash?** Run: `tail -30 docs/performance/2026-04-25-edges-contains/repro-server.log` and look for any `panic:` / `error:` / `Killed` line in the seconds before the cascade. Also check `repro-ingest.log` for `SERVER_PROCESS_DIED`.

  2. **Did `coord_apply_*` counters stop ticking?** Run: `grep 'metrics:' docs/performance/2026-04-25-edges-contains/repro-server.log | tail -20`. If `coord_apply_ops_total` was rising and then stalled (same value for ≥ 30 s before cascade), that's a server-side stall.

  3. **Did `mg_rwlock_*_wait_ns_total` grow disproportionately?** Same `grep 'metrics:'` output. If `mg_rwlock_exclusive_wait_ns_total` is large (≥ 30 s of wait time) while `mg_rwlock_shared_wait_ns_total` stays small, an EXCLUSIVE acquirer is starving (candidate 3).

  4. **Did the QUIC layer log a flow-control or stream-limit message?** Run: `grep -iE 'flow.control|max.streams|max.data|connection close|conn close|stream reset|stream limit' docs/performance/2026-04-25-edges-contains/repro-server.log`. Any match confirms candidate 1.

  5. **Did `VmRSS` show extreme growth?** Run: `grep VmRSS docs/performance/2026-04-25-edges-contains/repro-ingest.log`. Compare to a healthy idle server (~50–200 MB). > 2 GB at cascade time is suspicious; an OOM kill (vs. a clean process death in 5.4.1) confirms candidate 2.

  Write `docs/performance/2026-04-25-edges-contains/diagnosis.md` documenting the findings:

  ```markdown
  # edges_contains cascade — diagnosis (2026-04-25)

  Repro: `/tmp/run-edges-contains-repro.sh`. Wall-clock to cascade: <N> seconds.

  ## Captured signals

  - server crash: <yes/no>; last server-log line: `<paste>`
  - coord_apply_ops_total trajectory: <e.g., "rose 0→8500 over 9 min, then stalled at 8500 for 90 s before client gave up">
  - mg_rwlock_shared_wait_ns_total at cascade: <N>
  - mg_rwlock_exclusive_wait_ns_total at cascade: <N>
  - QUIC flow-control / stream messages: <yes/no — paste matching grep result>
  - VmRSS at cascade: <N MB>; VmPeak: <N MB>

  ## Verdict

  Primary cause: <one of: candidate-1-quic, candidate-2-memory, candidate-2-stall, candidate-3-rwlock, none-of-the-three>.

  Supporting evidence: <2-3 sentences referring to the captured signals above>.

  ## Recommended fix (Task 6)

  <one paragraph naming the targeted fix path>
  ```

- [ ] **Step 5.5: Commit the artifacts.**

  ```bash
  git add docs/performance/2026-04-25-edges-contains/
  git commit -m "docs(perf): edges_contains cascade — diagnostic repro + verdict (Task 5)"
  ```

---

## Phase 3 — Apply the targeted fix

### Task 6: Apply the fix that diagnosis.md names

**Files:** depend on the verdict written in Task 5.4.

The verdict in Task 5's `diagnosis.md` selects exactly ONE of the five sub-tasks below. Execute that sub-task; skip the others.

- [ ] **Step 6A: If verdict is `candidate-1-quic` (flow-control or stream limit hit).**

  Modify `src/transport/quic.zig` `Config.max_data` and `Config.max_stream_data` defaults.

  Find the existing block (`grep -n 'max_stream_data\|max_data:' src/transport/quic.zig`):

  ```zig
          max_stream_data: u64 = 10 * 1024 * 1024,
          max_data: u64 = 100 * 1024 * 1024,
  ```

  Replace with:

  ```zig
          // GAP-2026-04-25: 16-worker msft-graph ingest sustains 10+ minutes
          // of bidirectional traffic per connection. The prior 10MB/100MB
          // window saturated mid-file on edges_contains (4969 dense edge
          // ops). Bumped 10x to give a single connection 1GB total +
          // 100MB per stream of headroom; production callers can lower via
          // Config if they're memory-constrained.
          max_stream_data: u64 = 100 * 1024 * 1024,
          max_data: u64 = 1024 * 1024 * 1024,
  ```

  Verify:

  ```bash
  zig build 2>&1 | tail -5
  zig build test-sharded-coordinator-hub 2>&1 | tail -3
  ```
  Expected: clean + PASS.

  Commit:

  ```bash
  git add src/transport/quic.zig
  git commit -m "fix(transport): raise QUIC per-conn max_data 100MB->1GB and per-stream 10MB->100MB

  Sustained 16-worker msft-graph ingest exhausted the prior flow-control
  window mid-file on edges_contains. Empirically the cascade aligned with
  the 100MB max_data budget — see docs/performance/2026-04-25-edges-contains/diagnosis.md.
  "
  ```

- [ ] **Step 6B: If verdict is `candidate-2-memory` (RSS growth >2 GB or OOM kill).**

  This sub-task assumes diagnosis.md identified a specific allocation hotspot. Without that pointer, this sub-task can't proceed mechanically — too many possible leaks (per-batch allocation in `applyShardBatch`, undo-log retention, per-shard queue not freed, etc.).

  Report **DONE_WITH_CONCERNS** with diagnosis.md's hotspot annotation; a follow-up plan targets the specific leak.

- [ ] **Step 6C: If verdict is `candidate-2-stall` (coord_apply_ops_total stopped ticking but process alive).**

  Likely cause: shard worker(s) deadlocked on a lock (typically `merge_prop_index_lock` or `string_indexes_mutex`). Capture a stack trace at cascade time:

  ```bash
  pid=$(pgrep -f "geode serve --data-dir /tmp/geode-edges-contains" | head -1)
  if [ -n "$pid" ]; then
      gdb -p $pid -batch -ex 'thread apply all bt' -ex detach 2>&1 | tee docs/performance/2026-04-25-edges-contains/stacks.txt
  fi
  ```

  Inspect `stacks.txt` for threads blocked in `lockUncancelable` / `pthread_cond_wait`. The lock at the top of multiple worker stacks is the contended one. Document it in `diagnosis.md` and report **DONE_WITH_CONCERNS** with the call-site for a follow-up plan.

- [ ] **Step 6D: If verdict is `candidate-3-rwlock` (mg_rwlock_exclusive_wait_ns_total disproportionate).**

  Find the EXCLUSIVE acquirer that's starving. Run: `grep -n 'rwlock\.lockUncancelable\|rwlock\.lock\b' src/storage/graph_storage_adapter.zig src/graph_store.zig | head -20`. Common starver: persistence/checkpoint thread.

  Without a specific call-site identified by the rwlock telemetry, this sub-task can't proceed mechanically. Report **DONE_WITH_CONCERNS** naming the call-site that the metrics + (optionally) gdb stack-trace point to, for a follow-up plan to apply a fairness/back-off fix.

- [ ] **Step 6E: If verdict is `none-of-the-three`.**

  Stop. Report **DONE_WITH_CONCERNS** with diagnosis.md's detailed findings — the three candidates aren't the cause; brainstorm a new plan.

---

## Phase 4 — Re-validate

### Task 7: Re-run full msft-graph ingest after fix

**Files:**
- Create: `docs/performance/2026-04-25-edges-contains/post-fix-run.log`

- [ ] **Step 7.1: Build release.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 7.2: Adapt the existing `/tmp/run-final-v2.sh` and run.**

  ```bash
  cp /tmp/run-final-v2.sh /tmp/run-postfix-v2.sh
  sed -i 's|phase2-final-run.log|2026-04-25-edges-contains/post-fix-run.log|g' /tmp/run-postfix-v2.sh
  bash /tmp/run-postfix-v2.sh
  ```

  Target wall-clock: ≤ 30 min (a 25%+ improvement over the prior 45-min cap).

- [ ] **Step 7.3: Verify exit criteria.**

  ```bash
  grep wall_clock_s docs/performance/2026-04-25-edges-contains/post-fix-run.log
  # Expected: wall_clock_s=<N> with ingest actually completed (not 2700-cap)

  grep -c '40001' docs/performance/2026-04-25-edges-contains/post-fix-run.log
  # Expected: 0

  grep -c 'retrying file in serial mode' docs/performance/2026-04-25-edges-contains/post-fix-run.log
  # Expected: 0 (or ≤ 1 if a different file cascades)

  grep 'seeded edges' docs/performance/2026-04-25-edges-contains/post-fix-run.log | wc -l
  # Expected: ≥ 5 (we got 4 last time; goal is to exceed 4)

  grep 'seeded edges.*edges_contains' docs/performance/2026-04-25-edges-contains/post-fix-run.log
  # Expected: one matching line — edges_contains MUST complete
  ```

- [ ] **Step 7.4: Commit the evidence.**

  Pass case:

  ```bash
  git add docs/performance/2026-04-25-edges-contains/post-fix-run.log
  git commit -m "docs(perf): post-fix msft-graph run — edges_contains completes (Task 7)"
  ```

  Fail case (`edges_contains` still doesn't complete):

  ```bash
  git add docs/performance/2026-04-25-edges-contains/post-fix-run.log
  git commit -m "docs(perf): post-fix msft-graph run — partial improvement, edges_contains residual (Task 7)"
  ```

  And append a follow-up note to `diagnosis.md` documenting what's still needed.

---

## Self-review results

- **Spec coverage:**
  - Candidate 1 (QUIC flow-control / stream limit) — Task 5.4.4 captures QUIC-layer diagnostics (`flow.control|max.streams|max.data|connection close`); Task 6A applies the targeted fix (raise `max_data` and `max_stream_data`). ✓
  - Candidate 2 (server-side memory or scheduler stall) — Task 5.4.1 + 5.4.2 + 5.4.5 capture server-crash signal, `coord_apply_*` trajectory, `VmRSS`; Tasks 6B / 6C apply targeted fixes. ✓
  - Candidate 3 (mg.rwlock SHARED starvation) — Task 3 wires the wait-time counters; Task 5.4.3 reads them; Task 6D applies the targeted fix. ✓

- **Placeholder scan:** Tasks 6B, 6C, 6D explicitly report `DONE_WITH_CONCERNS` if diagnosis.md doesn't name a specific call-site — that's an acknowledged plan structure for diagnostic-conditional tasks, not a hidden TODO.

- **Type consistency:**
  - `Counter`, `Registry` symbols in `runtime_metrics.zig` (Task 1) referenced consistently in Tasks 2, 3, 4. ✓
  - All counter types are `std.atomic.Value(u64)`. ✓
  - Counter names (`coord_apply_*`, `mg_rwlock_*`) consistent across tasks 2, 3, 4, 5. ✓

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-25-edges-contains-cascade-resolution.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, spec + quality review between, fast iteration on diagnosis-conditional fixes.
2. **Inline execution** — execute tasks in this session using superpowers:executing-plans, batch with checkpoints.

**Which approach?**
