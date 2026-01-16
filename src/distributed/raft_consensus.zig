const std = @import("std");
const Allocator = std.mem.Allocator;
const txn_coordinator = @import("txn_coordinator.zig");

const log = std.log.scoped(.raft);

// Type aliases
pub const TxnCoordinator = txn_coordinator.TxnCoordinator;

// Client response structure for pending responses
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
    txn_prepare: TxnPrepare,
    txn_decide: TxnDecide,
};

pub const TxnPrepare = struct {
    xid: u64,
    shard_id: u64,
    write_set: []const u8, // Serialized operations
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

// RPC client for peer communication
// During `zig test` the transport/quic module may not be compiled; provide a lightweight stub.
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
        // Lazy open; if file doesn't exist return null
        if (self.current_term_file == null) {
            var dir = try std.fs.cwd().openDir(self.data_dir, .{ .iterate = true });
            defer dir.close();
            var exists = true;
            dir.access("current_term", .{}) catch |err| switch (err) {
                error.FileNotFound => exists = false,
                else => return err,
            };
            if (!exists) return null;
            self.current_term_file = try dir.openFile("current_term", .{ .mode = .read_write });
        }
        const f = self.current_term_file.?;
        try f.seekTo(0);
        var buf: [32]u8 = undefined;
        const n = try f.read(&buf);
        if (n == 0) return null;
        const slice = std.mem.trim(u8, buf[0..n], " \n\r\t");
        if (slice.len == 0) return null;
        return try std.fmt.parseInt(u64, slice, 10);
    }

    pub fn saveCurrentTerm(self: *PersistentStorage, term: u64) !void {
        if (self.current_term_file == null) {
            std.fs.cwd().makePath(self.data_dir) catch {};
            var dir = try std.fs.cwd().openDir(self.data_dir, .{ .iterate = true });
            defer dir.close();
            self.current_term_file = try dir.createFile("current_term", .{ .truncate = true });
        }
        const f = self.current_term_file.?;
        try f.seekTo(0);
        try f.writeAll("\n"); // ensure file not empty to allow atomic style replace
        try f.seekTo(0);
        var buf: [64]u8 = undefined;
        const w = std.fmt.bufPrint(&buf, "{d}\n", .{term}) catch return error.UnexpectedWriteFailure;
        try f.writeAll(w);
        try f.sync();
    }

    pub fn getVotedFor(self: *PersistentStorage) !?u64 {
        if (self.voted_for_file == null) {
            var dir = try std.fs.cwd().openDir(self.data_dir, .{ .iterate = true });
            defer dir.close();
            var exists = true;
            dir.access("voted_for", .{}) catch |err| switch (err) {
                error.FileNotFound => exists = false,
                else => return err,
            };
            if (!exists) return null;
            self.voted_for_file = try dir.openFile("voted_for", .{ .mode = .read_write });
        }
        const f = self.voted_for_file.?;
        try f.seekTo(0);
        var buf: [32]u8 = undefined;
        const n = try f.read(&buf);
        if (n == 0) return null;
        const slice = std.mem.trim(u8, buf[0..n], " \n\r\t");
        if (slice.len == 0 or std.mem.eql(u8, slice, "null")) return null;
        return try std.fmt.parseInt(u64, slice, 10);
    }

    pub fn saveVotedFor(self: *PersistentStorage, node_id: ?u64) !void {
        if (self.voted_for_file == null) {
            std.fs.cwd().makePath(self.data_dir) catch {};
            var dir = try std.fs.cwd().openDir(self.data_dir, .{ .iterate = true });
            defer dir.close();
            self.voted_for_file = try dir.createFile("voted_for", .{ .truncate = true });
        }
        const f = self.voted_for_file.?;
        try f.seekTo(0);
        var buf: [64]u8 = undefined;
        if (node_id) |id| {
            const w = std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch return error.UnexpectedWriteFailure;
            try f.writeAll(w);
        } else {
            try f.writeAll("null\n");
        }
        try f.sync();
    }

    pub fn getLogEntries(self: *PersistentStorage, allocator: Allocator) ![]LogEntry {
        // Read JSONL log entries file; each line: {"term":..,"index":..,"cmd":"tag"}
        var dir = try std.fs.cwd().openDir(self.data_dir, .{ .iterate = true });
        defer dir.close();
        var exists = true;
        dir.access("log.jsonl", .{}) catch {
            exists = false;
        };
        if (!exists) return &[_]LogEntry{};
        const file = try dir.openFile("log.jsonl", .{ .mode = .read_only });
        defer file.close();
        var list = std.ArrayList(LogEntry).initCapacity(allocator, 0) catch return error.OutOfMemory;
        defer if (false) list.deinit();
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        while (true) {
            var line_buf = std.ArrayList(u8).init(allocator);
            defer line_buf.deinit();
            const res = in_stream.readUntilDelimiterArrayList(&line_buf, '\n', 1024 * 8) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            _ = res;
            const line = std.mem.trim(u8, line_buf.items, " \r\n\t");
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
                log.warn("Skipping invalid log line: {s} err={}", .{ line, err });
                continue;
            };
            defer parsed.deinit();
            const root = parsed.value;
            if (root != .object) continue;
            const obj = root.object;
            const term_v = obj.get("term") orelse continue;
            const index_v = obj.get("index") orelse continue;
            const cmd_v = obj.get("cmd") orelse continue;
            if (term_v != .integer or index_v != .integer or cmd_v != .string) continue;
            const cmd_tag = cmd_v.string;
            var command: Command = .noop;
            if (std.mem.eql(u8, cmd_tag, "noop")) {
                // leave as noop
            } else if (std.mem.eql(u8, cmd_tag, "write")) {
                command = Command{ .write = "" }; // payload omitted
            } else if (std.mem.eql(u8, cmd_tag, "graph_mutation")) {
                command = Command{ .graph_mutation = .{ .graph = "", .mutation_type = .create, .data = "", .txn_id = null } };
            } else if (std.mem.eql(u8, cmd_tag, "schema_change")) {
                command = Command{ .schema_change = .{ .operation = .create_graph, .graph = "", .schema = "" } };
            } else if (std.mem.eql(u8, cmd_tag, "config_change")) {
                command = Command{ .config_change = .{ .change_type = .add_server, .server_id = 0, .server_endpoint = null, .server_port = null } };
            } else if (std.mem.eql(u8, cmd_tag, "snapshot_pointer")) {
                command = Command{ .snapshot_pointer = .{ .last_included_index = 0, .last_included_term = 0, .size_bytes = 0, .checksum = 0 } };
            }
            try list.append(.{ .term = @intCast(term_v.integer), .index = @intCast(index_v.integer), .command = command, .timestamp = 0, .client_id = null, .serial_number = null });
        }
        return list.toOwnedSlice();
    }

    pub fn appendLogEntry(self: *PersistentStorage, entry: LogEntry) !void {
        if (self.log_file == null) {
            std.fs.cwd().makePath(self.data_dir) catch {};
            var dir = try std.fs.cwd().openDir(self.data_dir, .{ .iterate = true });
            defer dir.close();
            var exists2 = true;
            dir.access("log.jsonl", .{}) catch {
                exists2 = false;
            };
            if (!exists2) {
                self.log_file = try dir.createFile("log.jsonl", .{ .truncate = false });
            } else {
                self.log_file = try dir.openFile("log.jsonl", .{ .mode = .read_write });
            }
        }
        const f = self.log_file.?;
        try f.seekFromEnd(0);
        var buf: [128]u8 = undefined;
        const cmd_tag = switch (entry.command) {
            .noop => "noop",
            .write => "write",
            .graph_mutation => "graph_mutation",
            .schema_change => "schema_change",
            .config_change => "config_change",
            .snapshot_pointer => "snapshot_pointer",
        };
        const line = std.fmt.bufPrint(&buf, "{\"term\":{d},\"index\":{d},\"cmd\":\"{s}\"}\n", .{ entry.term, entry.index, cmd_tag }) catch return error.UnexpectedWriteFailure;
        try f.writeAll(line);
        try f.sync();
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

// Lightweight envelope for Raft traffic over QUIC/newline framed transport.
// JSON shape: {"term":<u64>,"from":<u64>,"kind":"req_vote|req_vote_resp|append|append_resp|install_snapshot|install_snapshot_resp","payload":{...}}
pub const RaftFrameKind = enum { req_vote, req_vote_resp, append, append_resp, install_snapshot, install_snapshot_resp, snapshot_chunk };

pub fn encodeRaftFrame(allocator: Allocator, from: u64, term: u64, msg: Message) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    const kind = switch (msg) {
        .request_vote => "req_vote",
        .request_vote_response => "req_vote_resp",
        .append_entries => "append",
        .append_entries_response => "append_resp",
        .install_snapshot => "install_snapshot",
        .install_snapshot_response => "install_snapshot_resp",
    };
    try w.print("{\"term\":{d},\"from\":{d},\"kind\":\"{s}\",\"payload\":", .{ term, from, kind });
    switch (msg) {
        .request_vote => |rv| try w.print("{\"term\":{d},\"candidate_id\":{d},\"last_log_index\":{d},\"last_log_term\":{d},\"pre_vote\":{s}}", .{ rv.term, rv.candidate_id, rv.last_log_index, rv.last_log_term, if (rv.pre_vote) "true" else "false" }),
        .request_vote_response => |rvr| try w.print("{\"term\":{d},\"vote_granted\":{s},\"voter_id\":{d}}", .{ rvr.term, if (rvr.vote_granted) "true" else "false", rvr.voter_id }),
        .append_entries => |ae| {
            try w.print("{\"term\":{d},\"leader_id\":{d},\"prev_log_index\":{d},\"prev_log_term\":{d},\"leader_commit\":{d},\"entries\":[", .{ ae.term, ae.leader_id, ae.prev_log_index, ae.prev_log_term, ae.leader_commit });
            for (ae.entries, 0..) |e, i| {
                if (i > 0) try w.writeAll(",");
                const cmd_tag = switch (e.command) {
                    .noop => "noop",
                    .write => "write",
                    .graph_mutation => "graph_mutation",
                    .schema_change => "schema_change",
                    .config_change => "config_change",
                    .snapshot_pointer => "snapshot_pointer",
                };
                try w.print("{\"term\":{d},\"index\":{d},\"cmd\":\"{s}\"}", .{ e.term, e.index, cmd_tag });
            }
            try w.writeAll("]}");
        },
        .append_entries_response => |aer| try w.print("{\"term\":{d},\"success\":{s},\"match_index\":{d}}", .{ aer.term, if (aer.success) "true" else "false", aer.match_index }),
        .install_snapshot => |is| try w.print("{\"term\":{d},\"leader_id\":{d},\"last_included_index\":{d},\"last_included_term\":{d},\"offset\":{d},\"done\":{s}}", .{ is.term, is.leader_id, is.last_included_index, is.last_included_term, is.offset, if (is.done) "true" else "false" }),
        .install_snapshot_response => |isr| try w.print("{\"term\":{d}}", .{isr.term}),
    }
    try w.writeAll("}\n");
    return buf.toOwnedSlice();
}

pub const DecodedRaftFrame = struct {
    term: u64,
    from: u64,
    body: Message,
    // deinit placeholder (currently no heap inside except maybe in message entries arrays which are borrowed)
    pub fn deinit(self: DecodedRaftFrame, _: Allocator) void {
        _ = self;
    }
};

pub fn decodeRaftFrame(allocator: Allocator, line: []const u8) !DecodedRaftFrame {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidFrame;
    const obj = root.object;
    const term_v = obj.get("term") orelse return error.InvalidFrame;
    const from_v = obj.get("from") orelse return error.InvalidFrame;
    const kind_v = obj.get("kind") orelse return error.InvalidFrame;
    const payload_v = obj.get("payload") orelse return error.InvalidFrame;
    if (term_v != .integer or from_v != .integer or kind_v != .string or payload_v != .object) return error.InvalidFrame;
    const term: u64 = @intCast(term_v.integer);
    const from: u64 = @intCast(from_v.integer);
    const kind_str = kind_v.string;
    // We translate payload object back to Message union by matching kind string.
    if (std.mem.eql(u8, kind_str, "req_vote")) {
        const po = payload_v.object;
        const rv = RequestVote{
            .term = @intCast((po.get("term") orelse return error.InvalidFrame).integer),
            .candidate_id = @intCast((po.get("candidate_id") orelse return error.InvalidFrame).integer),
            .last_log_index = @intCast((po.get("last_log_index") orelse return error.InvalidFrame).integer),
            .last_log_term = @intCast((po.get("last_log_term") orelse return error.InvalidFrame).integer),
            .pre_vote = if (po.get("pre_vote")) |pv| pv == .bool and pv.bool else false,
        };
        return DecodedRaftFrame{ .term = term, .from = from, .body = .{ .request_vote = rv } };
    } else if (std.mem.eql(u8, kind_str, "req_vote_resp")) {
        const po = payload_v.object;
        const rvr = RequestVoteResponse{
            .term = @intCast((po.get("term") orelse return error.InvalidFrame).integer),
            .vote_granted = if (po.get("vote_granted") orelse return error.InvalidFrame) |vg| vg == .bool and vg.bool else false,
            .voter_id = @intCast((po.get("voter_id") orelse return error.InvalidFrame).integer),
        };
        return DecodedRaftFrame{ .term = term, .from = from, .body = .{ .request_vote_response = rvr } };
    } else if (std.mem.eql(u8, kind_str, "append")) {
        const po = payload_v.object;
        var entries: []LogEntry = &[_]LogEntry{};
        if (po.get("entries")) |ev| ev: {
            if (ev != .array) break :ev;
            const arr = ev.array.items;
            var tmp = try allocator.alloc(LogEntry, arr.len);
            errdefer allocator.free(tmp);
            for (arr, 0..) |item, i| {
                if (item != .object) return error.InvalidFrame;
                const io = item.object;
                const term_i = io.get("term") orelse return error.InvalidFrame;
                const index_i = io.get("index") orelse return error.InvalidFrame;
                if (term_i != .integer or index_i != .integer) return error.InvalidFrame;
                tmp[i] = LogEntry{ .term = @intCast(term_i.integer), .index = @intCast(index_i.integer), .command = .noop, .timestamp = 0, .client_id = null, .serial_number = null };
            }
            entries = tmp;
        }
        const ae = AppendEntries{
            .term = @intCast((po.get("term") orelse return error.InvalidFrame).integer),
            .leader_id = @intCast((po.get("leader_id") orelse return error.InvalidFrame).integer),
            .prev_log_index = @intCast((po.get("prev_log_index") orelse return error.InvalidFrame).integer),
            .prev_log_term = @intCast((po.get("prev_log_term") orelse return error.InvalidFrame).integer),
            .entries = entries,
            .leader_commit = @intCast((po.get("leader_commit") orelse return error.InvalidFrame).integer),
        };
        return DecodedRaftFrame{ .term = term, .from = from, .body = .{ .append_entries = ae } };
    } else if (std.mem.eql(u8, kind_str, "append_resp")) {
        const po = payload_v.object;
        const aer = AppendEntriesResponse{
            .term = @intCast((po.get("term") orelse return error.InvalidFrame).integer),
            .success = if (po.get("success") orelse return error.InvalidFrame) |sv| sv == .bool and sv.bool else false,
            .match_index = @intCast((po.get("match_index") orelse return error.InvalidFrame).integer),
        };
        return DecodedRaftFrame{ .term = term, .from = from, .body = .{ .append_entries_response = aer } };
    } else if (std.mem.eql(u8, kind_str, "install_snapshot")) {
        const po = payload_v.object;
        const isnap = InstallSnapshot{
            .term = @intCast((po.get("term") orelse return error.InvalidFrame).integer),
            .leader_id = @intCast((po.get("leader_id") orelse return error.InvalidFrame).integer),
            .last_included_index = @intCast((po.get("last_included_index") orelse return error.InvalidFrame).integer),
            .last_included_term = @intCast((po.get("last_included_term") orelse return error.InvalidFrame).integer),
            .offset = @intCast((po.get("offset") orelse return error.InvalidFrame).integer),
            .data = &[_]u8{},
            .done = if (po.get("done")) |dv| dv == .bool and dv.bool else false,
        };
        return DecodedRaftFrame{ .term = term, .from = from, .body = .{ .install_snapshot = isnap } };
    } else if (std.mem.eql(u8, kind_str, "install_snapshot_resp")) {
        const po = payload_v.object;
        const resp = InstallSnapshotResponse{ .term = @intCast((po.get("term") orelse return error.InvalidFrame).integer) };
        return DecodedRaftFrame{ .term = term, .from = from, .body = .{ .install_snapshot_response = resp } };
    }
    return error.InvalidFrame;
}

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
    clock: *const Clock = &RealClock.instance,

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

    // CANARY: REQ=REQ-RAFT-SNAPSHOT-001; FEATURE="SnapshotInstallation"; ASPECT=SnapshotTransfer; STATUS=IMPL; OWNER=raft; UPDATED=2026-01-10
    // Snapshot transfer state (follower receiving snapshot)
    snapshot_buffer: ?std.ArrayList(u8) = null,
    snapshot_expected_offset: u64 = 0,
    snapshot_last_included_index: u64 = 0,
    snapshot_last_included_term: u64 = 0,

    pub fn init(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
    ) !RaftNode {
        return RaftNode.initWithClock(allocator, id, peers, election_timeout_ms, &RealClock.instance);
    }

    pub fn initWithClock(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        clock: *const Clock,
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
            .last_heartbeat = clock.nowMillis(),
            .election_timer = clock.nowMillis() + @as(i64, @intCast(election_timeout_ms)),
            .clock = clock,
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
            .txn_coordinator = null,
            .pending_responses = std.StringHashMap(ClientResponse).init(allocator),
        };

        // Add initial noop entry to simplify log indexing
        try node.log.append(allocator, .{
            .term = 0,
            .index = 0,
            .command = .noop,
            .timestamp = clock.nowMillis(),
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
        if (self.txn_coordinator) |*coord| coord.deinit();
        self.pending_responses.deinit();
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

    pub fn proposeCommand(self: *RaftNode, command: Command) !bool {
        // Only leaders can propose commands
        if (self.state != .leader) return false;

        // Create log entry
        const entry = LogEntry{
            .term = self.current_term,
            .index = self.log.items.len,
            .command = command,
            .timestamp = self.clock.nowMillis(),
            .client_id = null,
            .serial_number = null,
        };

        // Append to local log
        try self.log.append(self.allocator, entry);
        self.stats.entries_appended += 1;

        // Replicate to followers
        for (self.peers) |peer| {
            try self.sendAppendEntries(peer);
        }

        return true;
    }

    pub fn tick(self: *RaftNode) !void {
        if (self.state == .shutdown) return;

        const now = self.clock.nowMillis();

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
            .timestamp = self.clock.nowMillis(),
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
        self.last_heartbeat = self.clock.nowMillis();
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
            peer.last_contact = self.clock.nowMillis();
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

    // CANARY: REQ=REQ-RAFT-SNAPSHOT-001; FEATURE="SnapshotInstallation"; ASPECT=HandleInstallSnapshot; STATUS=IMPL; OWNER=raft; UPDATED=2026-01-10
    fn handleInstallSnapshot(self: *RaftNode, is: InstallSnapshot, from: u64) !void {
        // 1. Reply immediately if term < currentTerm
        if (is.term < self.current_term) {
            try self.sendInstallSnapshotResponse(from, self.current_term);
            return;
        }

        // 2. If term > currentTerm, update term and become follower
        if (is.term > self.current_term) {
            self.current_term = is.term;
            self.voted_for = null;
            self.state = .follower;
        }

        // 3. Reset election timer (valid message from current leader)
        self.resetElectionTimer();

        // 4. If this is a new snapshot (offset == 0), initialize buffer
        if (is.offset == 0) {
            // Clear any existing snapshot buffer
            if (self.snapshot_buffer) |*buf| {
                buf.deinit();
            }
            self.snapshot_buffer = std.ArrayList(u8).init(self.allocator);
            self.snapshot_expected_offset = 0;
            self.snapshot_last_included_index = is.last_included_index;
            self.snapshot_last_included_term = is.last_included_term;
        }

        // 5. Validate offset matches expected
        if (is.offset != self.snapshot_expected_offset) {
            // Out of order chunk, reply with current term but don't process
            try self.sendInstallSnapshotResponse(from, self.current_term);
            return;
        }

        // 6. Append data to snapshot buffer
        if (self.snapshot_buffer) |*buf| {
            try buf.appendSlice(is.data);
            self.snapshot_expected_offset = is.offset + is.data.len;
        }

        // 7. If done, apply snapshot and update state
        if (is.done) {
            if (self.snapshot_buffer) |*buf| {
                // Apply snapshot via restore callback if available
                if (self.restore_callback) |restore_fn| {
                    try restore_fn(self.allocator, buf.items);
                }

                // Discard the entire log (snapshot replaces it)
                self.log.clearAndFree();

                // Update last_applied and commit_index to snapshot's last included index
                self.last_applied = self.snapshot_last_included_index;
                self.commit_index = self.snapshot_last_included_index;

                // Persist snapshot if storage is available
                if (self.storage) |storage| {
                    try storage.saveSnapshot(self.snapshot_last_included_index, self.snapshot_last_included_term, buf.items);
                }

                // Update statistics
                self.stats.snapshots_received += 1;

                // Clean up buffer
                buf.deinit();
                self.snapshot_buffer = null;
                self.snapshot_expected_offset = 0;
            }
        }

        // 8. Send response
        try self.sendInstallSnapshotResponse(from, self.current_term);
    }

    fn sendInstallSnapshotResponse(self: *RaftNode, to: u64, term: u64) !void {
        if (self.transport) |transport| {
            const response = Message{
                .install_snapshot_response = InstallSnapshotResponse{
                    .term = term,
                },
            };
            const frame = try encodeRaftFrame(self.allocator, self.id, term, response);
            defer self.allocator.free(frame);
            try transport.send(to, frame);
        }
    }

    // CANARY: REQ=REQ-RAFT-SNAPSHOT-001; FEATURE="SnapshotInstallation"; ASPECT=HandleSnapshotResponse; STATUS=IMPL; OWNER=raft; UPDATED=2026-01-10
    fn handleInstallSnapshotResponse(self: *RaftNode, isr: InstallSnapshotResponse, from: u64) !void {
        // Only leaders handle snapshot responses
        if (self.state != .leader) {
            return;
        }

        // If response contains a higher term, step down
        if (isr.term > self.current_term) {
            self.current_term = isr.term;
            self.voted_for = null;
            self.state = .follower;
            return;
        }

        // If terms match and we're still the leader, update tracking for the follower
        if (isr.term == self.current_term) {
            // Get the snapshot's last included index (stored when we sent the snapshot)
            // For now, we update next_index and match_index to the last known snapshot index
            if (self.snapshot_last_included_index > 0) {
                if (self.next_index) |*ni| {
                    try ni.put(from, self.snapshot_last_included_index + 1);
                }
                if (self.match_index) |*mi| {
                    try mi.put(from, self.snapshot_last_included_index);
                }
            }

            // Update statistics
            self.stats.snapshots_sent += 1;
        }
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

            // Internal handling for config change to adjust membership
            switch (entry.command) {
                .config_change => |cc| {
                    // Simple synchronous in-memory update (no joint consensus yet)
                    if (cc.change_type == .add_server) {
                        if (cc.server_endpoint) |ep| {
                            // Avoid duplicates
                            var exists = false;
                            for (self.peers) |p| {
                                if (p.id == cc.server_id) {
                                    exists = true;
                                    break;
                                }
                            }
                            if (!exists) {
                                var new_peers = try self.allocator.alloc(Peer, self.peers.len + 1);
                                @memcpy(new_peers[0..self.peers.len], self.peers);
                                new_peers[self.peers.len] = .{ .id = cc.server_id, .endpoint = ep, .port = cc.server_port orelse 0, .alive = true, .last_contact = self.clock.nowMillis(), .rpc_client = null };
                                self.peers = new_peers;
                            }
                        }
                    } else if (cc.change_type == .remove_server) {
                        var idx: usize = 0;
                        while (idx < self.peers.len) : (idx += 1) {
                            if (self.peers[idx].id == cc.server_id) {
                                // remove by swapping last
                                if (self.peers.len > 1) self.peers[idx] = self.peers[self.peers.len - 1];
                                self.peers = self.peers[0 .. self.peers.len - 1];
                                break;
                            }
                        }
                    }
                },

                .txn_prepare => |prepare| {
                    // Handle distributed transaction prepare phase
                    // CANARY: REQ=REQ-GQL-2PC-004; FEATURE="2PC Raft Integration"; ASPECT=2PC; STATUS=TESTED; TEST=TestCANARY_2PC_RaftIntegration; OWNER=distributed; UPDATED=2025-09-29
                    if (self.txn_coordinator) |*coordinator| {
                        const can_commit = try coordinator.handlePrepare(prepare);
                        // Store result for client response
                        if (entry.client_id) |client| {
                            try self.pending_responses.put(client, .{
                                .prepare_result = can_commit,
                                .xid = prepare.xid,
                            });
                        }
                    }
                },

                .txn_decide => |decide| {
                    // Handle distributed transaction decision
                    if (self.txn_coordinator) |*coordinator| {
                        try coordinator.handleDecide(decide);
                        // Notify client of completion
                        if (entry.client_id) |client| {
                            try self.pending_responses.put(client, .{
                                .decision = if (decide.commit) "committed" else "aborted",
                                .xid = decide.xid,
                            });
                        }
                    }
                },
                else => {},
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
        const random_timeout = self.election_timeout_ms + self.clock.rand(self.election_timeout_ms);
        self.election_timer = self.clock.nowMillis() + @as(i64, @intCast(random_timeout));
    }

    fn getPeer(self: *RaftNode, id: u64) ?*Peer {
        for (self.peers) |*peer| {
            if (peer.id == id) return peer;
        }
        return null;
    }

    fn sendMessage(self: *RaftNode, peer: Peer, msg: Message) !void {
        if (!peer.alive) return;
        const line = try encodeRaftFrame(self.allocator, self.id, self.current_term, msg);
        defer self.allocator.free(line);
        if (self.transport) |transport| {
            transport.send(peer, line) catch |err| {
                log.warn("Failed to send raft frame to peer {}: {}", .{ peer.id, err });
            };
        } else if (peer.rpc_client) |client| {
            // Wrap client to send newline-delimited frame
            if (client.client == null) {
                try client.sendMessage(msg); // fallback legacy
            } else {
                if (client.stream) |s| {
                    try s.writeAll(line);
                } else try client.sendMessage(msg);
            }
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
            .timestamp = self.clock.nowMillis(),
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

test "raft frame encode/decode round trip (heartbeat append)" {
    const allocator = std.testing.allocator;
    var peers = [_]Peer{.{ .id = 1, .endpoint = "127.0.0.1", .port = 8001, .alive = true, .last_contact = 0, .rpc_client = null }};
    var node = try RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();
    const msg = Message{ .append_entries = .{ .term = 0, .leader_id = 1, .prev_log_index = 0, .prev_log_term = 0, .entries = &[_]LogEntry{}, .leader_commit = 0 } };
    const line = try encodeRaftFrame(allocator, node.id, node.current_term, msg);
    defer allocator.free(line);
    const decoded = try decodeRaftFrame(allocator, line);
    defer decoded.deinit(allocator);
    try std.testing.expect(decoded.from == 1);
    try std.testing.expect(decoded.term == 0);
    switch (decoded.body) {
        .append_entries => {},
        else => return error.UnexpectedKind,
    }
}

// CANARY: REQ=REQ-GQL-074; FEATURE="RaftFrameEntriesArray"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_RaftFrameEntries; OWNER=cluster; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_074_RaftFrameEntries" {
    const allocator = std.testing.allocator;
    var entries = [_]LogEntry{.{ .term = 1, .index = 5, .command = .noop, .timestamp = 0, .client_id = null, .serial_number = null }};
    const msg = Message{ .append_entries = .{ .term = 1, .leader_id = 9, .prev_log_index = 4, .prev_log_term = 1, .entries = &entries, .leader_commit = 4 } };
    const line = try encodeRaftFrame(allocator, 9, 1, msg);
    defer allocator.free(line);
    const decoded = try decodeRaftFrame(allocator, line);
    defer decoded.deinit(allocator);
    switch (decoded.body) {
        .append_entries => |ae| {
            try std.testing.expect(ae.entries.len == 1);
            try std.testing.expect(ae.entries[0].index == 5);
        },
        else => return error.UnexpectedKind,
    }
}

// CANARY: REQ=REQ-GQL-074; FEATURE="RaftFrameSnapshotInstall"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_RaftFrameSnapshotInstall; OWNER=cluster; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_074_RaftFrameSnapshotInstall" {
    const allocator = std.testing.allocator;
    const snap = Message{ .install_snapshot = .{ .term = 3, .leader_id = 1, .last_included_index = 100, .last_included_term = 3, .offset = 0, .data = &[_]u8{}, .done = true } };
    const line = try encodeRaftFrame(allocator, 1, 3, snap);
    defer allocator.free(line);
    const decoded = try decodeRaftFrame(allocator, line);
    defer decoded.deinit(allocator);
    switch (decoded.body) {
        .install_snapshot => |is| {
            try std.testing.expect(is.done);
            try std.testing.expect(is.last_included_index == 100);
        },
        else => return error.UnexpectedKind,
    }
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

// CANARY: REQ=REQ-GQL-074; FEATURE="RaftPersistentStorage"; ASPECT=Durability; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_RaftPersistentStorageRoundTrip; OWNER=cluster; UPDATED=2025-09-24
test "TestCANARY_REQ_GQL_074_RaftPersistentStorageRoundTrip" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // create temp dir
    var tmp_dir_buf: [128]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_dir_buf, "raft_ps_{d}", .{std.time.milliTimestamp()});
    try std.fs.cwd().makePath(tmp_name);
    defer std.fs.cwd().deleteTree(tmp_name) catch {};

    var storage = try PersistentStorage.init(alloc, tmp_name);
    defer storage.close();
    try storage.saveCurrentTerm(7);
    try storage.saveVotedFor(42);
    try storage.appendLogEntry(.{ .term = 7, .index = 1, .command = .noop, .timestamp = 0, .client_id = null, .serial_number = null });

    const term = try storage.getCurrentTerm();
    try testing.expect(term.? == 7);
    const voted = try storage.getVotedFor();
    try testing.expect(voted.? == 42);
    const entries = try storage.getLogEntries(alloc);
    defer alloc.free(entries);
    try testing.expect(entries.len == 1);
    try testing.expect(entries[0].index == 1);

    // Re-open storage new instance
    var storage2 = try PersistentStorage.init(alloc, tmp_name);
    defer storage2.close();
    const term2 = try storage2.getCurrentTerm();
    try testing.expect(term2.? == 7);
    const voted2 = try storage2.getVotedFor();
    try testing.expect(voted2.? == 42);
}
