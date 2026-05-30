// CANARY: REQ=REQ-DIST-CLUSTER-CONFIG-001; FEATURE="DistributedClusterCoordinator"; ASPECT=ConfigBootstrap; STATUS=TESTED; TEST=tests/test_cluster_coordinator_config.zig; OWNER=distributed; UPDATED=2026-05-25
// Unit tests for the new cluster-bootstrap fields on ClusterCoordinator.Config
// (Tasks A3, A3b, A3c of the 2026-05-25 distributed cluster testing plan).
//
// These tests verify:
//   * `Config` carries listen_address, cluster_port, cluster_token,
//     cluster_name, and max_connections with sane defaults.
//   * `ClusterCoordinator.init` copies the cluster_port and listen_address
//     into top-level coordinator state so networkLoop can read them without
//     re-touching the Config.
//   * cluster_token is stored by reference (caller owns the lifetime).
//
// Why no `deinit()`: ClusterCoordinator.init() creates a heavyweight RaftNode
// + graph_store + nonce tracker. The matching deinit() calls stop(), which
// joins thread pools and tears down a global GraphStore — both of which are
// global-state-sensitive operations that other tests in the suite mutate.
// For these field-copy assertions we leak the coordinator's owned resources
// inside an arena allocator so the parent test process reclaims them on exit.
// That keeps these tests focused on the *new* Config wiring without
// entangling them in the existing lifecycle scaffolding.

const std = @import("std");
const geode = @import("geode");
const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;

test "Config has the new cluster bootstrap fields with defaults" {
    const cfg = ClusterCoordinator.Config{ .peers = &.{} };
    try std.testing.expectEqualStrings("0.0.0.0", cfg.listen_address);
    try std.testing.expectEqual(@as(u16, 4242), cfg.cluster_port);
    try std.testing.expectEqualStrings("", cfg.cluster_token);
    try std.testing.expectEqualStrings("geode-cluster", cfg.cluster_name);
    try std.testing.expectEqual(@as(u32, 256), cfg.max_connections);
}

test "init copies cluster_port and listen_address into ClusterCoordinator state" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = ClusterCoordinator.Config{
        .peers = &.{},
        .listen_address = "127.0.0.1",
        .cluster_port = 5555,
        .cluster_token = "secret",
        .cluster_name = "test-cluster",
    };
    var coord = try ClusterCoordinator.init(a, 7, cfg);
    // NOTE: see file-level comment — we intentionally do not call
    // coord.deinit() here.  The arena above is the safety net.
    _ = &coord;
    try std.testing.expectEqualStrings("127.0.0.1", coord.listen_address);
    try std.testing.expectEqual(@as(u16, 5555), coord.cluster_port);
    try std.testing.expectEqual(@as(u64, 7), coord.node_id);
}

test "init with cluster_token stores token reference (not deep copy)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const token_literal: []const u8 = "test-token-123";
    const cfg = ClusterCoordinator.Config{
        .peers = &.{},
        .cluster_token = token_literal,
    };
    // node_id must be > 0 (the underlying raft library rejects id==0 as
    // InvalidId — single-node test config still needs a valid identity).
    var coord = try ClusterCoordinator.init(a, 1, cfg);
    _ = &coord;
    try std.testing.expectEqualStrings("test-token-123", coord.cluster_token);
    // Reference identity: the coordinator should be pointing at the exact
    // bytes we passed in, not a heap copy.
    try std.testing.expectEqual(token_literal.ptr, coord.cluster_token.ptr);
}

test "init copies cluster_name and max_connections from Config" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = ClusterCoordinator.Config{
        .peers = &.{},
        .cluster_name = "prod-east",
        .max_connections = 1024,
    };
    var coord = try ClusterCoordinator.init(a, 1, cfg);
    _ = &coord;
    try std.testing.expectEqualStrings("prod-east", coord.cluster_name);
    try std.testing.expectEqual(@as(u32, 1024), coord.max_connections);
}

test "init rejects node_id 0 as InvalidId and leaks nothing" {
    // The bundled raft library reserves id 0 as the invalid sentinel
    // (raft node.zig: `if (self.id == 0) return ConfigError.InvalidId`).
    // ClusterCoordinator.init must surface that as error.InvalidId AND free
    // everything it allocated before the failure: the resolvePeers slice, the
    // duped peer endpoints, and the RaftNode wrapper. Before the errdefer
    // fixes in cluster.zig/raft_consensus.zig these leaked on every rejected
    // cluster config, which the DebugAllocator reported and which aborted
    // geodetestlab cluster startup ("Server exited unexpectedly with code 1").
    //
    // Using std.testing.allocator (not an arena) is the whole point: it fails
    // the test if any of those allocations are not reclaimed on the error path.
    const a = std.testing.allocator;
    const peers = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 5000 },
    };
    const cfg = ClusterCoordinator.Config{
        .peers = &peers,
        .cluster_token = "test",
    };
    try std.testing.expectError(error.InvalidId, ClusterCoordinator.init(a, 0, cfg));
}
