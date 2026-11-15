// SONNY-6617 (1): a cluster node whose Raft storage write fails recovers
// once the storage is writable again.
//
// `RaftNode.drainReady` persists each Ready with the raft library's
// `advancePersist()` before it sends the Ready's votes and replies and
// applies its committed entries (SONNY-6611). When the write failed it
// logged and returned, leaving the library's Ready un-advanced, so every
// later `ready()` answered `ReadyNotAdvanced`: the node never voted,
// acknowledged or applied again until it was restarted, even after the
// disk was writable again.
//
// The failure here is real: the node's FileStorage directory is made
// read-only, so writing the hard state (`hard_state.tmp`, then a rename)
// fails with AccessDenied. While it fails the vote must not be sent, and
// the node must take no new Raft input (stepping a message would mutate
// state the pending Ready still points into). Once the directory is
// writable again, ticks retry the write (with backoff); the vote then
// reaches the network with the hard state on disk, and the node takes
// later messages as usual.
//
// CANARY: REQ=REQ-SONNY-6617-RAFT-PERSIST-RETRY; FEATURE="Raft Consensus Persistence"; ASPECT=PersistFailureRetried; STATUS=TESTED; TEST=tests/test_sonny6617_raft_persist_failure.zig; OWNER=distributed; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;

const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();

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
    /// Granted votes in send order: (candidate term, disk hard state then).
    at_send: [8]struct { term: u64, disk: DiskHardState } = undefined,
    sends: usize = 0,

    fn send(t: *Transport, _: Peer, _: u64, _: u64, msg: Message) anyerror!void {
        const self: *Network = @ptrCast(@alignCast(t.send_override_ctx orelse return error.MissingCtx));
        switch (msg) {
            .request_vote_response => |r| if (r.vote_granted and self.sends < self.at_send.len) {
                self.at_send[self.sends] = .{ .term = r.term, .disk = readDiskHardState(self.dir) };
                self.sends += 1;
            },
            else => {},
        }
    }
};

fn chmod(path: []const u8, mode: std.posix.mode_t) !void {
    var buf: [256]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (std.c.chmod(z, mode) != 0) return error.ChmodFailed;
}

fn uniqueDir(allocator: std.mem.Allocator) ![]u8 {
    var rnd: [8]u8 = undefined;
    _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    return std.fmt.allocPrint(allocator, "/tmp/geode-sonny6617-{x}", .{std.mem.readInt(u64, &rnd, .little)});
}

fn voteRequest(term: u64, candidate: u64) geode.distributed.raft.Message {
    return .{ .request_vote = .{
        .term = term,
        .candidate_id = candidate,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
}

test "SONNY-6617 (1): a node whose Raft hard-state write fails sends nothing, then recovers when the directory is writable again" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // root ignores the directory's permissions: no write would fail.
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer {
        chmod(dir, 0o755) catch {};
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    }

    var peers = [_]Peer{
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 21172, .last_contact = 0 },
        .{ .id = 3, .endpoint = "127.0.0.1", .port = 21173, .last_contact = 0 },
    };
    var net = Network{ .dir = dir };
    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = Network.send;
    transport.send_override_ctx = @ptrCast(&net);

    var node = try RaftNode.initWithStorageDir(a, 1, &peers, 200, dir);
    defer {
        chmod(dir, 0o755) catch {};
        node.deinit();
        a.destroy(node);
    }
    node.setTransport(&transport);

    // The hard-state write of the vote for candidate 2 in term 7 fails.
    try chmod(dir, 0o555);
    try node.stepInner(2, voteRequest(7, 2));
    try std.testing.expectEqual(@as(usize, 0), net.sends);
    try std.testing.expectEqual(@as(u64, 0), readDiskHardState(dir).term);

    // Still failing: no new input is taken, nothing is sent.
    if (node.stepInner(3, voteRequest(8, 3))) |_| {
        std.debug.print("a message was stepped while the previous Ready was not persisted\n", .{});
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqualStrings("RaftStoragePersistFailed", @errorName(err));
    for (0..20) |_| try node.tick();
    try std.testing.expectEqual(@as(usize, 0), net.sends);
    try std.testing.expect(node.persistStalled());
    try std.testing.expectError(error.RaftStoragePersistFailed, node.proposeCommand(.{ .write = "x" }));

    // Writable again: a tick retries the write and the vote leaves.
    try chmod(dir, 0o755);
    var ticks: usize = 0;
    while (net.sends == 0 and ticks < 500) : (ticks += 1) try node.tick();
    if (net.sends != 1) {
        std.debug.print("after the directory was writable again and {d} ticks, {d} vote grants were sent (want 1)\n", .{ ticks, net.sends });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u64, 7), net.at_send[0].term);
    try std.testing.expectEqual(@as(u64, 7), net.at_send[0].disk.term);
    try std.testing.expectEqual(@as(?u64, 2), net.at_send[0].disk.voted_for);
    try std.testing.expect(!node.persistStalled());

    // And the node takes Raft input again: a vote in a later term.
    try node.stepInner(3, voteRequest(9, 3));
    try std.testing.expectEqual(@as(usize, 2), net.sends);
    try std.testing.expectEqual(@as(u64, 9), net.at_send[1].disk.term);
    try std.testing.expectEqual(@as(?u64, 3), net.at_send[1].disk.voted_for);
}
