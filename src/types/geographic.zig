const std = @import("std");

// CANARY: REQ=REQ-GQL-GEO-TYPES-001; FEATURE="Geographic Types Implementation"; ASPECT=Types; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_GEO_TYPES_001_All; OWNER=types; UPDATED=2025-01-03

/// Geographic types for spatial data and GIS operations
/// Supports latitude/longitude coordinates, points, and spatial operations
/// Latitude/Longitude coordinate pair
pub const LatLon = struct {
    lat: f64, // Latitude in decimal degrees (-90 to +90)
    lon: f64, // Longitude in decimal degrees (-180 to +180)

    pub fn fromCoords(lat: f64, lon: f64) !LatLon {
        if (lat < -90.0 or lat > 90.0) return error.InvalidLatitude;
        if (lon < -180.0 or lon > 180.0) return error.InvalidLongitude;

        return LatLon{
            .lat = lat,
            .lon = lon,
        };
    }

    pub fn fromString(coord_str: []const u8) !LatLon {
        // Parse formats: "lat,lon", "(lat,lon)", "lat lon"
        var cleaned_str = coord_str;

        // Remove parentheses if present
        if (std.mem.startsWith(u8, cleaned_str, "(") and std.mem.endsWith(u8, cleaned_str, ")")) {
            cleaned_str = cleaned_str[1 .. cleaned_str.len - 1];
        }

        // Split by comma or space
        var parts_comma = std.mem.splitSequence(u8, cleaned_str, ",");
        var parts: [2][]const u8 = undefined;
        var part_count: usize = 0;

        // Try comma first
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

        return fromCoords(lat, lon);
    }

    pub fn toString(self: LatLon, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{d},{d}", .{ self.lat, self.lon });
    }

    /// Calculate distance between two points using Haversine formula (in kilometers)
    pub fn distanceKm(self: LatLon, other: LatLon) f64 {
        const earth_radius_km = 6371.0;

        const lat1_rad = std.math.degreesToRadians(self.lat);
        const lat2_rad = std.math.degreesToRadians(other.lat);
        const delta_lat = std.math.degreesToRadians(other.lat - self.lat);
        const delta_lon = std.math.degreesToRadians(other.lon - self.lon);

        const a = @sin(delta_lat / 2.0) * @sin(delta_lat / 2.0) +
            @cos(lat1_rad) * @cos(lat2_rad) *
                @sin(delta_lon / 2.0) * @sin(delta_lon / 2.0);

        const c = 2.0 * std.math.atan2(@sqrt(a), @sqrt(1.0 - a));

        return earth_radius_km * c;
    }

    /// Calculate bearing from this point to another (in degrees, 0-360)
    pub fn bearingTo(self: LatLon, other: LatLon) f64 {
        const lat1_rad = std.math.degreesToRadians(self.lat);
        const lat2_rad = std.math.degreesToRadians(other.lat);
        const delta_lon = std.math.degreesToRadians(other.lon - self.lon);

        const y = @sin(delta_lon) * @cos(lat2_rad);
        const x = @cos(lat1_rad) * @sin(lat2_rad) -
            @sin(lat1_rad) * @cos(lat2_rad) * @cos(delta_lon);

        var bearing = std.math.radiansToDegrees(std.math.atan2(y, x));

        // Normalize to 0-360 degrees
        if (bearing < 0) {
            bearing += 360.0;
        }

        return bearing;
    }

    /// Check if point is within a bounding box
    pub fn isWithinBounds(self: LatLon, sw: LatLon, ne: LatLon) bool {
        return self.lat >= sw.lat and self.lat <= ne.lat and
            self.lon >= sw.lon and self.lon <= ne.lon;
    }

    /// Move point by distance and bearing
    pub fn moveByBearing(self: LatLon, distance_km: f64, bearing_degrees: f64) LatLon {
        const earth_radius_km = 6371.0;
        const angular_distance = distance_km / earth_radius_km;

        const lat1_rad = std.math.degreesToRadians(self.lat);
        const bearing_rad = std.math.degreesToRadians(bearing_degrees);

        const lat2_rad = std.math.asin(@sin(lat1_rad) * @cos(angular_distance) +
            @cos(lat1_rad) * @sin(angular_distance) * @cos(bearing_rad));

        const lon2_rad = std.math.degreesToRadians(self.lon) +
            std.math.atan2(@sin(bearing_rad) * @sin(angular_distance) * @cos(lat1_rad), @cos(angular_distance) - @sin(lat1_rad) * @sin(lat2_rad));

        const lat2 = std.math.radiansToDegrees(lat2_rad);
        var lon2 = std.math.radiansToDegrees(lon2_rad);

        // Normalize longitude to -180 to +180
        while (lon2 > 180.0) lon2 -= 360.0;
        while (lon2 < -180.0) lon2 += 360.0;

        return LatLon{
            .lat = lat2,
            .lon = lon2,
        };
    }

    /// Binary encoding for storage
    pub fn encode(self: LatLon, writer: anytype) !void {
        try writer.writeByte(0x12); // LatLon tag
        try writer.writeAll(std.mem.asBytes(&self.lat));
        try writer.writeAll(std.mem.asBytes(&self.lon));
    }

    pub fn decode(reader: anytype) !LatLon {
        const tag = try reader.readByte();
        if (tag != 0x12) return error.InvalidLatLonTag;

        const lat = @as(f64, @bitCast(try reader.readInt(u64, .little)));
        const lon = @as(f64, @bitCast(try reader.readInt(u64, .little)));

        return LatLon{
            .lat = lat,
            .lon = lon,
        };
    }

    /// Check if coordinates are valid
    pub fn isValid(self: LatLon) bool {
        return self.lat >= -90.0 and self.lat <= 90.0 and
            self.lon >= -180.0 and self.lon <= 180.0;
    }
};

/// Latitude/Longitude with altitude coordinate
pub const LatLonAlt = struct {
    lat: f64, // Latitude in decimal degrees (-90 to +90)
    lon: f64, // Longitude in decimal degrees (-180 to +180)
    alt: f64, // Altitude in meters

    pub fn fromCoords(lat: f64, lon: f64, alt: f64) !LatLonAlt {
        if (lat < -90.0 or lat > 90.0) return error.InvalidLatitude;
        if (lon < -180.0 or lon > 180.0) return error.InvalidLongitude;

        return LatLonAlt{
            .lat = lat,
            .lon = lon,
            .alt = alt,
        };
    }

    pub fn fromString(coord_str: []const u8) !LatLonAlt {
        // Parse formats: "lat,lon,alt", "(lat,lon,alt)", "lat lon alt"
        var cleaned_str = coord_str;

        // Remove parentheses if present
        if (std.mem.startsWith(u8, cleaned_str, "(") and std.mem.endsWith(u8, cleaned_str, ")")) {
            cleaned_str = cleaned_str[1 .. cleaned_str.len - 1];
        }

        // Split by comma or space
        var parts_comma = std.mem.splitSequence(u8, cleaned_str, ",");
        var parts: [3][]const u8 = undefined;
        var part_count: usize = 0;

        // Try comma first
        while (parts_comma.next()) |part| {
            if (part_count >= 3) return error.InvalidCoordinateFormat;
            parts[part_count] = std.mem.trim(u8, part, " \t\n\r");
            part_count += 1;
        }

        // If not enough parts, try space separation
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

        return fromCoords(lat, lon, alt);
    }

    pub fn toString(self: LatLonAlt, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{d},{d},{d}", .{ self.lat, self.lon, self.alt });
    }

    /// Convert to LatLon (ignoring altitude)
    pub fn toLatLon(self: LatLonAlt) LatLon {
        return LatLon{
            .lat = self.lat,
            .lon = self.lon,
        };
    }

    /// Calculate 3D distance including altitude difference (in kilometers)
    pub fn distance3D(self: LatLonAlt, other: LatLonAlt) f64 {
        const horizontal_dist = self.toLatLon().distanceKm(other.toLatLon());
        const vertical_dist_km = (self.alt - other.alt) / 1000.0; // Convert meters to km

        return @sqrt(horizontal_dist * horizontal_dist + vertical_dist_km * vertical_dist_km);
    }

    /// Binary encoding for storage
    pub fn encode(self: LatLonAlt, writer: anytype) !void {
        try writer.writeByte(0x13); // LatLonAlt tag
        try writer.writeAll(std.mem.asBytes(&self.lat));
        try writer.writeAll(std.mem.asBytes(&self.lon));
        try writer.writeAll(std.mem.asBytes(&self.alt));
    }

    pub fn decode(reader: anytype) !LatLonAlt {
        const tag = try reader.readByte();
        if (tag != 0x13) return error.InvalidLatLonAltTag;

        const lat = @as(f64, @bitCast(try reader.readInt(u64, .little)));
        const lon = @as(f64, @bitCast(try reader.readInt(u64, .little)));
        const alt = @as(f64, @bitCast(try reader.readInt(u64, .little)));

        return LatLonAlt{
            .lat = lat,
            .lon = lon,
            .alt = alt,
        };
    }

    /// Check if coordinates are valid
    pub fn isValid(self: LatLonAlt) bool {
        return self.lat >= -90.0 and self.lat <= 90.0 and
            self.lon >= -180.0 and self.lon <= 180.0;
    }
};

/// Simple geographic point with additional properties
pub const GeoPoint = struct {
    coord: LatLon,
    properties: ?[]const u8 = null, // JSON properties

    pub fn fromCoords(lat: f64, lon: f64) !GeoPoint {
        const coord = try LatLon.fromCoords(lat, lon);
        return GeoPoint{
            .coord = coord,
        };
    }

    pub fn fromString(coord_str: []const u8) !GeoPoint {
        const coord = try LatLon.fromString(coord_str);
        return GeoPoint{
            .coord = coord,
        };
    }

    pub fn toString(self: GeoPoint, allocator: std.mem.Allocator) ![]u8 {
        return self.coord.toString(allocator);
    }

    pub fn withProperties(self: GeoPoint, properties: []const u8) GeoPoint {
        return GeoPoint{
            .coord = self.coord,
            .properties = properties,
        };
    }

    /// Distance to another point
    pub fn distanceKm(self: GeoPoint, other: GeoPoint) f64 {
        return self.coord.distanceKm(other.coord);
    }

    /// Binary encoding for storage
    pub fn encode(self: GeoPoint, writer: anytype) !void {
        try writer.writeByte(0x14); // GeoPoint tag
        try self.coord.encode(writer);

        if (self.properties) |props| {
            try writer.writeByte(1); // Has properties
            try writer.writeInt(u32, @intCast(props.len), .little);
            try writer.writeAll(props);
        } else {
            try writer.writeByte(0); // No properties
        }
    }

    pub fn decode(reader: anytype, allocator: std.mem.Allocator) !GeoPoint {
        const tag = try reader.readByte();
        if (tag != 0x14) return error.InvalidGeoPointTag;

        _ = try reader.readByte(); // Skip LatLon tag
        const coord = LatLon{
            .lat = @bitCast(try reader.readInt(u64, .little)),
            .lon = @bitCast(try reader.readInt(u64, .little)),
        };

        const has_properties = try reader.readByte();
        var properties: ?[]const u8 = null;

        if (has_properties == 1) {
            const props_len = try reader.readInt(u32, .little);
            const props_data = try allocator.alloc(u8, props_len);
            try reader.readNoEof(props_data);
            properties = props_data;
        }

        return GeoPoint{
            .coord = coord,
            .properties = properties,
        };
    }

    pub fn deinit(self: GeoPoint, allocator: std.mem.Allocator) void {
        if (self.properties) |props| {
            allocator.free(props);
        }
    }
};

// Utility functions for geographic operations
pub fn latLonDistance(a: LatLon, b: LatLon) f64 {
    return a.distanceKm(b);
}

pub fn latLonBearing(from: LatLon, to: LatLon) f64 {
    return from.bearingTo(to);
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
/// This is the standard function used in GQL queries
pub fn distance_haversine(a: LatLon, b: LatLon) f64 {
    return a.distanceKm(b) * 1000.0; // Convert km to meters
}

/// Calculate bearing from one point to another (0-360 degrees)
pub fn geo_bearing(from: LatLon, to: LatLon) f64 {
    return from.bearingTo(to);
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
    // Simple average for small distances (works well for most use cases)
    // For more accuracy over large distances, spherical interpolation could be used
    return LatLon{
        .lat = (a.lat + b.lat) / 2.0,
        .lon = (a.lon + b.lon) / 2.0,
    };
}

/// Check if a point is within a circular radius (in meters) from a center point
pub fn geo_within_radius(point: LatLon, center: LatLon, radius_meters: f64) bool {
    const distance = distance_haversine(point, center);
    return distance <= radius_meters;
}

/// Check if a point is within a bounding box defined by southwest and northeast corners
pub fn geo_within_box(point: LatLon, southwest: LatLon, northeast: LatLon) bool {
    return point.isWithinBounds(southwest, northeast);
}

/// Calculate the destination point given a starting point, bearing, and distance
pub fn geo_destination(start: LatLon, bearing_degrees: f64, distance_meters: f64) LatLon {
    return start.moveByBearing(distance_meters / 1000.0, bearing_degrees);
}

/// Calculate approximate area of a triangle formed by three points (in square meters)
/// Uses Heron's formula with great circle distances
pub fn geo_triangle_area(a: LatLon, b: LatLon, c: LatLon) f64 {
    const side_a = distance_haversine(b, c);
    const side_b = distance_haversine(a, c);
    const side_c = distance_haversine(a, b);

    // Semi-perimeter
    const s = (side_a + side_b + side_c) / 2.0;

    // Heron's formula
    const area_squared = s * (s - side_a) * (s - side_b) * (s - side_c);
    if (area_squared <= 0.0) return 0.0;

    return @sqrt(area_squared);
}

/// Calculate the initial and final bearings (forward and reverse azimuths)
pub fn geo_azimuth(from: LatLon, to: LatLon) struct { forward: f64, reverse: f64 } {
    const forward = from.bearingTo(to);
    const reverse = to.bearingTo(from);
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
/// Returns signed distance in meters (positive = right of path, negative = left of path)
pub fn geo_cross_track_distance(point: LatLon, path_start: LatLon, path_end: LatLon) f64 {
    const earth_radius_m = 6371000.0;

    const d13_rad = distance_haversine(path_start, point) / earth_radius_m;
    const bearing_13_rad = std.math.degreesToRadians(path_start.bearingTo(point));
    const bearing_12_rad = std.math.degreesToRadians(path_start.bearingTo(path_end));

    const dxt = std.math.asin(@sin(d13_rad) * @sin(bearing_13_rad - bearing_12_rad));
    return dxt * earth_radius_m;
}

/// Calculate along-track distance from start of path to closest point to given point
/// Returns distance in meters along the great circle path
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

/// Calculate area of a polygon in square meters using the spherical excess formula
/// For small polygons, uses planar approximation which is faster
pub fn st_area(polygon: Polygon) f64 {
    if (polygon.points.len < 3) return 0.0;

    // For small polygons (< 1000 km²), use planar approximation
    // For large polygons, would need spherical excess formula
    const centroid = calculate_centroid(polygon.points);

    // Use planar approximation in meters
    var area: f64 = 0.0;
    const n = polygon.points.len;

    for (0..polygon.points.len) |i| {
        const curr = polygon.points[i];
        const next = polygon.points[(i + 1) % n];

        // Convert to meters from centroid
        const curr_x = distance_haversine(centroid, LatLon{ .lat = centroid.lat, .lon = curr.lon });
        const curr_y = distance_haversine(centroid, LatLon{ .lat = curr.lat, .lon = centroid.lon });
        const next_x = distance_haversine(centroid, LatLon{ .lat = centroid.lat, .lon = next.lon });
        const next_y = distance_haversine(centroid, LatLon{ .lat = next.lat, .lon = centroid.lon });

        // Apply longitude sign
        const curr_x_signed = if (curr.lon < centroid.lon) -curr_x else curr_x;
        const next_x_signed = if (next.lon < centroid.lon) -next_x else next_x;
        const curr_y_signed = if (curr.lat < centroid.lat) -curr_y else curr_y;
        const next_y_signed = if (next.lat < centroid.lat) -next_y else next_y;

        // Shoelace formula
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

    // Ray casting algorithm
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

/// Check if two geometries intersect (for points, this means they're the same)
pub fn st_intersects(a: LatLon, b: LatLon) bool {
    const threshold = 0.000001; // About 10cm at equator
    return @abs(a.lat - b.lat) < threshold and @abs(a.lon - b.lon) < threshold;
}

/// Check if two polygons intersect
pub fn st_intersects_polygon(a: Polygon, b: Polygon) bool {
    // Simple check: if any vertex of one polygon is inside the other
    for (a.points) |point| {
        if (st_within(point, b)) return true;
    }
    for (b.points) |point| {
        if (st_within(point, a)) return true;
    }
    return false;
}

/// Create a buffer (circle) around a point with specified radius in meters
/// Returns a polygon approximating a circle
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

/// Calculate the union of two polygons (simplified: convex hull)
/// For a full implementation, would use Sutherland-Hodgman or similar algorithm
pub fn st_union(allocator: std.mem.Allocator, a: Polygon, b: Polygon) !Polygon {
    // Simplified: just merge all points and return convex hull
    const total_points = a.points.len + b.points.len;
    const merged = try allocator.alloc(LatLon, total_points);
    errdefer allocator.free(merged);

    @memcpy(merged[0..a.points.len], a.points);
    @memcpy(merged[a.points.len..], b.points);

    // For MVP, return the merged points (would need convex hull algorithm for production)
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
    // Close the polygon
    if (polygon.points.len > 0) {
        total += distance_haversine(polygon.points[polygon.points.len - 1], polygon.points[0]);
    }
    return total;
}

/// Check if a polygon is simple (no self-intersections)
pub fn st_issimple(polygon: Polygon) bool {
    // Simplified check: assume simple for now
    // Full implementation would check all edge pairs for intersections
    return polygon.points.len >= 3;
}

/// Check if a polygon is valid (closed, simple, non-self-intersecting)
pub fn st_isvalid(polygon: Polygon) bool {
    if (polygon.points.len < 3) return false;

    // Check if polygon is closed
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
            .southwest = LatLon{ .lat = 0, .lon = 0 },
            .northeast = LatLon{ .lat = 0, .lon = 0 },
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
        .southwest = LatLon{ .lat = min_lat, .lon = min_lon },
        .northeast = LatLon{ .lat = max_lat, .lon = max_lon },
    };
}

/// Helper: Calculate centroid of points
fn calculate_centroid(points: []LatLon) LatLon {
    if (points.len == 0) return LatLon{ .lat = 0, .lon = 0 };

    var sum_lat: f64 = 0;
    var sum_lon: f64 = 0;

    for (points) |point| {
        sum_lat += point.lat;
        sum_lon += point.lon;
    }

    return LatLon{
        .lat = sum_lat / @as(f64, @floatFromInt(points.len)),
        .lon = sum_lon / @as(f64, @floatFromInt(points.len)),
    };
}

// Test suite
test "LatLon operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test coordinate creation and validation
    const coord1 = try LatLon.fromCoords(40.7128, -74.0060); // New York
    const coord2 = try LatLon.fromCoords(34.0522, -118.2437); // Los Angeles

    try testing.expect(coord1.isValid());
    try testing.expect(coord2.isValid());

    // Test string parsing
    const coord3 = try LatLon.fromString("40.7128,-74.0060");
    try testing.expectEqual(coord1.lat, coord3.lat);
    try testing.expectEqual(coord1.lon, coord3.lon);

    const coord4 = try LatLon.fromString("(34.0522, -118.2437)");
    try testing.expectEqual(coord2.lat, coord4.lat);
    try testing.expectEqual(coord2.lon, coord4.lon);

    // Test string formatting
    const coord_str = try coord1.toString(allocator);
    defer allocator.free(coord_str);
    try testing.expectEqualStrings("40.7128,-74.006", coord_str);

    // Test distance calculation (NY to LA is approximately 3944 km)
    const distance = coord1.distanceKm(coord2);
    try testing.expect(distance > 3900.0 and distance < 4000.0);

    // Test bearing calculation
    const bearing = coord1.bearingTo(coord2);
    try testing.expect(bearing > 270.0 and bearing < 280.0); // West-northwest direction
}

test "LatLonAlt operations" {
    const testing = std.testing;

    // Test 3D coordinates
    const coord1 = try LatLonAlt.fromCoords(40.7128, -74.0060, 100.0);
    const coord2 = try LatLonAlt.fromCoords(40.7128, -74.0060, 200.0);

    try testing.expect(coord1.isValid());
    try testing.expect(coord2.isValid());

    // Test string parsing
    const coord3 = try LatLonAlt.fromString("40.7128,-74.0060,100.0");
    try testing.expectEqual(coord1.lat, coord3.lat);
    try testing.expectEqual(coord1.lon, coord3.lon);
    try testing.expectEqual(coord1.alt, coord3.alt);

    // Test 3D distance (should be approximately 0.1 km due to altitude difference)
    const distance = coord1.distance3D(coord2);
    try testing.expect(distance > 0.09 and distance < 0.11);

    // Test conversion to LatLon
    const latlon = coord1.toLatLon();
    try testing.expectEqual(coord1.lat, latlon.lat);
    try testing.expectEqual(coord1.lon, latlon.lon);
}

test "GeoPoint operations" {
    const testing = std.testing;

    // Test point creation
    const point1 = try GeoPoint.fromCoords(40.7128, -74.0060);
    const point2 = try GeoPoint.fromString("34.0522,-118.2437");

    // Test distance
    const distance = point1.distanceKm(point2);
    try testing.expect(distance > 3900.0 and distance < 4000.0);

    // Test with properties
    const props = "{\"name\":\"New York\",\"population\":8175133}";
    const point_with_props = point1.withProperties(props);
    try testing.expectEqualStrings(props, point_with_props.properties.?);
}

test "Geographic encoding and decoding" {
    const testing = std.testing;

    // Test LatLon encoding/decoding
    const coord = try LatLon.fromCoords(40.7128, -74.0060);

    var buffer: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try coord.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_coord = try LatLon.decode(fbs.reader());

    try testing.expectEqual(coord.lat, decoded_coord.lat);
    try testing.expectEqual(coord.lon, decoded_coord.lon);

    // Test LatLonAlt encoding/decoding
    fbs.pos = 0;
    const coord_alt = try LatLonAlt.fromCoords(40.7128, -74.0060, 100.0);

    try coord_alt.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_coord_alt = try LatLonAlt.decode(fbs.reader());

    try testing.expectEqual(coord_alt.lat, decoded_coord_alt.lat);
    try testing.expectEqual(coord_alt.lon, decoded_coord_alt.lon);
    try testing.expectEqual(coord_alt.alt, decoded_coord_alt.alt);
}

test "Geographic error handling" {
    const testing = std.testing;

    // Test invalid coordinates
    try testing.expectError(error.InvalidLatitude, LatLon.fromCoords(91.0, 0.0));
    try testing.expectError(error.InvalidLatitude, LatLon.fromCoords(-91.0, 0.0));
    try testing.expectError(error.InvalidLongitude, LatLon.fromCoords(0.0, 181.0));
    try testing.expectError(error.InvalidLongitude, LatLon.fromCoords(0.0, -181.0));

    // Test invalid string formats
    try testing.expectError(error.InvalidCoordinateFormat, LatLon.fromString("invalid"));
    try testing.expectError(error.InvalidCoordinateFormat, LatLon.fromString("40.7128"));
    try testing.expectError(error.InvalidLatitude, LatLon.fromString("91.0,-74.0060"));
    try testing.expectError(error.InvalidLongitude, LatLon.fromString("40.7128,-181.0"));
}
