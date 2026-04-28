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

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const graph_store = @import("graph_store.zig");
const property_codec = @import("property_value_codec.zig");
const txn_undo_log = @import("txn_undo_log.zig");
const tde = @import("storage/tde_file_encryption.zig");
const wal_lib = @import("wal");

// CANARY: REQ=REQ-PERF-WAL-001; FEATURE="WriteAheadLog"; ASPECT=DeltaPersistence; STATUS=TESTED; OWNER=storage; UPDATED=2026-03-31
// CANARY: REQ=REQ-TDE-ENFORCE-002; FEATURE=TDEEnforcement; ASPECT=WALEncryption; STATUS=TESTED; OWNER=security; UPDATED=2026-02-19
//
// This WAL is a logical change feed for CDC/audit purposes.
// Physical crash recovery is handled by the graph-storage engine's own WAL
// (via engine.open() which replays committed transactions on startup).
// This WAL is NOT required for database durability.
//
// Delegates to the external wal library (gitlab.com/devnw/zig/wal) for
// append-only storage. This module provides the geode-specific serialization layer
// (WalRecord types, mutation callbacks, persistence hooks, global instance management).

const logging = @import("logging");
const log = logging.scoped("wal");
const Attr = logging.Attr;

/// WAL record operation types (post-images for redo, reuse UndoOpType discriminants)
pub const WalOpType = enum(u8) {
    CreateNode = 1,
    CreateEdge = 2,
    SetNodeProperty = 3,
    RemoveNodeProperty = 4,
    SetEdgeProperty = 5,
    RemoveEdgeProperty = 6,
    DeleteNode = 7,
    DeleteEdge = 8,
    AddNodeLabel = 9,
    RemoveNodeLabel = 10,
};

/// WAL record payload (post-image for redo)
pub const WalRecord = union(WalOpType) {
    CreateNode: struct {
        node_id: u64,
        graph_name: []const u8,
        labels: []const []const u8,
    },
    CreateEdge: struct {
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        label: []const u8,
        graph_name: []const u8,
    },
    SetNodeProperty: struct {
        node_id: u64,
        key: []const u8,
        value: txn_undo_log.SerializedProperty,
    },
    RemoveNodeProperty: struct {
        node_id: u64,
        key: []const u8,
    },
    SetEdgeProperty: struct {
        edge_id: u64,
        key: []const u8,
        value: txn_undo_log.SerializedProperty,
    },
    RemoveEdgeProperty: struct {
        edge_id: u64,
        key: []const u8,
    },
    DeleteNode: struct {
        node_id: u64,
        graph_name: []const u8,
    },
    DeleteEdge: struct {
        edge_id: u64,
        graph_name: []const u8,
    },
    AddNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },
    RemoveNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },
};

/// Load the WAL encryption key. Checks GEODE_WAL_KEY first (WAL-specific key),
/// then falls back to GEODE_TDE_KEY. Returns null if neither is set.
fn loadWalKey(allocator: std.mem.Allocator) !?[32]u8 {
    // Try WAL-specific key first
    const wal_hex = getEnvVarOwned(allocator, "GEODE_WAL_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => return e,
    };
    if (wal_hex) |hex| {
        defer allocator.free(hex);
        if (hex.len == 64) {
            var key: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                const hi = std.fmt.charToDigit(hex[i * 2], 16) catch return tde.TdeError.InvalidKey;
                const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return tde.TdeError.InvalidKey;
                key[i] = @as(u8, @intCast(hi * 16 + lo));
            }
            return key;
        }
    }
    // Fall back to GEODE_TDE_KEY
    return try tde.loadKey(allocator);
}

/// Geode WriteAheadLog — wraps the external wal library with graph-specific
/// record types, serialization, and integration with graph_store.
pub const WriteAheadLog = struct {
    allocator: std.mem.Allocator,
    inner: wal_lib.WriteAheadLog,
    checkpoint_lsn: u64,
    last_checkpoint_ms: i64,

    /// Current LSN (read-only accessor for tests and diagnostics).
    pub fn currentLsn(self: *WriteAheadLog) u64 {
        return self.inner.currentLsn();
    }

    /// Bytes written since last checkpoint/compaction.
    pub fn bytesSinceCheckpoint(self: *WriteAheadLog) u64 {
        return self.inner.bytesSinceCompact();
    }

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !WriteAheadLog {
        // Load WAL encryption key: GEODE_WAL_KEY takes precedence, then GEODE_TDE_KEY.
        const wal_key = try loadWalKey(allocator);

        // Split path into directory and filename for the external WAL library.
        const sep = std.mem.lastIndexOfScalar(u8, path, '/');
        const dir_path = if (sep) |s| path[0..s] else ".";
        const filename = if (sep) |s| path[s + 1 ..] else path;

        const dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir_path);
                return init(allocator, path);
            }
            return err;
        };

        const inner = try wal_lib.WriteAheadLog.init(allocator, dir, filename, .{
            .encryption_key = wal_key,
            .manual_sync = true, // Geode manages sync via persistence hooks
            .checkpoint = true,
        });

        return WriteAheadLog{
            .allocator = allocator,
            .inner = inner,
            .checkpoint_lsn = 0,
            .last_checkpoint_ms = compat_milliTimestamp(),
        };
    }

    pub fn deinit(self: *WriteAheadLog) void {
        self.inner.deinit();
    }

    /// Append a WAL record and return the assigned LSN.
    /// Thread-safe: the external WAL library handles locking internally.
    pub fn appendRecord(self: *WriteAheadLog, txn_id: u64, record: WalRecord) !u64 {
        // OTel Task 12: record WAL append duration + record type count.
        const _om12w = @import("otel_metrics");
        const _t0_12w = @import("otel").internal.clock.unixNanoNow();
        const _rec_type: _om12w.WalRecordType = switch (record) {
            .CreateNode => .node_create,
            .CreateEdge => .edge_create,
            .SetNodeProperty, .AddNodeLabel => .node_update,
            .RemoveNodeProperty, .RemoveNodeLabel => .node_update,
            .SetEdgeProperty => .edge_update,
            .RemoveEdgeProperty => .edge_update,
            .DeleteNode => .node_delete,
            .DeleteEdge => .edge_delete,
        };
        _om12w.recordWalRecord(_rec_type);

        // #692: Use a stack buffer for small records (majority of mutations
        // are under 256 bytes) to avoid a heap allocation per WAL append.
        // The FixedBufferAllocator serves from the stack; if the record
        // exceeds 256 bytes, we fall back to the heap allocator.
        var stack_buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
        const stack_alloc = fba.allocator();

        // Try stack-backed path first; fall back to heap on overflow.
        const _lsn = self.appendRecordWithAllocator(stack_alloc, txn_id, record) catch |err| switch (err) {
            error.OutOfMemory => try self.appendRecordWithAllocator(self.allocator, txn_id, record),
            else => return err,
        };
        const _append_dur: f64 = @as(f64, @floatFromInt(@import("otel").internal.clock.unixNanoNow() -% _t0_12w)) / @as(f64, std.time.ns_per_s);
        _om12w.recordWalAppend(_append_dur, .success);
        return _lsn;
    }

    fn appendRecordWithAllocator(self: *WriteAheadLog, alloc: std.mem.Allocator, txn_id: u64, record: WalRecord) !u64 {
        // Serialize the geode-specific payload: [u64: txn_id][u8: op_type][payload...]
        var payload_buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
        defer payload_buf.deinit(alloc);

        // Prepend txn_id and op_type to the serialized payload
        try appendU64(&payload_buf, alloc, txn_id);
        try payload_buf.append(alloc, @intFromEnum(std.meta.activeTag(record)));
        try serializePayload(alloc, &payload_buf, record);

        return self.inner.append(payload_buf.items);
    }

    /// Flush WAL to disk (fsync)
    pub fn sync(self: *WriteAheadLog) !void {
        // OTel Task 12: record WAL fsync duration.
        const _om12s = @import("otel_metrics");
        const _t0_12s = @import("otel").internal.clock.unixNanoNow();
        var _fsync_ok = true;
        self.inner.sync() catch |err| {
            _fsync_ok = false;
            log.warn("WAL fsync failed — CDC/audit events may be lost", &.{
                Attr.string("error", @errorName(err)),
            });
        };
        const _fsync_dur: f64 = @as(f64, @floatFromInt(@import("otel").internal.clock.unixNanoNow() -% _t0_12s)) / @as(f64, std.time.ns_per_s);
        _om12s.recordWalFsync(_fsync_dur, if (_fsync_ok) .success else .error_);
    }

    /// DEPRECATED: Crash recovery is now handled by the graph-storage engine's
    /// own WAL via engine.open(). This Geode WAL serves only as a logical change
    /// feed for CDC/audit. Replay is skipped; returns 0.
    pub fn replay(self: *WriteAheadLog, store: *graph_store.GraphStore) !u64 {
        log.info("WAL replay skipped — crash recovery delegated to graph-storage engine", &.{});

        // Legacy replay logic retained for reference and potential CDC replay.
        // Gate behind an unreachable condition to keep applyRecord reachable
        // for the compiler while ensuring this path is never taken at runtime.
        if (false) {
            return self.replayLegacy(store);
        }
        return 0;
    }

    /// Legacy replay implementation — retained for potential CDC replay use.
    fn replayLegacy(self: *WriteAheadLog, store: *graph_store.GraphStore) !u64 {
        graph_store.setMutationNotifyInhibit(true);
        defer graph_store.setMutationNotifyInhibit(false);

        var iter = try self.inner.iterator(self.checkpoint_lsn);
        defer iter.deinit();

        var last_lsn: u64 = 0;
        var replayed: u64 = 0;

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            if (entry.lsn <= self.checkpoint_lsn) continue;

            const payload = entry.payload;
            if (payload.len < 9) continue;

            const op_type_byte = payload[8];
            const record_payload = payload[9..];

            const op_type: WalOpType = @enumFromInt(op_type_byte);
            applyRecord(store, op_type, record_payload) catch |err| {
                log.warn("WAL replay failed for record", &.{
                    Attr.int("lsn", @intCast(entry.lsn)),
                    Attr.string("error", @errorName(err)),
                });
                continue;
            };

            last_lsn = entry.lsn;
            replayed += 1;
        }

        if (replayed > 0) {
            log.info("WAL replay complete", &.{
                Attr.int("records_replayed", @intCast(replayed)),
                Attr.int("last_lsn", @intCast(last_lsn)),
            });
        }

        return last_lsn;
    }

    /// Truncate WAL records up to the given LSN (after a successful checkpoint).
    pub fn truncate(self: *WriteAheadLog, up_to_lsn: u64) !void {
        if (up_to_lsn == 0) return;
        try self.inner.compact(up_to_lsn);
        self.checkpoint_lsn = up_to_lsn;
        self.last_checkpoint_ms = compat_milliTimestamp();
    }

    /// Perform a checkpoint: delegates physical durability to the graph-storage
    /// engine (via adapter.checkpointAll()), saves IdMaps, then truncates this
    /// logical WAL for space management.
    pub fn checkpoint(self: *WriteAheadLog, store: *graph_store.GraphStore) !void {
        try store.saveToFile(); // calls adapter.checkpointAll() + legacy sidecar cleanup
        const checkpoint_at = self.inner.currentLsn();
        try self.truncate(checkpoint_at);
    }

    /// Check if a checkpoint is needed based on byte or time thresholds.
    pub fn needsCheckpoint(self: *WriteAheadLog, byte_threshold: u64, time_threshold_ms: u64) bool {
        const bytes = self.inner.bytesSinceCompact();
        if (bytes >= byte_threshold) return true;
        if (time_threshold_ms > 0 and bytes > 0) {
            const now = compat_milliTimestamp();
            const elapsed: u64 = @intCast(@max(0, now - self.last_checkpoint_ms));
            return elapsed >= time_threshold_ms;
        }
        return false;
    }
};

// ---- Serialization helpers ----

fn serializePayload(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), record: WalRecord) !void {
    switch (record) {
        .CreateNode => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.graph_name);
            try appendU32(buf, allocator, @intCast(r.labels.len));
            for (r.labels) |label| {
                try appendString(buf, allocator, label);
            }
        },
        .CreateEdge => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendU64(buf, allocator, r.from_id);
            try appendU64(buf, allocator, r.to_id);
            try appendString(buf, allocator, r.label);
            try appendString(buf, allocator, r.graph_name);
        },
        .SetNodeProperty => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.key);
            try serializeProperty(buf, allocator, r.value);
        },
        .RemoveNodeProperty => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.key);
        },
        .SetEdgeProperty => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendString(buf, allocator, r.key);
            try serializeProperty(buf, allocator, r.value);
        },
        .RemoveEdgeProperty => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendString(buf, allocator, r.key);
        },
        .DeleteNode => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.graph_name);
        },
        .DeleteEdge => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendString(buf, allocator, r.graph_name);
        },
        .AddNodeLabel => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.label);
        },
        .RemoveNodeLabel => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.label);
        },
    }
}

fn serializeProperty(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, prop: txn_undo_log.SerializedProperty) !void {
    try buf.append(allocator, prop.value_type);
    switch (prop.value_type) {
        0 => {}, // Null
        1 => try appendString(buf, allocator, prop.string_value orelse ""),
        2 => try appendI64(buf, allocator, prop.int_value),
        3 => try appendF64(buf, allocator, prop.float_value),
        4 => try buf.append(allocator, if (prop.bool_value) @as(u8, 1) else @as(u8, 0)),
        5 => try appendString(buf, allocator, prop.binary_value orelse ""),
        else => {},
    }
}

fn appendU64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendI64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendI128(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i128) !void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(i128, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendF64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64) !void {
    const bits: u64 = @bitCast(value);
    try appendU64(buf, allocator, bits);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    try appendU32(buf, allocator, @intCast(str.len));
    try buf.appendSlice(allocator, str);
}

// ---- Deserialization / replay helpers ----

fn readU64(data: []const u8, offset: *usize) !u64 {
    if (offset.* + 8 > data.len) return error.UnexpectedEndOfStream;
    const value = std.mem.readInt(u64, data[offset.*..][0..8], .little);
    offset.* += 8;
    return value;
}

fn readI64(data: []const u8, offset: *usize) !i64 {
    if (offset.* + 8 > data.len) return error.UnexpectedEndOfStream;
    const value = std.mem.readInt(i64, data[offset.*..][0..8], .little);
    offset.* += 8;
    return value;
}

fn readI128(data: []const u8, offset: *usize) !i128 {
    if (offset.* + 16 > data.len) return error.UnexpectedEndOfStream;
    const value = std.mem.readInt(i128, data[offset.*..][0..16], .little);
    offset.* += 16;
    return value;
}

fn readF64(data: []const u8, offset: *usize) !f64 {
    const bits = try readU64(data, offset);
    return @bitCast(bits);
}

fn readU32(data: []const u8, offset: *usize) !u32 {
    if (offset.* + 4 > data.len) return error.UnexpectedEndOfStream;
    const value = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    return value;
}

fn readString(data: []const u8, offset: *usize) ![]const u8 {
    const len = try readU32(data, offset);
    if (offset.* + len > data.len) return error.UnexpectedEndOfStream;
    const str = data[offset.* .. offset.* + len];
    offset.* += len;
    return str;
}

fn applyRecord(store: *graph_store.GraphStore, op_type: WalOpType, payload: []const u8) !void {
    var offset: usize = 0;
    switch (op_type) {
        .CreateNode => {
            const node_id = try readU64(payload, &offset);
            const graph_name = try readString(payload, &offset);
            const label_count = try readU32(payload, &offset);
            var labels = try store.allocator.alloc([]const u8, label_count);
            defer store.allocator.free(labels);
            for (0..label_count) |i| {
                labels[i] = try readString(payload, &offset);
            }
            store.createNodeWithId(node_id, labels, graph_name) catch |err| {
                log.warn("WAL replay: createNodeWithId failed", &.{Attr.string("error", @errorName(err))});
            };
        },
        .CreateEdge => {
            const edge_id = try readU64(payload, &offset);
            const from_id = try readU64(payload, &offset);
            const to_id = try readU64(payload, &offset);
            const label = try readString(payload, &offset);
            const graph_name = try readString(payload, &offset);
            store.createEdgeWithId(edge_id, from_id, to_id, label, graph_name) catch |err| {
                log.warn("WAL replay: createEdgeWithId failed", &.{Attr.string("error", @errorName(err))});
            };
        },
        .SetNodeProperty => {
            const node_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            const value_type = if (offset < payload.len) payload[offset] else return error.UnexpectedEndOfStream;
            offset += 1;
            const pv = deserializePropertyValue(store.allocator, payload, &offset, value_type) catch graph_store.PropertyValue.Null;
            defer property_codec.freePropertyValue(store.allocator, pv);
            store.setNodeProperty(node_id, key, pv) catch |err| {
                log.warn("WAL replay: setNodeProperty failed", &.{Attr.string("error", @errorName(err))});
            };
        },
        .RemoveNodeProperty => {
            const node_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            store.removeNodeProperty(node_id, key);
        },
        .SetEdgeProperty => {
            const edge_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            const value_type = if (offset < payload.len) payload[offset] else return error.UnexpectedEndOfStream;
            offset += 1;
            const pv = deserializePropertyValue(store.allocator, payload, &offset, value_type) catch graph_store.PropertyValue.Null;
            defer property_codec.freePropertyValue(store.allocator, pv);
            store.setEdgeProperty(edge_id, key, pv) catch |err| {
                log.warn("WAL replay: setEdgeProperty failed", &.{Attr.string("error", @errorName(err))});
            };
        },
        .RemoveEdgeProperty => {
            const edge_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            store.removeEdgeProperty(edge_id, key);
        },
        .DeleteNode => {
            const node_id = try readU64(payload, &offset);
            _ = try readString(payload, &offset); // graph_name
            store.deleteNode(node_id);
        },
        .DeleteEdge => {
            const edge_id = try readU64(payload, &offset);
            _ = try readString(payload, &offset); // graph_name
            store.deleteEdge(edge_id);
        },
        .AddNodeLabel => {
            const node_id = try readU64(payload, &offset);
            const label = try readString(payload, &offset);
            store.addNodeLabel(node_id, label) catch |err| {
                log.warn("WAL replay: addNodeLabel failed", &.{Attr.string("error", @errorName(err))});
            };
        },
        .RemoveNodeLabel => {
            const node_id = try readU64(payload, &offset);
            const label = try readString(payload, &offset);
            store.removeNodeLabel(node_id, label) catch |err| {
                log.warn("WAL replay: removeNodeLabel failed", &.{Attr.string("error", @errorName(err))});
            };
        },
    }
}

fn deserializePropertyValue(allocator: std.mem.Allocator, data: []const u8, offset: *usize, value_type: u8) !graph_store.PropertyValue {
    return switch (value_type) {
        0 => graph_store.PropertyValue.Null,
        1 => graph_store.PropertyValue{ .String = try readString(data, offset) },
        2 => graph_store.PropertyValue{ .Int = try readI64(data, offset) },
        3 => graph_store.PropertyValue{ .Float = try readF64(data, offset) },
        4 => blk: {
            if (offset.* >= data.len) return error.UnexpectedEndOfStream;
            const b = data[offset.*] != 0;
            offset.* += 1;
            break :blk graph_store.PropertyValue{ .Bool = b };
        },
        5 => blk: {
            const bytes = try readString(data, offset);
            break :blk try property_codec.decodePropertyValue(allocator, bytes);
        },
        else => graph_store.PropertyValue.Null,
    };
}

// ---- Global WAL instance ----

pub var g_wal: ?*WriteAheadLog = null;
pub var g_wal_storage: ?WriteAheadLog = null;

/// Initialize the global WAL instance using the data directory
pub fn initGlobalWal(allocator: std.mem.Allocator, data_dir: ?[]const u8) !void {
    const dir = data_dir orelse "/tmp";
    const wal_path = try std.fmt.allocPrint(allocator, "{s}/geode_wal.log", .{dir});
    defer allocator.free(wal_path);

    // Ensure the directory exists
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir) catch |err| {
        log.err("WAL: failed to create data directory", &.{Attr.string("error", @errorName(err))});
    };

    g_wal_storage = try WriteAheadLog.init(allocator, wal_path);
    g_wal = &g_wal_storage.?;
}

/// Get the global WAL instance (null if not initialized)
pub fn getGlobalWal() ?*WriteAheadLog {
    return g_wal;
}

/// Deinitialize the global WAL
pub fn deinitGlobalWal() void {
    if (g_wal_storage) |*w| {
        w.deinit();
        g_wal_storage = null;
        g_wal = null;
    }
}

// ---- Mutation callback integration ----

/// Mutation callback installed in graph_store.
fn mutationCallback(
    op: graph_store.MutationOp,
    id1: u64,
    id2: u64,
    id3: u64,
    label: ?[]const u8,
    key: ?[]const u8,
    value: ?graph_store.PropertyValue,
    graph_name: ?[]const u8,
) void {
    const w = getGlobalWal() orelse return;
    var owned_property: ?txn_undo_log.SerializedProperty = null;
    defer if (owned_property) |prop| prop.deinit(w.allocator);
    const record: WalRecord = switch (op) {
        .create_node => .{ .CreateNode = .{
            .node_id = id1,
            .graph_name = graph_name orelse "default",
            .labels = if (label != null) @as([]const []const u8, &.{label.?}) else &.{},
        } },
        .create_edge => .{ .CreateEdge = .{
            .edge_id = id1,
            .from_id = id2,
            .to_id = id3,
            .label = label orelse "",
            .graph_name = graph_name orelse "default",
        } },
        .set_node_property => .{ .SetNodeProperty = .{
            .node_id = id1,
            .key = key orelse "",
            .value = blk: {
                owned_property = txn_undo_log.SerializedProperty.fromPropertyValue(
                    w.allocator,
                    key orelse "",
                    value orelse graph_store.PropertyValue.Null,
                ) catch return;
                break :blk owned_property.?;
            },
        } },
        .remove_node_property => .{ .RemoveNodeProperty = .{
            .node_id = id1,
            .key = key orelse "",
        } },
        .set_edge_property => .{ .SetEdgeProperty = .{
            .edge_id = id1,
            .key = key orelse "",
            .value = blk: {
                owned_property = txn_undo_log.SerializedProperty.fromPropertyValue(
                    w.allocator,
                    key orelse "",
                    value orelse graph_store.PropertyValue.Null,
                ) catch return;
                break :blk owned_property.?;
            },
        } },
        .remove_edge_property => .{ .RemoveEdgeProperty = .{
            .edge_id = id1,
            .key = key orelse "",
        } },
        .delete_node => .{ .DeleteNode = .{
            .node_id = id1,
            .graph_name = graph_name orelse "default",
        } },
        .delete_edge => .{ .DeleteEdge = .{
            .edge_id = id1,
            .graph_name = graph_name orelse "default",
        } },
        .add_node_label => .{ .AddNodeLabel = .{
            .node_id = id1,
            .label = label orelse "",
        } },
        .remove_node_label => .{ .RemoveNodeLabel = .{
            .node_id = id1,
            .label = label orelse "",
        } },
    };
    _ = w.appendRecord(0, record) catch |err| {
        log.err("WAL: appendRecord failed — mutation not logged for CDC/audit", &.{Attr.string("error", @errorName(err))});
    };
}

/// Install the WAL mutation callback in graph_store.
pub fn installMutationCallback() void {
    graph_store.setMutationNotify(&mutationCallback);
}

/// Remove the WAL mutation callback (e.g., during shutdown).
pub fn removeMutationCallback() void {
    graph_store.setMutationNotify(null);
}

// ---- Persistence integration ----

/// Default checkpoint thresholds
pub const CHECKPOINT_BYTE_THRESHOLD: u64 = 16 * 1024 * 1024; // 16MB
pub const CHECKPOINT_INTERVAL_MS: u64 = 60_000; // 60 seconds

fn walSyncHook() void {
    if (g_wal) |w| {
        w.sync() catch |err| {
            log.err("WAL: sync failed — CDC/audit events may not be durable", &.{Attr.string("error", @errorName(err))});
        };
    }
}

fn walNeedsCheckpointHook() bool {
    if (g_wal) |w| {
        return w.needsCheckpoint(CHECKPOINT_BYTE_THRESHOLD, CHECKPOINT_INTERVAL_MS);
    }
    return true;
}

/// Checkpoint hook: delegates physical durability to the graph-storage engine
/// (adapter.checkpointAll()), saves IdMaps, and truncates the logical WAL.
fn walCheckpointHook(store: *graph_store.GraphStore) void {
    if (g_wal) |w| {
        w.checkpoint(store) catch |err| {
            log.err("WAL checkpoint failed", &.{
                Attr.string("error", @errorName(err)),
            });
            // Fall back to engine checkpoint + IdMap save directly
            store.saveToFile() catch |save_err| {
                log.err("WAL: fallback saveToFile also failed — data may not be persisted", &.{Attr.string("error", @errorName(save_err))});
            };
        };
    } else {
        // No WAL — delegate to adapter checkpoint + IdMap save
        store.saveToFile() catch |err| {
            log.err("WAL: saveToFile failed — data may not be persisted", &.{Attr.string("error", @errorName(err))});
        };
    }
}

/// Install WAL persistence hooks in graph_store's persistence loop.
pub fn installPersistenceHooks() void {
    graph_store.setWalPersistenceHooks(
        &walSyncHook,
        &walNeedsCheckpointHook,
        &walCheckpointHook,
    );
}

/// Remove WAL persistence hooks (e.g., during shutdown).
pub fn removePersistenceHooks() void {
    graph_store.setWalPersistenceHooks(null, null, null);
}
