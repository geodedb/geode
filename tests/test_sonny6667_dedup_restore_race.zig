// SONNY-6667: the Raft idempotency table and a node's shutdown under a
// snapshot restore.
//
// A follower restores the leader's snapshot on its restore thread, without
// `inner_mutex` (SONNY-6636), and the restore replaces the process's
// idempotency-key table (`IdempotencyDedup.replaceFrom`), which apply
// (`record` / `lookup`) and the snapshot thread (`serialize`) use too.
// Under load test-sonny6633-snapshot-wire panicked "incorrect alignment" in
// that table's hash map from the restore thread: the table had been freed
// while the thread still ran. Two causes:
//
//   * nothing serialised the table: apply, restore and serialize each
//     touched it under whatever lock their caller held, or none;
//   * `ClusterCoordinator.deinit` freed the table (and the applied
//     configuration and 2PC coordinator, the other apply targets) before
//     `RaftNode.deinit` joined the restore and snapshot threads.
//
// 1. Appliers record and look up keys while restorers replace and
//    serialize the table, with one spinning thread per CPU, under
//    std.testing.allocator (which reports any leak, double free or use of
//    freed memory).
// 2. Three cluster coordinators in one process over real QUIC (as
//    test-sonny6636-snapshot-over-quic): node 3 starts behind the leader's
//    compacted log and is shut down (`ClusterCoordinator.deinit`) while its
//    restore thread runs, under CPU load.
//
// CANARY: REQ=REQ-SONNY-6667-DEDUP-RESTORE-RACE; FEATURE="DistributedCluster"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6667_dedup_restore_race.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const graph_store = geode.graph_store;
const raft_consensus = geode.distributed.raft_consensus;
const cr = geode.distributed.cluster_replication;
const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const snapshot_manager = geode.distributed.raft_snapshot_manager;
const graph_store_adapter = geode.graph_storage_adapter;
const test_ports = @import("test_ports.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const token = "test-sonny6667-dedup-restore-race";
const ips = [_][]const u8{ "127.0.0.97", "127.0.0.98", "127.0.0.99" };
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

/// One spinning thread per CPU, until stopped.
const Load = struct {
    stop: std.atomic.Value(bool) = .init(false),
    threads: [64]std.Thread = undefined,
    n: usize = 0,

    fn spin(self: *Load) void {
        var x: u64 = 0;
        while (!self.stop.load(.monotonic)) {
            x +%= 1;
            std.mem.doNotOptimizeAway(x);
        }
    }

    fn start(self: *Load) !void {
        const cpus = @min(std.Thread.getCpuCount() catch 4, self.threads.len);
        while (self.n < cpus) : (self.n += 1) self.threads[self.n] = try std.Thread.spawn(.{}, spin, .{self});
    }

    fn finish(self: *Load) void {
        self.stop.store(true, .release);
        for (self.threads[0..self.n]) |t| t.join();
        self.n = 0;
    }
};

const Race = struct {
    dedup: *cr.IdempotencyDedup,
    table: []const u8,
    until_ms: i64,
    failed: std.atomic.Value(bool) = .init(false),
    applied: std.atomic.Value(u64) = .init(0),
    restored: std.atomic.Value(u64) = .init(0),

    fn apply(self: *Race, id: usize) void {
        var i: u64 = 0;
        var buf: [48]u8 = undefined;
        while (nowMillis() < self.until_ms) : (i += 1) {
            const key = std.fmt.bufPrint(&buf, "apply-{d}-{d}", .{ id, i }) catch unreachable;
            self.dedup.record(key, i + 1) catch {
                self.failed.store(true, .release);
                return;
            };
            _ = self.dedup.lookup(key);
            _ = self.dedup.lookup("snap-key-7");
            _ = self.applied.fetchAdd(1, .monotonic);
        }
    }

    fn restore(self: *Race) void {
        const a = std.testing.allocator;
        while (nowMillis() < self.until_ms) {
            self.dedup.replaceFrom(self.table) catch {
                self.failed.store(true, .release);
                return;
            };
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(a);
            self.dedup.serialize(&out, a) catch {
                self.failed.store(true, .release);
                return;
            };
            _ = self.restored.fetchAdd(1, .monotonic);
        }
    }
};

test "SONNY-6667: the idempotency table takes restores racing applies and serializes under CPU load" {
    const a = std.testing.allocator;
    // The table a snapshot carries.
    var src = cr.IdempotencyDedup.init(a);
    defer src.deinit();
    var buf: [32]u8 = undefined;
    for (0..500) |k| try src.record(try std.fmt.bufPrint(&buf, "snap-key-{d}", .{k}), k + 1);
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(a);
    try src.serialize(&table, a);

    var dedup = cr.IdempotencyDedup.init(a);
    defer dedup.deinit();
    var load: Load = .{};
    try load.start();
    defer load.finish();
    var race: Race = .{ .dedup = &dedup, .table = table.items, .until_ms = nowMillis() + 2000 };
    var threads: [6]std.Thread = undefined;
    for (threads[0..4], 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Race.apply, .{ &race, id });
    for (threads[4..6]) |*t| t.* = try std.Thread.spawn(.{}, Race.restore, .{&race});
    for (threads) |t| t.join();
    std.debug.print("SONNY-6667: {d} applies and {d} restores raced on one table ({d} spinning threads)\n", .{ race.applied.load(.acquire), race.restored.load(.acquire), load.n });
    try std.testing.expect(!race.failed.load(.acquire));
    try std.testing.expect(race.applied.load(.acquire) > 0 and race.restored.load(.acquire) > 0);
    // A last restore leaves exactly the snapshot's table.
    try dedup.replaceFrom(table.items);
    try std.testing.expectEqual(@as(?u64, 8), dedup.lookup("snap-key-7"));
    try std.testing.expectEqual(@as(?u64, null), dedup.lookup("apply-0-0"));
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
        .cluster_name = "test-sonny6667",
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

/// The node's restore thread is running (`RaftNode.restore_state`:
/// 1 = running).
fn restoring(c: *ClusterCoordinator) bool {
    return c.raft.restore_state.load(.acquire) == 1;
}

test "SONNY-6667: a coordinator shut down while its restore thread runs frees nothing the thread still uses" {
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
    raft_consensus.useRealQuicInTests(true);
    defer raft_consensus.useRealQuicInTests(false);
    _ = unsetenv("GEODE_DATA_DIR");
    graph_store.deinitGlobalStore();
    defer graph_store.setDataDirOverride(a, null);

    // The leader's store and its durable snapshot, carrying an idempotency
    // table near its cap: a restore parses it, then replaces the follower's
    // table with it, which takes a while.
    const leader_dir = try std.fmt.allocPrint(a, "{s}/leader", .{dir});
    defer a.free(leader_dir);
    {
        const leader_store = try graph_store.initGlobalStore(a, leader_dir);
        defer {
            geode.execution.cleanupCatalogInstance();
            graph_store.deinitGlobalStore();
        }
        try leader_store.loadFromFile();
        for (0..3000) |_| _ = try leader_store.createNode(&.{"Snap6667"});
    }
    var leader_dedup = cr.IdempotencyDedup.init(a);
    defer leader_dedup.deinit();
    var buf: [32]u8 = undefined;
    for (0..60_000) |k| try leader_dedup.record(try std.fmt.bufPrint(&buf, "stmt-6667-{d}", .{k}), k + 1);
    const payload = blk: {
        const ad = try graph_store_adapter.StorageAdapter.init(a, leader_dir, .{ .data_dir = leader_dir });
        defer ad.deinit();
        break :blk try snapshot_manager.encodeDurableSnapshot(a, ad, &leader_dedup);
    };
    defer a.free(payload);

    const follower_dir = try std.fmt.allocPrint(a, "{s}/follower", .{dir});
    defer a.free(follower_dir);
    const store = try graph_store.initGlobalStore(a, follower_dir);
    defer {
        geode.execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }
    try store.loadFromFile();

    for (&ports, 0..) |*p, i| p.* = try test_ports.freeUdpPortExcept(ports[0..i]);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var nodes: [2]*ClusterCoordinator = undefined;
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
    const two: []const *ClusterCoordinator = nodes[0..2];
    try waitUntil(nowMillis() + 30_000, two, hasLeader);
    const leader = leaderOf(two).?;
    var last: u64 = 0;
    for (0..5) |_| last = try leader.proposeWrite(.{ .write = "sonny6667" });
    for (two) |c| try waitUntil(nowMillis() + 30_000, Applied{ .c = c, .index = last }, Applied.done);
    // Both compact behind the snapshot, so whichever leads must send it.
    for (two) |c| {
        c.raft.inner_mutex.lockUncancelable(io);
        defer c.raft.inner_mutex.unlock(io);
        try c.raft.inner.reportSnapshot(payload);
    }

    // Node 3 starts behind it and is shut down, under CPU load, as soon as
    // its restore thread runs.
    const third = try initNode(a, arena.allocator(), 3, dir);
    var third_live = true;
    defer if (third_live) {
        third.deinit();
        a.destroy(third);
    };
    try third.start();
    const deadline = nowMillis() + 60_000;
    while (!restoring(third)) {
        if (nowMillis() > deadline) {
            std.debug.print("SONNY-6667: node 3's restore thread never ran (applied {d})\n", .{third.raft.appliedIndex()});
            return error.Timeout;
        }
        sleepMs(1);
    }
    var load: Load = .{};
    try load.start();
    defer load.finish();
    std.debug.print("SONNY-6667: node 3's restore thread is running; shutting node 3 down under {d} spinning threads\n", .{load.n});
    third_live = false;
    const t0 = nowMillis();
    third.deinit();
    a.destroy(third);
    std.debug.print("SONNY-6667: node 3 shut down in {d} ms\n", .{nowMillis() - t0});
}
