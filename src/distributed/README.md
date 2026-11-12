# Distributed Module

This module implements Geode's distributed systems layer: consensus,
coordination, sharding, federation, and distributed query execution.

> Distributed mode activates when `GEODE_CLUSTER_TOKEN` is set.
> All inter-node communication is authenticated and encrypted via QUIC+TLS.

## Cluster Token Rotation (SEC-INFRA-03)

The cluster bearer token supports zero-downtime rotation via a dual-token
overlap window (`src/distributed/cluster_auth.zig`):

- `GEODE_CLUSTER_TOKEN` — the **primary** token. Required to activate
  distributed mode; always the token **sent** on outbound inter-node
  traffic (federation HELLO, Raft envelopes, 2PC messages, cluster RPC).
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

## Layer Diagram

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

## Coordinator Hierarchy

### Cluster Coordination

| Coordinator | File | Role | Use When |
|-------------|------|------|----------|
| **ClusterCoordinator** | `cluster.zig` | Production coordinator | Production and multi-node deployments |
| DistributedCoordinator | `mod.zig` | Simplified wrapper (deprecated) | Single-node testing or lightweight integration |

**ClusterCoordinator** is the canonical production coordinator. It manages Raft
consensus (via `raft_consensus.zig`), node health monitoring, data replication,
protobuf-based cluster messaging, and network transport. All new production code
should use `ClusterCoordinator`.

**DistributedCoordinator** is a simpler facade that wraps `raft.zig` (now a thin
shim over `raft_consensus.zig`) and `twophase.zig`. It is retained for backward
compatibility and lightweight tests but is **deprecated** in favor of
`ClusterCoordinator`.

### Query Coordination

| Coordinator | File | Role | Use When |
|-------------|------|------|----------|
| **EnhancedQueryCoordinator** | `enhanced_query_coordinator.zig` | Full-featured query coordinator | Production distributed queries |
| QueryCoordinator | `query_coordinator.zig` | Basic scatter-gather (deprecated) | Simple federation without caching |

**EnhancedQueryCoordinator** is the preferred query coordinator. It is a superset
of `QueryCoordinator`, adding:

- Distributed query cache (`QueryCache`)
- Cost-based distributed query optimizer (`DistributedQueryOptimizer`)
- Shard-aware routing via `ShardRegistry`
- Node health tracking via `NodeRegistry`
- Top-K push-down and aggregation push-down
- Coordinator-level metrics

**QueryCoordinator** provides basic scatter-gather execution with CBO statistics
integration. It is **deprecated** -- use `EnhancedQueryCoordinator` for new work.

## Module Entrypoint

`mod.zig` re-exports the key types for convenient access:

```zig
const distributed = @import("distributed");

// Production coordinators (preferred)
const Cluster = distributed.ClusterCoordinator;
const QueryCoord = distributed.EnhancedQueryCoordinator;

// Legacy (deprecated)
const Legacy = distributed.DistributedCoordinator;
const BasicQuery = distributed.QueryCoordinator;
```

## File Responsibilities

### Consensus

| File | Purpose |
|------|---------|
| `raft_consensus.zig` | Canonical Raft consensus implementation (leader election, log replication, snapshotting) |
| `raft.zig` | Thin compatibility shim delegating to `raft_consensus.zig` |
| `raft_persistent.zig` | Durable Raft log and state persistence (WAL-backed) |

> **Note:** `raft_consensus.zig` is the canonical Raft wrapper. `raft.zig` exists
> solely as a compatibility shim and should not be extended.

### Cluster Management

| File | Purpose |
|------|---------|
| `cluster.zig` | Production cluster coordinator (node lifecycle, replication, messaging) |
| `cluster_auth.zig` | Intra-cluster authentication and token validation |
| `cluster_health.zig` | Node health monitoring, failure detection, heartbeat tracking |
| `consistent_hash.zig` | Consistent hashing ring for shard placement |
| `sharding.zig` | Hash-based shard management and key-range routing |
| `nonce_tracker.zig` | Replay-attack prevention via nonce deduplication |

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
- **Cluster:** `ClusterCoordinator` handles node join/leave, health checks,
  and protobuf-based intra-cluster messaging.
- **Two-phase commit:** Coordinator and participant roles are implemented.
  Undo/rollback path is partially implemented.
- **Distributed query planning:** `query_planner.zig` provides partition-aware
  planning. The enhanced coordinator adds caching and push-down, but the full
  cost model integration with the main planner is scaffolded.
- **Federation:** Cross-cluster query dispatch, mismatch flag propagation, and
  merge strategies are implemented. Latency tracking is functional.
