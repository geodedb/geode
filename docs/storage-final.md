# Storage Final Implementation Plan

> Scope: complete the per-graph storage path across Geode and `/home/benji/src/devnw/zig/graph-storage` so that ingest durability, recovery, label persistence, and on-disk metadata are fully implemented and verifiable.
>
> Recommended architectural decision: make `graph-storage` the sole crash-recovery and physical durability authority. Geode's `src/wal.zig` may remain as a logical change feed or audit log, but it must not be part of the primary crash-recovery path.

## Goals

- Make every graph mutation durable and reloadable.
- Eliminate placeholder or misleading on-disk files.
- Make per-graph WAL and recovery active for normal ingest traffic.
- Persist node label mutations and edge properties correctly.
- Replace the current unsound label encoding with a scalable representation.
- Add migration, observability, and tests so large ingests can be trusted.

## Non-goals

- Cross-graph physical storage or cross-graph query support.
- Preserving the exact old on-disk format.
- Shipping a "mostly wired" dual-write path. The end state must be internally consistent.

## Current Gaps To Close

- Edge properties are not durably persisted. `GraphStore.setEdgeProperty` mutates only the in-memory edge map, the adapter vtable has no edge-property hooks, `StorageAdapter.setEdgeProperty` cannot write a new `prop_head` back into adjacency, and reload reconstructs edges with empty property maps.
- Per-graph WAL exists on disk but is not active for normal writes. Normal mutations go directly to the page stores, recovery only understands `page_update` records, and the transaction/WAL APIs are not used by production graph mutations.
- Node label mutations after creation are not persisted. `addNodeLabel` and `removeNodeLabel` only update the in-memory store.
- Label storage is unsound beyond trivial cases. The engine stores `label % 32`, the adapter reconstructs labels by modulo scan, and rebuild code treats a bitset as a single label identifier.
- Several files are placeholders today. `labels.idx` and `props.idx` are not opened by the engine, `free.store` is rebuilt from file sizes instead of persisted metadata, and `var.store` is effectively unused.
- Verification is incomplete. `graph-storage` unit tests pass, but integration tests have drifted, and Geode does not currently have a reliable storage-focused verification path.

## End-State Contract

When this plan is complete, the storage stack must satisfy all of the following:

- Every mutating `GraphStore` API used by query execution has a storage-backed implementation path.
- Edge properties survive restart and reload exactly like node properties.
- Node labels added or removed after node creation survive restart and reload.
- Recovery from a crash between ingest batches replays committed changes from `wal/graph.wal`.
- `labels.idx`, `free.store`, and `var.store` have clear semantics and real readers/writers.
- `props.idx` is either fully implemented for persistent secondary property indexes or removed from the baseline file set until that feature exists.
- `adapter_labels.dat` is removed or migrated away so there is a single authoritative label dictionary.
- A large ingest can be validated through tests and storage inspection without relying on directory size guesses.

## Required Design Decisions

These decisions should be locked before implementation begins. The rest of the plan assumes them.

### 1. Make `graph-storage` the physical source of truth

- Crash recovery, checkpointing, page images, and manifest LSNs must belong to `/home/benji/src/devnw/zig/graph-storage`.
- Geode's `src/wal.zig` should no longer be required for database crash recovery.
- If `src/wal.zig` remains, it should become a post-commit logical feed for audit, CDC, or replication, with real transaction IDs instead of `txn_id = 0`.

### 2. Replace `label % 32` with a real persisted label model

- The current bitmap is not salvageable as the only persisted source of node labels.
- Node records need either:
  - a `label_head` pointer to a variable-length label block chain, or
  - an inline small-label array plus overflow blocks in `var.store`.
- `labels.idx` should become the persistent label-to-node index.

### 3. Make edge metadata updatable in place

- The engine needs a supported way to update edge metadata after edge creation, at minimum `prop_head`.
- Correctness requires updating both copies of an edge entry: the outgoing adjacency entry and the incoming adjacency entry.
- Edge-property writes may start with adjacency scans for correctness, but the engine should grow an edge locator/index so `getEdge` and edge metadata updates are not permanently O(degree).

### 4. Remove placeholder file semantics

- Files that are always created must have active read/write logic.
- Files that are optional should be created lazily.
- The user-visible graph directory should reflect actual state, not unfinished scaffolding.

## File Map

### Geode

- `src/graph_store.zig`
- `src/storage/graph_storage_adapter.zig`
- `src/server/main.zig`
- `src/wal.zig`
- `src/execution/` call sites that currently mutate `GraphStore`
- `tests/` and `geodetestlab/`

### graph-storage dependency

- `/home/benji/src/devnw/zig/graph-storage/src/engine.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/adj_store.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/node_store.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/prop_store.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/property_index.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/label_index.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/free_space.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/file_manager.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/recovery.zig`
- `/home/benji/src/devnw/zig/graph-storage/src/txn.zig`
- `/home/benji/src/devnw/zig/graph-storage/tests/integration.zig`

## Phase 0: Stabilize the Verification Harness

This phase prevents the storage rewrite from happening blind.

- [ ] Fix `graph-storage/tests/integration.zig` to use the iterator-returning `expandOut` and `expandIn` APIs instead of the removed slice-returning signature.
- [ ] Add a `zig build test-storage` or equivalent Geode target that exercises storage and adapter code without depending on the broken QUIC dependency path.
- [ ] Add a storage smoke test that creates a graph, writes nodes, writes edges, checkpoints, closes, reopens, and verifies reload.
- [ ] Add a crash-simulation harness in `graph-storage` that can:
  - create a graph,
  - begin a transaction,
  - mutate pages,
  - kill the process before checkpoint,
  - reopen and validate replay.
- [ ] Add a deterministic fixture for the `abs_eagle` style ingest shape: many node properties, many edges, repeated label mutations, and checkpoint/restart boundaries.

### Exit Criteria

- `zig build test` and `zig build test-integration` pass in `/home/benji/src/devnw/zig/graph-storage`.
- Geode has at least one repeatable storage integration target that does not depend on transport setup.

## Phase 1: Complete the Dual-Write API Surface in Geode

The Geode API surface must stop dropping mutations on the floor before the engine can be trusted.

- [ ] Extend `AdapterVTable` in `src/graph_store.zig` with:
  - `setEdgeProperty`
  - `removeEdgeProperty`
  - `addNodeLabel`
  - `removeNodeLabel`
  - optional `beginTransaction`, `commitTransaction`, and `abortTransaction`
- [ ] Implement the new vtable dispatchers in `initGlobalAdapter`.
- [ ] Update `GraphStore.setEdgeProperty` and `GraphStore.removeEdgeProperty` to dual-write through the adapter before mutating the in-memory edge map.
- [ ] Update `GraphStore.addNodeLabel` and `GraphStore.removeNodeLabel` to dual-write through the adapter before mutating the in-memory node labels and label index.
- [ ] Teach `loadFromAdapter` to load edge properties from storage instead of reconstructing edges with empty property maps.
- [ ] Add tests in Geode that fail if node-label or edge-property mutations are missing after restart.

### Implementation Notes

- Use the existing in-memory `Edge` record to recover `from_id` and `to_id` for adapter calls.
- Do not hide adapter errors; storage failures on mutating operations must be surfaced to the caller.
- Keep dual-write temporary. The target architecture is storage-first, but this phase makes the existing Geode layer correct enough to proceed.

### Exit Criteria

- Setting and removing edge properties changes both in-memory state and the engine.
- Adding and removing node labels after creation survives adapter reload.

## Phase 2: Implement Correct Edge Property Persistence in `graph-storage`

This is the highest-priority correctness gap in the engine itself.

- [ ] Add an adjacency-level API for updating edge metadata in place. Minimum required API:
  - `updateEdgePropHead(list_head: u64, edge_id: u64, new_prop_head: u32) !bool`
- [ ] Add engine-level helpers in `/home/benji/src/devnw/zig/graph-storage/src/engine.zig`:
  - `setEdgeProperty(from, to, edge_id, key, value)`
  - `removeEdgeProperty(from, to, edge_id, key)`
  - `getAllEdgeProperties(from, edge_id)`
- [ ] Ensure the engine updates both the outgoing and incoming adjacency entry for the same logical edge so `prop_head` stays consistent from either direction.
- [ ] Keep the first implementation simple and correct:
  - scan the source outgoing list to find the edge entry,
  - write or update the property chain,
  - update the outgoing adjacency entry,
  - update the incoming adjacency entry on the target node.
- [ ] Add an edge locator/index as a follow-up within the same phase or immediately after:
  - `edge_id -> {from_node_id, to_node_id, out_location, in_location}`
  - use it to implement `getEdge(edge_id)` and remove long-term O(degree) scans.
- [ ] Add edge-property replay/reload coverage so reopened graphs rebuild edge property maps from storage, not from empty defaults.

### Exit Criteria

- A newly created edge with its first property persists correctly.
- Updating an existing edge property rewrites the stored `prop_head` correctly.
- Removing an edge property survives restart.
- `getEdge` is no longer a hard `EdgeIndexNotImplemented` blocker.

## Phase 3: Replace the Label Model With a Sound Persisted Representation

The current label implementation cannot be extended safely. This phase replaces it.

- [ ] Define a new node-record format with real label ownership. Recommended shape:
  - `label_count`
  - `label_head`
  - optional tiny inline label slots for the common case of 1-2 labels
- [ ] Implement a label block structure in `var.store` for variable-length node label membership.
- [ ] Rebuild `labels.idx` as a persistent label postings/index structure:
  - `label_id -> node_id set`
  - page-backed and recoverable
  - updated on node create, label add, label remove, and node delete
- [ ] Remove the modulo-32 encoding from `engine.addLabel` and `engine.removeLabel`.
- [ ] Rewrite adapter label loading so it reads exact label IDs from the persisted node membership structure rather than reconstructing by `% 32`.
- [ ] Rewrite `/home/benji/src/devnw/zig/graph-storage/src/label_index.zig` rebuild logic so it iterates exact labels, not a bitset mistaken for a scalar.
- [ ] Unify the label dictionary:
  - make the engine-owned label dictionary authoritative,
  - stop persisting `adapter_labels.dat`,
  - migrate existing label names from `adapter_labels.dat` into the engine dictionary during startup migration.

### Data Format Recommendation

- `labels.dict` remains the authoritative mapping of `label_id <-> label_string`.
- Node records point to exact label membership blocks.
- `labels.idx` becomes the query-time reverse index.
- Geode no longer owns a separate persistent label dictionary sidecar.

### Exit Criteria

- Any node can hold more than 32 distinct labels without ambiguity.
- Label add/remove operations survive restart exactly.
- Label scans are served by the persistent index, not by in-memory reconstruction hacks.

## Phase 4: Activate Real Per-Graph Transactions, WAL, and Recovery

The current WAL exists, but the normal mutation path bypasses it. This phase makes it real.

- [ ] Add transaction ownership to normal graph mutations.
- [ ] Support two usage modes:
  - explicit transactions from higher layers,
  - auto-transactions for single-call mutations so callers do not silently bypass WAL.
- [ ] Track dirty pages per transaction in the buffer pool or pager layer.
- [ ] On `commitTxn`, append `page_update` WAL records for all dirty pages touched by the transaction before any dirty page is flushed to disk.
- [ ] Append and fsync the `commit_txn` record before acknowledging success to the caller.
- [ ] Prevent `checkpoint` from writing a manifest LSN that is ahead of durable WAL state.
- [ ] Keep recovery aligned with the new commit protocol:
  - classify begin/commit/abort,
  - replay committed `page_update` records after the last checkpoint LSN,
  - ignore uncommitted page updates,
  - write a fresh clean manifest after recovery.
- [ ] Wire Geode adapter write operations to use engine transactions instead of direct non-transactional page mutations.
- [ ] Remove Geode's mutation-callback WAL from the primary durability path.
- [ ] If Geode logical WAL remains, emit it only after the engine transaction commits and include the real transaction ID.

### Recommended Commit Protocol

1. Begin engine transaction.
2. Mutate pages in memory and register dirty-page ownership.
3. On commit, serialize dirty page images into `graph.wal`.
4. Append `commit_txn` and fsync WAL.
5. Mark transaction committed.
6. Allow checkpoint or background flush to write dirty pages.
7. Update `manifest.last_checkpoint_lsn` only after checkpointed pages are durable.

### Exit Criteria

- `wal/graph.wal` grows during real ingest activity.
- A crash after commit but before checkpoint replays committed changes.
- A crash before commit does not expose uncommitted changes.

## Phase 5: Implement or Remove Placeholder Files

The storage directory should stop containing zero-value placeholders with no live code path behind them.

### `free.store`

- [ ] Replace the current derived-from-file-size free-space bitmap with a persisted free-page map or freelist.
- [ ] Load it on startup and checkpoint it like the other stores.
- [ ] Update allocate/free paths for node, adjacency, property, and variable stores.

### `labels.idx`

- [ ] Implement as the persistent label reverse index introduced in Phase 3.
- [ ] Open/register it in `file_manager` and `engine`.

### `var.store`

- [ ] Give `var.store` a real role:
  - overflow values for large strings/bytes/decimals,
  - label membership blocks,
  - any future variable-length record payloads.
- [ ] Add size thresholds so small scalar values stay inline, but large payloads spill predictably.
- [ ] Add tests for overflow read/write/recovery.

### `props.idx`

- [ ] Stop treating `props.idx` as a mandatory always-present file unless there is a real persistent property index implementation.
- [ ] Recommended plan:
  - define property indexes as explicit secondary indexes, not an implicit global index for every property,
  - implement them as page-backed structures in `props.idx`,
  - create the file lazily when the first persistent property index is created.
- [ ] If persistent property indexing is not part of the current release scope, remove `props.idx` from the baseline graph directory and from `file_manager` until the feature is added.

### Exit Criteria

- Every baseline file in a new graph directory has an active code path and documented semantics.
- Optional files are created lazily and only when the corresponding feature is in use.

## Phase 6: Migration and Compatibility

This work changes the on-disk contract. Migration must be explicit and safe.

- [ ] Bump the manifest/data format version.
- [ ] Add startup migration logic for existing graph directories that contain:
  - `adapter_labels.dat`
  - label bitmaps encoded in old node records
  - empty or inactive `wal/graph.wal`
  - placeholder files with no useful content
- [ ] Migration strategy:
  - open the old graph in compatibility mode,
  - read nodes, edges, labels, and properties through the old code,
  - write them into the new layout under a temp graph directory,
  - fsync and atomically swap the directory or manifest pointer.
- [ ] Preserve `id_map.dat` unchanged where possible so external UUIDs remain stable.
- [ ] Add a one-shot offline migrator command for large datasets so operators can upgrade without relying on lazy runtime conversion.
- [ ] Add rollback support:
  - backup original graph directory,
  - do not delete it until the migrated graph passes integrity checks.

### Exit Criteria

- Existing graphs can be upgraded without losing labels, edge properties, or UUID mappings.
- Migration can be retried safely after interruption.

## Phase 7: Observability and Operator Validation

The current workflow relies too much on `ls -alR`. That is insufficient once the storage layer is correct.

- [ ] Add a storage inspection command or debug API that reports:
  - node count
  - edge count
  - label count
  - property page count
  - free-page count
  - var-store usage
  - WAL size and current LSN
  - last checkpoint LSN and timestamp
- [ ] Add integrity-check commands:
  - verify node-to-label index consistency
  - verify edge adjacency symmetry
  - verify edge `prop_head` consistency in both adjacency directions
  - verify ID map coverage
- [ ] Add ingest-time metrics so operators can see whether checkpoints, WAL replay, and page reuse are functioning.

### Exit Criteria

- Operators can verify storage health without inferring correctness from static file sizes.

## Suggested Execution Order

1. Phase 0: make tests trustworthy first.
2. Phase 1: close the Geode API holes so mutations stop being silently dropped.
3. Phase 2: make edge properties correct in the engine.
4. Phase 3: replace the label model and unify the label dictionary.
5. Phase 4: activate real WAL and transaction semantics.
6. Phase 5: implement or remove placeholder files based on the new format.
7. Phase 6: ship migration.
8. Phase 7: add operator-facing inspection and integrity tooling.

## Test Matrix

- [ ] Unit: node property round-trip
- [ ] Unit: edge property first-write round-trip
- [ ] Unit: edge property update/remove round-trip
- [ ] Unit: add/remove node label after creation
- [ ] Unit: label dictionary persistence and lookup
- [ ] Unit: free-space persistence across restart
- [ ] Unit: var-store overflow values across restart
- [ ] Unit: property index persistence if `props.idx` remains in scope
- [ ] Integration: checkpoint and reopen after mixed node/edge/property/label ingest
- [ ] Integration: crash before commit
- [ ] Integration: crash after commit before checkpoint
- [ ] Integration: crash during checkpoint
- [ ] Integration: migration from old graph directory to new format
- [ ] Integration: large ingest with repeated checkpoints and integrity verification
- [ ] Performance: ingest throughput before/after WAL activation
- [ ] Performance: restart time and WAL replay time at realistic graph sizes

## Release Gate

Do not call the storage system "fully implemented" until all of the following are true:

- Edge properties and post-create label mutations survive restart.
- `wal/graph.wal` is active for normal writes and replayed on crash recovery.
- The label model no longer uses `% 32` reconstruction.
- Placeholder files are either real or gone.
- Migration exists for old graph directories.
- Storage integration tests pass in both repos.
- There is an operator-visible way to inspect storage health and replay state.
