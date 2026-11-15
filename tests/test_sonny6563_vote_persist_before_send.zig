// SONNY-6563: a granted vote is on disk before the reply that grants it can
// leave the node.
//
// Election safety needs at most one vote per term across a crash: if a node
// tells candidate 2 "granted" and crashes before its hard state (term,
// voted_for) is durable, it restarts with no vote for that term and can grant
// it again to candidate 3, and two candidates can each count a majority.
//
// The raft library (v0.1.22, node.zig handleRequestVote) records the vote in
// memory and hands the reply to its Transport inside `step()`; the hard state
// is written (FileStorage: temp file, fsync, rename, directory fsync) only by
// `advance()`, which the cluster's RaftNode calls from `drainReady()` after
// `step()` returns. Geode's Transport bridge (`RaftLibTransportBridge`)
// queued the reply on the per-peer outbox at once, and the outbox thread
// sends without the raft mutex, so the reply could be on the wire before the
// fsync. Since raft v0.2.0 (SONNY-6592) the library queues the reply in
// `Ready.messages`, and `drainReady` sends it after `advancePersist()`. This
// test drives the production wiring (`RaftNode.setTransport`) on a
// FileStorage directory and reads the on-disk hard state at the moment the
// reply is handed to the network (`Transport.send`, which the outbox calls;
// `send_override` is the test's network).
//
// CANARY: REQ=REQ-SONNY-6563-VOTE-PERSIST-BEFORE-SEND; FEATURE="Raft Consensus Persistence"; ASPECT=VoteDurableBeforeReply; STATUS=TESTED; TEST=tests/test_sonny6563_vote_persist_before_send.zig; OWNER=distributed; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;

const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();

/// The raft library's on-disk hard state (file_storage.zig saveHardStateImpl:
/// term u64 LE, voted_for u64 LE with maxInt = none, CRC32).
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
    /// The on-disk hard state when each granted vote reached the network.
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

fn uniqueDir(allocator: std.mem.Allocator) ![]u8 {
    var rnd: [8]u8 = undefined;
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    } else {
        std.c.arc4random_buf(&rnd, rnd.len);
    }
    return std.fmt.allocPrint(allocator, "/tmp/geode-sonny6563-{x}", .{std.mem.readInt(u64, &rnd, .little)});
}

test "SONNY-6563: the hard state recording a granted vote is on disk when the grant reaches the network" {
    const a = std.testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var peers = try a.alloc(Peer, 2);
    defer a.free(peers);
    peers[0] = .{ .id = 2, .endpoint = "127.0.0.1", .port = 21062, .last_contact = 0 };
    peers[1] = .{ .id = 3, .endpoint = "127.0.0.1", .port = 21063, .last_contact = 0 };

    var net = Network{ .dir = dir };
    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = Network.send;
    transport.send_override_ctx = @ptrCast(&net);

    var node = try RaftNode.initWithStorageDir(a, 1, peers, 200, dir);
    defer {
        node.deinit();
        a.destroy(node);
    }
    node.setTransport(&transport);

    // Term 7: candidate 2. Then term 9: candidate 3 (a new term, a new vote).
    for ([_][2]u64{ .{ 7, 2 }, .{ 9, 3 } }, 0..) |tc, i| {
        try node.stepInner(tc[1], .{ .request_vote = .{
            .term = tc[0],
            .candidate_id = tc[1],
            .last_log_index = 0,
            .last_log_term = 0,
            .pre_vote = false,
        } });
        try std.testing.expectEqual(i + 1, net.sends);
        const disk = net.at_send[i];
        if (disk.term != tc[0] or disk.voted_for != tc[1]) {
            std.debug.print("vote for {d} in term {d} reached the network while the disk held term {d}, voted_for {?d}\n", .{ tc[1], tc[0], disk.term, disk.voted_for });
        }
        try std.testing.expectEqual(tc[0], disk.term);
        try std.testing.expectEqual(@as(?u64, tc[1]), disk.voted_for);
    }
}
