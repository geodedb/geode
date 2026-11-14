// CANARY: REQ=REQ-GQL-2PC-002; FEATURE="Distributed Transaction Coordinator"; ASPECT=2PC; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11

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
const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const graph_store = @import("../graph_store.zig");
const PropertyValue = graph_store.PropertyValue;

const logging = @import("logging");
const log = logging.scoped("txn_coordinator");
const Attr = logging.Attr;

// ---------------------------------------------------------------------------
// Native 2PC write-set codec (GAP-0870)
//
// The original write-set payload was a protobuf-encoded
// `dist_schema.TwoPhaseMessage`, whose `operations` field is a repeated Zig
// `union` — and the pinned protobuf 0.1.3 rejects a union-as-submessage at
// COMPTIME on BOTH the encode path (`protobuf.zig:713 @compileError`) and the
// decode path (`wire.zig:704 expected StructField found UnionField`).  That
// made the entire 2PC apply path uncompilable the moment anything referenced
// it (see tests/test_txn_coordinator_2pc.zig and its
// `protobuf_union_submessage_supported` gate, which stays in place to track
// the protobuf wire format).
//
// GAP-0870 replaces the payload codec with a self-describing native binary
// format (magic "G2PC"), in the same style as cluster_replication.zig's
// GNC1/GNC2/GDEL/GMRG/GUPD payloads.  Encode AND decode work today, so the
// Raft `txn_prepare` / `txn_decide` commands have a real, testable apply
// path end-to-end.
// ---------------------------------------------------------------------------

pub const MAGIC_2PC = [4]u8{ 'G', '2', 'P', 'C' };

pub const CodecError = error{ UnsupportedPropertyType, CorruptPayload };

pub const Prop = struct { key: []const u8, value: PropertyValue };

pub const WriteOpType = enum(u8) { create = 1, update = 2, delete = 3 };

pub const NodeWriteOp = struct {
    op_type: WriteOpType,
    node_id: u64,
    label: []const u8 = "",
    graph: []const u8 = "",
    props: []const Prop = &.{},
};

pub const EdgeWriteOp = struct {
    op_type: WriteOpType,
    edge_id: u64,
    source_id: u64 = 0,
    target_id: u64 = 0,
    edge_type: []const u8 = "",
    graph: []const u8 = "",
    props: []const Prop = &.{},
};

pub const WriteSetOp = union(enum) {
    node_op: NodeWriteOp,
    edge_op: EdgeWriteOp,
};

/// True when `data` carries the native 2PC write-set magic.
pub fn isWriteSetPayload(data: []const u8) bool {
    return data.len >= MAGIC_2PC.len and std.mem.eql(u8, data[0..MAGIC_2PC.len], &MAGIC_2PC);
}

fn appendU16(list: *std.ArrayList(u8), a: Allocator, v: usize) !void {
    if (v > std.math.maxInt(u16)) return CodecError.CorruptPayload;
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, @intCast(v), .little);
    try list.appendSlice(a, &b);
}

fn appendU32(list: *std.ArrayList(u8), a: Allocator, v: usize) !void {
    if (v > std.math.maxInt(u32)) return CodecError.CorruptPayload;
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(v), .little);
    try list.appendSlice(a, &b);
}

fn appendU64(list: *std.ArrayList(u8), a: Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try list.appendSlice(a, &b);
}

fn appendStr16(list: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    try appendU16(list, a, s.len);
    try list.appendSlice(a, s);
}

fn appendProps(list: *std.ArrayList(u8), a: Allocator, props: []const Prop) !void {
    try appendU16(list, a, props.len);
    for (props) |p| {
        try appendStr16(list, a, p.key);
        switch (p.value) {
            .Null => try list.append(a, 0),
            .Int => |i| {
                try list.append(a, 1);
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, i, .little);
                try list.appendSlice(a, &b);
            },
            .Float => |f| {
                try list.append(a, 2);
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @bitCast(f), .little);
                try list.appendSlice(a, &b);
            },
            .Bool => |bo| {
                try list.append(a, 3);
                try list.append(a, if (bo) 1 else 0);
            },
            .String => |s| {
                try list.append(a, 4);
                try appendU32(list, a, s.len);
                try list.appendSlice(a, s);
            },
            else => return CodecError.UnsupportedPropertyType,
        }
    }
}

/// Serialize a 2PC write set into a self-describing G2PC payload.
/// Caller owns the returned slice.
pub fn serializeWriteSet(allocator: Allocator, ops: []const WriteSetOp) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &MAGIC_2PC);
    try appendU16(&list, allocator, ops.len);
    for (ops) |op| switch (op) {
        .node_op => |n| {
            try list.append(allocator, 0); // kind 0 = node
            try list.append(allocator, @intFromEnum(n.op_type));
            try appendU64(&list, allocator, n.node_id);
            try appendStr16(&list, allocator, n.label);
            try appendStr16(&list, allocator, n.graph);
            try appendProps(&list, allocator, n.props);
        },
        .edge_op => |e| {
            try list.append(allocator, 1); // kind 1 = edge
            try list.append(allocator, @intFromEnum(e.op_type));
            try appendU64(&list, allocator, e.edge_id);
            try appendU64(&list, allocator, e.source_id);
            try appendU64(&list, allocator, e.target_id);
            try appendStr16(&list, allocator, e.edge_type);
            try appendStr16(&list, allocator, e.graph);
            try appendProps(&list, allocator, e.props);
        },
    };

    return list.toOwnedSlice(allocator);
}

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn readU16(self: *Reader) !u16 {
        if (self.pos + 2 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn readU32(self: *Reader) !u32 {
        if (self.pos + 4 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn readI64(self: *Reader) !i64 {
        if (self.pos + 8 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn readU64(self: *Reader) !u64 {
        if (self.pos + 8 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn byte(self: *Reader) !u8 {
        if (self.pos + 1 > self.data.len) return CodecError.CorruptPayload;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn str16(self: *Reader) ![]const u8 {
        const n = try self.readU16();
        if (self.pos + n > self.data.len) return CodecError.CorruptPayload;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn str32(self: *Reader) ![]const u8 {
        const n = try self.readU32();
        if (self.pos + n > self.data.len) return CodecError.CorruptPayload;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

fn readProps(r: *Reader, allocator: Allocator) ![]Prop {
    const count = try r.readU16();
    const props = try allocator.alloc(Prop, count);
    errdefer allocator.free(props);
    for (props) |*p| {
        const key = try r.str16();
        const tag = try r.byte();
        const val: PropertyValue = switch (tag) {
            0 => .Null,
            1 => .{ .Int = try r.readI64() },
            2 => .{ .Float = @bitCast(try r.readU64()) },
            3 => .{ .Bool = (try r.byte()) != 0 },
            4 => .{ .String = try r.str32() },
            else => return CodecError.CorruptPayload,
        };
        p.* = .{ .key = key, .value = val };
    }
    return props;
}

fn readWriteOpType(r: *Reader) !WriteOpType {
    return switch (try r.byte()) {
        1 => .create,
        2 => .update,
        3 => .delete,
        else => CodecError.CorruptPayload,
    };
}

/// Decoded write set. String slices borrow from the payload buffer; the ops
/// and props arrays are owned and must be released via `deinit`.
pub const DecodedWriteSet = struct {
    ops: []WriteSetOp,

    pub fn deinit(self: *DecodedWriteSet, allocator: Allocator) void {
        for (self.ops) |op| switch (op) {
            .node_op => |n| if (n.props.len > 0) allocator.free(n.props),
            .edge_op => |e| if (e.props.len > 0) allocator.free(e.props),
        };
        allocator.free(self.ops);
    }
};

/// Decode a G2PC write-set payload. Strings borrow from `data`.
pub fn deserializeWriteSet(allocator: Allocator, data: []const u8) !DecodedWriteSet {
    if (!isWriteSetPayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC_2PC.len };

    const count = try r.readU16();
    var ops = std.ArrayList(WriteSetOp).empty;
    errdefer {
        for (ops.items) |op| switch (op) {
            .node_op => |n| if (n.props.len > 0) allocator.free(n.props),
            .edge_op => |e| if (e.props.len > 0) allocator.free(e.props),
        };
        ops.deinit(allocator);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const kind = try r.byte();
        switch (kind) {
            0 => {
                const op_type = try readWriteOpType(&r);
                const node_id = try r.readU64();
                const label = try r.str16();
                const graph = try r.str16();
                const props = try readProps(&r, allocator);
                errdefer if (props.len > 0) allocator.free(props);
                try ops.append(allocator, .{ .node_op = .{
                    .op_type = op_type,
                    .node_id = node_id,
                    .label = label,
                    .graph = graph,
                    .props = props,
                } });
            },
            1 => {
                const op_type = try readWriteOpType(&r);
                const edge_id = try r.readU64();
                const source_id = try r.readU64();
                const target_id = try r.readU64();
                const edge_type = try r.str16();
                const graph = try r.str16();
                const props = try readProps(&r, allocator);
                errdefer if (props.len > 0) allocator.free(props);
                try ops.append(allocator, .{ .edge_op = .{
                    .op_type = op_type,
                    .edge_id = edge_id,
                    .source_id = source_id,
                    .target_id = target_id,
                    .edge_type = edge_type,
                    .graph = graph,
                    .props = props,
                } });
            },
            else => return CodecError.CorruptPayload,
        }
    }

    return .{ .ops = try ops.toOwnedSlice(allocator) };
}

// ---------------------------------------------------------------------------
// Coordinator
// ---------------------------------------------------------------------------

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

/// Distributed Transaction Coordinator with durable storage integration.
/// Committed Raft `txn_prepare` / `txn_decide` entries route here from
/// `raft_apply.zig` (GAP-0870).
/// CANARY: REQ=REQ-GQL-2PC-APPLY-001; FEATURE="2PC Write Set Application"; ASPECT=2PC; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
pub const TxnCoordinator = struct {
    allocator: Allocator,
    store: *graph_store.GraphStore,
    prepared_txns: std.AutoHashMap(u64, PreparedTxn),
    lock_table: std.AutoHashMap(u64, Lock),
    timeout_ms: u64 = 10_000, // Default 10 seconds

    pub fn init(allocator: Allocator, store: *graph_store.GraphStore) !TxnCoordinator {
        return TxnCoordinator{
            .allocator = allocator,
            .store = store,
            .prepared_txns = std.AutoHashMap(u64, PreparedTxn).init(allocator),
            .lock_table = std.AutoHashMap(u64, Lock).init(allocator),
        };
    }

    pub fn deinit(self: *TxnCoordinator) void {
        var it = self.prepared_txns.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.write_set);
            self.allocator.free(entry.value_ptr.metadata);
            entry.value_ptr.locks.deinit(self.allocator);
        }
        self.prepared_txns.deinit();

        self.lock_table.deinit();
    }

    /// Handle txn_prepare command from Raft.  Returns the vote: true =
    /// VOTE_COMMIT (locks acquired, write set buffered), false = VOTE_ABORT
    /// (conflict or undecodable write set).
    pub fn handlePrepare(self: *TxnCoordinator, prepare: raft_consensus.TxnPrepare) !bool {
        // Re-prepare of an already-prepared xid (restart log replay) is a
        // deterministic re-vote, not a conflict with itself.
        if (self.prepared_txns.contains(prepare.xid)) return true;

        var decoded = deserializeWriteSet(self.allocator, prepare.write_set) catch |err| {
            log.warn("Invalid 2PC write set payload — voting abort", &.{
                Attr.uint("xid", prepare.xid),
                Attr.string("error", @errorName(err)),
            });
            return false;
        };
        defer decoded.deinit(self.allocator);

        // Check for conflicts
        for (decoded.ops) |op| {
            const resource_id = resourceIdOf(op);
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
        errdefer locks.deinit(self.allocator);
        // GAP-0889 (Task-28 nit): if anything below fails (OOM in the dupe
        // or the prepared_txns.put), the lock_table entries inserted so far
        // must be rolled back too — otherwise the resources stay locked by
        // an xid that was never registered and can never be decided.
        errdefer for (locks.items) |lock| {
            _ = self.lock_table.remove(lock.resource_id);
        };
        for (decoded.ops) |op| {
            const lock = Lock{
                .resource_id = resourceIdOf(op),
                .mode = .exclusive,
                .holder_xid = prepare.xid,
            };
            try locks.append(self.allocator, lock);
            try self.lock_table.put(lock.resource_id, lock);
        }

        const ws_copy = try self.allocator.dupe(u8, prepare.write_set);
        errdefer self.allocator.free(ws_copy);
        const md_copy = try self.allocator.dupe(u8, prepare.metadata);
        errdefer self.allocator.free(md_copy);

        try self.prepared_txns.put(prepare.xid, .{
            .xid = prepare.xid,
            .write_set = ws_copy,
            .metadata = md_copy,
            .prepare_time = compat_milliTimestamp(),
            .locks = locks,
        });
        log.info("Transaction prepared successfully", &.{
            Attr.uint("xid", prepare.xid),
        });
        return true; // Vote commit
    }

    /// Handle txn_decide command from Raft: commit applies the buffered
    /// write set to the store; abort releases the locks without applying.
    /// An unknown xid is tolerated — a decide(abort) legitimately follows a
    /// prepare that voted abort and never registered.
    pub fn handleDecide(self: *TxnCoordinator, decide: raft_consensus.TxnDecide) !void {
        const removed = self.prepared_txns.fetchRemove(decide.xid) orelse {
            log.warn("Transaction not found in prepared state", &.{
                Attr.uint("xid", decide.xid),
            });
            return;
        };
        var prepared = removed.value;

        defer {
            // Release locks + free buffered state whether we commit or abort.
            for (prepared.locks.items) |lock| {
                _ = self.lock_table.remove(lock.resource_id);
            }
            prepared.locks.deinit(self.allocator);
            self.allocator.free(prepared.write_set);
            self.allocator.free(prepared.metadata);
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

    /// Check for timed-out transactions.
    ///
    /// GAP-0889 (Task-28 F2) — DOCUMENTED RESIDUAL, do not wire as-is:
    /// this function has NO production caller, and that is deliberate. The
    /// TxnCoordinator is a *replicated state machine* applied on every raft
    /// node; a wall-clock timeout abort taken locally would be
    /// replica-divergent (each node's clock crosses `timeout_ms` at a
    /// different moment relative to its apply stream, so one replica could
    /// abort an xid that another replica then commits via a late
    /// `txn_decide`). The correct design is for the *leader* to detect the
    /// timeout and propose a `txn_decide{commit=false}` through raft, so
    /// every replica aborts at the same log position. Implementing
    /// raft-proposed timeout decides is tracked future work
    /// (docs/DISTRIBUTED_QUALITY_GAP_ANALYSIS.md); until then this helper
    /// exists for tests and for that future leader-side caller only.
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

    fn resourceIdOf(op: WriteSetOp) u64 {
        return switch (op) {
            .node_op => |n| n.node_id,
            .edge_op => |e| e.edge_id,
        };
    }

    /// Parse and apply write set operations to GraphStore.
    /// Write set payload is a native G2PC-encoded operation list (GAP-0870).
    /// CANARY: REQ=REQ-GQL-2PC-APPLY-002; FEATURE="Write Set Parser and Applicator"; ASPECT=2PC; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
    fn applyWriteSet(self: *TxnCoordinator, write_set: []const u8) !void {
        var decoded = deserializeWriteSet(self.allocator, write_set) catch |err| {
            log.err("Failed to decode write set", &.{
                Attr.string("error", @errorName(err)),
            });
            return err;
        };
        defer decoded.deinit(self.allocator);

        for (decoded.ops) |op| {
            try self.applyOperation(op);
        }

        log.info("2PC applied operations from write set", &.{
            Attr.uint("operation_count", decoded.ops.len),
        });
    }

    // CANARY: REQ=REQ-SONNY-6541-2PC-APPLY-CHECKPOINT-EXCLUSION; FEATURE="DistributedCluster"; ASPECT=DecideHoldsReplicatedApplyMutex; STATUS=TESTED; TEST=tests/test_sonny6541_2pc_apply_checkpoint_exclusion.zig; OWNER=distributed; UPDATED=2026-11-14
    /// SONNY-6541 (2): each operation holds its graph's
    /// `replicated_apply_mutex`, as a Raft graph mutation's apply does
    /// (SONNY-6528 (1), `raft_apply.applyGraphMutationInner`): a checkpoint
    /// of the graph waits for it. It runs on the Raft apply thread under the
    /// node's `inner_mutex`, so it cannot take the graph's `rwlock`. The
    /// graph is hydrated first, outside the mutex (a first hydration persists
    /// its products with a checkpoint of the graph).
    fn applyOperation(self: *TxnCoordinator, op: WriteSetOp) !void {
        const op_graph = switch (op) {
            .node_op => |n| n.graph,
            .edge_op => |e| e.graph,
        };
        const graph_name = if (op_graph.len > 0) op_graph else graph_store.DEFAULT_GRAPH_NAME;
        self.store.ensureGraphForReplicatedWrite(graph_name) catch |err| switch (err) {
            error.GraphAlreadyExists => {},
            else => return err,
        };
        self.store.ensureGraphHydrated(graph_name);
        const adapter = graph_store.getGlobalAdapter();
        const apply_mg = if (adapter) |a| try a.beginReplicatedApply(graph_name) else null;
        defer if (apply_mg) |mg| adapter.?.endReplicatedApply(mg);
        return self.applyOperationLocked(op);
    }

    fn applyOperationLocked(self: *TxnCoordinator, op: WriteSetOp) !void {
        switch (op) {
            .node_op => |node_op| {
                const graph_name = if (node_op.graph.len > 0) node_op.graph else graph_store.DEFAULT_GRAPH_NAME;
                // Ensure the target graph exists (idempotent, mirrors raft_apply).
                self.store.ensureGraphForReplicatedWrite(graph_name) catch |err| switch (err) {
                    error.GraphAlreadyExists => {},
                    else => return err,
                };
                switch (node_op.op_type) {
                    .create => {
                        if (self.store.getNodePtr(node_op.node_id) == null) {
                            const labels = [_][]const u8{node_op.label};
                            const label_slice: []const []const u8 = if (node_op.label.len > 0) &labels else &.{};
                            self.store.createNodeWithId(node_op.node_id, label_slice, graph_name) catch |err| switch (err) {
                                error.NodeAlreadyExists => {},
                                else => return err,
                            };
                        } else if (node_op.label.len > 0) {
                            self.store.addNodeLabel(node_op.node_id, node_op.label) catch {};
                        }
                        for (node_op.props) |p| {
                            try self.store.setNodeProperty(node_op.node_id, p.key, p.value);
                        }
                    },
                    .update => {
                        // PHASE 1b (H3): a no-snapshot deferred graph keeps its
                        // IdMap/resident caches EMPTY until first access, so the
                        // raw `getNodePtr` gate below would resolve null and
                        // SILENTLY DROP this replicated property update. Hydrate
                        // the target graph first (no-op once hydrated / for a
                        // non-deferred graph) so the by-id gate sees the node.
                        self.store.ensureGraphHydrated(graph_name);
                        if (self.store.getNodePtr(node_op.node_id) != null) {
                            for (node_op.props) |p| {
                                try self.store.setNodeProperty(node_op.node_id, p.key, p.value);
                            }
                        }
                    },
                    .delete => {
                        // SONNY-6302: a failed delete fails the apply, as a
                        // failed create or property write does (the void form
                        // only logged it).
                        try self.store.deleteNodeChecked(node_op.node_id);
                    },
                }
            },
            .edge_op => |edge_op| {
                const graph_name = if (edge_op.graph.len > 0) edge_op.graph else graph_store.DEFAULT_GRAPH_NAME;
                self.store.ensureGraphForReplicatedWrite(graph_name) catch |err| switch (err) {
                    error.GraphAlreadyExists => {},
                    else => return err,
                };
                switch (edge_op.op_type) {
                    .create => {
                        if (self.store.getEdgePtr(edge_op.edge_id) == null) {
                            self.store.createEdgeWithId(edge_op.edge_id, edge_op.source_id, edge_op.target_id, edge_op.edge_type, graph_name) catch |err| switch (err) {
                                error.EdgeAlreadyExists => {},
                                else => return err,
                            };
                        }
                        for (edge_op.props) |p| {
                            try self.store.setEdgeProperty(edge_op.edge_id, p.key, p.value);
                        }
                    },
                    .update => {
                        // PHASE 1b (H3): mirror the node .update fix. A deferred
                        // no-snapshot graph's edge IdMap/cache is EMPTY until
                        // first access, so the raw `getEdgePtr` gate would
                        // resolve null and SILENTLY DROP this replicated edge
                        // property update. Hydrate first (no-op once hydrated).
                        self.store.ensureGraphHydrated(graph_name);
                        if (self.store.getEdgePtr(edge_op.edge_id) != null) {
                            for (edge_op.props) |p| {
                                try self.store.setEdgeProperty(edge_op.edge_id, p.key, p.value);
                            }
                        }
                    },
                    .delete => {
                        try self.store.deleteEdgeChecked(edge_op.edge_id); // SONNY-6302
                    },
                }
            },
        }
    }
};

// ---------------------------------------------------------------------------
// History note (2026-06-10 / GAP-0870 update 2026-06-11):
//
// The four `TestCANARY_2PC_*` inline tests were moved to
// `tests/test_txn_coordinator_2pc.zig` (`zig build test-txn-coordinator-2pc`)
// because their protobuf union-encoding bodies broke compilation of any test
// root that transitively imported this file.  That step stays gated behind
// `protobuf_union_submessage_supported` and now ONLY tracks the protobuf
// TwoPhaseMessage WIRE format (blocked in the pinned protobuf 0.1.3 for both
// encode and decode of union-as-submessage).
//
// The 2PC APPLY path itself no longer depends on protobuf: GAP-0870 moved
// the write-set payload to the native G2PC codec above, exercised end-to-end
// (serialize → prepare → decide → store mutation) by
// tests/test_gap0870_raft_command_variants.zig (`zig build test-gap0870`).
// ---------------------------------------------------------------------------

test "write set codec: round-trips node and edge ops" {
    const allocator = std.testing.allocator;
    const props = [_]Prop{
        .{ .key = "name", .value = .{ .String = "alice" } },
        .{ .key = "age", .value = .{ .Int = 30 } },
    };
    const ops = [_]WriteSetOp{
        .{ .node_op = .{ .op_type = .create, .node_id = 7, .label = "Person", .graph = "g", .props = &props } },
        .{ .edge_op = .{ .op_type = .create, .edge_id = 8, .source_id = 7, .target_id = 7, .edge_type = "SELF", .graph = "g" } },
        .{ .node_op = .{ .op_type = .delete, .node_id = 9 } },
    };
    const payload = try serializeWriteSet(allocator, &ops);
    defer allocator.free(payload);
    try std.testing.expect(isWriteSetPayload(payload));

    var decoded = try deserializeWriteSet(allocator, payload);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), decoded.ops.len);
    try std.testing.expectEqual(@as(u64, 7), decoded.ops[0].node_op.node_id);
    try std.testing.expectEqualStrings("Person", decoded.ops[0].node_op.label);
    try std.testing.expectEqual(@as(usize, 2), decoded.ops[0].node_op.props.len);
    try std.testing.expectEqualStrings("alice", decoded.ops[0].node_op.props[0].value.String);
    try std.testing.expectEqual(@as(i64, 30), decoded.ops[0].node_op.props[1].value.Int);
    try std.testing.expectEqualStrings("SELF", decoded.ops[1].edge_op.edge_type);
    try std.testing.expectEqual(WriteOpType.delete, decoded.ops[2].node_op.op_type);
}

test "write set codec: rejects corrupt payloads" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(CodecError.CorruptPayload, deserializeWriteSet(allocator, "not-a-write-set"));
    // Magic with truncated body.
    const truncated = MAGIC_2PC ++ [_]u8{0x05};
    try std.testing.expectError(CodecError.CorruptPayload, deserializeWriteSet(allocator, &truncated));
}
