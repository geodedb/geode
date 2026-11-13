// SONNY-6459 items 4, 7, 8 and 9: dead or unrun code in the distributed
// module, and docs that describe it as working.
//
//   * Item 4: `ClusterCoordinator.handleJoinCluster` and
//     `serializeClusterTopology` (src/distributed/cluster.zig) had no caller:
//     the only inbound cluster RPC dispatcher (`handleClusterRpcLocal`)
//     answers JOIN_CLUSTER with ERR, and raft frames go to raft. Zig never
//     analysed them, so neither noticed that they do not compile
//     (`nodes.append(node_info)` without an allocator,
//     `std.ArrayList(...).init`). They are removed with the helpers only
//     they used (`parseNodeInfo`, `rebalanceShards`,
//     `serializeMinimalJoinResponse`, `NodeInfoProto`, `JoinResponsePayload`,
//     the `Topology*` payloads). Membership is the static `--peers` list.
//   * Item 7: Zig collects inline tests only from the test root's own
//     module, and most test roots import `geode` as a module. The inline
//     tests of src/distributed/raft_consensus.zig, cluster.zig and
//     cluster_auth.zig are collected only by the unfiltered src/-rooted
//     roots of test-graph-store and test-gap0866, which did not compile
//     from 300eb9a94 until 12879e5d1; twophase.zig's 23 are collected by no
//     root at all. `zig build test-sonny6459-distributed-inline` runs the
//     four files' inline tests through a dedicated src/-rooted module.
//   * Item 8: nothing in production fills `cluster_state.shards`, so shard
//     forwarding, replica promotion and the replication-factor repair are
//     reachable only from tests; the docs that presented node join/leave
//     and sharded horizontal scaling as working say so now.
//   * Item 9: tests/test_groupby_having_count_distinct.zig was built by no
//     step and could not compile (it imports tests/exec.zig, tests/eval.zig
//     and tests/planner.zig, which do not exist, and calls `planQuery` /
//     `runGroupedQuery` with old signatures). It is removed;
//     `zig build test-sonny2675-grouped-having` runs HAVING count(DISTINCT)
//     end to end.
//
// CANARY: REQ=REQ-SONNY-6459-HYGIENE; FEATURE="DistributedCluster"; ASPECT=DeadJoinCodeAndUnrunInlineTests; STATUS=TESTED; TEST=tests/test_sonny6459_hygiene.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const options = @import("sonny6459_hygiene_options");
const testing = std.testing;

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs, allocator, .limited(64 << 20));
}

fn expectAbsent(allocator: std.mem.Allocator, rel: []const u8, needles: []const []const u8) !void {
    const text = try readRepoFile(allocator, rel);
    defer allocator.free(text);
    var found: usize = 0;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) {
            std.debug.print("SONNY-6459: {s} still contains \"{s}\"\n", .{ rel, needle });
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), found);
}

test "SONNY-6459 (4) cluster.zig carries no uncompilable dynamic-join or topology code" {
    try expectAbsent(testing.allocator, "src/distributed/cluster.zig", &.{
        "fn handleJoinCluster",
        "fn serializeClusterTopology",
        "fn serializeMinimalJoinResponse",
        "fn parseNodeInfo",
        "fn rebalanceShards",
        "const JoinResponsePayload",
        "const TopologyPayload",
    });
}

test "SONNY-6459 (7) the distributed modules' inline tests have a step" {
    const allocator = testing.allocator;
    const build = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build);
    try testing.expect(std.mem.indexOf(u8, build, "b.step(\"test-sonny6459-distributed-inline\"") != null);
    const root = try readRepoFile(allocator, "src/distributed_inline_test_root.zig");
    defer allocator.free(root);
    for ([_][]const u8{ "distributed/raft_consensus.zig", "distributed/cluster.zig", "distributed/twophase.zig", "distributed/cluster_auth.zig" }) |file| {
        if (std.mem.indexOf(u8, root, file) == null) {
            std.debug.print("SONNY-6459 (7): the inline-test root does not import {s}\n", .{file});
            return error.InlineTestsNotRooted;
        }
    }
}

test "SONNY-6459 (8) the docs do not present cluster join/leave or sharded scaling as working" {
    try expectAbsent(testing.allocator, "src/distributed/README.md", &.{"handles node join/leave"});
    try expectAbsent(testing.allocator, "docs/SERVER_FEATURES.md", &.{ "Shards: Tested up to 32 shards", "Replication: 3-5 replicas typical" });
}

test "SONNY-6459 (9) no test file that no step builds: test_groupby_having_count_distinct.zig is gone" {
    const allocator = testing.allocator;
    if (readRepoFile(allocator, "tests/test_groupby_having_count_distinct.zig")) |text| {
        allocator.free(text);
        std.debug.print("SONNY-6459 (9): tests/test_groupby_having_count_distinct.zig still exists and no step builds it\n", .{});
        return error.OrphanTestFile;
    } else |err| {
        try testing.expectEqual(error.FileNotFound, err);
    }
}
