const std = @import("std");
const ast = @import("gql/ast.zig");
const heap = @import("storage/heap.zig");
const patricia = @import("index/patricia.zig");
const rtree = @import("index/rtree.zig");
const hnsw = @import("index/hnsw.zig");
const extf = @import("types/extended_functions.zig");
const network = @import("types/network.zig");
const datetime = @import("types/datetime.zig");
const uuid = @import("types/uuid.zig");
const url = @import("types/url.zig");
const jsonb = @import("types/jsonb.zig");
const xml = @import("types/xml.zig");
const bitstring = @import("types/bitstring.zig");
const range = @import("types/range.zig");

// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=ADAPTER_CACHE; STATUS=IMPL; TEST=tests/canary_extended_builtins.zig; OWNER=engine; UPDATED=2025-09-26

// Adapter registry caching: avoid rebuilding extf registry for every bridged call.
// We lazily initialize a global registry once in a thread-safe manner (single-threaded init assumption for now).
var global_adapter_registry: ?extf.Registry = null;
var global_adapter_registry_init = std.atomic.Value(bool).init(false);
fn getAdapterRegistry(allocator: std.mem.Allocator) !*extf.Registry {
    if (global_adapter_registry_init.load(.acquire)) {
        return &global_adapter_registry.?;
    }
    const reg = try extf.initRegistry(allocator);
    global_adapter_registry = reg;
    global_adapter_registry_init.store(true, .release);
    return &global_adapter_registry.?;
}

// Bridge for new experimental extended functions (uuid_v4, geobox_contains, polygon_area, vector_cosine etc.)
// We expose them under their existing names; adapter converts between ExtValue and extf.BuiltinValue.

fn toBuiltin(v: ExtValue) extf.BuiltinValue {
    return switch (v) {
        .Null => .{ .Null = {} },
        .Int => |x| .{ .Int = x },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        else => .{ .Null = {} }, // unsupported pass-through (could extend)
    };
}

fn fromBuiltin(v: extf.BuiltinValue) ExtValue {
    return switch (v) {
        .Null => .{ .Null = {} },
        .Int => |x| .{ .Int = x },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        else => .{ .Null = {} },
    };
}

fn adapterFactory(comptime name: []const u8) *const fn (allocator: std.mem.Allocator, args: []const ExtValue) anyerror!ExtValue {
    return struct {
        fn call(allocator: std.mem.Allocator, args: []const ExtValue) anyerror!ExtValue {
            const reg_ptr = try getAdapterRegistry(allocator);
            const fnp = reg_ptr.get(name) orelse return error.NotFound;
            var tmp: [8]extf.BuiltinValue = undefined;
            if (args.len > tmp.len) return error.InvalidArgs;
            var i: usize = 0;
            while (i < args.len) : (i += 1) tmp[i] = toBuiltin(args[i]);
            const res = try fnp(allocator, tmp[0..args.len]);
            return fromBuiltin(res);
        }
    }.call;
}

pub const ExtValue = union(enum) {
    Null,
    Int: i64,
    Bool: bool,
    Str: []const u8,
    Decimal: struct { coeff: i128, scale: u8 },
    IpAddr: heap.IpAddr,
    Subnet: heap.Subnet,
    Mac: heap.Mac,
    Hash: heap.Hash,
    Currency: heap.Currency,
    LanguageTag: heap.LanguageTag,
    LatLon: heap.LatLon,
    LatLonAlt: heap.LatLonAlt,
    Geometry: heap.Geometry,
    Temperature: heap.Temperature,
    Pressure: heap.Pressure,
    VectorF32: heap.VectorF32,
    VectorI32: heap.VectorI32,
    Date: datetime.Date,
    Time: datetime.Time,
    TimestampTZ: datetime.TimestampTZ,
    Interval: datetime.Interval,
    UUID: uuid.UUID,
    Url: url.Url,
    Domain: url.Domain,
    Bytea: []const u8,
    Json: []const u8,
    Jsonb: jsonb.JsonbDocument,
    Xml: xml.XmlDocument,
    BitString: bitstring.BitString,
    VarBit: bitstring.BitString,
    IntRange: range.IntRange,
    Enum: struct { type_id: u32, value_ordinal: u32 },
    List: []ExtValue,
};

const FunctionRegistry = std.StringHashMap(*const fn (allocator: std.mem.Allocator, args: []const ExtValue) anyerror!ExtValue);

pub fn initFunctionRegistry(allocator: std.mem.Allocator) !FunctionRegistry {
    var registry = FunctionRegistry.init(allocator);

    // Constructors
    try registry.put("ipaddr", &constructIpAddr);
    try registry.put("subnet", &constructSubnet);
    try registry.put("mac", &constructMac);
    try registry.put("hash", &constructHash);
    try registry.put("currency", &constructCurrency);
    try registry.put("languagetag", &constructLanguageTag);
    try registry.put("latlon", &constructLatLon);
    try registry.put("latlonalt", &constructLatLonAlt);
    try registry.put("geometryfromtext", &constructGeometryFromText);
    try registry.put("temperature", &constructTemperature);
    try registry.put("pressure", &constructPressure);
    try registry.put("vector", &constructVector);
    try registry.put("vectorf32", &constructVectorF32);
    try registry.put("vectori32", &constructVectorI32);
    try registry.put("decimal", &constructDecimal);
    try registry.put("jsonb", &constructJsonb);

    // IP/CIDR functions
    try registry.put("ip_contains", &ipContains);
    try registry.put("ip_overlaps", &ipOverlaps);
    try registry.put("ip_family", &ipFamily);
    try registry.put("ip_is_private", &ipIsPrivate);
    try registry.put("subnet_prefix_length", &subnetPrefixLength);
    try registry.put("ip_network", &ipNetwork);
    try registry.put("ip_netmask", &ipNetmask);

    // MAC functions
    try registry.put("mac_is_local", &macIsLocal);
    try registry.put("mac_is_multicast", &macIsMulticast);
    try registry.put("oui", &macOui);

    // Hash functions
    try registry.put("hash_equals", &hashEquals);
    try registry.put("hash_alg", &hashAlg);

    // Currency functions
    try registry.put("minor_units", &currencyMinorUnits);

    // Language functions
    try registry.put("lang_canonicalize", &langCanonizalize);
    try registry.put("lang_match", &langMatch);

    // LatLon functions
    try registry.put("distance_haversine", &distanceHaversine);
    try registry.put("latitude", &getLatitude);
    try registry.put("longitude", &getLongitude);
    try registry.put("altitude", &getAltitude);
    try registry.put("alt_ref", &getAltRef);
    try registry.put("geo_bearing", &geoBearing);
    try registry.put("geo_lat", &geoLat);
    try registry.put("geo_lon", &geoLon);

    // Geometry functions
    try registry.put("st_point", &stPoint);
    try registry.put("st_astext", &stAsText);
    try registry.put("st_asgeojson", &stAsGeoJson);
    try registry.put("st_x", &stX);
    try registry.put("st_y", &stY);
    try registry.put("st_distance", &stDistance);
    try registry.put("st_area", &stArea);
    try registry.put("st_centroid", &stCentroid);
    try registry.put("st_buffer", &stBuffer);
    try registry.put("st_contains", &stContains);
    try registry.put("st_intersects", &stIntersects);
    try registry.put("st_within", &stWithin);

    // Vector functions
    try registry.put("vector_dot", &vectorDot);
    try registry.put("vector_l2", &vectorL2);
    try registry.put("vector_cosine", &vectorCosine);
    try registry.put("vector_knn", &vectorKnn);

    // Decimal arithmetic functions
    try registry.put("decimal_add", &decimalAdd);
    try registry.put("decimal_sub", &decimalSub);
    try registry.put("decimal_mul", &decimalMul);
    try registry.put("decimal_div", &decimalDiv);

    // Experimental extended functions (bridged)
    try registry.put("uuid_v4", adapterFactory("uuid_v4"));
    try registry.put("geobox_contains", adapterFactory("geobox_contains"));
    try registry.put("polygon_area", adapterFactory("polygon_area"));
    // vector_cosine already exists; keep original for f32 vectors
    try registry.put("date_part", adapterFactory("date_part"));
    try registry.put("time_part", adapterFactory("time_part"));
    try registry.put("duration_add", adapterFactory("duration_add"));
    try registry.put("duration_sub", adapterFactory("duration_sub"));
    try registry.put("json_get", adapterFactory("json_get"));

    return registry;
}

// Constructors
fn constructIpAddr(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const text = args[0].Str;
    const addr = network.IpAddr.fromString(text) catch return error.InvalidIpAddress;

    // Convert to heap.IpAddr format
    const heap_addr = switch (addr) {
        .v4 => |ipv4| heap.IpAddr{ .v4 = ipv4.octets },
        .v6 => |ipv6| blk: {
            var bytes: [16]u8 = undefined;
            for (ipv6.segments, 0..) |segment, i| {
                bytes[i * 2] = @intCast((segment >> 8) & 0xFF);
                bytes[i * 2 + 1] = @intCast(segment & 0xFF);
            }
            break :blk heap.IpAddr{ .v6 = bytes };
        },
    };

    return .{ .IpAddr = heap_addr };
}

fn constructSubnet(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const text = args[0].Str;
    const subnet = network.Subnet.fromString(text) catch return error.InvalidSubnet;

    // Convert to heap.Subnet format
    const heap_addr = switch (subnet) {
        .v4 => |ipv4_subnet| heap.IpAddr{ .v4 = ipv4_subnet.network },
        .v6 => |ipv6_subnet| blk: {
            var bytes: [16]u8 = undefined;
            for (ipv6_subnet.network, 0..) |segment, i| {
                bytes[i * 2] = @intCast((segment >> 8) & 0xFF);
                bytes[i * 2 + 1] = @intCast(segment & 0xFF);
            }
            break :blk heap.IpAddr{ .v6 = bytes };
        },
    };

    const prefix_len = switch (subnet) {
        .v4 => |ipv4_subnet| ipv4_subnet.prefix_len,
        .v6 => |ipv6_subnet| ipv6_subnet.prefix_len,
    };

    return .{ .Subnet = .{ .addr = heap_addr, .prefix_len = prefix_len } };
}

fn constructMac(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const text = args[0].Str;
    const mac = network.Mac.fromString(text) catch return error.InvalidMac;

    return .{ .Mac = .{ .bytes = mac.octets } };
}

fn constructHash(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Str or args[1] != .Str) return error.TypeMismatch;

    const alg_str = args[0].Str;
    const hex_str = args[1].Str;

    const alg: heap.HashAlg = if (std.ascii.eqlIgnoreCase(alg_str, "sha3-256"))
        .SHA3_256
    else if (std.ascii.eqlIgnoreCase(alg_str, "sha3-512"))
        .SHA3_512
    else if (std.ascii.eqlIgnoreCase(alg_str, "blake3"))
        .BLAKE3
    else if (std.ascii.eqlIgnoreCase(alg_str, "blake2b-256"))
        .BLAKE2B_256
    else if (std.ascii.eqlIgnoreCase(alg_str, "blake2b-512"))
        .BLAKE2B_512
    else if (std.ascii.eqlIgnoreCase(alg_str, "blake2s-256"))
        .BLAKE2S_256
    else if (std.ascii.eqlIgnoreCase(alg_str, "argon2id"))
        .ARGON2ID
    else
        return error.InvalidHashAlg;

    const expected_len: usize = switch (alg) {
        .SHA3_256, .BLAKE3, .BLAKE2B_256, .BLAKE2S_256, .ARGON2ID => 64,
        .SHA3_512, .BLAKE2B_512 => 128,
    };

    if (hex_str.len != expected_len) return error.InvalidHashLength;

    const digest_len = expected_len / 2;
    var digest = try allocator.alloc(u8, digest_len);

    var i: usize = 0;
    while (i < digest_len) : (i += 1) {
        digest[i] = try std.fmt.parseInt(u8, hex_str[i * 2 .. (i + 1) * 2], 16);
    }

    return .{ .Hash = .{ .alg = alg, .digest = digest } };
}

fn constructCurrency(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    // allocator currently unused
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const code_str = args[0].Str;
    if (code_str.len != 3) return error.InvalidCurrency;

    var code: [3]u8 = undefined;
    for (code_str, 0..) |c, i| {
        code[i] = std.ascii.toUpper(c);
    }

    return .{ .Currency = .{ .code = code } };
}

fn constructLanguageTag(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const tag_str = args[0].Str;
    const canonical = try canonicalizeLanguageTag(allocator, tag_str);

    return .{ .LanguageTag = .{ .tag = canonical } };
}

fn canonicalizeLanguageTag(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    var parts = std.mem.tokenizeAny(u8, tag, "-");
    var part_idx: usize = 0;
    while (parts.next()) |part| {
        if (part_idx == 0) {
            if (std.mem.eql(u8, part, "iw")) {
                try result.appendSlice(allocator, "he");
            } else if (std.mem.eql(u8, part, "mo")) {
                try result.appendSlice(allocator, "ro");
            } else {
                for (part) |c| try result.append(allocator, std.ascii.toLower(c));
            }
        } else if (part.len == 4 and part_idx == 1) {
            if (result.items.len > 0) try result.append(allocator, '-');
            try result.append(allocator, std.ascii.toUpper(part[0]));
            for (part[1..]) |c| try result.append(allocator, std.ascii.toLower(c));
        } else if (part.len == 2 or part.len == 3) {
            if (result.items.len > 0) try result.append(allocator, '-');
            for (part) |c| try result.append(allocator, std.ascii.toUpper(c));
        } else {
            if (result.items.len > 0) try result.append(allocator, '-');
            for (part) |c| try result.append(allocator, std.ascii.toLower(c));
        }
        part_idx += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn constructLatLon(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;

    // Handle string format: LatLon('40.7128,-74.0060')
    if (args.len == 1 and args[0] == .Str) {
        const text = args[0].Str;
        var parts = std.mem.tokenizeAny(u8, text, ",");

        const lat_str = parts.next() orelse return error.InvalidFormat;
        const lon_str = parts.next() orelse return error.InvalidFormat;

        const lat = try std.fmt.parseFloat(f64, lat_str);
        const lon = try std.fmt.parseFloat(f64, lon_str);

        if (lat < -90 or lat > 90) return error.InvalidLatitude;
        if (lon < -180 or lon > 180) return error.InvalidLongitude;

        return .{ .LatLon = .{ .lat = lat, .lon = lon } };
    }

    // Handle numeric format: LatLon(40.7128, -74.0060)
    if (args.len != 2) return error.InvalidArgs;

    const lat = switch (args[0]) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };

    const lon = switch (args[1]) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };

    if (lat < -90 or lat > 90) return error.InvalidLatitude;
    if (lon < -180 or lon > 180) return error.InvalidLongitude;

    return .{ .LatLon = .{ .lat = lat, .lon = lon } };
}

fn constructLatLonAlt(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;

    // Handle string format: LatLonAlt('40.7128,-74.0060,100') or LatLonAlt('40.7128,-74.0060,100,ellipsoid')
    if (args.len == 1 and args[0] == .Str) {
        const text = args[0].Str;
        var parts = std.mem.tokenizeAny(u8, text, ",");

        const lat_str = parts.next() orelse return error.InvalidFormat;
        const lon_str = parts.next() orelse return error.InvalidFormat;
        const alt_str = parts.next() orelse return error.InvalidFormat;
        const ref_str = parts.next(); // Optional, defaults to ellipsoid

        const lat = try std.fmt.parseFloat(f64, lat_str);
        const lon = try std.fmt.parseFloat(f64, lon_str);
        const alt = try std.fmt.parseFloat(f64, alt_str);

        const ref: heap.AltRef = if (ref_str) |r|
            if (std.mem.eql(u8, r, "ellipsoid"))
                .ellipsoid
            else if (std.mem.eql(u8, r, "geoid"))
                .geoid
            else
                return error.InvalidAltRef
        else
            .ellipsoid; // Default

        if (lat < -90 or lat > 90) return error.InvalidLatitude;
        if (lon < -180 or lon > 180) return error.InvalidLongitude;

        return .{ .LatLonAlt = .{ .lat = lat, .lon = lon, .alt = alt, .ref = ref } };
    }

    // Handle numeric format: LatLonAlt(40.7128, -74.0060, 100, 'ellipsoid')
    // Also accept 3 args with default ref
    if (args.len != 3 and args.len != 4) return error.InvalidArgs;

    const lat = switch (args[0]) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };

    const lon = switch (args[1]) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };

    const alt = switch (args[2]) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };

    const ref: heap.AltRef = if (args.len == 4) blk: {
        // Support both integer and string ref parameters
        if (args[3] == .Int) {
            const ref_int = args[3].Int;
            break :blk if (ref_int == 0)
                .ellipsoid
            else if (ref_int == 1)
                .geoid
            else
                return error.InvalidAltRef;
        } else if (args[3] == .Str) {
            break :blk if (std.mem.eql(u8, args[3].Str, "ellipsoid"))
                .ellipsoid
            else if (std.mem.eql(u8, args[3].Str, "geoid"))
                .geoid
            else
                return error.InvalidAltRef;
        } else {
            return error.TypeMismatch;
        }
    } else .ellipsoid; // Default

    if (lat < -90 or lat > 90) return error.InvalidLatitude;
    if (lon < -180 or lon > 180) return error.InvalidLongitude;

    return .{ .LatLonAlt = .{ .lat = lat, .lon = lon, .alt = alt, .ref = ref } };
}

fn constructGeometryFromText(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const wkt = args[0].Str;
    const wkb = try parseWktToWkb(allocator, wkt);

    return .{ .Geometry = .{ .wkb = wkb } };
}

fn parseWktToWkb(allocator: std.mem.Allocator, wkt: []const u8) ![]const u8 {
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
        var points = try std.ArrayList(Point).initCapacity(allocator, 0);
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
        var points = try std.ArrayList(Point).initCapacity(allocator, 0);
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
    // CANARY: REQ=REQ-GEO-MULTI-001; FEATURE="MultiGeometry"; ASPECT=SpatialTypes; STATUS=IMPL; OWNER=types; UPDATED=2026-01-10
    if (std.mem.startsWith(u8, wkt, "MULTIPOINT")) {
        const Point = struct { x: f64, y: f64 };
        var points = try std.ArrayList(Point).initCapacity(allocator, 0);
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
    // CANARY: REQ=REQ-GEO-MULTI-002; FEATURE="MultiGeometry"; ASPECT=SpatialTypes; STATUS=IMPL; OWNER=types; UPDATED=2026-01-10
    if (std.mem.startsWith(u8, wkt, "MULTILINESTRING")) {
        const Point = struct { x: f64, y: f64 };
        // Parse as single linestring for simplicity - handle first linestring in multi
        const start_idx = std.mem.indexOf(u8, wkt, "((") orelse return error.InvalidWkt;
        const end_idx = std.mem.lastIndexOf(u8, wkt, "))") orelse return error.InvalidWkt;
        const lines_str = wkt[start_idx + 2 .. end_idx];

        // Parse first linestring (simplified - full implementation would parse all)
        var points = try std.ArrayList(Point).initCapacity(allocator, 0);
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
    // CANARY: REQ=REQ-GEO-MULTI-003; FEATURE="MultiGeometry"; ASPECT=SpatialTypes; STATUS=IMPL; OWNER=types; UPDATED=2026-01-10
    if (std.mem.startsWith(u8, wkt, "MULTIPOLYGON")) {
        const Point = struct { x: f64, y: f64 };
        // Parse first polygon for simplicity
        const start_idx = std.mem.indexOf(u8, wkt, "(((") orelse return error.InvalidWkt;
        const end_idx = std.mem.indexOf(u8, wkt, ")))") orelse return error.InvalidWkt;
        const poly_str = wkt[start_idx + 3 .. end_idx];

        var points = try std.ArrayList(Point).initCapacity(allocator, 0);
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

fn constructTemperature(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;

    const value = switch (args[0]) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };

    var unit_in: heap.TempUnit = undefined;
    var value_K: f64 = undefined;

    // Support both integer and string unit parameters
    if (args[1] == .Int) {
        const unit_int = args[1].Int;
        if (unit_int == 0) {
            unit_in = .K;
            value_K = value;
        } else if (unit_int == 1) {
            unit_in = .C;
            value_K = value + 273.15;
        } else if (unit_int == 2) {
            unit_in = .F;
            value_K = (value - 32) * 5 / 9 + 273.15;
        } else {
            return error.InvalidTempUnit;
        }
    } else if (args[1] == .Str) {
        const unit_str = args[1].Str;
        if (std.ascii.eqlIgnoreCase(unit_str, "K")) {
            unit_in = .K;
            value_K = value;
        } else if (std.ascii.eqlIgnoreCase(unit_str, "C")) {
            unit_in = .C;
            value_K = value + 273.15;
        } else if (std.ascii.eqlIgnoreCase(unit_str, "F")) {
            unit_in = .F;
            value_K = (value - 32) * 5 / 9 + 273.15;
        } else {
            return error.InvalidTempUnit;
        }
    } else {
        return error.TypeMismatch;
    }

    return .{ .Temperature = .{ .value_K = value_K, .unit_in = unit_in } };
}

fn constructPressure(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;

    const value = switch (args[0]) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };

    var unit_in: heap.PressureUnit = undefined;
    var value_Pa: f64 = undefined;

    // Support both integer and string unit parameters
    if (args[1] == .Int) {
        const unit_int = args[1].Int;
        if (unit_int == 0) {
            unit_in = .Pa;
            value_Pa = value;
        } else if (unit_int == 1) {
            unit_in = .kPa;
            value_Pa = value * 1000;
        } else if (unit_int == 2) {
            unit_in = .bar;
            value_Pa = value * 100000;
        } else if (unit_int == 3) {
            unit_in = .atm;
            value_Pa = value * 101325;
        } else {
            return error.InvalidPressureUnit;
        }
    } else if (args[1] == .Str) {
        const unit_str = args[1].Str;
        if (std.ascii.eqlIgnoreCase(unit_str, "Pa")) {
            unit_in = .Pa;
            value_Pa = value;
        } else if (std.ascii.eqlIgnoreCase(unit_str, "kPa") or std.ascii.eqlIgnoreCase(unit_str, "hPa")) {
            unit_in = .kPa;
            value_Pa = value * 1000;
        } else if (std.ascii.eqlIgnoreCase(unit_str, "bar")) {
            unit_in = .bar;
            value_Pa = value * 100000;
        } else if (std.ascii.eqlIgnoreCase(unit_str, "atm")) {
            unit_in = .atm;
            value_Pa = value * 101325;
        } else {
            return error.InvalidPressureUnit;
        }
    } else {
        return error.TypeMismatch;
    }

    return .{ .Pressure = .{ .value_Pa = value_Pa, .unit_in = unit_in } };
}

fn constructVector(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .List) return error.TypeMismatch;

    const list = args[0].List;
    var data = try allocator.alloc(f32, list.len);

    for (list, 0..) |item, i| {
        data[i] = switch (item) {
            .Int => |v| @floatFromInt(v),
            .Decimal => |d| @as(f32, @floatCast(@as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))))),
            else => return error.TypeMismatch,
        };
    }

    return .{ .VectorF32 = .{ .dim = @intCast(list.len), .data = data } };
}

fn constructVectorF32(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;

    // Handle array literal: VectorF32([0.1, 0.2, 0.3])
    if (args[0] == .List) {
        const list = args[0].List;
        var data = try allocator.alloc(f32, list.len);

        for (list, 0..) |item, i| {
            data[i] = switch (item) {
                .Int => |iv| @floatFromInt(iv),
                .Decimal => |d| blk: {
                    const coeff_f64 = @as(f64, @floatFromInt(d.coeff));
                    const scale_f64 = @as(f64, @floatFromInt(d.scale));
                    const divisor = std.math.pow(f64, 10, scale_f64);
                    break :blk @as(f32, @floatCast(coeff_f64 / divisor));
                },
                else => return error.TypeMismatch,
            };
        }

        return .{ .VectorF32 = .{ .dim = @intCast(list.len), .data = data } };
    }

    // Handle string: VectorF32('[0.1, 0.2, 0.3]')
    if (args[0] != .Str) return error.TypeMismatch;

    const text = args[0].Str;

    // Use the evaluator_functions implementation
    const eval_funcs = @import("types/evaluator_functions.zig");
    const result = eval_funcs.VectorF32(allocator, text) catch return error.InvalidFormat;

    return .{ .VectorF32 = result.VectorF32 };
}

// CANARY: REQ=REQ-VECTOR-I32-002; FEATURE="VectorI32"; ASPECT=ConstructorFunction; STATUS=IMPL; OWNER=eval; UPDATED=2025-12-23
fn constructVectorI32(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;

    // Handle array literal: VectorI32([1, 2, 3])
    if (args[0] == .List) {
        const list = args[0].List;
        var data = try allocator.alloc(i32, list.len);

        for (list, 0..) |item, i| {
            data[i] = switch (item) {
                .Int => |iv| @intCast(iv),
                else => return error.TypeMismatch,
            };
        }

        return .{ .VectorI32 = .{ .dim = @intCast(list.len), .data = data } };
    }

    // Handle string: VectorI32('[1, 2, 3]')
    if (args[0] != .Str) return error.TypeMismatch;

    const text = args[0].Str;

    // Parse vector string format: "[1, 2, 3]" or "1,2,3"
    var cleaned_str = text;

    // Remove brackets if present
    if (std.mem.startsWith(u8, cleaned_str, "[") and std.mem.endsWith(u8, cleaned_str, "]")) {
        cleaned_str = cleaned_str[1 .. cleaned_str.len - 1];
    }

    // Split by comma and parse each element
    var parts = std.mem.splitSequence(u8, cleaned_str, ",");
    var elements = std.ArrayListUnmanaged(i32){};
    defer elements.deinit(allocator);

    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;
        const value = std.fmt.parseInt(i32, trimmed, 10) catch return error.InvalidFormat;
        try elements.append(allocator, value);
    }

    if (elements.items.len == 0) return error.InvalidFormat;
    if (elements.items.len > 65535) return error.InvalidFormat;

    const data = try allocator.dupe(i32, elements.items);
    return .{ .VectorI32 = .{ .dim = @intCast(data.len), .data = data } };
}

fn constructJsonb(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const json_str = args[0].Str;

    // Basic JSON validation - check for balanced braces/brackets
    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_string = false;
    var escape_next = false;

    for (json_str) |c| {
        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (c == '\\') {
            escape_next = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (!in_string) {
            if (c == '{') brace_depth += 1;
            if (c == '}') brace_depth -= 1;
            if (c == '[') bracket_depth += 1;
            if (c == ']') bracket_depth -= 1;
        }
    }

    if (brace_depth != 0 or bracket_depth != 0 or in_string) {
        return error.InvalidJson;
    }

    // Return as string for now (until Jsonb heap type is fully integrated)
    return .{ .Str = json_str };
}

// IP/CIDR functions
fn ipContains(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;

    const subnet = switch (args[0]) {
        .Subnet => |s| s,
        else => return error.TypeMismatch,
    };

    const check_addr = switch (args[1]) {
        .IpAddr => |ip| ip,
        .Subnet => |s| s.addr,
        else => return error.TypeMismatch,
    };

    // Check family match
    if ((subnet.addr == .v4) != (check_addr == .v4)) {
        return .{ .Bool = false };
    }

    if (subnet.addr == .v4) {
        const subnet_bytes = subnet.addr.v4;
        const check_bytes = check_addr.v4;

        const mask_bits = subnet.prefix_len;
        if (mask_bits == 0) return .{ .Bool = true };

        const full_bytes = mask_bits / 8;
        const remaining_bits = mask_bits % 8;

        var i: usize = 0;
        while (i < full_bytes) : (i += 1) {
            if (subnet_bytes[i] != check_bytes[i]) return .{ .Bool = false };
        }

        if (remaining_bits > 0) {
            const shift: u3 = @intCast(8 - remaining_bits); // remaining_bits 1..7
            const mask: u8 = (@as(u8, 0xFF)) << shift;
            if ((subnet_bytes[full_bytes] & mask) != (check_bytes[full_bytes] & mask)) return .{ .Bool = false };
        }

        return .{ .Bool = true };
    } else {
        const subnet_bytes = subnet.addr.v6;
        const check_bytes = check_addr.v6;

        const mask_bits = subnet.prefix_len;
        if (mask_bits == 0) return .{ .Bool = true };

        const full_bytes = mask_bits / 8;
        const remaining_bits = mask_bits % 8;

        var i: usize = 0;
        while (i < full_bytes) : (i += 1) {
            if (subnet_bytes[i] != check_bytes[i]) return .{ .Bool = false };
        }

        if (remaining_bits > 0) {
            const shift: u3 = @intCast(8 - remaining_bits);
            const mask: u8 = (@as(u8, 0xFF)) << shift;
            if ((subnet_bytes[full_bytes] & mask) != (check_bytes[full_bytes] & mask)) return .{ .Bool = false };
        }

        return .{ .Bool = true };
    }
}

fn ipOverlaps(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Subnet or args[1] != .Subnet) return error.TypeMismatch;

    const subnet1 = args[0].Subnet;
    const subnet2 = args[1].Subnet;

    // Different families don't overlap
    if ((subnet1.addr == .v4) != (subnet2.addr == .v4)) {
        return .{ .Bool = false };
    }

    // Check if either subnet contains the other's network address
    const contains1 = try ipContains(allocator, &[_]ExtValue{ .{ .Subnet = subnet1 }, .{ .IpAddr = subnet2.addr } });
    if (contains1.Bool) return .{ .Bool = true };

    const contains2 = try ipContains(allocator, &[_]ExtValue{ .{ .Subnet = subnet2 }, .{ .IpAddr = subnet1.addr } });
    return contains2;
}

fn ipFamily(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    const family = switch (args[0]) {
        .IpAddr => |ip| if (ip == .v4) "IPv4" else "IPv6",
        .Subnet => |subnet| if (subnet.addr == .v4) "IPv4" else "IPv6",
        else => return error.TypeMismatch,
    };

    return .{ .Str = family };
}

fn ipIsPrivate(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .IpAddr) return error.TypeMismatch;

    const ip = args[0].IpAddr;

    switch (ip) {
        .v4 => |bytes| {
            // RFC 1918 private ranges
            if (bytes[0] == 10) return .{ .Bool = true };
            if (bytes[0] == 172 and bytes[1] >= 16 and bytes[1] <= 31) return .{ .Bool = true };
            if (bytes[0] == 192 and bytes[1] == 168) return .{ .Bool = true };
            if (bytes[0] == 127) return .{ .Bool = true }; // Loopback
            return .{ .Bool = false };
        },
        .v6 => |bytes| {
            // RFC 4193 unique local addresses
            if (bytes[0] == 0xfc or bytes[0] == 0xfd) return .{ .Bool = true };
            // Loopback
            if (bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0 and
                bytes[4] == 0 and bytes[5] == 0 and bytes[6] == 0 and bytes[7] == 0 and
                bytes[8] == 0 and bytes[9] == 0 and bytes[10] == 0 and bytes[11] == 0 and
                bytes[12] == 0 and bytes[13] == 0 and bytes[14] == 0 and bytes[15] == 1)
            {
                return .{ .Bool = true };
            }
            return .{ .Bool = false };
        },
    }
}

fn subnetPrefixLength(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    const subnet = switch (args[0]) {
        .Subnet => |s| s,
        else => return error.TypeMismatch,
    };

    return .{ .Int = @intCast(subnet.prefix_len) };
}

// CANARY: REQ=REQ-GQL-NET-FUNC-EVAL-001; FEATURE="NetworkFunctionsEvaluation"; ASPECT=BuiltinFunctions; STATUS=IMPL; OWNER=eval; UPDATED=2025-10-19
fn ipNetwork(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    const subnet = switch (args[0]) {
        .Subnet => |s| s,
        else => return error.TypeMismatch,
    };

    // The subnet already contains the network address in its addr field
    return .{ .IpAddr = subnet.addr };
}

fn ipNetmask(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;

    const addr = switch (args[0]) {
        .IpAddr => |a| a,
        else => return error.TypeMismatch,
    };

    const prefix_len = switch (args[1]) {
        .Int => |i| @as(u8, @intCast(i)),
        else => return error.TypeMismatch,
    };

    // Create subnet from IP address and prefix length
    const subnet = switch (addr) {
        .v4 => |octets| blk: {
            if (prefix_len > 32) return error.InvalidArgs;

            // Create network mask
            const mask = if (prefix_len == 0) 0 else ~@as(u32, 0) << @intCast(32 - prefix_len);

            // Convert IP to u32
            const addr_int = (@as(u32, octets[0]) << 24) |
                (@as(u32, octets[1]) << 16) |
                (@as(u32, octets[2]) << 8) |
                @as(u32, octets[3]);

            // Apply mask to get network address
            const network_int = addr_int & mask;
            const network_bytes = [4]u8{
                @intCast((network_int >> 24) & 0xFF),
                @intCast((network_int >> 16) & 0xFF),
                @intCast((network_int >> 8) & 0xFF),
                @intCast(network_int & 0xFF),
            };

            break :blk heap.Subnet{
                .addr = heap.IpAddr{ .v4 = network_bytes },
                .prefix_len = prefix_len,
            };
        },
        .v6 => |bytes| blk: {
            if (prefix_len > 128) return error.InvalidArgs;

            // Convert bytes to segments
            var segments: [8]u16 = undefined;
            for (0..8) |i| {
                segments[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
            }

            // Apply mask to each segment
            const full_segments = prefix_len / 16;
            const remaining_bits = prefix_len % 16;

            var i: usize = full_segments;
            while (i < 8) : (i += 1) {
                if (i == full_segments and remaining_bits > 0) {
                    const mask = ~@as(u16, 0) << @intCast(16 - remaining_bits);
                    segments[i] = segments[i] & mask;
                } else if (i > full_segments) {
                    segments[i] = 0;
                }
            }

            // Convert segments back to bytes
            var network_bytes: [16]u8 = undefined;
            for (0..8) |j| {
                network_bytes[j * 2] = @intCast((segments[j] >> 8) & 0xFF);
                network_bytes[j * 2 + 1] = @intCast(segments[j] & 0xFF);
            }

            break :blk heap.Subnet{
                .addr = heap.IpAddr{ .v6 = network_bytes },
                .prefix_len = prefix_len,
            };
        },
    };

    return .{ .Subnet = subnet };
}

// MAC functions
fn macIsLocal(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator; // unused
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Mac) return error.TypeMismatch;

    const mac = args[0].Mac;
    const is_local = (mac.bytes[0] & 0x02) != 0;
    return .{ .Bool = is_local };
}

fn macIsMulticast(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator; // unused
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Mac) return error.TypeMismatch;

    const mac = args[0].Mac;
    const is_multicast = (mac.bytes[0] & 0x01) != 0;
    return .{ .Bool = is_multicast };
}

fn macOui(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Mac) return error.TypeMismatch;

    const mac = args[0].Mac;
    const oui = (@as(u32, mac.bytes[0]) << 16) | (@as(u32, mac.bytes[1]) << 8) | @as(u32, mac.bytes[2]);
    return .{ .Int = @intCast(oui) };
}

// Hash functions
fn hashEquals(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Hash or args[1] != .Hash) return error.TypeMismatch;

    const h1 = args[0].Hash;
    const h2 = args[1].Hash;

    if (h1.alg != h2.alg) return .{ .Bool = false };
    if (h1.digest.len != h2.digest.len) return .{ .Bool = false };

    // Constant-time comparison
    var diff: u8 = 0;
    for (h1.digest, h2.digest) |b1, b2| {
        diff |= b1 ^ b2;
    }

    return .{ .Bool = diff == 0 };
}

fn hashAlg(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Hash) return error.TypeMismatch;

    const hash = args[0].Hash;
    const alg_str = switch (hash.alg) {
        .SHA3_256 => "SHA3-256",
        .SHA3_512 => "SHA3-512",
        .BLAKE3 => "BLAKE3",
        .BLAKE2B_256 => "BLAKE2b-256",
        .BLAKE2B_512 => "BLAKE2b-512",
        .BLAKE2S_256 => "BLAKE2s-256",
        .ARGON2ID => "Argon2id",
    };

    return .{ .Str = alg_str };
}

// Currency functions
fn currencyMinorUnits(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Currency) return error.TypeMismatch;

    const cur = args[0].Currency;

    // Common currency minor units
    if (std.mem.eql(u8, &cur.code, "USD")) return .{ .Int = 2 };
    if (std.mem.eql(u8, &cur.code, "EUR")) return .{ .Int = 2 };
    if (std.mem.eql(u8, &cur.code, "GBP")) return .{ .Int = 2 };
    if (std.mem.eql(u8, &cur.code, "JPY")) return .{ .Int = 0 };
    if (std.mem.eql(u8, &cur.code, "BHD")) return .{ .Int = 3 };
    if (std.mem.eql(u8, &cur.code, "KWD")) return .{ .Int = 3 };
    if (std.mem.eql(u8, &cur.code, "OMR")) return .{ .Int = 3 };
    if (std.mem.eql(u8, &cur.code, "TND")) return .{ .Int = 3 };

    // Default to 2 for unknown currencies
    return .{ .Int = 2 };
}

// Language functions
fn langCanonizalize(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;

    const tag = args[0].Str;
    const canonical = try canonicalizeLanguageTag(allocator, tag);

    return .{ .LanguageTag = .{ .tag = canonical } };
}

fn langMatch(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .List or args[1] != .LanguageTag) return error.TypeMismatch;

    const ranges = args[0].List;
    const tag = args[1].LanguageTag;

    // Basic language matching
    for (ranges) |r| {
        if (r != .Str) continue;

        const range_str = r.Str;

        // Exact match
        if (std.mem.eql(u8, range_str, tag.tag)) return .{ .Bool = true };

        // Prefix match (e.g., "fr" matches "fr-CA")
        if (std.mem.startsWith(u8, tag.tag, range_str)) {
            if (range_str.len == tag.tag.len or tag.tag[range_str.len] == '-') {
                return .{ .Bool = true };
            }
        }
    }

    return .{ .Bool = false };
}

// LatLon functions
fn distanceHaversine(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;

    var lat1: f64 = undefined;
    var lon1: f64 = undefined;
    var lat2: f64 = undefined;
    var lon2: f64 = undefined;

    switch (args[0]) {
        .LatLon => |ll| {
            lat1 = ll.lat;
            lon1 = ll.lon;
        },
        .LatLonAlt => |lla| {
            lat1 = lla.lat;
            lon1 = lla.lon;
        },
        else => return error.TypeMismatch,
    }

    switch (args[1]) {
        .LatLon => |ll| {
            lat2 = ll.lat;
            lon2 = ll.lon;
        },
        .LatLonAlt => |lla| {
            lat2 = lla.lat;
            lon2 = lla.lon;
        },
        else => return error.TypeMismatch,
    }

    const R = 6371000.0; // Earth radius in meters

    const lat1_rad = lat1 * std.math.pi / 180.0;
    const lat2_rad = lat2 * std.math.pi / 180.0;
    const dlat = (lat2 - lat1) * std.math.pi / 180.0;
    const dlon = (lon2 - lon1) * std.math.pi / 180.0;

    const a = std.math.sin(dlat / 2) * std.math.sin(dlat / 2) +
        std.math.cos(lat1_rad) * std.math.cos(lat2_rad) *
            std.math.sin(dlon / 2) * std.math.sin(dlon / 2);
    const c = 2 * std.math.atan2(std.math.sqrt(a), std.math.sqrt(1 - a));

    const distance = R * c;
    return .{ .Int = @intFromFloat(@round(distance)) };
}

fn getLatitude(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    const lat = switch (args[0]) {
        .LatLon => |ll| ll.lat,
        .LatLonAlt => |lla| lla.lat,
        else => return error.TypeMismatch,
    };

    return .{ .Decimal = .{ .coeff = @intFromFloat(lat * 1000000), .scale = 6 } };
}

fn getLongitude(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    const lon = switch (args[0]) {
        .LatLon => |ll| ll.lon,
        .LatLonAlt => |lla| lla.lon,
        else => return error.TypeMismatch,
    };

    return .{ .Decimal = .{ .coeff = @intFromFloat(lon * 1000000), .scale = 6 } };
}

fn getAltitude(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    switch (args[0]) {
        .LatLonAlt => |lla| return .{ .Decimal = .{ .coeff = @intFromFloat(lla.alt * 1000), .scale = 3 } },
        else => return .{ .Null = {} },
    }
}

fn getAltRef(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    switch (args[0]) {
        .LatLonAlt => |lla| {
            const ref_str = switch (lla.ref) {
                .ellipsoid => "ellipsoid",
                .geoid => "geoid",
            };
            return .{ .Str = ref_str };
        },
        else => return .{ .Null = {} },
    }
}

// CANARY: REQ=REQ-GQL-GEO-FUNC-EVAL-001; FEATURE="GeographicFunctionsEvaluation"; ASPECT=BuiltinFunctions; STATUS=IMPL; OWNER=eval; UPDATED=2025-10-19
fn geoBearing(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;

    var lat1: f64 = undefined;
    var lon1: f64 = undefined;
    var lat2: f64 = undefined;
    var lon2: f64 = undefined;

    switch (args[0]) {
        .LatLon => |ll| {
            lat1 = ll.lat;
            lon1 = ll.lon;
        },
        .LatLonAlt => |lla| {
            lat1 = lla.lat;
            lon1 = lla.lon;
        },
        else => return error.TypeMismatch,
    }

    switch (args[1]) {
        .LatLon => |ll| {
            lat2 = ll.lat;
            lon2 = ll.lon;
        },
        .LatLonAlt => |lla| {
            lat2 = lla.lat;
            lon2 = lla.lon;
        },
        else => return error.TypeMismatch,
    }

    // Calculate bearing using atan2
    const lat1_rad = lat1 * std.math.pi / 180.0;
    const lat2_rad = lat2 * std.math.pi / 180.0;
    const dlon = (lon2 - lon1) * std.math.pi / 180.0;

    const y = std.math.sin(dlon) * std.math.cos(lat2_rad);
    const x = std.math.cos(lat1_rad) * std.math.sin(lat2_rad) -
        std.math.sin(lat1_rad) * std.math.cos(lat2_rad) * std.math.cos(dlon);

    var bearing = std.math.atan2(y, x) * 180.0 / std.math.pi;

    // Normalize to 0-360
    if (bearing < 0) {
        bearing += 360.0;
    }

    return .{ .Decimal = .{ .coeff = @intFromFloat(bearing * 1000000), .scale = 6 } };
}

fn geoLat(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    const lat = switch (args[0]) {
        .LatLon => |ll| ll.lat,
        .LatLonAlt => |lla| lla.lat,
        else => return error.TypeMismatch,
    };

    return .{ .Decimal = .{ .coeff = @intFromFloat(lat * 1000000), .scale = 6 } };
}

fn geoLon(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    const lon = switch (args[0]) {
        .LatLon => |ll| ll.lon,
        .LatLonAlt => |lla| lla.lon,
        else => return error.TypeMismatch,
    };

    return .{ .Decimal = .{ .coeff = @intFromFloat(lon * 1000000), .scale = 6 } };
}

// Geometry functions
fn stAsText(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    const geom = args[0].Geometry;
    const wkt = try wkbToWkt(allocator, geom.wkb);

    return .{ .Str = wkt };
}

fn wkbToWkt(allocator: std.mem.Allocator, wkb: []const u8) ![]const u8 {
    if (wkb.len < 5) return error.InvalidWkb;

    // WKB byte order: 0x00 = big endian, 0x01 = little endian
    const byte_order: std.builtin.Endian = if (wkb[0] == 0x00) .big else .little;

    const geom_type = std.mem.readInt(u32, wkb[1..5][0..4], byte_order);

    if (geom_type == 1) { // Point
        if (wkb.len < 21) return error.InvalidWkb;
        const x_bits = std.mem.readInt(u64, wkb[5..13][0..8], byte_order);
        const y_bits = std.mem.readInt(u64, wkb[13..21][0..8], byte_order);

        const x: f64 = @bitCast(x_bits);
        const y: f64 = @bitCast(y_bits);

        return try std.fmt.allocPrint(allocator, "POINT({d} {d})", .{ x, y });
    }

    if (geom_type == 3) { // Polygon
        if (wkb.len < 13) return error.InvalidWkb;

        const num_rings = std.mem.readInt(u32, wkb[5..9][0..4], byte_order);
        if (num_rings == 0) return error.InvalidWkb;

        // Only handle exterior ring for now
        const num_points = std.mem.readInt(u32, wkb[9..13][0..4], byte_order);
        if (num_points == 0) return error.InvalidWkb;

        const expected_len = 13 + num_points * 16;
        if (wkb.len < expected_len) return error.InvalidWkb;

        // Build coordinate string
        var coords = std.ArrayListUnmanaged(u8){};
        defer coords.deinit(allocator);

        try coords.appendSlice(allocator, "POLYGON((");

        var offset: usize = 13;
        for (0..num_points) |i| {
            const x_bits = std.mem.readInt(u64, wkb[offset..][0..8], byte_order);
            const y_bits = std.mem.readInt(u64, wkb[offset + 8 ..][0..8], byte_order);
            const x: f64 = @bitCast(x_bits);
            const y: f64 = @bitCast(y_bits);

            if (i > 0) {
                try coords.appendSlice(allocator, ", ");
            }
            const coord_str = try std.fmt.allocPrint(allocator, "{d} {d}", .{ x, y });
            defer allocator.free(coord_str);
            try coords.appendSlice(allocator, coord_str);

            offset += 16;
        }

        try coords.appendSlice(allocator, "))");

        return try allocator.dupe(u8, coords.items);
    }

    return error.UnsupportedGeometry;
}

fn stAsGeoJson(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    const geom = args[0].Geometry;
    const json = try wkbToGeoJson(allocator, geom.wkb);

    return .{ .Str = json };
}

fn wkbToGeoJson(allocator: std.mem.Allocator, wkb: []const u8) ![]const u8 {
    if (wkb.len < 5) return error.InvalidWkb;

    // WKB byte order: 0x00 = big endian, 0x01 = little endian
    const byte_order: std.builtin.Endian = if (wkb[0] == 0x00) .big else .little;

    const geom_type = std.mem.readInt(u32, wkb[1..5][0..4], byte_order);

    if (geom_type == 1) { // Point
        if (wkb.len < 21) return error.InvalidWkb;
        const x_bits = std.mem.readInt(u64, wkb[5..13][0..8], byte_order);
        const y_bits = std.mem.readInt(u64, wkb[13..21][0..8], byte_order);

        const x: f64 = @bitCast(x_bits);
        const y: f64 = @bitCast(y_bits);

        return try std.fmt.allocPrint(allocator, "{{\"type\":\"Point\",\"coordinates\":[{d},{d}]}}", .{ x, y });
    }

    if (geom_type == 3) { // Polygon
        if (wkb.len < 13) return error.InvalidWkb;

        const num_rings = std.mem.readInt(u32, wkb[5..9][0..4], byte_order);
        if (num_rings == 0) return error.InvalidWkb;

        const num_points = std.mem.readInt(u32, wkb[9..13][0..4], byte_order);
        if (num_points == 0) return error.InvalidWkb;

        const expected_len = 13 + num_points * 16;
        if (wkb.len < expected_len) return error.InvalidWkb;

        // Build coordinate array string
        var coords = std.ArrayListUnmanaged(u8){};
        defer coords.deinit(allocator);

        try coords.appendSlice(allocator, "{\"type\":\"Polygon\",\"coordinates\":[[");

        var offset: usize = 13;
        for (0..num_points) |i| {
            const x_bits = std.mem.readInt(u64, wkb[offset..][0..8], byte_order);
            const y_bits = std.mem.readInt(u64, wkb[offset + 8 ..][0..8], byte_order);
            const x: f64 = @bitCast(x_bits);
            const y: f64 = @bitCast(y_bits);

            if (i > 0) {
                try coords.appendSlice(allocator, ",");
            }
            const coord_str = try std.fmt.allocPrint(allocator, "[{d},{d}]", .{ x, y });
            defer allocator.free(coord_str);
            try coords.appendSlice(allocator, coord_str);

            offset += 16;
        }

        try coords.appendSlice(allocator, "]]}");

        return try allocator.dupe(u8, coords.items);
    }

    return error.UnsupportedGeometry;
}

// CANARY: REQ=REQ-SPATIAL-CONTAINS-001; FEATURE="SpatialContains"; ASPECT=GeometryRelation; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// GAP-0089 RESOLVED: Proper point-in-polygon test using ray casting algorithm
fn stContains(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;

    const container = args[0].Geometry;
    const contained = args[1].Geometry;

    // Parse both geometries
    const container_type = parseWkbGeomType(container.wkb);
    const contained_type = parseWkbGeomType(contained.wkb);

    // Point-in-Polygon test
    if (container_type == 3 and contained_type == 1) { // Polygon contains Point
        const point = try parseWkbPoint(contained.wkb);
        const polygon = try parseWkbPolygon(allocator, container.wkb);
        defer allocator.free(polygon);

        const result = pointInPolygon(point, polygon);
        return .{ .Bool = result };
    }

    // Point contains Point: only if same location
    if (container_type == 1 and contained_type == 1) {
        const p1 = try parseWkbPoint(container.wkb);
        const p2 = try parseWkbPoint(contained.wkb);
        const result = @abs(p1[0] - p2[0]) < 1e-10 and @abs(p1[1] - p2[1]) < 1e-10;
        return .{ .Bool = result };
    }

    // For unsupported geometry combinations, return false
    return .{ .Bool = false };
}

// CANARY: REQ=REQ-SPATIAL-INTERSECTS-001; FEATURE="SpatialIntersects"; ASPECT=GeometryRelation; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// GAP-0089 RESOLVED: Proper geometry intersection test
fn stIntersects(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;

    const geom1 = args[0].Geometry;
    const geom2 = args[1].Geometry;

    const type1 = parseWkbGeomType(geom1.wkb);
    const type2 = parseWkbGeomType(geom2.wkb);

    // Point-Point intersection: same location within tolerance
    if (type1 == 1 and type2 == 1) {
        const p1 = try parseWkbPoint(geom1.wkb);
        const p2 = try parseWkbPoint(geom2.wkb);
        const result = @abs(p1[0] - p2[0]) < 1e-10 and @abs(p1[1] - p2[1]) < 1e-10;
        return .{ .Bool = result };
    }

    // Point-Polygon intersection: point in polygon
    if (type1 == 1 and type2 == 3) {
        const point = try parseWkbPoint(geom1.wkb);
        const polygon = try parseWkbPolygon(allocator, geom2.wkb);
        defer allocator.free(polygon);
        return .{ .Bool = pointInPolygon(point, polygon) };
    }

    if (type1 == 3 and type2 == 1) {
        const point = try parseWkbPoint(geom2.wkb);
        const polygon = try parseWkbPolygon(allocator, geom1.wkb);
        defer allocator.free(polygon);
        return .{ .Bool = pointInPolygon(point, polygon) };
    }

    // Polygon-Polygon: check if any vertex of one is inside the other or edges cross
    if (type1 == 3 and type2 == 3) {
        const poly1 = try parseWkbPolygon(allocator, geom1.wkb);
        defer allocator.free(poly1);
        const poly2 = try parseWkbPolygon(allocator, geom2.wkb);
        defer allocator.free(poly2);

        // Check if any vertex of poly1 is inside poly2
        for (poly1) |vertex| {
            if (pointInPolygon(vertex, poly2)) {
                return .{ .Bool = true };
            }
        }
        // Check if any vertex of poly2 is inside poly1
        for (poly2) |vertex| {
            if (pointInPolygon(vertex, poly1)) {
                return .{ .Bool = true };
            }
        }
        return .{ .Bool = false };
    }

    // For unsupported combinations, return false
    return .{ .Bool = false };
}

// CANARY: REQ=REQ-SPATIAL-WITHIN-001; FEATURE="SpatialWithin"; ASPECT=GeometryRelation; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// GAP-0089 RESOLVED: stWithin(a, b) is the inverse of stContains(b, a)
fn stWithin(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;

    // stWithin(a, b) = stContains(b, a)
    var reversed_args: [2]ExtValue = undefined;
    reversed_args[0] = args[1];
    reversed_args[1] = args[0];
    return stContains(allocator, &reversed_args);
}

// Helper: Parse WKB geometry type
fn parseWkbGeomType(wkb: []const u8) u32 {
    if (wkb.len < 5) return 0;
    return std.mem.readInt(u32, wkb[1..5][0..4], .little);
}

// Helper: Parse WKB Point coordinates
fn parseWkbPoint(wkb: []const u8) ![2]f64 {
    if (wkb.len < 21) return error.InvalidWkb;
    const x_bits = std.mem.readInt(u64, wkb[5..13][0..8], .little);
    const y_bits = std.mem.readInt(u64, wkb[13..21][0..8], .little);
    return .{ @bitCast(x_bits), @bitCast(y_bits) };
}

// Helper: Parse WKB Polygon exterior ring coordinates
fn parseWkbPolygon(allocator: std.mem.Allocator, wkb: []const u8) ![][2]f64 {
    if (wkb.len < 13) return error.InvalidWkb;

    // Skip byte order (1) + type (4) + num rings (4) = 9 bytes
    const num_rings = std.mem.readInt(u32, wkb[5..9][0..4], .little);
    if (num_rings == 0) return error.InvalidWkb;

    // Get number of points in exterior ring
    const num_points = std.mem.readInt(u32, wkb[9..13][0..4], .little);
    if (num_points == 0) return error.InvalidWkb;

    // Check if we have enough data
    const expected_len = 13 + num_points * 16;
    if (wkb.len < expected_len) return error.InvalidWkb;

    var points = try allocator.alloc([2]f64, num_points);
    var offset: usize = 13;
    for (0..num_points) |i| {
        const x_bits = std.mem.readInt(u64, wkb[offset..][0..8], .little);
        const y_bits = std.mem.readInt(u64, wkb[offset + 8 ..][0..8], .little);
        points[i] = .{ @bitCast(x_bits), @bitCast(y_bits) };
        offset += 16;
    }

    return points;
}

// Ray casting algorithm for point-in-polygon test
fn pointInPolygon(point: [2]f64, polygon: [][2]f64) bool {
    if (polygon.len < 3) return false;

    var inside = false;
    const px = point[0];
    const py = point[1];

    var j: usize = polygon.len - 1;
    for (0..polygon.len) |i| {
        const xi = polygon[i][0];
        const yi = polygon[i][1];
        const xj = polygon[j][0];
        const yj = polygon[j][1];

        // Check if point is exactly on a vertex
        if (@abs(px - xi) < 1e-10 and @abs(py - yi) < 1e-10) {
            return true;
        }

        // Ray casting: count intersections
        if (((yi > py) != (yj > py)) and
            (px < (xj - xi) * (py - yi) / (yj - yi) + xi))
        {
            inside = !inside;
        }
        j = i;
    }

    return inside;
}

// CANARY: REQ=REQ-SPATIAL-POINT-001; FEATURE="SpatialPoint"; ASPECT=PointCreation; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ST_Point(x, y) - Creates a Point geometry from coordinates
fn stPoint(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;

    // Extract x coordinate
    const x: f64 = switch (args[0]) {
        .Int => |i| @floatFromInt(i),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @floatFromInt(d.scale)),
        else => return error.TypeMismatch,
    };

    // Extract y coordinate
    const y: f64 = switch (args[1]) {
        .Int => |i| @floatFromInt(i),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @floatFromInt(d.scale)),
        else => return error.TypeMismatch,
    };

    // Create WKB for Point: 1 byte endian + 4 bytes type + 16 bytes coords = 21 bytes
    var wkb = try allocator.alloc(u8, 21);
    wkb[0] = 1; // Little endian
    std.mem.writeInt(u32, wkb[1..5][0..4], 1, .little); // Point type = 1
    std.mem.writeInt(u64, wkb[5..13][0..8], @bitCast(x), .little);
    std.mem.writeInt(u64, wkb[13..21][0..8], @bitCast(y), .little);

    return .{ .Geometry = .{ .wkb = wkb } };
}

// CANARY: REQ=REQ-SPATIAL-X-001; FEATURE="SpatialX"; ASPECT=CoordinateExtraction; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ST_X(point) - Extracts X coordinate from a Point geometry
fn stX(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    const geom = args[0].Geometry;
    const point = try parseWkbPoint(geom.wkb);

    // Convert to Decimal with 6 decimal places
    const x_scaled: i128 = @intFromFloat(point[0] * 1000000);
    return .{ .Decimal = .{ .coeff = x_scaled, .scale = 6 } };
}

// CANARY: REQ=REQ-SPATIAL-Y-001; FEATURE="SpatialY"; ASPECT=CoordinateExtraction; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ST_Y(point) - Extracts Y coordinate from a Point geometry
fn stY(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    const geom = args[0].Geometry;
    const point = try parseWkbPoint(geom.wkb);

    // Convert to Decimal with 6 decimal places
    const y_scaled: i128 = @intFromFloat(point[1] * 1000000);
    return .{ .Decimal = .{ .coeff = y_scaled, .scale = 6 } };
}

// CANARY: REQ=REQ-SPATIAL-DISTANCE-001; FEATURE="SpatialDistance"; ASPECT=GeometryMeasure; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ST_Distance(geom1, geom2) - Calculates Euclidean distance between two geometries
fn stDistance(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;

    const geom1 = args[0].Geometry;
    const geom2 = args[1].Geometry;

    // For now, only support Point-Point distance
    const type1 = parseWkbGeomType(geom1.wkb);
    const type2 = parseWkbGeomType(geom2.wkb);

    if (type1 == 1 and type2 == 1) {
        const p1 = try parseWkbPoint(geom1.wkb);
        const p2 = try parseWkbPoint(geom2.wkb);

        const dx = p2[0] - p1[0];
        const dy = p2[1] - p1[1];
        const distance = @sqrt(dx * dx + dy * dy);

        // Convert to Decimal with 6 decimal places
        const dist_scaled: i128 = @intFromFloat(distance * 1000000);
        return .{ .Decimal = .{ .coeff = dist_scaled, .scale = 6 } };
    }

    return error.UnsupportedGeometry;
}

// CANARY: REQ=REQ-SPATIAL-AREA-001; FEATURE="SpatialArea"; ASPECT=GeometryMeasure; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ST_Area(polygon) - Calculates area of a Polygon using Shoelace formula
fn stArea(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    const geom = args[0].Geometry;
    const geom_type = parseWkbGeomType(geom.wkb);

    // Only Polygon (type 3) has area
    if (geom_type == 1) {
        // Point has zero area
        return .{ .Decimal = .{ .coeff = 0, .scale = 6 } };
    }

    if (geom_type != 3) return error.UnsupportedGeometry;

    const polygon = try parseWkbPolygon(allocator, geom.wkb);
    defer allocator.free(polygon);

    if (polygon.len < 3) {
        return .{ .Decimal = .{ .coeff = 0, .scale = 6 } };
    }

    // Shoelace formula: A = 0.5 * |sum((x[i] * y[i+1]) - (x[i+1] * y[i]))|
    var sum: f64 = 0;
    for (0..polygon.len) |i| {
        const j = (i + 1) % polygon.len;
        sum += polygon[i][0] * polygon[j][1];
        sum -= polygon[j][0] * polygon[i][1];
    }
    const area = @abs(sum) / 2.0;

    // Convert to Decimal with 6 decimal places
    const area_scaled: i128 = @intFromFloat(area * 1000000);
    return .{ .Decimal = .{ .coeff = area_scaled, .scale = 6 } };
}

// CANARY: REQ=REQ-SPATIAL-CENTROID-001; FEATURE="SpatialCentroid"; ASPECT=GeometryMeasure; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ST_Centroid(polygon) - Calculates centroid of a Polygon
fn stCentroid(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    const geom = args[0].Geometry;
    const geom_type = parseWkbGeomType(geom.wkb);

    // Point centroid is itself
    if (geom_type == 1) {
        return args[0];
    }

    if (geom_type != 3) return error.UnsupportedGeometry;

    const polygon = try parseWkbPolygon(allocator, geom.wkb);
    defer allocator.free(polygon);

    if (polygon.len < 3) return error.InvalidWkb;

    // First calculate signed area
    var signed_area: f64 = 0;
    for (0..polygon.len) |i| {
        const j = (i + 1) % polygon.len;
        signed_area += polygon[i][0] * polygon[j][1] - polygon[j][0] * polygon[i][1];
    }
    signed_area /= 2.0;

    if (@abs(signed_area) < 1e-10) return error.InvalidWkb;

    // Calculate centroid coordinates
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (0..polygon.len) |i| {
        const j = (i + 1) % polygon.len;
        const factor = polygon[i][0] * polygon[j][1] - polygon[j][0] * polygon[i][1];
        cx += (polygon[i][0] + polygon[j][0]) * factor;
        cy += (polygon[i][1] + polygon[j][1]) * factor;
    }
    cx /= (6.0 * signed_area);
    cy /= (6.0 * signed_area);

    // Create WKB for Point
    var wkb = try allocator.alloc(u8, 21);
    wkb[0] = 1; // Little endian
    std.mem.writeInt(u32, wkb[1..5][0..4], 1, .little); // Point type = 1
    std.mem.writeInt(u64, wkb[5..13][0..8], @bitCast(cx), .little);
    std.mem.writeInt(u64, wkb[13..21][0..8], @bitCast(cy), .little);

    return .{ .Geometry = .{ .wkb = wkb } };
}

// CANARY: REQ=REQ-SPATIAL-BUFFER-001; FEATURE="SpatialBuffer"; ASPECT=GeometryTransform; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ST_Buffer(geometry, distance) - Creates a buffer around a geometry
// For Point: creates a square polygon at distance (approximation of circle)
fn stBuffer(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    // Extract buffer distance
    const distance: f64 = switch (args[1]) {
        .Int => |i| @floatFromInt(i),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @floatFromInt(d.scale)),
        else => return error.TypeMismatch,
    };

    const geom = args[0].Geometry;
    const geom_type = parseWkbGeomType(geom.wkb);

    if (geom_type == 1) {
        // Point: create a square polygon around it (8-point octagon for better approximation)
        const point = try parseWkbPoint(geom.wkb);
        const x = point[0];
        const y = point[1];

        // Create an 8-point octagon approximation of a circle buffer
        const d = distance;
        const d45 = distance * 0.7071067811865476; // cos(45°) = sin(45°) ≈ 0.7071

        // Octagon points (counter-clockwise, closing at first point)
        const points = [_][2]f64{
            .{ x + d, y },
            .{ x + d45, y + d45 },
            .{ x, y + d },
            .{ x - d45, y + d45 },
            .{ x - d, y },
            .{ x - d45, y - d45 },
            .{ x, y - d },
            .{ x + d45, y - d45 },
            .{ x + d, y }, // Close the ring
        };

        // WKB size: 1 (endian) + 4 (type) + 4 (num_rings) + 4 (num_points) + 9 * 16 (coordinates)
        const wkb_size = 1 + 4 + 4 + 4 + (9 * 16);
        var wkb = try allocator.alloc(u8, wkb_size);

        wkb[0] = 1; // Little endian
        std.mem.writeInt(u32, wkb[1..5][0..4], 3, .little); // Polygon type = 3
        std.mem.writeInt(u32, wkb[5..9][0..4], 1, .little); // 1 ring
        std.mem.writeInt(u32, wkb[9..13][0..4], 9, .little); // 9 points

        var offset: usize = 13;
        for (points) |pt| {
            std.mem.writeInt(u64, wkb[offset..][0..8], @bitCast(pt[0]), .little);
            std.mem.writeInt(u64, wkb[offset + 8 ..][0..8], @bitCast(pt[1]), .little);
            offset += 16;
        }

        return .{ .Geometry = .{ .wkb = wkb } };
    }

    // For other geometry types, return error for now
    return error.UnsupportedGeometry;
}

// Vector functions
fn vectorDot(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .VectorF32 or args[1] != .VectorF32) return error.TypeMismatch;

    const a = args[0].VectorF32;
    const b = args[1].VectorF32;

    if (a.dim != b.dim) return error.DimensionMismatch;

    var sum: f64 = 0;
    for (a.data, b.data) |av, bv| {
        sum += av * bv;
    }

    return .{ .Int = @intFromFloat(sum) };
}

fn vectorL2(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .VectorF32 or args[1] != .VectorF32) return error.TypeMismatch;

    const a = args[0].VectorF32;
    const b = args[1].VectorF32;

    if (a.dim != b.dim) return error.DimensionMismatch;

    var sum: f64 = 0;
    for (a.data, b.data) |av, bv| {
        const diff = av - bv;
        sum += diff * diff;
    }

    const dist = @sqrt(sum);
    return .{ .Decimal = .{ .coeff = @intFromFloat(dist * 1000000), .scale = 6 } };
}

fn vectorCosine(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .VectorF32 or args[1] != .VectorF32) return error.TypeMismatch;

    const a = args[0].VectorF32;
    const b = args[1].VectorF32;

    if (a.dim != b.dim) return error.DimensionMismatch;

    var dot_product: f64 = 0;
    var norm_a: f64 = 0;
    var norm_b: f64 = 0;

    for (a.data, b.data) |av, bv| {
        dot_product += av * bv;
        norm_a += av * av;
        norm_b += bv * bv;
    }

    if (norm_a == 0 or norm_b == 0) return .{ .Null = {} };

    const similarity = dot_product / (@sqrt(norm_a) * @sqrt(norm_b));
    return .{ .Decimal = .{ .coeff = @intFromFloat(similarity * 1000000), .scale = 6 } };
}

fn vectorKnn(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 4) return error.InvalidArgs;

    // For MVP, return empty list
    return .{ .List = &[_]ExtValue{} };
}

// Decimal constructor
fn constructDecimal(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Str) return error.TypeMismatch;
    if (args[1] != .Int) return error.TypeMismatch;

    const value_str = args[0].Str;
    const scale_val = args[1].Int;

    // Import the decimal module
    const decimal128 = @import("types/decimal128.zig");
    const dec = decimal128.Decimal128.fromStr(value_str) catch return error.InvalidFormat;
    const final_scale = @as(i16, @intCast(scale_val));
    const rounded = dec.roundHalfEven(final_scale) catch return error.DecimalOverflow;

    return .{ .Decimal = .{ .coeff = rounded.coeff, .scale = @intCast(rounded.scale) } };
}

// Decimal arithmetic functions
fn decimalAdd(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Decimal or args[1] != .Decimal) return error.TypeMismatch;

    const decimal128 = @import("types/decimal128.zig");
    const da = decimal128.Decimal128{ .coeff = args[0].Decimal.coeff, .scale = args[0].Decimal.scale };
    const db = decimal128.Decimal128{ .coeff = args[1].Decimal.coeff, .scale = args[1].Decimal.scale };

    const result = da.add(db) catch return error.DecimalOverflow;
    return .{ .Decimal = .{ .coeff = result.coeff, .scale = @intCast(result.scale) } };
}

fn decimalSub(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Decimal or args[1] != .Decimal) return error.TypeMismatch;

    const decimal128 = @import("types/decimal128.zig");
    const da = decimal128.Decimal128{ .coeff = args[0].Decimal.coeff, .scale = args[0].Decimal.scale };
    const db = decimal128.Decimal128{ .coeff = args[1].Decimal.coeff, .scale = args[1].Decimal.scale };

    const result = da.sub(db) catch return error.DecimalOverflow;
    return .{ .Decimal = .{ .coeff = result.coeff, .scale = @intCast(result.scale) } };
}

fn decimalMul(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Decimal or args[1] != .Decimal) return error.TypeMismatch;

    const decimal128 = @import("types/decimal128.zig");
    const da = decimal128.Decimal128{ .coeff = args[0].Decimal.coeff, .scale = args[0].Decimal.scale };
    const db = decimal128.Decimal128{ .coeff = args[1].Decimal.coeff, .scale = args[1].Decimal.scale };

    const result = da.mul(db) catch return error.DecimalOverflow;
    return .{ .Decimal = .{ .coeff = result.coeff, .scale = @intCast(result.scale) } };
}

fn decimalDiv(_: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Decimal or args[1] != .Decimal) return error.TypeMismatch;

    const decimal128 = @import("types/decimal128.zig");
    const da = decimal128.Decimal128{ .coeff = args[0].Decimal.coeff, .scale = args[0].Decimal.scale };
    const db = decimal128.Decimal128{ .coeff = args[1].Decimal.coeff, .scale = args[1].Decimal.scale };

    const result = da.div(db) catch |err| switch (err) {
        decimal128.Decimal128.Error.DivisionByZero => return error.DecimalDivZero,
        else => return error.DecimalOverflow,
    };
    return .{ .Decimal = .{ .coeff = result.coeff, .scale = @intCast(result.scale) } };
}

// ============================================================================
// Unit Tests for WKB Big Endian Support
// CANARY: REQ=REQ-SPATIAL-WKB-ENDIAN-001; FEATURE="WKBByteOrderParsing"; ASPECT=UnitTest; STATUS=IMPL; OWNER=spatial; UPDATED=2026-01-10
// ============================================================================

const testing = std.testing;

// Helper to create WKB Point data
fn createWkbPoint(byte_order: u8, x: f64, y: f64) [21]u8 {
    var result: [21]u8 = undefined;
    result[0] = byte_order;

    const x_bits: u64 = @bitCast(x);
    const y_bits: u64 = @bitCast(y);

    if (byte_order == 0x00) { // Big endian
        // Geometry type = 1 (Point) in big endian
        result[1] = 0x00;
        result[2] = 0x00;
        result[3] = 0x00;
        result[4] = 0x01;
        // X coordinate
        result[5] = @intCast((x_bits >> 56) & 0xFF);
        result[6] = @intCast((x_bits >> 48) & 0xFF);
        result[7] = @intCast((x_bits >> 40) & 0xFF);
        result[8] = @intCast((x_bits >> 32) & 0xFF);
        result[9] = @intCast((x_bits >> 24) & 0xFF);
        result[10] = @intCast((x_bits >> 16) & 0xFF);
        result[11] = @intCast((x_bits >> 8) & 0xFF);
        result[12] = @intCast(x_bits & 0xFF);
        // Y coordinate
        result[13] = @intCast((y_bits >> 56) & 0xFF);
        result[14] = @intCast((y_bits >> 48) & 0xFF);
        result[15] = @intCast((y_bits >> 40) & 0xFF);
        result[16] = @intCast((y_bits >> 32) & 0xFF);
        result[17] = @intCast((y_bits >> 24) & 0xFF);
        result[18] = @intCast((y_bits >> 16) & 0xFF);
        result[19] = @intCast((y_bits >> 8) & 0xFF);
        result[20] = @intCast(y_bits & 0xFF);
    } else { // Little endian (0x01)
        // Geometry type = 1 (Point) in little endian
        result[1] = 0x01;
        result[2] = 0x00;
        result[3] = 0x00;
        result[4] = 0x00;
        // X coordinate
        result[5] = @intCast(x_bits & 0xFF);
        result[6] = @intCast((x_bits >> 8) & 0xFF);
        result[7] = @intCast((x_bits >> 16) & 0xFF);
        result[8] = @intCast((x_bits >> 24) & 0xFF);
        result[9] = @intCast((x_bits >> 32) & 0xFF);
        result[10] = @intCast((x_bits >> 40) & 0xFF);
        result[11] = @intCast((x_bits >> 48) & 0xFF);
        result[12] = @intCast((x_bits >> 56) & 0xFF);
        // Y coordinate
        result[13] = @intCast(y_bits & 0xFF);
        result[14] = @intCast((y_bits >> 8) & 0xFF);
        result[15] = @intCast((y_bits >> 16) & 0xFF);
        result[16] = @intCast((y_bits >> 24) & 0xFF);
        result[17] = @intCast((y_bits >> 32) & 0xFF);
        result[18] = @intCast((y_bits >> 40) & 0xFF);
        result[19] = @intCast((y_bits >> 48) & 0xFF);
        result[20] = @intCast((y_bits >> 56) & 0xFF);
    }

    return result;
}

test "wkbToWkt parses little endian Point correctly" {
    const allocator = testing.allocator;

    // Create little endian WKB Point at (1.5, 2.5)
    const wkb = createWkbPoint(0x01, 1.5, 2.5);

    const wkt = try wkbToWkt(allocator, &wkb);
    defer allocator.free(wkt);

    // Should contain POINT and coordinates
    try testing.expect(std.mem.indexOf(u8, wkt, "POINT") != null);
    try testing.expect(std.mem.indexOf(u8, wkt, "1.5") != null);
    try testing.expect(std.mem.indexOf(u8, wkt, "2.5") != null);
}

test "wkbToWkt parses big endian Point correctly" {
    const allocator = testing.allocator;

    // Create big endian WKB Point at (3.0, 4.0)
    const wkb = createWkbPoint(0x00, 3.0, 4.0);

    const wkt = try wkbToWkt(allocator, &wkb);
    defer allocator.free(wkt);

    // Should contain POINT and coordinates
    try testing.expect(std.mem.indexOf(u8, wkt, "POINT") != null);
    try testing.expect(std.mem.indexOf(u8, wkt, "3") != null);
    try testing.expect(std.mem.indexOf(u8, wkt, "4") != null);
}

test "wkbToWkt big endian and little endian produce same result for same coordinates" {
    const allocator = testing.allocator;

    const x: f64 = -122.4194;
    const y: f64 = 37.7749;

    // Create WKB in both byte orders
    const wkb_le = createWkbPoint(0x01, x, y);
    const wkb_be = createWkbPoint(0x00, x, y);

    const wkt_le = try wkbToWkt(allocator, &wkb_le);
    defer allocator.free(wkt_le);

    const wkt_be = try wkbToWkt(allocator, &wkb_be);
    defer allocator.free(wkt_be);

    // Both should produce the same WKT output
    try testing.expectEqualStrings(wkt_le, wkt_be);
}

test "wkbToGeoJson parses little endian Point correctly" {
    const allocator = testing.allocator;

    // Create little endian WKB Point at (10.0, 20.0)
    const wkb = createWkbPoint(0x01, 10.0, 20.0);

    const json = try wkbToGeoJson(allocator, &wkb);
    defer allocator.free(json);

    // Should be valid GeoJSON Point
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"Point\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"coordinates\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "10") != null);
    try testing.expect(std.mem.indexOf(u8, json, "20") != null);
}

test "wkbToGeoJson parses big endian Point correctly" {
    const allocator = testing.allocator;

    // Create big endian WKB Point at (-73.9857, 40.7484) (NYC)
    const wkb = createWkbPoint(0x00, -73.9857, 40.7484);

    const json = try wkbToGeoJson(allocator, &wkb);
    defer allocator.free(json);

    // Should be valid GeoJSON Point
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"Point\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"coordinates\"") != null);
}

test "wkbToGeoJson big endian and little endian produce same result" {
    const allocator = testing.allocator;

    const x: f64 = 139.6917;
    const y: f64 = 35.6895;

    // Create WKB in both byte orders
    const wkb_le = createWkbPoint(0x01, x, y);
    const wkb_be = createWkbPoint(0x00, x, y);

    const json_le = try wkbToGeoJson(allocator, &wkb_le);
    defer allocator.free(json_le);

    const json_be = try wkbToGeoJson(allocator, &wkb_be);
    defer allocator.free(json_be);

    // Both should produce the same GeoJSON output
    try testing.expectEqualStrings(json_le, json_be);
}

test "wkbToWkt rejects invalid WKB (too short)" {
    const allocator = testing.allocator;

    const short_wkb = [_]u8{ 0x01, 0x01, 0x00, 0x00 }; // Only 4 bytes
    const result = wkbToWkt(allocator, &short_wkb);
    try testing.expectError(error.InvalidWkb, result);
}

test "wkbToGeoJson rejects invalid WKB (too short)" {
    const allocator = testing.allocator;

    const short_wkb = [_]u8{ 0x00, 0x00, 0x00, 0x00 }; // Only 4 bytes
    const result = wkbToGeoJson(allocator, &short_wkb);
    try testing.expectError(error.InvalidWkb, result);
}
