# Phase 4.1 validation — hang reproduced under concurrency (2026-04-24)

## TL;DR

**Phase 4.1 + default group_commit fails the ≤ 60 s target.**  The
seed hangs indefinitely in every parallel configuration tested,
with workers blocked in `QUICTransport.ReceiveProto` waiting for a
`BeginTx` response that never arrives.

Serial mode completes successfully.  The hang is specific to
pinned-conn reuse under concurrent load, and reproduces with or
without `GEODE_GROUP_COMMIT`.

## Test matrix

| Config | Result | Where it hung |
| --- | --- | --- |
| `--parallel --workers 16` | HANG | `users.jsonl` at 317/621 nodes (~51%) |
| `--parallel --workers 16` + `GEODE_GROUP_COMMIT=0` | HANG | `users.jsonl` at 317/621 nodes |
| `--parallel --workers 8` | WORKS through node phase | no hang observed before kill |
| `--parallel --workers 2` | node phase OK, edges hang | `edges_app_role_assignment.jsonl` (2nd edge file) at 0/400 — both workers stuck |
| `--parallel=false` (serial) | WORKS | completed all 25 node files in ~3 min, edges progressing |

All runs used geode `24db46c5` (default `group_commit` ON) + msft-graph
`467021f` (Phase 4.1 pinned conns).

## Goroutine dump evidence

`kill -QUIT <pid>` on the `w=16` hang produced identical stack
traces for all 8 stuck workers (saved as
`phase4.1-validation/w16-hang-with-goroutine-dump.log`):

```
runtime.gopark
io.ReadFull(...)
geodedb.com/geode.(*QUICTransport).ReceiveProto
    transport.go:259
geodedb.com/geode.(*Conn).BeginTx
    conn.go:471
database/sql.ctxDriverBegin
database/sql.(*DB).beginDC.func1
database/sql.(*Conn).BeginTx
main.batchExecTxOnConn
    geodeutil.go:308
main.batchExecPinned
    geodeutil.go:564
main.pipelineExec.func1
    geodeutil.go:718
```

Every stuck goroutine is on `conn.BeginTx → QUICTransport.ReceiveProto
→ io.ReadFull`, waiting for a `BeginTx` response.  The server is
idle (all threads in `S` state per `/proc/<pid>/task/*/wchan`:
82 futex_do_wait, 15 hrtimer_nanosleep).

## Server responsiveness check

While the seed was hung, `geode query --server 127.0.0.1:3151
"RETURN 1"` on a FRESH conn returned successfully.  So the server
is alive and the QUIC transport is functional — but BeginTx on
pre-existing pinned conns never returns.

## Hypothesis

Per-conn server-side state gets into a bad state after some
threshold of sequential transactions on a single QUIC connection:

- Serial path (fresh conn per chunk) never reuses a conn long
  enough to trigger — no hang.
- Parallel `w=16` triggers fast — first 8 chunks complete, next 8
  hang immediately.
- Parallel `w=2` takes longer to accumulate — node phase
  completes (25 files' worth of chunks), but the second edge file's
  MATCH+CREATE pattern trips the bad state.

The common factor is pinned-conn reuse: once the trigger
condition is hit on a pinned conn, every subsequent BeginTx on
THAT conn is silently dropped by the server.

## What we know it ISN'T

- **Not group_commit**: reproduces with `GEODE_GROUP_COMMIT=0`
  forcing the single-phase path.
- **Not slog observability loss**: hang is directly reproducible
  and verifiable via goroutine dump.
- **Not client-side batchExecPinned retry loop**: workers are
  stuck in the FIRST attempt, not looping.
- **Not pool exhaustion**: `MaxOpenConns = workers*2 = 32` with
  16 pinned; 16 slots free for fresh conns.
- **Not QUIC stream-limit**: default 1000 bidi streams per conn;
  each chunk uses ~40 streams, 8 completed chunks = 320 streams
  per conn, well below limit.

## Recovery options

**A. Revert Phase 4.1**, keep the `batchExecTxOnConn` primitive
   and the `ConnMaxIdleTime=10min` tune.  Restore
   `pipelineExec`'s per-chunk `pool.DB().Conn` pattern.  Loses
   the per-file warm-conn benefit but eliminates the hang.
   Phase 4.0's HELLO storm becomes the new floor (~30 s/file
   QUIC reconnect).

**B. Cap pinned conn transaction count**.  After N transactions
   (say 5) per pinned conn, explicitly close-and-replace via
   `pinned.Replace`.  Trades a small amount of HELLO overhead
   for reliability.  Exact N needs empirical tuning.

**C. Server-side fix**.  Identify WHY the server drops BeginTx
   on long-lived QUIC conns.  Candidate areas:

- QUIC stream ID recycling / reuse in the Zig library
- Per-conn session state in `src/server/quic_connection_handler.zig`
- Auth cache TTL on session tokens (auth re-check deadlocks?)
- Orphan-txn reaper (`orphan-txn rolled back on stream close`
     — could this fire incorrectly on pinned conns?)

Recommended: **B** first (client-side tactical), then pursue **C**
in parallel as the real fix.

## Artifacts

- `phase4.1-validation/w16-hang.log` — seed log showing 317/621
  then silence.
- `phase4.1-validation/w16-hang-with-goroutine-dump.log` — full
  `SIGQUIT` goroutine dump showing 8 workers stuck in BeginTx.
- `phase4.1-validation/w8-node-phase.log` — workers=8 progress
  through node phase (no hang observed in first file).
- `phase4.1-validation/w2-edge-hang.log` — workers=2 completing
  node phase then hanging on `edges_app_role_assignment`
  (`BeginTx` stuck).
- `phase4.1-validation/serial-works.log` — `--parallel=false`
  progressing cleanly through node + edge phases.

## Commits tested

- geode `a86b634b` (Phase 4.1 status doc + Phase 2.4 base).
- geode `24db46c5` (group_commit default-on + build.zig thread_pool
  dep fix).
- msft-graph `467021f` (Phase 4.1 seed-top-level pinned-conn
  pipelining with keepalive).
