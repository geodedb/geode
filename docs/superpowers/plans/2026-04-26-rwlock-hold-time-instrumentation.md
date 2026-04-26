# rwlock Hold-Time Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-graph SHARED-rwlock hold-time counters to `ManagedGraph` and re-run the cascade repro so the secondary bisection in `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md` can definitively distinguish "long MATCH-with-RLS holds the read lock" (fix in `match_operations.executeMultiNodeMatch`) from "rwlock implementation is the chokepoint" (fix in `Io.RwLock`).

**Architecture:** Mirrors the existing `rwlock_shared_wait_ns_total` / `rwlock_shared_acquired_total` / `rwlock_exclusive_wait_ns_total` infrastructure committed at `14999b61`. Two new `std.atomic.Value(u64)` fields on `ManagedGraph` (cumulative hold-time + observed max), one increment-on-release defer per SHARED acquire site (six total), one register-with-runtime_metrics call. Then re-run the cascade repro from the prior plan and update the bisection analysis with the new evidence.

**Tech Stack:** Zig 0.16. `std.atomic.Value(u64).fetchAdd(.monotonic)` for cumulative; non-CAS racy load/store for the observed max (acceptable for diagnostic data — worst case is stale max). `runtime_metrics.Registry.register(name, *atomic.Value(u64))` for the gauge surface (counters, not gauges — cumulative ns + observed max are both monotonic). Build via `make build`. Existing repro driver at `/tmp/run-quic-investigation-repro.sh` (workers=4 variant from the prior plan; reproduces cascade in 24 min wall-clock, captures stacks at trigger).

---

## File structure

| File | Status | Responsibility |
|------|--------|----------------|
| `src/storage/graph_storage_adapter.zig` | Modify | Add 2 fields to `ManagedGraph` (`rwlock_shared_hold_ns_total`, `rwlock_shared_max_hold_ns_observed`). Add hold-time defer at 6 SHARED acquire sites. Register the 2 new counters in the existing `runtime_metrics` registration block. |
| `tests/test_graph_storage_adapter_metrics.zig` | Create | Unit test that exercises the new hold-time atomics: acquire SHARED, sleep ~10 ms, release, snapshot the counters, assert hold_ns_total ≥ ~10 ms. |
| `build.zig` | Modify (small) | Register the new test binary. |
| `docs/performance/2026-04-26-rwlock-hold-time/repro-server.log` | Create (committed) | Cascade repro server log against the instrumented binary. |
| `docs/performance/2026-04-26-rwlock-hold-time/repro-ingest.log` | Create (committed) | Cascade repro ingest log. |
| `docs/performance/2026-04-26-rwlock-hold-time/cascade-stacks.txt` | Create (committed) | Stack capture at cascade trigger. |
| `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md` | Modify (append) | New section "Hold-time secondary bisection (2026-04-26)" with the rate table for the two new counters and the verdict (long-RLS-hold confirmed OR rwlock-impl confirmed OR neither — pick H5a / H5b / H5c). |

---

## Phase 1 — Instrument

### Task 1: Add the two atomic fields to `ManagedGraph`

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig:552-558`

The existing block (commit `14999b61`):

```zig
    rwlock_shared_acquired_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock_shared_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock_exclusive_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
```

- [ ] **Step 1.1: Add the two new fields immediately after the existing block.**

  Find the existing three-counter block (around `src/storage/graph_storage_adapter.zig:552-558`). Add immediately after:

  ```zig
      // Hold-time counters (added 2026-04-26 for the rwlock-hold-time investigation
      // plan that follows the QUIC cascade Phase 4 H5 verdict). Cumulative ns
      // counts time the SHARED lock was actually held (separate from
      // rwlock_shared_wait_ns_total which counts time spent WAITING to acquire).
      // max_hold_ns_observed is racy-write — diagnostic only, occasional lost
      // update under concurrent release is acceptable.
      rwlock_shared_hold_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      rwlock_shared_max_hold_ns_observed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
  ```

- [ ] **Step 1.2: Build.**

  ```bash
  make build 2>&1 | tail -3
  ```

  Expected: clean build. The fields are not yet referenced anywhere — this commit only declares them.

- [ ] **Step 1.3: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig
  git commit -m "feat(metrics): add rwlock SHARED hold-time atomics to ManagedGraph

  Two new fields paralleling the existing rwlock_shared_wait_ns_total
  pattern: rwlock_shared_hold_ns_total (cumulative time the lock was
  actually held) and rwlock_shared_max_hold_ns_observed (racy max
  observation, diagnostic only). Wired in the next commit.

  Drives the rwlock-hold-time investigation that follows the QUIC
  cascade Phase 4 H5 verdict."
  ```

### Task 2: Add hold-time defer at all six SHARED acquire sites

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig` at six line ranges (1318-1326, 1378-1386, 1461-1469, 2839-2847, 2865-2873, 3499-3507)

Each acquire site currently ends with `defer mg.rwlock.unlockShared(io);`. Insert a new hold-time defer AFTER the unlock-defer in source order (LIFO unwind: hold-measure runs FIRST, then unlock — correct timing because the lock is still held at the moment we sample `monoNanosNow()`).

The pattern for ALL six sites is identical. Apply mechanically.

- [ ] **Step 2.1: Find all six SHARED acquire sites.**

  ```bash
  grep -nE "rwlock_shared_acquired_total\.fetchAdd" src/storage/graph_storage_adapter.zig
  ```

  Expected output: six lines (1325, 1385, 1468, 2846, 2872, 3506). All are inside their own `defer mg.rwlock.unlockShared(io);` scope.

- [ ] **Step 2.2: Apply the wrapper at site 1 (around line 1325).**

  Find the existing block:

  ```zig
          const _t_start = monoNanosNow();
          mg.rwlock.lockSharedUncancelable(io);
          _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
          _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
          defer mg.rwlock.unlockShared(io);
  ```

  Replace with:

  ```zig
          const _t_start = monoNanosNow();
          mg.rwlock.lockSharedUncancelable(io);
          _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
          _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
          defer mg.rwlock.unlockShared(io);
          const _hold_start = monoNanosNow();
          defer {
              const _hold_ns = monoNanosNow() -| _hold_start;
              _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
              const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
              if (_hold_ns > _cur_max) {
                  mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
              }
          }
  ```

  The inserted block (5 lines + the defer scope) goes immediately after the existing `defer mg.rwlock.unlockShared(io);`. LIFO defer ordering means the hold-measure defer runs BEFORE the unlock defer on unwind — so `_hold_ns` correctly captures the duration from `_hold_start` to the moment of release.

- [ ] **Step 2.3: Apply the same wrapper at sites 2-6.**

  Sites at lines 1385, 1468, 2846, 2872, 3506. The before/after code is byte-identical to Step 2.2; just sed/grep through them.

  Quick automation if you trust the pattern:

  ```bash
  # Verify all 6 sites have the IDENTICAL before-pattern (they should — the prior
  # plan's commit 14999b61 made them so):
  grep -B1 -A1 "rwlock_shared_acquired_total.fetchAdd" src/storage/graph_storage_adapter.zig | grep "defer mg.rwlock.unlockShared" | wc -l
  ```

  Expected: 6. If not 6, do the edits manually per-site rather than risk a botched bulk-edit.

- [ ] **Step 2.4: Build.**

  ```bash
  make build 2>&1 | tail -5
  ```

  Expected: clean build. If a brace level is wrong at any site (the inserted `defer { ... }` block must close cleanly), the build will tell you which line.

- [ ] **Step 2.5: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig
  git commit -m "feat(metrics): wrap six SHARED acquire sites with hold-time measurement

  Each of the six mg.rwlock.lockSharedUncancelable sites in
  graph_storage_adapter.zig gets a paired hold-time defer that runs
  BEFORE the existing unlock defer on LIFO unwind. Measures actual
  lock-held duration; cumulative goes into rwlock_shared_hold_ns_total,
  racy max into rwlock_shared_max_hold_ns_observed.

  Drives the rwlock-hold-time investigation."
  ```

### Task 3: Register the two new counters in the existing block

**Files:**
- Modify: `src/storage/graph_storage_adapter.zig` around lines 3186-3188

The existing registration block:

```zig
                reg.register("mg_rwlock_shared_acquired_total", &mg.rwlock_shared_acquired_total) catch {};
                reg.register("mg_rwlock_shared_wait_ns_total", &mg.rwlock_shared_wait_ns_total) catch {};
                reg.register("mg_rwlock_exclusive_wait_ns_total", &mg.rwlock_exclusive_wait_ns_total) catch {};
```

- [ ] **Step 3.1: Add the two new register calls.**

  Append immediately after the existing three:

  ```zig
                reg.register("mg_rwlock_shared_acquired_total", &mg.rwlock_shared_acquired_total) catch {};
                reg.register("mg_rwlock_shared_wait_ns_total", &mg.rwlock_shared_wait_ns_total) catch {};
                reg.register("mg_rwlock_exclusive_wait_ns_total", &mg.rwlock_exclusive_wait_ns_total) catch {};
                reg.register("mg_rwlock_shared_hold_ns_total", &mg.rwlock_shared_hold_ns_total) catch {};
                reg.register("mg_rwlock_shared_max_hold_ns_observed", &mg.rwlock_shared_max_hold_ns_observed) catch {};
  ```

- [ ] **Step 3.2: Build + smoke test.**

  ```bash
  make build 2>&1 | tail -3

  # Quick smoke test: boot the server, drive ONE query, confirm the new counters
  # appear in info: metrics: lines.
  rm -rf /tmp/geode-rwlock-holdtime-smoke
  GEODE_ADMIN_PASSWORD=Geode1234Abc nohup zig-out/bin/geode serve \
    --data-dir /tmp/geode-rwlock-holdtime-smoke \
    --listen 127.0.0.1:3176 --log-level info \
    > /tmp/geode-rwlock-holdtime-smoke.log 2>&1 &
  SMOKE_PID=$!
  sleep 8
  zig-out/bin/geode query --server 127.0.0.1:3176 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session "RETURN 1 AS ok" > /dev/null 2>&1
  sleep 7
  grep "metrics:" /tmp/geode-rwlock-holdtime-smoke.log | tail -1 | tr ' ' '\n' \
    | grep -E "mg_rwlock_shared_hold|mg_rwlock_shared_max_hold"
  kill -9 $SMOKE_PID 2>/dev/null
  rm -rf /tmp/geode-rwlock-holdtime-smoke
  ```

  Expected: two lines, e.g. `mg_rwlock_shared_hold_ns_total=NNN` (probably some small value from server startup) and `mg_rwlock_shared_max_hold_ns_observed=NNN`.

- [ ] **Step 3.3: Commit.**

  ```bash
  git add src/storage/graph_storage_adapter.zig
  git commit -m "feat(metrics): register the two new SHARED hold-time counters

  mg_rwlock_shared_hold_ns_total and mg_rwlock_shared_max_hold_ns_observed
  now appear in 'info: metrics:' lines every 5 s alongside the existing
  rwlock counters and the QUIC + BufferedProtoReader instrumentation
  from docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md."
  ```

---

## Phase 2 — Test

### Task 4: Unit test for the hold-time atomics

**Files:**
- Create: `tests/test_graph_storage_adapter_metrics.zig`
- Modify: `build.zig` (register the new test binary)

The unit test exercises the two new atomics directly: take the SHARED lock on a freshly-created `ManagedGraph`, sleep ~10 ms, release, snapshot the counters, assert `rwlock_shared_hold_ns_total ≥ ~10 × 10^6` and `rwlock_shared_max_hold_ns_observed ≥ ~10 × 10^6`.

This is NOT an integration test — it just verifies the field reads/writes work as the next phase's bisection assumes.

- [ ] **Step 4.1: Find an existing test that exercises `ManagedGraph`** to copy the imports + fixture pattern.

  ```bash
  grep -rln "ManagedGraph" tests/ | head -5
  ```

  If none, look at how `test_runtime_metrics.zig` constructs its test fixture and adapt.

- [ ] **Step 4.2: Write the test.**

  Create `tests/test_graph_storage_adapter_metrics.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  const std = @import("std");
  const adapter = @import("graph_storage_adapter");

  test "ManagedGraph: rwlock_shared_hold_ns_total accumulates from manual SHARED hold" {
      const allocator = std.testing.allocator;

      // Construct a minimal ManagedGraph fixture. If the type's init signature
      // requires more setup than this, copy the pattern from the nearest
      // existing tests/test_*.zig that constructs a ManagedGraph.
      var mg = adapter.ManagedGraph{};

      const io = std.Io.Threaded.global_single_threaded.io();

      // Manually exercise the wrap pattern (this is what each acquire site
      // does in production, distilled to its essentials):
      mg.rwlock.lockSharedUncancelable(io);
      const _hold_start = std.time.nanoTimestamp();

      // Hold the lock for ~10 ms.
      const req = std.os.linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
      var rem: std.os.linux.timespec = undefined;
      _ = std.os.linux.nanosleep(&req, &rem);

      const _hold_ns = @as(u64, @intCast(std.time.nanoTimestamp() -| _hold_start));
      _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
      const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
      if (_hold_ns > _cur_max) {
          mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
      }
      mg.rwlock.unlockShared(io);

      // Assert the counters reflect the hold.
      const total = mg.rwlock_shared_hold_ns_total.load(.monotonic);
      const max_obs = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);

      // 10 ms ± slack; nanosleep can return early or late by a few ms.
      // Floor at 5 ms; no upper bound (CI may be slow).
      try std.testing.expect(total >= 5 * std.time.ns_per_ms);
      try std.testing.expect(max_obs >= 5 * std.time.ns_per_ms);
      try std.testing.expectEqual(total, max_obs);  // single hold, so they're equal
      _ = allocator;
  }
  ```

  IMPORTANT: if `adapter.ManagedGraph{}` doesn't compile because the struct requires non-default-initialised fields, look at one of the existing constructors (`getOrCreateGraph` in `graph_storage_adapter.zig:~3120`) and either (a) copy its allocation pattern, or (b) declare the test as `pub fn` and skip the field-init issue by accessing the `.rwlock`, `.rwlock_shared_hold_ns_total`, `.rwlock_shared_max_hold_ns_observed` fields by name on a manually-allocated struct. The test only needs the lock and the two atomics.

- [ ] **Step 4.3: Register in build.zig.**

  Find the existing test registration block (mirror of how `test-runtime-metrics` is registered). Add a sibling step:

  ```zig
  const test_graph_storage_adapter_metrics = b.addTest(.{
      .root_source_file = b.path("tests/test_graph_storage_adapter_metrics.zig"),
      .target = target,
      .optimize = optimize,
  });
  // ... import("graph_storage_adapter") wiring same as the integration tests use ...
  const test_step_graph_storage_adapter_metrics = b.step(
      "test-graph-storage-adapter-metrics",
      "Hold-time atomics unit test",
  );
  test_step_graph_storage_adapter_metrics.dependOn(&b.addRunArtifact(test_graph_storage_adapter_metrics).step);
  ```

  If the existing test-runtime-metrics step uses a different idiom (e.g., a `for` loop over a fixture array), follow that idiom instead.

- [ ] **Step 4.4: Run the test.**

  ```bash
  zig build test-graph-storage-adapter-metrics --summary all 2>&1 | tail -5
  ```

  Expected: `1/1 tests passed`. If the test fails on the assertions, the wrap pattern from Task 2 is broken — go back and verify the LIFO defer ordering. If it fails to compile, the import path or `ManagedGraph` constructor needs fixing.

- [ ] **Step 4.5: Commit.**

  ```bash
  git add tests/test_graph_storage_adapter_metrics.zig build.zig
  git commit -m "test(metrics): unit test for rwlock SHARED hold-time atomics

  Manually exercises the wrap pattern from Task 2 against a freshly-
  allocated ManagedGraph: take SHARED, sleep 10 ms, release, snapshot
  the two counters, assert both reflect the hold."
  ```

---

## Phase 3 — Re-run cascade + secondary bisection

### Task 5: Re-run the instrumented cascade repro

**Files:**
- Create (committed): `docs/performance/2026-04-26-rwlock-hold-time/repro-server.log`
- Create (committed): `docs/performance/2026-04-26-rwlock-hold-time/repro-ingest.log`
- Create (committed): `docs/performance/2026-04-26-rwlock-hold-time/cascade-stacks.txt`

The prior plan (`docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md` Task 8) reproduced the cascade at `--workers 4` on `edges_audited.jsonl` after ~24 min wall-clock. We re-run that exact repro against the new instrumented binary so the secondary bisection has the new counter trajectories to consult.

- [ ] **Step 5.1: Adapt the existing repro driver.**

  ```bash
  cp /tmp/run-quic-investigation-repro.sh /tmp/run-rwlock-hold-time-repro.sh
  sed -i 's|docs/performance/2026-04-25-quic-cascade-investigation|docs/performance/2026-04-26-rwlock-hold-time|g' /tmp/run-rwlock-hold-time-repro.sh
  sed -i 's|/tmp/geode-quic-investigation|/tmp/geode-rwlock-hold-time|g' /tmp/run-rwlock-hold-time-repro.sh
  sed -i 's|/tmp/quic-investigation-data|/tmp/rwlock-hold-time-data|g' /tmp/run-rwlock-hold-time-repro.sh
  sed -i 's|127.0.0.1:3175|127.0.0.1:3176|g' /tmp/run-rwlock-hold-time-repro.sh
  mkdir -p docs/performance/2026-04-26-rwlock-hold-time
  ```

  Confirm the script is using `--workers 4` (not 16) by `grep workers /tmp/run-rwlock-hold-time-repro.sh`.

- [ ] **Step 5.2: Run the repro in background (~25 min wall-clock).**

  ```bash
  bash /tmp/run-rwlock-hold-time-repro.sh
  ```

  Use `run_in_background: true` on the Bash tool call. Poll the artifacts every 3-5 minutes via `tail` until either the cascade trigger fires (look for `pipeline failed — retrying file in serial mode` in the ingest log) OR the `timeout 1500` hits and the script self-terminates. DO NOT kill the bash early — the prior plan's first attempt was killed prematurely and had to be re-run.

- [ ] **Step 5.3: Verify the artifacts include the new counters.**

  ```bash
  ls -la docs/performance/2026-04-26-rwlock-hold-time/
  grep "info: metrics:" docs/performance/2026-04-26-rwlock-hold-time/repro-server.log | tail -1 \
    | tr ' ' '\n' | grep -E "mg_rwlock_shared_hold|mg_rwlock_shared_max_hold"
  ```

  Expected: two lines for the new counters in the latest emit. Cumulative `mg_rwlock_shared_hold_ns_total` should be a large number (several seconds at minimum); `mg_rwlock_shared_max_hold_ns_observed` should be the longest single hold seen across the run.

- [ ] **Step 5.4: Commit the artifacts.**

  ```bash
  git add docs/performance/2026-04-26-rwlock-hold-time/repro-server.log
  git add docs/performance/2026-04-26-rwlock-hold-time/repro-ingest.log
  git add docs/performance/2026-04-26-rwlock-hold-time/cascade-stacks.txt
  git commit -m "docs(perf): instrumented cascade repro with rwlock hold-time counters

  Re-run of the workers=4 cascade-investigation repro against the
  binary built with the new mg_rwlock_shared_hold_ns_total and
  mg_rwlock_shared_max_hold_ns_observed counters. Hold-time deltas
  drive the secondary bisection in the next commit."
  ```

### Task 6: Update the bisection-analysis.md with the secondary verdict

**Files:**
- Modify: `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md`

Append a new section. The existing primary bisection picked H5 (rwlock saturation) but couldn't distinguish the sub-causes. The new evidence either confirms one or refutes both.

- [ ] **Step 6.1: Identify reference timestamps from the new repro.**

  Same pattern as the prior plan's Task 9 Step 9.1. Use the new T0/T1/T2 from `docs/performance/2026-04-26-rwlock-hold-time/repro-ingest.log` (NOT the prior run's timestamps — it's a different run).

- [ ] **Step 6.2: Tabulate the two new counter trajectories at six checkpoints.**

  Use `awk` / `grep` to extract `mg_rwlock_shared_hold_ns_total` and `mg_rwlock_shared_max_hold_ns_observed` from `info: metrics:` lines at: T0+5s, T1, T1+30s, T1+5min, T2−5s, T2.

  Compute:
  - **Per-acquire average hold** = `(hold_ns_total[Tk+1] − hold_ns_total[Tk]) / (acquired_total[Tk+1] − acquired_total[Tk])` for each interval.
  - **Per-acquire trend** — does the average hold-time per SHARED acquire grow as the run progresses? (If yes, individual queries are getting slower under the lock — the smoking gun for "long MATCH-with-RLS holds the read lock.")
  - **Max hold** — what's the largest single observed hold? (If it's > 1 second, no individual query should hold the read lock that long; confirms the RLS-evaluation hypothesis. If it's < 100 ms, the chokepoint isn't individual-query hold-time.)

- [ ] **Step 6.3: Pick the secondary verdict.**

  Write the new section at the END of `bisection-analysis.md`, structured as:

  ```markdown
  ---

  ## Secondary bisection — rwlock SHARED hold-time (added 2026-04-26)

  After the primary verdict (H5 — rwlock saturation as wall-clock chokepoint),
  the next investigation thread instrumented per-acquire SHARED hold-time on
  `ManagedGraph` (commits <fill>, <fill>, <fill>) and re-ran the same
  workers=4 cascade repro (`docs/performance/2026-04-26-rwlock-hold-time/`).

  ### Reference timestamps

  | Marker | Time | Notes |
  |--------|------|-------|
  | T0 ingest start | <fill> | new run timestamp |
  | T1 last forward progress | <fill> | edges_audited.jsonl exec start |
  | T2 cascade trigger | <fill> | "pipeline failed — retrying file in serial mode" |
  | Δ (T2 − T1) | <fill> | should be ~10 min if H5 still applies |

  ### Hold-time deltas

  | Checkpoint | acquired_total | hold_ns_total | avg-hold-per-acquire (ns) | max_hold_observed (ns) |
  |------------|----------------|---------------|---------------------------|------------------------|
  | T0+5s | <fill> | <fill> | <fill> | <fill> |
  | T1 | <fill> | <fill> | <fill> | <fill> |
  | T1+30s | <fill> | <fill> | <fill> | <fill> |
  | T1+5min | <fill> | <fill> | <fill> | <fill> |
  | T2−5s | <fill> | <fill> | <fill> | <fill> |
  | T2 | <fill> | <fill> | <fill> | <fill> |

  ### Sub-hypothesis verdict

  Pick ONE:

  #### H5a — Long MATCH-with-RLS holds the read lock
  **Signature:** avg-hold-per-acquire grows from sub-microsecond at T0 to
  hundreds-of-ms or more at T1 onwards; max_hold_observed exceeds 1 second
  somewhere between T1 and T2.
  **Verdict:** <Yes / No, with the actual numbers>

  #### H5b — Rwlock implementation is the chokepoint (per-acquire hold is small)
  **Signature:** avg-hold-per-acquire stays small (< 1 ms) throughout the
  run; max_hold_observed stays below ~100 ms; the cumulative
  rwlock_shared_hold_ns_total stays orders-of-magnitude smaller than the
  cumulative rwlock_shared_wait_ns_total. Chokepoint is somewhere inside
  `Io.RwLock.lockSharedUncancelable` itself (kernel futex contention,
  fairness, or the per-graph rwlock's reader-counter being the hot
  cache-line) rather than how long readers actually hold the lock.
  **Verdict:** <Yes / No>

  #### H5c — Neither (something else)
  **Signature:** Hold-time data does not match either H5a or H5b cleanly.
  Likely explanations: the holds are roughly steady-state across the run
  (so neither growing nor truly small), suggesting the cascade is driven
  by a NUMBER-of-acquires phenomenon rather than per-acquire cost. Or the
  holds are small but bursty.
  **Verdict:** <Yes / No>

  ### Recommended next step

  Based on the verdict above:

  - **H5a →** the fix lives in `match_operations.executeMultiNodeMatch`.
    Two candidate fixes: (a) release the read lock between row batches and
    re-acquire (introduces possible inconsistency window — needs design
    review), or (b) take a snapshot reference (read-only view of the graph
    state) at MATCH-start and operate on that snapshot for the full scan
    duration (no inconsistency, but may overcommit memory under long
    scans). Either way, the next investigation thread is "design + plan
    the snapshot or batched-release fix in match_operations.zig."

  - **H5b →** the fix lives in the rwlock implementation. Either replace
    the per-graph `Io.RwLock` with a sharded reader-counter (Linux
    seqlock-style, or a per-CPU counter array summed at writer time),
    or move the cache-line of the rwlock's internal reader counter onto
    its own page to eliminate false sharing. The next investigation
    thread is "profile the rwlock internals — perf record on the
    cascade workload."

  - **H5c →** open a fresh investigation. The hold-time data has refuted
    the narrowest two sub-hypotheses but the cascade still triggers; the
    next investigation should bring NEW dimensions (per-query deadline
    histograms, per-shard work-balance, server-side queue depth at the
    coordinator level).
  ```

  Fill EVERY `<fill>`. Pick the verdict honestly — if the data is genuinely ambiguous, pick H5c and propose the next dimension.

- [ ] **Step 6.4: Commit.**

  ```bash
  git add docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md
  git commit -m "docs(perf): secondary bisection from rwlock hold-time — verdict <H5a|H5b|H5c>

  Hold-time deltas + per-acquire average + observed max across the
  six-checkpoint window. See the new 'Secondary bisection — rwlock
  SHARED hold-time' section at the end of bisection-analysis.md.

  Plan complete: docs/superpowers/plans/2026-04-26-rwlock-hold-time-instrumentation.md"
  ```

---

## Out of scope (separate plans / handoffs)

This plan deliberately scopes to a single track from the prior `bisection-analysis.md`'s recommended next-investigation list. The other three are independent and should be addressed separately:

1. **Per-stream last-activity-time logging** (the secondary recommendation, to disambiguate the 10-min idle-timeout coincidence). Belongs in a sibling plan that adds a per-`QuicConnection` `last_activity_ns` accessor, exposes it via a new gauge, and re-runs the cascade. Estimated 1.5 hours of work; clean follow-up to this plan.

2. **`NoHandshakeKeys` regression in the new quic dep `c7808ed`** (tertiary). Belongs upstream in `~/src/devnw/zig/quic/`. File a brief handoff at `~/src/devnw/zig/quic/docs/2026-04-26-no-handshake-keys-regression.md` (mirror the format of the earlier `~/src/devnw/zig/graph-storage/docs/2026-04-25-thread-pool-v0.2.1-bump-handoff.md`) noting the workers=16 reproduction, the workers=4 partial reproduction, and the auth-cascade failure mode. The fix lives in the quic library's handshake state machine, not in geode.

3. **`quic_total_cwnd_bytes` unbounded growth** (quaternary). Three options:
   - (a) Geode-side display sanity: clamp the gauge sum to `min(sum, 64 MB × N_connections)` in `quic_connection_metrics.totalCongestionWindow` with a short comment explaining "cwnd from NewReno can grow unboundedly during slow-start probing; this clamp is for emit-line readability, not a bug fix."
   - (b) Upstream fix in `~/src/devnw/zig/quic/src/quic/recovery/congestion.zig` to bound `cwnd` by `max(initial_cwnd, bytes_in_flight × 2)` per RFC 9002 §7.4 ("Congestion Window During Recovery"). This is the right architectural fix.
   - (c) Both. Apply (a) as a same-day patch and file (b) as an upstream handoff.
   Recommend (c). Total geode-side work: ~10 lines + 1 commit.

These three should each become their own plan or handoff. They are NOT folded into this plan because they have independent ownership boundaries (#2 is upstream, #3 is upstream + small geode-side, #1 is geode-side but a clean separable feature).

---

## Self-review results

**Spec coverage:**
- Add hold-time atomics → Task 1 ✓
- Wrap acquire sites → Task 2 ✓
- Register with runtime_metrics → Task 3 ✓
- Unit test → Task 4 ✓
- Re-run cascade with new instrumentation → Task 5 ✓
- Secondary bisection (H5a/b/c verdict) → Task 6 ✓

**Placeholder scan:** All `<fill>` slots in §"Task 6 step 6.3" are deliberate — the analyst must fill in the actual numbers from the run. No placeholders in code blocks. No "TBD"/"implement later" anywhere.

**Type consistency:** `rwlock_shared_hold_ns_total` and `rwlock_shared_max_hold_ns_observed` use the same names everywhere (Task 1 declaration → Task 2 acquire sites → Task 3 register calls → Task 4 test → Task 6 verdict table). The metric names (`mg_rwlock_shared_hold_ns_total`, `mg_rwlock_shared_max_hold_ns_observed`) consistently use the `mg_` prefix matching the existing `mg_rwlock_*` set.

**One known unknown:** the `ManagedGraph{}` default-construction in Task 4's test may not compile if the struct has non-default-initialised fields. Step 4.2 calls this out and proposes the fallback. If the fallback is also painful, the test can be skipped (the integration test in Task 5 implicitly verifies the wrap pattern works under real load) — but per the plan's TDD posture, please attempt the unit test first.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-26-rwlock-hold-time-instrumentation.md`.

Total task count: **6 tasks across 3 phases.** Wall-clock estimate:
- Phase 1: ~30 min (3 small commits + smoke test)
- Phase 2: ~20 min (1 unit test + 1 commit)
- Phase 3: ~50 min (~25 min repro + 20 min secondary-bisection writing + 1 commit)
- **Total: ~100 min** including the 25-min cascade repro
