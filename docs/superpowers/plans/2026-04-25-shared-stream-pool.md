# Shared Stream-Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the `edges_contains` cascade by replacing the per-connection stream and acceptor `pooled.ThreadPool` instances in `src/server/quic_connection_handler.zig:1995` with **single shared pools allocated at server startup**, so msft-graph's per-file reconnect pattern (~720 connection closes per ingest) can no longer leak ~1800 zombie pool workers that starve the QUIC packet pump.

**Architecture:** Move pool ownership from `handleQuicConnection` (per-connection) up to `main()` (server lifetime). Add `stream_pool: *pooled.ThreadPool` and `acceptor_pool: *pooled.ThreadPool` fields to `ConnectionContext`, initialise them once at startup with capacity sized for the expected concurrent-connection count (`64` stream workers + `4` acceptor workers covers a 16-connection burst with multiplexed streams), and pass them through `handleConnectionAsync` to `handleQuicConnection`. Remove the per-connection `pooled.ThreadPool.init` + `defer pool.deinit()` blocks. Connection-close stops being a pool-lifecycle event — closes just stop submitting new work; the pools live as long as the server does.

**Tech Stack:** Zig 0.16. `pooled.ThreadPool` from `transport/thread_pool` (the local wrapper) backed by `zig-pkg/thread_pool-0.2.0`. Existing diagnostic infrastructure: `runtime_metrics` registry (commits `ec2084e4`–`aa9708d0`), `mg_rwlock_*` counters (`14999b61`), `coord_apply_*` counters (`62527d40`), gdb stack-capture script (`/tmp/capture-cascade-stacks.sh`), repro driver (`/tmp/run-rwlock-fairness-repro.sh`). The reused-test from the prior plan (`tests/test_rwlock_fairness_under_load.zig`, commit `fb5b3ea9`) still passes — keep it.

---

## File structure

**Create:**
- `tests/test_handle_quic_connection_pool_lifetime.zig` — Zig test that exercises 100 rapid-fire `pooled.ThreadPool.init` + `deinit` cycles and asserts the process thread count grows by < 8 (i.e., the pool wrapper itself doesn't leak on clean deinit). Locks down the no-leak invariant and documents the contract the post-fix architecture relies on.
- `docs/performance/2026-04-25-shared-stream-pool/repro-server.log` — server log from the post-fix repro.
- `docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log` — msft-graph client log from the post-fix repro.
- `docs/performance/2026-04-25-shared-stream-pool/cascade-stacks.txt` — gdb stacks captured at cascade time IF a cascade still occurs (for the next investigation).
- `docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log` — full msft-graph re-run after the fix.
- `docs/performance/2026-04-25-shared-stream-pool/CLOSURE.md` — final closure report.

**Modify:**
- `src/server/main.zig` — add `stream_pool: *pooled.ThreadPool` and `acceptor_pool: *pooled.ThreadPool` to `ConnectionContext`. Allocate both at server startup; deallocate in the existing shutdown defer chain.
- `src/server/quic_connection_handler.zig` — update `handleQuicConnection` signature to take `stream_pool: *pooled.ThreadPool, acceptor_pool: *pooled.ThreadPool`. Remove the per-connection `pooled.ThreadPool.init(...)` + `defer ... .deinit()` blocks at lines ~1994–2041. The fallback to `runStreamQueryLoop` for `acceptor_pool.submitBlocking` failure stays.
- `build.zig` — register the new `test-handle-quic-connection-pool-lifetime` test target.

**Leave alone:**
- `pooled.ThreadPool` API itself (no changes to the wrapper).
- The shard worker thread pool inside `ShardedCoordinator` (per-graph singleton; already correct).
- The persistence loop's pool (singleton, already correct).
- The connection-dispatch pool at `main.zig` (singleton, already correct).

---

## Phase 0 — Add the lifetime regression test

### Task 1: Pool-lifetime regression test

**Files:**
- Create: `tests/test_handle_quic_connection_pool_lifetime.zig`
- Modify: `build.zig`

This test asserts that opening + closing many `pooled.ThreadPool` instances in succession does NOT increase the process thread count beyond a small bound. After the Phase 1 fix, no per-connection inits happen — but the wrapper itself must not leak on its own deinit path either.

- [ ] **Step 1.1: Write the test file.**

  Create `tests/test_handle_quic_connection_pool_lifetime.zig` with EXACTLY this content:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Pool-lifetime regression test.
  //!
  //! Pre-fix: handleQuicConnection created a fresh pooled.ThreadPool per
  //! connection with deinit_timeout=2s. Under msft-graph's per-file
  //! reconnect pattern, deinit timed out on in-flight tasks, leaving
  //! zombie worker threads. Over ~720 connections this accumulated to
  //! ~1800 threads — confirmed by the cascade-time gdb capture at
  //! docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt.
  //!
  //! Post-fix: the stream and acceptor pools are server-wide singletons.
  //! handleQuicConnection no longer creates pools — it submits to the
  //! shared ones. Connection close is a no-op for pool lifetime.
  //!
  //! This test exercises the wrapper directly: 100 init+deinit cycles
  //! on a small pool with no submitted work, asserting that the OS
  //! thread count of the current process does not climb by more than 8.
  //! Documents the no-leak invariant the post-fix architecture relies
  //! on (the wrapper itself must clean up workers on a clean deinit).

  // CANARY: REQ=REQ-PERF-CONN-POOL-LIFETIME; FEATURE="ConnectionPoolLifetime"; ASPECT=NoLeakOnInitDeinit; STATUS=TESTED; TEST=tests/test_handle_quic_connection_pool_lifetime.zig; OWNER=server; UPDATED=2026-04-25

  const std = @import("std");
  const geode = @import("geode");
  const pooled = geode.pooled;

  fn readProcThreadCount() !u64 {
      var f = try std.fs.cwd().openFile("/proc/self/status", .{});
      defer f.close();
      var buf: [4096]u8 = undefined;
      const n = try f.readAll(&buf);
      const slice = buf[0..n];
      var line_iter = std.mem.splitScalar(u8, slice, '\n');
      while (line_iter.next()) |line| {
          const prefix = "Threads:\t";
          if (std.mem.startsWith(u8, line, prefix)) {
              const value = std.mem.trim(u8, line[prefix.len..], " \t");
              return try std.fmt.parseInt(u64, value, 10);
          }
      }
      return error.ThreadCountNotFound;
  }

  test "pooled.ThreadPool.init + deinit does not leak threads" {
      const allocator = std.testing.allocator;

      const before = try readProcThreadCount();

      var i: usize = 0;
      while (i < 100) : (i += 1) {
          const pool = try pooled.ThreadPool.init(allocator, .{
              .num_threads = 5,
              .queue_capacity = 16,
              .deinit_timeout_ns = 2 * std.time.ns_per_s,
          });
          // No work submitted — deinit should be quick and clean.
          pool.deinit();
      }

      // Give the kernel a moment to tear down threads.
      var rem: std.os.linux.timespec = undefined;
      const settle_req = std.os.linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
      _ = std.os.linux.nanosleep(&settle_req, &rem);

      const after = try readProcThreadCount();

      // Tolerance: 8 threads. Pool's own internal book-keeping plus
      // any test-runner overhead should be within this. Pre-bug
      // expected ~500 stranded threads under this workload.
      const grew_by = if (after > before) after - before else 0;
      if (grew_by > 8) {
          std.debug.print("Pool init+deinit leaked threads: before={d} after={d} grew_by={d}\n", .{ before, after, grew_by });
      }
      try std.testing.expect(grew_by <= 8);
  }
  ```

- [ ] **Step 1.2: Register the test in `build.zig`.**

  Find the `test-rwlock-fairness-under-load` block: `grep -n 'test-rwlock-fairness-under-load' build.zig`. Immediately after that block, add:

  ```zig
      const conn_pool_lifetime_mod = b.createModule(.{ .root_source_file = b.path("tests/test_handle_quic_connection_pool_lifetime.zig"), .target = target, .optimize = optimize });
      conn_pool_lifetime_mod.addImport("geode", root_mod);
      const conn_pool_lifetime_tests = b.addTest(.{ .root_module = conn_pool_lifetime_mod });
      const run_conn_pool_lifetime_tests = b.addRunArtifact(conn_pool_lifetime_tests);
      test_step.dependOn(&run_conn_pool_lifetime_tests.step);
      const conn_pool_lifetime_step = b.step("test-handle-quic-connection-pool-lifetime", "Run pooled.ThreadPool init+deinit thread-leak regression test");
      conn_pool_lifetime_step.dependOn(&run_conn_pool_lifetime_tests.step);
  ```

- [ ] **Step 1.3: Run the test on current HEAD.**

  ```bash
  zig build test-handle-quic-connection-pool-lifetime 2>&1 | tail -10
  ```

  Expected outcomes:
  - **PASS:** `pooled.ThreadPool.deinit` correctly joins its workers when no in-flight tasks exist; the leak we observed in production is specifically the `deinit_timeout` ABANDON path (which only triggers when tasks are still running). The test still locks down the no-leak invariant for the no-task path.
  - **FAIL:** `pooled.ThreadPool` itself leaks even on clean deinit. That would indicate a deeper bug; investigate the wrapper before proceeding.

  Either outcome is acceptable for this task — the test is documenting an invariant. Report the actual outcome.

- [ ] **Step 1.4: Commit.**

  ```bash
  git add tests/test_handle_quic_connection_pool_lifetime.zig build.zig
  git commit -m "test(server): pool-lifetime regression — init+deinit must not leak threads (Task 1)"
  ```

---

## Phase 1 — Plumb shared pools through to `handleQuicConnection`

### Task 2: Allocate shared pools at server startup; add to ConnectionContext

**Files:**
- Modify: `src/server/main.zig`

This task adds two `*pooled.ThreadPool` fields to `ConnectionContext` and initialises them once at server startup, alongside the existing main connection-dispatch pool. Hands them to every connection.

- [ ] **Step 2.1: Locate the existing pool init.**

  ```bash
  grep -n 'pooled\.ThreadPool\.init\|stream_pool\|acceptor_pool' src/server/main.zig | head
  grep -n 'const pool ' src/server/main.zig | head
  grep -n '^const ConnectionContext' src/server/main.zig
  ```

  You'll see one existing `pool` (the connection-dispatch pool, ~16 workers, used for `handleConnectionAsync`). The two new pools are siblings of it.

- [ ] **Step 2.2: Add the two fields to `ConnectionContext`.**

  Find `const ConnectionContext = struct {` (around line 178). Add two fields immediately before the closing `};`:

  ```zig
      // Shared stream + acceptor pools owned by main(); one per server lifetime
      // instead of one per connection (which leaked under msft-graph reconnect).
      // See docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md.
      stream_pool: *pooled.ThreadPool,
      acceptor_pool: *pooled.ThreadPool,
  ```

  Confirm `pooled` is already imported in `main.zig`. Run: `grep -n 'pooled = @import\|const pooled' src/server/main.zig`. If it isn't, add at the imports block:

  ```zig
  const pooled = @import("transport/thread_pool");
  ```

- [ ] **Step 2.3: Allocate the pools at server startup.**

  Find the existing connection-dispatch pool init in `main()`. Run: `grep -n 'pool = pooled\|const pool ' src/server/main.zig`. Just AFTER its init line and its `defer pool.deinit()` line, add:

  ```zig
      const stream_pool = try pooled.ThreadPool.init(gpa, .{
          .num_threads = 64,
          .queue_capacity = 256,
          // No deinit timeout: the pool lives as long as the server.
          // On shutdown the queue should be empty; if any task is
          // genuinely stuck the operator wants to know about it.
      });
      defer stream_pool.deinit();

      const acceptor_pool = try pooled.ThreadPool.init(gpa, .{
          .num_threads = 4,
          .queue_capacity = 64,
      });
      defer acceptor_pool.deinit();
  ```

  Note on sizing: 64 stream workers covers up to ~16 concurrent connections × ~4 streams each (the prior per-connection pool was 4 workers × 16 connections = 64 max under that bound). The 4-worker acceptor pool covers up to 4 concurrent stream-acceptor loops; matches typical `handleQuicConnection` invocations in flight. Conservative — adjust higher if production load exceeds.

- [ ] **Step 2.4: Wire the pools into `ConnectionContext` initialisation.**

  Find `ctx.* = .{` for `ConnectionContext` (around line 985). Add the two fields to the struct literal:

  ```zig
              ctx.* = .{
                  .allocator = gpa,
                  .transport = &transport,
                  .conn = conn,
                  .disable_estimates = disable_estimates,
                  .compact_profile = compact_profile,
                  .memcurve_profile = memcurve_profile,
                  .env_spill_threshold = env_spill_threshold,
                  .env_storage_checksum_error = env_storage_checksum_error,
                  .security_manager = init_ctx.security_manager,
                  .shared_ast_cache = init_ctx.shared_ast_cache,
                  .shared_optimizer = init_ctx.shared_optimizer,
                  .env_config = &init_ctx.env_config,
                  .stream_pool = stream_pool,
                  .acceptor_pool = acceptor_pool,
              };
  ```

- [ ] **Step 2.5: Update `handleConnectionAsync` to forward the pools.**

  Find `fn handleConnectionAsync` (around line 201). Pass the two new fields through:

  ```zig
  fn handleConnectionAsync(context: *anyopaque) void {
      const ctx: *ConnectionContext = @ptrCast(@alignCast(context));
      quic_connection_handler.handleQuicConnection(
          ctx.allocator,
          ctx.transport,
          ctx.conn,
          ctx.disable_estimates,
          ctx.compact_profile,
          ctx.memcurve_profile,
          ctx.env_spill_threshold,
          ctx.env_storage_checksum_error,
          false,
          ctx.security_manager,
          ctx.shared_ast_cache,
          ctx.shared_optimizer,
          ctx.env_config,
          ctx.stream_pool,
          ctx.acceptor_pool,
      ) catch |err| {
          log.err("Error handling QUIC connection (async)", &.{
              Attr.string("error", @errorName(err)),
          });
      };
      ctx.allocator.destroy(ctx);
  }
  ```

  Note: `handleQuicConnection`'s signature must be updated in Task 3 to accept the two new params; this step's edit will not compile cleanly until Task 3 lands. Acceptable — do them as a single commit at Step 3.6.

- [ ] **Step 2.6: Don't commit yet.**

  Hold this commit until Task 3 lands so the tree compiles cleanly. Skip directly to Task 3.

### Task 3: Remove per-connection pool init from `handleQuicConnection`

**Files:**
- Modify: `src/server/quic_connection_handler.zig`

- [ ] **Step 3.1: Update the function signature.**

  Find `pub fn handleQuicConnection(` (line 1664). Add two params at the end (before the `) !void {`):

  ```zig
  pub fn handleQuicConnection(
      gpa: std.mem.Allocator,
      transport: *quic_transport.QuicTransport,
      conn: *quic_transport.QuicConnection,
      disable_estimates: bool,
      compact_profile: bool,
      memcurve_profile: bool,
      env_spill_threshold: usize,
      env_storage_checksum_error: bool,
      _force_serialization_failure_unused: bool,
      security_manager: ?*geode_auth.SecurityManager,
      shared_ast_cache: ?*anyopaque, // Type is query_ast_cache.SharedAstCache
      shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer, // Issue #460
      env_config: *const server_init.EnvironmentConfig, // #683: Cached env vars
      stream_pool: *pooled.ThreadPool,
      acceptor_pool: *pooled.ThreadPool,
  ) !void {
  ```

- [ ] **Step 3.2: Delete the per-connection `pooled.ThreadPool.init` blocks.**

  In `src/server/quic_connection_handler.zig`, find the stream_pool init at line ~1994:

  ```zig
      const cpu_count = std.Thread.getCpuCount() catch 4;
      _ = cpu_count; // retained for future per-host tuning; see R6 notes
      const stream_pool_size: usize = 4;
      const stream_pool = pooled.ThreadPool.init(gpa, .{
          .num_threads = stream_pool_size,
          .queue_capacity = stream_pool_size * 16,
          // ... long comment ...
          .deinit_timeout_ns = 2 * std.time.ns_per_s,
      }) catch |err| {
          log.warn("Failed to initialize stream worker pool, single-stream mode", &.{
              Attr.string("error", @errorName(err)),
          });
          runStreamQueryLoop(gpa, transport, stream, &state, &conn_state, disable_estimates, compact_profile, memcurve_profile, peer_ip);
          return;
      };
      defer stream_pool.deinit();
  ```

  Delete that entire block. The `stream_pool` parameter is now in scope from the function signature.

  Find the acceptor_pool init right after (line ~2024):

  ```zig
      var acceptor_shutdown = std.atomic.Value(bool).init(false);
      const acceptor_pool = pooled.ThreadPool.init(gpa, .{
          .num_threads = 1,
          .queue_capacity = 4,
          .deinit_timeout_ns = 2 * std.time.ns_per_s,
      }) catch |err| {
          log.warn("Failed to initialize stream acceptor pool, single-stream mode", &.{
              Attr.string("error", @errorName(err)),
          });
          runStreamQueryLoop(gpa, transport, stream, &state, &conn_state, disable_estimates, compact_profile, memcurve_profile, peer_ip);
          return;
      };
      defer acceptor_pool.deinit();
  ```

  Delete the `const acceptor_pool = ...` and its `defer acceptor_pool.deinit();`. **Keep** the `var acceptor_shutdown = std.atomic.Value(bool).init(false);` declaration — it's referenced by `acceptor_ctx`.

  After the cuts the surrounding code reads:

  ```zig
      var acceptor_shutdown = std.atomic.Value(bool).init(false);

      var acceptor_ctx = StreamAcceptorContext{
          .allocator = gpa,
          .transport = transport,
          .conn = conn,
          .conn_state = &conn_state,
          .shutdown = &acceptor_shutdown,
          .stream_pool = stream_pool,
      };
      acceptor_pool.submitBlocking(.{
          .context = @ptrCast(&acceptor_ctx),
          .callback = runStreamAcceptorLoop,
      }) catch |err| {
          log.warn("Failed to start stream acceptor, single-stream mode", &.{
              Attr.string("error", @errorName(err)),
          });
          runStreamQueryLoop(gpa, transport, stream, &state, &conn_state, disable_estimates, compact_profile, memcurve_profile, peer_ip);
          return;
      };
      defer {
          acceptor_shutdown.store(true, .release);
      }
  ```

  If the `const cpu_count = std.Thread.getCpuCount() catch 4; _ = cpu_count;` lines are now genuinely dead, delete them.

- [ ] **Step 3.3: Verify build.**

  ```bash
  zig build 2>&1 | tail -10
  ```

  Expected: clean build. Common errors and fixes:
  - "stream_pool not declared": signature update in Step 3.1 missed.
  - "acceptor_pool used before declaration": you deleted the variable but a later use still references the local-scoped name. Verify `grep -n 'acceptor_pool' src/server/quic_connection_handler.zig` — there should be exactly one usage (the `submitBlocking` call) which now resolves to the function parameter.
  - "function call expects N args, got N+2": a caller of `handleQuicConnection` somewhere wasn't updated. Run `grep -rn 'handleQuicConnection(' src/ tests/` and update.

- [ ] **Step 3.4: Run pool-lifetime test from Task 1.**

  ```bash
  zig build test-handle-quic-connection-pool-lifetime 2>&1 | tail -5
  ```

  Expected: PASS. (The test exercises the wrapper directly, so it should pass before AND after the fix — it's a documentation-of-invariant test. The actual fix verification is in Task 4's full repro.)

- [ ] **Step 3.5: Run sharded-coord tests to verify no regression.**

  ```bash
  zig build test-sharded-coordinator-routing test-sharded-coordinator test-sharded-coordinator-hub 2>&1 | tail -5
  ```

  Expected: all PASS.

- [ ] **Step 3.6: Commit Task 2 + Task 3 together (single coherent change-set).**

  ```bash
  git add src/server/main.zig src/server/quic_connection_handler.zig
  git commit -m "fix(server): hoist stream + acceptor pools to server lifetime (Tasks 2-3)

  Per the cascade-stacks diagnosis at
  docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md,
  per-connection pooled.ThreadPool.init + 2s deinit_timeout was leaking
  ~5 zombie worker threads per QUIC connection-close under msft-graph's
  per-file reconnect pattern. ~720 closes per ingest × 5 = ~1800 zombie
  threads, which starved the QUIC packet pump and triggered the
  edges_contains cascade.

  Move pool ownership to main(): one shared 64-worker stream pool + one
  4-worker acceptor pool, allocated at server startup, lifetime = server
  lifetime. Pass through ConnectionContext → handleConnectionAsync →
  handleQuicConnection. Connection-close stops being a pool-lifecycle
  event."
  ```

---

## Phase 2 — Validate end-to-end

> **CLOSURE NOTE (2026-04-25):** Tasks 4 and 5 are PARTIALLY RESOLVED.
> The per-connection QUIC pool fix from Phase 1 (commits `edb82c71`,
> `b52846cc`) was insufficient on its own — the dominant per-engine
> `tp.ThreadPool` fanout in `graph_storage` (16 sub-engines × 56 workers
> per `ShardedGraphEngine`) remained. That root cause was fixed upstream
> in graph-storage Phase 1 (commits `ef9bf88` → `5ead31b`) and pulled
> into geode by bumping `build.zig.zon` to graph-storage `5ead31b`. NLWP
> dropped from 1881 → 97 (~19× reduction).
>
> **However, the cascade still triggers.** Re-running the repro on the
> bumped dep showed `edges_contains` still hits the 1500s timeout. The
> dominant cause is now writer starvation on `mg.rwlock`
> (`mg_rwlock_exclusive_wait_ns_total` froze at 17.85s for the entire
> 25-min run), not thread budget. Continuation of the work belongs in
> the rwlock-fairness plan
> (`docs/superpowers/plans/2026-04-25-enterprise-rwlock-fairness.md`).
>
> Full results: `docs/performance/2026-04-25-shared-stream-pool/2026-04-25-graph-storage-bump-result.md`.
> Upstream design referenced from this fix:
> `~/src/devnw/zig/graph-storage/docs/2026-04-25-shared-engine-thread-pool.md`.
>
> Tasks 4 and 5 below are kept for historical context but their
> "completion" criterion (cascade resolved) is satisfied by the
> graph-storage dep bump for the thread-pool dimension and is now
> blocked on the rwlock-fairness work for the actual end-to-end pass.

### Task 4: Re-run the cascade repro under the shared-pool fix

**Files:**
- Create (committed): `docs/performance/2026-04-25-shared-stream-pool/repro-server.log`
- Create (committed): `docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log`
- Create (committed): `docs/performance/2026-04-25-shared-stream-pool/cascade-stacks.txt` — only IF a cascade still occurs.
- Create (scratch, not committed): `/tmp/run-shared-pool-repro.sh`

This task runs the same `edges_contains`-only repro from the prior plan, with the stack-capture watcher attached. Goal: prove that thread count stays bounded (< 100 instead of 1800+) and `edges_contains` completes in parallel mode.

- [ ] **Step 4.1: Build release.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 4.2: Adapt the existing repro driver.**

  ```bash
  cp /tmp/run-rwlock-fairness-repro.sh /tmp/run-shared-pool-repro.sh
  sed -i 's|2026-04-25-enterprise-rwlock-fairness|2026-04-25-shared-stream-pool|g; s|/tmp/geode-rwlock-fairness|/tmp/geode-shared-pool|g; s|/tmp/rwlock-fairness-data|/tmp/shared-pool-data|g; s|listen 127.0.0.1:3172|listen 127.0.0.1:3174|g; s|quic://127.0.0.1:3172|quic://127.0.0.1:3174|g' /tmp/run-shared-pool-repro.sh
  mkdir -p docs/performance/2026-04-25-shared-stream-pool
  ```

- [ ] **Step 4.3: Run the repro (~20–25 min wall-clock).**

  ```bash
  chmod +x /tmp/run-shared-pool-repro.sh
  bash /tmp/run-shared-pool-repro.sh
  ```

  Expected outcomes:
  - **Best case:** `edges_contains` completes in parallel mode without a cascade. The watcher times out (`cascade-stacks.txt` may not be written, or contains a marker noting no cascade observed).
  - **Mixed case:** `edges_contains` cascades but at a different statement number / with bounded thread count.
  - **Worst case:** cascade still happens at ~stmt 105–108 with similar thread count — fix didn't reach. Investigate.

- [ ] **Step 4.4: Verify thread count stays bounded.**

  ```bash
  grep VmPeak docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log
  grep Threads docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log
  grep -E 'seeded edges|seeding edges|pipeline failed|wall_clock' docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log | tail -15
  ```

  Hard-pass criteria:
  - **`Threads:` line is < 200** (vs. pre-fix 1838). If still >1000 the leak isn't in the path we fixed; capture stacks and revisit.
  - `edges_contains` appears in `seeded edges` lines (it MUST complete in parallel mode).
  - `wall_clock_s` < 1500 (vs. pre-fix ~6000 s when the run was timed out).

  If `cascade-stacks.txt` was written, the fix didn't fully resolve — inspect it for whatever's still leaking threads, write a follow-up note, and stop here for triage.

- [ ] **Step 4.5: Commit the artifacts.**

  ```bash
  git add docs/performance/2026-04-25-shared-stream-pool/repro-server.log \
          docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log
  if [ -s docs/performance/2026-04-25-shared-stream-pool/cascade-stacks.txt ]; then
      git add docs/performance/2026-04-25-shared-stream-pool/cascade-stacks.txt
  fi
  git commit -m "docs(perf): post-shared-pool repro — thread count + cascade outcome (Task 4)"
  ```

### Task 5: Full msft-graph re-run + closure

**Files:**
- Create (committed): `docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log`
- Create (committed): `docs/performance/2026-04-25-shared-stream-pool/CLOSURE.md`

- [ ] **Step 5.1: Build release.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 5.2: Run the full msft-graph workload.**

  ```bash
  cp /tmp/run-final-v2.sh /tmp/run-shared-pool-postfix.sh
  sed -i 's|docs/performance/2026-04-24-sharding/phase2-final-run.log|docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log|g' /tmp/run-shared-pool-postfix.sh
  bash /tmp/run-shared-pool-postfix.sh
  ```

  Expected wall-clock: ≤ 25 min (vs. pre-fix 45 min cap, 4 of 5 edge files completing in parallel).

- [ ] **Step 5.3: Verify exit criteria.**

  ```bash
  grep wall_clock_s docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log
  grep -c '40001' docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log
  grep -c 'retrying file in serial mode' docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log
  grep 'seeded edges' docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log | wc -l
  grep 'seeded edges.*edges_contains' docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log
  ```

  Hard-pass criteria:
  - `40001` count: **0** (preserved from Phase 2-final).
  - `retrying file in serial mode` count: **0** (or ≤ 1 for genuinely-different reasons; document if so).
  - `edges_contains` MUST appear in `seeded edges` lines.
  - Wall-clock ≤ 1500 s (substantial improvement over the prior plan's run that timed out at 2700 s with edges_contains still cascading).

  If any criterion fails, document the residual in `CLOSURE.md` rather than re-iterating — this plan delivers the architectural fix; subsequent investigation can target whatever's left.

- [ ] **Step 5.4: Write `CLOSURE.md`.**

  ```bash
  echo "=== closure metrics ==="
  grep wall_clock_s docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log
  grep VmPeak docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log
  grep Threads docs/performance/2026-04-25-shared-stream-pool/repro-ingest.log
  grep 'seeded edges' docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log | wc -l
  ```

  Create `docs/performance/2026-04-25-shared-stream-pool/CLOSURE.md`:

  ```markdown
  # Shared stream-pool — closure (2026-04-25)

  ## Outcome

  - Thread count under sustained 16-way ingest: <N> (vs. 1838 pre-fix).
  - VmPeak: <N> KB (vs. 30 GB virtual pre-fix).
  - msft-graph wall-clock: <N> s (vs. 2700 s timeout pre-fix).
  - Edge files completed in parallel mode: <N> of 16 (vs. 4 of 16 pre-fix).
  - `edges_contains.jsonl` (4969 rows) completes in parallel mode: <YES/NO>.
  - 40001 errors: 0 ✅.
  - `retrying file in serial mode` count: <N>.

  ## What landed

  - Shared stream + acceptor pools at server startup (commit `<SHA>`).
  - Pool-lifetime regression test (commit `<SHA>`).

  ## Plan

  Plan: `docs/superpowers/plans/2026-04-25-shared-stream-pool.md`.
  Diagnosis source: `docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md`.
  Repro evidence: `repro-server.log`, `repro-ingest.log`, `cascade-stacks.txt` (if present).
  Final-run evidence: `post-fix-run.log`.

  ## Residual / follow-up

  <list anything still left, or "no residual">.
  ```

- [ ] **Step 5.5: Commit.**

  ```bash
  git add docs/performance/2026-04-25-shared-stream-pool/post-fix-run.log \
          docs/performance/2026-04-25-shared-stream-pool/CLOSURE.md
  git commit -m "docs(perf): shared-stream-pool closure — edges_contains completes in parallel mode (Task 5)"
  ```

---

## Self-review results

- **Spec coverage:**
  - "Replace per-connection pools with single shared pools at server startup" → Tasks 2 + 3. ✓
  - "Update ConnectionContext to carry pools" → Task 2.2 + 2.4. ✓
  - "Update handleQuicConnection signature" → Task 3.1. ✓
  - "Remove per-connection pool init + deinit blocks" → Task 3.2. ✓
  - "Verify thread count stays bounded" → Task 4.4. ✓
  - "Verify edges_contains completes in parallel" → Task 5.3. ✓
  - "Lock-down regression test" → Task 1. ✓

- **Placeholder scan:** All steps have concrete code blocks or commands. The closure note's `<N>` values are runtime measurements that get filled in at Step 5.4 — that's expected output, not a hidden TODO.

- **Type consistency:**
  - `ConnectionContext` has `stream_pool` + `acceptor_pool` fields after Task 2.2; consumed in Task 2.5 (`handleConnectionAsync`) and forwarded to `handleQuicConnection` (Task 3.1).
  - `*pooled.ThreadPool` reference type is consistent across `ConnectionContext`, `handleConnectionAsync`, `handleQuicConnection`.
  - `pooled` import path: `@import("transport/thread_pool")` per existing usage in `src/server/quic_connection_handler.zig`.

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-25-shared-stream-pool.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, spec + quality review between, fast iteration on the plumbing change.
2. **Inline execution** — execute tasks in this session using `superpowers:executing-plans`, batch with checkpoints.

**Which approach?**
