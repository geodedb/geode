// SONNY-6636 (c): a peer's outbox keeps one send of the leader's snapshot,
// not every one.
//
// The raft library sends a snapshot as a burst of InstallSnapshot chunks
// (64 KiB each) and, while the peer does not answer, sends the whole burst
// again every few rounds. The Raft transport's per-peer outbox coalesced
// only AppendEntries: a follower that was down for a minute came back to a
// queue of thousands of stale chunks of older snapshots (in a three-process
// cluster: 6410 UnexpectedOffset and 609 StaleSnapshot refusals), restored
// the oldest snapshot first and never caught up with the newest. A burst
// starts at offset 0, so a chunk at offset 0 now supersedes every snapshot
// chunk still queued for that peer.
//
// Driven on a real `raft_consensus.Transport` whose drain threads are not
// started, so the queue is read back as the drain would take it.
//
// CANARY: REQ=REQ-SONNY-6636-OUTBOX-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_outbox_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const CHUNK: usize = 4;

fn peer(id: u64) Peer {
    return .{ .id = id, .endpoint = "127.0.0.1", .port = 1, .last_contact = 0 };
}

/// Chunk `k` of a snapshot at `index`, owning its slices as the transport
/// expects (`freeOutboundMessage` frees them).
fn chunk(a: std.mem.Allocator, index: u64, k: usize, chunks: usize) !Message {
    const data = try a.alloc(u8, CHUNK);
    @memset(data, @intCast(index));
    const voters = try a.dupe(u64, &.{ 1, 2, 3 });
    return .{ .install_snapshot = .{
        .term = 2,
        .leader_id = 1,
        .last_included_index = index,
        .last_included_term = 2,
        .offset = k * CHUNK,
        .data = data,
        .done = k + 1 == chunks,
        .voters = voters,
    } };
}

fn sendSnapshot(a: std.mem.Allocator, t: *Transport, to: u64, index: u64, chunks: usize) !void {
    for (0..chunks) |k| try t.enqueueOutbound(peer(to), 1, 2, try chunk(a, index, k, chunks));
}

test "SONNY-6636: a new send of the snapshot replaces every snapshot chunk still queued for the peer, and nothing else" {
    const a = testing.allocator;
    var t = Transport.init(a);
    defer t.deinit();

    // Peer 3 is down: the leader sends its snapshot (at 50) again and
    // again, then a newer one (at 75); a vote reply sits between them.
    for (0..100) |_| try sendSnapshot(a, &t, 3, 50, 11);
    try t.enqueueOutbound(peer(3), 1, 2, .{ .request_vote_response = .{ .term = 2, .vote_granted = false, .voter_id = 3 } });
    try sendSnapshot(a, &t, 3, 75, 11);
    // Peer 2 is healthy; its snapshot is its own.
    try sendSnapshot(a, &t, 2, 50, 11);

    var snap = t.snapshotOutbox();
    defer {
        for (snap.items) |e| raft_consensus.freeOutboundMessage(a, e.msg);
        snap.deinit(a);
    }
    var to3_chunks: usize = 0;
    var to3_other: usize = 0;
    var to2_chunks: usize = 0;
    var next_offset: u64 = 0;
    for (snap.items) |e| switch (e.msg) {
        .install_snapshot => |is| {
            if (e.peer.id == 2) {
                to2_chunks += 1;
                continue;
            }
            to3_chunks += 1;
            // What is left for peer 3 is the newest send, whole and in order.
            try testing.expectEqual(@as(u64, 75), is.last_included_index);
            try testing.expectEqual(next_offset, is.offset);
            next_offset += CHUNK;
        },
        else => to3_other += 1,
    };
    std.debug.print("SONNY-6636: queued for peer 3: {d} snapshot chunk(s), {d} other message(s); for peer 2: {d} chunk(s)\n", .{ to3_chunks, to3_other, to2_chunks });
    try testing.expectEqual(@as(usize, 11), to3_chunks);
    try testing.expectEqual(@as(usize, 1), to3_other);
    try testing.expectEqual(@as(usize, 11), to2_chunks);
}
