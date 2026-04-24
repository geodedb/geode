# Phase 2 graph-sharding + coordinator rework — session summary (2026-04-23)

## Progression

Eight distinct designs attempted, measured against msft-graph
`seed --input ~/eagleg-topology-data-16 --parallel --workers 16`:

| Phase | Commits | Design | Outcome |
| --- | --- | --- | --- |
| Phase 1 | 7ff6319d, a52248bf, ba21a7d6, f20152d9, 280aac93, 3103275b | `ShardedStore(K,V)` + sharded `GraphStore.nodes/.edges/adjacency` | Foundation; pure data-structure refactor |
| Move | graph-storage `2dadc13` + geode `0d7da6a2` | ShardedStore promoted to `graph_storage` v0.2.0 | Published as reusable primitive |
| Phase 2 Task 4 | `b061a238` | Per-shard rwlocks on `ManagedGraph` + `acquireShardWriteLock*` | Tests pass; unused by coordinator |
| Phase 2 Task 5 | `b12d43ad` | `*WithReservedId` shard-locked bulk-helper variants | Tests pass; primitives kept |
| Phase 2 Task 6 | `210de668` | 16-way `ShardedCoordinator` with per-shard workers | **3-4× regression vs morning — mutex scope bug** |
| Phase 2.1 | `19beb0b4` | Revert to thread-pool-hosted single-flusher (morning-baseline logic) | 40001 cascade on edges_audited after 2 files |
| Phase 2.2 | `85855ac5` | Flusher uses `acquireGraphWriteLock` (lockUncancelable, writer-preferred) | No 40001 from flusher; but client context-deadline failures; serial fallback |
| Phase 2.3 | `cc55ca40` | Coordinator-resolved edge endpoints (eliminates SHARED reader contention at hot path) | Still slow; eventually 40001 from general executor path |
| Phase 2.4 | `7109c0dd` | Writer-preferred `acquireGraphWriteLockCancelable` for ≥1s budgets | **Best result so far**: completed 11 files through `edges_located_at` (8259) cleanly; cascade eventually on `edges_member_of` (2119) |

## What works after Phase 2.4

Measured against msft-graph workload, from the Phase 2.4 run
(commit `7109c0dd`):

- **Node phase**: 9350 nodes in 11m49s. Zero errors. Per-file
  ~32s, dominated by msft-graph per-file QUIC reconnect.
- **Edge files 1-11**: completed cleanly including the
  previously-cascading `edges_located_at` (8259 rows in 3m33s).
  No 40001 on these files.
- **Edge file 12 (`edges_member_of`, 2119 rows)**: 40001 triggered
  → msft-graph serial-fallback.

Total edge phase to cascade: ~28 min, 21k+ edges applied. Compare
to morning-baseline R13 which cascaded earlier and total run was
2h5m.

## Residual problem

The 40001 on `edges_member_of` chunk=2 isn't coming from any
logged `log.warn("Write lock acquisition timed out", ...)` path in
the server — exhaustive grep of `/tmp/geode-phase2-4/server.log`
finds zero `Write lock` messages, while the msft-graph client
unambiguously received `40001: Write lock acquisition timed out`.

This means there's a 40001-emitting path I haven't identified —
likely an error-propagation path that converts some other error to
40001 elsewhere in the stack (proto mapping, session error handling,
or a stream-level timeout in transport).  Without identifying that
path, Phase 2.4's fix of the adapter's tryLock-spin is incomplete.

## The architectural constraints that remain

1. **graph-storage engine is single-threaded by charter**
   (`graph_storage/src/engine.zig:588-589` does non-atomic
   `next_node_id += 1`).  Writes MUST serialize.

2. **The msft-graph MATCH+CREATE edge hot path** (and the
   similar MERGE hot path at `executeBulkSimpleMerge`) need
   endpoint resolution.  Either:
   - Under SHARED read lock (contends with flusher's EXCLUSIVE)
   - Inside the coordinator (Phase 2.3 approach, works but serialises)
   - Lock-free via snapshot (requires data-structure rework)

3. **std.Io.RwLock writer-preference only activates via
   `lockUncancelable` or `lock`** — `tryLock` never marks writer
   pending (verified in `std/Io/RwLock.zig:28-40`).  Any
   deadline-aware acquire has to choose between:
   - Fail-fast tryLock (starves under reader pressure)
   - Block-forever lockUncancelable (loses deadline semantics)

4. **The msft-graph client serial-fallbacks on a SINGLE 40001 per
   file** (per `cmd/msft-graph/seed.go:117-136`'s `dispatchSeed`).
   Any transient 40001 during a file means the entire file falls
   back to serial mode — adding minutes of wall-clock per file.

## What Phase 2.4 actually won

Significant progress even without a clean sub-60s result:
- No more starvation on the per-graph rwlock under 16-way fan-in
  (the tryLock-spin bug is genuinely fixed for ≥1s budgets).
- First clean completion of `edges_located_at` (8259 rows) — a
  pre-Phase-2 trouble file — under concurrent workers.
- `ShardedStore` primitive published to `graph_storage` v0.2.0
  for future use by any consumer.
- Per-shard lock primitives + `*WithReservedId` helpers kept as
  Phase 2.2 primitives in `graph_storage_adapter.zig` for future
  fine-grained parallelism.

## Recommended next steps (not in this session)

1. **Identify the residual 40001 source.** grep-sweep of the
   transport + proto layers for error-mapping that converts
   `error.Timeout` or similar to `"40001"`.  Likely in
   `src/transport/` stream-level handling.

2. **Phase 4: client-side pipelining.** The dominant cost on the
   node phase (~32s per file × 25 files = 13 min) is the
   msft-graph per-file QUIC reconnect — fixable entirely
   client-side in `/home/benji/src/devnw/go/msft/cmd/msft-graph/`
   by replacing `drainIdle(pool)` + fresh conns with persistent
   per-worker `*sql.Conn` pinned across files.  Independent of
   the coordinator design; complements any server-side fix.

3. **Lock-free endpoint snapshot (deep fix).** Replace
   `store.merge_prop_index` StringHashMap with a RCU-style
   snapshot: writers atomically swap a new snapshot pointer,
   readers dereference the current snapshot without locking.
   This eliminates the reader/writer contention entirely and
   allows true N-way parallel endpoint resolution during batch
   apply.  Significant implementation effort (~days).

4. **Engine thread-safety (deep fix, upstream).** Make
   `graph_storage`'s engine handle concurrent writes via internal
   locks on `manifest`, `buffer_pool`, `wal`.  Enables actual
   sharded-writer parallelism.  Weeks of work in the graph-storage
   repo.

## Commit list (Phase 2 session)

```
cc55ca40 perf(storage): coordinator resolves edge endpoints under its own lock (Phase 2.3)
7109c0dd fix(storage): writer-preferred path for long-budget acquireGraphWriteLockCancelable (Phase 2.4)
85855ac5 fix(storage): flusher uses acquireGraphWriteLock (writer-preferred)
19beb0b4 fix(storage): thread-pool-hosted single-flusher coordinator (Phase 2.1)
efc2c2a7 docs(perf): Phase 2 ingest validation shows regression (Task 7)
210de668 feat(storage): N-way ShardedCoordinator (Phase 2, Task 6)
b12d43ad feat(storage): shard-locked bulk-helper variants (Phase 2, Task 5)
5c5ddf8c refactor(test): migrate test_shard_locks to thread-pool
b061a238 feat(storage): per-shard rwlocks on ManagedGraph (Phase 2, Task 4)
0d7da6a2 refactor(storage): move ShardedStore to graph_storage v0.2.0 library
3103275b chore(storage): address Phase 1 final-review polish
280aac93 fix(storage): use catch @panic in clearNodes adjacency re-init (Phase 1, Task 3 follow-up)
f20152d9 refactor(storage): shard outgoing_edges / incoming_edges (Phase 1, Task 3)
ba21a7d6 refactor(storage): shard GraphStore.nodes and GraphStore.edges (Phase 1, Task 2)
a52248bf feat(storage): extend ShardedStore API for real-caller needs
7ff6319d feat(storage): add ShardedStore type (Phase 1, Task 1)
```

Plus `2dadc13` in graph-storage publishing v0.2.0.
