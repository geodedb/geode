// CANARY: REQ=REQ-GAP-0503-DIST-BOOT; FEATURE="DistributedMode"; ASPECT=ClusterBootstrap; STATUS=TESTED; TEST=tests/test_cluster_bootstrap.zig; OWNER=core; UPDATED=2026-05-25
// Unit tests for src/server/cluster_bootstrap.zig (Task A2 of the 2026-05-25
// distributed cluster testing plan).
//
// `cluster_bootstrap.maybeStart` is the glue between the (already-extended)
// `ClusterCoordinator.Config` (A3/A3b/A3c) and the geode server boot path
// (A4). These tests verify:
//   * standalone mode (no GEODE_CLUSTER_TOKEN) returns null cleanly,
//   * activation requires a parseable GEODE_NODE_ID,
//   * env-only and CLI-override paths both reach a started coordinator,
//   * CLI peers take precedence over GEODE_PEERS,
//   * peer parsing produces the right number of Raft peers.
//
// NOTE: node_id == 0 is rejected by the underlying raft library
// (InvalidId), so each test that actually starts a coordinator uses
// node_id >= 1.  Peer host:port pairs use ephemeral high ports
// (14242-14249) to avoid stepping on any real geode/test listener.

const std = @import("std");
const cluster_bootstrap = @import("cluster_bootstrap");

test "maybeStart returns null when GEODE_CLUSTER_TOKEN is absent" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try cluster_bootstrap.maybeStart(a, env, null, &.{});
    try std.testing.expect(result == null);
}

test "maybeStart errors when token set but node_id missing" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "abc");
    const result = cluster_bootstrap.maybeStart(a, env, null, &.{});
    try std.testing.expectError(error.MissingNodeId, result);
}

test "maybeStart errors when node_id is not a number" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "abc");
    try env.put("GEODE_NODE_ID", "not-a-number");
    const result = cluster_bootstrap.maybeStart(a, env, null, &.{});
    try std.testing.expectError(error.InvalidNodeId, result);
}

test "maybeStart starts a coordinator when env is complete (single node, no peers)" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok-single");
    try env.put("GEODE_NODE_ID", "1");
    try env.put("GEODE_CLUSTER_PORT", "14242"); // high port to avoid conflict
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{})) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    try std.testing.expectEqual(@as(u64, 1), bs.coordinator.node_id);
    try std.testing.expectEqual(@as(u16, 14242), bs.coordinator.cluster_port);
    try std.testing.expectEqualStrings("tok-single", bs.coordinator.cluster_token);
}

test "maybeStart parses 2-peer cluster from GEODE_PEERS" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok-multi");
    // node_id 10 is outside the position-derived peer-id range (1, 2 for a
    // 2-peer list), so neither derived peer collides with our own id and
    // raft.validate() won't trip DuplicatePeerId.
    try env.put("GEODE_NODE_ID", "10");
    try env.put("GEODE_CLUSTER_PORT", "14243");
    try env.put("GEODE_PEERS", "127.0.0.1:14244,127.0.0.1:14245");
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{})) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    // ClusterCoordinator.raft.peers should have 2 entries
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}

test "maybeStart: CLI peers override GEODE_PEERS env" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok");
    try env.put("GEODE_NODE_ID", "10"); // see note above
    try env.put("GEODE_CLUSTER_PORT", "14246");
    try env.put("GEODE_PEERS", "127.0.0.1:9999"); // would be 1 peer
    const cli_peers = [_][]const u8{ "127.0.0.1:14247", "127.0.0.1:14248" };
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &cli_peers)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}
