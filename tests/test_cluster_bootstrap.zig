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
const builtin = @import("builtin");
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

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// A coordinator start opens the intra-cluster QUIC listener, which self-signs
// the missing test certificate only in dev posture. A release build refuses
// that (SONNY-2394) unless the operator opts in, so these tests opt in for the
// duration of the start and restore the environment afterwards (SONNY-6886).
const autogen_env = "GEODE_TLS_AUTOGENERATE_CERT";

fn allowSelfSignedCert() bool {
    if (builtin.mode == .Debug or std.c.getenv(autogen_env) != null) return false;
    _ = setenv(autogen_env, "1", 1);
    return true;
}

fn restoreCertPosture(set: bool) void {
    if (set) _ = unsetenv(autogen_env);
}

test "maybeStart returns null when GEODE_CLUSTER_TOKEN is absent" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null);
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
    const result = try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null);
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
    const result = cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null);
    try std.testing.expectError(error.MissingNodeId, result);
}

test "maybeStart errors when node_id is not a number" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "abc");
    try env.put("GEODE_NODE_ID", "not-a-number");
    const result = cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null);
    try std.testing.expectError(error.InvalidNodeId, result);
}

test "maybeStart starts a coordinator when env is complete (single node, no peers)" {
    // CI doesn't pre-generate TLS certs in the test working directory and
    // QuicTransport refuses to start without them. Skip in CI (the cluster
    // boot path is exercised end-to-end via the harness specs instead).
    if (std.c.getenv("CI") != null) return error.SkipZigTest;
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
    const opted_in = allowSelfSignedCert();
    defer restoreCertPosture(opted_in);
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok-single");
    try env.put("GEODE_NODE_ID", "1");
    try env.put("GEODE_CLUSTER_PORT", "14242"); // high port to avoid conflict
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    try std.testing.expectEqual(@as(u64, 1), bs.coordinator.node_id);
    try std.testing.expectEqual(@as(u16, 14242), bs.coordinator.cluster_port);
    try std.testing.expectEqualStrings("tok-single", bs.coordinator.cluster_token);
}

test "maybeStart parses 2-peer cluster from GEODE_PEERS" {
    if (std.c.getenv("CI") != null) return error.SkipZigTest;
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
    const opted_in = allowSelfSignedCert();
    defer restoreCertPosture(opted_in);
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
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    // ClusterCoordinator.raft.peers should have 2 entries
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}

test "maybeStart: CLI peers override GEODE_PEERS env" {
    if (std.c.getenv("CI") != null) return error.SkipZigTest;
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
    const opted_in = allowSelfSignedCert();
    defer restoreCertPosture(opted_in);
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok");
    try env.put("GEODE_NODE_ID", "10"); // see note above
    try env.put("GEODE_CLUSTER_PORT", "14246");
    try env.put("GEODE_PEERS", "127.0.0.1:9999"); // would be 1 peer
    const cli_peers = [_][]const u8{ "127.0.0.1:14247", "127.0.0.1:14248" };
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &cli_peers, null, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}

// ----------------------------------------------------------------------
// GAP-0838 Bug B: auto-derive node_id from $HOSTNAME so a k8s StatefulSet
// elects a leader without a hand-set GEODE_NODE_ID. Pure-helper unit tests.
// See docs/superpowers/plans/2026-06-03-cluster-election-autoderive-node-id.md
// ----------------------------------------------------------------------

test "resolveNodeId: hostname match with no explicit id derives the position" {
    const r = cluster_bootstrap.resolveNodeId(null, 2).?;
    try std.testing.expectEqual(@as(u64, 2), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.derived_from_hostname, r.source);
}

test "resolveNodeId: explicit id that agrees with hostname is env_explicit" {
    const r = cluster_bootstrap.resolveNodeId(2, 2).?;
    try std.testing.expectEqual(@as(u64, 2), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.env_explicit, r.source);
}

test "resolveNodeId: explicit id that disagrees with hostname is corrected to the hostname position" {
    // THE BUG: GEODE_NODE_ID=1 on the geode-1 pod (position 2). Hostname wins.
    const r = cluster_bootstrap.resolveNodeId(1, 2).?;
    try std.testing.expectEqual(@as(u64, 2), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.env_corrected_by_hostname, r.source);
}

test "resolveNodeId: no hostname match falls back to the explicit id (loopback/non-k8s)" {
    const r = cluster_bootstrap.resolveNodeId(3, null).?;
    try std.testing.expectEqual(@as(u64, 3), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.env_explicit, r.source);
}

test "resolveNodeId: neither signal present returns null (caller errors MissingNodeId)" {
    try std.testing.expectEqual(@as(?cluster_bootstrap.ResolvedNodeId, null), cluster_bootstrap.resolveNodeId(null, null));
}

test "computeSelfIdentity: k8s DNS peers match $HOSTNAME by leading label" {
    const specs = [_][]const u8{
        "geode-0.geode.geode-qa.svc.cluster.local:4242",
        "geode-1.geode.geode-qa.svc.cluster.local:4242",
        "geode-2.geode.geode-qa.svc.cluster.local:4242",
    };
    const id = cluster_bootstrap.computeSelfIdentity(&specs, "geode-1");
    try std.testing.expectEqual(@as(?usize, 2), id.self_position);
    try std.testing.expect(id.any_dns_peer);
}

test "computeSelfIdentity: loopback peers yield no hostname match and any_dns=false" {
    const specs = [_][]const u8{ "127.0.0.1:14242", "127.0.0.1:14243", "127.0.0.1:14244" };
    const id = cluster_bootstrap.computeSelfIdentity(&specs, "geode-0");
    try std.testing.expectEqual(@as(?usize, null), id.self_position);
    try std.testing.expect(!id.any_dns_peer);
}

test "computeSelfIdentity: empty hostname never matches" {
    const specs = [_][]const u8{ "geode-0.geode:4242", "geode-1.geode:4242" };
    const id = cluster_bootstrap.computeSelfIdentity(&specs, "");
    try std.testing.expectEqual(@as(?usize, null), id.self_position);
    try std.testing.expect(id.any_dns_peer);
}

test "maybeStart: derives node_id from $HOSTNAME when GEODE_NODE_ID is unset (k8s StatefulSet)" {
    // Drives a real coordinator; skip under contended CI like the sibling tests.
    if (std.c.getenv("CI") != null) return error.SkipZigTest;
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
    const opted_in = allowSelfSignedCert();
    defer restoreCertPosture(opted_in);
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok");
    try env.put("GEODE_CLUSTER_PORT", "14250");
    // The pod's hostname (StatefulSet pod name). NO GEODE_NODE_ID is set — it
    // must be auto-derived from this host's position in GEODE_PEERS.
    try env.put("HOSTNAME", "geode-0");
    // Self entry uses the pod hostname (position 1); the other two are loopback
    // so the coordinator's background connect attempts have somewhere to go.
    try env.put("GEODE_PEERS", "geode-0:14250,127.0.0.1:14251,127.0.0.1:14252");
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    // node_id derived as 1 from the $HOSTNAME match (geode-0 at position 1).
    try std.testing.expectEqual(@as(u64, 1), bs.coordinator.raft.id);
    // Self (geode-0, position 1) skipped -> 2 voter peers (ids 2 and 3).
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}

test "maybeStart: $HOSTNAME position overrides a mismatched GEODE_NODE_ID (the k8s bug)" {
    if (std.c.getenv("CI") != null) return error.SkipZigTest;
    resetGlobalGraphStore();
    defer resetGlobalGraphStore();
    const opted_in = allowSelfSignedCert();
    defer restoreCertPosture(opted_in);
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok");
    try env.put("GEODE_CLUSTER_PORT", "14253");
    try env.put("HOSTNAME", "geode-1"); // pod is geode-1 -> position 2
    try env.put("GEODE_NODE_ID", "1"); // MISCONFIGURED (the silent-hang bug)
    try env.put("GEODE_PEERS", "127.0.0.1:14254,geode-1:14253,127.0.0.1:14255");
    var bs = (try cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, null)) orelse return error.TestExpectedNonNull;
    defer bs.deinit();
    // Despite GEODE_NODE_ID=1, the hostname position (2) wins so votes are counted.
    try std.testing.expectEqual(@as(u64, 2), bs.coordinator.raft.id);
    // Self (geode-1, position 2) skipped -> 2 voter peers.
    try std.testing.expectEqual(@as(usize, 2), bs.coordinator.raft.peers.len);
}
