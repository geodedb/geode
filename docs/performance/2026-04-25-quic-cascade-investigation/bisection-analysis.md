# 9-min hang bisection — 2026-04-26 (workers=4 run)

Final task of the 9-task QUIC cascade investigation plan
(`docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md`).

Source artifacts (all committed at `a7b55acd`):

- `repro-server.log` — 305 `info: metrics:` lines emitted at a fixed 5 s
  cadence (see `src/server/main.zig:947-964`).
- `repro-ingest.log` — controller log with wall-clock timestamps.
- `cascade-stacks.txt` — `gdb thread apply all bt` of all 97 server threads
  taken at `2026-04-26T02:04:53` (first line of the file confirms the timestamp).

## Reference timestamps

The server-side log carries no per-line wall-clock timestamps, so checkpoints
were anchored to the metric emit cadence (5 s) and the controller's ingest
log. Note that the actual ingest-start timestamp from the controller log is
`01:44:08`, not the `01:40:50` quoted in the task brief — the task narrative
predates the actual run. The cascade-trigger time (`02:04:53`) and the
edges_audited cutoff (`01:54:53`) are confirmed by the controller log.

| Marker | Time | Notes |
|--------|------|-------|
| T0 ingest start | 2026-04-26T01:44:08 | Controller "ingest start" line |
| T0+5s (1st metric emit) | ≈ 2026-04-26T01:44:13 | First `info: metrics:` line at server-log L18 |
| T1 last forward progress | 2026-04-26T01:54:53 | edges_audited.jsonl exec start; statement 170 was about to fail |
| T1+30s | 2026-04-26T01:55:23 | |
| T1+5min | 2026-04-26T01:59:53 | |
| T2−5s | ≈ 2026-04-26T02:04:48 | Last metric emission BEFORE the orphan-txn rollback warnings |
| T2 cascade trigger | 2026-04-26T02:04:53 | "pipeline failed — retrying file in serial mode"; orphan-txn warnings fire at server-log L271-272 |
| Δ (T2 − T1) | 10 min 0 s | The hang — exactly the controller's per-statement deadline |
| Stack capture timestamp | 2026-04-26T02:04:53 | First line of cascade-stacks.txt |
| Run config | --workers 4, --chunk-size 1000 | Reduced from historical --workers 16 |

The orphan-txn warnings at server-log lines 271–272 are the on-the-wire
fingerprint of the cascade: two transactions on `abs_eagleg` got rolled back
because the underlying QUIC streams closed mid-write. The very next metric
emission (L273) shows `quic_active_connections` dropped 4→2 and
`proto_reader_eof_total` ticked 2→5 in the same 5-second window.

## Metric deltas across the hang

All rates below are per-second, computed from cumulative counter values at
each checkpoint divided by the wall-clock interval. The per-checkpoint
absolute values appear in the second table.

| Metric | T0+5s → T1 (640 s) | T1 → T1+30s (30 s) | T1+30s → T1+5m (270 s) | T1+5m → T2−5s (300 s) | T2−5s → T2 (5 s) | T2 → post-T2 (5 s) | Verdict-relevant signal |
|--------|------|---------|-------------|------------|------|------|-------------------------|
| proto_reader_messages_delivered_total /s | **20.84** | **1.53** | **1.14** | **1.11** | 0.80 | 0.40 | **18× collapse at T1.** Server-side delivery throughput drops within seconds of edges_audited starting and stays flat for 10 minutes. NOT zero — server keeps trickling work through. |
| proto_reader_would_block_loop_iterations_total /s | 49.38 | 65.30 | 1.86 | 2.09 | 1.00 | 0.20 | Spin-rate FALLS from ~50/s to ~2/s during the hang. Threads aren't busy-waiting for absent data; they're elsewhere (blocked on something else — see stacks). |
| proto_reader_bytes_read_total /s | 13184 | 472 | 411 | 403 | 225 | 73 | **32× collapse.** Bytes still arriving (~400 B/s ≈ small QUIC keepalive/control traffic), so reader is functioning — there's just nothing meaningful coming in. |
| proto_reader_eof_total (delta) | 0 | 0 | 0 | 0 | 0 | **+3** | Three streams EOF'd in the 5 s straddling T2. |
| quic_active_connections (gauge value at end of interval) | 4 | 4 | 4 | 4 | 4 | **2** | **4 → 2 at T2.** Two QUIC connections torn down at the cascade trigger. |
| quic_total_bytes_in_flight (gauge value at end) | 0 | 0 | 0 | 0 | 0 | 0 | Always ≈ 0 (occasional 99–236 B blips elsewhere in the log). Server is NOT pinned at a congestion-window cap. |
| quic_total_cwnd_bytes (gauge delta) | +489 G | +73 G | +1.0 T | +2.0 T | +24 G | **−1.77 T** | Grew monotonically — Reno-style probing on idle connections inflates cwnd indefinitely. The −1.77 TB drop at T2 is purely from losing 2 of 4 connections (their per-conn cwnd evaporates from the sum). |
| quic_min_flow_control_headroom (gauge value at end) | 8388608 | 8388608 | 8388608 | 8388608 | 8388608 | 8388608 | **Pinned at 8 MiB the entire run.** Flow control is NEVER exhausted. H1 refuted outright. |
| mg_rwlock_shared_acquired_total /s | 0.111 | 0.033 | 0.104 | 0.090 | 0.200 | 0.200 | Reader acquires are infrequent (~1 every 10 s) but never zero. Steady. |
| mg_rwlock_exclusive_wait_ns_total (cumulative ns at end of interval) | 1.79e12 | 1.87e12 | 2.69e12 | 3.59e12 | 3.60e12 | 3.63e12 | **2.79–3.02 × 10⁹ ns of writer-wait accrue per second of wall-clock**, holding steady the whole run. With ≤4 contending writers this is **0.70–0.76 of every wall-clock second** spent by EACH writer waiting for the rwlock. |

### Cumulative absolute counter values

| Snapshot | msgs | wb_iters | bytes_read | eof | sh_acq | ex_wait_ns | conn | in_flight | cwnd | fc_headroom |
|----------|------|----------|------------|-----|--------|------------|------|-----------|------|-------------|
| T0+5s (L18, idx 1)     | 5      | 125    | 244     | 2 | 0   | 0              | 1 | 0 | 15163         | 8388608 |
| T1 (L149, idx 129)     | 13342  | 31730  | 8438158 | 2 | 71  | 1786498309158  | 4 | 0 | 489237677892  | 8388608 |
| T1+30s (L155, idx 135) | 13388  | 33689  | 8452330 | 2 | 72  | 1872998418219  | 4 | 0 | 562709899735  | 8388608 |
| T1+5m (L209, idx 189)  | 13697  | 34191  | 8563375 | 2 | 100 | 2688042298169  | 4 | 0 | 1566178032579 | 8388608 |
| T2−5s (L269, idx 249)  | 14030  | 34819  | 8684330 | 2 | 127 | 3593625738220  | 4 | 0 | 3614039536125 | 8388608 |
| T2 (L270, idx 250)     | 14034  | 34824  | 8685455 | 2 | 128 | 3599386669846  | 4 | 0 | 3638096900347 | 8388608 |
| post-T2 (L273, idx 251)| 14036  | 34825  | 8685818 | 5 | 129 | 3628900046300  | 2 | 0 | 1871860124774 | 8388608 |

### Pre-T2 reference: T2-bracketing 5 s windows (server log L268..L275)

| L268 | L269 | L270 | L271 | L272 | L273 | L274 | L275 |
|------|------|------|------|------|------|------|------|
| conn=4, eof=2, cwnd=3.57T | conn=4, eof=2, cwnd=3.61T | conn=4, eof=2, cwnd=3.64T | (warning: orphan-txn rolled back, txn=…377) | (warning: orphan-txn rolled back, txn=…382) | conn=2, eof=5, cwnd=1.87T | conn=2, eof=5, cwnd=1.89T | conn=2, eof=5, cwnd=1.90T |

The 4 → 2 connection drop, the +3 EOF tick, and the cwnd halving all
materialise in a single 5 s metric window — and they bracket the orphan-txn
rollback log lines exactly. This is the moment the cascade fires.

## Stack-capture clusters at T2

97 threads total. Frame-#4 cluster breakdown:

```
     87 Io.Threaded.futexWait
      3 Io.Threaded.futexWaitUncancelable
      2 thread_pool.ThreadPool.runSubmittedTask
      1 server.quic_connection_handler.handleClientMessage
      1 server.main.runPollLoopTask
      1 quic.QuicTransport.accept
      1 pool.Core.runTask
      1 hash_map.HashMapUnmanaged([]const u8,rls_core.Value,hash_map.StringContext,80).allocate
```

The 87+3 = 90 `futex*` threads are **all** thread-pool workers idle in
`pool.Core.idle → sync.Condition.timedWait` (frame #6 cluster confirms: 87
on `sync.Condition.waitInner`, 3 on `Io.Mutex.lockUncancelable`). The pool
has plenty of workers; they have nothing to do.

The interesting threads, hand-extracted:

| Thread | Top-of-stack signature |
|--------|------------------------|
| **T19** | `acquireGraphWriteLockCancelable` (graph `abs_eagleg`, lock 0x7f675cf60118) inside `handleQuicConnection → handleClientMessage` |
| **T20** | `acquireGraphWriteLockCancelable` (same lock 0x7f675cf60118) inside `handleQuicConnection → handleClientMessage` |
| **T23** | `acquireGraphWriteLockCancelable` (same lock 0x7f675cf60118) inside `handleQuicConnection → handleClientMessage` |
| **T89** | `acquireGraphWriteLockCancelable` (same lock 0x7f675cf60118) inside `handleAdditionalStream → runStreamQueryLoop → handleClientMessage` |
| **T12** | `passesRLSExprFilter → nodePropertiesToRLSRow → HashMap.put → allocate` — only thread doing actual compute, mid-MATCH-with-RLS |
| **T7**  | `quic.QuicTransport.pollLoop` — 500 µs sleep (normal, healthy) |
| **T27** | `streamAcceptorLoop` — sleeping (normal) |
| **T93** | `graph_store.persistenceLoop` — sleeping (normal) |
| **T21** | `server.main…run` — sleeping (normal) |

**All four QUIC handler threads (T19, T20, T23, T89) are queued on the
SAME per-graph rwlock at address `0x7f675cf60118` for `abs_eagleg`.** The
deadline timestamps on each frame (810459079761034, 810459893373195,
810460587409637, 810461053588099) are within ~2 ms of each other — they
arrived at the lock in essentially a tight burst and have been waiting ever
since. Three of them are in `lockUncancelable` (futex), one is in a
nanosleep poll path inside `acquireStoreWriteLockCancelable` (T89, the one
in `runStreamQueryLoop`).

Comparison to the post-thread-pool-fix capture from
`docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks-postthreadpoolfix.txt`
(same workers=4 setup, after the thread-pool hoist landed in commit
`b52846cc`):

```
     85 Io.Threaded.futexWait
      4 server.quic_connection_handler.handleQuicConnection
      3 server.quic_connection_handler.runStreamQueryLoop
      2 thread_pool.ThreadPool.runSubmittedTask
      1 server.main.runPollLoopTask
      1 quic.QuicTransport.accept
      1 pool.Core.runTask
```

The post-fix capture has 4 + 3 = 7 active connection-handler threads. The
current capture has 4. **Three QUIC connection-handler threads are missing
from the current capture** — exactly consistent with the gauges (4 → 2 conn
drop plus already-EOF'd streams). The thread-pool fix delivered what it
promised (no thread leaks; all the `futex*` threads are idle workers, not
zombies) but it does not address the upstream chokepoint, which is at the
write-lock acquisition layer.

Instrumentation-overhead sanity check: zero threads appear in
`proto_reader_metrics`, `quic_connection_metrics`, or `runtime_metrics`
frames in the stack capture. The cacheline-contention concern flagged
during Task 6's review is not materialising in this run.

## Hypothesis verdict

### H1 — Flow-control deadlock

**Signature:** `quic_min_flow_control_headroom = 0` at T1 and stays 0 to T2.
**Verdict: REFUTED.** `quic_min_flow_control_headroom` stays pinned at the
8388608 = 8 MiB initial value across **all 305 metric emissions** — across
T0, T1, the entire 10-minute hang, T2, and the 1500 s timeout window. Flow
control is never exhausted and bytes_in_flight is essentially zero
throughout (occasional small blips of 99 / 236 / 263 bytes near other
metric lines). There is no flow-control bottleneck.

### H2 — Congestion-control collapse

**Signature:** `quic_total_cwnd_bytes` collapses by T1 and stays small;
bytes_in_flight pinned at the cwnd cap.
**Verdict: REFUTED.** `quic_total_cwnd_bytes` grows **monotonically**
across the run, from 15 KiB at T0 to 3.64 TB right before T2 — an
artifact of NewReno-style cwnd probing that never actually has data to
send (Reno keeps growing cwnd as long as `bytes_in_flight < cwnd`, which is
always true here because there's no traffic). The 1.77 TB drop at T2 is
a direct consequence of two connections vanishing from the gauge sum, not
a per-connection congestion event. Bytes-in-flight stays at zero. No
congestion event happened.

### H3 — BufferedProtoReader silent-receive

**Signature:** `proto_reader_bytes_read_total` rate > 0 but
`proto_reader_messages_delivered_total` rate = 0 between T1 and T2 (partial
frames accumulating).
**Verdict: REFUTED.** Both rates fall together (32× and 18× respectively).
During the hang both are POSITIVE: bytes_read averages ~411 B/s and
messages_delivered averages ~1.1/s. The reader IS still parsing complete
messages — it's just not getting many. There is no partial-frame
accumulation and the buffer-management code is exonerated.

### H4 — Pinned-stream lifecycle mismatch

**Signature:** `quic_active_connections` drops between T1 and T2;
`proto_reader_eof_total` ticks upward simultaneously; the stack capture at
T2 shows fewer `runStreamQueryLoop` threads than at T0.
**Verdict: PARTIALLY CONFIRMED — but as a downstream symptom of H5, not
the root cause.** The signature is unmistakable: at T2 the active-conn
gauge drops 4 → 2, eof_total ticks 2 → 5, the cwnd-sum halves, and the
stack capture is missing three of the seven QUIC connection-handler frames
relative to the post-thread-pool-fix baseline. Two QUIC connections were
torn down. **But** the connections were torn down **because** they had
been hung for the full 10-minute client-side per-statement deadline (the
controller's `chunk failed: statement 170: context deadline exceeded`
error matches a Go SQL driver exec timeout, not a QUIC protocol error).
The handler threads were still alive at this snapshot — the four threads
T19, T20, T23, T89 are all still spinning in `acquireGraphWriteLockCancelable`.
H4 is what the cascade looks like from the client's perspective; H5 below
is what caused it.

### H5 — Other (rwlock saturation as wall-clock chokepoint)

**Signature:** `mg_rwlock_exclusive_wait_ns_total` climbs FAST and steadily;
measured aggregate writer-wait is so large it accounts for a substantial
fraction of run wall-clock; failure mode is "throughput collapse under
sustained writer queueing," distinct from "writer starvation."
**Verdict: CONFIRMED — root cause.**

| Interval | Δt (s) | Δ exclusive_wait_ns | rate (ns/s) | per-writer ratio (÷4 writers) |
|----------|-------:|--------------------:|------------:|------------------------------:|
| T0+5s → T1     | 640 | 1.79e12 | 2.79e9 | **0.698** |
| T1 → T1+30s    |  30 | 8.65e10 | 2.88e9 | **0.721** |
| T1+30s → T1+5m | 270 | 8.15e11 | 3.02e9 | **0.755** |
| T1+5m → T2−5s  | 300 | 9.06e11 | 3.02e9 | **0.755** |

Each writer thread spends **70–76% of every wall-clock second** queued on
the rwlock — and the rate is **steady-state linear** (the per-writer ratio
holds within ±0.05 across all intervals). This is not pathological queue
growth (which would be super-linear); it is a consistent throughput
ceiling enforced by lock-acquisition cost. Total cumulative writer-wait
hits 3628.9 s (≈ 60 min) in 1250 s wall-clock with ≤4 writers — a
writer-wait/wall-clock ratio of 2.90× across the pool.

The stack capture corroborates: ALL four active QUIC handler threads are
queued on the same `0x7f675cf60118` rwlock for `abs_eagleg`, with deadline
timestamps within 2 ms of each other (they piled up in a tight burst and
have been there ever since). The single thread NOT idle is T12 doing per-row
`passesRLSExprFilter → nodePropertiesToRLSRow → HashMap.put` work — a slow
RLS-evaluating MATCH that holds the read lock while writers queue up.

Important framing distinction: this is **not** "writer starvation" in the
classic rwlock-fairness sense (where some writers never get the lock).
The historical `enterprise-rwlock-fairness` Part-2 investigation
specifically refuted that hypothesis. Writers DO eventually acquire the
lock — there are 13342 → 14034 `proto_reader_messages_delivered`
events across the hang, and `mg_rwlock_shared_acquired_total` advances from
71 → 128 (writers and readers both make progress). What's broken is
**throughput**: the lock can be acquired, but acquisition costs ≈70% of
wall-clock per attempt, so aggregate throughput collapses.

## Pre-existing failure modes flagged during this run (not the verdict, but worth knowing)

- **`NoHandshakeKeys` errors during connection establishment** (server log
  lines 17, 19, 20, 22). Same regression Task 1 surfaced. Did NOT prevent
  connection establishment at workers=4 — eventual retry succeeded and
  the run reached 4 active connections — but at workers=16 the prior
  repro session showed it kept the client from connecting at all. Worth a
  separate investigation thread.

- **`quic_min_smoothed_rtt_ns / quic_max_smoothed_rtt_ns =
  12297829382473034410`** — that's `0xAAAAAAAAAAAAAAAA`, the Zig
  uninitialized-memory sentinel (`undefined` byte pattern in safe builds).
  The `Connection.rtt_app.smoothed_rtt_ns` field is being read before any
  RTT sample lands. Instrumentation bug — the gauge callback should detect
  "never measured" and return 0. Out of scope for this analysis (we
  treated the rows as unmeasured and skipped them) but should be
  fixed before the gauges are useful for any future RTT-based diagnosis.

- **Linear cwnd drift** — `quic_total_cwnd_bytes` summed across idle
  connections grows without bound (15 KiB → 3.6 TB across 25 minutes). The
  underlying NewReno/CUBIC implementation has no `bytes_in_flight`-gated
  cwnd cap on idle paths. Cosmetic for this analysis but the gauge value
  is meaningless once cwnd exceeds any plausible window. A
  `min(cwnd, max_send_buffer)` clamp would make the gauge more honest.

## Recommended fix path

The verdict is H5, with H4 as a coupled downstream symptom. The fix lives at
the rwlock layer, not in QUIC.

- **`graph_storage_adapter.zig` writer paths under sustained 4-way write
  contention.** The 3654 s of cumulative writer wait at workers=4
  (writer-wait / wall-clock ratio = 2.90×) is the chokepoint. Two
  candidate root causes within H5:

  1. **A long-lived MATCH-with-RLS holding the read lock.** Thread T12 in
     the capture is mid-`passesRLSExprFilter` doing per-row hashmap
     allocation. If `executeMultiNodeMatch` holds the read lock for the
     duration of a full graph scan with RLS evaluation, that single
     reader can starve all writers as the graph grows. The "writers
     accrue 70% wall-clock wait per writer, steady-state" signal is
     consistent with one long reader being interleaved with batches of
     writers. **Recommended next probe:** instrument the read-lock
     hold-time per query in `acquireGraphReadLockCancelable` /
     `releaseGraphReadLockCancelable` (it currently has no
     held-duration counter), and re-run.

  2. **Per-acquire overhead inside `Io.RwLock.lockUncancelable`.** The
     stack shows three of the four queued writers sitting in
     `Io.Mutex.lockUncancelable` inside the rwlock implementation — the
     rwlock's internal mutex itself is contended. If
     `Io.RwLock.lockUncancelable` does work proportional to the number
     of pending acquirers (e.g., scans a waiter list), the cost-per-acquire
     could grow with concurrency. Less likely than (1) because the
     historical `enterprise-rwlock-fairness` work already audited this,
     but worth re-checking with the new "throughput collapse, not
     starvation" framing.

- **Address the H4 symptom independently.** Even with H5 fixed, the
  client-side 10-min deadline → orphan-txn rollback path is harsh.
  Options: shorter server-side deadline + earlier `BUSY` response so the
  client can retry without losing the stream; or in-flight progress
  reporting on long writes so the client extends its deadline on liveness
  signals.

- **Address H1/H2/H3 are NOT applicable.** The QUIC transport is healthy
  end-to-end — flow control is fine, no congestion event happened, and
  the BufferedProtoReader is parsing what it gets.

## Recommended next investigation thread

**Top priority: instrument the read-lock hold-time per query and re-run
the cascade repro at workers=4.** The smoking gun is the combination of
(a) one long-running MATCH-with-RLS reader (T12), (b) four writers all
queued on the same per-graph rwlock for `abs_eagleg`, and (c) writer-wait
accruing at 70-75% of each writer's wall-clock the entire run. If one
reader holds the lock for tens of seconds at a time, that explains every
single signal in this analysis. The fix would then live in
`match_operations.executeMultiNodeMatch` — release the read lock between
row batches, or hold a snapshot reference instead of the live lock for
the duration of the scan.

**Secondary**: fix the `quic_min/max_smoothed_rtt_ns` sentinel bug
(`Connection.rtt_app.smoothed_rtt_ns` returns `undefined` before first
sample; gauge callback should fall back to 0).

**Tertiary**: revisit the `NoHandshakeKeys` regression (Task 1 left this
INDETERMINATE and it surfaced again here at workers=4; under heavier
workers=16 it blocked the run entirely).
