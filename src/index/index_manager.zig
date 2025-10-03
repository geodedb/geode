const std = @import("std");
const Allocator = std.mem.Allocator;
const btree = @import("btree.zig");
const fulltext = @import("fulltext.zig");
const hnsw = @import("hnsw.zig");
const rtree = @import("rtree.zig");
const advanced_types = @import("advanced_types_index.zig");
const vector_index = @import("vector_index.zig");
const spatial_index = @import("spatial_index.zig");

// Comprehensive index management for graph database
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
    statistics: IndexStatistics,

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
            .composite_indexes = std.ArrayList(CompositeIndex).initCapacity(allocator, 0) catch unreachable,
            .fulltext_indexes = std.StringHashMap(fulltext.FullTextIndex).init(allocator),
            .spatial_indexes = std.StringHashMap(*rtree.RTree).init(allocator),
            .vector_indexes = std.StringHashMap(*anyopaque).init(allocator),
            // Initialize advanced type indexes
            .advanced_vector_indexes = std.StringHashMap(*advanced_types.VectorIndexWrapper).init(allocator),
            .advanced_spatial_indexes = std.StringHashMap(*advanced_types.SpatialIndexWrapper).init(allocator),
            .advanced_network_indexes = std.StringHashMap(*advanced_types.NetworkIndexWrapper).init(allocator),
            .advanced_signature_indexes = std.StringHashMap(*advanced_types.SignatureIndexWrapper).init(allocator),
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
                    bucket.entries.deinit();
                }
                self.allocator.free(hash.buckets);
            }
        }
        self.property_indexes.deinit();

        var label_it = self.label_indexes.iterator();
        while (label_it.next()) |entry| {
            entry.value_ptr.node_ids.deinit();
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
        self.composite_indexes.deinit();

        var ft_it = self.fulltext_indexes.iterator();
        while (ft_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.fulltext_indexes.deinit();

        var spatial_it = self.spatial_indexes.iterator();
        while (spatial_it.next()) |entry| {
            entry.value_ptr.deinit();
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
        }
        self.advanced_vector_indexes.deinit();
        
        var adv_spatial_it = self.advanced_spatial_indexes.iterator();
        while (adv_spatial_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.advanced_spatial_indexes.deinit();
        
        var adv_network_it = self.advanced_network_indexes.iterator();
        while (adv_network_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.advanced_network_indexes.deinit();
        
        var adv_signature_it = self.advanced_signature_indexes.iterator();
        while (adv_signature_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.advanced_signature_indexes.deinit();
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
                spatial.* = rtree.RTree.init(self.allocator, 16);
                try self.spatial_indexes.put(name, spatial);
                break :blk spatial;
            } else null,
            .vector_index = if (index_type == .vector) blk: {
                // Default to 128-dimensional vectors with M=16, ef_construction=200
                const vector = try self.allocator.create(hnsw.Hnsw);
                vector.* = hnsw.Hnsw.init(self.allocator, 128, 16, 200);
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
            .node_ids = std.ArrayList(u64).initCapacity(self.allocator, 0) catch unreachable,
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

            try index.node_ids.append(node_id);

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

    // Range scan on property index
    pub fn rangeScan(
        self: *IndexManager,
        index_name: []const u8,
        _: []const u8, // start_key
        _: []const u8, // end_key
        _: bool, // inclusive
    ) ![]u64 {
        if (self.property_indexes.getPtr(index_name)) |index| {
            index.statistics.read_count += 1;

            if (index.btree_index) |tree_ptr| {
                const BTreeType = btree.BTree([]const u8, u64, 32);
                const tree: *BTreeType = @ptrCast(@alignCast(tree_ptr));
                // For now, return empty array as range scan needs more complex implementation
                _ = tree;
                return try self.allocator.alloc(u64, 0);
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
                .entries = std.ArrayList(HashIndex.Entry).initCapacity(self.allocator, 0) catch unreachable,
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
        var results = std.ArrayList(u64).init(self.allocator);
        defer results.deinit();

        if (self.spatial_indexes.get(index_name)) |spatial| {
            try spatial.search(query_mbr, &results);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.spatial_index) |spatial| {
                try spatial.search(query_mbr, &results);
                index.statistics.read_count += 1;
            }
        }

        return results.toOwnedSlice();
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
                vector.* = hnsw.Hnsw.init(self.allocator, dimensions, 16, 200);
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
        vector: []const f32,
        node_id: u64,
    ) !void {
        if (self.vector_indexes.get(index_name)) |vector_idx| {
            const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
            try hnsw_index.insert(node_id, vector);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.vector_index) |vector_idx| {
                const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
                try hnsw_index.insert(node_id, vector);
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
            return try hnsw_index.knnSearch(query_vector, k, .l2);
        } else if (self.property_indexes.getPtr(index_name)) |index| {
            if (index.vector_index) |vector_idx| {
                const hnsw_index: *hnsw.Hnsw = @ptrCast(@alignCast(vector_idx));
                index.statistics.read_count += 1;
                return try hnsw_index.knnSearch(query_vector, k, .l2);
            }
        }

        return try self.allocator.alloc(struct { id: u64, score: f64 }, 0);
    }

    // Advanced type index management functions
    
    pub fn createAdvancedVectorIndex(
        self: *IndexManager,
        name: []const u8,
        dimension: u16,
        metric: advanced_types.VectorIndexWrapper.DistanceMetric,
    ) !void {
        // Validate inputs
        if (name.len == 0 or name.len > 255) return error.InvalidInput;
        if (dimension == 0 or dimension > 8192) return error.InvalidInput;
        
        if (self.advanced_vector_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }
        
        const wrapper = try self.allocator.create(advanced_types.VectorIndexWrapper);
        errdefer self.allocator.destroy(wrapper);
        
        wrapper.* = try advanced_types.VectorIndexWrapper.init(self.allocator, dimension, metric);
        errdefer wrapper.deinit();
        
        try self.advanced_vector_indexes.put(name, wrapper);
        self.statistics.total_indexes += 1;
    }
    
    pub fn createAdvancedSpatialIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        // Validate inputs
        if (name.len == 0 or name.len > 255) return error.InvalidInput;
        
        if (self.advanced_spatial_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }
        
        const wrapper = try self.allocator.create(advanced_types.SpatialIndexWrapper);
        errdefer self.allocator.destroy(wrapper);
        
        wrapper.* = try advanced_types.SpatialIndexWrapper.init(self.allocator);
        errdefer wrapper.deinit();
        
        try self.advanced_spatial_indexes.put(name, wrapper);
        self.statistics.total_indexes += 1;
    }
    
    pub fn createAdvancedNetworkIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (self.advanced_network_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }
        
        const wrapper = try self.allocator.create(advanced_types.NetworkIndexWrapper);
        wrapper.* = try advanced_types.NetworkIndexWrapper.init(self.allocator);
        
        try self.advanced_network_indexes.put(name, wrapper);
        self.statistics.total_indexes += 1;
    }
    
    pub fn createAdvancedSignatureIndex(
        self: *IndexManager,
        name: []const u8,
    ) !void {
        if (self.advanced_signature_indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }
        
        const wrapper = try self.allocator.create(advanced_types.SignatureIndexWrapper);
        wrapper.* = try advanced_types.SignatureIndexWrapper.init(self.allocator);
        
        try self.advanced_signature_indexes.put(name, wrapper);
        self.statistics.total_indexes += 1;
    }
    
    // Advanced type index operations
    
    pub fn insertIntoAdvancedVectorIndex(
        self: *IndexManager,
        index_name: []const u8,
        vector: @import("../types/vector.zig").VectorF32,
        entity_id: u64,
    ) !void {
        if (self.advanced_vector_indexes.getPtr(index_name)) |wrapper| {
            try wrapper.*.insert(entity_id, vector);
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
    
    pub fn queryAdvancedSpatialIndex(
        self: *IndexManager,
        index_name: []const u8,
        query_location: @import("../types/geographic.zig").LatLon,
        radius_km: f64,
    ) ![]advanced_types.SpatialSearchResult {
        if (self.advanced_spatial_indexes.getPtr(index_name)) |wrapper| {
            return try wrapper.*.search(query_location, radius_km, self.allocator);
        } else {
            return error.IndexNotFound;
        }
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
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .spatial_geographic => {
                if (self.advanced_spatial_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .network_cidr => {
                if (self.advanced_network_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            .signature_crypto => {
                if (self.advanced_signature_indexes.fetchRemove(index_name)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                    self.statistics.total_indexes -= 1;
                    return true;
                }
            },
            else => return false,
        }
        return false;
    }
};
