const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const rpc = @import("rpc.zig");

// CANARY: REQ=REQ-0006; FEATURE="Distributed Consensus"; ASPECT=RaftImplementation; STATUS=TESTED; TEST=geodetestlab/specs/gap_0210_distributed_rpc.yml; OWNER=dist; UPDATED=2026-01-16
// GAP-0210 FIX: Enhanced distributed scaffold with real network transport for Raft/2PC

pub const Role = enum { Leader, Follower, Candidate };

pub const NodeId = u32;
pub const Term = u64;
pub const LogIndex = u64;

/// Enhanced Raft consensus implementation with real network transport
/// GAP-0210 FIX: Now uses RPC client for actual network communication
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

    // GAP-0210 FIX: RPC client for network communication
    rpc_client: rpc.RpcClient,

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
            .rpc_client = rpc.RpcClient.init(allocator),
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
        self.rpc_client.deinit();
    }

    /// Register a cluster node's network address for RPC communication
    /// GAP-0210 FIX: Required for real network transport
    pub fn registerNodeAddress(self: *RaftNode, node_id: NodeId, address: []const u8, port: u16) !void {
        try self.rpc_client.registerNode(node_id, address, port);
    }

    /// Start election process
    pub fn startElection(self: *RaftNode) !void {
        self.role = .Candidate;
        self.current_term += 1;
        self.voted_for = self.node_id;
        self.votes_received.clearRetainingCapacity();
        try self.votes_received.put(self.node_id, {});

        // Reset election timeout
        self.last_heartbeat = compat_milliTimestamp();

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
        self.last_heartbeat = compat_milliTimestamp();
        return true;
    }

    /// Check if election timeout has occurred
    pub fn shouldStartElection(self: *RaftNode) bool {
        if (self.role == .Leader) return false;

        const now = compat_milliTimestamp();
        return (now - self.last_heartbeat) > self.election_timeout;
    }

    /// Check if leader should send heartbeats
    pub fn shouldSendHeartbeats(self: *RaftNode) bool {
        if (self.role != .Leader) return false;

        const now = compat_milliTimestamp();
        return (now - self.last_heartbeat) > self.heartbeat_interval;
    }

    /// GAP-0210 FIX: Real network implementation using RPC client
    fn sendRequestVote(self: *RaftNode, target: NodeId) bool {
        const last_log_index = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].index
        else
            0;
        const last_log_term = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].term
        else
            0;

        const msg = rpc.RequestVoteMsg{
            .term = self.current_term,
            .candidate_id = self.node_id,
            .last_log_index = last_log_index,
            .last_log_term = last_log_term,
        };

        const response = self.rpc_client.sendRequestVote(target, msg) catch |err| {
            std.debug.print("RequestVote RPC to node {} failed: {}\n", .{ target, err });
            return false;
        };

        // Update term if response has higher term
        if (response.term > self.current_term) {
            self.current_term = response.term;
            self.role = .Follower;
            self.voted_for = null;
            return false;
        }

        return response.vote_granted;
    }

    fn sendHeartbeats(self: *RaftNode) !void {
        for (self.cluster_nodes.items) |node_id| {
            if (node_id != self.node_id) {
                // Send AppendEntries RPC with no entries (heartbeat)
                _ = self.sendAppendEntries(node_id, &.{});
            }
        }
        self.last_heartbeat = compat_milliTimestamp();
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

    /// GAP-0210 FIX: Real network implementation using RPC client
    fn sendAppendEntries(self: *RaftNode, target: NodeId, entries: []const LogEntry) bool {
        const prev_log_index = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].index
        else
            0;
        const prev_log_term = if (self.log.items.len > 0)
            self.log.items[self.log.items.len - 1].term
        else
            0;

        const msg = rpc.AppendEntriesMsg{
            .term = self.current_term,
            .leader_id = self.node_id,
            .prev_log_index = prev_log_index,
            .prev_log_term = prev_log_term,
            .leader_commit = self.commit_index,
            .entries_count = @intCast(entries.len),
        };

        // Convert LogEntry to rpc.LogEntry
        var rpc_entries = self.allocator.alloc(rpc.LogEntry, entries.len) catch return false;
        defer self.allocator.free(rpc_entries);

        for (entries, 0..) |entry, i| {
            rpc_entries[i] = rpc.LogEntry{
                .term = entry.term,
                .index = entry.index,
                .command = entry.command,
                .committed = entry.committed,
            };
        }

        const response = self.rpc_client.sendAppendEntries(target, msg, rpc_entries) catch |err| {
            std.debug.print("AppendEntries RPC to node {} failed: {}\n", .{ target, err });
            return false;
        };

        // Update term if response has higher term
        if (response.term > self.current_term) {
            self.current_term = response.term;
            self.role = .Follower;
            self.voted_for = null;
            return false;
        }

        // Update match_index on success
        if (response.success) {
            self.match_index.put(target, response.match_index) catch {};
            self.next_index.put(target, response.match_index + 1) catch {};
        } else {
            // Decrement next_index on failure (log inconsistency)
            if (self.next_index.get(target)) |current| {
                if (current > 1) {
                    self.next_index.put(target, current - 1) catch {};
                }
            }
        }

        return response.success;
    }
};

/// Enhanced Two-Phase Commit coordinator with real network transport
/// GAP-0210 FIX: Now uses RPC client for actual network communication
pub const TwoPCCoordinator = struct {
    allocator: std.mem.Allocator,
    transaction_id: u64,
    coordinator_id: NodeId,
    participants: std.ArrayList(NodeId),
    state: State,
    timeout_ms: u64 = 30000, // 30 second timeout

    // GAP-0210 FIX: RPC client for network communication
    rpc_client: rpc.RpcClient,

    // Transaction payload to send to participants
    payload: []const u8 = &.{},

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
            .coordinator_id = 0, // Set via setCoordinatorId
            .participants = std.ArrayList(NodeId){},
            .state = .Preparing,
            .rpc_client = rpc.RpcClient.init(allocator),
        };
    }

    pub fn deinit(self: *TwoPCCoordinator) void {
        self.participants.deinit();
        self.rpc_client.deinit();
        if (self.payload.len > 0) {
            self.allocator.free(self.payload);
        }
    }

    pub fn setCoordinatorId(self: *TwoPCCoordinator, coordinator_id: NodeId) void {
        self.coordinator_id = coordinator_id;
    }

    pub fn setPayload(self: *TwoPCCoordinator, payload: []const u8) !void {
        if (self.payload.len > 0) {
            self.allocator.free(self.payload);
        }
        self.payload = try self.allocator.dupe(u8, payload);
    }

    /// Register a participant node's network address for RPC communication
    /// GAP-0210 FIX: Required for real network transport
    pub fn registerNodeAddress(self: *TwoPCCoordinator, node_id: NodeId, address: []const u8, port: u16) !void {
        try self.rpc_client.registerNode(node_id, address, port);
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

    /// GAP-0210 FIX: Real network implementation using RPC client
    fn sendPrepare(self: *TwoPCCoordinator, participant: NodeId) ParticipantResponse.Vote {
        const msg = rpc.PrepareMsg{
            .transaction_id = self.transaction_id,
            .coordinator_id = self.coordinator_id,
            .payload_len = @intCast(self.payload.len),
        };

        const response = self.rpc_client.sendPrepare(participant, msg, self.payload) catch |err| {
            std.debug.print("2PC Prepare RPC to node {} failed: {}\n", .{ participant, err });
            return .Abort;
        };

        return switch (response.vote) {
            .Prepared => .Prepare,
            .Abort => .Abort,
        };
    }

    /// GAP-0210 FIX: Real network implementation using RPC client
    fn sendCommit(self: *TwoPCCoordinator, participant: NodeId) void {
        const msg = rpc.CommitAbortMsg{
            .transaction_id = self.transaction_id,
            .coordinator_id = self.coordinator_id,
        };

        self.rpc_client.sendCommit(participant, msg) catch |err| {
            std.debug.print("2PC Commit RPC to node {} failed: {}\n", .{ participant, err });
        };
    }

    /// GAP-0210 FIX: Real network implementation using RPC client
    fn sendAbort(self: *TwoPCCoordinator, participant: NodeId) void {
        const msg = rpc.CommitAbortMsg{
            .transaction_id = self.transaction_id,
            .coordinator_id = self.coordinator_id,
        };

        self.rpc_client.sendAbort(participant, msg) catch |err| {
            std.debug.print("2PC Abort RPC to node {} failed: {}\n", .{ participant, err });
        };
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
