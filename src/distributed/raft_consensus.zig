const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;

// Raft consensus implementation for leader election
pub const RaftNode = struct {
    allocator: Allocator,
    id: u64,
    state: State,
    current_term: u64,
    voted_for: ?u64,
    log: std.ArrayList(LogEntry),
    commit_index: u64,
    last_applied: u64,

    // Leader state
    next_index: ?std.AutoHashMap(u64, u64),
    match_index: ?std.AutoHashMap(u64, u64),

    // Configuration
    peers: []Peer,
    election_timeout_ms: u64,
    heartbeat_interval_ms: u64,

    // Timers
    last_heartbeat: i64,
    election_timer: i64,

    pub const State = enum {
        follower,
        candidate,
        leader,
    };

    pub const Peer = struct {
        id: u64,
        address: net.Address,
        alive: bool,
    };

    pub const LogEntry = struct {
        term: u64,
        index: u64,
        command: Command,
        timestamp: i64,
    };

    pub const Command = union(enum) {
        noop,
        write: []const u8,
        config_change: ConfigChange,
    };

    pub const ConfigChange = struct {
        add_peer: ?Peer,
        remove_peer: ?u64,
    };

    pub const Message = union(enum) {
        request_vote: RequestVote,
        request_vote_response: RequestVoteResponse,
        append_entries: AppendEntries,
        append_entries_response: AppendEntriesResponse,
        install_snapshot: InstallSnapshot,
        install_snapshot_response: InstallSnapshotResponse,
    };

    pub const RequestVote = struct {
        term: u64,
        candidate_id: u64,
        last_log_index: u64,
        last_log_term: u64,
    };

    pub const RequestVoteResponse = struct {
        term: u64,
        vote_granted: bool,
    };

    pub const AppendEntries = struct {
        term: u64,
        leader_id: u64,
        prev_log_index: u64,
        prev_log_term: u64,
        entries: []LogEntry,
        leader_commit: u64,
    };

    pub const AppendEntriesResponse = struct {
        term: u64,
        success: bool,
        match_index: u64,
    };

    pub const InstallSnapshot = struct {
        term: u64,
        leader_id: u64,
        last_included_index: u64,
        last_included_term: u64,
        offset: u64,
        data: []const u8,
        done: bool,
    };

    pub const InstallSnapshotResponse = struct {
        term: u64,
    };

    pub fn init(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
    ) !RaftNode {
        return RaftNode{
            .allocator = allocator,
            .id = id,
            .state = .follower,
            .current_term = 0,
            .voted_for = null,
            .log = std.ArrayList(LogEntry).init(allocator),
            .commit_index = 0,
            .last_applied = 0,
            .next_index = null,
            .match_index = null,
            .peers = peers,
            .election_timeout_ms = election_timeout_ms,
            .heartbeat_interval_ms = election_timeout_ms / 10,
            .last_heartbeat = std.time.milliTimestamp(),
            .election_timer = std.time.milliTimestamp() + @as(i64, @intCast(election_timeout_ms)),
        };
    }

    pub fn deinit(self: *RaftNode) void {
        self.log.deinit();
        if (self.next_index) |*ni| ni.deinit();
        if (self.match_index) |*mi| mi.deinit();
    }

    pub fn tick(self: *RaftNode) !void {
        const now = std.time.milliTimestamp();

        switch (self.state) {
            .follower => {
                if (now > self.election_timer) {
                    try self.startElection();
                }
            },
            .candidate => {
                if (now > self.election_timer) {
                    // Election timeout, start new election
                    try self.startElection();
                }
            },
            .leader => {
                if (now - self.last_heartbeat > @as(i64, @intCast(self.heartbeat_interval_ms))) {
                    try self.sendHeartbeats();
                    self.last_heartbeat = now;
                }
            },
        }
    }

    pub fn handleMessage(self: *RaftNode, msg: Message, from: u64) !void {
        switch (msg) {
            .request_vote => |rv| try self.handleRequestVote(rv, from),
            .request_vote_response => |rvr| try self.handleRequestVoteResponse(rvr, from),
            .append_entries => |ae| try self.handleAppendEntries(ae, from),
            .append_entries_response => |aer| try self.handleAppendEntriesResponse(aer, from),
            .install_snapshot => |is| try self.handleInstallSnapshot(is, from),
            .install_snapshot_response => |isr| try self.handleInstallSnapshotResponse(isr, from),
        }
    }

    fn startElection(self: *RaftNode) !void {
        self.state = .candidate;
        self.current_term += 1;
        self.voted_for = self.id;
        self.resetElectionTimer();

        std.log.info("Node {} starting election for term {}", .{ self.id, self.current_term });

        // Vote for self
        var votes_received: u64 = 1;

        // Request votes from peers
        const last_log_index = if (self.log.items.len > 0) self.log.items[self.log.items.len - 1].index else 0;
        const last_log_term = if (self.log.items.len > 0) self.log.items[self.log.items.len - 1].term else 0;

        for (self.peers) |peer| {
            if (peer.id == self.id) continue;

            const msg = Message{
                .request_vote = .{
                    .term = self.current_term,
                    .candidate_id = self.id,
                    .last_log_index = last_log_index,
                    .last_log_term = last_log_term,
                },
            };

            try self.sendMessage(peer, msg);
        }

        // Check if we already have majority (single node cluster)
        if (votes_received > self.peers.len / 2) {
            try self.becomeLeader();
        }
    }

    fn becomeLeader(self: *RaftNode) !void {
        std.log.info("Node {} became leader for term {}", .{ self.id, self.current_term });

        self.state = .leader;

        // Initialize leader state
        self.next_index = std.AutoHashMap(u64, u64).init(self.allocator);
        self.match_index = std.AutoHashMap(u64, u64).init(self.allocator);

        const last_log_index = if (self.log.items.len > 0) self.log.items[self.log.items.len - 1].index else 0;

        for (self.peers) |peer| {
            if (peer.id == self.id) continue;
            try self.next_index.?.put(peer.id, last_log_index + 1);
            try self.match_index.?.put(peer.id, 0);
        }

        // Send initial heartbeat
        try self.sendHeartbeats();
    }

    fn sendHeartbeats(self: *RaftNode) !void {
        for (self.peers) |peer| {
            if (peer.id == self.id) continue;

            const next_idx = self.next_index.?.get(peer.id) orelse 1;
            const prev_log_index = if (next_idx > 1) next_idx - 1 else 0;
            const prev_log_term = if (prev_log_index > 0) self.getLogTerm(prev_log_index) else 0;

            const msg = Message{
                .append_entries = .{
                    .term = self.current_term,
                    .leader_id = self.id,
                    .prev_log_index = prev_log_index,
                    .prev_log_term = prev_log_term,
                    .entries = &[_]LogEntry{}, // Empty for heartbeat
                    .leader_commit = self.commit_index,
                },
            };

            try self.sendMessage(peer, msg);
        }
    }

    fn handleRequestVote(self: *RaftNode, rv: RequestVote, from: u64) !void {
        var vote_granted = false;

        if (rv.term > self.current_term) {
            self.current_term = rv.term;
            self.state = .follower;
            self.voted_for = null;
        }

        if (rv.term == self.current_term and
            (self.voted_for == null or self.voted_for.? == rv.candidate_id))
        {
            // Check if candidate's log is at least as up-to-date as ours
            const last_log_index = if (self.log.items.len > 0) self.log.items[self.log.items.len - 1].index else 0;
            const last_log_term = if (self.log.items.len > 0) self.log.items[self.log.items.len - 1].term else 0;

            if (rv.last_log_term > last_log_term or
                (rv.last_log_term == last_log_term and rv.last_log_index >= last_log_index))
            {
                vote_granted = true;
                self.voted_for = rv.candidate_id;
                self.resetElectionTimer();
            }
        }

        const response = Message{
            .request_vote_response = .{
                .term = self.current_term,
                .vote_granted = vote_granted,
            },
        };

        const peer = self.getPeer(from) orelse return;
        try self.sendMessage(peer, response);
    }

    fn handleRequestVoteResponse(self: *RaftNode, rvr: RequestVoteResponse, from: u64) !void {
        _ = from;

        if (rvr.term > self.current_term) {
            self.current_term = rvr.term;
            self.state = .follower;
            self.voted_for = null;
            return;
        }

        if (self.state != .candidate or rvr.term != self.current_term) {
            return;
        }

        if (rvr.vote_granted) {
            // Count votes
            var votes: u64 = 1; // Self vote
            for (self.peers) |peer| {
                if (peer.id == self.id) continue;
                // In real implementation, track which peers voted
                votes += 1;
            }

            if (votes > self.peers.len / 2) {
                try self.becomeLeader();
            }
        }
    }

    fn handleAppendEntries(self: *RaftNode, ae: AppendEntries, from: u64) !void {
        var success = false;
        var match_index: u64 = 0;

        if (ae.term >= self.current_term) {
            if (ae.term > self.current_term) {
                self.current_term = ae.term;
                self.voted_for = null;
            }
            self.state = .follower;
            self.resetElectionTimer();

            // Check if we have the previous log entry
            if (ae.prev_log_index == 0 or
                (ae.prev_log_index <= self.log.items.len and
                    self.getLogTerm(ae.prev_log_index) == ae.prev_log_term))
            {
                success = true;

                // Append new entries
                var i: usize = 0;
                while (i < ae.entries.len) : (i += 1) {
                    const entry = ae.entries[i];
                    if (entry.index <= self.log.items.len) {
                        // Check for conflicts
                        if (self.log.items[entry.index - 1].term != entry.term) {
                            // Delete conflicting entries
                            self.log.shrinkRetainingCapacity(entry.index - 1);
                        }
                    }

                    if (entry.index > self.log.items.len) {
                        try self.log.append(entry);
                    }
                }

                match_index = ae.prev_log_index + ae.entries.len;

                // Update commit index
                if (ae.leader_commit > self.commit_index) {
                    self.commit_index = @min(ae.leader_commit, match_index);
                    try self.applyCommittedEntries();
                }
            }
        }

        const response = Message{
            .append_entries_response = .{
                .term = self.current_term,
                .success = success,
                .match_index = match_index,
            },
        };

        const peer = self.getPeer(from) orelse return;
        try self.sendMessage(peer, response);
    }

    fn handleAppendEntriesResponse(self: *RaftNode, aer: AppendEntriesResponse, from: u64) !void {
        if (aer.term > self.current_term) {
            self.current_term = aer.term;
            self.state = .follower;
            self.voted_for = null;
            return;
        }

        if (self.state != .leader) return;

        if (aer.success) {
            // Update match and next index
            try self.match_index.?.put(from, aer.match_index);
            try self.next_index.?.put(from, aer.match_index + 1);

            // Check if we can advance commit index
            try self.updateCommitIndex();
        } else {
            // Decrement next index and retry
            const next_idx = self.next_index.?.get(from) orelse 1;
            if (next_idx > 1) {
                try self.next_index.?.put(from, next_idx - 1);
            }
        }
    }

    fn handleInstallSnapshot(self: *RaftNode, is: InstallSnapshot, from: u64) !void {
        _ = is;
        _ = from;
        // Snapshot installation logic
        // This is a simplified version - real implementation would handle chunked transfers
    }

    fn handleInstallSnapshotResponse(self: *RaftNode, isr: InstallSnapshotResponse, from: u64) !void {
        _ = self;
        _ = isr;
        _ = from;
        // Handle snapshot installation response
    }

    fn updateCommitIndex(self: *RaftNode) !void {
        // Find the highest index that a majority has replicated
        var match_indices = std.ArrayList(u64).init(self.allocator);
        defer match_indices.deinit();

        try match_indices.append(self.log.items.len); // Leader's own log

        var iter = self.match_index.?.iterator();
        while (iter.next()) |entry| {
            try match_indices.append(entry.value_ptr.*);
        }

        std.mem.sort(u64, match_indices.items, {}, std.sort.desc(u64));

        const majority_index = match_indices.items[self.peers.len / 2];

        if (majority_index > self.commit_index and
            self.getLogTerm(majority_index) == self.current_term)
        {
            self.commit_index = majority_index;
            try self.applyCommittedEntries();
        }
    }

    fn applyCommittedEntries(self: *RaftNode) !void {
        while (self.last_applied < self.commit_index) {
            self.last_applied += 1;
            const entry = self.log.items[self.last_applied - 1];

            // Apply the command to the state machine
            switch (entry.command) {
                .write => |data| {
                    std.log.info("Applied write: {s}", .{data});
                },
                .config_change => |cc| {
                    if (cc.add_peer) |peer| {
                        // Add new peer
                        _ = peer;
                    }
                    if (cc.remove_peer) |peer_id| {
                        // Remove peer
                        _ = peer_id;
                    }
                },
                .noop => {},
            }
        }
    }

    fn getLogTerm(self: *RaftNode, index: u64) u64 {
        if (index == 0 or index > self.log.items.len) return 0;
        return self.log.items[index - 1].term;
    }

    fn resetElectionTimer(self: *RaftNode) void {
        const random_timeout = self.election_timeout_ms +
            (std.crypto.random.int(u64) % self.election_timeout_ms);
        self.election_timer = std.time.milliTimestamp() + @as(i64, @intCast(random_timeout));
    }

    fn getPeer(self: *RaftNode, id: u64) ?Peer {
        for (self.peers) |peer| {
            if (peer.id == id) return peer;
        }
        return null;
    }

    fn sendMessage(self: *RaftNode, peer: Peer, msg: Message) !void {
        _ = self;
        _ = peer;
        _ = msg;
        // Network implementation would go here
        // This would serialize the message and send it to the peer's address
    }

    pub fn propose(self: *RaftNode, command: Command) !void {
        if (self.state != .leader) {
            return error.NotLeader;
        }

        const entry = LogEntry{
            .term = self.current_term,
            .index = self.log.items.len + 1,
            .command = command,
            .timestamp = std.time.milliTimestamp(),
        };

        try self.log.append(entry);

        // Send to followers
        for (self.peers) |peer| {
            if (peer.id == self.id) continue;

            const next_idx = self.next_index.?.get(peer.id) orelse 1;
            const prev_log_index = if (next_idx > 1) next_idx - 1 else 0;
            const prev_log_term = if (prev_log_index > 0) self.getLogTerm(prev_log_index) else 0;

            const msg = Message{
                .append_entries = .{
                    .term = self.current_term,
                    .leader_id = self.id,
                    .prev_log_index = prev_log_index,
                    .prev_log_term = prev_log_term,
                    .entries = self.log.items[next_idx - 1 ..],
                    .leader_commit = self.commit_index,
                },
            };

            try self.sendMessage(peer, msg);
        }
    }
};
