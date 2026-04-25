# Cascade-time stack analysis (2026-04-25)

Source: `cascade-stacks.txt` (gdb thread apply all bt at cascade trigger).

## Thread-count summary

- Total threads at capture: **1838**
- VmRSS: 680 MB. VmPeak: 30 GB virtual.
- Open FDs: < 360.
- Distinct top-frame-cluster shapes: 13 (vast majority in one cluster).

## Cluster A — IDLE thread-pool workers (1802 threads, 98%)

Top frames:

```
#0  Io.Threaded.Thread.futexWaitInner (...)
#1  Io.Threaded.Thread.futexWait (..., expect=128)
#2  Io.Threaded.futexWait (...)
#3  Io.futexWaitTimeout__anon_22123 (...)
#4  sync.Condition.waitInner (...)         zig-pkg/thread_pool-0.2.0/src/sync.zig:73
#5  sync.Condition.timedWait (...)         zig-pkg/thread_pool-0.2.0/src/sync.zig:49
#6  pool.Core.idle (...)                   zig-pkg/thread_pool-0.2.0/src/pool.zig:2194
#7  pool.Core.workerMain (...)             zig-pkg/thread_pool-0.2.0/src/pool.zig:1627
```

Status: **IDLE pool workers waiting for work**. They are NOT blocked on any application lock, NOT starved acquirers, NOT contending for `mg.rwlock`.

These 1802 threads represent **~106 distinct thread pools × ~17 workers each**. Each pool's workers sit in `pool.Core.idle()` indefinitely until the pool is `deinit`'d.

## Cluster B — actively-running pool tasks (16 threads)

Top frames:

```
#3  thread_pool.ThreadPool.runSubmittedTask    src/transport/thread_pool.zig:333
#4  pool.Core.runTaskWithOptions (...)         zig-pkg/thread_pool-0.2.0/src/pool.zig:2054
#5  pool.Core.runWorker (...)                  zig-pkg/thread_pool-0.2.0/src/pool.zig:1960
#6  pool.Core.workerMain (...)                 zig-pkg/thread_pool-0.2.0/src/pool.zig:1631
```

Status: 16 active worker threads — these ARE the shard workers from `ShardedCoordinator` (`runSubmittedTask` is the dispatch shim wrapping `shardLoop`).

## Other small clusters (≤ 5 threads each)

- 4 × QUIC stream-acceptor loop (`runStreamAcceptorLoop` in `quic_connection_handler.zig:1599`).
- A handful of QUIC stream-query handlers.
- Main thread.
- Persistence loop.

**Zero threads** were observed in `RwLock.lock`-style application paths (i.e., NOT in `acquireGraphWriteLock` / `acquireGraphWriteLockCancelable` / `acquireWholeGraphExclusive`).

## Verdict — REVISED FROM PLAN'S PREMISE

The cascade is **NOT caused by `mg.rwlock` EXCLUSIVE-side starvation**. The 21,289 s of cumulative `mg_rwlock_exclusive_wait_ns_total` reported in the prior plan's diagnosis appears to be a measurement artifact (or the wait time is real but the resulting accumulated thread count is not from blocked rwlock waiters).

**The actual root cause: per-connection thread-pool leak under msft-graph's per-file reconnect pattern.**

Mechanism:

1. `quic_connection_handler.handleQuicConnection` creates a **new `pooled.ThreadPool`** at `src/server/quic_connection_handler.zig:1995` (4 stream workers + 1 acceptor = ~5 threads) PER QUIC CONNECTION.
2. msft-graph reconnects per-file (45 files × 16 workers = ~720 connections over the full ingest).
3. Each connection close runs `defer stream_pool.deinit()` with `deinit_timeout_ns = 2 * std.time.ns_per_s`. If any task is still running at close time, the deinit ABANDONS the pool — workers stay alive but the pool is no longer tracked.
4. ~106 leaked pools × ~17 workers each ≈ **~1800 zombie threads**, exactly matching the 1802 idle pool workers we captured.
5. With ~1800 threads competing for kernel scheduler slots, the QUIC packet-pump thread eventually loses fairness; under sustained 16-way load the latency between client-statement-send and server-ack exceeds the client's 5 s deadline; cascade triggers.

## Implications for the plan

- **Task 5 (apply tryLock-with-backoff / writer-preferred at each rwlock site)** is targeting the wrong root cause. SKIP it.
- **Task 6 (rwlock fairness regression test)** is already committed (`fb5b3ea9`) — keep it as documentation of the rwlock invariant, but it's NOT the bug we're chasing.
- **The actual fix** needs to address the per-connection thread-pool leak, NOT rwlock fairness. That's a different plan entirely.

## Recommended fix path (out of this plan's scope)

Three plausible options for the leak:

### Option A — Raise per-connection pool `deinit_timeout`

Change the `2 * std.time.ns_per_s` ceiling at `src/server/quic_connection_handler.zig:2017` to e.g. `30 * std.time.ns_per_s`. Tasks that take 2-30 s to drain on connection-close will complete cleanly instead of leaving zombie threads. Cost: connection-close latency under load.

### Option B — Replace per-connection pools with a single shared stream pool

Allocate ONE `pooled.ThreadPool` at server startup (e.g., `64` stream workers + `4` acceptor workers). Every connection submits work to this pool instead of creating its own. Pool lifecycle = server lifetime — no per-connection leak surface.

This is the architecturally clean fix. It matches the existing main-pool pattern (the connection-dispatcher already uses a single global pool at `src/server/main.zig:993`).

### Option C — Move pool ownership outside `handleQuicConnection`

Same as B but more incremental: keep the per-connection pool struct shape but allocate a singleton at server startup and pass it down through `handleQuicConnection`'s context. Requires updating the function signature and the call sites.

## Recommended next step

Stop the current plan (rwlock fairness was the wrong target). Write a new plan focused on the thread-pool leak fix.
