const std = @import("std");
const testing = std.testing;
const raft = @import("../src/distributed/raft_consensus.zig");
const net = std.net;

// Mock transport for testing
const MockTransport = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    nodes: std.AutoHashMap(u64, *raft.RaftNode),

    const Message = struct {
        from: u64,
        to: u64,
        msg: raft.Message,
    };

    pub fn init(allocator: std.mem.Allocator) MockTransport {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message).init(allocator),
            .nodes = std.AutoHashMap(u64, *raft.RaftNode).init(allocator),
        };
    }

    pub fn deinit(self: *MockTransport) void {
        self.messages.deinit();
        self.nodes.deinit();
    }

    pub fn registerNode(self: *MockTransport, id: u64, node: *raft.RaftNode) !void {
        try self.nodes.put(id, node);
    }

    pub fn send(self: *MockTransport, from: u64, to: u64, msg: raft.Message) !void {
        try self.messages.append(.{ .from = from, .to = to, .msg = msg });
    }

    pub fn deliver(self: *MockTransport) !void {
        if (self.messages.items.len == 0) return;

        const msg = self.messages.orderedRemove(0);
        if (self.nodes.get(msg.to)) |node| {
            try node.handleMessage(msg.from, msg.msg);
        }
    }

    pub fn deliverAll(self: *MockTransport) !void {
        while (self.messages.items.len > 0) {
            try self.deliver();
        }
    }
};

test "three node cluster leader election" {
    const allocator = testing.allocator;

    var transport = MockTransport.init(allocator);
    defer transport.deinit();

    // Create three nodes
    var peers = [_]raft.Peer{
        .{ .id = 1, .address = try net.Address.parseIp("127.0.0.1", 8001), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .address = try net.Address.parseIp("127.0.0.1", 8002), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 3, .address = try net.Address.parseIp("127.0.0.1", 8003), .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node1 = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer node1.deinit();
    try transport.registerNode(1, &node1);

    var node2 = try raft.RaftNode.init(allocator, 2, &peers, 150);
    defer node2.deinit();
    try transport.registerNode(2, &node2);

    var node3 = try raft.RaftNode.init(allocator, 3, &peers, 150);
    defer node3.deinit();
    try transport.registerNode(3, &node3);

    // All nodes should start as followers
    try testing.expect(node1.state == .follower);
    try testing.expect(node2.state == .follower);
    try testing.expect(node3.state == .follower);

    // Node 1 starts an election
    try node1.startElection();
    try testing.expect(node1.state == .candidate);

    // Simulate vote responses
    const vote_response2 = raft.RequestVoteResponse{
        .term = 1,
        .vote_granted = true,
        .voter_id = 2,
    };
    try node1.handleRequestVoteResponse(vote_response2, 2);

    const vote_response3 = raft.RequestVoteResponse{
        .term = 1,
        .vote_granted = true,
        .voter_id = 3,
    };
    try node1.handleRequestVoteResponse(vote_response3, 3);

    // Node 1 should become leader
    try testing.expect(node1.state == .leader);
    try testing.expect(node1.current_term == 1);
}

test "log replication across cluster" {
    const allocator = testing.allocator;

    var peers = [_]raft.Peer{
        .{ .id = 1, .address = try net.Address.parseIp("127.0.0.1", 8001), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .address = try net.Address.parseIp("127.0.0.1", 8002), .alive = true, .last_contact = 0, .rpc_client = null },
    };

    // Create leader
    var leader = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer leader.deinit();
    try leader.startElection(); // Single node becomes leader immediately

    // Create follower
    var follower = try raft.RaftNode.init(allocator, 2, &peers, 150);
    defer follower.deinit();

    // Leader proposes a command
    const cmd = raft.Command{ .write = "test data" };
    const index = try leader.propose(cmd);
    try testing.expect(index > 0);

    // Simulate AppendEntries to follower
    const entries = leader.log.items[1..]; // Skip init noop
    const append_msg = raft.AppendEntries{
        .term = leader.current_term,
        .leader_id = leader.id,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = entries,
        .leader_commit = 0,
    };

    try follower.handleAppendEntries(append_msg, 1);

    // Follower should have the entries
    try testing.expect(follower.log.items.len == leader.log.items.len);
}

test "split vote scenario" {
    const allocator = testing.allocator;

    var peers = [_]raft.Peer{
        .{ .id = 1, .address = try net.Address.parseIp("127.0.0.1", 8001), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .address = try net.Address.parseIp("127.0.0.1", 8002), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 3, .address = try net.Address.parseIp("127.0.0.1", 8003), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 4, .address = try net.Address.parseIp("127.0.0.1", 8004), .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node1 = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer node1.deinit();

    var node2 = try raft.RaftNode.init(allocator, 2, &peers, 150);
    defer node2.deinit();

    // Both start elections at same term
    try node1.startElection();
    try node2.startElection();

    // Node 1 gets vote from node 3, node 2 gets vote from node 4
    const vote13 = raft.RequestVoteResponse{ .term = 1, .vote_granted = true, .voter_id = 3 };
    try node1.handleRequestVoteResponse(vote13, 3);

    const vote24 = raft.RequestVoteResponse{ .term = 1, .vote_granted = true, .voter_id = 4 };
    try node2.handleRequestVoteResponse(vote24, 4);

    // Neither should be leader (need 3 out of 4 votes)
    try testing.expect(node1.state == .candidate);
    try testing.expect(node2.state == .candidate);
}

test "network partition recovery" {
    const allocator = testing.allocator;

    var peers = [_]raft.Peer{
        .{ .id = 1, .address = try net.Address.parseIp("127.0.0.1", 8001), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .address = try net.Address.parseIp("127.0.0.1", 8002), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 3, .address = try net.Address.parseIp("127.0.0.1", 8003), .alive = false, .last_contact = 0, .rpc_client = null }, // Partitioned
    };

    var leader = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer leader.deinit();
    try leader.startElection();

    // Propose commands while node 3 is partitioned
    const cmd1 = raft.Command{ .write = "data1" };
    _ = try leader.propose(cmd1);

    // Heal partition
    for (leader.peers) |*peer| {
        if (peer.id == 3) {
            peer.alive = true;
            break;
        }
    }

    // Node 3 should be able to catch up
    var node3 = try raft.RaftNode.init(allocator, 3, &peers, 150);
    defer node3.deinit();

    // Send catch-up AppendEntries
    const entries = leader.log.items[1..];
    const append_msg = raft.AppendEntries{
        .term = leader.current_term,
        .leader_id = leader.id,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = entries,
        .leader_commit = leader.commit_index,
    };

    try node3.handleAppendEntries(append_msg, 1);
    try testing.expect(node3.log.items.len == leader.log.items.len);
}

test "leader step down on higher term" {
    const allocator = testing.allocator;

    var peers = [_]raft.Peer{
        .{ .id = 1, .address = try net.Address.parseIp("127.0.0.1", 8001), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .address = try net.Address.parseIp("127.0.0.1", 8002), .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node1 = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer node1.deinit();

    // Node 1 becomes leader at term 1
    try node1.startElection();
    try testing.expect(node1.state == .leader);
    try testing.expect(node1.current_term == 1);

    // Receive message from higher term
    const higher_term_msg = raft.RequestVote{
        .term = 5,
        .candidate_id = 2,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    };

    try node1.handleRequestVote(higher_term_msg, 2);

    // Should step down to follower
    try testing.expect(node1.state == .follower);
    try testing.expect(node1.current_term == 5);
}

test "commit index advancement" {
    const allocator = testing.allocator;

    var peers = [_]raft.Peer{
        .{ .id = 1, .address = try net.Address.parseIp("127.0.0.1", 8001), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .address = try net.Address.parseIp("127.0.0.1", 8002), .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 3, .address = try net.Address.parseIp("127.0.0.1", 8003), .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var leader = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer leader.deinit();
    try leader.startElection();

    // Initialize next_index and match_index properly
    try leader.next_index.?.put(2, 2);
    try leader.next_index.?.put(3, 2);

    // Propose entry
    const cmd = raft.Command{ .write = "test" };
    const idx = try leader.propose(cmd);

    // Simulate successful AppendEntries responses
    const resp2 = raft.AppendEntriesResponse{
        .term = leader.current_term,
        .success = true,
        .match_index = idx,
    };
    try leader.handleAppendEntriesResponse(resp2, 2);

    const resp3 = raft.AppendEntriesResponse{
        .term = leader.current_term,
        .success = true,
        .match_index = idx,
    };
    try leader.handleAppendEntriesResponse(resp3, 3);

    // Commit index should advance
    try testing.expect(leader.commit_index >= idx);
}
