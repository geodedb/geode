const std = @import("std");

// CANARY: REQ=REQ-GQL-GEO-TYPES-001; FEATURE="Geographic Types Implementation"; ASPECT=Types; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_GEO_TYPES_001_All; OWNER=types; UPDATED=2025-01-03

// =============================================================================
// Re-export core geographic types from the external advanced_types library.
// The external library provides LatLon, LatLonAlt, and GeoPoint with
// validation, haversine distance, formatting, and parsing.
//
// Geode extends these with:
//   - GQL-style geographic functions (distance_haversine, geo_bearing, etc.)
//   - PostGIS-style spatial functions (st_distance, st_area, st_within, etc.)
//   - Polygon and LineString types for spatial queries
//   - Binary encoding/decoding for storage
//   - Legacy compatibility methods (fromCoords, fromString, distanceKm, etc.)
// =============================================================================
const advanced_types = @import("advanced_types_lib");

/// External library geographic error type
pub const GeoError = advanced_types.geographic.GeoError;

/// Latitude/Longitude coordinate pair.
/// Fields: .lat (f64, -90..90), .lon (f64, -180..180)
///
/// External library methods available:
///   - init(lat, lon) -> GeoError!LatLon
///   - initUnchecked(lat, lon) -> LatLon
///   - eql(other) -> bool
///   - haversineDistance(other) -> f64 (meters)
///   - format(writer) -> !void
///   - parse(input) -> GeoError!LatLon
///
/// Geode adds compatibility and convenience functions below.
pub const LatLon = advanced_types.LatLon;

/// Latitude/Longitude with altitude.
/// Fields: .lat (f64), .lon (f64), .alt (f64, meters)
pub const LatLonAlt = advanced_types.LatLonAlt;

/// Tagged union for 2D or 3D geographic coordinates.
/// Variants: .point_2d (LatLon), .point_3d (LatLonAlt)
pub const GeoPoint = advanced_types.GeoPoint;

// =============================================================================
// Compatibility helpers — bridge old Geode API to external library
// =============================================================================

/// Create a LatLon from coordinates (legacy API — delegates to LatLon.init).
/// Maps error.LatitudeOutOfRange -> error.InvalidLatitude, etc.
pub fn latLonFromCoords(lat: f64, lon: f64) !LatLon {
    return LatLon.init(lat, lon) catch |err| switch (err) {
        GeoError.LatitudeOutOfRange => return error.InvalidLatitude,
        GeoError.LongitudeOutOfRange => return error.InvalidLongitude,
        else => return error.InvalidCoordinateFormat,
    };
}

/// Parse a LatLon from string (legacy API — accepts "lat,lon" and "(lat,lon)" formats).
/// The external library only accepts "(lat, lon)" with parens, so we handle the
/// bare "lat,lon" format here for backward compatibility.
pub fn latLonFromString(coord_str: []const u8) !LatLon {
    // First try the external library's parser (handles "(lat, lon)")
    if (LatLon.parse(coord_str)) |result| {
        return result;
    } else |_| {}

    // Fall back to legacy format: "lat,lon" or "lat lon"
    var cleaned_str = coord_str;

    // Remove parentheses if present
    if (std.mem.startsWith(u8, cleaned_str, "(") and std.mem.endsWith(u8, cleaned_str, ")")) {
        cleaned_str = cleaned_str[1 .. cleaned_str.len - 1];
    }

    // Split by comma
    var parts_comma = std.mem.splitSequence(u8, cleaned_str, ",");
    var parts: [2][]const u8 = undefined;
    var part_count: usize = 0;

    while (parts_comma.next()) |part| {
        if (part_count >= 2) return error.InvalidCoordinateFormat;
        parts[part_count] = std.mem.trim(u8, part, " \t\n\r");
        part_count += 1;
    }

    // If only one part, try space separation
    if (part_count == 1) {
        var parts_space = std.mem.splitSequence(u8, cleaned_str, " ");
        part_count = 0;
        while (parts_space.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\n\r");
            if (trimmed.len == 0) continue;
            if (part_count >= 2) return error.InvalidCoordinateFormat;
            parts[part_count] = trimmed;
            part_count += 1;
        }
    }

    if (part_count != 2) return error.InvalidCoordinateFormat;

    const lat = std.fmt.parseFloat(f64, parts[0]) catch return error.InvalidLatitude;
    const lon = std.fmt.parseFloat(f64, parts[1]) catch return error.InvalidLongitude;

    return latLonFromCoords(lat, lon);
}

/// Format a LatLon as "lat,lon" (legacy format, allocating)
pub fn latLonToString(coord: LatLon, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d},{d}", .{ coord.lat, coord.lon });
}

/// Haversine distance in kilometers (legacy API — external lib returns meters)
pub fn latLonDistanceKm(a: LatLon, b: LatLon) f64 {
    return a.haversineDistance(b) / 1000.0;
}

/// Calculate bearing from one point to another (in degrees, 0-360)
pub fn latLonBearingTo(from: LatLon, to: LatLon) f64 {
    const lat1_rad = std.math.degreesToRadians(from.lat);
    const lat2_rad = std.math.degreesToRadians(to.lat);
    const delta_lon = std.math.degreesToRadians(to.lon - from.lon);

    const y = @sin(delta_lon) * @cos(lat2_rad);
    const x = @cos(lat1_rad) * @sin(lat2_rad) -
        @sin(lat1_rad) * @cos(lat2_rad) * @cos(delta_lon);

    var bearing = std.math.radiansToDegrees(std.math.atan2(y, x));
    if (bearing < 0) {
        bearing += 360.0;
    }
    return bearing;
}

/// Check if point is within a bounding box
pub fn latLonIsWithinBounds(point: LatLon, sw: LatLon, ne: LatLon) bool {
    return point.lat >= sw.lat and point.lat <= ne.lat and
        point.lon >= sw.lon and point.lon <= ne.lon;
}

/// Move point by distance and bearing
pub fn latLonMoveByBearing(start: LatLon, distance_km: f64, bearing_degrees: f64) LatLon {
    const earth_radius_km = 6371.0;
    const angular_distance = distance_km / earth_radius_km;

    const lat1_rad = std.math.degreesToRadians(start.lat);
    const bearing_rad = std.math.degreesToRadians(bearing_degrees);

    const lat2_rad = std.math.asin(@sin(lat1_rad) * @cos(angular_distance) +
        @cos(lat1_rad) * @sin(angular_distance) * @cos(bearing_rad));

    const lon2_rad = std.math.degreesToRadians(start.lon) +
        std.math.atan2(@sin(bearing_rad) * @sin(angular_distance) * @cos(lat1_rad), @cos(angular_distance) - @sin(lat1_rad) * @sin(lat2_rad));

    const lat2 = std.math.radiansToDegrees(lat2_rad);
    var lon2 = std.math.radiansToDegrees(lon2_rad);

    while (lon2 > 180.0) lon2 -= 360.0;
    while (lon2 < -180.0) lon2 += 360.0;

    return LatLon.initUnchecked(lat2, lon2);
}

/// Binary encoding for LatLon storage
pub fn latLonEncode(coord: LatLon, writer: anytype) !void {
    try writer.writeByte(0x12); // LatLon tag
    try writer.writeAll(std.mem.asBytes(&coord.lat));
    try writer.writeAll(std.mem.asBytes(&coord.lon));
}

pub fn latLonDecode(reader: anytype) !LatLon {
    const tag = try reader.takeByte();
    if (tag != 0x12) return error.InvalidLatLonTag;

    const lat = @as(f64, @bitCast(try reader.takeInt(u64, .little)));
    const lon = @as(f64, @bitCast(try reader.takeInt(u64, .little)));

    return LatLon.initUnchecked(lat, lon);
}

/// Check if LatLon coordinates are valid
pub fn latLonIsValid(coord: LatLon) bool {
    return coord.lat >= -90.0 and coord.lat <= 90.0 and
        coord.lon >= -180.0 and coord.lon <= 180.0;
}

// =============================================================================
// LatLonAlt compatibility helpers
// =============================================================================

/// Create a LatLonAlt from coordinates (legacy API)
pub fn latLonAltFromCoords(lat: f64, lon: f64, alt: f64) !LatLonAlt {
    return LatLonAlt.init(lat, lon, alt) catch |err| switch (err) {
        GeoError.LatitudeOutOfRange => return error.InvalidLatitude,
        GeoError.LongitudeOutOfRange => return error.InvalidLongitude,
        else => return error.InvalidCoordinateFormat,
    };
}

/// Parse a LatLonAlt from string (legacy API — accepts "lat,lon,alt" format)
pub fn latLonAltFromString(coord_str: []const u8) !LatLonAlt {
    // First try the external library's parser
    if (LatLonAlt.parse(coord_str)) |result| {
        return result;
    } else |_| {}

    // Fall back to legacy format: "lat,lon,alt" or "lat lon alt"
    var cleaned_str = coord_str;

    if (std.mem.startsWith(u8, cleaned_str, "(") and std.mem.endsWith(u8, cleaned_str, ")")) {
        cleaned_str = cleaned_str[1 .. cleaned_str.len - 1];
    }

    var parts_comma = std.mem.splitSequence(u8, cleaned_str, ",");
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;

    while (parts_comma.next()) |part| {
        if (part_count >= 3) return error.InvalidCoordinateFormat;
        parts[part_count] = std.mem.trim(u8, part, " \t\n\r");
        part_count += 1;
    }

    if (part_count < 3) {
        var parts_space = std.mem.splitSequence(u8, cleaned_str, " ");
        part_count = 0;
        while (parts_space.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\n\r");
            if (trimmed.len == 0) continue;
            if (part_count >= 3) return error.InvalidCoordinateFormat;
            parts[part_count] = trimmed;
            part_count += 1;
        }
    }

    if (part_count != 3) return error.InvalidCoordinateFormat;

    const lat = std.fmt.parseFloat(f64, parts[0]) catch return error.InvalidLatitude;
    const lon = std.fmt.parseFloat(f64, parts[1]) catch return error.InvalidLongitude;
    const alt = std.fmt.parseFloat(f64, parts[2]) catch return error.InvalidAltitude;

    return latLonAltFromCoords(lat, lon, alt);
}

/// Format a LatLonAlt as "lat,lon,alt" (legacy format, allocating)
pub fn latLonAltToString(coord: LatLonAlt, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d},{d},{d}", .{ coord.lat, coord.lon, coord.alt });
}

/// Calculate 3D distance including altitude difference (in kilometers)
pub fn latLonAltDistance3D(a: LatLonAlt, b: LatLonAlt) f64 {
    const horizontal_dist = latLonDistanceKm(a.toLatLon(), b.toLatLon());
    const vertical_dist_km = (a.alt - b.alt) / 1000.0;
    return @sqrt(horizontal_dist * horizontal_dist + vertical_dist_km * vertical_dist_km);
}

/// Binary encoding for LatLonAlt storage
pub fn latLonAltEncode(coord: LatLonAlt, writer: anytype) !void {
    try writer.writeByte(0x13); // LatLonAlt tag
    try writer.writeAll(std.mem.asBytes(&coord.lat));
    try writer.writeAll(std.mem.asBytes(&coord.lon));
    try writer.writeAll(std.mem.asBytes(&coord.alt));
}

pub fn latLonAltDecode(reader: anytype) !LatLonAlt {
    const tag = try reader.takeByte();
    if (tag != 0x13) return error.InvalidLatLonAltTag;

    const lat = @as(f64, @bitCast(try reader.takeInt(u64, .little)));
    const lon = @as(f64, @bitCast(try reader.takeInt(u64, .little)));
    const alt = @as(f64, @bitCast(try reader.takeInt(u64, .little)));

    return LatLonAlt.initUnchecked(lat, lon, alt);
}

/// Check if LatLonAlt coordinates are valid
pub fn latLonAltIsValid(coord: LatLonAlt) bool {
    return coord.lat >= -90.0 and coord.lat <= 90.0 and
        coord.lon >= -180.0 and coord.lon <= 180.0;
}

// =============================================================================
// Utility functions for geographic operations (preserve existing API)
// =============================================================================

pub fn latLonDistance(a: LatLon, b: LatLon) f64 {
    return latLonDistanceKm(a, b);
}

pub fn latLonBearing(from: LatLon, to: LatLon) f64 {
    return latLonBearingTo(from, to);
}

pub fn isValidLatitude(lat: f64) bool {
    return lat >= -90.0 and lat <= 90.0;
}

pub fn isValidLongitude(lon: f64) bool {
    return lon >= -180.0 and lon <= 180.0;
}

// CANARY: REQ=REQ-GQL-GEO-FUNC-001; FEATURE="GeographicFunctions"; ASPECT=BuiltinFunctions; STATUS=TESTED; TEST=geodetestlab/specs/spatial_wkb_functions.yml; OWNER=types; UPDATED=2025-10-19
// GQL-style geographic functions for query integration

/// Calculate distance between two LatLon points using Haversine formula (returns meters)
pub fn distance_haversine(a: LatLon, b: LatLon) f64 {
    return a.haversineDistance(b);
}

/// Calculate bearing from one point to another (0-360 degrees)
pub fn geo_bearing(from: LatLon, to: LatLon) f64 {
    return latLonBearingTo(from, to);
}

/// Extract latitude from a LatLon coordinate
pub fn geo_lat(coord: LatLon) f64 {
    return coord.lat;
}

/// Extract longitude from a LatLon coordinate
pub fn geo_lon(coord: LatLon) f64 {
    return coord.lon;
}

/// Calculate the midpoint between two LatLon coordinates
pub fn geo_midpoint(a: LatLon, b: LatLon) LatLon {
    return LatLon.initUnchecked(
        (a.lat + b.lat) / 2.0,
        (a.lon + b.lon) / 2.0,
    );
}

/// Check if a point is within a circular radius (in meters) from a center point
pub fn geo_within_radius(point: LatLon, center: LatLon, radius_meters: f64) bool {
    const dist = distance_haversine(point, center);
    return dist <= radius_meters;
}

/// Check if a point is within a bounding box defined by southwest and northeast corners
pub fn geo_within_box(point: LatLon, southwest: LatLon, northeast: LatLon) bool {
    return latLonIsWithinBounds(point, southwest, northeast);
}

/// Calculate the destination point given a starting point, bearing, and distance
pub fn geo_destination(start: LatLon, bearing_degrees: f64, distance_meters: f64) LatLon {
    return latLonMoveByBearing(start, distance_meters / 1000.0, bearing_degrees);
}

/// Calculate approximate area of a triangle formed by three points (in square meters)
pub fn geo_triangle_area(a: LatLon, b: LatLon, c: LatLon) f64 {
    const side_a = distance_haversine(b, c);
    const side_b = distance_haversine(a, c);
    const side_c = distance_haversine(a, b);

    const s = (side_a + side_b + side_c) / 2.0;
    const area_squared = s * (s - side_a) * (s - side_b) * (s - side_c);
    if (area_squared <= 0.0) return 0.0;
    return @sqrt(area_squared);
}

/// Calculate the initial and final bearings (forward and reverse azimuths)
pub fn geo_azimuth(from: LatLon, to: LatLon) struct { forward: f64, reverse: f64 } {
    const forward = latLonBearingTo(from, to);
    const reverse = latLonBearingTo(to, from);
    return .{ .forward = forward, .reverse = reverse };
}

/// Normalize a bearing to 0-360 degrees
pub fn normalize_bearing(bearing: f64) f64 {
    var result = @mod(bearing, 360.0);
    if (result < 0.0) {
        result += 360.0;
    }
    return result;
}

/// Calculate compass direction from bearing (N, NE, E, SE, S, SW, W, NW)
pub fn bearing_to_compass(bearing: f64) []const u8 {
    const normalized = normalize_bearing(bearing);

    if (normalized < 22.5 or normalized >= 337.5) return "N";
    if (normalized < 67.5) return "NE";
    if (normalized < 112.5) return "E";
    if (normalized < 157.5) return "SE";
    if (normalized < 202.5) return "S";
    if (normalized < 247.5) return "SW";
    if (normalized < 292.5) return "W";
    return "NW";
}

/// Calculate the cross-track distance (perpendicular distance) from a point to a great circle path
pub fn geo_cross_track_distance(point: LatLon, path_start: LatLon, path_end: LatLon) f64 {
    const earth_radius_m = 6371000.0;

    const d13_rad = distance_haversine(path_start, point) / earth_radius_m;
    const bearing_13_rad = std.math.degreesToRadians(latLonBearingTo(path_start, point));
    const bearing_12_rad = std.math.degreesToRadians(latLonBearingTo(path_start, path_end));

    const dxt = std.math.asin(@sin(d13_rad) * @sin(bearing_13_rad - bearing_12_rad));
    return dxt * earth_radius_m;
}

/// Calculate along-track distance from start of path to closest point to given point
pub fn geo_along_track_distance(point: LatLon, path_start: LatLon, path_end: LatLon) f64 {
    const earth_radius_m = 6371000.0;

    const d13_rad = distance_haversine(path_start, point) / earth_radius_m;
    const dxt_rad = geo_cross_track_distance(point, path_start, path_end) / earth_radius_m;

    const dat = std.math.acos(@cos(d13_rad) / @cos(dxt_rad));
    return dat * earth_radius_m;
}

// CANARY: REQ=REQ-GQL-SPATIAL-FUNC-001; FEATURE="SpatialFunctions"; ASPECT=PostGISStyle; STATUS=TESTED; TEST=geodetestlab/specs/spatial_wkb_functions.yml; OWNER=types; UPDATED=2025-10-19
// PostGIS-style spatial functions (st_* prefix) for GQL compatibility

/// Polygon type for area calculations
pub const Polygon = struct {
    points: []LatLon,
};

/// LineString type for distance calculations
pub const LineString = struct {
    points: []LatLon,
};

/// Calculate distance between two points (alias for distance_haversine)
pub fn st_distance(a: LatLon, b: LatLon) f64 {
    return distance_haversine(a, b);
}

/// Calculate area of a polygon in square meters
pub fn st_area(polygon: Polygon) f64 {
    if (polygon.points.len < 3) return 0.0;

    const centroid = calculate_centroid(polygon.points);

    var area: f64 = 0.0;
    const n = polygon.points.len;

    for (0..polygon.points.len) |i| {
        const curr = polygon.points[i];
        const next = polygon.points[(i + 1) % n];

        const curr_x = distance_haversine(centroid, LatLon.initUnchecked(centroid.lat, curr.lon));
        const curr_y = distance_haversine(centroid, LatLon.initUnchecked(curr.lat, centroid.lon));
        const next_x = distance_haversine(centroid, LatLon.initUnchecked(centroid.lat, next.lon));
        const next_y = distance_haversine(centroid, LatLon.initUnchecked(next.lat, centroid.lon));

        const curr_x_signed = if (curr.lon < centroid.lon) -curr_x else curr_x;
        const next_x_signed = if (next.lon < centroid.lon) -next_x else next_x;
        const curr_y_signed = if (curr.lat < centroid.lat) -curr_y else curr_y;
        const next_y_signed = if (next.lat < centroid.lat) -next_y else next_y;

        area += curr_x_signed * next_y_signed - next_x_signed * curr_y_signed;
    }

    return @abs(area / 2.0);
}

/// Check if two points are within a specified distance
pub fn st_dwithin(a: LatLon, b: LatLon, distance_meters: f64) bool {
    return distance_haversine(a, b) <= distance_meters;
}

/// Check if a point is within a polygon (2D point-in-polygon test)
pub fn st_within(point: LatLon, polygon: Polygon) bool {
    if (polygon.points.len < 3) return false;

    var inside = false;
    const n = polygon.points.len;

    var j: usize = n - 1;
    for (0..polygon.points.len) |i| {
        const pi = polygon.points[i];
        const pj = polygon.points[j];

        if ((pi.lat > point.lat) != (pj.lat > point.lat) and
            point.lon < (pj.lon - pi.lon) * (point.lat - pi.lat) / (pj.lat - pi.lat) + pi.lon)
        {
            inside = !inside;
        }
        j = i;
    }

    return inside;
}

/// Check if a point contains another (always false for points, true if same)
pub fn st_contains(container: LatLon, contained: LatLon) bool {
    return container.lat == contained.lat and container.lon == contained.lon;
}

/// Check if two geometries intersect (for points, this means they're approximately the same)
pub fn st_intersects(a: LatLon, b: LatLon) bool {
    const threshold = 0.000001;
    return @abs(a.lat - b.lat) < threshold and @abs(a.lon - b.lon) < threshold;
}

/// Check if two polygons intersect
pub fn st_intersects_polygon(a: Polygon, b: Polygon) bool {
    for (a.points) |point| {
        if (st_within(point, b)) return true;
    }
    for (b.points) |point| {
        if (st_within(point, a)) return true;
    }
    return false;
}

/// Create a buffer (circle) around a point with specified radius in meters
pub fn st_buffer(allocator: std.mem.Allocator, center: LatLon, radius_meters: f64, num_points: usize) !Polygon {
    const points = try allocator.alloc(LatLon, num_points);
    errdefer allocator.free(points);

    const angle_step = 360.0 / @as(f64, @floatFromInt(num_points));

    for (0..num_points) |i| {
        const angle = @as(f64, @floatFromInt(i)) * angle_step;
        points[i] = geo_destination(center, angle, radius_meters);
    }

    return Polygon{ .points = points };
}

/// Calculate the union of two polygons (simplified: merge all points)
pub fn st_union(allocator: std.mem.Allocator, a: Polygon, b: Polygon) !Polygon {
    const total_points = a.points.len + b.points.len;
    const merged = try allocator.alloc(LatLon, total_points);
    errdefer allocator.free(merged);

    @memcpy(merged[0..a.points.len], a.points);
    @memcpy(merged[a.points.len..], b.points);

    return Polygon{ .points = merged };
}

/// Calculate the centroid of a polygon or set of points
pub fn st_centroid(points: []LatLon) LatLon {
    return calculate_centroid(points);
}

/// Calculate length of a line string in meters
pub fn st_length(line: LineString) f64 {
    if (line.points.len < 2) return 0.0;

    var total_length: f64 = 0.0;
    for (1..line.points.len) |i| {
        total_length += distance_haversine(line.points[i - 1], line.points[i]);
    }
    return total_length;
}

/// Calculate perimeter of a polygon in meters
pub fn st_perimeter(polygon: Polygon) f64 {
    if (polygon.points.len < 2) return 0.0;

    var total: f64 = 0.0;
    for (1..polygon.points.len) |i| {
        total += distance_haversine(polygon.points[i - 1], polygon.points[i]);
    }
    if (polygon.points.len > 0) {
        total += distance_haversine(polygon.points[polygon.points.len - 1], polygon.points[0]);
    }
    return total;
}

/// Check if a polygon is simple (no self-intersections)
pub fn st_issimple(polygon: Polygon) bool {
    return polygon.points.len >= 3;
}

/// Check if a polygon is valid (closed, simple, non-self-intersecting)
pub fn st_isvalid(polygon: Polygon) bool {
    if (polygon.points.len < 3) return false;

    const first = polygon.points[0];
    const last = polygon.points[polygon.points.len - 1];
    const threshold = 0.000001;

    const is_closed = @abs(first.lat - last.lat) < threshold and
        @abs(first.lon - last.lon) < threshold;

    return is_closed and st_issimple(polygon);
}

/// Calculate the envelope (bounding box) of a set of points
pub fn st_envelope(points: []LatLon) struct { southwest: LatLon, northeast: LatLon } {
    if (points.len == 0) {
        return .{
            .southwest = LatLon.initUnchecked(0, 0),
            .northeast = LatLon.initUnchecked(0, 0),
        };
    }

    var min_lat = points[0].lat;
    var max_lat = points[0].lat;
    var min_lon = points[0].lon;
    var max_lon = points[0].lon;

    for (points[1..]) |point| {
        if (point.lat < min_lat) min_lat = point.lat;
        if (point.lat > max_lat) max_lat = point.lat;
        if (point.lon < min_lon) min_lon = point.lon;
        if (point.lon > max_lon) max_lon = point.lon;
    }

    return .{
        .southwest = LatLon.initUnchecked(min_lat, min_lon),
        .northeast = LatLon.initUnchecked(max_lat, max_lon),
    };
}

/// Helper: Calculate centroid of points
fn calculate_centroid(points: []LatLon) LatLon {
    if (points.len == 0) return LatLon.initUnchecked(0, 0);

    var sum_lat: f64 = 0;
    var sum_lon: f64 = 0;

    for (points) |point| {
        sum_lat += point.lat;
        sum_lon += point.lon;
    }

    return LatLon.initUnchecked(
        sum_lat / @as(f64, @floatFromInt(points.len)),
        sum_lon / @as(f64, @floatFromInt(points.len)),
    );
}

// =============================================================================
// Test suite
// =============================================================================

test "LatLon operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test coordinate creation and validation
    const coord1 = try latLonFromCoords(40.7128, -74.0060); // New York
    const coord2 = try latLonFromCoords(34.0522, -118.2437); // Los Angeles

    try testing.expect(latLonIsValid(coord1));
    try testing.expect(latLonIsValid(coord2));

    // Test string parsing
    const coord3 = try latLonFromString("40.7128,-74.0060");
    try testing.expectEqual(coord1.lat, coord3.lat);
    try testing.expectEqual(coord1.lon, coord3.lon);

    const coord4 = try latLonFromString("(34.0522, -118.2437)");
    try testing.expectEqual(coord2.lat, coord4.lat);
    try testing.expectEqual(coord2.lon, coord4.lon);

    // Test string formatting
    const coord_str = try latLonToString(coord1, allocator);
    defer allocator.free(coord_str);
    try testing.expectEqualStrings("40.7128,-74.006", coord_str);

    // Test distance calculation (NY to LA is approximately 3944 km)
    const dist = latLonDistanceKm(coord1, coord2);
    try testing.expect(dist > 3900.0 and dist < 4000.0);

    // Test bearing calculation
    const bearing = latLonBearingTo(coord1, coord2);
    try testing.expect(bearing > 270.0 and bearing < 280.0);
}

test "LatLonAlt operations" {
    const testing = std.testing;

    // Test 3D coordinates
    const coord1 = try latLonAltFromCoords(40.7128, -74.0060, 100.0);
    const coord2 = try latLonAltFromCoords(40.7128, -74.0060, 200.0);

    try testing.expect(latLonAltIsValid(coord1));
    try testing.expect(latLonAltIsValid(coord2));

    // Test string parsing
    const coord3 = try latLonAltFromString("40.7128,-74.0060,100.0");
    try testing.expectEqual(coord1.lat, coord3.lat);
    try testing.expectEqual(coord1.lon, coord3.lon);
    try testing.expectEqual(coord1.alt, coord3.alt);

    // Test 3D distance (should be approximately 0.1 km due to altitude difference)
    const dist = latLonAltDistance3D(coord1, coord2);
    try testing.expect(dist > 0.09 and dist < 0.11);

    // Test conversion to LatLon
    const latlon = coord1.toLatLon();
    try testing.expectEqual(coord1.lat, latlon.lat);
    try testing.expectEqual(coord1.lon, latlon.lon);
}

test "Geographic encoding and decoding" {
    const testing = std.testing;

    // Test LatLon encoding/decoding
    const coord = try latLonFromCoords(40.7128, -74.0060);

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try latLonEncode(coord, &writer);
    const coord_len = writer.buffered().len;
    var reader = std.Io.Reader.fixed(buffer[0..coord_len]);
    const decoded_coord = try latLonDecode(&reader);

    try testing.expectEqual(coord.lat, decoded_coord.lat);
    try testing.expectEqual(coord.lon, decoded_coord.lon);

    // Test LatLonAlt encoding/decoding
    var writer2 = std.Io.Writer.fixed(&buffer);
    const coord_alt = try latLonAltFromCoords(40.7128, -74.0060, 100.0);

    try latLonAltEncode(coord_alt, &writer2);
    const alt_len = writer2.buffered().len;
    var reader2 = std.Io.Reader.fixed(buffer[0..alt_len]);
    const decoded_coord_alt = try latLonAltDecode(&reader2);

    try testing.expectEqual(coord_alt.lat, decoded_coord_alt.lat);
    try testing.expectEqual(coord_alt.lon, decoded_coord_alt.lon);
    try testing.expectEqual(coord_alt.alt, decoded_coord_alt.alt);
}

test "Geographic error handling" {
    const testing = std.testing;

    // Test invalid coordinates
    try testing.expectError(error.InvalidLatitude, latLonFromCoords(91.0, 0.0));
    try testing.expectError(error.InvalidLatitude, latLonFromCoords(-91.0, 0.0));
    try testing.expectError(error.InvalidLongitude, latLonFromCoords(0.0, 181.0));
    try testing.expectError(error.InvalidLongitude, latLonFromCoords(0.0, -181.0));

    // Test invalid string formats
    try testing.expectError(error.InvalidCoordinateFormat, latLonFromString("invalid"));
    try testing.expectError(error.InvalidCoordinateFormat, latLonFromString("40.7128"));
    try testing.expectError(error.InvalidLatitude, latLonFromString("91.0,-74.0060"));
    try testing.expectError(error.InvalidLongitude, latLonFromString("40.7128,-181.0"));
}
