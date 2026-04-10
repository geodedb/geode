# Distributed Module Gap Analysis

**Date:** 2026-04-01
**Scope:** `src/distributed/` (20 files, 12,837 lines, 90 CANARY tokens)

## CANARY Status Summary

| Status | Count | Percentage |
|--------|-------|-----------|
| TESTED | 55 | 61.1% |
| EXEMPT | 34 | 37.8% |
| BENCHED | 1 | 1.1% |

## Open Gaps (21 total)

### Critical (0)

All critical gaps have been closed. See Closed Gaps section below.

### High (2)

| Gap-ID | Category | Description | File:Line | Req ID |
|--------|----------|-------------|-----------|--------|
| GAP-D005 | Incomplete Impl | union_distinct merge is a placeholder (calls union_all) | `federation.zig:856-859` | -- |
| GAP-D006 | Incomplete Impl | hash_aggregate merge has hardcoded sum=0 | `enhanced_query_coordinator.zig:465-523` | -- |
| ~~GAP-D007~~ | ~~Missing Impl~~ | ~~query_planner.zig entirely scaffolded~~ — **CLOSED (2026-04-10)**: 6 stub methods replaced with real implementations (planExecutionPhases, addPropertyFilters, addEdgePattern, addFilterCondition, addFunctionFilter, analyzeDataFlow). 12 new tests in `tests/test_distributed_query_planner.zig`. | `query_planner.zig` | -- |
| GAP-D008 | Incomplete Impl | Raft PersistentStorage methods all return null/no-op | `raft_consensus.zig:222-245` | REQ-GQL-RAFT-PERSIST |

### Medium (11)

| Gap-ID | Category | Description | File:Line | Req ID |
|--------|----------|-------------|-----------|--------|
| GAP-D009 | Phantom Test | `e2e_cluster_replication` does not exist | `cluster.zig:950` | REQ-GQL-020 |
| GAP-D010 | Phantom Test | `TestCANARY_DistributedQuery` does not exist | `cluster.zig:1010` | REQ-GQL-2PC-005 |
| GAP-D011 | Phantom Test | `TestCANARY_REQ_DIST_QUERY_COORD_001` does not exist | `enhanced_query_coordinator.zig:1` | REQ-DIST-QUERY-COORD-001 |
| GAP-D012 | Phantom Test | `TestCANARY_REQ_DIST_QUERY_COORD_002` does not exist | `enhanced_query_coordinator.zig:2` | REQ-DIST-QUERY-COORD-002 |
| GAP-D013 | Phantom Test | `TestCANARY_REQ_DIST_QUERY_TRANSPORT_001` does not exist | `query_transport.zig:1` | REQ-DIST-QUERY-TRANSPORT-001 |
| GAP-D014 | Phantom Test | `TestCANARY_REQ_DIST_QUERY_TRANSPORT_002` does not exist | `query_transport.zig:2` | REQ-DIST-QUERY-TRANSPORT-002 |
| GAP-D015 | Phantom Test | 20+ tokens reference missing geodetestlab specs | multiple | multiple |
| GAP-D016 | Missing Test | `e2e_raft_persist_snapshot_membership` is print-only sham | `raft_persistent.zig:4` | REQ-GQL-RAFT-PERSIST |
| GAP-D017 | Missing Test | `e2e_distributed_cluster` commented out in all_tests.zig | `network_transport.zig:6` | REQ-GQL-041 |
| GAP-D028 | Missing Test | No unit tests for twophase Transaction prepare/commit/abort | `twophase.zig:399-630` | REQ-DIST-2PC-001/002/003 |
| ~~GAP-D027~~ | ~~Missing CANARY~~ | ~~query_planner.zig has 0 CANARY tokens~~ — **CLOSED (2026-04-10)**: 6 CANARY markers added (REQ-DIST-PLAN-010 through REQ-DIST-PLAN-015) | `query_planner.zig` | -- |

### Low (8) -- Status Mismatches

| Gap-ID | Description | File:Line | Current | Should Be |
|--------|-------------|-----------|---------|-----------|
| GAP-D018 | Cluster getReplicationLag has real impl | `cluster.zig:742` | EXEMPT | IMPL |
| GAP-D019 | Cluster rebalanceShards has analysis impl | `cluster.zig:839` | EXEMPT | IMPL |
| GAP-D020 | Cluster serializeClusterTopology is complete | `cluster.zig:884` | EXEMPT | IMPL |
| GAP-D021 | 2PC prepare/commit/abort have real impls | `twophase.zig:498,548,589` | EXEMPT | IMPL |
| GAP-D022 | 2PC participant storage ops implemented | `twophase.zig:819,989,1022` | EXEMPT | IMPL |
| GAP-D023 | 2PC transport and TLS implemented | `twophase.zig:80,152,204,318,327` | EXEMPT | IMPL |
| GAP-D024 | Distributed query federation has real code | `query_coordinator.zig:114,835,863` | EXEMPT | IMPL |
| GAP-D025 | Sharding operations partially implemented | `sharding.zig:586-796` | EXEMPT | IMPL |

## Untracked Features (no CANARY tokens)

| Feature | File:Line | Implementation State |
|---------|-----------|---------------------|
| Query result caching | `federation.zig:1126`, `enhanced_query_coordinator.zig:1020` | Implemented, no bounds |
| Streaming query execution | `query_transport.zig:133` | Implemented |
| Connection retry/backoff | `twophase.zig:565`, `query_transport.zig:25` | Implemented |
| Health monitoring | `cluster.zig:705-740` | Implemented |
| Distributed cost model | `query_planner.zig:9` | Scaffolded (stubs) |
| Partition-aware planning | `mod.zig:29-147` | Scaffolded (hardcoded) |
| Value conversion | `value_convert.zig` | Implemented, 0 tests |
| Distributed metrics | `mod.zig:299-323` | Implemented |

## Closed Gaps

### Critical (Closed 2026-04-10)

| Gap-ID | Category | Description | File:Line | Req ID | Resolution |
|--------|----------|-------------|-----------|--------|------------|
| GAP-D001 | Incomplete Impl | Cluster replication sends empty 0-byte snapshots | `cluster.zig:707-729` | REQ-DIST-CLUSTER-002 | Real snapshot serialization via `serializeSnapshot` now produces actual shard data |
| GAP-D002 | Incomplete Impl | Raft handleMessage zeroes out AppendEntries/InstallSnapshot fields | `raft_consensus.zig:886-960` | -- | Proper field conversion with serialized entries in handleMessage |
| GAP-D003 | Incomplete Impl | Raft proposeCommand discards Command, proposes empty bytes | `raft_consensus.zig:962-972` | -- | `serializeCommand` with tag-prefixed format now preserves command data |
| GAP-D026 | Incomplete Impl | Raft protobuf conversion drops entries and snapshot data at wire level | `raft_consensus.zig:418-468` | -- | Proper protobuf conversion with `messageToProto`/`protoToMessage` |

### High (Closed 2026-04-10)

| Gap-ID | Category | Description | File:Line | Req ID | Resolution |
|--------|----------|-------------|-----------|--------|------------|
| GAP-D004 | Incomplete Impl | 2PC applyUndoOperation is a no-op -- abort does not roll back | `twophase.zig:491-550` | REQ-DIST-2PC-003 | Real undo implemented: CREATE->deleteNode, UPDATE->restore pre-image, DELETE->re-create |

---

*Generated 2026-04-01, updated 2026-04-10*
