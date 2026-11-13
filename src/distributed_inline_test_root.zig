// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6459 item 7 — test root for the distributed modules' inline tests
// (at src/ so their relative imports, e.g. txn_coordinator.zig's
// "../graph_store.zig", resolve; same pattern as conn_pool_diag_test_root.zig).
//
// CANARY: REQ=REQ-SONNY-6459-DISTRIBUTED-INLINE-TESTS; FEATURE="DistributedCluster"; ASPECT=InlineTestRoot; STATUS=TESTED; TEST=tests/test_sonny6459_hygiene.zig; OWNER=distributed; UPDATED=2026-11-13
//
// Zig collects inline `test` blocks only from the test root's own module, and
// most test roots import these files through the `geode` module. The inline
// tests of raft_consensus.zig, cluster.zig and cluster_auth.zig were
// collected only by the unfiltered graph_store.zig / eval.zig roots (which
// did not compile from 300eb9a94 until 12879e5d1); twophase.zig's by none.
// `zig build test-sonny6459-distributed-inline` builds this root, wired like
// the graph_store.zig test root, with filters that select those four files'
// tests. Excluded: twophase.zig's two `TwoPCCoordinator.handleMessage` tests,
// which cannot compile (protobuf 0.1.6 cannot decode TwoPhaseMessage's union
// submessages). Test-only; never linked into the shipped binary.

test {
    _ = @import("distributed/raft_consensus.zig");
    _ = @import("distributed/cluster.zig");
    _ = @import("distributed/twophase.zig");
    _ = @import("distributed/cluster_auth.zig");
}
