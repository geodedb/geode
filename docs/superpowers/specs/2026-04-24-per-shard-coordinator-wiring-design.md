# Per-Shard Coordinator Wiring — Design Spec

> Status: **draft** · Date: 2026-04-24 · Item 2 of the "dramatic-ingest-perf" pair (depends on the sharded-engine design living in `gitlab.com/devnw/zig/graph-storage` branch `perf/sharded-engine`, file `docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md`)

## Goal

Land **≤ 60 s wall-clock** on `msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000` (44,558 statements) by rewiring geode's per-graph group-commit coordinator onto the `ShardedGraphEngine` from Item 1. Three specific wins:

1. Eliminate `ManagedGraph.string_indexes_mutex` (the Phase 2 Task 6 3–4× regression cause) by making the auxiliary string indexes **per-shard** rather than per-`ManagedGraph`.
2. Eliminate the MVCC `error.SerializationFailure → 40001` cascade (the Phase 2.4 residual) by routing ops that touch the same resource to the same shard thread — deterministically removing concurrent writes to shared MVCC-tracked keys.
3. Decouple WAL `fsync` from op apply via a per-shard `WalFlusher` thread (from `2026-04-24-graph-sharding-and-wal-group-commit.md` Phase 3, activated here).

## Phase 2 triage — grounded root cause

I re-read `docs/performance/2026-04-24-sharding/phase2-run.log`, `phase2-result.md`, and `PHASE2-SUMMARY.md`. Two distinct failure modes, only one of which was previously understood:

### Failure mode A (understood, per `phase2-result.md`): `string_indexes_mutex` scope

Phase 2 Task 5 (`b12d43ad`) added `ManagedGraph.string_indexes_mutex` to protect the outer `label_index` / `edge_type_index` / `graphs` StringHashMaps during concurrent writers. Task 6 (`210de668`) wired the N-way `ShardedCoordinator`. The bug: the mutex is acquired at the top of `createNodeWithReservedIdAndGraph` / `createEdgeWithGraph` / `bulkMergeNodeWithReservedId` and held across the **entire** call — adapter vtable writes, IdMap, posting-list updates, not just the StringHashMap ops. 16 shard threads serialise through one mutex → **3–4× slower than single-coordinator baseline** (phase2-result.md lines 25–30: `edges_audited` 58s → ~4m12s).

### Failure mode B (new finding, from this spec's triage): MVCC write-write conflict cascade

PHASE2-SUMMARY noted the Phase 2.4 residual `40001` cascade on `edges_member_of` had no matching `"Write lock"` `log.warn` in the server log. I traced the 40001 emission sites in the current tree:

- **Explicit lock-timeout emission**: 4 sites in `src/server/quic_connection_handler.zig` (lines 344, 631, 824, 3213). All guarded by `err == error.Deadline` and preceded by `log.warn("Write lock acquisition timed out", …)`. **None of these fired** in Phase 2.4 — server log is clean of those warnings.
- **MVCC / transactions path**: `src/transactions/manager.zig:209` throws `error.SerializationFailure` from `hasWriteWriteConflicts` during commit; `:402,413` from `detectPhantoms`. `src/server/txn/mvcc.zig:485,514` throws it from validation. The `conflictToError` helper at `src/server/txn/mvcc.zig:667` composes a `DiagnosticInfo{ .status_class = "40", .status_subclass = "001" }` that proto-serialises as sqlstate `40001` — **no `log.warn` on this path**.

The cascade pattern matches: `edges_located_at` and 10 other edge files completed cleanly (low hub-node collision → low write-write conflict), `edges_member_of` cascaded (2119 edges concentrate on group nodes → high write-write conflict). Phase 2.4's writer-preferred-lock fix doesn't touch this path.

### Why sharded routing fixes both

Under the Item 1 `ShardedGraphEngine` with deterministic shard routing:

- **Same source node** always goes to the same shard thread. `createNode(v)` and `createEdge(v, …)` run on the single thread that owns shard `shard_of(v.id)`. No concurrent writers touch `v`'s MVCC-tracked resources → no write-write conflicts → no `SerializationFailure` cascade.
- **Different source nodes in different shards** run on different threads. Each thread owns its shard's engine + per-shard `label_index` / `edge_type_index` / `string_indexes` maps. No cross-shard mutex.
- **`edges_member_of` hub-node writes** all route to the same shard thread (hub node has one id → one shard). That thread processes them serially — no conflict, but also no cross-thread coordination overhead.

The combination of (A) per-shard auxiliary state and (B) deterministic shard routing **removes both Phase 2 failure modes structurally**, not by patching.

## Non-goals

- **Not the lock-free `merge_prop_index` snapshot.** That's the parallel `2026-04-24-lock-free-merge-prop-index-snapshot.md` plan, landing independently on `main`. This spec assumes it's landed (or not; design is correct either way — the snapshot just makes it faster).
- **Not the msft-graph client-side per-file QUIC reconnect fix.** That's Phase 4 of the graph-sharding plan, lives in `/home/benji/src/devnw/go/msft/cmd/msft-graph/`. Independent; complements this spec.
- **Not a new coordinator design.** The existing `ShardedCoordinator` (commit `210de668`, reverted at `19beb0b4`) is structurally correct; we re-enable it with the fixes below.
- **Not changing the QUIC/proto error mapping.** 40001 → serial-fallback is a client contract; we eliminate the *cause*, not the mapping.

## Architecture

### Re-enable the `ShardedCoordinator`

The `ShardedCoordinator` from commit `210de668` is kept in git history but unused. We:

1. Restore it to `src/storage/group_commit.zig` (the revert removed it from active build).
2. Wire it as the default coordinator for all `ManagedGraph` instances.
3. Route `submit(op)` by `shardIndex(op.primary_node_id)`.

### Per-shard `ManagedGraph` auxiliary state (removes `string_indexes_mutex`)

In `src/storage/graph_storage_adapter.zig`, the maps currently under `string_indexes_mutex`:

- `label_index: std.StringHashMap(std.ArrayList(u64))` — label → node-id posting list.
- `edge_type_index: std.StringHashMap(std.ArrayList(u64))` — edge-type → edge-id posting list.
- `graphs: std.StringHashMap(*ManagedGraph)` — this is global, not per-graph; stays under its existing `graph_handles_mutex`.

Transform to:

```zig
// src/storage/graph_storage_adapter.zig
pub const ManagedGraph = struct {
    // REMOVED: string_indexes_mutex: std.Thread.Mutex
    // REMOVED: label_index: std.StringHashMap(std.ArrayList(u64))
    // REMOVED: edge_type_index: std.StringHashMap(std.ArrayList(u64))

    // NEW: one per shard, owned by that shard's coordinator worker thread.
    shard_label_indexes: [SHARD_COUNT]std.StringHashMap(std.ArrayList(u64)),
    shard_edge_type_indexes: [SHARD_COUNT]std.StringHashMap(std.ArrayList(u64)),

    // … rest unchanged …
};
```

**Read paths** (label scans, edge-type scans): fan-out across shards and merge posting lists. Same pattern as `ShardedGraphEngine.scanNodes`.

**Write paths**: the shard coordinator worker thread mutates only its own shard's maps — no mutex needed, since the thread owns the shard.

### Per-shard rwlocks (Phase 2 Task 4, `b061a238`, kept)

The per-shard `std.Io.RwLock` on `ManagedGraph` from Phase 2 Task 4 is kept. Each shard coordinator thread takes its own shard's rwlock EXCLUSIVE for its batch; readers (match/expand operations) take SHARED on the shard they're reading. No cross-shard lock.

### Cross-shard edge creation (delegated to `ShardedGraphEngine`)

When an op creates an edge whose endpoints are in different shards, the coordinator submits it to the source shard thread. That thread invokes `ShardedGraphEngine.createEdge` which handles the 2PC protocol internally. The coordinator doesn't need to know about 2PC — the engine facade abstracts it.

### Per-shard `WalFlusher`

Activated from `2026-04-24-graph-sharding-and-wal-group-commit.md` Phase 3. One flusher thread per shard. The coordinator submits ops with a `done` condvar; the flusher batches `sync` calls across ops in the same shard (default 500 µs batch window). Caller blocks on `done` only. No cross-shard flusher coordination.

### MVCC-path changes

The residual 40001 cascade was write-write-conflict-on-commit. With deterministic shard routing, workers never commit concurrent writes on the same resource. But as a belt-and-braces measure, this spec mandates one additional check:

- **Assert-level invariant** in `transactions/manager.zig:hasWriteWriteConflicts`: panic if a conflict is detected while the coordinator is routing deterministically. This catches routing bugs at debug-build time. Release builds keep the existing 40001 path (defense in depth).

## Request-level flow, post-change

```
msft-graph worker N (1..16)
    → QUIC conn → stream
    → quic_connection_handler.zig dispatch
    → ManagedGraph.submit(op)           // no lock; atomic shard route
    → ShardedCoordinator.route(op)      // op enqueued on shard worker
    → shard worker thread for shard s:
          → take shard s's rwlock EXCLUSIVE
          → batch N ops (default 256-op cap)
          → for each op: ShardedGraphEngine.createNode/createEdge
                → route to shard s's GraphEngine (intra-shard, no 2PC)
                OR → 2PC if cross-shard edge
          → update shard s's label_index / edge_type_index (no mutex; thread owns)
          → commit WAL (appendRecord, no sync)
          → enqueue all op LSNs on shard s's WalFlusher
          → release shard s's rwlock
          → for each op in batch: wait on op.done condvar
          → WalFlusher batched fsync → signals done
          → op result returned to QUIC handler → sent to client
```

Zero mutex contention across shards. Each shard's wall-clock is determined by that shard's workload; the 16-way fan-in sees 16-way concurrent progress.

## Measurable success

1. `msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000` completes in **≤ 60 s** wall-clock. (Target per `2026-04-24-graph-sharding-and-wal-group-commit.md:5`; we commit to this number as the Item 2 exit criterion.)
2. Server log contains **zero** `"Write lock acquisition timed out"` warnings during the ingest.
3. `strace -e fsync -c` on the server process shows `fsync` call count drops to ≤ 1 per WalFlusher batch window per shard, not one per op.
4. `edges_member_of` completes without triggering `dispatchSeed` serial fallback.
5. Regression suite (`test-r6-parallel-ingest`, `test-graph-write-lock-cancelable`, `test-undo-log-isolation`, `test-orphan-txn-cleanup`, `test-match-read-serial`, `test-handler-lock-hold-scope`) passes unchanged.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Shard imbalance: one hub-heavy shard becomes the tail-latency driver | `splitmix64` has good avalanche. Add shard-depth histogram to metrics; alert if max/min > 4. Fallback: bump `N` from 16 to 32 (requires data-dir nuke per project policy). |
| Per-shard indexes balloon memory | Each shard holds ~1/N of total postings. Net memory ≈ same; the difference is allocator churn. Pre-size each shard's maps at init (total_estimated / N). |
| MVCC code still runs, producing SerializationFailure on a routing-bug | Debug-build panic mentioned above. Also: add a regression test that deliberately produces a cross-shard write-write conflict (two workers, same node, same shard-routing) and asserts it panics or serialises correctly. |
| Cross-shard edge 2PC bugs under crash | Covered by Item 1 spec's `test_cross_shard_recovery.zig`. This spec depends on those tests passing. |
| Phase 2.4's writer-preferred lock work becomes moot | That's the point — the workaround is no longer needed. Code can be removed once Item 2 is measured and accepted. Documented as a follow-up cleanup ticket. |

## Implementation plan pointer

The concrete task breakdown is produced by `superpowers:writing-plans` from this spec and lands at `docs/superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md`. That plan assumes Item 1's `ShardedGraphEngine` is landed (it updates the `graph_storage` dep to the new sharded version first).

## Dependencies and sequencing

- **Hard dependency on Item 1** (sharded-engine design in `gitlab.com/devnw/zig/graph-storage` branch `perf/sharded-engine`): this spec's core premise is that each shard's engine is single-threaded-correct.
- **Soft dependency on the RCU merge snapshot** (`2026-04-24-lock-free-merge-prop-index-snapshot.md`, already in flight on `main`): improves read-path perf for `lookupMergeCandidate` but isn't required for the 60s target.
- **Independent of** the msft-graph client-side pipelining (Phase 4 of the sharding plan); each can land on its own.

## Open questions (to resolve during plan-writing)

1. **How `ShardedCoordinator` balances batch sizes across shards of widely differing depths.** If shard 3 has 10k pending ops and shard 5 has 100, does the 256-op batch cap apply per-shard or per-graph? **Recommendation**: per-shard. Small shards commit quickly; large shards commit in natural 256-op batches. No rebalancing needed.
2. **`graphs` map on `ManagedGraph` — should it also shard?** The map is `graph_name → *ManagedGraph`, one entry per graph. Low-contention; keep global with existing `graph_handles_mutex`.
3. **Fallback to single-engine mode if `shard_count = 1`?** Tempting for test determinism, but adds a code path to maintain. **Recommendation**: no — always N=16 in production; tests can still verify correctness with N=16 (just not concurrency).
