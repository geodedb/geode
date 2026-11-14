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
- Raft-replicated writes within the documented slice; statements are proposed
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
  (`zig build test-raft-hardstate-durability`), and a vote is durable before
  the grant leaves the node (`test-sonny6563-vote-persist-before-send`).
- **Cluster:** membership is the static `--peers` / `GEODE_PEERS` list read
  at startup; there is no dynamic join or leave (a JOIN_CLUSTER message is
  answered with ERR; the uncompilable, never-called `handleJoinCluster` and
  topology serializer were removed, SONNY-6459). `ClusterCoordinator` runs
  health checks (a peer is failed when it is not heard from for 5 s) and
  protobuf-based intra-cluster messaging.
- **Shards:** nothing in production fills `cluster_state.shards`, so shard
  forwarding (`forwardToShard`), replica promotion on node failure
  (`promoteReplica`) and the replication-factor repair
  (`ensureReplicationFactor`) never run outside tests
  (`zig build test-cluster-forward-to-shard` populates shards by hand). A
  failed node's raft role is taken over by raft leader election, not by
  shard failover.
- **Writes:** Replicated within the documented slice; other write surfaces
  fail closed in cluster mode.
- **Two-phase commit:** Coordinator and participant roles are implemented.
  Undo/rollback path is partially implemented.
- **Distributed / federated query coordination:** not implemented (removed
  2026-11-11, SONNY-6279; the code was never wired into a build artifact).
