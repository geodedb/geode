# Distributed Module Architecture

## Module Roles

### Consensus Layer

- **`raft_consensus.zig`** -- Canonical Raft wrapper around the external
  `gitlab.com/devnw/zig/raft` library. Uses u64 node IDs, typed `Command`
  unions, protobuf wire framing over QUIC, and file-backed
  `PersistentStorage` for term/votedFor durability.

- **`raft.zig`** -- Thin compatibility shim for `mod.zig`. Accepts
  string-based node IDs (hashed to u64 via Wyhash) and raw byte payloads,
  then delegates all consensus operations to `raft_consensus.RaftNode`.

- **`raft_persistent.zig`** -- Standalone persistent Raft node used for
  cluster membership bookkeeping (member add/remove, snapshots). Reads and
  writes term state to the filesystem independently of the consensus
  wrapper.

### Coordination Layer

- **`mod.zig`** -- `DistributedCoordinator` facade. Composes Raft (via the
  `raft.zig` shim), 2PC, and sharding behind a single API. This is the
  entry point used by the rest of Geode.

- **`cluster.zig`** -- `ClusterCoordinator`. Higher-level coordinator that
  uses `raft_consensus.RaftNode` directly for production cluster
  management, health monitoring, and leader-driven operations.

- **`twophase.zig`** -- Two-phase commit coordinator for distributed
  transactions spanning multiple shards.

- **`txn_coordinator.zig`** -- Transaction lifecycle management integrated
  with the Raft log for replicated transaction decisions.

### Query Layer

- **`query_coordinator.zig`** / **`query_planner.zig`** -- Distributed
  query planning and execution across shards.

- **`enhanced_query_coordinator.zig`** / **`enhanced_query_transport.zig`**
  -- Extended query coordination with federation awareness and load
  balancing.

### Data Distribution

- **`sharding.zig`** -- Consistent-hash shard manager mapping keys to
  shard IDs and nodes.

- **`federation.zig`** / **`federation_flag.zig`** /
  **`federation_latency_aggregate.zig`** -- Cross-cluster federation,
  latency tracking, and mismatch detection.

### Transport

- **`network_transport.zig`** / **`query_transport.zig`** -- QUIC-based
  inter-node transport for Raft messages and query data.

## Layer Diagram

```
 Transport (QUIC/TLS)
        |
 Consensus (raft_consensus.zig)
        |
 Cluster  (cluster.zig / mod.zig)
        |
 Query Coordination (query_coordinator.zig)
```

## Key Design Decisions

1. **Single consensus implementation.** `raft_consensus.zig` is the only
   file that wraps the external raft library for consensus operations.
   `raft.zig` is a backward-compatible shim, not a second implementation.

2. **u64 node identity.** The external raft library requires u64 node IDs.
   String IDs (used by `mod.zig`) are hashed via Wyhash in the shim layer.

3. **File-backed persistence.** `PersistentStorage` in `raft_consensus.zig`
   writes `current_term` and `voted_for` to the data directory. Log entry
   persistence is deferred (requires a WAL implementation).

4. **Protobuf wire format.** Inter-node Raft messages are encoded as
   protobuf `RaftEnvelope` frames, length-prefixed (4-byte big-endian)
   over QUIC streams.
