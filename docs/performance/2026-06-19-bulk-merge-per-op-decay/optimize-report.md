# bench-optimize report — bulk-MERGE per-op throughput decay

Date: 2026-06-19. Target: geode deferred-WAL bulk-MERGE ingest throughput decay at scale.

## Problem

During the 13M-taxon `divelife` ingest, per-op throughput decayed with graph size:
~940 ops/s @0.8M nodes → ~237 ops/s @4.2M. Suspected (wrongly) to be buffer-pool
disk-bound page probes.

## Audit (profile of the live decaying server, ~4M nodes, 12,391 samples)

`perf record` on the running server. Top self-time:

- **54.85% `NodePropertyExactIndex.add`** ← `addIndexedNodeProperty` ← `bulkInsertNode...`
- 9.84% + 8.37% CRC (WAL serialize)
- ~2% buffer pool

Root cause: `NodePropertyExactIndex.add` (`graph_storage_adapter.zig`) linear-scans
the posting list on every insert to de-dup the node_id (`for (items) |existing| if (existing==node_id) return;`).
For a low-selectivity indexed key — here the composite-MERGE key component
`source='col'` shared by all 5.37M col nodes — the posting list grows to N, so the
scan is **O(N) per insert → O(N²) total**. That is the decay. NOT the buffer pool.

## Hypothesis (h1, accepted)

The bulk-INSERT path reserves a fresh node_id that has never been indexed, so the
de-dup scan is provably redundant there. Skip it on the fresh-insert path; keep it
on update/re-index paths.

Change: `NodePropertyExactIndex.addEx(assume_new)` + `addIndexedNodePropertyEx`;
`assume_new=true` from `bulkInsertNodeWithReservedIdForTenant` and
`addNodePropertiesForLabels` (load-rebuild + addNodeLabel). Update paths
(`setNodeProperty*`, `removeNodeProperty`) keep `assume_new=false`.
Geode-side only; no graph-storage change. Commit `401f0fe5`.

## A/B (col ingest, low-selectivity `source` key)

| metric | before | after (h1) |
|---|---|---|
| `NodePropertyExactIndex.add` (profile) | 54.85% | gone from top |
| throughput @ ~948K nodes | ~940 ops/s (16 workers, idle box) | **~3,400–4,600 ops/s (8 workers, box contended by the 13M run)** |
| rate trend 30K→948K | decaying | ~flat |

≥3.6× even handicapped (half the workers, contended box). The O(N²) decay is eliminated.

Correctness: regression test (`graph_storage_adapter.zig` — complete low-sel posting
via `assume_new=true`; de-dup preserved on `assume_new=false`); `test-graph-store`,
`test-simple-merge-fastpath`, `test-gap0900-lean-index`, `test-gap0900-compact-node-store`,
`test-gap0900-reopen-remerge-dup`, `test-merge-prop-index-concurrent` green.

## Remaining lever (not implemented — next opportunity)

After h1 the profile top is WAL serialization: `WriteAheadLog.append` 26% +
`WalRecord.serializeInto` 25% + `memset` 23% (block-aligned record writes →
`writev`). This is **O(1) per op — it does NOT decay with graph size**, so it does
not reverse the decay fix; it caps absolute throughput. Reducing it means WAL
write-buffering/record-batching in graph-storage (the engine WAL), a larger,
durability-sensitive change requiring a graph-storage release + pin bump. The
`serializeInto` path itself is already allocation/zero-free (no cheap memset win);
the memset is in the external WAL lib's block padding. Deferred for a separate session.
