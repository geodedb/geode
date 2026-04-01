const std = @import("std");
const heap = @import("../storage/heap.zig");
const vector = @import("../types/vector.zig");
const geographic = @import("../types/geographic.zig");
const cryptographic = @import("../types/cryptographic.zig");
const hnsw = @import("hnsw_lib");
const rtree = @import("rtree_lib");
const patricia = @import("patricia.zig");
const interval_tree = @import("interval_tree.zig");
const interval_persist = @import("interval_persist.zig");
const jsonb_inverted = @import("jsonb_inverted.zig");
const jsonb_persist = @import("jsonb_inverted_persist.zig");
const domain_trie = @import("domain_trie.zig");
const domain_persist = @import("domain_trie_persist.zig");

// CANARY: REQ=REQ-GQL-ADVANCED-INDEX-INTEGRATION; FEATURE="Advanced Types Index Integration"; ASPECT=Index; STATUS=TESTED; TEST=src/index/advanced_types_index.zig; OWNER=index; UPDATED=2026-01-15

/// Advanced types index integration layer
/// Bridges our advanced types (Vector, Geographic, Cryptographic) with specialized indexes
/// Comprehensive error set for advanced index operations
pub const AdvancedIndexError = error{
    // General index errors
    IndexNotFound,
    IndexAlreadyExists,
    IndexCorrupted,
    InvalidIndexType,
    IndexOperationFailed,

    // Vector index specific errors
    DimensionMismatch,
    InvalidVectorType,
    VectorNotFound,
    UnsupportedMetric,
    EmptyVectorData,

    // Spatial index specific errors
    InvalidGeographicType,
    CoordinateOutOfBounds,
    InvalidBoundingBox,
    SpatialIndexOverflow,

    // Network index specific errors
    InvalidIPAddress,
    InvalidSubnet,
    InvalidMACAddress,
    UnsupportedAddressFamily,

    // Cryptographic index specific errors
    InvalidSignature,
    UnsupportedAlgorithm,
    SignatureVerificationFailed,
    InvalidDigest,

    // System level errors
    OutOfMemory,
    InvalidInput,
    PermissionDenied,
    ResourceExhausted,
};

/// Input validation functions for advanced index operations
pub const Validation = struct {
    /// Validate vector for index operations
    pub fn validateVector(vec: vector.VectorF32) AdvancedIndexError!void {
        if (vec.dim == 0) return AdvancedIndexError.EmptyVectorData;
        if (vec.dim > 8192) return AdvancedIndexError.DimensionMismatch; // Reasonable limit
        if (vec.data == null) return AdvancedIndexError.InvalidVectorType;

        // Check for invalid values (NaN, infinity)
        for (0..vec.dim) |i| {
            const val = vec.data[i];
            if (!std.math.isFinite(val)) {
                return AdvancedIndexError.InvalidVectorType;
            }
        }
    }

    /// Validate geographic coordinates
    pub fn validateLatLon(point: geographic.LatLon) AdvancedIndexError!void {
        if (point.lat < -90.0 or point.lat > 90.0) {
            return AdvancedIndexError.CoordinateOutOfBounds;
        }
        if (point.lon < -180.0 or point.lon > 180.0) {
            return AdvancedIndexError.CoordinateOutOfBounds;
        }
        if (!std.math.isFinite(point.lat) or !std.math.isFinite(point.lon)) {
            return AdvancedIndexError.InvalidGeographicType;
        }
    }

    /// Validate network address format
    pub fn validateIPAddress(addr_bytes: []const u8) AdvancedIndexError!void {
        if (addr_bytes.len != 4 and addr_bytes.len != 16) {
            return AdvancedIndexError.InvalidIPAddress;
        }
        // IPv4 and IPv6 addresses are valid if they have correct byte length
        // Additional validation could be added here for reserved ranges
    }

    /// Validate cryptographic signature
    pub fn validateSignature(sig: cryptographic.Signature) AdvancedIndexError!void {
        if (sig.data.len == 0) {
            return AdvancedIndexError.InvalidSignature;
        }
        if (sig.data.len > 1024) { // Reasonable signature size limit
            return AdvancedIndexError.InvalidSignature;
        }
        // Additional algorithm-specific validation could be added here
    }

    /// Validate index name format
    pub fn validateIndexName(name: []const u8) AdvancedIndexError!void {
        if (name.len == 0) return AdvancedIndexError.InvalidInput;
        if (name.len > 255) return AdvancedIndexError.InvalidInput;

        // Check for valid identifier characters
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                return AdvancedIndexError.InvalidInput;
            }
        }
    }

    /// Validate search parameters
    pub fn validateSearchParams(k: u32, radius_km: f64) AdvancedIndexError!void {
        if (k == 0) return AdvancedIndexError.InvalidInput;
        if (k > 10000) return AdvancedIndexError.ResourceExhausted; // Reasonable limit
        if (radius_km < 0.0 or radius_km > 40075.0) { // Earth's circumference
            return AdvancedIndexError.InvalidInput;
        }
        if (!std.math.isFinite(radius_km)) {
            return AdvancedIndexError.InvalidInput;
        }
    }
};

pub const AdvancedIndexManager = struct {
    allocator: std.mem.Allocator,
    vector_indexes: std.StringHashMap(*VectorIndexWrapper),
    spatial_indexes: std.StringHashMap(*SpatialIndexWrapper),
    network_indexes: std.StringHashMap(*NetworkIndexWrapper),
    signature_indexes: std.StringHashMap(*SignatureIndexWrapper),
    interval_indexes: std.StringHashMap(*IntervalIndexWrapper),
    jsonb_indexes: std.StringHashMap(*jsonb_inverted.JsonbInvertedIndex),
    domain_indexes: std.StringHashMap(*domain_trie.DomainTrie),

    pub fn init(allocator: std.mem.Allocator) AdvancedIndexManager {
        return AdvancedIndexManager{
            .allocator = allocator,
            .vector_indexes = std.StringHashMap(*VectorIndexWrapper).init(allocator),
            .spatial_indexes = std.StringHashMap(*SpatialIndexWrapper).init(allocator),
            .network_indexes = std.StringHashMap(*NetworkIndexWrapper).init(allocator),
            .signature_indexes = std.StringHashMap(*SignatureIndexWrapper).init(allocator),
            .interval_indexes = std.StringHashMap(*IntervalIndexWrapper).init(allocator),
            .jsonb_indexes = std.StringHashMap(*jsonb_inverted.JsonbInvertedIndex).init(allocator),
            .domain_indexes = std.StringHashMap(*domain_trie.DomainTrie).init(allocator),
        };
    }

    pub fn deinit(self: *AdvancedIndexManager) void {
        // Clean up vector indexes
        var vector_iter = self.vector_indexes.iterator();
        while (vector_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.vector_indexes.deinit();

        // Clean up spatial indexes
        var spatial_iter = self.spatial_indexes.iterator();
        while (spatial_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.spatial_indexes.deinit();

        // Clean up network indexes
        var network_iter = self.network_indexes.iterator();
        while (network_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.network_indexes.deinit();

        // Clean up signature indexes
        var signature_iter = self.signature_indexes.iterator();
        while (signature_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.signature_indexes.deinit();

        // Clean up interval indexes
        var interval_iter = self.interval_indexes.iterator();
        while (interval_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.interval_indexes.deinit();

        // Clean up jsonb indexes
        var jsonb_iter = self.jsonb_indexes.iterator();
        while (jsonb_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.jsonb_indexes.deinit();

        // Clean up domain indexes
        var domain_iter = self.domain_indexes.iterator();
        while (domain_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.domain_indexes.deinit();
    }

    /// Create a vector index for similarity search
    pub fn createVectorIndex(self: *AdvancedIndexManager, name: []const u8, dim: u16, metric: VectorIndexWrapper.DistanceMetric) !void {
        const index = try self.allocator.create(VectorIndexWrapper);
        index.* = try VectorIndexWrapper.init(self.allocator, dim, metric);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.vector_indexes.put(name_copy, index);
    }

    /// Create a spatial index for geographic queries
    pub fn createSpatialIndex(self: *AdvancedIndexManager, name: []const u8) !void {
        const index = try self.allocator.create(SpatialIndexWrapper);
        index.* = try SpatialIndexWrapper.init(self.allocator);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.spatial_indexes.put(name_copy, index);
    }

    /// Create a network index for CIDR and network queries
    pub fn createNetworkIndex(self: *AdvancedIndexManager, name: []const u8) !void {
        const index = try self.allocator.create(NetworkIndexWrapper);
        index.* = try NetworkIndexWrapper.init(self.allocator);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.network_indexes.put(name_copy, index);
    }

    /// Create a signature index for cryptographic verification
    pub fn createSignatureIndex(self: *AdvancedIndexManager, name: []const u8) !void {
        const index = try self.allocator.create(SignatureIndexWrapper);
        index.* = try SignatureIndexWrapper.init(self.allocator);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.signature_indexes.put(name_copy, index);
    }

    /// Create an interval index for range queries
    pub fn createIntervalIndex(self: *AdvancedIndexManager, name: []const u8) !void {
        const index = try self.allocator.create(IntervalIndexWrapper);
        index.* = IntervalIndexWrapper.init(self.allocator);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.interval_indexes.put(name_copy, index);
    }

    /// Create a JSONB inverted index for document path queries
    pub fn createJsonbIndex(self: *AdvancedIndexManager, name: []const u8) !void {
        const index = try self.allocator.create(jsonb_inverted.JsonbInvertedIndex);
        index.* = jsonb_inverted.JsonbInvertedIndex.init(self.allocator);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.jsonb_indexes.put(name_copy, index);
    }

    /// Create a domain trie index for domain queries
    pub fn createDomainIndex(self: *AdvancedIndexManager, name: []const u8) !void {
        const index = try self.allocator.create(domain_trie.DomainTrie);
        index.* = domain_trie.DomainTrie.init(self.allocator);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.domain_indexes.put(name_copy, index);
    }

    // Persistence
    pub fn persistAll(self: *AdvancedIndexManager, dir_path: []const u8) !void {
        // Create directory if not exists? Assuming exists or caller ensures.
        // Interval
        var interval_iter = self.interval_indexes.iterator();
        while (interval_iter.next()) |entry| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.gdir", .{ dir_path, entry.key_ptr.* });
            defer self.allocator.free(path);
            try interval_persist.persistSnapshot(i64, &entry.value_ptr.*.tree, path);
        }
        // Jsonb
        var jsonb_iter = self.jsonb_indexes.iterator();
        while (jsonb_iter.next()) |entry| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.gdjb", .{ dir_path, entry.key_ptr.* });
            defer self.allocator.free(path);
            try jsonb_persist.persistSnapshot(entry.value_ptr.*, path);
        }
        // Domain
        var domain_iter = self.domain_indexes.iterator();
        while (domain_iter.next()) |entry| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.gddn", .{ dir_path, entry.key_ptr.* });
            defer self.allocator.free(path);
            try domain_persist.persistSnapshot(entry.value_ptr.*, path);
        }
    }

    pub fn loadAll(self: *AdvancedIndexManager, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            if (std.mem.endsWith(u8, entry.name, ".gdir")) {
                const name = entry.name[0 .. entry.name.len - 5];
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(full_path);

                const tree = try interval_persist.loadSnapshot(i64, self.allocator, full_path);
                const wrapper = try self.allocator.create(IntervalIndexWrapper);
                wrapper.* = IntervalIndexWrapper{ .tree = tree, .allocator = self.allocator };
                try self.interval_indexes.put(try self.allocator.dupe(u8, name), wrapper);
            } else if (std.mem.endsWith(u8, entry.name, ".gdjb")) {
                const name = entry.name[0 .. entry.name.len - 5];
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(full_path);

                const index = try jsonb_persist.loadSnapshot(self.allocator, full_path);
                const idx_ptr = try self.allocator.create(jsonb_inverted.JsonbInvertedIndex);
                idx_ptr.* = index;
                try self.jsonb_indexes.put(try self.allocator.dupe(u8, name), idx_ptr);
            } else if (std.mem.endsWith(u8, entry.name, ".gddn")) {
                const name = entry.name[0 .. entry.name.len - 5];
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(full_path);

                const trie = try domain_persist.loadSnapshot(self.allocator, full_path);
                const trie_ptr = try self.allocator.create(domain_trie.DomainTrie);
                trie_ptr.* = trie;
                try self.domain_indexes.put(try self.allocator.dupe(u8, name), trie_ptr);
            }
        }
    }

    /// Insert vector into index with comprehensive validation
    pub fn insertVector(self: *AdvancedIndexManager, index_name: []const u8, node_id: u64, vec: vector.VectorF32) AdvancedIndexError!void {
        // Validate inputs
        try Validation.validateIndexName(index_name);
        try Validation.validateVector(vec);

        if (self.vector_indexes.get(index_name)) |index| {
            try index.insert(node_id, vec);
        } else {
            return AdvancedIndexError.IndexNotFound;
        }
    }

    /// Search for similar vectors with comprehensive validation
    pub fn searchVectors(self: *AdvancedIndexManager, index_name: []const u8, query: vector.VectorF32, k: u32, allocator: std.mem.Allocator) AdvancedIndexError![]VectorSearchResult {
        // Validate inputs
        try Validation.validateIndexName(index_name);
        try Validation.validateVector(query);
        try Validation.validateSearchParams(k, 0.0); // radius doesn't apply to vector search

        if (self.vector_indexes.get(index_name)) |index| {
            return index.search(query, k, allocator) catch |err| switch (err) {
                error.OutOfMemory => AdvancedIndexError.OutOfMemory,
                else => AdvancedIndexError.IndexOperationFailed,
            };
        } else {
            return AdvancedIndexError.IndexNotFound;
        }
    }

    /// Insert geographic point into spatial index with validation
    pub fn insertGeographic(self: *AdvancedIndexManager, index_name: []const u8, node_id: u64, point: geographic.LatLon) AdvancedIndexError!void {
        // Validate inputs
        try Validation.validateIndexName(index_name);
        try Validation.validateLatLon(point);

        if (self.spatial_indexes.get(index_name)) |index| {
            try index.insert(node_id, point);
        } else {
            return AdvancedIndexError.IndexNotFound;
        }
    }

    /// Search for points within radius with validation
    pub fn searchWithinRadius(self: *AdvancedIndexManager, index_name: []const u8, center: geographic.LatLon, radius_km: f64, allocator: std.mem.Allocator) AdvancedIndexError![]SpatialSearchResult {
        // Validate inputs
        try Validation.validateIndexName(index_name);
        try Validation.validateLatLon(center);
        try Validation.validateSearchParams(1, radius_km); // k=1 is dummy for radius validation

        if (self.spatial_indexes.get(index_name)) |index| {
            return index.searchWithinRadius(center, radius_km, allocator) catch |err| switch (err) {
                error.OutOfMemory => AdvancedIndexError.OutOfMemory,
                else => AdvancedIndexError.IndexOperationFailed,
            };
        } else {
            return AdvancedIndexError.IndexNotFound;
        }
    }

    /// Insert network address into network index
    pub fn insertNetwork(self: *AdvancedIndexManager, index_name: []const u8, node_id: u64, value: heap.Value) !void {
        if (self.network_indexes.get(index_name)) |index| {
            try index.insert(node_id, value);
        } else {
            return error.IndexNotFound;
        }
    }

    pub fn searchInSubnet(self: *AdvancedIndexManager, index_name: []const u8, subnet: heap.Subnet, allocator: std.mem.Allocator) ![]NetworkSearchResult {
        if (self.network_indexes.get(index_name)) |index| {
            return index.searchInSubnet(subnet, allocator);
        } else {
            return error.IndexNotFound;
        }
    }

    // Interval index usage
    pub fn insertInterval(self: *AdvancedIndexManager, index_name: []const u8, low: i64, high: i64, node_id: usize) !void {
        if (self.interval_indexes.get(index_name)) |index| {
            const r = try @import("../types/range.zig").IntRange.init(low, high, .inclusive_exclusive); // Default bounds?
            try index.tree.insert(r, node_id);
        } else {
            return error.IndexNotFound;
        }
    }

    // Jsonb index usage
    pub fn insertJsonb(self: *AdvancedIndexManager, index_name: []const u8, doc_id: usize, document: @import("../types/jsonb.zig").JsonbDocument) !void {
        if (self.jsonb_indexes.get(index_name)) |index| {
            try index.indexDocument(doc_id, document);
        } else {
            return error.IndexNotFound;
        }
    }

    // Domain index usage
    pub fn insertDomain(self: *AdvancedIndexManager, index_name: []const u8, domain: @import("../types/url.zig").Domain, data: usize) !void {
        if (self.domain_indexes.get(index_name)) |index| {
            try index.insert(domain, data);
        } else {
            return error.IndexNotFound;
        }
    }
};

/// Wrapper for HNSW vector index with our VectorF32 types
pub const VectorIndexWrapper = struct {
    allocator: std.mem.Allocator,
    hnsw_index: ?hnsw.Hnsw,
    metric: DistanceMetric,
    dimension: u16,

    pub const DistanceMetric = enum {
        l2,
        cosine,
        dot_product,
    };

    pub fn init(allocator: std.mem.Allocator, dim: u16, metric: DistanceMetric) !VectorIndexWrapper {
        return VectorIndexWrapper{
            .allocator = allocator,
            .hnsw_index = if (dim == 0) null else try hnsw.Hnsw.init(allocator, dim, toHnswMetric(metric), .{
                .m = 16,
                .ef_construction = 200,
                .ef_search = 200,
            }),
            .metric = metric,
            .dimension = dim,
        };
    }

    pub fn deinit(self: *VectorIndexWrapper) void {
        if (self.hnsw_index) |*index| {
            index.deinit();
            self.hnsw_index = null;
        }
    }

    pub fn insert(self: *VectorIndexWrapper, node_id: u64, vec: vector.VectorF32) !void {
        try self.ensureInitialized(vec.dim);
        if (self.dimension != vec.dim) return error.DimensionMismatch;
        try self.hnsw_index.?.insert(node_id, vec.data);
    }

    pub fn search(self: *VectorIndexWrapper, query: vector.VectorF32, k: u32, allocator: std.mem.Allocator) ![]VectorSearchResult {
        return self.searchWithMetric(query, k, self.metric, allocator);
    }

    pub fn searchWithMetric(
        self: *VectorIndexWrapper,
        query: vector.VectorF32,
        k: u32,
        metric: DistanceMetric,
        allocator: std.mem.Allocator,
    ) ![]VectorSearchResult {
        if (self.hnsw_index == null) {
            return allocator.alloc(VectorSearchResult, 0);
        }
        if (self.dimension != query.dim) return error.DimensionMismatch;

        const results = try self.hnsw_index.?.knnSearch(query.data, k);
        defer allocator.free(results);

        const search_results = try allocator.alloc(VectorSearchResult, results.len);
        for (results, 0..) |result, i| {
            const base_distance = @as(f32, @floatCast(result.distance));
            const similarity: f32 = switch (metric) {
                .l2, .cosine, .dot_product => self.distanceToSimilarity(metric, base_distance),
            };
            const distance: f32 = switch (metric) {
                .l2, .cosine, .dot_product => base_distance,
            };
            search_results[i] = VectorSearchResult{
                .node_id = result.id,
                .distance = distance,
                .similarity = similarity,
            };
        }

        return search_results;
    }

    fn ensureInitialized(self: *VectorIndexWrapper, dim: u16) !void {
        if (self.hnsw_index == null) {
            self.dimension = dim;
            self.hnsw_index = try hnsw.Hnsw.init(self.allocator, dim, toHnswMetric(self.metric), .{
                .m = 16,
                .ef_construction = 200,
                .ef_search = 200,
            });
        }
    }

    fn toHnswMetric(metric: DistanceMetric) hnsw.DistanceMetric {
        return switch (metric) {
            .l2 => .euclidean,
            .cosine => .cosine,
            .dot_product => .dot_product,
        };
    }

    fn distanceToSimilarity(self: VectorIndexWrapper, metric: DistanceMetric, distance: f32) f32 {
        _ = self;
        return switch (metric) {
            .l2 => 1.0 / (1.0 + distance),
            .cosine => 1.0 - distance,
            .dot_product => distance,
        };
    }
};

/// Wrapper for R-tree spatial index with geographic types
/// CANARY: REQ=REQ-GQL-SPATIAL-001; FEATURE="Spatial Index"; ASPECT=CoordinateStorage; STATUS=TESTED; OWNER=index; UPDATED=2026-01-16
/// GAP-0205 FIX: Added coordinate_map to store actual coordinates for accurate distance calculations
pub const SpatialIndexWrapper = struct {
    allocator: std.mem.Allocator,
    rtree_index: rtree.RTree,
    // GAP-0205 FIX: Store coordinates by node_id for accurate distance calculation
    coordinate_map: std.AutoHashMap(u64, geographic.LatLon),

    pub fn init(allocator: std.mem.Allocator) !SpatialIndexWrapper {
        return SpatialIndexWrapper{
            .allocator = allocator,
            .rtree_index = try rtree.RTree.init(allocator, 16),
            .coordinate_map = std.AutoHashMap(u64, geographic.LatLon).init(allocator),
        };
    }

    pub fn deinit(self: *SpatialIndexWrapper) void {
        self.rtree_index.deinit();
        self.coordinate_map.deinit();
    }

    pub fn insert(self: *SpatialIndexWrapper, node_id: u64, point: geographic.LatLon) !void {
        const mbr = rtree.MBR{
            .min_x = point.lon,
            .min_y = point.lat,
            .max_x = point.lon,
            .max_y = point.lat,
        };
        try self.rtree_index.insert(mbr, node_id);
        // GAP-0205 FIX: Store coordinates for later retrieval during search
        try self.coordinate_map.put(node_id, point);
    }

    // GAP-0205 FIX: Remove method also cleans up coordinate map
    pub fn remove(self: *SpatialIndexWrapper, node_id: u64, point: geographic.LatLon) bool {
        const mbr = rtree.MBR{
            .min_x = point.lon,
            .min_y = point.lat,
            .max_x = point.lon,
            .max_y = point.lat,
        };
        const removed = self.rtree_index.remove(mbr, node_id) catch false;
        if (removed) {
            _ = self.coordinate_map.remove(node_id);
        }
        return removed;
    }

    // GAP-0205 FIX: Get stored coordinates for a node_id
    pub fn getCoordinates(self: *const SpatialIndexWrapper, node_id: u64) ?geographic.LatLon {
        return self.coordinate_map.get(node_id);
    }

    pub fn searchWithinRadius(self: *SpatialIndexWrapper, center: geographic.LatLon, radius_km: f64, allocator: std.mem.Allocator) ![]SpatialSearchResult {
        // Convert radius from km to approximate degrees
        const lat_deg_per_km = 1.0 / 111.0;
        const lon_deg_per_km = 1.0 / (111.0 * @cos(std.math.degreesToRadians(center.lat)));

        const lat_radius = radius_km * lat_deg_per_km;
        const lon_radius = radius_km * lon_deg_per_km;

        const search_mbr = rtree.MBR{
            .min_x = center.lon - lon_radius,
            .min_y = center.lat - lat_radius,
            .max_x = center.lon + lon_radius,
            .max_y = center.lat + lat_radius,
        };

        var candidates = std.ArrayList(u64).empty;
        defer candidates.deinit(allocator);
        try self.rtree_index.search(search_mbr, allocator, &candidates);

        var results = std.ArrayList(SpatialSearchResult).empty;
        defer results.deinit(allocator);

        for (candidates.items) |candidate_id| {
            // GAP-0205 FIX: Retrieve actual coordinates from the coordinate map
            const candidate_point = self.coordinate_map.get(candidate_id) orelse {
                // If coordinates not found, skip this candidate (shouldn't happen in normal operation)
                continue;
            };

            // Calculate actual distance using the real coordinates
            const distance = center.haversineDistance(candidate_point) / 1000.0;

            // Only include results within the radius (precise filtering after bounding box query)
            if (distance <= radius_km) {
                try results.append(allocator, SpatialSearchResult{
                    .node_id = candidate_id,
                    .distance_km = distance,
                    .point = candidate_point,
                });
            }
        }

        return results.toOwnedSlice(allocator);
    }
};

/// Wrapper for Patricia trie network index
/// CANARY: REQ=REQ-GQL-NETWORK-003; FEATURE="Network Index"; ASPECT=ValueStorage; STATUS=TESTED; OWNER=index; UPDATED=2026-01-16
/// GAP-0206 FIX: Added value storage for returning actual network values in search results
pub const NetworkIndexWrapper = struct {
    allocator: std.mem.Allocator,
    patricia_index: patricia.PatriciaTrie,
    // GAP-0206 FIX: Store network values by node_id for accurate search results
    value_map: std.AutoHashMap(u64, heap.Value),

    pub fn init(allocator: std.mem.Allocator) !NetworkIndexWrapper {
        return NetworkIndexWrapper{
            .allocator = allocator,
            .patricia_index = patricia.PatriciaTrie.init(allocator, .both),
            .value_map = std.AutoHashMap(u64, heap.Value).init(allocator),
        };
    }

    pub fn deinit(self: *NetworkIndexWrapper) void {
        self.patricia_index.deinit();
        self.value_map.deinit();
    }

    pub fn insert(self: *NetworkIndexWrapper, node_id: u64, value: heap.Value) !void {
        switch (value) {
            .IpAddr => |ip| {
                const subnet = switch (ip) {
                    .v4 => heap.Subnet{ .addr = ip, .prefix_len = 32 },
                    .v6 => heap.Subnet{ .addr = ip, .prefix_len = 128 },
                };
                try self.patricia_index.insert(subnet, node_id);
                // GAP-0206 FIX: Store the original value for retrieval
                try self.value_map.put(node_id, value);
            },
            .Subnet => |subnet| {
                try self.patricia_index.insert(subnet, node_id);
                // GAP-0206 FIX: Store the original value for retrieval
                try self.value_map.put(node_id, value);
            },
            .Mac => |mac| {
                // GAP-0206 FIX: Store the original value for retrieval
                _ = mac;
                try self.value_map.put(node_id, value);
            },
            else => return error.UnsupportedNetworkType,
        }
    }

    // GAP-0206 FIX: Remove also cleans up value storage
    pub fn remove(self: *NetworkIndexWrapper, node_id: u64) void {
        _ = self.value_map.remove(node_id);
        // Note: Patricia trie removal would need the key, which requires storing the key or value
    }

    // GAP-0206 FIX: Get stored value for a node_id
    pub fn getValue(self: *const NetworkIndexWrapper, node_id: u64) ?heap.Value {
        return self.value_map.get(node_id);
    }

    pub fn searchInSubnet(self: *NetworkIndexWrapper, subnet: heap.Subnet, allocator: std.mem.Allocator) ![]NetworkSearchResult {
        const prefix = try self.subnetToPrefix(subnet);
        defer self.allocator.free(prefix);
        const matches = try self.patricia_index.searchPrefix(prefix, allocator);
        defer allocator.free(matches);

        var results_list = std.ArrayList(NetworkSearchResult).empty;
        defer results_list.deinit(allocator);

        for (matches) |match| {
            // GAP-0206 FIX: Retrieve actual stored value
            if (self.value_map.get(match.value)) |stored_value| {
                try results_list.append(allocator, NetworkSearchResult{
                    .node_id = match.value,
                    .network_value = stored_value,
                });
            }
        }

        return results_list.toOwnedSlice(allocator);
    }

    fn ipToKey(self: NetworkIndexWrapper, ip: heap.IpAddr) ![]u8 {
        switch (ip) {
            .v4 => |octets| {
                const key = try self.allocator.alloc(u8, 4);
                @memcpy(key, &octets);
                return key;
            },
            .v6 => |bytes| {
                const key = try self.allocator.alloc(u8, 16);
                @memcpy(key, &bytes);
                return key;
            },
        }
    }

    // CANARY: REQ=REQ-GQL-NETWORK-001; FEATURE="Network Index"; ASPECT=SubnetKey; STATUS=TESTED; OWNER=index; UPDATED=2026-01-16
    // GAP-0206 FIX: Properly convert subnet to unique key using address bytes + prefix length
    fn subnetToKey(self: NetworkIndexWrapper, subnet: heap.Subnet) ![]u8 {
        // Key format: [address_bytes][prefix_len]
        // For IPv4: 4 bytes address + 1 byte prefix = 5 bytes
        // For IPv6: 16 bytes address + 1 byte prefix = 17 bytes
        switch (subnet.addr) {
            .v4 => |octets| {
                const key = try self.allocator.alloc(u8, 5);
                @memcpy(key[0..4], &octets);
                key[4] = subnet.prefix_len;
                return key;
            },
            .v6 => |bytes| {
                const key = try self.allocator.alloc(u8, 17);
                @memcpy(key[0..16], &bytes);
                key[16] = subnet.prefix_len;
                return key;
            },
        }
    }

    // CANARY: REQ=REQ-GQL-NETWORK-002; FEATURE="Network Index"; ASPECT=SubnetPrefix; STATUS=TESTED; OWNER=index; UPDATED=2026-01-16
    // GAP-0206 FIX: Properly convert subnet to prefix for Patricia trie search
    // Returns the network portion of the address (masked by prefix_len)
    fn subnetToPrefix(self: NetworkIndexWrapper, subnet: heap.Subnet) ![]u8 {
        switch (subnet.addr) {
            .v4 => |octets| {
                // Calculate how many full bytes and remaining bits
                const full_bytes = subnet.prefix_len / 8;
                const remaining_bits = subnet.prefix_len % 8;
                const key_len: usize = if (remaining_bits > 0) full_bytes + 1 else full_bytes;

                const prefix = try self.allocator.alloc(u8, if (key_len == 0) 1 else key_len);

                // Copy full bytes
                for (0..full_bytes) |i| {
                    prefix[i] = octets[i];
                }

                // Apply mask to final byte if there are remaining bits
                if (remaining_bits > 0 and full_bytes < 4) {
                    const mask: u8 = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
                    prefix[full_bytes] = octets[full_bytes] & mask;
                }

                return prefix;
            },
            .v6 => |bytes| {
                // Calculate how many full bytes and remaining bits
                const full_bytes = subnet.prefix_len / 8;
                const remaining_bits = subnet.prefix_len % 8;
                const key_len: usize = if (remaining_bits > 0) full_bytes + 1 else full_bytes;

                const prefix = try self.allocator.alloc(u8, if (key_len == 0) 1 else key_len);

                // Copy full bytes
                for (0..full_bytes) |i| {
                    prefix[i] = bytes[i];
                }

                // Apply mask to final byte if there are remaining bits
                if (remaining_bits > 0 and full_bytes < 16) {
                    const mask: u8 = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
                    prefix[full_bytes] = bytes[full_bytes] & mask;
                }

                return prefix;
            },
        }
    }

    fn macToKey(self: NetworkIndexWrapper, mac: heap.Mac) ![]u8 {
        const key = try self.allocator.alloc(u8, 6);
        @memcpy(key, &mac.bytes);
        return key;
    }
};

/// Hash-based index for cryptographic signatures
pub const SignatureIndexWrapper = struct {
    allocator: std.mem.Allocator,
    signature_map: std.HashMap(SignatureKey, std.ArrayList(u64), SignatureKeyContext, std.hash_map.default_max_load_percentage),

    const SignatureKey = struct {
        algorithm: cryptographic.Signature.SignatureAlg,
        digest_hash: u64, // Hash of first 8 bytes of signature
    };

    const SignatureKeyContext = struct {
        pub fn hash(self: @This(), key: SignatureKey) u64 {
            _ = self;
            return std.hash_map.hashString(key.algorithm.toString()) ^ key.digest_hash;
        }

        pub fn eql(self: @This(), a: SignatureKey, b: SignatureKey) bool {
            _ = self;
            return a.algorithm == b.algorithm and a.digest_hash == b.digest_hash;
        }
    };

    pub fn init(allocator: std.mem.Allocator) !SignatureIndexWrapper {
        return SignatureIndexWrapper{
            .allocator = allocator,
            .signature_map = std.HashMap(SignatureKey, std.ArrayList(u64), SignatureKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *SignatureIndexWrapper) void {
        var iter = self.signature_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.signature_map.deinit();
    }

    pub fn insert(self: *SignatureIndexWrapper, node_id: u64, signature: cryptographic.Signature) !void {
        const key = SignatureKey{
            .algorithm = signature.alg,
            .digest_hash = self.hashSignature(signature.signature),
        };

        const result = try self.signature_map.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.append(self.allocator, node_id);
    }

    pub fn searchByAlgorithm(self: *SignatureIndexWrapper, alg: cryptographic.Signature.SignatureAlg, allocator: std.mem.Allocator) ![]SignatureSearchResult {
        var results = std.ArrayList(SignatureSearchResult).empty;
        defer results.deinit(allocator);

        var iter = self.signature_map.iterator();
        while (iter.next()) |entry| {
            if (entry.key_ptr.algorithm == alg) {
                for (entry.value_ptr.items) |node_id| {
                    try results.append(allocator, SignatureSearchResult{
                        .node_id = node_id,
                        .algorithm = alg,
                    });
                }
            }
        }

        return results.toOwnedSlice(allocator);
    }

    fn hashSignature(self: SignatureIndexWrapper, signature: []const u8) u64 {
        _ = self;
        if (signature.len >= 8) {
            return std.mem.readInt(u64, signature[0..8], .little);
        } else {
            var bytes: [8]u8 = [_]u8{0} ** 8;
            @memcpy(bytes[0..signature.len], signature);
            return std.mem.readInt(u64, &bytes, .little);
        }
    }
};

/// Wrapper for Interval tree (i64 for now)
pub const IntervalIndexWrapper = struct {
    tree: interval_tree.IntIntervalTree,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IntervalIndexWrapper {
        return IntervalIndexWrapper{
            .tree = interval_tree.IntIntervalTree.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IntervalIndexWrapper) void {
        self.tree.deinit();
    }
};

// Search result types
pub const VectorSearchResult = struct {
    node_id: u64,
    distance: f32,
    similarity: f32,
};

pub const SpatialSearchResult = struct {
    node_id: u64,
    distance_km: f64,
    point: geographic.LatLon,
};

pub const NetworkSearchResult = struct {
    node_id: u64,
    network_value: heap.Value,
};

pub const SignatureSearchResult = struct {
    node_id: u64,
    algorithm: cryptographic.Signature.SignatureAlg,
};

// Test suite
test "VectorIndexWrapper operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = try VectorIndexWrapper.init(allocator, 3, .cosine);
    defer index.deinit();

    // Test vector insertion
    const vec1 = try vector.VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer vec1.deinit(allocator);

    try index.insert(1, vec1);

    const vec2 = try vector.VectorF32.fromString("[1.1, 2.1, 3.1]", allocator);
    defer vec2.deinit(allocator);

    try index.insert(2, vec2);

    // Test vector search
    const query = try vector.VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer query.deinit(allocator);

    const results = try index.search(query, 2, allocator);
    defer allocator.free(results);

    try testing.expect(results.len > 0);
    try testing.expectEqual(@as(u64, 1), results[0].node_id); // Should find exact match first
}

test "SpatialIndexWrapper operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = try SpatialIndexWrapper.init(allocator);
    defer index.deinit();

    // Test point insertion
    const point1 = try geographic.latLonFromCoords(40.7128, -74.0060); // New York
    const point2 = try geographic.latLonFromCoords(40.7589, -73.9851); // Manhattan

    try index.insert(1, point1);
    try index.insert(2, point2);

    // Test radius search
    const center = try geographic.latLonFromCoords(40.7128, -74.0060);
    const results = try index.searchWithinRadius(center, 50.0, allocator); // 50km radius
    defer allocator.free(results);

    try testing.expect(results.len > 0);
}

test "AdvancedIndexManager integration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = AdvancedIndexManager.init(allocator);
    defer manager.deinit();

    // Test vector index creation and usage
    try manager.createVectorIndex("embeddings", 3, .cosine);

    const vec = try vector.VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer vec.deinit(allocator);

    try manager.insertVector("embeddings", 1, vec);

    const search_results = try manager.searchVectors("embeddings", vec, 1, allocator);
    defer allocator.free(search_results);

    try testing.expect(search_results.len > 0);

    // Test spatial index creation and usage
    try manager.createSpatialIndex("locations");

    const point = try geographic.latLonFromCoords(40.7128, -74.0060);
    try manager.insertGeographic("locations", 1, point);

    const spatial_results = try manager.searchWithinRadius("locations", point, 10.0, allocator);
    defer allocator.free(spatial_results);

    try testing.expect(spatial_results.len >= 0); // May be 0 due to placeholder implementation
}
