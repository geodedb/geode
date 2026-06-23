# Bug: an idle-but-CONNECTED geode burns ~10 cores in the FirstStreamScheduler

**Status:** **FIXED — 2026-06-23** on branch `perf/firststream-busypoll`
(off `bound-node-mirror` == origin/main at f08970b9). One-line scheduler change in
`src/server/quic_connection_handler.zig` + a subprocess CPU regression test.

## 1. Symptom

A geode server that is *idle but has lingering connections* (the common steady
state: client pools holding connections open, half-closed connections, idle
verifier streams) burns large amounts of CPU doing **zero** work
(`msgs_delivered+=0`). Live gdb on the deployed system geodes showed ~512 threads
sitting at `#0 server.quic_connection_handler.FirstStreamScheduler.takeReady`,
~10 cores of pure busy-poll, stealing CPU from real edge-ingest endpoint lookups
and scans at scale.

This is the sibling of the 2026-06-08 idle-spin fix
(`2026-06-08-idle-node-810pct-cpu-poll-and-pool-spin.md`). That fix cured the
**zero-connection** case (`takeReady` parks 1s when `contexts.items.len == 0`).
It did **not** cure the **contexts-present** case, which is what production
actually sits in.

## 2. Root cause

`FirstStreamScheduler` runs a fixed **512-worker** (ReleaseSafe) cooperative pool.
When the ready queue is empty, each worker parks in `takeReady` on a
`futexWaitTimeout(&ready_generation)`. The timeout is chosen by:

```zig
const has_contexts = self.contexts.items.len != 0;
const wait_ns = if (has_contexts) first_stream_scheduler_idle_sweep_ns  // 10ms
               else              first_stream_scheduler_idle_park_ns;   // 1s
```

The 10ms cadence exists **only** to drive the missed-RX-wakeup sweep
(REQ-QUIC-HC-100): a low-frequency scan comparing each stream's RX generation
against the last generation seen at WouldBlock, recovering the rare lost
poll-thread notifier callback. That sweep needs to run ~every 10ms **in total**,
by **one** worker. But the code made **every one of the 512 workers** use the
10ms timeout whenever *any* context existed. So a handful of lingering idle
connections made all 512 workers wake 100×/s:

- **Fixed cost:** ~512 × 100/s = ~51k futex round-trips/s.
- **Amplified cost:** every 10ms wake takes `self.mutex` and the elected scanner
  runs `takeChangedContextLocked`, an **O(contexts)** scan, inside that lock. As
  lingering connections accumulate the critical section grows, and all 512 waking
  workers contend on the one mutex — so the waste grows with connection count.

The primary wake path (`enqueueReady` → `ready_generation += 1` + `futexWake(1)`)
is event-driven and was always correct; the 10ms timeout is purely a fallback,
and 511 of the 512 per-10ms wakes did nothing but re-park.

## 3. Fix

`src/server/quic_connection_handler.zig` — elect **one** designated sweeper.

A new `sweeper_claimed: std.atomic.Value(bool)` on the scheduler. In `takeReady`,
when contexts exist, a worker about to wait tries to claim the sweeper role:

```zig
const is_sweeper = has_contexts and
    self.sweeper_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
defer if (is_sweeper) self.sweeper_claimed.store(false, .release);

const wait_ns = if (is_sweeper) first_stream_scheduler_idle_sweep_ns  // 10ms
                else            first_stream_scheduler_idle_park_ns;   // 1s
```

Only the claimer polls at 10ms and runs the sweep; every other idle worker parks
1s. Real work still wakes any parked worker immediately via `enqueueReady`'s
`futexWake(1)`, so dispatch latency is unchanged. The claim is released after
each wait (the `defer` runs at the end of every loop iteration, including the
shutdown `return`), so the sweeper role rotates and is never stranded on a worker
that left to process a request.

### Why this is missed-wakeup safe

- The event-driven wake path (`enqueueReady` futexWake) is untouched — new ready
  work always wakes a worker promptly regardless of which timeout it parked on.
- Whenever **any** worker is idle-waiting, exactly one holds the sweeper claim and
  runs the 10ms sweep, so the missed-RX-wakeup recovery cadence is preserved at
  10ms in the common idle case. A worker that finishes a turn re-enters `takeReady`
  and re-claims the free slot before parking long.
- Worst case (the elected sweeper was just woken for real work and is mid-turn
  while every other worker is parked long): recovery falls back to
  `idle_park_ns` (1s) — the same bound the 2026-06-08 zero-context path already
  ships — then resumes 10ms once any worker idles again.

### Why no thundering herd

`enqueueReady` uses `futexWake(1)` (wake one), not broadcast. On a sweeper
timeout only the single ex-sweeper wakes (the other 511 are parked 1s and are not
signalled), does the sweep, and re-waits. No mass wakeup.

## 4. Validation (ReleaseSafe build box)

Idle server, poll loop pinned to 1 worker to isolate the cooperative-pool cost
(`GEODE_QUIC_POLL_WORKERS=1`), lingering connections held idle:

| lingering connections | BEFORE (busy-poll) | AFTER (one sweeper) |
|---|---|---|
| 16  | 36.0% | 4.4% |
| 32  | 36.8% | 5.4% |
| 64  | 37.4% | 6.8% |
| 128 | 46.6% | 6.2% |

~6–8× reduction; AFTER is flat regardless of connection count (one sweeper, not
512). Zero-connection idle is unchanged (~6%, the 2026-06-08 path preserved).

- **Query latency (unchanged):** `readstress` 8 workers → 5598 ops/s, p50 1.36ms /
  p95 1.92ms / p99 2.20ms, 0 errors. Single-worker (scheduler goes fully idle
  between sequential queries, so each must wake a parked worker): p50 1.39ms /
  p95 1.86ms / p99 2.44ms, 0 errors — no added latency from the longer park.
- **Sustained ingest (no stall):** `data-ingest ingest --from-dump testdata/dump
  --workers 16` completed clean (mapping + species + miner + facility_edges),
  exit 0, 0 errors.
- **Regression test:** `tests/test_quic_idle_cpu_with_contexts.zig`
  (`zig build test-quic-idle-cpu-with-connections`) boots a 1-poll-worker server,
  holds 32 idle connections, asserts server CPU < 20%. RED on baseline
  (36–47%), GREEN after (~5%).
- **Scheduler suite:** `test-quic-condition-cadence` — the first-stream/scheduler
  assertions (REQ-QUIC-HC-054/067/100/108) stay green; the futexWaitTimeout shape
  and `first_stream_scheduler_idle_sweep_ns` constant are preserved. (4 unrelated
  vendored-quic source-scan tests fail identically before and after this change.)
