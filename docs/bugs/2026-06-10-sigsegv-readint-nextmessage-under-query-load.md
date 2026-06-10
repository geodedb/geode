# Bug: SIGSEGV (exit 139) — "General protection exception" in `readInt` ← `nextMessage` (QUIC message parser) under sustained query load

**Status:** **FIXED on `main` (2026-06-10)** — root cause was a **use-after-free of
`FirstStreamOwnerContext`**, not a framing-parser bug: the cooperative
scheduler's detached async-cleanup (`finishCooperativeContext` →
`cleanupFirstStreamOwnerAsync` → `gpa.destroy(ctx)`) freed the context while
the detached-owner read loop and/or the poll-thread RX-ready notifier
(`firstStreamReadyCallback`) still referenced `&ctx.reader` — the GP fault in
`readInt` was a recycled-allocation read of the corrupt `buffer` slice header.
Fix (commits `93f914c5` red tests, `d66ed52a` fix, `2580ff4e` review
follow-ups): `owner_refs` lifetime refcount on `FirstStreamOwnerContext`
(creation = lifecycle ref; cooperative `submit` takes a notifier ref before
publishing; the last release destroys — mirrors `StreamAcceptorContext` and
the 2026-06-02 reaper philosophy), a `notifier_inflight` enter/exit gate with
`waitNotifierDrained()` in cleanup, `submit` returns ownership by value so the
caller never dereferences the ctx after publication, a post-drain
`removeContext` re-purge of stale notifier re-enqueues, and a loud bounds
guard (`error.CorruptStreamFraming`) at the faulting `readInt` site.
Regression: `tests/test_first_stream_owner_lifetime.zig` +
`src/first_stream_owner_lifetime_test_root.zig`
(`zig build test-first-stream-owner-lifetime`, 9/9, in the sharded aggregate;
the two race regressions were deterministic-red before the fix via allocator
canaries). **Known residual (documented at the notifier-gate comment in
`quic_connection_handler.zig`):** the vendored quic lib's `notifyRxReady`
loads fn+ctx non-atomically after `Connection.mu` release, so a
captured-but-not-yet-invoked callback in that ~3-instruction window survives
the drain — vastly narrower than the fixed whole-loop window (the 9×/hour
crash class is closed) but structurally present until a lib-level notifier
quiesce or a `pending_destroy`-epoch ctx free lands.

Original report follows.

**Original status:** **OPEN — reproduced on latest `geodedb/geode:dev`** (2026-06-10).
Under a sustained Playwright e2e query workload (a single divelife-api replica +
~2 PDS replicas serving the divelife-ui coverage/qa-integration/runtime-error
scanner suites), geode crashes with a **SIGSEGV / General protection exception**
in the QUIC stream message-reader. Exit code **139** (128+11), `reason="Error"`,
`signal=11`. Distinct from:

- the **resolved** [2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md](2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md) (use-after-free in the connection-**teardown** / `sendExecuteError` path) — that fix did not cover this **message-read** path; and
- the **liveness-wedge** ([2026-06-07-unresponsive-…-liveness-kill-503.md](2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md), [2026-06-10-dev-v0.6.26-still-wedges-plus-batch-ingest-bad-connection.md](2026-06-10-dev-v0.6.26-still-wedges-plus-batch-ingest-bad-connection.md)) which is an **exit 137** kubelet SIGKILL of a *live-but-slow* pod.

**This crash is now the dominant restart cause once the liveness-wedge is mitigated** (see §3): after the QA livenessProbe was moved off the in-band query path to the out-of-band `GET /health` endpoint (per the 2026-06-07 report §9), geode is no longer SIGKILLed (137) by the probe — but it then **segfaults (139) on its own** under the same load. The fix mitigated the *symptom* (probe kill); the underlying under-load instability is still crashing the process.

## Environment (exact)

| | |
|---|---|
| Image | `docker.io/geodedb/geode:dev` (latest; `v0.6.26-16-gd8c1adb` / build `8bdb973` observed during the run) |
| Topology | single-node QA, mem limit 6Gi (not OOM — this is a segfault, not a cgroup kill) |
| Liveness probe | **`httpGet /health:9091`** (out-of-band, GEODE_METRICS_PORT=9091) — i.e. the probe is NOT the killer here |
| Readiness probe | in-band `geode query … "RETURN 1" --timeout 5` (observed failing with `query timed out after 5 seconds` under load — geode sheds traffic, expected) |
| Workload | divelife-ui Playwright e2e: `qa-integration` (multi-tier logins) + `coverage/*` (CRUD walkers) + `runtime-errors`/`route-walker` (per-persona all-screen scanners). ~1 API replica, ~2 PDS replicas. |
| Restarts | **9** SIGSEGV restarts over one ~1-hour e2e run (exit 139 each) |

## 1. Crash signature (exact stack)

From the crashed container's stderr (kubelet `lastState.terminated.exitCode=139`):

```
General protection exception (no address available)
/opt/zig/lib/std/mem.zig:1895:5: 0x15dab1b in readInt (geode)
src/server/quic_connection_handler.zig:1309:47: 0x15dafb6 in nextMessage (geode)
src/server/quic_connection_handler.zig:2283:51: 0x175bde6 in runStreamQueryLoopWithReader (geode)
src/server/quic_connection_handler.zig:3698:33: 0x175b8ff in handleFirstStreamOwner (geode)
/opt/zig/lib/std/Thread.zig:422:13: 0x17596a4 in callFn__anon_614982 (geode)
/lib/x86_64-linux-gnu/libc.so.6 (thread start)
```

A **General protection exception in `std.mem.readInt`** means an unaligned/invalid
pointer was dereferenced while reading a fixed-width integer out of a QUIC stream
message frame. The call site is `nextMessage` (`quic_connection_handler.zig:1309`)
— the per-stream message framing/length reader — invoked from the hot
`runStreamQueryLoopWithReader` (`:2283`) on the first-stream owner thread
(`handleFirstStreamOwner`, `:3698`). I.e. geode faults while **parsing the next
inbound message length/header on an established query stream** under concurrency.

## 2. Trigger / reproduce

1. Single-node geode (`:dev`), one divelife-api replica + 2 PDS replicas connected.
2. Run the divelife-ui Playwright suite against QA with the heavy scanner specs:
   `TEST_WEB_MODE=1 QA_INTEGRATION=1 BASE_URL=https://qa.divelife.org pnpm exec playwright test --workers=1`
   (the `runtime-errors`/`route-walker`/`coverage` specs open many screens in
   sequence, each issuing bursts of concurrent queries through the API's QUIC
   connection pool).
3. Within minutes geode's readiness `RETURN 1` starts timing out (>5s), and geode
   then **segfaults (139)** in `nextMessage`/`readInt`. It restarts (~30-60s
   reconnect window), serves for a few minutes, and crashes again — observed **9
   crashes in ~1 hour**.

The crash is load/concurrency-sensitive (does not occur on an idle node), and is
**independent of the liveness probe** (the probe is now out-of-band `/health`, so
this is a genuine process crash, not a kubelet kill).

## 3. Interaction with the liveness-wedge mitigation

The QA deployment applied the recommended probe split (2026-06-07 §9):
liveness = `httpGet /health:9091` (off the QUIC hot path), readiness = in-band
`RETURN 1`. This **correctly eliminated the exit-137 liveness-SIGKILLs**. But the
restart count did **not** go to zero — geode now exits **139 (SIGSEGV)** instead
of **137 (SIGKILL)**. So:

- The probe split is still the right operational mitigation (a slow-but-alive
  geode is no longer killed; only a truly-crashed one restarts).
- **The load-induced instability is a real geode crash, not just probe latency.**
  Eliminating it requires fixing the `nextMessage`/`readInt` fault (and the
  underlying `Endpoint.mu` poll-vs-stream contention that drives the loop into
  this state under concurrency — see the wedge reports).

## 4. Impact

- **Whole-DB availability.** Each segfault takes the single-node DB offline for
  the ~30-60s restart+reconnect; every geode-backed API call 503s in that window.
- **Self-inflicted by modest load.** One API replica + a test browser pool
  (~workers=1) is enough. Real production read concurrency would hit the same
  fault.
- **e2e cannot reach green.** On the consuming side (divelife-ui e2e), the
  per-persona all-screen scanners (`runtime-errors.spec.ts`) take **9+ minutes
  per attempt and still fail on retry #3** because a geode segfault lands inside
  the screen walk — so the crash directly blocks a clean test run.

## 5. Suggested next steps (geode side)

1. **Harden `nextMessage` framing reads.** The GP fault in `readInt` suggests
   reading a length/header from a buffer slice that is shorter than the fixed
   width, or from a pointer that was freed/realloc'd concurrently (a read off a
   stream buffer that another thread mutated). Bounds-check the slice before
   `readInt`, and audit the buffer's lifetime/ownership across the
   `runStreamQueryLoopWithReader` concurrency boundary (this is adjacent to the
   teardown use-after-free fixed in the 2026-06-02 report — the same QUIC handler
   file — so a sibling lifetime bug on the read path is plausible).
2. **Capture a core / ASan build.** A `-Doptimize=Debug` + AddressSanitizer build
   under the repro would pinpoint the exact bad read (the release stack gives the
   frame but not the offending buffer).
3. **The durable poll-loop/`Endpoint.mu` rework** (tracked in
   `docs/superpowers/plans/2026-06-07-quic-sustained-load-liveness-kill.md`) likely
   reduces the concurrency that drives the loop into this fault; pair the crash
   fix with it.

---

*Filed 2026-06-10 from divelife QA (single-node `geodedb/geode:dev`,
`v0.6.26-16-gd8c1adb`/`8bdb973`), reproduced under the divelife-ui Playwright e2e
suite. Cross-refs: 2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md
(resolved teardown UAF, same file, different path),
2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md (exit-137
liveness-wedge + the §9 /health mitigation applied here),
2026-06-10-dev-v0.6.26-still-wedges-plus-batch-ingest-bad-connection.md.*
