// CANARY: REQ=REQ-GQL-2PC-002; FEATURE="Distributed Transaction Coordinator"; ASPECT=2PC; STATUS=TESTED; TEST=TestCANARY_2PC_Coordinator; OWNER=distributed; UPDATED=2025-09-29

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
const raft_consensus = @import("raft_consensus.zig");
const protobuf = @import("protobuf");
const dist_schema = @import("distributed_schema");
const schema = @import("schema");
const graph_store = @import("../graph_store.zig");
const value_convert = @import("value_convert.zig");
const parallel_wrapper = @import("parallel/thread_pool_parallel");

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
/// CANARY: REQ=REQ-GQL-2PC-APPLY-001; FEATURE="2PC Write Set Application"; ASPECT=2PC; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
pub const TxnCoordinator = struct {
    allocator: Allocator,
    store: *graph_store.GraphStore,
    prepared_txns: std.AutoHashMap(u64, PreparedTxn),
    lock_table: std.AutoHashMap(u64, Lock),
    timeout_ms: u64 = 10_000, // Default 10 seconds
    pool: parallel_wrapper.ParallelPool, // PERF-D007: Reuse pool across calls

    pub fn init(allocator: Allocator, store: *graph_store.GraphStore) !TxnCoordinator {
        return TxnCoordinator{
            .allocator = allocator,
            .store = store,
            .prepared_txns = std.AutoHashMap(u64, PreparedTxn).init(allocator),
            .lock_table = std.AutoHashMap(u64, Lock).init(allocator),
            .pool = parallel_wrapper.ParallelPool.init(allocator, null),
        };
    }

    pub fn deinit(self: *TxnCoordinator) void {
        self.pool.deinit();
        var it = self.prepared_txns.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.write_set);
            self.allocator.free(entry.value_ptr.metadata);
            entry.value_ptr.locks.deinit(self.allocator);
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
            .prepare_time = compat_milliTimestamp(),
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
            prepared.locks.deinit(self.allocator);

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
        const now = compat_milliTimestamp();
        var to_abort = try std.ArrayList(u64).initCapacity(self.allocator, 0);
        defer to_abort.deinit(self.allocator);

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

        if (parallel_wrapper.shouldUseParallelism(operations.len, parallel_wrapper.Thresholds.forEach)) {
            // PERF-D007: Reuse struct-level pool instead of creating per-call
            const Context = struct {
                ops: []const dist_schema.TwoPhaseOperation,
                out: []u64,
            };
            const ctx = Context{ .ops = operations, .out = ids };

            parallel_wrapper.parallelForEach(&self.pool, 0, operations.len, ctx, struct {
                fn work(_: *parallel_wrapper.Task, idx: usize, c: Context) void {
                    const op = c.ops[idx];
                    c.out[idx] = switch (op) {
                        .node_op => |node_op| node_op.node_id,
                        .edge_op => |edge_op| edge_op.edge_id,
                    };
                }
            }.work, parallel_wrapper.Thresholds.forEach);
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
    /// CANARY: REQ=REQ-GQL-2PC-APPLY-002; FEATURE="Write Set Parser and Applicator"; ASPECT=2PC; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
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

// ---------------------------------------------------------------------------
// 2PC inline tests MOVED OUT of this file (2026-06-10).
//
// The four `TestCANARY_2PC_*` tests + their `makeStringValue` / `encodeWriteSet`
// helpers used to live here as inline `test` blocks. They `protobuf.encode` a
// `distributed_schema.TwoPhaseMessage`, whose `operations` field is a repeated
// `TwoPhaseOperation` Zig `union` — and the pinned `protobuf` 0.1.3 rejects a
// union-as-submessage at COMPTIME (`protobuf.zig:713 @compileError "Invalid
// internal init type ... TwoPhaseOperation"`; `wire.zig:704 expected
// StructField found UnionField`).
//
// Because `src/graph_store.zig` transitively imports this file
// (graph_store -> fle_integration -> execution -> raft_consensus ->
// txn_coordinator), those inline tests were pulled into the
// `graph_store_unit_tests` test root and broke the sharded `zig build test`
// (shard carrying graph_store failed to COMPILE — see docs/KNOWN_TEST_ISSUES.md
// "Blocked: graph_store_unit_tests shard"). Production never reaches the
// union-encode path: the `distributed/txn_coordinator.TxnCoordinator` is only
// held as a `?*TxnCoordinator = null` field on raft_consensus and is never
// instantiated; the live 2PC path is `src/transactions/two_phase_commit.zig`.
//
// The tests now live in `tests/test_txn_coordinator_2pc.zig`, wired as the
// standalone `zig build test-txn-coordinator-2pc` step, where their
// union-encoding bodies are guarded behind a comptime blocker flag
// (`protobuf_union_submessage_supported`) so the file compiles and the suite
// self-skips until the protobuf dependency gains union-as-submessage support.
// ---------------------------------------------------------------------------
