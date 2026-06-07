# QUIC Sustained-Load Liveness-Kill Mitigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop sustained parallel QUIC query load from amplifying into a cluster-wide outage (`docs/bugs/2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md`): make the degradation observable, stop leaking wedged streams, keep an out-of-band liveness signal available, and (durable) remove the `Endpoint.mu` poll-vs-stream head-of-line blocking.

**Architecture:** Phased. Phase 1 = bounded, low-risk geode-side fixes that resolve the documented *harm* (observability + stream reaping + out-of-band liveness availability) without touching QUIC internals. Phase 2 = the durable QUIC-library concurrency fix (`Endpoint.mu` work-bounding / lock-split + per-connection fairness) in `~/src/devnw/zig/quic`, which is the higher-risk root-cause fix. Phase 1 ships independently and is verifiable with unit tests; Phase 2 is scoped with the precise contention analysis and gated behind its own validation.

**Tech Stack:** Zig 0.16, geode `src/transport/quic.zig` + `src/server/*`, vendored QUIC library `~/src/devnw/zig/quic` (`src/quic/endpoint.zig`).

---

## Root cause (from triage)

A single coarse `Endpoint.mu` (`endpoint.zig:512`) is held across poll packet-processing **and** `acceptStream`. Under N concurrent streams one expensive packet (6.15 s observed) head-of-line-blocks the whole endpoint, stalling every stream — including the in-band `RETURN 1` liveness probe, which then times out → kubelet SIGKILL (exit 137) → ~30–60 s of API 503s. Contributing geode-side gaps: the slow-poll state is recorded as a metric (`poll_overrun_total`, `quic_poll_cycle_max_ns`) but emits **no warning log**; per-stream `proto_reader` stalls are **detected and logged but never reaped** (a 5.4 h leaked localhost probe stream observed); and the out-of-band HTTP `/health` (which exists on `GEODE_METRICS_PORT`) is not guaranteed available for k8s liveness.

## File structure

- `src/transport/quic.zig` — `observePollCycle` gains a rate-limited slow-poll WARNING (Phase 1 Task 1). Holds `poll_cycle_max_ns` etc.
- `src/server/main.zig` — proto_reader stall-detection monitor (lines ~2380–2425) gains a forced reap of streams idle beyond a hard bound (Phase 1 Task 2).
- `src/server/proto_reader_registry.zig` / `quic_connection_handler.zig` — per-stream idle tracking + the force-close hook the reaper calls.
- `src/monitoring/metrics_server.zig` / `src/server/main.zig` — ensure the out-of-band `/health` listener is available for liveness (Phase 1 Task 3).
- `~/src/devnw/zig/quic/src/quic/endpoint.zig` — Phase 2: bound per-poll work + split/shorten `Endpoint.mu` on the accept path.
- Tests: `tests/test_quic_slow_poll_warning.zig`, `tests/test_proto_reader_stream_reaper.zig`.

---

## Phase 1 — geode-side outage mitigation (bounded, low-risk)

### Task 1: Slow-poll warning + metric (observability)

Make the QUIC poll-loop degradation visible in logs *before* the liveness kill. The metric exists; add a rate-limited warning when a poll cycle exceeds a threshold, naming the dominant sub-phase.

**Files:**
- Modify: `src/transport/quic.zig` — `observePollCycle` (~706-726) + a new rate-limit field on `QuicTransport`.
- Test: `tests/test_quic_slow_poll_warning.zig`

- [ ] **Step 1: Write the failing test** — a pure unit test of the decision helper (no live QUIC).

```zig
// tests/test_quic_slow_poll_warning.zig
const std = @import("std");
const quic = @import("geode").transport.quic;

test "slow-poll warning fires only past the threshold and is rate-limited" {
    // shouldWarnSlowPoll(cycle_ns, threshold_ns, last_warn_ns, now_ns, min_interval_ns)
    // 1) below threshold -> no warn
    try std.testing.expect(!quic.shouldWarnSlowPoll(500, 1_000, 0, 10_000, 5_000));
    // 2) above threshold, no prior warn -> warn
    try std.testing.expect(quic.shouldWarnSlowPoll(2_000, 1_000, 0, 10_000, 5_000));
    // 3) above threshold but within rate-limit window -> suppressed
    try std.testing.expect(!quic.shouldWarnSlowPoll(2_000, 1_000, 9_000, 10_000, 5_000));
    // 4) above threshold and past rate-limit window -> warn
    try std.testing.expect(quic.shouldWarnSlowPoll(2_000, 1_000, 1_000, 10_000, 5_000));
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `zig build test-quic-slow-poll-warning` (after wiring the build step — mirror `test-cert-provided` in `build.zig`)
Expected: FAIL — `shouldWarnSlowPoll` undefined.

- [ ] **Step 3: Implement the pure helper + wire it into observePollCycle**

In `src/transport/quic.zig`, add the helper (pure, testable) near `observeMaxAtomic`:

```zig
/// Decide whether a slow-poll warning should fire for a cycle of `cycle_ns`.
/// Pure: fires when the cycle exceeds `threshold_ns` AND at least
/// `min_interval_ns` has elapsed since `last_warn_ns` (rate limit).
pub fn shouldWarnSlowPoll(cycle_ns: u64, threshold_ns: u64, last_warn_ns: u64, now_ns: u64, min_interval_ns: u64) bool {
    if (cycle_ns <= threshold_ns) return false;
    return (now_ns -% last_warn_ns) >= min_interval_ns;
}
```

Add a field to `QuicTransport`:

```zig
    /// Last wall-clock ns a slow-poll warning was emitted (rate limiting).
    slow_poll_last_warn_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
```

At the end of `observePollCycle`, after the overrun counter:

```zig
        if (cycle_ns > overrun_threshold_ns) {
            _ = self.poll_overrun_total.fetchAdd(1, .monotonic);
        }
        // Slow-poll WARNING (bug 2026-06-07): make multi-second poll cycles
        // visible in logs before the in-band liveness probe times out. Threshold
        // defaults to 1s (>= a single human-noticeable stall), rate-limited to
        // one line / 5s so a sustained-load storm cannot flood the log.
        const slow_threshold_ns: u64 = 1 * std.time.ns_per_s;
        if (cycle_ns > slow_threshold_ns) {
            const now_ns = monoNsRaw();
            const last = self.slow_poll_last_warn_ns.load(.acquire);
            if (shouldWarnSlowPoll(cycle_ns, slow_threshold_ns, last, now_ns, 5 * std.time.ns_per_s)) {
                if (self.slow_poll_last_warn_ns.cmpxchgStrong(last, now_ns, .acq_rel, .acquire) == null) {
                    log.warn("QUIC poll cycle slow — query path degraded (sustained-load liveness-kill risk)", &.{
                        Attr.uint("cycle_ms", cycle_ns / std.time.ns_per_ms),
                        Attr.uint("recv_process_ms", stats.recv_process_ns / std.time.ns_per_ms),
                        Attr.uint("timer_process_ms", stats.timer_process_ns / std.time.ns_per_ms),
                        Attr.uint("packets", stats.packets_processed),
                    });
                }
            }
        }
```

Confirm `log` + `Attr` are imported in `quic.zig` (they are used elsewhere in `src/server`; if not present in `quic.zig`, add `const logging = @import("logging"); const log = logging.scoped("quic"); const Attr = logging.Attr;`).

- [ ] **Step 4: Run the test, verify it passes**

Run: `zig build test-quic-slow-poll-warning`
Expected: PASS.

- [ ] **Step 5: Build geode + manually confirm a warning is emittable**

Run: `zig build` then a load test (or unit harness) that drives a >1s cycle; confirm `QUIC poll cycle slow` appears at most once / 5s.

- [ ] **Step 6: Commit**

```bash
git add src/transport/quic.zig tests/test_quic_slow_poll_warning.zig build.zig
git commit -m "feat(quic): rate-limited slow-poll warning before liveness-kill (2026-06-07 bug)"
```

### Task 2: Reap wedged/idle proto_reader streams — **DEFERRED to Phase 2 (evidence below)**

> **Status (2026-06-07): NOT implemented in Phase 1. Moved to Phase 2.** Source-level
> investigation showed the watchdog force-close sketched below is **not safe** in the
> current vendored QUIC wrapper and would reintroduce known teardown races. Concrete evidence:
>
> 1. **The blocking read path already self-reaps.** `BufferedProtoReader.nextMessage`
>    (`src/server/quic_connection_handler.zig:1293`) caps would-block iterations at
>    `max_would_block_attempts = 300000` (300 s, "matches QUIC idle timeout") → returns
>    `error.Timeout`, unwinding the handler and closing its stream. The blocking path is
>    already bounded; no watchdog reap is needed for it.
> 2. **`QuicStream.close` is deliberately a near-no-op by default.**
>    `~/src/devnw/zig/quic/src/quic/transport.zig:741` only issues a wire `api.closeStream`
>    when `GEODE_QUIC_FORCE_STREAM_CLOSE=1`; otherwise it just nulls `quic_stream_id`. The
>    in-tree comment: *"avoid vendor close by default to reduce teardown races."* The
>    maintainers already hit close-races here and chose to avoid vendor close.
> 3. **Cross-thread close is a data race.** `close()` nulls `self.quic_stream_id` while a
>    handler thread's `read()` reads it, with no per-stream lock. A watchdog-thread force-close
>    races the handler — exactly the teardown race (2) avoids.
> 4. **The registry deliberately never aborts** (`src/server/proto_reader_registry.zig:25-27`):
>    *"a wedged handler may be mid-transaction, so the watchdog never aborts a stuck stream.
>    Recovery remains pod restart."* Force-reaping contradicts this deliberate safety choice.
> 5. **The 5.4 h leak is in the cooperative-scheduler path** (`nextMessageNonBlocking`,
>    `:1261`, which has *no* would-block cap). A safe reap for it must be performed by the
>    scheduler thread that *owns* the stream (no cross-thread race) AND distinguish
>    between-requests idle (safe to close) from mid-request (must not abort) — a change to the
>    perf-critical, high-fanout-tuned cooperative scheduler that requires load-test validation.
>
> **Conclusion:** safe stream reaping requires per-stream close synchronization in the vendored
> wrapper (transport.zig) + a scheduler-owned reap path — this is Phase 2 concurrency work,
> gated behind a load-test repro. The original sketch is retained below for reference only.

Today the per-stream stall is *detected and logged* ("restart pod to recover") but the stream is never closed — a 5.4 h leaked localhost probe stream was observed. Force-close streams idle beyond a hard bound so leaked health-probe streams cannot accumulate.

**Files:**
- Modify: `src/server/main.zig` (proto_reader stall monitor, ~2380-2425) — call the reaper when `idle_ms` exceeds a hard bound.
- Modify: `src/server/proto_reader_registry.zig` / `src/server/quic_connection_handler.zig` — expose a safe force-close for a registered stream id.
- Test: `tests/test_proto_reader_stream_reaper.zig`

- [ ] **Step 1: Write the failing test** — pure decision helper.

```zig
// tests/test_proto_reader_stream_reaper.zig
const std = @import("std");
const reg = @import("geode").proto_reader_registry; // adjust import to actual export

test "reap decision: only past the hard bound, never below" {
    // shouldReapStream(idle_ms, reap_bound_ms)
    try std.testing.expect(!reg.shouldReapStream(60_000, 300_000)); // 60s < 5min bound
    try std.testing.expect(reg.shouldReapStream(310_000, 300_000)); // past bound -> reap
    try std.testing.expect(!reg.shouldReapStream(0, 300_000));
}
```

- [ ] **Step 2: Run it, verify it fails** — `shouldReapStream` undefined.

- [ ] **Step 3: Implement `shouldReapStream` + wire a force-close call** in the stall monitor.

```zig
/// True when a per-stream proto_reader idle time warrants a forced close.
/// Bound default 300_000 ms (5 min): far beyond any legitimate request, but
/// well under the multi-hour leak observed in the 2026-06-07 bug.
pub fn shouldReapStream(idle_ms: u64, reap_bound_ms: u64) bool {
    return idle_ms >= reap_bound_ms;
}
```

In the stall monitor (`main.zig` ~2421, where the per-stream stall is logged), after the warning, when `shouldReapStream(idle_ms, reap_bound_ms)` is true, invoke the registry's force-close for that stream id (the existing `quic_connection_handler` stream registry already tracks `(conn, stream_id)`); the close MUST go through the connection's own lock (never the poll thread's `ep.mu`) to avoid the very contention this bug is about. Reap bound is env-tunable via `GEODE_QUIC_STREAM_REAP_MS` (default 300000).

- [ ] **Step 4: Run the test, verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add src/server/proto_reader_registry.zig src/server/main.zig tests/test_proto_reader_stream_reaper.zig build.zig
git commit -m "fix(quic): reap proto_reader streams idle beyond a hard bound (2026-06-07 leak)"
```

### Task 3: Guarantee an out-of-band liveness signal

geode already serves a static `200 {"status":"ok"}` at `/health` on `GEODE_METRICS_PORT` (`metrics_server.zig:serveHealth`) on its own thread — independent of the QUIC poll loop. Ensure this is documented + reliably available as the k8s liveness target so a busy-but-progressing pod is not SIGKILLed by an in-band `RETURN 1` probe.

**Files:**
- Modify: `docs/USER_AUTH.md` / a deployment note — document `GET http://<host>:$GEODE_METRICS_PORT/health` as the liveness target (cheap, out-of-band).
- Modify: `src/server/main.zig` — log the health URL at startup when the metrics server is enabled, so operators discover it.

- [ ] **Step 1: Add a startup log line** when the metrics/health server binds, naming the `/health` liveness URL. Commit.
- [ ] **Step 2: Document** the out-of-band liveness contract (and that in-band `RETURN 1` should be readiness-only, looser timeout). Commit.

---

## Phase 2 — durable QUIC concurrency fix (`~/src/devnw/zig/quic`) [SCOPED]

The root cause is the coarse `Endpoint.mu` held across poll packet-processing and `acceptStream`. The durable fix is to bound per-poll work and shorten/split the lock so one expensive packet cannot head-of-line-block all streams. This is a higher-risk change to a vendored library many projects depend on and is gated behind its own validation; it is scoped here, not auto-executed in Phase 1.

Design directions (from triage + the acceptor-wedge §6):
1. **Bound packets per poll call.** `endpoint.zig` poll currently drains all ready datagrams under `mu`. Add a `max_packets_per_poll` budget so the lock is released between batches, letting `acceptStream` and other streams interleave.
2. **Split the accept path off `Endpoint.mu`.** Move the accepted-connection/stream queues behind their own mutex so `acceptStream` does not contend with packet processing.
3. **Per-connection fairness** on the poll path so one busy connection cannot starve others or the health path.
4. **Safe stream reaping (the moved Task 2).** Add per-stream close synchronization in
   `~/src/devnw/zig/quic/src/quic/transport.zig` so `QuicStream.close` is race-free against a
   concurrent `read()` (guard `quic_stream_id`), then either (a) let the cooperative
   first-stream scheduler — which *owns* the stream — close streams idle-between-requests
   beyond a generous bound (e.g. ≥600 s, well past the 300 s blocking cap and the QUIC idle
   timeout), distinguishing between-requests idle from mid-request, or (b) make `close()`
   safely callable from the watchdog. (a) is preferred (no cross-thread race).

**Why this is gated, not auto-executed.** This is a concurrency rework of the vendored QUIC
library that the entire DB + every client (`geode-client-zig`, etc.) depend on. The library
already carries scar tissue from teardown races (the env-gated `close`, the `PollSync` enter/leave
barrier, the 5 ms poll cadence comments). An unvalidated change here risks regressing handshake,
teardown, or high-fanout throughput project-wide — violating the repo's own "no regressions in
core operations" quality gate.

**Prerequisite — a reproduction harness.** Before any Phase 2 code lands, build a local
concurrency repro that drives the degradation deterministically:
- Constrain geode's CPU to mimic the k8s `limits.cpu: 4` (cgroup v2 / `systemd-run
  --property=CPUQuota=400%` — both available on the dev box) so the fast 56-core host does not
  mask the contention.
- Drive N≈11 sustained concurrent QUIC query streams (reuse `tests/e2e_quic_high_concurrency.zig`
  as the driver, or the Go loadtest in `../geode-test-harness`) plus one low-rate **probe** stream.
- Assert the failing baseline: under load, `quic_first_stream_packet_process_max_ns` and the
  probe stream's `RETURN 1` round-trip climb into the multi-second range (and ideally the
  slow-poll warning from Task 1 fires).
- The Phase 2 fix is accepted only when this harness shows the probe round-trip stays bounded
  while a slow stream runs, with no regression in the high-concurrency objective suite
  (`test-quic-high-concurrency-e2e`).

---

## Self-review

- Spec coverage: doc fix #5 (slow-poll warning) → Task 1; #4 (reap wedged streams) → Task 2; #2 (out-of-band liveness) → Task 3; #1/#3 (poll non-blocking / fairness, the durable fix) → Phase 2. All five mapped.
- Placeholders: Phase 1 tasks carry exact code for the pure helpers + wiring; Phase 2 is intentionally a scoped design (higher-risk, separate validation), not an exact-code task.
- Type consistency: `shouldWarnSlowPoll` / `shouldReapStream` signatures are used identically in test and impl.
