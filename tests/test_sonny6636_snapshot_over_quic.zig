// SONNY-6636 (5), (1): three cluster coordinators started in one process
// exchange Raft frames over real QUIC, and a follower started behind the
// leader's compacted log catches up from the snapshot over it.
//
// Coordinators started in one test process exchanged no Raft frames (no
// leader, "peer stalled ... evicting"): in a test build the Raft
// transport's QUIC client and listener are a no-op stub unless the test
// calls `raft_consensus.useRealQuicInTests(true)` (SONNY-6456). Production
// builds always use the real client; nothing was broken in geode's wiring,
// only in how the test drove it.
//
// Three started `ClusterCoordinator`s on 127.0.0.94-96 (free UDP ports)
// (real QUIC listeners, outboxes, frame reader, `RaftNode.handleMessage`),
// Raft storage in memory, the process store durable (a data directory: the
// snapshot restores into it; the coordinators share it, one process). Nodes
// 1 and 2 elect a leader and commit entries; the leader compacts its log
// behind a durable snapshot (GRS3, `encodeDurableSnapshot`, `reportSnapshot`)
// of a leader store built and closed in a directory of its own. Node 3
// starts only then: it must install the snapshot, carried by geode's frames
// over QUIC, restore the store from it and apply the entries after it.
//
// CANARY: REQ=REQ-SONNY-6636-SNAPSHOT-OVER-QUIC; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_snapshot_over_quic.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const graph_store = geode.graph_store;
const raft_consensus = geode.distributed.raft_consensus;
const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const snapshot_manager = geode.distributed.raft_snapshot_manager;
const graph_store_adapter = geode.graph_storage_adapter;
const test_ports = @import("test_ports.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const token = "test-sonny6636-snapshot-over-quic";
const ips = [_][]const u8{ "127.0.0.94", "127.0.0.95", "127.0.0.96" };
/// Filled before any node starts (every node must know its peers' ports).
var ports: [3]u16 = undefined;
const io = std.Io.Threaded.global_single_threaded.io();

fn portOf(id: u64) u16 {
    return ports[id - 1];
}

fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    io.sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

/// `paths` keeps the certificate paths alive for the coordinator's life.
fn initNode(a: std.mem.Allocator, paths: std.mem.Allocator, id: u64, dir: []const u8) !*ClusterCoordinator {
    var peers: [2]ClusterCoordinator.PeerConfig = undefined;
    var n: usize = 0;
    for (1..4) |j| {
        if (j == id) continue;
        peers[n] = .{ .id = j, .address = ips[j - 1], .port = portOf(j) };
        n += 1;
    }
    const cert = try std.fmt.allocPrint(paths, "{s}/node{d}.crt", .{ dir, id });
    const key = try std.fmt.allocPrint(paths, "{s}/node{d}.key", .{ dir, id });
    const c = try a.create(ClusterCoordinator);
    errdefer a.destroy(c);
    c.* = try ClusterCoordinator.init(a, id, .{
        .peers = peers[0..],
        .listen_address = ips[id - 1],
        .cluster_port = portOf(id),
        .cluster_token = token,
        .cluster_name = "test-sonny6636",
        .election_timeout_ms = 1000,
        .cert_path = cert,
        .key_path = key,
    });
    return c;
}

fn waitUntil(deadline_ms: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
    while (!done(ctx)) {
        if (nowMillis() > deadline_ms) return error.Timeout;
        sleepMs(20);
    }
}

const Applied = struct {
    c: *ClusterCoordinator,
    index: u64,
    fn done(self: Applied) bool {
        return self.c.raft.appliedIndex() >= self.index;
    }
};

fn leaderOf(cs: []const *ClusterCoordinator) ?*ClusterCoordinator {
    for (cs) |c| if (c.role() == .leader) return c;
    return null;
}

fn hasLeader(cs: []const *ClusterCoordinator) bool {
    return leaderOf(cs) != null;
}

test "SONNY-6636: coordinators in one process elect over real QUIC, and a follower behind a compacted log catches up from the snapshot over it" {
    if (comptime builtin.mode != .Debug) return error.SkipZigTest; // insecure peer TLS + self-signed listeners
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);

    if (setenv("GEODE_CLUSTER_INSECURE", "1", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_INSECURE");
    if (setenv("GEODE_CLUSTER_TOKEN", token, 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_TOKEN");
    // The real QUIC client and listener (the test build's default is a stub).
    raft_consensus.useRealQuicInTests(true);
    defer raft_consensus.useRealQuicInTests(false);
    // The leader's store: built in a directory of its own and closed; its
    // durable snapshot.
    _ = unsetenv("GEODE_DATA_DIR");
    graph_store.deinitGlobalStore();
    defer graph_store.setDataDirOverride(a, null);
    const leader_dir = try std.fmt.allocPrint(a, "{s}/leader", .{dir});
    defer a.free(leader_dir);
    {
        const leader_store = try graph_store.initGlobalStore(a, leader_dir);
        defer {
            geode.execution.cleanupCatalogInstance();
            graph_store.deinitGlobalStore();
        }
        try leader_store.loadFromFile();
        for (0..3) |_| _ = try leader_store.createNode(&.{"Snap6636"});
    }
    const payload = blk: {
        const ad = try graph_store_adapter.StorageAdapter.init(a, leader_dir, .{ .data_dir = leader_dir });
        defer ad.deinit();
        break :blk try snapshot_manager.encodeDurableSnapshot(a, ad, null);
    };
    defer a.free(payload);
    // The process store: durable, without the leader's nodes.
    const follower_dir = try std.fmt.allocPrint(a, "{s}/follower", .{dir});
    defer a.free(follower_dir);
    const store = try graph_store.initGlobalStore(a, follower_dir);
    defer {
        geode.execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }
    try store.loadFromFile();
    try std.testing.expect(graph_store.getGlobalAdapter() != null);
    try std.testing.expectEqual(@as(usize, 0), store.countNodesByLabel("default", "Snap6636", null));

    for (&ports, 0..) |*p, i| p.* = try test_ports.freeUdpPortExcept(ports[0..i]);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var nodes: [3]*ClusterCoordinator = undefined;
    var made: usize = 0;
    defer for (nodes[0..made]) |c| {
        c.deinit();
        a.destroy(c);
    };
    for (0..2) |i| {
        nodes[i] = try initNode(a, arena.allocator(), i + 1, dir);
        made += 1;
        try nodes[i].start();
    }

    // Nodes 1 and 2 elect a leader over QUIC and commit entries.
    const two: []const *ClusterCoordinator = nodes[0..2];
    const elected = waitUntil(nowMillis() + 30_000, two, hasLeader);
    std.debug.print("SONNY-6636 (5): leader elected over QUIC: {}\n", .{if (elected) |_| true else |_| false});
    try elected;
    const leader = leaderOf(two).?;
    var last: u64 = 0;
    for (0..10) |_| last = try leader.proposeWrite(.{ .write = "sonny6636" });
    for (two) |c| try waitUntil(nowMillis() + 30_000, Applied{ .c = c, .index = last }, Applied.done);

    // The leader compacts its log behind its durable snapshot.
    const snap_index = blk: {
        leader.raft.inner_mutex.lockUncancelable(io);
        defer leader.raft.inner_mutex.unlock(io);
        try leader.raft.inner.reportSnapshot(payload);
        break :blk leader.raft.inner.log.applied;
    };

    // Node 3 starts behind it: only the snapshot can catch it up.
    nodes[2] = try initNode(a, arena.allocator(), 3, dir);
    made += 1;
    try nodes[2].start();
    const t0 = nowMillis();
    const caught_up = waitUntil(nowMillis() + 60_000, Applied{ .c = nodes[2], .index = snap_index }, Applied.done);
    const catch_up_ms = nowMillis() - t0;
    std.debug.print("SONNY-6636 (1): node 3 applied index {d} after {d} ms (snapshot {d}); snapshots restored {d}; stalled={}\n", .{
        nodes[2].raft.appliedIndex(), catch_up_ms, snap_index, nodes[2].raft.stats.snapshots_received, nodes[2].raft.persistStalled(),
    });
    try caught_up;
    const after = try leader.proposeWrite(.{ .write = "after-snapshot" });
    try waitUntil(nowMillis() + 30_000, Applied{ .c = nodes[2], .index = after }, Applied.done);
    try std.testing.expectEqual(@as(u64, 1), nodes[2].raft.stats.snapshots_received);
    try std.testing.expect(!nodes[2].raft.persistStalled());
    try std.testing.expectEqual(@as(usize, 3), store.countNodesByLabel("default", "Snap6636", null));
}
