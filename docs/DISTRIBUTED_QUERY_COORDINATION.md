# Distributed Query Coordination: status

## Status: not implemented

Geode does not coordinate a query across nodes or shards. There is no
scatter-gather execution, no federated query dispatch, no cross-node result
merge, no cross-shard query planning, and no federation-aware optimization or
load balancing. A query runs on the node that receives it.

### Scope limitation: `EXPLAIN` / `PROFILE` are node-local only (GAP-0856)

`EXPLAIN` and `PROFILE` run on the node that receives them. Their wire payloads
(`ExplainPayload` / `ProfilePayload`) are not row-shaped, and there is no
coherent way to merge independent plan trees from several nodes.
`src/distributed/distributed_explain.zig` defines the structured error
`DistributedExplainError.DistributedExplainUnsupported` for a remote plan
payload; `src/server/proto_util.zig` maps it to SQLSTATE `0A000`. No remote
consumer remains to raise it (see below). To obtain a plan, issue `EXPLAIN` /
`PROFILE` against the node that owns the data. Regression cover:
`tests/test_gap0856_distributed_explain.zig` (`zig build test-gap0856`).

## What was removed

An earlier version of this document described an "Enhanced Query
Coordinator", a "Query Transport Layer", federation, merge strategies and a
distributed query cache. That code (`src/distributed/federation.zig`,
`federation_merge.zig`, `merge_strategies.zig`, `query_coordinator.zig`,
`enhanced_query_coordinator.zig`, `query_transport.zig`, `result_utils.zig`
and `mod.zig`) was never compiled into any executable or test: no file in
`build.zig`'s import graph reached it. It was removed on 2026-11-11
(SONNY-6279), together with the tests and benchmarks that only exercised it.

## What the live cluster path provides

When `GEODE_CLUSTER_TOKEN` is set, `geode serve` runs the cluster path in
`src/distributed/`:

- Raft consensus with durable hard state, log and snapshots
  (`raft_consensus.zig`, `raft_log_storage.zig`, `raft_persistent.zig`,
  `raft_snapshot_manager.zig`, `raft_apply.zig`).
- `ClusterCoordinator` (`cluster.zig`): node membership, leader tracking,
  health checks (`cluster_health.zig`), cluster-token authentication
  (`cluster_auth.zig`, `nonce_tracker.zig`) and replication
  (`cluster_replication.zig`).
- Raft-replicated writes within the documented slice, proposed through
  `statement_proposals.zig`. Write surfaces with no replication slice fail
  closed: a follower answers `ClusterNotLeader`, a leader
  `ClusterWriteNotReplicable`. See "Cluster-mode fail-closed surfaces" in
  `CLAUDE.md` and `tests/test_cluster_replicable_mutations.zig`
  (`zig build test-cluster-replicable-mutations`).

`src/distributed/README.md` lists every remaining file and whether a build
artifact compiles it.
