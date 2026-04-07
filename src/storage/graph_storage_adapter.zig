// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Graph Storage Adapter — bridges the graph-storage engine library to geode's
//! execution engine.
//!
//! Manages one `GraphEngine` instance per named graph and provides the methods
//! that geode's execution engine calls.

const std = @import("std");
const gs = @import("graph_storage");
const uuid = @import("uuid");
const graph_store = @import("../graph_store.zig");
const property_codec = @import("../property_value_codec.zig");
const audit = @import("../security/audit.zig");
const ts_mod = @import("timeseries_lib");
const fulltext = @import("../index/fulltext.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.graph_storage_adapter);

// Re-export edge type for callers that need EdgeEntry from scan results.
pub const EdgeEntry = gs.edge.EdgeEntry;

const LabelScanContext = struct {
    mg: *ManagedGraph,
    label_id: gs.LabelId,
};

// ============================================================================
// LabelStringDict — bidirectional label string ↔ LabelId mapping view
// ============================================================================

pub const LabelStringDict = struct {
    allocator: ?Allocator,
    backing: union(enum) {
        local: LocalState,
        external: *gs.label_dict.LabelDictionary,
    },

    const LocalState = struct {
        str_to_id: std.StringHashMap(gs.LabelId),
        id_to_str: std.AutoHashMap(gs.LabelId, []const u8),
        next_id: gs.LabelId,
    };

    pub fn init(allocator: Allocator) LabelStringDict {
        return .{
            .allocator = allocator,
            .backing = .{
                .local = .{
                    .str_to_id = std.StringHashMap(gs.LabelId).init(allocator),
                    .id_to_str = std.AutoHashMap(gs.LabelId, []const u8).init(allocator),
                    .next_id = 1,
                },
            },
        };
    }

    pub fn initView(dict: *gs.label_dict.LabelDictionary) LabelStringDict {
        return .{
            .allocator = null,
            .backing = .{ .external = dict },
        };
    }

    pub fn deinit(self: *LabelStringDict) void {
        switch (self.backing) {
            .local => |*local| {
                const allocator = self.allocator orelse return;
                var it = local.str_to_id.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                local.str_to_id.deinit();
                local.id_to_str.deinit();
            },
            .external => {},
        }
    }

    /// Return the LabelId for `label`, assigning a new one if this is the
    /// first time the label has been seen.
    pub fn getOrCreate(self: *LabelStringDict, label: []const u8) !gs.LabelId {
        switch (self.backing) {
            .local => |*local| {
                const allocator = self.allocator orelse return error.OutOfMemory;
                if (local.str_to_id.get(label)) |id| {
                    return id;
                }

                const id = local.next_id;
                local.next_id += 1;

                const owned = try allocator.dupe(u8, label);
                errdefer allocator.free(owned);

                try local.str_to_id.put(owned, id);
                errdefer _ = local.str_to_id.remove(owned);

                try local.id_to_str.put(id, owned);
                return id;
            },
            .external => |dict| return dict.getOrAssign(label),
        }
    }

    /// Reverse lookup: LabelId → string. Returns null when the id is unknown.
    pub fn getString(self: *const LabelStringDict, id: gs.LabelId) ?[]const u8 {
        return switch (self.backing) {
            .local => |local| local.id_to_str.get(id),
            .external => |dict| dict.getName(id),
        };
    }

    /// Forward lookup: string → LabelId. Returns null when the label is unknown.
    pub fn getId(self: *const LabelStringDict, label: []const u8) ?gs.LabelId {
        return switch (self.backing) {
            .local => |local| local.str_to_id.get(label),
            .external => |dict| dict.getId(label),
        };
    }

    /// Number of labels currently tracked.
    pub fn count(self: *const LabelStringDict) u32 {
        return switch (self.backing) {
            .local => |local| @intCast(local.str_to_id.count()),
            .external => |dict| dict.count(),
        };
    }
};

// ============================================================================
// Property Value Translation
// ============================================================================

/// Convert a geode `PropertyValue` to a graph-storage `PropertyValue`.
///
/// String data is passed through as a slice reference (no copy). The caller
/// must ensure the source value outlives the returned storage value.
pub fn toStorageProperty(allocator: Allocator, val: graph_store.PropertyValue) !gs.PropertyValue {
    return switch (val) {
        .String => |s| .{ .string = s },
        .Int => |i| .{ .int = i },
        .Float => |f| .{ .float = f },
        .Bool => |b| .{ .bool = b },
        .Null => .null,
        .Decimal => |d| .{ .decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ExtValue => blk: {
            const encoded = try property_codec.encodePropertyValue(allocator, val);
            errdefer allocator.free(encoded);
            const type_tag = if (encoded.len > 0) encoded[0] else 0;
            const payload = if (encoded.len > 1) try allocator.dupe(u8, encoded[1..]) else try allocator.dupe(u8, "");
            allocator.free(encoded);
            break :blk .{ .ext = .{ .type_tag = type_tag, .data = payload } };
        },
    };
}

/// Convert a graph-storage `PropertyValue` to a geode `PropertyValue`.
///
/// String data is duplicated into `allocator` so the returned value is
/// independently owned.
pub fn fromStorageProperty(allocator: Allocator, val: gs.PropertyValue) !graph_store.PropertyValue {
    return switch (val) {
        .string => |s| .{ .String = try allocator.dupe(u8, s) },
        .int => |i| .{ .Int = i },
        .float => |f| .{ .Float = f },
        .bool => |b| .{ .Bool = b },
        .null => .Null,
        .decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ext => |ext| blk: {
            const encoded_len = ext.data.len + 1;
            const encoded = try allocator.alloc(u8, encoded_len);
            encoded[0] = @intCast(ext.type_tag & 0xFF);
            @memcpy(encoded[1..], ext.data);
            defer allocator.free(encoded);
            break :blk try property_codec.decodePropertyValue(allocator, encoded);
        },
    };
}

fn freeTemporaryStorageProperty(allocator: Allocator, val: gs.PropertyValue) void {
    switch (val) {
        .ext => |ext| allocator.free(ext.data),
        else => {},
    }
}

pub fn freeOwnedStorageProperty(allocator: Allocator, val: gs.PropertyValue) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .ext => |ext| allocator.free(ext.data),
        else => {},
    }
}

fn shouldExposePropertyKey(key: []const u8) bool {
    return !std.mem.eql(u8, key, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY) and
        !std.mem.eql(u8, key, graph_store.INTERNAL_EDGE_ID_PROPERTY_KEY);
}

// ============================================================================
// ManagedGraph — one engine instance + its label dictionary
// ============================================================================

/// Wraps a single `GraphEngine` together with its label dictionary and
/// metadata.  Owned by (and keyed inside) the `StorageAdapter`.
pub const ManagedGraph = struct {
    engine: *gs.GraphEngine,
    label_dict: LabelStringDict,
    name: []const u8, // owned
    uuid: [16]u8,
    /// Per-graph audit logger writing to `{graph_dir}/audit.jsonl`.
    /// May be null if audit init failed (soft failure — graph still usable).
    audit_logger: ?*audit.AuditLogger = null,
    /// Per-graph timeseries store persisting to `{graph_dir}/timeseries/`.
    /// May be null if timeseries init failed (soft failure — graph still usable).
    ts_store: ?*ts_mod.Store = null,
    /// Per-graph full-text search index persisting to `{graph_dir}/fts/`.
    /// May be null if FTS init failed (soft failure — graph still usable).
    fts_index: ?*fulltext.FullTextIndex = null,
    /// Owned path to the FTS subdirectory (needed for saveToDisk on close).
    fts_dir: ?[]const u8 = null,
    /// Per-graph RwLock for concurrent read access. Queries acquire shared;
    /// mutations and persistence acquire exclusive. Part of P1 lock migration.
    rwlock: std.Thread.RwLock = .{},

    /// Obtain the vtable-based `GraphStorage` interface for direct low-level
    /// access to the engine.
    pub fn storage(self: *ManagedGraph) gs.GraphStorage {
        return gs.GraphStorage.init(gs.GraphEngine, self.engine);
    }

    fn deinit(self: *ManagedGraph, allocator: Allocator) void {
        if (self.fts_index) |fts| {
            if (self.fts_dir) |dir| {
                fts.saveToDisk(dir) catch |err| {
                    log.warn("failed to persist per-graph FTS index: {}", .{err});
                };
            }
            fts.deinit();
            allocator.destroy(fts);
            self.fts_index = null;
        }
        if (self.fts_dir) |dir| {
            allocator.free(dir);
            self.fts_dir = null;
        }
        if (self.ts_store) |tss| {
            tss.deinit();
            allocator.destroy(tss);
            self.ts_store = null;
        }
        if (self.audit_logger) |al| {
            al.deinit();
            allocator.destroy(al);
            self.audit_logger = null;
        }
        self.engine.close() catch {};
        self.label_dict.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

// ============================================================================
// StorageAdapter — top-level adapter managing multiple named graphs
// ============================================================================

pub const StorageAdapter = struct {
    allocator: Allocator,
    data_dir: []const u8, // owned
    engines: std.StringHashMap(*ManagedGraph),
    default_engine: ?*ManagedGraph,
    config: gs.GraphConfig,
    registry: gs.registry.GraphRegistry,
    registry_path: []const u8, // owned
    mutex: std.Thread.Mutex,

    /// Create a new `StorageAdapter`.
    ///
    /// `data_dir` is the root directory under which per-graph subdirectories
    /// are created (each at `{data_dir}/graphs/{uuid_hex}/`).
    pub fn init(allocator: Allocator, data_dir: []const u8, config: gs.GraphConfig) !*StorageAdapter {
        const owned_dir = try allocator.dupe(u8, data_dir);
        errdefer allocator.free(owned_dir);

        // Ensure the graphs root directory exists.
        const graphs_dir = try std.fmt.allocPrint(allocator, "{s}/graphs", .{owned_dir});
        defer allocator.free(graphs_dir);
        std.fs.cwd().makePath(graphs_dir) catch |err| {
            log.err("failed to create graphs directory {s}: {}", .{ graphs_dir, err });
            return err;
        };

        const self = try allocator.create(StorageAdapter);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .data_dir = owned_dir,
            .engines = std.StringHashMap(*ManagedGraph).init(allocator),
            .default_engine = null,
            .config = config,
            .registry = gs.registry.GraphRegistry.init(allocator),
            .registry_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{owned_dir}),
            .mutex = .{},
        };
        errdefer self.registry.deinit();
        errdefer allocator.free(self.registry_path);

        self.loadRegistry() catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("failed to load graph registry {s}: {}", .{ self.registry_path, err }),
        };

        return self;
    }

    /// Shut down all engines, release every allocation.
    pub fn deinit(self: *StorageAdapter) void {
        self.mutex.lock();

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.engines.deinit();
        self.default_engine = null;

        self.registry.deinit();
        self.allocator.free(self.registry_path);
        self.allocator.free(self.data_dir);
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    /// Return the `ManagedGraph` for `name`, creating a new `GraphEngine` if
    /// the graph has not been opened yet.
    pub fn getOrCreateGraph(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.engines.get(name)) |mg| {
            return mg;
        }

        if (self.findRegistryEntryLocked(name)) |entry| {
            return self.openGraphLocked(name, entry.uuid);
        }

        return self.createGraphLocked(name);
    }

    /// Open an existing graph by name and UUID. Uses `GraphEngine.open()` to
    /// recover the persisted on-disk data directory.
    pub fn openGraphWithUuid(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8) !*ManagedGraph {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.engines.get(name)) |mg| {
            return mg;
        }

        return self.openGraphLocked(name, graph_uuid);
    }

    /// Return the stored UUID for a loaded graph, or null if not loaded.
    pub fn getGraphUuid(self: *StorageAdapter, name: []const u8) ?[16]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.engines.get(name)) |mg| {
            return mg.uuid;
        }
        if (self.findRegistryEntryLocked(name)) |entry| {
            return entry.uuid;
        }
        return null;
    }

    /// Return the per-graph audit logger for `name`, or null if the graph
    /// does not exist or audit was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getAuditLogger(self: *StorageAdapter, name: []const u8) ?*audit.AuditLogger {
        self.mutex.lock();
        const mg = self.engines.get(name);
        self.mutex.unlock();

        return if (mg) |m| m.audit_logger else null;
    }

    /// Return the per-graph timeseries store for `name`, or null if the graph
    /// does not exist or timeseries was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getTimeseriesStore(self: *StorageAdapter, name: []const u8) ?*ts_mod.Store {
        self.mutex.lock();
        const mg = self.engines.get(name);
        self.mutex.unlock();

        return if (mg) |m| m.ts_store else null;
    }

    /// Return the per-graph full-text search index for `name`, or null if the
    /// graph does not exist or FTS was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getFulltextIndex(self: *StorageAdapter, name: []const u8) ?*fulltext.FullTextIndex {
        self.mutex.lock();
        const mg = self.engines.get(name);
        self.mutex.unlock();

        return if (mg) |m| m.fts_index else null;
    }

    /// Check whether a graph with the given name exists either in memory or in
    /// the persisted registry.
    pub fn graphExists(self: *StorageAdapter, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.engines.contains(name) or self.findRegistryEntryLocked(name) != null;
    }

    /// Close and remove the graph identified by `name`.
    pub fn dropGraph(self: *StorageAdapter, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var dropped_uuid: ?[16]u8 = null;
        if (self.engines.fetchRemove(name)) |kv| {
            const mg = kv.value;

            // Clear default_engine if it pointed to the dropped graph.
            if (self.default_engine == mg) {
                self.default_engine = null;
            }

            dropped_uuid = mg.uuid;
            mg.deinit(self.allocator);
        } else if (self.findRegistryEntryLocked(name)) |entry| {
            dropped_uuid = entry.uuid;
        }

        if (self.registry.removeGraph(name)) {
            self.saveRegistryLocked() catch |err| {
                log.warn("failed to persist graph registry after drop of '{s}': {}", .{ name, err });
            };
        }

        if (dropped_uuid) |graph_uuid| {
            var graph_dir = gs.graph_dir.GraphDir.open(self.allocator, self.data_dir, graph_uuid) catch return;
            defer graph_dir.deinit();

            graph_dir.delete() catch |err| {
                log.warn("failed to delete graph directory for '{s}': {}", .{ name, err });
            };
        }
    }

    /// Return the names of all known graphs. Caller owns the returned slice and
    /// each name string inside it.
    pub fn listGraphNames(self: *StorageAdapter, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var names = std.ArrayList([]const u8){};
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }

        var seen = std.StringHashMap(void).init(allocator);
        defer {
            var seen_it = seen.iterator();
            while (seen_it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            seen.deinit();
        }

        for (self.registry.entries.items) |entry| {
            const seen_key = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(seen_key);
            const seen_result = try seen.getOrPut(seen_key);
            if (!seen_result.found_existing) {
                try names.append(allocator, try allocator.dupe(u8, entry.name));
            } else {
                allocator.free(seen_key);
            }
        }

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            const seen_key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(seen_key);
            const seen_result = try seen.getOrPut(seen_key);
            if (!seen_result.found_existing) {
                try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            } else {
                allocator.free(seen_key);
            }
        }

        return names.toOwnedSlice(allocator);
    }

    /// Return the default graph, creating one named "default" if none exists.
    pub fn getDefaultGraph(self: *StorageAdapter) !*ManagedGraph {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.default_engine) |mg| {
            return mg;
        }

        const mg = if (self.engines.get("default")) |existing|
            existing
        else if (self.findRegistryEntryLocked("default")) |entry|
            try self.openGraphLocked("default", entry.uuid)
        else
            try self.createGraphLocked("default");

        self.default_engine = mg;
        return mg;
    }

    // ------------------------------------------------------------------
    // Node CRUD
    // ------------------------------------------------------------------

    /// Create a node with the given string labels in the named graph.
    /// The graph is created on-demand if it does not exist. Returns the
    /// new node ID.
    pub fn createNode(self: *StorageAdapter, graph_name: []const u8, labels: []const []const u8) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        const node_id = try mg.engine.allocNode();

        // Write an initial node record.  The txn_stamp must be non-zero so
        // that getNode() does not treat the slot as empty (isEmpty checks all
        // fields == 0).  Using 1 as a sentinel "created" stamp.
        const rec = gs.node.NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };
        try mg.engine.putNode(node_id, rec);

        // Attach each label via the engine (updates label blocks in var.store
        // and the label index).
        for (labels) |lbl| {
            const label_id = try mg.label_dict.getOrCreate(lbl);
            try mg.engine.addLabel(node_id, label_id);
        }

        return node_id;
    }

    /// Delete a node by ID in the named graph.
    pub fn deleteNode(self: *StorageAdapter, graph_name: []const u8, node_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        try mg.engine.deleteNode(node_id);
    }

    /// Retrieve the string labels for a node. Caller owns the returned
    /// slice and must free both the slice and each string inside it.
    pub fn getNodeLabels(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        // Retrieve label IDs from the engine's LabelStore (variable-length
        // label blocks stored in var.store).
        const label_ids = try mg.engine.label_store.getLabels(rec.label_head, allocator);
        defer allocator.free(label_ids);

        var result: std.ArrayList([]const u8) = .{};
        errdefer {
            for (result.items) |s| allocator.free(s);
            result.deinit(allocator);
        }

        for (label_ids) |label_id| {
            if (mg.label_dict.getString(label_id)) |name| {
                try result.append(allocator, try allocator.dupe(u8, name));
            }
        }

        return result.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Edge CRUD
    // ------------------------------------------------------------------

    /// Create an edge between two nodes. Returns the edge ID.
    pub fn createEdge(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, label: []const u8) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        const rel_type = try mg.label_dict.getOrCreate(label);
        return mg.engine.addEdge(from_id, to_id, rel_type);
    }

    /// Delete an edge by its endpoints and edge ID.
    pub fn deleteEdge(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        try mg.engine.removeEdge(from_id, to_id, edge_id);
    }

    /// Iterate all outgoing edges from a node without materializing them.
    pub fn iterateOutgoingEdges(
        self: *StorageAdapter,
        graph_name: []const u8,
        node_id: u64,
        allocator: Allocator,
    ) !gs.interface.EdgeIterator {
        const mg = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.storage().expandOut(node_id, null, allocator);
    }

    /// Iterate all incoming edges to a node without materializing them.
    pub fn iterateIncomingEdges(
        self: *StorageAdapter,
        graph_name: []const u8,
        node_id: u64,
        allocator: Allocator,
    ) !gs.interface.EdgeIterator {
        const mg = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.storage().expandIn(node_id, null, allocator);
    }

    /// Get all outgoing edges from a node.
    /// Returns a caller-owned slice built from the engine's edge iterator.
    pub fn getOutgoingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
        var result = std.ArrayList(gs.edge.EdgeEntry).empty;
        errdefer result.deinit(allocator);

        var iter = try self.iterateOutgoingEdges(graph_name, node_id, allocator);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            try result.append(allocator, entry);
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Get all incoming edges to a node.
    /// Returns a caller-owned slice built from the engine's edge iterator.
    pub fn getIncomingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
        var result = std.ArrayList(gs.edge.EdgeEntry).empty;
        errdefer result.deinit(allocator);

        var iter = try self.iterateIncomingEdges(graph_name, node_id, allocator);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            try result.append(allocator, entry);
        }

        return try result.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Property operations
    // ------------------------------------------------------------------

    /// Set a property on a node. The value is converted from a geode
    /// `PropertyValue` to the storage engine's representation.
    ///
    /// The engine's `putProperty` returns a (potentially new) `prop_head`
    /// that must be written back to the node record.
    pub fn setNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, value: graph_store.PropertyValue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        const storage_val = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_val);
        const new_prop_head = try mg.engine.putProperty(rec.prop_head, key, storage_val);

        // Update the node record with the (possibly changed) prop_head.
        rec.prop_head = new_prop_head;
        try mg.engine.putNode(node_id, rec);
    }

    /// Batch property entry: a key with either a value to set or null to remove.
    pub const BatchPropertyEntry = struct {
        key: []const u8,
        value: ?graph_store.PropertyValue, // null means remove (tombstone)
    };

    /// Set or remove multiple properties on a node under a single mutex
    /// acquisition.  This avoids the per-property lock/unlock overhead of
    /// calling `setNodeProperty` / `removeNodeProperty` in a loop, which
    /// can cause severe mutex contention when the server is concurrently
    /// servicing queries against the same StorageAdapter.
    pub fn setNodePropertiesBatch(self: *StorageAdapter, graph_name: []const u8, node_id: u64, entries: []const BatchPropertyEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        for (entries) |entry| {
            if (entry.value) |val| {
                const storage_val = try toStorageProperty(self.allocator, val);
                defer freeTemporaryStorageProperty(self.allocator, storage_val);
                const new_prop_head = try mg.engine.putProperty(rec.prop_head, entry.key, storage_val);
                rec.prop_head = new_prop_head;
            } else {
                const new_prop_head = try mg.engine.putProperty(rec.prop_head, entry.key, .null);
                rec.prop_head = new_prop_head;
            }
        }

        // Write the node record once after all property mutations.
        try mg.engine.putNode(node_id, rec);
    }

    /// Remove a property from a node by writing a null tombstone.
    pub fn removeNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        const new_prop_head = try mg.engine.putProperty(rec.prop_head, key, .null);
        rec.prop_head = new_prop_head;
        try mg.engine.putNode(node_id, rec);
    }

    /// Get a property from a node, returned in graph-storage representation.
    pub fn getNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, allocator: Allocator) !?gs.PropertyValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        if (rec.prop_head == 0) return null;
        return mg.engine.getProperty(rec.prop_head, key, allocator);
    }

    /// Find all node IDs with the given label in a graph.
    /// Filters out deleted nodes whose slot IDs are still present in the
    /// label index (the engine's deleteNode sets NODE_FLAG_DELETED but does
    /// not remove the entry from the label posting list).
    pub fn getNodesByLabel(self: *StorageAdapter, graph_name: []const u8, label: []const u8, allocator: Allocator) ![]u64 {
        // Brief mutex hold: look up ManagedGraph and label ID, then release.
        // The ManagedGraph is stable while the caller holds the per-graph
        // rwlock, so the expensive scan below does not need the adapter mutex.
        // Holding mutex during the scan caused ABBA deadlocks with concurrent
        // ingest (QUIC handler: rwlock → mutex; ingest: mutex → rwlock).
        const mg, const label_id = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const mg = try self.requireExistingGraphLocked(graph_name);
            const lid = mg.label_dict.getId(label) orelse return try allocator.alloc(u64, 0);
            break :blk .{ mg, lid };
        };
        const raw_ids = try mg.engine.scanLabel(label_id, allocator);

        // Filter out deleted/empty nodes whose slot IDs are still present
        // in the label index.  We read raw page bytes via the buffer pool
        // and check the record flags directly — this avoids engine.getNode()
        // which conflates "empty" and "deleted" into a single null return,
        // and whose null-based filtering caused regressions in prior attempts.
        const node_mod = gs.node;
        const NodeRec = node_mod.NodeRec;
        const npp = mg.engine.node_store.nodes_per_page;
        const hdr_size = gs.node.PAGE_HEADER_SIZE;
        var live_count: usize = 0;
        for (raw_ids) |nid| {
            const page_id = nid / npp;
            // Page not allocated → node cannot be live (stale index entry)
            if (!mg.engine.node_store.free_space.isAllocated(page_id)) continue;

            const slot: u32 = @intCast(nid % npp);
            const slot_offset = hdr_size + slot * @sizeOf(NodeRec);
            const frame = try mg.engine.node_store.buffer_pool.pin(.nodes, page_id);
            const data = frame.dataSlice();
            const rec = std.mem.bytesToValue(NodeRec, data[slot_offset..][0..@sizeOf(NodeRec)]);
            mg.engine.node_store.buffer_pool.unpin(
                mg.engine.node_store.buffer_pool.frameIndex(frame),
                false,
            );

            if (node_mod.isDeleted(&rec)) continue;
            if (node_mod.isEmpty(&rec)) continue;

            raw_ids[live_count] = nid;
            live_count += 1;
        }

        if (live_count == raw_ids.len) return raw_ids;

        // Shrink the allocation to only the live IDs.
        if (live_count == 0) {
            allocator.free(raw_ids);
            return try allocator.alloc(u64, 0);
        }
        // realloc in-place when possible; the live IDs are already packed
        // at the front of raw_ids.
        if (allocator.resize(raw_ids, live_count)) {
            return raw_ids[0..live_count];
        }
        // Fallback: allocate a new slice and copy.
        const result = try allocator.alloc(u64, live_count);
        @memcpy(result, raw_ids[0..live_count]);
        allocator.free(raw_ids);
        return result;
    }

    // ------------------------------------------------------------------
    // Edge property operations
    // ------------------------------------------------------------------

    /// Set a property on an edge. Delegates to the engine's
    /// `setEdgeProperty` which handles prop_head updates in both
    /// adjacency lists automatically.
    pub fn setEdgeProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        from_id: u64,
        to_id: u64,
        edge_id: u64,
        key: []const u8,
        value: graph_store.PropertyValue,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        const storage_val = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_val);
        try mg.engine.setEdgeProperty(from_id, to_id, edge_id, key, storage_val);
    }

    /// Get a property from an edge. Delegates to the engine's
    /// `getEdgeProperty` which handles adjacency list scanning internally.
    pub fn getEdgeProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        from_id: u64,
        edge_id: u64,
        key: []const u8,
        allocator: Allocator,
    ) !?gs.PropertyValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        return mg.engine.getEdgeProperty(from_id, edge_id, key, allocator);
    }

    // ------------------------------------------------------------------
    // Full node scanning
    // ------------------------------------------------------------------

    /// A single entry from a full node scan.
    pub const ScanEntry = struct {
        slot_id: u64,
        rec: gs.node.NodeRec,
    };

    /// Scan all live nodes in the named graph. Returns a caller-owned
    /// slice of `ScanEntry` values. Uses the engine's efficient
    /// page-scan iterator (one pin per page rather than per node).
    pub fn scanAllNodes(self: *StorageAdapter, graph_name: []const u8, allocator: Allocator) ![]ScanEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);

        const Ctx = struct {
            entries: std.ArrayList(ScanEntry),
            alloc: Allocator,
            had_error: bool = false,

            fn onNode(ctx: *@This(), node_id: u64, rec: gs.node.NodeRec) void {
                ctx.entries.append(ctx.alloc, .{ .slot_id = node_id, .rec = rec }) catch {
                    ctx.had_error = true;
                };
            }
        };

        var ctx = Ctx{ .entries = .{}, .alloc = allocator };
        try mg.engine.node_store.scanNodes(
            mg.engine.manifest.next_node_id,
            &ctx,
            &Ctx.onNode,
        );

        if (ctx.had_error) return error.OutOfMemory;

        return ctx.entries.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Statistics API
    // ------------------------------------------------------------------

    /// Aggregate statistics for a single graph, sourced from the engine
    /// manifest.
    pub const GraphStats = struct {
        node_count: u64,
        edge_count: u64,
        pages_used: u64,
        label_count: u32,
    };

    /// Return manifest-level statistics for the named graph, or null if
    /// the graph is not loaded.
    pub fn getGraphStats(self: *StorageAdapter, graph_name: []const u8) ?GraphStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.requireExistingGraphLocked(graph_name) catch return null;
        const m = &mg.engine.manifest;

        return .{
            .node_count = m.node_count,
            .edge_count = m.edge_count,
            .pages_used = m.nodes_pages +
                m.adj_out_pages +
                m.adj_in_pages +
                m.props_pages +
                m.var_pages +
                m.free_pages,
            .label_count = m.label_count,
        };
    }

    // ------------------------------------------------------------------
    // Property iteration
    // ------------------------------------------------------------------

    /// Return all properties on a node as a hash map. Keys are
    /// heap-allocated copies owned by the map; values are converted
    /// geode `PropertyValue` instances. The caller owns the returned
    /// map and must free each key/value plus the map itself.
    pub fn getAllNodeProperties(
        self: *StorageAdapter,
        graph_name: []const u8,
        node_id: u64,
        allocator: Allocator,
    ) !std.StringHashMap(gs.PropertyValue) {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        var result = std.StringHashMap(gs.PropertyValue).init(allocator);
        errdefer result.deinit();

        if (rec.prop_head == 0) return result;

        // Use the engine's property iterator to walk all key-value pairs.
        // The iterator yields raw PropertyEntrySlice (encoded bytes). We
        // re-fetch each property by key through getProperty, which
        // returns a decoded PropertyValue.
        var iter = try mg.engine.getAllProperties(rec.prop_head);
        defer iter.deinit();

        // Collect keys first (iterator borrows page buffers).
        var keys: std.ArrayList([]const u8) = .{};
        defer {
            for (keys.items) |k| allocator.free(k);
            keys.deinit(allocator);
        }
        while (try iter.next()) |entry| {
            try keys.append(allocator, try allocator.dupe(u8, entry.key));
        }

        // Now fetch each property by key.
        for (keys.items) |key| {
            if (!shouldExposePropertyKey(key)) continue;
            if (try mg.engine.getProperty(rec.prop_head, key, allocator)) |val| {
                // Transfer key ownership into the map.
                const owned_key = try allocator.dupe(u8, key);
                try result.put(owned_key, val);
            }
        }

        return result;
    }

    /// Return all properties for an edge given its `prop_head` pointer.
    /// Works identically to `getAllNodeProperties` but takes a raw
    /// `prop_head` instead of looking up a node record — edge property
    /// heads come directly from the `EdgeEntry` returned by the
    /// adjacency iterator.
    pub fn getAllEdgeProperties(
        self: *StorageAdapter,
        graph_name: []const u8,
        prop_head: u32,
        allocator: Allocator,
    ) !std.StringHashMap(gs.PropertyValue) {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);

        var result = std.StringHashMap(gs.PropertyValue).init(allocator);
        errdefer result.deinit();

        if (prop_head == 0) return result;

        const prop_head_u64: u64 = @intCast(prop_head);

        // Use the engine's property iterator to walk all key-value pairs.
        var iter = try mg.engine.getAllProperties(prop_head_u64);
        defer iter.deinit();

        // Collect keys first (iterator borrows page buffers).
        var keys: std.ArrayList([]const u8) = .{};
        defer {
            for (keys.items) |k| allocator.free(k);
            keys.deinit(allocator);
        }
        while (try iter.next()) |entry| {
            try keys.append(allocator, try allocator.dupe(u8, entry.key));
        }

        // Now fetch each property by key.
        for (keys.items) |key| {
            if (!shouldExposePropertyKey(key)) continue;
            if (try mg.engine.getProperty(prop_head_u64, key, allocator)) |val| {
                const owned_key = try allocator.dupe(u8, key);
                try result.put(owned_key, val);
            }
        }

        return result;
    }

    // ------------------------------------------------------------------
    // Transaction operations
    // ------------------------------------------------------------------

    /// Begin a new transaction in the named graph.
    pub fn beginTransaction(self: *StorageAdapter, graph_name: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        return mg.engine.beginTxn();
    }

    /// Commit a transaction.
    pub fn commitTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        try mg.engine.commitTxn(txn_id);
    }

    /// Abort (rollback) a transaction.
    pub fn abortTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        try mg.engine.abortTxn(txn_id);
    }

    /// Run a checkpoint on every loaded graph engine.
    pub fn checkpointAll(self: *StorageAdapter) !void {
        // Collect ManagedGraph pointers under brief mutex hold.
        var graphs_buf: [64]*ManagedGraph = undefined;
        var graph_count: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.engines.valueIterator();
            while (it.next()) |mg| {
                if (graph_count < graphs_buf.len) {
                    graphs_buf[graph_count] = mg.*;
                    graph_count += 1;
                }
            }
        }

        // Checkpoint each graph WITHOUT holding the adapter mutex.
        // The ManagedGraph pointers remain valid because graphs are only
        // removed via dropGraph which also holds self.mutex.
        for (graphs_buf[0..graph_count]) |mg| {
            mg.engine.checkpoint() catch |err| {
                log.warn("checkpoint failed for graph '{s}': {}", .{ mg.name, err });
            };
        }

        // Re-acquire mutex briefly to sync registry counts and persist.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (graphs_buf[0..graph_count]) |mg| {
                self.syncRegistryCountsLocked(mg);
            }
            self.saveRegistryLocked() catch |err| {
                log.warn("failed to persist graph registry: {}", .{err});
            };
        }
    }

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------

    /// Return the number of nodes in the named graph.
    pub fn nodeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        return mg.engine.nodeCount();
    }

    /// Return the number of edges in the named graph.
    pub fn edgeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        return mg.engine.edgeCount();
    }

    // ------------------------------------------------------------------
    // Internal helpers (must be called with mutex held)
    // ------------------------------------------------------------------

    /// Build the on-disk directory path for a graph: `{data_dir}/graphs/{uuid_hex}`.
    fn graphDirPath(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) ![]const u8 {
        const hex = std.fmt.bytesToHex(graph_uuid, .lower);
        return std.fmt.allocPrint(allocator, "{s}/graphs/{s}", .{
            data_dir,
            &hex,
        });
    }

    /// Attempt to create a per-graph audit logger. Returns null on failure
    /// (soft failure — the graph remains usable without per-graph audit).
    fn initAuditForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) ?*audit.AuditLogger {
        const graph_dir = graphDirPath(allocator, data_dir, graph_uuid) catch |err| {
            log.warn("failed to build graph dir path for audit: {}", .{err});
            return null;
        };
        defer allocator.free(graph_dir);

        const al = allocator.create(audit.AuditLogger) catch |err| {
            log.warn("failed to allocate per-graph audit logger: {}", .{err});
            return null;
        };
        al.* = audit.AuditLogger.initForGraph(allocator, graph_dir) catch |err| {
            log.warn("failed to init per-graph audit logger: {}", .{err});
            allocator.destroy(al);
            return null;
        };
        return al;
    }

    /// Attempt to create a per-graph timeseries store. Returns null on failure
    /// (soft failure — the graph remains usable without per-graph timeseries).
    fn initTimeseriesForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) ?*ts_mod.Store {
        const graph_dir = graphDirPath(allocator, data_dir, graph_uuid) catch |err| {
            log.warn("failed to build graph dir path for timeseries: {}", .{err});
            return null;
        };
        defer allocator.free(graph_dir);

        // Pass the graph directory as the timeseries data_dir.
        // The timeseries library internally appends "/timeseries" to create
        // its subdirectory — do NOT pre-create a timeseries/ subdir here.
        const store = allocator.create(ts_mod.Store) catch |err| {
            log.warn("failed to allocate per-graph timeseries store: {}", .{err});
            return null;
        };
        store.* = ts_mod.Store.initWithConfig(allocator, .{
            .data_dir = graph_dir,
        }) catch |err| {
            log.warn("failed to init per-graph timeseries store: {}", .{err});
            allocator.destroy(store);
            return null;
        };

        store.loadFromDisk() catch |err| {
            log.warn("failed to load per-graph timeseries data from disk: {}", .{err});
            // Store is still usable in-memory, continue with it.
        };

        return store;
    }

    const FtsInitResult = struct {
        index: *fulltext.FullTextIndex,
        dir: []const u8,
    };

    /// Attempt to create or load a per-graph full-text search index.
    /// Returns null on failure (soft failure — the graph remains usable without FTS).
    fn initFtsForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, load_existing: bool) ?FtsInitResult {
        const graph_dir = graphDirPath(allocator, data_dir, graph_uuid) catch |err| {
            log.warn("failed to build graph dir path for FTS: {}", .{err});
            return null;
        };
        defer allocator.free(graph_dir);

        // Build the FTS subdirectory path.
        const fts_dir = std.fmt.allocPrint(allocator, "{s}/fts", .{graph_dir}) catch |err| {
            log.warn("failed to allocate FTS dir path: {}", .{err});
            return null;
        };
        errdefer allocator.free(fts_dir);

        // Ensure the FTS subdirectory exists.
        std.fs.cwd().makePath(fts_dir) catch |err| {
            log.warn("failed to create FTS dir '{s}': {}", .{ fts_dir, err });
            return null;
        };

        const idx = allocator.create(fulltext.FullTextIndex) catch |err| {
            log.warn("failed to allocate per-graph FTS index: {}", .{err});
            return null;
        };
        errdefer allocator.destroy(idx);

        if (load_existing) {
            idx.* = fulltext.FullTextIndex.loadFromDisk(allocator, fts_dir) catch |err| {
                log.warn("failed to load per-graph FTS index from disk: {}", .{err});
                // Fall back to a fresh index.
                idx.* = fulltext.FullTextIndex.init(allocator) catch |err2| {
                    log.warn("failed to init fresh FTS index after load failure: {}", .{err2});
                    allocator.destroy(idx);
                    return null;
                };
                return .{ .index = idx, .dir = fts_dir };
            };
        } else {
            idx.* = fulltext.FullTextIndex.init(allocator) catch |err| {
                log.warn("failed to init per-graph FTS index: {}", .{err});
                allocator.destroy(idx);
                return null;
            };
        }

        return .{ .index = idx, .dir = fts_dir };
    }

    fn createGraphLocked(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
        const graph_uuid = generateUuid();

        var cfg = self.config;
        cfg.data_dir = self.data_dir;

        const engine = gs.GraphEngine.create(
            self.allocator,
            self.data_dir,
            graph_uuid,
            cfg,
        ) catch |err| {
            log.err("failed to create GraphEngine for graph '{s}': {}", .{ name, err });
            return err;
        };
        errdefer engine.close() catch {};

        const mg = try self.allocator.create(ManagedGraph);
        errdefer self.allocator.destroy(mg);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        mg.* = .{
            .engine = engine,
            .label_dict = LabelStringDict.initView(&engine.label_dict),
            .name = owned_name,
            .uuid = graph_uuid,
            .audit_logger = initAuditForGraph(self.allocator, self.data_dir, graph_uuid),
            .ts_store = initTimeseriesForGraph(self.allocator, self.data_dir, graph_uuid),
        };

        // Initialise per-graph FTS (fresh index for new graphs).
        if (initFtsForGraph(self.allocator, self.data_dir, graph_uuid, false)) |fts_result| {
            mg.fts_index = fts_result.index;
            mg.fts_dir = fts_result.dir;
        }

        try self.engines.put(owned_name, mg);
        self.upsertRegistryEntryLocked(name, graph_uuid, 0, 0);
        self.saveRegistryLocked() catch |err| {
            log.warn("failed to persist graph registry after create of '{s}': {}", .{ name, err });
        };

        log.info("created graph '{s}'", .{name});

        return mg;
    }

    /// Open an existing graph engine from a known UUID directory.
    fn openGraphLocked(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8) !*ManagedGraph {
        var cfg = self.config;
        cfg.data_dir = self.data_dir;

        const engine = gs.GraphEngine.open(
            self.allocator,
            self.data_dir,
            graph_uuid,
            cfg,
        ) catch |err| {
            log.err("failed to open GraphEngine for graph '{s}': {}", .{ name, err });
            return err;
        };
        errdefer engine.close() catch {};

        const mg = try self.allocator.create(ManagedGraph);
        errdefer self.allocator.destroy(mg);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        mg.* = .{
            .engine = engine,
            .label_dict = LabelStringDict.initView(&engine.label_dict),
            .name = owned_name,
            .uuid = graph_uuid,
            .audit_logger = initAuditForGraph(self.allocator, self.data_dir, graph_uuid),
            .ts_store = initTimeseriesForGraph(self.allocator, self.data_dir, graph_uuid),
        };

        // Load per-graph FTS from disk (existing graphs may have persisted data).
        if (initFtsForGraph(self.allocator, self.data_dir, graph_uuid, true)) |fts_result| {
            mg.fts_index = fts_result.index;
            mg.fts_dir = fts_result.dir;
        }

        try self.engines.put(owned_name, mg);
        self.upsertRegistryEntryLocked(name, graph_uuid, mg.engine.manifest.node_count, mg.engine.manifest.edge_count);
        self.saveRegistryLocked() catch |err| {
            log.warn("failed to persist graph registry after open of '{s}': {}", .{ name, err });
        };

        log.info("opened existing graph '{s}'", .{name});

        return mg;
    }

    fn requireExistingGraphLocked(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        if (self.engines.get(graph_name)) |mg| {
            return mg;
        }
        if (self.findRegistryEntryLocked(graph_name)) |entry| {
            return self.openGraphLocked(graph_name, entry.uuid);
        }
        return error.GraphNotFound;
    }

    fn findRegistryEntryLocked(self: *StorageAdapter, name: []const u8) ?gs.registry.GraphEntry {
        return self.registry.findByName(name);
    }

    fn upsertRegistryEntryLocked(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8, node_count: u64, edge_count: u64) void {
        for (self.registry.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.uuid = graph_uuid;
                entry.node_count = node_count;
                entry.edge_count = edge_count;
                return;
            }
        }

        self.registry.addGraph(name, graph_uuid) catch |err| {
            log.warn("failed to add graph '{s}' to registry: {}", .{ name, err });
            return;
        };
        const entry = &self.registry.entries.items[self.registry.entries.items.len - 1];
        entry.node_count = node_count;
        entry.edge_count = edge_count;
    }

    fn syncRegistryCountsLocked(self: *StorageAdapter, mg: *ManagedGraph) void {
        self.upsertRegistryEntryLocked(
            mg.name,
            mg.uuid,
            mg.engine.manifest.node_count,
            mg.engine.manifest.edge_count,
        );
    }

    fn loadPersistedManifestLocked(self: *StorageAdapter, graph_uuid: [16]u8) !gs.manifest.Manifest {
        var graph_dir = try gs.graph_dir.GraphDir.open(self.allocator, self.data_dir, graph_uuid);
        defer graph_dir.deinit();

        const path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(path_a);

        const path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(path_b);

        const manifest_a = try gs.manifest.Manifest.readFromFile(self.allocator, path_a);
        const manifest_b = try gs.manifest.Manifest.readFromFile(self.allocator, path_b);
        return try gs.manifest.Manifest.selectManifest(manifest_a, manifest_b);
    }

    fn refreshRegistryHeaderNextIdsLocked(self: *StorageAdapter) !void {
        var next_node_id: u64 = 1;
        var next_edge_id: u64 = 1;

        for (self.registry.entries.items) |entry| {
            if (self.engines.get(entry.name)) |mg| {
                next_node_id = @max(next_node_id, mg.engine.manifest.next_node_id);
                next_edge_id = @max(next_edge_id, mg.engine.manifest.next_edge_id);
                continue;
            }

            const manifest = try self.loadPersistedManifestLocked(entry.uuid);
            next_node_id = @max(next_node_id, manifest.next_node_id);
            next_edge_id = @max(next_edge_id, manifest.next_edge_id);
        }

        self.registry.next_node_id = next_node_id;
        self.registry.next_edge_id = next_edge_id;
    }

    fn saveRegistryLocked(self: *StorageAdapter) !void {
        try self.refreshRegistryHeaderNextIdsLocked();
        try self.registry.saveToFile(self.registry_path);
    }

    fn loadRegistry(self: *StorageAdapter) !void {
        std.fs.cwd().access(self.registry_path, .{}) catch |err| {
            if (err == error.FileNotFound) return err;
            return err;
        };
        try self.registry.loadFromFile(self.registry_path);
    }

    // ------------------------------------------------------------------
    // Node label operations (vtable targets)
    // ------------------------------------------------------------------

    /// Add a label to a node. The label string is mapped to a numeric
    /// LabelId via the per-graph dictionary, creating a new mapping if
    /// this is the first time the label has been seen.
    pub fn addNodeLabel(self: *StorageAdapter, graph_name: []const u8, node_id: u64, label: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        const label_id = try mg.label_dict.getOrCreate(label);
        try mg.engine.addLabel(node_id, label_id);
    }

    /// Remove a label from a node. If the label string is not in the
    /// per-graph dictionary then there is nothing to remove.
    pub fn removeNodeLabel(self: *StorageAdapter, graph_name: []const u8, node_id: u64, label: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        const label_id = mg.label_dict.getId(label) orelse return; // nothing to remove
        try mg.engine.removeLabel(node_id, label_id);
    }

    // ------------------------------------------------------------------
    // Edge property operations (vtable targets)
    // ------------------------------------------------------------------

    /// Remove a property from an edge. Delegates to the engine's
    /// `removeEdgeProperty` which handles adjacency list scanning internally.
    pub fn removeEdgeProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        from_id: u64,
        _: u64, // to_id — reserved for future use
        edge_id: u64,
        key: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        try mg.engine.removeEdgeProperty(from_id, edge_id, key);
    }

    // ------------------------------------------------------------------
    // Storage inspection
    // ------------------------------------------------------------------

    /// Return storage-level statistics for the named graph.
    pub fn getStorageStats(self: *StorageAdapter, graph_name: []const u8) !gs.GraphEngine.StorageStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        return mg.engine.getStorageStats();
    }

    /// Run an integrity check on the named graph and return the report.
    pub fn checkIntegrity(self: *StorageAdapter, graph_name: []const u8) !gs.GraphEngine.IntegrityReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = try self.requireExistingGraphLocked(graph_name);
        return mg.engine.checkIntegrity();
    }

    // ------------------------------------------------------------------
    // Per-graph RwLock acquisition API (P1 lock migration)
    // ------------------------------------------------------------------

    /// Acquire a shared (read) lock on the named graph.
    /// Caller MUST call releaseGraphReadLock when done.
    pub fn acquireGraphReadLock(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        self.mutex.lock();
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock();
            return error.GraphNotFound;
        };
        self.mutex.unlock();
        mg.rwlock.lockShared();
        return mg;
    }

    pub fn releaseGraphReadLock(_: *StorageAdapter, mg: *ManagedGraph) void {
        mg.rwlock.unlockShared();
    }

    /// Acquire an exclusive (write) lock on the named graph.
    /// Caller MUST call releaseGraphWriteLock when done.
    pub fn acquireGraphWriteLock(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        self.mutex.lock();
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock();
            return error.GraphNotFound;
        };
        self.mutex.unlock();
        mg.rwlock.lock();
        return mg;
    }

    pub fn releaseGraphWriteLock(_: *StorageAdapter, mg: *ManagedGraph) void {
        mg.rwlock.unlock();
    }

    /// Acquire shared (read) locks on multiple named graphs simultaneously.
    /// Locks are acquired in alphabetical order to prevent deadlocks.
    /// Caller MUST pass the returned slice to releaseMultiGraphReadLocks when done.
    pub fn acquireMultiGraphReadLocks(
        self: *StorageAdapter,
        allocator: std.mem.Allocator,
        graph_names: []const []const u8,
    ) ![]GraphLockHandle {
        // Sort alphabetically for deadlock prevention.
        const sorted = try allocator.dupe([]const u8, graph_names);
        defer allocator.free(sorted);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        var handles = try allocator.alloc(GraphLockHandle, sorted.len);
        var acquired: usize = 0;
        errdefer {
            while (acquired > 0) {
                acquired -= 1;
                self.releaseGraphReadLock(handles[acquired].mg);
            }
            allocator.free(handles);
        }

        for (sorted) |name| {
            const mg = try self.acquireGraphReadLock(name);
            handles[acquired] = .{ .graph_name = name, .mg = mg };
            acquired += 1;
        }

        return handles;
    }

    /// Release all locks acquired by acquireMultiGraphReadLocks and free the slice.
    pub fn releaseMultiGraphReadLocks(self: *StorageAdapter, allocator: std.mem.Allocator, handles: []GraphLockHandle) void {
        for (handles) |h| {
            self.releaseGraphReadLock(h.mg);
        }
        allocator.free(handles);
    }
};

/// Handle returned by acquireMultiGraphReadLocks, pairing a graph name with its locked ManagedGraph.
pub const GraphLockHandle = struct {
    graph_name: []const u8,
    mg: *ManagedGraph,
};

// ============================================================================
// UUID generation helper
// ============================================================================

fn generateUuid() [16]u8 {
    return (uuid.newV7() catch unreachable).bytes;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "LabelStringDict basic operations" {
    const allocator = std.testing.allocator;
    var dict = LabelStringDict.init(allocator);
    defer dict.deinit();

    // First assignment
    const id_person = try dict.getOrCreate("Person");
    try std.testing.expectEqual(@as(gs.LabelId, 1), id_person);

    // Same label returns same id
    const id_person2 = try dict.getOrCreate("Person");
    try std.testing.expectEqual(id_person, id_person2);

    // Different label gets a different id
    const id_place = try dict.getOrCreate("Place");
    try std.testing.expectEqual(@as(gs.LabelId, 2), id_place);
    try std.testing.expect(id_person != id_place);

    // Reverse lookup
    try std.testing.expectEqualStrings("Person", dict.getString(id_person).?);
    try std.testing.expectEqualStrings("Place", dict.getString(id_place).?);
    try std.testing.expectEqual(@as(?[]const u8, null), dict.getString(999));

    // Forward lookup
    try std.testing.expectEqual(id_person, dict.getId("Person").?);
    try std.testing.expectEqual(@as(?gs.LabelId, null), dict.getId("Unknown"));

    // Count
    try std.testing.expectEqual(@as(u32, 2), dict.count());
}

test "LabelStringDict starts at id 1" {
    const allocator = std.testing.allocator;
    var dict = LabelStringDict.init(allocator);
    defer dict.deinit();

    const first = try dict.getOrCreate("A");
    try std.testing.expectEqual(@as(gs.LabelId, 1), first);
}

test "toStorageProperty round-trip for scalars" {
    const allocator = std.testing.allocator;
    // Int
    const gs_int = try toStorageProperty(allocator, .{ .Int = 42 });
    try std.testing.expectEqual(@as(i64, 42), gs_int.int);

    // Float
    const gs_float = try toStorageProperty(allocator, .{ .Float = 3.14 });
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), gs_float.float, 0.001);

    // Bool
    const gs_bool = try toStorageProperty(allocator, .{ .Bool = true });
    try std.testing.expect(gs_bool.bool);

    // Null
    const gs_null = try toStorageProperty(allocator, .Null);
    try std.testing.expectEqual(gs.PropertyValue.null, gs_null);

    // String
    const gs_str = try toStorageProperty(allocator, .{ .String = "hello" });
    try std.testing.expectEqualStrings("hello", gs_str.string);

    // Decimal
    const gs_dec = try toStorageProperty(allocator, .{ .Decimal = .{ .coeff = 12345, .scale = 2 } });
    try std.testing.expectEqual(@as(i128, 12345), gs_dec.decimal.coeff);
    try std.testing.expectEqual(@as(u8, 2), gs_dec.decimal.scale);
}

test "ExtValue survives adapter property translation" {
    const allocator = std.testing.allocator;
    const nested = try allocator.dupe(u8, "nested");
    // nested ownership transfers to ext.ExtValue.List below;
    // freeDetachedExtValue will free it via the List slice.

    const ext = graph_store.PropertyValue{
        .ExtValue = .{
            .List = try allocator.dupe(@import("../eval_extended.zig").ExtValue, &.{
                .{ .Int = 7 },
                .{ .Str = nested },
            }),
        },
    };
    defer graph_store.freeDetachedExtValue(allocator, ext.ExtValue);

    const storage_val = try toStorageProperty(allocator, ext);
    defer freeTemporaryStorageProperty(allocator, storage_val);

    // The type_tag comes from the first byte of the codec encoding (property_tag_ext = 0x86)
    try std.testing.expectEqual(@as(u16, 0x86), storage_val.ext.type_tag);
    try std.testing.expect(storage_val.ext.data.len > 0);

    const roundtrip = try fromStorageProperty(allocator, storage_val);
    defer graph_store.freeDetachedExtValue(allocator, roundtrip.ExtValue);

    try std.testing.expect(roundtrip == .ExtValue);
    try std.testing.expectEqual(@as(usize, 2), roundtrip.ExtValue.List.len);
    try std.testing.expectEqual(@as(i64, 7), roundtrip.ExtValue.List[0].Int);
    try std.testing.expectEqualStrings("nested", roundtrip.ExtValue.List[1].Str);
}

test "fromStorageProperty round-trip for scalars" {
    const allocator = std.testing.allocator;

    // Int
    const geode_int = try fromStorageProperty(allocator, .{ .int = -7 });
    try std.testing.expectEqual(@as(i64, -7), geode_int.Int);

    // Float
    const geode_float = try fromStorageProperty(allocator, .{ .float = 2.72 });
    try std.testing.expectApproxEqAbs(@as(f64, 2.72), geode_float.Float, 0.001);

    // Bool
    const geode_bool = try fromStorageProperty(allocator, .{ .bool = false });
    try std.testing.expect(!geode_bool.Bool);

    // Null
    const geode_null = try fromStorageProperty(allocator, .null);
    try std.testing.expectEqual(graph_store.PropertyValue.Null, geode_null);

    // String (must free)
    const geode_str = try fromStorageProperty(allocator, .{ .string = "world" });
    defer allocator.free(geode_str.String);
    try std.testing.expectEqualStrings("world", geode_str.String);

    // Decimal
    const geode_dec = try fromStorageProperty(allocator, .{ .decimal = .{ .coeff = 99, .scale = 3 } });
    try std.testing.expectEqual(@as(i128, 99), geode_dec.Decimal.coeff);
    try std.testing.expectEqual(@as(u8, 3), geode_dec.Decimal.scale);
}

test {
    std.testing.refAllDecls(@This());
}

// ============================================================================
// Integration Tests — StorageAdapter with real GraphEngine instances
// ============================================================================

/// Minimal GraphConfig suitable for in-process integration tests.
fn testConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };
}

test "StorageAdapter: create and query graph" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("test_graph");

    try std.testing.expect(adapter.graphExists("test_graph"));
    try std.testing.expect(!adapter.graphExists("nonexistent"));
}

test "StorageAdapter: create node with labels" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const labels = &[_][]const u8{ "Person", "Employee" };
    const node_id = try adapter.createNode("test_graph", labels);
    try std.testing.expect(node_id > 0);

    const got_labels = try adapter.getNodeLabels("test_graph", node_id, allocator);
    defer {
        for (got_labels) |s| allocator.free(s);
        allocator.free(got_labels);
    }

    try std.testing.expectEqual(@as(usize, 2), got_labels.len);
}

test "StorageAdapter: create and traverse edge" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const node_a = try adapter.createNode("test_graph", &[_][]const u8{});
    const node_b = try adapter.createNode("test_graph", &[_][]const u8{});

    _ = try adapter.createEdge("test_graph", node_a, node_b, "KNOWS");

    const edges = try adapter.getOutgoingEdges("test_graph", node_a, allocator);
    defer allocator.free(edges);

    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqual(node_b, edges[0].neighbor);
}

test "StorageAdapter: drop graph" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("drop_me");
    try std.testing.expect(adapter.graphExists("drop_me"));

    adapter.dropGraph("drop_me");
    try std.testing.expect(!adapter.graphExists("drop_me"));
}

test "StorageAdapter: registry persists graph discovery across restart" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const graph = "persisted_graph";
        const node_id = try adapter.createNode(graph, &[_][]const u8{"Person"});
        try adapter.setNodeProperty(graph, node_id, "name", .{ .String = "Alice" });
        try adapter.checkpointAll();
        try std.testing.expect(adapter.graphExists(graph));
    }

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        try std.testing.expect(adapter.graphExists("persisted_graph"));

        const names = try adapter.listGraphNames(allocator);
        defer {
            for (names) |name| allocator.free(name);
            allocator.free(names);
        }

        var found = false;
        for (names) |name| {
            if (std.mem.eql(u8, name, "persisted_graph")) found = true;
        }
        try std.testing.expect(found);

        _ = try adapter.getOrCreateGraph("persisted_graph");
        try std.testing.expectEqual(@as(u64, 1), try adapter.nodeCount("persisted_graph"));
    }
}

test "StorageAdapter: node and edge counts" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "count_graph";
    const n1 = try adapter.createNode(graph, &[_][]const u8{});
    const n2 = try adapter.createNode(graph, &[_][]const u8{});
    const n3 = try adapter.createNode(graph, &[_][]const u8{});
    _ = try adapter.createEdge(graph, n1, n2, "REL");
    _ = try adapter.createEdge(graph, n2, n3, "REL");

    try std.testing.expectEqual(@as(u64, 3), try adapter.nodeCount(graph));
    try std.testing.expectEqual(@as(u64, 2), try adapter.edgeCount(graph));
}

test "StorageAdapter: registry header next ids include unloaded graphs" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const n1 = try adapter.createNode("persisted_graph", &[_][]const u8{});
        const n2 = try adapter.createNode("persisted_graph", &[_][]const u8{});
        _ = try adapter.createEdge("persisted_graph", n1, n2, "REL");
        try adapter.checkpointAll();
    }

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.createNode("fresh_graph", &[_][]const u8{});
        try adapter.checkpointAll();
    }

    const registry_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{path});
    defer allocator.free(registry_path);

    var registry = gs.registry.GraphRegistry.init(allocator);
    defer registry.deinit();
    try registry.loadFromFile(registry_path);

    try std.testing.expectEqual(@as(usize, 2), registry.graphCount());
    try std.testing.expectEqual(@as(u64, 3), registry.next_node_id);
    try std.testing.expectEqual(@as(u64, 2), registry.next_edge_id);
}

test "StorageAdapter: acquireGraphReadLock and releaseGraphReadLock" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("lock_test_graph");

    // Acquire a shared read lock and verify we get back a valid ManagedGraph.
    const mg = try adapter.acquireGraphReadLock("lock_test_graph");
    try std.testing.expectEqualStrings("lock_test_graph", mg.name);
    adapter.releaseGraphReadLock(mg);

    // Error on nonexistent graph.
    try std.testing.expectError(error.GraphNotFound, adapter.acquireGraphReadLock("no_such_graph"));
}

test "StorageAdapter: acquireGraphWriteLock and releaseGraphWriteLock" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("write_lock_graph");

    const mg = try adapter.acquireGraphWriteLock("write_lock_graph");
    try std.testing.expectEqualStrings("write_lock_graph", mg.name);
    adapter.releaseGraphWriteLock(mg);

    // Error on nonexistent graph.
    try std.testing.expectError(error.GraphNotFound, adapter.acquireGraphWriteLock("no_such_graph"));
}

test "StorageAdapter: acquireMultiGraphReadLocks acquires in alphabetical order" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("zebra");
    _ = try adapter.getOrCreateGraph("alpha");
    _ = try adapter.getOrCreateGraph("mango");

    const names = &[_][]const u8{ "zebra", "alpha", "mango" };
    const handles = try adapter.acquireMultiGraphReadLocks(allocator, names);
    defer adapter.releaseMultiGraphReadLocks(allocator, handles);

    try std.testing.expectEqual(@as(usize, 3), handles.len);

    // Verify all three graphs are locked and names are accessible.
    var found_alpha = false;
    var found_mango = false;
    var found_zebra = false;
    for (handles) |h| {
        if (std.mem.eql(u8, h.graph_name, "alpha")) found_alpha = true;
        if (std.mem.eql(u8, h.graph_name, "mango")) found_mango = true;
        if (std.mem.eql(u8, h.graph_name, "zebra")) found_zebra = true;
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_mango);
    try std.testing.expect(found_zebra);
}

test "StorageAdapter: acquireMultiGraphReadLocks returns error on missing graph" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("exists");

    const names = &[_][]const u8{ "exists", "does_not_exist" };
    try std.testing.expectError(error.GraphNotFound, adapter.acquireMultiGraphReadLocks(allocator, names));
}

// ============================================================================
// Per-graph subsystem colocation tests (Tasks 5-7)
// ============================================================================

test "StorageAdapter: per-graph audit logger is created and accessible" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const mg = try adapter.getOrCreateGraph("audit_graph");

    // Per-graph audit logger should be initialised (non-null).
    try std.testing.expect(mg.audit_logger != null);

    // Accessor on StorageAdapter returns the same logger.
    const logger = adapter.getAuditLogger("audit_graph");
    try std.testing.expect(logger != null);
    try std.testing.expect(logger.? == mg.audit_logger.?);

    // Verify audit.jsonl file exists inside the graph directory.
    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, mg.uuid);
    defer allocator.free(graph_dir);

    const audit_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{graph_dir});
    defer allocator.free(audit_path);

    // statFile returns a Stat struct on success; an error means the file does not exist.
    _ = std.fs.cwd().statFile(audit_path) catch |err| {
        std.debug.print("audit.jsonl should exist: {}\n", .{err});
        return err;
    };
}

test "StorageAdapter: per-graph timeseries store is created and accessible" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const mg = try adapter.getOrCreateGraph("ts_graph");

    // Per-graph timeseries store should be initialised (non-null).
    try std.testing.expect(mg.ts_store != null);

    // Accessor on StorageAdapter returns the same store.
    const store = adapter.getTimeseriesStore("ts_graph");
    try std.testing.expect(store != null);
    try std.testing.expect(store.? == mg.ts_store.?);

    // Verify timeseries/ subdirectory exists inside the graph directory.
    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, mg.uuid);
    defer allocator.free(graph_dir);

    const ts_dir = try std.fmt.allocPrint(allocator, "{s}/timeseries", .{graph_dir});
    defer allocator.free(ts_dir);

    var dir = std.fs.cwd().openDir(ts_dir, .{}) catch |err| {
        std.debug.print("timeseries dir open failed: {}\n", .{err});
        return err;
    };
    dir.close();
}

test "StorageAdapter: per-graph FTS index is created, persists, and accessible" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // Capture the graph UUID so we can reopen later.
    var graph_uuid: [16]u8 = undefined;

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const mg = try adapter.getOrCreateGraph("fts_graph");
        graph_uuid = mg.uuid;

        // Per-graph FTS index should be initialised (non-null).
        try std.testing.expect(mg.fts_index != null);
        try std.testing.expect(mg.fts_dir != null);

        // Accessor on StorageAdapter returns the same index.
        const idx = adapter.getFulltextIndex("fts_graph");
        try std.testing.expect(idx != null);
        try std.testing.expect(idx.? == mg.fts_index.?);

        // Index a document into the per-graph FTS index.
        try mg.fts_index.?.indexDocument(42, "the quick brown fox jumps over the lazy dog");

        // Verify fts/ subdirectory exists inside the graph directory.
        const graph_dir = try StorageAdapter.graphDirPath(allocator, path, mg.uuid);
        defer allocator.free(graph_dir);

        const fts_dir = try std.fmt.allocPrint(allocator, "{s}/fts", .{graph_dir});
        defer allocator.free(fts_dir);

        var dir = std.fs.cwd().openDir(fts_dir, .{}) catch |err| {
            std.debug.print("fts dir open failed: {}\n", .{err});
            return err;
        };
        dir.close();

        // deinit triggers saveToDisk for the FTS index.
    }

    // Reopen the adapter and verify FTS data persists.
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const mg = try adapter.openGraphWithUuid("fts_graph", graph_uuid);

        try std.testing.expect(mg.fts_index != null);

        // The previously indexed document should be present after reload.
        // We verify via the document count rather than search() to avoid
        // ArrayList leak in FullTextIndex.search().
        try std.testing.expect(mg.fts_index.?.documents.count() > 0);
    }
}

test "StorageAdapter: dropGraph removes graph directory and subsystem data" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const mg = try adapter.getOrCreateGraph("drop_graph");
    const graph_uuid = mg.uuid;

    // Verify all subsystems are initialised.
    try std.testing.expect(mg.audit_logger != null);
    try std.testing.expect(mg.ts_store != null);
    try std.testing.expect(mg.fts_index != null);

    // Get the graph directory path before dropping.
    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, graph_uuid);
    defer allocator.free(graph_dir);

    // Verify graph directory exists before drop.
    {
        var dir = std.fs.cwd().openDir(graph_dir, .{}) catch |err| {
            std.debug.print("graph dir should exist before drop: {}\n", .{err});
            return err;
        };
        dir.close();
    }

    // Drop the graph — this should deinit subsystems and delete the directory.
    adapter.dropGraph("drop_graph");

    // Verify graph directory is removed.
    const dir_result = std.fs.cwd().openDir(graph_dir, .{});
    if (dir_result) |*d| {
        var dir_copy = d.*;
        dir_copy.close();
        return error.TestExpectedError; // directory should not exist
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }

    // Verify accessors return null after drop.
    try std.testing.expect(adapter.getAuditLogger("drop_graph") == null);
    try std.testing.expect(adapter.getTimeseriesStore("drop_graph") == null);
    try std.testing.expect(adapter.getFulltextIndex("drop_graph") == null);
    try std.testing.expect(!adapter.graphExists("drop_graph"));
}
