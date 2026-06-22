# Bug: sustained single-connection ingest wedges deterministically (~26K ops) — periodic checkpoint deadlocks on `mg.rwlock`

**Status:** **FIXED** (2026-06-21) on `geode v0.7.1-81-g7e6b461d`. Root-caused
with a live `gdb` capture of the wedged server; fix verified with the
`geode-client-go` reproduction `TestConn_SustainedSingleConnIngest_NoWedge`
passing 30K ops twice (was wedging at op ~26.6K).

## Symptom

A sustained sequential ingest on a SINGLE QUIC connection (one stream,
`MaxOpenConns=1`) wedges deterministically after ~4K–30K autocommit MERGE ops
(observed at coord op ~26,647 on a fresh server). The client goroutine parks in
`ReceiveProto` waiting for a response that never comes; the per-batch context
deadline then fires. Server-side:

- `coord_apply_ops_total` flatlines (e.g. frozen at `total=26647`).
- `msgs_delivered+=0` thereafter; `proto_idle_ms` climbs without bound.
- The connection's stream stays registered (`active_streams=1`) and the server
  spins at ~95–150% CPU.

Reproduces WITHOUT `GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING`, so it is NOT a
multiplex/acceptor bug. It requires `GEODE_WAL_SYNC=deferred` (the bulk-seed
mode), which enables the GAP-0900 load-driven inline checkpoint.

## Root cause — a reader/writer deadlock on the per-graph `mg.rwlock`

Captured live via `gdb -p <pid> -ex 'thread apply all bt'` on the wedged server:

- **Checkpoint thread** (`persistenceLoop → walCheckpointHook →
  GraphStore.saveToFileEx → StorageAdapter.checkpointAllEx`,
  `graph_storage_adapter.zig:4372`): parked in `Io.Semaphore.waitUncancelable`
  inside `RwLock.lockUncancelable` — i.e. it registered as a pending WRITER on
  `mg.rwlock`, set `is_writing`, took the RwLock's internal mutex, and is
  waiting on the counting semaphore for the last reader to `unlockShared`.
- **Shard-apply worker** (`group_commit.shardLoop → applyShardBatch →
  bulkMergeNodeWithReservedIdForTenant`, `graph_storage_adapter.zig:2485`):
  parked in `RwLock.lockSharedUncancelable → Mutex.lockUncancelable` — a NEW
  reader that, because a writer is pending, must take the RwLock's internal
  mutex (held by the wedged writer) to register. It blocks forever.
- Live RwLock state word = `0x100000001` → `reader_count = 1`, `is_writing = 1`,
  but **zero threads on any stack are inside the shared region** — the phantom
  reader count is the std `Io.RwLock` lost-wakeup: the writer's
  `semaphore.waitUncancelable` was never `post()`ed by the last
  `unlockShared`, so it sleeps permanently while holding the internal mutex.

Consequence chain: checkpoint writer wedged → holds RwLock internal mutex →
every subsequent bulk-MERGE shard apply blocks taking `mg.rwlock` SHARED → the
blocked apply never sets its `ApplyResult.done` → the cooperative first-stream
submitter parks in `ShardedCoordinator.awaitOp` → the connection's response is
never written → the client wedges in `ReceiveProto`.

This is the SAME std `Io.RwLock` lost-wakeup that was already diagnosed and
worked around for the two OTHER exclusive acquirers of `mg.rwlock`:
`acquireGraphWriteLockCancelable` (graph_storage_adapter.zig ~5496) and
`acquireWholeGraphExclusive` (~6310), both of which were converted to a bounded
`tryLock` re-probe spin. **`checkpointAllEx` was missed** and still used the raw
hang-prone `mg.rwlock.lockUncancelable(io)`.

## Fix

`StorageAdapter.checkpointAllEx` (graph_storage_adapter.zig:4372) no longer
parks on the RwLock's internal semaphore. It re-probes via `mg.rwlock.tryLock`
(which reads `rl.state` directly and touches no semaphore, so it is immune to
the lost wakeup), mirroring the two existing exclusive acquirers:

- Periodic LIGHT checkpoint: bounded ~5s `tryLock` spin; on exhaustion it SKIPS
  this graph for this cycle (the GAP-0900 load-driven trigger re-fires next
  batch) — never hangs, never holds the lock.
- FULL checkpoint (clean shutdown / explicit): unbounded `tryLock` spin so
  durability is never sacrificed (matches `acquireWholeGraphExclusive`).

## Verification

`geode-client-go` `TestConn_SustainedSingleConnIngest_NoWedge` (300 batches ×
100 MERGE = 30K ops, single conn, 20s per-batch deadline):

- Before: FAIL — `exec op 26643: context deadline exceeded` (wedged in
  `ReceiveProto`).
- After: PASS twice — `completed 30000 ops over a single connection ... with no
  wedge`; server reached `coord total=30003`, `0` checkpoint skips, `0` stalls,
  `0` panics.
