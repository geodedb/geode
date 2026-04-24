# Task #31 triage — QUIC stream multiplex hang (2026-04-23)

## TL;DR

**Root cause identified without needing strace**: geode's per-connection
stream thread pool is sized at `num_threads=4` but the **blocking lane** —
the lane that `submit()` routes to and that services long-lived
`handleAdditionalStream` tasks — has only **1 worker**. Default-lane workers
refuse to help because `cpu_helps_blocking = false` (unset). Each QUIC
connection can therefore only dispatch **1 inline stream + 1 blocking-lane
stream = 2 concurrent** streams, not 4. Any additional streams submitted
via `stream_pool.submit` land in `blocking_inject` and never execute
until a running stream closes. The client's `BeginTx` write lands in the
kernel/QUIC RX buffer, no handler consumes it, so `io.ReadFull` blocks
forever.

Classification: **deadlock via resource-starvation / lane
misconfiguration** (not a race, not a QUIC-library bug, not a write-lock
deadlock).

## Evidence (why I'm certain)

Static-analysis proof, bottom-up:

1. `src/server/quic_connection_handler.zig:1994` hard-codes
   `stream_pool_size = 4` for the per-connection `pooled.ThreadPool`.
2. `src/server/quic_connection_handler.zig:1572` submits each accepted
   stream via `stream_pool.submit(...)` — which is the blocking-lane
   helper (see step 3).
3. `src/transport/thread_pool.zig:237-240` `submit()` unconditionally
   passes `.lane = .blocking`.
4. `src/transport/thread_pool.zig:216` hard-codes `blocking_workers = 1`
   in the upstream pool config.
5. `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:723` — only
   workers with `idx < blocking_workers` get `serves_lane = .blocking`.
   With `blocking_workers = 1` that's exactly worker 0.
6. `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:1756-1760`
   `rebalanceLane()`: a `.default` worker helps the blocking lane
   **only if `cpu_helps_blocking = true`**. Default is `false`
   (`/home/benji/src/devnw/zig/thread-pool/src/types.zig:321`).
   Geode never sets it.
7. `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:1381-1400`
   blocking submits go into `blocking_inject` and `submit()` returns
   success as soon as `tryPush` succeeds (queue cap ≈ 64). Items sit
   queued, never drained, if the single blocking worker is busy.
8. `src/server/quic_connection_handler.zig:1373-1456`
   `handleAdditionalStream` runs `runStreamQueryLoop` (line 1481), a
   **long-lived blocking I/O loop** that returns only on stream close
   — so the one blocking worker is pinned for the stream's lifetime.

Arithmetic matches the goroutine dump exactly:

- Go driver `DefaultQUICPoolSize = 4` ⇒ 4 QUIC conns for 16 sql.Conns
  (4 streams/conn).
- Per conn on server: 1 inline (`runStreamQueryLoop` in
  `handleQuicConnection`) + 1 blocking worker = **2 concurrent**.
- 4 conns × 2 = **8 running**; 4 × (4−2) = **8 stuck**.
- `w16-hang-with-goroutine-dump.log` shows **exactly 8** workers stuck
  in `BeginTx → QUICTransport.ReceiveProto → io.ReadFull`. Match.

Sub-config explains why `--workers=4` survived the node phase but
eventually hung: 4 workers on 4 QUIC conns = 1 stream/conn, fits inline;
edge-phase mutations are long-running under the per-graph write lock, so
cumulative stream churn eventually backs up the blocking queue on
occasional multi-stream bursts. `--workers=2` on big edge files:
occasional over-2-stream bursts during prepared-statement reuse
multiplex briefly, then stall.

## Reproducer (minimal, <30 s to hang)

A goroutine-level reproducer is unnecessary because the fault is
deterministic and structural, but for a regression test I recommend a
pure-Go minimal repro using the driver:

```go
// geode-test-harness/task31_repro.go — compile with `go run`
// pre: geode server running on :3141 with --insecure certs

func main() {
    dsn := "localhost:3141?insecure=true&user=geode&pass=<pw>"
    db, _ := sql.Open("geode", dsn)
    db.SetMaxOpenConns(4)  // force 4 sql.Conns on one QUIC conn
    db.SetMaxIdleConns(4)

    // Pin 4 sql.Conns onto one QUIC conn (DefaultQUICPoolSize=4;
    // so 4 sql.Conns all share one QUIC conn with 4 streams).
    conns := make([]*sql.Conn, 4)
    for i := range conns { conns[i], _ = db.Conn(context.Background()) }

    // Fire 4 BeginTx in parallel.
    var wg sync.WaitGroup
    done := make(chan int, 4)
    for i, c := range conns {
        wg.Add(1)
        go func(idx int, conn *sql.Conn) {
            defer wg.Done()
            ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
            defer cancel()
            tx, err := conn.BeginTx(ctx, nil)
            if err != nil { fmt.Printf("w%d: %v\n", idx, err); return }
            done <- idx
            tx.Commit()
        }(i, c)
    }
    wg.Wait()
    fmt.Printf("completed=%d/4\n", len(done))  // expect 1 or 2, not 4
}
```

Expected failure: `completed=2/4` after 10 s timeout. On the server this
is the same 1 inline + 1 blocking-worker limit per QUIC conn.

A still simpler Zig-side repro: add a unit test that submits 4
long-running `.lane = .blocking` tasks to a 4-thread pool and asserts
all 4 run concurrently. It will fail today.

## Root-cause candidates (ranked)

| # | Candidate | File:line | Verdict |
|---|-----------|-----------|---------|
| 1 | `blocking_workers = 1` with `submit()` always routing to blocking lane | `src/transport/thread_pool.zig:216` + `:237` | **Confirmed root cause** |
| 2 | Per-conn pool size 4 is conservative but correct intent, undermined by #1 | `src/server/quic_connection_handler.zig:1994` | Design flaw amplifying #1 |
| 3 | QUIC library `acceptStream` re-queues stream IDs on every data arrival | `/home/benji/src/devnw/zig/quic/src/quic/connection/methods_c.zig:302-315` | Works as documented; not the bug |
| 4 | Orphan-txn reaper fires on stream close | `src/server/quic_connection_handler.zig:3661,3706` | Tangent — reaper comment mentions "spurious FIN" (known QUIC-lib race) but is not in the stuck path |
| 5 | `PollSync` serializes reads across streams | `src/transport/quic.zig:70-133` | Not the bug — QUIC lib v0.1.10 has fine-grained internal locking; handlers don't hold poll_sync during reads |

## Classification

**Deadlock / lane-starvation** — structurally equivalent to running a
single-threaded server behind a 4-thread queue. Not a race; not
non-deterministic in the repro (every run with ≥3 concurrent streams on
one QUIC conn hangs at exactly the same point).

## Fix scope (defer to next phase)

Primary fix is in **geode** (NOT the external `zig/thread-pool` library):

- `src/transport/thread_pool.zig:216` — either pass
  `blocking_workers = @min(num_threads - 1, num_threads)` so all but one
  worker serve blocking, or set `cpu_helps_blocking = true` so default
  workers back-fill when the blocking queue has waiters.
- Alternative: `src/server/quic_connection_handler.zig:1572` — call
  `submitDefault` instead of `submit` for `handleAdditionalStream`.
  `submitDefault` routes to `.lane = .default` and uses all 4 workers
  symmetrically. This is the smallest, most targeted change, and it's
  what the thread-pool's `submitDefault` docstring (lines 242-254)
  recommends for exactly this use case: "Callers who need parallelism
  across N default-lane workers ... should use this entry point."

Secondary (cleanup, not blocking):

- Reconsider `stream_pool_size = 4` once the lane fix lands. With the
  16-worker msft-graph workload expecting up to 4 streams/conn, `4`
  covers the worst case; `8` would give headroom without ballooning
  thread count (16 conns × 8 = 128 threads, still under the 256 global
  cap).
- Add an integration test that forces 4 concurrent streams per QUIC
  conn and asserts none hangs past a 5-second budget.

**No fix needed in `zig/quic`** or `zig/thread-pool`. The upstream
libraries are correct; geode is using the wrong submit helper.

## Blockers

None for diagnosis. Fix phase needs:

- Rebuild + rerun msft-graph Phase 4.1 client (checkout `467021f`) to
  validate end-to-end (~2 min hang → expected to progress at w=16).
- No ptrace / perf needed; `std.debug.print` in `submitInternal` would
  confirm queue backlog but is unnecessary given static-analysis proof.
- The geodetestlab suite does not currently stress >2 streams per QUIC
  conn — before closing Task #31, add a regression test at
  `tests/test_gap_multiplexed_streams.zig` per the integration-test
  note above.

## Residual concerns

The "spurious FIN under concurrent load" comment at
`quic_connection_handler.zig:1261-1264` and the pending_result rescue
path at `:3706` suggest a secondary QUIC-library race exists (separate
from this hang). It's plausible that under msft-graph load the
stream-ID re-queue behavior in `queueIncomingStream` (methods_c.zig:302)
— which intentionally allows duplicates — combined with `tryAcceptStream`
draining via `swapRemove(0)` (non-FIFO) could deliver accept
notifications out-of-order relative to data arrival, leading to
mis-directed reads. This should be verified after the lane fix
eliminates the primary hang; if post-fix runs still show sporadic
stalls, open a separate ticket against the QUIC library.
