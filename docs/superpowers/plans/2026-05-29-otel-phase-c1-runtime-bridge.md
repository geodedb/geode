# OTel Phase C Increment 1 — runtime-counter → OTLP bridge

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Export geode's rich runtime metrics registry (the `quic_*` / `proto_reader_* `/ `quic_stream_write_*` / poll-phase counters geode already computes and renders to Prometheus) through the OTLP pipeline as OTel observable gauges, so the "full performance landscape" (RTT, cwnd, bytes-in-flight, poll timings, stream-write stats) reaches the collector — not just Prometheus.

**Architecture:** `src/server/runtime_metrics.zig` holds a process-global `Registry` of `counters` (`{name, ptr: *atomic.Value(u64)}`) and `gauges` (`{name, callback: fn(*anyopaque) u64, ctx}`), populated at startup (`src/server/main.zig` ~1977–2154) and exposed via `globalRegistry()`. Today it's rendered only to the Prometheus `/metrics` endpoint. We add `otel_metrics.registerRuntimeMetricsOtel(registry)` that, after the registry is fully populated, creates one OTel observable gauge per registry entry named `geode.runtime.<original_name>`, backed by a heap bridge that reads the source atomic/callback at OTel collection time. These callbacks are confirmed bounded + safe (atomic reads / brief connection-mutex at collection cadence; no unbounded labels).

**Tech Stack:** Zig 0.16, the Phase A docker-compose collector for verification.

---

## File Structure
- Modify: `src/monitoring/otel_metrics.zig` — add `registerRuntimeMetricsOtel` + the bridge callback/struct + process-lifetime storage for names/bridges.
- Modify: `src/server/main.zig` — call `registerRuntimeMetricsOtel(registry)` once, AFTER all runtime-metric registrations complete (after the `registerAll()` / gauge registrations near line ~2154), guarded so it is a cheap no-op when the OTLP meter is not active.
- Create: `tests/test_otel_runtime_bridge.zig` — unit test: register a small runtime Registry with one counter + one gauge, call `registerRuntimeMetricsOtel`, force a metric collection into an in-memory recorder, assert `geode.runtime.<name>` gauges are observed with the source values.
- Modify: `build.zig` — wire `test-otel-runtime-bridge` (mirror `test-otel-span-facade`).

---

### Task 1: The bridge in otel_metrics.zig

**Files:** Modify `src/monitoring/otel_metrics.zig`; Create `tests/test_otel_runtime_bridge.zig`; Modify `build.zig`

- [ ] **Step 1: Write the failing test** `tests/test_otel_runtime_bridge.zig`:
```zig
const std = @import("std");
const otel_metrics = @import("otel_metrics");
const runtime_metrics = @import("runtime_metrics");

// CANARY: REQ=REQ-OTEL-METRICS-RUNTIME-BRIDGE-001; FEATURE="OTel Instrumentation"; ASPECT=RuntimeCounterBridge; STATUS=TESTED; TEST=tests/test_otel_runtime_bridge.zig; OWNER=monitoring; UPDATED=2026-05-29
var test_ctr: std.atomic.Value(u64) = .init(0);
fn gaugeCb(_: *anyopaque) u64 { return 42; }
var gauge_ctx: u8 = 0;

test "runtime registry counters+gauges export as geode.runtime.* observable gauges" {
    const alloc = std.testing.allocator;
    var recorder = otel_metrics.InMemoryRecorder.init(alloc);
    defer recorder.deinit();
    try otel_metrics.initForMetricsTest(alloc, &recorder); // see VERIFY note below

    const reg = try runtime_metrics.Registry.init(alloc);
    defer reg.deinit();
    test_ctr.store(7, .release);
    try reg.register("test_counter_total", &test_ctr);
    try reg.registerGauge("test_gauge", gaugeCb, &gauge_ctx);

    try otel_metrics.registerRuntimeMetricsOtel(reg);
    try otel_metrics.collectAndAssertHasMetric(&recorder, "geode.runtime.test_counter_total", 7);
    try otel_metrics.collectAndAssertHasMetric(&recorder, "geode.runtime.test_gauge", 42);
    otel_metrics.shutdown();
}
```
**VERIFY before writing:** the real test entry for metrics + in-memory recorder. The repo already has `initForTracingTest`/`InMemoryRecorder`; find the METRICS equivalent (e.g. `initForTesting` + a way to force a collect, or `MeterProvider.collect`). If there is no `collectAndAssertHasMetric` helper, assert directly by triggering `g_provider.?.collect(...)` into the recorder and scanning recorded metric names/values. Use the REAL collect path (no mocks). If a metrics in-memory recorder does not exist, model the test on `tests/test_otel_facade_smoke.zig` (which exercises the metric facade) and assert the observable gauges are registered + observed.

- [ ] **Step 2: Implement `registerRuntimeMetricsOtel` in otel_metrics.zig** (near the other `register*Gauge` helpers):
```zig
const runtime_metrics = @import("runtime_metrics");

// Heap bridge so an OTel observable callback (single ?*anyopaque ctx) can carry
// either a counter atomic ptr or a runtime Gauge{callback,ctx}. Process-lifetime.
const RuntimeBridge = struct {
    counter_ptr: ?*std.atomic.Value(u64) = null,
    gauge_cb: ?*const fn (*anyopaque) u64 = null,
    gauge_ctx: ?*anyopaque = null,
    fn read(self: *const RuntimeBridge) i64 {
        if (self.counter_ptr) |p| return @intCast(p.load(.acquire));
        if (self.gauge_cb) |cb| return @intCast(cb(self.gauge_ctx.?));
        return 0;
    }
};

fn observeRuntimeBridge(ctx: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    const b: *const RuntimeBridge = @ptrCast(@alignCast(ctx.?));
    observer.observeInt(b.read(), &.{});
}

/// Export every entry of the runtime metrics Registry as a `geode.runtime.<name>`
/// OTel observable gauge. Call ONCE at startup AFTER the registry is fully
/// populated. No-op when the OTLP meter provider is not active.
pub fn registerRuntimeMetricsOtel(registry: *runtime_metrics.Registry) !void {
    if (g_provider == null) return; // metrics pipeline not active -> nothing to do
    const alloc = g_allocator orelse return;
    const m = meter();
    const io = initIo();
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (registry.counters.items) |c| {
        const name = try std.fmt.allocPrint(alloc, "geode.runtime.{s}", .{c.name});
        const b = try alloc.create(RuntimeBridge);
        b.* = .{ .counter_ptr = c.ptr };
        _ = try m.createObservableGauge(
            .{ .name = name, .unit = "", .kind = .observable_gauge, .description = c.name },
            observeRuntimeBridge,
            b,
        );
    }
    for (registry.gauges.items) |g| {
        const name = try std.fmt.allocPrint(alloc, "geode.runtime.{s}", .{g.name});
        const b = try alloc.create(RuntimeBridge);
        b.* = .{ .gauge_cb = g.callback, .gauge_ctx = g.ctx };
        _ = try m.createObservableGauge(
            .{ .name = name, .unit = "", .kind = .observable_gauge, .description = g.name },
            observeRuntimeBridge,
            b,
        );
    }
}
```
**VERIFY:** exact `createObservableGauge` signature + `InstrumentDescriptor` field names (`.name/.unit/.kind/.description`) against `registerTransportConnectionGauge` (otel_metrics.zig:1054) and the otel `api/metrics.zig`. Confirm `g_allocator` is the right process allocator and that `meter()` returns the live meter (parallel to `tracer()`). The `name`/bridge allocations are intentionally process-lifetime (registered for the life of the provider); do not free them while the provider lives.

- [ ] **Step 3: Wire `test-otel-runtime-bridge` in build.zig** (mirror `test-otel-span-facade`; the test imports `otel_metrics` + `runtime_metrics`). Run `zig build test-otel-runtime-bridge` — confirm GREEN.

- [ ] **Step 4: Build + commit**
```bash
zig build -Doptimize=ReleaseSafe   # MUST pass before commit (pre-commit does not compile)
git add src/monitoring/otel_metrics.zig tests/test_otel_runtime_bridge.zig build.zig docs/status.csv
git commit -m "feat(otel): bridge runtime metrics registry to OTLP observable gauges (geode.runtime.*)"
```

---

### Task 2: Wire the bridge at server startup

**Files:** Modify `src/server/main.zig`

- [ ] **Step 1: Call the bridge after the registry is populated**

Find where the runtime registry is fully populated (after `registerAll()` / the QUIC/proto-reader gauge registrations, ~line 2154 — VERIFY the exact line). Add, immediately after:
```zig
    // Bridge the runtime metrics registry into OTLP (geode.runtime.*). Must run
    // after every runtime-metric registration above so all entries are exported.
    if (runtime_metrics_mod.globalRegistry()) |rt_reg| {
        otel_metrics.registerRuntimeMetricsOtel(rt_reg) catch |err| {
            log.warn("otel_metrics: runtime bridge registration failed", &.{Attr.string("error", @errorName(err))});
        };
    }
```
**VERIFY:** the real import alias for the runtime metrics module in main.zig (`runtime_metrics_mod`?), the `otel_metrics` import alias, the `log`/`Attr` helpers in scope, and the exact post-registration line.

- [ ] **Step 2: Build**
```bash
zig build -Doptimize=ReleaseSafe   # MUST pass
```

- [ ] **Step 3: Commit**
```bash
git add src/server/main.zig
git commit -m "feat(otel): register the runtime-metrics OTLP bridge at server startup"
```

---

### Task 3: End-to-end verification + baseline update

- [ ] **Step 1: Verify `geode.runtime.*` metrics land in the collector**

Run the docker verify and additionally scan for the new family:
```bash
scripts/otel-compose-verify.sh   # must still PASS (metrics)
```
Then bring the stack up, generate a little traffic, and confirm `geode.runtime.` names appear in the collector debug output and/or `geode_runtime_` in the Prometheus pull:
```bash
# (mirror the diagnostic recipe used in docs/otel-compose-baseline-2026-05-29.md)
```
Expected: collector debug output includes `geode.runtime.quic_active_connections`, `geode.runtime.quic_min_smoothed_rtt_ns`, `geode.runtime.proto_reader_*`, etc.

- [ ] **Step 2: Append to `docs/otel-compose-baseline-2026-05-29.md`** a "Phase C1 update" listing the new `geode.runtime.*` families now exported via OTLP, with a captured sample. Commit.

---

## Self-Review checklist
- The bridge exports BOTH counters and gauges from the registry (Task 1).
- Names are `geode.runtime.<original>` — bounded, no per-connection/user labels.
- Bridge ctx lifetime is process-long (allocated on g_allocator, never freed while provider lives).
- No-op when OTLP meter inactive (early return on `g_provider == null`).
- Registration runs once, after the registry is fully populated (Task 2 ordering).
- Build + relevant tests pass BEFORE each commit (pre-commit does not compile).

## Notes / follow-up (Phase C Increment 2 — separate plan)
Wire the unwired `record*` facade functions at their call sites: `recordQueryPlan`/`recordQueryRowsReturned` (execution.zig), `recordLockWait`/`recordSerializationConflict`/`recordDeadlock`/`recordTransactionTimeout` (transactions/manager.zig), `recordAuthzCheck` (auth_dispatch.zig), `recordRlsEvaluation` (rls_filter.zig), `recordAuditEvent`/`recordAuditDropped` (security/audit.zig), `recordTdeOperation`/`recordTdeBytes` (tde), and the ready gauge registrations (node/edge/index/storage/wal counts — providers exist, register in main.zig). Blocked/deferred: QUIC handshake/timeout (vendor lib), distributed (cluster-only), CDC/analytics (subsystems absent), backup (bridge private S3Metrics to facade).
