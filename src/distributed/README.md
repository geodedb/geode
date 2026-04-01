# Distributed Module

This module implements Geode's distributed systems layer: consensus, coordination,
sharding, federation, and distributed query execution.

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

## Other Components

| File | Purpose |
|------|---------|
| `raft_consensus.zig` | Full Raft consensus implementation |
| `raft.zig` | Thin shim delegating to `raft_consensus.zig` |
| `twophase.zig` | Two-phase commit coordinator |
| `sharding.zig` | Hash-based shard management |
| `federation.zig` | Federation configuration and routing |
| `query_planner.zig` | Partition-aware query planning |
| `query_transport.zig` | Inter-node query message transport |
| `network_transport.zig` | Low-level cluster networking |
| `txn_coordinator.zig` | Distributed transaction coordination |
