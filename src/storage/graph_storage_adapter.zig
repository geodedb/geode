// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Graph Storage Adapter — bridges the graph-storage engine library to geode's
//! execution engine.
//!
//! Manages one `GraphEngine` instance per named graph, maintains a per-graph
//! label string↔LabelId dictionary, and provides the methods that geode's
//! execution engine calls.

const std = @import("std");
const gs = @import("graph_storage");
const uuid_mod = @import("../uuid.zig");
const graph_store = @import("../graph_store.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.graph_storage_adapter);

// Re-export edge type for callers that need EdgeEntry from scan results.
pub const EdgeEntry = gs.edge.EdgeEntry;

// ============================================================================
// LabelStringDict — bidirectional label string ↔ LabelId mapping
// ============================================================================

/// Per-graph bidirectional mapping between human-readable label strings and
/// numeric `LabelId` values used by the storage engine.
pub const LabelStringDict = struct {
    allocator: Allocator,
    str_to_id: std.StringHashMap(gs.LabelId),
    id_to_str: std.AutoHashMap(gs.LabelId, []const u8),
    next_id: gs.LabelId,

    pub fn init(allocator: Allocator) LabelStringDict {
        return .{
            .allocator = allocator,
            .str_to_id = std.StringHashMap(gs.LabelId).init(allocator),
            .id_to_str = std.AutoHashMap(gs.LabelId, []const u8).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *LabelStringDict) void {
        var it = self.str_to_id.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.str_to_id.deinit();
        self.id_to_str.deinit();
    }

    /// Return the LabelId for `label`, assigning a new one if this is the
    /// first time the label has been seen.
    pub fn getOrCreate(self: *LabelStringDict, label: []const u8) !gs.LabelId {
        if (self.str_to_id.get(label)) |id| {
            return id;
        }

        const id = self.next_id;
        self.next_id += 1;

        const owned = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned);

        try self.str_to_id.put(owned, id);
        errdefer _ = self.str_to_id.remove(owned);

        try self.id_to_str.put(id, owned);

        return id;
    }

    /// Reverse lookup: LabelId → string. Returns null when the id is unknown.
    pub fn getString(self: *const LabelStringDict, id: gs.LabelId) ?[]const u8 {
        return self.id_to_str.get(id);
    }

    /// Forward lookup: string → LabelId. Returns null when the label is unknown.
    pub fn getId(self: *const LabelStringDict, label: []const u8) ?gs.LabelId {
        return self.str_to_id.get(label);
    }

    /// Number of labels currently tracked.
    pub fn count(self: *const LabelStringDict) u32 {
        return @intCast(self.str_to_id.count());
    }
};

// ============================================================================
// Property Value Translation
// ============================================================================

/// Convert a geode `PropertyValue` to a graph-storage `PropertyValue`.
///
/// String data is passed through as a slice reference (no copy). The caller
/// must ensure the source value outlives the returned storage value.
pub fn toStorageProperty(val: graph_store.PropertyValue) gs.PropertyValue {
    return switch (val) {
        .String => |s| .{ .string = s },
        .Int => |i| .{ .int = i },
        .Float => |f| .{ .float = f },
        .Bool => |b| .{ .bool = b },
        .Null => .null,
        .Decimal => |d| .{ .decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ExtValue => .{ .ext = .{ .type_tag = 0, .data = "" } },
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
        .ext => .Null, // ExtValue round-trip is lossy; no geode ExtValue representation for raw ext
    };
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

    /// Obtain the vtable-based `GraphStorage` interface for direct low-level
    /// access to the engine.
    pub fn storage(self: *ManagedGraph) gs.GraphStorage {
        return gs.GraphStorage.init(gs.GraphEngine, self.engine);
    }

    fn deinit(self: *ManagedGraph, allocator: Allocator) void {
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
        self.* = .{
            .allocator = allocator,
            .data_dir = owned_dir,
            .engines = std.StringHashMap(*ManagedGraph).init(allocator),
            .default_engine = null,
            .config = config,
            .mutex = .{},
        };

        return self;
    }

    /// Shut down all engines, release every allocation.
    pub fn deinit(self: *StorageAdapter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.engines.deinit();
        self.default_engine = null;

        self.allocator.free(self.data_dir);
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

        return self.createGraphLocked(name);
    }

    /// Check whether a graph with the given name is currently loaded.
    pub fn graphExists(self: *StorageAdapter, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.engines.contains(name);
    }

    /// Close and remove the graph identified by `name`.
    pub fn dropGraph(self: *StorageAdapter, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.engines.fetchRemove(name)) |kv| {
            const mg = kv.value;

            // Clear default_engine if it pointed to the dropped graph.
            if (self.default_engine == mg) {
                self.default_engine = null;
            }

            mg.deinit(self.allocator);
        }
    }

    /// Return the names of all currently loaded graphs. Caller owns the
    /// returned slice and each name string inside it.
    pub fn listGraphNames(self: *StorageAdapter, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const n = self.engines.count();
        const names = try allocator.alloc([]const u8, n);
        errdefer allocator.free(names);

        var idx: usize = 0;
        var it = self.engines.iterator();
        while (it.next()) |entry| {
            names[idx] = try allocator.dupe(u8, entry.key_ptr.*);
            idx += 1;
        }

        return names;
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

        // Write an initial (empty) node record so the node store knows this
        // slot is occupied.
        const rec = gs.node.NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_set = 0,
            .flags = 0,
            ._pad = 0,
            .txn_stamp = 0,
        };
        try mg.engine.putNode(node_id, rec);

        // Attach each label via the engine (updates label_set bitmap and
        // label index).
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

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        try mg.engine.deleteNode(node_id);
    }

    /// Retrieve the string labels for a node. Caller owns the returned
    /// slice and must free both the slice and each string inside it.
    pub fn getNodeLabels(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        // Walk bits in label_set; each set bit corresponds to a LabelId.
        var result = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (result.items) |s| allocator.free(s);
            result.deinit();
        }

        var bits = rec.label_set;
        var bit_pos: u5 = 0;
        while (bits != 0) : (bit_pos += 1) {
            if (bits & 1 != 0) {
                // The engine stores label_id % 32 in the bitmap, so we need
                // to find which LabelId mapped to this bit position. Walk the
                // dictionary to find labels whose id % 32 == bit_pos.
                var dict_it = mg.label_dict.id_to_str.iterator();
                while (dict_it.next()) |entry| {
                    if (entry.key_ptr.* % 32 == bit_pos) {
                        try result.append(try allocator.dupe(u8, entry.value_ptr.*));
                    }
                }
            }
            bits >>= 1;
            if (bit_pos == 31) break;
        }

        return result.toOwnedSlice();
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

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        try mg.engine.removeEdge(from_id, to_id, edge_id);
    }

    /// Get all outgoing edges from a node.
    pub fn getOutgoingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        return mg.engine.expandOut(node_id, null, allocator);
    }

    /// Get all incoming edges to a node.
    pub fn getIncomingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        return mg.engine.expandIn(node_id, null, allocator);
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

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        const storage_val = toStorageProperty(value);
        const new_prop_head = try mg.engine.putProperty(rec.prop_head, key, storage_val);

        // Update the node record with the (possibly changed) prop_head.
        rec.prop_head = new_prop_head;
        try mg.engine.putNode(node_id, rec);
    }

    /// Remove a property from a node by writing a null tombstone.
    pub fn removeNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        const new_prop_head = try mg.engine.putProperty(rec.prop_head, key, .null);
        rec.prop_head = new_prop_head;
        try mg.engine.putNode(node_id, rec);
    }

    /// Get a property from a node, returned in graph-storage representation.
    pub fn getNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, allocator: Allocator) !?gs.PropertyValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        if (rec.prop_head == 0) return null;
        return mg.engine.getProperty(rec.prop_head, key, allocator);
    }

    /// Find all node IDs with the given label in a graph.
    pub fn getNodesByLabel(self: *StorageAdapter, graph_name: []const u8, label: []const u8, allocator: Allocator) ![]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        const label_id = mg.label_dict.getId(label) orelse return try allocator.alloc(u64, 0);
        return mg.engine.scanLabel(label_id, allocator);
    }

    // ------------------------------------------------------------------
    // Transaction operations
    // ------------------------------------------------------------------

    /// Begin a new transaction in the named graph.
    pub fn beginTransaction(self: *StorageAdapter, graph_name: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        return mg.engine.beginTxn();
    }

    /// Commit a transaction.
    pub fn commitTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        try mg.engine.commitTxn(txn_id);
    }

    /// Abort (rollback) a transaction.
    pub fn abortTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        try mg.engine.abortTxn(txn_id);
    }

    /// Run a checkpoint on every loaded graph engine.
    pub fn checkpointAll(self: *StorageAdapter) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            try entry.value_ptr.*.engine.checkpoint();
        }
    }

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------

    /// Return the number of nodes in the named graph.
    pub fn nodeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        return mg.engine.nodeCount();
    }

    /// Return the number of edges in the named graph.
    pub fn edgeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        return mg.engine.edgeCount();
    }

    // ------------------------------------------------------------------
    // Internal helpers (must be called with mutex held)
    // ------------------------------------------------------------------

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
            .label_dict = LabelStringDict.init(self.allocator),
            .name = owned_name,
            .uuid = graph_uuid,
        };

        try self.engines.put(owned_name, mg);

        log.info("created graph '{s}'", .{name});

        return mg;
    }
};

// ============================================================================
// UUID generation helper
// ============================================================================

fn generateUuid() [16]u8 {
    return uuid_mod.UuidV7.new().bytes;
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
    // Int
    const gs_int = toStorageProperty(.{ .Int = 42 });
    try std.testing.expectEqual(@as(i64, 42), gs_int.int);

    // Float
    const gs_float = toStorageProperty(.{ .Float = 3.14 });
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), gs_float.float, 0.001);

    // Bool
    const gs_bool = toStorageProperty(.{ .Bool = true });
    try std.testing.expect(gs_bool.bool);

    // Null
    const gs_null = toStorageProperty(.Null);
    try std.testing.expectEqual(gs.PropertyValue.null, gs_null);

    // String
    const gs_str = toStorageProperty(.{ .String = "hello" });
    try std.testing.expectEqualStrings("hello", gs_str.string);

    // Decimal
    const gs_dec = toStorageProperty(.{ .Decimal = .{ .coeff = 12345, .scale = 2 } });
    try std.testing.expectEqual(@as(i128, 12345), gs_dec.decimal.coeff);
    try std.testing.expectEqual(@as(u8, 2), gs_dec.decimal.scale);
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
