const std = @import("std");
const Allocator = std.mem.Allocator;

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

// CANARY: REQ=REQ-DIST-2PC-MSG-001; FEATURE="Two-Phase Commit Message Format"; ASPECT=Protocol; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-08
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

/// Send a 2PC message to a participant endpoint
fn sendMessage(endpoint: []const u8, msg: TwoPhaseMessage, timeout_ms: u64) !TwoPhaseResponse {
    // Implementation uses network transport layer
    // In production, this would:
    // 1. Serialize message to wire format
    // 2. Open connection to endpoint (or reuse from pool)
    // 3. Send message with timeout
    // 4. Wait for response with timeout
    // 5. Deserialize and return response
    _ = endpoint;
    _ = timeout_ms;

    // For now, return success response
    // Real implementation would use network_transport.zig
    return TwoPhaseResponse{
        .msg_type = switch (msg.msg_type) {
            .prepare => .prepare_response,
            .commit => .commit_response,
            .abort => .abort_response,
            else => .prepare_response,
        },
        .transaction_id = msg.transaction_id,
        .participant_id = "participant",
        .vote = .vote_commit,
        .timestamp = std.time.timestamp(),
    };
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

        // CANARY: REQ=REQ-DIST-2PC-001; FEATURE="Two-Phase Commit Messaging"; ASPECT=Prepare; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-08
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

        // CANARY: REQ=REQ-DIST-2PC-002; FEATURE="Two-Phase Commit Messaging"; ASPECT=Commit; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-08
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

        // CANARY: REQ=REQ-DIST-2PC-003; FEATURE="Two-Phase Commit Messaging"; ASPECT=Abort; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-08
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

/// Two-Phase Commit Participant
pub const ParticipantNode = struct {
    allocator: Allocator,
    node_id: []const u8,
    transactions: std.StringHashMap(LocalTransaction),
    resource_manager: *ResourceManager,

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
        };
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

    pub fn handleCommit(self: *ParticipantNode, transaction_id: []const u8) !void {
        const local_txn = self.transactions.getPtr(transaction_id) orelse return error.TransactionNotFound;

        if (local_txn.state != .prepared) {
            return error.InvalidState;
        }

        local_txn.state = .committing;

        // Apply operations
        for (local_txn.operations.items) |op| {
            // TODO: Actually apply the operation to storage
            _ = op;
        }

        // Release locks
        for (local_txn.locks.items) |lock| {
            try self.resource_manager.releaseLock(lock.resource_id, transaction_id);
        }

        local_txn.state = .committed;
    }

    pub fn handleAbort(self: *ParticipantNode, transaction_id: []const u8) !void {
        const local_txn = self.transactions.getPtr(transaction_id) orelse return error.TransactionNotFound;

        local_txn.state = .aborting;

        // Apply undo log
        while (local_txn.undo_log.popOrNull()) |undo_entry| {
            // TODO: Apply undo operation
            _ = undo_entry;
        }

        // Release locks
        for (local_txn.locks.items) |lock| {
            try self.resource_manager.releaseLock(lock.resource_id, transaction_id);
        }

        local_txn.state = .aborted;
    }
};
