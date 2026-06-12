# Distributed Module Code Quality Gap Analysis

Last updated: 2026-06-11 (GAP-0889 batch closed — see `GAP_ANALYSIS.md` and commit history; archive details live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md))

This file contains only open distributed quality gaps. The 2026-06-11 GAP-0889
batch closed the High-severity rows; what remains below are documented
residuals with honest scoping notes.

## Closed by the 2026-06-11 GAP-0889 batch (summary, for context)

- **Duplication:** `cloneBindingRow`/`freeBindingRow`/`cloneSchema` rows were
  stale — all consumers (federation.zig, query_coordinator.zig,
  enhanced_query_coordinator.zig, query_transport.zig) already delegate to
  `result_utils.zig`. `NodeRegistry` (query_transport flavor) extracted to
  `node_registry.zig`; the drift-warned inline copy in
  `test_query_transport_node_registry.zig` was deleted and the tests now drive
  the real type. The four copy-pasted offset/limit pagination blocks in
  `enhanced_query_coordinator.zig` collapsed into one `applyPaginationWindow`.
- **Dead code:** `federation_root.zig` was already removed (`35eaaad9`).
  The fake-OK `handleLeaveCluster`/`handleReplicateData`/`handleFailoverRequest`
  stubs were removed from cluster.zig (zero callers; the live RPC path
  `handleClusterRpcLocal` rejects those message types with ERR).
  `raft.zig handleMessage` now fails loud (`error.WireDeserializationNotWired`).
- **Dual Raft wrappers:** documented, not consolidated — `raft.zig` is a thin
  string-node-ID compatibility shim delegating to `raft_consensus.zig` (see its
  header comment); its sole consumer is `mod.zig`, which is outside the build
  graph. The production wire path is `raft_consensus.zig`.
- **Error handling:** raft committed-entry decode failures skip loudly with a
  `decode_errors` counter (no fabricated `.write`); `raft_persistent` load
  failures propagate (`error.CorruptPersistentState`); 2PC commit surfaces
  unacked COMMIT delivery (`error.CommitDeliveryIncomplete`) and logs
  undeliverable ABORTs; `query_coordinator` parse/catalog/execution failures
  propagate and a failed scatter fragment fails the query; `cluster.zig`
  replica-slice leaks fixed (three sites). Regression: `zig build test-gap0889`.

## Open Residuals

### Medium

| Finding | Detail / honest scope |
|---|---|
| Coordinator subtree is outside the build graph | `mod.zig` (and through it `query_coordinator.zig`, `enhanced_query_coordinator.zig`, `raft.zig`; plus `federation.zig`/`query_transport.zig` via those) has zero importers in the compiled graph — `src/lib.zig` exports only the raft_*/cluster*/txn_coordinator/twophase/query_planner/value_convert/principal_envelope set. These files are verified by `zig ast-check` only, and `query_transport.zig` + `enhanced_query_coordinator.zig` carry pre-existing ast-check errors at HEAD (unused capture / never-mutated var / `self` shadowing / undeclared `cluster_auth`); they also still use pre-0.16 managed-ArrayList APIs and would not compile if added to the graph today. Joining the graph (or deleting the subtree) is the real fix; tracked under the distributed consolidation plan. |
| `ShardInfo` same-name divergence | The old "5 copies" claim is inaccurate: there are 3 *divergent* shapes sharing the name (`mod.zig` string-keyed, `cluster.zig` u64 + KeyRange + size/record counts, `query_coordinator.zig` string-id + u64 range), plus `sharding.zig`'s richer `ShardManager.Shard` and `enhanced_query_coordinator.zig` aliasing `merge_strategies.ShardInfo`. This is semantic divergence, not mechanical duplication — consolidation requires reconciling the shard model, deferred to the consolidation plan. |
| Pre-A3e 2PC write scaffolding in cluster.zig | `handleClusterMessage` → `handleShardQuery` (2PC prepare/decide over shards) has no live caller — the wired path is `handleClusterRpcOnStream` → `handleClusterRpcLocal`, which executes READ only and ERRs on everything else. `handleJoinCluster` likewise has no caller on the wire path (bootstrap is static-config). Retained pending task S2 (cross-shard read forwarding integration) and the 2PC wire-up; `forwardToShard` itself IS live (testing_surface + `tests/test_cluster_forward_to_shard.zig`). |
| 2PC `checkTimeouts` has no production caller (deliberate) | `txn_coordinator.checkTimeouts` must NOT be wired as-is: the TxnCoordinator is a replicated state machine, and a wall-clock timeout abort taken locally would be replica-divergent (one replica aborts an xid another then commits via a late `txn_decide`). The correct design is leader-detected timeout proposed through raft as `txn_decide{commit=false}` so every replica aborts at the same log position. Documented at the function site; implementing raft-proposed timeout decides is future work. |
| Global transport/metrics synchronization audit | Not performed this round. `twophase.zig` global transport state and `query_coordinator.zig` metrics counters still need a systematic cross-thread audit (the timeseries-style mutex/lock-ordering treatment). |
| `PartitionAwarePlanner` hardcoded/scaffolded | In `mod.zig` — outside the build graph (see first row); inherits that row's resolution. |

### Low

| Finding | Detail / honest scope |
|---|---|
| Oversized distributed modules exceed local 800-line guidance | `federation.zig`, `twophase.zig`, `sharding.zig`, `enhanced_query_coordinator.zig`, `cluster.zig` — unchanged this round; splitting belongs to the consolidation plan, not a quality batch. |
| Competing coordinator/Raft/persistence abstractions | `raft.zig` vs `raft_consensus.zig` is now documented (compat shim); the broader coordinator duplication (QueryCoordinator vs EnhancedQueryCoordinator vs ClusterCoordinator query path) remains and is the consolidation plan's subject. |
| Inline-test coverage in out-of-graph files | Every distributed file IN the build graph now has inline tests or a dedicated standalone test file (`node_registry.zig` inline + `test_query_transport_node_registry.zig`, `raft_log_storage.zig` via `tests/test_raft_log_storage.zig`, `principal_envelope.zig` via the GPS wire tests). The one remaining zero-inline-test source file is `query_transport.zig`, which is outside the build graph (its extracted NodeRegistry is covered); it cannot be compile-tested until the subtree joins the graph. |
