# Distributed Module Code Quality Gap Analysis

Last updated: 2026-06-10

This file now contains only open distributed quality gaps. Archive details live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open Gaps

### High — Code Duplication

| Finding | Files | Copies |
|---|---|---:|
| `cloneBindingRow` duplication | `federation.zig`, `query_coordinator.zig`, `enhanced_query_coordinator.zig` | 3 |
| `freeBindingRow` duplication | `federation.zig`, `query_coordinator.zig`, `enhanced_query_coordinator.zig`, `query_transport.zig` | 4 |
| `cloneSchema` duplication | `federation.zig`, `query_coordinator.zig`, `enhanced_query_coordinator.zig` | 3 |
| Dual Raft wrappers | `raft.zig`, `raft_consensus.zig` | 2 |
| `ShardInfo` duplication | `mod.zig`, `cluster.zig`, `sharding.zig`, `query_coordinator.zig`, `enhanced_query_coordinator.zig` | 5 |
| `NodeRegistry` duplication | `query_coordinator.zig`, `enhanced_query_coordinator.zig` | 2 |
| Pagination merge logic duplication | `enhanced_query_coordinator.zig` | 5 |

### High — Dead Code / Stubs

| Finding | File:Line |
|---|---|
| `federation_root.zig` has zero imports | `src/distributed/federation_root.zig` |
| Cluster request stubs: leave, replicate, failover, shard forward | `src/distributed/cluster.zig` |
| `raft.zig handleMessage` discards all args | `src/distributed/raft.zig` |
| `PartitionAwarePlanner` remains hardcoded/scaffolded | `src/distributed/mod.zig` |

### High — Error Handling / Thread Safety / Leaks

| Finding | File:Line |
|---|---|
| Persistent-state load/save failures can be ignored | `src/distributed/raft_persistent.zig` |
| 2PC/network errors are sometimes discarded or reported successful after retries | `src/distributed/twophase.zig` |
| Parse errors can return empty results | `src/distributed/query_coordinator.zig` |
| Global transport/metrics state needs synchronization audit | `src/distributed/twophase.zig`; `src/distributed/query_coordinator.zig` |
| Replica and affected-shard slices can leak on failure paths | `src/distributed/cluster.zig` |

### Medium / Low

| Finding | File:Line |
|---|---|
| Oversized distributed modules exceed local 800-line guidance. | `federation.zig`, `twophase.zig`, `sharding.zig`, `enhanced_query_coordinator.zig`, `cluster.zig` |
| Competing coordinator/Raft/persistence abstractions remain. | `src/distributed/` |
| 11 of 20 distributed files had zero inline tests in the source audit. | `src/distributed/` |
