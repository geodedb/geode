const std = @import("std");
const graph_store = @import("graph_store.zig");
// CANARY: REQ=REQ-TXN-UNDO-SERVER-014; FEATURE="TransactionUndoLog"; ASPECT=GraphCommonImport; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
const graph_common = @import("types/graph_common.zig");

// CANARY: REQ=REQ-TXN-UNDO-001; FEATURE="TransactionUndoLog"; ASPECT=UndoLogCore; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
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
    value_type: u8, // 0=null, 1=string, 2=int, 3=float, 4=bool
    string_value: ?[]const u8 = null,
    int_value: i64 = 0,
    float_value: f64 = 0.0,
    bool_value: bool = false,

    pub fn fromPropertyValue(key: []const u8, pv: graph_store.PropertyValue) SerializedProperty {
        return switch (pv) {
            .Null => .{ .key = key, .value_type = 0 },
            .String => |s| .{ .key = key, .value_type = 1, .string_value = s },
            .Int => |i| .{ .key = key, .value_type = 2, .int_value = i },
            .Float => |f| .{ .key = key, .value_type = 3, .float_value = f },
            .Bool => |b| .{ .key = key, .value_type = 4, .bool_value = b },
            .ExtValue => .{ .key = key, .value_type = 0 }, // Treat ExtValue as null for now
        };
    }

    pub fn toPropertyValue(self: SerializedProperty) graph_store.PropertyValue {
        return switch (self.value_type) {
            0 => .Null,
            1 => .{ .String = self.string_value orelse "" },
            2 => .{ .Int = self.int_value },
            3 => .{ .Float = self.float_value },
            4 => .{ .Bool = self.bool_value },
            else => .Null,
        };
    }
};

pub const UndoEntry = union(UndoOpType) {
    // On rollback: delete this node
    CreateNode: struct {
        node_id: u64,
    },

    // On rollback: delete this edge
    CreateEdge: struct {
        edge_id: u64,
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
        properties: []SerializedProperty,
        graph_name: []const u8,
    },

    // On rollback: recreate the edge with its data
    DeleteEdge: struct {
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        label: []const u8,
        properties: []SerializedProperty,
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

/// Transaction undo log that persists across CLI invocations
pub const UndoLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(UndoEntry),
    active: bool,

    pub fn init(allocator: std.mem.Allocator) UndoLog {
        return .{
            .allocator = allocator,
            .entries = .{},
            .active = false,
        };
    }

    pub fn deinit(self: *UndoLog) void {
        self.clear();
        self.entries.deinit(self.allocator);
    }

    pub fn clear(self: *UndoLog) void {
        // Free any allocated memory in entries
        for (self.entries.items) |entry| {
            switch (entry) {
                .SetNodeProperty => |e| {
                    self.allocator.free(e.key);
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    self.allocator.free(e.old_value.key);
                },
                .RemoveNodeProperty => |e| {
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    self.allocator.free(e.old_value.key);
                },
                .SetEdgeProperty => |e| {
                    self.allocator.free(e.key);
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    self.allocator.free(e.old_value.key);
                },
                .RemoveEdgeProperty => |e| {
                    if (e.old_value.string_value) |s| self.allocator.free(s);
                    self.allocator.free(e.old_value.key);
                },
                .DeleteNode => |e| {
                    for (e.labels) |label| self.allocator.free(label);
                    self.allocator.free(e.labels);
                    for (e.properties) |prop| {
                        self.allocator.free(prop.key);
                        if (prop.string_value) |s| self.allocator.free(s);
                    }
                    self.allocator.free(e.properties);
                    self.allocator.free(e.graph_name);
                },
                .DeleteEdge => |e| {
                    self.allocator.free(e.label);
                    for (e.properties) |prop| {
                        self.allocator.free(prop.key);
                        if (prop.string_value) |s| self.allocator.free(s);
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
                .CreateNode, .CreateEdge => {},
            }
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn begin(self: *UndoLog) void {
        self.clear();
        self.active = true;
    }

    pub fn commit(self: *UndoLog) void {
        self.clear();
        self.active = false;
    }

    /// Log creation of a node (undo = delete it)
    pub fn logCreateNode(self: *UndoLog, node_id: u64) !void {
        if (!self.active) return;
        try self.entries.append(self.allocator, .{ .CreateNode = .{ .node_id = node_id } });
    }

    /// Log creation of an edge (undo = delete it)
    pub fn logCreateEdge(self: *UndoLog, edge_id: u64) !void {
        if (!self.active) return;
        try self.entries.append(self.allocator, .{ .CreateEdge = .{ .edge_id = edge_id } });
    }

    /// Log setting a node property (undo = restore old value or remove)
    pub fn logSetNodeProperty(self: *UndoLog, node_id: u64, key: []const u8, old_value: ?graph_store.PropertyValue) !void {
        if (!self.active) return;
        const key_copy = try self.allocator.dupe(u8, key);
        const serialized = if (old_value) |ov|
            blk: {
                var sp = SerializedProperty.fromPropertyValue(key, ov);
                sp.key = try self.allocator.dupe(u8, sp.key);
                if (sp.string_value) |s| {
                    sp.string_value = try self.allocator.dupe(u8, s);
                }
                break :blk sp;
            }
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
        var sp = SerializedProperty.fromPropertyValue(key, old_value);
        sp.key = try self.allocator.dupe(u8, sp.key);
        if (sp.string_value) |s| {
            sp.string_value = try self.allocator.dupe(u8, s);
        }
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
            var sp = SerializedProperty.fromPropertyValue(entry.key_ptr.*, entry.value_ptr.*);
            sp.key = try self.allocator.dupe(u8, sp.key);
            if (sp.string_value) |s| {
                sp.string_value = try self.allocator.dupe(u8, s);
            }
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
            var sp = SerializedProperty.fromPropertyValue(entry.key_ptr.*, entry.value_ptr.*);
            sp.key = try self.allocator.dupe(u8, sp.key);
            if (sp.string_value) |s| {
                sp.string_value = try self.allocator.dupe(u8, s);
            }
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

    // CANARY: REQ=REQ-TXN-UNDO-SERVER-015; FEATURE="TransactionUndoLog"; ASPECT=RollbackGraphStorage; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
    /// Rollback all changes using GraphStorage (for server-side execution)
    pub fn rollbackGraphStorage(self: *UndoLog, storage: *graph_common.GraphStorage) void {
        if (!self.active) return;

        // Process entries in reverse order
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            self.undoEntryGraphStorage(storage, entry);
        }

        self.clear();
        self.active = false;
    }

    fn undoEntryGraphStorage(self: *UndoLog, storage: *graph_common.GraphStorage, entry: UndoEntry) void {
        _ = self;
        switch (entry) {
            .CreateNode => |e| {
                // Undo: delete the created node
                storage.removeNode(e.node_id);
            },
            .CreateEdge => |e| {
                // Undo: delete the created edge
                storage.removeEdge(e.edge_id);
            },
            // Other entry types are not commonly used in server mode for now
            // They can be implemented later if needed
            else => {},
        }
    }

    fn undoEntry(self: *UndoLog, store: *graph_store.GraphStore, entry: UndoEntry) !void {
        _ = self;
        switch (entry) {
            .CreateNode => |e| {
                // Undo: delete the created node
                store.deleteNodeNoSave(e.node_id);
            },
            .CreateEdge => |e| {
                // Undo: delete the created edge
                store.deleteEdgeNoSave(e.edge_id);
            },
            .SetNodeProperty => |e| {
                // Undo: restore old value or remove property
                if (e.had_old_value) {
                    const pv = e.old_value.toPropertyValue();
                    try store.setNodePropertyNoSave(e.node_id, e.key, pv);
                } else {
                    store.removeNodePropertyNoSave(e.node_id, e.key);
                }
            },
            .RemoveNodeProperty => |e| {
                // Undo: restore the removed property
                const pv = e.old_value.toPropertyValue();
                try store.setNodePropertyNoSave(e.node_id, e.old_value.key, pv);
            },
            .SetEdgeProperty => |e| {
                // Undo: restore old value or remove property
                if (e.had_old_value) {
                    const pv = e.old_value.toPropertyValue();
                    try store.setEdgePropertyNoSave(e.edge_id, e.key, pv);
                } else {
                    store.removeEdgePropertyNoSave(e.edge_id, e.key);
                }
            },
            .RemoveEdgeProperty => |e| {
                // Undo: restore the removed property
                const pv = e.old_value.toPropertyValue();
                try store.setEdgePropertyNoSave(e.edge_id, e.old_value.key, pv);
            },
            .DeleteNode => |e| {
                // Undo: recreate the node
                try store.restoreNodeNoSave(e.node_id, e.labels, e.graph_name);
                for (e.properties) |prop| {
                    const pv = prop.toPropertyValue();
                    try store.setNodePropertyNoSave(e.node_id, prop.key, pv);
                }
            },
            .DeleteEdge => |e| {
                // Undo: recreate the edge
                try store.restoreEdgeNoSave(e.edge_id, e.from_id, e.to_id, e.label, e.graph_name);
                for (e.properties) |prop| {
                    const pv = prop.toPropertyValue();
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

    const file = try std.fs.cwd().createFile(file_path, .{});
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

fn writeUndoEntry(file: std.fs.File, entry: UndoEntry) !void {
    // Write entry type
    const entry_type: u8 = @intFromEnum(std.meta.activeTag(entry));
    _ = try file.write(&[_]u8{entry_type});

    switch (entry) {
        .CreateNode => |e| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, e.node_id, .little);
            _ = try file.write(&buf);
        },
        .CreateEdge => |e| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, e.edge_id, .little);
            _ = try file.write(&buf);
        },
        else => {
            // For complex entries, we'll use a simplified approach
            // In a production system, you'd serialize all fields
        },
    }
}

/// Load undo log from disk
pub fn loadUndoLog(allocator: std.mem.Allocator) !?*UndoLog {
    const file_path = try getUndoLogFilePath(allocator);
    defer allocator.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
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

fn readUndoEntry(allocator: std.mem.Allocator, file: std.fs.File) !?UndoEntry {
    _ = allocator;
    var type_buf: [1]u8 = undefined;
    const bytes_read = try file.read(&type_buf);
    if (bytes_read == 0) return null;

    const entry_type: UndoOpType = @enumFromInt(type_buf[0]);

    switch (entry_type) {
        .CreateNode => {
            var buf: [8]u8 = undefined;
            _ = try file.read(&buf);
            const node_id = std.mem.readInt(u64, &buf, .little);
            return .{ .CreateNode = .{ .node_id = node_id } };
        },
        .CreateEdge => {
            var buf: [8]u8 = undefined;
            _ = try file.read(&buf);
            const edge_id = std.mem.readInt(u64, &buf, .little);
            return .{ .CreateEdge = .{ .edge_id = edge_id } };
        },
        else => {
            // For complex entries, skip for now
            return null;
        },
    }
}

/// Clear the undo log file
pub fn clearUndoLogFile(allocator: std.mem.Allocator) !void {
    const file_path = try getUndoLogFilePath(allocator);
    defer allocator.free(file_path);
    std.fs.cwd().deleteFile(file_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

test "basic undo log operations" {
    const allocator = std.testing.allocator;
    var log = UndoLog.init(allocator);
    defer log.deinit();

    // Not active, should not log
    try log.logCreateNode(1);
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);

    // Begin transaction
    log.begin();
    try std.testing.expect(log.active);

    // Log operations
    try log.logCreateNode(1);
    try log.logCreateNode(2);
    try log.logCreateEdge(100);

    try std.testing.expectEqual(@as(usize, 3), log.entries.items.len);

    // Commit clears the log
    log.commit();
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
    try std.testing.expect(!log.active);
}
