const std = @import("std");

// CANARY: REQ=REQ-GQL-GEO-TYPES-001; FEATURE="Geographic Types Implementation"; ASPECT=Types; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_GEO_TYPES_001_All; OWNER=types; UPDATED=2025-01-03

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
