# QUIC-Layer Cascade Investigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify the root cause of the `edges_contains` cascade that triggers ~9m 41s into 16-way `msft-graph` ingest, by adding two narrow instrumentation surfaces (QUIC connection-level metrics + BufferedProtoReader delivery rate), running a controlled load-test comparison, and bisecting what changes at the trigger moment using the new data.

**Architecture:** Investigation-first plan. Two infrastructure tasks (Phases 2 + 3) wire new gauges into the existing `runtime_metrics` periodic-emit loop without changing any application code paths. Two analysis tasks (Phases 1 + 4) use that data to bound the search space and identify the failing subsystem. The instrumentation is purposefully read-only; nothing in the application changes behaviour.

**Tech Stack:** Zig 0.16. `runtime_metrics` registry at `src/server/runtime_metrics.zig` (counter API: `Registry.register(name, *atomic.Value(u64))`; serializer: `snapshotInto(allocator, *ArrayList(u8))`; periodic emit at `src/server/main.zig:901-918` runs every 5 s). QUIC connection state at `~/src/devnw/zig/quic/src/quic/conn.zig:472` (`Connection.rtt_app: recovery.RttState`, `Connection.cc_nr: recovery.NewReno`, `Connection.local_max_data`, `Connection.peer_max_data`). Geode's QUIC wrapper at `src/transport/quic.zig:439` (exposes `connections.items`). `BufferedProtoReader.nextMessage` at `src/server/quic_connection_handler.zig:945-1046`. Existing repro driver at `/tmp/run-rwlock-fairness-repro.sh`. Existing stack-capture watcher at `/tmp/capture-cascade-stacks.sh`. Cascade signature already characterised in `docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md` §"Part 2 — Post-fix re-analysis".

---

## File structure

| File | Status | Responsibility |
|------|--------|----------------|
| `src/server/runtime_metrics.zig` | Modify | Add `Gauge` type + `registerGauge(name, callback_fn)`. Snapshot extended to call gauge callbacks. |
| `src/server/quic_connection_metrics.zig` | Create | Per-connection-aggregate gauges: bytes-in-flight, smoothed-RTT min/max, cwnd min/max, flow-control headroom. Owns the aggregation function called from the emit loop. |
| `src/server/buffered_proto_reader_metrics.zig` | Create | Process-wide counters for `BufferedProtoReader`: messages-delivered, would-block-loop-iterations, bytes-read. Owns the atomics. |
| `src/server/quic_connection_handler.zig` | Modify | At `nextMessage` delivery point (line 1003) and at the `WouldBlock` retry loop (lines 1009-1029): increment the new counters. Two exact insertions. |
| `src/server/main.zig` | Modify | At lines 879-901 (the existing metrics-registry init block): also init the new metric modules and pass their pointers to the emit loop's context so the refresh phase runs before snapshot. |
| `docs/performance/2026-04-25-quic-cascade-investigation/` | Create (dir) | New investigation evidence dir. Phase 4 captures go here: `repro-instrumented.{server,ingest}.log`, `cascade-stacks-instrumented.txt`, `bisection-analysis.md`. |
| `benchmarks/loadtest/baseline.jsonl` | Read-only | Existing baseline. Compared against in Phase 1. |

---

## Phase 1 — Loadtest baseline cross-check (control test)

This phase runs first because it is the cheapest control test and it bounds the rest of the investigation. If `loadtest-compare` shows QPS@16 unaffected vs the saved baseline, the cascade is **specific to msft-graph's pattern** (long-lived pinned QUIC connections + large per-batch payloads). If QPS@16 has regressed, the cascade is broader and any sustained 16-way load reproduces it. Either result narrows Phase 4's bisection.

### Task 1: Run loadtest-compare against current binary

**Files:**
- Read: `benchmarks/loadtest/baseline.jsonl`
- Read: `Makefile` target `loadtest-compare` (already exists per CLAUDE.md "Load Test Baseline Tracking")
- Create (committed): `docs/performance/2026-04-25-quic-cascade-investigation/loadtest-control.md`

- [ ] **Step 1.1: Confirm sibling test harness is present.**

  ```bash
  test -d ../geode-test-harness && echo "harness present" || echo "MISSING"
  ```

  Expected: `harness present`. If MISSING, the harness must be cloned at `../geode-test-harness` per CLAUDE.md before this task can run.

- [ ] **Step 1.2: Build release binary if not already.**

  ```bash
  ls -la zig-out/bin/geode 2>&1 | head -1
  # If older than current HEAD, rebuild:
  make release 2>&1 | tail -3
  ```

  Expected: a `geode` binary exists and matches the current commit (check size > 200 MB after the 2026-04-25 quic bump).

- [ ] **Step 1.3: Run loadtest in the harness.**

  ```bash
  cd ../geode-test-harness
  GEODE_ADMIN_PASSWORD=Geode1234Abc \
    LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=Geode1234Abc" \
    make loadtest-go 2>&1 | tee /tmp/loadtest-control-run.log
  cd -
  ```

  Expected: 5–10 minutes wall-clock. Produces a results file at `../geode-test-harness/results/loadtest-results.jsonl` (or similar — confirm exact path from the harness Makefile).

- [ ] **Step 1.4: Compare against baseline.**

  ```bash
  make loadtest-compare 2>&1 | tee /tmp/loadtest-compare.log
  ```

  Read the output for the c=16 row (or the closest concurrency level the harness exercises).
  Record:
  - Current c=16 QPS
  - Baseline c=16 QPS
  - Ratio (current / baseline)
  - p50 latency: current vs baseline

- [ ] **Step 1.5: Write the control finding.**

  Create `docs/performance/2026-04-25-quic-cascade-investigation/loadtest-control.md`:

  ```markdown
  # Loadtest control test — 2026-04-25

  **Binary tested:** geode HEAD (after quic dep bump to c7808ed)
  **Baseline:** benchmarks/loadtest/baseline.jsonl (committed reference)

  ## Result

  | Concurrency | Current QPS | Baseline QPS | Ratio | p50 current | p50 baseline | Verdict |
  |-------------|-------------|--------------|-------|-------------|--------------|---------|
  | c=16 | <fill from compare output> | <fill> | <fill> | <fill> | <fill> | <PASS/REGRESS> |

  ## Interpretation

  - **If ratio ≥ 0.8 AND p50 increase ≤ 20%:** The QUIC transport is healthy at sustained 16-way load with simple queries. The cascade is therefore **msft-graph-specific** — driven by long-lived pinned connections + large batch payloads + the specific message pattern (`batch begin tx` then `apply` chunks). Phase 4's bisection should focus on connection-pinning lifecycle and per-stream backlog under burst load, not on general QUIC throughput.
  - **If ratio < 0.8 OR p50 increase > 20%:** The cascade is broader. The QUIC layer (or something below it) regresses under any sustained 16-way load. Phase 4's bisection should focus on the regression vs the baseline commit. The likely culprit set widens to include the recent quic protocol-fix commits (`13c714a`, `0aa17fc`, `43814de`, `c7808ed`) and any geode-side change between baseline and HEAD.

  ## Raw artifacts

  - `/tmp/loadtest-control-run.log`
  - `/tmp/loadtest-compare.log`
  ```

  Fill in the table from the compare output. Pick the verdict.

- [ ] **Step 1.6: Commit.**

  ```bash
  git add docs/performance/2026-04-25-quic-cascade-investigation/loadtest-control.md
  git commit -m "docs(perf): loadtest control test result — bounds the QUIC cascade hypothesis"
  ```

---

## Phase 2 — Wire QUIC connection-level metrics into runtime_metrics

This phase exposes the QUIC `Connection` state already maintained by the vendored quic library (RTT, congestion window, bytes in flight, flow-control window) as gauges in geode's existing periodic emit log. The values are *gauges* (current snapshot), not counters (monotonic increment), so we extend `runtime_metrics.Registry` with a `Gauge` type that supports a callback. The aggregation function iterates all active QUIC connections and reduces to per-process min/max/sum.

### Task 2: Add `Gauge` to runtime_metrics.zig

**Files:**
- Modify: `src/server/runtime_metrics.zig`

The existing `Counter` reads a `*std.atomic.Value(u64)` on snapshot. Gauges read via a callback so they can pull live values from foreign data structures (the QUIC `Connection` state) without owning the atomic.

- [ ] **Step 2.1: Add `Gauge` struct + register API.**

  Append after the `Counter` struct definition (currently at `src/server/runtime_metrics.zig:15-18`):

  ```zig
  /// `name` must outlive the registry. `callback` is invoked at snapshot
  /// time and must be cheap (no I/O, no allocations, no locks held longer
  /// than a single field read). Returns the current value as a u64.
  pub const Gauge = struct {
      name: []const u8,
      callback: *const fn (ctx: *anyopaque) u64,
      ctx: *anyopaque,
  };
  ```

  Inside `Registry`, add a sibling list:

  ```zig
  pub const Registry = struct {
      allocator: std.mem.Allocator,
      counters: std.ArrayList(Counter),
      gauges: std.ArrayList(Gauge),  // NEW
      mutex: std.Io.Mutex = std.Io.Mutex.init,
  ```

  Update `init` to initialise the new list:

  ```zig
      pub fn init(allocator: std.mem.Allocator) !*Registry {
          const self = try allocator.create(Registry);
          self.* = .{
              .allocator = allocator,
              .counters = std.ArrayList(Counter).empty,
              .gauges = std.ArrayList(Gauge).empty,  // NEW
          };
          return self;
      }
  ```

  Update `deinit`:

  ```zig
      pub fn deinit(self: *Registry) void {
          self.counters.deinit(self.allocator);
          self.gauges.deinit(self.allocator);  // NEW
          self.allocator.destroy(self);
      }
  ```

  Add `registerGauge` after `register`:

  ```zig
      pub fn registerGauge(
          self: *Registry,
          name: []const u8,
          callback: *const fn (ctx: *anyopaque) u64,
          ctx: *anyopaque,
      ) !void {
          const io = std.Io.Threaded.global_single_threaded.io();
          self.mutex.lockUncancelable(io);
          defer self.mutex.unlock(io);
          try self.gauges.append(self.allocator, .{
              .name = name,
              .callback = callback,
              .ctx = ctx,
          });
      }
  ```

- [ ] **Step 2.2: Extend `snapshotInto` to emit gauges after counters.**

  Current implementation (lines 46-68) iterates `self.counters.items` only. Replace the body's loop with:

  ```zig
      pub fn snapshotInto(
          self: *Registry,
          allocator: std.mem.Allocator,
          out: *std.ArrayList(u8),
      ) !void {
          const io = std.Io.Threaded.global_single_threaded.io();
          self.mutex.lockUncancelable(io);
          defer self.mutex.unlock(io);

          var first = true;
          for (self.counters.items) |c| {
              if (!first) try out.append(allocator, ' ');
              first = false;
              try out.appendSlice(allocator, c.name);
              try out.append(allocator, '=');
              const val = c.ptr.load(.acquire);
              const str = try std.fmt.allocPrint(allocator, "{d}", .{val});
              defer allocator.free(str);
              try out.appendSlice(allocator, str);
          }
          for (self.gauges.items) |g| {
              if (!first) try out.append(allocator, ' ');
              first = false;
              try out.appendSlice(allocator, g.name);
              try out.append(allocator, '=');
              const val = g.callback(g.ctx);
              const str = try std.fmt.allocPrint(allocator, "{d}", .{val});
              defer allocator.free(str);
              try out.appendSlice(allocator, str);
          }
      }
  ```

- [ ] **Step 2.3: Build + smoke-test.**

  ```bash
  make build 2>&1 | tail -5
  ```

  Expected: clean build. If the build fails, the most likely cause is missing `std.ArrayList(Gauge).empty` initialiser — confirm Zig 0.16 syntax matches the existing `Counter` initialiser at line 29.

- [ ] **Step 2.4: Commit.**

  ```bash
  git add src/server/runtime_metrics.zig
  git commit -m "feat(metrics): add Gauge type to runtime_metrics for read-on-snapshot values

  Counters monotonically increment; QUIC connection state (RTT, cwnd,
  bytes in flight, flow-control headroom) is a snapshot gauge that
  needs to be sampled at emit time. Adds Gauge struct + registerGauge
  + snapshotInto extension. No behaviour change for existing counters."
  ```

### Task 3: Add `quic_connection_metrics.zig` aggregation module

**Files:**
- Create: `src/server/quic_connection_metrics.zig`

This module owns the gauge-callback functions. Each callback iterates the QUIC transport's connection list, reduces to a single u64, and returns it. Five gauges total (one callback per gauge). All gauges share a single context: a pointer to the QUIC transport.

- [ ] **Step 3.1: Find the exact accessor for active QUIC connections.**

  ```bash
  grep -n "pub fn\|connections" src/transport/quic.zig | head -20
  ```

  Expected: `self.connections.items` (per `src/transport/quic.zig:439`). The struct field is unconditionally accessible because the geode wrapper owns it. If the field is private, add a `pub fn activeConnections(self: *const QuicTransport) []const *quic_lib.Connection` accessor first. **Note the exact import alias used for the quic library** (the file uses `@import("quic")` with type alias `quic_lib`).

- [ ] **Step 3.2: Write the module.**

  Write `src/server/quic_connection_metrics.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Per-process aggregation of QUIC `Connection` state for the
  //! runtime_metrics gauge surface. Reads are snapshot-time only —
  //! these are gauges, not counters. Iteration over the active
  //! connection list is read-only and short-lived; the QUIC transport
  //! itself protects the list with its own internal mutex.

  const std = @import("std");
  const quic_lib = @import("quic");
  const quic_transport_mod = @import("../transport/quic.zig");

  const QuicTransport = quic_transport_mod.QuicTransport;

  pub const Ctx = struct {
      transport: *QuicTransport,
  };

  /// Number of active QUIC connections.
  pub fn activeConnections(ctx_ptr: *anyopaque) u64 {
      const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
      // Direct field read — the QUIC transport's connections list is
      // append-only during steady state; a stale read of `.len` is fine
      // for an emit-time gauge.
      return ctx.transport.connections.items.len;
  }

  /// Sum of `cc_nr.bytes_in_flight` across all active connections.
  /// Spikes here suggest the congestion window is full — packets cannot
  /// be sent until ACKs free up credit.
  pub fn totalBytesInFlight(ctx_ptr: *anyopaque) u64 {
      const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
      var total: u64 = 0;
      for (ctx.transport.connections.items) |conn| {
          total += conn.cc_nr.bytes_in_flight;
      }
      return total;
  }

  /// Sum of `cc_nr.cwnd` across all active connections (bytes).
  /// If the sum collapses while bytes_in_flight stays high, congestion
  /// control is throttling — likely loss event.
  pub fn totalCongestionWindow(ctx_ptr: *anyopaque) u64 {
      const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
      var total: u64 = 0;
      for (ctx.transport.connections.items) |conn| {
          total += conn.cc_nr.cwnd;
      }
      return total;
  }

  /// Min smoothed RTT across active connections, in nanoseconds.
  /// 0 if no active connections. A floor that climbs means the
  /// network path itself is slowing.
  pub fn minSmoothedRttNs(ctx_ptr: *anyopaque) u64 {
      const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
      var min_val: u64 = std.math.maxInt(u64);
      var any: bool = false;
      for (ctx.transport.connections.items) |conn| {
          const v = conn.rtt_app.smoothed_rtt_ns;
          if (v < min_val) min_val = v;
          any = true;
      }
      return if (any) min_val else 0;
  }

  /// Max smoothed RTT across active connections, in nanoseconds.
  /// A spike here on one connection means that connection is suffering
  /// disproportionately.
  pub fn maxSmoothedRttNs(ctx_ptr: *anyopaque) u64 {
      const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
      var max_val: u64 = 0;
      for (ctx.transport.connections.items) |conn| {
          const v = conn.rtt_app.smoothed_rtt_ns;
          if (v > max_val) max_val = v;
      }
      return max_val;
  }

  /// Min flow-control headroom (peer_max_data − bytes_in_flight) across
  /// connections, in bytes. A floor of 0 means at least one connection
  /// has saturated the receiver's advertised window — sender cannot send
  /// more until peer issues a MAX_DATA frame.
  pub fn minFlowControlHeadroom(ctx_ptr: *anyopaque) u64 {
      const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
      var min_val: u64 = std.math.maxInt(u64);
      var any: bool = false;
      for (ctx.transport.connections.items) |conn| {
          const sent = conn.cc_nr.bytes_in_flight;
          const cap = conn.peer_max_data;
          const headroom = if (cap > sent) cap - sent else 0;
          if (headroom < min_val) min_val = headroom;
          any = true;
      }
      return if (any) min_val else 0;
  }
  ```

- [ ] **Step 3.3: Verify the module compiles in isolation.**

  ```bash
  make build 2>&1 | tail -10
  ```

  Expected: clean build. The module is not yet wired into `main.zig` — this step only catches type errors.

  **Likely issue:** if the field names on `Connection` differ (e.g., `cc_nr` may not be the active congestion controller — geode might use the Cubic variant `cc_cubic`). Confirm by reading `~/src/devnw/zig/quic/src/quic/conn.zig:703-704` which currently shows both `cc_nr: recovery.NewReno` and `cc_cubic: recovery.Cubic` as fields. If geode selects Cubic at runtime, swap the references — but `bytes_in_flight` and `cwnd` are present on both per `~/src/devnw/zig/quic/src/quic/recovery/congestion.zig:16-18`.

- [ ] **Step 3.4: Commit.**

  ```bash
  git add src/server/quic_connection_metrics.zig
  git commit -m "feat(metrics): aggregate QUIC connection state as runtime_metrics gauges

  Six gauges: active_connections, total_bytes_in_flight,
  total_cwnd, min_smoothed_rtt_ns, max_smoothed_rtt_ns,
  min_flow_control_headroom. Reduces over QuicTransport.connections
  at snapshot time. Read-only — does not touch Connection state."
  ```

### Task 4: Wire the QUIC gauges into the existing emit loop

**Files:**
- Modify: `src/server/main.zig` (around lines 879-901, the metrics-registry init block)

The existing init block (commit `aa9708d0`) creates the registry and submits the emit loop. We add: (1) a heap-allocated `quic_connection_metrics.Ctx` initialised after the QUIC transport is up, (2) six `registerGauge` calls. The emit loop's body is unchanged — `snapshotInto` already iterates gauges after Task 2.

- [ ] **Step 4.1: Locate the registration block.**

  ```bash
  grep -n "setGlobalRegistry\|metrics_registry" src/server/main.zig | head -5
  ```

  Confirm the block is around lines 879-883 (init), 901 (`pool.submitDefault`).

- [ ] **Step 4.2: Add the import + Ctx allocation.**

  Near the other server-internal imports (top of `main.zig`), add:

  ```zig
  const quic_metrics = @import("quic_connection_metrics.zig");
  ```

  After `transport` is initialised (the transport must already exist at runtime, since QUIC is up before the handler thread pool is submitted), and AFTER `metrics_registry` is created (line 880) but BEFORE the emit loop is submitted (line 901), insert:

  ```zig
          // Allocate the QUIC metrics context. Lives until server shutdown
          // so the gauge callbacks can dereference it from the emit loop.
          const quic_metrics_ctx = try gpa.create(quic_metrics.Ctx);
          defer gpa.destroy(quic_metrics_ctx);
          quic_metrics_ctx.* = .{ .transport = &transport };

          try metrics_registry.registerGauge(
              "quic_active_connections",
              quic_metrics.activeConnections,
              quic_metrics_ctx,
          );
          try metrics_registry.registerGauge(
              "quic_total_bytes_in_flight",
              quic_metrics.totalBytesInFlight,
              quic_metrics_ctx,
          );
          try metrics_registry.registerGauge(
              "quic_total_cwnd_bytes",
              quic_metrics.totalCongestionWindow,
              quic_metrics_ctx,
          );
          try metrics_registry.registerGauge(
              "quic_min_smoothed_rtt_ns",
              quic_metrics.minSmoothedRttNs,
              quic_metrics_ctx,
          );
          try metrics_registry.registerGauge(
              "quic_max_smoothed_rtt_ns",
              quic_metrics.maxSmoothedRttNs,
              quic_metrics_ctx,
          );
          try metrics_registry.registerGauge(
              "quic_min_flow_control_headroom",
              quic_metrics.minFlowControlHeadroom,
              quic_metrics_ctx,
          );
  ```

- [ ] **Step 4.3: Build + smoke-test.**

  ```bash
  make build 2>&1 | tail -10
  GEODE_ADMIN_PASSWORD=Geode1234Abc nohup zig-out/bin/geode serve \
    --data-dir /tmp/geode-quic-metrics-smoke \
    --listen 127.0.0.1:3173 --log-level info \
    > /tmp/geode-smoke.log 2>&1 &
  SMOKE_PID=$!
  sleep 8
  zig-out/bin/geode query --server 127.0.0.1:3173 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session "RETURN 1 AS ok" > /dev/null 2>&1
  sleep 7
  grep -c "quic_active_connections=" /tmp/geode-smoke.log
  grep "metrics:" /tmp/geode-smoke.log | tail -2
  kill -9 $SMOKE_PID 2>/dev/null
  rm -rf /tmp/geode-quic-metrics-smoke
  ```

  Expected: at least 1 line containing `quic_active_connections=`, the latest `metrics:` line includes all six new `quic_*` keys, and `quic_active_connections` is ≥ 1.

- [ ] **Step 4.4: Commit.**

  ```bash
  git add src/server/main.zig
  git commit -m "feat(metrics): register six QUIC connection gauges in the emit loop

  Wire quic_connection_metrics.Ctx into the existing periodic-emit loop
  so QUIC connection state (active_connections, total_bytes_in_flight,
  total_cwnd, min/max_smoothed_rtt_ns, min_flow_control_headroom)
  appears in 'info: metrics:' lines every 5 s. Read-only at emit time.

  Drives the QUIC-cascade investigation in
  docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md
  Phase 4 (bisect the 9-min hang)."
  ```

---

## Phase 3 — Instrument BufferedProtoReader delivery rate

`BufferedProtoReader.nextMessage` (`src/server/quic_connection_handler.zig:972-1046`) is the single read-side bottleneck on the server. Every incoming client message lands here. Two counters:

- `proto_reader_messages_delivered_total` — incremented when `nextMessage` returns a parsed `ClientPacket`. If this counter stops climbing while client load is sustained, the cascade is a delivery-side problem.
- `proto_reader_would_block_loop_iterations_total` — incremented each time the inner `WouldBlock` loop sleeps waiting for the QUIC poll thread. If this climbs without bound while messages_delivered is flat, server-side handlers are spinning waiting for data that never arrives.

The deltas between successive emits tell us the per-5s rate.

### Task 5: Add `buffered_proto_reader_metrics.zig`

**Files:**
- Create: `src/server/buffered_proto_reader_metrics.zig`

- [ ] **Step 5.1: Write the module.**

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Process-wide counters for `BufferedProtoReader.nextMessage` —
  //! the server's single read-side QUIC entry point. These are
  //! monotonic-increment counters (not gauges); deltas between
  //! periodic emits give the per-interval rate.

  const std = @import("std");

  pub var messages_delivered_total = std.atomic.Value(u64).init(0);
  pub var would_block_loop_iterations_total = std.atomic.Value(u64).init(0);
  pub var bytes_read_total = std.atomic.Value(u64).init(0);
  pub var eof_total = std.atomic.Value(u64).init(0);

  /// Called from main.zig after the registry is created.
  pub fn registerAll(registry: anytype) !void {
      try registry.register("proto_reader_messages_delivered_total", &messages_delivered_total);
      try registry.register("proto_reader_would_block_loop_iterations_total", &would_block_loop_iterations_total);
      try registry.register("proto_reader_bytes_read_total", &bytes_read_total);
      try registry.register("proto_reader_eof_total", &eof_total);
  }
  ```

- [ ] **Step 5.2: Build (module not yet wired into the reader).**

  ```bash
  make build 2>&1 | tail -5
  ```

  Expected: clean build.

- [ ] **Step 5.3: Commit.**

  ```bash
  git add src/server/buffered_proto_reader_metrics.zig
  git commit -m "feat(metrics): add BufferedProtoReader counter atomics

  Four counters: messages_delivered_total, would_block_loop_iterations_total,
  bytes_read_total, eof_total. Will be incremented from
  BufferedProtoReader.nextMessage in the next commit and registered
  with runtime_metrics from main.zig."
  ```

### Task 6: Increment the counters from `nextMessage`

**Files:**
- Modify: `src/server/quic_connection_handler.zig`

Three insertion points in `nextMessage` (function spans lines 972-1046):

1. After the successful decode and `start_index` update (just before the `return msg;` at line 1003) — increment `messages_delivered_total`.
2. Inside the `WouldBlock` branch (between line 1010 and the `continue;` at 1028) — increment `would_block_loop_iterations_total`.
3. After a successful `stream.read` returning `n` bytes (just after line 1031 / before line 1044) — add `n` to `bytes_read_total`.
4. At the EOF branch (lines 1035-1041) — increment `eof_total` once when returning `null`.

- [ ] **Step 6.1: Add the import at the top of `quic_connection_handler.zig`.**

  Near the other server-internal imports (file head), add:

  ```zig
  const proto_reader_metrics = @import("buffered_proto_reader_metrics.zig");
  ```

- [ ] **Step 6.2: Insertion 1 — message delivered.**

  Find this block (currently at lines 999-1003):

  ```zig
                  // Consume bytes
                  self.start_index += 4 + msg_len;
                  self.compactBuffer();
                  return msg;
  ```

  Replace with:

  ```zig
                  // Consume bytes
                  self.start_index += 4 + msg_len;
                  self.compactBuffer();
                  _ = proto_reader_metrics.messages_delivered_total.fetchAdd(1, .monotonic);
                  return msg;
  ```

- [ ] **Step 6.3: Insertion 2 — would-block loop iteration.**

  Find this block (currently around lines 1009-1010):

  ```zig
              if (err == error.WouldBlock) {
                  would_block_attempts += 1;
  ```

  Replace with:

  ```zig
              if (err == error.WouldBlock) {
                  would_block_attempts += 1;
                  _ = proto_reader_metrics.would_block_loop_iterations_total.fetchAdd(1, .monotonic);
  ```

- [ ] **Step 6.4: Insertion 3 — bytes read on success + EOF.**

  Find this block (currently around lines 1033-1044):

  ```zig
              would_block_attempts = 0;

              if (n == 0) {
                  if (self.start_index == self.buffer.items.len) {
                      // Clean EOF
                      return null; // Return optional null for EOF
                  }
                  // Partial message EOF
                  return error.UnexpectedEndOfStream;
              }

              try self.buffer.appendSlice(self.allocator, self.read_buf[0..n]);
  ```

  Replace with:

  ```zig
              would_block_attempts = 0;

              if (n == 0) {
                  if (self.start_index == self.buffer.items.len) {
                      // Clean EOF
                      _ = proto_reader_metrics.eof_total.fetchAdd(1, .monotonic);
                      return null; // Return optional null for EOF
                  }
                  // Partial message EOF
                  return error.UnexpectedEndOfStream;
              }

              _ = proto_reader_metrics.bytes_read_total.fetchAdd(@as(u64, n), .monotonic);
              try self.buffer.appendSlice(self.allocator, self.read_buf[0..n]);
  ```

- [ ] **Step 6.5: Build to verify the four insertions are syntactically correct.**

  ```bash
  make build 2>&1 | tail -5
  ```

  Expected: clean build. If it fails, the most likely cause is a missing brace level — re-check that each insertion stays inside the existing control-flow scope.

- [ ] **Step 6.6: Commit.**

  ```bash
  git add src/server/quic_connection_handler.zig
  git commit -m "feat(metrics): increment BufferedProtoReader counters at delivery + retry sites

  Four insertions in nextMessage:
  - messages_delivered_total++ on successful parse
  - would_block_loop_iterations_total++ in WouldBlock branch
  - bytes_read_total += n on successful stream.read
  - eof_total++ on clean EOF

  Counters are .monotonic atomics; surfaced via runtime_metrics in
  the next commit (main.zig wire-up)."
  ```

### Task 7: Register the BufferedProtoReader counters from main

**Files:**
- Modify: `src/server/main.zig`

- [ ] **Step 7.1: Add the import.**

  Near the other server-internal imports, add:

  ```zig
  const proto_reader_metrics = @import("buffered_proto_reader_metrics.zig");
  ```

- [ ] **Step 7.2: Register from the same block as Task 4.**

  Right after the QUIC `registerGauge` calls added in Task 4.2, add:

  ```zig
          try proto_reader_metrics.registerAll(metrics_registry);
  ```

- [ ] **Step 7.3: Smoke test that the counters appear and increment.**

  ```bash
  make build 2>&1 | tail -5
  GEODE_ADMIN_PASSWORD=Geode1234Abc nohup zig-out/bin/geode serve \
    --data-dir /tmp/geode-proto-metrics-smoke \
    --listen 127.0.0.1:3174 --log-level info \
    > /tmp/geode-proto-smoke.log 2>&1 &
  SMOKE_PID=$!
  sleep 8
  for i in 1 2 3 4 5; do
    zig-out/bin/geode query --server 127.0.0.1:3174 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session "RETURN $i AS x" > /dev/null 2>&1
  done
  sleep 7
  grep "metrics:" /tmp/geode-proto-smoke.log | tail -1 | tr ' ' '\n' | grep proto_reader
  kill -9 $SMOKE_PID 2>/dev/null
  rm -rf /tmp/geode-proto-metrics-smoke
  ```

  Expected: four lines, with `proto_reader_messages_delivered_total ≥ 5` (the queries) and `proto_reader_bytes_read_total > 0`.

- [ ] **Step 7.4: Commit.**

  ```bash
  git add src/server/main.zig
  git commit -m "feat(metrics): register four BufferedProtoReader counters in the emit loop

  proto_reader_{messages_delivered,would_block_loop_iterations,bytes_read,eof}_total
  appear alongside the QUIC gauges in 'info: metrics:' lines every 5 s.
  Drives the QUIC-cascade investigation in
  docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md
  Phase 4 (bisect the 9-min hang)."
  ```

---

## Phase 4 — Re-run cascade with the new instrumentation, bisect the 9-min hang

This phase produces no code changes. It runs the existing repro script (which already reproduces the cascade reliably at ~9m 41s in) against the now-instrumented binary, then analyses the rich emit log to identify which subsystem changes state at the trigger moment.

### Task 8: Run the instrumented cascade repro

**Files:**
- Create (committed): `docs/performance/2026-04-25-quic-cascade-investigation/repro-server.log`
- Create (committed): `docs/performance/2026-04-25-quic-cascade-investigation/repro-ingest.log`
- Create (committed): `docs/performance/2026-04-25-quic-cascade-investigation/cascade-stacks.txt`
- Read: `/tmp/run-rwlock-fairness-repro.sh` (existing repro driver)
- Read: `/tmp/capture-cascade-stacks.sh` (existing watcher)

- [ ] **Step 8.1: Verify the existing repro script will pick up the rebuilt binary.**

  ```bash
  head -25 /tmp/run-rwlock-fairness-repro.sh | grep -E "REPRO_DIR|zig-out|GEODE_DSN"
  ```

  Note that the script writes outputs to `docs/performance/2026-04-25-enterprise-rwlock-fairness/` by default. We want the new outputs in `docs/performance/2026-04-25-quic-cascade-investigation/` to keep the rwlock-fairness investigation directory frozen.

- [ ] **Step 8.2: Copy the script and redirect output paths.**

  ```bash
  cp /tmp/run-rwlock-fairness-repro.sh /tmp/run-quic-investigation-repro.sh
  sed -i 's|docs/performance/2026-04-25-enterprise-rwlock-fairness|docs/performance/2026-04-25-quic-cascade-investigation|g' /tmp/run-quic-investigation-repro.sh
  sed -i 's|/tmp/geode-rwlock-fairness|/tmp/geode-quic-investigation|g' /tmp/run-quic-investigation-repro.sh
  sed -i 's|/tmp/rwlock-fairness-data|/tmp/quic-investigation-data|g' /tmp/run-quic-investigation-repro.sh
  sed -i 's|127.0.0.1:3172|127.0.0.1:3175|g' /tmp/run-quic-investigation-repro.sh
  mkdir -p docs/performance/2026-04-25-quic-cascade-investigation
  ```

- [ ] **Step 8.3: Run the instrumented repro (~25 min wall-clock).**

  ```bash
  bash /tmp/run-quic-investigation-repro.sh
  ```

  Expected wall-clock: ingest will time out at 1500s; the watcher captures stacks at the cascade-trigger moment (~9m 41s in). Total wall-clock ≤ 26 min.

- [ ] **Step 8.4: Verify all three artifacts landed.**

  ```bash
  ls -la docs/performance/2026-04-25-quic-cascade-investigation/
  ```

  Expected: `cascade-stacks.txt`, `repro-ingest.log`, `repro-server.log` all non-empty. The server log should contain `info: metrics:` lines with both `quic_*` gauges and `proto_reader_*` counters.

- [ ] **Step 8.5: Commit the artifacts.**

  ```bash
  git add docs/performance/2026-04-25-quic-cascade-investigation/repro-server.log
  git add docs/performance/2026-04-25-quic-cascade-investigation/repro-ingest.log
  git add docs/performance/2026-04-25-quic-cascade-investigation/cascade-stacks.txt
  git commit -m "docs(perf): instrumented cascade repro — server, ingest, stacks (Phase 4)

  Server log includes the new QUIC connection gauges and BufferedProtoReader
  counters every 5 s. Stack capture taken automatically at cascade trigger.
  Bisection analysis follows in the next commit."
  ```

### Task 9: Bisect the 9-min hang from the instrumented data

**Files:**
- Read: `docs/performance/2026-04-25-quic-cascade-investigation/repro-server.log`
- Read: `docs/performance/2026-04-25-quic-cascade-investigation/repro-ingest.log`
- Create (committed): `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md`

- [ ] **Step 9.1: Identify the three reference timestamps.**

  ```bash
  cd docs/performance/2026-04-25-quic-cascade-investigation
  grep -E "ingest start|pipeline progress.*flushed=281|pipeline failed — retrying" repro-ingest.log | head -5
  ```

  Expected three timestamps:
  - `T0` = ingest start (e.g. `2026-04-25T23:13:54Z`)
  - `T1` = last forward progress at `flushed=281` (~14-19 s after T0)
  - `T2` = cascade trigger ("pipeline failed — retrying file in serial mode") (~9m 41s after T0)

  Record the exact timestamps; everything below references them.

- [ ] **Step 9.2: Extract the metric trajectory at six checkpoints.**

  Open the server log; pick six representative `info: metrics:` lines (T0+5s, T1, T1+30s, T1+5min, T2−5s, T2). For each, write down the values of:

  - `quic_active_connections`
  - `quic_total_bytes_in_flight`
  - `quic_total_cwnd_bytes`
  - `quic_min_smoothed_rtt_ns`, `quic_max_smoothed_rtt_ns`
  - `quic_min_flow_control_headroom`
  - `proto_reader_messages_delivered_total`
  - `proto_reader_would_block_loop_iterations_total`
  - `proto_reader_bytes_read_total`
  - `mg_rwlock_shared_acquired_total`
  - `mg_rwlock_exclusive_wait_ns_total`

- [ ] **Step 9.3: Compute deltas across the six checkpoints.**

  For each counter, compute the per-interval rate: `(value[Tk+1] − value[Tk]) / (Tk+1 − Tk seconds)`.

  Look for the boundary at which a rate goes to zero. Specifically:

  - **`proto_reader_messages_delivered_total` rate**: if it goes to zero between T1 and T2, the cascade is **server-side delivery silence** — incoming client messages are not being parsed by the server. The bottleneck is at or before `BufferedProtoReader.nextMessage`.
  - **`proto_reader_would_block_loop_iterations_total` rate**: if it climbs steadily while `messages_delivered` rate is zero, server handler threads are correctly spin-waiting for data that the QUIC layer is not delivering.
  - **`proto_reader_bytes_read_total` rate**: distinguishes "no data on the wire" from "data on the wire but not parseable yet". If bytes_read rate > 0 but messages_delivered rate = 0, partial messages are accumulating without ever forming a complete frame.
  - **`quic_total_bytes_in_flight` trajectory**: if it spikes then plateaus at the trigger time, the congestion window is full — the client cannot send more until ACKs free credit. Cross-reference with `quic_total_cwnd_bytes`.
  - **`quic_min_flow_control_headroom`**: if it collapses to 0 around T1 and stays there until T2, the cascade is **flow-control deadlock** — at least one connection has saturated the receiver's MAX_DATA window and the server is not advancing it.
  - **`quic_max_smoothed_rtt_ns` spike**: if it climbs sharply between T1 and T2, the network path itself is degrading (packet loss, queue buildup).
  - **`mg_rwlock_*` trajectory**: re-confirms the prior observation. `exclusive_wait_ns_total` should freeze early; shared rate should drop.

- [ ] **Step 9.4: Cross-reference with the stack capture taken at T2.**

  ```bash
  awk '/^Thread / {capture=1; depth=-1; next} capture && /^#/ {depth++; if (depth==4) {print; capture=0}}' cascade-stacks.txt | sed -E 's/^#4 +0x[0-9a-f]+ +in +//; s/ \(.*//; s/[ \t]+at .*//' | sort | uniq -c | sort -rn | head -10
  ```

  Compare to the post-fix capture in `docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks-postthreadpoolfix.txt` (same pattern? same number of `runStreamQueryLoop` threads idle in `BufferedProtoReader.nextMessage`?).

- [ ] **Step 9.5: Pick the verdict and write the analysis.**

  Based on the metric deltas (Step 9.3) and the stack pattern (Step 9.4), one of the four hypotheses below should fit the data cleanly. Write `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md`:

  ```markdown
  # 9-min hang bisection — 2026-04-25

  ## Reference timestamps

  | Marker | Time | Notes |
  |--------|------|-------|
  | T0 ingest start | <fill> | |
  | T1 last forward progress (281 nodes flushed) | <fill> | |
  | T2 cascade trigger | <fill> | "pipeline failed — retrying file in serial mode" |
  | Δ (T2 − T1) | ~9 min | The hang |

  ## Metric deltas across the hang

  | Metric | T0+5s rate | T1 rate | T1+30s rate | T2−5s rate |
  |--------|------------|---------|-------------|------------|
  | proto_reader_messages_delivered_total/sec | <fill> | <fill> | <fill> | <fill> |
  | proto_reader_would_block_loop_iterations_total/sec | <fill> | <fill> | <fill> | <fill> |
  | proto_reader_bytes_read_total/sec | <fill> | <fill> | <fill> | <fill> |
  | quic_total_bytes_in_flight (gauge value) | <fill> | <fill> | <fill> | <fill> |
  | quic_total_cwnd_bytes (gauge) | <fill> | <fill> | <fill> | <fill> |
  | quic_min_flow_control_headroom (gauge) | <fill> | <fill> | <fill> | <fill> |
  | quic_max_smoothed_rtt_ns (gauge) | <fill> | <fill> | <fill> | <fill> |
  | mg_rwlock_shared_acquired_total/sec | <fill> | <fill> | <fill> | <fill> |

  ## Hypothesis verdict

  Pick the one hypothesis that best fits the data:

  ### H1 — Flow-control deadlock
  **Signature:** `quic_min_flow_control_headroom = 0` at T1 and stays 0 to T2; `proto_reader_bytes_read_total` rate drops to 0; `proto_reader_messages_delivered` rate also 0; bytes_in_flight is at the cap.
  **Verdict:** <Yes/No, with evidence from the table above>

  ### H2 — Congestion-control collapse
  **Signature:** `quic_total_cwnd_bytes` collapses by T1 and stays small; `quic_total_bytes_in_flight` is pinned at the (smaller) cwnd; `quic_max_smoothed_rtt_ns` spikes (loss event).
  **Verdict:** <Yes/No>

  ### H3 — BufferedProtoReader silent-receive
  **Signature:** `proto_reader_bytes_read_total` rate > 0 (data IS being read) but `proto_reader_messages_delivered_total` rate = 0 between T1 and T2. Means partial frames accumulating but never completing — likely a length-prefix mismatch or message larger than the cap.
  **Verdict:** <Yes/No>

  ### H4 — Pinned-stream lifecycle mismatch
  **Signature:** `quic_active_connections` drops between T1 and T2 (server tore down a stream / connection the client still thinks is live); `proto_reader_eof_total` ticks upward simultaneously; the stack capture at T2 shows fewer `runStreamQueryLoop` threads than at T0.
  **Verdict:** <Yes/No>

  ### H5 — Other
  If none of H1-H4 fit, document what the data shows and propose H5.

  ## Recommended fix path

  Based on the verdict above, the likely fix lives in:
  - **H1 →** quic library MAX_DATA frame emission cadence; OR geode-side stream consumption pacing (server is not draining receive buffers fast enough so the receive credit never refreshes).
  - **H2 →** quic library NewReno tuning OR network-path issue (out-of-scope for geode).
  - **H3 →** `BufferedProtoReader.nextMessage` buffer-management bug; check `compactBuffer`, `start_index`, and the 16 MB cap.
  - **H4 →** `quic_connection_handler.handleQuicConnection` stream lifecycle; cross-check with `streamAcceptorLoop` and `runStreamQueryLoop` exit paths.
  - **H5 →** open a new investigation thread.
  ```

  Fill in every `<fill>` slot with actual values from the log. Pick the verdict honestly — if the data is ambiguous, pick H5 and propose a follow-up.

- [ ] **Step 9.6: Commit.**

  ```bash
  git add docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md
  git commit -m "docs(perf): cascade bisection from instrumented metrics — verdict <H1|H2|H3|H4|H5>

  Cross-references the six checkpoint deltas of QUIC connection gauges
  and BufferedProtoReader counters against the stack capture at trigger
  time. See bisection-analysis.md for the rate table and the verdict.

  Plan complete: docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md"
  ```

---

## Self-review results

**Spec coverage:** All four user-listed investigation tasks have a phase:
- Task 4 (loadtest baseline cross-check) → Phase 1 ✓
- Task 1 (QUIC connection-level metrics) → Phase 2 (Tasks 2-4) ✓
- Task 2 (BufferedProtoReader delivery rate) → Phase 3 (Tasks 5-7) ✓
- Task 3 (bisect the 9-min hang) → Phase 4 (Tasks 8-9) ✓

**Placeholder scan:** All steps contain real code or real commands. Step 9.5's "fill in" slots are deliberate — the analyst MUST capture the actual log values; the plan cannot pre-compute them.

**Type consistency:** `Counter` (existing) vs `Gauge` (new) both registered via `Registry`. `Gauge.callback: *const fn(*anyopaque) u64` matches the call site `g.callback(g.ctx)`. `quic_metrics.Ctx { transport: *QuicTransport }` is consistent across all six callbacks. Counter names match between Task 5 (`messages_delivered_total`, `would_block_loop_iterations_total`, `bytes_read_total`, `eof_total`) and Task 6's `fetchAdd` sites and Task 7's `registerAll`. Gauge names match between Task 3 (six functions) and Task 4 (six `registerGauge` calls).

**One known unknown:** the geode `QuicTransport` field name (`connections.items`) is confirmed at `src/transport/quic.zig:439`, but the underlying quic library accessor for `Connection.cc_nr` vs `Connection.cc_cubic` may need a runtime selector — Step 3.3 calls this out and proposes the field-presence check. If the build fails there, the executor swaps the reference; the rest of the plan is unaffected because `bytes_in_flight` and `cwnd` exist on both NewReno and Cubic per `~/src/devnw/zig/quic/src/quic/recovery/congestion.zig`.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md`.

**Phase 1 (loadtest control) is independent and can run before, during, or after Phases 2-4.** Phases 2 → 3 → 4 must run in order (Phase 4 needs the instrumentation from Phases 2 + 3 to produce its evidence).

Total task count: **9 tasks across 4 phases.** Wall-clock estimate:
- Phase 1: ~30 min (mostly waiting on the loadtest run + compare)
- Phase 2: ~25 min (4 small commits + smoke test)
- Phase 3: ~20 min (3 small commits + smoke test)
- Phase 4: ~35 min (~25 min repro + 10 min analysis writing)
- **Total: ~110 min** including the 25-min cascade repro
