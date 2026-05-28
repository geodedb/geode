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
const graph_store = @import("geode").graph_store;

// ClusterCoordinator.init internally calls graph_store.getGlobalStore(allocator)
// which lazily-initializes a process-global GraphStore using THAT allocator.
// In a unit-test binary, every test uses std.testing.allocator -- BUT each
// test wraps it in its own DebugAllocator instance (verifying canaries).
// Without resetting the global store between tests, the second test's
// allocator detects an "Invalid free" when ClusterCoordinator.deinit chains
// back into structures originally allocated by the first test's allocator.
//
// Reset the global store at the start of every test that drives a real
// ClusterCoordinator so each test owns its store from end to end.
fn resetGlobalGraphStore() void {
    graph_store.deinitGlobalStore();
}

test "maybeStart returns null when GEODE_CLUSTER_TOKEN is absent" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null);
    try std.testing.expect(result == null);
}

test "maybeStart token-only mode: token set, no node_id, no peers -> null" {
    // GEODE_CLUSTER_TOKEN alone (without GEODE_NODE_ID and without peers) is
    // a valid client-authentication-only configuration. The token gates
    // client connections via validateClusterToken but no cluster bootstrap
    // is attempted. specs/2pc_cluster_token_required.yml relies on this.
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "abc");
    const result = try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null);
    try std.testing.expectEqual(@as(?cluster_bootstrap.Bootstrap, null), result);
}

test "maybeStart errors when peers set but node_id missing" {
    // If GEODE_PEERS is set, a cluster bootstrap IS intended; node_id
    // becomes required and its absence is a configuration error.
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "abc");
    try env.put("GEODE_PEERS", "127.0.0.1:5001");
    const result = cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null);
    try std.testing.expectError(error.MissingNodeId, result);
}

test "maybeStart errors when node_id is not a number" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "abc");
    try env.put("GEODE_NODE_ID", "not-a-number");
    const result = cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null);
    try std.testing.expectError(error.InvalidNodeId, result);
}

test "maybeStart starts a coordinator when env is complete (single node, no peers)" {
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok-single");
    try env.put("GEODE_NODE_ID", "1");
    try env.put("GEODE_CLUSTER_PORT", "14242"); // high port to avoid conflict
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    try std.testing.expectEqual(@as(u64, 1), bs.coordinator.node_id);
    try std.testing.expectEqual(@as(u16, 14242), bs.coordinator.cluster_port);
    try std.testing.expectEqualStrings("tok-single", bs.coordinator.cluster_token);
}

test "maybeStart parses 2-peer cluster from GEODE_PEERS" {
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
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
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    // ClusterCoordinator.raft.peers should have 2 entries
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}

test "maybeStart: CLI peers override GEODE_PEERS env" {
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok");
    try env.put("GEODE_NODE_ID", "10"); // see note above
    try env.put("GEODE_CLUSTER_PORT", "14246");
    try env.put("GEODE_PEERS", "127.0.0.1:9999"); // would be 1 peer
    const cli_peers = [_][]const u8{ "127.0.0.1:14247", "127.0.0.1:14248" };
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &cli_peers, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}
