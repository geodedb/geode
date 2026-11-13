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
 Client Request
      |
      v
+------------------+
|   Transport      |  network_transport.zig, query_transport.zig,
|   (QUIC/TLS)     |  enhanced_query_transport.zig
+------------------+
      |
      v
+------------------+
|   Consensus      |  raft_consensus.zig (canonical), raft.zig (shim),
|   (Raft)         |  raft_persistent.zig
+------------------+
      |
      v
+------------------+
|   Cluster        |  cluster.zig, cluster_auth.zig, cluster_health.zig,
|   Management     |  consistent_hash.zig, sharding.zig, nonce_tracker.zig
+------------------+
      |
      v
+------------------+
|   Query          |  enhanced_query_coordinator.zig, query_coordinator.zig,
|   Coordination   |  query_planner.zig, txn_coordinator.zig,
|                  |  twophase.zig, twophase_participant.zig
+------------------+
      |
      v
+------------------+
|   Federation     |  federation.zig, federation_flag.zig,
|   & Merge        |  federation_merge.zig, merge_strategies.zig,
|                  |  result_utils.zig, value_convert.zig
+------------------+
```

- Raft consensus with durable hard state, log and snapshots
  (`raft_consensus.zig`, `raft_log_storage.zig`, `raft_persistent.zig`,
  `raft_snapshot_manager.zig`), applied to the graph store by
  `raft_apply.zig`.
- `ClusterCoordinator` (`cluster.zig`): node membership, leader tracking,
  health (`cluster_health.zig`), token authentication (`cluster_auth.zig`,
  `nonce_tracker.zig`) and replication (`cluster_replication.zig`).
- Raft-replicated writes within the documented slice; statements are proposed
  through `statement_proposals.zig`. Write surfaces with no replication slice
  fail closed (`ClusterNotLeader` / `ClusterWriteNotReplicable`).
- Principal envelopes (`principal_envelope.zig`). EXPLAIN/PROFILE are
  node-local; `distributed_explain.zig` defines the error that refuses a
  remote plan payload (no remote consumer remains to raise it).

Queries execute on the node that receives them. There is no cross-node
scatter-gather, federated query dispatch, distributed result merge, or
federation-aware query optimization.

## File Responsibilities

### Imported by the geode library / server

| File | Purpose |
|------|---------|
| `raft_consensus.zig` | Canonical Raft implementation (election, log replication, snapshots) |
| `raft_log_storage.zig`, `raft_persistent.zig` | Durable Raft log and hard state |
| `raft_snapshot_manager.zig` | Snapshot creation and installation |
| `raft_apply.zig` | Applies committed Raft commands to the graph store |
| `cluster.zig` | `ClusterCoordinator`: node lifecycle, replication, cluster messaging |
| `cluster_auth.zig` | Cluster token validation (incl. rotation overlap) |
| `cluster_health.zig` | Node health monitoring and failure detection |
| `cluster_replication.zig` | Replication of the supported write slice |
| `statement_proposals.zig` | Proposes statement mutations through Raft |
| `nonce_tracker.zig` | Replay prevention for cluster frames |
| `principal_envelope.zig` | Serialized principal carried with cluster requests |
| `distributed_explain.zig` | `DistributedExplainUnsupported` error and message (mapped in `proto_util.zig`) |
| `txn_coordinator.zig`, `twophase.zig`, `twophase_participant.zig` | Two-phase commit coordinator and participant |
| `query_planner.zig` | Partition-aware planning helpers; the QUIC handler creates a `DistributedQueryPlanner` per stream and stores it as an opaque pointer, but no executor consults it |
| `value_convert.zig` | Value conversion between wire and engine types |

### Compiled only by their own unit-test steps

| File | Purpose |
|------|---------|
| `consistent_hash.zig`, `sharding.zig` | Consistent-hash ring and shard management |
| `network_transport.zig`, `enhanced_query_transport.zig` | Inter-node transport helpers |
| `node_registry.zig` | `NodeRegistry` (tested by `test_query_transport_node_registry.zig`) |
| `federation_flag.zig`, `federation_latency_aggregate.zig` | Mismatch flag and latency aggregates; nothing in the tree sets the flag now |

### Transport

| File | Purpose |
|------|---------|
| `network_transport.zig` | Low-level cluster networking (QUIC streams, connection pooling) |
| `query_transport.zig` | Inter-node query message transport (request/response framing) |
| `enhanced_query_transport.zig` | Extended transport with batching and compression |

### Query Coordination

| File | Purpose |
|------|---------|
| `enhanced_query_coordinator.zig` | Full-featured distributed query coordinator (caching, CBO, push-down) |
| `query_coordinator.zig` | Basic scatter-gather query coordinator (deprecated) |
| `query_planner.zig` | Partition-aware distributed query planning |
| `txn_coordinator.zig` | Distributed transaction coordination across shards |
| `twophase.zig` | Two-phase commit coordinator (prepare/commit/abort) |
| `twophase_participant.zig` | Two-phase commit participant (vote/ack handling) |

### Federation & Merge

| File | Purpose |
|------|---------|
| `federation.zig` | Federation configuration, routing, and cross-cluster query dispatch |
| `federation_flag.zig` | Federation mismatch flag propagation (schema/version divergence) |
| `federation_merge.zig` | Result merging across federated clusters |
| `merge_strategies.zig` | Pluggable merge strategies (union, intersection, priority) |
| `result_utils.zig` | Utility functions for result set manipulation |
| `value_convert.zig` | Cross-node value type conversion and normalization |

### Module Root

| File | Purpose |
|------|---------|
| `mod.zig` | Module entrypoint; re-exports public types; hosts deprecated `DistributedCoordinator` |

### Tests

| File | Purpose |
|------|---------|
| `test_federation_auth.zig` | Integration tests for federation authentication flows |

## Current Status

- **Consensus:** Raft leader election and log replication are functional.
  `raft_persistent.zig` provides durable state across restarts.
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
