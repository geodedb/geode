const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "spatial index creation and search" {
    const allocator = std.testing.allocator;

    // Initialize index manager
    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Create a spatial index
    try index_mgr.createSpatialIndex("location_idx", "Place", "coordinates");

    // Insert spatial data (bounding boxes)
    const mbr1 = geode.index.rtree.MBR{
        .min_x = 0.0,
        .min_y = 0.0,
        .max_x = 10.0,
        .max_y = 10.0,
    };

    const mbr2 = geode.index.rtree.MBR{
        .min_x = 5.0,
        .min_y = 5.0,
        .max_x = 15.0,
        .max_y = 15.0,
    };

    const mbr3 = geode.index.rtree.MBR{
        .min_x = 20.0,
        .min_y = 20.0,
        .max_x = 30.0,
        .max_y = 30.0,
    };

    try index_mgr.insertIntoSpatialIndex("location_idx", mbr1, 1);
    try index_mgr.insertIntoSpatialIndex("location_idx", mbr2, 2);
    try index_mgr.insertIntoSpatialIndex("location_idx", mbr3, 3);

    // Search for intersecting rectangles
    const query = geode.index.rtree.MBR{
        .min_x = 7.0,
        .min_y = 7.0,
        .max_x = 12.0,
        .max_y = 12.0,
    };

    const results = try index_mgr.searchSpatialIndex("location_idx", query);
    defer allocator.free(results);

    // Should find mbr1 and mbr2
    try testing.expect(results.len == 2);
}

test "spatial point queries" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    try index_mgr.createSpatialIndex("point_idx", "Location", "point");

    // Insert points (as zero-area bounding boxes)
    const points = [_]struct { x: f64, y: f64, id: u64 }{
        .{ .x = 40.7128, .y = -74.0060, .id = 1 }, // New York
        .{ .x = 37.7749, .y = -122.4194, .id = 2 }, // San Francisco
        .{ .x = 51.5074, .y = -0.1278, .id = 3 }, // London
        .{ .x = 35.6762, .y = 139.6503, .id = 4 }, // Tokyo
    };

    for (points) |p| {
        const mbr = geode.index.rtree.MBR{
            .min_x = p.x,
            .min_y = p.y,
            .max_x = p.x,
            .max_y = p.y,
        };
        try index_mgr.insertIntoSpatialIndex("point_idx", mbr, p.id);
    }

    // Search for points in a region (Western US)
    const west_us = geode.index.rtree.MBR{
        .min_x = 30.0,
        .min_y = -130.0,
        .max_x = 50.0,
        .max_y = -100.0,
    };

    const results = try index_mgr.searchSpatialIndex("point_idx", west_us);
    defer allocator.free(results);

    // Should find San Francisco
    try testing.expect(results.len == 1);
    try testing.expect(results[0] == 2);
}

test "spatial containment queries" {
    const allocator = std.testing.allocator;

    // Test R-tree directly
    var rtree = try geode.index.rtree.RTree.init(allocator, 4);
    defer rtree.deinit();

    // Insert nested rectangles
    const outer = geode.index.rtree.MBR{
        .min_x = 0.0,
        .min_y = 0.0,
        .max_x = 100.0,
        .max_y = 100.0,
    };

    const middle = geode.index.rtree.MBR{
        .min_x = 20.0,
        .min_y = 20.0,
        .max_x = 80.0,
        .max_y = 80.0,
    };

    const inner = geode.index.rtree.MBR{
        .min_x = 40.0,
        .min_y = 40.0,
        .max_x = 60.0,
        .max_y = 60.0,
    };

    try rtree.insert(outer, 1);
    try rtree.insert(middle, 2);
    try rtree.insert(inner, 3);

    // Test containment
    try testing.expect(outer.contains(middle));
    try testing.expect(middle.contains(inner));
    try testing.expect(outer.contains(inner));

    // Search for all rectangles containing a point
    const point_query = geode.index.rtree.MBR{
        .min_x = 50.0,
        .min_y = 50.0,
        .max_x = 50.0,
        .max_y = 50.0,
    };

    var results = std.ArrayList(u64).init(allocator);
    defer results.deinit();

    try rtree.search(point_query, allocator, &results);

    // All three rectangles contain the point
    try testing.expect(results.items.len == 3);
}

test "spatial index with large dataset" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    try index_mgr.createSpatialIndex("large_spatial_idx", "GeoData", "bounds");

    // Insert many random rectangles
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    const num_rectangles = 1000;
    var i: u64 = 0;
    while (i < num_rectangles) : (i += 1) {
        const x = random.float(f64) * 1000.0;
        const y = random.float(f64) * 1000.0;
        const w = random.float(f64) * 100.0;
        const h = random.float(f64) * 100.0;

        const mbr = geode.index.rtree.MBR{
            .min_x = x,
            .min_y = y,
            .max_x = x + w,
            .max_y = y + h,
        };

        try index_mgr.insertIntoSpatialIndex("large_spatial_idx", mbr, i);
    }

    // Search in a specific region
    const search_region = geode.index.rtree.MBR{
        .min_x = 400.0,
        .min_y = 400.0,
        .max_x = 600.0,
        .max_y = 600.0,
    };

    const results = try index_mgr.searchSpatialIndex("large_spatial_idx", search_region);
    defer allocator.free(results);

    // Should find some rectangles
    try testing.expect(results.len > 0);
    try testing.expect(results.len < num_rectangles);
}

test "spatial index MBR operations" {
    const MBR = geode.index.rtree.MBR;

    const mbr1 = MBR{
        .min_x = 0.0,
        .min_y = 0.0,
        .max_x = 10.0,
        .max_y = 10.0,
    };

    const mbr2 = MBR{
        .min_x = 5.0,
        .min_y = 5.0,
        .max_x = 15.0,
        .max_y = 15.0,
    };

    const mbr3 = MBR{
        .min_x = 20.0,
        .min_y = 20.0,
        .max_x = 30.0,
        .max_y = 30.0,
    };

    // Test intersection
    try testing.expect(mbr1.intersects(mbr2));
    try testing.expect(!mbr1.intersects(mbr3));

    // Test area calculation
    try testing.expectEqual(@as(f64, 100.0), mbr1.area());
    try testing.expectEqual(@as(f64, 100.0), mbr2.area());

    // Test union
    const union_mbr = mbr1.union_mbr(mbr2);
    try testing.expectEqual(@as(f64, 0.0), union_mbr.min_x);
    try testing.expectEqual(@as(f64, 0.0), union_mbr.min_y);
    try testing.expectEqual(@as(f64, 15.0), union_mbr.max_x);
    try testing.expectEqual(@as(f64, 15.0), union_mbr.max_y);

    // Test enlargement
    const enlargement = mbr1.enlargement(mbr2);
    try testing.expect(enlargement > 0);
}

test "CANARY: REQ=REQ-GQL-SPATIAL-INDEX" {
    // CANARY: REQ=REQ-GQL-SPATIAL-INDEX; FEATURE="SpatialIndex"; ASPECT=Core; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_SPATIAL_INDEX; OWNER=team; UPDATED=2026-11-14
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Test complete spatial index workflow
    try index_mgr.createSpatialIndex("canary_spatial_idx", "GeoEntity", "region");

    // Insert geographic regions
    const regions = [_]struct {
        mbr: geode.index.rtree.MBR,
        id: u64,
    }{
        .{
            .mbr = .{ .min_x = -74.0, .min_y = 40.0, .max_x = -73.0, .max_y = 41.0 }, // NYC area
            .id = 100,
        },
        .{
            .mbr = .{ .min_x = -122.5, .min_y = 37.0, .max_x = -121.5, .max_y = 38.0 }, // SF area
            .id = 200,
        },
        .{
            .mbr = .{ .min_x = -0.5, .min_y = 51.0, .max_x = 0.5, .max_y = 52.0 }, // London area
            .id = 300,
        },
    };

    for (regions) |r| {
        try index_mgr.insertIntoSpatialIndex("canary_spatial_idx", r.mbr, r.id);
    }

    // Search for European regions
    const europe_query = geode.index.rtree.MBR{
        .min_x = -10.0,
        .min_y = 45.0,
        .max_x = 10.0,
        .max_y = 60.0,
    };

    const results = try index_mgr.searchSpatialIndex("canary_spatial_idx", europe_query);
    defer allocator.free(results);

    try testing.expect(results.len == 1);
    try testing.expect(results[0] == 300); // London
}
