# Phase 4 — client-side pinned-conn pipelining (2026-04-23)

## What shipped (working tree, not committed)

In `~/src/devnw/go/msft/cmd/msft-graph/`:

- **`batchExecTxOnConn`** (new primitive): runs a transaction on a
  caller-supplied `*sql.Conn` instead of acquiring one from the pool.
  Keeps the same rollback/stale-tx/ErrBadConn semantics as
  `batchExecTx`.
- **`batchExecOnConn`** (new retry variant): wraps
  `batchExecTxOnConn` in the same retry loop as `batchExec`, but
  operates on a pinned conn.  On stale-tx error the bad conn is
  closed (evicting from pool via ErrBadConn flag) and a fresh conn
  is acquired for the retry.  Returns whichever conn the caller
  should keep pinned going forward.
- **`pipelineExec` rewrite**: pre-acquires `maxWorkers` conns at
  start, multiplexes them through a channel for the goroutines,
  releases all at pipelineExec exit.  No per-chunk
  `pool.DB().Conn()` / `conn.Close()` cycling.
- **`connectGeodeWithWorkers`**: raised `ConnMaxIdleTime` from the
  geode driver's default 25 s to 10 min via
  `geode.WithConnMaxIdleTime(10*time.Minute)`.

## Result on validation ingest

First two files hit chunk failures simultaneously:
- 6 × `"batch begin tx: context deadline exceeded"`
- 2 × `"batch begin tx: sql: connection is already closed"`

msft-graph serial-fallbacked both files.  The ingest made
functional progress but regressed vs Phase 2.4 — every file paid
the 16-conn handshake storm cost at pipelineExec start.

## Root cause

Each call to `pipelineExec` pre-acquires 16 FRESH conns via
`pool.DB().Conn(ctx)`.  When the pool has fewer than 16 idle conns
(normal state — starts empty, drained by `drainIdle(pool)` in
`dispatchSeed`'s fallback path), the acquire forces 16 concurrent
QUIC HELLO handshakes against the server.  Some queue, some hit
QUIC idle timeout before their first BeginTx fires → `sql:
connection is already closed` or timing out at context deadline.

The per-file handshake storm was exactly what Phase 4 set out to
eliminate — pinning within one pipelineExec call addresses
intra-file per-chunk churn but not inter-file churn, which is the
dominant cost for a 41-file seed.

## The correct design (Phase 4.1)

Pin conns at the **seed top-level**: acquire `workers` conns once
in `runSeed` before the file loop, pass the conn channel into
`dispatchSeed → pipelineExec`.  Conns stay warm across every file
in the seed run.  pipelineExec becomes a pure consumer that
multiplexes existing conns, not a conn producer.

Additional tuning needed:
- Remove `drainIdle(pool)` from `dispatchSeed`'s fallback path —
  with seed-top-level pinning, conns aren't in the idle pool; they're
  held in the channel.  Force-draining does nothing helpful.
- Raise the geode client's QUIC idle timeout to survive inter-file
  gaps.  Current QUIC-level default times out waiting-to-BeginTx
  conns during the handshake storm even if they're in the pool.
- Add periodic keepalive on each pinned conn (e.g., a `SELECT 1`
  every 20 s) so inter-file gaps don't silently disconnect conns.

## Decision required

Three options for the working-tree changes:

**A. Commit the primitives only, revert pipelineExec rewrite**
   (recommended).  `batchExecTxOnConn` and `batchExecOnConn` are
   pure additions that are correct and reusable.  pipelineExec
   stays as it was — no regression, no partial win.  Phase 4.1
   rework has a clean starting point.

**B. Commit as-is + document as "incomplete Phase 4.0"**.
   pipelineExec pinning is present but introduces a new regression
   (per-file handshake storm triggering msft-graph serial fallback
   more often than pre-Phase-4).  Forward flag lets experienced
   users disable via `--parallel=false` if needed.  Phase 4.1 picks
   up where this left off.

**C. Defer entirely — roll back all working-tree changes**.  No
   Phase 4 code lands.  Future session starts from scratch with a
   cleaner design brief (seed-top-level conn management +
   QUIC keepalive + dispatchSeed drainIdle removal).

Recommended: **A**.

## Files changed (working tree)

- `~/src/devnw/go/msft/cmd/msft-graph/geodestore.go` —
  `WithConnMaxIdleTime(10*time.Minute)` in pool init.
- `~/src/devnw/go/msft/cmd/msft-graph/geodeutil.go` —
  `batchExecTxOnConn`, `batchExecOnConn`, `pipelineExec` rewrite.

## Files NOT changed

- `seed.go` `dispatchSeed` — untouched.  Its `drainIdle(pool)` on
  fallback remains.
