// SONNY-6665: every InstallSnapshot / InstallSnapshotResponse field raft
// v0.2.5 reads crosses geode's Raft frame and its conversions intact.
//
// The frame (`encodeRaftFrame` / `decodeRaftFrame`, raft_schema) and the
// geode -> raft library conversion a receiver steps with
// (`geodeMessageToRaftLib`, as `RaftNode.handleMessage` does) carry an
// InstallSnapshot's BLAKE3 digest and cluster configuration (SONNY-6633),
// and an InstallSnapshotResponse's `last_index` and `next_offset` (raft
// SONNY-6652: the snapshot a follower holds, and where to resume after a
// lost chunk). A frame from a peer that sends neither reads them as 0.
//
// CANARY: REQ=REQ-SONNY-6665-WIRE-FIELDS; FEATURE="Raft Snapshot Persistence"; ASPECT=FrameRoundTrip; STATUS=TESTED; TEST=tests/test_sonny6665_wire_fields.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const raft_schema = @import("raft_schema");
const protobuf = @import("protobuf");

const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;

test "SONNY-6665: an InstallSnapshot's digest and configuration cross a frame and reach the raft library" {
    const a = testing.allocator;
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*b, i| b.* = @intCast(0xA0 + i);
    const voters = [_]u64{ 1, 2, 3 };
    const outgoing = [_]u64{ 1, 2 };
    const bytes = try raft_consensus.encodeRaftFrame(a, 1, 7, .{ .install_snapshot = .{
        .term = 7,
        .leader_id = 1,
        .last_included_index = 42,
        .last_included_term = 6,
        .offset = 131072,
        .data = "last-chunk",
        .done = true,
        .checksum = digest,
        .voters = &voters,
        .voters_outgoing = &outgoing,
        .is_joint = true,
    } });
    defer a.free(bytes);
    var frame = try raft_consensus.decodeRaftFrame(a, bytes);
    defer frame.deinit(a);
    const lib = raft_consensus.geodeMessageToRaftLib(frame.body).install_snapshot;
    try testing.expectEqual(@as(u64, 42), lib.last_included_index);
    try testing.expectEqual(@as(u64, 131072), lib.offset);
    try testing.expectEqualStrings("last-chunk", lib.data);
    try testing.expect(lib.done);
    try testing.expectEqualSlices(u8, &digest, &lib.checksum);
    try testing.expectEqualSlices(u64, &voters, lib.config.voters);
    try testing.expectEqualSlices(u64, &outgoing, lib.config.voters_outgoing);
    try testing.expect(lib.config.is_joint);
}

test "SONNY-6665: an InstallSnapshotResponse's last_index and next_offset cross a frame and reach the raft library" {
    const a = testing.allocator;
    const cases = [_]struct { success: bool, last_index: u64, next_offset: u64 }{
        // An install, or a snapshot the follower already holds.
        .{ .success = true, .last_index = 42, .next_offset = 0 },
        // A gap: chunk 65536 of snapshot 42 was lost.
        .{ .success = false, .last_index = 42, .next_offset = 65536 },
        // A plain refusal.
        .{ .success = false, .last_index = 0, .next_offset = 0 },
    };
    for (cases) |c| {
        const bytes = try raft_consensus.encodeRaftFrame(a, 3, 7, .{ .install_snapshot_response = .{
            .term = 7,
            .success = c.success,
            .last_index = c.last_index,
            .next_offset = c.next_offset,
        } });
        defer a.free(bytes);
        var frame = try raft_consensus.decodeRaftFrame(a, bytes);
        defer frame.deinit(a);
        const isr = frame.body.install_snapshot_response;
        try testing.expectEqual(c.success, isr.success);
        try testing.expectEqual(c.last_index, isr.last_index);
        try testing.expectEqual(c.next_offset, isr.next_offset);
        const lib: raft_lib.InstallSnapshotResponse = raft_consensus.geodeMessageToRaftLib(frame.body).install_snapshot_response;
        try testing.expectEqual(@as(u64, 7), lib.term);
        try testing.expectEqual(c.success, lib.success);
        try testing.expectEqual(c.last_index, lib.last_index);
        try testing.expectEqual(c.next_offset, lib.next_offset);
    }
}

test "SONNY-6665: a response from a peer that sends no last_index / next_offset reads them as 0" {
    const a = testing.allocator;
    // raft_schema field numbers 1 (term) and 2 (failed) only, as an older
    // geode encodes it.
    var old = raft_schema.RaftEnvelope{
        .term = 7,
        .from = 3,
        .message = .{ .install_snapshot_response = .{ .term = 7, .failed = true } },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, a, old);
    _ = &old;
    var frame = try raft_consensus.decodeRaftFrame(a, aw.writer.buffered());
    defer frame.deinit(a);
    const lib = raft_consensus.geodeMessageToRaftLib(frame.body).install_snapshot_response;
    try testing.expect(!lib.success);
    try testing.expectEqual(@as(u64, 0), lib.last_index);
    try testing.expectEqual(@as(u64, 0), lib.next_offset);
}
