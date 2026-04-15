const std = @import("std");
const graph_store = @import("graph_store.zig");
const property_codec = @import("property_value_codec.zig");
// CANARY: REQ=REQ-TXN-UNDO-SERVER-014; FEATURE="TransactionUndoLog"; ASPECT=GraphCommonImport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const graph_common = @import("types/graph_common.zig");

// CANARY: REQ=REQ-TXN-UNDO-001; FEATURE="TransactionUndoLog"; ASPECT=UndoLogCore; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
// Transaction undo log for proper ROLLBACK support in CLI mode
// This module tracks all data modifications during a transaction
// and can undo them in reverse order on ROLLBACK

pub const UndoOpType = enum(u8) {
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

/// Serializable property value for undo log
pub const SerializedProperty = struct {
    key: []const u8,
    value_type: u8, // 0=null, 1=string, 2=int, 3=float, 4=bool, 5=binary encoded property
    string_value: ?[]const u8 = null,
    binary_value: ?[]const u8 = null,
    int_value: i64 = 0,
    float_value: f64 = 0.0,
    bool_value: bool = false,

    pub fn fromPropertyValue(allocator: std.mem.Allocator, key: []const u8, pv: graph_store.PropertyValue) !SerializedProperty {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);

        return switch (pv) {
            .Null => .{ .key = key_copy, .value_type = 0 },
            .String => |s| .{
                .key = key_copy,
                .value_type = 1,
                .string_value = try allocator.dupe(u8, s),
            },
            .Int => |i| .{ .key = key_copy, .value_type = 2, .int_value = i },
            .Float => |f| .{ .key = key_copy, .value_type = 3, .float_value = f },
            .Bool => |b| .{ .key = key_copy, .value_type = 4, .bool_value = b },
            .Decimal, .ExtValue => .{
                .key = key_copy,
                .value_type = 5,
                .binary_value = try property_codec.encodePropertyValue(allocator, pv),
            },
        };
    }

    pub fn toPropertyValue(self: SerializedProperty, allocator: std.mem.Allocator) !graph_store.PropertyValue {
        return switch (self.value_type) {
            0 => .Null,
            1 => .{ .String = self.string_value orelse "" },
            2 => .{ .Int = self.int_value },
            3 => .{ .Float = self.float_value },
            4 => .{ .Bool = self.bool_value },
            5 => try property_codec.decodePropertyValue(allocator, self.binary_value orelse return error.InvalidUndoLogProperty),
            else => .Null,
        };
    }

    pub fn deinit(self: SerializedProperty, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.string_value) |s| allocator.free(s);
        if (self.binary_value) |bytes| allocator.free(bytes);
    }
};

pub const UndoEntry = union(UndoOpType) {
    // On rollback: delete this node
    CreateNode: struct {
        node_id: u64,
        graph_name: []const u8, // Graph where node was created
    },

    // On rollback: delete this edge
    CreateEdge: struct {
        edge_id: u64,
        graph_name: []const u8, // Graph where edge was created
    },

    // On rollback: restore old value or remove property
    SetNodeProperty: struct {
        node_id: u64,
        key: []const u8,
        had_old_value: bool,
        old_value: SerializedProperty,
    },

    // On rollback: restore the removed property
    RemoveNodeProperty: struct {
        node_id: u64,
        old_value: SerializedProperty,
    },

    // On rollback: restore old value or remove property
    SetEdgeProperty: struct {
        edge_id: u64,
        key: []const u8,
        had_old_value: bool,
        old_value: SerializedProperty,
    },

    // On rollback: restore the removed property
    RemoveEdgeProperty: struct {
        edge_id: u64,
        old_value: SerializedProperty,
    },

    // On rollback: recreate the node with its data
    DeleteNode: struct {
        node_id: u64,
        labels: []const []const u8,
        properties: []const SerializedProperty,
        graph_name: []const u8,
    },

    // On rollback: recreate the edge with its data
    DeleteEdge: struct {
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        label: []const u8,
        properties: []const SerializedProperty,
        graph_name: []const u8,
    },

    // On rollback: remove the added label
    AddNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },

    // On rollback: add the removed label back
    RemoveNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },
};

// CANARY: REQ=REQ-TXN-SAVEPOINT-001; FEATURE="TransactionSavepoints"; ASPECT=UndoLogSavepoint; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
/// A savepoint records a named position in the undo log so that
/// rollbackToSavepoint can partially undo entries back to that point
/// without aborting the entire transaction.
pub const Savepoint = struct {
    name: []const u8,
    entry_index: usize,
};

/// Transaction undo log that persists across CLI invocations
pub const UndoLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(UndoEntry),
    active: bool,
    savepoints: std.ArrayListUnmanaged(Savepoint) = .{},
    pending_advanced_index_rebuilds: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(allocator: std.mem.Allocator) UndoLog {
        return .{
            .allocator = allocator,
            .entries = .{},
            .active = false,
            .savepoints = .{},
            .pending_advanced_index_rebuilds = .{},
        };
    }

    pub fn queueAdvancedIndexRebuild(self: *UndoLog, index_name: []const u8) !void {
        if (!self.active) return;
        const name_copy = try self.allocator.dupe(u8, index_name);
        try self.pending_advanced_index_rebuilds.put(self.allocator, name_copy, {});
    }

    pub fn flushPendingRebuilds(self: *UndoLog, store: *graph_store.GraphStore) void {
        const index_manager = @import("index/index_manager.zig").getGlobalIndexManager() orelse return;
        var iter = self.pending_advanced_index_rebuilds.keyIterator();
        while (iter.next()) |key_ptr| {
            index_manager.rebuildAdvancedIndex(store, key_ptr.*) catch {};
        }
        self.clearPendingRebuilds();
    }

    pub fn clearPendingRebuilds(self: *UndoLog) void {
        var iter = self.pending_advanced_index_rebuilds.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.pending_advanced_index_rebuilds.clearRetainingCapacity();
    }

    pub fn deinit(self: *UndoLog) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.clearSavepoints();
        self.savepoints.deinit(self.allocator);
        self.clearPendingRebuilds();
        self.pending_advanced_index_rebuilds.deinit(self.allocator);
    }

    pub fn clear(self: *UndoLog) void {
        // Free any allocated memory in entries
        for (self.entries.items) |entry| {
            switch (entry) {
                .SetNodeProperty => |e| {
                    self.allocator.free(e.key);
                    e.old_value.deinit(self.allocator);
                },
                .RemoveNodeProperty => |e| {
                    e.old_value.deinit(self.allocator);
                },
                .SetEdgeProperty => |e| {
                    self.allocator.free(e.key);
                    e.old_value.deinit(self.allocator);
                },
                .RemoveEdgeProperty => |e| {
                    e.old_value.deinit(self.allocator);
                },
                .DeleteNode => |e| {
                    for (e.labels) |label| self.allocator.free(label);
                    self.allocator.free(e.labels);
                    for (e.properties) |prop| {
                        prop.deinit(self.allocator);
                    }
                    self.allocator.free(e.properties);
                    self.allocator.free(e.graph_name);
                },
                .DeleteEdge => |e| {
                    self.allocator.free(e.label);
                    for (e.properties) |prop| {
                        prop.deinit(self.allocator);
                    }
                    self.allocator.free(e.properties);
                    self.allocator.free(e.graph_name);
                },
                .AddNodeLabel => |e| {
                    self.allocator.free(e.label);
                },
                .RemoveNodeLabel => |e| {
                    self.allocator.free(e.label);
                },
                .CreateNode => |e| {
                    self.allocator.free(e.graph_name);
                },
                .CreateEdge => |e| {
                    self.allocator.free(e.graph_name);
                },
            }
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn clearSavepoints(self: *UndoLog) void {
        for (self.savepoints.items) |sp| {
            self.allocator.free(sp.name);
        }
        self.savepoints.clearRetainingCapacity();
    }

    pub fn begin(self: *UndoLog) void {
        self.clear();
        self.clearSavepoints();
        self.clearPendingRebuilds();
        self.active = true;
    }

    pub fn commit(self: *UndoLog, store: ?*graph_store.GraphStore) void {
        if (store) |s| {
            self.flushPendingRebuilds(s);
        } else {
            self.clearPendingRebuilds();
        }
        self.clear();
        self.clearSavepoints();
        self.active = false;
    }

    /// GAP-0511: Commit transaction state (clear entries, savepoints, deactivate)
    /// WITHOUT flushing pending index rebuilds. Caller is responsible for calling
    /// flushPendingRebuilds separately -- typically after releasing the write lock
    /// to avoid blocking other connections during the O(N) index population scan.
    pub fn commitDeferRebuilds(self: *UndoLog) void {
        self.clear();
        self.clearSavepoints();
        self.active = false;
    }

    // CANARY: REQ=REQ-TXN-SAVEPOINT-002; FEATURE="TransactionSavepoints"; ASPECT=CreateSavepoint; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
    /// Create a named savepoint at the current position in the undo log.
    /// If a savepoint with the same name already exists, it is replaced.
    pub fn createSavepoint(self: *UndoLog, name: []const u8) !void {
        if (!self.active) return error.NoActiveTransaction;

        // Replace existing savepoint with same name
        for (self.savepoints.items) |*sp| {
            if (std.mem.eql(u8, sp.name, name)) {
                sp.entry_index = self.entries.items.len;
                return;
            }
        }

        const name_copy = try self.allocator.dupe(u8, name);
        try self.savepoints.append(self.allocator, .{
            .name = name_copy,
            .entry_index = self.entries.items.len,
        });
    }

    // CANARY: REQ=REQ-TXN-SAVEPOINT-003; FEATURE="TransactionSavepoints"; ASPECT=RollbackToSavepoint; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
    /// Roll back all undo entries recorded after the named savepoint,
    /// undoing their effects on the store. The savepoint itself is kept
    /// (SQL semantics: ROLLBACK TO does not release the savepoint).
    /// Any savepoints created after this one are discarded.
    pub fn rollbackToSavepoint(self: *UndoLog, name: []const u8, store: *graph_store.GraphStore) !void {
        if (!self.active) return error.NoActiveTransaction;

        // Find the savepoint
        var sp_idx: ?usize = null;
        for (self.savepoints.items, 0..) |sp, idx| {
            if (std.mem.eql(u8, sp.name, name)) {
                sp_idx = idx;
                break;
            }
        }
        const idx = sp_idx orelse return error.SavepointNotFound;
        const target_entry_index = self.savepoints.items[idx].entry_index;

        // Undo entries in reverse order from current end back to the savepoint position
        var i: usize = self.entries.items.len;
        while (i > target_entry_index) {
            i -= 1;
            const entry = self.entries.items[i];
            try self.undoEntry(store, entry);
        }

        // Free memory for undone entries and shrink the list
        self.freeEntriesFrom(target_entry_index);
        self.entries.shrinkRetainingCapacity(target_entry_index);

        // Remove savepoints created after this one
        var j: usize = self.savepoints.items.len;
        while (j > idx + 1) {
            j -= 1;
            self.allocator.free(self.savepoints.items[j].name);
        }
        self.savepoints.shrinkRetainingCapacity(idx + 1);
    }

    /// Free allocated memory in entries from index `from` to end.
    fn freeEntriesFrom(self: *UndoLog, from: usize) void {
        for (self.entries.items[from..]) |entry| {
            switch (entry) {
                .SetNodeProperty => |e| {
                    self.allocator.free(e.key);
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    if (e.old_value.binary_value) |b| self.allocator.free(b);
                    self.allocator.free(e.old_value.key);
                },
                .RemoveNodeProperty => |e| {
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    if (e.old_value.binary_value) |b| self.allocator.free(b);
                    self.allocator.free(e.old_value.key);
                },
                .SetEdgeProperty => |e| {
                    self.allocator.free(e.key);
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    if (e.old_value.binary_value) |b| self.allocator.free(b);
                    self.allocator.free(e.old_value.key);
                },
                .RemoveEdgeProperty => |e| {
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    if (e.old_value.binary_value) |b| self.allocator.free(b);
                    self.allocator.free(e.old_value.key);
                },
                .DeleteNode => |e| {
                    for (e.labels) |label| self.allocator.free(label);
                    self.allocator.free(e.labels);
                    for (e.properties) |prop| {
                        self.allocator.free(prop.key);
                        if (prop.string_value) |s| self.allocator.free(s);
                        if (prop.binary_value) |b| self.allocator.free(b);
                    }
                    self.allocator.free(e.properties);
                    self.allocator.free(e.graph_name);
                },
                .DeleteEdge => |e| {
                    self.allocator.free(e.label);
                    for (e.properties) |prop| {
                        self.allocator.free(prop.key);
                        if (prop.string_value) |s| self.allocator.free(s);
                        if (prop.binary_value) |b| self.allocator.free(b);
                    }
                    self.allocator.free(e.properties);
                    self.allocator.free(e.graph_name);
                },
                .AddNodeLabel => |e| {
                    self.allocator.free(e.label);
                },
                .RemoveNodeLabel => |e| {
                    self.allocator.free(e.label);
                },
                .CreateNode => |e| {
                    self.allocator.free(e.graph_name);
                },
                .CreateEdge => |e| {
                    self.allocator.free(e.graph_name);
                },
            }
        }
    }

    /// Log creation of a node (undo = delete it)
    pub fn logCreateNode(self: *UndoLog, node_id: u64, graph_name: ?[]const u8) !void {
        if (!self.active) return;
        const gname = graph_name orelse "default";
        try self.entries.append(self.allocator, .{ .CreateNode = .{
            .node_id = node_id,
            .graph_name = try self.allocator.dupe(u8, gname),
        } });
    }

    /// Log creation of an edge (undo = delete it)
    pub fn logCreateEdge(self: *UndoLog, edge_id: u64, graph_name: ?[]const u8) !void {
        if (!self.active) return;
        const gname = graph_name orelse "default";
        try self.entries.append(self.allocator, .{ .CreateEdge = .{
            .edge_id = edge_id,
            .graph_name = try self.allocator.dupe(u8, gname),
        } });
    }

    /// Log setting a node property (undo = restore old value or remove)
    pub fn logSetNodeProperty(self: *UndoLog, node_id: u64, key: []const u8, old_value: ?graph_store.PropertyValue) !void {
        if (!self.active) return;
        const key_copy = try self.allocator.dupe(u8, key);
        const serialized = if (old_value) |ov|
            try SerializedProperty.fromPropertyValue(self.allocator, key, ov)
        else
            SerializedProperty{ .key = try self.allocator.dupe(u8, key), .value_type = 0 };

        try self.entries.append(self.allocator, .{ .SetNodeProperty = .{
            .node_id = node_id,
            .key = key_copy,
            .had_old_value = old_value != null,
            .old_value = serialized,
        } });
    }

    /// Log removing a node property (undo = restore it)
    pub fn logRemoveNodeProperty(self: *UndoLog, node_id: u64, old_value: graph_store.PropertyValue, key: []const u8) !void {
        if (!self.active) return;
        const sp = try SerializedProperty.fromPropertyValue(self.allocator, key, old_value);
        try self.entries.append(self.allocator, .{ .RemoveNodeProperty = .{
            .node_id = node_id,
            .old_value = sp,
        } });
    }

    /// Log deletion of a node (undo = recreate it)
    pub fn logDeleteNode(self: *UndoLog, node: graph_store.Node) !void {
        if (!self.active) return;

        // Copy labels
        const labels = try self.allocator.alloc([]const u8, node.labels.len);
        for (node.labels, 0..) |label, i| {
            labels[i] = try self.allocator.dupe(u8, label);
        }

        // Copy properties
        var props: std.ArrayListUnmanaged(SerializedProperty) = .{};
        var prop_iter = node.properties.iterator();
        while (prop_iter.next()) |entry| {
            const sp = try SerializedProperty.fromPropertyValue(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            try props.append(self.allocator, sp);
        }

        try self.entries.append(self.allocator, .{ .DeleteNode = .{
            .node_id = node.id,
            .labels = labels,
            .properties = try props.toOwnedSlice(self.allocator),
            .graph_name = try self.allocator.dupe(u8, node.graph_name),
        } });
    }

    /// Log deletion of an edge (undo = recreate it)
    pub fn logDeleteEdge(self: *UndoLog, edge: graph_store.Edge) !void {
        if (!self.active) return;

        // Copy properties
        var props: std.ArrayListUnmanaged(SerializedProperty) = .{};
        var prop_iter = edge.properties.iterator();
        while (prop_iter.next()) |entry| {
            const sp = try SerializedProperty.fromPropertyValue(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            try props.append(self.allocator, sp);
        }

        try self.entries.append(self.allocator, .{ .DeleteEdge = .{
            .edge_id = edge.id,
            .from_id = edge.from_id,
            .to_id = edge.to_id,
            .label = try self.allocator.dupe(u8, edge.label),
            .properties = try props.toOwnedSlice(self.allocator),
            .graph_name = try self.allocator.dupe(u8, edge.graph_name),
        } });
    }

    /// Log adding a label to a node (undo = remove it)
    pub fn logAddNodeLabel(self: *UndoLog, node_id: u64, label: []const u8) !void {
        if (!self.active) return;
        try self.entries.append(self.allocator, .{ .AddNodeLabel = .{
            .node_id = node_id,
            .label = try self.allocator.dupe(u8, label),
        } });
    }

    /// Log removing a label from a node (undo = add it back)
    pub fn logRemoveNodeLabel(self: *UndoLog, node_id: u64, label: []const u8) !void {
        if (!self.active) return;
        try self.entries.append(self.allocator, .{ .RemoveNodeLabel = .{
            .node_id = node_id,
            .label = try self.allocator.dupe(u8, label),
        } });
    }

    /// Rollback all changes by replaying undo entries in reverse order
    pub fn rollback(self: *UndoLog, store: *graph_store.GraphStore) !void {
        if (!self.active) return;
        graph_store.setMutationNotifyInhibit(true);
        defer graph_store.setMutationNotifyInhibit(false);

        // Process entries in reverse order
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            try self.undoEntry(store, entry);
        }

        self.clear();
        self.active = false;
    }

    // CANARY: REQ=REQ-TXN-UNDO-SERVER-015; FEATURE="TransactionUndoLog"; ASPECT=RollbackGraphStore; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    /// Rollback all changes using GraphStore (for server-side execution)
    /// The storage parameter is kept for API compatibility but each entry looks up its own graph
    pub fn rollbackGraphStore(self: *UndoLog, storage: *graph_common.GraphStore) void {
        _ = storage; // Kept for API compatibility, but we look up per-entry graph
        if (!self.active) return;
        graph_store.setMutationNotifyInhibit(true);
        defer graph_store.setMutationNotifyInhibit(false);

        // Process entries in reverse order
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            self.undoEntryGraphStore(entry);
        }

        self.clear();
        self.active = false;
    }

    fn undoEntryGraphStore(self: *UndoLog, entry: UndoEntry) void {
        const store = graph_store.getGlobalStore(self.allocator);
        self.undoEntry(store, entry) catch |err| {
            std.log.err("rollbackGraphStore failed: {}", .{err});
        };
    }

    fn undoEntry(self: *UndoLog, store: *graph_store.GraphStore, entry: UndoEntry) !void {
        _ = self;
        switch (entry) {
            .CreateNode => |e| {
                // Undo: delete the created node (full delete propagates to adapter)
                store.deleteNode(e.node_id);
            },
            .CreateEdge => |e| {
                // Undo: delete the created edge (full delete propagates to adapter)
                store.deleteEdge(e.edge_id);
            },
            .SetNodeProperty => |e| {
                // Undo: restore old value or remove property
                if (e.had_old_value) {
                    const pv = try e.old_value.toPropertyValue(store.allocator);
                    defer property_codec.freePropertyValue(store.allocator, pv);
                    try store.setNodePropertyNoSave(e.node_id, e.key, pv);
                } else {
                    store.removeNodePropertyNoSave(e.node_id, e.key);
                }
            },
            .RemoveNodeProperty => |e| {
                // Undo: restore the removed property
                const pv = try e.old_value.toPropertyValue(store.allocator);
                defer property_codec.freePropertyValue(store.allocator, pv);
                try store.setNodePropertyNoSave(e.node_id, e.old_value.key, pv);
            },
            .SetEdgeProperty => |e| {
                // Undo: restore old value or remove property
                if (e.had_old_value) {
                    const pv = try e.old_value.toPropertyValue(store.allocator);
                    defer property_codec.freePropertyValue(store.allocator, pv);
                    try store.setEdgePropertyNoSave(e.edge_id, e.key, pv);
                } else {
                    store.removeEdgePropertyNoSave(e.edge_id, e.key);
                }
            },
            .RemoveEdgeProperty => |e| {
                // Undo: restore the removed property
                const pv = try e.old_value.toPropertyValue(store.allocator);
                defer property_codec.freePropertyValue(store.allocator, pv);
                try store.setEdgePropertyNoSave(e.edge_id, e.old_value.key, pv);
            },
            .DeleteNode => |e| {
                // Undo: recreate the node
                try store.restoreNodeNoSave(e.node_id, e.labels, e.graph_name);
                for (e.properties) |prop| {
                    const pv = try prop.toPropertyValue(store.allocator);
                    defer property_codec.freePropertyValue(store.allocator, pv);
                    try store.setNodePropertyNoSave(e.node_id, prop.key, pv);
                }
            },
            .DeleteEdge => |e| {
                // Undo: recreate the edge
                try store.restoreEdgeNoSave(e.edge_id, e.from_id, e.to_id, e.label, e.graph_name);
                for (e.properties) |prop| {
                    const pv = try prop.toPropertyValue(store.allocator);
                    defer property_codec.freePropertyValue(store.allocator, pv);
                    try store.setEdgePropertyNoSave(e.edge_id, prop.key, pv);
                }
            },
            .AddNodeLabel => |e| {
                // Undo: remove the added label
                try store.removeNodeLabelNoSave(e.node_id, e.label);
            },
            .RemoveNodeLabel => |e| {
                // Undo: add the removed label back
                try store.addNodeLabelNoSave(e.node_id, e.label);
            },
        }
    }
};

// Global undo log instance for CLI mode
var global_undo_log: ?UndoLog = null;

pub fn getGlobalUndoLog(allocator: std.mem.Allocator) *UndoLog {
    if (global_undo_log == null) {
        global_undo_log = UndoLog.init(allocator);
    }
    return &global_undo_log.?;
}

/// File-based persistence for undo log (to survive across CLI invocations)
fn getUndoLogFilePath(allocator: std.mem.Allocator) ![]const u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("GEODE_DATA_DIR")) |data_dir| {
        return try std.fmt.allocPrint(allocator, "{s}/geode_undo_log.bin", .{data_dir});
    }
    return try allocator.dupe(u8, "/tmp/geode_undo_log.bin");
}

/// Save undo log to disk for persistence across CLI invocations
pub fn saveUndoLog(allocator: std.mem.Allocator, log: *UndoLog) !void {
    if (!log.active or log.entries.items.len == 0) {
        // No active transaction or no entries, clear the file
        try clearUndoLogFile(allocator);
        return;
    }

    const file_path = try getUndoLogFilePath(allocator);
    defer allocator.free(file_path);

    const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
    defer file.close();

    // Write number of entries
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, log.entries.items.len, .little);
    _ = try file.write(&count_buf);

    // Write each entry (simplified binary format)
    for (log.entries.items) |entry| {
        try writeUndoEntry(file, entry);
    }
}

fn writeU32(file: std.Io.File, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    _ = try file.write(&buf);
}

fn writeU64(file: std.Io.File, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    _ = try file.write(&buf);
}

fn writeI64(file: std.Io.File, value: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, value, .little);
    _ = try file.write(&buf);
}

fn writeI128(file: std.Io.File, value: i128) !void {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i128, &buf, value, .little);
    _ = try file.write(&buf);
}

fn writeF64(file: std.Io.File, value: f64) !void {
    const bits: u64 = @bitCast(value);
    try writeU64(file, bits);
}

fn writeBool(file: std.Io.File, value: bool) !void {
    const byte: u8 = if (value) 1 else 0;
    _ = try file.write(&[_]u8{byte});
}

fn writeString(file: std.Io.File, value: []const u8) !void {
    try writeU32(file, @intCast(value.len));
    _ = try file.write(value);
}

fn writeSerializedProperty(file: std.Io.File, prop: SerializedProperty) !void {
    try writeString(file, prop.key);
    _ = try file.write(&[_]u8{prop.value_type});
    switch (prop.value_type) {
        0 => {},
        1 => try writeString(file, prop.string_value orelse ""),
        2 => try writeI64(file, prop.int_value),
        3 => try writeF64(file, prop.float_value),
        4 => try writeBool(file, prop.bool_value),
        5 => try writeString(file, prop.binary_value orelse ""),
        else => {},
    }
}

fn writeUndoEntry(file: std.Io.File, entry: UndoEntry) !void {
    // Write entry type
    const entry_type: u8 = @intFromEnum(std.meta.activeTag(entry));
    _ = try file.write(&[_]u8{entry_type});

    switch (entry) {
        .CreateNode => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.graph_name);
        },
        .CreateEdge => |e| {
            try writeU64(file, e.edge_id);
            try writeString(file, e.graph_name);
        },
        .SetNodeProperty => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.key);
            try writeBool(file, e.had_old_value);
            try writeSerializedProperty(file, e.old_value);
        },
        .RemoveNodeProperty => |e| {
            try writeU64(file, e.node_id);
            try writeSerializedProperty(file, e.old_value);
        },
        .SetEdgeProperty => |e| {
            try writeU64(file, e.edge_id);
            try writeString(file, e.key);
            try writeBool(file, e.had_old_value);
            try writeSerializedProperty(file, e.old_value);
        },
        .RemoveEdgeProperty => |e| {
            try writeU64(file, e.edge_id);
            try writeSerializedProperty(file, e.old_value);
        },
        .DeleteNode => |e| {
            try writeU64(file, e.node_id);
            try writeU32(file, @intCast(e.labels.len));
            for (e.labels) |label| {
                try writeString(file, label);
            }
            try writeU32(file, @intCast(e.properties.len));
            for (e.properties) |prop| {
                try writeSerializedProperty(file, prop);
            }
            try writeString(file, e.graph_name);
        },
        .DeleteEdge => |e| {
            try writeU64(file, e.edge_id);
            try writeU64(file, e.from_id);
            try writeU64(file, e.to_id);
            try writeString(file, e.label);
            try writeU32(file, @intCast(e.properties.len));
            for (e.properties) |prop| {
                try writeSerializedProperty(file, prop);
            }
            try writeString(file, e.graph_name);
        },
        .AddNodeLabel => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.label);
        },
        .RemoveNodeLabel => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.label);
        },
    }
}

/// Load undo log from disk
pub fn loadUndoLog(allocator: std.mem.Allocator) !?*UndoLog {
    const file_path = try getUndoLogFilePath(allocator);
    defer allocator.free(file_path);

    const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    var log = getGlobalUndoLog(allocator);
    log.active = true;
    log.clear();

    // Read number of entries
    var count_buf: [8]u8 = undefined;
    _ = try file.read(&count_buf);
    const count = std.mem.readInt(u64, &count_buf, .little);

    // Read entries
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const entry = try readUndoEntry(allocator, file);
        if (entry) |e| {
            try log.entries.append(allocator, e);
        }
    }

    return log;
}

fn readU32(file: std.Io.File) !u32 {
    var buf: [4]u8 = undefined;
    if ((try file.readAll(&buf)) < buf.len) return error.UnexpectedEndOfFile;
    return std.mem.readInt(u32, &buf, .little);
}

fn readU64(file: std.Io.File) !u64 {
    var buf: [8]u8 = undefined;
    if ((try file.readAll(&buf)) < buf.len) return error.UnexpectedEndOfFile;
    return std.mem.readInt(u64, &buf, .little);
}

fn readI64(file: std.Io.File) !i64 {
    var buf: [8]u8 = undefined;
    if ((try file.readAll(&buf)) < buf.len) return error.UnexpectedEndOfFile;
    return std.mem.readInt(i64, &buf, .little);
}

fn readI128(file: std.Io.File) !i128 {
    var buf: [16]u8 = undefined;
    if ((try file.readAll(&buf)) < buf.len) return error.UnexpectedEndOfFile;
    return std.mem.readInt(i128, &buf, .little);
}

fn readF64(file: std.Io.File) !f64 {
    const bits = try readU64(file);
    return @bitCast(bits);
}

fn readBool(file: std.Io.File) !bool {
    var buf: [1]u8 = undefined;
    if ((try file.readAll(&buf)) < buf.len) return error.UnexpectedEndOfFile;
    return buf[0] != 0;
}

fn readString(allocator: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const len = try readU32(file);
    const buf = try allocator.alloc(u8, len);
    if ((try file.readAll(buf)) < len) return error.UnexpectedEndOfFile;
    return buf;
}

fn readSerializedProperty(allocator: std.mem.Allocator, file: std.Io.File) !SerializedProperty {
    const key = try readString(allocator, file);
    var type_buf: [1]u8 = undefined;
    if ((try file.readAll(&type_buf)) < type_buf.len) return error.UnexpectedEndOfFile;
    const value_type = type_buf[0];
    var prop = SerializedProperty{ .key = key, .value_type = value_type };
    switch (value_type) {
        0 => {},
        1 => {
            prop.string_value = try readString(allocator, file);
        },
        2 => {
            prop.int_value = try readI64(file);
        },
        3 => {
            prop.float_value = try readF64(file);
        },
        4 => {
            prop.bool_value = try readBool(file);
        },
        5 => {
            prop.binary_value = try readString(allocator, file);
        },
        else => {},
    }
    return prop;
}

fn readUndoEntry(allocator: std.mem.Allocator, file: std.Io.File) !?UndoEntry {
    var type_buf: [1]u8 = undefined;
    const bytes_read = try file.readAll(&type_buf);
    if (bytes_read == 0) return null;
    if (bytes_read < type_buf.len) return error.UnexpectedEndOfFile;

    const entry_type: UndoOpType = @enumFromInt(type_buf[0]);

    switch (entry_type) {
        .CreateNode => {
            const node_id = try readU64(file);
            const graph_name = try readString(allocator, file);
            return .{ .CreateNode = .{ .node_id = node_id, .graph_name = graph_name } };
        },
        .CreateEdge => {
            const edge_id = try readU64(file);
            const graph_name = try readString(allocator, file);
            return .{ .CreateEdge = .{ .edge_id = edge_id, .graph_name = graph_name } };
        },
        .SetNodeProperty => {
            const node_id = try readU64(file);
            const key = try readString(allocator, file);
            const had_old_value = try readBool(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .SetNodeProperty = .{
                .node_id = node_id,
                .key = key,
                .had_old_value = had_old_value,
                .old_value = old_value,
            } };
        },
        .RemoveNodeProperty => {
            const node_id = try readU64(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .RemoveNodeProperty = .{
                .node_id = node_id,
                .old_value = old_value,
            } };
        },
        .SetEdgeProperty => {
            const edge_id = try readU64(file);
            const key = try readString(allocator, file);
            const had_old_value = try readBool(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .SetEdgeProperty = .{
                .edge_id = edge_id,
                .key = key,
                .had_old_value = had_old_value,
                .old_value = old_value,
            } };
        },
        .RemoveEdgeProperty => {
            const edge_id = try readU64(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .RemoveEdgeProperty = .{
                .edge_id = edge_id,
                .old_value = old_value,
            } };
        },
        .DeleteNode => {
            const node_id = try readU64(file);
            const label_count = try readU32(file);
            const labels = try allocator.alloc([]const u8, label_count);
            for (labels, 0..) |*slot, idx| {
                _ = idx;
                slot.* = try readString(allocator, file);
            }
            const prop_count = try readU32(file);
            const props = try allocator.alloc(SerializedProperty, prop_count);
            for (props, 0..) |*slot, idx| {
                _ = idx;
                slot.* = try readSerializedProperty(allocator, file);
            }
            const graph_name = try readString(allocator, file);
            return .{ .DeleteNode = .{
                .node_id = node_id,
                .labels = labels,
                .properties = props,
                .graph_name = graph_name,
            } };
        },
        .DeleteEdge => {
            const edge_id = try readU64(file);
            const from_id = try readU64(file);
            const to_id = try readU64(file);
            const label = try readString(allocator, file);
            const prop_count = try readU32(file);
            const props = try allocator.alloc(SerializedProperty, prop_count);
            for (props, 0..) |*slot, idx| {
                _ = idx;
                slot.* = try readSerializedProperty(allocator, file);
            }
            const graph_name = try readString(allocator, file);
            return .{ .DeleteEdge = .{
                .edge_id = edge_id,
                .from_id = from_id,
                .to_id = to_id,
                .label = label,
                .properties = props,
                .graph_name = graph_name,
            } };
        },
        .AddNodeLabel => {
            const node_id = try readU64(file);
            const label = try readString(allocator, file);
            return .{ .AddNodeLabel = .{ .node_id = node_id, .label = label } };
        },
        .RemoveNodeLabel => {
            const node_id = try readU64(file);
            const label = try readString(allocator, file);
            return .{ .RemoveNodeLabel = .{ .node_id = node_id, .label = label } };
        },
    }
}

/// Clear the undo log file
pub fn clearUndoLogFile(allocator: std.mem.Allocator) !void {
    const file_path = try getUndoLogFilePath(allocator);
    defer allocator.free(file_path);
    std.Io.Dir.cwd().deleteFile(file_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

test "basic undo log operations" {
    const allocator = std.testing.allocator;
    var log = UndoLog.init(allocator);
    defer log.deinit();

    // Not active, should not log
    try log.logCreateNode(1, null);
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);

    // Begin transaction
    log.begin();
    try std.testing.expect(log.active);

    // Log operations
    try log.logCreateNode(1, null);
    try log.logCreateNode(2, null);
    try log.logCreateEdge(100, null);

    try std.testing.expectEqual(@as(usize, 3), log.entries.items.len);

    // Commit clears the log
    log.commit(null);
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
    try std.testing.expect(!log.active);
}

test "undo log persistence roundtrip for complex entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "undo.bin", .{ .read = true, .truncate = true });
    defer file.close();

    const labels = [_][]const u8{ "Person", "Active" };
    const props = [_]SerializedProperty{
        .{ .key = "name", .value_type = 1, .string_value = "Ada" },
        .{ .key = "age", .value_type = 2, .int_value = 42 },
    };

    const entry1 = UndoEntry{ .SetNodeProperty = .{
        .node_id = 1,
        .key = "name",
        .had_old_value = true,
        .old_value = props[0],
    } };
    const entry2 = UndoEntry{ .DeleteNode = .{
        .node_id = 7,
        .labels = labels[0..],
        .properties = props[0..],
        .graph_name = "g",
    } };
    const entry3 = UndoEntry{ .DeleteEdge = .{
        .edge_id = 9,
        .from_id = 1,
        .to_id = 2,
        .label = "KNOWS",
        .properties = props[1..2],
        .graph_name = "g",
    } };
    const entry4 = UndoEntry{ .AddNodeLabel = .{
        .node_id = 3,
        .label = "VIP",
    } };

    try writeUndoEntry(file, entry1);
    try writeUndoEntry(file, entry2);
    try writeUndoEntry(file, entry3);
    try writeUndoEntry(file, entry4);

    try file.seekTo(0);

    var log = UndoLog.init(allocator);
    defer log.deinit();

    const r1 = (try readUndoEntry(allocator, file)).?;
    try log.entries.append(allocator, r1);
    switch (r1) {
        .SetNodeProperty => |e| {
            try std.testing.expectEqual(@as(u64, 1), e.node_id);
            try std.testing.expectEqualStrings("name", e.key);
            try std.testing.expect(e.had_old_value);
            try std.testing.expectEqual(@as(u8, 1), e.old_value.value_type);
            try std.testing.expectEqualStrings("Ada", e.old_value.string_value.?);
        },
        else => try std.testing.expect(false),
    }

    const r2 = (try readUndoEntry(allocator, file)).?;
    try log.entries.append(allocator, r2);
    switch (r2) {
        .DeleteNode => |e| {
            try std.testing.expectEqual(@as(u64, 7), e.node_id);
            try std.testing.expectEqual(@as(usize, 2), e.labels.len);
            try std.testing.expectEqualStrings("Person", e.labels[0]);
            try std.testing.expectEqualStrings("Active", e.labels[1]);
            try std.testing.expectEqual(@as(usize, 2), e.properties.len);
            try std.testing.expectEqualStrings("name", e.properties[0].key);
            try std.testing.expectEqualStrings("g", e.graph_name);
        },
        else => try std.testing.expect(false),
    }

    const r3 = (try readUndoEntry(allocator, file)).?;
    try log.entries.append(allocator, r3);
    switch (r3) {
        .DeleteEdge => |e| {
            try std.testing.expectEqual(@as(u64, 9), e.edge_id);
            try std.testing.expectEqualStrings("KNOWS", e.label);
            try std.testing.expectEqual(@as(usize, 1), e.properties.len);
        },
        else => try std.testing.expect(false),
    }

    const r4 = (try readUndoEntry(allocator, file)).?;
    try log.entries.append(allocator, r4);
    switch (r4) {
        .AddNodeLabel => |e| {
            try std.testing.expectEqual(@as(u64, 3), e.node_id);
            try std.testing.expectEqualStrings("VIP", e.label);
        },
        else => try std.testing.expect(false),
    }
}

test "savepoint create and rollback to savepoint" {
    const allocator = std.testing.allocator;
    var undo = UndoLog.init(allocator);
    defer undo.deinit();

    // Cannot create savepoint outside transaction
    try std.testing.expectError(error.NoActiveTransaction, undo.createSavepoint("sp1"));

    undo.begin();
    try std.testing.expect(undo.active);

    // Log two operations, then create a savepoint
    try undo.logCreateNode(1, null);
    try undo.logCreateNode(2, null);
    try std.testing.expectEqual(@as(usize, 2), undo.entries.items.len);

    try undo.createSavepoint("sp1");
    try std.testing.expectEqual(@as(usize, 1), undo.savepoints.items.len);
    try std.testing.expectEqual(@as(usize, 2), undo.savepoints.items[0].entry_index);

    // Log two more operations after the savepoint
    try undo.logCreateNode(3, null);
    try undo.logCreateNode(4, null);
    try std.testing.expectEqual(@as(usize, 4), undo.entries.items.len);

    // Rollback to savepoint should undo entries after sp1 (entries 3 and 4)
    // Note: rollbackToSavepoint needs a store, but the CreateNode undo (delete)
    // will fail because there is no actual store. For unit testing purposes
    // we test the entry/savepoint bookkeeping by using a second savepoint.
    try undo.createSavepoint("sp2");
    try std.testing.expectEqual(@as(usize, 2), undo.savepoints.items.len);
    try std.testing.expectEqual(@as(usize, 4), undo.savepoints.items[1].entry_index);

    // Replacing an existing savepoint updates its index
    try undo.logCreateNode(5, null);
    try undo.createSavepoint("sp2");
    try std.testing.expectEqual(@as(usize, 2), undo.savepoints.items.len);
    try std.testing.expectEqual(@as(usize, 5), undo.savepoints.items[1].entry_index);

    // Commit clears savepoints
    undo.commit(null);
    try std.testing.expectEqual(@as(usize, 0), undo.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), undo.savepoints.items.len);
    try std.testing.expect(!undo.active);
}

test "savepoint not found error" {
    const allocator = std.testing.allocator;
    var undo = UndoLog.init(allocator);
    defer undo.deinit();

    undo.begin();
    try undo.createSavepoint("sp1");

    // Rollback to non-existent savepoint should fail
    // We need a dummy store for the API; since no entries exist after the
    // savepoint, no actual undo work is done.
    // However rollbackToSavepoint requires a *GraphStore which we cannot
    // easily construct in a unit test without initializing the full engine.
    // Instead we test that the error is returned for a missing name.
    try std.testing.expectError(error.SavepointNotFound, undo.rollbackToSavepoint("nonexistent", dummy_store_ptr));
    undo.commit(null);
}

const dummy_store_ptr = @as(*graph_store.GraphStore, @ptrFromInt(std.mem.alignForward(usize, 0xdeadbeef, @alignOf(graph_store.GraphStore))));

test "begin clears savepoints from previous transaction" {
    const allocator = std.testing.allocator;
    var undo = UndoLog.init(allocator);
    defer undo.deinit();

    undo.begin();
    try undo.createSavepoint("sp1");
    try std.testing.expectEqual(@as(usize, 1), undo.savepoints.items.len);

    // Begin a new transaction — should clear previous savepoints
    undo.begin();
    try std.testing.expectEqual(@as(usize, 0), undo.savepoints.items.len);
    undo.commit(null);
}

test "SerializedProperty round-trips decimal and ext values" {
    const allocator = std.testing.allocator;

    const decimal = try SerializedProperty.fromPropertyValue(
        allocator,
        "price",
        .{ .Decimal = .{ .coeff = 123456, .scale = 3 } },
    );
    defer decimal.deinit(allocator);

    const decimal_value = try decimal.toPropertyValue(allocator);
    try std.testing.expect(decimal_value == .Decimal);
    try std.testing.expectEqual(@as(i128, 123456), decimal_value.Decimal.coeff);
    try std.testing.expectEqual(@as(u8, 3), decimal_value.Decimal.scale);

    const nested = try allocator.dupe(u8, "ext");
    const list_slice = try allocator.dupe(@import("eval_extended.zig").ExtValue, &.{
        .{ .Int = 9 },
        .{ .Str = nested },
    });
    const ext_prop = SerializedProperty.fromPropertyValue(
        allocator,
        "payload",
        .{ .ExtValue = .{ .List = list_slice } },
    ) catch |err| {
        allocator.free(nested);
        allocator.free(list_slice);
        return err;
    };
    defer ext_prop.deinit(allocator);
    // Free input allocations — fromPropertyValue copies what it needs
    allocator.free(nested);
    allocator.free(list_slice);

    const ext_value = try ext_prop.toPropertyValue(allocator);
    defer graph_store.freeDetachedPropertyValue(allocator, ext_value);
    try std.testing.expect(ext_value == .ExtValue);
    try std.testing.expectEqual(@as(usize, 2), ext_value.ExtValue.List.len);
    try std.testing.expectEqual(@as(i64, 9), ext_value.ExtValue.List[0].Int);
    try std.testing.expectEqualStrings("ext", ext_value.ExtValue.List[1].Str);
}
