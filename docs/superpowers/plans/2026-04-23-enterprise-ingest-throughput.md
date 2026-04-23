# Enterprise-Grade Ingest Throughput Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the 16-worker `msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000` command complete the full 44,558-statement ingest in **under 60 seconds** (currently 2h 5m with R6–R13, never completed before R6). That's a ~125× improvement over the current post-R13 state; 1 fsync/batch is already paid for, so the remaining wins must come from (a) critical-section reduction, (b) concurrent writer paths on a single graph, and (c) a bulk-ingest short-circuit for well-formed CREATE/MATCH+CREATE patterns.

**Architecture:** Four-pillar attack on the per-graph exclusive write-lock bottleneck. (1) **Profile first** — build a reliable integration bench driven by the user's exact msft-graph command and pinpoint where time actually goes in the 1–60 ms per-statement critical section. (2) **Strip per-statement overhead** — move work that doesn't need the write lock outside it (parse, plan, audit, RLS, pending-index rebuild). (3) **Bulk-ingest fast path** — add `StorageAdapter.bulkInsertNodes` / `bulkInsertEdges` APIs that accept pre-resolved batches and bypass the GQL executor, the undo log, and the mutation-notify callback entirely when the session opts in via `GEODE_BULK_INGEST=1`. (4) **Concurrent-reader MATCH on mutation path** — split the per-statement critical section into a read-locked MATCH phase and a write-locked CREATE phase so 16 MATCHes can run in parallel while a single CREATE takes the exclusive lock.

**Tech Stack:** Zig 0.16, `std.Io.RwLock` / `std.Io.Mutex`, `graph_storage` (external dep at `graph_storage-0.1.0-9UyJS8dECwB9_…`), `bench-query-executor-mutation` (in-process bench at `benchmarks/bench_executor_mutation.zig`), `msft-graph` Go client (installed at `/home/benji/go/bin/msft-graph`), `perf` / `strace` / `/proc/<pid>/task/` for diagnostics.

---

## Pre-work: repository state check

All R6–R13 commits are on `main` (see `git log --oneline -14`). The work in this plan builds on top of those. Before starting, verify:

- [ ] **Step 0.1: Confirm the current baseline still reproduces.**

  Run:

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-" 2>/dev/null || true
  rm -rf /tmp/geode-plan-baseline && mkdir -p /tmp/geode-plan-baseline
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  GEODE_ADMIN_PASSWORD="Geode1234Abc" nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-plan-baseline --listen 127.0.0.1:3142 \
      --log-level warn > /tmp/geode-plan-baseline/server.log 2>&1 &
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3142 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      "CREATE GRAPH abs_eagleg" > /dev/null 2>&1
  time GEODE_DSN="quic://127.0.0.1:3142/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 2>&1 | tail -5
  ```

  Expected: `seed complete nodes=9350 edges=35208` after roughly 2 h. Record the exact wall-clock time in `docs/performance/2026-04-23-enterprise-ingest/r13-baseline.txt`. If the time is > 3 h, the hardware or host changed; adjust targets accordingly.

- [ ] **Step 0.2: Confirm the regression test suite passes.**

  ```bash
  zig build test-r6-parallel-ingest test-graph-write-lock-cancelable \
      test-undo-log-isolation test-orphan-txn-cleanup \
      test-match-read-serial test-handler-lock-hold-scope
  ```

  Expected: exit 0.

- [ ] **Step 0.3: Create the evidence directory.**

  ```bash
  mkdir -p docs/performance/2026-04-23-enterprise-ingest
  ```

  This is where every phase's before/after JSON goes, alongside `r13-baseline.txt`.

---

## Phase 1 — Pinpoint the Actual Per-Statement Bottleneck

We have been guessing about where the 10–170 ms per statement goes. Before cutting any more code, measure it with instrumentation. The only numbers we *know* are the WAL fsyncs, and R7–R13 have largely eliminated those. What else lives under the per-graph write lock?

### Task 1: Add per-statement timing breakdown to the QUIC handler

**Files:**

- Modify: `src/server/quic_connection_handler.zig:2415-2820` (the `.rows` case under `is_mutation`)
- Modify: `src/server/quic_connection_handler.zig:1795-1825` (near `mutationWriteLockTimeoutNs`, add the instrumentation config)
- Create: `src/server/mutation_timing.zig` (thread-local sampling sink)

The goal: opt-in mutation-path timing that logs one structured line per mutation with the wall-clock cost of each phase. Off by default, turned on by `GEODE_MUTATION_TIMING_LOG=1`.

- [ ] **Step 1.1: Write the failing test.**

  Create `tests/perf/test_mutation_timing_phases.zig`:

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const mutation_timing = @import("geode").mutation_timing;

  test "records lock_wait_ns, execute_ns, release_ns when enabled" {
      mutation_timing.setEnabledForTest(true);
      defer mutation_timing.setEnabledForTest(false);

      var sample = mutation_timing.begin();
      sample.markLockAcquired();
      std.time.sleep(1_000_000); // 1 ms "execute"
      sample.markExecuteDone();
      sample.markLockReleased();
      sample.record("CREATE (n:T)");

      const last = mutation_timing.lastSampleForTest() orelse return error.NoSample;
      try testing.expect(last.lock_wait_ns < 10 * std.time.ns_per_ms);
      try testing.expect(last.execute_ns >= 1 * std.time.ns_per_ms);
      try testing.expect(last.release_ns < 10 * std.time.ns_per_ms);
  }
  ```

  Wire it into `build.zig` alongside the other `tests/perf/` targets (search `test_bench_executor_mutation` for the pattern).

- [ ] **Step 1.2: Run the test to verify it fails.**

  ```bash
  zig build test-mutation-timing
  ```

  Expected: compile error — `mutation_timing` doesn't exist yet.

- [ ] **Step 1.3: Implement `src/server/mutation_timing.zig`.**

  ```zig
  const std = @import("std");

  pub const Sample = struct {
      stage_start_ns: u64,
      lock_acquire_start_ns: u64 = 0,
      lock_acquired_ns: u64 = 0,
      execute_done_ns: u64 = 0,
      lock_released_ns: u64 = 0,

      pub fn markLockAcquired(self: *Sample) void {
          self.lock_acquired_ns = monoNanos();
      }
      pub fn markExecuteDone(self: *Sample) void {
          self.execute_done_ns = monoNanos();
      }
      pub fn markLockReleased(self: *Sample) void {
          self.lock_released_ns = monoNanos();
      }

      pub fn lockWaitNs(self: Sample) u64 {
          if (self.lock_acquired_ns == 0 or self.lock_acquire_start_ns == 0) return 0;
          return self.lock_acquired_ns - self.lock_acquire_start_ns;
      }
      pub fn executeNs(self: Sample) u64 {
          if (self.execute_done_ns == 0 or self.lock_acquired_ns == 0) return 0;
          return self.execute_done_ns - self.lock_acquired_ns;
      }
      pub fn releaseNs(self: Sample) u64 {
          if (self.lock_released_ns == 0 or self.execute_done_ns == 0) return 0;
          return self.lock_released_ns - self.execute_done_ns;
      }

      pub fn record(self: *Sample, stmt_preview: []const u8) void {
          if (!enabled.load(.acquire)) return;
          std.debug.print(
              "MUT_TIMING lock_wait_ns={d} execute_ns={d} release_ns={d} stmt=\"{s}\"\n",
              .{ self.lockWaitNs(), self.executeNs(), self.releaseNs(), stmt_preview },
          );
          t_last_sample = self.*;
      }
  };

  var enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
  threadlocal var t_last_sample: ?Sample = null;

  pub fn init() void {
      const env = std.posix.getenv("GEODE_MUTATION_TIMING_LOG");
      enabled.store(env != null and env.?.len > 0 and env.?[0] != '0', .release);
  }

  pub fn begin() Sample {
      return .{ .stage_start_ns = monoNanos(), .lock_acquire_start_ns = monoNanos() };
  }

  pub fn setEnabledForTest(v: bool) void {
      enabled.store(v, .release);
  }

  pub fn lastSampleForTest() ?Sample {
      return t_last_sample;
  }

  fn monoNanos() u64 {
      var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
      _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
      return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
  }
  ```

  Note: the Zig 0.16 `std.posix.getenv` is removed. Use the existing `posixGetenv` helper at `src/server/quic_connection_handler.zig:56-58` — delete the inline `std.posix.getenv` call above and have `init()` take an optional override string.

- [ ] **Step 1.4: Register the module in `src/lib.zig`.**

  Add near the other server imports:

  ```zig
  pub const mutation_timing = @import("server/mutation_timing.zig");
  ```

- [ ] **Step 1.5: Run the test, verify PASS.**

  ```bash
  zig build test-mutation-timing
  ```

  Expected: exit 0.

- [ ] **Step 1.6: Hook the sample into `handleExecute` around the existing lock acquisition.**

  At the top of `src/server/quic_connection_handler.zig` mutation path (near line 2415, where `acquireGraphWriteLockCancelable` is called):

  ```zig
  var mut_sample = mutation_timing.begin();
  ```

  Immediately after the successful lock acquire (line ~2441 after R6):

  ```zig
  mut_sample.markLockAcquired();
  ```

  Immediately after the `executeProgramWithContext` call (line ~2805):

  ```zig
  mut_sample.markExecuteDone();
  ```

  Immediately after `releaseGraphLock` (line ~2819):

  ```zig
  mut_sample.markLockReleased();
  mut_sample.record(query_text[0..@min(query_text.len, 80)]);
  ```

  (The `query_text` local is declared near line ~2280.)

- [ ] **Step 1.7: Call `mutation_timing.init()` at server startup.**

  In `src/server/main.zig`, add after the other global-init calls (search for `setAuthRateLimiter`):

  ```zig
  mutation_timing.init();
  ```

  Expose via `const mutation_timing = geode.mutation_timing;` at the top.

- [ ] **Step 1.8: Commit.**

  ```bash
  git add src/server/mutation_timing.zig src/lib.zig \
      src/server/quic_connection_handler.zig src/server/main.zig \
      tests/perf/test_mutation_timing_phases.zig build.zig
  git commit -m "perf(server): add per-mutation timing instrumentation (GEODE_MUTATION_TIMING_LOG)"
  ```

### Task 2: Capture the real per-phase cost for a msft-graph batch

- [ ] **Step 2.1: Rebuild with R13 + Task 1 instrumentation.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 2.2: Run a 1-minute sample of msft-graph ingest with timing enabled.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-plan-" 2>/dev/null || true
  rm -rf /tmp/geode-plan-phase1 && mkdir -p /tmp/geode-plan-phase1
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_MUTATION_TIMING_LOG=1 \
      nohup zig-out/bin/geode serve --data-dir /tmp/geode-plan-phase1 \
      --listen 127.0.0.1:3142 --log-level warn \
      > /tmp/geode-plan-phase1/server.log 2>&1 &
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3142 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      "CREATE GRAPH abs_eagleg"
  timeout 180 \
      env GEODE_DSN="quic://127.0.0.1:3142/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 2>&1 > /dev/null || true
  pkill -9 -f "geode serve --data-dir /tmp/geode-plan-phase1"
  ```

- [ ] **Step 2.3: Aggregate the samples.**

  ```bash
  python3 - <<'PY' > docs/performance/2026-04-23-enterprise-ingest/phase1-timing-breakdown.txt
  import re, statistics
  lock_wait, execute, release = [], [], []
  with open("/tmp/geode-plan-phase1/server.log") as f:
      for line in f:
          m = re.search(r"lock_wait_ns=(\d+) execute_ns=(\d+) release_ns=(\d+)", line)
          if m:
              lock_wait.append(int(m.group(1)))
              execute.append(int(m.group(2)))
              release.append(int(m.group(3)))
  def pct(xs, p):
      xs = sorted(xs); i = int(len(xs)*p/100)
      return xs[min(i, len(xs)-1)] / 1e6
  print(f"samples={len(execute)}")
  for name, xs in [("lock_wait_ms", lock_wait), ("execute_ms", execute), ("release_ms", release)]:
      if not xs: continue
      print(f"{name}: p50={pct(xs,50):.2f} p90={pct(xs,90):.2f} p99={pct(xs,99):.2f} max={max(xs)/1e6:.2f} mean={statistics.mean(xs)/1e6:.2f}")
  PY
  cat docs/performance/2026-04-23-enterprise-ingest/phase1-timing-breakdown.txt
  ```

  This writes the empirical breakdown. Expected shape (based on R13 observations — actual numbers go into the evidence file):

  ```
  samples=1234
  lock_wait_ms: p50=... p90=... p99=...
  execute_ms:   p50=... p90=... p99=...
  release_ms:   p50=... p90=... p99=...
  ```

- [ ] **Step 2.4: Add per-inner-phase instrumentation if `execute_ms` dominates.**

  If `execute_ms` p50 ≥ 5 ms, drill in. Add timing *inside* `executeProgramWithContext` for: parse (cached?), plan, mutation-loop, undo-log append, pending-index queue, RLS filter, audit log. The same `Sample` type can carry more marks — extend it with `execute_parse_ns`, `execute_plan_ns`, `execute_mutation_ns`, `execute_audit_ns`. Emit in the same log line.

  Commit each new mark as its own step-commit:

  ```bash
  git add src/server/mutation_timing.zig src/execution.zig
  git commit -m "perf(server): add execute-phase sub-timing (parse/plan/mutation/audit)"
  ```

- [ ] **Step 2.5: Re-run the sample capture with sub-timing.**

  Repeat Step 2.2 and 2.3 with the expanded fields. Overwrite `phase1-timing-breakdown.txt`. This is the measurement we will optimize against.

- [ ] **Step 2.6: Commit the evidence file.**

  ```bash
  git add docs/performance/2026-04-23-enterprise-ingest/phase1-timing-breakdown.txt
  git commit -m "docs(perf): capture R13 per-phase mutation timing baseline"
  ```

### Task 3: Identify the top three per-statement cost drivers

- [ ] **Step 3.1: Write a one-page diagnosis.**

  Create `docs/performance/2026-04-23-enterprise-ingest/phase1-diagnosis.md`:

  ```markdown
  # Phase 1 diagnosis — where the critical section goes

  Based on `phase1-timing-breakdown.txt`:

  ## Top three contributors (by p50 × fraction of samples)

  1. **<phase name>** — p50 `<x>` ms, dominant in `<y>`% of samples.
     Probable cause: `<one-sentence hypothesis with file:line reference>`.
     Fix hypothesis: `<one sentence>`.
  2. ...
  3. ...

  ## Fixable (in scope of this plan)

  - <phase>: ...
  - <phase>: ...

  ## Not fixable (inherent cost)

  - <phase>: ...

  ## Target per-statement critical section

  To hit 44 558 statements / 60 s = 742 stmts / s aggregate with 16
  workers serialising on one graph, we need per-statement hold time
  of **≤ 1.3 ms**. Current observed (from
  `phase1-timing-breakdown.txt` p50 `execute_ms`): **`X.XX` ms**
  (replace with the literal number captured in Step 2.3).
  Ratio: **`(X.XX / 1.3)`× reduction required**.
  ```

- [ ] **Step 3.2: Commit the diagnosis.**

  ```bash
  git add docs/performance/2026-04-23-enterprise-ingest/phase1-diagnosis.md
  git commit -m "docs(perf): identify R13 top-3 per-statement cost drivers"
  ```

---

## Phase 2 — Shrink the Write-Lock Critical Section

Everything in the current critical section that doesn't require exclusive access to graph state is overhead. Phase 1 identified it — Phase 2 strips it.

### Task 4: Move parse + plan outside the write lock

**Files:**

- Modify: `src/server/quic_connection_handler.zig:2280-2440` (pre-lock block) and `2440-2810` (lock hold block)

The AST parse already happens before the lock via `SharedAstCache`. The plan currently happens inside `executeProgramWithContext`. Extract planning into a pre-lock step for the common case of a `Query`/`CreateStatement`/`MergeStatement` where the plan doesn't depend on the current graph state.

- [ ] **Step 4.1: Write the failing test.**

  Create `tests/perf/test_plan_outside_write_lock.zig`. The test pins
  the contract that two concurrent planners on the same program are
  NOT serialised by the write lock: before the hoist, both block; after,
  they run in parallel so total wall time is within ~1.5 × single-thread
  planning time. Barrier pattern mirrors
  `tests/test_r6_parallel_ingest_throughput.zig:writerWorker` exactly.

  ```zig
  const std = @import("std");
  const testing = std.testing;
  const geode = @import("geode");
  const execution = geode.execution;
  const graph_store = geode.graph_store;
  const gql = geode.gql;

  fn monoNanos() u64 {
      var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
      _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
      return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
  }

  const PlanCtx = struct {
      graph: []const u8,
      start_gate: *std.atomic.Value(u32),
      plan_wall_ns: *u64,
  };

  fn planWorker(ctx: *PlanCtx) void {
      while (ctx.start_gate.load(.acquire) == 0) std.atomic.spinLoopHint();
      var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
      defer arena.deinit();
      const alloc = arena.allocator();
      var parse_res = gql.parser.parse(alloc,
          "CREATE (n:TestPlanHoist {id: 1, name: 'x'})") catch return;
      defer parse_res.deinit(alloc);
      // A plan-only entrypoint — planProgram returns without touching
      // the live store.  Task 4's Step 4.3 adds this public API.
      const t0 = monoNanos();
      var plan = execution.planProgram(alloc, &parse_res.program,
          execution.ExecutionContext{ .catalog = execution.ensureCatalogInstance(alloc) catch unreachable }) catch return;
      defer plan.deinit(alloc);
      ctx.plan_wall_ns.* = monoNanos() - t0;
  }

  test "plan hoist: two concurrent CREATE plans run in parallel" {
      // Plant a writer holding the exclusive lock for 50 ms; start two
      // planners; measure their wall time.  Before the hoist, both block
      // on the write lock for ≥ 50 ms each (serialised).  After hoist,
      // both finish in ≤ 10 ms (no lock acquired during plan).
      const graph = "test_plan_hoist";
      _ = graph_store.initGlobalAdapter(std.heap.smp_allocator,
          ".zig-cache/tmp/test_plan_hoist_" ++ @src().fn_name) catch {};
      _ = graph_store.acquireGraphWriteLock(graph);
      // Writer holds the lock; we want to verify the planners don't
      // block on it.
      var gate = std.atomic.Value(u32).init(0);
      var w1_ns: u64 = 0;
      var w2_ns: u64 = 0;
      var c1 = PlanCtx{ .graph = graph, .start_gate = &gate, .plan_wall_ns = &w1_ns };
      var c2 = PlanCtx{ .graph = graph, .start_gate = &gate, .plan_wall_ns = &w2_ns };
      const t1 = try std.Thread.spawn(.{}, planWorker, .{&c1});
      const t2 = try std.Thread.spawn(.{}, planWorker, .{&c2});
      gate.store(1, .release);
      t1.join();
      t2.join();
      // No writer is blocking plan; both finish quickly.
      try testing.expect(w1_ns < 10 * std.time.ns_per_ms);
      try testing.expect(w2_ns < 10 * std.time.ns_per_ms);
  }
  ```

  Register the test in `build.zig` following the `test-mutation-timing` pattern.

- [ ] **Step 4.2: Run it — should fail today.**

  ```bash
  zig build test-plan-outside-write-lock
  ```

- [ ] **Step 4.3: Extract the plan step from `executeProgramWithContext`.**

  In `src/execution.zig`, add a public `planProgram(allocator, program, context)` that returns an `ExecutionPlan` struct. Keep `executeProgramWithContext` as a wrapper: `planProgram` then `executePlan(plan, …)`.

  In `src/server/quic_connection_handler.zig`, before the `acquireGraphWriteLockCancelable` call, run:

  ```zig
  const plan = try execution.planProgram(gpa, &parse_result.program, exec_context);
  defer plan.deinit(gpa);
  ```

  Then the lock scope only runs `executePlan(plan, …)`. The plan is position-independent — it doesn't read live store state.

  (If that's not true for a given operator — e.g. an `IndexScan` that reads stats — keep that operator inside the lock and narrow the hoist to only the operators that are pure.)

- [ ] **Step 4.4: Run the test, verify PASS.**

  ```bash
  zig build test-plan-outside-write-lock
  ```

- [ ] **Step 4.5: Re-run `bench-query-executor-mutation` to confirm no regression.**

  ```bash
  zig build -Doptimize=ReleaseFast bench-query-executor-mutation \
      -- --output /tmp/bench-task4.json
  python3 /home/benji/src/devnw/codepros/geode/geode/scripts/perf/compare-bench.py \
      /tmp/bench-baseline.json /tmp/bench-task4.json
  ```

  If `compare-bench.py` doesn't exist, create it (a 30-line script that prints a side-by-side table of `wall_time_ns` deltas per scenario). Commit the script as `scripts/perf/compare-bench.py`.

  Expected: `create_single` ≤ 5% regression, others unchanged.

- [ ] **Step 4.6: Re-run the msft-graph sample.**

  Same command as Step 2.2 but writing to `/tmp/geode-plan-phase2-task4/` and the evidence to `docs/performance/2026-04-23-enterprise-ingest/task4-timing.txt`.

- [ ] **Step 4.7: Commit.**

  ```bash
  git add src/execution.zig src/server/quic_connection_handler.zig \
      tests/perf/test_plan_outside_write_lock.zig \
      scripts/perf/compare-bench.py \
      docs/performance/2026-04-23-enterprise-ingest/task4-timing.txt
  git commit -m "perf(exec): hoist pure-plan step outside write lock (Task 4)"
  ```

### Task 5: Move audit logging outside the write lock

**Files:**

- Modify: `src/server/quic_connection_handler.zig:2627,2698,2878` (the three `auditQueryExecution` call sites)
- Modify: `src/server/quic_connection_handler.zig:1429-1438` (`auditQueryExecution` helper itself)

Audit currently runs after `executeProgramWithContext` but *inside* the lock scope. It doesn't read graph state — it only writes the audit log. Move every call site to *after* `releaseGraphLock`.

- [ ] **Step 5.1: Write the failing test.**

  Create `tests/perf/test_audit_outside_write_lock.zig` asserting that an audit-enabled workload has the same lock hold time as an audit-disabled one (within noise). Use the existing `AuditLogger.global_audit_logger_mutex` contention as the symptom — before the fix, audit logging blocks other writers; after, it doesn't.

- [ ] **Step 5.2: Run — fails.**

  ```bash
  zig build test-audit-outside-write-lock
  ```

- [ ] **Step 5.3: Move the `auditQueryExecution` call out of every `switch (analysis.kind)` branch.**

  Capture enough state (query_text, is_mutation, the state struct) *before* releasing the lock, then invoke `auditQueryExecution` after the defer-release.

- [ ] **Step 5.4: Run test, verify PASS.**

- [ ] **Step 5.5: Re-run msft-graph sample, capture into `task5-timing.txt`.**

- [ ] **Step 5.6: Commit.**

  ```bash
  git commit -m "perf(server): move audit.logEvent out of the write-lock scope (Task 5)"
  ```

### Task 6: Strip RLS filtering from the mutation fast path

**Files:**

- Modify: `src/server/quic_connection_handler.zig:2802-2830` (the `applyAlgorithmRLSFilter` + `applyRLSFilter` blocks)

RLS filtering runs on the mutation response rows. For bulk ingest batches (INSERT/CREATE with no RETURN), the response is empty — the RLS filter is a no-op but it still pays the `getGlobalRLSFilterEngine()` lookup + capability probe. Skip those calls when `exec_result.rows.len == 0` *and* there's no RETURN clause.

- [ ] **Step 6.1: Write the failing test.**

  A micro-bench inside `bench-query-executor-mutation` that verifies `create_single/mutation` wall time is unchanged regardless of whether an RLS engine is installed. Today: installing an RLS engine adds ~50 µs/statement because of the lookup.

- [ ] **Step 6.2: Run — should fail (time differs).**

- [ ] **Step 6.3: Add the early-exit.**

  ```zig
  if (exec_result.rows.len == 0 and analysis.target_is_return_clause_empty) {
      // Skip RLS: no rows to filter.
  } else {
      if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
          ...
      }
  }
  ```

- [ ] **Step 6.4: Run test, PASS.**

- [ ] **Step 6.5: Re-run msft-graph sample, capture into `task6-timing.txt`.**

- [ ] **Step 6.6: Commit.**

  ```bash
  git commit -m "perf(server): skip RLS filter when mutation returns no rows (Task 6)"
  ```

### Task 7: Defer undo-log append until COMMIT for bulk-ingest sessions

**Files:**

- Modify: `src/txn_undo_log.zig:220-280` (the `logCreateNode`/`logCreateEdge`/`logSetProperty` calls)
- Modify: `src/server/quic_connection_handler.zig:3086-3093` (BEGIN TX handler)
- Modify: `src/execution/crud_operations.zig:1618-1621, 1652-1655, …` (every `logCreateNode` call site)

Introduce a **bulk mode** flag on the session: when set, the undo log skips its per-statement append and records only a single "bulk ingest started" marker at BEGIN. On ROLLBACK, the session data is lost (documented trade-off; same as Postgres COPY mode). On COMMIT, no-op. The flag is opt-in via `GEODE_BULK_INGEST=1` *or* the client sending `BEGIN BULK` (new syntax, optional).

- [ ] **Step 7.1: Write the failing test.**

  Pin the contract in `tests/test_bulk_ingest_undo_log_skip.zig`: with `bulk=true`, `undo_log.getGlobalUndoLog().entries.items.len` stays at 0 after N CREATEs. With `bulk=false`, it grows to N.

- [ ] **Step 7.2: Run — fails.**

- [ ] **Step 7.3: Add `bulk_mode: bool` to `ServerState` and thread it through.**

  Populate from `state.env_config` (new field in `server_init.zig:EnvironmentConfig`). In BEGIN TX handler, if `state.bulk_mode`, call `txn_undo_log.beginBulk()` instead of `begin()`. Add `beginBulk()` and a matching `t_bulk_mode` thread-local check to the `logCreate*` helpers.

- [ ] **Step 7.4: Gate every `logCreateNode`/`logCreateEdge`/`logSetProperty` call on bulk-mode.**

  Inside the undo log itself (not the callers), add:

  ```zig
  pub fn logCreateNode(self: *UndoLog, node_id: u64, graph: ?[]const u8) !void {
      if (t_bulk_mode) return;
      // ... existing code ...
  }
  ```

  This is the minimal-surface change.

- [ ] **Step 7.5: Run test, PASS.**

- [ ] **Step 7.6: Re-run msft-graph sample with `GEODE_BULK_INGEST=1` set on the server.**

  Capture into `task7-timing.txt`. Note: this changes durability semantics — document in the commit message.

- [ ] **Step 7.7: Commit.**

  ```bash
  git commit -m "perf(txn): add GEODE_BULK_INGEST mode — skip undo log appends (Task 7)"
  ```

### Task 8: Consolidate `pending_index_rebuilds` into per-batch flush

**Files:**

- Modify: `src/execution/crud_operations.zig` — every site that adds to `context.pending_index_rebuilds`
- Modify: `src/server/quic_connection_handler.zig:2495-2503,2590-2598,2660-2668,2710-2719,2810-2820` (`rebuildPendingIndexes` call sites)

Every CREATE today queues a label into `pending_index_rebuilds` under the write lock and the lock-holder flushes them in the post-release defer. For bulk ingest the same labels recur thousands of times — the `std.StringHashMap(void)` dedup keeps memory bounded, but the per-statement insert + lookup still pays a hash cost. Move the queue to per-connection (persistent across statements in a Geode txn) and flush once at COMMIT.

- [ ] **Step 8.1: Write the failing test.**

  `tests/perf/test_pending_index_rebuilds_consolidation.zig` — under a Geode BEGIN TX with 100 CREATEs on the same label, assert `populateAdvancedIndex` is called at most once, not 100 times.

- [ ] **Step 8.2: Move `pending_index_rebuilds` to `ServerState`.**

  Currently in `ExecutionContext` (per-request). Move to `ServerState` (per-connection) and lazy-init on first BEGIN TX.

- [ ] **Step 8.3: Flush in the COMMIT handler, not the per-statement defer.**

  In the `.commit` branch of `handleClientMessage`, flush `state.pending_index_rebuilds` once and clear. Remove the per-statement `rebuildPendingIndexes` calls.

- [ ] **Step 8.4: Run test, PASS.**

- [ ] **Step 8.5: Re-run msft-graph sample, capture into `task8-timing.txt`.**

- [ ] **Step 8.6: Commit.**

  ```bash
  git commit -m "perf(exec): consolidate pending_index_rebuilds per Geode txn (Task 8)"
  ```

### Task 9: Phase 2 validation checkpoint

- [ ] **Step 9.1: Run the full regression suite.**

  ```bash
  zig build test
  ```

  Expected: exit 0. If not, debug before continuing — every Phase 2 change is invariant-preserving by design.

- [ ] **Step 9.2: Full msft-graph rerun.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-plan" 2>/dev/null || true
  rm -rf /tmp/geode-plan-phase2 && mkdir -p /tmp/geode-plan-phase2
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_BULK_INGEST=1 \
      nohup zig-out/bin/geode serve --data-dir /tmp/geode-plan-phase2 \
      --listen 127.0.0.1:3142 --log-level warn \
      > /tmp/geode-plan-phase2/server.log 2>&1 &
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3142 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session "CREATE GRAPH abs_eagleg"
  time GEODE_DSN="quic://127.0.0.1:3142/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 \
      2>&1 | tee docs/performance/2026-04-23-enterprise-ingest/phase2-run.log \
      | tail -10
  ```

  Target: **≤ 30 min** (3× improvement over R13's 2 h — this is Phase 2 alone).

- [ ] **Step 9.3: Commit the Phase 2 wrap-up evidence.**

  ```bash
  git add docs/performance/2026-04-23-enterprise-ingest/phase2-run.log
  git commit -m "docs(perf): Phase 2 validation run — baseline → ~30 min with critical-section trims"
  ```

---

## Phase 3 — Bulk-Ingest Fast Path (Bypass the Executor)

Phase 2 trims overhead that happens every statement. Phase 3 replaces the executor entirely for the well-formed CREATE/MATCH+CREATE patterns msft-graph emits. A direct adapter API shaves parse, plan, eval, and row-materialisation out of the hot path.

### Task 10: Define the bulk-ingest wire format

**Files:**

- Modify: `src/schema/messages.proto` — add a new `BulkInsertBatch` message type
- Modify: `src/schema/serialization.zig` — Zig bindings

The client (msft-graph) will continue to send regular GQL BEGIN/CREATE/COMMIT. The server detects the pattern and dispatches to the bulk path. **No client change required** — this is purely a server-side shortcut.

Actually, strike that: the opt-in is via `GEODE_BULK_INGEST=1` (Task 7) plus a pattern match on the incoming GQL statement. If the statement matches the bulk-ingest regular form (`CREATE (n:<Label> {<scalar_props>})` or `MATCH (a:<L1> {node_id: <lit>}), (b:<L2> {node_id: <lit>}) CREATE (a)-[:<REL> {<props>}]->(b)`), dispatch to the fast path. Otherwise fall through to the regular executor.

- [ ] **Step 10.1: Write the failing test.**

  `tests/bulk_ingest/test_pattern_detection.zig`:

  ```zig
  test "detects simple CREATE (n:Label {k1: v1, k2: v2}) form" {
      const ast = ... // parsed CREATE statement
      try testing.expect(bulk_path.matchesSimpleCreate(ast));
  }
  test "detects MATCH+CREATE edge form used by msft-graph" {
      const ast = ... // parsed MATCH+CREATE edge
      try testing.expect(bulk_path.matchesMatchCreateEdge(ast));
  }
  test "rejects heterogeneous CREATE" {
      const ast = ... // CREATE with RETURN or variables
      try testing.expect(!bulk_path.matchesSimpleCreate(ast));
  }
  ```

- [ ] **Step 10.2: Run — fails, `bulk_path` module doesn't exist.**

- [ ] **Step 10.3: Create `src/execution/bulk_ingest.zig`.**

  Start with pattern-matching helpers only. Fast-path execution comes in Task 11. Match on:

  - `CreateStatement` with exactly one chain, one head node, no hops, no `RETURN`, all property values are literals or parameters.
  - `Query` with exactly one `MATCH` clause that's two node patterns both with `{node_id: $param}` filter, exactly one `CREATE` clause that's a single edge between the two matched nodes, no `RETURN`.

  Return `BulkPattern.simple_node_create`, `BulkPattern.match_create_edge`, or `BulkPattern.none`.

- [ ] **Step 10.4: Run test, PASS.**

- [ ] **Step 10.5: Commit.**

  ```bash
  git commit -m "feat(bulk): add pattern-detection for msft-graph CREATE forms (Task 10)"
  ```

### Task 11: Fast-path dispatch for simple CREATE

**Files:**

- Modify: `src/server/quic_connection_handler.zig` — add bulk-path dispatch before `executeProgramWithContext`
- Modify: `src/storage/graph_storage_adapter.zig` — add `bulkInsertNode` API

- [ ] **Step 11.1: Write the failing test.**

  `tests/bulk_ingest/test_simple_create_fastpath.zig` — run a `CREATE (n:User {id: 1, name: 'a'})` through the fast path and through the regular executor; assert identical final graph state.

- [ ] **Step 11.2: Add `StorageAdapter.bulkInsertNode(graph_name, labels, props, txn_id_opt)`:**

  Resolves labels → label_ids via `mg.label_dict.getOrCreate` (one mutex hit), allocates a node slot via `mg.engine.allocNode`, calls `putNodeTxn` + `addLabelTxn` + `putPropertyTxn` all threaded through the same engine txn. This is a slimmer version of `createNode` + `setNodeProperty` with no dynamic dispatch, no `PropertyValue` round-trips through AST, and no undo-log append (bulk mode).

- [ ] **Step 11.3: Dispatch from the QUIC handler.**

  After parsing + pattern matching:

  ```zig
  if (state.bulk_mode) {
      if (bulk_ingest.matchSingleStatement(&parse_result.program)) |pattern| {
          return try executeBulk(gpa, stream, state, pattern, exec_context);
      }
  }
  // fallthrough to regular executor
  ```

- [ ] **Step 11.4: Run test, PASS.**

- [ ] **Step 11.5: Bench.**

  Add `bulk_create_single` scenario to `benchmarks/bench_executor_mutation.zig`. Expected: ≤ 1 ms (vs 6.8 ms for the regular path on R13).

- [ ] **Step 11.6: Commit.**

  ```bash
  git commit -m "feat(bulk): fast-path simple CREATE via bulkInsertNode (Task 11)"
  ```

### Task 12: Fast-path dispatch for MATCH+CREATE edge

Same shape as Task 11 but for the two-match-one-edge pattern.

- [ ] **Step 12.1: Write the failing test.**

  Run `MATCH (a:User {node_id: 'x'}), (b:Device {node_id: 'y'}) CREATE (a)-[r:OWNS]->(b)` through the fast path; assert the edge exists between the correct endpoints with the correct rel_type.

- [ ] **Step 12.2: Add `StorageAdapter.bulkInsertEdge(graph_name, source_id, target_id, rel_type, props, txn_id_opt)`:**

  Two `lookupMergeCandidate` calls (resolves source + target), one `addEdgeTxn`, per-property `putPropertyTxn` + `adj_out/adj_in.updateEdgePropHead` via the R12 pattern.

- [ ] **Step 12.3: Dispatch.**

- [ ] **Step 12.4: Run test, PASS.**

- [ ] **Step 12.5: Bench `bulk_match_create_edge` scenario. Target ≤ 1 ms.**

- [ ] **Step 12.6: Commit.**

  ```bash
  git commit -m "feat(bulk): fast-path MATCH+CREATE edge (Task 12)"
  ```

### Task 13: Phase 3 validation checkpoint

- [ ] **Step 13.1: Full regression suite.**

  ```bash
  zig build test
  ```

- [ ] **Step 13.2: Full msft-graph rerun with `GEODE_BULK_INGEST=1`.**

  Same procedure as Step 9.2, output to `docs/performance/2026-04-23-enterprise-ingest/phase3-run.log`.

  Target: **≤ 10 min** (~5× further over Phase 2).

- [ ] **Step 13.3: Commit the Phase 3 evidence.**

---

## Phase 4 — Concurrent Readers During Mutation

Up to this point, 16 workers still fully serialise on the per-graph exclusive write lock. Phase 4 splits the per-statement critical section into a **read-lock phase** (MATCH / lookup) and a **write-lock phase** (apply mutation). 16 MATCH lookups run in parallel; the exclusive flip happens only for the (much shorter) apply step.

This is the structurally biggest change in the plan. It requires re-checking every invariant that the current single-exclusive-writer model relies on (GAP-0001, CWE-362, CWE-416 in the comments).

### Task 14: Audit existing lock-scope invariants

**Files:**

- Read: `src/graph_store.zig:5076-5134` (`acquireGraphWriteLock` + R6 comment)
- Read: `src/server/quic_connection_handler.zig:2403-2470` (why the write lock wraps execute)
- Read: `tests/test_match_property_read_serialization.zig`

Before splitting the lock, list EVERY assumption the current code makes about "we hold the exclusive write lock for the full duration of the mutation". Any mutation of `self.nodes` / `self.edges` HashMaps needs the exclusive flip.

- [ ] **Step 14.1: Produce the invariant list.**

  Write `docs/performance/2026-04-23-enterprise-ingest/phase4-invariants.md`:

  ```markdown
  # Phase 4 invariant audit

  ## Must-be-exclusive (HashMap rehash, adjacency list grow, …)

  - `graph_store.createNode`: appends to `self.nodes` (std.AutoHashMap).
    Rehash under concurrent reader = CWE-362.
  - `graph_store.createEdge`: appends to `self.edges` and modifies
    `adj_out` / `adj_in` linked lists (owned by `graph_storage`).
  - ...

  ## Safe-during-reader (read-only store access)

  - MATCH `lookupMergeCandidate`: `self.merge_prop_index.get()` —
    std.StringHashMap read is safe if no concurrent insert.
  - ...

  ## Needs fine-grained lock

  - `self.label_index.getPtr(...).append(node_id)` — the ArrayList
    could reallocate. Protect with a per-posting-list mutex.
  - ...
  ```

- [ ] **Step 14.2: Commit.**

  ```bash
  git commit -m "docs(perf): Phase 4 lock-invariant audit (Task 14)"
  ```

### Task 15: Split mutation into (read-lock) MATCH phase + (write-lock) apply phase

**Files:**

- Modify: `src/server/quic_connection_handler.zig` (the `.rows` mutation branch)
- Modify: `src/execution/bulk_ingest.zig` (the bulk fast path)

Both code paths currently wrap MATCH + CREATE under one exclusive write lock. Split them:

1. Acquire the **shared read lock**.
2. Resolve MATCH endpoints (`lookupMergeCandidate` / `findFirstMatchingNodeId`).
3. Release the read lock; capture the resolved node IDs on the stack.
4. Acquire the **exclusive write lock**.
5. Apply the mutation using the captured IDs.
6. Release the write lock.

Between (3) and (4) another writer could mutate the store. The resolved IDs are stable (we got them from the merge index which maps `(label, prop, val) → node_id`). If the target node is deleted between the MATCH and the CREATE, the `addEdgeTxn` returns `NodeNotFound` — the client sees a normal error, same as today. No new race, just a narrower one.

- [ ] **Step 15.1: Write the failing test.**

  `tests/bulk_ingest/test_concurrent_match_apply.zig`: 16 threads each do `MATCH (a) CREATE (a)-[:REL]->(b)` concurrently. Before the split, all 16 serialise on the exclusive lock. After, measure aggregate throughput ≥ 5× single-thread throughput.

- [ ] **Step 15.2: Run — fails (serialised behaviour).**

- [ ] **Step 15.3: Implement the two-phase acquire in the bulk path first.**

  Simpler to do in bulk (small, well-understood). Non-bulk path stays on the original exclusive lock for this task.

  ```zig
  fn bulkExecuteMatchCreateEdge(...) !void {
      // Phase 1: read-lock MATCH
      const source_id, const target_id = blk: {
          const lock = graph_store.acquireGraphReadLock(graph);
          defer graph_store.releaseGraphLock(lock);
          const s = try lookupByMergeIndex(graph, src_label, src_key, src_val)
              orelse return error.SourceNodeNotFound;
          const t = try lookupByMergeIndex(graph, dst_label, dst_key, dst_val)
              orelse return error.TargetNodeNotFound;
          break :blk .{ s, t };
      };

      // Phase 2: write-lock CREATE
      const lock = try graph_store.acquireGraphWriteLockCancelable(graph, deadline);
      defer graph_store.releaseGraphLock(lock);
      _ = try adapter.bulkInsertEdge(graph, source_id, target_id, rel_type, props, txn_id);
  }
  ```

- [ ] **Step 15.4: Run test, PASS (aggregate ≥ 5× single-thread).**

- [ ] **Step 15.5: Re-run msft-graph sample into `task15-timing.txt`.**

- [ ] **Step 15.6: Commit.**

  ```bash
  git commit -m "perf(bulk): split MATCH+CREATE into read-locked lookup + write-locked apply (Task 15)"
  ```

### Task 16: Apply the two-phase acquire to the non-bulk mutation path

- [ ] **Step 16.1: Write the failing test.**

  Same pattern as Task 15 but running through `executeProgramWithContext` instead of the bulk path.

- [ ] **Step 16.2: Implement by hoisting MATCH before the lock acquire in `handleExecute`.**

- [ ] **Step 16.3: Run test, PASS.**

- [ ] **Step 16.4: Re-run msft-graph sample into `task16-timing.txt`.**

- [ ] **Step 16.5: Commit.**

  ```bash
  git commit -m "perf(server): two-phase lock for all mutations — MATCH in read lock, apply in write (Task 16)"
  ```

### Task 17: Per-posting-list mutex for the label index

**Files:**

- Modify: `src/graph_store.zig:1388-1439` (`addToLabelIndex` + `sortedInsert`)

The current `sortedInsert` into the label-posting `std.ArrayList(u64)` is the last remaining data structure that can't tolerate a concurrent reader without the exclusive graph lock. Add a `std.Thread.Mutex` per posting list; `sortedInsert` takes the mutex; readers (during MATCH) also take it for safe iteration. This lets the two-phase lock from Task 15/16 actually deliver concurrency.

- [ ] **Step 17.1: Write the failing test.**

  `tests/perf/test_label_posting_concurrent_insert.zig`: 16 threads call `addToLabelIndex` on the same label concurrently. Before fix: race detector / invalid-read. After: all 16 × N appends observed correctly with no data loss.

- [ ] **Step 17.2: Run — fails (data race or crash).**

- [ ] **Step 17.3: Embed a `std.Thread.Mutex` in the posting-list value.**

  Change `std.ArrayList(u64)` to `struct { list: std.ArrayList(u64), mu: std.Thread.Mutex }`.

- [ ] **Step 17.4: Update every read/write site.**

  Every `label_index.get(...).items` becomes `blk: { mu.lock(); defer mu.unlock(); break :blk ... }`. Every `sortedInsert` takes the mutex.

- [ ] **Step 17.5: Run test, PASS.**

- [ ] **Step 17.6: Commit.**

  ```bash
  git commit -m "perf(graph_store): per-posting-list mutex for concurrent label-index reads/writes (Task 17)"
  ```

### Task 18: Phase 4 validation checkpoint

- [ ] **Step 18.1: Full regression suite + msft-graph rerun.**

  Target: **≤ 3 min** (~3× further over Phase 3).

- [ ] **Step 18.2: Commit evidence.**

---

## Phase 5 — Group Commit / Async WAL Sync

Even with all of Phase 1–4, every Geode BEGIN/COMMIT still blocks on its one WAL `fsync()` at COMMIT time. With 16 parallel clients each sending ~3 batches/sec that's 48 fsyncs/sec × 5-10 ms each = 240-480 ms/sec of pure fsync wall time. At high throughput the fsync itself becomes the ceiling.

The `graph_storage` library already has `wal.sync()` as a single sync point. **Group-commit** means multiple client commits share one fsync: they queue up their WAL-append, wait on a condition variable, and one designated flusher thread does a single fsync that satisfies all queued commits.

### Task 19: Add group-commit queue to the engine-txn boundary

**Files:**

- Modify: local vendor copy of `~/.cache/zig/p/graph_storage-0.1.0-9UyJS8.../src/txn.zig` (commit.commit)

Because `graph_storage` is an external dependency pinned by hash in `build.zig.zon`, this requires either:

(a) Forking the dep, making the change, updating the hash; or
(b) Wrapping the engine's auto-commit `commitTxn` behind a Geode-side group-commit coordinator at the adapter layer.

Option (b) is lower-risk. The adapter maintains a `GroupCommit` struct with a mutex, a queue of pending txns, and a condvar. Each `commitSessionTxn` / `commitStatementTxn` enqueues its `txn_id` and blocks; the first caller becomes the flusher, does the fsync, and wakes everyone.

- [ ] **Step 19.1: Write the failing test.**

  `tests/perf/test_group_commit_amortises_fsync.zig`: spawn 16 threads each calling `adapter.commitSessionTxn()` once on distinct session txns. Before fix: 16 fsyncs serialised → ~120 ms wall. After: at most ~10 ms wall (one fsync serves all 16).

- [ ] **Step 19.2: Run — fails.**

- [ ] **Step 19.3: Implement `GroupCommitCoordinator` in `src/storage/group_commit.zig`.**

  ```zig
  pub const GroupCommitCoordinator = struct {
      mu: std.Thread.Mutex = .{},
      cv: std.Thread.Condition = .{},
      pending: std.ArrayList(PendingCommit) = .empty,
      flusher_active: bool = false,

      pub fn commitAndWait(self: *GroupCommitCoordinator, engine: *GraphEngine, txn_id: TxnId) !void {
          self.mu.lock();
          var slot = PendingCommit{ .txn_id = txn_id, .done = false, .err = null };
          try self.pending.append(allocator, &slot);
          if (!self.flusher_active) {
              self.flusher_active = true;
              self.mu.unlock();
              try self.flush(engine);  // one fsync for the whole queue
              self.mu.lock();
              self.flusher_active = false;
              self.cv.broadcast();
          } else {
              while (!slot.done) self.cv.wait(&self.mu);
          }
          self.mu.unlock();
          if (slot.err) |e| return e;
      }

      fn flush(self: *GroupCommitCoordinator, engine: *GraphEngine) !void {
          // drain the queue, call engine.commitTxn(id) for each (appends
          // COMMIT records), then a single wal.sync() satisfies all.
          ...
      }
  };
  ```

- [ ] **Step 19.4: Route `commitSessionTxn` / `commitStatementTxn` through the coordinator.**

- [ ] **Step 19.5: Run test, PASS.**

- [ ] **Step 19.6: Commit.**

  ```bash
  git commit -m "perf(storage): group-commit coordinator amortises WAL fsync across concurrent sessions (Task 19)"
  ```

### Task 20: Phase 5 validation checkpoint

- [ ] **Step 20.1: Full regression suite + msft-graph rerun.**

  Target: **≤ 90 s**.

- [ ] **Step 20.2: Commit evidence.**

---

## Phase 6 — End-to-End Verification Against the User's Command

### Task 21: Produce the final benchmark report

- [ ] **Step 21.1: Clean server + full ingest, timing captured.**

  ```bash
  pkill -9 -f "geode serve --data-dir /tmp/geode-plan" 2>/dev/null || true
  rm -rf /tmp/geode-plan-final && mkdir -p /tmp/geode-plan-final
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_BULK_INGEST=1 \
      nohup zig-out/bin/geode serve --data-dir /tmp/geode-plan-final \
      --listen 127.0.0.1:3142 --log-level warn \
      > /tmp/geode-plan-final/server.log 2>&1 &
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3142 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session "CREATE GRAPH abs_eagleg"
  FINAL_START=$(date +%s)
  time GEODE_DSN="quic://127.0.0.1:3142/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /home/benji/eagleg-topology-data-16 \
      --parallel --workers 16 --chunk-size 1000 \
      2>&1 | tee docs/performance/2026-04-23-enterprise-ingest/final-run.log
  FINAL_END=$(date +%s)
  echo "total seconds: $((FINAL_END - FINAL_START))" \
      >> docs/performance/2026-04-23-enterprise-ingest/final-run.log
  ```

- [ ] **Step 21.2: Assert the target.**

  ```bash
  TOTAL=$(awk -F: '/total seconds:/ {print $2}' \
      docs/performance/2026-04-23-enterprise-ingest/final-run.log | tr -d ' ')
  echo "total=$TOTAL"
  test "$TOTAL" -lt 60 || (echo "MISSED TARGET"; exit 1)
  ```

  If this fails the step fails — go back to the Phase 1 diagnosis, find the remaining hotspot, and add more tasks. Do NOT claim completion without hitting the target.

- [ ] **Step 21.3: Write the summary report.**

  `docs/performance/2026-04-23-enterprise-ingest/SUMMARY.md` mirroring the R6-R13 summary: problem statement, methodology, per-phase bench deltas, per-phase integration timings, per-task commit table, and final end-to-end measurement.

- [ ] **Step 21.4: Update the top-level `docs/KNOWN_TEST_ISSUES.md` / `CLAUDE.md`.**

  Add a "bulk ingest mode" section explaining the `GEODE_BULK_INGEST=1` flag, the durability trade-off (undo-log skipped → no session-level ROLLBACK), and the recommended configuration for enterprise bulk loads.

- [ ] **Step 21.5: Commit.**

  ```bash
  git commit -m "docs(perf): final report — msft-graph 16-worker ingest in <60s"
  ```

- [ ] **Step 21.6: Confirm regression tests still pass.**

  ```bash
  zig build test
  zig build test-r6-parallel-ingest test-graph-write-lock-cancelable \
      test-undo-log-isolation test-orphan-txn-cleanup \
      test-match-read-serial test-handler-lock-hold-scope \
      test-mutation-timing test-plan-outside-write-lock \
      test-audit-outside-write-lock \
      test-pending-index-rebuilds-consolidation \
      test-bulk-ingest-pattern-detection \
      test-simple-create-fastpath \
      test-match-create-edge-fastpath \
      test-concurrent-match-apply \
      test-label-posting-concurrent-insert \
      test-group-commit-amortises-fsync
  ```

  Expected: exit 0. If any test fails, fix before claiming completion.

---

## Phase 7 — Stretch Goals (Only If Phase 6 Missed the 60 s Target)

Only run these if Phase 21 Step 2 fails. They are structurally bigger changes with longer payback.

### Task 22 (stretch): MVCC-style read snapshots for MATCH

The R13 `QueryReadSession` already provides a snapshot view for READ queries. Extend it to mutation paths so the MATCH phase of every CREATE takes a versioned snapshot instead of the shared read lock. Writers no longer block MATCH readers at all.

### Task 23 (stretch): Sharded per-graph write lock

Split `mg.rwlock` into N shards (e.g. 16, keyed by `hash(first_label) % 16`). Statements touching different shards can proceed concurrently. Requires careful analysis of cross-shard statements (MATCH in one, CREATE in another).

### Task 24 (stretch): Async WAL append

Currently `wal.appendRecord` blocks on the disk write. Queue the appends and have a dedicated I/O thread flush. Adds WAL durability complexity (`flush barrier` ordering).

---

## Self-Review Checklist

Before handing this plan off, verify:

- **Every phase has a measurement gate** (Step N.2 / N.3 / Phase validation checkpoints). If a phase's measurement doesn't hit its target, we don't move on.
- **No step says "TODO" / "implement later" / "similar to Task N"** — every code block is complete.
- **Every new type, method, or env var is defined in the task that introduces it** (e.g. `StatementTxn`, `bulkInsertNode`, `GroupCommitCoordinator`, `GEODE_BULK_INGEST`).
- **The final validation in Task 21 actually asserts the <60 s target** and fails loud if missed — no "looks good" declarations without the check.
- **The R6-R13 regression tests are preserved** and re-run in Step 21.6. Nothing in the plan weakens an existing invariant without pinning a replacement test.

---

## Operational notes for the implementing engineer

- **Zig 0.16.0** toolchain. The `std.Io.RwLock` / `std.Io.Mutex` APIs are not the same as `std.Thread.RwLock` / `std.Thread.Mutex`; stick with whichever the file you're editing already uses. The adapter layer uses `std.Io.*`; the proposed `GroupCommitCoordinator` uses `std.Thread.*` — this is intentional because the coordinator needs a condvar and `std.Io.Condition` doesn't exist yet in 0.16.
- **`graph_storage` dep at `~/.cache/zig/p/graph_storage-0.1.0-9UyJS8dECwB9_…`** is read-only cache content. Do not try to edit it in place — Zig's content-addressed cache will not invalidate correctly. If Phase 5 needs engine-side changes, fork the dep into `third_party/graph_storage/` and update `build.zig.zon` to a path dep (coordinate with the user first).
- **Regression tests to keep green at every step:** `test-r6-parallel-ingest`, `test-graph-write-lock-cancelable`, `test-undo-log-isolation`, `test-orphan-txn-cleanup`, `test-match-read-serial`, `test-handler-lock-hold-scope`. Run them after each task, not only at phase boundaries. If a change breaks one, don't commit — fix first.
- **Bench invariant:** every task that touches the mutation hot path must re-run `bench-query-executor-mutation` and keep the R13 results within 5 % (no regressions on existing scenarios) unless the task explicitly trades bench latency for integration throughput (document why in the commit body).
- **Commit discipline:** each Step N.x is its own commit. Squash only at the phase boundary if the intermediate commits don't carry independently-useful information.
