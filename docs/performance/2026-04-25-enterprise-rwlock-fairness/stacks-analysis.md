# Cascade-time stack analysis (2026-04-25)

> **POST-FIX UPDATE (2026-04-25, 22:44 UTC).** The Part 1 capture below
> was taken on `e9ee75d7` with 1838 threads, of which 1802 were idle
> pool-leak workers. That noise contaminated the analysis: its verdict
> was "REFUTE rwlock-starvation, blame per-connection thread-pool leak."
> Phase 1 of the upstream graph-storage shared-pool work landed and
> reduced NLWP to **97**. The cascade still triggers at the same point.
> A fresh capture on the cleaned-up run is preserved alongside this
> file as `cascade-stacks.txt` (the Part 2 capture; the original
> contaminated capture is now `cascade-stacks-prefix.txt`).
>
> The Part 2 analysis is appended below as **§"Part 2 — Post-fix
> re-analysis"** and supersedes the Part 1 verdict for the question
> "what is the cascade root cause?". Part 1 is preserved as a record of
> the investigation arc and the lessons learned about hypothesis
> contamination. **Both hypotheses (rwlock starvation AND per-engine
> thread-pool leak) are now refuted by Part 2's clean evidence.**

---

## Part 1 — Original analysis (now superseded)

Source: `cascade-stacks-prefix.txt` (renamed from `cascade-stacks.txt`,
gdb thread apply all bt at cascade trigger on commit `e9ee75d7`).

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

---

## Part 2 — Post-fix re-analysis (2026-04-25, 22:44 UTC)

Source: `cascade-stacks.txt` (gdb thread apply all bt at cascade trigger on
geode HEAD with `build.zig.zon` bumped to graph-storage `5ead31bc`).

### Thread-count summary

- Total threads at capture: **97** (down from 1838 — a 19× reduction)
- VmRSS: 207 MB. VmPeak: 2.07 GB virtual.
- Open FDs: 360.
- Cascade trigger time: 22:29:32 UTC, 9m 31s into ingest.
- Same trigger pattern as Part 1: 281/623 nodes flushed in 14s, then 9-min
  silence, then all 16 chunks fail simultaneously with `context deadline
  exceeded`.

### Cluster breakdown (frame #8 = top of pool/work loop)

| Count | Top frame | Meaning |
|-------|-----------|---------|
| 85 | `pool.Core.idle` | Idle thread-pool workers in futex_wait — same as Part 1 Cluster A but ~21× fewer |
| 7 | `pool.Core.workerMain` | Workers in transitional state (about to pick up or just finished a task) |
| 2 | `Thread.PosixThreadImpl.spawn.entryFn` | Generic spawned threads |
| 1 each | `cli.main.main`, `start_thread`, `Thread.callFn` | Main thread + supporting infrastructure |

### Cluster comparison: prefix vs postfix

| | Prefix (1838 threads) | Postfix (97 threads) |
|---|---|---|
| Idle pool workers | 1802 (the leak) | 85 |
| Active workers in `pool.Core.invokeTask` | **16** | **0** |
| QUIC stream-query handlers idle in `nextMessage` | 1 | 7 |
| Connection handlers idle in `nextMessage` | 0 | 4 |
| Stream acceptor loops | ~1 | 1 |
| QUIC pollLoop reactor | 1 | 1 |
| Persistence loop in nanosleep | 1 | 1 |

### What is actually happening at cascade time

Every single non-idle thread in the postfix capture is parked in a **passive
poll wait state with a 2 ms timeout**:

1. **Persistence loop** (Thread 93): `nanosleep` in its normal interval — not
   holding any locks, not running a checkpoint.
2. **3× `runStreamQueryLoop` threads** (Threads 76, 47, 29): all in
   `BufferedProtoReader.nextMessage` → `quic.PollSync.waitForPoll(timeout_ns=2000000)`
   waiting for the next client query to arrive on their pinned stream.
3. **4× `handleQuicConnection` threads** (Threads 19, 14, 13, 8): same
   `BufferedProtoReader.nextMessage(timeout_ns=2000000)` waiting at the
   connection level.
4. **streamAcceptorLoop** (Thread 27): `nanosleep` waiting for the next stream
   accept event.
5. **quic.QuicTransport.pollLoop** (Thread 7): `compat_sleepNs(500000)` —
   500 µs yield in the QUIC reactor, normal idle pattern.
6. **main async loop** (Thread 21): `server.main.main.run` in nanosleep —
   normal idle pattern.

**Zero threads** in `RwLock.lock`, `lockUncancelable`, `acquireGraphWriteLock*`,
`coord_apply_*`, `bulkInsert*`, `executeQuery`, or any other application path.
**Zero threads** in any database mutation code path.

The grep is exact:

```
$ grep -E 'rwlock|RwLock|acquireGraph|ManagedGraph|ShardedCoordinator|coord_apply|persistenceLoop|graph_storage_adapter' cascade-stacks.txt
176:#2  0x0000000002d5f88c in graph_store.persistenceLoop ()
$ grep -E 'lockUncancelable|Mutex.lock|Cond.wait|rwlock_shared|rwlock_exclusive' cascade-stacks.txt
(no matches)
```

### Re-evaluating the rwlock metric

`mg_rwlock_exclusive_wait_ns_total` trajectory across the run:

```
0 → 930 ns → 6.99 s → ... → 37,777,803,760 ns ≈ 37.78 s → frozen
```

Interpretation:

- Early in the run, **a writer (or several) accumulated 37.78s of cumulative
  wait time** while contending with the parallel-ingest readers. This was
  real contention.
- After reaching 37.78s, the metric **froze** — meaning **no new writers have
  entered the wait state** for the rest of the 25-min run.
- Shared-acquire counter continued creeping up at ~5/sec — readers are still
  occasionally acquiring (e.g., for the metric polling thread itself).
- **At cascade time, no thread is anywhere near `mg.rwlock`.** The metric is a
  historical record of past contention, not a measurement of current
  starvation.

The mid-session hypothesis "rwlock starvation is the remaining cause"
(filed in `docs/performance/2026-04-25-shared-stream-pool/2026-04-25-graph-storage-bump-result.md`
TL;DR table) was an over-interpretation of the frozen counter. Frozen ≠
parked — frozen means *nobody is even trying to acquire any more*.

### Verdict — REVISED FROM PART 1 AND FROM THE BUMP-RESULT TL;DR

**The cascade is NOT caused by `mg.rwlock` writer starvation.** No thread is
in any rwlock acquisition path. No thread is parked in any application lock
path. The rwlock metric is a historical artifact, not an active signal.

**The cascade is also NOT caused by per-engine thread-pool fanout.** That was
fixed by the graph-storage Phase 1 dep bump (NLWP 1881 → 97). The cascade
still triggers identically.

**The actual signature** at cascade time is a **server-side no-progress state**:

- All worker threads idle (not holding locks, not running queries)
- All stream-query handlers idle in `nextMessage` (no incoming queries to
  process)
- The QUIC reactor running normally (500 µs yield loops)
- The client claims to be sending queries; they are not arriving at the
  application layer

This is **upstream of the database**. The bottleneck is somewhere at the
**QUIC transport / client-server protocol boundary**. Candidate hypotheses
(in priority order):

1. **QUIC flow control / congestion stall.** The client's pinned
   `runStreamQueryLoop` connections might be waiting on credits or stuck in a
   recv-window=0 state. This would explain why `nextMessage` sees no incoming
   data despite the client claiming to send.
2. **Client-side retry storm after first deadline miss.** The chunks fail at
   exactly the 5s `context deadline exceeded` mark. If the client opens
   replacement connections (or tears down + reopens streams) under deadline
   pressure, the server's QUIC reactor may spend its budget on
   accept/handshake/teardown work and never deliver the original messages.
3. **A subtle mismatch between server-side pinned-connection state and
   client expectations.** The Go client uses `--workers 16 --chunk-size
   1000` and pins one connection per worker; the server reports
   `pinned connections acquired geode.count=16` early in the ingest.
   If a connection's keep-alive or stream lifetime is mismanaged, queries
   could be sent on a stream the server has already closed (or vice versa)
   without an explicit error surfacing.

The 9-minute hang between last forward progress (22:20:15) and the chunk
failure (22:29:31) is suggestive: it implies whatever request is "in flight"
takes ~9 minutes to surface a failure end-to-end. That is too long for a
lock — locks fail fast. It is consistent with a transport-layer wait
(QUIC keep-alive timeout, idle connection probe, or congestion-window
recovery cycle).

### Implications for the rwlock-fairness plan

- **Task 5 (apply writer-preferred / tryLock-with-backoff at each starved
  EXCLUSIVE call site) is NOT actionable.** The Part 1 verdict already
  marked it SKIP for a different reason; Part 2 confirms there is nothing
  to skip toward — there are no starved EXCLUSIVE acquirers. Patching
  rwlock call sites would change nothing about this cascade.
- **Task 6 (rwlock fairness regression test) was already committed
  (`fb5b3ea9`) and remains valuable** as documentation of the rwlock
  invariant. The test stays.
- **The rwlock-fairness plan as a whole should be marked CLOSED**, not
  paused. The hypothesis it was built around has been falsified by clean
  data twice (once in Part 1 with contaminated stacks, once in Part 2 with
  clean stacks).

### Recommended next investigation (out of this plan's scope)

Open a new investigation focused on the QUIC transport layer:

1. **Capture QUIC-level metrics during the 9-minute hang**: connection-level
   send/recv window size, in-flight bytes, pacing rate, packet loss, RTT.
   The geode QUIC vendored library at `~/src/devnw/zig/quic/` should
   already have these counters; they need wiring into the server's
   `runtime_metrics` periodic emit (parallel to what the persistence-loop
   diagnostic added in commit `aa9708d0`).
2. **Add server-side instrumentation to count incoming `BufferedProtoReader`
   delivery rate per connection.** If the client claims to be sending and
   the server `nextMessage` sees nothing, the discrepancy is the smoking
   gun.
3. **Bisect the 9-minute hang.** What event at 22:29:31 makes the chunks
   simultaneously decide to fail? The Go client's `context deadline
   exceeded` fires per-chunk based on a per-call deadline — they all fire
   together because they were all started together at ~22:20:15 and have
   the same deadline budget. So the question is: what happens between
   22:20:15 and 22:29:31 to PREVENT any one of them from completing?
4. **Cross-check against the `loadtest-compare` baseline.** If load-test
   QPS at concurrency=16 is unaffected, the cascade is specific to
   `msft-graph` ingest patterns (long-lived pinned connections, large
   batches). Otherwise it is broader.

### Why the prior bump-result TL;DR was over-confident

The bump-result document at
`docs/performance/2026-04-25-shared-stream-pool/2026-04-25-graph-storage-bump-result.md`
identified the rwlock as "the actual dominant cause" based on the **frozen
exclusive-wait metric alone** (server log evidence) without re-capturing
stacks. Part 2 here corrects that conclusion: the metric was a historical
artifact from early-run contention, not a live signal of current starvation.
The bump-result document should be updated with a footnote pointing to
Part 2; the broader claim "thread-pool fix is structurally correct, but
cascade has shifted to rwlock" decomposes into:

- **Thread-pool fix is structurally correct** — confirmed (NLWP 1881 → 97).
- **Cascade has shifted to rwlock** — refuted by Part 2 stacks. The cascade
  shifted to *something else*, not to the rwlock.
