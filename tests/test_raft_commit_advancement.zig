const std = @import("std");
const raft = @import("../src/distributed/raft_consensus.zig");
const net = std.net;

// CANARY: REQ=REQ-GQL-070; FEATURE="Raft Replication"; ASPECT=AppendEntriesCommitAdvance; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_070_AppendEntriesCommitAdvance; OWNER=distributed; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_070_AppendEntriesCommitAdvance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]raft.Peer{
        .{ .id = 1, .address = try net.Address.parseIp("127.0.0.1", 8001), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .address = try net.Address.parseIp("127.0.0.1", 8002), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 3, .address = try net.Address.parseIp("127.0.0.1", 8003), .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var leader = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer leader.deinit();

    // Start election -> become leader (single process view of cluster)
    try leader.startElection();
    try testing.expect(leader.state == .leader);

    const current_term = leader.current_term;

    // Propose a new command (will append leader noop first during election, then this entry)
    const cmd = raft.Command{ .write = "set k=v" };
    const entry_index = try leader.propose(cmd);
    try testing.expect(entry_index == 2); // 0:init noop,1:leader noop,2:our command
    try testing.expect(leader.commit_index == 0); // not committed yet

    // Simulate successful replication to follower 2 (majority: leader + follower2)
    const aer1 = raft.AppendEntriesResponse{ .term = current_term, .success = true, .match_index = entry_index };
    try leader.handleAppendEntriesResponse(aer1, 2);

    // Commit index should advance now (majority achieved) and entry applied
    try testing.expect(leader.commit_index == entry_index);
    try testing.expect(leader.last_applied == entry_index);

    // Simulate follower 3 also acknowledging (idempotent)
    const aer2 = raft.AppendEntriesResponse{ .term = current_term, .success = true, .match_index = entry_index };
    try leader.handleAppendEntriesResponse(aer2, 3);
    try testing.expect(leader.commit_index == entry_index);
    try testing.expect(leader.last_applied == entry_index);
}
