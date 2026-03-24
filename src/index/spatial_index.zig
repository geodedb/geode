const std = @import("std");
const rtree = @import("rtree.zig");
const geographic_types = @import("../types/geographic.zig");
const heap = @import("../storage/heap.zig");

// CANARY: REQ=REQ-GQL-SPATIAL-INDEX-001; FEATURE="Spatial Index Integration"; ASPECT=Index; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SPATIAL_INDEX_001_All; OWNER=index; UPDATED=2025-01-03

/// High-level spatial index interface that bridges Geode's geographic types with R-tree
pub const SpatialIndex = struct {
    allocator: std.mem.Allocator,
    rtree_index: rtree.RTree,
    value_storage: std.AutoHashMap(u64, heap.Value),
    coordinate_storage: std.AutoHashMap(u64, Coordinate),
    next_id: u64,

    const IndexError = error{
        InvalidGeographicType,
        CoordinateNotFound,
        OutOfMemory,
        IndexCorrupted,
        InvalidBounds,
    };

    /// Internal coordinate representation for spatial indexing
    const Coordinate = struct {
        lat: f64,
        lon: f64,
        alt: ?f64 = null,

        pub fn toMBR(self: Coordinate) rtree.MBR {
            return rtree.MBR{
                .min_x = self.lon,
                .min_y = self.lat,
                .max_x = self.lon,
                .max_y = self.lat,
            };
        }

        pub fn toBoundingBox(self: Coordinate, radius_meters: f64) rtree.MBR {
            // Convert radius in meters to approximate degrees
            const lat_deg_per_meter = 1.0 / 111111.0; // Approximate
            const lon_deg_per_meter = 1.0 / (111111.0 * @cos(self.lat * std.math.pi / 180.0));

            const lat_offset = radius_meters * lat_deg_per_meter;
            const lon_offset = radius_meters * lon_deg_per_meter;

            return rtree.MBR{
                .min_x = self.lon - lon_offset,
                .min_y = self.lat - lat_offset,
                .max_x = self.lon + lon_offset,
                .max_y = self.lat + lat_offset,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) SpatialIndex {
        return SpatialIndex{
            .allocator = allocator,
            .rtree_index = rtree.RTree.init(allocator, 8), // Max 8 entries per node
            .value_storage = std.AutoHashMap(u64, heap.Value).init(allocator),
            .coordinate_storage = std.AutoHashMap(u64, Coordinate).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *SpatialIndex) void {
        self.rtree_index.deinit();

        // Clean up stored values
        var iter = self.value_storage.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.value_storage.deinit();
        self.coordinate_storage.deinit();
    }

    /// Insert a LatLon point into the spatial index
    pub fn insertLatLon(self: *SpatialIndex, latlon: geographic_types.LatLon, node_id: ?u64) !u64 {
        const id = node_id orelse self.getNextId();

        const coord = Coordinate{ .lat = latlon.lat, .lon = latlon.lon };
        const mbr = coord.toMBR();

        // Insert into R-tree
        try self.rtree_index.insert(mbr, id);

        // Store the original value and coordinate
        const stored_value = heap.Value{ .latlon = latlon };
        try self.value_storage.put(id, stored_value);
        try self.coordinate_storage.put(id, coord);

        return id;
    }

    /// Insert a LatLonAlt point into the spatial index
    pub fn insertLatLonAlt(self: *SpatialIndex, latlonalt: geographic_types.LatLonAlt, node_id: ?u64) !u64 {
        const id = node_id orelse self.getNextId();

        const coord = Coordinate{ .lat = latlonalt.lat, .lon = latlonalt.lon, .alt = latlonalt.alt };
        const mbr = coord.toMBR();

        // Insert into R-tree (2D projection)
        try self.rtree_index.insert(mbr, id);

        // Store the original value and coordinate
        const stored_value = heap.Value{ .latlonalt = latlonalt };
        try self.value_storage.put(id, stored_value);
        try self.coordinate_storage.put(id, coord);

        return id;
    }

    /// Insert a GeoPoint into the spatial index
    pub fn insertGeoPoint(self: *SpatialIndex, geopoint: geographic_types.GeoPoint, node_id: ?u64) !u64 {
        const id = node_id orelse self.getNextId();

        const coord = Coordinate{ .lat = geopoint.lat(), .lon = geopoint.lon(), .alt = geopoint.alt() orelse 0.0 };
        const mbr = coord.toMBR();

        // Insert into R-tree
        try self.rtree_index.insert(mbr, id);

        // Store the original value and coordinate
        const stored_value = heap.Value{ .geopoint = geopoint };
        try self.value_storage.put(id, stored_value);
        try self.coordinate_storage.put(id, coord);

        return id;
    }

    /// Search for points within a bounding box
    pub fn searchBoundingBox(self: *const SpatialIndex, min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64) !SpatialSearchResult {
        const query_mbr = rtree.MBR{
            .min_x = min_lon,
            .min_y = min_lat,
            .max_x = max_lon,
            .max_y = max_lat,
        };

        var result_ids = std.ArrayList(u64).init(self.allocator);
        defer result_ids.deinit();

        try self.rtree_index.search(query_mbr, &result_ids);

        var search_result = SpatialSearchResult.init(self.allocator);

        for (result_ids.items) |id| {
            if (self.value_storage.get(id)) |stored_value| {
                if (self.coordinate_storage.get(id)) |coord| {
                    try search_result.results.append(.{
                        .id = id,
                        .coordinate = coord,
                        .value = stored_value,
                    });
                }
            }
        }

        return search_result;
    }

    /// Search for points within a radius (in meters) of a center point
    pub fn searchRadius(self: *const SpatialIndex, center_lat: f64, center_lon: f64, radius_meters: f64) !SpatialSearchResult {
        const center = Coordinate{ .lat = center_lat, .lon = center_lon };
        const query_mbr = center.toBoundingBox(radius_meters);

        var result_ids = std.ArrayList(u64).init(self.allocator);
        defer result_ids.deinit();

        try self.rtree_index.search(query_mbr, &result_ids);

        var search_result = SpatialSearchResult.init(self.allocator);

        // Filter results by actual distance
        for (result_ids.items) |id| {
            if (self.value_storage.get(id)) |stored_value| {
                if (self.coordinate_storage.get(id)) |coord| {
                    const distance = haversineDistance(center_lat, center_lon, coord.lat, coord.lon);
                    if (distance <= radius_meters) {
                        try search_result.results.append(.{
                            .id = id,
                            .coordinate = coord,
                            .value = stored_value,
                            .distance_meters = distance,
                        });
                    }
                }
            }
        }

        // Sort by distance
        std.sort.pdq(
            SpatialMatch,
            search_result.results.items,
            {},
            struct {
                fn lessThan(_: void, a: SpatialMatch, b: SpatialMatch) bool {
                    const a_dist = a.distance_meters orelse std.math.inf(f64);
                    const b_dist = b.distance_meters orelse std.math.inf(f64);
                    return a_dist < b_dist;
                }
            }.lessThan,
        );

        return search_result;
    }

    /// Find k nearest neighbors to a point
    pub fn searchKNearest(self: *const SpatialIndex, center_lat: f64, center_lon: f64, k: usize) !SpatialSearchResult {
        // Start with a small radius and expand until we have enough results
        var radius_meters: f64 = 1000; // Start with 1km
        const max_radius: f64 = 40075000; // Half of Earth's circumference

        while (radius_meters <= max_radius) {
            var results = try self.searchRadius(center_lat, center_lon, radius_meters);
            if (results.len() >= k) {
                // Trim to k results
                if (results.results.items.len > k) {
                    results.results.shrinkRetainingCapacity(k);
                }
                return results;
            }
            results.deinit();
            radius_meters *= 2; // Double the search radius
        }

        // Return all found results if we couldn't find k points
        return self.searchRadius(center_lat, center_lon, max_radius);
    }

    /// Remove a point from the spatial index
    pub fn remove(self: *SpatialIndex, id: u64) bool {
        if (self.coordinate_storage.get(id)) |coord| {
            const mbr = coord.toMBR();

            // Remove from R-tree
            const removed = self.rtree_index.remove(mbr, id);

            // Remove from storage
            _ = self.value_storage.remove(id);
            _ = self.coordinate_storage.remove(id);

            return removed;
        }
        return false;
    }

    /// Get a geographic value by ID
    pub fn getValue(self: *const SpatialIndex, id: u64) ?heap.Value {
        return self.value_storage.get(id);
    }

    /// Get statistics about the spatial index
    pub fn getStats(self: *const SpatialIndex) SpatialIndexStats {
        return SpatialIndexStats{
            .total_points = self.value_storage.count(),
            .rtree_height = self.rtree_index.height,
            .rtree_nodes = self.rtree_index.count,
        };
    }

    fn getNextId(self: *SpatialIndex) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

/// Haversine distance calculation in meters
fn haversineDistance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const R = 6371000.0; // Earth's radius in meters
    const pi = std.math.pi;

    const lat1_rad = lat1 * pi / 180.0;
    const lat2_rad = lat2 * pi / 180.0;
    const dlat = (lat2 - lat1) * pi / 180.0;
    const dlon = (lon2 - lon1) * pi / 180.0;

    const a = @sin(dlat / 2.0) * @sin(dlat / 2.0) +
        @cos(lat1_rad) * @cos(lat2_rad) *
            @sin(dlon / 2.0) * @sin(dlon / 2.0);
    const c = 2.0 * std.math.atan2(@sqrt(a), @sqrt(1.0 - a));

    return R * c;
}

/// Result of a spatial search
pub const SpatialSearchResult = struct {
    results: std.ArrayList(SpatialMatch),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpatialSearchResult {
        return SpatialSearchResult{
            .results = std.ArrayList(SpatialMatch).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpatialSearchResult) void {
        self.results.deinit();
    }

    pub fn len(self: *const SpatialSearchResult) usize {
        return self.results.items.len;
    }

    pub fn get(self: *const SpatialSearchResult, index: usize) ?SpatialMatch {
        if (index < self.results.items.len) {
            return self.results.items[index];
        }
        return null;
    }
};

/// A single match from spatial search
pub const SpatialMatch = struct {
    id: u64,
    coordinate: SpatialIndex.Coordinate,
    value: heap.Value,
    distance_meters: ?f64 = null,
};

/// Statistics about a spatial index
pub const SpatialIndexStats = struct {
    total_points: u32,
    rtree_height: u16,
    rtree_nodes: u64,
};

/// Manager for multiple spatial indexes
pub const SpatialIndexManager = struct {
    allocator: std.mem.Allocator,
    indexes: std.StringHashMap(*SpatialIndex),

    pub fn init(allocator: std.mem.Allocator) SpatialIndexManager {
        return SpatialIndexManager{
            .allocator = allocator,
            .indexes = std.StringHashMap(*SpatialIndex).init(allocator),
        };
    }

    pub fn deinit(self: *SpatialIndexManager) void {
        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.indexes.deinit();
    }

    /// Create a new spatial index
    pub fn createIndex(self: *SpatialIndexManager, name: []const u8) !void {
        if (self.indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const index = try self.allocator.create(SpatialIndex);
        index.* = SpatialIndex.init(self.allocator);

        const owned_name = try self.allocator.dupe(u8, name);
        try self.indexes.put(owned_name, index);
    }

    /// Get an existing spatial index
    pub fn getIndex(self: *SpatialIndexManager, name: []const u8) ?*SpatialIndex {
        return self.indexes.get(name);
    }

    /// Drop a spatial index
    pub fn dropIndex(self: *SpatialIndexManager, name: []const u8) bool {
        if (self.indexes.fetchRemove(name)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    /// List all spatial indexes
    pub fn listIndexes(self: *const SpatialIndexManager, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        defer names.deinit();

        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            try names.append(try allocator.dupe(u8, entry.key_ptr.*));
        }

        return names.toOwnedSlice();
    }
};

// Test suite
test "SpatialIndex basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = SpatialIndex.init(allocator);
    defer index.deinit();

    // Test LatLon insertion
    const point1 = geographic_types.LatLon{ .lat = 40.7128, .lon = -74.0060 }; // NYC
    const point2 = geographic_types.LatLon{ .lat = 34.0522, .lon = -118.2437 }; // LA
    const point3 = geographic_types.LatLon{ .lat = 40.7589, .lon = -73.9851 }; // Times Square

    _ = try index.insertLatLon(point1, null);
    _ = try index.insertLatLon(point2, null);
    _ = try index.insertLatLon(point3, null);

    // Test bounding box search
    var results = try index.searchBoundingBox(40.0, -75.0, 41.0, -73.0);
    defer results.deinit();

    // Should find NYC and Times Square, but not LA
    try testing.expect(results.len() == 2);

    // Test radius search
    var radius_results = try index.searchRadius(40.7128, -74.0060, 10000); // 10km from NYC
    defer radius_results.deinit();

    try testing.expect(radius_results.len() >= 1);

    // Test stats
    const stats = index.getStats();
    try testing.expectEqual(@as(u32, 3), stats.total_points);
}

test "SpatialIndex distance calculations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = SpatialIndex.init(allocator);
    defer index.deinit();

    // Test points in NYC area
    const central_park = geographic_types.LatLon{ .lat = 40.7812, .lon = -73.9665 };
    const times_square = geographic_types.LatLon{ .lat = 40.7589, .lon = -73.9851 };

    _ = try index.insertLatLon(central_park, null);
    _ = try index.insertLatLon(times_square, null);

    // Search within 3km of Central Park
    var results = try index.searchRadius(40.7812, -73.9665, 3000);
    defer results.deinit();

    try testing.expect(results.len() >= 1);

    // Check that distances are calculated
    for (results.results.items) |result| {
        try testing.expect(result.distance_meters != null);
        try testing.expect(result.distance_meters.? <= 3000);
    }
}

test "SpatialIndex k-nearest neighbors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = SpatialIndex.init(allocator);
    defer index.deinit();

    // Add several points around NYC
    const points = [_]geographic_types.LatLon{
        .{ .lat = 40.7128, .lon = -74.0060 }, // NYC
        .{ .lat = 40.7589, .lon = -73.9851 }, // Times Square
        .{ .lat = 40.7812, .lon = -73.9665 }, // Central Park
        .{ .lat = 40.6782, .lon = -73.9442 }, // Brooklyn
        .{ .lat = 40.8176, .lon = -73.9782 }, // Harlem
    };

    for (points) |point| {
        _ = try index.insertLatLon(point, null);
    }

    // Find 3 nearest to NYC
    var results = try index.searchKNearest(40.7128, -74.0060, 3);
    defer results.deinit();

    try testing.expectEqual(@as(usize, 3), results.len());

    // Results should be sorted by distance
    for (0..results.len() - 1) |i| {
        const dist1 = results.get(i).?.distance_meters.?;
        const dist2 = results.get(i + 1).?.distance_meters.?;
        try testing.expect(dist1 <= dist2);
    }
}

test "SpatialIndexManager operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = SpatialIndexManager.init(allocator);
    defer manager.deinit();

    // Create indexes
    try manager.createIndex("locations");
    try manager.createIndex("landmarks");

    // Test getting indexes
    const locations_index = manager.getIndex("locations");
    try testing.expect(locations_index != null);

    const landmarks_index = manager.getIndex("landmarks");
    try testing.expect(landmarks_index != null);

    // Test listing indexes
    const index_names = try manager.listIndexes(allocator);
    defer {
        for (index_names) |name| {
            allocator.free(name);
        }
        allocator.free(index_names);
    }
    try testing.expectEqual(@as(usize, 2), index_names.len);

    // Test dropping index
    try testing.expect(manager.dropIndex("landmarks"));
    try testing.expect(manager.getIndex("landmarks") == null);
}
