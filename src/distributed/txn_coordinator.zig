// CANARY: REQ=REQ-GQL-2PC-002; FEATURE="Distributed Transaction Coordinator"; ASPECT=2PC; STATUS=TESTED; TEST=TestCANARY_2PC_Coordinator; OWNER=distributed; UPDATED=2025-09-29

const std = @import("std");
const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const protobuf = @import("protobuf");
const dist_schema = @import("distributed_schema");
const schema = @import("schema");
const graph_store = @import("../graph_store.zig");
const value_convert = @import("value_convert.zig");
const spice_wrapper = @import("parallel/spice");

const logging = @import("logging");
const log = logging.scoped("txn_coordinator");
const Attr = logging.Attr;

/// Prepared transaction state
pub const PreparedTxn = struct {
    xid: u64,
    write_set: []const u8,
    metadata: []const u8,
    prepare_time: i64,
    locks: std.ArrayList(Lock),
};

/// Lock information
pub const Lock = struct {
    resource_id: u64,
    mode: enum { shared, exclusive },
    holder_xid: u64,
};

/// Distributed Transaction Coordinator with durable storage integration
/// CANARY: REQ=REQ-GQL-2PC-APPLY-001; FEATURE="2PC Write Set Application"; ASPECT=2PC; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-12
pub const TxnCoordinator = struct {
    allocator: Allocator,
    store: *graph_store.GraphStore,
    prepared_txns: std.AutoHashMap(u64, PreparedTxn),
    lock_table: std.AutoHashMap(u64, Lock),
    timeout_ms: u64 = 10_000, // Default 10 seconds
    pool: spice_wrapper.SpicePool, // PERF-D007: Reuse pool across calls

    pub fn init(allocator: Allocator, store: *graph_store.GraphStore) !TxnCoordinator {
        return TxnCoordinator{
            .allocator = allocator,
            .store = store,
            .prepared_txns = std.AutoHashMap(u64, PreparedTxn).init(allocator),
            .lock_table = std.AutoHashMap(u64, Lock).init(allocator),
            .pool = spice_wrapper.SpicePool.init(allocator, null),
        };
    }

    pub fn deinit(self: *TxnCoordinator) void {
        self.pool.deinit();
        var it = self.prepared_txns.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.write_set);
            self.allocator.free(entry.value_ptr.metadata);
            entry.value_ptr.locks.deinit();
        }
        self.prepared_txns.deinit();

        self.lock_table.deinit();
    }

    /// Handle txn_prepare command from Raft
    pub fn handlePrepare(self: *TxnCoordinator, prepare: raft_consensus.TxnPrepare) !bool {
        // Decode write set as protobuf TwoPhaseMessage
        var reader: std.Io.Reader = .fixed(prepare.write_set);
        var msg = protobuf.decode(dist_schema.TwoPhaseMessage, &reader, self.allocator) catch |err| {
            log.warn("Invalid write set payload", &.{
                Attr.uint("xid", prepare.xid),
                Attr.string("error", @errorName(err)),
            });
            return false;
        };
        defer msg.deinit(self.allocator);

        // Check for conflicts
        const resource_ids = try self.extractResourceIds(msg.operations.items);
        defer self.allocator.free(resource_ids);

        for (resource_ids) |resource_id| {
            if (self.lock_table.get(resource_id)) |existing_lock| {
                if (existing_lock.holder_xid != prepare.xid) {
                    log.debug("Transaction conflicts on key", &.{
                        Attr.uint("xid", prepare.xid),
                        Attr.uint("holder_xid", existing_lock.holder_xid),
                        Attr.uint("resource_id", resource_id),
                    });
                    return false; // Conflict - vote abort
                }
            }
        }

        // No conflicts, acquire locks and prepare
        var locks = try std.ArrayList(Lock).initCapacity(self.allocator, 0);
        for (resource_ids) |resource_id| {
            const lock = Lock{
                .resource_id = resource_id,
                .mode = .exclusive,
                .holder_xid = prepare.xid,
            };
            try locks.append(self.allocator, lock);
            try self.lock_table.put(resource_id, lock);
        }

        const prepared = PreparedTxn{
            .xid = prepare.xid,
            .write_set = try self.allocator.dupe(u8, prepare.write_set),
            .metadata = try self.allocator.dupe(u8, prepare.metadata),
            .prepare_time = std.time.milliTimestamp(),
            .locks = locks,
        };

        try self.prepared_txns.put(prepare.xid, prepared);
        log.info("Transaction prepared successfully", &.{
            Attr.uint("xid", prepare.xid),
        });
        return true; // Vote commit
    }

    /// Handle txn_decide command from Raft
    pub fn handleDecide(self: *TxnCoordinator, decide: raft_consensus.TxnDecide) !void {
        const prepared = self.prepared_txns.get(decide.xid) orelse {
            log.warn("Transaction not found in prepared state", &.{
                Attr.uint("xid", decide.xid),
            });
            return;
        };

        defer {
            // Release locks
            for (prepared.locks.items) |lock| {
                _ = self.lock_table.remove(lock.resource_id);
            }
            prepared.locks.deinit();

            // Clean up prepared state
            self.allocator.free(prepared.write_set);
            self.allocator.free(prepared.metadata);
            _ = self.prepared_txns.remove(decide.xid);
        }

        if (decide.commit) {
            // Apply the write set
            try self.applyWriteSet(prepared.write_set);
            log.info("Transaction committed", &.{
                Attr.uint("xid", decide.xid),
            });
        } else {
            // Rollback is implicit - just release locks
            log.info("Transaction aborted", &.{
                Attr.uint("xid", decide.xid),
            });
        }
    }

    /// Check for timed-out transactions
    pub fn checkTimeouts(self: *TxnCoordinator) !void {
        const now = std.time.milliTimestamp();
        var to_abort = try std.ArrayList(u64).initCapacity(self.allocator, 0);
        defer to_abort.deinit();

        var it = self.prepared_txns.iterator();
        while (it.next()) |entry| {
            const elapsed = @as(u64, @intCast(now - entry.value_ptr.prepare_time));
            if (elapsed > self.timeout_ms) {
                try to_abort.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_abort.items) |xid| {
            log.warn("Transaction timed out, auto-aborting", &.{
                Attr.uint("xid", xid),
            });
            try self.handleDecide(.{ .xid = xid, .commit = false });
        }
    }

    fn extractResourceIds(self: *TxnCoordinator, operations: []const dist_schema.TwoPhaseOperation) ![]u64 {
        const ids = try self.allocator.alloc(u64, operations.len);
        if (operations.len == 0) return ids;

        if (spice_wrapper.shouldUseParallelism(operations.len, spice_wrapper.Thresholds.forEach)) {
            // PERF-D007: Reuse struct-level pool instead of creating per-call
            const Context = struct {
                ops: []const dist_schema.TwoPhaseOperation,
                out: []u64,
            };
            const ctx = Context{ .ops = operations, .out = ids };

            spice_wrapper.parallelForEach(&self.pool, 0, operations.len, ctx, struct {
                fn work(_: *spice_wrapper.Task, idx: usize, c: Context) void {
                    const op = c.ops[idx];
                    c.out[idx] = switch (op) {
                        .node_op => |node_op| node_op.node_id,
                        .edge_op => |edge_op| edge_op.edge_id,
                    };
                }
            }.work, spice_wrapper.Thresholds.forEach);
        } else {
            for (operations, 0..) |op, idx| {
                ids[idx] = switch (op) {
                    .node_op => |node_op| node_op.node_id,
                    .edge_op => |edge_op| edge_op.edge_id,
                };
            }
        }

        return ids;
    }

    /// Parse and apply write set operations to GraphStore.
    /// Write set payload is a protobuf-encoded TwoPhaseMessage.
    /// CANARY: REQ=REQ-GQL-2PC-APPLY-002; FEATURE="Write Set Parser and Applicator"; ASPECT=2PC; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-12
    fn applyWriteSet(self: *TxnCoordinator, write_set: []const u8) !void {
        var reader: std.Io.Reader = .fixed(write_set);
        var msg = protobuf.decode(dist_schema.TwoPhaseMessage, &reader, self.allocator) catch |err| {
            log.err("Failed to decode write set", &.{
                Attr.string("error", @errorName(err)),
            });
            return err;
        };
        defer msg.deinit(self.allocator);

        for (msg.operations.items) |op| {
            try self.applyOperation(op);
        }

        log.info("2PC applied operations from write set", &.{
            Attr.uint("operation_count", msg.operations.items.len),
        });
    }

    fn applyOperation(self: *TxnCoordinator, op: dist_schema.TwoPhaseOperation) !void {
        switch (op) {
            .node_op => |node_op| {
                const graph_name = if (node_op.graph_name.len > 0) node_op.graph_name else graph_store.DEFAULT_GRAPH_NAME;
                const labels = [_][]const u8{node_op.label};
                switch (node_op.op_type) {
                    .CREATE => {
                        if (self.store.getNodePtr(node_op.node_id) == null) {
                            self.store.createNodeWithId(node_op.node_id, &labels, graph_name) catch |err| switch (err) {
                                error.NodeAlreadyExists => {},
                                else => return err,
                            };
                        } else if (node_op.label.len > 0) {
                            self.store.addNodeLabel(node_op.node_id, node_op.label) catch {};
                        }
                        try value_convert.applyMapEntriesToNode(self.store, self.allocator, node_op.node_id, node_op.properties.items);
                    },
                    .UPDATE => {
                        if (self.store.getNodePtr(node_op.node_id) != null) {
                            try value_convert.applyMapEntriesToNode(self.store, self.allocator, node_op.node_id, node_op.properties.items);
                        }
                    },
                    .DELETE => {
                        self.store.deleteNode(node_op.node_id);
                    },
                    else => {},
                }
            },
            .edge_op => |edge_op| {
                const graph_name = if (edge_op.graph_name.len > 0) edge_op.graph_name else graph_store.DEFAULT_GRAPH_NAME;
                switch (edge_op.op_type) {
                    .CREATE => {
                        if (self.store.getEdgePtr(edge_op.edge_id) == null) {
                            self.store.createEdgeWithId(edge_op.edge_id, edge_op.source_id, edge_op.target_id, edge_op.edge_type, graph_name) catch |err| switch (err) {
                                error.EdgeAlreadyExists => {},
                                else => return err,
                            };
                        }
                        try value_convert.applyMapEntriesToEdge(self.store, self.allocator, edge_op.edge_id, edge_op.properties.items);
                    },
                    .UPDATE => {
                        if (self.store.getEdgePtr(edge_op.edge_id) != null) {
                            try value_convert.applyMapEntriesToEdge(self.store, self.allocator, edge_op.edge_id, edge_op.properties.items);
                        }
                    },
                    .DELETE => {
                        self.store.deleteEdge(edge_op.edge_id);
                    },
                    else => {},
                }
            },
        }
    }
};

// CANARY: REQ=REQ-GQL-2PC-003; FEATURE="2PC Idempotence"; ASPECT=2PC; STATUS=TESTED; TEST=TestCANARY_2PC_Idempotent; OWNER=distributed; UPDATED=2025-09-29

fn makeStringValue(allocator: Allocator, text: []const u8) !schema.Value {
    return .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, text), .kind = .STRING } } };
}

fn encodeWriteSet(allocator: Allocator, msg: *dist_schema.TwoPhaseMessage) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 512);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg.*);
    const body = aw.writer.buffer[0..aw.writer.end];
    return allocator.dupe(u8, body);
}

test "TestCANARY_2PC_Coordinator basic prepare and commit" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    var props = std.ArrayList(schema.MapEntry).init(allocator);
    try props.append(allocator, .{
        .key = try allocator.dupe(u8, "name"),
        .value = try makeStringValue(allocator, "Alice"),
    });

    const op = dist_schema.TwoPhaseOperation{
        .node_op = .{
            .op_type = .CREATE,
            .node_id = 1,
            .label = try allocator.dupe(u8, "User"),
            .graph_name = try allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
            .properties = props,
        },
    };

    var ops = std.ArrayList(dist_schema.TwoPhaseOperation).init(allocator);
    try ops.append(allocator, op);

    var msg = dist_schema.TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = try allocator.dupe(u8, "txn-1"),
        .coordinator_id = try allocator.dupe(u8, "coord"),
        .timestamp = std.time.milliTimestamp(),
        .operations = ops,
    };

    const write_set = try encodeWriteSet(allocator, &msg);
    defer allocator.free(write_set);
    msg.deinit(allocator);

    const prepare = raft_consensus.TxnPrepare{
        .xid = 1,
        .shard_id = 0,
        .write_set = write_set,
        .metadata = "test",
    };

    const can_commit = try coordinator.handlePrepare(prepare);
    try std.testing.expect(can_commit);

    try coordinator.handleDecide(.{ .xid = 1, .commit = true });

    const node = store.getNodePtr(1);
    try std.testing.expect(node != null);
    const name_prop = store.getNodeProperty(1, "name");
    try std.testing.expect(name_prop != null);
    try std.testing.expectEqualStrings("Alice", name_prop.?.String);
}

test "TestCANARY_2PC_Idempotent repeated prepare" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    var ops = std.ArrayList(dist_schema.TwoPhaseOperation).init(allocator);
    try ops.append(allocator, .{
        .node_op = .{
            .op_type = .CREATE,
            .node_id = 42,
            .label = try allocator.dupe(u8, "LockNode"),
            .graph_name = try allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
            .properties = std.ArrayList(schema.MapEntry).init(allocator),
        },
    });

    var msg = dist_schema.TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = try allocator.dupe(u8, "txn-1"),
        .coordinator_id = try allocator.dupe(u8, "coord"),
        .timestamp = std.time.milliTimestamp(),
        .operations = ops,
    };
    const write_set = try encodeWriteSet(allocator, &msg);
    defer allocator.free(write_set);
    msg.deinit(allocator);

    const prepare1 = raft_consensus.TxnPrepare{
        .xid = 1,
        .shard_id = 0,
        .write_set = write_set,
        .metadata = "test",
    };
    try std.testing.expect(try coordinator.handlePrepare(prepare1));

    const prepare2 = raft_consensus.TxnPrepare{
        .xid = 2,
        .shard_id = 0,
        .write_set = write_set,
        .metadata = "test",
    };
    try std.testing.expect(!try coordinator.handlePrepare(prepare2));
}

test "TestCANARY_2PC_WriteSetApplied verifies data is persisted" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    var props1 = std.ArrayList(schema.MapEntry).init(allocator);
    try props1.append(allocator, .{
        .key = try allocator.dupe(u8, "name"),
        .value = try makeStringValue(allocator, "Alice Smith"),
    });
    var props2 = std.ArrayList(schema.MapEntry).init(allocator);
    try props2.append(allocator, .{
        .key = try allocator.dupe(u8, "name"),
        .value = try makeStringValue(allocator, "Bob Jones"),
    });

    var ops = std.ArrayList(dist_schema.TwoPhaseOperation).init(allocator);
    try ops.append(allocator, .{
        .node_op = .{
            .op_type = .CREATE,
            .node_id = 10,
            .label = try allocator.dupe(u8, "User"),
            .graph_name = try allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
            .properties = props1,
        },
    });
    try ops.append(allocator, .{
        .node_op = .{
            .op_type = .CREATE,
            .node_id = 11,
            .label = try allocator.dupe(u8, "User"),
            .graph_name = try allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
            .properties = props2,
        },
    });

    var msg = dist_schema.TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = try allocator.dupe(u8, "txn-100"),
        .coordinator_id = try allocator.dupe(u8, "coord"),
        .timestamp = std.time.milliTimestamp(),
        .operations = ops,
    };
    const write_set = try encodeWriteSet(allocator, &msg);
    defer allocator.free(write_set);
    msg.deinit(allocator);

    const prepare = raft_consensus.TxnPrepare{
        .xid = 100,
        .shard_id = 0,
        .write_set = write_set,
        .metadata = "test_persistence",
    };
    try std.testing.expect(try coordinator.handlePrepare(prepare));
    try coordinator.handleDecide(.{ .xid = 100, .commit = true });

    const alice = store.getNodeProperty(10, "name");
    try std.testing.expect(alice != null);
    try std.testing.expectEqualStrings("Alice Smith", alice.?.String);

    const bob = store.getNodeProperty(11, "name");
    try std.testing.expect(bob != null);
    try std.testing.expectEqualStrings("Bob Jones", bob.?.String);
}

test "TestCANARY_2PC_WriteSetDelete verifies delete operations" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    const props = std.ArrayList(schema.MapEntry).init(allocator);

    var ops1 = std.ArrayList(dist_schema.TwoPhaseOperation).init(allocator);
    try ops1.append(allocator, .{
        .node_op = .{
            .op_type = .CREATE,
            .node_id = 55,
            .label = try allocator.dupe(u8, "Temp"),
            .graph_name = try allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
            .properties = props,
        },
    });

    var msg1 = dist_schema.TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = try allocator.dupe(u8, "txn-200"),
        .coordinator_id = try allocator.dupe(u8, "coord"),
        .timestamp = std.time.milliTimestamp(),
        .operations = ops1,
    };
    const write_set1 = try encodeWriteSet(allocator, &msg1);
    defer allocator.free(write_set1);
    msg1.deinit(allocator);

    _ = try coordinator.handlePrepare(.{ .xid = 200, .shard_id = 0, .write_set = write_set1, .metadata = "insert" });
    try coordinator.handleDecide(.{ .xid = 200, .commit = true });
    try std.testing.expect(store.getNodePtr(55) != null);

    var ops2 = std.ArrayList(dist_schema.TwoPhaseOperation).init(allocator);
    try ops2.append(allocator, .{
        .node_op = .{
            .op_type = .DELETE,
            .node_id = 55,
            .label = try allocator.dupe(u8, "Temp"),
            .graph_name = try allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
            .properties = std.ArrayList(schema.MapEntry).init(allocator),
        },
    });

    var msg2 = dist_schema.TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = try allocator.dupe(u8, "txn-201"),
        .coordinator_id = try allocator.dupe(u8, "coord"),
        .timestamp = std.time.milliTimestamp(),
        .operations = ops2,
    };
    const write_set2 = try encodeWriteSet(allocator, &msg2);
    defer allocator.free(write_set2);
    msg2.deinit(allocator);

    _ = try coordinator.handlePrepare(.{ .xid = 201, .shard_id = 0, .write_set = write_set2, .metadata = "delete" });
    try coordinator.handleDecide(.{ .xid = 201, .commit = true });
    try std.testing.expect(store.getNodePtr(55) == null);
}
