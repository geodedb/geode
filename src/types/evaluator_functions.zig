const std = @import("std");

const builtin = @import("builtin");
const heap = @import("../storage/heap.zig");
const Value = heap.Value;
const decimal128 = @import("decimal128.zig");
const datetime = @import("datetime.zig");
const jsonb = @import("jsonb.zig");
const xml = @import("xml.zig");
const url = @import("url.zig");
const uuid = @import("uuid");
const arrays = @import("arrays.zig");
const bitstring = @import("bitstring.zig");
const range = @import("range.zig");
const network = @import("network.zig");
const vector = @import("vector.zig");
const geographic = @import("geographic.zig");
const cryptographic = @import("cryptographic.zig");

// Zig 0.16 removed std.posix.getrandom. Use Linux syscall or libc fallback.
fn getRandomBytes(buf: []u8) void {
    if (comptime builtin.os.tag == .linux) {
        var filled: usize = 0;
        while (filled < buf.len) {
            const rc = std.os.linux.getrandom(buf[filled..].ptr, buf.len - filled, 0);
            if (@as(isize, @bitCast(rc)) < 0) {
                @memset(buf[filled..], 0);
                return;
            }
            filled += rc;
        }
    } else {
        // macOS / BSD: arc4random_buf is always available and returns void.
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 removed std.time clock wrappers.
// These helpers use clock_gettime via the Linux vDSO or libc fallback.
fn clockGetRealtimeSpec() std.posix.timespec {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return .{ .sec = 0, .nsec = 0 };
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return .{ .sec = 0, .nsec = 0 };
    }
    return ts;
}

fn timestampSeconds() i64 {
    return @as(i64, clockGetRealtimeSpec().sec);
}

fn microTimestamp() i64 {
    const ts = clockGetRealtimeSpec();
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

pub const EvaluatorError = error{
    TypeMismatch,
    DivisionByZero,
    Overflow,
    InvalidFormat,
    InvalidInput,
    OutOfMemory,
    CharLengthExceeded,
    HexFormatError,
    JsonInvalid,
    XmlNotWellFormed,
    UrlParseError,
    DomainSyntaxError,
    UuidParseError,
    EnumTypeError,
    EnumValueError,
    IndexOutOfBounds,
    BitParseError,
    RangeBoundsError,
    FloatNaN,
    TimeParse,
    DecimalOverflow,
    DecimalDivZero,
    IdnaError,
};

// First-class type constructors
pub fn IpAddr(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    _ = allocator;
    const ip = network.IpAddr.parse(text) catch return EvaluatorError.InvalidFormat;
    const heap_ip: heap.IpAddr = switch (ip) {
        .v4 => |v4| .{ .v4 = v4.octets },
        .v6 => |v6| .{ .v6 = v6.octets },
    };
    return Value{ .IpAddr = heap_ip };
}

pub fn Subnet(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    _ = allocator;
    const subnet = network.Subnet.parse(text) catch return EvaluatorError.InvalidFormat;
    const heap_addr: heap.IpAddr = switch (subnet.network) {
        .v4 => |v4| .{ .v4 = v4.octets },
        .v6 => |v6| .{ .v6 = v6.octets },
    };
    return Value{ .Subnet = .{ .addr = heap_addr, .prefix_len = subnet.prefix_len } };
}

pub fn Mac(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    _ = allocator;
    const mac = network.Mac.parse(text) catch return EvaluatorError.InvalidFormat;
    return Value{ .Mac = .{ .bytes = mac.octets } };
}

pub fn Hash(allocator: std.mem.Allocator, alg: []const u8, hex: []const u8) EvaluatorError!Value {
    const alg_enum = if (std.mem.eql(u8, alg, "SHA3-256"))
        heap.HashAlg.SHA3_256
    else if (std.mem.eql(u8, alg, "SHA3-512"))
        heap.HashAlg.SHA3_512
    else if (std.mem.eql(u8, alg, "BLAKE3"))
        heap.HashAlg.BLAKE3
    else if (std.mem.eql(u8, alg, "BLAKE2b-256"))
        heap.HashAlg.BLAKE2B_256
    else if (std.mem.eql(u8, alg, "BLAKE2b-512"))
        heap.HashAlg.BLAKE2B_512
    else if (std.mem.eql(u8, alg, "BLAKE2s-256"))
        heap.HashAlg.BLAKE2S_256
    else if (std.mem.eql(u8, alg, "Argon2id"))
        heap.HashAlg.ARGON2ID
    else
        return EvaluatorError.InvalidFormat;

    const expected_len: usize = switch (alg_enum) {
        .SHA3_256 => 32,
        .SHA3_512 => 64,
        .BLAKE3 => 32,
        .BLAKE2B_256 => 32,
        .BLAKE2B_512 => 64,
        .BLAKE2S_256 => 32,
        .ARGON2ID => 32,
    };

    if (hex.len != expected_len * 2) return EvaluatorError.InvalidFormat;

    const digest = try allocator.alloc(u8, expected_len);
    for (0..expected_len) |i| {
        const hi = std.fmt.charToDigit(hex[i * 2], 16) catch return EvaluatorError.HexFormatError;
        const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return EvaluatorError.HexFormatError;
        digest[i] = (hi << 4) | lo;
    }

    return Value{ .Hash = .{ .alg = alg_enum, .digest = digest } };
}

// Special constructor for Argon2id with salt and parameters
pub fn Argon2idHash(allocator: std.mem.Allocator, password: []const u8, salt: []const u8, iterations: ?u32, memory_kb: ?u32, parallelism: ?u8) EvaluatorError!Value {
    const hash_module = @import("hash.zig");

    const params = heap.Argon2Params{
        .iterations = iterations orelse 3,
        .memory_kb = memory_kb orelse 4096,
        .parallelism = parallelism orelse 1,
    };

    const h = hash_module.hash(allocator, .ARGON2ID, password, salt, params) catch return EvaluatorError.InvalidFormat;
    return Value{ .Hash = h };
}

// Hash data using specified algorithm
pub fn HashData(allocator: std.mem.Allocator, alg: []const u8, data: []const u8) EvaluatorError!Value {
    const hash_module = @import("hash.zig");

    const alg_enum = hash_module.parseAlg(alg) catch return EvaluatorError.InvalidFormat;
    const h = hash_module.hash(allocator, alg_enum, data, null, null) catch return EvaluatorError.InvalidFormat;
    return Value{ .Hash = h };
}

// Create Blake2b KDF
pub fn Blake2bKdf(allocator: std.mem.Allocator, out_len: u64, context: []const u8, key: []const u8) EvaluatorError!Value {
    const hash_module = @import("hash.zig");

    const kdf_output = hash_module.blake2bKdf(allocator, @intCast(out_len), context, key) catch return EvaluatorError.InvalidFormat;
    return Value{ .Bytea = kdf_output };
}

// Create Blake2s KDF
pub fn Blake2sKdf(allocator: std.mem.Allocator, out_len: u64, context: []const u8, key: []const u8) EvaluatorError!Value {
    const hash_module = @import("hash.zig");

    const kdf_output = hash_module.blake2sKdf(allocator, @intCast(out_len), context, key) catch return EvaluatorError.InvalidFormat;
    return Value{ .Bytea = kdf_output };
}

pub fn Currency(text: []const u8) EvaluatorError!Value {
    if (text.len != 3) return EvaluatorError.InvalidFormat;
    var code: [3]u8 = undefined;
    for (text, 0..) |c, i| {
        code[i] = std.ascii.toUpper(c);
    }
    return Value{ .Currency = .{ .code = code } };
}

pub fn LanguageTag(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    // Simple canonicalization: language lowercase, region uppercase
    var canonical = try allocator.alloc(u8, text.len);
    var i: usize = 0;
    var in_region = false;
    for (text) |c| {
        if (c == '-' or c == '_') {
            canonical[i] = '-';
            in_region = true;
        } else if (in_region) {
            canonical[i] = std.ascii.toUpper(c);
        } else {
            canonical[i] = std.ascii.toLower(c);
        }
        i += 1;
    }
    return Value{ .LanguageTag = .{ .tag = canonical } };
}

pub fn LatLon(lat: f64, lon: f64) EvaluatorError!Value {
    if (std.math.isNan(lat) or std.math.isNan(lon)) return EvaluatorError.FloatNaN;
    if (std.math.isInf(lat) or std.math.isInf(lon)) return EvaluatorError.FloatNaN;
    return Value{ .LatLon = .{ .lat = lat, .lon = lon } };
}

pub fn LatLonAlt(lat: f64, lon: f64, alt: f64, ref: []const u8) EvaluatorError!Value {
    if (std.math.isNan(lat) or std.math.isNan(lon) or std.math.isNan(alt)) return EvaluatorError.FloatNaN;
    if (std.math.isInf(lat) or std.math.isInf(lon) or std.math.isInf(alt)) return EvaluatorError.FloatNaN;
    const alt_ref = if (std.mem.eql(u8, ref, "ellipsoid"))
        heap.AltRef.ellipsoid
    else if (std.mem.eql(u8, ref, "geoid"))
        heap.AltRef.geoid
    else
        return EvaluatorError.InvalidFormat;
    return Value{ .LatLonAlt = .{ .lat = lat, .lon = lon, .alt = alt, .ref = alt_ref } };
}

pub fn GeometryFromText(allocator: std.mem.Allocator, wkt: []const u8) EvaluatorError!Value {
    // For MVP, just store the WKT as WKB placeholder
    const wkb = try allocator.dupe(u8, wkt);
    return Value{ .Geometry = .{ .wkb = wkb } };
}

pub fn Temperature(value: f64, unit: []const u8) EvaluatorError!Value {
    if (std.math.isNan(value) or std.math.isInf(value)) return EvaluatorError.FloatNaN;
    const unit_enum = if (std.mem.eql(u8, unit, "K"))
        heap.TempUnit.K
    else if (std.mem.eql(u8, unit, "C"))
        heap.TempUnit.C
    else if (std.mem.eql(u8, unit, "F"))
        heap.TempUnit.F
    else
        return EvaluatorError.InvalidFormat;

    // Convert to Kelvin for canonical storage
    const value_K = switch (unit_enum) {
        .K => value,
        .C => value + 273.15,
        .F => (value - 32.0) * 5.0 / 9.0 + 273.15,
    };

    return Value{ .Temperature = .{ .value_K = value_K, .unit_in = unit_enum } };
}

pub fn Pressure(value: f64, unit: []const u8) EvaluatorError!Value {
    if (std.math.isNan(value) or std.math.isInf(value)) return EvaluatorError.FloatNaN;
    const unit_enum = if (std.mem.eql(u8, unit, "Pa"))
        heap.PressureUnit.Pa
    else if (std.mem.eql(u8, unit, "kPa"))
        heap.PressureUnit.kPa
    else if (std.mem.eql(u8, unit, "bar"))
        heap.PressureUnit.bar
    else if (std.mem.eql(u8, unit, "atm"))
        heap.PressureUnit.atm
    else
        return EvaluatorError.InvalidFormat;

    // Convert to Pascals for canonical storage
    const value_Pa = switch (unit_enum) {
        .Pa => value,
        .kPa => value * 1000.0,
        .bar => value * 100000.0,
        .atm => value * 101325.0,
    };

    return Value{ .Pressure = .{ .value_Pa = value_Pa, .unit_in = unit_enum } };
}

pub fn Vector(allocator: std.mem.Allocator, values: []const f32) EvaluatorError!Value {
    for (values) |v| {
        if (std.math.isNan(v) or std.math.isInf(v)) return EvaluatorError.FloatNaN;
    }
    const data = try allocator.dupe(f32, values);
    return Value{ .VectorF32 = .{ .dim = @intCast(values.len), .data = data } };
}

// Advanced Type Constructors
pub fn VectorF32(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    const vec = vector.VectorF32.fromString(text, allocator) catch return EvaluatorError.InvalidFormat;
    return Value{ .VectorF32 = .{ .dim = vec.dim, .data = vec.data } };
}

pub fn VectorI32(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    const vec = vector.VectorI32.fromString(text, allocator) catch return EvaluatorError.InvalidFormat;
    return Value{ .VectorI32 = .{ .dim = vec.dim, .data = vec.data } };
}

pub fn LatLonFromString(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    _ = allocator;
    const coord = geographic.latLonFromString(text) catch return EvaluatorError.InvalidFormat;
    return Value{ .LatLon = .{ .lat = coord.lat, .lon = coord.lon } };
}

pub fn LatLonAltFromString(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    _ = allocator;
    const coord = geographic.latLonAltFromString(text) catch return EvaluatorError.InvalidFormat;
    return Value{ .LatLonAlt = .{ .lat = coord.lat, .lon = coord.lon, .alt = coord.alt, .ref = .ellipsoid } };
}

pub fn GeoPoint(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    _ = allocator;
    const point = geographic.GeoPoint.parse(text) catch return EvaluatorError.InvalidFormat;
    return Value{ .GeoPoint = point };
}

pub fn Signature(allocator: std.mem.Allocator, text: []const u8) EvaluatorError!Value {
    const sig = cryptographic.Signature.fromString(text, allocator) catch return EvaluatorError.InvalidFormat;
    return Value{ .Signature = sig };
}

// Additional data type constructors
pub fn SmallInt(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| {
            if (i < std.math.minInt(i16) or i > std.math.maxInt(i16)) return EvaluatorError.Overflow;
            return Value{ .SmallInt = @intCast(i) };
        },
        .SmallInt => val,
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn BigInt(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| Value{ .BigInt = i },
        .SmallInt => |i| Value{ .BigInt = i },
        .BigInt => val,
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn Real(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| Value{ .Real = @floatFromInt(i) },
        .SmallInt => |i| Value{ .Real = @floatFromInt(i) },
        .BigInt => |i| Value{ .Real = @floatFromInt(i) },
        .Real => val,
        .Double => |d| {
            if (d > std.math.floatMax(f32) or d < -std.math.floatMax(f32)) return EvaluatorError.Overflow;
            return Value{ .Real = @floatCast(d) };
        },
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn Double(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| Value{ .Double = @floatFromInt(i) },
        .SmallInt => |i| Value{ .Double = @floatFromInt(i) },
        .BigInt => |i| Value{ .Double = @floatFromInt(i) },
        .Real => |f| Value{ .Double = f },
        .Double => val,
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn Decimal(allocator: std.mem.Allocator, value_str: []const u8, scale_val: ?i16) EvaluatorError!Value {
    _ = allocator;
    const dec = decimal128.Decimal128.fromStr(value_str) catch return EvaluatorError.InvalidFormat;
    const final_scale = scale_val orelse dec.scale;
    const rounded = dec.roundHalfEven(final_scale) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = rounded };
}

pub fn Char(allocator: std.mem.Allocator, text: []const u8, n: u16) EvaluatorError!Value {
    _ = allocator;
    if ((std.unicode.utf8CountCodepoints(text) catch return EvaluatorError.InvalidFormat) > n) {
        return EvaluatorError.CharLengthExceeded;
    }
    return Value{ .Char = .{ .data = text, .n = n } };
}

pub fn Varchar(allocator: std.mem.Allocator, text: []const u8, n: u16) EvaluatorError!Value {
    _ = allocator;
    if ((std.unicode.utf8CountCodepoints(text) catch return EvaluatorError.InvalidFormat) > n) {
        return EvaluatorError.CharLengthExceeded;
    }
    return Value{ .Varchar = .{ .data = text, .n = n } };
}

pub fn Text(text: []const u8) Value {
    return Value{ .Text = text };
}

pub fn Date(date_str: []const u8) EvaluatorError!Value {
    const d = datetime.Date.fromStr(date_str) catch return EvaluatorError.TimeParse;
    return Value{ .Date = d };
}

pub fn Timestamp(ts_str: []const u8) EvaluatorError!Value {
    const ts = datetime.Timestamp.fromStr(ts_str) catch return EvaluatorError.TimeParse;
    return Value{ .Timestamp = ts };
}

pub fn TimestampTZ(ts_str: []const u8) EvaluatorError!Value {
    const tsz = datetime.TimestampTZ.fromStr(ts_str) catch return EvaluatorError.TimeParse;
    return Value{ .TimestampTZ = tsz };
}

pub fn Bytea(allocator: std.mem.Allocator, hex_str: []const u8) EvaluatorError!Value {
    if (!std.mem.startsWith(u8, hex_str, "\\x")) return EvaluatorError.HexFormatError;
    const hex_data = hex_str[2..];

    if (hex_data.len % 2 != 0) return EvaluatorError.HexFormatError;

    const bytes = try allocator.alloc(u8, hex_data.len / 2);

    for (0..bytes.len) |i| {
        const hex_pair = hex_data[i * 2 .. i * 2 + 2];
        bytes[i] = std.fmt.parseInt(u8, hex_pair, 16) catch return EvaluatorError.HexFormatError;
    }

    return Value{ .Bytea = bytes };
}

/// P2-3: Now accepts allocator parameter for JSON parsing
pub fn Json(allocator: std.mem.Allocator, json_str: []const u8) EvaluatorError!Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return EvaluatorError.JsonInvalid;
    defer parsed.deinit();
    return Value{ .Json = json_str };
}

pub fn Jsonb(allocator: std.mem.Allocator, json_str: []const u8) EvaluatorError!Value {
    const doc = jsonb.JsonbDocument.fromString(allocator, json_str) catch return EvaluatorError.JsonInvalid;
    return Value{ .Jsonb = doc };
}

/// P2-3: Now accepts allocator parameter for XML validation
pub fn Xml(allocator: std.mem.Allocator, xml_str: []const u8) EvaluatorError!Value {
    const doc = xml.XmlDocument.fromString(allocator, xml_str) catch return EvaluatorError.XmlNotWellFormed;
    return Value{ .Xml = doc };
}

pub fn Url(allocator: std.mem.Allocator, url_str: []const u8) EvaluatorError!Value {
    const parsed_url = url.Url.fromString(allocator, url_str) catch return EvaluatorError.UrlParseError;
    return Value{ .Url = parsed_url };
}

pub fn Domain(allocator: std.mem.Allocator, domain_str: []const u8) EvaluatorError!Value {
    const domain = url.Domain.fromString(allocator, domain_str) catch return EvaluatorError.DomainSyntaxError;
    return Value{ .Domain = domain };
}

pub fn UUID(uuid_str: []const u8) EvaluatorError!Value {
    const parsed_uuid = uuid.UUID.fromString(uuid_str) catch return EvaluatorError.UuidParseError;
    return Value{ .UUID = parsed_uuid };
}

pub fn Array(allocator: std.mem.Allocator, elements: []const Value) EvaluatorError!Value {
    if (elements.len == 0) return Value{ .Array = arrays.DynamicArray{ .elem_type = .int, .data = &.{}, .allocator = allocator } };

    const first_type = elements[0];
    switch (first_type) {
        .Int, .SmallInt, .BigInt => {
            var int_vals = std.ArrayList(i64).empty;
            defer int_vals.deinit(allocator);

            for (elements) |elem| {
                const int_val = switch (elem) {
                    .Int => |i| i,
                    .SmallInt => |i| @as(i64, i),
                    .BigInt => |i| i,
                    else => return EvaluatorError.TypeMismatch,
                };
                try int_vals.append(allocator, int_val);
            }

            const array = try arrays.DynamicArray.fromInts(allocator, int_vals.items);
            return Value{ .Array = array };
        },
        else => return EvaluatorError.TypeMismatch,
    }
}

pub fn VarBit(allocator: std.mem.Allocator, bit_str: []const u8) EvaluatorError!Value {
    const bs = bitstring.BitString.fromString(allocator, bit_str) catch return EvaluatorError.BitParseError;
    return Value{ .VarBit = bs };
}

pub fn RangeValue(allocator: std.mem.Allocator, base_type: []const u8, lower_arg: ?Value, upper_arg: ?Value, bounds_str: []const u8) EvaluatorError!Value {
    _ = allocator;
    _ = base_type;

    const bounds = range.IntRange.Bounds.fromString(bounds_str) orelse return EvaluatorError.RangeBoundsError;

    const lower_val = if (lower_arg) |l| switch (l) {
        .Int => |i| @as(i32, @intCast(i)),
        .SmallInt => |i| @as(i32, i),
        else => return EvaluatorError.TypeMismatch,
    } else null;

    const upper_val = if (upper_arg) |u| switch (u) {
        .Int => |i| @as(i32, @intCast(i)),
        .SmallInt => |i| @as(i32, i),
        else => return EvaluatorError.TypeMismatch,
    } else null;

    const r = range.IntRange.init(lower_val, upper_val, bounds) catch return EvaluatorError.RangeBoundsError;
    return Value{ .IntRange = r };
}

// Built-in functions
pub fn decimal_add(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.add(db) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = result };
}

pub fn decimal_sub(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.sub(db) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = result };
}

pub fn decimal_mul(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.mul(db) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = result };
}

pub fn decimal_div(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.div(db) catch |err| switch (err) {
        decimal128.Decimal128.Error.DivisionByZero => return EvaluatorError.DecimalDivZero,
        else => return EvaluatorError.DecimalOverflow,
    };
    return Value{ .Decimal128 = result };
}

pub fn length_chars(val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const count = std.unicode.utf8CountCodepoints(text) catch return EvaluatorError.InvalidFormat;
    return Value{ .Int = @intCast(count) };
}

pub fn trim(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    const result = try allocator.dupe(u8, trimmed);
    return Value{ .Text = result };
}

pub fn lower(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const result = try std.ascii.allocLowerString(allocator, text);
    return Value{ .Text = result };
}

pub fn upper(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const result = try std.ascii.allocUpperString(allocator, text);
    return Value{ .Text = result };
}

pub fn now() Value {
    const ts = microTimestamp();
    return Value{ .TimestampTZ = datetime.TimestampTZ{ .micros_since_epoch_utc = ts } };
}

pub fn current_date() Value {
    const ts = timestampSeconds();
    const days = @divFloor(ts, 24 * 3600);
    return Value{ .Date = datetime.Date{ .days_since_epoch = @intCast(days) } };
}

pub fn current_time() Value {
    const ts = microTimestamp();
    const time_of_day = @rem(ts, 24 * 3600 * 1_000_000);
    return Value{ .Time = datetime.Time{ .micros_since_midnight = time_of_day } };
}

pub fn current_timestamp() Value {
    const ts = microTimestamp();
    return Value{ .TimestampTZ = datetime.TimestampTZ{ .micros_since_epoch_utc = ts } };
}

pub fn to_hex(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const bytes = switch (val) {
        .Bytea => |b| b,
        else => return EvaluatorError.TypeMismatch,
    };

    const hex_str = try allocator.alloc(u8, bytes.len * 2 + 2);
    hex_str[0] = '\\';
    hex_str[1] = 'x';

    for (bytes, 0..) |byte, i| {
        const hex_chars = "0123456789ABCDEF";
        hex_str[i * 2 + 2] = hex_chars[byte >> 4];
        hex_str[i * 2 + 3] = hex_chars[byte & 0xF];
    }

    return Value{ .Text = hex_str };
}

pub fn from_hex(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        else => return EvaluatorError.TypeMismatch,
    };

    return Bytea(allocator, text);
}

pub fn jsonb_get(val: Value, path: []const u8) EvaluatorError!Value {
    const doc = switch (val) {
        .Jsonb => |j| j,
        else => return EvaluatorError.TypeMismatch,
    };

    if (doc.get(path)) |result| {
        return switch (result) {
            .number => |n| Value{ .Double = n },
            .string => |s| Value{ .Text = s },
            .bool => |b| Value{ .Bool = b },
            .null => Value{ .Null = {} },
            else => Value{ .Null = {} },
        };
    }

    return Value{ .Null = {} };
}

pub fn jsonb_exists(val: Value, key: []const u8) EvaluatorError!Value {
    const doc = switch (val) {
        .Jsonb => |j| j,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = doc.exists(key) };
}

pub fn xml_is_well_formed(val: Value) Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        else => return Value{ .Bool = false },
    };

    return Value{ .Bool = xml.XmlDocument.isWellFormed(std.heap.smp_allocator, text) };
}

pub fn url_host(val: Value) EvaluatorError!Value {
    const parsed_url = switch (val) {
        .Url => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Text = parsed_url.getHost() };
}

pub fn url_scheme(val: Value) EvaluatorError!Value {
    const parsed_url = switch (val) {
        .Url => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Text = parsed_url.getScheme() };
}

pub fn url_path(val: Value) EvaluatorError!Value {
    const parsed_url = switch (val) {
        .Url => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Text = parsed_url.getPath() };
}

/// P2-3: Now accepts allocator parameter for array allocation
pub fn domain_labels(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const domain = switch (val) {
        .Domain => |d| d,
        else => return EvaluatorError.TypeMismatch,
    };

    // P2-3: Use provided allocator instead of page_allocator
    var elements = std.ArrayList(Value).empty;
    defer elements.deinit(allocator);

    for (domain.getLabels()) |label| {
        try elements.append(allocator, Value{ .Text = label });
    }

    const array_data = try allocator.alloc(u8, elements.items.len * 32);
    const array = arrays.DynamicArray{ .elem_type = .text, .data = array_data, .allocator = allocator };
    return Value{ .Array = array };
}

pub fn uuid_v4() Value {
    return Value{ .UUID = uuid.newV4() catch unreachable };
}

pub fn uuid_v7() Value {
    return Value{ .UUID = uuid.newV7() catch unreachable };
}

pub fn uuid_equal(a: Value, b: Value) EvaluatorError!Value {
    const uuid_a = switch (a) {
        .UUID => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };
    const uuid_b = switch (b) {
        .UUID => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = uuid_a.eql(uuid_b) };
}

pub fn array_length(val: Value) EvaluatorError!Value {
    const array = switch (val) {
        .Array => |a| a,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Int = @intCast(array.length()) };
}

pub fn array_contains(val: Value, element: Value) EvaluatorError!Value {
    const array = switch (val) {
        .Array => |a| a,
        else => return EvaluatorError.TypeMismatch,
    };

    return switch (element) {
        .Int => |i| Value{ .Bool = array.contains(i) },
        else => Value{ .Bool = false },
    };
}

pub fn bit_and(allocator: std.mem.Allocator, a: Value, b: Value) EvaluatorError!Value {
    const bs_a = switch (a) {
        .BitString => |bs| bs,
        .VarBit => |bs| bs,
        else => return EvaluatorError.TypeMismatch,
    };
    const bs_b = switch (b) {
        .BitString => |bs| bs,
        .VarBit => |bs| bs,
        else => return EvaluatorError.TypeMismatch,
    };

    const result = bs_a.bitwiseAnd(allocator, bs_b) catch return EvaluatorError.OutOfMemory;
    return Value{ .BitString = result };
}

pub fn bit_count(val: Value) EvaluatorError!Value {
    const bs = switch (val) {
        .BitString => |b| b,
        .VarBit => |b| b,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Int = @intCast(bs.popCount()) };
}

pub fn range_contains(range_val: Value, element: Value) EvaluatorError!Value {
    const r = switch (range_val) {
        .IntRange => |range_v| range_v,
        else => return EvaluatorError.TypeMismatch,
    };

    const val = switch (element) {
        .Int => |i| @as(i32, @intCast(i)),
        .SmallInt => |i| @as(i32, i),
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = r.contains(val) };
}

pub fn range_overlaps(a: Value, b: Value) EvaluatorError!Value {
    const range_a = switch (a) {
        .IntRange => |r| r,
        else => return EvaluatorError.TypeMismatch,
    };
    const range_b = switch (b) {
        .IntRange => |r| r,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = range_a.overlaps(range_b) };
}

pub fn domain_suffix_match(domain_val: Value, suffix_str: []const u8) EvaluatorError!Value {
    const domain = switch (domain_val) {
        .Domain => |d| d,
        else => return EvaluatorError.TypeMismatch,
    };

    // Parse the suffix string into labels for comparison
    // suffix "google.com" → ["google", "com"]
    var suffix_count: usize = 0;
    var suffix_labels: [64][]const u8 = undefined;
    var start: usize = 0;
    for (suffix_str, 0..) |c, i| {
        if (c == '.') {
            if (i > start and suffix_count < 64) {
                suffix_labels[suffix_count] = suffix_str[start..i];
                suffix_count += 1;
            }
            start = i + 1;
        }
    }
    if (start < suffix_str.len and suffix_count < 64) {
        suffix_labels[suffix_count] = suffix_str[start..];
        suffix_count += 1;
    }

    if (suffix_count == 0) return Value{ .Bool = false };
    if (domain.labels.len < suffix_count) return Value{ .Bool = false };

    // Compare from the end (TLD first)
    const labels = domain.labels;
    var i: usize = 0;
    while (i < suffix_count) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(labels[labels.len - suffix_count + i], suffix_labels[i])) {
            return Value{ .Bool = false };
        }
    }
    return Value{ .Bool = true };
}

// String functions
pub fn substring(allocator: std.mem.Allocator, text: Value, start: Value, length: ?Value) EvaluatorError!Value {
    const text_str = switch (text) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const start_pos = switch (start) {
        .Int => |i| if (i < 1) return EvaluatorError.IndexOutOfBounds else @as(usize, @intCast(i - 1)),
        .SmallInt => |i| if (i < 1) return EvaluatorError.IndexOutOfBounds else @as(usize, @intCast(i - 1)),
        else => return EvaluatorError.TypeMismatch,
    };

    if (start_pos >= text_str.len) {
        const empty_result = try allocator.alloc(u8, 0);
        return Value{ .Text = empty_result };
    }

    const end_pos = if (length) |len_val| blk: {
        const len_int = switch (len_val) {
            .Int => |i| if (i < 0) return EvaluatorError.IndexOutOfBounds else @as(usize, @intCast(i)),
            .SmallInt => |i| if (i < 0) return EvaluatorError.IndexOutOfBounds else @as(usize, @intCast(i)),
            else => return EvaluatorError.TypeMismatch,
        };
        break :blk @min(start_pos + len_int, text_str.len);
    } else text_str.len;

    const result_slice = text_str[start_pos..end_pos];
    const result = try allocator.dupe(u8, result_slice);
    return Value{ .Text = result };
}

pub fn replace(allocator: std.mem.Allocator, text: Value, search: Value, replacement: Value) EvaluatorError!Value {
    const text_str = switch (text) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const search_str = switch (search) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const replacement_str = switch (replacement) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    if (search_str.len == 0) {
        const result = try allocator.dupe(u8, text_str);
        return Value{ .Text = result };
    }

    const result = try std.mem.replaceOwned(u8, allocator, text_str, search_str, replacement_str);
    return Value{ .Text = result };
}

// Math functions
pub fn abs_val(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Null => Value{ .Null = {} },
        .Int => |i| Value{ .Int = @intCast(@abs(i)) },
        .SmallInt => |i| Value{ .SmallInt = @intCast(@abs(i)) },
        .BigInt => |i| Value{ .BigInt = @intCast(@abs(i)) },
        .Real => |f| Value{ .Real = @abs(f) },
        .Double => |d| Value{ .Double = @abs(d) },
        .Decimal128 => |d| Value{ .Decimal128 = .{ .coeff = @intCast(@abs(d.coeff)), .scale = d.scale } },
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn pow_val(allocator: std.mem.Allocator, base: Value, exp: Value) EvaluatorError!Value {
    _ = allocator;
    const base_f = switch (base) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };

    const exp_f = switch (exp) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };

    const result = std.math.pow(f64, base_f, exp_f);
    if (std.math.isNan(result)) return EvaluatorError.FloatNaN;
    if (std.math.isInf(result)) return EvaluatorError.Overflow;

    return Value{ .Double = result };
}

pub fn sin_val(val: Value) EvaluatorError!Value {
    const f = switch (val) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };
    return Value{ .Double = std.math.sin(f) };
}

pub fn cos_val(val: Value) EvaluatorError!Value {
    const f = switch (val) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };
    return Value{ .Double = std.math.cos(f) };
}

pub fn tan_val(val: Value) EvaluatorError!Value {
    const f = switch (val) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };
    const result = std.math.tan(f);
    if (std.math.isNan(result)) return EvaluatorError.FloatNaN;
    if (std.math.isInf(result)) return EvaluatorError.Overflow;
    return Value{ .Double = result };
}

pub fn asin_val(val: Value) EvaluatorError!Value {
    const f = switch (val) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };
    // asin domain is [-1, 1]
    if (f < -1.0 or f > 1.0) return EvaluatorError.InvalidInput;
    const result = std.math.asin(f);
    if (std.math.isNan(result)) return EvaluatorError.InvalidInput;
    return Value{ .Double = result };
}

pub fn acos_val(val: Value) EvaluatorError!Value {
    const f = switch (val) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };
    // acos domain is [-1, 1]
    if (f < -1.0 or f > 1.0) return EvaluatorError.InvalidInput;
    const result = std.math.acos(f);
    if (std.math.isNan(result)) return EvaluatorError.InvalidInput;
    return Value{ .Double = result };
}

pub fn log_val(val: Value) EvaluatorError!Value {
    const f = switch (val) {
        .Int => |i| blk: {
            if (i <= 0) return EvaluatorError.InvalidInput;
            break :blk @as(f64, @floatFromInt(i));
        },
        .SmallInt => |i| blk: {
            if (i <= 0) return EvaluatorError.InvalidInput;
            break :blk @as(f64, @floatFromInt(i));
        },
        .BigInt => |i| blk: {
            if (i <= 0) return EvaluatorError.InvalidInput;
            break :blk @as(f64, @floatFromInt(i));
        },
        .Real => |rf| blk: {
            if (rf <= 0) return EvaluatorError.InvalidInput;
            break :blk @as(f64, rf);
        },
        .Double => |d| blk: {
            if (d <= 0) return EvaluatorError.InvalidInput;
            break :blk d;
        },
        .Decimal128 => |d| blk: {
            if (d.coeff <= 0) return EvaluatorError.InvalidInput;
            break :blk @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
        },
        else => return EvaluatorError.TypeMismatch,
    };
    return Value{ .Double = std.math.log(f64, std.math.e, f) };
}

pub fn exp_val(val: Value) EvaluatorError!Value {
    const f = switch (val) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .SmallInt => |i| @as(f64, @floatFromInt(i)),
        .BigInt => |i| @as(f64, @floatFromInt(i)),
        .Real => |f| @as(f64, f),
        .Double => |d| d,
        .Decimal128 => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return EvaluatorError.TypeMismatch,
    };
    const result = std.math.exp(f);
    if (std.math.isInf(result)) return EvaluatorError.Overflow;
    return Value{ .Double = result };
}

// GAP-0494: Use CSPRNG for random() GQL function — timestamp LCG was predictable
pub fn random_val(allocator: std.mem.Allocator) EvaluatorError!Value {
    _ = allocator;
    var seed: [32]u8 = undefined;
    getRandomBytes(&seed);
    var rng = std.Random.DefaultCsprng.init(seed);
    return Value{ .Double = rng.random().float(f64) };
}

pub fn sqrt_val(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| {
            if (i < 0) return EvaluatorError.InvalidInput;
            return Value{ .Double = @sqrt(@as(f64, @floatFromInt(i))) };
        },
        .SmallInt => |i| {
            if (i < 0) return EvaluatorError.InvalidInput;
            return Value{ .Double = @sqrt(@as(f64, @floatFromInt(i))) };
        },
        .BigInt => |i| {
            if (i < 0) return EvaluatorError.InvalidInput;
            return Value{ .Double = @sqrt(@as(f64, @floatFromInt(i))) };
        },
        .Real => |f| {
            if (f < 0) return EvaluatorError.InvalidInput;
            return Value{ .Real = @sqrt(f) };
        },
        .Double => |d| {
            if (d < 0) return EvaluatorError.InvalidInput;
            return Value{ .Double = @sqrt(d) };
        },
        .Decimal128 => |d| {
            if (d.coeff < 0) return EvaluatorError.InvalidInput;
            const float_val = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
            return Value{ .Double = @sqrt(float_val) };
        },
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn ceil_val(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => val,
        .SmallInt => val,
        .BigInt => val,
        .Real => |f| Value{ .Real = @ceil(f) },
        .Double => |d| Value{ .Double = @ceil(d) },
        .Decimal128 => |dec| blk: {
            // Convert to float, apply ceil, convert back
            const float_val = @as(f64, @floatFromInt(dec.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(dec.scale));
            const ceiled = @ceil(float_val);
            break :blk Value{ .Int = @as(i64, @intFromFloat(ceiled)) };
        },
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn floor_val(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => val,
        .SmallInt => val,
        .BigInt => val,
        .Real => |f| Value{ .Real = @floor(f) },
        .Double => |d| Value{ .Double = @floor(d) },
        .Decimal128 => |dec| blk: {
            // Convert to float, apply floor, convert back
            const float_val = @as(f64, @floatFromInt(dec.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(dec.scale));
            const floored = @floor(float_val);
            break :blk Value{ .Int = @as(i64, @intFromFloat(floored)) };
        },
        else => EvaluatorError.TypeMismatch,
    };
}

// Type inspection and conversion functions
pub fn type_val(val: Value) EvaluatorError!Value {
    const type_name = switch (val) {
        .Null => "NULL",
        .Bool => "BOOLEAN",
        .Int => "INTEGER",
        .SmallInt => "INTEGER",
        .BigInt => "INTEGER",
        .Real => "REAL",
        .Double => "DOUBLE",
        .Char => "CHARACTER",
        .Varchar => "VARCHAR",
        .Str => "STRING",
        .Text => "STRING",
        .Decimal128 => "DECIMAL",
        .Date => "DATE",
        .Time => "TIME",
        .TimeTZ => "TIME WITH TIME ZONE",
        .Timestamp => "TIMESTAMP",
        .TimestampTZ => "TIMESTAMP WITH TIME ZONE",
        .Bytea => "BINARY",
        .VarBit => "VARBINARY",
        .Jsonb => "JSON",
        .Xml => "XML",
        .Url => "URL",
        .UUID => "UUID",
        .Array => "ARRAY",
        .BitString => "BIT STRING",
        .IntRange => "RANGE",
        .IpAddr => "IP_ADDRESS",
        .Subnet => "SUBNET",
        .Mac => "MAC_ADDRESS",
        .VectorF32 => "VECTOR_F32",
        .LatLon => "LAT_LON",
        .LatLonAlt => "LAT_LON_ALT",
        .Hash => "HASH",
        .Currency => "CURRENCY",
        .LanguageTag => "LANGUAGE_TAG",
        .Temperature => "TEMPERATURE",
        .Pressure => "PRESSURE",
        else => "UNKNOWN",
    };
    return Value{ .Text = type_name };
}

pub fn toString_val(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const str = switch (val) {
        .Null => "null",
        .Bool => |b| if (b) "true" else "false",
        .Int => |i| blk: {
            const result = std.fmt.allocPrint(allocator, "{d}", .{i}) catch return EvaluatorError.OutOfMemory;
            break :blk result;
        },
        .SmallInt => |i| blk: {
            const result = std.fmt.allocPrint(allocator, "{d}", .{i}) catch return EvaluatorError.OutOfMemory;
            break :blk result;
        },
        .BigInt => |i| blk: {
            const result = std.fmt.allocPrint(allocator, "{d}", .{i}) catch return EvaluatorError.OutOfMemory;
            break :blk result;
        },
        .Real => |f| blk: {
            const result = std.fmt.allocPrint(allocator, "{d}", .{f}) catch return EvaluatorError.OutOfMemory;
            break :blk result;
        },
        .Double => |d| blk: {
            const result = std.fmt.allocPrint(allocator, "{d}", .{d}) catch return EvaluatorError.OutOfMemory;
            break :blk result;
        },
        .Decimal128 => |dec| blk: {
            // Convert Decimal128 to string representation
            const float_val = @as(f64, @floatFromInt(dec.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(dec.scale));
            const result = std.fmt.allocPrint(allocator, "{d}", .{float_val}) catch return EvaluatorError.OutOfMemory;
            break :blk result;
        },
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };
    return Value{ .Text = str };
}

pub fn toInteger_val(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => val,
        .SmallInt => |i| Value{ .Int = i },
        .BigInt => |i| {
            if (i > std.math.maxInt(i64) or i < std.math.minInt(i64)) return EvaluatorError.Overflow;
            return Value{ .Int = @intCast(i) };
        },
        .Real => |f| {
            if (f > 9.223372e18 or f < -9.223372e18) return EvaluatorError.Overflow;
            return Value{ .Int = @intFromFloat(f) };
        },
        .Double => |d| {
            if (d > 9.223372036854775807e18 or d < -9.223372036854775808e18) return EvaluatorError.Overflow;
            return Value{ .Int = @intFromFloat(d) };
        },
        .Decimal128 => |dec| blk: {
            const float_val = @as(f64, @floatFromInt(dec.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(dec.scale));
            if (float_val > 9.223372036854775807e18 or float_val < -9.223372036854775808e18) return EvaluatorError.Overflow;
            break :blk Value{ .Int = @intFromFloat(float_val) };
        },
        .Bool => |b| Value{ .Int = if (b) 1 else 0 },
        .Str => |s| blk: {
            const result = std.fmt.parseInt(i64, s, 10) catch return EvaluatorError.InvalidFormat;
            break :blk Value{ .Int = result };
        },
        .Text => |s| blk: {
            const result = std.fmt.parseInt(i64, s, 10) catch return EvaluatorError.InvalidFormat;
            break :blk Value{ .Int = result };
        },
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn toReal_val(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Real => val,
        .Double => |d| {
            if (d > std.math.floatMax(f32) or d < -std.math.floatMax(f32)) return EvaluatorError.Overflow;
            return Value{ .Real = @floatCast(d) };
        },
        .Int => |i| Value{ .Real = @floatFromInt(i) },
        .SmallInt => |i| Value{ .Real = @floatFromInt(i) },
        .BigInt => |i| Value{ .Real = @floatFromInt(i) },
        .Str => |s| blk: {
            const result = std.fmt.parseFloat(f32, s) catch return EvaluatorError.InvalidFormat;
            break :blk Value{ .Real = result };
        },
        .Text => |s| blk: {
            const result = std.fmt.parseFloat(f32, s) catch return EvaluatorError.InvalidFormat;
            break :blk Value{ .Real = result };
        },
        else => EvaluatorError.TypeMismatch,
    };
}
