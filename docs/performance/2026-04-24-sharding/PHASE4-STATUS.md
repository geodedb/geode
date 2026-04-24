# Phase 4 — client-side pinned-conn pipelining (2026-04-23 / 24)

## Current state: Phase 4.1 landed (unvalidated)

### Phase 4.0 (committed as `5d8d7916` / msft-graph `b0e9d0b`)

- `batchExecTxOnConn` primitive: runs a transaction on a
  caller-supplied `*sql.Conn` with the same rollback / stale-tx
  / ErrBadConn semantics as `batchExecTx`.
- `ConnMaxIdleTime = 10 min` (via `geode.WithConnMaxIdleTime`).
- Pipelining rewrite reverted after validation showed regression:
  every file paid a 16-conn HELLO handshake storm at pipelineExec
  start because the pool's idle-conn cache was drained between
  files.

### Phase 4.1 (committed as msft-graph `467021f`)

Hoists conn pinning to the **seed top-level**:

- **`pinnedConns` type** (new): fixed-size bounded pool of
  `*sql.Conn` held for the entire seed run.  Workers Acquire /
  Release via a channel; a background keepalive goroutine sends
  `RETURN 1` on idle conns every 20 s so the QUIC session stays
  alive across inter-file gaps.  `Replace()` swaps bad conns out
  for fresh ones on ErrBadConn.
- **`batchExecPinned`** (new): retry-loop variant of `batchExec`
  that runs on a pinned conn; swaps via `pinnedConns.Replace` on
  stale-tx.
- **`pipelineExec`** (sig change): takes `*pinnedConns` instead of
  `*geode.Pool`.  Pinned channel capacity caps in-flight
  parallelism — no separate semaphore needed.
- **`pipelineExecWithPool`** (new): convenience wrapper acquiring
  a short-lived pinned set.  Used by `geodeWriter.flush` /
  `updateSnapshot` which are infrequent enough to absorb the
  per-call 16-conn acquire.
- **`runSeed`**: acquires `pinnedConns` ONCE before the file
  loop (parallel mode only), releases on exit.  Conns stay warm
  across every file.
- **`dispatchSeed`**: accepts `*pinnedConns`; `drainIdle(pool)`
  removed from the serial-fallback path (it was a no-op on the
  pinned set).
- **`drainIdle`**: removed — no longer called.

## Expected impact

Against the 41-file msft-graph validation seed:

- **Node phase**: eliminates the per-file QUIC HELLO of ~30 s × 25
  files ≈ 13 min of pure reconnect.  Target: node phase < 2 min.
- **Edge phase**: pre-warm conns avoid the 16-way handshake storm
  observed on the two densest edge files that were serial-falling
  back post-Phase-2.4.

## Server-side complement (committed as `24db46c5`)

`group_commit.isEnabled()` now defaults to **true** unless
`GEODE_GROUP_COMMIT` is set to 0/false/no/off.  The coordinator
is the architectural default post-Phase 2.3; the single-phase
`executeBulkSimpleCreate` / `executeBulkMatchCreateEdge` /
`executeBulkSimpleMerge` fallbacks only exist for forensic
comparison.  Those fallbacks are the only code paths that can
emit `40001: Write lock acquisition timed out` on the msft-graph
workload; routing all writes through the coordinator by default
eliminates the class entirely.

## Validation status

**Unvalidated.**  The next msft-graph seed run will confirm
whether Phase 4.1 + default group_commit hits the ≤ 60 s target.

Open follow-ups for a bad-result scenario:

1. **Residual 40001 source** — if the coordinator path still
   produces 40001 in the log, investigate whether slog.warn is
   getting lost (known observability gap: slog output isn't
   reaching the captured stderr; see grep of
   `/tmp/geode-phase2-4/server.log` finding zero `time=` lines).
2. **Lock-free endpoint snapshot** — replace
   `store.merge_prop_index` StringHashMap with an RCU-style
   pointer-swap snapshot; readers dereference current snapshot
   without locking.  Deep fix (~days), eliminates residual
   reader/writer contention if any remains.
3. **Engine thread-safety (upstream)** — make `graph_storage`'s
   engine handle concurrent writes via internal locks on
   `manifest`, `buffer_pool`, `wal`.  Enables actual
   sharded-writer parallelism.  Weeks of work in the
   graph-storage repo.

## Files changed

**geode**:

- `src/storage/group_commit.zig` — default `isEnabled()` to true.
- `build.zig` — add `thread_pool` dep to `graph_store_mod`,
  `graph_store_unit_tests`, `merge_bench_gs_mod` (fixes
  pre-existing compile error in graph_store-rooted test modules).

**msft-graph**:

- `cmd/msft-graph/geodeutil.go` — `pinnedConns` type,
  `batchExecPinned`, `pipelineExec` rewrite,
  `pipelineExecWithPool`.
- `cmd/msft-graph/seed.go` — `runSeed` seed-top-level pinning,
  `dispatchSeed` signature, `drainIdle` removal.
- `cmd/msft-graph/geodestore.go` — switch flush callers to
  `pipelineExecWithPool`.
