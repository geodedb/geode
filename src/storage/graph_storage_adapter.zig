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
const sharded_store = gs.sharded_store;
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

    /// Per-shard rwlocks covering the N partitions of
    /// `GraphStore.nodes` / `GraphStore.edges` / adjacency.  Writers
    /// take one of these in EXCLUSIVE mode for ops routed to a
    /// specific node_id; full-graph exclusive ops
    /// (`acquireWholeGraphExclusive`) take `rwlock` EXCLUSIVE which
    /// blocks new shard writers (they take `rwlock` SHARED first).
    /// Readers that need a consistent full-graph snapshot acquire
    /// every entry in shard-index ascending order.
    ///
    /// Phase 2 of the graph-sharding plan
    /// (docs/superpowers/plans/2026-04-24-graph-sharding-and-wal-
    /// group-commit.md).  See `acquireShardWriteLock` below for the
    /// full locking protocol including cross-shard lock ordering.
    shard_locks: [sharded_store.SHARD_COUNT]std.Io.RwLock =
        [_]std.Io.RwLock{std.Io.RwLock.init} ** sharded_store.SHARD_COUNT,

    /// Dedicated lock for the `merge_prop_index` (which is keyed by a
    /// composite string, not by node_id, and therefore cannot be
    /// sharded by the same function as the other structures).  MERGE
    /// probes acquire this SHARED for the fast-path lookup;
    /// insert-if-absent takes it EXCLUSIVE.
    merge_prop_index_lock: std.Io.RwLock = std.Io.RwLock.init,

    /// Brief-hold mutex covering the other outer-StringHashMap
    /// metadata operations that shard writers touch indirectly
    /// (label_index getOrPut, graphs put, id_maps init,
    /// edge_type_index getOrPut).  Holds are microseconds — the
    /// outer StringHashMap operation is a single bucket probe +
    /// optional rehash, not the per-label posting-list mutation
    /// which is already guarded by its own `LabelPosting.mutex`.
    ///
    /// Under the shard-locked write protocol (Phase 2), a shard
    /// writer holds `mg.rwlock` SHARED + `shard_locks[idx]`
    /// EXCLUSIVE for the duration of the op.  Inside that scope
    /// the writer briefly takes this mutex for the single moment
    /// it touches a string-keyed outer map.  Release before the
    /// shard lock so the mutex is always held strictly inside the
    /// shard lock scope — prevents a future consumer from taking
    /// shard lock + string_indexes_mutex in a different order and
    /// deadlocking.
    string_indexes_mutex: std.Io.Mutex = std.Io.Mutex.init,

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
// R8 (2026-04-22): Per-statement engine-txn batching.
//
// After R7, each adapter mutation method (createNode, setNodeProperty, ...)
// wraps its engine sub-ops in a single explicit engine transaction — so a
// single adapter call is one WAL fsync.  That still means a GQL statement
// like `CREATE (n:User {p1, p2, p3, p4, p5})` costs 1 (createNode) + 5
// (setNodeProperty) = 6 fsyncs, because the executor calls the adapter
// once per sub-step.
//
// R8 lets the caller open a *statement-scoped* engine transaction that
// subsequent adapter mutations join (skipping their own beginTxn/commitTxn
// pair) so the whole statement commits with a single fsync:
//
//   const txn = try adapter.beginStatementTxn(graph_name);
//   errdefer txn.abort();
//   // adapter.createNode / adapter.setNodeProperty etc. now join `txn`
//   try txn.commit();                  // ONE WAL fsync
//
// Rules:
//   - Uses a `threadlocal var` — only the thread that opened the txn sees
//     it.  The per-graph exclusive write lock is held across the
//     statement, so no other thread can concurrently mutate the same
//     graph — the thread-local is safe.
//   - Mutations on a DIFFERENT graph than the active StatementTxn fall
//     back to the regular auto-commit path (per-sub-op fsync).
//   - `abort()` / `commit()` clear the thread-local.  If neither is
//     called before the guarded scope exits, the engine will keep the
//     txn record as "begin without commit" until replay rolls it back,
//     which is correct but wasteful — use `errdefer txn.abort()`.
// ============================================================================

/// Per-statement engine transaction handle returned by
/// `StorageAdapter.beginStatementTxn`.
pub const StatementTxn = struct {
    mg: *ManagedGraph,
    txn_id: gs.TxnId,
    graph_name: []const u8, // non-owning — adapter's engines map owns the storage

    /// Commit the statement txn → exactly one WAL fsync.
    pub fn commit(self: *StatementTxn) !void {
        t_current_statement_txn = null;
        try self.mg.engine.commitTxn(self.txn_id);
    }

    /// Abort the statement txn (no fsync beyond the ABORT record append).
    /// Safe to call from `errdefer`.
    pub fn abort(self: *StatementTxn) void {
        t_current_statement_txn = null;
        self.mg.engine.abortTxn(self.txn_id) catch {};
    }
};

threadlocal var t_current_statement_txn: ?*StatementTxn = null;

// R9 (2026-04-22): session-scoped engine txn — spans an entire Geode
// BEGIN TX / COMMIT block.  The msft-graph client sends batches of the
// form `BEGIN; CREATE ... (×38); COMMIT`.  Before R9 each CREATE opened
// its own engine txn + fsync; after R9 the whole batch commits with a
// SINGLE fsync.  Separate thread-local from the per-statement slot so
// a nested per-statement txn (e.g. DDL during a Geode txn) can still
// take precedence.  `currentStatementTxnForGraph` checks the
// per-statement slot first, then falls back to the session slot.
threadlocal var t_session_engine_txn: ?*StatementTxn = null;

// R9 (2026-04-22, lazy variant): backing storage for the session
// engine txn when the executor opens it lazily (on the first mutation
// inside a Geode txn) and therefore has no `ServerState.session_engine_txn_storage`
// pointer in scope.  Lives in thread-local so the backing slot is
// automatically per-session (one QUIC stream = one thread).  Populated
// by `beginSessionTxnLazy`; cleared by `commitSessionTxn` /
// `abortSessionTxn`.
threadlocal var t_session_engine_txn_storage_lazy: StatementTxn = undefined;

/// Return the thread-local statement txn if it targets `graph_name`; else null.
/// Adapter mutation methods consult this to decide whether to batch into an
/// existing transaction or spin their own (the R7 behaviour).  Priority:
/// 1. per-statement txn (R8), 2. session txn (R9).
pub fn currentStatementTxnForGraph(graph_name: []const u8) ?*StatementTxn {
    if (t_current_statement_txn) |txn| {
        if (std.mem.eql(u8, txn.graph_name, graph_name)) return txn;
    }
    if (t_session_engine_txn) |txn| {
        if (std.mem.eql(u8, txn.graph_name, graph_name)) return txn;
    }
    return null;
}

/// True when an R9 session-scoped engine txn is active on this thread.
/// Callers use this to decide whether to open a per-statement txn (no —
/// the session txn covers us) or not.
pub fn hasSessionEngineTxn() bool {
    return t_session_engine_txn != null;
}

/// Return the graph name of the active session-scoped engine txn, if any.
pub fn sessionEngineTxnGraph() ?[]const u8 {
    if (t_session_engine_txn) |txn| return txn.graph_name;
    return null;
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
        // R8 (2026-04-22): if the current thread already has an open
        // `StatementTxn` on this graph, JOIN it instead of opening a fresh
        // txn — the whole GQL statement (createNode + N setNodeProperty)
        // will then commit with one fsync instead of N+1.
        //
        // The engine's auto-commit variants (putNode, addLabel,
        // putProperty) each call `txn_manager.begin()` + `commit()`, and
        // `commit()` always ends with `wal.sync()` (fsync) — see
        // `graph_storage/src/txn.zig:67-85`.
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const txn: gs.TxnId = if (stmt_txn) |s| s.txn_id else try mg.engine.beginTxn();
        errdefer if (stmt_txn == null) {
            mg.engine.abortTxn(txn) catch {};
        };

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

        if (stmt_txn == null) try mg.engine.commitTxn(txn);
        return node_id;
    }

    /// Single-node "bulk-ingest" fast path (Task 11 of the enterprise-ingest-
    /// throughput plan).  Creates one node with `labels` and `props` in
    /// `graph_name`, returning the allocated slot's public node id.
    ///
    /// Used by the QUIC handler's fast-path dispatch for the msft-graph hot
    /// pattern `CREATE (n:Label {k: literal_or_param, ...})` (Tasks 10 + 11).
    /// Bypasses the full executor's AST traversal, row materialization, and
    /// RLS filter.  Caller is responsible for having already verified the
    /// pattern via `bulk_ingest.matchSingleStatement`.
    ///
    /// Transaction semantics:
    ///   * Joins the active session / statement engine txn (R8 / R9) via the
    ///     thread-local `t_current_statement_txn` / `t_session_engine_txn`
    ///     slots, exactly like `createNode` does.  When no statement txn is
    ///     open, opens one for the duration of this call.
    ///   * The `txn_id_opt` parameter is accepted for interface parity with
    ///     future bulk-edge / bulk-batch variants; when provided, callers
    ///     must have registered the txn id via `beginStatementTxn`
    ///     beforehand (the adapter still consults the thread-locals).
    ///
    /// Undo-log contract:
    ///   The caller MUST NOT be inside a rollback-able Geode transaction
    ///   when invoking `bulkInsertNode` — this method SKIPS the
    ///   `txn_undo_log.logCreateNode` append that `executeCreate` performs
    ///   on every CREATE statement.  That is the primary performance lever
    ///   of the bulk path (GEODE_BULK_INGEST=1 is opt-in for exactly this
    ///   reason).  Under the bulk env var, rollbacks of individual
    ///   statements are not supported; the operator is expected to either
    ///   commit the whole batch or nuke the target data directory.
    ///
    /// In-memory store consistency:
    ///   Routes through `GraphStore.createNodeWithGraph` + `setNodeProperty`
    ///   so the in-memory node map, label index, and merge-property index
    ///   stay in sync with the persistent engine state.  Reads that land
    ///   against the in-memory snapshot therefore see the newly inserted
    ///   node without waiting for a persistence flush.
    pub fn bulkInsertNode(
        self: *StorageAdapter,
        graph_name: []const u8,
        labels: []const []const u8,
        props: []const PropKV,
        txn_id_opt: ?u64,
    ) !u64 {
        _ = txn_id_opt; // reserved for future extensions; thread-local is source of truth.

        // Match the executor's R8/R9 fsync batching: if a session or
        // per-statement engine txn is already active on this thread for
        // `graph_name`, the adapter's `createNode` / `setNodeProperty`
        // will join it automatically.  Otherwise, open a per-statement
        // txn so the createNode + N×setNodeProperty sub-ops commit with
        // ONE WAL fsync instead of N+1.  Without this step the bulk
        // path regresses vs `executeCreate` because each sub-op would
        // open its own auto-commit engine txn.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                // Graph might not exist yet — fall through to per-sub-op
                // auto-commit; `createNode` lazily creates the graph.
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const node_id = try store.createNodeWithGraph(labels, graph_name);

        // Set properties directly on the store — this writes to both the
        // adapter (via vtable → setNodeProperty → putPropertyTxn) and
        // the in-memory map.  All sub-ops join the statement / session
        // engine txn opened above (or pre-existing), so the whole CREATE
        // commits with a SINGLE WAL fsync.
        for (props) |kv| {
            try store.setNodeProperty(node_id, kv.key, kv.value);
        }

        if (stmt_txn_open) try stmt_txn.commit();
        return node_id;
    }

    /// Helper for `bulkInsertNode`: ensure the graph engine is registered
    /// before we call `beginStatementTxn` (which requires an existing
    /// graph and returns GraphNotFound otherwise).  Returns
    /// `GraphNotFound` only if `getOrCreateGraph` fails — in the normal
    /// case it populates the engines map and returns successfully.
    fn ensureGraphExistsForBulk(self: *StorageAdapter, graph_name: []const u8) !void {
        _ = try self.getOrCreateGraph(graph_name);
    }

    /// Phase 2 variant of `bulkInsertNode` that consumes a
    /// pre-allocated id (via `GraphStore.reserveNodeId`) and
    /// self-locks under the shard-locked write protocol:
    ///
    ///   1. Take `mg.rwlock` SHARED (fences whole-graph-exclusive
    ///      ops like RESTORE).
    ///   2. Take `shard_locks[shardIndex(reserved_id)]` EXCLUSIVE
    ///      (serialises writes to this shard's state).
    ///   3. Take `mg.string_indexes_mutex` briefly for the outer
    ///      StringHashMap operations (graph registration, label
    ///      index getOrPut).  Held only around the
    ///      `createNodeWithReservedIdAndGraph` call.
    ///   4. Write properties via `setNodeProperty` under the shard
    ///      lock only (the property chain is sharded because the
    ///      node_id keys into the sharded store).
    ///
    /// Called by `ShardedCoordinator.applyShardBatch` in Task 6.
    /// Does NOT open a statement txn on its own — the coordinator
    /// wraps the whole batch in one statement txn for WAL fsync
    /// amortisation across every op in the shard batch.
    ///
    /// Same undo-log + in-memory-store contracts as `bulkInsertNode`.
    pub fn bulkInsertNodeWithReservedId(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        labels: []const []const u8,
        props: []const PropKV,
    ) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        mg.rwlock.lockSharedUncancelable(io);
        defer mg.rwlock.unlockShared(io);

        const idx = sharded_store.shardIndex(reserved_id);
        mg.shard_locks[idx].lockUncancelable(io);
        defer mg.shard_locks[idx].unlock(io);

        mg.string_indexes_mutex.lockUncancelable(io);
        const create_result = store.createNodeWithReservedIdAndGraph(reserved_id, labels, graph_name);
        mg.string_indexes_mutex.unlock(io);
        try create_result;

        // Property writes touch the sharded store only; no further
        // string-index lock needed (setNodeProperty operates on the
        // per-node properties map, not any outer StringHashMap).
        for (props) |kv| {
            try store.setNodeProperty(reserved_id, kv.key, kv.value);
        }
        return reserved_id;
    }

    /// Phase 2 shard-locked edge-insert variant.  Both endpoint ids
    /// are known to the caller, so the helper routes writes to the
    /// owning shards for source and target.
    ///
    /// Locking protocol:
    ///   1. Take `mg.rwlock` SHARED.
    ///   2. If `shardIndex(source_id) == shardIndex(target_id)`,
    ///      take that one shard's EXCLUSIVE lock.
    ///   3. Otherwise, take the lower-index shard's EXCLUSIVE lock
    ///      first, then the higher-index shard's — ascending order
    ///      to prevent deadlock with any other cross-shard op.
    ///   4. Take `mg.string_indexes_mutex` briefly for the
    ///      edge_type_index getOrPut inside `createEdgeWithGraph`.
    ///   5. Write properties via `setEdgeProperty` under the shard
    ///      locks.
    ///
    /// Race handling: re-checks source/target existence under the
    /// held locks and surfaces `SourceNodeNotFound` / `TargetNodeNotFound`
    /// if either was deleted in a prior batch.  Matches the
    /// `bulkInsertEdgeWithIds` semantics so the coordinator's
    /// orphan-edge silent-skip path still works.
    pub fn bulkInsertEdgeWithIdsShardLocked(
        self: *StorageAdapter,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
    ) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        const src_shard = sharded_store.shardIndex(source_id);
        const dst_shard = sharded_store.shardIndex(target_id);

        mg.rwlock.lockSharedUncancelable(io);
        defer mg.rwlock.unlockShared(io);

        if (src_shard == dst_shard) {
            mg.shard_locks[src_shard].lockUncancelable(io);
            defer mg.shard_locks[src_shard].unlock(io);
            return self.bulkInsertEdgeInnerShardLocked(mg, store, graph_name, source_id, target_id, rel_type, props);
        } else {
            const first = @min(src_shard, dst_shard);
            const second = @max(src_shard, dst_shard);
            mg.shard_locks[first].lockUncancelable(io);
            mg.shard_locks[second].lockUncancelable(io);
            defer {
                mg.shard_locks[second].unlock(io);
                mg.shard_locks[first].unlock(io);
            }
            return self.bulkInsertEdgeInnerShardLocked(mg, store, graph_name, source_id, target_id, rel_type, props);
        }
    }

    fn bulkInsertEdgeInnerShardLocked(
        self: *StorageAdapter,
        mg: *ManagedGraph,
        store: *graph_store.GraphStore,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
    ) !u64 {
        _ = self;
        const io = std.Io.Threaded.global_single_threaded.io();

        if (store.nodes.getPtr(source_id) == null) return error.SourceNodeNotFound;
        if (store.nodes.getPtr(target_id) == null) return error.TargetNodeNotFound;

        mg.string_indexes_mutex.lockUncancelable(io);
        const create_result = store.createEdgeWithGraph(source_id, target_id, rel_type, graph_name);
        mg.string_indexes_mutex.unlock(io);
        const edge_id = try create_result;

        for (props) |kv| {
            try store.setEdgeProperty(edge_id, kv.key, kv.value);
        }
        return edge_id;
    }

    /// Phase 2 shard-locked MERGE variant.  Probe under
    /// `merge_prop_index_lock` SHARED for the fast path; on miss,
    /// acquire the shard lock for `reserved_id` + the merge-index
    /// lock EXCLUSIVE and re-probe before inserting.
    ///
    /// The `reserved_id` may be abandoned if the probe discovers an
    /// existing candidate (id-space leak is bounded by ingest size;
    /// same behaviour as the pre-sharding coordinator under race).
    pub fn bulkMergeNodeWithReservedId(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        label: []const u8,
        merge_key: []const u8,
        merge_value: graph_store.PropertyValue,
        on_create_props: []const PropKV,
    ) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        mg.rwlock.lockSharedUncancelable(io);
        defer mg.rwlock.unlockShared(io);

        // Probe phase: shared lock on merge-index, fast return on hit.
        mg.merge_prop_index_lock.lockSharedUncancelable(io);
        var probe_id: u64 = 0;
        const probe = store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &probe_id);
        mg.merge_prop_index_lock.unlockShared(io);
        if (probe == .found) return probe_id;

        // Insert phase: take the shard lock for the reserved id plus
        // the merge-index lock EXCLUSIVE.  Re-probe under the
        // exclusive lock so concurrent MERGEs for the same key
        // serialise correctly.
        const idx = sharded_store.shardIndex(reserved_id);
        mg.shard_locks[idx].lockUncancelable(io);
        defer mg.shard_locks[idx].unlock(io);

        mg.merge_prop_index_lock.lockUncancelable(io);
        defer mg.merge_prop_index_lock.unlock(io);

        var reprobe_id: u64 = 0;
        if (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &reprobe_id) == .found) {
            return reprobe_id;
        }

        mg.string_indexes_mutex.lockUncancelable(io);
        const labels_slice = [_][]const u8{label};
        const create_result = store.createNodeWithReservedIdAndGraph(reserved_id, &labels_slice, graph_name);
        mg.string_indexes_mutex.unlock(io);
        try create_result;

        // Property writes under the shard lock — setNodeProperty will
        // update the merge_prop_index (which is protected by the
        // merge_prop_index_lock we already hold EXCLUSIVE above).
        try store.setNodeProperty(reserved_id, merge_key, merge_value);
        for (on_create_props) |kv| {
            try store.setNodeProperty(reserved_id, kv.key, kv.value);
        }

        return reserved_id;
    }

    /// Key + value pair accepted by `bulkInsertNode`.  The caller owns both
    /// the key bytes and the value payload for the duration of the call; the
    /// adapter/store copies what it needs internally before returning.
    pub const PropKV = struct {
        key: []const u8,
        value: graph_store.PropertyValue,
    };

    /// Task 12 (enterprise-ingest-throughput): MATCH+CREATE edge fast path.
    ///
    /// Resolves `(src_label, filter_key=src_node_id)` and
    /// `(dst_label, filter_key=dst_node_id)` via `lookupMergeCandidate`
    /// (O(1) merge-prop index probe against the in-memory store), then
    /// creates the edge + writes each property under a single statement
    /// engine txn so the whole operation commits with ONE WAL fsync.
    ///
    /// The caller must supply BOTH endpoints' label + filter key + filter
    /// value — mirroring the msft-graph edges_*.jsonl hot-path pattern
    /// `MATCH (a:L1 {node_id: 'x'}), (b:L2 {node_id: 'y'}) CREATE
    /// (a)-[:T {props}]->(b)`.
    ///
    /// Errors:
    ///   * `error.SourceNodeNotFound` — the (src_label, src_filter_key=value)
    ///     probe returned null (or not-indexable, which means the caller
    ///     cannot use the fast path — dispatcher should fall back).
    ///   * `error.TargetNodeNotFound` — symmetric.
    ///   * anything else — propagates the underlying graph-store /
    ///     engine error.
    ///
    /// Undo-log contract: same as `bulkInsertNode` — SKIPS the undo log.
    /// The operator opts into the bulk path via `GEODE_BULK_INGEST=1` and
    /// commits or nukes the whole batch; individual-statement rollback is
    /// not supported.
    ///
    /// In-memory store consistency: routes through
    /// `GraphStore.createEdgeWithGraph` + `setEdgeProperty`, so the
    /// in-memory edge map, adjacency index, and edge-type index stay in
    /// sync with the persistent engine state.
    pub fn bulkInsertEdge(
        self: *StorageAdapter,
        graph_name: []const u8,
        src_label: []const u8,
        src_node_id: graph_store.PropertyValue,
        src_filter_key: []const u8,
        dst_label: []const u8,
        dst_node_id: graph_store.PropertyValue,
        dst_filter_key: []const u8,
        rel_type: []const u8,
        props: []const PropKV,
        txn_id_opt: ?u64,
    ) !u64 {
        _ = txn_id_opt; // thread-local statement-txn slots are source of truth.

        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // Endpoint resolution — both lookups MUST succeed for a fast-path
        // edge.  `.not_indexable` means the value type (e.g. list / map)
        // can't use the merge-prop index; dispatchers should treat that
        // as "fall back to full executor" not a user-visible error, so
        // we map it here to the same not-found error code — the caller
        // can distinguish if needed.
        var src_id: u64 = undefined;
        switch (store.lookupMergeCandidate(graph_name, src_label, src_filter_key, src_node_id, &src_id)) {
            .found => {},
            .not_found => return error.SourceNodeNotFound,
            .not_indexable => return error.SourceNodeNotFound,
        }
        var dst_id: u64 = undefined;
        switch (store.lookupMergeCandidate(graph_name, dst_label, dst_filter_key, dst_node_id, &dst_id)) {
            .found => {},
            .not_found => return error.TargetNodeNotFound,
            .not_indexable => return error.TargetNodeNotFound,
        }

        // Statement-txn batching: same pattern as `bulkInsertNode`.  Join
        // an existing session/statement txn if one is active on this
        // graph; otherwise open a per-statement txn so the addEdge +
        // per-property putProperty sub-ops commit with ONE WAL fsync.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        // Create the edge — `createEdgeWithGraph` routes through the
        // adapter vtable (which joins the statement txn internally via
        // `StorageAdapter.createEdge`) AND updates the in-memory
        // `GraphStore.edges` map / adjacency index / edge-type index.
        const edge_id = try store.createEdgeWithGraph(src_id, dst_id, rel_type, graph_name);

        // Per-property: route through `GraphStore.setEdgeProperty` which
        // hits the adapter (R12 patch keeps this inside our statement
        // txn) plus the in-memory edge property map.
        for (props) |kv| {
            try store.setEdgeProperty(edge_id, kv.key, kv.value);
        }

        if (stmt_txn_open) try stmt_txn.commit();
        return edge_id;
    }

    /// Task 15/16 (enterprise-ingest-throughput): pure MATCH-side resolver for
    /// the two-phase lock split on the bulk edge path.
    ///
    /// Returns the node id of the single node in `graph_name` that matches
    /// `(label, prop_key = prop_value)` via the merge-prop index.  On miss,
    /// returns `missing_err` — the caller passes `error.SourceNodeNotFound`
    /// or `error.TargetNodeNotFound` to keep wire-level error mapping
    /// consistent with `bulkInsertEdge`.
    ///
    /// This function is a PURE READ: it consults `merge_prop_index.get` +
    /// `nodes.get` only (see Phase 4 invariants in
    /// `docs/performance/2026-04-23-enterprise-ingest/phase4-invariants.md`),
    /// so it is safe to call under `acquireGraphReadLock`.
    ///
    /// `.not_indexable` results are mapped to `missing_err` for the same
    /// reason as `bulkInsertEdge` — the fast path cannot handle
    /// non-indexable values and must treat them as a not-found for the
    /// caller's purposes.
    pub fn lookupNodeByMergeKey(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: graph_store.PropertyValue,
        missing_err: anyerror,
    ) !u64 {
        _ = self;
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        var id: u64 = undefined;
        switch (store.lookupMergeCandidate(graph_name, label, prop_key, prop_value, &id)) {
            .found => return id,
            .not_found, .not_indexable => return missing_err,
        }
    }

    /// Task 15/16 (enterprise-ingest-throughput): write-phase counterpart of
    /// `bulkInsertEdge` that skips the MATCH lookups.
    ///
    /// Caller must have resolved `source_id` + `target_id` via
    /// `lookupNodeByMergeKey` under a shared read lock BEFORE calling this
    /// method, and must hold the exclusive per-graph write lock for the
    /// duration of this call.
    ///
    /// Race handling: between the caller's Phase 1 read-lock lookup and
    /// this Phase 2 write-lock apply, another writer could have deleted one
    /// of the endpoint nodes.  In that case `createEdgeWithGraph` stores
    /// the edge record but the adapter-side `nodeSlot` lookup yields null
    /// and the persisted-edge branch is skipped — the in-memory edge will
    /// point at a vanished endpoint.  To surface this cleanly, we re-check
    /// `nodes.get` for both endpoints under the write lock before writing.
    /// A miss returns `error.SourceNodeNotFound` / `error.TargetNodeNotFound`
    /// — the same errors the single-phase `bulkInsertEdge` raises for a
    /// missing endpoint, so callers need no new wire mapping.
    ///
    /// Other invariants (undo-log skip, statement-txn batching, in-memory
    /// index maintenance) match `bulkInsertEdge`.
    pub fn bulkInsertEdgeWithIds(
        self: *StorageAdapter,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        txn_id_opt: ?u64,
    ) !u64 {
        _ = txn_id_opt; // thread-local statement-txn slots are source of truth.

        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // Race re-check: the caller resolved the endpoints under the shared
        // read lock, then released it before acquiring the write lock we
        // now hold.  A concurrent writer could have deleted either node in
        // the gap.  Surface that cleanly before mutating any state.
        if (store.nodes.getPtr(source_id) == null) return error.SourceNodeNotFound;
        if (store.nodes.getPtr(target_id) == null) return error.TargetNodeNotFound;

        // Statement-txn batching: same pattern as `bulkInsertEdge`.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        const edge_id = try store.createEdgeWithGraph(source_id, target_id, rel_type, graph_name);
        for (props) |kv| {
            try store.setEdgeProperty(edge_id, kv.key, kv.value);
        }

        if (stmt_txn_open) try stmt_txn.commit();
        return edge_id;
    }

    /// Bulk-ingest MERGE fast path for simple single-label, single-merge-key
    /// MERGE statements — counterpart to `bulkInsertNode` for the
    /// msft-graph nodes_*.jsonl hot path (677/677 node-phase statements
    /// were MERGEs per the Phase 1 trace).
    ///
    /// Semantics:
    ///   1. Probe the merge-prop index for `(graph, label, merge_key, merge_value)`
    ///      via `GraphStore.lookupMergeCandidate`.  If a node is found, return
    ///      its id unchanged (this is the ON MATCH no-op — the caller has
    ///      pre-screened that no `ON MATCH SET` clause is attached).
    ///   2. If not found, insert a new node with `[label]` and properties
    ///      `(merge_key, merge_value) ++ on_create_props`.  The merge key is
    ///      written as a regular property on the node (msft-graph's
    ///      `node_id` is both the merge key and a property in the output
    ///      view of the node) so a subsequent MATCH + filter path can find
    ///      it via either the merge-prop index or a property scan.
    ///
    /// Race handling: the two-phase QUIC dispatcher calls this helper after
    /// taking the per-graph exclusive write lock.  In the tests (which call
    /// the adapter directly, without an outer lock) a shared-read probe +
    /// exclusive-write insert is encoded inside this single call: both the
    /// probe and the insert go through the globally-held graph mutex via
    /// the in-memory store, so a 16-way concurrent `MERGE (n:U {id:'X'})`
    /// for the SAME id inserts exactly once (the lookup-then-insert is not
    /// atomic per-call, but the graph-store mutex serialises the
    /// `createNodeWithGraph` + `merge_prop_index.put` pair, and subsequent
    /// threads re-probe the index inside this same helper and observe the
    /// winning insertion).  The concurrent-MERGE-race test pins this
    /// invariant.
    ///
    /// Undo-log contract: same as `bulkInsertNode` — SKIPS the undo log.
    /// Callers must be running under `GEODE_BULK_INGEST=1` or equivalent
    /// opt-in (the QUIC dispatcher gates the call, and tests call the
    /// adapter directly to mirror that setup).
    ///
    /// Transaction semantics: joins the active session / statement engine
    /// txn via the R8 / R9 thread-local slots, exactly like `bulkInsertNode`.
    /// When no txn is open, opens a per-statement txn for the duration of
    /// the insert so the createNode + N × setNodeProperty sub-ops commit
    /// with ONE WAL fsync.
    ///
    /// Errors: propagates `createNodeWithGraph` / `setNodeProperty` errors
    /// unchanged.  Never returns a sentinel "found" flag — the caller can
    /// tell a creation from a match only by observing the node id
    /// (`store.nodes.count()` delta) if it cares.
    pub fn bulkMergeNode(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        merge_key: []const u8,
        merge_value: graph_store.PropertyValue,
        on_create_props: []const PropKV,
        txn_id_opt: ?u64,
    ) !u64 {
        _ = txn_id_opt; // reserved for future extensions; thread-local is source of truth.

        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // Phase 1 (inline): merge-prop index probe.  `.not_indexable`
        // means the value type (list / map) cannot use the index; the
        // QUIC dispatcher pre-screens `isScalarPropExpr`, so hitting this
        // branch is unexpected — surface a distinct error so a
        // test / trace can differentiate "real miss" from "misclassified
        // fast-path candidate".
        var existing_id: u64 = undefined;
        switch (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &existing_id)) {
            .found => return existing_id,
            .not_found => {},
            .not_indexable => return error.MergeValueNotIndexable,
        }

        // Phase 2: no node yet — insert.  Match the executor's R8/R9
        // fsync batching: join an open session/statement txn or open one
        // so the createNode + N × setNodeProperty commit with a single
        // WAL fsync.  See `bulkInsertNode` for the full rationale.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        // Concurrent-MERGE safety re-check: another thread that raced
        // through Phase 1 with us may have committed the new node before
        // we opened our statement txn.  Re-probe; if a peer won the
        // race, return their id without inserting.  The graph-store
        // mutex serialises the probe, so this double-check catches the
        // narrow window between our own Phase 1 miss and createNodeWithGraph.
        switch (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &existing_id)) {
            .found => {
                if (stmt_txn_open) stmt_txn.abort();
                return existing_id;
            },
            .not_found, .not_indexable => {},
        }

        const labels = [_][]const u8{label};
        const node_id = try store.createNodeWithGraph(&labels, graph_name);

        // Write the merge key as a regular property (msft-graph's node_id
        // is both the merge key and a node property) and then all
        // ON CREATE SET properties.  `setNodeProperty` updates both the
        // adapter (via vtable → statement-txn putPropertyTxn) and the
        // in-memory map + merge-prop index.
        try store.setNodeProperty(node_id, merge_key, merge_value);
        for (on_create_props) |kv| {
            // Skip a duplicate merge_key entry in ON CREATE SET (caller
            // is allowed to specify it; we already wrote it above).
            if (std.mem.eql(u8, kv.key, merge_key)) continue;
            try store.setNodeProperty(node_id, kv.key, kv.value);
        }

        if (stmt_txn_open) try stmt_txn.commit();
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

        // R10 (2026-04-22): join the active session/statement engine txn
        // when one exists on this graph so a whole edges_*.jsonl batch of
        // N CREATE edge statements commits with a single WAL fsync.  The
        // engine's `addEdge` auto-commit variant costs ~10 ms on SSD —
        // dominant in workloads with thousands of edges per batch (msft-
        // graph edges_signed_in_to / located_at have 8K+ rows each).
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        if (stmt_txn) |s| {
            return mg.engine.addEdgeTxn(from_id, to_id, rel_type, s.txn_id);
        }
        return mg.engine.addEdge(from_id, to_id, rel_type);
    }

    /// Delete an edge by its endpoints and edge ID.
    pub fn deleteEdge(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // R10 (2026-04-22): join active session/statement engine txn when
        // present — keeps DELETE ... edge batches at one fsync per batch.
        if (currentStatementTxnForGraph(graph_name)) |s| {
            try mg.engine.removeEdgeTxn(from_id, to_id, edge_id, s.txn_id);
            return;
        }
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
        // `createNode` for the fsync rationale.
        //
        // R8 (2026-04-22): join the current thread's StatementTxn when
        // one is active on this graph, so the whole GQL statement
        // commits with a single fsync.
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const txn: gs.TxnId = if (stmt_txn) |s| s.txn_id else try mg.engine.beginTxn();
        errdefer if (stmt_txn == null) {
            mg.engine.abortTxn(txn) catch {};
        };

        const new_prop_head = try mg.engine.putPropertyTxn(rec.prop_head, key, storage_val, txn);

        // Update the node record with the (possibly changed) prop_head.
        rec.prop_head = new_prop_head;
        try mg.engine.putNodeTxn(node_id, rec, txn);

        if (stmt_txn == null) try mg.engine.commitTxn(txn);

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

    /// Set a property on an edge.
    ///
    /// R12 (2026-04-22): when a session/statement engine txn is active
    /// on this graph, replicate the engine's `setEdgeProperty` logic
    /// using `putPropertyTxn` + adjacency-list updates so the whole
    /// operation joins the active txn and incurs NO extra WAL fsync.
    /// Without this branch, the engine's auto-commit variant runs
    /// `txn_manager.begin()` + `commit()` (and thus one `wal.sync()`)
    /// per edge property — for a msft-graph edge with 5 properties and
    /// 2186 edges per batch that's >10K fsyncs per batch, overwhelming
    /// the 120 s `acquireGraphWriteLockCancelable` budget.
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

        if (currentStatementTxnForGraph(graph_name)) |s| {
            // R12: manual setEdgeProperty using Txn variants.  Mirrors the
            // upstream engine_edge_props.setEdgeProperty logic 1:1, just
            // threading our session/statement txn through `putPropertyTxn`.
            const edge_entry = mg.engine.edge_index.get(edge_id) orelse return error.EdgeNotFound;
            if (edge_entry.from != from_id or edge_entry.neighbor != to_id) return error.EdgeNotFound;

            const from_rec = (try mg.engine.node_store.getNode(from_id)) orelse return error.NodeNotFound;
            const found_prop_head = edge_entry.prop_head;

            const new_head_u64 = try mg.engine.putPropertyTxn(@as(u64, found_prop_head), key, storage_val, s.txn_id);
            const new_head: u32 = std.math.cast(u32, new_head_u64) orelse return error.Overflow;

            if (new_head != found_prop_head) {
                _ = try mg.engine.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head);
                const to_rec = (try mg.engine.node_store.getNode(to_id)) orelse return error.NodeNotFound;
                _ = try mg.engine.adj_in.updateEdgePropHead(to_rec.in_head, edge_id, new_head);

                if (mg.engine.edge_index.getPtr(edge_id)) |idx_entry| {
                    idx_entry.prop_head = new_head;
                }
            }

            // Keep the property-chain index in sync (same as upstream does).
            if (found_prop_head != 0 and found_prop_head != new_head) {
                mg.engine.property_index.removeChain(found_prop_head);
            }
            try mg.engine.refreshPropertyChainIndex(new_head_u64);
            return;
        }
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
        // R10 (2026-04-22): join active session/statement engine txn.
        if (currentStatementTxnForGraph(graph_name)) |s| {
            try mg.engine.addLabelTxn(node_id, label_id, s.txn_id);
        } else {
            try mg.engine.addLabel(node_id, label_id);
        }
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
        // R10 (2026-04-22): join active session/statement engine txn.
        if (currentStatementTxnForGraph(graph_name)) |s| {
            try mg.engine.removeLabelTxn(node_id, label_id, s.txn_id);
        } else {
            try mg.engine.removeLabel(node_id, label_id);
        }
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

        // 2026-04-23: contended path.  Starts at 200 µs and caps at 4 ms
        // (previously 1 ms → 20 ms under R6).  R6's wider ladder was
        // calibrated for the pre-Task-16 critical section (~60 ms p95,
        // ~1 s max lock_wait).  Post-Task-16 + Task-19, the write
        // critical section is <= ~3 ms worst-case (coordinator batch
        // apply) and typically ~100 µs (single fast-path apply), so the
        // old 20 ms ceiling leaves every contending worker idle ~15 ms
        // past the point the lock is free — a 5-10× amplifier we no
        // longer need.
        //
        // New ladder 200 µs → 400 µs → 800 µs → 1.6 ms → 3.2 ms → cap
        // at 4 ms.  Worst-case contender sleep before first tryLock
        // check is 200 µs, well matched to the common ~100 µs apply
        // window.  R2 test's 100 ms deadline still honoured: contender
        // spins up to ~100/0.2 = 500 iterations cheaply, far more than
        // the deadline check granularity requires.  CAS-thrash
        // concern from R6 (10 k attempts/s/waiter) remains bounded:
        // 16 × 5 k = 80 k CAS/s at the lower bound — comparable to
        // the `std.Thread.Mutex` contended path and well inside
        // cache-line bandwidth limits on any modern x86.
        var sleep_ns: u64 = 200 * std.time.ns_per_us;
        const max_sleep_ns: u64 = 4 * std.time.ns_per_ms;
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

    /// R8 (2026-04-22): begin a per-statement engine transaction on `graph_name`.
    ///
    /// After this call, the current thread's subsequent adapter mutation
    /// calls on the same graph (createNode, setNodeProperty, createEdge,
    /// deleteNode, etc.) JOIN this transaction instead of opening their
    /// own engine txn.  The entire statement commits with a single WAL
    /// fsync via `StatementTxn.commit`.
    ///
    /// Caller contract:
    ///   const txn = try adapter.beginStatementTxn(graph_name);
    ///   errdefer txn.abort();
    ///   // …adapter mutation calls on `graph_name`…
    ///   try txn.commit();
    ///
    /// It is a bug to call `beginStatementTxn` while another statement
    /// txn is already active on the current thread — the per-graph
    /// exclusive write lock is expected to serialise statements on a
    /// given graph, so nested opens should be impossible in normal
    /// operation.  We log and return `error.NestedStatementTxn` rather
    /// than silently overwriting the thread-local.
    pub fn beginStatementTxn(self: *StorageAdapter, graph_name: []const u8, out: *StatementTxn) !void {
        if (t_current_statement_txn != null) {
            log.err("adapter.beginStatementTxn called with an existing statement txn on this thread (graph={s})", .{graph_name});
            return error.NestedStatementTxn;
        }

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.engines.get(graph_name) orelse return error.GraphNotFound;
        };

        const txn_id = try mg.engine.beginTxn();
        out.* = .{
            .mg = mg,
            .txn_id = txn_id,
            .graph_name = mg.name, // owned by ManagedGraph, stable while engines map keeps the entry
        };
        t_current_statement_txn = out;
    }

    /// R9 (2026-04-22): open an engine transaction that lives for the
    /// lifetime of a Geode-level logical transaction (BEGIN TX … COMMIT).
    /// All subsequent mutation calls from this thread on `graph_name`
    /// join this engine txn, so the whole Geode batch commits with a
    /// SINGLE WAL fsync.
    ///
    /// Restriction: only one session engine txn per thread at a time.
    /// If a Geode txn touches multiple graphs, the caller opens additional
    /// per-statement txns via `beginStatementTxn` (preferred) or simply
    /// lets the adapter's auto-batch (R7) path handle those sub-ops.
    pub fn beginSessionTxn(self: *StorageAdapter, graph_name: []const u8, out: *StatementTxn) !void {
        if (t_session_engine_txn != null) {
            log.err("adapter.beginSessionTxn called with an existing session txn on this thread (graph={s})", .{graph_name});
            return error.NestedSessionTxn;
        }
        if (t_current_statement_txn != null) {
            log.err("adapter.beginSessionTxn called while a per-statement txn is already open (graph={s})", .{graph_name});
            return error.NestedStatementTxn;
        }

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.engines.get(graph_name) orelse return error.GraphNotFound;
        };

        const txn_id = try mg.engine.beginTxn();
        out.* = .{
            .mg = mg,
            .txn_id = txn_id,
            .graph_name = mg.name,
        };
        t_session_engine_txn = out;
    }

    /// R9: commit the session-scoped engine txn → ONE WAL fsync.
    pub fn commitSessionTxn(self: *StorageAdapter) !void {
        _ = self;
        const txn = t_session_engine_txn orelse return error.NoActiveSessionTxn;
        t_session_engine_txn = null;
        try txn.mg.engine.commitTxn(txn.txn_id);
    }

    /// R9: abort the session-scoped engine txn (no data-durability fsync).
    pub fn abortSessionTxn(self: *StorageAdapter) void {
        _ = self;
        const txn = t_session_engine_txn orelse return;
        t_session_engine_txn = null;
        txn.mg.engine.abortTxn(txn.txn_id) catch {};
    }

    /// R9 (2026-04-22, lazy): open a session-scoped engine txn using the
    /// thread-local `t_session_engine_txn_storage_lazy` backing slot.
    /// Used by the executor when it encounters the first mutation in a
    /// Geode BEGIN TX … COMMIT batch and has no direct pointer into
    /// `ServerState.session_engine_txn_storage`.  The slot is
    /// thread-local so it's naturally per-session (one QUIC stream handler
    /// runs on one pool thread).
    pub fn beginSessionTxnLazy(self: *StorageAdapter, graph_name: []const u8) !void {
        try self.beginSessionTxn(graph_name, &t_session_engine_txn_storage_lazy);
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

// ===========================================================================
// Per-shard lock helpers (Phase 2, graph-sharding plan)
// ===========================================================================

/// Acquire EXCLUSIVE mode on the single shard owning `key`.
/// Protocol: take `mg.rwlock` SHARED (coexists with other shard
/// writers; blocks whole-graph-exclusive ops), then take
/// `shard_locks[shardIndex(key)]` EXCLUSIVE.
///
/// Use for bulk mutations keyed by a specific `node_id`.  For
/// cross-shard ops (edge insert spanning two shards) see the
/// ascending-index acquire pattern in `bulkInsertEdgeWithIds`.
pub fn acquireShardWriteLock(mg: *ManagedGraph, key: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    mg.rwlock.lockSharedUncancelable(io);
    const idx = sharded_store.shardIndex(key);
    mg.shard_locks[idx].lockUncancelable(io);
}

/// Release the shard lock + whole-graph SHARED acquired by
/// `acquireShardWriteLock`.
pub fn releaseShardWriteLock(mg: *ManagedGraph, key: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const idx = sharded_store.shardIndex(key);
    mg.shard_locks[idx].unlock(io);
    mg.rwlock.unlockShared(io);
}

/// Deadline-aware variant used by the coordinator's shard-apply
/// loop.  `deadline_mono_ns` caps waiting on the shard-lock step
/// only — the whole-graph SHARED rwlock is assumed fast because it
/// only conflicts with whole-graph EXCLUSIVE ops (RESTORE, etc.)
/// which are rare.
pub fn acquireShardWriteLockCancelable(
    mg: *ManagedGraph,
    key: u64,
    deadline_mono_ns: u64,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    mg.rwlock.lockSharedUncancelable(io);
    errdefer mg.rwlock.unlockShared(io);
    const idx = sharded_store.shardIndex(key);
    if (mg.shard_locks[idx].tryLock(io)) return;
    var sleep_ns: u64 = 200 * std.time.ns_per_us;
    const max_sleep_ns: u64 = 4 * std.time.ns_per_ms;
    while (true) {
        const now = monoNanosNowLocal();
        if (now >= deadline_mono_ns) return error.Deadline;
        const remaining = deadline_mono_ns - now;
        const nap_ns = @min(sleep_ns, remaining);
        const req = std.os.linux.timespec{
            .sec = @intCast(nap_ns / std.time.ns_per_s),
            .nsec = @intCast(nap_ns % std.time.ns_per_s),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
        if (mg.shard_locks[idx].tryLock(io)) return;
        sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
    }
}

/// Acquire `mg.rwlock` EXCLUSIVE + every shard lock EXCLUSIVE in
/// ascending index order.  Used by RESTORE, bulk DELETE-all, and
/// other full-graph writes that need global isolation.  The rwlock
/// EXCLUSIVE acquire blocks any new `acquireShardWriteLock` caller
/// (they take `rwlock` SHARED first) and waits for in-flight shard
/// writers to release their SHARED hold.
pub fn acquireWholeGraphExclusive(mg: *ManagedGraph) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    mg.rwlock.lockUncancelable(io);
    for (&mg.shard_locks) |*sl| sl.lockUncancelable(io);
}

/// Release the whole-graph EXCLUSIVE acquired by
/// `acquireWholeGraphExclusive`.  Releases shard locks in reverse
/// index order (symmetry with acquire; not strictly required by
/// the rwlock contract, but keeps debug traces sane).
pub fn releaseWholeGraphExclusive(mg: *ManagedGraph) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var i: usize = sharded_store.SHARD_COUNT;
    while (i > 0) {
        i -= 1;
        mg.shard_locks[i].unlock(io);
    }
    mg.rwlock.unlock(io);
}

fn monoNanosNowLocal() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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
