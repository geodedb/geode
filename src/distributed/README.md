# Distributed Module

This module implements Geode's cluster layer: Raft consensus, cluster
membership and health, and Raft-replicated writes within a documented slice.
Federated / scatter-gather query coordination is **not implemented**: the
code that described it (`federation.zig`, `query_coordinator.zig`,
`enhanced_query_coordinator.zig`, `query_transport.zig`, `mod.zig`, …) was
never compiled into any build artifact and was removed on 2026-11-11
(SONNY-6279).

> Distributed mode activates when `GEODE_CLUSTER_TOKEN` is set.
> All inter-node communication is authenticated and encrypted via QUIC+TLS.

## Cluster Token Rotation (SEC-INFRA-03)

The cluster bearer token supports zero-downtime rotation via a dual-token
overlap window (`src/distributed/cluster_auth.zig`):

- `GEODE_CLUSTER_TOKEN` — the **primary** token. Required to activate
  distributed mode; always the token **sent** on outbound inter-node
  traffic (Raft envelopes, 2PC messages, cluster RPC).
- `GEODE_CLUSTER_TOKEN_PREVIOUS` — optional **secondary** token. During a
  rotation overlap window, inbound validation accepts **either** token
  (both compared constant-time). It never authenticates on its own: if
  `GEODE_CLUSTER_TOKEN` is unset the node stays in standalone mode and
  rejects everything, regardless of `GEODE_CLUSTER_TOKEN_PREVIOUS`.

Token requirements (SONNY-6600):

- Each token that is set must be at least **16 bytes**; `geode serve`
  refuses to start otherwise (exit 1, naming the variable and its
  length). Set but empty is refused too. Use a random token, for example
  `openssl rand -hex 32` (64 characters, 256 bits); no other entropy check
  is made.
- Tokens are compared in full: both are hashed with SHA-256 and the
  digests compared in constant time, so the time taken depends only on
  the two lengths. Until SONNY-6600 only the first 256 bytes were
  compared, so a token longer than 256 bytes was accepted from a peer that
  knew its first 256 bytes. Regression: `zig build test-sonny6600-cluster-token`.

Rotation procedure (no flag-day, no quorum loss). A running process only
sees the env values it started with, so the accept-both phase must complete
on **every** node before any node starts *sending* the new token:

1. On every node set `GEODE_CLUSTER_TOKEN=<old-token>` (unchanged) and
   `GEODE_CLUSTER_TOKEN_PREVIOUS=<new-token>`, then rolling-restart.
   All nodes still send the old token; restarted nodes additionally
   accept the new one. No auth failures at any point during the roll.
2. On every node swap to `GEODE_CLUSTER_TOKEN=<new-token>` and
   `GEODE_CLUSTER_TOKEN_PREVIOUS=<old-token>`, then rolling-restart.
   Restarted nodes send the new token; every node (restarted or not)
   accepts both, so mixed-version traffic stays authenticated.
3. Once all nodes run with the new primary, remove
   `GEODE_CLUSTER_TOKEN_PREVIOUS` and rolling-restart again. The old token
   is now rejected cluster-wide.

Keep the overlap window short — while `GEODE_CLUSTER_TOKEN_PREVIOUS` is
set, the old (presumed compromised-or-stale) token still grants cluster
access. Validation applies uniformly to federation HELLOs (QUIC + gRPC
handlers), Raft frames, 2PC messages, and cluster RPC frames — all routes
go through `cluster_auth.validateClusterToken`. Regression:
`zig build test-sec-infra03` (`tests/test_sec_infra03_token_rotation.zig`).

## What the live cluster path provides

```
 Client request (QUIC / gRPC listener, src/server, src/transport)
      |
      v
+------------------+
|   Cluster        |  cluster.zig (ClusterCoordinator, its QUIC peer
|   Management     |  listener and raft transport), cluster_auth.zig,
|                  |  cluster_health.zig, nonce_tracker.zig
+------------------+
      |
      v
+------------------+
|   Consensus      |  raft_consensus.zig over the pinned raft library
|   (Raft)         |  (FileStorage: term, vote, log), raft_snapshot_manager.zig
+------------------+
      |
      v
+------------------+
|   Apply          |  raft_apply.zig, cluster_replication.zig,
|                  |  statement_proposals.zig, txn_coordinator.zig
+------------------+
```

- Raft consensus (`raft_consensus.zig`) over the pinned raft library. With a
  data directory the node's hard state (term and vote, written together) and
  log live in the library's `FileStorage`; what the library sends is released
  to the network only after that state is fsynced (SONNY-6563). Committed
  entries are applied to the graph store by `raft_apply.zig`.
- `ClusterCoordinator` (`cluster.zig`): static membership, leader tracking,
  health (`cluster_health.zig`), token authentication (`cluster_auth.zig`,
  `nonce_tracker.zig`) and replication (`cluster_replication.zig`).
- Raft-replicated writes within the documented slice (`docs/CLUSTER_WRITES.md`:
  what replicates, what is refused); statements are proposed
  through `statement_proposals.zig`. Write surfaces with no replication slice
  fail closed (`ClusterNotLeader` / `ClusterWriteNotReplicable`).
- Principal envelopes (`principal_envelope.zig`). EXPLAIN/PROFILE are
  node-local; `distributed_explain.zig` defines the error that refuses a
  remote plan payload (no remote consumer remains to raise it).

Queries execute on the node that receives them. There is no cross-node
scatter-gather, federated query dispatch, distributed query planning,
distributed result merge, sharding or federation-aware query optimization.

## Files (every one is reached from the server binary)

| File | Purpose |
|------|---------|
| `raft_consensus.zig` | Cluster `RaftNode` over the raft library: storage backing, the transport bridge, the per-peer outbox |
| `raft_snapshot_manager.zig` | Snapshot creation and installation |
| `raft_apply.zig` | Applies committed Raft commands to the graph store |
| `cluster.zig` | `ClusterCoordinator`: node lifecycle, replication, cluster messaging |
| `cluster_auth.zig` | Cluster token validation (incl. rotation overlap) and the verified peer dial |
| `cluster_health.zig` | Node health monitoring and failure detection |
| `cluster_replication.zig` | Replication of the supported write slice |
| `statement_proposals.zig` | Proposes statement mutations through Raft |
| `txn_coordinator.zig` | Decodes and applies replicated two-phase-commit write sets (`txn_prepare` / `txn_decide` Raft commands) |
| `nonce_tracker.zig` | Replay prevention for cluster frames |
| `principal_envelope.zig` | Serialized principal carried with cluster requests |
| `distributed_explain.zig` | `DistributedExplainUnsupported` error and message (mapped in `proto_util.zig`) |

Removed because nothing in the server reached them (no reference chain from
the server root, no symbol in the Debug binary; SONNY-6563): the
`raft_persistent.zig` wrapper (it persisted the term and not the vote),
`raft_log_storage.zig` and `raft_consensus.PersistentStorage` (a second,
unused term/vote/log store), `twophase.zig` (a 2PC transport) and
`value_convert.zig`, `query_planner.zig` (`DistributedQueryPlanner`,
`FederationManager`), `network_transport.zig`,
`enhanced_query_transport.zig`, `node_registry.zig`, `sharding.zig`,
`consistent_hash.zig` and `federation_flag.zig`. The federation and
query-coordination files this README listed before were removed in
SONNY-6279.

## Current Status

- **Consensus:** Raft leader election and log replication are functional.
  With a data directory the term, vote and log survive a restart
  (`zig build test-raft-hardstate-durability`). `RaftNode.drainReady`
  persists each Ready (raft v0.2.0 `advancePersist()`) before it sends the
  votes and replies the Ready holds and before it applies committed entries:
  a vote is durable before the grant leaves the node
  (`test-sonny6563-vote-persist-before-send`), and an entry is durable
  before it is applied or acknowledged
  (`test-sonny6611-raft-persist-before-apply`). Leader AppendEntries,
  heartbeats and InstallSnapshot go out at once, each with its own copy of
  the entry and snapshot data. If the Raft storage write fails, the node
  pauses (no Raft input, nothing sent or applied, proposals refused with
  `RaftStoragePersistFailed`) and each tick retries the write with backoff
  until it succeeds (`test-sonny6617-raft-persist-failure`). raft v0.2.2:
  a snapshot a follower installs is restored into the store before it is
  persisted or anything after it applies (on a restore thread while the
  node stays paused, SONNY-6636), and a store that cannot take it pauses
  the node the same way. Every node snapshots its own store past a
  threshold and compacts its Raft log there (see below). A rejected
  AppendEntries carries the
  follower's `conflict_index` / `conflict_term`. A Raft log with a damaged
  record refuses startup (`RaftStorageLogCorrupted`, `...LogAuthFailed`,
  `...LogEncryptionMismatch`) and is left as it is
  (`test-sonny6622-raft-v022-adapt`). The graphs an entry's apply writes are
  hydrated when the entry enters the log or before a restarted node
  replays it, not under `inner_mutex`
  (`test-sonny6631-apply-hydration-off-mutex`). A label or relationship type
  new to a graph an entry writes is given its id (a durable label-dictionary
  write, two fsyncs per shard set) at the same point, under the graph's
  `replicated_apply_mutex`, not under `inner_mutex`; only into a graph
  already open, never creating one (SONNY-6633 item 4, SONNY-6636).
  InstallSnapshot
  carries its chunk data, BLAKE3 digest and configuration on the wire, and a
  refused snapshot reaches the leader as a refusal; a snapshot carries the
  idempotency-key table (`test-sonny6633-snapshot-wire`). raft v0.2.3: the
  leader re-sends a refused snapshot after 16, 32, 64 ... rounds (at most
  256), not at the next round; a successful install resets the backoff.

### Raft snapshots into the durable store (SONNY-6633 item 2, SONNY-6636)

**Works now:** every node (leader and followers) snapshots its durable
store once its log has grown past a threshold and compacts its Raft log
there, so the log is bounded; a follower behind the leader's compacted
log restores the leader's snapshot into its durable store. Shown in one
process and in a cluster of `geode serve` processes. See "Still open"
below for what is left.

- **Taking a snapshot (`RaftNode.maybeStartSnapshot`, SONNY-6636 (b)):**
  once `SnapshotPolicy.entries` entries (`GEODE_RAFT_SNAPSHOT_ENTRIES`,
  default 10000) or `SnapshotPolicy.bytes` bytes of entry data
  (`GEODE_RAFT_SNAPSHOT_BYTES`, default 64 MiB) were applied since the last
  snapshot (0 turns a criterion off, both 0 turn snapshots off), the node,
  under `inner_mutex` and with every committed entry applied, records the
  applied index I and *holds its applies*: from then on committed entries
  are copied into a queue (`held_entries`), in order, not applied. The
  store then reflects exactly I. The snapshot thread
  (`snapshot_create_callback` = `raft_apply.createSnapshotCallbackFn`)
  checkpoints the store and archives every user graph's files into a GRS3
  snapshot (`encodeDurableSnapshot`), each graph under its read lock and
  its `replicated_apply_mutex` (`StorageAdapter.holdGraphForSnapshot`), so
  no local writer, checkpoint or label interning writes the files while
  they are read. It never takes `inner_mutex`. Meanwhile the node keeps
  ticking, heartbeating, persisting, voting and committing; only the
  applies wait. When the thread ends, `tick` (under `inner_mutex`) saves
  the snapshot to the Raft storage and compacts the log at I (raft
  `reportSnapshot`'s steps, at I rather than `log.applied`), then applies
  the held entries, at most `SnapshotPolicy.apply_budget_ns` (10 ms) per
  tick. A failure backs off and retries; an in-memory store turns
  snapshots off (`RaftSnapshotNeedsDurableStore`).
- **What the held applies cost:** a write is acknowledged when it commits
  (`waitForProposalCommitted`: its entry, by index and term, SONNY-6844), so writes go on during a snapshot; they
  become visible on the snapshotting node only once the copy ends and the
  held entries are applied (a read of one's own write on that node can
  miss it for the length of the copy: about 4 s for a 4.4 MB store in a
  Debug build on a busy disk). Measured by
  `test-sonny6636-server-snapshot`: no tick or message delivery took more
  than 147 ms during a snapshot (budget: a quarter of the 1000 ms election
  timeout) while the copy took 3.7-4.2 s; the longest of them is the save
  and compaction under `inner_mutex` (141-167 ms for that store).
- **A restart replays from the snapshot:** the log starts at the node's
  last snapshot I, and the store (checkpointed at I before the log was
  compacted) reflects some J >= I. The entries after I are applied again;
  `test-sonny6636-replay-idempotency` shows that replaying any suffix of a
  log covering every apply kind onto a store that reflects it changes
  nothing (an update, MERGE or edge naming a node a later entry deleted
  skips that node and goes on). The idempotency table comes back from the
  node's own snapshot (`raft_apply.seedFromLocalSnapshot`, at
  `ClusterCoordinator.init`): the compacted entries no longer rebuild it.
- **Snapshot and restore exclude each other** (`state_machine_io_mutex`):
  a snapshot of the leader that arrives while the node copies its own
  waits for the copy; the copy is then dropped, and the held entries the
  restored snapshot covers are dropped with it.

- **Snapshot format (GRS3, `raft_snapshot_manager.encodeDurableSnapshot`):**
  the storage engine's own files of every graph except `__geode_security`
  (whose contents belong to each node), byte for byte (`storage/graph_archive.zig`,
  the GEODBAK1 archive that backups also use), with each graph's name
  and uuid, plus the idempotency table. Nothing is converted, so every
  property value (including `ExtValue`s), label, edge, tenant tag, empty
  graph and per-graph index (fulltext, exact property) arrives unchanged.
  The default graph is included. The receiver checks the whole snapshot
  before it writes anything: the CRC, the graph list (a snapshot that
  names `__geode_security` is refused with `SnapshotNamesSecurityGraph`),
  that every archive entry name is safe and under a listed graph, and the
  idempotency table. Under at-rest encryption the files stay sealed, so the
  nodes must share `GEODE_TDE_KEY`. A durable store refuses the old
  JSON-lines snapshot (GRS2, which wrote every `ExtValue` as `"<ext>"`
  and carried no empty graphs) is gone: its encoder
  (`GraphStore.serializeSnapshot`, `encodeRaftSnapshot`) and its installer
  (`installSnapshotData`, `installRaftSnapshot`) were deleted, with the
  shard replication path that sent it (`ClusterCoordinator.
  replicateShardToNode`). Any other payload is refused
  (`RaftSnapshotUnknownFormat`), and so is any snapshot for an in-memory
  store (`RaftSnapshotNeedsDurableStore`).
- **Restore off `inner_mutex`:** `drainReady` pauses the node with the
  Ready (`stalled_ready`, the SONNY-6617 machinery) and runs
  `snapshot_restore_callback` on a restore thread. `tick` waits for that
  thread. On success it persists the snapshot (`advancePersist`) and
  applies the entries after it. On failure it starts the restore again
  after a backoff. While paused, the node sends nothing, applies nothing
  and refuses proposals. `inner_mutex` is never held across the restore's
  file I/O or graph locks.
- **Restore steps (`raft_snapshot_manager.restoreDurableSnapshot`):**
  1. Each graph is staged under `<data_dir>/<uuid>.restore`
     (`StorageAdapter.beginGraphRestoreAt`). The intent (fsynced, sealed
     under at-rest encryption) records the snapshot's Raft index and term.
     Each graph is then written and verified byte for byte. Nothing a
     reader sees changes during this step.
  2. The store's write lock is taken, which keeps out the persistence
     thread's checkpoints but not requests: a statement takes no store
     lock. For each graph, `GraphStore.forgetGraphBeforeRestore` drops what
     is resident, leaves the graph unbuilt and marks it restoring
     (SONNY-6749). Until step 4 no first touch builds it: the read fails
     with WouldBlock instead of building the old graph, whose completion
     persist wrote its IdMap and hydration snapshots into the restored
     directory, stamped with the restored engine's checkpoint epoch, where
     step 4 adopted them.
  3. The swap is committed (`commitGraphRestore`, unchanged below). While
     it runs, nothing opens the graphs' engines (`WouldBlock`); an open
     during the rename failed with FileNotFound, which the adapter
     remembered for the uuid, so the restored graph never opened again.
  4. `resetGraphAfterRestore` registers each graph for a build from its
     new files: resident nodes and edges, label postings and counts, MERGE
     entries (resident or not), lean backfill marks and the IdMap are gone,
     and the restored uuid is recorded. The graph builds again on its next
     touch (`endGraphRestore` also clears the mark when the restore stops
     before this step).
  5. Each graph the snapshot does not carry is dropped. The default graph
     and `__geode_security` are never dropped.
  6. The idempotency table is replaced. The server's hook
     (`index_manager.rebuildVectorIndexesForRestoredGraph`) rebuilds the
     vector indexes, which are not per graph. Fulltext and exact-property
     indexes come with the files.
- **Applied index:** finishing a restore (in the running process, or in
  `StorageAdapter.init` after a crash past the commit point) writes
  `<data_dir>/raft_store.index` (index and term, CRC'd, fsynced) before the
  intent is removed. `raft_apply` loads it with the store and applies no
  entry at or below it. A node that restarts before its Raft log persisted
  the snapshot replays its older entries; those are skipped instead of
  being applied over the restored store. A damaged file halts the apply.
- **Swap (`StorageAdapter.beginGraphRestore` / `commitGraphRestore`):** a
  restored graph keeps the uuid its files were written under. graph-storage
  binds a graph's uuid into its manifest, WAL header (`UuidMismatch`),
  shard uuids and, under at-rest encryption, its keys, and it has no re-key,
  so files cannot move to another uuid. `commitGraphRestore` works in this
  order:
  1. It rewrites the intent as committed. This is the commit point.
  2. It detaches the old engines: they are dropped, drained under their
     whole-graph lock, and freed by the last unpin with no checkpoint.
  3. It renames each staged directory into place. A graph restored again
     under its own uuid first has its live directory renamed aside to
     `<uuid>.old`.
  4. It points the registry at the restored uuids.
  5. It deletes the old directories, records the Raft index and deletes the
     intent.

  A uuid that belongs to another graph here is refused
  (`GraphRestoreUuidInUse`).
- **Crash safety:** `StorageAdapter.init` reads the intent before any graph
  opens. If the intent is not committed, the staged directories are deleted
  and the old graphs stay. If it is committed, the swap is finished. A
  damaged intent refuses the open. A crash after the swap but before the
  drops (step 5 of the restore) leaves the graphs the snapshot lacks until
  the leader sends the snapshot again: the Raft snapshot is persisted only
  after the restore returns. Tests:
  - `test-sonny6636-graph-restore-swap`: the swap alone, stopped at every
    step, with and without at-rest encryption.
  - `test-sonny6636-resident-reset`: the store's resident state.
  - `test-sonny6636-durable-snapshot-restore`: three Raft nodes in one
    process. A follower behind a compacted log catches up into the durable
    store. `inner_mutex` is free during the restore. Covered entries are
    never applied again, including after a restart. Restores stopped at
    every swap step reopen on all-old or all-restored data. A damaged or
    `__geode_security`-naming snapshot changes nothing.
  - `test-sonny6636-server-snapshot`: three Raft nodes on FileStorage in
    one process; the leader, then a follower, snapshots a 1500-node store
    past the threshold and compacts its log; a follower cut off behind the
    leader's compaction installs the leader's snapshot; the timing above;
    after a restart the log starts at the snapshot and a retried key is not
    applied twice.
  - `test-sonny6636-cluster-snapshot`: three `geode serve` processes with
    `GEODE_RAFT_SNAPSHOT_ENTRIES=25`: every node snapshots under sustained
    writes; a follower SIGKILLed while the leader compacts past it restores
    the leader's snapshot when it restarts; killed again and restarted, it
    and every other node hold each row exactly once.
  - `test-sonny6622-raft-v022-adapt`, `test-sonny6633-snapshot-wire`,
    `test-sonny6636-snapshot-over-quic`: a durable follower takes a GRS3
    snapshot of a closed leader data directory (library messages, geode
    frames, real QUIC).
- **Still open (SONNY-6636):**
  - **The Raft library writes the snapshot under the caller's lock.**
    `FileStorage.saveSnapshot` writes and fsyncs the whole snapshot (and,
    under TDE, seals it) inside `inner_mutex`, and a leader reads it back
    from disk under `inner_mutex` each time it sends it to a lagging
    follower (`sendSnapshotTo`). Both grow with the store (141-167 ms for
    4.4 MB measured): for a store of gigabytes they delay heartbeats past
    the election timeout. A raft API that stages the data off the lock
    and commits it under it is owed.
  - **The Raft index is recorded only by a restore,** not at each
    checkpoint.
  - **Applies are held for the whole copy,** so a snapshotting node serves
    reads that lag its commits by the length of the copy.
  - **Catalog rows are not in the snapshot.** Index and constraint
    definitions live in the engine-wide `geode_catalog.dat`. In cluster mode
    their DDL, and tenant DDL, is refused (`gateUnreplicatedWrite`), so
    nodes bootstrapped alike hold the same rows. A snapshot carries the
    graphs' files and the per-graph indexes inside them, but not those
    rows.
  - **A snapshot is built and held in memory whole** (the raft library
    takes a `[]const u8`), once on the node that takes it and again each
    time a leader sends it.

- **Cluster:** membership is the static `--peers` / `GEODE_PEERS` list read
  at startup; there is no dynamic join or leave (a JOIN_CLUSTER message is
  answered with ERR; the uncompilable, never-called `handleJoinCluster` and
  topology serializer were removed, SONNY-6459). `ClusterCoordinator` runs
  health checks (a peer is failed when it is not heard from for 5 s) and
  protobuf-based intra-cluster messaging.
- **Shards:** nothing in production fills `cluster_state.shards`, so shard
  forwarding (`forwardToShard`), replica promotion on node failure
  (`promoteReplica`) and the replication-factor repair
  (`ensureReplicationFactor`) never run outside tests; the shard data
  replication loop that sent a lossy JSON-lines copy of the whole store to
  a shard's replicas (`replicateShardToNode`) was deleted (SONNY-6636)
  (`zig build test-cluster-forward-to-shard` populates shards by hand). A
  failed node's raft role is taken over by raft leader election, not by
  shard failover.
- **Writes:** Replicated within the documented slice; other write surfaces
  fail closed in cluster mode.
- **Two-phase commit / distributed transactions:** not available. Nothing in
  the server proposes a `txn_prepare` or `txn_decide` entry (the only
  proposer, `statement_proposals.zig`, proposes `graph_mutation` entries), so
  the `TxnCoordinator` apply arms run only in tests; `twophase.zig` is not in
  the server binary (SONNY-6547).
- **DDL:** not replicated. Nothing proposes a `schema_change` entry; in
  cluster mode CREATE/DROP GRAPH, index, constraint, policy, auth and tenant
  DDL are refused by `cluster.gateUnreplicatedWrite()` (follower:
  `ClusterNotLeader`, leader: `ClusterWriteNotReplicable`). The
  `schema_change` apply arm in `raft_apply.zig` is the receiving side of a
  future replicated DDL, exercised only by tests (SONNY-6547).
- **Distributed / federated query coordination:** not implemented (removed
  2026-11-11, SONNY-6279; the code was never wired into a build artifact).
