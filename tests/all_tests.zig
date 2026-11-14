const std = @import("std");

const geode = @import("geode");

// Only a declaration something references is analyzed, so this file compiles
// exactly the files its test block below passes to refAllDecls. SONNY-6542:
// it used to import ~90 more files as unreferenced consts (`const _x =
// @import("x.zig");`); none of them compiled and none of their tests ran.
// The ones that pass now run through `zig build test-sonny6542-revived`
// (tests/test_sonny6542_revived.zig); the rest were removed or are listed,
// with the reason, in scripts/ci/unreachable_test_sources.zig, which
// build.zig's checkTestSourcesReachable guard keeps current.

// Advanced type operators
const _advanced_types_operators = @import("advanced_types_operators.zig");

// Distributed cluster CLI flag tests (Task A1 of 2026-05-25 distributed cluster testing plan)
const _test_cli_args_cluster = @import("test_cli_args_cluster.zig");

// Distributed cluster coordinator Config tests (Tasks A3/A3b/A3c of the same plan)
const _test_cluster_coordinator_config = @import("test_cluster_coordinator_config.zig");

// Cluster bootstrap (env-var/CLI -> ClusterCoordinator) tests (Task A2 of the same plan)
const _test_cluster_bootstrap = @import("test_cluster_bootstrap.zig");

// In-process 3-node leader election smoke test (Task A5 of the same plan)
const _test_cluster_3node_election = @import("test_cluster_3node_election.zig");

// In-process 3-node propose-and-apply smoke test (Task A3d of the same plan).
// Validates the new public ClusterCoordinator API surface for tests /
// harness: proposeWrite / waitForApplied / role / currentTerm.
const _test_cluster_propose_write = @import("test_cluster_propose_write.zig");

// Cross-node read forwarding smoke test (Task A3e of the same plan).
// Verifies forwardToShard actually round-trips a cluster RPC frame
// between two ClusterCoordinators over QUIC.
const _test_cluster_forward_to_shard = @import("test_cluster_forward_to_shard.zig");

// drainReady-and-bridge dispatch test (Task A5b of the same plan)
const _test_drainready_dispatch = @import("test_drainready_dispatch.zig");

// Subprocess 3-node cluster smoke test (Task A6 of the same plan). It spawns
// this build's geode (geode_test_bin, built before this artifact compiles)
// and SKIPS only when $GEODE_SKIP_SUBPROC_CLUSTER is set.
const _test_cluster_3node_subprocess = @import("test_cluster_3node_subprocess.zig");

// ENG-3921 data-dir lock subprocess e2e.  Same binary and skip semantics as
// the 3-node test above.  The ENG-3921 UNIT lane
// (tests/test_data_dir_lock.zig) is deliberately NOT referenced here: it
// imports the named module "data_dir_lock", which only the dedicated
// `test-data-dir-lock` build step wires up (mirrors
// tests/test_admin_bootstrap_hardening.zig).
const _test_datadir_lock_subprocess = @import("test_datadir_lock_subprocess.zig");

test "aggregate: geode module loads" {
    // Basic sanity check: parse trivial query
    std.testing.refAllDecls(_advanced_types_operators);
    std.testing.refAllDecls(_test_cli_args_cluster);
    std.testing.refAllDecls(_test_cluster_coordinator_config);
    std.testing.refAllDecls(_test_cluster_bootstrap);
    std.testing.refAllDecls(_test_cluster_3node_election);
    std.testing.refAllDecls(_test_cluster_propose_write);
    std.testing.refAllDecls(_test_cluster_forward_to_shard);
    std.testing.refAllDecls(_test_drainready_dispatch);
    std.testing.refAllDecls(_test_cluster_3node_subprocess);
    std.testing.refAllDecls(_test_datadir_lock_subprocess);
    var res = try geode.parseGql("RETURN 1", std.testing.allocator);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
