const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;
const protobuf = @import("protobuf");
const dist_schema = @import("distributed_schema");
const graph_store = @import("../graph_store.zig");
const value_convert = @import("value_convert.zig");

const logging = @import("logging");
const log = logging.scoped("twophase");
const Attr = logging.Attr;

const twophase = @import("twophase.zig");
pub const TransactionState = twophase.TransactionState;
pub const TwoPhaseMessage = twophase.TwoPhaseMessage;
pub const PrepareResponse = twophase.PrepareResponse;
pub const Operation = twophase.Operation;

/// Two-Phase Commit Participant
// CANARY: REQ=REQ-2PC-PARTICIPANT-001; FEATURE="2PC Participant Node"; ASPECT=StorageOps; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
pub const ParticipantNode = struct {
    allocator: Allocator,
    node_id: []const u8,
    transactions: std.StringHashMap(LocalTransaction),
    resource_manager: *ResourceManager,
    store: ?*graph_store.GraphStore,

    pub const LocalTransaction = struct {
        id: []const u8,
        coordinator_id: []const u8,
        state: TransactionState,
        write_set: []u8,
        locks: std.ArrayListUnmanaged(Lock),

        pub fn deinit(self: *LocalTransaction, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.coordinator_id);
            allocator.free(self.write_set);
            self.locks.deinit(allocator);
        }
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
        };

        pub fn init(allocator: Allocator) ResourceManager {
            return .{ .locks = std.AutoHashMap(u64, LockInfo).init(allocator) };
        }

        pub fn deinit(self: *ResourceManager) void {
            self.locks.deinit();
        }

        pub fn acquireLock(self: *ResourceManager, resource_id: u64, transaction_id: []const u8, lock_type: LockType) !bool {
            const result = try self.locks.getOrPut(resource_id);
            if (!result.found_existing) {
                result.value_ptr.* = .{
                    .holder = transaction_id,
                    .lock_type = lock_type,
                };
                return true;
            }

            // Check compatibility
            if (result.value_ptr.holder == null) {
                result.value_ptr.holder = transaction_id;
                result.value_ptr.lock_type = lock_type;
                return true;
            }
            if (result.value_ptr.holder) |holder| {
                if (std.mem.eql(u8, holder, transaction_id)) {
                    return true;
                }
            }

            return false;
        }

        pub fn releaseLock(self: *ResourceManager, resource_id: u64, transaction_id: []const u8) !void {
            if (self.locks.getPtr(resource_id)) |lock_info| {
                if (lock_info.holder) |holder| {
                    if (std.mem.eql(u8, holder, transaction_id)) {
                        lock_info.holder = null;
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
            .store = null,
        };
    }

    /// Initialize with GraphStore for actual data persistence
    pub fn initWithStore(allocator: Allocator, node_id: []const u8, resource_manager: *ResourceManager, store: *graph_store.GraphStore) ParticipantNode {
        return .{
            .allocator = allocator,
            .node_id = node_id,
            .transactions = std.StringHashMap(LocalTransaction).init(allocator),
            .resource_manager = resource_manager,
            .store = store,
        };
    }

    /// Set the GraphStore after initialization
    pub fn setStore(self: *ParticipantNode, store: *graph_store.GraphStore) void {
        self.store = store;
    }

    pub fn deinit(self: *ParticipantNode) void {
        var it = self.transactions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.transactions.deinit();
    }

    pub fn handlePrepare(self: *ParticipantNode, msg: *const TwoPhaseMessage, payload: []const u8) !PrepareResponse {
        if (self.transactions.getPtr(msg.transaction_id)) |existing| {
            return if (existing.state == .prepared) .VOTE_COMMIT else .VOTE_ABORT;
        }

        // Create local transaction
        var local_txn = LocalTransaction{
            .id = try self.allocator.dupe(u8, msg.transaction_id),
            .coordinator_id = try self.allocator.dupe(u8, msg.coordinator_id),
            .state = .preparing,
            .write_set = try self.allocator.dupe(u8, payload),
            .locks = std.ArrayList(Lock).empty,
        };
        errdefer local_txn.deinit(self.allocator);

        // Try to acquire locks for all operations
        for (msg.operations.items) |op| {
            const resource_id = switch (op) {
                .node_op => |node_op| node_op.node_id,
                .edge_op => |edge_op| edge_op.edge_id,
            };

            const lock_acquired = try self.resource_manager.acquireLock(
                resource_id,
                local_txn.id,
                .exclusive,
            );

            if (!lock_acquired) {
                // Cannot acquire lock, vote abort
                for (local_txn.locks.items) |lock| {
                    self.resource_manager.releaseLock(lock.resource_id, local_txn.id) catch {};
                }
                return .VOTE_ABORT;
            }

            try local_txn.locks.append(self.allocator, .{
                .resource_id = resource_id,
                .lock_type = .exclusive,
                .acquired_at = compat_timestamp(),
            });
        }

        // All locks acquired, prepare transaction
        local_txn.state = .prepared;
        try self.transactions.put(local_txn.id, local_txn);

        return .VOTE_COMMIT;
    }

    // CANARY: REQ=REQ-2PC-COMMIT-001; FEATURE="2PC Commit Handler"; ASPECT=StorageApplication; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn handleCommit(self: *ParticipantNode, transaction_id: []const u8) !void {
        const removed = self.transactions.fetchRemove(transaction_id) orelse return error.TransactionNotFound;
        var local_txn = removed.value;
        defer local_txn.deinit(self.allocator);

        if (local_txn.state != .prepared) {
            return error.InvalidState;
        }

        local_txn.state = .committing;
        defer {
            for (local_txn.locks.items) |lock| {
                self.resource_manager.releaseLock(lock.resource_id, local_txn.id) catch {};
            }
        }

        // Apply operations to GraphStore
        const store = self.store orelse return error.NoStorage;
        var reader: std.Io.Reader = .fixed(local_txn.write_set);
        var msg = protobuf.decode(TwoPhaseMessage, &reader, self.allocator) catch |err| {
            log.err("2PC participant failed to decode write set", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        defer msg.deinit(self.allocator);

        for (msg.operations.items) |op| {
            try self.applyOperation(store, op);
        }

        local_txn.state = .committed;
    }

    // CANARY: REQ=REQ-2PC-ABORT-001; FEATURE="2PC Abort Handler"; ASPECT=UndoApplication; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn handleAbort(self: *ParticipantNode, transaction_id: []const u8) !void {
        const removed = self.transactions.fetchRemove(transaction_id) orelse return error.TransactionNotFound;
        var local_txn = removed.value;
        defer local_txn.deinit(self.allocator);

        local_txn.state = .aborting;
        for (local_txn.locks.items) |lock| {
            self.resource_manager.releaseLock(lock.resource_id, local_txn.id) catch {};
        }
        local_txn.state = .aborted;
    }

    /// Apply a single operation to storage
    fn applyOperation(self: *ParticipantNode, store: *graph_store.GraphStore, op: Operation) !void {
        switch (op) {
            .node_op => |node_op| {
                const graph_name = if (node_op.graph_name.len > 0) node_op.graph_name else graph_store.DEFAULT_GRAPH_NAME;
                const labels = if (node_op.label.len > 0) &[_][]const u8{node_op.label} else &[_][]const u8{};
                switch (node_op.op_type) {
                    .CREATE => {
                        if (store.getNodePtr(node_op.node_id) == null) {
                            store.createNodeWithId(node_op.node_id, labels, graph_name) catch |err| switch (err) {
                                error.NodeAlreadyExists => {},
                                else => return err,
                            };
                        } else if (node_op.label.len > 0) {
                            store.addNodeLabel(node_op.node_id, node_op.label) catch {};
                        }
                        try value_convert.applyMapEntriesToNode(store, self.allocator, node_op.node_id, node_op.properties.items);
                    },
                    .UPDATE => {
                        if (store.getNodePtr(node_op.node_id) != null) {
                            try value_convert.applyMapEntriesToNode(store, self.allocator, node_op.node_id, node_op.properties.items);
                        }
                    },
                    .DELETE => {
                        // SONNY-6302: a failed delete fails the commit, as a
                        // failed CREATE or UPDATE does (the void form only
                        // logged it and the commit reported success).
                        try store.deleteNodeChecked(node_op.node_id);
                    },
                    else => {},
                }
            },
            .edge_op => |edge_op| {
                const graph_name = if (edge_op.graph_name.len > 0) edge_op.graph_name else graph_store.DEFAULT_GRAPH_NAME;
                switch (edge_op.op_type) {
                    .CREATE => {
                        if (store.getEdgePtr(edge_op.edge_id) == null) {
                            store.createEdgeWithId(edge_op.edge_id, edge_op.source_id, edge_op.target_id, edge_op.edge_type, graph_name) catch |err| switch (err) {
                                error.EdgeAlreadyExists => {},
                                else => return err,
                            };
                        }
                        try value_convert.applyMapEntriesToEdge(store, self.allocator, edge_op.edge_id, edge_op.properties.items);
                    },
                    .UPDATE => {
                        if (store.getEdgePtr(edge_op.edge_id) != null) {
                            try value_convert.applyMapEntriesToEdge(store, self.allocator, edge_op.edge_id, edge_op.properties.items);
                        }
                    },
                    .DELETE => {
                        try store.deleteEdgeChecked(edge_op.edge_id); // SONNY-6302
                    },
                    else => {},
                }
            },
        }
    }
};

// CANARY: REQ=REQ-2PC-PARTICIPANT-TEST-001; FEATURE="2PC Participant Unit Tests"; ASPECT=TestCoverage; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
test "ResourceManager.acquireLock: first acquire succeeds" {
    const allocator = std.testing.allocator;
    var rm = ParticipantNode.ResourceManager.init(allocator);
    defer rm.deinit();

    const acquired = try rm.acquireLock(42, "txn-1", .exclusive);
    try std.testing.expect(acquired);
}

test "ResourceManager.acquireLock: same txn re-acquire is idempotent, different txn conflicts" {
    const allocator = std.testing.allocator;
    var rm = ParticipantNode.ResourceManager.init(allocator);
    defer rm.deinit();

    // First acquire by txn-1
    const first = try rm.acquireLock(10, "txn-1", .exclusive);
    try std.testing.expect(first);

    // Same txn re-acquires — should succeed (idempotent)
    const same = try rm.acquireLock(10, "txn-1", .exclusive);
    try std.testing.expect(same);

    // Different txn conflicts — should fail
    const conflict = try rm.acquireLock(10, "txn-2", .exclusive);
    try std.testing.expect(!conflict);
}

test "ResourceManager.releaseLock: after release, different txn can acquire" {
    const allocator = std.testing.allocator;
    var rm = ParticipantNode.ResourceManager.init(allocator);
    defer rm.deinit();

    // txn-1 acquires resource 99
    const acquired = try rm.acquireLock(99, "txn-1", .exclusive);
    try std.testing.expect(acquired);

    // txn-2 cannot acquire while txn-1 holds it
    const blocked = try rm.acquireLock(99, "txn-2", .exclusive);
    try std.testing.expect(!blocked);

    // txn-1 releases
    try rm.releaseLock(99, "txn-1");

    // txn-2 can now acquire
    const reacquired = try rm.acquireLock(99, "txn-2", .exclusive);
    try std.testing.expect(reacquired);
}

test "ParticipantNode.handleAbort: aborts prepared transaction, map becomes empty" {
    const allocator = std.testing.allocator;
    var rm = ParticipantNode.ResourceManager.init(allocator);
    defer rm.deinit();

    var node = ParticipantNode.init(allocator, "node-1", &rm);
    defer node.deinit();

    // Manually insert a prepared transaction (heap-allocate id so handleAbort can free it)
    const txn_id = try allocator.dupe(u8, "txn-abort-test");
    const coordinator_id = try allocator.dupe(u8, "coord-1");
    const write_set = try allocator.dupe(u8, "");
    const local_txn = ParticipantNode.LocalTransaction{
        .id = txn_id,
        .coordinator_id = coordinator_id,
        .state = .prepared,
        .write_set = write_set,
        .locks = std.ArrayList(ParticipantNode.Lock).empty,
    };
    try node.transactions.put(txn_id, local_txn);

    try std.testing.expect(node.transactions.count() == 1);

    // Abort the transaction
    try node.handleAbort(txn_id);

    // Transaction should be removed
    try std.testing.expect(node.transactions.count() == 0);
}

test "ParticipantNode.handleAbort: unknown transaction returns error.TransactionNotFound" {
    const allocator = std.testing.allocator;
    var rm = ParticipantNode.ResourceManager.init(allocator);
    defer rm.deinit();

    var node = ParticipantNode.init(allocator, "node-1", &rm);
    defer node.deinit();

    const result = node.handleAbort("nonexistent-txn");
    try std.testing.expectError(error.TransactionNotFound, result);
}
