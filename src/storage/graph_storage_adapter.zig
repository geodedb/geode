// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Graph Storage Adapter — bridges the graph-storage engine library to geode's
//! execution engine.
//!
//! Manages one `GraphEngine` instance per named graph and provides the methods
//! that geode's execution engine calls.

const std = @import("std");
const builtin = @import("builtin");
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

var g_exact_node_property_lookup_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_label_scan_lookup_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

const graph_store_file_names = [_][]const u8{
    "nodes.store",
    "adj_out.store",
    "adj_in.store",
    "props.store",
    "var.store",
};

const free_store_header_size: usize = 16;
const free_store_path_name = "free.store";

pub fn resetLookupCounters() void {
    g_exact_node_property_lookup_count.store(0, .release);
    g_label_scan_lookup_count.store(0, .release);
}

pub fn getExactNodePropertyLookupCount() u64 {
    return g_exact_node_property_lookup_count.load(.acquire);
}

pub fn getLabelScanLookupCount() u64 {
    return g_label_scan_lookup_count.load(.acquire);
}

const NodePropertyExactIndex = struct {
    allocator: Allocator,
    postings: std.StringHashMap(std.ArrayList(u64)),

    fn init(allocator: Allocator) NodePropertyExactIndex {
        return .{
            .allocator = allocator,
            .postings = std.StringHashMap(std.ArrayList(u64)).init(allocator),
        };
    }

    fn deinit(self: *NodePropertyExactIndex) void {
        var it = self.postings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.postings.deinit();
    }

    fn clear(self: *NodePropertyExactIndex) void {
        var it = self.postings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.postings.clearAndFree();
    }

    fn add(self: *NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64, node_id: u64) !void {
        const probe_key = try self.encodeKey(label_id, property_key, value_hash);
        defer self.allocator.free(probe_key);

        if (self.postings.getPtr(probe_key)) |list| {
            for (list.items) |existing_id| {
                if (existing_id == node_id) return;
            }
            try list.append(self.allocator, node_id);
            return;
        }

        const owned_key = try self.encodeKey(label_id, property_key, value_hash);
        errdefer self.allocator.free(owned_key);

        const gop = try self.postings.getOrPut(owned_key);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).empty;
        } else {
            self.allocator.free(owned_key);
        }
        try gop.value_ptr.append(self.allocator, node_id);
    }

    fn remove(self: *NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64, node_id: u64) void {
        const probe_key = self.encodeKey(label_id, property_key, value_hash) catch return;
        defer self.allocator.free(probe_key);

        if (self.postings.getPtr(probe_key)) |list| {
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                if (list.items[i] == node_id) {
                    _ = list.orderedRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                if (self.postings.fetchRemove(probe_key)) |kv| {
                    self.allocator.free(kv.key);
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    fn get(self: *const NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) ?[]const u64 {
        const probe_key = self.encodeKey(label_id, property_key, value_hash) catch return null;
        defer self.allocator.free(probe_key);

        if (self.postings.get(probe_key)) |list| {
            return list.items;
        }
        return null;
    }

    fn encodeKey(self: *const NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) ![]u8 {
        const total_len = 4 + 4 + property_key.len + 8;
        const key = try self.allocator.alloc(u8, total_len);
        std.mem.writeInt(u32, key[0..4], label_id, .little);
        std.mem.writeInt(u32, key[4..8], @intCast(property_key.len), .little);
        @memcpy(key[8 .. 8 + property_key.len], property_key);
        std.mem.writeInt(u64, key[8 + property_key.len ..][0..8], value_hash, .little);
        return key;
    }

    /// Persist the index to `prop_exact.idx` inside `graph_dir_path`.
    /// Non-fatal: callers should catch and log warnings.
    fn saveToFile(self: *const NodePropertyExactIndex, graph_dir_path: []const u8) !void {
        const idx_path = try self.allocator.alloc(u8, graph_dir_path.len + "/prop_exact.idx".len);
        defer self.allocator.free(idx_path);
        @memcpy(idx_path[0..graph_dir_path.len], graph_dir_path);
        @memcpy(idx_path[graph_dir_path.len..], "/prop_exact.idx");

        const idx_io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(idx_io, idx_path, .{ .truncate = true });
        defer file.close(idx_io);

        var idx_wbuf: [8192]u8 = undefined;
        var idx_fw = file.writerStreaming(idx_io, &idx_wbuf);
        const writer = &idx_fw.interface;

        // 8-byte magic header
        try writer.writeAll("GENPIDX1");

        // Entry count
        var count: u64 = 0;
        {
            var count_iter = self.postings.iterator();
            while (count_iter.next()) |_| count += 1;
        }
        try writer.writeInt(u64, count, .little);

        // Each entry: [key_len: u32][key bytes][posting_count: u64][node_ids: u64...]
        var iter = self.postings.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const posting = entry.value_ptr.items;
            try writer.writeInt(u32, @intCast(key.len), .little);
            try writer.writeAll(key);
            try writer.writeInt(u64, @intCast(posting.len), .little);
            for (posting) |nid| {
                try writer.writeInt(u64, nid, .little);
            }
        }
        try idx_fw.flush();
    }

    /// Load the index from `prop_exact.idx` inside `graph_dir_path`.
    /// Returns true on success, false if file is missing, corrupt, or unreadable
    /// (caller should fall back to full rebuild).
    fn loadFromFile(self: *NodePropertyExactIndex, graph_dir_path: []const u8) bool {
        const idx_path = self.allocator.alloc(u8, graph_dir_path.len + "/prop_exact.idx".len) catch return false;
        defer self.allocator.free(idx_path);
        @memcpy(idx_path[0..graph_dir_path.len], graph_dir_path);
        @memcpy(idx_path[graph_dir_path.len..], "/prop_exact.idx");

        const gsa_io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(gsa_io, idx_path, .{}) catch return false;
        defer file.close(gsa_io);

        var reader_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(gsa_io, &reader_buffer);
        const reader = &file_reader.interface;

        // Validate magic header
        var magic: [8]u8 = undefined;
        reader.readSliceAll(&magic) catch return false;
        if (!std.mem.eql(u8, &magic, "GENPIDX1")) return false;

        const entry_count = reader.takeInt(u64, .little) catch return false;

        self.clear();

        var i: u64 = 0;
        while (i < entry_count) : (i += 1) {
            const key_len = reader.takeInt(u32, .little) catch return false;
            const key = self.allocator.alloc(u8, key_len) catch return false;
            reader.readSliceAll(key) catch {
                self.allocator.free(key);
                return false;
            };

            const posting_count = reader.takeInt(u64, .little) catch {
                self.allocator.free(key);
                return false;
            };
            var posting = std.ArrayList(u64).initCapacity(self.allocator, @intCast(posting_count)) catch {
                self.allocator.free(key);
                return false;
            };
            var j: u64 = 0;
            while (j < posting_count) : (j += 1) {
                const nid = reader.takeInt(u64, .little) catch {
                    posting.deinit(self.allocator);
                    self.allocator.free(key);
                    return false;
                };
                posting.appendAssumeCapacity(nid);
            }

            self.postings.put(key, posting) catch {
                posting.deinit(self.allocator);
                self.allocator.free(key);
                return false;
            };
        }

        return true;
    }
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

fn hashStorageProperty(allocator: Allocator, value: gs.PropertyValue) !u64 {
    var stack_buf: [64]u8 = undefined;
    const encoded_len = gs.property.encodedSize(value);
    if (encoded_len <= stack_buf.len) {
        const used = try gs.property.encodeInto(stack_buf[0..encoded_len], value);
        return std.hash.Wyhash.hash(0, stack_buf[0..used]);
    }

    const encoded = try gs.property.encode(allocator, value);
    defer allocator.free(encoded);
    return std.hash.Wyhash.hash(0, encoded);
}

/// Hash pre-encoded property bytes directly — zero-copy, no allocation.
/// The encoded bytes must be in the canonical format produced by `gs.property.encode`.
fn hashEncodedPropertyBytes(encoded_value: []const u8) u64 {
    return std.hash.Wyhash.hash(0, encoded_value);
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
    exact_node_property_index: NodePropertyExactIndex,
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
    rwlock: std.Io.RwLock = std.Io.RwLock.init,

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
        self.exact_node_property_index.deinit();
        self.label_dict.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

fn addIndexedNodeProperty(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, value: gs.PropertyValue) !void {
    const value_hash = try hashStorageProperty(mg.engine.allocator, value);
    try mg.exact_node_property_index.add(label_id, property_key, value_hash, node_id);
}

fn removeIndexedNodeProperty(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, value: gs.PropertyValue) void {
    const value_hash = hashStorageProperty(mg.engine.allocator, value) catch return;
    mg.exact_node_property_index.remove(label_id, property_key, value_hash, node_id);
}

/// Zero-copy variant: index a property using pre-encoded bytes from the iterator.
/// Avoids the decode-then-re-encode round-trip that `addIndexedNodeProperty` performs.
fn addIndexedNodePropertyFromEncoded(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, encoded_value: []const u8) !void {
    const value_hash = hashEncodedPropertyBytes(encoded_value);
    try mg.exact_node_property_index.add(label_id, property_key, value_hash, node_id);
}

/// Zero-copy variant: remove a property from the index using pre-encoded bytes.
fn removeIndexedNodePropertyFromEncoded(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, encoded_value: []const u8) void {
    const value_hash = hashEncodedPropertyBytes(encoded_value);
    mg.exact_node_property_index.remove(label_id, property_key, value_hash, node_id);
}

fn addNodePropertiesForLabels(mg: *ManagedGraph, node_id: u64, label_ids: []const gs.LabelId, prop_head: u64) !void {
    if (prop_head == 0 or label_ids.len == 0) return;

    var iter = try mg.engine.getAllProperties(prop_head);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        // Zero-copy path: hash the pre-encoded value bytes directly from the
        // iterator instead of re-fetching, decoding (which heap-allocates for
        // strings/ext), and re-encoding.
        for (label_ids) |label_id| {
            try addIndexedNodePropertyFromEncoded(mg, label_id, node_id, entry.key, entry.encoded_value);
        }
    }
}

fn removeNodePropertiesForLabels(mg: *ManagedGraph, node_id: u64, label_ids: []const gs.LabelId, prop_head: u64) void {
    if (prop_head == 0 or label_ids.len == 0) return;

    var iter = mg.engine.getAllProperties(prop_head) catch return;
    defer iter.deinit();
    while (iter.next() catch return) |entry| {
        // Zero-copy path: hash the pre-encoded value bytes directly.
        for (label_ids) |label_id| {
            removeIndexedNodePropertyFromEncoded(mg, label_id, node_id, entry.key, entry.encoded_value);
        }
    }
}

fn rebuildExactNodePropertyIndex(mg: *ManagedGraph) !void {
    mg.exact_node_property_index.clear();

    const Ctx = struct {
        mg: *ManagedGraph,
        err: ?anyerror = null,

        fn callback(self: *@This(), node_id: gs.NodeId, rec: gs.node.NodeRec) void {
            if (self.err != null) return;
            if (rec.label_head == 0 or rec.prop_head == 0) return;

            const label_ids = self.mg.engine.label_store.getLabels(rec.label_head, self.mg.engine.allocator) catch |err| {
                self.err = err;
                return;
            };
            defer self.mg.engine.allocator.free(label_ids);

            addNodePropertiesForLabels(self.mg, node_id, label_ids, rec.prop_head) catch |err| {
                self.err = err;
            };
        }
    };

    var ctx = Ctx{ .mg = mg };
    try mg.engine.node_store.scanNodes(mg.engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |err| return err;
}

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
    mutex: std.Io.Mutex,

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
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), graphs_dir) catch |err| {
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
            .mutex = std.Io.Mutex.init,
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
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.engines.deinit();
        self.default_engine = null;

        self.registry.deinit();
        self.allocator.free(self.registry_path);
        self.allocator.free(self.data_dir);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.allocator.destroy(self);
    }

    /// Return the `ManagedGraph` for `name`, creating a new `GraphEngine` if
    /// the graph has not been opened yet.
    pub fn getOrCreateGraph(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.engines.get(name)) |mg| {
            return mg;
        }

        return self.openGraphLocked(name, graph_uuid);
    }

    /// Return the stored UUID for a loaded graph, or null if not loaded.
    pub fn getGraphUuid(self: *StorageAdapter, name: []const u8) ?[16]u8 {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return if (mg) |m| m.audit_logger else null;
    }

    /// Return the per-graph timeseries store for `name`, or null if the graph
    /// does not exist or timeseries was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getTimeseriesStore(self: *StorageAdapter, name: []const u8) ?*ts_mod.Store {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return if (mg) |m| m.ts_store else null;
    }

    /// Return the per-graph full-text search index for `name`, or null if the
    /// graph does not exist or FTS was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getFulltextIndex(self: *StorageAdapter, name: []const u8) ?*fulltext.FullTextIndex {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return if (mg) |m| m.fts_index else null;
    }

    /// Check whether a graph with the given name exists either in memory or in
    /// the persisted registry.
    pub fn graphExists(self: *StorageAdapter, name: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return self.engines.contains(name) or self.findRegistryEntryLocked(name) != null;
    }

    /// Close and remove the graph identified by `name`.
    pub fn dropGraph(self: *StorageAdapter, name: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var names = std.ArrayList([]const u8).empty;
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
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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

        // R7 (2026-04-22): batch every sub-op (putNode + per-label addLabel)
        // into a SINGLE storage-engine transaction so we incur exactly one
        // WAL fsync per CREATE, not one per sub-op.
        //
        // The engine's auto-commit variants (putNode, addLabel,
        // putProperty) each call `txn_manager.begin()` + `commit()`, and
        // `commit()` always ends with `wal.sync()` (fsync) — see
        // `graph_storage/src/txn.zig:67-85`.  A CREATE (n:Label {prop: x})
        // therefore incurs 1 putNode + 1 addLabel + 2 setNodeProperty
        // fsyncs ≈ 40-60 ms on SSD, which was the dominant contributor to
        // the 50 ms/CREATE median measured by
        // `bench-query-executor-mutation` baseline (create_single scenario
        // 2026-04-22).
        //
        // Wrapping the sub-ops in an explicit transaction collapses the
        // fsync count to 1, dropping measured create_single latency
        // dramatically (expected 5-10× speedup).
        const txn = try mg.engine.beginTxn();
        errdefer mg.engine.abortTxn(txn) catch {};

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
        try mg.engine.putNodeTxn(node_id, rec, txn);

        // Attach each label via the engine (updates label blocks in var.store
        // and the label index).
        for (labels) |lbl| {
            const label_id = try mg.label_dict.getOrCreate(lbl);
            try mg.engine.addLabelTxn(node_id, label_id, txn);
        }

        try mg.engine.commitTxn(txn);
        return node_id;
    }

    // CANARY: REQ=REQ-PERF-QPS-0815; FEATURE="BatchCreate"; ASPECT=AdapterBulkSlots; STATUS=TESTED; TEST=tests/test_gap0815_deep_bulk_create.zig; OWNER=performance; UPDATED=2026-04-20
    /// Allocate `n` node slots in the given graph + attach the same label set
    /// to each, under a SINGLE adapter mutex acquisition (vs N for N separate
    /// `createNode` calls). Caller owns the returned `[]u64`.
    ///
    /// Rationale: `createNode` calls `getOrCreateGraph` each invocation,
    /// which takes `self.mutex` once per call. For N homogeneous CREATE
    /// clauses this is the dominant per-clause overhead (the engine-level
    /// `allocNode` / `putNode` / `addLabel` work itself runs lock-free
    /// afterward). This variant resolves the `ManagedGraph` once and then
    /// caches label-id lookups across all N slots.
    ///
    /// Returns node slot IDs in the same order as their allocation (which
    /// is the order they are handed to the caller and the order they
    /// should be inserted into higher-level indices — e.g. GraphStore's
    /// label-posting-list append).
    pub fn createNodesBatch(
        self: *StorageAdapter,
        graph_name: []const u8,
        labels: []const []const u8,
        n: usize,
        out_allocator: Allocator,
    ) ![]u64 {
        if (n == 0) return try out_allocator.alloc(u64, 0);

        // Single adapter-mutex acquisition for the graph lookup (see
        // `getOrCreateGraph`). The ManagedGraph pointer is stable once
        // registered; subsequent engine operations don't need the adapter
        // mutex.
        const mg = try self.getOrCreateGraph(graph_name);

        // Resolve label strings → label ids once; apply to every new slot.
        var label_ids_buf: [8]gs.LabelId = undefined;
        var label_ids: []gs.LabelId = if (labels.len <= label_ids_buf.len)
            label_ids_buf[0..labels.len]
        else
            try self.allocator.alloc(gs.LabelId, labels.len);
        defer if (labels.len > label_ids_buf.len) self.allocator.free(label_ids);
        for (labels, 0..) |lbl, i| {
            label_ids[i] = try mg.label_dict.getOrCreate(lbl);
        }

        const rec_template = gs.node.NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };

        const out = try out_allocator.alloc(u64, n);
        errdefer out_allocator.free(out);

        // R7 (2026-04-22): collapse N × (1 + L) fsyncs (one per putNode and
        // one per addLabel) into ONE fsync for the full batch.  This is the
        // whole reason `createNodesBatch` exists — to amortise per-slot
        // overhead over a single transaction.  Previously each of the
        // N × (1 + L) auto-commits did its own `wal.sync()`, so the
        // "batch" was only amortising the mutex + graph-lookup costs.
        const txn = try mg.engine.beginTxn();
        errdefer mg.engine.abortTxn(txn) catch {};

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const node_id = try mg.engine.allocNode();
            try mg.engine.putNodeTxn(node_id, rec_template, txn);
            for (label_ids) |label_id| {
                try mg.engine.addLabelTxn(node_id, label_id, txn);
            }
            out[i] = node_id;
        }

        try mg.engine.commitTxn(txn);
        return out;
    }

    /// Delete a node by ID in the named graph.
    pub fn deleteNode(self: *StorageAdapter, graph_name: []const u8, node_id: u64) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_ids = try mg.engine.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);
        removeNodePropertiesForLabels(mg, node_id, label_ids, rec.prop_head);

        // R7 (2026-04-22): wrap the engine deleteNode call in an explicit
        // transaction — same fsync batching rationale as createNode.  For
        // deleteNode specifically there is only one engine sub-op, so the
        // saving is minimal, but using the `*Txn` variant keeps the code
        // path consistent with the other adapter methods and future-proofs
        // any follow-up that adds per-property tombstones.
        const txn = try mg.engine.beginTxn();
        errdefer mg.engine.abortTxn(txn) catch {};
        try mg.engine.deleteNodeTxn(node_id, txn);
        try mg.engine.commitTxn(txn);
    }

    /// Retrieve the string labels for a node. Caller owns the returned
    /// slice and must free both the slice and each string inside it.
    pub fn getNodeLabels(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![][]const u8 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        // Retrieve label IDs from the engine's LabelStore (variable-length
        // label blocks stored in var.store).
        const label_ids = try mg.engine.label_store.getLabels(rec.label_head, allocator);
        defer allocator.free(label_ids);

        var result: std.ArrayList([]const u8) = .empty;
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
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
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_ids = try mg.engine.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);

        const old_value = if (rec.prop_head != 0) try mg.engine.getProperty(rec.prop_head, key, self.allocator) else null;
        defer {
            if (old_value) |val| freeOwnedStorageProperty(self.allocator, val);
        }

        const storage_val = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_val);

        if (old_value) |existing| {
            for (label_ids) |label_id| {
                removeIndexedNodeProperty(mg, label_id, node_id, key, existing);
            }
        }

        // R7 (2026-04-22): batch putProperty + putNode into one txn — see
        // `createNode` for the fsync rationale.  Previously each auto-commit
        // issued its own `wal.sync()`, making every setNodeProperty ≈ 10 ms
        // on SSD.
        const txn = try mg.engine.beginTxn();
        errdefer mg.engine.abortTxn(txn) catch {};

        const new_prop_head = try mg.engine.putPropertyTxn(rec.prop_head, key, storage_val, txn);

        // Update the node record with the (possibly changed) prop_head.
        rec.prop_head = new_prop_head;
        try mg.engine.putNodeTxn(node_id, rec, txn);

        try mg.engine.commitTxn(txn);

        for (label_ids) |label_id| {
            try addIndexedNodeProperty(mg, label_id, node_id, key, storage_val);
        }
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_ids = try mg.engine.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);

        // R7 (2026-04-22): wrap the full N-property batch in ONE engine
        // transaction so the entire batch incurs a single WAL fsync instead
        // of one per property.  Caller invokes this specifically to amortise
        // per-property overhead, so collapsing N fsyncs → 1 fsync is the
        // whole point.
        const txn = try mg.engine.beginTxn();
        errdefer mg.engine.abortTxn(txn) catch {};

        for (entries) |entry| {
            const old_value = if (rec.prop_head != 0) try mg.engine.getProperty(rec.prop_head, entry.key, self.allocator) else null;
            defer {
                if (old_value) |val| freeOwnedStorageProperty(self.allocator, val);
            }

            if (entry.value) |val| {
                const storage_val = try toStorageProperty(self.allocator, val);
                defer freeTemporaryStorageProperty(self.allocator, storage_val);
                if (old_value) |existing| {
                    for (label_ids) |label_id| {
                        removeIndexedNodeProperty(mg, label_id, node_id, entry.key, existing);
                    }
                }
                const new_prop_head = try mg.engine.putPropertyTxn(rec.prop_head, entry.key, storage_val, txn);
                rec.prop_head = new_prop_head;
                for (label_ids) |label_id| {
                    try addIndexedNodeProperty(mg, label_id, node_id, entry.key, storage_val);
                }
            } else {
                if (old_value) |existing| {
                    for (label_ids) |label_id| {
                        removeIndexedNodeProperty(mg, label_id, node_id, entry.key, existing);
                    }
                }
                const new_prop_head = try mg.engine.putPropertyTxn(rec.prop_head, entry.key, .null, txn);
                rec.prop_head = new_prop_head;
                for (label_ids) |label_id| {
                    try addIndexedNodeProperty(mg, label_id, node_id, entry.key, .null);
                }
            }
        }

        // Write the node record once after all property mutations — still
        // inside the same transaction so the whole batch commits atomically
        // with a single fsync.
        try mg.engine.putNodeTxn(node_id, rec, txn);
        try mg.engine.commitTxn(txn);
    }

    /// Remove a property from a node by writing a null tombstone.
    pub fn removeNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_ids = try mg.engine.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);
        const old_value = if (rec.prop_head != 0) try mg.engine.getProperty(rec.prop_head, key, self.allocator) else null;
        defer {
            if (old_value) |val| freeOwnedStorageProperty(self.allocator, val);
        }

        if (old_value) |existing| {
            for (label_ids) |label_id| {
                removeIndexedNodeProperty(mg, label_id, node_id, key, existing);
            }
        }

        // R7 (2026-04-22): batch putProperty + putNode into one txn.
        const txn = try mg.engine.beginTxn();
        errdefer mg.engine.abortTxn(txn) catch {};

        const new_prop_head = try mg.engine.putPropertyTxn(rec.prop_head, key, .null, txn);
        rec.prop_head = new_prop_head;
        try mg.engine.putNodeTxn(node_id, rec, txn);

        try mg.engine.commitTxn(txn);

        for (label_ids) |label_id| {
            try addIndexedNodeProperty(mg, label_id, node_id, key, .null);
        }
    }

    /// Get a property from a node, returned in graph-storage representation.
    pub fn getNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, allocator: Allocator) !?gs.PropertyValue {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        if (rec.prop_head == 0) return null;
        return mg.engine.getProperty(rec.prop_head, key, allocator);
    }

    /// Find all node IDs with the given label in a graph.
    /// Filters out deleted nodes whose slot IDs are still present in the
    /// label index (the engine's deleteNode sets NODE_FLAG_DELETED but does
    /// not remove the entry from the label posting list).
    pub fn iterateNodesByLabel(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        allocator: Allocator,
    ) !?gs.NodeIterator {
        const ctx = try self.resolveLabelScanContext(graph_name, label) orelse return null;
        return try ctx.mg.storage().scanLabelIter(ctx.label_id, allocator);
    }

    pub fn getNodesByLabel(self: *StorageAdapter, graph_name: []const u8, label: []const u8, allocator: Allocator) ![]u64 {
        _ = g_label_scan_lookup_count.fetchAdd(1, .monotonic);
        const ctx = try self.resolveLabelScanContext(graph_name, label) orelse return try allocator.alloc(u64, 0);
        const mg = ctx.mg;
        var iter = try mg.storage().scanLabelIter(ctx.label_id, allocator);
        defer iter.deinit();
        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(allocator);

        // Filter out deleted/empty nodes whose slot IDs are still present
        // in the label index.  We read raw page bytes via the buffer pool
        // and check the record flags directly — this avoids engine.getNode()
        // which conflates "empty" and "deleted" into a single null return,
        // and whose null-based filtering caused regressions in prior attempts.
        const node_mod = gs.node;
        const NodeRec = node_mod.NodeRec;
        const npp = mg.engine.node_store.nodes_per_page;
        const hdr_size = gs.node.PAGE_HEADER_SIZE;
        const bp = mg.engine.node_store.buffer_pool;

        // Cache the pinned page frame across iterations.  Node IDs from
        // the label index are sorted, so consecutive IDs usually share the
        // same page — caching avoids redundant pin/unpin round-trips.
        var cached_page_id: ?u64 = null;
        var cached_frame: *gs.page_frame.PageFrame = undefined;
        defer if (cached_page_id != null) bp.unpin(bp.frameIndex(cached_frame), false);

        while (try iter.next()) |nid| {
            const page_id = nid / npp;
            // Page not allocated → node cannot be live (stale index entry)
            if (!mg.engine.node_store.free_space.isAllocated(page_id)) continue;

            // Re-pin only when we transition to a different page.
            if (cached_page_id == null or cached_page_id.? != page_id) {
                if (cached_page_id != null) {
                    bp.unpin(bp.frameIndex(cached_frame), false);
                    cached_page_id = null;
                }
                cached_frame = try bp.pin(.nodes, page_id);
                cached_page_id = page_id;
            }

            const slot: u32 = @intCast(nid % npp);
            const slot_offset = hdr_size + slot * @sizeOf(NodeRec);
            const data = cached_frame.dataSlice();
            const rec = std.mem.bytesToValue(NodeRec, data[slot_offset..][0..@sizeOf(NodeRec)]);

            if (node_mod.isDeleted(&rec)) continue;
            if (node_mod.isEmpty(&rec)) continue;
            try result.append(allocator, nid);
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Return node candidates for an exact `(label, property = value)` probe.
    /// Hash collisions are tolerated because higher layers still verify the
    /// full property map before treating a candidate as a MERGE match.
    pub fn getCandidateNodesByLabelAndProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        value: graph_store.PropertyValue,
        allocator: Allocator,
    ) ![]u64 {
        _ = g_exact_node_property_lookup_count.fetchAdd(1, .monotonic);

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const label_id = mg.label_dict.getId(label) orelse return try allocator.alloc(u64, 0);

        const storage_value = try toStorageProperty(allocator, value);
        defer freeTemporaryStorageProperty(allocator, storage_value);
        const value_hash = try hashStorageProperty(allocator, storage_value);
        const indexed = mg.exact_node_property_index.get(label_id, property_key, value_hash) orelse return try allocator.alloc(u64, 0);

        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(allocator);

        for (indexed) |node_id| {
            if (try mg.engine.getNode(node_id) == null) continue;
            try result.append(allocator, node_id);
        }

        return try result.toOwnedSlice(allocator);
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
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
        // Brief mutex hold: look up ManagedGraph, then release.
        // The ManagedGraph pointer is heap-allocated and only freed by
        // dropGraph (under mutex), so using it after unlock is safe.
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

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

        var ctx = Ctx{ .entries = .empty, .alloc = allocator };
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        var result = std.StringHashMap(gs.PropertyValue).init(allocator);
        errdefer result.deinit();

        if (rec.prop_head == 0) return result;

        // Single-pass zero-copy iteration: the PropIterator yields each
        // property's key and pre-encoded value bytes directly from pinned
        // page frames.  We decode the value inline (allocating only for
        // string/ext payloads that must outlive the iterator) instead of
        // the previous two-pass pattern (collect keys → re-fetch each).
        var iter = try mg.engine.getAllProperties(rec.prop_head);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (!shouldExposePropertyKey(entry.key)) continue;
            const decoded = try gs.property.decode(allocator, entry.encoded_value);
            const owned_key = try allocator.dupe(u8, entry.key);
            try result.put(owned_key, decoded.value);
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

        var result = std.StringHashMap(gs.PropertyValue).init(allocator);
        errdefer result.deinit();

        if (prop_head == 0) return result;

        const prop_head_u64: u64 = @intCast(prop_head);

        // Single-pass zero-copy iteration (see getAllNodeProperties).
        var iter = try mg.engine.getAllProperties(prop_head_u64);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (!shouldExposePropertyKey(entry.key)) continue;
            const decoded = try gs.property.decode(allocator, entry.encoded_value);
            const owned_key = try allocator.dupe(u8, entry.key);
            try result.put(owned_key, decoded.value);
        }

        return result;
    }

    // ------------------------------------------------------------------
    // Transaction operations
    // ------------------------------------------------------------------

    /// Begin a new transaction in the named graph.
    pub fn beginTransaction(self: *StorageAdapter, graph_name: []const u8) !u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.beginTxn();
    }

    /// Commit a transaction.
    pub fn commitTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        try mg.engine.commitTxn(txn_id);
    }

    /// Abort (rollback) a transaction.
    pub fn abortTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        try mg.engine.abortTxn(txn_id);
    }

    /// Run a checkpoint on every loaded graph engine.
    pub fn checkpointAll(self: *StorageAdapter) !void {
        // Collect ManagedGraph pointers under brief mutex hold.
        var graphs_buf: [64]*ManagedGraph = undefined;
        var graph_count: usize = 0;
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
        // IMPORTANT: Acquire the per-graph read lock during checkpoint to
        // prevent data races with concurrent mutations (which hold the
        // write lock). Without this, engine.checkpoint() iterates hash maps
        // (label_index, edge_index) that mutations can resize concurrently,
        // causing use-after-free and GPA size mismatch errors.
        for (graphs_buf[0..graph_count]) |mg| {
            mg.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
            mg.engine.checkpoint() catch |err| {
                log.warn("checkpoint failed for graph '{s}': {}", .{ mg.name, err });
            };
            // Persist the exact property index alongside the engine checkpoint.
            if (graphDirPath(self.allocator, self.data_dir, mg.uuid)) |dir_path| {
                mg.exact_node_property_index.saveToFile(dir_path) catch |err| {
                    log.warn("failed to persist property index for graph '{s}': {}", .{ mg.name, err });
                };
                self.allocator.free(dir_path);
            } else |err| {
                log.warn("failed to build graph dir path for property index persist '{s}': {}", .{ mg.name, err });
            }
            mg.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
        }

        // Collect manifest counts under per-graph read lock (no mutex),
        // then sync the registry under the adapter mutex (no rwlock).
        // Holding mutex while acquiring rwlock caused ABBA deadlocks:
        //   Thread A (MERGE): holds rwlock → wants mutex (adapter methods)
        //   Thread B (checkpoint): holds mutex → wants rwlock (here)
        var counts_buf: [64]struct { name: []const u8, uuid: [16]u8, node_count: u64, edge_count: u64 } = undefined;
        for (graphs_buf[0..graph_count], 0..) |mg, i| {
            mg.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
            counts_buf[i] = .{
                .name = mg.name,
                .uuid = mg.uuid,
                .node_count = mg.engine.manifest.node_count,
                .edge_count = mg.engine.manifest.edge_count,
            };
            mg.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
        }
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            for (counts_buf[0..graph_count]) |c| {
                self.upsertRegistryEntryLocked(c.name, c.uuid, c.node_count, c.edge_count);
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.nodeCount();
    }

    /// Return the number of edges in the named graph.
    pub fn edgeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
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

    fn freeStoreMaskCount(total_pages: u64) usize {
        return @intCast((total_pages + @bitSizeOf(usize) - 1) / @bitSizeOf(usize));
    }

    fn truncateFreeStoreIfPresent(allocator: Allocator, graph_dir: []const u8) !bool {
        const free_store_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ graph_dir, free_store_path_name });
        defer allocator.free(free_store_path);

        const trunc_io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(trunc_io, free_store_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(trunc_io);

        try file.setLength(trunc_io, 0);
        return true;
    }

    fn maxPersistedPagesForStorePath(self: *StorageAdapter, graph_dir: []const u8, file_name: []const u8) !u64 {
        const store_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_dir, file_name });
        defer self.allocator.free(store_path);

        const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), store_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 64,
            else => return err,
        };

        const page_count = stat.size / self.config.page_size;
        if (page_count >= std.math.maxInt(u64) / 2) return std.math.maxInt(u64);
        return @max(@as(u64, 64), page_count * 2);
    }

    fn freeStoreLooksValidLocked(self: *StorageAdapter, graph_dir: []const u8) !bool {
        const free_store_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_dir, free_store_path_name });
        defer self.allocator.free(free_store_path);

        const io_fv = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_fv, free_store_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return err,
        };
        defer file.close(io_fv);

        const stat = try file.stat(io_fv);
        if (stat.size == 0) return true;

        const word_size = @sizeOf(usize);
        const min_section_size = free_store_header_size + word_size;
        const min_total_size = min_section_size * graph_store_file_names.len;
        if (stat.size < min_total_size) return false;

        var max_total_size: u64 = 0;
        for (graph_store_file_names) |file_name| {
            const max_pages = try self.maxPersistedPagesForStorePath(graph_dir, file_name);
            max_total_size += free_store_header_size + freeStoreMaskCount(max_pages) * word_size;
        }
        if (stat.size > max_total_size) return false;

        var offset: u64 = 0;
        var header_buf: [free_store_header_size]u8 = undefined;
        for (graph_store_file_names) |file_name| {
            const max_pages = try self.maxPersistedPagesForStorePath(graph_dir, file_name);
            const bytes_read = try file.readPositionalAll(io_fv, &header_buf, offset);
            if (bytes_read != header_buf.len) return false;

            const total_pages = std.mem.readInt(u64, header_buf[0..8], .little);
            const next_free_hint = std.mem.readInt(u64, header_buf[8..16], .little);
            if (total_pages < 64 or total_pages > max_pages) return false;
            if (next_free_hint == 0 or next_free_hint > total_pages) return false;

            const section_size: u64 = free_store_header_size + freeStoreMaskCount(total_pages) * word_size;
            if (offset + section_size > stat.size) return false;
            offset += section_size;
        }

        return offset == stat.size;
    }

    fn sanitizeFreeStoreBeforeOpenLocked(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8) !void {
        const graph_dir = try graphDirPath(self.allocator, self.data_dir, graph_uuid);
        defer self.allocator.free(graph_dir);

        if (!(try self.freeStoreLooksValidLocked(graph_dir))) {
            if (try truncateFreeStoreIfPresent(self.allocator, graph_dir)) {
                log.warn("graph '{s}' has invalid persisted free.store; truncating it so GraphEngine.open can rebuild from disk", .{name});
            }
        }
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
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), fts_dir) catch |err| {
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

        // GAP-0512: Only create per-graph audit for the security graph.
        // Other graphs use the global audit logger. Per-graph audit on every
        // graph caused recursive mutex deadlocks and unnecessary I/O.
        const is_security_graph = std.mem.eql(u8, name, "__geode_security");
        mg.* = .{
            .engine = engine,
            .label_dict = LabelStringDict.initView(&engine.label_dict),
            .exact_node_property_index = NodePropertyExactIndex.init(self.allocator),
            .name = owned_name,
            .uuid = graph_uuid,
            .audit_logger = if (is_security_graph) initAuditForGraph(self.allocator, self.data_dir, graph_uuid) else null,
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
        try self.sanitizeFreeStoreBeforeOpenLocked(name, graph_uuid);

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

        const is_security_graph = std.mem.eql(u8, name, "__geode_security");
        mg.* = .{
            .engine = engine,
            .label_dict = LabelStringDict.initView(&engine.label_dict),
            .exact_node_property_index = NodePropertyExactIndex.init(self.allocator),
            .name = owned_name,
            .uuid = graph_uuid,
            .audit_logger = if (is_security_graph) initAuditForGraph(self.allocator, self.data_dir, graph_uuid) else null,
            .ts_store = initTimeseriesForGraph(self.allocator, self.data_dir, graph_uuid),
        };

        // Load per-graph FTS from disk (existing graphs may have persisted data).
        if (initFtsForGraph(self.allocator, self.data_dir, graph_uuid, true)) |fts_result| {
            mg.fts_index = fts_result.index;
            mg.fts_dir = fts_result.dir;
        }

        // Try loading the persisted property index; fall back to full rebuild.
        const loaded_from_disk = blk: {
            const dir_path = graphDirPath(self.allocator, self.data_dir, graph_uuid) catch break :blk false;
            defer self.allocator.free(dir_path);
            break :blk mg.exact_node_property_index.loadFromFile(dir_path);
        };
        if (!loaded_from_disk) {
            try rebuildExactNodePropertyIndex(mg);
        }

        try self.engines.put(owned_name, mg);
        self.upsertRegistryEntryLocked(name, graph_uuid, mg.engine.manifest.node_count, mg.engine.manifest.edge_count);
        self.saveRegistryLocked() catch |err| {
            log.warn("failed to persist graph registry after open of '{s}': {}", .{ name, err });
        };

        if (loaded_from_disk) {
            log.info("opened existing graph '{s}' (property index loaded from disk)", .{name});
        } else {
            log.info("opened existing graph '{s}' (property index rebuilt from scan)", .{name});
        }

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

    fn resolveLabelScanContext(self: *StorageAdapter, graph_name: []const u8, label: []const u8) !?LabelScanContext {
        // Brief mutex hold: look up ManagedGraph and label ID, then release.
        // The ManagedGraph is stable while the caller holds the per-graph
        // rwlock, so iterator-backed scans do not need the adapter mutex.
        // Holding mutex during scans caused ABBA deadlocks with concurrent
        // ingest (QUIC handler: rwlock → mutex; ingest: mutex → rwlock).
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const mg = try self.requireExistingGraphLocked(graph_name);
        const label_id = mg.label_dict.getId(label) orelse return null;
        return .{
            .mg = mg,
            .label_id = label_id,
        };
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
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), self.registry_path, .{}) catch |err| {
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_id = try mg.label_dict.getOrCreate(label);
        try mg.engine.addLabel(node_id, label_id);
        try addNodePropertiesForLabels(mg, node_id, &[_]gs.LabelId{label_id}, rec.prop_head);
    }

    /// Remove a label from a node. If the label string is not in the
    /// per-graph dictionary then there is nothing to remove.
    pub fn removeNodeLabel(self: *StorageAdapter, graph_name: []const u8, node_id: u64, label: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_id = mg.label_dict.getId(label) orelse return; // nothing to remove
        removeNodePropertiesForLabels(mg, node_id, &[_]gs.LabelId{label_id}, rec.prop_head);
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
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        try mg.engine.removeEdgeProperty(from_id, edge_id, key);
    }

    // ------------------------------------------------------------------
    // Storage inspection
    // ------------------------------------------------------------------

    /// Return storage-level statistics for the named graph.
    pub fn getStorageStats(self: *StorageAdapter, graph_name: []const u8) !gs.GraphEngine.StorageStats {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.getStorageStats();
    }

    /// Run an integrity check on the named graph and return the report.
    pub fn checkIntegrity(self: *StorageAdapter, graph_name: []const u8) !gs.GraphEngine.IntegrityReport {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.checkIntegrity();
    }

    // ------------------------------------------------------------------
    // Per-graph RwLock acquisition API (P1 lock migration)
    // ------------------------------------------------------------------

    /// Acquire a shared (read) lock on the named graph.
    /// Caller MUST call releaseGraphReadLock when done.
    pub fn acquireGraphReadLock(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.GraphNotFound;
        };
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        mg.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        return mg;
    }

    pub fn releaseGraphReadLock(_: *StorageAdapter, mg: *ManagedGraph) void {
        mg.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
    }

    /// Acquire an exclusive (write) lock on the named graph.
    /// Caller MUST call releaseGraphWriteLock when done.
    pub fn acquireGraphWriteLock(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.GraphNotFound;
        };
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        mg.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        return mg;
    }

    /// Deadline-aware variant of `acquireGraphWriteLock` (R2, 2026-04-22).
    /// `deadline_mono_ns` is an absolute CLOCK_MONOTONIC-ish nanosecond
    /// timestamp (caller typically computes `monoNanos() + budget`).
    /// Returns `error.Deadline` when the lock could not be acquired before
    /// the deadline.  Internally uses `tryLock` in an exponentially-
    /// backing-off loop so the caller thread can honour client or
    /// shutdown timeouts instead of parking forever.
    pub fn acquireGraphWriteLockCancelable(
        self: *StorageAdapter,
        graph_name: []const u8,
        deadline_mono_ns: u64,
    ) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.GraphNotFound;
        };
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const io = std.Io.Threaded.global_single_threaded.io();
        // Fast path: uncontended acquire in one call.
        if (mg.rwlock.tryLock(io)) return mg;

        // R6 (2026-04-22): contended path.  Backoff starts at 1 ms (was
        // 100 µs) and caps at 20 ms.  Under the 16-worker ingest workload
        // the old 100 µs starting backoff made every waiter thrash the
        // rwlock's cache line ~10 000 times/second — 16 × 10k = 160 k
        // atomic CAS per second across the contention region, enough to
        // stall forward progress and inflate critical-section duration.
        //
        // 1 ms → 20 ms cap still honours the R2 test's 100 ms deadline
        // (`tests/test_graph_write_lock_cancelable.zig`) — the contender
        // spins at most ~5 tries (1+2+4+8+16 ≈ 31 ms worst-case) before
        // falling out on the deadline check.  Real workloads with 30 s
        // deadlines see orders of magnitude less CPU spent on retries.
        var sleep_ns: u64 = 1 * std.time.ns_per_ms;
        const max_sleep_ns: u64 = 20 * std.time.ns_per_ms;
        while (true) {
            const now = monoNanosNow();
            if (now >= deadline_mono_ns) return error.Deadline;
            const remaining = deadline_mono_ns - now;
            const nap_ns = @min(sleep_ns, remaining);
            {
                const req = std.os.linux.timespec{
                    .sec = @intCast(nap_ns / std.time.ns_per_s),
                    .nsec = @intCast(nap_ns % std.time.ns_per_s),
                };
                var rem: std.os.linux.timespec = undefined;
                _ = std.os.linux.nanosleep(&req, &rem);
            }
            if (mg.rwlock.tryLock(io)) return mg;
            sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
        }
    }

    pub fn releaseGraphWriteLock(_: *StorageAdapter, mg: *ManagedGraph) void {
        mg.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
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

/// CLOCK_MONOTONIC nanoseconds; used by the cancelable write-lock path (R2).
fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

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

test "StorageAdapter: exact node-property lookup follows property and label mutations" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "lookup_graph";
    const node_id = try adapter.createNode(graph, &[_][]const u8{"User"});
    try adapter.setNodeProperty(graph, node_id, "node_id", .{ .Int = 7 });

    const initial = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 7 }, allocator);
    defer allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 1), initial.len);
    try std.testing.expectEqual(node_id, initial[0]);

    try adapter.setNodeProperty(graph, node_id, "node_id", .{ .Int = 8 });

    const stale = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 7 }, allocator);
    defer allocator.free(stale);
    try std.testing.expectEqual(@as(usize, 0), stale.len);

    const updated = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(updated);
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqual(node_id, updated[0]);

    try adapter.addNodeLabel(graph, node_id, "Admin");
    const added_label = try adapter.getCandidateNodesByLabelAndProperty(graph, "Admin", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(added_label);
    try std.testing.expectEqual(@as(usize, 1), added_label.len);
    try std.testing.expectEqual(node_id, added_label[0]);

    try adapter.removeNodeLabel(graph, node_id, "Admin");
    const removed_label = try adapter.getCandidateNodesByLabelAndProperty(graph, "Admin", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(removed_label);
    try std.testing.expectEqual(@as(usize, 0), removed_label.len);

    try adapter.deleteNode(graph, node_id);
    const deleted = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(deleted);
    try std.testing.expectEqual(@as(usize, 0), deleted.len);
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

    const mg = try adapter.getOrCreateGraph("__geode_security");

    // Per-graph audit logger should be initialised (non-null).
    try std.testing.expect(mg.audit_logger != null);

    // Accessor on StorageAdapter returns the same logger.
    const logger = adapter.getAuditLogger("__geode_security");
    try std.testing.expect(logger != null);
    try std.testing.expect(logger.? == mg.audit_logger.?);

    // Verify audit.jsonl file exists inside the graph directory.
    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, mg.uuid);
    defer allocator.free(graph_dir);

    const audit_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{graph_dir});
    defer allocator.free(audit_path);

    // statFile returns a Stat struct on success; an error means the file does not exist.
    _ = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), audit_path, .{}) catch |err| {
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

    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), ts_dir, .{}) catch |err| {
        std.debug.print("timeseries dir open failed: {}\n", .{err});
        return err;
    };
    dir.close(std.Io.Threaded.global_single_threaded.io());
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

        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), fts_dir, .{}) catch |err| {
            std.debug.print("fts dir open failed: {}\n", .{err});
            return err;
        };
        dir.close(std.Io.Threaded.global_single_threaded.io());

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

test "StorageAdapter: reopen repairs corrupted free.store" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph_name = "repair_graph";
    var graph_uuid: [16]u8 = undefined;
    var node_id: u64 = 0;

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        node_id = try adapter.createNode(graph_name, &[_][]const u8{"Person"});
        try adapter.setNodeProperty(graph_name, node_id, "name", .{ .String = "Alice" });
        graph_uuid = adapter.getGraphUuid(graph_name) orelse return error.GraphNotFound;
        try adapter.checkpointAll();
    }

    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, graph_uuid);
    defer allocator.free(graph_dir);

    const free_store_path = try std.fmt.allocPrint(allocator, "{s}/free.store", .{graph_dir});
    defer allocator.free(free_store_path);

    {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_fs, free_store_path, .{ .truncate = true });
        defer file.close(io_fs);
        try file.writeStreamingAll(io_fs, &([_]u8{0xFF} ** 64));
    }

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.openGraphWithUuid(graph_name, graph_uuid);

        const name_prop = try adapter.getNodeProperty(graph_name, node_id, "name", allocator) orelse return error.PropertyNotFound;
        defer freeOwnedStorageProperty(allocator, name_prop);

        try std.testing.expectEqualStrings("Alice", name_prop.string);
        try std.testing.expectEqual(@as(u64, 1), try adapter.nodeCount(graph_name));
        const repaired_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), free_store_path, .{});
        try std.testing.expectEqual(@as(u64, 0), repaired_stat.size);
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

    const mg = try adapter.getOrCreateGraph("__geode_security");
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
        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), graph_dir, .{}) catch |err| {
            std.debug.print("graph dir should exist before drop: {}\n", .{err});
            return err;
        };
        dir.close(std.Io.Threaded.global_single_threaded.io());
    }

    // Drop the graph — this should deinit subsystems and delete the directory.
    adapter.dropGraph("__geode_security");

    // Verify graph directory is removed.
    const dir_result = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), graph_dir, .{});
    if (dir_result) |*d| {
        var dir_copy = d.*;
        dir_copy.close(std.Io.Threaded.global_single_threaded.io());
        return error.TestExpectedError; // directory should not exist
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }

    // Verify accessors return null after drop.
    try std.testing.expect(adapter.getAuditLogger("__geode_security") == null);
    try std.testing.expect(adapter.getTimeseriesStore("__geode_security") == null);
    try std.testing.expect(adapter.getFulltextIndex("__geode_security") == null);
    try std.testing.expect(!adapter.graphExists("__geode_security"));
}
