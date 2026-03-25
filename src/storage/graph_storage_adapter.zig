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

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.graph_storage_adapter);

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
        self.engine.close();
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
        errdefer engine.close();

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

test {
    std.testing.refAllDecls(@This());
}
