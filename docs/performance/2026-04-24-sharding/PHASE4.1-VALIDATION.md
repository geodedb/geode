# Phase 4.1 validation — REVERTED (2026-04-24)

## TL;DR

**Phase 4.1 reverted.**  Client-side seed-top-level conn pinning
triggers a server hang in every parallel configuration tested.
Root cause: **the geode Go driver's `DefaultQUICPoolSize = 4`**
multiplexes logical sql.Conns via streams on only 4 underlying
QUIC connections — so pinning 16 conns actually pins 4 QUIC
conns with 4 streams each, and the geode server has a bug
handling 4+ concurrent streams per QUIC conn.

Even worker counts below the QUIC pool size eventually hit the
hang on larger data sets (w=4 hung on `audit_events` 2414 nodes).
The revert restores Phase 2.4 behavior (slow, retries, but
forward progress).

## Test matrix

| Config | Pinned | Result |
| --- | --- | --- |
| `--parallel --workers 16` | YES (4.1) | HANG at 317/621 nodes |
| `--parallel --workers 16` + `GC=0` | YES | HANG same point |
| `--parallel --workers 8` | YES | node phase progressing, not run to edges |
| `--parallel --workers 4` | YES | node phase OK, HANG on `audit_events` (2414 nodes) |
| `--parallel --workers 2` | YES | nodes OK, HANG on 2nd edge file |
| `--parallel=false` (serial) | — | WORKS cleanly |
| `--parallel --workers 16` post-revert | NO | progressing at Phase-2.4 speed (slow retries but no hang) |

## Root cause: QUIC pool stream multiplexing

From `/home/benji/go/pkg/mod/geodedb.com/geode@v0.1.19/quic_pool.go`:

```go
const DefaultQUICPoolSize = 4

// QUICPool manages a small pool of persistent QUIC connections.
// Each database/sql Conn gets a new QUIC stream on a pooled connection,
// amortizing the TLS handshake cost across many logical connections.
```

So a `*sql.Conn` is NOT a unique QUIC connection — it's a logical
connection multiplexed onto one of 4 underlying QUIC conns via
streams.  Pinning 16 sql.Conns keeps them alive long-term on 4
QUIC conns, accumulating 4 active streams each.

Goroutine dump from the w=16 hang (saved as
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
```

Every stuck worker is waiting for a `BeginTx` response that
never arrives.  Server remains alive (fresh conns work fine) —
but BeginTx on existing multiplexed streams is silently dropped.

## Server-side stream handling (for follow-up investigation)

The server's stream dispatch (in
`src/server/quic_connection_handler.zig:1488`
`streamAcceptorLoop`) spawns a new OS thread per accepted
stream via `stream_pool.submit`.  Per-conn limit:
`max_total_streams_per_connection = 65` (from
`src/server/active_stream_registry.zig:7`), global throttle
`default_max_global_stream_threads = 256`.  These are not
exceeded by our workload (~40 streams per tx × ~4 txs in flight
per QUIC conn).

Candidate root causes, untested:

1. **Stream-dispatch race**: `streamAcceptorLoop` uses
   `conn.tryAcceptStream` in a hot loop.  Under sustained stream
   submission (many tx.ExecContext calls on pinned conns), maybe
   some streams get accepted but the handler thread never sees
   the first message (FIN-before-data or similar).
2. **Orphan-txn reaper**: `orphan-txn rolled back on stream
   close` (server_state.zig:469) — could fire incorrectly on a
   pinned conn's active stream, poisoning subsequent BeginTx?
3. **Stream ID reuse** in the Zig QUIC library under load.
4. **Per-conn serialization** for writes — multiple response
   frames on the same QUIC conn serialize through a mutex;
   under 4 concurrent streams this could deadlock if any stream's
   handler blocks on adjacent stream I/O.

Investigation needed: strace/perf on the server while a hang
is in progress (required CAP_SYS_PTRACE — not available in
this session).

## Decision: REVERT msft-graph Phase 4.1

Committed as msft-graph `90a1227` — reverts `467021f`.

msft-graph now runs the Phase 4.0 primitives
(`batchExecTxOnConn`, `ConnMaxIdleTime=10min`) on top of the
pre-Phase-4.1 pool-based per-chunk acquire pattern.  This is
the Phase 2.4 baseline which is known to complete (slowly,
with retries).

## Server-side changes retained

Geode commits `24db46c5` (default `group_commit` ON +
`build.zig` thread_pool dep fix) and `a86b634b` (PHASE4-STATUS
doc) remain — they're not implicated in the stream-multiplex
hang and eliminate the 40001 cascade path independently.

## Artifacts

Under `phase4.1-validation/`:

- `w16-hang.log` — 317/621 hang on users.jsonl.
- `w16-hang-with-goroutine-dump.log` — SIGQUIT dump showing 8
  workers stuck in `BeginTx`.
- `w8-node-phase.log` — workers=8 progressing.
- `w4-hang.log` — workers=4 hang on audit_events (2414 nodes).
- `w2-edge-hang.log` — workers=2 hang on 2nd edge file.
- `serial-works.log` — `--parallel=false` working.
- `revert-post-phase4.1.log` — post-revert w=16 restored to
  Phase-2.4 behavior (slow retries, forward progress, no hang).

## Next steps

Task #31 (open): server-side investigation of QUIC stream
multiplex hang.  The fix is deep — probably days of work in
`src/server/quic_connection_handler.zig` +
`src/transport/quic.zig` + possibly the Zig QUIC library.

Without the server-side fix, the ≤ 60 s target is
unreachable — msft-graph is capped at the Phase 2.4 baseline
(~40 min for a good run, up to 2 h 5 m for a bad one) until
the QUIC multiplex hang is fixed.

## Commits

- geode `24db46c5` — `group_commit` default ON + build.zig.
- geode `a86b634b` — Phase 4.1 status.
- geode `7b3edf2b` — Phase 4.1 validation v1 (initial findings).
- geode `<THIS>` — Phase 4.1 validation v2 + revert notice.
- msft-graph `467021f` — Phase 4.1 (reverted).
- msft-graph `90a1227` — **revert Phase 4.1**.
