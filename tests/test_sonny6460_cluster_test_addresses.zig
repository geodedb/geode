// SONNY-6460 item 6: every cluster test step binds loopback addresses no
// other test uses.
//
// The aggregate `zig build test` runs its steps concurrently. The two
// subprocess cluster suites (test-cluster-steady-state and
// test-cluster-replicable-mutations) both started three `geode serve` nodes
// on 127.0.0.11-13, and test-sonny6451-health-failed-peer configured a
// coordinator on the same three. Each node binds one free port on its
// address (SONNY-6450), chosen by probing before the node binds it, so two
// suites on the same addresses could pick the same port between the probe
// and the bind, or a node of one suite could answer the other's client.
// test-sonny6453-cluster-peer-tls and test-gap0838-cluster-tls listened on
// 127.0.0.2, which four other steps also bind.
//
// This test reads every test source under tests/ and checks that each
// loopback address other than 127.0.0.1 a cluster test step names appears in
// that step's file only.
//
// CANARY: REQ=REQ-SONNY-6460-CLUSTER-TEST-ADDRESSES; FEATURE="DistributedCluster"; ASPECT=DisjointLoopbackAddresses; STATUS=TESTED; TEST=tests/test_sonny6460_cluster_test_addresses.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const options = @import("sonny6460_addresses_options");
const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The source of every cluster test step: subprocess clusters, in-process
/// coordinators and the cluster peer TLS handshakes.
const cluster_test_files = [_][]const u8{
    "tests/test_cluster_3node_steady_state.zig",
    "tests/test_cluster_replicable_mutations.zig",
    "tests/test_sonny6451_health_failed_peer.zig",
    "tests/test_sonny6451_cluster_sigterm.zig",
    "tests/test_sonny6451_raft_restarted_peer.zig",
    "tests/test_sonny6456_cluster_dead_conn_reap.zig",
    "tests/test_sonny6456_raft_real_sender.zig",
    "tests/test_sonny6456_shutdown_persistence_stop.zig",
    "tests/test_sonny6456_cluster_health_liveness.zig",
    "tests/test_sonny6453_cluster_peer_tls.zig",
    "tests/test_gap0838_cluster_tls_noloopback.zig",
};

/// Appends to `out` every distinct `127.0.0.N` (N not 1) in `src`.
fn loopbackAddresses(allocator: std.mem.Allocator, src: []const u8, out: *std.ArrayList([]const u8)) !void {
    const prefix = "127.0.0.";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, prefix)) |at| {
        pos = at + prefix.len;
        if (at > 0 and (std.ascii.isDigit(src[at - 1]) or src[at - 1] == '.')) continue;
        var end = pos;
        while (end < src.len and std.ascii.isDigit(src[end])) end += 1;
        if (end == pos or end - pos > 3) continue;
        const addr = src[at..end];
        if (std.mem.eql(u8, addr, "127.0.0.1")) continue;
        var seen = false;
        for (out.items) |have| {
            if (std.mem.eql(u8, have, addr)) seen = true;
        }
        if (!seen) try out.append(allocator, addr);
    }
}

fn containsAddress(src: []const u8, addr: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, addr)) |at| {
        pos = at + addr.len;
        const before_ok = at == 0 or !(std.ascii.isDigit(src[at - 1]) or src[at - 1] == '.');
        const after_ok = pos >= src.len or !std.ascii.isDigit(src[pos]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

test "SONNY-6460 (6): each cluster test step's loopback addresses are used by no other test" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tests_abs = try std.fs.path.join(a, &.{ options.repo_root, "tests" });
    var dir = try std.Io.Dir.cwd().openDir(io(), tests_abs, .{ .iterate = true });
    defer dir.close(io());

    const Source = struct { path: []const u8, text: []const u8 };
    var sources: std.ArrayList(Source) = .empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        // This file names the addresses it checks.
        if (std.mem.eql(u8, entry.basename, "test_sonny6460_cluster_test_addresses.zig")) continue;
        const rel = try std.fs.path.join(a, &.{ "tests", entry.path });
        const text = try dir.readFileAlloc(io(), entry.path, a, .limited(64 << 20));
        try sources.append(a, .{ .path = rel, .text = text });
    }

    var clashes: usize = 0;
    for (cluster_test_files) |owner| {
        const own = for (sources.items) |s| {
            if (std.mem.eql(u8, s.path, owner)) break s;
        } else {
            std.debug.print("cluster test file {s} not found\n", .{owner});
            return error.ClusterTestFileMissing;
        };
        var addrs: std.ArrayList([]const u8) = .empty;
        try loopbackAddresses(a, own.text, &addrs);
        try testing.expect(addrs.items.len > 0);
        for (addrs.items) |addr| {
            for (sources.items) |other| {
                if (std.mem.eql(u8, other.path, owner)) continue;
                if (!containsAddress(other.text, addr)) continue;
                std.debug.print("{s} (used by {s}) is also used by {s}\n", .{ addr, owner, other.path });
                clashes += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), clashes);
}
