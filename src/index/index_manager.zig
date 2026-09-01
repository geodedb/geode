const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

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
const Allocator = std.mem.Allocator;
const btree = @import("btree.zig");
const fulltext = @import("fulltext.zig");
const hnsw = @import("hnsw_lib");
const rtree = @import("rtree_lib");
const advanced_types = @import("advanced_types_index.zig");
const jsonb_inverted = @import("jsonb_inverted.zig");
const domain_trie = @import("domain_trie.zig");
const vector_index = @import("vector_index.zig");
const spatial_index = @import("spatial_index.zig");
const graph_store = @import("../graph_store.zig");
const eval_extended = @import("../eval_extended.zig");
const property_codec = @import("../property_value_codec.zig");
const vector_types = @import("../types/vector.zig");
const geographic = @import("../types/geographic.zig");
const jsonb = @import("../types/jsonb.zig");
const url = @import("../types/url.zig");
const cryptographic = @import("../types/cryptographic.zig");

var global_index_manager: ?*IndexManager = null;
var global_index_manager_mutex: std.Io.Mutex = std.Io.Mutex.init;

// Comprehensive index management for graph database
// CANARY: REQ=REQ-PERF-MERGE-001; FEATURE="IndexRebuild"; ASPECT=DeferredRebuild; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-10
pub const IndexManager = struct {
    allocator: Allocator,
    property_indexes: std.StringHashMap(PropertyIndex),
    label_indexes: std.StringHashMap(LabelIndex),
    composite_indexes: std.ArrayList(CompositeIndex),
    fulltext_indexes: std.StringHashMap(fulltext.FullTextIndex),
    spatial_indexes: std.StringHashMap(*rtree.RTree),
    vector_indexes: std.StringHashMap(*anyopaque), // hnsw.Hnsw instances
    // Advanced type indexes
    advanced_vector_indexes: std.StringHashMap(*advanced_types.VectorIndexWrapper),
    advanced_spatial_indexes: std.StringHashMap(*advanced_types.SpatialIndexWrapper),
    advanced_network_indexes: std.StringHashMap(*advanced_types.NetworkIndexWrapper),
    advanced_signature_indexes: std.StringHashMap(*advanced_types.SignatureIndexWrapper),
    advanced_interval_indexes: std.StringHashMap(*advanced_types.IntervalIndexWrapper),
    advanced_jsonb_indexes: std.StringHashMap(*jsonb_inverted.JsonbInvertedIndex),
    advanced_domain_indexes: std.StringHashMap(*domain_trie.DomainTrie),
    advanced_property_indexes: std.StringHashMap(AdvancedPropertyIndex),
    // GAP-0918: lightweight dimension-validation registry for vector-indexed
    // (label, property) pairs, keyed by index name. Deliberately separate
    // from the wrapper machinery (no rebuild churn); dim 0 = not yet
    // established, adopted from the first vector written.
    vector_dim_registry: std.StringHashMap(VectorDimEntry),
    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimRegistry; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
    // ENG-3922(a): the same dimension pin for an (label, property) pair that has
    // NO vector index. `vector_dim_registry` above is keyed by INDEX NAME, so it
    // holds zero entries for an unindexed pair and the guard covered nothing —
    // yet mixed dimensions under one property are a data-integrity defect with
    // or without an index (`vector_cosine` over a dim-4/dim-3 pair yields NULL,
    // a knn scan silently drops the non-conforming rows).
    //
    // Keyed by "graph\x00label\x00property". Scope is PER GRAPH, deliberately
    // unlike the indexed registry: an HNSW index is a process-global object
    // keyed by index name whose backfill selects by label+property with no graph
    // filter, so its pin has to be process-wide (pinned by
    // tests/test_eng3912_dim_pinning.zig). An unindexed property has no such
    // shared object behind it, so the same label+property in another graph is a
    // separate property with its own dimension.
    //
    // Entries are created LAZILY on the first vector write to the pair and
    // seeded from COMMITTED data (`scanCommittedVectorDim`), so nothing a
    // refused statement carries can pin anything, and a restart re-derives the
    // pin from what is stored rather than from whichever write happens to
    // arrive first.
    vector_dim_unindexed: std.StringHashMap(VectorDimEntry),
    /// Guards `vector_dim_unindexed` — BOTH its structure and its entries.
    ///
    /// Unlike the indexed registry, which is only ever populated from DDL
    /// (under the statement's exclusive graph lock), this map is INSERTED INTO
    /// from the write path, and two writes to different graphs run under
    /// different graph locks — i.e. genuinely concurrently.
    ///
    /// LOCK ORDERING: leaf. It is acquired while the caller already holds its
    /// per-graph write lock, and it is NEVER held while calling into
    /// `graph_store` (the one-shot seed scan, which takes the store's own
    /// locks, runs with this mutex released — see `unindexedVectorDim`).
    vector_dim_mutex: std.Io.Mutex = std.Io.Mutex.init,
    statistics: IndexStatistics,
    /// GAP-0511: Mutex protecting rebuild operations so they can safely run
    /// outside the graph write lock without racing with concurrent rebuilds.
    rebuild_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// geode#875 RC-2b: the set of indexes currently being rebuilt into a
    /// SHADOW wrapper, each mapped to the entity ids written while its window
    /// was armed. Mirrors `fts_storage_adapter.rebuilds` exactly: a rebuild
    /// snapshots the id set under a brief SHARED graph lock and then builds
    /// with NO lock held, so a write landing mid-build would otherwise be lost
    /// against the pre-write snapshot. Armed by `beginRebuild`, fed by
    /// `noteWriteDuringRebuild` (called from the write path via
    /// `tryIncrementalInsertForProperty`), drained by `endRebuild`.
    rebuild_windows: std.StringHashMapUnmanaged(std.AutoHashMapUnmanaged(u64, void)) = .{},
    /// Guards `rebuild_windows` only. LOCK ORDERING: leaf, and strictly BELOW
    /// `rebuild_mutex` — `tryIncrementalInsertForProperty` takes
    /// `rebuild_mutex` and then this one; nothing ever takes `rebuild_mutex`
    /// while holding this.
    rebuild_window_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // GAP-0918: entry in the vector dimension-validation registry.
    pub const VectorDimEntry = struct {
        label: []const u8,
        property: []const u8,
        /// ENG-3922(a): the graph this pin is scoped to, for an entry in
        /// `vector_dim_unindexed`. Null for an INDEXED pin, which is
        /// process-wide because the HNSW index it guards is (see the field
        /// comment on `vector_dim_unindexed`). Owned; read by
        /// `dropUnindexedVectorDimsForGraph`.
        graph: ?[]const u8 = null,
        /// The established dimension, or 0 when no vector has been COMMITTED
        /// under this (label, property) yet.
        dim: u16,
        /// ENG-3912(d): whether the one-shot "derive the pin from already
        /// committed data" pass has run for this entry. The pin is not
        /// persisted anywhere, so after a restart the entry comes back with
        /// `dim = 0`; without this the FIRST write after a restart would
        /// establish whatever dimension it happened to carry and the guard
        /// would silently invert (mixed dimensions accepted).
        seed_attempted: bool = false,
    };

    pub const IndexType = enum {
        btree,
        hash,
        fulltext,
        spatial,
        bitmap,
        vector,
        // Advanced type indexes
        vector_f32,
        spatial_geographic,
        network_cidr,
        signature_crypto,
        interval_tree,
        jsonb_inverted,
        domain_trie,
    };

    pub const AdvancedPropertyIndex = struct {
        name: []const u8,
        label: []const u8,
        property: []const u8,
        index_type: IndexType,
    };

    pub const PropertyIndex = struct {
        name: []const u8,
        label: []const u8,
        property: []const u8,
        type: IndexType,
        unique: bool,
        btree_index: ?*anyopaque, // Actually btree.BTree([]const u8, u64, order)
        hash_index: ?HashIndex,
        spatial_index: ?*rtree.RTree,
        vector_index: ?*anyopaque, // Actually hnsw.Hnsw
        fulltext_index: ?*fulltext.FullTextIndex,
        statistics: IndexStats,
    };

    pub const LabelIndex = struct {
        name: []const u8,
        label: []const u8,
        type: IndexType,
        node_ids: std.ArrayList(u64),
        bitmap: ?BitMap,
        statistics: IndexStats,
    };

    pub const CompositeIndex = struct {
        name: []const u8,
        label: []const u8,
        properties: [][]const u8,
        type: IndexType,
        unique: bool,
        btree_index: ?*anyopaque, // Actually btree.BTree([]const u8, u64, order)
        statistics: IndexStats,
    };

    pub const IndexStats = struct {
        entries: u64,
        size_bytes: u64,
        height: u32,
        fill_factor: f64,
        last_updated: i64,
        read_count: u64,
        write_count: u64,
        cache_hits: u64,
        cache_misses: u64,
    };

    pub const IndexStatistics = struct {
        total_indexes: u64,
        total_entries: u64,
        total_size_bytes: u64,
        index_hits: u64,
        index_misses: u64,
        rebuild_count: u64,
        last_analyze: i64,
    };

    pub const HashIndex = struct {
        buckets: []Bucket,
        size: usize,
        count: usize,

        pub const Bucket = struct {
            entries: std.ArrayList(Entry),
        };

        pub const Entry = struct {
            key: []const u8,
            value: u64,
        };
    };

    pub const BitMap = struct {
        bits: []u64,
        size: usize,

        pub fn set(self: *BitMap, index: usize) void {
            const word = index / 64;
            const bit = index % 64;
            self.bits[word] |= @as(u64, 1) << @intCast(bit);
        }

        pub fn clear(self: *BitMap, index: usize) void {
            const word = index / 64;
            const bit = index % 64;
            self.bits[word] &= ~(@as(u64, 1) << @intCast(bit));
        }

        pub fn isSet(self: *BitMap, index: usize) bool {
            const word = index / 64;
            const bit = index % 64;
            return (self.bits[word] & (@as(u64, 1) << @intCast(bit))) != 0;
        }
    };

    pub fn init(allocator: Allocator) IndexManager {
        return .{
            .allocator = allocator,
            .property_indexes = std.StringHashMap(PropertyIndex).init(allocator),
            .label_indexes = std.StringHashMap(LabelIndex).init(allocator),
            .composite_indexes = std.ArrayList(CompositeIndex).empty,
            .fulltext_indexes = std.StringHashMap(fulltext.FullTextIndex).init(allocator),
            .spatial_indexes = std.StringHashMap(*rtree.RTree).init(allocator),
            .vector_indexes = std.StringHashMap(*anyopaque).init(allocator),
            // Initialize advanced type indexes
            .advanced_vector_indexes = std.StringHashMap(*advanced_types.VectorIndexWrapper).init(allocator),
            .advanced_spatial_indexes = std.StringHashMap(*advanced_types.SpatialIndexWrapper).init(allocator),
            .advanced_network_indexes = std.StringHashMap(*advanced_types.NetworkIndexWrapper).init(allocator),
            .advanced_signature_indexes = std.StringHashMap(*advanced_types.SignatureIndexWrapper).init(allocator),
            .advanced_interval_indexes = std.StringHashMap(*advanced_types.IntervalIndexWrapper).init(allocator),
            .advanced_jsonb_indexes = std.StringHashMap(*jsonb_inverted.JsonbInvertedIndex).init(allocator),
            .advanced_domain_indexes = std.StringHashMap(*domain_trie.DomainTrie).init(allocator),
            .advanced_property_indexes = std.StringHashMap(AdvancedPropertyIndex).init(allocator),
            .vector_dim_registry = std.StringHashMap(VectorDimEntry).init(allocator),
            .vector_dim_unindexed = std.StringHashMap(VectorDimEntry).init(allocator),
            .statistics = .{
                .total_indexes = 0,
                .total_entries = 0,
                .total_size_bytes = 0,
                .index_hits = 0,
                .index_misses = 0,
                .rebuild_count = 0,
                .last_analyze = 0,
            },
        };
    }

    pub fn deinit(self: *IndexManager) void {
        var prop_it = self.property_indexes.iterator();
        while (prop_it.next()) |entry| {
            if (entry.value_ptr.btree_index) |tree_ptr| {
                const BTreeType = btree.BTree([]const u8, u64, 32);
                const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));
                tree.deinit();
                self.allocator.destroy(tree);
            }
            if (entry.value_ptr.hash_index) |*hash| {
                for (hash.buckets) |*bucket| {
                    bucket.entries.deinit(self.allocator);
                }
                self.allocator.free(hash.buckets);
            }
        }
        self.property_indexes.deinit();

        var label_it = self.label_indexes.iterator();
        while (label_it.next()) |entry| {
            entry.value_ptr.node_ids.deinit(self.allocator);
            if (entry.value_ptr.bitmap) |*bm| {
                self.allocator.free(bm.bits);
            }
        }
        self.label_indexes.deinit();

        for (self.composite_indexes.items) |*index| {
            if (index.btree_index) |tree_ptr| {
                const BTreeType = btree.BTree([]const u8, u64, 32);
                const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));
                tree.deinit();
                self.allocator.destroy(tree);
            }
        }
        self.composite_indexes.deinit(self.allocator);

        var ft_it = self.fulltext_indexes.iterator();
        while (ft_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.fulltext_indexes.deinit();

        var spatial_it = self.spatial_indexes.iterator();
        while (spatial_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.spatial_indexes.deinit();

        var vector_it = self.vector_indexes.iterator();
        while (vector_it.next()) |entry| {
            // Cast to Hnsw and deinit
            var hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(entry.value_ptr.*));
            hnsw_index.deinit();
            self.allocator.destroy(hnsw_index);
        }
        self.vector_indexes.deinit();

        // geode#875 RC-2b: any rebuild window still armed at shutdown.
        var rebuild_window_it = self.rebuild_windows.iterator();
        while (rebuild_window_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.rebuild_windows.deinit(self.allocator);

        // Cleanup advanced type indexes
        var adv_vector_it = self.advanced_vector_indexes.iterator();
        while (adv_vector_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.advanced_vector_indexes.deinit();

        var adv_spatial_it = self.advanced_spatial_indexes.iterator();
        while (adv_spatial_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.advanced_spatial_indexes.deinit();

        var adv_network_it = self.advanced_network_indexes.iterator();
        while (adv_network_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.advanced_network_indexes.deinit();

        var adv_signature_it = self.advanced_signature_indexes.iterator();
        while (adv_signature_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.advanced_signature_indexes.deinit();

        var adv_interval_it = self.advanced_interval_indexes.iterator();
        while (adv_interval_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.advanced_interval_indexes.deinit();

        var adv_jsonb_it = self.advanced_jsonb_indexes.iterator();
        while (adv_jsonb_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.advanced_jsonb_indexes.deinit();

        var adv_domain_it = self.advanced_domain_indexes.iterator();
        while (adv_domain_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.advanced_domain_indexes.deinit();

        var adv_prop_it = self.advanced_property_indexes.iterator();
        while (adv_prop_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.label);
            self.allocator.free(entry.value_ptr.property);
        }
        self.advanced_property_indexes.deinit();

        var vdim_it = self.vector_dim_registry.iterator();
        while (vdim_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.label);
            self.allocator.free(entry.value_ptr.property);
        }
        self.vector_dim_registry.deinit();

        var vdim_free_it = self.vector_dim_unindexed.iterator();
        while (vdim_free_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.label);
            self.allocator.free(entry.value_ptr.property);
            if (entry.value_ptr.graph) |g| self.allocator.free(g);
        }
        self.vector_dim_unindexed.deinit();
    }

    // Create a property index
    pub fn createPropertyIndex(
        self: *IndexManager,
        name: []const u8,
        label: []const u8,
        property: []const u8,
        index_type: IndexType,
        unique: bool,
    ) !void {
        const index = PropertyIndex{
            .name = try self.allocator.dupe(u8, name),
            .label = try self.allocator.dupe(u8, label),
            .property = try self.allocator.dupe(u8, property),
            .type = index_type,
            .unique = unique,
            .btree_index = if (index_type == .btree) blk: {
                const BTreeType = btree.BTree([]const u8, u64, 32);
                const tree = self.allocator.create(BTreeType) catch break :blk null;
                tree.* = BTreeType.init(self.allocator);
                break :blk @as(?*anyopaque, tree);
            } else null,
            .hash_index = if (index_type == .hash)
                try self.createHashIndex(1024)
            else
                null,
            .spatial_index = if (index_type == .spatial) blk: {
                const spatial = try self.allocator.create(rtree.RTree);
                spatial.* = try rtree.RTree.init(self.allocator, 16);
                try self.spatial_indexes.put(name, spatial);
                break :blk spatial;
            } else null,
            .vector_index = if (index_type == .vector) blk: {
                // Default to 128-dimensional vectors with M=16, ef_construction=200
                const vector = try self.allocator.create(hnsw.Hnsw);
                vector.* = try hnsw.Hnsw.init(self.allocator, 128, .euclidean, .{
                    .m = 16,
                    .ef_construction = 200,
                    .ef_search = 200,
                });
                try self.vector_indexes.put(name, vector);
                break :blk @as(?*anyopaque, vector);
            } else null,
            .fulltext_index = null,
            .statistics = .{
                .entries = 0,
                .size_bytes = 0,
                .height = 0,
                .fill_factor = 0,
                .last_updated = compat_timestamp(),
                .read_count = 0,
                .write_count = 0,
                .cache_hits = 0,
                .cache_misses = 0,
            },
        };

        try self.property_indexes.put(name, index);
        self.statistics.total_indexes += 1;
    }

    // Create a label index
    pub fn createLabelIndex(
        self: *IndexManager,
        name: []const u8,
        label: []const u8,
        use_bitmap: bool,
    ) !void {
        const index = LabelIndex{
            .name = try self.allocator.dupe(u8, name),
            .label = try self.allocator.dupe(u8, label),
            .type = if (use_bitmap) .bitmap else .hash,
            .node_ids = std.ArrayList(u64).empty,
            .bitmap = if (use_bitmap) blk: {
                const bm = BitMap{
                    .bits = try self.allocator.alloc(u64, 1024),
                    .size = 1024 * 64,
                };
                @memset(bm.bits, 0);
                break :blk bm;
            } else null,
            .statistics = .{
                .entries = 0,
                .size_bytes = 0,
                .height = 0,
                .fill_factor = 0,
                .last_updated = compat_timestamp(),
                .read_count = 0,
                .write_count = 0,
                .cache_hits = 0,
                .cache_misses = 0,
            },
        };

        try self.label_indexes.put(name, index);
        self.statistics.total_indexes += 1;
    }

    // Create a composite index
    pub fn createCompositeIndex(
        self: *IndexManager,
        name: []const u8,
        label: []const u8,
        properties: [][]const u8,
        unique: bool,
    ) !void {
        var props = try self.allocator.alloc([]const u8, properties.len);
        for (properties, 0..) |prop, i| {
            props[i] = try self.allocator.dupe(u8, prop);
        }

        const index = CompositeIndex{
            .name = try self.allocator.dupe(u8, name),
            .label = try self.allocator.dupe(u8, label),
            .properties = props,
            .type = .btree,
            .unique = unique,
            .btree_index = blk: {
                const BTreeType = btree.BTree([]const u8, u64, 32);
                const tree = self.allocator.create(BTreeType) catch break :blk null;
                tree.* = BTreeType.init(self.allocator);
                break :blk @as(?*anyopaque, tree);
            },
            .statistics = .{
                .entries = 0,
                .size_bytes = 0,
                .height = 0,
                .fill_factor = 0,
                .last_updated = compat_timestamp(),
                .read_count = 0,
                .write_count = 0,
                .cache_hits = 0,
                .cache_misses = 0,
            },
        };

        try self.composite_indexes.append(self.allocator, index);
        self.statistics.total_indexes += 1;
    }

    // Create a full-text index
    pub fn createFullTextIndex(
        self: *IndexManager,
        name: []const u8,
        label: []const u8,
        properties: [][]const u8,
    ) !void {
        _ = self;
        _ = name;
        _ = label;
        _ = properties;

        // After the fts-storage migration the FullTextIndex facade no longer
        // has a standalone `init` — it must be constructed with `initBacked`
        // over a per-graph `FtsStorageAdapter`, which `IndexManager` does not
        // own. The live FTS path is `ManagedGraph.getFulltextIndex` in
        // graph_storage_adapter.zig (adapter created in `initFtsForGraph`).
        // This IndexManager entry point has no callers and the adapter-backed
        // CREATE-INDEX wiring is a follow-up task; fail explicitly rather than
        // silently no-op so a future caller is forced through the owning path.
        return error.FullTextIndexRequiresAdapter;
    }

    // Insert into property index
    pub fn insertIntoPropertyIndex(
        self: *IndexManager,
        index_name: []const u8,
        key: []const u8,
        node_id: u64,
    ) !void {
        if (self.property_indexes.getPtr(index_name)) |index| {
            index.statistics.write_count += 1;
            const t0 = otel.internal.clock.unixNanoNow();

            switch (index.type) {
                .btree => {
                    if (index.btree_index) |tree_ptr| {
                        const BTreeType = btree.BTree([]const u8, u64, 32);
                        const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));
                        const key_copy = try self.allocator.dupe(u8, key);
                        try tree.insert(key_copy, node_id);
                        index.statistics.entries += 1;
                        const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
                        otel_metrics.recordIndexUpdate(.btree, .create, elapsed_s);
                    }
                },
                .hash => {
                    if (index.hash_index) |*hash| {
                        try self.insertIntoHashIndex(hash, key, node_id);
                        index.statistics.entries += 1;
                        const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
                        otel_metrics.recordIndexUpdate(.hash, .create, elapsed_s);
                    }
                },
                else => {},
            }

            self.statistics.total_entries += 1;
        }
    }

    // Insert into label index
    pub fn insertIntoLabelIndex(
        self: *IndexManager,
        index_name: []const u8,
        node_id: u64,
    ) !void {
        if (self.label_indexes.getPtr(index_name)) |index| {
            index.statistics.write_count += 1;

            try index.node_ids.append(self.allocator, node_id);

            if (index.bitmap) |*bm| {
                if (node_id < bm.size) {
                    bm.set(node_id);
                }
            }

            index.statistics.entries += 1;
            self.statistics.total_entries += 1;
        }
    }

    // Lookup in property index
    pub fn lookupPropertyIndex(
        self: *IndexManager,
        index_name: []const u8,
        key: []const u8,
    ) !?u64 {
        const t0 = otel.internal.clock.unixNanoNow();
        if (self.property_indexes.getPtr(index_name)) |index| {
            index.statistics.read_count += 1;

            switch (index.type) {
                .btree => {
                    if (index.btree_index) |tree_ptr| {
                        const BTreeType = btree.BTree([]const u8, u64, 32);
                        const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));
                        if (tree.search(key)) |value| {
                            index.statistics.cache_hits += 1;
                            self.statistics.index_hits += 1;
                            const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
                            otel_metrics.recordIndexLookup(.btree, elapsed_s, .success);
                            return value;
                        }
                        index.statistics.cache_misses += 1;
                        self.statistics.index_misses += 1;
                        const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
                        otel_metrics.recordIndexLookup(.btree, elapsed_s, .error_);
                    }
                },
                .hash => {
                    if (index.hash_index) |*hash| {
                        if (self.lookupInHashIndex(hash, key)) |value| {
                            index.statistics.cache_hits += 1;
                            self.statistics.index_hits += 1;
                            const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
                            otel_metrics.recordIndexLookup(.hash, elapsed_s, .success);
                            return value;
                        }
                        const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
                        otel_metrics.recordIndexLookup(.hash, elapsed_s, .error_);
                    }
                },
                else => {},
            }

            index.statistics.cache_misses += 1;
            self.statistics.index_misses += 1;
        }

        return null;
    }

    /// Range scan on property index using B-tree range query
    /// Returns all node IDs where the indexed value is between start_key and end_key
    /// CANARY: REQ=REQ-GQL-INDEX-RANGE-001; FEATURE="B-Tree Range Scan"; ASPECT=QUERY; STATUS=TESTED; TEST=tests/index_operations_test.sh; OWNER=storage; UPDATED=2026-01-15
    pub fn rangeScan(
        self: *IndexManager,
        index_name: []const u8,
        start_key: []const u8,
        end_key: []const u8,
        inclusive: bool,
    ) ![]u64 {
        if (self.property_indexes.getPtr(index_name)) |index| {
            index.statistics.read_count += 1;

            if (index.btree_index) |tree_ptr| {
                const BTreeType = btree.BTree([]const u8, u64, 32);
                const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));

                // Perform actual B-tree range scan
                const results = try tree.range(start_key, end_key);
                defer self.allocator.free(results);

                // Extract node IDs from results
                var node_ids = std.ArrayList(u64).empty;

                for (results) |r| {
                    const key_cmp_start = std.mem.order(u8, r.key, start_key);
                    const key_cmp_end = std.mem.order(u8, r.key, end_key);

                    // Check inclusivity
                    const in_range = if (inclusive)
                        (key_cmp_start != .lt and key_cmp_end != .gt)
                    else
                        (key_cmp_start == .gt and key_cmp_end == .lt);

                    if (in_range or inclusive) {
                        try node_ids.append(self.allocator, r.value);
                    }
                }

                // Update statistics
                index.statistics.cache_hits += node_ids.items.len;
                self.statistics.index_hits += node_ids.items.len;

                return try node_ids.toOwnedSlice(self.allocator);
            }
        }

        return try self.allocator.alloc(u64, 0);
    }

    // Get nodes by label
    pub fn getNodesByLabel(
        self: *IndexManager,
        index_name: []const u8,
    ) ![]u64 {
        if (self.label_indexes.getPtr(index_name)) |index| {
            index.statistics.read_count += 1;
            index.statistics.cache_hits += index.node_ids.items.len;
            self.statistics.index_hits += index.node_ids.items.len;

            return try self.allocator.dupe(u64, index.node_ids.items);
        }

        return &[_]u64{};
    }

    // Analyze and update statistics
    pub fn analyzeIndexes(self: *IndexManager) !void {
        self.statistics.last_analyze = compat_timestamp();

        // Update statistics for each index
        var prop_it = self.property_indexes.iterator();
        while (prop_it.next()) |entry| {
            const index = entry.value_ptr;
            if (index.btree_index) |tree_ptr| {
                const BTreeType = btree.BTree([]const u8, u64, 32);
                const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));
                // Update statistics based on tree state
                index.statistics.height = tree.getHeight();
                index.statistics.fill_factor = @as(f64, @floatFromInt(index.statistics.entries)) / @as(f64, @floatFromInt(tree.getCapacity()));
                index.statistics.size_bytes = tree.getSizeBytes();
            }
        }

        // Calculate total size
        self.statistics.total_size_bytes = 0;
        prop_it = self.property_indexes.iterator();
        while (prop_it.next()) |entry| {
            self.statistics.total_size_bytes += entry.value_ptr.statistics.size_bytes;
        }
    }

    // Check if an index should be used based on selectivity
    pub fn shouldUseIndex(
        self: *IndexManager,
        index_name: []const u8,
        estimated_rows: u64,
        total_rows: u64,
    ) bool {
        _ = self;
        _ = index_name;

        // Use index if selectivity is less than 10%
        const selectivity = @as(f64, @floatFromInt(estimated_rows)) /
            @as(f64, @floatFromInt(total_rows));
        return selectivity < 0.1;
    }

    // Helper functions
    fn createHashIndex(self: *IndexManager, bucket_count: usize) !HashIndex {
        const buckets = try self.allocator.alloc(HashIndex.Bucket, bucket_count);
        for (buckets) |*bucket| {
            bucket.* = HashIndex.Bucket{
                .entries = std.ArrayList(HashIndex.Entry).empty,
            };
        }

        return HashIndex{
            .buckets = buckets,
            .size = bucket_count,
            .count = 0,
        };
    }

    fn insertIntoHashIndex(self: *IndexManager, hash: *HashIndex, key: []const u8, value: u64) !void {
        const hash_value = std.hash_map.hashString(key);
        const bucket_index = hash_value % hash.size;

        try hash.buckets[bucket_index].entries.append(self.allocator, .{
            .key = try self.allocator.dupe(u8, key),
            .value = value,
        });

        hash.count += 1;
    }

    fn lookupInHashIndex(self: *IndexManager, hash: *HashIndex, key: []const u8) ?u64 {
        _ = self;

        const hash_value = std.hash_map.hashString(key);
        const bucket_index = hash_value % hash.size;

        for (hash.buckets[bucket_index].entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }

        return null;
    }

    // Spatial index operations
    pub fn createSpatialIndex(
        self: *IndexManager,
        name: []const u8,
        label: []const u8,
        property: []const u8,
    ) !void {
        try self.createPropertyIndex(name, label, property, .spatial, false);
    }

    pub fn insertIntoSpatialIndex(
        self: *IndexManager,
        index_name: []const u8,
        mbr: rtree.MBR,
        node_id: u64,
    ) !void {
        if (self.spatial_indexes.get(index_name)) |spatial| {
            try spatial.insert(mbr, node_id);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.spatial_index) |spatial| {
                try spatial.insert(mbr, node_id);
                index.statistics.entries += 1;
                self.statistics.total_entries += 1;
            }
        }
    }

    pub fn searchSpatialIndex(
        self: *IndexManager,
        index_name: []const u8,
        query_mbr: rtree.MBR,
    ) ![]u64 {
        var results = std.ArrayList(u64).empty;
        defer results.deinit(self.allocator);

        if (self.spatial_indexes.get(index_name)) |spatial| {
            try spatial.search(query_mbr, self.allocator, &results);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.spatial_index) |spatial| {
                try spatial.search(query_mbr, self.allocator, &results);
                index.statistics.read_count += 1;
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    // Vector index operations
    pub fn createVectorIndex(
        self: *IndexManager,
        name: []const u8,
        label: []const u8,
        property: []const u8,
        dimensions: u16,
    ) !void {
        const index_name = try self.allocator.dupe(u8, name);
        const index = PropertyIndex{
            .name = index_name,
            .label = try self.allocator.dupe(u8, label),
            .property = try self.allocator.dupe(u8, property),
            .type = .vector,
            .unique = false,
            .btree_index = null,
            .hash_index = null,
            .spatial_index = null,
            .vector_index = blk: {
                const vector = try self.allocator.create(hnsw.Hnsw);
                vector.* = try hnsw.Hnsw.init(self.allocator, dimensions, .euclidean, .{
                    .m = 16,
                    .ef_construction = 200,
                    .ef_search = 200,
                });
                try self.vector_indexes.put(index_name, vector);
                break :blk @as(?*anyopaque, vector);
            },
            .fulltext_index = null,
            .statistics = .{
                .entries = 0,
                .size_bytes = 0,
                .height = 0,
                .fill_factor = 0,
                .last_updated = compat_timestamp(),
                .read_count = 0,
                .write_count = 0,
                .cache_hits = 0,
                .cache_misses = 0,
            },
        };

        try self.property_indexes.put(index_name, index);
        self.statistics.total_indexes += 1;
    }

    pub fn insertIntoVectorIndex(
        self: *IndexManager,
        index_name: []const u8,
        vector_data: []const f32,
        node_id: u64,
    ) !void {
        if (self.vector_indexes.get(index_name)) |vector_idx| {
            const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
            try hnsw_index.insert(node_id, vector_data);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.vector_index) |vector_idx| {
                const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
                try hnsw_index.insert(node_id, vector_data);
                index.statistics.entries += 1;
                index.statistics.write_count += 1;
                self.statistics.total_entries += 1;
            }
        }
    }

    pub fn knnSearchVectorIndex(
        self: *IndexManager,
        index_name: []const u8,
        query_vector: []const f32,
        k: usize,
    ) ![]struct { id: u64, score: f64 } {
        const t0 = otel.internal.clock.unixNanoNow();
        if (self.vector_indexes.get(index_name)) |vector_idx| {
            const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
            const raw_results = try hnsw_index.knnSearch(query_vector, @intCast(k));
            const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
            otel_metrics.recordHnswSearch(.l2, elapsed_s);
            return try mapSearchResults(self.allocator, raw_results);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.vector_index) |vector_idx| {
                const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
                index.statistics.read_count += 1;
                const raw_results = try hnsw_index.knnSearch(query_vector, @intCast(k));
                const elapsed_s = @as(f64, @floatFromInt(otel.internal.clock.unixNanoNow() -| t0)) / @as(f64, std.time.ns_per_s);
                otel_metrics.recordHnswSearch(.l2, elapsed_s);
                return try mapSearchResults(self.allocator, raw_results);
            }
        }

        return try self.allocator.alloc(struct { id: u64, score: f64 }, 0);
    }

    fn mapSearchResults(
        allocator: std.mem.Allocator,
        raw_results: []const hnsw.SearchResult,
    ) ![]struct { id: u64, score: f64 } {
        const results = try allocator.alloc(struct { id: u64, score: f64 }, raw_results.len);
        for (raw_results, 0..) |result, i| {
            results[i] = .{
                .id = result.id,
                .score = @as(f64, result.distance),
            };
        }
        allocator.free(raw_results);
        return results;
    }

    // Advanced type index management functions

    pub fn createAdvancedVectorIndex(
        self: *IndexManager,
        name: []const u8,
        dimension: u16,
        metric: advanced_types.VectorIndexWrapper.DistanceMetric,
    ) !void {
        if (name.len == 0 or name.len > 255) return error.InvalidInput;
        if (dimension > 8192) return error.InvalidInput;

        if (self.advanced_vector_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const wrapper = try self.allocator.create(advanced_types.VectorIndexWrapper);
        errdefer self.allocator.destroy(wrapper);

        wrapper.* = try advanced_types.VectorIndexWrapper.init(self.allocator, dimension, metric);
        errdefer wrapper.deinit();

        try self.advanced_vector_indexes.put(owned_name, wrapper);
        self.statistics.total_indexes += 1;
    }

    pub fn createAdvancedSpatialIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (name.len == 0 or name.len > 255) return error.InvalidInput;

        if (self.advanced_spatial_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const wrapper = try self.allocator.create(advanced_types.SpatialIndexWrapper);
        errdefer self.allocator.destroy(wrapper);

        wrapper.* = try advanced_types.SpatialIndexWrapper.init(self.allocator);
        errdefer wrapper.deinit();

        try self.advanced_spatial_indexes.put(owned_name, wrapper);
        self.statistics.total_indexes += 1;
    }

    pub fn createAdvancedNetworkIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (self.advanced_network_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const wrapper = try self.allocator.create(advanced_types.NetworkIndexWrapper);
        wrapper.* = try advanced_types.NetworkIndexWrapper.init(self.allocator);

        try self.advanced_network_indexes.put(owned_name, wrapper);
        self.statistics.total_indexes += 1;
    }

    pub fn createAdvancedSignatureIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (self.advanced_signature_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const wrapper = try self.allocator.create(advanced_types.SignatureIndexWrapper);
        wrapper.* = try advanced_types.SignatureIndexWrapper.init(self.allocator);

        try self.advanced_signature_indexes.put(owned_name, wrapper);
        self.statistics.total_indexes += 1;
    }

    pub fn createAdvancedIntervalIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (self.advanced_interval_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const wrapper = try self.allocator.create(advanced_types.IntervalIndexWrapper);
        wrapper.* = advanced_types.IntervalIndexWrapper.init(self.allocator);

        try self.advanced_interval_indexes.put(owned_name, wrapper);
        self.statistics.total_indexes += 1;
    }

    pub fn createAdvancedJsonbIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (self.advanced_jsonb_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const index = try self.allocator.create(jsonb_inverted.JsonbInvertedIndex);
        index.* = jsonb_inverted.JsonbInvertedIndex.init(self.allocator);

        try self.advanced_jsonb_indexes.put(owned_name, index);
        self.statistics.total_indexes += 1;
    }

    pub fn createAdvancedDomainIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (self.advanced_domain_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const index = try self.allocator.create(domain_trie.DomainTrie);
        index.* = domain_trie.DomainTrie.init(self.allocator);

        try self.advanced_domain_indexes.put(owned_name, index);
        self.statistics.total_indexes += 1;
    }

    // Advanced type index operations

    pub fn insertIntoAdvancedVectorIndex(
        self: *IndexManager,
        index_name: []const u8,
        vector_value: vector_types.VectorF32,
        entity_id: u64,
    ) !void {
        if (self.advanced_vector_indexes.getPtr(index_name)) |wrapper| {
            try wrapper.*.insert(entity_id, vector_value);
            self.statistics.total_entries += 1;
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn insertIntoAdvancedSpatialIndex(
        self: *IndexManager,
        index_name: []const u8,
        location: @import("../types/geographic.zig").LatLon,
        entity_id: u64,
    ) !void {
        if (self.advanced_spatial_indexes.getPtr(index_name)) |wrapper| {
            try wrapper.*.insert(entity_id, location);
            self.statistics.total_entries += 1;
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn insertIntoAdvancedNetworkIndex(
        self: *IndexManager,
        index_name: []const u8,
        value: @import("../storage/heap.zig").Value,
        entity_id: u64,
    ) !void {
        if (self.advanced_network_indexes.getPtr(index_name)) |wrapper| {
            try wrapper.*.insert(entity_id, value);
            self.statistics.total_entries += 1;
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn insertIntoAdvancedIntervalIndex(
        self: *IndexManager,
        index_name: []const u8,
        lower: i32,
        upper: i32,
        entity_id: u64,
    ) !void {
        if (self.advanced_interval_indexes.getPtr(index_name)) |wrapper| {
            const r = try @import("../types/range.zig").IntRange.init(lower, upper, .inclusive_exclusive);
            try wrapper.*.tree.insert(r, @as(usize, @intCast(entity_id)));
            self.statistics.total_entries += 1;
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn insertIntoAdvancedJsonbIndex(
        self: *IndexManager,
        index_name: []const u8,
        entity_id: u64,
        document: jsonb.JsonbDocument,
    ) !void {
        if (self.advanced_jsonb_indexes.getPtr(index_name)) |index| {
            try index.*.indexDocument(entity_id, document);
            self.statistics.total_entries += 1;
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn insertIntoAdvancedDomainIndex(
        self: *IndexManager,
        index_name: []const u8,
        domain: url.Domain,
        entity_id: u64,
    ) !void {
        if (self.advanced_domain_indexes.getPtr(index_name)) |index| {
            try index.*.insert(domain, entity_id);
            self.statistics.total_entries += 1;
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn queryAdvancedVectorIndex(
        self: *IndexManager,
        index_name: []const u8,
        query_vector: @import("../types/vector.zig").VectorF32,
        k: u32,
    ) ![]advanced_types.VectorSearchResult {
        if (self.advanced_vector_indexes.getPtr(index_name)) |wrapper| {
            return try wrapper.*.search(query_vector, k, self.allocator);
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn queryAdvancedVectorIndexWithMetric(
        self: *IndexManager,
        index_name: []const u8,
        query_vector: @import("../types/vector.zig").VectorF32,
        k: u32,
        metric: advanced_types.VectorIndexWrapper.DistanceMetric,
    ) ![]advanced_types.VectorSearchResult {
        if (self.advanced_vector_indexes.getPtr(index_name)) |wrapper| {
            return try wrapper.*.searchWithMetric(query_vector, k, metric, self.allocator);
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn searchAdvancedVectorIndex(
        self: *IndexManager,
        index_name: []const u8,
        query_vector: @import("../types/vector.zig").VectorF32,
        k: u32,
    ) ![]struct { id: u64, score: f64 } {
        const results = try self.queryAdvancedVectorIndex(index_name, query_vector, k);
        defer self.allocator.free(results);

        const converted = try self.allocator.alloc(struct { id: u64, score: f64 }, results.len);
        for (results, 0..) |result, i| {
            converted[i] = .{
                .id = result.node_id,
                .score = result.distance,
            };
        }
        return converted;
    }

    pub fn queryAdvancedSpatialIndex(
        self: *IndexManager,
        index_name: []const u8,
        query_location: @import("../types/geographic.zig").LatLon,
        radius_km: f64,
    ) ![]advanced_types.SpatialSearchResult {
        if (self.advanced_spatial_indexes.getPtr(index_name)) |wrapper| {
            return try wrapper.*.searchWithinRadius(query_location, radius_km, self.allocator);
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn registerAdvancedPropertyIndex(
        self: *IndexManager,
        index_name: []const u8,
        label: []const u8,
        property: []const u8,
        index_type: IndexType,
    ) !void {
        if (self.advanced_property_indexes.contains(index_name)) return;

        const owned_key = try self.allocator.dupe(u8, index_name);
        errdefer self.allocator.free(owned_key);

        try self.advanced_property_indexes.put(owned_key, .{
            .name = try self.allocator.dupe(u8, index_name),
            .label = try self.allocator.dupe(u8, label),
            .property = try self.allocator.dupe(u8, property),
            .index_type = index_type,
        });
    }

    // CANARY: REQ=REQ-GAP-0918-VECTOR-INDEX-VALIDATION; FEATURE="VectorIndex"; ASPECT=DimensionWriteCheck; STATUS=TESTED; TEST=tests/test_gap0918_vector_validation.zig; OWNER=index; UPDATED=2026-07-10
    /// GAP-0918: register a vector-indexed (label, property) pair in the
    /// lightweight dimension-validation registry. The first vector written
    /// establishes the dimension; later mismatches are rejected.
    pub fn registerVectorDimValidation(
        self: *IndexManager,
        index_name: []const u8,
        label: []const u8,
        property: []const u8,
    ) !void {
        if (self.vector_dim_registry.contains(index_name)) return;
        const owned_key = try self.allocator.dupe(u8, index_name);
        errdefer self.allocator.free(owned_key);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const owned_prop = try self.allocator.dupe(u8, property);
        errdefer self.allocator.free(owned_prop);
        try self.vector_dim_registry.put(owned_key, .{
            .label = owned_label,
            .property = owned_prop,
            .dim = 0,
            .seed_attempted = false,
        });
    }

    // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimRegistryFollowsCatalog; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
    /// ENG-3912(d): drop every dimension pin. The registry is DERIVED from the
    /// catalog (it is re-registered from the reloaded index rows), so it is
    /// released with the catalog — otherwise the entries a catalog load
    /// created would outlive it with nothing able to free them.
    pub fn clearVectorDimRegistry(self: *IndexManager) void {
        var it = self.vector_dim_registry.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.label);
            self.allocator.free(entry.value_ptr.property);
        }
        self.vector_dim_registry.clearAndFree();
    }

    // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimValidationUnregister; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
    /// ENG-3912(b): drop an index's dimension pin. Without this, `DROP INDEX`
    /// left the pin in force with NO index present — the property stayed
    /// locked to a dimension that nothing was indexing any more, and there was
    /// no statement that could clear it. Frees the duped strings symmetrically
    /// with `registerVectorDimValidation`. A no-op for an unknown name, so the
    /// DROP path can call it unconditionally.
    pub fn unregisterVectorDimValidation(self: *IndexManager, index_name: []const u8) void {
        if (self.vector_dim_registry.fetchRemove(index_name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.label);
            self.allocator.free(kv.value.property);
        }
    }

    // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimValidatePure; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
    /// GAP-0918: validate the dimension of a vector being written under an
    /// HNSW-indexed (label, property). Before that check a dim-3 vector was
    /// silently accepted into a dim-4 index — mixed-dimension vectors under
    /// one index with no signal to the caller.
    ///
    /// ENG-3912(a) — THIS FUNCTION IS PURE WITH RESPECT TO THE CANDIDATE
    /// WRITE. It used to ADOPT the candidate's dimension as a side effect
    /// (`if (meta.dim == 0) meta.dim = dim`). Because it is called from the
    /// statement-level atomicity PRE-PASS (execution/write_precheck.zig),
    /// which runs BEFORE the write is allowed, a statement that was then
    /// REFUSED still left its first vector's dimension pinned forever — a
    /// refused `CREATE (…dim3…), (…dim4…)` bricked the property at dim 3 with
    /// ZERO rows stored and no statement able to clear it. Adoption now lives
    /// in `adoptVectorDimension`, called only AFTER a write commits.
    ///
    /// Deriving the pin from data that is ALREADY COMMITTED (`seedVectorDim`)
    /// is a different thing and is still done here: it cannot pin a dimension
    /// that no stored vector has.
    pub fn checkVectorDimensionForWrite(
        self: *IndexManager,
        labels: []const []const u8,
        property: []const u8,
        dim: u16,
    ) !void {
        return self.checkVectorDimensionForWriteInGraph(null, labels, property, dim);
    }

    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimWriteCheck; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
    /// `checkVectorDimensionForWrite` extended to the UNINDEXED case (ENG-3922).
    ///
    /// The indexed pins are consulted first and, when one covers the pair, they
    /// are the whole answer — their process-wide scope is deliberate (see
    /// `vector_dim_unindexed`). Only when NO index guards the pair does the
    /// per-graph pin apply, created lazily here and seeded from committed data.
    ///
    /// Still PURE with respect to the candidate write: nothing the caller is
    /// about to write is adopted, so a statement refused after this point leaves
    /// no pin behind (ENG-3912(a)). Seeding reads only data that is already
    /// stored, so it cannot pin a dimension no stored vector has.
    ///
    /// `graph` null (no session context to resolve it from) skips the unindexed
    /// half rather than guessing a graph — a mis-scoped pin would refuse a write
    /// that is perfectly valid in its own graph.
    pub fn checkVectorDimensionForWriteInGraph(
        self: *IndexManager,
        graph: ?[]const u8,
        labels: []const []const u8,
        property: []const u8,
        dim: u16,
    ) !void {
        return self.checkVectorDimensionForWriteInGraphExcluding(graph, labels, property, dim, null);
    }

    /// `checkVectorDimensionForWriteInGraph` with the identity of the node the
    /// write REPLACES. The unindexed pin is derived from committed data; on an
    /// overwrite, the row being replaced must not testify against its own
    /// replacement (a re-embedding SET on the sole holder was permanently
    /// refused). The cached pin is therefore only a fast ACCEPT: on a mismatch
    /// the dimension is re-derived from live committed data (excluding
    /// `exclude_node_id`), which also releases a pin whose establishing rows
    /// have all been deleted — the former KNOWN RESIDUAL of ENG-3922.
    pub fn checkVectorDimensionForWriteInGraphExcluding(
        self: *IndexManager,
        graph: ?[]const u8,
        labels: []const []const u8,
        property: []const u8,
        dim: u16,
        exclude_node_id: ?u64,
    ) !void {
        var indexed = false;
        var iter = self.vector_dim_registry.iterator();
        while (iter.next()) |entry| {
            const meta = entry.value_ptr;
            if (!matchesLabelProperty(meta, labels, property)) continue;
            indexed = true;
            if (meta.dim == 0 and !meta.seed_attempted) self.seedVectorDim(meta);
            if (meta.dim == 0) continue;
            if (meta.dim != dim) return error.VectorDimensionMismatch;
        }
        if (indexed) return;

        const graph_name = graph orelse return;
        for (labels) |label| {
            const pinned = self.unindexedVectorDim(graph_name, label, property) catch continue;
            if (pinned == 0) continue;
            if (pinned == dim) continue;
            // Cached pin disagrees — it may be stale (rows deleted, or the sole
            // holder is the row this write replaces). Re-derive from committed
            // data. Still PURE w.r.t. the candidate write: `live` reflects only
            // stored data, never the candidate, and a live pin of 0 is NOT
            // written back (a refused statement downstream must leave the
            // conservative cached value in place — ENG-3912(a)).
            const live = self.scanCommittedVectorDimExcluding(graph_name, label, property, exclude_node_id);
            if (live != 0) self.repinUnindexedVectorDim(graph_name, label, property, live);
            if (live == 0) continue;
            if (live != dim) return error.VectorDimensionMismatch;
        }
    }

    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimLazySeed; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
    /// The pinned dimension for an unindexed (graph, label, property), or 0 when
    /// no committed vector has established one. The entry is created on first
    /// use and seeded exactly once from committed data.
    ///
    /// The seed scan runs with `vector_dim_mutex` RELEASED — it reads the graph
    /// store, which takes the store's own locks, and this mutex is a leaf that
    /// must never enclose them. The window that opens (two threads scanning the
    /// same pair concurrently) is benign: both read the same committed data and
    /// the first writer wins, so they compute the same dimension.
    ///
    /// The pin is cached process state, trusted as a fast ACCEPT only: when a
    /// candidate write disagrees with it, the checker re-derives the dimension
    /// from live committed data (`checkVectorDimensionForWriteInGraphExcluding`),
    /// so deleting every establishing row — or overwriting the sole holder —
    /// releases the pin without a restart. The re-derive scan runs only on
    /// mismatch, so the common same-dimension write stays O(1).
    fn unindexedVectorDim(
        self: *IndexManager,
        graph: []const u8,
        label: []const u8,
        property: []const u8,
    ) !u16 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{s}", .{ graph, label, property });
        defer self.allocator.free(key);

        self.vector_dim_mutex.lockUncancelable(io);
        if (self.vector_dim_unindexed.get(key)) |existing| {
            if (existing.seed_attempted) {
                self.vector_dim_mutex.unlock(io);
                return existing.dim;
            }
        }
        self.vector_dim_mutex.unlock(io);

        const seeded_dim = self.scanCommittedVectorDim(graph, label, property);

        self.vector_dim_mutex.lockUncancelable(io);
        defer self.vector_dim_mutex.unlock(io);

        if (self.vector_dim_unindexed.getPtr(key)) |existing| {
            if (!existing.seed_attempted) {
                existing.seed_attempted = true;
                if (existing.dim == 0) existing.dim = seeded_dim;
            }
            return existing.dim;
        }

        try self.putUnindexedVectorDim(key, graph, label, property, seeded_dim);
        return seeded_dim;
    }

    /// Insert a new unindexed pin. Caller holds `vector_dim_mutex` and has
    /// already established that `key` is absent.
    fn putUnindexedVectorDim(
        self: *IndexManager,
        key: []const u8,
        graph: []const u8,
        label: []const u8,
        property: []const u8,
        dim: u16,
    ) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_graph = try self.allocator.dupe(u8, graph);
        errdefer self.allocator.free(owned_graph);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const owned_prop = try self.allocator.dupe(u8, property);
        errdefer self.allocator.free(owned_prop);

        try self.vector_dim_unindexed.put(owned_key, .{
            .label = owned_label,
            .property = owned_prop,
            .graph = owned_graph,
            .dim = dim,
            .seed_attempted = true,
        });
    }

    /// The dimension of the first committed vector under (graph, label,
    /// property), or 0 when the property holds no vector yet. Takes no
    /// index-manager lock (see `unindexedVectorDim`).
    fn scanCommittedVectorDim(
        self: *IndexManager,
        graph: []const u8,
        label: []const u8,
        property: []const u8,
    ) u16 {
        return self.scanCommittedVectorDimExcluding(graph, label, property, null);
    }

    /// `scanCommittedVectorDim`, skipping `exclude_node_id` — the row a
    /// pending overwrite replaces must not establish the dimension the
    /// overwrite is judged against.
    fn scanCommittedVectorDimExcluding(
        self: *IndexManager,
        graph: []const u8,
        label: []const u8,
        property: []const u8,
        exclude_node_id: ?u64,
    ) u16 {
        const store = graph_store.getGlobalStore(self.allocator);
        const ids = store.getNodesByLabel(graph, label) orelse return 0;
        for (ids) |node_id| {
            if (exclude_node_id) |ex| {
                if (node_id == ex) continue;
            }
            const node = (store.nodes.getOrHydratePtr(node_id) catch null) orelse continue;
            const prop = node.properties.get(property) orelse continue;
            if (vectorDimOfPropertyValue(prop)) |stored_dim| return stored_dim;
        }
        return 0;
    }

    /// Establish an unindexed pin from a vector that has just COMMITTED. Only
    /// ever fills in a pin that is not established yet.
    fn adoptUnindexedVectorDim(
        self: *IndexManager,
        graph: []const u8,
        label: []const u8,
        property: []const u8,
        dim: u16,
    ) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{s}", .{ graph, label, property }) catch return;
        defer self.allocator.free(key);

        self.vector_dim_mutex.lockUncancelable(io);
        defer self.vector_dim_mutex.unlock(io);

        if (self.vector_dim_unindexed.getPtr(key)) |existing| {
            if (existing.dim == 0) {
                existing.dim = dim;
                existing.seed_attempted = true;
            }
            return;
        }
        self.putUnindexedVectorDim(key, graph, label, property, dim) catch return;
    }

    /// Move an ESTABLISHED unindexed pin to `dim` (adopt only fills dim == 0).
    /// Callers pass a dimension that reflects committed data: either a fresh
    /// re-derivation (`scanCommittedVectorDimExcluding`), or a write that has
    /// already passed the dimension check and committed — so overwriting the
    /// cached value can never contradict stored vectors.
    fn repinUnindexedVectorDim(
        self: *IndexManager,
        graph: []const u8,
        label: []const u8,
        property: []const u8,
        dim: u16,
    ) void {
        if (dim == 0) return;
        const io = std.Io.Threaded.global_single_threaded.io();
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{s}", .{ graph, label, property }) catch return;
        defer self.allocator.free(key);

        self.vector_dim_mutex.lockUncancelable(io);
        defer self.vector_dim_mutex.unlock(io);

        if (self.vector_dim_unindexed.getPtr(key)) |existing| {
            existing.dim = dim;
            existing.seed_attempted = true;
            return;
        }
        self.putUnindexedVectorDim(key, graph, label, property, dim) catch return;
    }

    /// Post-commit sibling of `adoptVectorDimensionInGraph` for the UNINDEXED
    /// half only: a committed overwrite that legitimately changed the sole
    /// holder's dimension must move the established pin with it. Indexed pins
    /// are deliberately process-wide sticky and are not touched. Called only
    /// AFTER the store write commits, with the dimension the check accepted.
    pub fn repinUnindexedVectorDimsInGraph(
        self: *IndexManager,
        graph: ?[]const u8,
        labels: []const []const u8,
        property: []const u8,
        dim: u16,
    ) void {
        if (dim == 0) return;
        var iter = self.vector_dim_registry.iterator();
        while (iter.next()) |entry| {
            if (matchesLabelProperty(entry.value_ptr, labels, property)) return;
        }
        const graph_name = graph orelse return;
        for (labels) |label| {
            self.repinUnindexedVectorDim(graph_name, label, property, dim);
        }
    }

    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimGraphDrop; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
    /// Release every unindexed pin belonging to `graph`. The pin describes the
    /// graph's committed data, so when the graph is dropped the data — and the
    /// pin's justification — is gone; keeping it would refuse a perfectly valid
    /// write to a freshly re-created graph of the same name.
    pub fn dropUnindexedVectorDimsForGraph(self: *IndexManager, graph: []const u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.vector_dim_mutex.lockUncancelable(io);
        defer self.vector_dim_mutex.unlock(io);

        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.allocator);

        var iter = self.vector_dim_unindexed.iterator();
        while (iter.next()) |entry| {
            const entry_graph = entry.value_ptr.graph orelse continue;
            if (!std.mem.eql(u8, entry_graph, graph)) continue;
            doomed.append(self.allocator, entry.key_ptr.*) catch return;
        }

        for (doomed.items) |key| {
            if (self.vector_dim_unindexed.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.label);
                self.allocator.free(kv.value.property);
                if (kv.value.graph) |g| self.allocator.free(g);
            }
        }
    }

    // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimAdoptAfterCommit; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
    /// ENG-3912(a): establish the dimension pin from a vector that has just
    /// been COMMITTED. Called from the single node-property write chokepoint
    /// (`property_mutation.setNodePropertyFromValue`) after the store write
    /// returns, so a refused statement can never pin anything.
    pub fn adoptVectorDimension(
        self: *IndexManager,
        labels: []const []const u8,
        property: []const u8,
        dim: u16,
    ) void {
        self.adoptVectorDimensionInGraph(null, labels, property, dim);
    }

    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimAdoptAfterCommit; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
    /// `adoptVectorDimension` extended to the per-graph unindexed pins.
    /// Same contract: called only AFTER the store write commits, and it only
    /// ever fills in a pin that is not established yet.
    pub fn adoptVectorDimensionInGraph(
        self: *IndexManager,
        graph: ?[]const u8,
        labels: []const []const u8,
        property: []const u8,
        dim: u16,
    ) void {
        if (dim == 0) return;
        var indexed = false;
        var iter = self.vector_dim_registry.iterator();
        while (iter.next()) |entry| {
            const meta = entry.value_ptr;
            if (!matchesLabelProperty(meta, labels, property)) continue;
            indexed = true;
            if (meta.dim == 0) {
                meta.dim = dim;
                meta.seed_attempted = true;
            }
        }
        if (indexed) return;

        const graph_name = graph orelse return;
        for (labels) |label| {
            self.adoptUnindexedVectorDim(graph_name, label, property, dim);
        }
    }

    // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimSeedFromCommittedData; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
    /// ENG-3912(d): re-establish an unestablished pin from data that is already
    /// stored. The pin is process state, not catalog state, so after a restart
    /// the re-registered entry starts at `dim = 0`; without this the first
    /// post-restart write would set the pin to ITS OWN dimension and the guard
    /// would happily accept a dimension that disagrees with every stored
    /// vector. One shot per entry per process: a miss (no vectors stored yet)
    /// marks the entry seeded so this is not re-run on every write.
    fn seedVectorDim(self: *IndexManager, meta: *VectorDimEntry) void {
        meta.seed_attempted = true;
        const store = graph_store.getGlobalStore(self.allocator);
        const graph_names = store.listGraphNames(self.allocator) catch return;
        defer {
            for (graph_names) |name| self.allocator.free(name);
            self.allocator.free(graph_names);
        }
        // An INDEXED pin guards an index whose backfill selects by
        // label+property with NO graph filter, so it is seeded from every
        // graph. The per-graph (unindexed) pins seed through
        // `scanCommittedVectorDim` instead, against their own graph only.
        for (graph_names) |graph_name| {
            const ids = store.getNodesByLabel(graph_name, meta.label) orelse continue;
            for (ids) |node_id| {
                const node = (store.nodes.getOrHydratePtr(node_id) catch null) orelse continue;
                const prop = node.properties.get(meta.property) orelse continue;
                if (vectorDimOfPropertyValue(prop)) |stored_dim| {
                    meta.dim = stored_dim;
                    return;
                }
            }
        }
    }

    pub fn findAdvancedVectorIndexForProperty(self: *IndexManager, property: []const u8) ?[]const u8 {
        var iter = self.advanced_property_indexes.iterator();
        while (iter.next()) |entry| {
            const meta = entry.value_ptr.*;
            if (meta.index_type == .vector_f32 and std.mem.eql(u8, meta.property, property)) {
                return meta.name;
            }
        }
        return null;
    }

    /// O(1) check whether any advanced index is registered for a label+property pair.
    /// Used by property_mutation to skip expensive rebuilds when no index exists.
    pub fn hasAdvancedIndexForProperty(self: *IndexManager, label: []const u8, property: []const u8) bool {
        var iter = self.advanced_property_indexes.iterator();
        while (iter.next()) |entry| {
            const meta = entry.value_ptr.*;
            if (std.mem.eql(u8, meta.label, label) and std.mem.eql(u8, meta.property, property)) {
                return true;
            }
        }
        return false;
    }

    /// O(1) check whether any advanced index is registered for a label.
    pub fn hasAdvancedIndexForLabel(self: *IndexManager, label: []const u8) bool {
        var iter = self.advanced_property_indexes.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.label, label)) return true;
        }
        return false;
    }

    pub fn rebuildAdvancedIndexesForProperty(
        self: *IndexManager,
        store: *graph_store.GraphStore,
        label: []const u8,
        property: []const u8,
    ) !void {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.allocator);

        var iter = self.advanced_property_indexes.iterator();
        while (iter.next()) |entry| {
            const meta = entry.value_ptr.*;
            if (std.mem.eql(u8, meta.label, label) and std.mem.eql(u8, meta.property, property)) {
                try names.append(self.allocator, meta.name);
            }
        }

        for (names.items) |name| {
            try self.rebuildAdvancedIndex(store, name);
        }
    }

    pub fn rebuildAdvancedIndexesForLabel(
        self: *IndexManager,
        store: *graph_store.GraphStore,
        label: []const u8,
    ) !void {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.allocator);

        var iter = self.advanced_property_indexes.iterator();
        while (iter.next()) |entry| {
            const meta = entry.value_ptr.*;
            if (std.mem.eql(u8, meta.label, label)) {
                try names.append(self.allocator, meta.name);
            }
        }

        for (names.items) |name| {
            try self.rebuildAdvancedIndex(store, name);
        }
    }

    /// geode#875 RC-1: incrementally insert ONE entity's vector into every
    /// advanced VECTOR index registered for (label, property), instead of the
    /// O((K+M)·M) full drop+rebuild the write path used to run per write.
    ///
    /// Returns true only when EVERY matching index was updated incrementally.
    /// Returns false (and the caller must fall back to a full rebuild) when:
    ///   * a matching index is not a vector index (no incremental path here),
    ///   * the id is ALREADY present — an OVERWRITE — because HNSW has no
    ///     in-place update/remove, so a second insert would leave a stale
    ///     duplicate; the rebuild rebuilds from the committed store state, and
    ///   * the property value does not coerce to a vector, or the insert failed.
    /// On a false return any partial incremental inserts are harmless: the
    /// caller's rebuild drops and repopulates the index from scratch.
    pub fn tryIncrementalInsertForProperty(
        self: *IndexManager,
        label: []const u8,
        property: []const u8,
        entity_id: u64,
        prop: graph_store.PropertyValue,
    ) bool {
        self.rebuild_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rebuild_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var handled_any = false;
        var iter = self.advanced_property_indexes.iterator();
        while (iter.next()) |entry| {
            const meta = entry.value_ptr.*;
            if (!std.mem.eql(u8, meta.label, label) or !std.mem.eql(u8, meta.property, property)) continue;
            if (meta.index_type != .vector_f32) return false;
            // geode#875 RC-2b: while this index is rebuilding into a SHADOW
            // wrapper, the live write is QUEUED into the rebuild window rather
            // than inserted — the visible wrapper is about to be replaced by
            // one built from a snapshot taken BEFORE this write, so an insert
            // here would be thrown away at the swap. `endRebuild`'s drain
            // re-applies the queued ids to the new wrapper.
            if (self.queueIfRebuilding(meta.name, entity_id)) {
                handled_any = true;
                continue;
            }
            const wrapper = self.advanced_vector_indexes.get(meta.name) orelse return false;
            // OVERWRITE of an already-indexed id: fall back to a full rebuild.
            if (wrapper.contains(entity_id)) return false;
            const vec = vectorFromPropertyValue(self.allocator, prop) orelse return false;
            defer if (vec.owned) |data| self.allocator.free(data);
            self.insertIntoAdvancedVectorIndex(meta.name, vec.value, entity_id) catch return false;
            handled_any = true;
        }
        return handled_any;
    }

    // =======================================================================
    // geode#875 RC-2b: the non-blocking (shadow) rebuild window.
    //
    // `rebuildAdvancedIndexCounted` below drops the live index, recreates it
    // EMPTY and repopulates it with a hydrating scan + one HNSW insert per row.
    // Its transport call sites used to hold the per-graph rwlock SHARED across
    // the whole thing, and `StorageAdapter.acquireGraphWriteLock` spins until
    // readers drain — so every unrelated writer in the database stalled for the
    // full build (measured ~90 s at 4 000 x 256 dims).
    //
    // `rebuildAdvancedVectorIndexNonBlocking` replaces that for vector indexes:
    // it takes the SHARED lock only long enough to COPY the (id, vector) pairs
    // out of the store, builds a shadow wrapper with NO graph lock held, and
    // swaps it in under `rebuild_mutex`. This window API is what keeps a write
    // landing mid-build from being lost against the pre-write snapshot; it
    // mirrors `fts_storage_adapter.zig`'s rebuild window one-for-one.
    // =======================================================================

    /// Arm the rebuild window for `index_name`. Returns
    /// `error.RebuildInProgress` when a rebuild of the SAME index is already in
    /// flight, so two builds cannot race for the same swap slot.
    // CANARY: REQ=REQ-GEODE-875-NONBLOCKING-BACKFILL; FEATURE="VectorIndex"; ASPECT=RebuildWindowApi; STATUS=TESTED; TEST=tests/test_geode875_nonblocking_backfill.zig; OWNER=index; UPDATED=2026-09-01
    pub fn beginRebuild(self: *IndexManager, index_name: []const u8) !void {
        self.rebuild_window_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rebuild_window_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.rebuild_windows.contains(index_name)) return error.RebuildInProgress;
        const name_copy = try self.allocator.dupe(u8, index_name);
        errdefer self.allocator.free(name_copy);
        try self.rebuild_windows.put(self.allocator, name_copy, .{});
    }

    /// Queue `entity_id` into `index_name`'s rebuild window when that window is
    /// armed, and report whether it was captured (deduped — noting the same id
    /// twice drains once). A `true` return means the caller MUST NOT perform
    /// the live index write: the id is safely captured and `endRebuild`'s drain
    /// re-applies it to the freshly swapped-in wrapper. `false` is the ordinary
    /// path (no rebuild in flight, caller proceeds as usual) and is also what an
    /// OOM queue-insert returns, so a failed capture falls through to the live
    /// write instead of silently dropping the row.
    // CANARY: REQ=REQ-GEODE-875-NONBLOCKING-BACKFILL; FEATURE="VectorIndex"; ASPECT=ConcurrentWriteQueued; STATUS=TESTED; TEST=tests/test_geode875_nonblocking_backfill.zig; OWNER=index; UPDATED=2026-09-01
    pub fn noteWriteDuringRebuild(self: *IndexManager, index_name: []const u8, entity_id: u64) bool {
        return self.queueIfRebuilding(index_name, entity_id);
    }

    fn queueIfRebuilding(self: *IndexManager, index_name: []const u8, entity_id: u64) bool {
        self.rebuild_window_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rebuild_window_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const pending = self.rebuild_windows.getPtr(index_name) orelse return false;
        pending.put(self.allocator, entity_id, {}) catch return false;
        return true;
    }

    /// True when `index_name` currently has an armed rebuild window.
    pub fn isRebuilding(self: *IndexManager, index_name: []const u8) bool {
        self.rebuild_window_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rebuild_window_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.rebuild_windows.contains(index_name);
    }

    /// Atomically disarm `index_name`'s rebuild window and return the entity
    /// ids queued while it was armed, as an `allocator`-owned slice (caller
    /// frees). A name that was never armed returns an empty slice.
    // CANARY: REQ=REQ-GEODE-875-NONBLOCKING-BACKFILL; FEATURE="VectorIndex"; ASPECT=RebuildWindowApi; STATUS=TESTED; TEST=tests/test_geode875_nonblocking_backfill.zig; OWNER=index; UPDATED=2026-09-01
    pub fn endRebuild(self: *IndexManager, index_name: []const u8, allocator: std.mem.Allocator) ![]u64 {
        self.rebuild_window_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rebuild_window_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const kv = self.rebuild_windows.fetchRemove(index_name) orelse return &[_]u64{};
        var pending = kv.value;
        defer pending.deinit(self.allocator);
        self.allocator.free(kv.key);

        const out = try allocator.alloc(u64, pending.count());
        var it = pending.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        return out;
    }

    /// GAP-0511: Rebuild an advanced index. Acquires rebuild_mutex internally
    /// so callers do NOT need to hold the graph write lock during rebuild.
    /// The rebuild drops the old index, creates a new empty one, re-registers
    /// it, then populates from the store. The rebuild_mutex prevents concurrent
    /// rebuilds from racing on the index manager's data structures.
    pub fn rebuildAdvancedIndex(
        self: *IndexManager,
        store: *graph_store.GraphStore,
        index_name: []const u8,
    ) !void {
        _ = try self.rebuildAdvancedIndexCounted(store, index_name);
    }

    /// Same as `rebuildAdvancedIndex`, but returns the number of entities the
    /// backfill inserted (geode#875 RC-5). CREATE INDEX and the quic/grpc rebuild
    /// call sites use this to log/surface a real nodes_indexed count instead of
    /// swallowing a silently-zero-indexed backfill.
    pub fn rebuildAdvancedIndexCounted(
        self: *IndexManager,
        store: *graph_store.GraphStore,
        index_name: []const u8,
    ) !usize {
        self.rebuild_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rebuild_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const meta = self.advanced_property_indexes.get(index_name) orelse return 0;
        const index_name_copy = try self.allocator.dupe(u8, index_name);
        defer self.allocator.free(index_name_copy);
        const label_copy = try self.allocator.dupe(u8, meta.label);
        defer self.allocator.free(label_copy);
        const property_copy = try self.allocator.dupe(u8, meta.property);
        defer self.allocator.free(property_copy);
        const index_type = meta.index_type;

        switch (index_type) {
            .vector_f32 => {
                const dimension: u16 = if (self.advanced_vector_indexes.get(index_name)) |wrapper| wrapper.dimension else 0;
                const metric = if (self.advanced_vector_indexes.get(index_name)) |wrapper| wrapper.metric else advanced_types.VectorIndexWrapper.DistanceMetric.l2;
                _ = try self.dropAdvancedIndex(index_name, .vector_f32);
                try self.createAdvancedVectorIndex(index_name_copy, dimension, metric);
            },
            .spatial_geographic => {
                _ = try self.dropAdvancedIndex(index_name, .spatial_geographic);
                try self.createAdvancedSpatialIndex(index_name_copy);
            },
            .network_cidr => {
                _ = try self.dropAdvancedIndex(index_name, .network_cidr);
                try self.createAdvancedNetworkIndex(index_name_copy);
            },
            .signature_crypto => {
                _ = try self.dropAdvancedIndex(index_name, .signature_crypto);
                try self.createAdvancedSignatureIndex(index_name_copy);
            },
            .interval_tree => {
                _ = try self.dropAdvancedIndex(index_name, .interval_tree);
                try self.createAdvancedIntervalIndex(index_name_copy);
            },
            .jsonb_inverted => {
                _ = try self.dropAdvancedIndex(index_name, .jsonb_inverted);
                try self.createAdvancedJsonbIndex(index_name_copy);
            },
            .domain_trie => {
                _ = try self.dropAdvancedIndex(index_name, .domain_trie);
                try self.createAdvancedDomainIndex(index_name_copy);
            },
            else => return 0,
        }

        try self.registerAdvancedPropertyIndex(index_name_copy, label_copy, property_copy, index_type);
        const indexed = try self.populateAdvancedIndex(store, self.advanced_property_indexes.get(index_name_copy).?);
        self.statistics.rebuild_count += 1;
        return indexed;
    }

    /// geode#875 RC-2b: rebuild `index_name` WITHOUT pinning the per-graph
    /// SHARED lock across the HNSW build.
    ///
    /// `rebuildAdvancedIndexCounted` above drops the live index, recreates it
    /// EMPTY, and repopulates it with a hydrating scan plus one HNSW insert per
    /// row. Its transport call sites used to hold the graph rwlock SHARED for
    /// that whole span, and `StorageAdapter.acquireGraphWriteLock` spins until
    /// readers drain — so EVERY unrelated writer stalled for the full build
    /// (~90 s at 4 000 x 256 dims), and readers saw an EMPTY index throughout.
    ///
    /// This variant instead:
    ///   1. arms the rebuild window (a concurrent rebuild of the same index is
    ///      refused rather than racing for the same swap slot),
    ///   2. takes the SHARED lock only long enough to COPY out every
    ///      (entity id, vector) pair — a hydrating scan plus an N x dim memcpy,
    ///      trivial next to the graph build — and RELEASES it,
    ///   3. builds a SHADOW `VectorIndexWrapper` from the copies with NO graph
    ///      lock held (`batchInsert` takes the HNSW write lock once),
    ///   4. swaps the shadow in under `rebuild_mutex` — readers keep seeing the
    ///      OLD, fully populated index right up to the swap — and
    ///   5. disarms the window and re-applies the ids written while it was
    ///      armed, skipping any the shadow already carries (HNSW has no remove,
    ///      so a double insert would leave a stale duplicate).
    ///
    /// Only vector indexes take this path; the other advanced index types are
    /// cheap to build and keep the in-place rebuild under the caller's lock.
    /// Returns the number of entities the shadow build indexed.
    // CANARY: REQ=REQ-GEODE-875-NONBLOCKING-BACKFILL; FEATURE="VectorIndex"; ASPECT=IndexQueryableDuringRebuild; STATUS=TESTED; TEST=tests/test_geode875_nonblocking_backfill.zig; OWNER=index; UPDATED=2026-09-01
    pub fn rebuildAdvancedVectorIndexNonBlocking(
        self: *IndexManager,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        index_name: []const u8,
    ) !usize {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Snapshot the metadata we need under `rebuild_mutex` — a concurrent
        // DROP INDEX frees the manager-owned label/property strings, so the
        // lock-free phases below run against copies.
        var label_copy: ?[]u8 = null;
        var property_copy: ?[]u8 = null;
        var dimension: u16 = 0;
        var metric: advanced_types.VectorIndexWrapper.DistanceMetric = .l2;
        var is_vector = false;
        var exists = false;
        {
            self.rebuild_mutex.lockUncancelable(io);
            defer self.rebuild_mutex.unlock(io);
            if (self.advanced_property_indexes.get(index_name)) |meta| {
                exists = true;
                if (meta.index_type == .vector_f32) {
                    is_vector = true;
                    label_copy = try self.allocator.dupe(u8, meta.label);
                    errdefer self.allocator.free(label_copy.?);
                    property_copy = try self.allocator.dupe(u8, meta.property);
                    if (self.advanced_vector_indexes.get(index_name)) |w| {
                        dimension = w.dimension;
                        metric = w.metric;
                    }
                }
            }
        }
        defer {
            if (label_copy) |l| self.allocator.free(l);
            if (property_copy) |p| self.allocator.free(p);
        }
        if (!exists) return 0;

        if (!is_vector) {
            const lock = graph_store.acquireGraphReadLockTagged(graph_name, .misc);
            defer graph_store.releaseGraphLock(lock);
            return self.rebuildAdvancedIndexCounted(graph_store.getGlobalStore(allocator), index_name);
        }

        const label = label_copy.?;
        const property = property_copy.?;

        try self.beginRebuild(index_name);
        var window_armed = true;
        defer if (window_armed) {
            const leftover = self.endRebuild(index_name, allocator) catch &[_]u64{};
            allocator.free(leftover);
        };

        // --- 1. Snapshot under the SHARED lock: ids plus a COPY of every
        //        indexed vector, into one flat owned buffer.
        var ids: std.ArrayListUnmanaged(u64) = .empty;
        defer ids.deinit(allocator);
        var flat: std.ArrayListUnmanaged(f32) = .empty;
        defer flat.deinit(allocator);
        {
            const lock = graph_store.acquireGraphReadLockTagged(graph_name, .misc);
            defer graph_store.releaseGraphLock(lock);
            const store = graph_store.getGlobalStore(allocator);

            // geode#875 RC-2 (bounded-cache-safe): enumerate the COMPLETE
            // persisted id set and hydrate each body — the resident map alone
            // misses evicted / cold entities (it is EMPTY after a restart).
            const node_ids = try store.getAllNodes(allocator);
            defer allocator.free(node_ids);
            for (node_ids) |nid| {
                const node = store.getNodePtrHydrated(nid) orelse continue;
                if (!nodeHasLabel(node.labels, label)) continue;
                const prop = node.properties.get(property) orelse continue;
                try self.snapshotVectorRow(allocator, prop, node.id, &dimension, &ids, &flat);
            }

            const edge_ids = try store.allEdgeIds(allocator);
            defer allocator.free(edge_ids);
            for (edge_ids) |eid| {
                const edge = store.getEdgePtrHydrated(eid) orelse continue;
                if (!std.mem.eql(u8, edge.label, label)) continue;
                const prop = edge.properties.get(property) orelse continue;
                try self.snapshotVectorRow(allocator, prop, edge.id, &dimension, &ids, &flat);
            }
        }
        // --- The graph lock is RELEASED. Everything below is lock-free, so an
        //     EXCLUSIVE writer can acquire immediately instead of spinning for
        //     the whole build.

        // --- 2/3. Build the shadow wrapper. The live wrapper is untouched, so
        //     readers keep seeing the fully populated old index.
        const shadow = try self.allocator.create(advanced_types.VectorIndexWrapper);
        errdefer self.allocator.destroy(shadow);
        shadow.* = try advanced_types.VectorIndexWrapper.init(self.allocator, dimension, metric);
        var shadow_owned = true;
        errdefer if (shadow_owned) shadow.deinit();

        if (ids.items.len > 0 and dimension > 0) {
            const rows = try allocator.alloc([]const f32, ids.items.len);
            defer allocator.free(rows);
            for (rows, 0..) |*row, i| row.* = flat.items[i * dimension ..][0..dimension];
            try shadow.batchInsert(ids.items, rows);
        }
        const indexed = ids.items.len;

        // --- 4. Swap under `rebuild_mutex`.
        {
            self.rebuild_mutex.lockUncancelable(io);
            defer self.rebuild_mutex.unlock(io);
            if (self.advanced_vector_indexes.getPtr(index_name)) |slot| {
                const old = slot.*;
                slot.* = shadow;
                shadow_owned = false;
                old.deinit();
                self.allocator.destroy(old);
                self.statistics.total_entries += indexed;
                self.statistics.rebuild_count += 1;
            } else {
                // DROP INDEX won the race while we were building: discard the
                // shadow rather than resurrecting a dropped index.
                shadow.deinit();
                shadow_owned = false;
                self.allocator.destroy(shadow);
                return 0;
            }
        }

        // --- 5. Disarm the window and re-apply the writes it captured. The
        //     SHARED lock is retaken per id (each hold covers one property read
        //     plus one HNSW insert) — never re-held across the whole drain.
        const drained = try self.endRebuild(index_name, allocator);
        window_armed = false;
        defer allocator.free(drained);
        for (drained) |entity_id| {
            const lock = graph_store.acquireGraphReadLockTagged(graph_name, .misc);
            defer graph_store.releaseGraphLock(lock);
            const store = graph_store.getGlobalStore(allocator);
            const prop = blk: {
                if (store.getNodePtrHydrated(entity_id)) |node| break :blk node.properties.get(property);
                if (store.getEdgePtrHydrated(entity_id)) |edge| break :blk edge.properties.get(property);
                break :blk null;
            } orelse continue; // deleted inside the window — nothing to index
            // Skips ids the shadow build already carries (`wrapper.contains`),
            // so a write captured by the window AND visible to the snapshot is
            // never double-inserted.
            _ = self.tryIncrementalInsertForProperty(label, property, entity_id, prop);
        }

        return indexed;
    }

    /// Copy one entity's indexed vector into the flat snapshot buffer. The
    /// FIRST vector seen establishes the build dimension when the index has
    /// none yet (a deferred-init wrapper); a row of a different dimension is
    /// skipped rather than aborting the whole rebuild.
    fn snapshotVectorRow(
        self: *IndexManager,
        allocator: std.mem.Allocator,
        prop: graph_store.PropertyValue,
        entity_id: u64,
        dimension: *u16,
        ids: *std.ArrayListUnmanaged(u64),
        flat: *std.ArrayListUnmanaged(f32),
    ) !void {
        const vec = vectorFromPropertyValue(self.allocator, prop) orelse return;
        defer if (vec.owned) |data| self.allocator.free(data);
        if (dimension.* == 0) dimension.* = vec.value.dim;
        if (vec.value.dim != dimension.*) {
            // error-policy: B — a dimension-mismatched row cannot enter an HNSW
            // graph of a different width; skip it and keep the rest of the
            // index buildable (the GAP-0918 write guard is what prevents this).
            std.log.scoped(.index_manager).warn(
                "skipping entity {d} in vector index rebuild: dim {d} != index dim {d}",
                .{ entity_id, vec.value.dim, dimension.* },
            );
            return;
        }
        try ids.append(allocator, entity_id);
        try flat.appendSlice(allocator, vec.value.data[0..vec.value.dim]);
    }

    pub fn dropAdvancedIndex(
        self: *IndexManager,
        index_name: []const u8,
        index_type: IndexType,
    ) !bool {
        switch (index_type) {
            .vector_f32 => {
                if (self.advanced_vector_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.allocator.free(kv.key);
                    self.removeAdvancedPropertyIndex(index_name);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .spatial_geographic => {
                if (self.advanced_spatial_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.allocator.free(kv.key);
                    self.removeAdvancedPropertyIndex(index_name);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .network_cidr => {
                if (self.advanced_network_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.allocator.free(kv.key);
                    self.removeAdvancedPropertyIndex(index_name);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .signature_crypto => {
                if (self.advanced_signature_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.allocator.free(kv.key);
                    self.removeAdvancedPropertyIndex(index_name);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .interval_tree => {
                if (self.advanced_interval_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.allocator.free(kv.key);
                    self.removeAdvancedPropertyIndex(index_name);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .jsonb_inverted => {
                if (self.advanced_jsonb_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.allocator.free(kv.key);
                    self.removeAdvancedPropertyIndex(index_name);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .domain_trie => {
                if (self.advanced_domain_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.allocator.free(kv.key);
                    self.removeAdvancedPropertyIndex(index_name);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            else => return false,
        }
        return false;
    }

    /// Backfill `meta`'s index from the store. Returns the number of entities
    /// (nodes + edges) actually inserted, so a caller can surface a real
    /// nodes_indexed count instead of swallowing a zero-indexed backfill as
    /// success (geode#875 RC-5).
    fn populateAdvancedIndex(self: *IndexManager, store: *graph_store.GraphStore, meta: AdvancedPropertyIndex) !usize {
        var indexed: usize = 0;

        // geode#875 RC-2 (bounded-cache-safe): enumerate the COMPLETE persisted
        // node id set and hydrate each body, mirroring the edge half below.
        // Iterating the resident `store.nodes` map alone misses evicted / cold
        // nodes (the resident cache is EMPTY after a restart until first access),
        // so a rebuild/backfill over the resident iterator inserts ~nothing and
        // leaves a populated-count-0 shell.
        const adv_node_ids = try store.getAllNodes(self.allocator);
        defer self.allocator.free(adv_node_ids);
        for (adv_node_ids) |__nid| {
            const node = store.getNodePtrHydrated(__nid) orelse continue;
            if (!nodeHasLabel(node.labels, meta.label)) continue;
            const prop = node.properties.get(meta.property) orelse continue;
            if (try self.insertAdvancedPropertyValue(meta, node.id, prop)) indexed += 1;
        }

        // PHASE 1 (edge-engine-direct): enumerate the COMPLETE edge id set
        // (bounded-cache-safe) and hydrate each body, instead of iterating the
        // resident `store.edges` map (which under a bounded edge cache would miss
        // evicted edges when building the index).
        const adv_edge_ids = try store.allEdgeIds(self.allocator);
        defer self.allocator.free(adv_edge_ids);
        for (adv_edge_ids) |__eid| {
            const edge = store.getEdgePtrHydrated(__eid) orelse continue;
            if (!std.mem.eql(u8, edge.label, meta.label)) continue;
            const prop = edge.properties.get(meta.property) orelse continue;
            if (try self.insertAdvancedPropertyValue(meta, edge.id, prop)) indexed += 1;
        }
        return indexed;
    }

    /// Insert one entity's property value into `meta`'s index. Returns true when
    /// a value was actually inserted (the property coerced to the index's type),
    /// so the backfill can report an honest indexed count (geode#875 RC-5).
    fn insertAdvancedPropertyValue(
        self: *IndexManager,
        meta: AdvancedPropertyIndex,
        entity_id: u64,
        prop: graph_store.PropertyValue,
    ) !bool {
        switch (meta.index_type) {
            .vector_f32 => {
                if (vectorFromPropertyValue(self.allocator, prop)) |vec| {
                    defer if (vec.owned) |data| self.allocator.free(data);
                    try self.insertIntoAdvancedVectorIndex(meta.name, vec.value, entity_id);
                    return true;
                }
            },
            .spatial_geographic => {
                if (latLonFromPropertyValue(prop)) |location| {
                    try self.insertIntoAdvancedSpatialIndex(meta.name, location, entity_id);
                    return true;
                }
            },
            .network_cidr => {
                if (networkValueFromPropertyValue(prop)) |network_value| {
                    try self.insertIntoAdvancedNetworkIndex(meta.name, network_value, entity_id);
                    return true;
                }
            },
            .signature_crypto => {
                if (signatureFromPropertyValue(self.allocator, prop)) |signature| {
                    defer signature.deinit(self.allocator);
                    if (self.advanced_signature_indexes.getPtr(meta.name)) |wrapper| {
                        try wrapper.*.insert(entity_id, signature);
                        self.statistics.total_entries += 1;
                        return true;
                    }
                }
            },
            .interval_tree => {
                if (intRangeFromPropertyValue(prop)) |r| {
                    if (r.lower) |lower| {
                        if (r.upper) |upper| {
                            try self.insertIntoAdvancedIntervalIndex(meta.name, lower, upper, entity_id);
                            return true;
                        }
                    }
                }
            },
            .jsonb_inverted => {
                if (jsonbFromPropertyValue(self.allocator, prop)) |doc| {
                    defer doc.deinit();
                    try self.insertIntoAdvancedJsonbIndex(meta.name, entity_id, doc);
                    return true;
                }
            },
            .domain_trie => {
                if (domainFromPropertyValue(self.allocator, prop)) |domain| {
                    defer domain.deinit(self.allocator);
                    try self.insertIntoAdvancedDomainIndex(meta.name, domain, entity_id);
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn removeAdvancedPropertyIndex(self: *IndexManager, index_name: []const u8) void {
        if (self.advanced_property_indexes.fetchRemove(index_name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.name);
            self.allocator.free(kv.value.label);
            self.allocator.free(kv.value.property);
        }
    }
};

pub fn ensureGlobalIndexManager(allocator: std.mem.Allocator) !*IndexManager {
    global_index_manager_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_index_manager_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_index_manager) |manager| return manager;

    const manager = try allocator.create(IndexManager);
    manager.* = IndexManager.init(allocator);
    global_index_manager = manager;
    return manager;
}

pub fn getGlobalIndexManager() ?*IndexManager {
    return global_index_manager;
}

// CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimRegistry; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
/// The index manager for the vector dimension guard, created on demand.
///
/// ENG-3922(a): the guard's write sites used to read `getGlobalIndexManager()`
/// and do nothing when it returned null. That was sound while every pin came
/// from `CREATE INDEX` DDL (which creates the manager), but the unindexed pin
/// has no DDL behind it — in a database where no index was ever created the
/// guard would simply not exist.
///
/// `smp_allocator` deliberately, NEVER the caller's allocator: this runs on the
/// write path whose allocator is a per-request arena, and the manager is
/// process-lifetime. Same reasoning, and the same governance-approved choice, as
/// `statement_dispatcher.ensureAdvancedVectorIndexForProperty`. Returns null
/// rather than failing a write if the manager cannot be created.
pub fn ensureGlobalIndexManagerForDimGuard() ?*IndexManager {
    if (global_index_manager) |manager| return manager;
    return ensureGlobalIndexManager(std.heap.smp_allocator) catch null;
}

pub fn cleanupGlobalIndexManager() void {
    global_index_manager_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_index_manager_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_index_manager) |manager| {
        const allocator = manager.allocator;
        manager.deinit();
        allocator.destroy(manager);
        global_index_manager = null;
    }
}

fn nodeHasLabel(labels: [][]const u8, label: []const u8) bool {
    for (labels) |node_label| {
        if (std.mem.eql(u8, node_label, label)) return true;
    }
    return false;
}

const OwnedVector = struct {
    value: vector_types.VectorF32,
    owned: ?[]f32 = null,
};

// CANARY: REQ=REQ-GEODE-877-KNN-LIST-PROPERTY; FEATURE="VectorKnn"; ASPECT=NumericListCoercion; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=index; UPDATED=2026-08-29
/// geode#877 (a): a numeric element of a stored LIST property as an f64, or
/// null for anything non-numeric. Mirrors `eval.numericValueAsF64` over the
/// stored (ExtValue) representation — a node written `{embedding: [1.0, 0.0]}`
/// (the natural shape for a JSON / client-side embedding) stores
/// `ExtValue.List`, never `ExtValue.VectorF32`.
fn numericExtValueAsF64(item: eval_extended.ExtValue) ?f64 {
    return switch (item) {
        .Int => |v| @floatFromInt(v),
        .SmallInt => |v| @floatFromInt(v),
        .BigInt => |v| @floatFromInt(v),
        .Real => |v| @floatCast(v),
        .Double => |v| v,
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
        else => null,
    };
}

/// The dimension of a numeric ExtValue list, or null when the list is empty,
/// wider than a vector dimension, or carries a non-numeric element. Skipping
/// (rather than erroring) keeps a `{embedding: ['a','b']}` row a non-candidate
/// exactly as a String-typed property already is.
fn numericExtListDim(items: []const eval_extended.ExtValue) ?u16 {
    if (items.len == 0 or items.len > std.math.maxInt(u16)) return null;
    for (items) |item| {
        if (numericExtValueAsF64(item) == null) return null;
    }
    return @intCast(items.len);
}

fn vectorFromPropertyValue(allocator: std.mem.Allocator, prop: graph_store.PropertyValue) ?OwnedVector {
    const ext = switch (prop) {
        .ExtValue => |value| value,
        else => return null,
    };

    return switch (ext) {
        .VectorF32 => |vec| .{ .value = .{ .dim = vec.dim, .data = vec.data } },
        .VectorI32 => |vec| blk: {
            const converted = allocator.alloc(f32, @intCast(vec.dim)) catch return null;
            for (vec.data, 0..) |item, i| converted[i] = @floatFromInt(item);
            break :blk .{
                .value = .{ .dim = vec.dim, .data = converted },
                .owned = converted,
            };
        },
        // geode#877 (a): a LIST-typed embedding property was skipped here, so
        // the index was built over NOTHING and then shadowed the brute-force
        // scan (geode#877 (b)) — the compounded silent empty result.
        .List => |items| blk: {
            const dim = numericExtListDim(items) orelse break :blk null;
            const converted = allocator.alloc(f32, dim) catch break :blk null;
            for (items, 0..) |item, i| {
                converted[i] = @floatCast(numericExtValueAsF64(item).?);
            }
            break :blk .{
                .value = .{ .dim = dim, .data = converted },
                .owned = converted,
            };
        },
        else => null,
    };
}

/// ENG-3912: the dimension of a stored vector property, or null when the
/// property does not hold a vector.
fn vectorDimOfPropertyValue(prop: graph_store.PropertyValue) ?u16 {
    const ext = switch (prop) {
        .ExtValue => |value| value,
        else => return null,
    };
    return switch (ext) {
        .VectorF32 => |vec| vec.dim,
        .VectorI32 => |vec| vec.dim,
        // geode#877 (a): keep the dimension inference in lock-step with
        // `vectorFromPropertyValue` above, or an index over a list-typed
        // property would infer dimension 0 for rows it then indexes at dim N.
        .List => |items| numericExtListDim(items),
        else => null,
    };
}

fn matchesLabelProperty(
    meta: *const IndexManager.VectorDimEntry,
    labels: []const []const u8,
    property: []const u8,
) bool {
    if (!std.mem.eql(u8, meta.property, property)) return false;
    for (labels) |lb| {
        if (std.mem.eql(u8, meta.label, lb)) return true;
    }
    return false;
}

fn latLonFromPropertyValue(prop: graph_store.PropertyValue) ?geographic.LatLon {
    const ext = switch (prop) {
        .ExtValue => |value| value,
        else => return null,
    };

    return switch (ext) {
        .LatLon => |location| geographic.LatLon.initUnchecked(location.lat, location.lon),
        .LatLonAlt => |location| geographic.LatLon.initUnchecked(location.lat, location.lon),
        else => null,
    };
}

fn networkValueFromPropertyValue(prop: graph_store.PropertyValue) ?@import("../storage/heap.zig").Value {
    return switch (prop) {
        .ExtValue => |ext| switch (ext) {
            .IpAddr, .Subnet, .Mac => property_codec.extValueToHeapValue(ext),
            else => null,
        },
        else => null,
    };
}

fn signatureFromPropertyValue(allocator: std.mem.Allocator, prop: graph_store.PropertyValue) ?cryptographic.Signature {
    const ext = switch (prop) {
        .ExtValue => |value| value,
        else => return null,
    };

    return switch (ext) {
        .Text => |text| cryptographic.Signature.fromString(text, allocator) catch null,
        .Str => |text| cryptographic.Signature.fromString(text, allocator) catch null,
        else => null,
    };
}

fn intRangeFromPropertyValue(prop: graph_store.PropertyValue) ?@import("../types/range.zig").IntRange {
    return switch (prop) {
        .ExtValue => |ext| switch (ext) {
            .IntRange => |r| r,
            else => null,
        },
        else => null,
    };
}

fn jsonbFromPropertyValue(allocator: std.mem.Allocator, prop: graph_store.PropertyValue) ?jsonb.JsonbDocument {
    return switch (prop) {
        .ExtValue => |ext| switch (ext) {
            .Jsonb => |doc| jsonb.JsonbDocument.fromString(allocator, doc.data) catch null,
            .Json => |doc| jsonb.JsonbDocument.fromString(allocator, doc) catch null,
            else => null,
        },
        .String => |text| jsonb.JsonbDocument.fromString(allocator, text) catch null,
        else => null,
    };
}

fn domainFromPropertyValue(allocator: std.mem.Allocator, prop: graph_store.PropertyValue) ?url.Domain {
    return switch (prop) {
        .ExtValue => |ext| switch (ext) {
            .Domain => |domain| cloneDomain(allocator, domain),
            .Url => |parsed_url| url.Domain.fromString(allocator, parsed_url.host) catch null,
            .Text => |text| url.Domain.fromString(allocator, text) catch null,
            .Str => |text| url.Domain.fromString(allocator, text) catch null,
            else => null,
        },
        .String => |text| url.Domain.fromString(allocator, text) catch null,
        else => null,
    };
}

fn cloneDomain(allocator: std.mem.Allocator, domain: url.Domain) ?url.Domain {
    const domain_str = domain.toString(allocator) catch return null;
    defer allocator.free(domain_str);
    return url.Domain.fromString(allocator, domain_str) catch null;
}
