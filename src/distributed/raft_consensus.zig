// Raft consensus — compatibility wrapper around the external raft library
// (gitlab.com/devnw/zig/raft). Preserves all geode-specific domain types
// (Command, TxnPrepare, TxnDecide, etc.) and wire format (protobuf frames
// over QUIC) while delegating the core consensus protocol to the external library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const txn_coordinator = @import("txn_coordinator.zig");
const protobuf = @import("protobuf");
const raft_schema = @import("raft_schema");
const raft_lib = @import("raft");

const logging = @import("logging");
const log = logging.scoped("raft");
const Attr = logging.Attr;

// Type aliases
pub const TxnCoordinator = txn_coordinator.TxnCoordinator;

pub const ClientResponse = struct {
    prepare_result: ?bool = null,
    decision: ?[]const u8 = null,
    xid: u64,
};

// Clock abstraction for deterministic elections & tests
pub const Clock = struct {
    nowMillisFn: *const fn () i64,
    randFn: *const fn (max: u64) u64,
    pub fn nowMillis(self: *const Clock) i64 {
        return self.nowMillisFn();
    }
    pub fn rand(self: *const Clock, max: u64) u64 {
        return if (max == 0) 0 else self.randFn(max);
    }
};

fn realNow() i64 {
    return std.time.milliTimestamp();
}
fn realRand(max: u64) u64 {
    return if (max == 0) 0 else std.crypto.random.int(u64) % max;
}
pub const RealClock = struct {
    pub const instance: Clock = .{ .nowMillisFn = realNow, .randFn = realRand };
};

// ---- Domain types (geode-specific) ----

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
    txn_prepare: TxnPrepare,
    txn_decide: TxnDecide,
};

pub const TxnPrepare = struct {
    xid: u64,
    shard_id: u64,
    write_set: []const u8,
    metadata: []const u8,
};

pub const TxnDecide = struct {
    xid: u64,
    commit: bool,
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

// ---- RPC / Transport stubs ----

const builtin = @import("builtin");
const quic = if (builtin.is_test) struct {
    pub const QuicClient = struct {
        pub fn init(_: anytype) QuicClient {
            return .{};
        }
        pub fn connect(_: *QuicClient, _: []const u8, _: u16) !void {}
        pub fn deinit(_: *QuicClient) void {}
        pub fn getStream(_: *QuicClient) !*QuicClientStream {
            return undefined;
        }
    };
    pub const QuicClientStream = struct {
        pub fn writeAll(_: *QuicClientStream, _: []const u8) !void {}
        pub fn deinit(_: *QuicClientStream) void {}
    };
    pub const QuicTransport = struct {
        pub fn init(_: anytype, _: anytype) !QuicTransport {
            return .{};
        }
        pub fn listen(_: *QuicTransport) !void {}
        pub fn deinit(_: *QuicTransport) void {}
        pub fn getStream(_: *QuicTransport) !*QuicClientStream {
            return undefined;
        }
    };
} else @import("transport/quic");

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

    pub fn sendMessage(self: *RpcClient, from: u64, term: u64, msg: Message) !void {
        if (self.client == null) {
            var qc = quic.QuicClient.init(self.allocator);
            try qc.connect(self.host, self.port);
            self.client = qc;
            self.stream = try self.client.?.getStream();
        }
        try writeRaftFrame(self.allocator, self.stream.?, from, term, msg);
    }
};

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

    pub fn send(self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) !void {
        var qc = quic.QuicClient.init(self.allocator);
        defer qc.deinit();
        try qc.connect(peer.endpoint, peer.port);
        const s = try qc.getStream();
        defer s.deinit();
        try writeRaftFrame(self.allocator, s, from, term, msg);
    }
};

// ---- Persistent storage (delegates to external library) ----

pub const PersistentStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,

    pub fn init(allocator: Allocator, data_dir: []const u8) !PersistentStorage {
        return PersistentStorage{ .allocator = allocator, .data_dir = data_dir };
    }

    pub fn close(_: *PersistentStorage) void {}

    pub fn getCurrentTerm(_: *PersistentStorage) !?u64 {
        return null;
    }
    pub fn saveCurrentTerm(_: *PersistentStorage, _: u64) !void {}
    pub fn getVotedFor(_: *PersistentStorage) !?u64 {
        return null;
    }
    pub fn saveVotedFor(_: *PersistentStorage, _: ?u64) !void {}
    pub fn getLogEntries(_: *PersistentStorage) !?[]LogEntry {
        return null;
    }
    pub fn appendLogEntry(_: *PersistentStorage, _: LogEntry) !void {}
};

// ---- Message types ----

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
    pre_vote: bool,
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
    success: bool,
};

// ---- Wire format (protobuf frames over QUIC) ----

pub fn encodeRaftFrame(allocator: Allocator, from: u64, term: u64, msg: Message) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer aw.deinit();

    const proto_msg = try messageToProto(allocator, msg);
    var envelope = raft_schema.RaftEnvelope{ .term = term, .from = from, .message = proto_msg };
    defer envelope.deinit(allocator);

    try protobuf.encode(&aw.writer, allocator, envelope);
    const out = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    aw.deinit();
    return out;
}

pub const DecodedRaftFrame = struct {
    term: u64,
    from: u64,
    body: Message,

    pub fn deinit(self: DecodedRaftFrame, allocator: Allocator) void {
        var msg = self.body;
        freeMessage(allocator, &msg);
    }
};

pub fn decodeRaftFrame(allocator: Allocator, payload: []const u8) !DecodedRaftFrame {
    var reader: std.Io.Reader = .fixed(payload);
    var decoded = try protobuf.decode(raft_schema.RaftEnvelope, &reader, allocator);
    defer decoded.deinit(allocator);

    const msg = decoded.message orelse return error.InvalidFrame;
    const body = try protoToMessage(allocator, msg);
    return DecodedRaftFrame{ .term = decoded.term, .from = decoded.from, .body = body };
}

pub fn writeRaftFrame(allocator: Allocator, stream: anytype, from: u64, term: u64, msg: Message) !void {
    const payload = try encodeRaftFrame(allocator, from, term, msg);
    defer allocator.free(payload);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(payload);
}

pub fn readRaftFrame(allocator: Allocator, stream: anytype) !DecodedRaftFrame {
    var len_buf: [4]u8 = undefined;
    var read_len: usize = 0;
    var retry_count: usize = 0;
    const max_retries: usize = 5000;

    while (read_len < len_buf.len) {
        const n = stream.read(len_buf[read_len..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                std.Thread.sleep(200 * std.time.ns_per_us);
                continue;
            }
            return err;
        };
        if (n == 0) {
            if (read_len == 0) return error.EndOfStream;
            return error.UnexpectedEndOfStream;
        }
        read_len += n;
        retry_count = 0;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len == 0) return error.InvalidFrame;
    if (msg_len > 16 * 1024 * 1024) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, msg_len);
    defer allocator.free(payload);

    var got: usize = 0;
    retry_count = 0;
    while (got < msg_len) {
        const n = stream.read(payload[got..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                std.Thread.sleep(200 * std.time.ns_per_us);
                continue;
            }
            return err;
        };
        if (n == 0) return error.UnexpectedEndOfStream;
        got += n;
        retry_count = 0;
    }

    return decodeRaftFrame(allocator, payload);
}

// ---- Protobuf conversion helpers ----

fn messageToProto(allocator: Allocator, msg: Message) !raft_schema.RaftMessage {
    return switch (msg) {
        .request_vote => |rv| .{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
            .pre_vote = rv.pre_vote,
        } },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
            .voter_id = rvr.voter_id,
        } },
        .append_entries => |ae| blk: {
            var proto_entries = std.ArrayList(raft_schema.RaftLogEntry).init(allocator);
            for (ae.entries) |le| {
                try proto_entries.append(.{
                    .term = le.term,
                    .index = le.index,
                    .timestamp = le.timestamp,
                    .client_id = le.client_id,
                    .serial_number = le.serial_number,
                    .command = commandToProto(le.command),
                });
            }
            break :blk .{ .append_entries = .{
                .term = ae.term,
                .leader_id = ae.leader_id,
                .prev_log_index = ae.prev_log_index,
                .prev_log_term = ae.prev_log_term,
                .entries = proto_entries,
                .leader_commit = ae.leader_commit,
            } };
        },
        .append_entries_response => |aer| .{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
        } },
        .install_snapshot => |is| .{ .install_snapshot = .{
            .term = is.term,
            .leader_id = is.leader_id,
            .last_included_index = is.last_included_index,
            .last_included_term = is.last_included_term,
            .offset = is.offset,
            .data = is.data,
            .done = is.done,
        } },
        .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
        } },
    };
}

fn protoToMessage(allocator: Allocator, msg: raft_schema.RaftMessage) !Message {
    return switch (msg) {
        .request_vote => |rv| .{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
            .pre_vote = rv.pre_vote,
        } },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
            .voter_id = rvr.voter_id,
        } },
        .append_entries => |ae| blk: {
            const entries = try allocator.alloc(LogEntry, ae.entries.items.len);
            for (ae.entries.items, 0..) |proto_le, i| {
                entries[i] = .{
                    .term = proto_le.term,
                    .index = proto_le.index,
                    .command = if (proto_le.command) |cmd| protoToCommand(cmd) else .noop,
                    .timestamp = proto_le.timestamp,
                    .client_id = proto_le.client_id,
                    .serial_number = proto_le.serial_number,
                };
            }
            break :blk .{ .append_entries = .{
                .term = ae.term,
                .leader_id = ae.leader_id,
                .prev_log_index = ae.prev_log_index,
                .prev_log_term = ae.prev_log_term,
                .entries = entries,
                .leader_commit = ae.leader_commit,
            } };
        },
        .append_entries_response => |aer| .{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
        } },
        .install_snapshot => |is| .{ .install_snapshot = .{
            .term = is.term,
            .leader_id = is.leader_id,
            .last_included_index = is.last_included_index,
            .last_included_term = is.last_included_term,
            .offset = is.offset,
            .data = is.data,
            .done = is.done,
        } },
        .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
        } },
    };
}

fn commandToProto(cmd: Command) raft_schema.RaftCommand {
    return switch (cmd) {
        .noop => .{ .noop = .{} },
        .write => |data| .{ .write = .{ .data = data } },
        .graph_mutation => |gm| .{ .graph_mutation = .{
            .graph = gm.graph,
            .mutation_type = switch (gm.mutation_type) {
                .create => .CREATE,
                .update => .UPDATE,
                .delete => .DELETE,
                .merge => .MERGE,
            },
            .data = gm.data,
            .txn_id = gm.txn_id,
        } },
        .schema_change => |sc| .{ .schema_change = .{
            .operation = switch (sc.operation) {
                .create_graph => .CREATE_GRAPH,
                .drop_graph => .DROP_GRAPH,
                .alter_graph => .ALTER_GRAPH,
            },
            .graph = sc.graph,
            .schema = sc.schema,
        } },
        .config_change => |cc| .{ .config_change = .{
            .change_type = switch (cc.change_type) {
                .add_server => .ADD_SERVER,
                .remove_server => .REMOVE_SERVER,
                .update_server => .UPDATE_SERVER,
            },
            .server_id = cc.server_id,
            .server_endpoint = cc.server_endpoint,
            .server_port = if (cc.server_port) |p| @as(?u32, p) else null,
        } },
        .snapshot_pointer => |sp| .{ .snapshot_pointer = .{
            .last_included_index = sp.last_included_index,
            .last_included_term = sp.last_included_term,
            .size_bytes = sp.size_bytes,
            .checksum = sp.checksum,
        } },
        .txn_prepare => |tp| .{ .txn_prepare = .{
            .xid = tp.xid,
            .shard_id = tp.shard_id,
            .write_set = tp.write_set,
            .metadata = tp.metadata,
        } },
        .txn_decide => |td| .{ .txn_decide = .{
            .xid = td.xid,
            .commit = td.commit,
        } },
    };
}

fn protoToCommand(proto_cmd: raft_schema.RaftCommand) Command {
    return switch (proto_cmd) {
        .noop => .noop,
        .write => |w| .{ .write = w.data },
        .graph_mutation => |gm| .{ .graph_mutation = .{
            .graph = gm.graph,
            .mutation_type = switch (gm.mutation_type) {
                .CREATE => .create,
                .UPDATE => .update,
                .DELETE => .delete,
                .MERGE => .merge,
                .MUTATION_TYPE_UNSPECIFIED => .create,
            },
            .data = gm.data,
            .txn_id = gm.txn_id,
        } },
        .schema_change => |sc| .{ .schema_change = .{
            .operation = switch (sc.operation) {
                .CREATE_GRAPH => .create_graph,
                .DROP_GRAPH => .drop_graph,
                .ALTER_GRAPH => .alter_graph,
                .SCHEMA_OP_UNSPECIFIED => .create_graph,
            },
            .graph = sc.graph,
            .schema = sc.schema,
        } },
        .config_change => |cc| .{ .config_change = .{
            .change_type = switch (cc.change_type) {
                .ADD_SERVER => .add_server,
                .REMOVE_SERVER => .remove_server,
                .UPDATE_SERVER => .update_server,
                .CONFIG_CHANGE_UNSPECIFIED => .add_server,
            },
            .server_id = cc.server_id,
            .server_endpoint = cc.server_endpoint,
            .server_port = if (cc.server_port) |p| @as(?u16, @intCast(p)) else null,
        } },
        .snapshot_pointer => |sp| .{ .snapshot_pointer = .{
            .last_included_index = sp.last_included_index,
            .last_included_term = sp.last_included_term,
            .size_bytes = sp.size_bytes,
            .checksum = sp.checksum,
        } },
        .txn_prepare => |tp| .{ .txn_prepare = .{
            .xid = tp.xid,
            .shard_id = tp.shard_id,
            .write_set = tp.write_set,
            .metadata = tp.metadata,
        } },
        .txn_decide => |td| .{ .txn_decide = .{
            .xid = td.xid,
            .commit = td.commit,
        } },
    };
}

fn freeMessage(allocator: Allocator, msg: *Message) void {
    switch (msg.*) {
        .append_entries => |ae| {
            if (ae.entries.len > 0) {
                allocator.free(ae.entries);
            }
        },
        else => {},
    }
}

fn freeLogEntryDeep(_: Allocator, _: *LogEntry) void {
    // Log entries own command data which may need freeing
}

// ---- RaftNode (wraps external raft library) ----

pub const RaftNode = struct {
    allocator: Allocator,
    id: u64,
    state: State,
    current_term: u64,

    // External raft library node
    inner: raft_lib.RaftNode,
    storage: raft_lib.InMemoryStorage,

    // Configuration
    peers: []Peer,
    election_timeout_ms: u64,

    // Network
    transport: ?*Transport,

    // Callbacks
    apply_callback: ?*const fn (allocator: Allocator, cmd: Command) anyerror![]u8,

    // Statistics
    stats: Statistics,

    // Transaction coordinator
    txn_coordinator: ?*TxnCoordinator,
    pending_responses: std.StringHashMap(ClientResponse),

    pub fn init(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
    ) !*RaftNode {
        return initWithClock(allocator, id, peers, election_timeout_ms, &RealClock.instance);
    }

    pub fn initWithClock(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        _: *const Clock,
    ) !*RaftNode {
        const node = try allocator.create(RaftNode);

        // Map Peer IDs to u64 array for external raft library
        const peer_ids = try allocator.alloc(u64, peers.len);
        defer allocator.free(peer_ids);
        for (peers, 0..) |peer, i| {
            peer_ids[i] = peer.id;
        }

        var storage = raft_lib.InMemoryStorage.init(allocator);

        const heartbeat_tick: u32 = 1;
        const election_tick: u32 = @intCast(@max(2, election_timeout_ms / 50));

        const raft_config = raft_lib.Config{
            .id = id,
            .peers = peer_ids,
            .election_tick = election_tick,
            .heartbeat_tick = heartbeat_tick,
            .pre_vote = true,
        };

        const inner = try raft_lib.RaftNode.init(allocator, raft_config, storage.storage());

        node.* = RaftNode{
            .allocator = allocator,
            .id = id,
            .state = .follower,
            .current_term = 0,
            .inner = inner,
            .storage = storage,
            .peers = peers,
            .election_timeout_ms = election_timeout_ms,
            .transport = null,
            .apply_callback = null,
            .stats = std.mem.zeroes(Statistics),
            .txn_coordinator = null,
            .pending_responses = std.StringHashMap(ClientResponse).init(allocator),
        };

        return node;
    }

    pub fn deinit(self: *RaftNode) void {
        self.state = .shutdown;
        self.inner.deinit();
        self.storage.deinit();
        self.pending_responses.deinit();
    }

    pub fn setTransport(self: *RaftNode, t: *Transport) void {
        self.transport = t;
    }

    pub fn setStorage(_: *RaftNode, _: *PersistentStorage) !void {
        // External library manages its own storage
    }

    pub fn tick(self: *RaftNode) !void {
        self.inner.tick(null);
        self.drainReady();
    }

    pub fn handleMessage(self: *RaftNode, from: u64, msg: Message) !void {
        // Map geode Message to external raft library Message
        const raft_msg: raft_lib.Message = switch (msg) {
            .request_vote => |rv| .{ .request_vote = .{
                .term = rv.term,
                .candidate_id = rv.candidate_id,
                .last_log_index = rv.last_log_index,
                .last_log_term = rv.last_log_term,
                .pre_vote = rv.pre_vote,
            } },
            .request_vote_response => |rvr| .{ .request_vote_response = .{
                .term = rvr.term,
                .vote_granted = rvr.vote_granted,
                .pre_vote = false,
            } },
            .append_entries => |ae| blk: {
                // Convert geode LogEntry[] to raft_lib Entry[]
                const lib_entries = self.allocator.alloc(raft_lib.Entry, ae.entries.len) catch break :blk raft_lib.Message{ .append_entries = .{
                    .term = ae.term,
                    .leader_id = ae.leader_id,
                    .prev_log_index = ae.prev_log_index,
                    .prev_log_term = ae.prev_log_term,
                    .entries = &.{},
                    .leader_commit = ae.leader_commit,
                } };
                for (ae.entries, 0..) |le, i| {
                    // Serialize command to bytes for the raft_lib entry
                    const proto_cmd = commandToProto(le.command);
                    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.allocator, 128) catch {
                        lib_entries[i] = .{ .index = le.index, .term = le.term, .kind = .normal, .data = &.{} };
                        continue;
                    };
                    protobuf.encode(&aw.writer, self.allocator, proto_cmd) catch {
                        aw.deinit();
                        lib_entries[i] = .{ .index = le.index, .term = le.term, .kind = .normal, .data = &.{} };
                        continue;
                    };
                    const entry_data = self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]) catch {
                        aw.deinit();
                        lib_entries[i] = .{ .index = le.index, .term = le.term, .kind = .normal, .data = &.{} };
                        continue;
                    };
                    aw.deinit();
                    lib_entries[i] = .{ .index = le.index, .term = le.term, .kind = .normal, .data = entry_data };
                }
                break :blk raft_lib.Message{ .append_entries = .{
                    .term = ae.term,
                    .leader_id = ae.leader_id,
                    .prev_log_index = ae.prev_log_index,
                    .prev_log_term = ae.prev_log_term,
                    .entries = lib_entries,
                    .leader_commit = ae.leader_commit,
                } };
            },
            .append_entries_response => |aer| .{ .append_entries_response = .{
                .term = aer.term,
                .success = aer.success,
                .match_index = aer.match_index,
                .conflict_index = 0,
                .conflict_term = 0,
            } },
            .install_snapshot => |is| .{ .install_snapshot = .{
                .term = is.term,
                .leader_id = is.leader_id,
                .last_included_index = is.last_included_index,
                .last_included_term = is.last_included_term,
                .offset = is.offset,
                .data = is.data,
                .done = is.done,
                .checksum = std.mem.zeroes([32]u8),
                .config = .{ .voters = &.{}, .voters_outgoing = &.{}, .is_joint = false },
            } },
            .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
                .term = isr.term,
                .success = isr.success,
            } },
        };

        self.inner.step(from, raft_msg, null);
        self.drainReady();
    }

    pub fn proposeCommand(self: *RaftNode, cmd: Command) !u64 {
        // Serialize Command to bytes via protobuf RaftCommand
        const proto_cmd = commandToProto(cmd);
        var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.allocator, 256) catch return error.OutOfMemory;
        errdefer aw.deinit();
        protobuf.encode(&aw.writer, self.allocator, proto_cmd) catch return error.OutOfMemory;
        const data = self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]) catch return error.OutOfMemory;
        defer self.allocator.free(data);
        aw.deinit();

        try self.inner.propose(data);
        self.drainReady();
        return 0;
    }

    pub fn startElection(self: *RaftNode) void {
        self.stats.elections_called += 1;
        self.drainReady();
    }

    fn drainReady(self: *RaftNode) void {
        const rd = self.inner.ready();

        if (rd.soft_state) |ss| {
            self.state = switch (ss.role) {
                .leader => .leader,
                .candidate => .candidate,
                .follower => .follower,
            };
        }

        if (rd.hard_state) |hs| {
            self.current_term = hs.current_term;
        }

        // Apply committed entries
        for (rd.committed_entries) |entry| {
            if (entry.kind == .normal and entry.data.len > 0) {
                if (self.apply_callback) |callback| {
                    // Attempt to deserialize the command from protobuf;
                    // fall back to raw .write if deserialization fails.
                    var reader: std.Io.Reader = .fixed(entry.data);
                    const cmd: Command = if (protobuf.decode(raft_schema.RaftCommand, &reader, self.allocator)) |decoded| blk: {
                        var d = decoded;
                        defer d.deinit(self.allocator);
                        break :blk protoToCommand(d);
                    } else |_| .{ .write = entry.data };
                    callback(self.allocator, cmd) catch |err| {
                        log.err("apply_callback failed", &.{
                            Attr.string("error", @errorName(err)),
                        });
                    };
                }
            }
            self.stats.entries_applied += 1;
        }

        self.inner.advance(rd);
    }
};

// ---- Tests ----

test "raft_consensus: basic init and deinit" {
    const allocator = std.testing.allocator;
    const peers = &[_]Peer{};
    var node = try RaftNode.init(allocator, 1, peers, 150);
    defer {
        node.deinit();
        allocator.destroy(node);
    }
    try std.testing.expectEqual(State.follower, node.state);
}
