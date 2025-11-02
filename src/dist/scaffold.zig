const std = @import("std");

// Enhanced distributed scaffold with Raft consensus and 2PC coordination

pub const Role = enum { Leader, Follower, Candidate };

pub const NodeId = u32;
pub const Term = u64;
pub const LogIndex = u64;

/// Enhanced Raft consensus implementation
pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    node_id: NodeId,
    role: Role = .Follower,
    current_term: Term = 0,
    voted_for: ?NodeId = null,
    log: std.ArrayList(LogEntry),
    commit_index: LogIndex = 0,
    last_applied: LogIndex = 0,

    // Leader state
    next_index: std.AutoHashMap(NodeId, LogIndex),
    match_index: std.AutoHashMap(NodeId, LogIndex),

    // Election state
    election_timeout: u64 = 150, // milliseconds
    heartbeat_interval: u64 = 50, // milliseconds
    last_heartbeat: i64 = 0,
    votes_received: std.AutoHashSet(NodeId),

    // Cluster configuration
    cluster_nodes: std.ArrayList(NodeId),

    const LogEntry = struct {
        term: Term,
        index: LogIndex,
        command: []const u8,
        committed: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, node_id: NodeId) RaftNode {
        return .{
            .allocator = allocator,
            .node_id = node_id,
            .log = std.ArrayList(LogEntry){},
            .next_index = std.AutoHashMap(NodeId, LogIndex).init(allocator),
            .match_index = std.AutoHashMap(NodeId, LogIndex).init(allocator),
            .votes_received = std.AutoHashSet(NodeId).init(allocator),
            .cluster_nodes = std.ArrayList(NodeId){},
        };
    }

    pub fn deinit(self: *RaftNode) void {
        for (self.log.items) |entry| {
            self.allocator.free(entry.command);
        }
        self.log.deinit();
        self.next_index.deinit();
        self.match_index.deinit();
        self.votes_received.deinit();
        self.cluster_nodes.deinit();
    }

    /// Start election process
    pub fn startElection(self: *RaftNode) !void {
        self.role = .Candidate;
        self.current_term += 1;
        self.voted_for = self.node_id;
        self.votes_received.clearRetainingCapacity();
        try self.votes_received.put(self.node_id, {});

        // Reset election timeout
        self.last_heartbeat = std.time.milliTimestamp();

        // Send RequestVote RPCs to all other nodes
        for (self.cluster_nodes.items) |node_id| {
            if (node_id != self.node_id) {
                // In a real implementation, this would send over network
                _ = self.sendRequestVote(node_id);
            }
        }
    }

    /// Become leader
    pub fn becomeLeader(self: *RaftNode) !void {
        self.role = .Leader;

        // Initialize leader state
        const last_log_index = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].index
        else
            0;

        for (self.cluster_nodes.items) |node_id| {
            if (node_id != self.node_id) {
                try self.next_index.put(node_id, last_log_index + 1);
                try self.match_index.put(node_id, 0);
            }
        }

        // Send initial heartbeats
        try self.sendHeartbeats();
    }

    /// Append entry to log (leader only)
    pub fn appendEntry(self: *RaftNode, command: []const u8) !LogIndex {
        if (self.role != .Leader) {
            return error.NotLeader;
        }

        const index = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].index + 1
        else
            1;

        const entry = LogEntry{
            .term = self.current_term,
            .index = index,
            .command = try self.allocator.dupe(u8, command),
        };

        try self.log.append(entry);

        // Replicate to followers
        try self.replicateToFollowers();

        return index;
    }

    /// Process RequestVote RPC
    pub fn handleRequestVote(self: *RaftNode, candidate_id: NodeId, term: Term, last_log_index: LogIndex, last_log_term: Term) bool {
        // Update term if necessary
        if (term > self.current_term) {
            self.current_term = term;
            self.voted_for = null;
            self.role = .Follower;
        }

        // Check if we can vote for this candidate
        if (term < self.current_term) {
            return false;
        }

        if (self.voted_for != null and self.voted_for != candidate_id) {
            return false;
        }

        // Check log up-to-date condition
        const our_last_log_index = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].index
        else
            0;
        const our_last_log_term = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].term
        else
            0;

        if (last_log_term < our_last_log_term or
            (last_log_term == our_last_log_term and last_log_index < our_last_log_index))
        {
            return false;
        }

        // Grant vote
        self.voted_for = candidate_id;
        self.last_heartbeat = std.time.milliTimestamp();
        return true;
    }

    /// Check if election timeout has occurred
    pub fn shouldStartElection(self: *RaftNode) bool {
        if (self.role == .Leader) return false;

        const now = std.time.milliTimestamp();
        return (now - self.last_heartbeat) > self.election_timeout;
    }

    /// Check if leader should send heartbeats
    pub fn shouldSendHeartbeats(self: *RaftNode) bool {
        if (self.role != .Leader) return false;

        const now = std.time.milliTimestamp();
        return (now - self.last_heartbeat) > self.heartbeat_interval;
    }

    fn sendRequestVote(self: *RaftNode, target: NodeId) bool {
        // Placeholder for network RPC
        _ = self;
        _ = target;
        return true;
    }

    fn sendHeartbeats(self: *RaftNode) !void {
        for (self.cluster_nodes.items) |node_id| {
            if (node_id != self.node_id) {
                // Send AppendEntries RPC with no entries (heartbeat)
                _ = self.sendAppendEntries(node_id, &.{});
            }
        }
        self.last_heartbeat = std.time.milliTimestamp();
    }

    fn replicateToFollowers(self: *RaftNode) !void {
        for (self.cluster_nodes.items) |node_id| {
            if (node_id != self.node_id) {
                const next_idx = self.next_index.get(node_id) orelse 1;
                const entries = if (next_idx <= self.log.items.len)
                    self.log.items[next_idx - 1 ..]
                else
                    &.{};
                _ = self.sendAppendEntries(node_id, entries);
            }
        }
    }

    fn sendAppendEntries(self: *RaftNode, target: NodeId, entries: []const LogEntry) bool {
        // Placeholder for network RPC
        _ = self;
        _ = target;
        _ = entries;
        return true;
    }
};

/// Enhanced Two-Phase Commit coordinator
pub const TwoPCCoordinator = struct {
    allocator: std.mem.Allocator,
    transaction_id: u64,
    participants: std.ArrayList(NodeId),
    state: State,
    timeout_ms: u64 = 30000, // 30 second timeout

    const State = enum {
        Preparing,
        Prepared,
        Committing,
        Committed,
        Aborting,
        Aborted,
    };

    const ParticipantResponse = struct {
        node_id: NodeId,
        vote: Vote,

        const Vote = enum { Prepare, Abort };
    };

    pub fn init(allocator: std.mem.Allocator, transaction_id: u64) TwoPCCoordinator {
        return .{
            .allocator = allocator,
            .transaction_id = transaction_id,
            .participants = std.ArrayList(NodeId){},
            .state = .Preparing,
        };
    }

    pub fn deinit(self: *TwoPCCoordinator) void {
        self.participants.deinit();
    }

    pub fn addParticipant(self: *TwoPCCoordinator, node_id: NodeId) !void {
        try self.participants.append(node_id);
    }

    /// Execute two-phase commit protocol
    pub fn execute(self: *TwoPCCoordinator) !bool {
        // Phase 1: Prepare
        self.state = .Preparing;

        var responses = std.ArrayList(ParticipantResponse){};
        defer responses.deinit();

        // Send prepare messages to all participants
        for (self.participants.items) |participant| {
            const response = self.sendPrepare(participant);
            try responses.append(.{ .node_id = participant, .vote = response });
        }

        // Check if all participants voted to prepare
        var all_prepared = true;
        for (responses.items) |response| {
            if (response.vote == .Abort) {
                all_prepared = false;
                break;
            }
        }

        if (!all_prepared) {
            // Phase 2: Abort
            self.state = .Aborting;
            for (self.participants.items) |participant| {
                self.sendAbort(participant);
            }
            self.state = .Aborted;
            return false;
        }

        // Phase 2: Commit
        self.state = .Committing;
        for (self.participants.items) |participant| {
            self.sendCommit(participant);
        }
        self.state = .Committed;
        return true;
    }

    fn sendPrepare(self: *TwoPCCoordinator, participant: NodeId) ParticipantResponse.Vote {
        // Placeholder for network RPC
        _ = self;
        _ = participant;

        // Simulate successful prepare for now
        return .Prepare;
    }

    fn sendCommit(self: *TwoPCCoordinator, participant: NodeId) void {
        // Placeholder for network RPC
        _ = self;
        _ = participant;
    }

    fn sendAbort(self: *TwoPCCoordinator, participant: NodeId) void {
        // Placeholder for network RPC
        _ = self;
        _ = participant;
    }
};

/// Enhanced shard mapping with consistent hashing
pub const ShardMap = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(ShardNode),
    virtual_nodes: std.ArrayList(VirtualNode),
    replication_factor: u32 = 3,

    const ShardNode = struct {
        id: NodeId,
        address: []const u8,
        weight: u32 = 1,
        healthy: bool = true,
    };

    const VirtualNode = struct {
        hash: u64,
        node_id: NodeId,
    };

    pub fn init(allocator: std.mem.Allocator) ShardMap {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(ShardNode){},
            .virtual_nodes = std.ArrayList(VirtualNode){},
        };
    }

    pub fn deinit(self: *ShardMap) void {
        for (self.nodes.items) |node| {
            self.allocator.free(node.address);
        }
        self.nodes.deinit();
        self.virtual_nodes.deinit();
    }

    pub fn addNode(self: *ShardMap, node_id: NodeId, address: []const u8, weight: u32) !void {
        const node = ShardNode{
            .id = node_id,
            .address = try self.allocator.dupe(u8, address),
            .weight = weight,
            .healthy = true,
        };

        try self.nodes.append(node);

        // Add virtual nodes for consistent hashing
        const virtual_count = weight * 100; // 100 virtual nodes per weight unit
        var i: u32 = 0;
        while (i < virtual_count) : (i += 1) {
            const key = try std.fmt.allocPrint(self.allocator, "{d}:{d}", .{ node_id, i });
            defer self.allocator.free(key);

            const hash = self.hashFunction(key);
            try self.virtual_nodes.append(.{ .hash = hash, .node_id = node_id });
        }

        // Sort virtual nodes by hash
        std.sort.block(VirtualNode, self.virtual_nodes.items, {}, struct {
            fn lessThan(_: void, a: VirtualNode, b: VirtualNode) bool {
                return a.hash < b.hash;
            }
        }.lessThan);
    }

    pub fn removeNode(self: *ShardMap, node_id: NodeId) void {
        // Remove from nodes list
        var i: usize = 0;
        while (i < self.nodes.items.len) {
            if (self.nodes.items[i].id == node_id) {
                self.allocator.free(self.nodes.items[i].address);
                _ = self.nodes.swapRemove(i);
                break;
            } else {
                i += 1;
            }
        }

        // Remove virtual nodes
        i = 0;
        while (i < self.virtual_nodes.items.len) {
            if (self.virtual_nodes.items[i].node_id == node_id) {
                _ = self.virtual_nodes.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Re-sort virtual nodes
        std.sort.block(VirtualNode, self.virtual_nodes.items, {}, struct {
            fn lessThan(_: void, a: VirtualNode, b: VirtualNode) bool {
                return a.hash < b.hash;
            }
        }.lessThan);
    }

    /// Locate primary node for a key
    pub fn locateNode(self: *ShardMap, key: []const u8) ?NodeId {
        if (self.virtual_nodes.items.len == 0) return null;

        const hash = self.hashFunction(key);

        // Find first virtual node with hash >= key hash
        for (self.virtual_nodes.items) |vnode| {
            if (vnode.hash >= hash) {
                // Check if node is healthy
                for (self.nodes.items) |node| {
                    if (node.id == vnode.node_id and node.healthy) {
                        return vnode.node_id;
                    }
                }
            }
        }

        // Wrap around to first virtual node
        const first_vnode = self.virtual_nodes.items[0];
        for (self.nodes.items) |node| {
            if (node.id == first_vnode.node_id and node.healthy) {
                return first_vnode.node_id;
            }
        }

        return null;
    }

    /// Get replica nodes for a key
    pub fn getReplicaNodes(self: *ShardMap, key: []const u8) ![]NodeId {
        var replicas = std.ArrayList(NodeId){};
        defer replicas.deinit();

        const hash = self.hashFunction(key);
        var found_count: u32 = 0;
        var start_idx: usize = 0;

        // Find starting position
        for (self.virtual_nodes.items, 0..) |vnode, i| {
            if (vnode.hash >= hash) {
                start_idx = i;
                break;
            }
        }

        // Collect unique healthy nodes
        var seen_nodes = std.AutoHashSet(NodeId).init(self.allocator);
        defer seen_nodes.deinit();

        var i: usize = 0;
        while (found_count < self.replication_factor and i < self.virtual_nodes.items.len) {
            const idx = (start_idx + i) % self.virtual_nodes.items.len;
            const vnode = self.virtual_nodes.items[idx];

            if (!seen_nodes.contains(vnode.node_id)) {
                // Check if node is healthy
                for (self.nodes.items) |node| {
                    if (node.id == vnode.node_id and node.healthy) {
                        try replicas.append(vnode.node_id);
                        try seen_nodes.put(vnode.node_id, {});
                        found_count += 1;
                        break;
                    }
                }
            }
            i += 1;
        }

        return replicas.toOwnedSlice();
    }

    fn hashFunction(self: *ShardMap, key: []const u8) u64 {
        _ = self;

        // Simple FNV-1a hash
        var hash: u64 = 14695981039346656037;
        for (key) |byte| {
            hash ^= byte;
            hash *%= 1099511628211;
        }
        return hash;
    }
};

test "raft node basic operations" {
    var node = RaftNode.init(std.testing.allocator, 1);
    defer node.deinit();

    try node.cluster_nodes.append(1);
    try node.cluster_nodes.append(2);
    try node.cluster_nodes.append(3);

    // Test election
    try node.startElection();
    try std.testing.expect(node.role == .Candidate);
    try std.testing.expect(node.current_term == 1);

    // Test becoming leader
    try node.becomeLeader();
    try std.testing.expect(node.role == .Leader);

    // Test log append
    const index = try node.appendEntry("test command");
    try std.testing.expect(index == 1);
    try std.testing.expect(node.log.items.len == 1);
}

test "two phase commit" {
    var coordinator = TwoPCCoordinator.init(std.testing.allocator, 12345);
    defer coordinator.deinit();

    try coordinator.addParticipant(1);
    try coordinator.addParticipant(2);
    try coordinator.addParticipant(3);

    const result = try coordinator.execute();
    try std.testing.expect(result); // Should succeed with mock implementation
    try std.testing.expect(coordinator.state == .Committed);
}

test "shard map consistent hashing" {
    var shard_map = ShardMap.init(std.testing.allocator);
    defer shard_map.deinit();

    try shard_map.addNode(1, "node1:7567", 1);
    try shard_map.addNode(2, "node2:7567", 1);
    try shard_map.addNode(3, "node3:7567", 1);

    // Test key location
    const node_id = shard_map.locateNode("test_key");
    try std.testing.expect(node_id != null);

    // Test replica nodes
    const replicas = try shard_map.getReplicaNodes("test_key");
    defer std.testing.allocator.free(replicas);
    try std.testing.expect(replicas.len <= 3);
}
