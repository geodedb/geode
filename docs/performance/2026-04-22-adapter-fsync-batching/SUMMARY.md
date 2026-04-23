# msft-graph 16-worker ingest — perf optimization session 2026-04-22 → 2026-04-23

## Problem statement (from user)

> The performance of geode is unusably slow and consistently fails to process
> requests as can be seen by the following logs from the msft-topology system.
>
>     msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000
>
> … cascade of `batch get conn: failed to receive HELLO response` and
> `batch begin tx: geode: transport read_length to 127.0.0.1:3141: NO_ERROR (remote)`
> errors, ingest stuck at 0.4 statements / second, never completes.

## Methodology

Ten-round test-driven bench-optimize loop against
`benchmarks/bench_executor_mutation.zig` (the existing in-process mutation-
latency bench) + integration validation against the user's exact
`msft-graph seed` command.  Every round preserves the R1–R5 parallel-ingest
regression test contracts (`test-r6-parallel-ingest`,
`test-graph-write-lock-cancelable`, `test-undo-log-isolation`,
`test-orphan-txn-cleanup`, `test-match-read-serial`,
`test-handler-lock-hold-scope`).

All rounds shipped behind evidence: `zig build -Doptimize=ReleaseFast
bench-query-executor-mutation -- --output after-<round>.json`, checked
against the baseline JSON aggregate retained in this directory.  The
full `zig build test` suite passes at every checkpoint.

## Bench deltas (vs R5 baseline, ReleaseFast)

|  scenario                    | baseline |   R7    |   R8    |   R11   |   R13   | total    |
|  --------------------------- | -------: | ------: | ------: | ------: | ------: | -------: |
|  create_single/mutation      |  50.79ms |  25.68ms |   5.52ms |   5.69ms |   6.81ms |  **7.5×**  |
|  create_batch_100/mutation   | 5186.21ms | 2628.12ms | 561.80ms | 653.98ms | 684.95ms |  **7.6×**  |
|  merge_single/mutation       |  40.81ms |  20.53ms |   5.48ms |   5.42ms |   5.49ms |  **7.4×**  |
|  set_property/mutation       |  10.23ms |   5.22ms |   5.22ms |   5.32ms |   5.31ms |  **1.9×**  |
|  create_edge/mutation        |  10.44ms |  10.51ms |  10.46ms |  10.58ms |  10.64ms |  **1.0×** (already 1 fsync) |
|  delete_single/mutation      |   5.23ms |   5.22ms |   5.24ms |   5.29ms |   5.29ms |  **1.0×** (already 1 fsync) |

Bench can't exercise the R9 / R10 / R12 / R13 paths (they all require a
live Geode `BEGIN TX`); their wins only surface on the end-to-end ingest.

## Integration (msft-graph seed --workers=16 --chunk-size=1000)

|  phase                              | R5 baseline        |   R8       |    R11     |    R13     |
|  ---------------------------------- | ------------------ | ---------: | ---------: | ---------: |
|  users.jsonl (621)                  | never completed    |    140 s   |     32 s   |     32 s   |
|  devices.jsonl (73)                 | never completed    |     62 s   |     31 s   |     31 s   |
|  groups.jsonl (328)                 | never completed    |     96 s   |     31 s   |     31 s   |
|  drive_item.jsonl (1345)            | never completed    |     61 s   |     31 s   |     31 s   |
|  audit_event.jsonl (2414)           | never completed    |     60 s   |     58 s   |     84 s   |
|  service_principal.jsonl (1075)     | never completed    |     60 s   |     55 s   |     57 s   |
|  ...                                |                    |            |            |            |
|  chunk failures on nodes phase      | cascaded every chunk | 0        | 0          | 0          |
|  chunk failures on large edge file  | (never reached)    | N/A       | 6+        | 2–3        |
|  full ingest completion             | **never**          | partial, cascades | completes, serial fallback on big edge files | completes, serial fallback on big edge files |

31 s/file on small node files is a **client-side** floor (msft-graph's
per-file connection-pool warmup + chunk pause) — confirmed by looking
at server CPU/thread state during those windows (both near idle).  No
further server-side work will move this number.

## Ten commits, smallest → biggest win

| round | commit      | change                                                                                                                  | primary win |
| ----- | ----------- | ----------------------------------------------------------------------------------------------------------------------- | ----------- |
|  R6   | `1713eff7`  | Remove exclusive GLOBAL `g_store_rwlock` acquire on per-graph mutation path.  Per-graph `mg.rwlock` already guarantees per-graph exclusion. Also widens `acquireGraphWriteLockCancelable` backoff 100 µs → 1-20 ms and caps per-connection stream pool at 4. | Removes cross-graph serialisation; eliminates the 16-way lock-storm that showed 700-800 % CPU with no client progress. |
|  R7   | `3be064d4`  | Wrap every adapter mutation (`createNode`, `setNodeProperty`, `setNodePropertiesBatch`, `removeNodeProperty`, `deleteNode`, `createNodesBatch`) in an explicit `beginTxn` / `*Txn` / `commitTxn` scope.  Each adapter call now does ONE WAL fsync instead of one per sub-op. | **-49 %** on create_single / merge_single / create_batch_100 / set_property in bench. |
|  R7f  | `604fa82e`  | Raise default `GEODE_GRAPH_WRITE_LOCK_TIMEOUT_MS` 30 s → 120 s.                                                        | Prevents cascade failure when a legitimate 16-way contended batch approaches 30 s. |
|  R8   | `112d0509`  | Per-STATEMENT engine txn.  `executeCreate` / `executeMerge` open a `StatementTxn` at entry via thread-local; every adapter sub-op on the same graph joins it; one fsync per whole GQL statement. | **-78 %** vs R7 on create_single (25.7 → 5.5 ms). Total vs R5 baseline: **9.2×**. |
|  R9   | `bc64791e`  | Session-scoped engine txn.  Geode `BEGIN TX` → `COMMIT` now opens a session engine txn; all R8 per-statement hooks notice and skip their own txn open.  Whole Geode batch commits with ONE fsync. | 38-statement `users.jsonl` batch: 38+ fsyncs → 1 fsync. |
|  R10  | `bc64791e`  | Edge and label mutations (`createEdge`, `deleteEdge`, `addNodeLabel`, `removeNodeLabel`) also join the active session/statement txn when present.                                              | Covers edge-heavy workloads where R8 only touched node mutations. |
|  R11  | `e9b349d6`  | Open R9 session engine txn LAZILY on the first mutation, pinned to `target_graph` — not eagerly in the `.begin` handler on `state.current_graph` (which is null under DSN graph-binding and was opening orphan txns on `graph=default`). | Fixes the `orphan-txn rolled back on stream close (graph=default)` log-spam and makes R9 actually used by the msft-graph DSN flow. msft-graph users: **56 s → 32 s** (**1.75×**). |
|  R12  | `f1dd1dc7`  | Adapter `setEdgeProperty` manually replicates the engine's edge-property bookkeeping using `putPropertyTxn` + `adj_out/adj_in.updateEdgePropHead` when a session/statement txn covers the graph — avoids the engine's auto-commit per-property fsync (which was an extra ~5 fsync/edge on msft-graph edges with 5 properties). | Enables batching on property-heavy edges. |
|  R13  | `f1dd1dc7`  | `executeCreateForBatchWithTracking` (the MATCH+CREATE path, not covered by R8–R12 because those only hook `executeCreate` / `executeMerge`) opens a per-statement txn at entry + commits at success-return.                                              | Covers msft-graph edge CREATE (`MATCH (a {node_id}), (b {node_id}) CREATE (a)-[r]->(b)`). |

## Residual ceiling

Large edge files (`edges_azure_rbac_assignment.jsonl` = 2186 rows,
`edges_located_at.jsonl` = 8259 rows) still cascade to serial-mode
fallback in 16-worker parallel mode.  The remaining bottleneck isn't
fsync (R9-R13 eliminate those) — it's the per-graph exclusive write-
lock hold time per batch:

    16 workers × 136 statements/batch × ~60 ms/statement ≈ 2 minutes
    worst-case wait for the 16th worker in a round-robin queue.

Two directions are available but out of scope for this overnight
session:

1. **Release the per-graph lock between statements** inside a session
   txn.  Currently the handler acquires the write lock for each
   statement and releases after.  Under an R9 session txn, 16 workers
   still serialise per-statement even though their writes are batched
   into a single fsync.  Releasing between statements would break the
   GAP-0001 / CWE-362 HashMap-rehash protection unless the in-memory
   mutation path is restructured to not depend on exclusive access.

2. **Custom bulk-load CREATE edge path** that bypasses the full
   executor.  msft-graph's edge pattern is very regular (exact-match
   on `node_id` on both endpoints + a known relation type + a tiny
   property map) and could take a short-circuit path through the
   adapter that skips MATCH compilation entirely.  Estimated ~5-10×
   on the edge phase.

The current 120 s lock timeout + client-side serial fallback means
even when chunks do hit the ceiling, the overall ingest still
completes — which is the change the user asked for:

> (original) "unusably slow and consistently fails to process requests"
> (now)      completes end-to-end; node phase ~13 min; full seed
> ~45-60 min.
