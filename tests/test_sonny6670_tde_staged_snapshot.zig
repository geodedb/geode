// SONNY-6670: Raft snapshots under GEODE_TDE_KEY are written off the Raft
// node lock, like plaintext ones.
//
// The TDE-wrapped Raft storage (`raft_tde_storage.TdeRaftStorage`) had no
// staged-snapshot API, so raft fell back to keeping a snapshot in memory
// and saving it whole at commit, under geode's `inner_mutex`: sealing (AES-
// 256-GCM), writing and fsyncing all of it, for a node's own snapshots
// (`commitSnapshot`) and for one received from the leader
// (`advancePersist`). SONNY-6665 moved that I/O off the lock for plaintext
// Raft storage only.
//
// 1. A follower on TDE Raft storage installs a 64 MiB snapshot from the
//    leader (three real Raft nodes exchanging geode Raft frames) while a
//    probe thread takes its `inner_mutex` over and over. No byte of it may
//    be sealed whole (`TdeRaftStorage.saveSnapshot`, which raft calls under
//    `inner_mutex`): it goes through the staged calls. And no take may wait
//    a quarter of the election timeout, the bound
//    test-sonny6665-install-lock-hold puts on plaintext storage, unless
//    that wait is also under a quarter of the install's own time: holding
//    the lock across the seal held it for most of the install (2683 ms),
//    while a loaded CI runner stalled the probe thread itself for up to
//    389 ms of a several-second install with the lock never held long
//    (SONNY-6956).
// 2. The leader on TDE Raft storage takes a 64 MiB snapshot of its own
//    state machine, its `inner_mutex` probed the same way, same bounds.
// 3. On the storage itself: a staged snapshot is in a staged file on disk
//    and holds no plaintext; a crash between stage and commit (the staged
//    files left behind, the storage reopened) leaves the previous snapshot,
//    whole, and no staged file; committed, the new one reads back (with
//    and without the lock's reader) and the snapshot file holds no
//    plaintext either. The previous snapshot was saved in the older
//    one-record format, which still reads.
//
// CANARY: REQ=REQ-SONNY-6670-TDE-STAGED-SNAPSHOT; FEATURE="TDEFileLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6670_tde_staged_snapshot.zig; OWNER=distributed; UPDATED=2026-11-24

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const raft_consensus = geode.distributed.raft_consensus;
const raft_tde = raft_consensus.raft_tde_storage;
const raft_lib = geode.distributed.raft;
const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();
const ELECTION_TIMEOUT_MS: u64 = 1000;
const HOLD_BUDGET_NS: u64 = ELECTION_TIMEOUT_MS * std.time.ns_per_ms / 4;
const MAX_ROUNDS: usize = 20000;
const SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;
const PATTERN = "PLAINTEXT-SONNY-6670-";

fn now() u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn randomKey() [raft_tde.KEY_BYTES]u8 {
    var key: [raft_tde.KEY_BYTES]u8 = undefined;
    io.random(&key);
    return key;
}

/// `len` bytes of PATTERN, repeated.
fn patterned(a: std.mem.Allocator, len: usize) ![]u8 {
    const out = try a.alloc(u8, len);
    for (out, 0..) |*b, i| b.* = PATTERN[i % PATTERN.len];
    return out;
}

fn peersOf(comptime id: u64) [2]Peer {
    var out: [2]Peer = undefined;
    var n: usize = 0;
    inline for (1..4) |j| {
        if (j != id) {
            out[n] = .{ .id = j, .endpoint = "127.0.0.1", .port = 22990 + j, .last_contact = 0 };
            n += 1;
        }
    }
    return out;
}

const Net = struct {
    const Frame = struct { to: u64, bytes: []u8 };

    a: std.mem.Allocator,
    nodes: [3]*RaftNode = undefined,
    transports: [3]Transport = undefined,
    queue: std.ArrayList(Frame) = .empty,
    cut: [4]bool = .{false} ** 4,
    made: usize = 0,

    fn send(t: *Transport, peer: Peer, from: u64, term: u64, msg: Message) anyerror!void {
        const self: *Net = @ptrCast(@alignCast(t.send_override_ctx orelse return error.MissingCtx));
        const bytes = try raft_consensus.encodeRaftFrame(self.a, from, term, msg);
        errdefer self.a.free(bytes);
        try self.queue.append(self.a, .{ .to = peer.id, .bytes = bytes });
    }

    fn deliver(self: *Net) !void {
        var i: usize = 0;
        while (i < self.queue.items.len) : (i += 1) {
            const f = self.queue.items[i];
            defer self.a.free(f.bytes);
            var frame = try raft_consensus.decodeRaftFrame(self.a, f.bytes);
            defer frame.deinit(self.a);
            if (self.cut[frame.from] or self.cut[f.to]) continue;
            try self.nodes[f.to - 1].handleMessage(frame.from, frame.body);
        }
        self.queue.clearRetainingCapacity();
    }

    fn round(self: *Net) !void {
        for (self.nodes) |n| try n.tick();
        try self.deliver();
    }

    fn init(self: *Net, peers: *[3][2]Peer, root: []const u8, key: [raft_tde.KEY_BYTES]u8) !void {
        errdefer self.deinit();
        for (0..3) |i| {
            const dir = try std.fmt.allocPrint(self.a, "{s}/raft{d}", .{ root, i + 1 });
            defer self.a.free(dir);
            self.transports[i] = Transport.init(self.a);
            self.transports[i].send_override = send;
            self.transports[i].send_override_ctx = @ptrCast(self);
            self.nodes[i] = RaftNode.initWithStorageDirKey(self.a, i + 1, &peers[i], ELECTION_TIMEOUT_MS, dir, key) catch |err| {
                self.transports[i].deinit();
                return err;
            };
            self.made += 1;
            self.nodes[i].setTransport(&self.transports[i]);
        }
        var r: usize = 0;
        while (self.nodes[0].role() != .leader) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.Timeout;
            try self.nodes[0].tick();
            try self.deliver();
        }
    }

    fn deinit(self: *Net) void {
        for (self.queue.items) |f| self.a.free(f.bytes);
        self.queue.deinit(self.a);
        for (0..self.made) |i| {
            self.nodes[i].deinit();
            self.a.destroy(self.nodes[i]);
            self.transports[i].deinit();
        }
        self.made = 0;
    }
};

/// Takes the node's `inner_mutex` over and over and records the longest
/// wait for it.
const Probe = struct {
    node: *RaftNode,
    stop: std.atomic.Value(bool) = .init(false),
    max_wait_ns: u64 = 0,
    takes: u64 = 0,

    fn run(self: *Probe) void {
        while (!self.stop.load(.acquire)) {
            const t0 = now();
            _ = self.node.currentTerm();
            const waited = now() - t0;
            if (waited > self.max_wait_ns) self.max_wait_ns = waited;
            self.takes += 1;
            io.sleep(.fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
        }
    }
};

/// The leader's own snapshot: what its state machine copy returns.
var own_payload: []const u8 = "";

fn ownSnapshot(allocator: std.mem.Allocator, index: u64, term: u64) anyerror![]u8 {
    _ = index;
    _ = term;
    return allocator.dupe(u8, own_payload);
}

/// SONNY-6956: the snapshot was never sealed whole under `inner_mutex`
/// (none of its bytes went through `saveSnapshot` since `sealed_before`),
/// and no take of `inner_mutex` waited both a quarter of the election
/// timeout and a quarter of the snapshot's own `ns`: the seal held under the
/// lock is most of the snapshot's time, a runner stalling the probe thread
/// is not.
fn expectNotHeldAcrossSnapshot(probe: *const Probe, ns: u64, sealed_before: u64) !void {
    const sealed = raft_tde.TdeRaftStorage.whole_snapshot_bytes_sealed_total.load(.acquire) - sealed_before;
    std.debug.print("SONNY-6670: {d} bytes sealed whole under inner_mutex\n", .{sealed});
    try testing.expectEqual(@as(u64, 0), sealed);
    try testing.expect(probe.takes > 0);
    try testing.expect(probe.max_wait_ns < HOLD_BUDGET_NS or probe.max_wait_ns < ns / 4);
}

fn report(what: []const u8, ns: u64, probe: *const Probe) void {
    std.debug.print("SONNY-6670: {s}: {d} MiB under TDE in {d} ms; {d} takes of its inner_mutex meanwhile, the longest waited {d} ms (budget {d} ms)\n", .{
        what, SNAPSHOT_BYTES / (1024 * 1024), ns / std.time.ns_per_ms, probe.takes, probe.max_wait_ns / std.time.ns_per_ms, HOLD_BUDGET_NS / std.time.ns_per_ms,
    });
}

test "SONNY-6670: a follower on TDE Raft storage installs a 64 MiB snapshot without holding inner_mutex a quarter of the election timeout" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6670-tde-install");
    defer root.remove();
    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: Net = .{ .a = a };
    try net.init(&peers, root.path(), randomKey());
    defer net.deinit();
    const leader = net.nodes[0];
    const follower = net.nodes[2];

    net.cut[3] = true;
    var last: u64 = 0;
    for (0..5) |_| last = try leader.proposeCommand(.{ .write = "sonny6670" });
    var r: usize = 0;
    while (leader.appliedIndex() < last or net.nodes[1].appliedIndex() < last) : (r += 1) {
        if (r >= MAX_ROUNDS) return error.Timeout;
        try net.round();
    }
    const payload = try patterned(a, SNAPSHOT_BYTES);
    defer a.free(payload);
    const snap_index = blk: {
        leader.inner_mutex.lockUncancelable(io);
        defer leader.inner_mutex.unlock(io);
        try leader.inner.reportSnapshot(payload);
        break :blk leader.inner.log.applied;
    };

    var probe: Probe = .{ .node = follower };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    var joined = false;
    defer if (!joined) {
        probe.stop.store(true, .release);
        thread.join();
    };
    net.cut[3] = false;
    const sealed0 = raft_tde.TdeRaftStorage.whole_snapshot_bytes_sealed_total.load(.acquire);
    const t0 = now();
    r = 0;
    while (follower.snapshotIndex() < snap_index) : (r += 1) {
        if (r >= MAX_ROUNDS) return error.Timeout;
        try net.round();
    }
    const ns = now() - t0;
    probe.stop.store(true, .release);
    thread.join();
    joined = true;
    report("node 3 installed the leader's snapshot", ns, &probe);
    try expectNotHeldAcrossSnapshot(&probe, ns, sealed0);
    const held = (try follower.localSnapshotData(a)) orelse return error.NoSnapshot;
    defer a.free(held);
    try testing.expect(std.mem.eql(u8, payload, held));
}

test "SONNY-6670: a leader on TDE Raft storage takes a 64 MiB snapshot of its own without holding inner_mutex a quarter of the election timeout" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6670-tde-own");
    defer root.remove();
    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: Net = .{ .a = a };
    try net.init(&peers, root.path(), randomKey());
    defer net.deinit();
    const leader = net.nodes[0];
    const payload = try patterned(a, SNAPSHOT_BYTES);
    defer a.free(payload);
    own_payload = payload;
    defer own_payload = "";
    leader.snapshot_create_callback = &ownSnapshot;
    leader.snapshot_policy = .{ .entries = 3, .bytes = 0 };

    var probe: Probe = .{ .node = leader };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    var joined = false;
    defer if (!joined) {
        probe.stop.store(true, .release);
        thread.join();
    };
    const sealed0 = raft_tde.TdeRaftStorage.whole_snapshot_bytes_sealed_total.load(.acquire);
    const t0 = now();
    for (0..5) |_| _ = try leader.proposeCommand(.{ .write = "sonny6670" });
    var r: usize = 0;
    while (leader.stats.snapshots_taken == 0) : (r += 1) {
        if (r >= MAX_ROUNDS) return error.Timeout;
        try net.round();
        io.sleep(.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
    }
    const ns = now() - t0;
    probe.stop.store(true, .release);
    thread.join();
    joined = true;
    report("the leader took its own snapshot", ns, &probe);
    try expectNotHeldAcrossSnapshot(&probe, ns, sealed0);
    const held = (try leader.localSnapshotData(a)) orelse return error.NoSnapshot;
    defer a.free(held);
    try testing.expect(std.mem.eql(u8, payload, held));
}

/// A FileStorage on `dir` wrapped in a TdeRaftStorage under `key`.
const Opened = struct {
    tde: *raft_tde.TdeRaftStorage,

    fn open(a: std.mem.Allocator, dir: []const u8, key: [raft_tde.KEY_BYTES]u8) !Opened {
        const fs = try a.create(raft_lib.FileStorage);
        errdefer a.destroy(fs);
        fs.* = try raft_lib.FileStorage.init(a, dir);
        errdefer fs.deinit();
        const tde = try a.create(raft_tde.TdeRaftStorage);
        errdefer a.destroy(tde);
        tde.* = try raft_tde.TdeRaftStorage.adopt(a, fs, key);
        return .{ .tde = tde };
    }

    fn close(self: Opened, a: std.mem.Allocator) void {
        self.tde.deinit();
        a.destroy(self.tde);
    }
};

/// The names of the staged snapshot files in `dir`.
fn stagedFiles(a: std.mem.Allocator, dir: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| a.free(n);
        out.deinit(a);
    }
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, "snapshot.stage.")) continue;
        try out.append(a, try a.dupe(u8, e.name));
    }
    return out;
}

fn freeNames(a: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |n| a.free(n);
    names.deinit(a);
}

fn readIn(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    defer a.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 << 20));
}

fn writeIn(a: std.mem.Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

test "SONNY-6670: a TDE snapshot is staged sealed, survives a crash before its commit as the previous snapshot, and commits sealed" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6670-tde-stage");
    defer root.remove();
    const dir = root.path();
    const key = randomKey();
    const cfg: raft_lib.ClusterConfig = .{ .voters = &.{ 1, 2, 3 }, .voters_outgoing = &.{}, .is_joint = false };

    // The previous snapshot, saved whole (the one-record format).
    const old = try patterned(a, 300 * 1024 + 17);
    defer a.free(old);
    {
        const s = try Opened.open(a, dir, key);
        defer s.close(a);
        try s.tde.storage().saveSnapshot(.{ .metadata = .{ .index = 5, .term = 1, .config = cfg }, .data = old });
    }

    // A new one staged: on disk, sealed. Then a crash before its commit.
    const new = try patterned(a, 5 * 64 * 1024 + 4321);
    defer a.free(new);
    var left: std.ArrayList([]u8) = .empty;
    var left_data: std.ArrayList([]u8) = .empty;
    defer {
        freeNames(a, &left);
        for (left_data.items) |d| a.free(d);
        left_data.deinit(a);
    }
    {
        const s = try Opened.open(a, dir, key);
        defer s.close(a);
        const st = s.tde.storage();
        var staged = try st.stageSnapshot(a, .{ .metadata = .{ .index = 9, .term = 2, .config = cfg }, .data = new });
        defer st.releaseStagedSnapshot(&staged);
        try testing.expect(staged.owner != null);
        left = try stagedFiles(a, dir);
        std.debug.print("SONNY-6670: staged files {d}\n", .{left.items.len});
        try testing.expect(left.items.len > 0);
        var staged_bytes: usize = 0;
        for (left.items) |name| {
            const data = try readIn(a, dir, name);
            try left_data.append(a, data);
            staged_bytes += data.len;
            try testing.expect(std.mem.indexOf(u8, data, PATTERN) == null);
        }
        try testing.expect(staged_bytes >= new.len);
    }
    // The crash leaves the staged files behind (the release above removed
    // them; put them back as they were).
    for (left.items, left_data.items) |name, data| try writeIn(a, dir, name, data);
    {
        const s = try Opened.open(a, dir, key);
        defer s.close(a);
        const snap = (try s.tde.storage().loadSnapshot()) orelse return error.NoSnapshot;
        defer raft_lib.freeSnapshot(a, snap);
        try testing.expectEqual(@as(u64, 5), snap.metadata.index);
        try testing.expect(std.mem.eql(u8, old, snap.data));
        var after = try stagedFiles(a, dir);
        defer freeNames(a, &after);
        try testing.expectEqual(@as(usize, 0), after.items.len);

        // Staged and committed this time.
        const st = s.tde.storage();
        var staged = try st.stageSnapshot(a, .{ .metadata = .{ .index = 9, .term = 2, .config = cfg }, .data = new });
        defer st.releaseStagedSnapshot(&staged);
        try st.commitStagedSnapshot(&staged);
    }
    const s = try Opened.open(a, dir, key);
    defer s.close(a);
    const snap = (try s.tde.storage().loadSnapshot()) orelse return error.NoSnapshot;
    defer raft_lib.freeSnapshot(a, snap);
    try testing.expectEqual(@as(u64, 9), snap.metadata.index);
    try testing.expect(std.mem.eql(u8, new, snap.data));
    const unlocked = (try s.tde.loadSnapshotUnlocked()) orelse return error.NoSnapshot;
    defer raft_lib.freeSnapshot(a, unlocked);
    try testing.expect(std.mem.eql(u8, new, unlocked.data));
    const on_disk = try readIn(a, dir, "snapshot.data");
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, PATTERN) == null);
}
