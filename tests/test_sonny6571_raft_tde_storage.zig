// SONNY-6571: the cluster's Raft storage under GEODE_TDE_KEY
// (src/distributed/raft_tde_storage.zig), on the raft library's real
// FileStorage and real files:
//
// * entry and snapshot data reach the disk only sealed, and read back after
//   a reopen (a new session, a new derived key) and after more appends;
// * a sealed record is bound to its index, term and kind: one rewritten at
//   another term, or a plaintext record, fails closed;
// * a directory holding Raft state written without TDE is refused under a
//   key and left as it was; an encrypted directory is refused without the
//   key and under another key (RaftNode.initWithStorageDirKey, the path
//   ClusterCoordinator.init takes);
// * SONNY-6563 still holds: a granted vote's hard state is on disk before the
//   grant reaches the network.
//
// The end-to-end check (real `geode serve` cluster, every file under every
// node's data directory) is tests/test_sonny6571_tde_at_rest.zig.
//
// CANARY: REQ=REQ-SONNY-6571-TDE-RAFT-AT-REST; FEATURE="TDEFileLevelEncryption"; ASPECT=RaftStorageSealOpenRefuse; STATUS=TESTED; TEST=tests/test_sonny6571_raft_tde_storage.zig; OWNER=distributed; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const raft_tde = raft_consensus.raft_tde_storage;
const raft_lib = geode.distributed.raft;
const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();
const testing = std.testing;

fn randomKey() [raft_tde.KEY_BYTES]u8 {
    var key: [raft_tde.KEY_BYTES]u8 = undefined;
    io.random(&key);
    return key;
}

fn uniqueDir(allocator: std.mem.Allocator) ![]u8 {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    return std.fmt.allocPrint(allocator, "/tmp/geode-sonny6571-{x}", .{std.mem.readInt(u64, &rnd, .little)});
}

/// Fails if any file under `dir` contains `needle`.
fn expectNotOnDisk(allocator: std.mem.Allocator, dir: []const u8, needle: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var walker = try d.walk(allocator);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(64 << 20));
        defer allocator.free(bytes);
        files += 1;
        if (std.mem.indexOf(u8, bytes, needle) != null) {
            std.debug.print("plaintext '{s}' found in {s}/{s}\n", .{ needle, dir, entry.path });
            return error.PlaintextOnDisk;
        }
    }
    try testing.expect(files > 0);
}

fn readFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20));
}

fn fileExists(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch return false;
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A FileStorage on `dir` wrapped in a TdeRaftStorage under `key`.
const Opened = struct {
    tde: *raft_tde.TdeRaftStorage,

    fn open(allocator: std.mem.Allocator, dir: []const u8, key: [raft_tde.KEY_BYTES]u8) !Opened {
        const fs = try allocator.create(raft_lib.FileStorage);
        errdefer allocator.destroy(fs);
        fs.* = try raft_lib.FileStorage.init(allocator, dir);
        errdefer fs.deinit();
        const tde = try allocator.create(raft_tde.TdeRaftStorage);
        errdefer allocator.destroy(tde);
        tde.* = try raft_tde.TdeRaftStorage.adopt(allocator, fs, key);
        return .{ .tde = tde };
    }

    fn close(self: Opened, allocator: std.mem.Allocator) void {
        self.tde.deinit();
        allocator.destroy(self.tde);
    }

    fn storage(self: Opened) raft_lib.Storage {
        return self.tde.storage();
    }
};

fn freeEntries(allocator: std.mem.Allocator, ents: []raft_lib.Entry) void {
    for (ents) |e| {
        if (e.data.len > 0) allocator.free(e.data);
    }
    if (ents.len > 0) allocator.free(ents);
}

test "SONNY-6571: Raft entry and snapshot data reach the disk sealed and read back across a reopen" {
    const a = testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const key = randomKey();
    const first = "CREATE (:Sonny6571Patient {diagnosis: 'sonny6571-first-entry'})";
    const second = "CREATE (:Sonny6571Patient {diagnosis: 'sonny6571-second-entry'})";
    const snap_data = "snapshot holding sonny6571-snapshot-row";

    {
        const s = try Opened.open(a, dir, key);
        defer s.close(a);
        try s.storage().saveHardState(.{ .current_term = 3, .voted_for = 2 });
        try s.storage().appendEntries(&.{
            .{ .index = 1, .term = 3, .kind = .noop, .data = "" },
            .{ .index = 2, .term = 3, .kind = .normal, .data = first },
        });
        const got = try s.storage().entries(1, 3);
        defer freeEntries(a, got);
        try testing.expectEqual(@as(usize, 2), got.len);
        try testing.expectEqualStrings("", got[0].data);
        try testing.expectEqual(raft_lib.EntryKind.noop, got[0].kind);
        try testing.expectEqualStrings(first, got[1].data);
    }
    try testing.expect(fileExists(a, dir, raft_tde.MARKER_FILE));
    try expectNotOnDisk(a, dir, "sonny6571-first-entry");
    try expectNotOnDisk(a, dir, "Sonny6571Patient");

    // Reopen: a new session (salt, derived key, nonce counter from 0). The
    // first session's records still open; new ones are written and read.
    {
        const s = try Opened.open(a, dir, key);
        defer s.close(a);
        try testing.expectEqual(@as(u64, 3), (try s.storage().loadHardState()).current_term);
        try testing.expectEqual(@as(?u64, 2), (try s.storage().loadHardState()).voted_for);
        try s.storage().appendEntries(&.{.{ .index = 3, .term = 4, .kind = .normal, .data = second }});
        try s.storage().saveSnapshot(.{
            .metadata = .{ .index = 2, .term = 3, .config = .{ .voters = &.{ 1, 2, 3 }, .voters_outgoing = &.{}, .is_joint = false } },
            .data = snap_data,
        });
        const got = try s.storage().entries(3, 4);
        defer freeEntries(a, got);
        try testing.expectEqualStrings(second, got[0].data);
    }
    {
        const s = try Opened.open(a, dir, key);
        defer s.close(a);
        try testing.expectEqual(@as(u64, 3), try s.storage().lastIndex());
        try testing.expectEqual(@as(u64, 4), try s.storage().term(3));
        const got = try s.storage().entries(3, 4);
        defer freeEntries(a, got);
        try testing.expectEqualStrings(second, got[0].data);
        const snap = (try s.storage().loadSnapshot()).?;
        defer raft_lib.freeSnapshot(a, snap);
        try testing.expectEqualStrings(snap_data, snap.data);
        try testing.expectEqual(@as(u64, 2), snap.metadata.index);
    }
    try expectNotOnDisk(a, dir, "sonny6571-second-entry");
    try expectNotOnDisk(a, dir, "sonny6571-snapshot-row");
    try expectNotOnDisk(a, dir, "Sonny6571Patient");
}

test "SONNY-6571: a sealed record moved to another term, or a plaintext record, fails closed" {
    const a = testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const s = try Opened.open(a, dir, randomKey());
    defer s.close(a);
    try s.storage().appendEntries(&.{.{ .index = 1, .term = 1, .kind = .normal, .data = "sonny6571-bound" }});

    // The record as the FileStorage holds it, rewritten at index 1 with term 2.
    const raw = try s.tde.inner.storage().entries(1, 2);
    defer freeEntries(a, raw);
    try testing.expect(std.mem.indexOf(u8, raw[0].data, "sonny6571-bound") == null);
    try s.tde.inner.storage().appendEntries(&.{.{ .index = 1, .term = 2, .kind = .normal, .data = raw[0].data }});
    try testing.expectError(error.RaftStorageAuthenticationFailed, s.storage().entries(1, 2));

    // A plaintext record where a sealed one belongs.
    try s.tde.inner.storage().appendEntries(&.{.{ .index = 1, .term = 2, .kind = .normal, .data = "sonny6571-plain" }});
    try testing.expectError(error.RaftStorageCorrupt, s.storage().entries(1, 2));
}

test "SONNY-6571: a Raft directory written without TDE is refused under GEODE_TDE_KEY and left unchanged" {
    const a = testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var fs = try raft_lib.FileStorage.init(a, dir);
        defer fs.deinit();
        const s = fs.storage();
        try s.saveHardState(.{ .current_term = 5, .voted_for = 1 });
        try s.appendEntries(&.{.{ .index = 1, .term = 5, .kind = .normal, .data = "sonny6571-legacy-plaintext" }});
    }
    const wal_before = try readFile(a, dir, "entries.wal");
    defer a.free(wal_before);

    var peers = [_]Peer{
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 21072, .last_contact = 0 },
        .{ .id = 3, .endpoint = "127.0.0.1", .port = 21073, .last_contact = 0 },
    };
    try testing.expectError(
        error.RaftStoragePlaintextUnderTde,
        RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, randomKey()),
    );
    try testing.expect(!fileExists(a, dir, raft_tde.MARKER_FILE));
    const wal_after = try readFile(a, dir, "entries.wal");
    defer a.free(wal_after);
    try testing.expectEqualSlices(u8, wal_before, wal_after);

    // Without a key it still opens as before (plaintext, the pre-TDE path).
    const node = try RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, null);
    node.deinit();
    a.destroy(node);
}

test "SONNY-6571: an encrypted Raft directory is refused without GEODE_TDE_KEY and under another key" {
    const a = testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const key = randomKey();

    var peers = [_]Peer{
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 21074, .last_contact = 0 },
        .{ .id = 3, .endpoint = "127.0.0.1", .port = 21075, .last_contact = 0 },
    };
    {
        const node = try RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, key);
        defer {
            node.deinit();
            a.destroy(node);
        }
        try testing.expect(node.storage_backing == .tde_file);
    }
    try testing.expectError(error.RaftStorageNeedsTdeKey, RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, null));
    var other = key;
    other[0] ^= 0x01;
    try testing.expectError(error.RaftStorageTdeKeyMismatch, RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, other));
    // The right key still opens it.
    const node = try RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, key);
    node.deinit();
    a.destroy(node);
}

// SONNY-6563 under TDE: the hard state is FileStorage's, unchanged, so a
// granted vote is still on disk before the grant reaches the network.
const DiskHardState = struct { term: u64, voted_for: ?u64 };

fn readDiskHardState(dir: []const u8) DiskHardState {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/hard_state", .{dir}) catch return .{ .term = 0, .voted_for = null };
    var buf: [20]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, path, &buf) catch return .{ .term = 0, .voted_for = null };
    if (bytes.len != 20) return .{ .term = 0, .voted_for = null };
    const vf = std.mem.readInt(u64, buf[8..16], .little);
    return .{
        .term = std.mem.readInt(u64, buf[0..8], .little),
        .voted_for = if (vf == std.math.maxInt(u64)) null else vf,
    };
}

const Network = struct {
    dir: []const u8,
    at_send: [8]DiskHardState = undefined,
    sends: usize = 0,

    fn send(t: *Transport, _: Peer, _: u64, _: u64, msg: Message) anyerror!void {
        const self: *Network = @ptrCast(@alignCast(t.send_override_ctx orelse return error.MissingCtx));
        switch (msg) {
            .request_vote_response => |r| if (r.vote_granted and self.sends < self.at_send.len) {
                self.at_send[self.sends] = readDiskHardState(self.dir);
                self.sends += 1;
            },
            else => {},
        }
    }
};

test "SONNY-6571: with TDE Raft storage a granted vote is still on disk when the grant reaches the network (SONNY-6563)" {
    const a = testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var peers = [_]Peer{
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 21076, .last_contact = 0 },
        .{ .id = 3, .endpoint = "127.0.0.1", .port = 21077, .last_contact = 0 },
    };
    var net = Network{ .dir = dir };
    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = Network.send;
    transport.send_override_ctx = @ptrCast(&net);

    var node = try RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, randomKey());
    defer {
        node.deinit();
        a.destroy(node);
    }
    try testing.expect(node.storage_backing == .tde_file);
    node.setTransport(&transport);

    for ([_][2]u64{ .{ 7, 2 }, .{ 9, 3 } }, 0..) |tc, i| {
        try node.stepInner(tc[1], .{ .request_vote = .{
            .term = tc[0],
            .candidate_id = tc[1],
            .last_log_index = 0,
            .last_log_term = 0,
            .pre_vote = false,
        } });
        try testing.expectEqual(i + 1, net.sends);
        try testing.expectEqual(tc[0], net.at_send[i].term);
        try testing.expectEqual(@as(?u64, tc[1]), net.at_send[i].voted_for);
    }
}
