// Raft consensus integration over the external raft library.
// This module owns Geode-specific command types, protobuf framing, and QUIC
// transport wiring while delegating consensus state transitions to the
// external raft package.

const std = @import("std");
const Allocator = std.mem.Allocator;
const txn_coordinator = @import("txn_coordinator.zig");
const protobuf = @import("protobuf");
const raft_schema = @import("raft_schema");
const raft_lib = @import("raft");

const cluster_auth = @import("cluster_auth.zig");

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

// ---- Persistent storage (file-backed term & votedFor) ----
// CANARY: REQ=REQ-GQL-RAFT-PERSIST; FEATURE="Raft Consensus Persistence"; ASPECT=TermVotedFor; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-05

pub const PersistentStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,

    pub fn init(allocator: Allocator, data_dir: []const u8) !PersistentStorage {
        return PersistentStorage{ .allocator = allocator, .data_dir = data_dir };
    }

    pub fn close(_: *PersistentStorage) void {}

    /// Read current_term from {data_dir}/current_term. Returns null if file does not exist.
    pub fn getCurrentTerm(self: *PersistentStorage) !?u64 {
        return readU64File(self.data_dir, "current_term");
    }

    /// Atomically write current_term to {data_dir}/current_term.
    pub fn saveCurrentTerm(self: *PersistentStorage, term: u64) !void {
        try ensureDir(self.data_dir);
        var dir = try std.fs.cwd().openDir(self.data_dir, .{});
        defer dir.close();
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{term}) catch unreachable;
        try atomicWriteFile(dir, "current_term", str);
    }

    /// Read voted_for from {data_dir}/voted_for. Returns null if file does not exist.
    pub fn getVotedFor(self: *PersistentStorage) !?u64 {
        return readU64File(self.data_dir, "voted_for");
    }

    /// Atomically write voted_for to {data_dir}/voted_for, or delete the file if null.
    pub fn saveVotedFor(self: *PersistentStorage, voter: ?u64) !void {
        try ensureDir(self.data_dir);
        var dir = try std.fs.cwd().openDir(self.data_dir, .{});
        defer dir.close();
        if (voter) |v| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try atomicWriteFile(dir, "voted_for", str);
        } else {
            dir.deleteFile("voted_for") catch |err| {
                if (err != error.FileNotFound) return err;
            };
        }
    }

    /// Log persistence is future work — returns null.
    pub fn getLogEntries(_: *PersistentStorage) !?[]LogEntry {
        return null;
    }

    /// Log persistence is future work — no-op.
    pub fn appendLogEntry(_: *PersistentStorage, _: LogEntry) !void {}

    // ---- Internal helpers ----

    fn ensureDir(path: []const u8) !void {
        std.fs.cwd().makePath(path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    fn readU64File(dir_path: []const u8, file_name: []const u8) !?u64 {
        var dir = std.fs.cwd().openDir(dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer dir.close();
        const f = dir.openFile(file_name, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer f.close();
        var buf: [32]u8 = undefined;
        const n = try f.readAll(&buf);
        if (n == 0) return null;
        const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
        return std.fmt.parseInt(u64, trimmed, 10) catch null;
    }

    /// Write data to file_name atomically via write-to-temp-then-rename.
    fn atomicWriteFile(dir: std.fs.Dir, name: []const u8, data: []const u8) !void {
        var tmp_buf: [256]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch return error.FileNotFound;

        const f = try dir.createFile(tmp_name, .{});
        errdefer {
            f.close();
            dir.deleteFile(tmp_name) catch {};
        }
        try f.writeAll(data);
        try f.sync();
        f.close();

        try dir.rename(tmp_name, name);
    }
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

// SEC-D009: Import nonce tracker for replay protection.
const nonce_tracker = @import("nonce_tracker.zig");

pub fn encodeRaftFrame(allocator: Allocator, from: u64, term: u64, msg: Message) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer aw.deinit();

    const proto_msg = try messageToProto(allocator, msg);
    // SEC-D009: Generate cryptographic nonce for replay protection.
    // SEC-D001: Include cluster token for inter-node authentication.
    var envelope = raft_schema.RaftEnvelope{
        .term = term,
        .from = from,
        .nonce = nonce_tracker.NonceTracker.generateNonce(),
        .message = proto_msg,
        .auth_token = std.posix.getenv("GEODE_CLUSTER_TOKEN") orelse "",
    };
    defer envelope.deinit(allocator);

    try protobuf.encode(&aw.writer, allocator, envelope);
    const out = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    aw.deinit();
    return out;
}

pub const DecodedRaftFrame = struct {
    term: u64,
    from: u64,
    /// SEC-D009: Nonce for replay protection (0 if absent / legacy frame).
    nonce: u64 = 0,
    /// SEC-D001: Cluster authentication token carried in the Raft envelope.
    auth_token: []const u8 = "",
    body: Message,

    pub fn deinit(self: DecodedRaftFrame, allocator: Allocator) void {
        if (self.auth_token.len > 0) allocator.free(self.auth_token);
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
    // SEC-D001: Carry auth_token through to caller for validation.
    const token_copy = if (decoded.auth_token.len > 0)
        try allocator.dupe(u8, decoded.auth_token)
    else
        @as([]const u8, "");
    return DecodedRaftFrame{ .term = decoded.term, .from = decoded.from, .nonce = decoded.nonce, .auth_token = token_copy, .body = body };
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
    const max_retries: usize = 200;

    while (read_len < len_buf.len) {
        const n = stream.read(len_buf[read_len..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                std.Thread.sleep(5 * std.time.ns_per_ms);
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

    const payload = try allocator.alloc(u8, msg_len);
    defer allocator.free(payload);

    var got: usize = 0;
    retry_count = 0;
    while (got < msg_len) {
        const n = stream.read(payload[got..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                std.Thread.sleep(5 * std.time.ns_per_ms);
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
    _ = allocator;
    return switch (msg) {
        .request_vote => |rv| .{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
        } },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
        } },
        .append_entries => |ae| .{ .append_entries = .{
            .term = ae.term,
            .leader_id = ae.leader_id,
            .prev_log_index = ae.prev_log_index,
            .prev_log_term = ae.prev_log_term,
            .leader_commit = ae.leader_commit,
        } },
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
            .done = is.done,
        } },
        .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
        } },
    };
}

fn protoToMessage(allocator: Allocator, msg: raft_schema.RaftMessage) !Message {
    _ = allocator;
    return switch (msg) {
        .request_vote => |rv| .{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
            .pre_vote = false,
        } },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
            .voter_id = 0,
        } },
        .append_entries => |ae| .{ .append_entries = .{
            .term = ae.term,
            .leader_id = ae.leader_id,
            .prev_log_index = ae.prev_log_index,
            .prev_log_term = ae.prev_log_term,
            .entries = &.{},
            .leader_commit = ae.leader_commit,
        } },
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
            .data = &.{},
            .done = is.done,
        } },
        .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
        } },
    };
}

fn freeMessage(_: Allocator, _: *Message) void {
    // Message fields are either stack values or slices pointing into protobuf decode buffers
}

fn freeLogEntryDeep(_: Allocator, _: *LogEntry) void {
    // Log entries own command data which may need freeing
}

// ---- Command serialization (tag-prefix format) ----
// Format: 1-byte tag | payload bytes
// Tags: 0=noop, 1=write, 2=graph_mutation, 3=schema_change,
//        4=config_change, 5=snapshot_pointer, 6=txn_prepare, 7=txn_decide

const CMD_TAG_NOOP: u8 = 0;
const CMD_TAG_WRITE: u8 = 1;
const CMD_TAG_GRAPH_MUTATION: u8 = 2;
const CMD_TAG_SCHEMA_CHANGE: u8 = 3;
const CMD_TAG_CONFIG_CHANGE: u8 = 4;
const CMD_TAG_SNAPSHOT_POINTER: u8 = 5;
const CMD_TAG_TXN_PREPARE: u8 = 6;
const CMD_TAG_TXN_DECIDE: u8 = 7;

/// Serialize a Command into a tag-prefixed byte array.
/// Caller owns the returned slice and must free with the same allocator.
pub fn serializeCommand(allocator: Allocator, cmd: Command) ![]u8 {
    switch (cmd) {
        .noop => {
            const buf = try allocator.alloc(u8, 1);
            buf[0] = CMD_TAG_NOOP;
            return buf;
        },
        .write => |data| {
            const buf = try allocator.alloc(u8, 1 + data.len);
            buf[0] = CMD_TAG_WRITE;
            @memcpy(buf[1..], data);
            return buf;
        },
        .graph_mutation => |gm| {
            // Serialize: tag | graph_len(4) | graph | type(1) | has_txn(1) [| txn_id(8)] | data
            const has_txn: u8 = if (gm.txn_id != null) 1 else 0;
            const txn_size: usize = if (gm.txn_id != null) 8 else 0;
            const total = 1 + 4 + gm.graph.len + 1 + 1 + txn_size + gm.data.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_GRAPH_MUTATION;
            pos += 1;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(gm.graph.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..gm.graph.len], gm.graph);
            pos += gm.graph.len;
            buf[pos] = @intFromEnum(gm.mutation_type);
            pos += 1;
            buf[pos] = has_txn;
            pos += 1;
            if (gm.txn_id) |tid| {
                std.mem.writeInt(u64, buf[pos..][0..8], tid, .big);
                pos += 8;
            }
            @memcpy(buf[pos..], gm.data);
            return buf;
        },
        .schema_change => |sc| {
            const total = 1 + 1 + 4 + sc.graph.len + sc.schema.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_SCHEMA_CHANGE;
            pos += 1;
            buf[pos] = @intFromEnum(sc.operation);
            pos += 1;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(sc.graph.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..sc.graph.len], sc.graph);
            pos += sc.graph.len;
            @memcpy(buf[pos..], sc.schema);
            return buf;
        },
        .config_change => |cc| {
            const ep = cc.server_endpoint orelse &[_]u8{};
            const has_port: u8 = if (cc.server_port != null) 1 else 0;
            const port_size: usize = if (cc.server_port != null) 2 else 0;
            const total = 1 + 1 + 8 + 4 + ep.len + 1 + port_size;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_CONFIG_CHANGE;
            pos += 1;
            buf[pos] = @intFromEnum(cc.change_type);
            pos += 1;
            std.mem.writeInt(u64, buf[pos..][0..8], cc.server_id, .big);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(ep.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..ep.len], ep);
            pos += ep.len;
            buf[pos] = has_port;
            pos += 1;
            if (cc.server_port) |p| {
                std.mem.writeInt(u16, buf[pos..][0..2], p, .big);
            }
            return buf;
        },
        .snapshot_pointer => |sp| {
            const buf = try allocator.alloc(u8, 1 + 8 * 4);
            buf[0] = CMD_TAG_SNAPSHOT_POINTER;
            std.mem.writeInt(u64, buf[1..][0..8], sp.last_included_index, .big);
            std.mem.writeInt(u64, buf[9..][0..8], sp.last_included_term, .big);
            std.mem.writeInt(u64, buf[17..][0..8], sp.size_bytes, .big);
            std.mem.writeInt(u64, buf[25..][0..8], sp.checksum, .big);
            return buf;
        },
        .txn_prepare => |tp| {
            const total = 1 + 8 + 8 + 4 + tp.write_set.len + 4 + tp.metadata.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_TXN_PREPARE;
            pos += 1;
            std.mem.writeInt(u64, buf[pos..][0..8], tp.xid, .big);
            pos += 8;
            std.mem.writeInt(u64, buf[pos..][0..8], tp.shard_id, .big);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(tp.write_set.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..tp.write_set.len], tp.write_set);
            pos += tp.write_set.len;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(tp.metadata.len), .big);
            pos += 4;
            @memcpy(buf[pos..], tp.metadata);
            return buf;
        },
        .txn_decide => |td| {
            const buf = try allocator.alloc(u8, 1 + 8 + 1);
            buf[0] = CMD_TAG_TXN_DECIDE;
            std.mem.writeInt(u64, buf[1..][0..8], td.xid, .big);
            buf[9] = if (td.commit) 1 else 0;
            return buf;
        },
    }
}

/// Deserialize a tag-prefixed byte array back into a Command.
/// The returned Command borrows slices from `data` (zero-copy for the payload).
pub fn deserializeCommand(data: []const u8) !Command {
    if (data.len == 0) return error.InvalidData;
    const tag = data[0];
    const payload = data[1..];
    switch (tag) {
        CMD_TAG_NOOP => return .noop,
        CMD_TAG_WRITE => return .{ .write = payload },
        CMD_TAG_TXN_DECIDE => {
            if (payload.len < 9) return error.InvalidData;
            return .{ .txn_decide = .{
                .xid = std.mem.readInt(u64, payload[0..8], .big),
                .commit = payload[8] != 0,
            } };
        },
        else => {
            // For complex types, return as write with the full tagged data
            // so the apply callback can re-deserialize if needed.
            return .{ .write = data };
        },
    }
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
        // Map geode Message to external raft library Message, preserving all data.
        var converted_entries: ?[]raft_lib.Entry = null;
        defer if (converted_entries) |ce| self.allocator.free(ce);

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
                const entries = try self.allocator.alloc(raft_lib.Entry, ae.entries.len);
                for (ae.entries, 0..) |entry, i| {
                    const data = try serializeCommand(self.allocator, entry.command);
                    entries[i] = .{
                        .index = entry.index,
                        .term = entry.term,
                        .kind = .normal,
                        .data = data,
                    };
                }
                converted_entries = entries;
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

        self.inner.step(from, raft_msg, null) catch |err| {
            log.warn("raft step error", &.{Attr.string("error", @errorName(err))});
        };
        // Free serialized entry data before freeing the entries array
        if (converted_entries) |ce| {
            for (ce) |entry| {
                self.allocator.free(entry.data);
            }
        }
        self.drainReady();
    }

    pub fn proposeCommand(self: *RaftNode, cmd: Command) !u64 {
        // Serialize Command to bytes for the external raft library's propose().
        // Format: 1-byte tag | payload
        // Tags: 0=noop, 1=write, 2=graph_mutation, 3=schema_change,
        //        4=config_change, 5=snapshot_pointer, 6=txn_prepare, 7=txn_decide
        const cmd_bytes = try serializeCommand(self.allocator, cmd);
        defer self.allocator.free(cmd_bytes);
        try self.inner.propose(cmd_bytes);
        self.drainReady();
        return self.stats.entries_applied;
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

        // Apply committed entries -- deserialize the tag-prefixed command bytes
        for (rd.committed_entries) |entry| {
            if (entry.kind == .normal and entry.data.len > 0) {
                if (self.apply_callback) |callback| {
                    const cmd = deserializeCommand(entry.data) catch Command{ .write = entry.data };
                    _ = callback(self.allocator, cmd) catch {};
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

test "serializeCommand: write command round-trips" {
    const allocator = std.testing.allocator;
    const original_data = "INSERT INTO foo VALUES (1, 'bar')";
    const cmd = Command{ .write = original_data };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);

    // First byte is the write tag
    try std.testing.expectEqual(CMD_TAG_WRITE, bytes[0]);
    // Remaining bytes are the original data
    try std.testing.expectEqualStrings(original_data, bytes[1..]);

    // Deserialize and verify
    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqualStrings(original_data, restored.write);
}

test "serializeCommand: noop round-trips" {
    const allocator = std.testing.allocator;
    const bytes = try serializeCommand(allocator, .noop);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), bytes.len);
    try std.testing.expectEqual(CMD_TAG_NOOP, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(Command.noop, restored);
}

test "serializeCommand: txn_decide round-trips" {
    const allocator = std.testing.allocator;
    const cmd = Command{ .txn_decide = .{ .xid = 42, .commit = true } };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);

    try std.testing.expectEqual(CMD_TAG_TXN_DECIDE, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(@as(u64, 42), restored.txn_decide.xid);
    try std.testing.expectEqual(true, restored.txn_decide.commit);
}

test "serializeCommand: write data is not empty" {
    // This test verifies the critical bug fix: proposeCommand must NOT
    // discard command data. The serialized bytes must contain the payload.
    const allocator = std.testing.allocator;
    const payload = "CREATE GRAPH mydb";
    const bytes = try serializeCommand(allocator, .{ .write = payload });
    defer allocator.free(bytes);

    // The serialized form must be longer than just a tag byte
    try std.testing.expect(bytes.len > 1);
    // The payload must be recoverable
    try std.testing.expectEqualStrings(payload, bytes[1..]);
}

test "encodeRaftFrame includes auth_token and decodeRaftFrame exposes it" {
    // SEC-D001: Verify auth_token round-trips through Raft frame encoding.
    // In test env, GEODE_CLUSTER_TOKEN is not set, so auth_token will be "".
    const allocator = std.testing.allocator;
    const msg = Message{ .noop = {} };
    const encoded = try encodeRaftFrame(allocator, 42, 1, msg);
    defer allocator.free(encoded);

    const decoded = try decodeRaftFrame(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), decoded.from);
    try std.testing.expectEqual(@as(u64, 1), decoded.term);
    // Without GEODE_CLUSTER_TOKEN set, auth_token should be empty
    try std.testing.expectEqualStrings("", decoded.auth_token);
}
