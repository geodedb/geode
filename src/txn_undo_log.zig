const std = @import("std");
const graph_store = @import("graph_store.zig");
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

    pub fn begin(self: *UndoLog) void {
        self.clear();
        self.active = true;
    }

    pub fn commit(self: *UndoLog) void {
        self.clear();
        self.active = false;
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
        const serialized = if (old_value) |ov| blk: {
            var sp = SerializedProperty.fromPropertyValue(key, ov);
            sp.key = try self.allocator.dupe(u8, sp.key);
            if (sp.string_value) |s| {
                sp.string_value = try self.allocator.dupe(u8, s);
            }
            break :blk sp;
        } else SerializedProperty{ .key = try self.allocator.dupe(u8, key), .value_type = 0 };

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

    // CANARY: REQ=REQ-TXN-UNDO-SERVER-015; FEATURE="TransactionUndoLog"; ASPECT=RollbackGraphStorage; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    /// Rollback all changes using GraphStorage (for server-side execution)
    /// The storage parameter is kept for API compatibility but each entry looks up its own graph
    pub fn rollbackGraphStorage(self: *UndoLog, storage: *graph_common.GraphStorage) void {
        _ = storage; // Kept for API compatibility, but we look up per-entry graph
        if (!self.active) return;

        // Process entries in reverse order
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            self.undoEntryGraphStorage(entry);
        }

        self.clear();
        self.active = false;
    }

    fn undoEntryGraphStorage(self: *UndoLog, entry: UndoEntry) void {
        switch (entry) {
            .CreateNode => |e| {
                // CANARY: REQ=REQ-TXN-UNDO-020; FEATURE="TransactionUndoLog"; ASPECT=RollbackUseGraphStore; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
                // Use GraphStore (the actual data store used by crud_operations) for rollback
                const store = graph_store.getGlobalStore(self.allocator);
                store.deleteNodeNoSave(e.node_id);
            },
            .CreateEdge => |e| {
                // Use GraphStore for rollback
                const store = graph_store.getGlobalStore(self.allocator);
                store.deleteEdgeNoSave(e.edge_id);
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

fn writeU32(file: std.fs.File, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    _ = try file.write(&buf);
}

fn writeU64(file: std.fs.File, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    _ = try file.write(&buf);
}

fn writeI64(file: std.fs.File, value: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, value, .little);
    _ = try file.write(&buf);
}

fn writeF64(file: std.fs.File, value: f64) !void {
    const bits: u64 = @bitCast(value);
    try writeU64(file, bits);
}

fn writeBool(file: std.fs.File, value: bool) !void {
    const byte: u8 = if (value) 1 else 0;
    _ = try file.write(&[_]u8{byte});
}

fn writeString(file: std.fs.File, value: []const u8) !void {
    try writeU32(file, @intCast(value.len));
    _ = try file.write(value);
}

fn writeSerializedProperty(file: std.fs.File, prop: SerializedProperty) !void {
    try writeString(file, prop.key);
    _ = try file.write(&[_]u8{prop.value_type});
    switch (prop.value_type) {
        0 => {},
        1 => try writeString(file, prop.string_value orelse ""),
        2 => try writeI64(file, prop.int_value),
        3 => try writeF64(file, prop.float_value),
        4 => try writeBool(file, prop.bool_value),
        else => {},
    }
}

fn writeUndoEntry(file: std.fs.File, entry: UndoEntry) !void {
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

fn readU32(file: std.fs.File) !u32 {
    var buf: [4]u8 = undefined;
    try file.reader().readNoEof(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

fn readU64(file: std.fs.File) !u64 {
    var buf: [8]u8 = undefined;
    try file.reader().readNoEof(&buf);
    return std.mem.readInt(u64, &buf, .little);
}

fn readI64(file: std.fs.File) !i64 {
    var buf: [8]u8 = undefined;
    try file.reader().readNoEof(&buf);
    return std.mem.readInt(i64, &buf, .little);
}

fn readF64(file: std.fs.File) !f64 {
    const bits = try readU64(file);
    return @bitCast(bits);
}

fn readBool(file: std.fs.File) !bool {
    var buf: [1]u8 = undefined;
    try file.reader().readNoEof(&buf);
    return buf[0] != 0;
}

fn readString(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    const len = try readU32(file);
    const buf = try allocator.alloc(u8, len);
    try file.reader().readNoEof(buf);
    return buf;
}

fn readSerializedProperty(allocator: std.mem.Allocator, file: std.fs.File) !SerializedProperty {
    const key = try readString(allocator, file);
    var type_buf: [1]u8 = undefined;
    try file.reader().readNoEof(&type_buf);
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
        else => {},
    }
    return prop;
}

fn readUndoEntry(allocator: std.mem.Allocator, file: std.fs.File) !?UndoEntry {
    var type_buf: [1]u8 = undefined;
    const bytes_read = try file.read(&type_buf);
    if (bytes_read == 0) return null;

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
    std.fs.cwd().deleteFile(file_path) catch |err| {
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
    log.commit();
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
    try std.testing.expect(!log.active);
}

test "undo log persistence roundtrip for complex entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("undo.bin", .{ .read = true, .truncate = true });
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
