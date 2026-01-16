const std = @import("std");
const quic = @import("../transport/quic.zig");

// CANARY: REQ=REQ-0006; FEATURE="Distributed RPC"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=geodetestlab/specs/gap_0210_distributed_rpc.yml; OWNER=dist; UPDATED=2026-01-16
// GAP-0210 FIX: Implement real network transport for Raft/2PC RPCs

/// Message types for distributed consensus RPCs
pub const MessageType = enum(u8) {
    // Raft messages
    RequestVote = 0x01,
    RequestVoteResponse = 0x02,
    AppendEntries = 0x03,
    AppendEntriesResponse = 0x04,

    // 2PC messages
    Prepare = 0x10,
    PrepareResponse = 0x11,
    Commit = 0x12,
    CommitResponse = 0x13,
    Abort = 0x14,
    AbortResponse = 0x15,

    // Health/Discovery
    Ping = 0x20,
    Pong = 0x21,
};

pub const NodeId = u32;
pub const Term = u64;
pub const LogIndex = u64;
pub const TransactionId = u64;

/// RequestVote RPC message
pub const RequestVoteMsg = struct {
    term: Term,
    candidate_id: NodeId,
    last_log_index: LogIndex,
    last_log_term: Term,

    pub fn serialize(self: RequestVoteMsg, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 32);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(MessageType.RequestVote));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.term));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.candidate_id));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.last_log_index));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.last_log_term));

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(data: []const u8) !RequestVoteMsg {
        if (data.len < 29) return error.InvalidMessage;
        if (data[0] != @intFromEnum(MessageType.RequestVote)) return error.WrongMessageType;

        return RequestVoteMsg{
            .term = std.mem.bytesToValue(Term, data[1..9]),
            .candidate_id = std.mem.bytesToValue(NodeId, data[9..13]),
            .last_log_index = std.mem.bytesToValue(LogIndex, data[13..21]),
            .last_log_term = std.mem.bytesToValue(Term, data[21..29]),
        };
    }
};

/// RequestVote response
pub const RequestVoteResponse = struct {
    term: Term,
    vote_granted: bool,

    pub fn serialize(self: RequestVoteResponse, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 16);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(MessageType.RequestVoteResponse));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.term));
        try buf.append(allocator, if (self.vote_granted) @as(u8, 1) else @as(u8, 0));

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(data: []const u8) !RequestVoteResponse {
        if (data.len < 10) return error.InvalidMessage;
        if (data[0] != @intFromEnum(MessageType.RequestVoteResponse)) return error.WrongMessageType;

        return RequestVoteResponse{
            .term = std.mem.bytesToValue(Term, data[1..9]),
            .vote_granted = data[9] == 1,
        };
    }
};

/// AppendEntries RPC message (also used for heartbeats)
pub const AppendEntriesMsg = struct {
    term: Term,
    leader_id: NodeId,
    prev_log_index: LogIndex,
    prev_log_term: Term,
    leader_commit: LogIndex,
    entries_count: u32,
    // entries are serialized after the header

    pub fn serialize(self: AppendEntriesMsg, allocator: std.mem.Allocator, entries: []const LogEntry) ![]u8 {
        // Calculate total size
        var entries_size: usize = 0;
        for (entries) |entry| {
            entries_size += 24 + entry.command.len; // term(8) + index(8) + cmd_len(4) + committed(1) + padding(3) + cmd
        }

        var buf = try std.ArrayList(u8).initCapacity(allocator, 41 + entries_size);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(MessageType.AppendEntries));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.term));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.leader_id));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.prev_log_index));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.prev_log_term));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.leader_commit));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.entries_count));

        // Serialize entries
        for (entries) |entry| {
            try buf.appendSlice(allocator, std.mem.asBytes(&entry.term));
            try buf.appendSlice(allocator, std.mem.asBytes(&entry.index));
            const cmd_len: u32 = @intCast(entry.command.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&cmd_len));
            try buf.append(allocator, if (entry.committed) @as(u8, 1) else @as(u8, 0));
            try buf.appendSlice(allocator, &[_]u8{ 0, 0, 0 }); // padding
            try buf.appendSlice(allocator, entry.command);
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !struct { msg: AppendEntriesMsg, entries: []LogEntry } {
        if (data.len < 41) return error.InvalidMessage;
        if (data[0] != @intFromEnum(MessageType.AppendEntries)) return error.WrongMessageType;

        const msg = AppendEntriesMsg{
            .term = std.mem.bytesToValue(Term, data[1..9]),
            .leader_id = std.mem.bytesToValue(NodeId, data[9..13]),
            .prev_log_index = std.mem.bytesToValue(LogIndex, data[13..21]),
            .prev_log_term = std.mem.bytesToValue(Term, data[21..29]),
            .leader_commit = std.mem.bytesToValue(LogIndex, data[29..37]),
            .entries_count = std.mem.bytesToValue(u32, data[37..41]),
        };

        // Deserialize entries
        var entries = try allocator.alloc(LogEntry, msg.entries_count);
        errdefer allocator.free(entries);

        var offset: usize = 41;
        for (0..msg.entries_count) |i| {
            if (offset + 24 > data.len) return error.InvalidMessage;

            const term = std.mem.bytesToValue(Term, data[offset .. offset + 8]);
            const index = std.mem.bytesToValue(LogIndex, data[offset + 8 .. offset + 16]);
            const cmd_len = std.mem.bytesToValue(u32, data[offset + 16 .. offset + 20]);
            const committed = data[offset + 20] == 1;
            offset += 24;

            if (offset + cmd_len > data.len) return error.InvalidMessage;
            const command = try allocator.dupe(u8, data[offset .. offset + cmd_len]);
            offset += cmd_len;

            entries[i] = LogEntry{
                .term = term,
                .index = index,
                .command = command,
                .committed = committed,
            };
        }

        return .{ .msg = msg, .entries = entries };
    }
};

/// AppendEntries response
pub const AppendEntriesResponse = struct {
    term: Term,
    success: bool,
    match_index: LogIndex, // For leader to update match_index

    pub fn serialize(self: AppendEntriesResponse, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 24);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(MessageType.AppendEntriesResponse));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.term));
        try buf.append(allocator, if (self.success) @as(u8, 1) else @as(u8, 0));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.match_index));

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(data: []const u8) !AppendEntriesResponse {
        if (data.len < 18) return error.InvalidMessage;
        if (data[0] != @intFromEnum(MessageType.AppendEntriesResponse)) return error.WrongMessageType;

        return AppendEntriesResponse{
            .term = std.mem.bytesToValue(Term, data[1..9]),
            .success = data[9] == 1,
            .match_index = std.mem.bytesToValue(LogIndex, data[10..18]),
        };
    }
};

/// 2PC Prepare message
pub const PrepareMsg = struct {
    transaction_id: TransactionId,
    coordinator_id: NodeId,
    payload_len: u32,
    // payload follows

    pub fn serialize(self: PrepareMsg, allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 17 + payload.len);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(MessageType.Prepare));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.transaction_id));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.coordinator_id));
        const payload_len: u32 = @intCast(payload.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&payload_len));
        try buf.appendSlice(allocator, payload);

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !struct { msg: PrepareMsg, payload: []const u8 } {
        if (data.len < 17) return error.InvalidMessage;
        if (data[0] != @intFromEnum(MessageType.Prepare)) return error.WrongMessageType;

        const msg = PrepareMsg{
            .transaction_id = std.mem.bytesToValue(TransactionId, data[1..9]),
            .coordinator_id = std.mem.bytesToValue(NodeId, data[9..13]),
            .payload_len = std.mem.bytesToValue(u32, data[13..17]),
        };

        if (data.len < 17 + msg.payload_len) return error.InvalidMessage;
        const payload = try allocator.dupe(u8, data[17 .. 17 + msg.payload_len]);

        return .{ .msg = msg, .payload = payload };
    }
};

/// 2PC Prepare response
pub const PrepareResponse = struct {
    transaction_id: TransactionId,
    participant_id: NodeId,
    vote: Vote,

    pub const Vote = enum(u8) { Prepared = 1, Abort = 2 };

    pub fn serialize(self: PrepareResponse, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 16);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(MessageType.PrepareResponse));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.transaction_id));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.participant_id));
        try buf.append(allocator, @intFromEnum(self.vote));

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(data: []const u8) !PrepareResponse {
        if (data.len < 14) return error.InvalidMessage;
        if (data[0] != @intFromEnum(MessageType.PrepareResponse)) return error.WrongMessageType;

        return PrepareResponse{
            .transaction_id = std.mem.bytesToValue(TransactionId, data[1..9]),
            .participant_id = std.mem.bytesToValue(NodeId, data[9..13]),
            .vote = @enumFromInt(data[13]),
        };
    }
};

/// 2PC Commit/Abort message
pub const CommitAbortMsg = struct {
    transaction_id: TransactionId,
    coordinator_id: NodeId,

    pub fn serializeCommit(self: CommitAbortMsg, allocator: std.mem.Allocator) ![]u8 {
        return self.serializeWithType(allocator, MessageType.Commit);
    }

    pub fn serializeAbort(self: CommitAbortMsg, allocator: std.mem.Allocator) ![]u8 {
        return self.serializeWithType(allocator, MessageType.Abort);
    }

    fn serializeWithType(self: CommitAbortMsg, allocator: std.mem.Allocator, msg_type: MessageType) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 16);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(msg_type));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.transaction_id));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.coordinator_id));

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(data: []const u8) !CommitAbortMsg {
        if (data.len < 13) return error.InvalidMessage;
        const msg_type: MessageType = @enumFromInt(data[0]);
        if (msg_type != .Commit and msg_type != .Abort) return error.WrongMessageType;

        return CommitAbortMsg{
            .transaction_id = std.mem.bytesToValue(TransactionId, data[1..9]),
            .coordinator_id = std.mem.bytesToValue(NodeId, data[9..13]),
        };
    }
};

/// Log entry structure (shared with scaffold)
pub const LogEntry = struct {
    term: Term,
    index: LogIndex,
    command: []const u8,
    committed: bool = false,
};

/// Cluster node address information
pub const NodeAddress = struct {
    node_id: NodeId,
    address: []const u8,
    port: u16,
};

/// RPC Client for making outbound calls to other nodes
pub const RpcClient = struct {
    allocator: std.mem.Allocator,
    node_addresses: std.AutoHashMap(NodeId, NodeAddress),
    timeout_ms: u64 = 5000, // 5 second timeout for RPCs

    pub fn init(allocator: std.mem.Allocator) RpcClient {
        return .{
            .allocator = allocator,
            .node_addresses = std.AutoHashMap(NodeId, NodeAddress).init(allocator),
        };
    }

    pub fn deinit(self: *RpcClient) void {
        var iter = self.node_addresses.valueIterator();
        while (iter.next()) |addr| {
            self.allocator.free(addr.address);
        }
        self.node_addresses.deinit();
    }

    pub fn registerNode(self: *RpcClient, node_id: NodeId, address: []const u8, port: u16) !void {
        const addr_copy = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(addr_copy);

        try self.node_addresses.put(node_id, NodeAddress{
            .node_id = node_id,
            .address = addr_copy,
            .port = port,
        });
    }

    pub fn unregisterNode(self: *RpcClient, node_id: NodeId) void {
        if (self.node_addresses.fetchRemove(node_id)) |entry| {
            self.allocator.free(entry.value.address);
        }
    }

    /// Send RequestVote RPC and get response
    pub fn sendRequestVote(self: *RpcClient, target: NodeId, msg: RequestVoteMsg) !RequestVoteResponse {
        const data = try msg.serialize(self.allocator);
        defer self.allocator.free(data);

        const response_data = try self.sendRpc(target, data);
        defer self.allocator.free(response_data);

        return RequestVoteResponse.deserialize(response_data);
    }

    /// Send AppendEntries RPC and get response
    pub fn sendAppendEntries(self: *RpcClient, target: NodeId, msg: AppendEntriesMsg, entries: []const LogEntry) !AppendEntriesResponse {
        const data = try msg.serialize(self.allocator, entries);
        defer self.allocator.free(data);

        const response_data = try self.sendRpc(target, data);
        defer self.allocator.free(response_data);

        return AppendEntriesResponse.deserialize(response_data);
    }

    /// Send 2PC Prepare and get response
    pub fn sendPrepare(self: *RpcClient, target: NodeId, msg: PrepareMsg, payload: []const u8) !PrepareResponse {
        const data = try msg.serialize(self.allocator, payload);
        defer self.allocator.free(data);

        const response_data = try self.sendRpc(target, data);
        defer self.allocator.free(response_data);

        return PrepareResponse.deserialize(response_data);
    }

    /// Send 2PC Commit
    pub fn sendCommit(self: *RpcClient, target: NodeId, msg: CommitAbortMsg) !void {
        const data = try msg.serializeCommit(self.allocator);
        defer self.allocator.free(data);

        // Commit is fire-and-forget (best effort)
        _ = self.sendRpc(target, data) catch |err| {
            std.debug.print("WARN: Commit RPC to node {} failed: {}\n", .{ target, err });
        };
    }

    /// Send 2PC Abort
    pub fn sendAbort(self: *RpcClient, target: NodeId, msg: CommitAbortMsg) !void {
        const data = try msg.serializeAbort(self.allocator);
        defer self.allocator.free(data);

        // Abort is fire-and-forget (best effort)
        _ = self.sendRpc(target, data) catch |err| {
            std.debug.print("WARN: Abort RPC to node {} failed: {}\n", .{ target, err });
        };
    }

    /// Low-level RPC send/receive
    fn sendRpc(self: *RpcClient, target: NodeId, data: []const u8) ![]u8 {
        const node_addr = self.node_addresses.get(target) orelse return error.NodeNotFound;

        // Create QUIC client and connect
        var client = quic.QuicClient.init(self.allocator);
        defer client.deinit();

        try client.connectInsecure(node_addr.address, node_addr.port, true);
        try client.waitForHandshake(5);

        // Open stream and send data
        const stream = try client.openStream(true);
        defer stream.close();

        // Send length-prefixed message
        const len: u32 = @intCast(data.len);
        try stream.writeAll(std.mem.asBytes(&len));
        try stream.writeAll(data);
        try stream.finish();

        // Read response (with polling for async)
        var response_len_buf: [4]u8 = undefined;
        var read_pos: usize = 0;
        const timeout_ns = self.timeout_ms * std.time.ns_per_ms;
        const start = std.time.nanoTimestamp();

        while (read_pos < 4) {
            if (@as(u64, @intCast(std.time.nanoTimestamp() - start)) > timeout_ns) {
                return error.Timeout;
            }
            try client.poll(10);
            const n = stream.read(response_len_buf[read_pos..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            read_pos += n;
        }

        const response_len = std.mem.bytesToValue(u32, &response_len_buf);
        if (response_len > 1024 * 1024) return error.ResponseTooLarge;

        var response_buf = try self.allocator.alloc(u8, response_len);
        errdefer self.allocator.free(response_buf);

        read_pos = 0;
        while (read_pos < response_len) {
            if (@as(u64, @intCast(std.time.nanoTimestamp() - start)) > timeout_ns) {
                return error.Timeout;
            }
            try client.poll(10);
            const n = stream.read(response_buf[read_pos..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            read_pos += n;
        }

        return response_buf;
    }
};

/// RPC Server handler interface for processing incoming RPCs
pub const RpcHandler = struct {
    allocator: std.mem.Allocator,
    on_request_vote: ?*const fn (RequestVoteMsg) RequestVoteResponse = null,
    on_append_entries: ?*const fn (AppendEntriesMsg, []const LogEntry) AppendEntriesResponse = null,
    on_prepare: ?*const fn (PrepareMsg, []const u8) PrepareResponse = null,
    on_commit: ?*const fn (CommitAbortMsg) void = null,
    on_abort: ?*const fn (CommitAbortMsg) void = null,

    pub fn init(allocator: std.mem.Allocator) RpcHandler {
        return .{ .allocator = allocator };
    }

    /// Process an incoming RPC message and return response data
    pub fn handleMessage(self: *RpcHandler, data: []const u8) !?[]u8 {
        if (data.len == 0) return null;

        const msg_type: MessageType = @enumFromInt(data[0]);

        switch (msg_type) {
            .RequestVote => {
                if (self.on_request_vote) |handler| {
                    const msg = try RequestVoteMsg.deserialize(data);
                    const response = handler(msg);
                    const response_data = try response.serialize(self.allocator);
                    return response_data;
                }
            },
            .AppendEntries => {
                if (self.on_append_entries) |handler| {
                    const result = try AppendEntriesMsg.deserialize(self.allocator, data);
                    defer {
                        for (result.entries) |entry| {
                            self.allocator.free(entry.command);
                        }
                        self.allocator.free(result.entries);
                    }
                    const response = handler(result.msg, result.entries);
                    const response_data = try response.serialize(self.allocator);
                    return response_data;
                }
            },
            .Prepare => {
                if (self.on_prepare) |handler| {
                    const result = try PrepareMsg.deserialize(self.allocator, data);
                    defer self.allocator.free(result.payload);
                    const response = handler(result.msg, result.payload);
                    const response_data = try response.serialize(self.allocator);
                    return response_data;
                }
            },
            .Commit => {
                if (self.on_commit) |handler| {
                    const msg = try CommitAbortMsg.deserialize(data);
                    handler(msg);
                    // No response for commit
                    return null;
                }
            },
            .Abort => {
                if (self.on_abort) |handler| {
                    const msg = try CommitAbortMsg.deserialize(data);
                    handler(msg);
                    // No response for abort
                    return null;
                }
            },
            else => {
                return error.UnknownMessageType;
            },
        }

        return null;
    }
};

// Tests
test "request vote serialization" {
    const allocator = std.testing.allocator;

    const msg = RequestVoteMsg{
        .term = 5,
        .candidate_id = 42,
        .last_log_index = 100,
        .last_log_term = 4,
    };

    const data = try msg.serialize(allocator);
    defer allocator.free(data);

    const decoded = try RequestVoteMsg.deserialize(data);
    try std.testing.expectEqual(msg.term, decoded.term);
    try std.testing.expectEqual(msg.candidate_id, decoded.candidate_id);
    try std.testing.expectEqual(msg.last_log_index, decoded.last_log_index);
    try std.testing.expectEqual(msg.last_log_term, decoded.last_log_term);
}

test "request vote response serialization" {
    const allocator = std.testing.allocator;

    const response = RequestVoteResponse{
        .term = 5,
        .vote_granted = true,
    };

    const data = try response.serialize(allocator);
    defer allocator.free(data);

    const decoded = try RequestVoteResponse.deserialize(data);
    try std.testing.expectEqual(response.term, decoded.term);
    try std.testing.expectEqual(response.vote_granted, decoded.vote_granted);
}

test "append entries serialization" {
    const allocator = std.testing.allocator;

    const entries = [_]LogEntry{
        .{ .term = 1, .index = 1, .command = "SET x 1", .committed = true },
        .{ .term = 2, .index = 2, .command = "SET y 2", .committed = false },
    };

    const msg = AppendEntriesMsg{
        .term = 3,
        .leader_id = 1,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .leader_commit = 1,
        .entries_count = 2,
    };

    const data = try msg.serialize(allocator, &entries);
    defer allocator.free(data);

    const decoded = try AppendEntriesMsg.deserialize(allocator, data);
    defer {
        for (decoded.entries) |entry| {
            allocator.free(entry.command);
        }
        allocator.free(decoded.entries);
    }

    try std.testing.expectEqual(msg.term, decoded.msg.term);
    try std.testing.expectEqual(msg.entries_count, decoded.msg.entries_count);
    try std.testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try std.testing.expectEqualStrings("SET x 1", decoded.entries[0].command);
    try std.testing.expectEqualStrings("SET y 2", decoded.entries[1].command);
}

test "prepare response serialization" {
    const allocator = std.testing.allocator;

    const response = PrepareResponse{
        .transaction_id = 12345,
        .participant_id = 2,
        .vote = .Prepared,
    };

    const data = try response.serialize(allocator);
    defer allocator.free(data);

    const decoded = try PrepareResponse.deserialize(data);
    try std.testing.expectEqual(response.transaction_id, decoded.transaction_id);
    try std.testing.expectEqual(response.participant_id, decoded.participant_id);
    try std.testing.expectEqual(response.vote, decoded.vote);
}
