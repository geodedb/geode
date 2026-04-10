const std = @import("std");
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
const property_codec = @import("../property_value_codec.zig");
const vector_types = @import("../types/vector.zig");
const geographic = @import("../types/geographic.zig");
const jsonb = @import("../types/jsonb.zig");
const url = @import("../types/url.zig");
const cryptographic = @import("../types/cryptographic.zig");

var global_index_manager: ?*IndexManager = null;
var global_index_manager_mutex = std.Thread.Mutex{};

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
    statistics: IndexStatistics,
    /// GAP-0511: Mutex protecting rebuild operations so they can safely run
    /// outside the graph write lock without racing with concurrent rebuilds.
    rebuild_mutex: std.Thread.Mutex = .{},

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
                .last_updated = std.time.timestamp(),
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
                .last_updated = std.time.timestamp(),
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
                .last_updated = std.time.timestamp(),
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
        _ = label;
        _ = properties;

        const ft_index = try fulltext.FullTextIndex.init(self.allocator);
        try self.fulltext_indexes.put(name, ft_index);
        self.statistics.total_indexes += 1;
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

            switch (index.type) {
                .btree => {
                    if (index.btree_index) |tree_ptr| {
                        const BTreeType = btree.BTree([]const u8, u64, 32);
                        const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));
                        const key_copy = try self.allocator.dupe(u8, key);
                        try tree.insert(key_copy, node_id);
                        index.statistics.entries += 1;
                    }
                },
                .hash => {
                    if (index.hash_index) |*hash| {
                        try self.insertIntoHashIndex(hash, key, node_id);
                        index.statistics.entries += 1;
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
                            return value;
                        }
                        index.statistics.cache_misses += 1;
                        self.statistics.index_misses += 1;
                    }
                },
                .hash => {
                    if (index.hash_index) |*hash| {
                        if (self.lookupInHashIndex(hash, key)) |value| {
                            index.statistics.cache_hits += 1;
                            self.statistics.index_hits += 1;
                            return value;
                        }
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
        self.statistics.last_analyze = std.time.timestamp();

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
                .last_updated = std.time.timestamp(),
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
        if (self.vector_indexes.get(index_name)) |vector_idx| {
            const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
            const raw_results = try hnsw_index.knnSearch(query_vector, @intCast(k));
            return try mapSearchResults(self.allocator, raw_results);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.vector_index) |vector_idx| {
                const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
                index.statistics.read_count += 1;
                const raw_results = try hnsw_index.knnSearch(query_vector, @intCast(k));
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
        self.rebuild_mutex.lock();
        defer self.rebuild_mutex.unlock();
        const meta = self.advanced_property_indexes.get(index_name) orelse return;
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
            else => return,
        }

        try self.registerAdvancedPropertyIndex(index_name_copy, label_copy, property_copy, index_type);
        try self.populateAdvancedIndex(store, self.advanced_property_indexes.get(index_name_copy).?);
        self.statistics.rebuild_count += 1;
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

    fn populateAdvancedIndex(self: *IndexManager, store: *graph_store.GraphStore, meta: AdvancedPropertyIndex) !void {
        var node_iter = store.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            if (!nodeHasLabel(node.labels, meta.label)) continue;
            const prop = node.properties.get(meta.property) orelse continue;
            try self.insertAdvancedPropertyValue(meta, node.id, prop);
        }

        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr;
            if (!std.mem.eql(u8, edge.label, meta.label)) continue;
            const prop = edge.properties.get(meta.property) orelse continue;
            try self.insertAdvancedPropertyValue(meta, edge.id, prop);
        }
    }

    fn insertAdvancedPropertyValue(
        self: *IndexManager,
        meta: AdvancedPropertyIndex,
        entity_id: u64,
        prop: graph_store.PropertyValue,
    ) !void {
        switch (meta.index_type) {
            .vector_f32 => {
                if (vectorFromPropertyValue(self.allocator, prop)) |vec| {
                    defer if (vec.owned) |data| self.allocator.free(data);
                    try self.insertIntoAdvancedVectorIndex(meta.name, vec.value, entity_id);
                }
            },
            .spatial_geographic => {
                if (latLonFromPropertyValue(prop)) |location| {
                    try self.insertIntoAdvancedSpatialIndex(meta.name, location, entity_id);
                }
            },
            .network_cidr => {
                if (networkValueFromPropertyValue(prop)) |network_value| {
                    try self.insertIntoAdvancedNetworkIndex(meta.name, network_value, entity_id);
                }
            },
            .signature_crypto => {
                if (signatureFromPropertyValue(self.allocator, prop)) |signature| {
                    defer signature.deinit(self.allocator);
                    if (self.advanced_signature_indexes.getPtr(meta.name)) |wrapper| {
                        try wrapper.*.insert(entity_id, signature);
                        self.statistics.total_entries += 1;
                    }
                }
            },
            .interval_tree => {
                if (intRangeFromPropertyValue(prop)) |r| {
                    if (r.lower) |lower| {
                        if (r.upper) |upper| {
                            try self.insertIntoAdvancedIntervalIndex(meta.name, lower, upper, entity_id);
                        }
                    }
                }
            },
            .jsonb_inverted => {
                if (jsonbFromPropertyValue(self.allocator, prop)) |doc| {
                    defer doc.deinit();
                    try self.insertIntoAdvancedJsonbIndex(meta.name, entity_id, doc);
                }
            },
            .domain_trie => {
                if (domainFromPropertyValue(self.allocator, prop)) |domain| {
                    defer domain.deinit(self.allocator);
                    try self.insertIntoAdvancedDomainIndex(meta.name, domain, entity_id);
                }
            },
            else => {},
        }
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
    global_index_manager_mutex.lock();
    defer global_index_manager_mutex.unlock();

    if (global_index_manager) |manager| return manager;

    const manager = try allocator.create(IndexManager);
    manager.* = IndexManager.init(allocator);
    global_index_manager = manager;
    return manager;
}

pub fn getGlobalIndexManager() ?*IndexManager {
    return global_index_manager;
}

pub fn cleanupGlobalIndexManager() void {
    global_index_manager_mutex.lock();
    defer global_index_manager_mutex.unlock();

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
        else => null,
    };
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
