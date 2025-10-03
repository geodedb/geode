const std = @import("std");
const ast = @import("gql/ast.zig");
const heap = @import("storage/heap.zig");
const patricia = @import("index/patricia.zig");
const rtree = @import("index/rtree.zig");
const hnsw = @import("index/hnsw.zig");
const extf = @import("types/extended_functions.zig");
const network = @import("types/network.zig");

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

    // IP/CIDR functions
    try registry.put("ip_contains", &ipContains);
    try registry.put("ip_overlaps", &ipOverlaps);
    try registry.put("ip_family", &ipFamily);
    try registry.put("ip_is_private", &ipIsPrivate);

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

    // Geometry functions
    try registry.put("st_astext", &stAsText);
    try registry.put("st_asgeojson", &stAsGeoJson);
    try registry.put("st_contains", &stContains);
    try registry.put("st_intersects", &stIntersects);
    try registry.put("st_within", &stWithin);

    // Vector functions
    try registry.put("vector_dot", &vectorDot);
    try registry.put("vector_l2", &vectorL2);
    try registry.put("vector_cosine", &vectorCosine);
    try registry.put("vector_knn", &vectorKnn);

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
    if (args.len != 4) return error.InvalidArgs;

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

    if (args[3] != .Str) return error.TypeMismatch;

    const ref: heap.AltRef = if (std.mem.eql(u8, args[3].Str, "ellipsoid"))
        .ellipsoid
    else if (std.mem.eql(u8, args[3].Str, "geoid"))
        .geoid
    else
        return error.InvalidAltRef;

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

    // TODO: Support more geometry types
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

    if (args[1] != .Str) return error.TypeMismatch;

    const unit_str = args[1].Str;
    var unit_in: heap.TempUnit = undefined;
    var value_K: f64 = undefined;

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

    if (args[1] != .Str) return error.TypeMismatch;

    const unit_str = args[1].Str;
    var unit_in: heap.PressureUnit = undefined;
    var value_Pa: f64 = undefined;

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
    if (args[0] != .Str) return error.TypeMismatch;

    const text = args[0].Str;
    
    // Use the evaluator_functions implementation
    const eval_funcs = @import("types/evaluator_functions.zig");
    const result = eval_funcs.VectorF32(allocator, text) catch return error.InvalidFormat;
    
    return .{ .VectorF32 = result.VectorF32 };
}


// IP/CIDR functions
fn ipContains(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Subnet) return error.TypeMismatch;

    const subnet = args[0].Subnet;

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
    for (ranges) |range| {
        if (range != .Str) continue;

        const range_str = range.Str;

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

// Geometry functions
fn stAsText(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    if (args.len != 1) return error.InvalidArgs;
    if (args[0] != .Geometry) return error.TypeMismatch;

    const geom = args[0].Geometry;
    const wkt = try wkbToWkt(allocator, geom.wkb);

    return .{ .Str = wkt };
}

fn wkbToWkt(allocator: std.mem.Allocator, wkb: []const u8) ![]const u8 {
    if (wkb.len < 21) return error.InvalidWkb;

    const endian = wkb[0];
    _ = endian; // TODO: Handle big endian

    const geom_type = std.mem.readInt(u32, wkb[1..5][0..4], .little);

    if (geom_type == 1) { // Point
        const x_bits = std.mem.readInt(u64, wkb[5..13][0..8], .little);
        const y_bits = std.mem.readInt(u64, wkb[13..21][0..8], .little);

        const x: f64 = @bitCast(x_bits);
        const y: f64 = @bitCast(y_bits);

        return try std.fmt.allocPrint(allocator, "POINT({d} {d})", .{ x, y });
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
    if (wkb.len < 21) return error.InvalidWkb;

    const endian = wkb[0];
    _ = endian; // TODO: Handle big endian

    const geom_type = std.mem.readInt(u32, wkb[1..5][0..4], .little);

    if (geom_type == 1) { // Point
        const x_bits = std.mem.readInt(u64, wkb[5..13][0..8], .little);
        const y_bits = std.mem.readInt(u64, wkb[13..21][0..8], .little);

        const x: f64 = @bitCast(x_bits);
        const y: f64 = @bitCast(y_bits);

        return try std.fmt.allocPrint(allocator, "{{\"type\":\"Point\",\"coordinates\":[{d},{d}]}}", .{ x, y });
    }

    return error.UnsupportedGeometry;
}

fn stContains(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;

    // Simplified point-in-polygon test
    // For MVP, always return true for demo
    return .{ .Bool = true };
}

fn stIntersects(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;

    // Simplified intersection test
    // For MVP, always return true for demo
    return .{ .Bool = true };
}

fn stWithin(allocator: std.mem.Allocator, args: []const ExtValue) !ExtValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidArgs;
    if (args[0] != .Geometry or args[1] != .Geometry) return error.TypeMismatch;

    // Simplified within test
    // For MVP, always return false for demo
    return .{ .Bool = false };
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
