const std = @import("std");
const Allocator = std.mem.Allocator;
const quic = @import("transport/quic");

/// Two-Phase Commit transaction states
pub const TransactionState = enum {
    active,
    preparing,
    prepared,
    committing,
    committed,
    aborting,
    aborted,
};

/// 2PC message types
pub const MessageType = enum {
    prepare,
    prepare_response,
    commit,
    commit_response,
    abort,
    abort_response,
    recovery_request,
    recovery_response,
};

/// Participant response to prepare
pub const PrepareResponse = enum {
    vote_commit,
    vote_abort,
    timeout,
};

/// Operation types
pub const Operation = union(enum) {
    create_node: NodeOp,
    update_node: NodeOp,
    delete_node: NodeOp,
    create_edge: EdgeOp,
    update_edge: EdgeOp,
    delete_edge: EdgeOp,
};

pub const NodeOp = struct {
    node_id: u64,
    label: []const u8,
    properties: []const u8,
};

pub const EdgeOp = struct {
    edge_id: u64,
    source_id: u64,
    target_id: u64,
    edge_type: []const u8,
    properties: []const u8,
};

/// Undo log entry for rollback
pub const UndoEntry = struct {
    operation: Operation,
    old_value: []const u8,
    timestamp: i64,
};

/// Redo log entry for recovery
pub const RedoEntry = struct {
    operation: Operation,
    new_value: []const u8,
    timestamp: i64,
};

/// Transaction participant information
pub const Participant = struct {
    id: []const u8,
    endpoint: []const u8,
    state: TransactionState,
    last_message_time: i64,
    prepare_response: ?PrepareResponse,
    undo_log: std.ArrayList(UndoEntry),
    redo_log: std.ArrayList(RedoEntry),
};

pub const IsolationLevel = enum {
    read_uncommitted,
    read_committed,
    repeatable_read,
    serializable,
};

pub const Savepoint = struct {
    name: []const u8,
    operation_index: usize,
    timestamp: i64,
};

// CANARY: REQ=REQ-DIST-2PC-MSG-001; FEATURE="Two-Phase Commit Message Format"; ASPECT=Protocol; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-08
/// 2PC protocol message for network communication
pub const TwoPhaseMessage = struct {
    msg_type: MessageType,
    transaction_id: []const u8,
    coordinator_id: []const u8,
    timestamp: i64,
    operations: []const Operation,
};

/// Response to a 2PC message
pub const TwoPhaseResponse = struct {
    msg_type: MessageType,
    transaction_id: []const u8,
    participant_id: []const u8,
    vote: PrepareResponse,
    timestamp: i64,
};

/// Connection pool for 2PC participant connections
pub const TwoPhaseTransport = struct {
    allocator: Allocator,
    connections: std.StringHashMap(ConnectionEntry),
    mutex: std.Thread.Mutex,

    pub const ConnectionEntry = struct {
        client: quic.QuicClient,
        stream: ?*quic.QuicClientStream,
        last_used: i64,
        endpoint: []const u8,
    };

    pub fn init(allocator: Allocator) TwoPhaseTransport {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(ConnectionEntry).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *TwoPhaseTransport) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.stream) |stream| {
                stream.close();
            }
            entry.value_ptr.client.deinit();
            self.allocator.free(entry.value_ptr.endpoint);
        }
        self.connections.deinit();
    }

    /// Get or create a connection to endpoint (format: "host:port")
    pub fn getConnection(self: *TwoPhaseTransport, endpoint: []const u8) !*ConnectionEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.getPtr(endpoint)) |entry| {
            entry.last_used = std.time.timestamp();
            return entry;
        }

        // Parse endpoint into host and port
        // GAP-0144: Secure TLS connections for 2PC coordination
        // CANARY: REQ=REQ-2PC-TLS-001; FEATURE="2PC TLS"; ASPECT=Security; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-13
        const colon_pos = std.mem.indexOf(u8, endpoint, ":") orelse return error.InvalidEndpoint;
        const host = endpoint[0..colon_pos];
        const port_str = endpoint[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;

        // Check if insecure mode is explicitly allowed
        const builtin = @import("builtin");
        const allow_insecure = blk: {
            if (builtin.mode == .Debug) break :blk true;
            const env = std.process.getEnvVarOwned(self.allocator, "GEODE_CLUSTER_INSECURE") catch null;
            if (env) |v| {
                defer self.allocator.free(v);
                if (std.mem.eql(u8, v, "1")) {
                    std.log.warn("SECURITY WARNING: 2PC TLS verification disabled", .{});
                    break :blk true;
                }
            }
            break :blk false;
        };

        // Create new connection with TLS verification by default
        var client = quic.QuicClient.init(self.allocator);
        client.connectInsecure(host, port, allow_insecure) catch |err| {
            std.debug.print("2PC_TRANSPORT: Failed to connect to {s}: {}\n", .{ endpoint, err });
            return error.ConnectionFailed;
        };

        // Wait for handshake
        client.waitForHandshake(5) catch |err| {
            client.deinit();
            std.debug.print("2PC_TRANSPORT: Handshake failed for {s}: {}\n", .{ endpoint, err });
            return error.HandshakeFailed;
        };

        const entry = ConnectionEntry{
            .client = client,
            .stream = null,
            .last_used = std.time.timestamp(),
            .endpoint = try self.allocator.dupe(u8, endpoint),
        };

        try self.connections.put(endpoint, entry);
        return self.connections.getPtr(endpoint).?;
    }

    // CANARY: REQ=REQ-2PC-TIMEOUT-001; FEATURE="2PCTimeout"; ASPECT=Transport; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-09
    /// Send a 2PC message and receive response with timeout handling
    pub fn sendMessage(self: *TwoPhaseTransport, endpoint: []const u8, msg: TwoPhaseMessage, timeout_ms: u64) !TwoPhaseResponse {
        const start_time = std.time.milliTimestamp();

        const conn = try self.getConnection(endpoint);

        // Get or create stream
        if (conn.stream == null) {
            conn.stream = try conn.client.openStream(true);
        }
        const stream = conn.stream.?;

        // Serialize message to JSON
        const json_msg = try serializeTwoPhaseMessage(self.allocator, msg);
        defer self.allocator.free(json_msg);

        // Check timeout before sending
        const elapsed = std.time.milliTimestamp() - start_time;
        if (elapsed >= @as(i64, @intCast(timeout_ms))) {
            std.debug.print("2PC_TRANSPORT: Timeout before send to {s}\n", .{endpoint});
            return error.Timeout;
        }

        // Send message
        try stream.writeAll(json_msg);

        // Poll for response with timeout
        const remaining_timeout = timeout_ms - @as(u64, @intCast(@max(0, elapsed)));
        const poll_interval: u64 = @min(100, remaining_timeout);
        var total_polled: u64 = 0;

        while (total_polled < remaining_timeout) {
            try conn.client.poll(@intCast(poll_interval));

            // Try to read response
            if (stream.readLine(4096)) |response_line| {
                defer self.allocator.free(response_line);
                return try parseTwoPhaseResponse(self.allocator, response_line);
            } else |err| {
                // Check if it's just waiting for data vs actual error
                if (err != error.WouldBlock) {
                    std.debug.print("2PC_TRANSPORT: Failed to read response from {s}: {}\n", .{ endpoint, err });
                    return error.ReadFailed;
                }
            }

            total_polled += poll_interval;
        }

        // Timeout reached
        std.debug.print("2PC_TRANSPORT: Timeout waiting for response from {s} after {}ms\n", .{ endpoint, timeout_ms });
        return error.Timeout;
    }
};

/// Global transport instance for 2PC messaging
var global_transport: ?*TwoPhaseTransport = null;
var transport_allocator: ?Allocator = null;

/// Initialize the global 2PC transport
pub fn initTransport(allocator: Allocator) !void {
    if (global_transport != null) return;
    transport_allocator = allocator;
    global_transport = try allocator.create(TwoPhaseTransport);
    global_transport.?.* = TwoPhaseTransport.init(allocator);
}

/// Deinitialize the global 2PC transport
pub fn deinitTransport() void {
    if (global_transport) |transport| {
        transport.deinit();
        if (transport_allocator) |allocator| {
            allocator.destroy(transport);
        }
        global_transport = null;
        transport_allocator = null;
    }
}

/// Serialize TwoPhaseMessage to JSON (newline-terminated)
fn serializeTwoPhaseMessage(allocator: Allocator, msg: TwoPhaseMessage) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    const writer = buffer.writer();
    try writer.print("{{\"msg_type\":\"{s}\",\"txn_id\":\"{s}\",\"coord_id\":\"{s}\",\"ts\":{d},\"ops\":[", .{
        @tagName(msg.msg_type),
        msg.transaction_id,
        msg.coordinator_id,
        msg.timestamp,
    });

    // Serialize operations
    for (msg.operations, 0..) |op, i| {
        if (i > 0) try writer.writeAll(",");
        try serializeOperation(writer, op);
    }

    try writer.writeAll("]}\n");
    return buffer.toOwnedSlice();
}

/// Serialize a single operation to JSON
fn serializeOperation(writer: anytype, op: Operation) !void {
    switch (op) {
        .create_node => |node_op| {
            try writer.print("{{\"type\":\"create_node\",\"node_id\":{d},\"label\":\"{s}\",\"props\":\"{s}\"}}", .{
                node_op.node_id,
                node_op.label,
                node_op.properties,
            });
        },
        .update_node => |node_op| {
            try writer.print("{{\"type\":\"update_node\",\"node_id\":{d},\"label\":\"{s}\",\"props\":\"{s}\"}}", .{
                node_op.node_id,
                node_op.label,
                node_op.properties,
            });
        },
        .delete_node => |node_op| {
            try writer.print("{{\"type\":\"delete_node\",\"node_id\":{d},\"label\":\"{s}\",\"props\":\"{s}\"}}", .{
                node_op.node_id,
                node_op.label,
                node_op.properties,
            });
        },
        .create_edge => |edge_op| {
            try writer.print("{{\"type\":\"create_edge\",\"edge_id\":{d},\"src\":{d},\"tgt\":{d},\"type\":\"{s}\",\"props\":\"{s}\"}}", .{
                edge_op.edge_id,
                edge_op.source_id,
                edge_op.target_id,
                edge_op.edge_type,
                edge_op.properties,
            });
        },
        .update_edge => |edge_op| {
            try writer.print("{{\"type\":\"update_edge\",\"edge_id\":{d},\"src\":{d},\"tgt\":{d},\"type\":\"{s}\",\"props\":\"{s}\"}}", .{
                edge_op.edge_id,
                edge_op.source_id,
                edge_op.target_id,
                edge_op.edge_type,
                edge_op.properties,
            });
        },
        .delete_edge => |edge_op| {
            try writer.print("{{\"type\":\"delete_edge\",\"edge_id\":{d},\"src\":{d},\"tgt\":{d},\"type\":\"{s}\",\"props\":\"{s}\"}}", .{
                edge_op.edge_id,
                edge_op.source_id,
                edge_op.target_id,
                edge_op.edge_type,
                edge_op.properties,
            });
        },
    }
}

/// Parse TwoPhaseResponse from JSON line
fn parseTwoPhaseResponse(allocator: Allocator, json_line: []const u8) !TwoPhaseResponse {
    // Trim trailing newline if present
    const line = std.mem.trimRight(u8, json_line, "\n\r");

    // Simple JSON parsing - extract key fields
    const msg_type_str = extractJsonString(line, "msg_type") orelse return error.InvalidResponse;
    const txn_id = extractJsonString(line, "txn_id") orelse return error.InvalidResponse;
    const participant_id = extractJsonString(line, "participant_id") orelse "unknown";
    const vote_str = extractJsonString(line, "vote") orelse return error.InvalidResponse;
    const timestamp = extractJsonInt(line, "ts") orelse std.time.timestamp();

    // Parse message type
    const msg_type: MessageType = if (std.mem.eql(u8, msg_type_str, "prepare_response"))
        .prepare_response
    else if (std.mem.eql(u8, msg_type_str, "commit_response"))
        .commit_response
    else if (std.mem.eql(u8, msg_type_str, "abort_response"))
        .abort_response
    else
        return error.InvalidMessageType;

    // Parse vote
    const vote: PrepareResponse = if (std.mem.eql(u8, vote_str, "vote_commit"))
        .vote_commit
    else if (std.mem.eql(u8, vote_str, "vote_abort"))
        .vote_abort
    else
        .timeout;

    // Dupe strings so they outlive the parse
    const txn_id_copy = try allocator.dupe(u8, txn_id);
    const participant_id_copy = try allocator.dupe(u8, participant_id);

    return TwoPhaseResponse{
        .msg_type = msg_type,
        .transaction_id = txn_id_copy,
        .participant_id = participant_id_copy,
        .vote = vote,
        .timestamp = timestamp,
    };
}

/// Extract a string value from JSON by key name
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"
    const search_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":\"", .{key}) catch return null;
    defer std.heap.page_allocator.free(search_pattern);

    const start_idx = std.mem.indexOf(u8, json, search_pattern) orelse return null;
    const value_start = start_idx + search_pattern.len;

    // Find closing quote
    const value_end = std.mem.indexOfPos(u8, json, value_start, "\"") orelse return null;

    return json[value_start..value_end];
}

/// Extract an integer value from JSON by key name
fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    // Find "key":
    const search_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(search_pattern);

    const start_idx = std.mem.indexOf(u8, json, search_pattern) orelse return null;
    const value_start = start_idx + search_pattern.len;

    // Find end of number (comma, }, or whitespace)
    var value_end = value_start;
    while (value_end < json.len) : (value_end += 1) {
        const c = json[value_end];
        if (c == ',' or c == '}' or c == ' ' or c == '\n') break;
    }

    return std.fmt.parseInt(i64, json[value_start..value_end], 10) catch null;
}

// CANARY: REQ=REQ-DIST-2PC-TRANSPORT-001; FEATURE="Two-Phase Commit Network Transport"; ASPECT=QUICMessaging; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-09
/// Send a 2PC message to a participant endpoint using QUIC transport
fn sendMessage(endpoint: []const u8, msg: TwoPhaseMessage, timeout_ms: u64) !TwoPhaseResponse {
    // Use global transport if available, otherwise fall back to creating a one-shot connection
    if (global_transport) |transport| {
        return transport.sendMessage(endpoint, msg, timeout_ms);
    }

    // GAP-0144: Secure TLS for one-shot 2PC connections
    // CANARY: REQ=REQ-2PC-TLS-002; FEATURE="2PC TLS One-shot"; ASPECT=Security; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-13
    // One-shot connection for when transport not initialized
    // Parse endpoint into host and port
    const colon_pos = std.mem.indexOf(u8, endpoint, ":") orelse return error.InvalidEndpoint;
    const host = endpoint[0..colon_pos];
    const port_str = endpoint[colon_pos + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;

    // Create allocator for this operation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check if insecure mode is explicitly allowed
    const builtin = @import("builtin");
    const allow_insecure = blk: {
        if (builtin.mode == .Debug) break :blk true;
        const env = std.process.getEnvVarOwned(allocator, "GEODE_CLUSTER_INSECURE") catch null;
        if (env) |v| {
            defer allocator.free(v);
            if (std.mem.eql(u8, v, "1")) break :blk true;
        }
        break :blk false;
    };

    // Create QUIC client and connect with TLS verification by default
    var client = quic.QuicClient.init(allocator);
    defer client.deinit();

    client.connectInsecure(host, port, allow_insecure) catch |err| {
        std.debug.print("2PC_TRANSPORT: One-shot connect failed to {s}: {}\n", .{ endpoint, err });
        return error.ConnectionFailed;
    };

    // Wait for handshake with timeout
    const handshake_timeout: u32 = @intCast(@min(timeout_ms / 1000, 5));
    client.waitForHandshake(if (handshake_timeout == 0) 1 else handshake_timeout) catch |err| {
        std.debug.print("2PC_TRANSPORT: Handshake failed: {}\n", .{err});
        return error.HandshakeFailed;
    };

    // Open stream
    const stream = try client.openStream(true);
    defer stream.close();

    // Serialize and send message
    const json_msg = try serializeTwoPhaseMessage(allocator, msg);
    defer allocator.free(json_msg);

    try stream.writeAll(json_msg);

    // Poll and read response
    try client.poll(100);

    const response_line = stream.readLine(4096) catch |err| {
        std.debug.print("2PC_TRANSPORT: Read response failed: {}\n", .{err});
        return error.ReadFailed;
    };
    defer allocator.free(response_line);

    // Parse and return response
    return try parseTwoPhaseResponse(allocator, response_line);
}

/// Apply an undo operation to rollback a change
fn applyUndoOperation(entry: UndoEntry) !void {
    // Implementation would reverse the operation
    // In production, this interacts with the storage layer
    switch (entry.operation) {
        .create_node => |op| {
            // Undo create = delete the node
            _ = op;
            // storage.deleteNode(op.node_id);
        },
        .update_node => |op| {
            // Undo update = restore old value
            _ = op;
            // storage.updateNode(op.node_id, entry.old_value);
        },
        .delete_node => |op| {
            // Undo delete = recreate the node
            _ = op;
            // storage.createNode(op.node_id, entry.old_value);
        },
        .create_edge => |op| {
            // Undo create = delete the edge
            _ = op;
            // storage.deleteEdge(op.edge_id);
        },
        .update_edge => |op| {
            // Undo update = restore old value
            _ = op;
            // storage.updateEdge(op.edge_id, entry.old_value);
        },
        .delete_edge => |op| {
            // Undo delete = recreate the edge
            _ = op;
            // storage.createEdge(op.edge_id, entry.old_value);
        },
    }
}

/// 2PC transaction context
pub const Transaction = struct {
    id: []const u8,
    coordinator_id: []const u8,
    participants: std.ArrayList(Participant),
    state: TransactionState,
    start_time: i64,
    timeout_ms: u64,
    operations: std.ArrayList(Operation),
    isolation_level: IsolationLevel,
    savepoints: std.ArrayList(Savepoint),

    pub fn init(allocator: Allocator, id: []const u8, coordinator_id: []const u8) !Transaction {
        return .{
            .id = try allocator.dupe(u8, id),
            .coordinator_id = try allocator.dupe(u8, coordinator_id),
            .participants = std.ArrayList(Participant){},
            .state = .active,
            .start_time = std.time.timestamp(),
            .timeout_ms = 30000, // 30 seconds default
            .operations = std.ArrayList(Operation){},
            .isolation_level = .read_committed,
            .savepoints = std.ArrayList(Savepoint){},
        };
    }

    pub fn deinit(self: *Transaction, allocator: Allocator) void {
        for (self.participants.items) |*participant| {
            allocator.free(participant.id);
            allocator.free(participant.endpoint);
            participant.undo_log.deinit();
            participant.redo_log.deinit();
        }
        self.participants.deinit();
        self.operations.deinit();
        self.savepoints.deinit();
        allocator.free(self.id);
        allocator.free(self.coordinator_id);
    }

    pub fn addParticipant(self: *Transaction, allocator: Allocator, id: []const u8, endpoint: []const u8) !void {
        const participant = Participant{
            .id = try allocator.dupe(u8, id),
            .endpoint = try allocator.dupe(u8, endpoint),
            .state = .active,
            .last_message_time = std.time.timestamp(),
            .prepare_response = null,
            .undo_log = std.ArrayList(UndoEntry){},
            .redo_log = std.ArrayList(RedoEntry){},
        };
        try self.participants.append(participant);
    }

    pub fn addOperation(self: *Transaction, operation: Operation) !void {
        try self.operations.append(operation);
    }

    pub fn createSavepoint(self: *Transaction, allocator: Allocator, name: []const u8) !void {
        const savepoint = Savepoint{
            .name = try allocator.dupe(u8, name),
            .operation_index = self.operations.items.len,
            .timestamp = std.time.timestamp(),
        };
        try self.savepoints.append(savepoint);
    }

    pub fn rollbackToSavepoint(self: *Transaction, name: []const u8) !void {
        for (self.savepoints.items) |savepoint| {
            if (std.mem.eql(u8, savepoint.name, name)) {
                // Remove operations after savepoint
                self.operations.shrinkRetainingCapacity(savepoint.operation_index);
                return;
            }
        }
        return error.SavepointNotFound;
    }

    pub fn prepare(self: *Transaction) !bool {
        self.state = .preparing;

        // CANARY: REQ=REQ-DIST-2PC-001; FEATURE="Two-Phase Commit Messaging"; ASPECT=Prepare; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-08
        // Send prepare messages to all participants
        var all_voted_commit = true;
        for (self.participants.items) |*participant| {
            participant.state = .preparing;

            // Create and send prepare message
            const msg = TwoPhaseMessage{
                .msg_type = .prepare,
                .transaction_id = self.id,
                .coordinator_id = self.coordinator_id,
                .timestamp = std.time.timestamp(),
                .operations = self.operations.items,
            };

            // Send message to participant (async with timeout)
            const response = sendMessage(participant.endpoint, msg, self.timeout_ms) catch |err| {
                // Network error - treat as abort vote
                participant.prepare_response = .timeout;
                all_voted_commit = false;
                _ = err;
                continue;
            };

            participant.prepare_response = response.vote;
            participant.last_message_time = std.time.timestamp();

            if (response.vote != .vote_commit) {
                all_voted_commit = false;
            }
        }

        // Check all votes
        if (!all_voted_commit) {
            self.state = .aborting;
            return false;
        }

        self.state = .prepared;
        return true;
    }

    pub fn commit(self: *Transaction) !void {
        if (self.state != .prepared) {
            return error.InvalidState;
        }

        self.state = .committing;

        // CANARY: REQ=REQ-DIST-2PC-002; FEATURE="Two-Phase Commit Messaging"; ASPECT=Commit; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-08
        // Send commit messages to all participants
        for (self.participants.items) |*participant| {
            participant.state = .committing;

            // Create and send commit message
            const msg = TwoPhaseMessage{
                .msg_type = .commit,
                .transaction_id = self.id,
                .coordinator_id = self.coordinator_id,
                .timestamp = std.time.timestamp(),
                .operations = &.{},
            };

            // Send commit message (with retry for reliability)
            var retries: u32 = 0;
            const max_retries: u32 = 3;
            while (retries < max_retries) : (retries += 1) {
                _ = sendMessage(participant.endpoint, msg, self.timeout_ms) catch {
                    // Retry after exponential backoff
                    std.time.sleep(@as(u64, 100) << @intCast(retries) * std.time.ns_per_ms);
                    continue;
                };
                break;
            }

            participant.state = .committed;
            participant.last_message_time = std.time.timestamp();
        }

        self.state = .committed;
    }

    pub fn abort(self: *Transaction) !void {
        self.state = .aborting;

        // CANARY: REQ=REQ-DIST-2PC-003; FEATURE="Two-Phase Commit Messaging"; ASPECT=Abort; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-08
        // Send abort messages to all participants
        for (self.participants.items) |*participant| {
            participant.state = .aborting;

            // Create and send abort message
            const msg = TwoPhaseMessage{
                .msg_type = .abort,
                .transaction_id = self.id,
                .coordinator_id = self.coordinator_id,
                .timestamp = std.time.timestamp(),
                .operations = &.{},
            };

            // Send abort message (best effort - proceed even if some fail)
            _ = sendMessage(participant.endpoint, msg, self.timeout_ms) catch {
                // Log failure but continue aborting other participants
            };

            // Apply undo log to rollback changes
            while (participant.undo_log.popOrNull()) |undo_entry| {
                // Apply undo operation to restore previous state
                try applyUndoOperation(undo_entry);
            }

            participant.state = .aborted;
            participant.last_message_time = std.time.timestamp();
        }

        self.state = .aborted;
    }

    pub fn isTimedOut(self: *Transaction) bool {
        const current_time = std.time.timestamp();
        const elapsed_ms = @as(u64, @intCast((current_time - self.start_time) * 1000));
        return elapsed_ms > self.timeout_ms;
    }
};

/// Two-Phase Commit Coordinator
pub const Coordinator = struct {
    allocator: Allocator,
    node_id: []const u8,
    transactions: std.StringHashMap(Transaction),
    log_writer: ?*LogWriter,

    pub const LogWriter = struct {
        file: std.fs.File,

        pub fn writeEntry(self: *LogWriter, entry: LogEntry) !void {
            const json = try std.json.stringify(entry, .{}, self.file.writer());
            try self.file.writer().writeByte('\n');
            _ = json;
        }
    };

    pub const LogEntry = struct {
        timestamp: i64,
        transaction_id: []const u8,
        event_type: LogEventType,
        data: []const u8,
    };

    pub const LogEventType = enum {
        transaction_start,
        prepare_sent,
        vote_received,
        commit_decision,
        abort_decision,
        transaction_complete,
    };

    pub fn init(allocator: Allocator, node_id: []const u8) Coordinator {
        return .{
            .allocator = allocator,
            .node_id = node_id,
            .transactions = std.StringHashMap(Transaction).init(allocator),
            .log_writer = null,
        };
    }

    pub fn deinit(self: *Coordinator) void {
        var it = self.transactions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.transactions.deinit();
    }

    pub fn beginTransaction(self: *Coordinator, transaction_id: []const u8) !*Transaction {
        const txn = try Transaction.init(self.allocator, transaction_id, self.node_id);
        try self.transactions.put(transaction_id, txn);

        // Log transaction start
        if (self.log_writer) |writer| {
            try writer.writeEntry(.{
                .timestamp = std.time.timestamp(),
                .transaction_id = transaction_id,
                .event_type = .transaction_start,
                .data = "",
            });
        }

        return self.transactions.getPtr(transaction_id).?;
    }

    pub fn executeTransaction(self: *Coordinator, transaction_id: []const u8) !bool {
        const txn = self.transactions.getPtr(transaction_id) orelse return error.TransactionNotFound;

        // Phase 1: Prepare
        const can_commit = try txn.prepare();

        if (self.log_writer) |writer| {
            try writer.writeEntry(.{
                .timestamp = std.time.timestamp(),
                .transaction_id = transaction_id,
                .event_type = if (can_commit) .commit_decision else .abort_decision,
                .data = "",
            });
        }

        // Phase 2: Commit or Abort
        if (can_commit) {
            try txn.commit();
        } else {
            try txn.abort();
        }

        if (self.log_writer) |writer| {
            try writer.writeEntry(.{
                .timestamp = std.time.timestamp(),
                .transaction_id = transaction_id,
                .event_type = .transaction_complete,
                .data = "",
            });
        }

        return can_commit;
    }

    pub fn recoverFromLog(self: *Coordinator, log_file: []const u8) !void {
        const file = try std.fs.cwd().openFile(log_file, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var reader = buf_reader.reader();

        var line_buf: [4096]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            // Parse log entry
            const entry = try std.json.parseFromSlice(LogEntry, self.allocator, line, .{});
            defer entry.deinit();

            // Recover transaction state
            switch (entry.value.event_type) {
                .transaction_start => {
                    _ = try self.beginTransaction(entry.value.transaction_id);
                },
                .commit_decision => {
                    if (self.transactions.getPtr(entry.value.transaction_id)) |txn| {
                        if (txn.state != .committed) {
                            // Need to complete commit
                            try txn.commit();
                        }
                    }
                },
                .abort_decision => {
                    if (self.transactions.getPtr(entry.value.transaction_id)) |txn| {
                        if (txn.state != .aborted) {
                            // Need to complete abort
                            try txn.abort();
                        }
                    }
                },
                else => {},
            }
        }
    }
};

// CANARY: REQ=REQ-2PC-STORAGE-001; FEATURE="2PC Storage Interface"; ASPECT=Interface; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-10
/// Storage interface for 2PC operations - abstracts the underlying storage mechanism
pub const StorageInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createNode: *const fn (ptr: *anyopaque, node_id: u64, label: []const u8, properties: []const u8) anyerror!void,
        updateNode: *const fn (ptr: *anyopaque, node_id: u64, properties: []const u8) anyerror!void,
        deleteNode: *const fn (ptr: *anyopaque, node_id: u64) anyerror!void,
        createEdge: *const fn (ptr: *anyopaque, edge_id: u64, source: u64, target: u64, edge_type: []const u8, properties: []const u8) anyerror!void,
        updateEdge: *const fn (ptr: *anyopaque, edge_id: u64, properties: []const u8) anyerror!void,
        deleteEdge: *const fn (ptr: *anyopaque, edge_id: u64) anyerror!void,
        getNodeProperties: *const fn (ptr: *anyopaque, node_id: u64) anyerror![]const u8,
        getEdgeProperties: *const fn (ptr: *anyopaque, edge_id: u64) anyerror![]const u8,
    };

    pub fn createNode(self: StorageInterface, node_id: u64, label: []const u8, properties: []const u8) !void {
        return self.vtable.createNode(self.ptr, node_id, label, properties);
    }

    pub fn updateNode(self: StorageInterface, node_id: u64, properties: []const u8) !void {
        return self.vtable.updateNode(self.ptr, node_id, properties);
    }

    pub fn deleteNode(self: StorageInterface, node_id: u64) !void {
        return self.vtable.deleteNode(self.ptr, node_id);
    }

    pub fn createEdge(self: StorageInterface, edge_id: u64, source: u64, target: u64, edge_type: []const u8, properties: []const u8) !void {
        return self.vtable.createEdge(self.ptr, edge_id, source, target, edge_type, properties);
    }

    pub fn updateEdge(self: StorageInterface, edge_id: u64, properties: []const u8) !void {
        return self.vtable.updateEdge(self.ptr, edge_id, properties);
    }

    pub fn deleteEdge(self: StorageInterface, edge_id: u64) !void {
        return self.vtable.deleteEdge(self.ptr, edge_id);
    }

    pub fn getNodeProperties(self: StorageInterface, node_id: u64) ![]const u8 {
        return self.vtable.getNodeProperties(self.ptr, node_id);
    }

    pub fn getEdgeProperties(self: StorageInterface, edge_id: u64) ![]const u8 {
        return self.vtable.getEdgeProperties(self.ptr, edge_id);
    }
};

/// Two-Phase Commit Participant
// CANARY: REQ=REQ-2PC-PARTICIPANT-001; FEATURE="2PC Participant Node"; ASPECT=StorageOps; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-10
pub const ParticipantNode = struct {
    allocator: Allocator,
    node_id: []const u8,
    transactions: std.StringHashMap(LocalTransaction),
    resource_manager: *ResourceManager,
    storage: ?StorageInterface,

    pub const LocalTransaction = struct {
        id: []const u8,
        coordinator_id: []const u8,
        state: TransactionState,
        operations: std.ArrayList(Operation),
        undo_log: std.ArrayList(UndoEntry),
        redo_log: std.ArrayList(RedoEntry),
        locks: std.ArrayList(Lock),
    };

    pub const Lock = struct {
        resource_id: u64,
        lock_type: LockType,
        acquired_at: i64,
    };

    pub const LockType = enum {
        shared,
        exclusive,
    };

    pub const ResourceManager = struct {
        locks: std.AutoHashMap(u64, LockInfo),

        pub const LockInfo = struct {
            holder: ?[]const u8,
            lock_type: LockType,
            waiters: std.ArrayList([]const u8),
        };

        pub fn acquireLock(self: *ResourceManager, resource_id: u64, transaction_id: []const u8, lock_type: LockType) !bool {
            const result = try self.locks.getOrPut(resource_id);
            if (!result.found_existing) {
                result.value_ptr.* = .{
                    .holder = transaction_id,
                    .lock_type = lock_type,
                    .waiters = std.ArrayList([]const u8){},
                };
                return true;
            }

            // Check compatibility
            if (result.value_ptr.holder == null) {
                result.value_ptr.holder = transaction_id;
                result.value_ptr.lock_type = lock_type;
                return true;
            }

            // Add to waiters
            try result.value_ptr.waiters.append(transaction_id);
            return false;
        }

        pub fn releaseLock(self: *ResourceManager, resource_id: u64, transaction_id: []const u8) !void {
            if (self.locks.getPtr(resource_id)) |lock_info| {
                if (lock_info.holder) |holder| {
                    if (std.mem.eql(u8, holder, transaction_id)) {
                        // Release lock and give to next waiter
                        if (lock_info.waiters.items.len > 0) {
                            lock_info.holder = lock_info.waiters.orderedRemove(0);
                        } else {
                            lock_info.holder = null;
                        }
                    }
                }
            }
        }
    };

    pub fn init(allocator: Allocator, node_id: []const u8, resource_manager: *ResourceManager) ParticipantNode {
        return .{
            .allocator = allocator,
            .node_id = node_id,
            .transactions = std.StringHashMap(LocalTransaction).init(allocator),
            .resource_manager = resource_manager,
            .storage = null,
        };
    }

    /// Initialize with storage interface for actual data persistence
    pub fn initWithStorage(allocator: Allocator, node_id: []const u8, resource_manager: *ResourceManager, storage: StorageInterface) ParticipantNode {
        return .{
            .allocator = allocator,
            .node_id = node_id,
            .transactions = std.StringHashMap(LocalTransaction).init(allocator),
            .resource_manager = resource_manager,
            .storage = storage,
        };
    }

    /// Set the storage interface after initialization
    pub fn setStorage(self: *ParticipantNode, storage: StorageInterface) void {
        self.storage = storage;
    }

    pub fn deinit(self: *ParticipantNode) void {
        var it = self.transactions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.operations.deinit();
            entry.value_ptr.undo_log.deinit();
            entry.value_ptr.redo_log.deinit();
            entry.value_ptr.locks.deinit();
        }
        self.transactions.deinit();
    }

    pub fn handlePrepare(self: *ParticipantNode, transaction_id: []const u8, operations: []Operation) !PrepareResponse {
        // Create local transaction
        var local_txn = LocalTransaction{
            .id = transaction_id,
            .coordinator_id = "", // Will be set by coordinator
            .state = .preparing,
            .operations = std.ArrayList(Operation){},
            .undo_log = std.ArrayList(UndoEntry){},
            .redo_log = std.ArrayList(RedoEntry){},
            .locks = std.ArrayList(Lock){},
        };

        // Try to acquire locks for all operations
        for (operations) |op| {
            const resource_id = switch (op) {
                .create_node, .update_node, .delete_node => |node_op| node_op.node_id,
                .create_edge, .update_edge, .delete_edge => |edge_op| edge_op.edge_id,
            };

            const lock_acquired = try self.resource_manager.acquireLock(
                resource_id,
                transaction_id,
                .exclusive,
            );

            if (!lock_acquired) {
                // Cannot acquire lock, vote abort
                local_txn.state = .aborting;
                try self.transactions.put(transaction_id, local_txn);
                return .vote_abort;
            }

            try local_txn.locks.append(.{
                .resource_id = resource_id,
                .lock_type = .exclusive,
                .acquired_at = std.time.timestamp(),
            });

            try local_txn.operations.append(op);
        }

        // All locks acquired, prepare transaction
        local_txn.state = .prepared;
        try self.transactions.put(transaction_id, local_txn);

        return .vote_commit;
    }

    // CANARY: REQ=REQ-2PC-COMMIT-001; FEATURE="2PC Commit Handler"; ASPECT=StorageApplication; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-10
    pub fn handleCommit(self: *ParticipantNode, transaction_id: []const u8) !void {
        const local_txn = self.transactions.getPtr(transaction_id) orelse return error.TransactionNotFound;

        if (local_txn.state != .prepared) {
            return error.InvalidState;
        }

        local_txn.state = .committing;

        // Apply operations to storage
        if (self.storage) |storage| {
            for (local_txn.operations.items) |op| {
                try self.applyOperation(storage, op);
            }
        }

        // Release locks
        for (local_txn.locks.items) |lock| {
            try self.resource_manager.releaseLock(lock.resource_id, transaction_id);
        }

        local_txn.state = .committed;
    }

    // CANARY: REQ=REQ-2PC-ABORT-001; FEATURE="2PC Abort Handler"; ASPECT=UndoApplication; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-10
    pub fn handleAbort(self: *ParticipantNode, transaction_id: []const u8) !void {
        const local_txn = self.transactions.getPtr(transaction_id) orelse return error.TransactionNotFound;

        local_txn.state = .aborting;

        // Apply undo log to reverse any partially applied operations
        if (self.storage) |storage| {
            while (local_txn.undo_log.popOrNull()) |undo_entry| {
                try self.applyUndoOperation(storage, undo_entry);
            }
        }

        // Release locks
        for (local_txn.locks.items) |lock| {
            try self.resource_manager.releaseLock(lock.resource_id, transaction_id);
        }

        local_txn.state = .aborted;
    }

    /// Apply a single operation to storage
    fn applyOperation(self: *ParticipantNode, storage: StorageInterface, op: Operation) !void {
        _ = self;
        switch (op) {
            .create_node => |node_op| {
                try storage.createNode(node_op.node_id, node_op.label, node_op.properties);
            },
            .update_node => |node_op| {
                try storage.updateNode(node_op.node_id, node_op.properties);
            },
            .delete_node => |node_op| {
                try storage.deleteNode(node_op.node_id);
            },
            .create_edge => |edge_op| {
                try storage.createEdge(edge_op.edge_id, edge_op.source_id, edge_op.target_id, edge_op.edge_type, edge_op.properties);
            },
            .update_edge => |edge_op| {
                try storage.updateEdge(edge_op.edge_id, edge_op.properties);
            },
            .delete_edge => |edge_op| {
                try storage.deleteEdge(edge_op.edge_id);
            },
        }
    }

    /// Apply an undo operation to reverse a previously applied operation
    fn applyUndoOperation(self: *ParticipantNode, storage: StorageInterface, undo_entry: UndoEntry) !void {
        _ = self;
        // Undo operations are the inverse of the original operation
        switch (undo_entry.operation) {
            .create_node => |node_op| {
                // Undo create = delete
                try storage.deleteNode(node_op.node_id);
            },
            .update_node => |node_op| {
                // Undo update = restore old value
                try storage.updateNode(node_op.node_id, undo_entry.old_value);
            },
            .delete_node => |node_op| {
                // Undo delete = recreate with old properties
                try storage.createNode(node_op.node_id, node_op.label, undo_entry.old_value);
            },
            .create_edge => |edge_op| {
                // Undo create = delete
                try storage.deleteEdge(edge_op.edge_id);
            },
            .update_edge => |edge_op| {
                // Undo update = restore old value
                try storage.updateEdge(edge_op.edge_id, undo_entry.old_value);
            },
            .delete_edge => |edge_op| {
                // Undo delete = recreate with old properties
                try storage.createEdge(edge_op.edge_id, edge_op.source_id, edge_op.target_id, edge_op.edge_type, undo_entry.old_value);
            },
        }
    }
};
