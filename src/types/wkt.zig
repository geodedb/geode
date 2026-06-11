//! WKT (Well-Known Text) -> WKB (Well-Known Binary) conversion.
//!
//! CANARY: REQ=REQ-GQL-SPATIAL-002; FEATURE="WktToWkb"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_gap0877_advanced_types.zig; OWNER=types; UPDATED=2026-06-11
//!
//! GAP-0877: extracted from eval_extended.zig so that BOTH geometry
//! constructor paths produce real WKB:
//!  - eval_extended.constructGeometryFromText (ExtValue path)
//!  - types/evaluator_functions.GeometryFromText (heap.Value path), which
//!    previously stored the raw WKT bytes in the `wkb` field, breaking every
//!    consumer that parses WKB (st_contains/st_intersects/st_aswkt, R-tree
//!    geometry indexing).
//!
//! Supported: POINT, LINESTRING, POLYGON (single exterior ring), MULTIPOINT,
//! MULTILINESTRING (first linestring), MULTIPOLYGON (first polygon).
//! Anything else returns error.UnsupportedGeometry (stable, never a silent
//! placeholder).

const std = @import("std");

pub fn parseWktToWkb(allocator: std.mem.Allocator, wkt: []const u8) ![]const u8 {
    // Simplified WKT parser for POINT
    if (std.mem.startsWith(u8, wkt, "POINT(") and std.mem.endsWith(u8, wkt, ")")) {
        const coords_str = wkt[6 .. wkt.len - 1];
        var parts = std.mem.tokenizeAny(u8, coords_str, " ");

        const x_str = parts.next() orelse return error.InvalidWkt;
        const y_str = parts.next() orelse return error.InvalidWkt;

        const x = try std.fmt.parseFloat(f64, x_str);
        const y = try std.fmt.parseFloat(f64, y_str);

        var wkb = try allocator.alloc(u8, 21);
        wkb[0] = 1; // Little endian
        std.mem.writeInt(u32, wkb[1..5][0..4], 1, .little); // Point type
        std.mem.writeInt(u64, wkb[5..13][0..8], @bitCast(x), .little);
        std.mem.writeInt(u64, wkb[13..21][0..8], @bitCast(y), .little);

        return wkb;
    }

    // POLYGON parser: POLYGON((x1 y1, x2 y2, ..., xn yn))
    if (std.mem.startsWith(u8, wkt, "POLYGON((") and std.mem.endsWith(u8, wkt, "))")) {
        const coords_str = wkt[9 .. wkt.len - 2]; // Extract coordinate string

        const Point = struct { x: f64, y: f64 };

        // Parse all coordinate pairs
        var points = std.ArrayList(Point).empty;
        defer points.deinit(allocator);

        var pairs = std.mem.tokenizeAny(u8, coords_str, ",");
        while (pairs.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t\n\r");
            var coords = std.mem.tokenizeAny(u8, trimmed, " ");

            const x_str = coords.next() orelse return error.InvalidWkt;
            const y_str = coords.next() orelse return error.InvalidWkt;

            const x = try std.fmt.parseFloat(f64, x_str);
            const y = try std.fmt.parseFloat(f64, y_str);

            try points.append(allocator, .{ .x = x, .y = y });
        }

        if (points.items.len < 4) return error.InvalidWkt; // Need at least 4 points (triangle + closing point)

        // Calculate WKB size: 1 (endian) + 4 (type) + 4 (num_rings) + 4 (num_points) + (num_points * 16)
        const num_points: u32 = @intCast(points.items.len);
        const wkb_size: usize = 1 + 4 + 4 + 4 + (@as(usize, num_points) * 16);
        var wkb = try allocator.alloc(u8, wkb_size);

        var offset: usize = 0;

        // Byte order (little endian)
        wkb[offset] = 1;
        offset += 1;

        // Geometry type (3 = Polygon)
        std.mem.writeInt(u32, wkb[offset..][0..4], 3, .little);
        offset += 4;

        // Number of rings (1 for simple polygon)
        std.mem.writeInt(u32, wkb[offset..][0..4], 1, .little);
        offset += 4;

        // Number of points in ring
        std.mem.writeInt(u32, wkb[offset..][0..4], num_points, .little);
        offset += 4;

        // Write all coordinates
        for (points.items) |point| {
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.x), .little);
            offset += 8;
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.y), .little);
            offset += 8;
        }

        return wkb;
    }

    // LINESTRING parser: LINESTRING(x1 y1, x2 y2, ..., xn yn)
    if (std.mem.startsWith(u8, wkt, "LINESTRING(") and std.mem.endsWith(u8, wkt, ")")) {
        const coords_str = wkt[11 .. wkt.len - 1]; // Extract coordinate string

        const Point = struct { x: f64, y: f64 };

        // Parse all coordinate pairs
        var points = std.ArrayList(Point).empty;
        defer points.deinit(allocator);

        var pairs = std.mem.tokenizeAny(u8, coords_str, ",");
        while (pairs.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t\n\r");
            var coords = std.mem.tokenizeAny(u8, trimmed, " ");

            const x_str = coords.next() orelse return error.InvalidWkt;
            const y_str = coords.next() orelse return error.InvalidWkt;

            const x = try std.fmt.parseFloat(f64, x_str);
            const y = try std.fmt.parseFloat(f64, y_str);

            try points.append(allocator, .{ .x = x, .y = y });
        }

        if (points.items.len < 2) return error.InvalidWkt; // Need at least 2 points

        // Calculate WKB size: 1 (endian) + 4 (type) + 4 (num_points) + (num_points * 16)
        const num_points: u32 = @intCast(points.items.len);
        const wkb_size: usize = 1 + 4 + 4 + (@as(usize, num_points) * 16);
        var wkb = try allocator.alloc(u8, wkb_size);

        var offset: usize = 0;

        // Byte order (little endian)
        wkb[offset] = 1;
        offset += 1;

        // Geometry type (2 = LineString)
        std.mem.writeInt(u32, wkb[offset..][0..4], 2, .little);
        offset += 4;

        // Number of points
        std.mem.writeInt(u32, wkb[offset..][0..4], num_points, .little);
        offset += 4;

        // Write all coordinates
        for (points.items) |point| {
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.x), .little);
            offset += 8;
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.y), .little);
            offset += 8;
        }

        return wkb;
    }

    // GAP-0076: MULTIPOINT parser: MULTIPOINT((x1 y1), (x2 y2), ...) or MULTIPOINT(x1 y1, x2 y2, ...)
    // CANARY: REQ=REQ-GEO-MULTI-001; FEATURE="MultiGeometry"; ASPECT=SpatialTypes; STATUS=TESTED; TEST=geodetestlab/specs/spatial_wkb_functions.yml; OWNER=types; UPDATED=2026-01-10
    if (std.mem.startsWith(u8, wkt, "MULTIPOINT")) {
        const Point = struct { x: f64, y: f64 };
        var points = std.ArrayList(Point).empty;
        defer points.deinit(allocator);

        // Find the opening paren
        const start_idx = std.mem.indexOf(u8, wkt, "(") orelse return error.InvalidWkt;
        const coords_str = wkt[start_idx + 1 .. wkt.len - 1];

        // Handle both formats: ((x y), (x y)) and (x y, x y)
        if (std.mem.startsWith(u8, coords_str, "(")) {
            // Format: ((x y), (x y), ...)
            var point_strs = std.mem.tokenizeSequence(u8, coords_str, "), ");
            while (point_strs.next()) |pt_str| {
                const clean = std.mem.trim(u8, pt_str, "() ");
                var coords = std.mem.tokenizeAny(u8, clean, " ");
                const x_str = coords.next() orelse continue;
                const y_str = coords.next() orelse continue;
                const x = std.fmt.parseFloat(f64, x_str) catch continue;
                const y = std.fmt.parseFloat(f64, y_str) catch continue;
                try points.append(allocator, .{ .x = x, .y = y });
            }
        } else {
            // Format: (x y, x y, ...)
            var pairs = std.mem.tokenizeAny(u8, coords_str, ",");
            while (pairs.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " \t\n\r");
                var coords = std.mem.tokenizeAny(u8, trimmed, " ");
                const x_str = coords.next() orelse continue;
                const y_str = coords.next() orelse continue;
                const x = std.fmt.parseFloat(f64, x_str) catch continue;
                const y = std.fmt.parseFloat(f64, y_str) catch continue;
                try points.append(allocator, .{ .x = x, .y = y });
            }
        }

        if (points.items.len == 0) return error.InvalidWkt;

        // WKB MultiPoint: 1(endian) + 4(type=4) + 4(num_geometries) + n * (1 + 4 + 16)
        const num_points: u32 = @intCast(points.items.len);
        const wkb_size: usize = 1 + 4 + 4 + (@as(usize, num_points) * 21);
        var wkb = try allocator.alloc(u8, wkb_size);

        var offset: usize = 0;
        wkb[offset] = 1;
        offset += 1;
        std.mem.writeInt(u32, wkb[offset..][0..4], 4, .little); // MultiPoint type
        offset += 4;
        std.mem.writeInt(u32, wkb[offset..][0..4], num_points, .little);
        offset += 4;

        for (points.items) |point| {
            wkb[offset] = 1;
            offset += 1;
            std.mem.writeInt(u32, wkb[offset..][0..4], 1, .little); // Point type
            offset += 4;
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.x), .little);
            offset += 8;
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.y), .little);
            offset += 8;
        }

        return wkb;
    }

    // GAP-0076: MULTILINESTRING parser: MULTILINESTRING((x1 y1, x2 y2), (x3 y3, x4 y4))
    // CANARY: REQ=REQ-GEO-MULTI-002; FEATURE="MultiGeometry"; ASPECT=SpatialTypes; STATUS=TESTED; TEST=geodetestlab/specs/spatial_wkb_functions.yml; OWNER=types; UPDATED=2026-01-10
    if (std.mem.startsWith(u8, wkt, "MULTILINESTRING")) {
        const Point = struct { x: f64, y: f64 };
        // Parse as single linestring for simplicity - handle first linestring in multi
        const start_idx = std.mem.indexOf(u8, wkt, "((") orelse return error.InvalidWkt;
        const end_idx = std.mem.lastIndexOf(u8, wkt, "))") orelse return error.InvalidWkt;
        const lines_str = wkt[start_idx + 2 .. end_idx];

        // Parse first linestring (simplified - full implementation would parse all)
        var points = std.ArrayList(Point).empty;
        defer points.deinit(allocator);

        var pairs = std.mem.tokenizeAny(u8, lines_str, ",");
        while (pairs.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t\n\r()");
            if (std.mem.indexOf(u8, trimmed, ")") != null) break; // End of first linestring
            var coords = std.mem.tokenizeAny(u8, trimmed, " ");
            const x_str = coords.next() orelse continue;
            const y_str = coords.next() orelse continue;
            const x = std.fmt.parseFloat(f64, x_str) catch continue;
            const y = std.fmt.parseFloat(f64, y_str) catch continue;
            try points.append(allocator, .{ .x = x, .y = y });
        }

        if (points.items.len < 2) return error.InvalidWkt;

        // WKB: 1 + 4 + 4 + 1 * (1 + 4 + 4 + points * 16)
        const num_points: u32 = @intCast(points.items.len);
        const wkb_size: usize = 1 + 4 + 4 + 1 + 4 + 4 + (@as(usize, num_points) * 16);
        var wkb = try allocator.alloc(u8, wkb_size);

        var offset: usize = 0;
        wkb[offset] = 1;
        offset += 1;
        std.mem.writeInt(u32, wkb[offset..][0..4], 5, .little); // MultiLineString type
        offset += 4;
        std.mem.writeInt(u32, wkb[offset..][0..4], 1, .little); // 1 linestring
        offset += 4;
        wkb[offset] = 1;
        offset += 1;
        std.mem.writeInt(u32, wkb[offset..][0..4], 2, .little); // LineString type
        offset += 4;
        std.mem.writeInt(u32, wkb[offset..][0..4], num_points, .little);
        offset += 4;
        for (points.items) |point| {
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.x), .little);
            offset += 8;
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.y), .little);
            offset += 8;
        }

        return wkb;
    }

    // GAP-0076: MULTIPOLYGON parser: MULTIPOLYGON(((x1 y1, ...)), ((x2 y2, ...)))
    // CANARY: REQ=REQ-GEO-MULTI-003; FEATURE="MultiGeometry"; ASPECT=SpatialTypes; STATUS=TESTED; TEST=geodetestlab/specs/spatial_wkb_functions.yml; OWNER=types; UPDATED=2026-01-10
    if (std.mem.startsWith(u8, wkt, "MULTIPOLYGON")) {
        const Point = struct { x: f64, y: f64 };
        // Parse first polygon for simplicity
        const start_idx = std.mem.indexOf(u8, wkt, "(((") orelse return error.InvalidWkt;
        const end_idx = std.mem.indexOf(u8, wkt, ")))") orelse return error.InvalidWkt;
        const poly_str = wkt[start_idx + 3 .. end_idx];

        var points = std.ArrayList(Point).empty;
        defer points.deinit(allocator);

        var pairs = std.mem.tokenizeAny(u8, poly_str, ",");
        while (pairs.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t\n\r()");
            if (std.mem.indexOf(u8, trimmed, ")") != null) break;
            var coords = std.mem.tokenizeAny(u8, trimmed, " ");
            const x_str = coords.next() orelse continue;
            const y_str = coords.next() orelse continue;
            const x = std.fmt.parseFloat(f64, x_str) catch continue;
            const y = std.fmt.parseFloat(f64, y_str) catch continue;
            try points.append(allocator, .{ .x = x, .y = y });
        }

        if (points.items.len < 4) return error.InvalidWkt;

        // WKB: 1 + 4 + 4 + 1 * (1 + 4 + 4 + 4 + points * 16)
        const num_points: u32 = @intCast(points.items.len);
        const wkb_size: usize = 1 + 4 + 4 + 1 + 4 + 4 + 4 + (@as(usize, num_points) * 16);
        var wkb = try allocator.alloc(u8, wkb_size);

        var offset: usize = 0;
        wkb[offset] = 1;
        offset += 1;
        std.mem.writeInt(u32, wkb[offset..][0..4], 6, .little); // MultiPolygon type
        offset += 4;
        std.mem.writeInt(u32, wkb[offset..][0..4], 1, .little); // 1 polygon
        offset += 4;
        wkb[offset] = 1;
        offset += 1;
        std.mem.writeInt(u32, wkb[offset..][0..4], 3, .little); // Polygon type
        offset += 4;
        std.mem.writeInt(u32, wkb[offset..][0..4], 1, .little); // 1 ring
        offset += 4;
        std.mem.writeInt(u32, wkb[offset..][0..4], num_points, .little);
        offset += 4;
        for (points.items) |point| {
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.x), .little);
            offset += 8;
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(point.y), .little);
            offset += 8;
        }

        return wkb;
    }

    return error.UnsupportedGeometry;
}
