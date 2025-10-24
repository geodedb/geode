const std = @import("std");
const raft = @import("../src/distributed/raft_consensus.zig");

// CANARY: REQ=REQ-GQL-070; FEATURE="Raft Replication"; ASPECT=AppendEntriesSuccess; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_070_AppendEntriesSuccess; OWNER=distributed; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-070; FEATURE="Raft Replication"; ASPECT=AppendEntriesTermMismatch; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_070_AppendEntriesTermMismatch; OWNER=distributed; UPDATED=2025-09-21

fn makeNode(allocator: std.mem.Allocator, id: u64, peer_ids: []const u64) !*raft.RaftNode {
    var builder = raft.RaftBuilder.init(allocator, .{});
    defer builder.deinit();
    var peers = try allocator.alloc(raft.PeerConfig, peer_ids.len);
    for (peer_ids, 0..) |pid, i| peers[i] = .{ .id = pid, .address = "" };
    return try builder.buildNode(id, peers);
}

test "TestCANARY_REQ_GQL_070_AppendEntriesSuccess" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const n1 = try makeNode(allocator, 1, &.{2});
    defer n1.deinit();
    const n2 = try makeNode(allocator, 2, &.{1});
    defer n2.deinit();

    // Force node1 as leader
    n1.state = .leader;
    n1.current_term = 5;
    // Prepare append entries with one new log entry
    const entry = raft.LogEntry{ .term = 5, .index = 1, .command = "set x=1" };
    const ae = raft.AppendEntries{
        .term = 5,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .leader_commit = 0,
        .entries = &.{entry},
    };
    try n2.handleAppendEntries(ae, 1);
    try std.testing.expect(n2.log.items.len == 1);
    try std.testing.expect(n2.log.items[0].term == 5);
    try std.testing.expect(n2.commit_index == 0); // not committed yet
}

test "TestCANARY_REQ_GQL_070_AppendEntriesTermMismatch" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const n1 = try makeNode(allocator, 1, &.{2});
    defer n1.deinit();
    const n2 = try makeNode(allocator, 2, &.{1});
    defer n2.deinit();

    n1.state = .leader;
    n1.current_term = 6;
    n2.current_term = 10; // follower has higher term -> reject append

    const entry = raft.LogEntry{ .term = 6, .index = 1, .command = "set y=2" };
    const ae = raft.AppendEntries{
        .term = 6,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .leader_commit = 0,
        .entries = &.{entry},
    };
    try n2.handleAppendEntries(ae, 1);
    // Because follower term higher, it should ignore append.
    try std.testing.expect(n2.log.items.len == 0);
}
