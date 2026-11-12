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

        // WAL trace span — emits when wal lib is built with -Dwith_otel=true
        // and otel_metrics.bindLibraryGlobals has wired the seam at server
        // startup. Both gates collapse to comptime no-ops otherwise.
        const _wal_op: []const u8 = switch (record) {
            .CreateNode => "create_node",
            .CreateEdge => "create_edge",
            .SetNodeProperty, .AddNodeLabel => "update_node",
            .RemoveNodeProperty, .RemoveNodeLabel => "update_node",
            .SetEdgeProperty => "update_edge",
            .RemoveEdgeProperty => "update_edge",
            .DeleteNode => "delete_node",
            .DeleteEdge => "delete_edge",
        };
        const _wal_span = wal_lib.observability.startWalSpan(_wal_op);
        defer wal_lib.observability.endWalSpan(_wal_span, true, 0);

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
    ///
    /// #812 (GAP-0886a): the dead always-false-gated legacy-replay path and its
    /// unreachable closure (legacy replay loop, record-apply switch, and the
    /// deserialization helpers) were removed 2026-06-10. If a CDC consumer needs to
    /// decode the logical feed, recover the implementation from git history
    /// (pre-GAP-0886a) rather than re-enabling an unmaintained in-process path.
    pub fn replay(self: *WriteAheadLog, store: *graph_store.GraphStore) !u64 {
        _ = self;
        _ = store;
        log.info("WAL replay skipped — crash recovery delegated to graph-storage engine", &.{});
        return 0;
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
        // GAP-0900 Layer-2: periodic WAL checkpoint uses the LIGHT engine
        // checkpoint (O(dirty): pages flushed + engine WAL truncated; derived
        // indexes rebuilt from pages on reopen). A FULL O(graph) checkpoint here
        // stalls a large ingest for minutes under the exclusive store lock.
        // Truncating the legacy WAL is safe after a light checkpoint because the
        // mutations are durable in the flushed pages.
        try store.saveToFileEx(true); // light engine checkpoint + legacy sidecar cleanup
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

// ---- Global WAL instance ----

pub var g_wal: ?*WriteAheadLog = null;
pub var g_wal_storage: ?WriteAheadLog = null;

// SONNY-6325: `initGlobalWal(allocator, ?data_dir)` was removed: nothing
// called it, and with no data directory it put the WAL at /tmp/geode_wal.log.
// Tests that need the global WAL set `g_wal_storage`/`g_wal` themselves.

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
            // Fall back to engine checkpoint + IdMap save directly (light: the
            // periodic hook must stay O(dirty), not O(graph)).
            store.saveToFileEx(true) catch |save_err| {
                log.err("WAL: fallback saveToFile also failed — data may not be persisted", &.{Attr.string("error", @errorName(save_err))});
            };
        };
    } else {
        // No WAL — delegate to adapter checkpoint + IdMap save (light: periodic).
        store.saveToFileEx(true) catch |err| {
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
