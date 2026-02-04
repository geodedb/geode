// CANARY: REQ=REQ-GQL-040; FEATURE="Raft Consensus"; ASPECT=Distributed; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_040_RaftLeaderElection; BENCH=BenchmarkCANARY_REQ_GQL_040_RaftElectionLatency; OWNER=distributed; UPDATED=2025-09-21

const std = @import("std");
const protobuf = @import("protobuf");
const fd = protobuf.fd;

const SnapshotRequest = struct {
    term: u64,
    last_included_index: u64,
    last_included_term: u64,
    done: bool,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .last_included_index = fd(2, .{ .scalar = .uint64 }),
        .last_included_term = fd(3, .{ .scalar = .uint64 }),
        .done = fd(4, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *SnapshotRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const SnapshotResponse = struct {
    term: u64,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *SnapshotResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

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

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .index = fd(2, .{ .scalar = .uint64 }),
        .command = fd(3, .{ .scalar = .bytes }),
        .timestamp = fd(4, .{ .scalar = .int64 }),
    };

    pub fn deinit(self: *LogEntry, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
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

/// Request Vote RPC
pub const RequestVoteRequest = struct {
    term: u64,
    candidate_id: []const u8,
    last_log_index: u64,
    last_log_term: u64,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .candidate_id = fd(2, .{ .scalar = .string }),
        .last_log_index = fd(3, .{ .scalar = .uint64 }),
        .last_log_term = fd(4, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *RequestVoteRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RequestVoteResponse = struct {
    term: u64,
    vote_granted: bool,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .vote_granted = fd(2, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *RequestVoteResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

/// Append Entries RPC
pub const AppendEntriesRequest = struct {
    term: u64,
    leader_id: []const u8,
    prev_log_index: u64,
    prev_log_term: u64,
    entries: std.ArrayList(LogEntry),
    leader_commit: u64,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .leader_id = fd(2, .{ .scalar = .string }),
        .prev_log_index = fd(3, .{ .scalar = .uint64 }),
        .prev_log_term = fd(4, .{ .scalar = .uint64 }),
        .entries = fd(5, .{ .repeated = .{ .submessage = {} } }),
        .leader_commit = fd(6, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *AppendEntriesRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const AppendEntriesResponse = struct {
    term: u64,
    success: bool,
    match_index: u64,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .success = fd(2, .{ .scalar = .bool }),
        .match_index = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *AppendEntriesResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

/// Raft node configuration
pub const RaftConfig = struct {
    node_id: []const u8,
    peers: []const []const u8,
    election_timeout_min_ms: u64 = 150,
    election_timeout_max_ms: u64 = 300,
    heartbeat_interval_ms: u64 = 50,
    log_compaction_threshold: usize = 1000,
    snapshot_chunk_size: usize = 64 * 1024, // 64KB
};

/// Raft consensus implementation
pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    config: RaftConfig,

    // Persistent state
    current_term: u64,
    voted_for: ?[]const u8,
    log: std.ArrayList(LogEntry),

    // Volatile state
    state: NodeState,
    commit_index: u64,
    last_applied: u64,

    // Leader state (valid only when leader)
    next_index: std.StringHashMap(u64),
    match_index: std.StringHashMap(u64),

    // Election state
    election_timer: ?std.time.Timer,
    heartbeat_timer: ?std.time.Timer,
    votes_received: usize,

    // Callbacks for integration
    apply_callback: ?*const fn ([]const u8) void,
    send_message_callback: ?*const fn ([]const u8, MessageType, []const u8) void,

    // Feature flags
    enable_leader_election: bool = false,
    enable_log_replication: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: RaftConfig) !RaftNode {
        var node = RaftNode{
            .allocator = allocator,
            .config = config,
            .current_term = 0,
            .voted_for = null,
            .log = std.ArrayList(LogEntry).init(allocator),
            .state = .follower,
            .commit_index = 0,
            .last_applied = 0,
            .next_index = std.StringHashMap(u64).init(allocator),
            .match_index = std.StringHashMap(u64).init(allocator),
            .election_timer = null,
            .heartbeat_timer = null,
            .votes_received = 0,
            .apply_callback = null,
            .send_message_callback = null,
        };

        // Initialize peer tracking
        for (config.peers) |peer| {
            try node.next_index.put(peer, 1);
            try node.match_index.put(peer, 0);
        }

        return node;
    }

    pub fn deinit(self: *RaftNode) void {
        self.log.deinit(self.allocator);
        self.next_index.deinit();
        self.match_index.deinit();
        if (self.voted_for) |voted| {
            self.allocator.free(voted);
        }
    }

    /// Enable Raft features (for gradual rollout)
    pub fn enableFeatures(self: *RaftNode, leader_election: bool, log_replication: bool) void {
        self.enable_leader_election = leader_election;
        self.enable_log_replication = log_replication;
    }

    /// Set callback for applying committed entries
    pub fn setApplyCallback(self: *RaftNode, callback: *const fn ([]const u8) void) void {
        self.apply_callback = callback;
    }

    /// Set callback for sending messages to peers
    pub fn setSendMessageCallback(self: *RaftNode, callback: *const fn ([]const u8, MessageType, []const u8) void) void {
        self.send_message_callback = callback;
    }

    /// Start the Raft node
    pub fn start(self: *RaftNode) !void {
        if (!self.enable_leader_election) {
            // In single-node mode, immediately become leader
            self.state = .leader;
            return;
        }

        self.state = .follower;
        try self.resetElectionTimer();
    }

    /// Process periodic tasks (should be called regularly)
    pub fn tick(self: *RaftNode) !void {
        switch (self.state) {
            .follower, .candidate => {
                if (self.election_timer) |*timer| {
                    const elapsed_ms = timer.read() / std.time.ns_per_ms;
                    const timeout_ms = self.getElectionTimeout();

                    if (elapsed_ms >= timeout_ms) {
                        try self.startElection();
                    }
                }
            },
            .leader => {
                if (self.enable_log_replication) {
                    if (self.heartbeat_timer) |*timer| {
                        const elapsed_ms = timer.read() / std.time.ns_per_ms;

                        if (elapsed_ms >= self.config.heartbeat_interval_ms) {
                            try self.sendHeartbeats();
                            try self.resetHeartbeatTimer();
                        }
                    }
                }
            },
        }

        // Apply committed entries
        try self.applyCommittedEntries();
    }

    /// Handle incoming Raft messages
    pub fn handleMessage(self: *RaftNode, from: []const u8, message_type: MessageType, payload: []const u8) !void {
        switch (message_type) {
            .request_vote => try self.handleRequestVote(from, payload),
            .request_vote_response => try self.handleRequestVoteResponse(from, payload),
            .append_entries => try self.handleAppendEntries(from, payload),
            .append_entries_response => try self.handleAppendEntriesResponse(from, payload),
            .install_snapshot => try self.handleInstallSnapshot(from, payload),
            .install_snapshot_response => try self.handleInstallSnapshotResponse(from, payload),
        }
    }

    /// Propose a new entry (only valid for leaders)
    pub fn propose(self: *RaftNode, command: []const u8) !bool {
        if (self.state != .leader) {
            return false;
        }

        const entry = LogEntry{
            .term = self.current_term,
            .index = self.getLastLogIndex() + 1,
            .command = try self.allocator.dupe(u8, command),
            .timestamp = std.time.timestamp(),
        };

        try self.log.append(self.allocator, entry);

        if (self.enable_log_replication) {
            // Send to followers
            try self.sendAppendEntries();
        } else {
            // In single-node mode, immediately commit
            self.commit_index = entry.index;
        }

        return true;
    }

    /// Get current leader information
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
            .log_length = self.log.items.len,
        };
    }

    // Private methods

    fn getElectionTimeout(self: *const RaftNode) u64 {
        const range = self.config.election_timeout_max_ms - self.config.election_timeout_min_ms;
        const random_offset = std.crypto.random.int(u64) % range;
        return self.config.election_timeout_min_ms + random_offset;
    }

    fn resetElectionTimer(self: *RaftNode) !void {
        self.election_timer = try std.time.Timer.start();
    }

    fn resetHeartbeatTimer(self: *RaftNode) !void {
        self.heartbeat_timer = try std.time.Timer.start();
    }

    fn getLastLogIndex(self: *const RaftNode) u64 {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].index;
    }

    fn getLastLogTerm(self: *const RaftNode) u64 {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].term;
    }

    pub fn startElection(self: *RaftNode) !void { // made public for test forcing election deterministically
        if (!self.enable_leader_election) return;

        self.state = .candidate;
        self.current_term += 1;

        // Vote for self
        if (self.voted_for) |voted| {
            self.allocator.free(voted);
        }
        self.voted_for = try self.allocator.dupe(u8, self.config.node_id);
        self.votes_received = 1;

        try self.resetElectionTimer();

        // Send RequestVote to all peers (test harness may directly inject responses)
        if (self.send_message_callback) |callback| {
            const request = RequestVoteRequest{
                .term = self.current_term,
                .candidate_id = self.config.node_id,
                .last_log_index = self.getLastLogIndex(),
                .last_log_term = self.getLastLogTerm(),
            };

            var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
            defer aw.deinit();
            try protobuf.encode(&aw.writer, self.allocator, request);
            const payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
            defer self.allocator.free(payload);

            for (self.config.peers) |peer| {
                callback(peer, .request_vote, payload);
            }
        }
    }

    fn sendHeartbeats(self: *RaftNode) !void {
        if (self.state != .leader) return;

        try self.sendAppendEntries();
    }

    fn sendAppendEntries(self: *RaftNode) !void {
        if (self.send_message_callback) |callback| {
            for (self.config.peers) |peer| {
                const next_idx = self.next_index.get(peer) orelse 1;
                const prev_log_index = if (next_idx > 1) next_idx - 1 else 0;
                const prev_log_term = if (prev_log_index > 0 and prev_log_index <= self.log.items.len)
                    self.log.items[prev_log_index - 1].term
                else
                    0;

                // Get entries to send
                var entries = std.ArrayList(LogEntry).init(self.allocator);
                defer entries.deinit(self.allocator);

                if (next_idx <= self.log.items.len) {
                    for (self.log.items[next_idx - 1 ..]) |entry| {
                        try entries.append(self.allocator, entry);
                    }
                }

                const request = AppendEntriesRequest{
                    .term = self.current_term,
                    .leader_id = self.config.node_id,
                    .prev_log_index = prev_log_index,
                    .prev_log_term = prev_log_term,
                    .entries = entries,
                    .leader_commit = self.commit_index,
                };

                var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 512);
                defer aw.deinit();
                try protobuf.encode(&aw.writer, self.allocator, request);
                const payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
                defer self.allocator.free(payload);

                callback(peer, .append_entries, payload);
            }
        }
    }

    fn applyCommittedEntries(self: *RaftNode) !void {
        while (self.last_applied < self.commit_index) {
            self.last_applied += 1;

            if (self.last_applied <= self.log.items.len) {
                const entry = self.log.items[self.last_applied - 1];

                if (self.apply_callback) |callback| {
                    callback(entry.command);
                }
            }
        }
    }

    fn handleRequestVote(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        var reader: std.Io.Reader = .fixed(payload);
        var request = protobuf.decode(RequestVoteRequest, &reader, self.allocator) catch return;
        defer request.deinit(self.allocator);

        var vote_granted = false;

        if (request.term > self.current_term) {
            self.current_term = request.term;
            self.state = .follower;
            if (self.voted_for) |voted| {
                self.allocator.free(voted);
                self.voted_for = null;
            }
        }

        if (request.term == self.current_term) {
            const can_vote = self.voted_for == null or
                std.mem.eql(u8, self.voted_for.?, request.candidate_id);

            const log_ok = request.last_log_term > self.getLastLogTerm() or
                (request.last_log_term == self.getLastLogTerm() and
                    request.last_log_index >= self.getLastLogIndex());

            if (can_vote and log_ok) {
                vote_granted = true;
                if (self.voted_for) |voted| {
                    self.allocator.free(voted);
                }
                self.voted_for = try self.allocator.dupe(u8, request.candidate_id);
                try self.resetElectionTimer();
            }
        }

        const response = RequestVoteResponse{
            .term = self.current_term,
            .vote_granted = vote_granted,
        };

        if (self.send_message_callback) |callback| {
            var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
            defer aw.deinit();
            try protobuf.encode(&aw.writer, self.allocator, response);
            const response_payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
            defer self.allocator.free(response_payload);
            callback(from, .request_vote_response, response_payload);
        }
    }

    fn handleRequestVoteResponse(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        _ = from;

        if (self.state != .candidate) return;

        var reader: std.Io.Reader = .fixed(payload);
        var response = protobuf.decode(RequestVoteResponse, &reader, self.allocator) catch return;
        defer response.deinit(self.allocator);

        if (response.term > self.current_term) {
            self.current_term = response.term;
            self.state = .follower;
            if (self.voted_for) |voted| {
                self.allocator.free(voted);
                self.voted_for = null;
            }
            return;
        }

        if (response.term == self.current_term and response.vote_granted) {
            self.votes_received += 1;

            const majority = (self.config.peers.len + 1) / 2 + 1;
            if (self.votes_received >= majority) {
                self.state = .leader;

                // Initialize leader state
                for (self.config.peers) |peer| {
                    try self.next_index.put(peer, self.getLastLogIndex() + 1);
                    try self.match_index.put(peer, 0);
                }

                try self.resetHeartbeatTimer();

                // Send initial heartbeats
                if (self.enable_log_replication) {
                    try self.sendHeartbeats();
                }
            }
        }
    }

    fn handleAppendEntries(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        var reader: std.Io.Reader = .fixed(payload);
        var request = protobuf.decode(AppendEntriesRequest, &reader, self.allocator) catch return;
        defer request.deinit(self.allocator);

        var success = false;

        if (request.term >= self.current_term) {
            self.current_term = request.term;
            self.state = .follower;
            try self.resetElectionTimer();

            // Log consistency check
            if (request.prev_log_index == 0 or
                (request.prev_log_index <= self.log.items.len and
                    self.log.items[request.prev_log_index - 1].term == request.prev_log_term))
            {
                success = true;

                // Append new entries
                if (request.entries.items.len > 0) {
                    // Remove conflicting entries
                    if (request.prev_log_index < self.log.items.len) {
                        // Truncate log
                        while (self.log.items.len > request.prev_log_index) {
                            const removed = self.log.pop();
                            self.allocator.free(removed.command);
                        }
                    }

                    // Append new entries
                    for (request.entries.items) |entry| {
                        const new_entry = LogEntry{
                            .term = entry.term,
                            .index = entry.index,
                            .command = try self.allocator.dupe(u8, entry.command),
                            .timestamp = entry.timestamp,
                        };
                        try self.log.append(self.allocator, new_entry);
                    }
                }

                // Update commit index
                if (request.leader_commit > self.commit_index) {
                    self.commit_index = @min(request.leader_commit, self.getLastLogIndex());
                }
            }
        }

        const response = AppendEntriesResponse{
            .term = self.current_term,
            .success = success,
            .match_index = if (success) self.getLastLogIndex() else 0,
        };

        if (self.send_message_callback) |callback| {
            var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
            defer aw.deinit();
            try protobuf.encode(&aw.writer, self.allocator, response);
            const response_payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
            defer self.allocator.free(response_payload);
            callback(from, .append_entries_response, response_payload);
        }
    }

    fn handleAppendEntriesResponse(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        if (self.state != .leader) return;

        var reader: std.Io.Reader = .fixed(payload);
        var response = protobuf.decode(AppendEntriesResponse, &reader, self.allocator) catch return;
        defer response.deinit(self.allocator);

        if (response.term > self.current_term) {
            self.current_term = response.term;
            self.state = .follower;
            if (self.voted_for) |voted| {
                self.allocator.free(voted);
                self.voted_for = null;
            }
            return;
        }

        if (response.term == self.current_term) {
            if (response.success) {
                try self.next_index.put(from, response.match_index + 1);
                try self.match_index.put(from, response.match_index);

                // Update commit index
                try self.updateCommitIndex();
            } else {
                // Decrement next_index and retry
                const current_next = self.next_index.get(from) orelse 1;
                if (current_next > 1) {
                    try self.next_index.put(from, current_next - 1);
                }
            }
        }
    }

    // CANARY: REQ=REQ-RAFT-SNAPSHOT-001; FEATURE="SnapshotInstallation"; ASPECT=HandleInstallSnapshot; STATUS=EXEMPT; OWNER=raft; UPDATED=2026-01-10
    fn handleInstallSnapshot(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        var reader: std.Io.Reader = .fixed(payload);
        var msg = protobuf.decode(SnapshotRequest, &reader, self.allocator) catch return;
        defer msg.deinit(self.allocator);

        // If term < current term, ignore
        if (msg.term < self.current_term) {
            return;
        }

        // Update term if necessary
        if (msg.term > self.current_term) {
            self.current_term = msg.term;
            self.voted_for = null;
            self.state = .follower;
        }

        // If snapshot is complete, update state
        if (msg.done) {
            // Discard log entries up to last_included_index
            // In a full implementation, this would also restore state machine from snapshot data
            self.commit_index = msg.last_included_index;
            self.last_applied = msg.last_included_index;

            // Truncate log (simplified: just clear it since we'd have the snapshot)
            self.log.clearAndFree();
        }

        // Send response
        if (self.send_message_callback) |send_fn| {
            const response_obj = SnapshotResponse{ .term = self.current_term };
            var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
            defer aw.deinit();
            try protobuf.encode(&aw.writer, self.allocator, response_obj);
            const response_payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
            defer self.allocator.free(response_payload);
            send_fn(from, .install_snapshot_response, response_payload);
        }
    }

    // CANARY: REQ=REQ-RAFT-SNAPSHOT-001; FEATURE="SnapshotInstallation"; ASPECT=HandleSnapshotResponse; STATUS=EXEMPT; OWNER=raft; UPDATED=2026-01-10
    fn handleInstallSnapshotResponse(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        // Only leaders process snapshot responses
        if (self.state != .leader) {
            return;
        }

        var reader: std.Io.Reader = .fixed(payload);
        var msg = protobuf.decode(SnapshotResponse, &reader, self.allocator) catch return;
        defer msg.deinit(self.allocator);

        // If term is higher, step down
        if (msg.term > self.current_term) {
            self.current_term = msg.term;
            self.voted_for = null;
            self.state = .follower;
            return;
        }

        // On successful snapshot installation, update next_index for the follower
        // This would typically be the snapshot's last_included_index + 1
        // For now, update to current log length
        try self.next_index.put(from, self.getLastLogIndex() + 1);
        try self.match_index.put(from, self.getLastLogIndex());
    }

    fn updateCommitIndex(self: *RaftNode) !void {
        // Find the highest index that is replicated on a majority of servers
        var indices = std.ArrayList(u64).init(self.allocator);
        defer indices.deinit(self.allocator);

        // Add leader's match index
        try indices.append(self.allocator, self.getLastLogIndex());

        // Add followers' match indices
        var iter = self.match_index.iterator();
        while (iter.next()) |entry| {
            try indices.append(self.allocator, entry.value_ptr.*);
        }

        // Sort indices in descending order
        std.mem.sort(u64, indices.items, {}, struct {
            fn lessThan(_: void, a: u64, b: u64) bool {
                return a > b;
            }
        }.lessThan);

        // Find majority index
        const majority_idx = indices.items.len / 2;
        if (majority_idx < indices.items.len) {
            const new_commit_index = indices.items[majority_idx];

            // Only commit entries from current term
            if (new_commit_index > self.commit_index and
                new_commit_index <= self.log.items.len and
                self.log.items[new_commit_index - 1].term == self.current_term)
            {
                self.commit_index = new_commit_index;
            }
        }
    }
};

// Tests
test "raft node initialization" {
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &[_][]const u8{ "node2", "node3" },
    };

    var node = try RaftNode.init(std.testing.allocator, config);
    defer node.deinit();

    try std.testing.expect(node.state == .follower);
    try std.testing.expect(node.current_term == 0);
    try std.testing.expect(node.voted_for == null);
}

test "raft single node mode" {
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &[_][]const u8{},
    };

    var node = try RaftNode.init(std.testing.allocator, config);
    defer node.deinit();

    try node.start();

    try std.testing.expect(node.state == .leader);

    // Test proposal in single-node mode
    const success = try node.propose("test command");
    try std.testing.expect(success);
    try std.testing.expect(node.log.items.len == 1);
    try std.testing.expect(node.commit_index == 1);
}

test "raft leader election disabled" {
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &[_][]const u8{ "node2", "node3" },
    };

    var node = try RaftNode.init(std.testing.allocator, config);
    defer node.deinit();

    node.enableFeatures(false, false); // Disable both features

    try node.start();

    // Should become leader immediately when election is disabled
    try std.testing.expect(node.state == .leader);
}
