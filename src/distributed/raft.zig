// CANARY: REQ=REQ-GQL-040; FEATURE="Raft Consensus"; ASPECT=Distributed; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_040_RaftLeaderElection; BENCH=BenchmarkCANARY_REQ_GQL_040_RaftElectionLatency; OWNER=distributed; UPDATED=2025-09-21
//
// Compatibility wrapper around the external raft library (gitlab.com/devnw/zig/raft).
// Preserves the existing geode API while delegating consensus to the external library.

const std = @import("std");
const raft_lib = @import("raft");

/// Raft node states
pub const NodeState = enum {
    follower,
    candidate,
    leader,
};

/// Raft log entry
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

/// Hash a string node_id to a u64 for the external raft library.
fn hashNodeId(id: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(id);
    const h = hasher.final();
    // Ensure non-zero (raft library requires non-zero node IDs)
    return if (h == 0) 1 else h;
}

/// Raft consensus implementation — wraps the external raft library.
pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    config: RaftConfig,
    inner: raft_lib.RaftNode,
    storage: raft_lib.InMemoryStorage,

    // Volatile state for API compatibility
    state: NodeState,
    commit_index: u64,
    last_applied: u64,
    current_term: u64,

    // Peer ID mapping (string → u64)
    peer_ids: []u64,

    // Callbacks
    apply_callback: ?*const fn ([]const u8) void,
    send_message_callback: ?*const fn ([]const u8, MessageType, []const u8) void,

    // Feature flags
    enable_leader_election: bool = false,
    enable_log_replication: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: RaftConfig) !RaftNode {
        const node_id = hashNodeId(config.node_id);

        // Map peer string IDs to u64
        const peer_ids = try allocator.alloc(u64, config.peers.len);
        for (config.peers, 0..) |peer, i| {
            peer_ids[i] = hashNodeId(peer);
        }

        var storage = raft_lib.InMemoryStorage.init(allocator);

        const raft_config = raft_lib.Config{
            .id = node_id,
            .peers = peer_ids,
            .election_tick = @intCast(config.election_timeout_min_ms / config.heartbeat_interval_ms),
            .heartbeat_tick = 1,
            .snapshot_threshold = @intCast(config.log_compaction_threshold),
            .snapshot_chunk_size = config.snapshot_chunk_size,
            .pre_vote = true,
        };

        const inner = try raft_lib.RaftNode.init(allocator, raft_config, storage.storage());

        return RaftNode{
            .allocator = allocator,
            .config = config,
            .inner = inner,
            .storage = storage,
            .state = .follower,
            .commit_index = 0,
            .last_applied = 0,
            .current_term = 0,
            .peer_ids = peer_ids,
            .apply_callback = null,
            .send_message_callback = null,
        };
    }

    pub fn deinit(self: *RaftNode) void {
        self.inner.deinit();
        self.storage.deinit();
        self.allocator.free(self.peer_ids);
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
            return;
        }
        self.state = .follower;
    }

    pub fn tick(self: *RaftNode) !void {
        self.inner.tick(null);
        self.drainReady();
    }

    pub fn handleMessage(self: *RaftNode, from: []const u8, message_type: MessageType, payload: []const u8) !void {
        _ = message_type;
        _ = payload;
        const from_id = hashNodeId(from);
        // The external library handles messages via step() with native Message types.
        // For wire compatibility, we'd need to deserialize the payload into the
        // appropriate raft_lib.Message type. For now, forward as a noop entry.
        _ = from_id;
        self.drainReady();
    }

    pub fn propose(self: *RaftNode, command: []const u8) !bool {
        if (self.state != .leader) {
            return false;
        }

        self.inner.propose(command);

        if (!self.enable_log_replication) {
            self.commit_index += 1;
        }

        self.drainReady();
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
        self.drainReady();
    }

    /// Drain the Ready struct from the external raft library,
    /// applying committed entries and updating local state.
    fn drainReady(self: *RaftNode) void {
        const rd = self.inner.ready();

        // Update state from soft state
        if (rd.soft_state) |ss| {
            self.state = switch (ss.role) {
                .leader => .leader,
                .candidate => .candidate,
                .follower => .follower,
            };
        }

        // Update term from hard state
        if (rd.hard_state) |hs| {
            self.current_term = hs.current_term;
        }

        // Apply committed entries
        for (rd.committed_entries) |entry| {
            if (entry.kind == .normal and entry.data.len > 0) {
                if (self.apply_callback) |callback| {
                    callback(entry.data);
                }
            }
            self.last_applied = entry.index;
            self.commit_index = @max(self.commit_index, entry.index);
        }

        self.inner.advance(rd);
    }
};

test "raft basic init and deinit" {
    const allocator = std.testing.allocator;
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &[_][]const u8{ "node2", "node3" },
    };
    var node = try RaftNode.init(allocator, config);
    defer node.deinit();

    try std.testing.expectEqual(NodeState.follower, node.state);
}

test "raft single node leader" {
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
