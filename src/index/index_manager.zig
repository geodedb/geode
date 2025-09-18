const std = @import("std");
const Allocator = std.mem.Allocator;
const btree = @import("btree.zig");
const fulltext = @import("fulltext.zig");

// Comprehensive index management for graph database
pub const IndexManager = struct {
    allocator: Allocator,
    property_indexes: std.StringHashMap(PropertyIndex),
    label_indexes: std.StringHashMap(LabelIndex),
    composite_indexes: std.ArrayList(CompositeIndex),
    fulltext_indexes: std.StringHashMap(fulltext.FullTextIndex),
    statistics: IndexStatistics,

    pub const IndexType = enum {
        btree,
        hash,
        fulltext,
        spatial,
        bitmap,
    };

    pub const PropertyIndex = struct {
        name: []const u8,
        label: []const u8,
        property: []const u8,
        type: IndexType,
        unique: bool,
        btree_index: ?btree.BTree,
        hash_index: ?HashIndex,
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
        btree_index: ?btree.BTree,
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
            .composite_indexes = std.ArrayList(CompositeIndex){},
            .fulltext_indexes = std.StringHashMap(fulltext.FullTextIndex).init(allocator),
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
            if (entry.value_ptr.btree_index) |*tree| {
                tree.deinit();
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
            if (index.btree_index) |*tree| {
                tree.deinit();
            }
        }
        self.composite_indexes.deinit();

        var ft_it = self.fulltext_indexes.iterator();
        while (ft_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.fulltext_indexes.deinit();
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
            .btree_index = if (index_type == .btree)
                btree.BTree.init(self.allocator, .{ .unique = unique })
            else
                null,
            .hash_index = if (index_type == .hash)
                try self.createHashIndex(1024)
            else
                null,
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
            .node_ids = std.ArrayList(u64){},
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
            .btree_index = btree.BTree.init(self.allocator, .{ .unique = unique }),
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

        try self.composite_indexes.append(index);
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

        var ft_index = try fulltext.FullTextIndex.init(self.allocator);
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
                    if (index.btree_index) |*tree| {
                        try tree.insert(key, node_id);
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
                    if (index.btree_index) |*tree| {
                        if (tree.search(key)) |value| {
                            index.statistics.cache_hits += 1;
                            self.statistics.index_hits += 1;
                            return value;
                        }
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
        start_key: []const u8,
        end_key: []const u8,
        inclusive: bool,
    ) ![]u64 {
        if (self.property_indexes.getPtr(index_name)) |index| {
            index.statistics.read_count += 1;

            if (index.btree_index) |*tree| {
                const results = try tree.rangeScan(start_key, end_key, inclusive);
                index.statistics.cache_hits += @intCast(results.len);
                self.statistics.index_hits += @intCast(results.len);
                return results;
            }
        }

        return &[_]u64{};
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
            if (index.btree_index) |tree| {
                index.statistics.height = tree.getHeight();
                index.statistics.fill_factor = tree.getFillFactor();
                index.statistics.size_bytes = tree.getMemoryUsage();
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
        var buckets = try self.allocator.alloc(HashIndex.Bucket, bucket_count);
        for (buckets) |*bucket| {
            bucket.entries = std.ArrayList(HashIndex.Entry){};
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

        try hash.buckets[bucket_index].entries.append(.{
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
};
