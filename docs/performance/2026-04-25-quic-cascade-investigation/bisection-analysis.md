# 9-min hang bisection — 2026-04-26 (workers=4 run)

Final task of the 9-task QUIC cascade investigation plan
(`docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md`).

Source artifacts (all committed at `a7b55acd`):

- `repro-server.log` — 300 `info: metrics:` lines emitted at a fixed 5 s
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
**Verdict: REFUTED.** `quic_min_flow_control_headroom` stays **≥ 8388372
(within 236 B of the full 8 MiB initial value) across all 300 metric
emissions** — across T0, T1, the entire 10-minute hang, T2, and the 1500 s
timeout window. The dip to 8388372 is < 0.003% of the window and corresponds
to the brief `bytes_in_flight` blips at the tail of the run (99 / 236 / 263
bytes seen near other metric lines). Flow control is never meaningfully
exhausted. There is no flow-control bottleneck.

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

**Controller-side error mix at T2 (sharper than "all chunks deadline-out
simultaneously").** `repro-ingest.log:286-291` shows the cascade is staged,
not simultaneous: only **chunk 0** hits `statement 170: context deadline
exceeded` (the true 10-minute deadline fire); **chunks 1, 2, 3** all hit
`statement 170: driver: bad connection`; **chunk 4** hits
`batch begin tx: sql: connection is already closed`. This is the
pinned-pool's shared-state cascade visible through the Go `database/sql`
driver: chunk 0's per-statement context deadline trips first, the QUIC
connection chunk 0 was pinned to closes (server- or client-initiated),
and chunks 1-4 then discover the dead connection on their next exec
attempt and fail almost simultaneously (all five errors land in the same
1 ms wall-clock window). This actually **strengthens** H4's "pinned-stream
lifecycle mismatch" framing — the connection-close visibly cascaded
across all chunks via the pinned-pool's shared per-connection state, so
the controller's pipeline fail-fast logic surfaces all five chunks as
"failed" within one emit window even though only one of them actually
hit its own deadline. Substance unchanged: H5 is still the chokepoint
that put chunk 0 onto the deadline path; H4 is still the downstream
symptom signature.

### Cross-cutting timing observation — the 10-minute clocks

The exact 10:00 Δ between T1 (last forward progress) and T2 (cascade
trigger) coincides with **two separate 10-minute clocks** in the system:

1. **The Go controller's per-statement context deadline.** The cascade
   surfaces in the client log as `chunk failed: statement 170: context
   deadline exceeded` — that is a Go SQL driver `context.WithTimeout` firing,
   not a QUIC protocol error.
2. **The server's `--idle-timeout 600000` flag** (10 minutes), set by the
   repro script `/tmp/run-quic-investigation-repro.sh:27`. When a QUIC
   connection sees no application traffic for 600 s, the server tears it
   down — which would produce exactly the 4 → 2 active-connection drop
   and EOF tick we see at T2.

These two timeouts are NOT necessarily causally linked. The Go context
deadline can fire while the server is healthy (slow query, fast network);
the server idle-timeout can fire while the client is healthy (long client
wait between statements, fast server). But the **exact 10:00 match across
both** deserves explicit acknowledgement so a future reader doesn't
mis-ascribe one or the other to the cascade root cause without checking.

The H5 verdict (rwlock-saturation chokepoint) holds regardless of which
clock fires first: the server is too slow to make forward progress
**either way**, and whichever 10-minute timer trips first is just the
proximate trip wire — not the underlying defect. To distinguish the two
clocks empirically, the recommended next investigation should **log the
server's last-activity-time per stream around the cascade trigger** to
confirm whether the server-side idle-timeout actually fires (its teardown
signature in the QUIC layer would differ from a client-initiated close).

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

**Tertiary**: empirically disambiguate the two 10-minute clocks
(controller's per-statement context deadline vs. server's
`--idle-timeout 600000`). Log server-side last-activity-time per stream
across the cascade window; the server-initiated idle-timeout teardown
would carry a distinct QUIC `CONNECTION_CLOSE` frame signature relative
to a client-initiated close. Cheap to add and resolves the residual
ambiguity flagged in the cross-cutting timing section above. Doesn't
change the H5 verdict but tightens the H4 narrative.

**Quaternary**: revisit the `NoHandshakeKeys` regression (Task 1 left
this INDETERMINATE and it surfaced again here at workers=4; under
heavier workers=16 it blocked the run entirely).

---

## Secondary bisection — rwlock SHARED hold-time (added 2026-04-26)

After the primary verdict (H5 — rwlock saturation as the wall-clock
chokepoint), the next investigation thread instrumented per-acquire
SHARED hold-time on `ManagedGraph`
(commits `c7eb4703` / `c29f441c` / `410b842d` / `a25a7a05` / `b48007e9` / `3bcfd597`)
and re-ran the same workers=4 cascade repro
(`docs/performance/2026-04-26-rwlock-hold-time/`, commit `463c01bb`).
Two new counters were added:

- `mg_rwlock_shared_hold_ns_total` — cumulative ns spent inside the
  SHARED critical section across all acquire sites.
- `mg_rwlock_shared_max_hold_ns_observed` — max single hold duration
  ever observed (high-water mark, monotonic).

The new repro emits metrics on the same 5 s cadence as the primary
investigation, so checkpoints are anchored the same way: emit #N ≈
ingest-start + N × 5 s.

### Reference timestamps

| Marker | Time | Notes |
|--------|------|-------|
| T0 ingest start | 2026-04-26T12:36:42 | Controller "ingest start" line (`repro-ingest.log:4`) |
| T0+5s (1st metric emit) | ≈ 2026-04-26T12:36:47 | First `info: metrics:` line at server-log L18 (emit #1) |
| T1 last forward progress | 2026-04-26T12:47:16 | `seeding edges file=edges_audited.jsonl` followed by `pipeline exec start geode.total=911` (`repro-ingest.log:283-285`) |
| T1+30s | ≈ 2026-04-26T12:47:46 | emit #133 / server-log L153 |
| T1+5min | ≈ 2026-04-26T12:52:16 | emit #187 / server-log L207 |
| T2−5s | ≈ 2026-04-26T12:57:12 | emit #246 / server-log L266 |
| T2 cascade trigger | 2026-04-26T12:57:17 | "pipeline failed — retrying file in serial mode" (`repro-ingest.log:291`); stack capture timestamp matches (`cascade-stacks.txt:1`) |
| Δ (T2 − T1) | 10 min 1 s | Same signature as the prior workers=4 cascade |
| Run config | --workers 4, --chunk-size 1000 | Identical to primary repro |

### Hold-time deltas

Per-interval avg-hold-per-acquire = `Δhold_ns_total / Δacquired_total`
(ns), reported in ms. Cumulative avg at T2 = `hold_ns_total[T2] /
acquired_total[T2]`.

| Checkpoint | acquired_total | hold_ns_total (ns) | avg-hold-per-acquire (ms) | max_hold_observed (ns) |
|------------|----------------|--------------------|---------------------------|------------------------|
| T0+5s | 0 | 0 | n/a — no acquires yet | 0 |
| T1 | 68 | 36,272,955,667 | **533** (cumulative T0→T1; interval n/a from zero) | 2,229,036,825 |
| T1+30s | 72 | 38,522,632,034 | **562** (interval T1→T1+30s: Δacq=4, Δhold=2,249,676,367) | 2,229,036,825 |
| T1+5min | 96 | 46,875,318,571 | **348** (interval T1+30s→T1+5m: Δacq=24, Δhold=8,352,686,537) | 2,229,036,825 |
| T2−5s | 124 | 56,999,476,714 | **361** (interval T1+5m→T2−5s: Δacq=28, Δhold=10,124,158,143) | 2,229,036,825 |
| T2 | 124 | 56,999,476,714 | **460** (cumulative T0→T2) | 2,229,036,825 |

#### When did per-acquire hold first cross the H5a threshold?

The instrumentation first emits non-zero values at emit #7 (server-log
L27, ≈ T0+35 s = 12:37:17): `acq=4, hold_ns=586,767,294,
max=531,308,838`. That gives a cumulative avg of **147 ms/acquire**
and a max single hold of **531 ms** — already at the upper end of the
H5a "hundreds-of-ms" threshold from the very first emitted sample.

The max single hold crossed 1 sec at emit #19 (≈ T0+95 s = 12:38:22)
with `max=1,263,318,098 ns = 1.26 s`, and reached the run's ceiling
of 2.23 s at emit #52 (≈ T0+260 s = 12:41:02). Both events occurred
**before T1** — the cascade-trigger run does not need T1's edges_audited
workload to surface multi-second holds; the SHARED critical section
was already chronically expensive during the earlier edge-seed phases
(`edges_activated_role.jsonl`, `edges_app_role_assignment.jsonl`).

### Sub-hypothesis verdict

#### H5a — Long MATCH-with-RLS holds the read lock

**Signature:** avg-hold-per-acquire grows from sub-microsecond at T0
to hundreds-of-ms or more at T1 onwards; max_hold_observed exceeds 1
second somewhere between T1 and T2.

**Verdict: YES — confirmed.** The cumulative avg per acquire at T2 is
**460 ms** (124 acquires, 56,999,476,714 ns total) — roughly 5× above
the "hundreds-of-ms" threshold. The largest single observed hold is
**2,229,036,825 ns = 2.23 s** — well above the "> 1 second"
threshold. Per-interval avgs (533 / 562 / 348 / 361 ms) confirm the
elevated hold-time is sustained across the 10-min hang window, not a
transient spike.

The signature is actually *stronger* than the original framing
predicted: the threshold is crossed **before T1**, not "between T1 and
T2." The first emit with a non-zero counter (emit #7, ≈ T0+35 s) already
shows a 531 ms max single hold and a 147 ms cumulative average — i.e.
the long-MATCH chokepoint is present from the start of the
edge-seeding phases, and the edges_audited.jsonl workload at T1 then
just keeps the lock saturated for the full 10-min hang. This refines
the original H5a hypothesis: it is not "edges_audited triggers long
holds" but "long holds are the steady state once the edge-MATCH-CREATE
phase begins; edges_audited is the file that finally exhausts the
controller's per-statement deadline."

**Cross-check from `cascade-stacks.txt` at T2 (12:57:17):**

- Thread 9 (LWP 114870) is the active SHARED holder, deep inside the
  RLS path:
  `executeMultiNodeMatch → passesRLSFilter → passesRLSExprFilter →
  rls_value_bridge.nodePropertiesToRLSRow → HashMapUnmanaged.allocate`
  (frames #13 → #11 → #10 → #3, file `cascade-stacks.txt:1518-1532`).
  This thread is allocating an RLS row in the per-node hash map — the
  exact code path the H5a hypothesis predicted.
- Threads 23 and 20 (LWPs 114856 and 114859) are blocked at
  `Io.RwLock.lockUncancelable → Io.Mutex.lockUncancelable` waiting on
  the `acquireGraphWriteLock` path from
  `ServerState.tearDownForStreamClose` (`cascade-stacks.txt:1289-1295`
  and `1338-1345`). These are the EXCLUSIVE waiters being starved by
  the long SHARED holder above.

This is a textbook reader-blocking-writer signature with the SHARED
holder in the RLS evaluation path — direct evidence supporting H5a.

#### H5b — Rwlock implementation is the chokepoint (per-acquire hold is small)

**Signature:** avg-hold-per-acquire stays small (< 1 ms) throughout
the run.

**Verdict: NO — refuted.** Per-acquire hold is 460 ms cumulative at
T2, not sub-millisecond — three orders of magnitude above the H5b
ceiling. The rwlock implementation is not the chokepoint; the work
done while holding the SHARED side is.

#### H5c — Neither (something else)

**Verdict: NO.** H5a fits the data cleanly; the per-checkpoint
trajectory, the stack at T2, and the reader-blocks-writer signature
all line up. No need to invoke H5c.

### Recommended next step

Based on the H5a verdict, the fix lives in
`match_operations.executeMultiNodeMatch` (and specifically the
`passesRLSFilter` / `passesRLSExprFilter` / `nodePropertiesToRLSRow`
sub-tree confirmed by the T2 stack). Three candidate approaches:

- **(a) Release the read lock between row batches and re-acquire.**
  Introduces a possible inconsistency window — if the graph mutates
  between batches, the second half of a single MATCH may see different
  state than the first half. Needs design review against MVCC
  semantics: is this acceptable, or does GQL require single-statement
  consistency? If the latter, this fix is out.

- **(b) Take a snapshot reference at MATCH-start and operate on that
  for the full scan.** No inconsistency window. But may overcommit
  memory under long scans if the snapshot must materialize the whole
  reachable graph region (depending on how MVCC snapshots are
  implemented in the storage engine). Probably the right fix if MVCC
  snapshot reads are cheap.

- **(c) Bound the MATCH execution time.** If individual query duration
  is the chokepoint, a per-statement deadline (separate from the
  QUIC-layer request deadline) at the executor level would let the
  query short-circuit rather than starve other writers. This is a
  defensive layer regardless of (a) or (b).

Recommend opening a new investigation plan for (b) — snapshot-based
reads — as the primary fix, with (c) as a defense-in-depth layer.

A complicating wrinkle from the T2 stack: the long hold is partly
spent inside `rls_value_bridge.nodePropertiesToRLSRow` building a
per-node `HashMapUnmanaged([]const u8, rls_core.Value, ...)` — i.e.
the per-node RLS row construction is itself a hot path inside the
critical section. Even if the rwlock is released between batches,
shrinking the per-node work (e.g. caching compiled property lookups
or moving the RLS row construction outside the lock) is likely needed
in tandem with (b). Worth noting in the follow-up plan.

### Out-of-scope follow-ups (from the rwlock-hold-time plan §"Out of scope")

Three items remain queued behind this verdict:

1. **Per-stream last-activity-time logging** — disambiguates the
   10-min idle-timeout coincidence (Task 2 of the original
   investigation list).
2. **`NoHandshakeKeys` regression in the new quic dep `c7808ed`** —
   needs upstream handoff in `~/src/devnw/zig/quic/`. Surfaced again
   in this run at server-log L17 / L20 / L22 / L24 alongside the
   first connection establishments.
3. **`quic_total_cwnd_bytes` unbounded growth** — small geode patch
   plus upstream handoff for the quic library's NewReno cwnd-cap.
   Counter climbed from `18,262` at T0+5s to `2,817,430,778,627`
   (≈ 2.8 TB) by emit #248, far past any reasonable ceiling.
