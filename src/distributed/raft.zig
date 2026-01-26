// CANARY: REQ=REQ-GQL-040; FEATURE="Raft Consensus"; ASPECT=Distributed; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_040_RaftLeaderElection; BENCH=BenchmarkCANARY_REQ_GQL_040_RaftElectionLatency; OWNER=distributed; UPDATED=2025-09-21

const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-066; FEATURE="JSON Library Migration"; ASPECT=RaftConsensus; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-25
const json_lib = @import("json");

// JSON response types for Raft protocol
const SnapshotResponse = struct { term: u64 };

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

/// Request Vote RPC
pub const RequestVoteRequest = struct {
    term: u64,
    candidate_id: []const u8,
    last_log_index: u64,
    last_log_term: u64,
};

pub const RequestVoteResponse = struct {
    term: u64,
    vote_granted: bool,
};

/// Append Entries RPC
pub const AppendEntriesRequest = struct {
    term: u64,
    leader_id: []const u8,
    prev_log_index: u64,
    prev_log_term: u64,
    entries: []const LogEntry,
    leader_commit: u64,
};

pub const AppendEntriesResponse = struct {
    term: u64,
    success: bool,
    match_index: u64,
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
            .log = std.ArrayList(LogEntry){},
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
        self.log.deinit();
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

        try self.log.append(entry);

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

            // Serialize request (simplified)
            const payload = try std.json.stringifyAlloc(self.allocator, request, .{});
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
                var entries = std.ArrayList(LogEntry){};
                defer entries.deinit();

                if (next_idx <= self.log.items.len) {
                    for (self.log.items[next_idx - 1 ..]) |entry| {
                        try entries.append(entry);
                    }
                }

                const request = AppendEntriesRequest{
                    .term = self.current_term,
                    .leader_id = self.config.node_id,
                    .prev_log_index = prev_log_index,
                    .prev_log_term = prev_log_term,
                    .entries = entries.items,
                    .leader_commit = self.commit_index,
                };

                const payload = try std.json.stringifyAlloc(self.allocator, request, .{});
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
        const request = std.json.parseFromSlice(RequestVoteRequest, self.allocator, payload, .{}) catch return;
        defer request.deinit();

        var vote_granted = false;

        if (request.value.term > self.current_term) {
            self.current_term = request.value.term;
            self.state = .follower;
            if (self.voted_for) |voted| {
                self.allocator.free(voted);
                self.voted_for = null;
            }
        }

        if (request.value.term == self.current_term) {
            const can_vote = self.voted_for == null or
                std.mem.eql(u8, self.voted_for.?, request.value.candidate_id);

            const log_ok = request.value.last_log_term > self.getLastLogTerm() or
                (request.value.last_log_term == self.getLastLogTerm() and
                    request.value.last_log_index >= self.getLastLogIndex());

            if (can_vote and log_ok) {
                vote_granted = true;
                if (self.voted_for) |voted| {
                    self.allocator.free(voted);
                }
                self.voted_for = try self.allocator.dupe(u8, request.value.candidate_id);
                try self.resetElectionTimer();
            }
        }

        const response = RequestVoteResponse{
            .term = self.current_term,
            .vote_granted = vote_granted,
        };

        if (self.send_message_callback) |callback| {
            const response_payload = try std.json.stringifyAlloc(self.allocator, response, .{});
            defer self.allocator.free(response_payload);
            callback(from, .request_vote_response, response_payload);
        }
    }

    fn handleRequestVoteResponse(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        _ = from;

        if (self.state != .candidate) return;

        const response = std.json.parseFromSlice(RequestVoteResponse, self.allocator, payload, .{}) catch return;
        defer response.deinit();

        if (response.value.term > self.current_term) {
            self.current_term = response.value.term;
            self.state = .follower;
            if (self.voted_for) |voted| {
                self.allocator.free(voted);
                self.voted_for = null;
            }
            return;
        }

        if (response.value.term == self.current_term and response.value.vote_granted) {
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
        const request = std.json.parseFromSlice(AppendEntriesRequest, self.allocator, payload, .{}) catch return;
        defer request.deinit();

        var success = false;

        if (request.value.term >= self.current_term) {
            self.current_term = request.value.term;
            self.state = .follower;
            try self.resetElectionTimer();

            // Log consistency check
            if (request.value.prev_log_index == 0 or
                (request.value.prev_log_index <= self.log.items.len and
                    self.log.items[request.value.prev_log_index - 1].term == request.value.prev_log_term))
            {
                success = true;

                // Append new entries
                if (request.value.entries.len > 0) {
                    // Remove conflicting entries
                    if (request.value.prev_log_index < self.log.items.len) {
                        // Truncate log
                        while (self.log.items.len > request.value.prev_log_index) {
                            const removed = self.log.pop();
                            self.allocator.free(removed.command);
                        }
                    }

                    // Append new entries
                    for (request.value.entries) |entry| {
                        const new_entry = LogEntry{
                            .term = entry.term,
                            .index = entry.index,
                            .command = try self.allocator.dupe(u8, entry.command),
                            .timestamp = entry.timestamp,
                        };
                        try self.log.append(new_entry);
                    }
                }

                // Update commit index
                if (request.value.leader_commit > self.commit_index) {
                    self.commit_index = @min(request.value.leader_commit, self.getLastLogIndex());
                }
            }
        }

        const response = AppendEntriesResponse{
            .term = self.current_term,
            .success = success,
            .match_index = if (success) self.getLastLogIndex() else 0,
        };

        if (self.send_message_callback) |callback| {
            const response_payload = try std.json.stringifyAlloc(self.allocator, response, .{});
            defer self.allocator.free(response_payload);
            callback(from, .append_entries_response, response_payload);
        }
    }

    fn handleAppendEntriesResponse(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        if (self.state != .leader) return;

        const response = std.json.parseFromSlice(AppendEntriesResponse, self.allocator, payload, .{}) catch return;
        defer response.deinit();

        if (response.value.term > self.current_term) {
            self.current_term = response.value.term;
            self.state = .follower;
            if (self.voted_for) |voted| {
                self.allocator.free(voted);
                self.voted_for = null;
            }
            return;
        }

        if (response.value.term == self.current_term) {
            if (response.value.success) {
                try self.next_index.put(from, response.value.match_index + 1);
                try self.match_index.put(from, response.value.match_index);

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
        // Parse snapshot metadata from payload (JSON format expected)
        const parsed = std.json.parseFromSlice(
            struct { term: u64, last_included_index: u64, last_included_term: u64, done: bool },
            self.allocator,
            payload,
            .{},
        ) catch return;
        defer parsed.deinit();

        const msg = parsed.value;

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
            const response_json = json_lib.encode(self.allocator, response_obj, .{}) catch return;
            defer self.allocator.free(response_json);
            send_fn(from, .install_snapshot_response, response_json);
        }
    }

    // CANARY: REQ=REQ-RAFT-SNAPSHOT-001; FEATURE="SnapshotInstallation"; ASPECT=HandleSnapshotResponse; STATUS=EXEMPT; OWNER=raft; UPDATED=2026-01-10
    fn handleInstallSnapshotResponse(self: *RaftNode, from: []const u8, payload: []const u8) !void {
        // Only leaders process snapshot responses
        if (self.state != .leader) {
            return;
        }

        // Parse response
        const parsed = std.json.parseFromSlice(
            struct { term: u64 },
            self.allocator,
            payload,
            .{},
        ) catch return;
        defer parsed.deinit();

        const msg = parsed.value;

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
        var indices = std.ArrayList(u64){};
        defer indices.deinit();

        // Add leader's match index
        try indices.append(self.getLastLogIndex());

        // Add followers' match indices
        var iter = self.match_index.iterator();
        while (iter.next()) |entry| {
            try indices.append(entry.value_ptr.*);
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
