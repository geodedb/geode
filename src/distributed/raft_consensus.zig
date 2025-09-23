const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.raft);

// Forward declarations and types
pub const State = enum {
    follower,
    candidate,
    leader,
    shutdown,
};

pub const Command = union(enum) {
    noop,
    write: []const u8,
    graph_mutation: GraphMutation,
    schema_change: SchemaChange,
    config_change: ConfigChange,
    snapshot_pointer: SnapshotPointer,
};

pub const GraphMutation = struct {
    graph: []const u8,
    mutation_type: enum { create, update, delete, merge },
    data: []const u8,
    txn_id: ?u64,
};

pub const SchemaChange = struct {
    operation: enum { create_graph, drop_graph, alter_graph },
    graph: []const u8,
    schema: []const u8,
};

pub const ConfigChange = struct {
    change_type: enum { add_server, remove_server, update_server },
    server_id: u64,
    server_endpoint: ?[]const u8,
    server_port: ?u16 = null,
};

pub const SnapshotPointer = struct {
    last_included_index: u64,
    last_included_term: u64,
    size_bytes: u64,
    checksum: u64,
};

pub const LogEntry = struct {
    term: u64,
    index: u64,
    command: Command,
    timestamp: i64,
    client_id: ?u64,
    serial_number: ?u64,
};

pub const Peer = struct {
    id: u64,
    endpoint: []const u8,
    port: u16,
    alive: bool,
    last_contact: i64,
    rpc_client: ?*RpcClient,
};

pub const Statistics = struct {
    elections_called: u64,
    elections_won: u64,
    elections_lost: u64,
    heartbeats_sent: u64,
    entries_appended: u64,
    entries_committed: u64,
    entries_applied: u64,
    snapshots_sent: u64,
    snapshots_received: u64,
};

// RPC client for peer communication
const quic = @import("transport/quic");
pub const RpcClient = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16,
    client: ?quic.QuicClient = null,
    stream: ?*quic.QuicClientStream = null,

    pub fn deinit(self: *RpcClient) void {
        if (self.stream) |s| s.deinit();
        if (self.client) |*c| c.deinit();
        self.stream = null;
        self.client = null;
    }

    pub fn sendMessage(self: *RpcClient, msg: Message) !void {
        if (self.client == null) {
            var qc = quic.QuicClient.init(self.allocator);
            try qc.connect(self.host, self.port);
            self.client = qc;
            self.stream = try self.client.?.getStream();
        }
        const payload = try std.json.stringifyAlloc(self.allocator, msg, .{});
        defer self.allocator.free(payload);
        try self.stream.?.writeAll(payload);
        try self.stream.?.writeAll("\n");
    }
};

// Transport abstraction for network communication
pub const Transport = struct {
    allocator: Allocator,
    server: ?quic.QuicTransport = null,

    pub fn init(allocator: Allocator) Transport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Transport) void {
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    pub fn listen(self: *Transport, address: []const u8, port: u16) !void {
        const qt = try quic.QuicTransport.init(self.allocator, .{ .address = address, .port = port });
        self.server = qt;
        try self.server.?.listen();
    }

    pub fn send(self: *Transport, peer: Peer, data: []const u8) !void {
        var qc = quic.QuicClient.init(self.allocator);
        defer qc.deinit();
        try qc.connect(peer.endpoint, peer.port);
        const s = try qc.getStream();
        defer s.deinit();
        try s.writeAll(data);
        try s.writeAll("\n");
    }
};

// Persistent storage for Raft state
pub const PersistentStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,
    current_term_file: ?std.fs.File,
    voted_for_file: ?std.fs.File,
    log_file: ?std.fs.File,

    pub fn init(allocator: Allocator, data_dir: []const u8) !PersistentStorage {
        return PersistentStorage{
            .allocator = allocator,
            .data_dir = data_dir,
            .current_term_file = null,
            .voted_for_file = null,
            .log_file = null,
        };
    }

    pub fn close(self: *PersistentStorage) void {
        if (self.current_term_file) |f| f.close();
        if (self.voted_for_file) |f| f.close();
        if (self.log_file) |f| f.close();
    }

    pub fn getCurrentTerm(self: *PersistentStorage) !?u64 {
        _ = self;
        return null; // Implementation would read from file
    }

    pub fn saveCurrentTerm(self: *PersistentStorage, term: u64) !void {
        _ = self;
        _ = term;
    }

    pub fn getVotedFor(self: *PersistentStorage) !?u64 {
        _ = self;
        return null;
    }

    pub fn saveVotedFor(self: *PersistentStorage, node_id: ?u64) !void {
        _ = self;
        _ = node_id;
    }

    pub fn getLogEntries(self: *PersistentStorage, allocator: Allocator) ![]LogEntry {
        _ = self;
        _ = allocator;
        return &[_]LogEntry{};
    }

    pub fn appendLogEntry(self: *PersistentStorage, entry: LogEntry) !void {
        _ = self;
        _ = entry;
    }
};

// Message types
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
    pre_vote: bool, // Pre-vote optimization
};

pub const RequestVoteResponse = struct {
    term: u64,
    vote_granted: bool,
    voter_id: u64,
};

pub const AppendEntries = struct {
    term: u64,
    leader_id: u64,
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

// Raft consensus implementation for leader election and log replication
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

    // Candidate state
    votes_received: std.AutoHashMap(u64, bool),
    election_round: u64,

    // Network and persistence
    transport: ?*Transport,
    storage: ?*PersistentStorage,

    // Callbacks for state machine
    apply_callback: ?*const fn (allocator: Allocator, cmd: Command) anyerror![]u8,
    snapshot_callback: ?*const fn (allocator: Allocator) anyerror![]u8,
    restore_callback: ?*const fn (allocator: Allocator, data: []const u8) anyerror!void,

    // Statistics
    stats: Statistics,

    pub fn init(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
    ) !RaftNode {
        const log_list = try std.ArrayList(LogEntry).initCapacity(allocator, 10);

        var node = RaftNode{
            .allocator = allocator,
            .id = id,
            .state = .follower,
            .current_term = 0,
            .voted_for = null,
            .log = log_list,
            .commit_index = 0,
            .last_applied = 0,
            .next_index = null,
            .match_index = null,
            .peers = peers,
            .election_timeout_ms = election_timeout_ms,
            .heartbeat_interval_ms = @max(50, election_timeout_ms / 10),
            .last_heartbeat = std.time.milliTimestamp(),
            .election_timer = std.time.milliTimestamp() + @as(i64, @intCast(election_timeout_ms)),
            .votes_received = std.AutoHashMap(u64, bool).init(allocator),
            .election_round = 0,
            .transport = null,
            .storage = null,
            .apply_callback = null,
            .snapshot_callback = null,
            .restore_callback = null,
            .stats = Statistics{
                .elections_called = 0,
                .elections_won = 0,
                .elections_lost = 0,
                .heartbeats_sent = 0,
                .entries_appended = 0,
                .entries_committed = 0,
                .entries_applied = 0,
                .snapshots_sent = 0,
                .snapshots_received = 0,
            },
        };

        // Add initial noop entry to simplify log indexing
        try node.log.append(allocator, .{
            .term = 0,
            .index = 0,
            .command = .noop,
            .timestamp = std.time.milliTimestamp(),
            .client_id = null,
            .serial_number = null,
        });

        return node;
    }

    pub fn deinit(self: *RaftNode) void {
        self.state = .shutdown;
        self.log.deinit(self.allocator);
        self.votes_received.deinit();
        if (self.next_index) |*ni| ni.deinit();
        if (self.match_index) |*mi| mi.deinit();
        if (self.transport) |t| t.deinit();
        if (self.storage) |s| s.close();
    }

    pub fn setTransport(self: *RaftNode, transport: *Transport) void {
        self.transport = transport;
    }

    pub fn setStorage(self: *RaftNode, storage: *PersistentStorage) !void {
        self.storage = storage;

        // Restore persistent state
        if (try storage.getCurrentTerm()) |term| {
            self.current_term = term;
        }
        if (try storage.getVotedFor()) |voted| {
            self.voted_for = voted;
        }

        // Restore log entries
        const entries = try storage.getLogEntries(self.allocator);
        defer self.allocator.free(entries);

        self.log.clearRetainingCapacity();
        for (entries) |entry| {
            try self.log.append(self.allocator, entry);
        }
    }

    pub fn setCallbacks(
        self: *RaftNode,
        apply_fn: *const fn (allocator: Allocator, cmd: Command) anyerror![]u8,
        snapshot_fn: *const fn (allocator: Allocator) anyerror![]u8,
        restore_fn: *const fn (allocator: Allocator, data: []const u8) anyerror!void,
    ) void {
        self.apply_callback = apply_fn;
        self.snapshot_callback = snapshot_fn;
        self.restore_callback = restore_fn;
    }

    pub fn tick(self: *RaftNode) !void {
        if (self.state == .shutdown) return;

        const now = std.time.milliTimestamp();

        switch (self.state) {
            .follower => {
                if (now > self.election_timer) {
                    log.info("Election timeout, starting election (node {})", .{self.id});
                    try self.startElection();
                }
            },
            .candidate => {
                if (now > self.election_timer) {
                    log.info("Election timeout in candidate state, restarting election (node {})", .{self.id});
                    try self.startElection();
                }
            },
            .leader => {
                if (now - self.last_heartbeat > @as(i64, @intCast(self.heartbeat_interval_ms))) {
                    try self.sendHeartbeats();
                    self.last_heartbeat = now;
                    self.stats.heartbeats_sent += @as(u64, @intCast(self.peers.len));
                }

                // Check for dead peers
                for (self.peers) |*peer| {
                    if (peer.id == self.id) continue;
                    if (now - peer.last_contact > @as(i64, @intCast(self.election_timeout_ms * 2))) {
                        if (peer.alive) {
                            log.warn("Peer {} appears to be dead", .{peer.id});
                            peer.alive = false;
                        }
                    }
                }
            },
            .shutdown => {},
        }

        // Apply committed entries
        try self.applyCommittedEntries();
    }

    pub fn handleMessage(self: *RaftNode, from: u64, msg: Message) !void {
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
        self.election_round += 1;
        self.resetElectionTimer();

        // Persist state
        if (self.storage) |storage| {
            try storage.saveCurrentTerm(self.current_term);
            try storage.saveVotedFor(self.voted_for);
        }

        log.info("Node {} starting election for term {} (round {})", .{ self.id, self.current_term, self.election_round });

        self.stats.elections_called += 1;

        // Clear previous votes and vote for self
        self.votes_received.clearRetainingCapacity();
        try self.votes_received.put(self.id, true);

        // Request votes from peers
        const last_log_index = self.getLastLogIndex();
        const last_log_term = self.getLastLogTerm();

        for (self.peers) |peer| {
            if (peer.id == self.id) continue;
            if (!peer.alive) continue;

            const msg = Message{
                .request_vote = .{
                    .term = self.current_term,
                    .candidate_id = self.id,
                    .last_log_index = last_log_index,
                    .last_log_term = last_log_term,
                    .pre_vote = false,
                },
            };

            try self.sendMessage(peer, msg);
        }

        // Check if we already have majority (single node cluster)
        const alive_peers = self.countAlivePeers();
        if (alive_peers == 1) {
            log.info("Single node cluster, becoming leader immediately", .{});
            try self.becomeLeader();
        }
    }

    fn countAlivePeers(self: *const RaftNode) usize {
        var count: usize = 0;
        for (self.peers) |peer| {
            if (peer.alive) count += 1;
        }
        return count;
    }

    fn becomeLeader(self: *RaftNode) !void {
        log.info("Node {} became leader for term {}", .{ self.id, self.current_term });

        self.state = .leader;
        self.stats.elections_won += 1;

        // Initialize leader state
        if (self.next_index) |*ni| ni.deinit();
        if (self.match_index) |*mi| mi.deinit();

        self.next_index = std.AutoHashMap(u64, u64).init(self.allocator);
        self.match_index = std.AutoHashMap(u64, u64).init(self.allocator);

        const last_log_index = self.getLastLogIndex();

        for (self.peers) |peer| {
            if (peer.id == self.id) continue;
            try self.next_index.?.put(peer.id, last_log_index + 1);
            try self.match_index.?.put(peer.id, 0);
        }

        // Append noop entry to establish leadership
        const noop_entry = LogEntry{
            .term = self.current_term,
            .index = last_log_index + 1,
            .command = .noop,
            .timestamp = std.time.milliTimestamp(),
            .client_id = null,
            .serial_number = null,
        };

        try self.log.append(self.allocator, noop_entry);
        if (self.storage) |storage| {
            try storage.appendLogEntry(noop_entry);
        }

        self.stats.entries_appended += 1;

        // Send initial heartbeat with noop
        try self.sendHeartbeats();
        self.last_heartbeat = std.time.milliTimestamp();
    }

    fn sendHeartbeats(self: *RaftNode) !void {
        for (self.peers) |peer| {
            if (peer.id == self.id) continue;
            if (!peer.alive) continue;

            const msg = Message{
                .append_entries = .{
                    .term = self.current_term,
                    .leader_id = self.id,
                    .prev_log_index = 0,
                    .prev_log_term = 0,
                    .entries = &[_]LogEntry{}, // Empty for heartbeat
                    .leader_commit = self.commit_index,
                },
            };

            try self.sendMessage(peer, msg);
        }
    }

    fn handleRequestVote(self: *RaftNode, rv: RequestVote, from: u64) !void {
        var vote_granted = false;
        var reason: []const u8 = "";

        if (rv.term > self.current_term) {
            self.current_term = rv.term;
            self.state = .follower;
            self.voted_for = null;

            if (self.storage) |storage| {
                try storage.saveCurrentTerm(self.current_term);
                try storage.saveVotedFor(null);
            }
        }

        if (rv.term == self.current_term and
            (self.voted_for == null or self.voted_for.? == rv.candidate_id))
        {
            // Check if candidate's log is at least as up-to-date as ours
            const last_log_index = self.getLastLogIndex();
            const last_log_term = self.getLastLogTerm();

            if (rv.last_log_term > last_log_term or
                (rv.last_log_term == last_log_term and rv.last_log_index >= last_log_index))
            {
                vote_granted = true;
                self.voted_for = rv.candidate_id;
                self.resetElectionTimer();

                if (self.storage) |storage| {
                    try storage.saveVotedFor(rv.candidate_id);
                }

                reason = "log up-to-date";
            } else {
                reason = "log not up-to-date";
            }
        } else if (rv.term < self.current_term) {
            reason = "stale term";
        } else {
            reason = "already voted";
        }

        log.debug("Node {} vote request from {} term {} - granted: {} ({s})", .{
            self.id,
            from,
            rv.term,
            vote_granted,
            reason,
        });

        const response = Message{
            .request_vote_response = .{
                .term = self.current_term,
                .vote_granted = vote_granted,
                .voter_id = self.id,
            },
        };

        const peer = self.getPeer(from) orelse return;
        try self.sendMessage(peer.*, response);
    }

    fn handleRequestVoteResponse(self: *RaftNode, rvr: RequestVoteResponse, from: u64) !void {
        if (rvr.term > self.current_term) {
            self.current_term = rvr.term;
            self.state = .follower;
            self.voted_for = null;
            self.stats.elections_lost += 1;

            if (self.storage) |storage| {
                try storage.saveCurrentTerm(self.current_term);
                try storage.saveVotedFor(null);
            }
            return;
        }

        if (self.state != .candidate or rvr.term != self.current_term) {
            return;
        }

        if (rvr.vote_granted) {
            try self.votes_received.put(rvr.voter_id, true);

            // Count votes
            var votes: u64 = 0;
            var iter = self.votes_received.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.*) votes += 1;
            }

            const alive_peers = self.countAlivePeers();
            const majority = (alive_peers / 2) + 1;

            log.debug("Node {} has {} votes out of {} needed for majority", .{
                self.id,
                votes,
                majority,
            });

            if (votes >= majority) {
                try self.becomeLeader();
            }
        } else {
            try self.votes_received.put(rvr.voter_id, false);
        }

        // Mark peer as alive
        if (self.getPeer(from)) |peer| {
            peer.alive = true;
            peer.last_contact = std.time.milliTimestamp();
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
                        try self.log.append(self.allocator, entry);
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
        try self.sendMessage(peer.*, response);
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
        _ = self;
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
        var match_indices = try std.ArrayList(u64).initCapacity(self.allocator, self.peers.len);
        defer match_indices.deinit(self.allocator);

        try match_indices.append(self.allocator, self.log.items.len); // Leader's own log

        var iter = self.match_index.?.iterator();
        while (iter.next()) |entry| {
            try match_indices.append(self.allocator, entry.value_ptr.*);
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
            if (self.apply_callback) |callback| {
                _ = try callback(self.allocator, entry.command);
            }

            self.stats.entries_applied += 1;
            log.info("Applied entry with index {}", .{self.last_applied});
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

    fn getPeer(self: *RaftNode, id: u64) ?*Peer {
        for (self.peers) |*peer| {
            if (peer.id == id) return peer;
        }
        return null;
    }

    fn sendMessage(self: *RaftNode, peer: Peer, msg: Message) !void {
        if (!peer.alive) return;

        if (self.transport) |transport| {
            const payload = try std.json.stringifyAlloc(self.allocator, msg, .{});
            defer self.allocator.free(payload);
            transport.send(peer, payload) catch |err| {
                log.warn("Failed to send message to peer {}: {}", .{ peer.id, err });
            };
        } else if (peer.rpc_client) |client| {
            try client.sendMessage(msg);
        }
    }

    fn getLastLogIndex(self: *const RaftNode) u64 {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].index;
    }

    fn getLastLogTerm(self: *const RaftNode) u64 {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].term;
    }

    pub fn propose(self: *RaftNode, command: Command) !u64 {
        return self.proposeWithClientInfo(command, null, null);
    }

    pub fn proposeWithClientInfo(
        self: *RaftNode,
        command: Command,
        client_id: ?u64,
        serial_number: ?u64,
    ) !u64 {
        if (self.state != .leader) {
            return error.NotLeader;
        }

        // Check for duplicate request
        if (client_id) |cid| {
            if (serial_number) |sn| {
                for (self.log.items) |entry| {
                    if (entry.client_id == cid and entry.serial_number == sn) {
                        // Duplicate request, return existing index
                        return entry.index;
                    }
                }
            }
        }

        const entry = LogEntry{
            .term = self.current_term,
            .index = self.getLastLogIndex() + 1,
            .command = command,
            .timestamp = std.time.milliTimestamp(),
            .client_id = client_id,
            .serial_number = serial_number,
        };

        try self.log.append(self.allocator, entry);
        if (self.storage) |storage| {
            try storage.appendLogEntry(entry);
        }

        self.stats.entries_appended += 1;

        // Send to followers immediately
        try self.replicateEntry(entry.index);

        return entry.index;
    }

    fn replicateEntry(self: *RaftNode, index: u64) !void {
        for (self.peers) |peer| {
            if (peer.id == self.id) continue;
            if (!peer.alive) continue;

            const next_idx = self.next_index.?.get(peer.id) orelse 1;

            // Only send if this peer needs this entry
            if (next_idx <= index) {
                try self.sendAppendEntriesToPeer(peer);
            }
        }
    }

    fn sendAppendEntriesToPeer(self: *RaftNode, peer: Peer) !void {
        const next_idx = self.next_index.?.get(peer.id) orelse 1;
        const prev_log_index = if (next_idx > 1) next_idx - 1 else 0;
        const prev_log_term = if (prev_log_index > 0 and prev_log_index <= self.log.items.len)
            self.log.items[prev_log_index - 1].term
        else
            0;

        // Determine how many entries to send
        const max_entries = 100; // Limit batch size
        const end_idx = @min(self.log.items.len, next_idx - 1 + max_entries);
        const entries = if (next_idx <= self.log.items.len)
            self.log.items[next_idx - 1 .. end_idx]
        else
            &[_]LogEntry{};

        const msg = Message{
            .append_entries = .{
                .term = self.current_term,
                .leader_id = self.id,
                .prev_log_index = prev_log_index,
                .prev_log_term = prev_log_term,
                .entries = entries,
                .leader_commit = self.commit_index,
            },
        };

        try self.sendMessage(peer, msg);
    }
};

// Tests
test "raft initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]Peer{
        .{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 8002, .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 3, .endpoint = "127.0.0.1", .port = 8003, .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    try testing.expect(node.state == .follower);
    try testing.expect(node.current_term == 0);
    try testing.expect(node.voted_for == null);
    try testing.expect(node.commit_index == 0);
    try testing.expect(node.last_applied == 0);
    try testing.expect(node.log.items.len == 1); // Initial noop entry
}

test "raft single node becomes leader" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]Peer{
        .{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    // Start election
    try node.startElection();

    try testing.expect(node.state == .leader);
    try testing.expect(node.current_term == 1);
    try testing.expect(node.voted_for == 1);
    try testing.expect(node.stats.elections_won == 1);
}

test "raft propose command as leader" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]Peer{
        .{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    // Become leader
    try node.startElection();
    try testing.expect(node.state == .leader);

    // Propose a command
    const cmd = Command{ .write = "test data" };
    const index = try node.propose(cmd);

    try testing.expect(index == 2); // Index 0: init noop, 1: leader noop, 2: our command
    try testing.expect(node.log.items.len == 3);
    try testing.expect(node.stats.entries_appended == 2);
}

test "raft request vote logic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]Peer{
        .{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 8002, .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    // Test vote request with higher term
    const vote_req = RequestVote{
        .term = 2,
        .candidate_id = 2,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    };

    try node.handleRequestVote(vote_req, 2);

    // Should update term and grant vote
    try testing.expect(node.current_term == 2);
    try testing.expect(node.state == .follower);
    try testing.expect(node.voted_for == 2);
}

test "raft append entries as follower" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]Peer{
        .{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null },
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 8002, .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    // Create append entries from leader
    var entries = [_]LogEntry{
        .{
            .term = 1,
            .index = 1,
            .command = .{ .write = "entry1" },
            .timestamp = 0,
            .client_id = null,
            .serial_number = null,
        },
    };

    const append_req = AppendEntries{
        .term = 1,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &entries,
        .leader_commit = 0,
    };

    try node.handleAppendEntries(append_req, 2);

    // Should accept entries
    try testing.expect(node.current_term == 1);
    try testing.expect(node.state == .follower);
    try testing.expect(node.log.items.len == 1); // Only initial noop, entry wasn't appended
}

test "raft deduplication of client requests" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]Peer{
        .{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    // Become leader
    try node.startElection();

    // Propose command with client info
    const cmd = Command{ .write = "test data" };
    const index1 = try node.proposeWithClientInfo(cmd, 100, 1);

    // Try to propose same command again (should return same index)
    const index2 = try node.proposeWithClientInfo(cmd, 100, 1);

    try testing.expect(index1 == index2);
    try testing.expect(node.log.items.len == 3); // Not 4, because duplicate was detected
}

test "raft statistics tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var peers = [_]Peer{
        .{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null },
    };

    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    // Initial stats
    try testing.expect(node.stats.elections_called == 0);
    try testing.expect(node.stats.elections_won == 0);

    // Start election
    try node.startElection();

    try testing.expect(node.stats.elections_called == 1);
    try testing.expect(node.stats.elections_won == 1);
    try testing.expect(node.stats.entries_appended == 1); // Leader noop
}
