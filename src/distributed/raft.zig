// CANARY: REQ=REQ-GQL-040; FEATURE="Raft Consensus"; ASPECT=Distributed; STATUS=TESTED; TEST="raft shim single node leader"; OWNER=distributed; UPDATED=2026-04-10
//
// Compatibility shim over raft_consensus.RaftNode.
// Preserves the string-based node ID API used by mod.zig:DistributedCoordinator
// while delegating all consensus logic to the canonical raft_consensus wrapper.

const std = @import("std");
const raft_consensus = @import("raft_consensus.zig");

/// Raft node states (mirrors raft_consensus.State for backward compat)
pub const NodeState = enum {
    follower,
    candidate,
    leader,
};

/// Raft log entry (string-based command for the legacy API)
pub const LogEntry = struct {
    term: u64,
    index: u64,
    command: []const u8,
    timestamp: i64,
};

/// Raft RPC message types
pub const MessageType = enum {
    request_vote,
    request_vote_response,
    append_entries,
    append_entries_response,
    install_snapshot,
    install_snapshot_response,
};

pub const RaftConfig = struct {
    node_id: []const u8,
    peers: []const []const u8,
    election_timeout_min_ms: u64 = 150,
    election_timeout_max_ms: u64 = 300,
    heartbeat_interval_ms: u64 = 50,
    log_compaction_threshold: usize = 1000,
    snapshot_chunk_size: usize = 64 * 1024,
};

/// Hash a string node_id to a u64 for the inner raft_consensus node.
fn hashNodeId(id: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(id);
    const h = hasher.final();
    // External raft library requires non-zero node IDs
    return if (h == 0) 1 else h;
}

/// Compatibility wrapper that delegates to raft_consensus.RaftNode.
/// Accepts string node IDs and raw byte payloads, converting them to
/// the u64-based types used by raft_consensus internally.
pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    config: RaftConfig,
    inner: *raft_consensus.RaftNode,

    // Volatile state for API compatibility
    state: NodeState,
    commit_index: u64,
    last_applied: u64,
    current_term: u64,

    // Callbacks (legacy API)
    apply_callback: ?*const fn ([]const u8) void,
    send_message_callback: ?*const fn ([]const u8, MessageType, []const u8) void,

    // Feature flags
    enable_leader_election: bool = false,
    enable_log_replication: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: RaftConfig) !RaftNode {
        // Map peer string IDs to raft_consensus.Peer array
        const peers = try allocator.alloc(raft_consensus.Peer, config.peers.len);
        for (config.peers, 0..) |peer_str, i| {
            peers[i] = raft_consensus.Peer{
                .id = hashNodeId(peer_str),
                .endpoint = peer_str,
                .port = 0,
                .alive = true,
                .last_contact = 0,
                .rpc_client = null,
            };
        }

        const inner = try raft_consensus.RaftNode.init(
            allocator,
            hashNodeId(config.node_id),
            peers,
            config.election_timeout_min_ms,
        );

        return RaftNode{
            .allocator = allocator,
            .config = config,
            .inner = inner,
            .state = .follower,
            .commit_index = 0,
            .last_applied = 0,
            .current_term = 0,
            .apply_callback = null,
            .send_message_callback = null,
        };
    }

    pub fn deinit(self: *RaftNode) void {
        const peers = self.inner.peers;
        self.inner.deinit();
        self.allocator.destroy(self.inner);
        self.allocator.free(peers);
    }

    pub fn enableFeatures(self: *RaftNode, leader_election: bool, log_replication: bool) void {
        self.enable_leader_election = leader_election;
        self.enable_log_replication = log_replication;
    }

    pub fn setApplyCallback(self: *RaftNode, callback: *const fn ([]const u8) void) void {
        self.apply_callback = callback;
    }

    pub fn setSendMessageCallback(self: *RaftNode, callback: *const fn ([]const u8, MessageType, []const u8) void) void {
        self.send_message_callback = callback;
    }

    pub fn start(self: *RaftNode) !void {
        if (!self.enable_leader_election) {
            self.state = .leader;
            self.syncFromInner();
            return;
        }
        self.state = .follower;
    }

    pub fn tick(self: *RaftNode) !void {
        try self.inner.tick();
        self.syncFromInner();
    }

    pub fn handleMessage(self: *RaftNode, from: []const u8, message_type: MessageType, payload: []const u8) !void {
        // The legacy API passes raw bytes; the inner node expects typed Messages.
        // Wire deserialization is not yet wired, so we forward as a no-op drain
        // to keep state synchronized (same behavior as the old implementation).
        _ = from;
        _ = message_type;
        _ = payload;
        self.syncFromInner();
    }

    pub fn propose(self: *RaftNode, command: []const u8) !bool {
        if (self.state != .leader) {
            return false;
        }

        _ = try self.inner.proposeCommand(.{ .write = command });

        if (!self.enable_log_replication) {
            self.commit_index += 1;
        }

        self.syncFromInner();
        return true;
    }

    pub fn getLeaderInfo(self: *const RaftNode) struct {
        is_leader: bool,
        current_term: u64,
        commit_index: u64,
        log_length: usize,
    } {
        return .{
            .is_leader = self.state == .leader,
            .current_term = self.current_term,
            .commit_index = self.commit_index,
            .log_length = 0,
        };
    }

    pub fn startElection(self: *RaftNode) !void {
        if (!self.enable_leader_election) return;
        self.state = .candidate;
        self.current_term += 1;
        self.inner.startElection();
        self.syncFromInner();
    }

    /// Synchronize shim state from the inner raft_consensus node.
    fn syncFromInner(self: *RaftNode) void {
        self.state = switch (self.inner.state) {
            .follower => .follower,
            .candidate => .candidate,
            .leader => .leader,
            .shutdown => .follower,
        };
        self.current_term = self.inner.current_term;
    }
};

test "raft shim basic init and deinit" {
    const allocator = std.testing.allocator;
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &[_][]const u8{ "node2", "node3" },
    };
    var node = try RaftNode.init(allocator, config);
    defer node.deinit();

    try std.testing.expectEqual(NodeState.follower, node.state);
}

test "raft shim single node leader" {
    const allocator = std.testing.allocator;
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &[_][]const u8{},
    };
    var node = try RaftNode.init(allocator, config);
    defer node.deinit();

    try node.start();
    try std.testing.expectEqual(NodeState.leader, node.state);
}

test "raft shim delegates to raft_consensus" {
    const allocator = std.testing.allocator;
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &[_][]const u8{},
    };
    var node = try RaftNode.init(allocator, config);
    defer node.deinit();

    // Inner node should have the same hashed ID
    try std.testing.expectEqual(hashNodeId("node1"), node.inner.id);

    // Tick should not crash
    try node.tick();

    // getLeaderInfo should work
    const info = node.getLeaderInfo();
    try std.testing.expectEqual(false, info.is_leader);
}
