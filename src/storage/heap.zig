const std = @import("std");
const datetime = @import("../types/datetime.zig");
const decimal128 = @import("../types/decimal128.zig");
const jsonb = @import("../types/jsonb.zig");
const xml = @import("../types/xml.zig");
const url = @import("../types/url.zig");
const uuid = @import("../types/uuid.zig");
const arrays = @import("../types/arrays.zig");
const bitstring = @import("../types/bitstring.zig");
const range = @import("../types/range.zig");

pub const Value = union(enum) {
    // Legacy types (tags 0x00-0x19)
    Null: void,
    Bool: bool,
    Int: i64,
    Str: []const u8,
    IpAddr: IpAddr,
    Subnet: Subnet,
    Mac: Mac,
    Hash: Hash,
    Currency: Currency,
    LanguageTag: LanguageTag,
    LatLon: LatLon,
    LatLonAlt: LatLonAlt,
    Geometry: Geometry,
    Temperature: Temperature,
    Pressure: Pressure,
    VectorF32: VectorF32,
    VectorI32: VectorI32,

    // Additional data types (tags >= 0x20)
    SmallInt: i16,
    BigInt: i64,
    Real: f32,
    Double: f64,
    Decimal128: decimal128.Decimal128,
    Char: struct { data: []const u8, n: u16 },
    Varchar: struct { data: []const u8, n: u16 },
    Text: []const u8,
    Date: datetime.Date,
    Time: datetime.Time,
    TimeTZ: datetime.TimeTZ,
    Timestamp: datetime.Timestamp,
    TimestampTZ: datetime.TimestampTZ,
    Interval: datetime.Interval,
    Bytea: []const u8,
    Json: []const u8,
    Jsonb: jsonb.JsonbDocument,
    Xml: xml.XmlDocument,
    Url: url.Url,
    Domain: url.Domain,
    UUID: uuid.UUID,
    Enum: struct { type_id: u32, value_ordinal: u32 },
    Array: arrays.DynamicArray,
    BitString: bitstring.BitString,
    VarBit: bitstring.BitString,
    IntRange: range.IntRange,
};

pub const IpAddr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
};

pub const Subnet = struct {
    addr: IpAddr,
    prefix_len: u8,
};

pub const Mac = struct {
    bytes: [6]u8,
};

pub const Hash = struct {
    alg: HashAlg,
    digest: []const u8,
    // For Argon2, we may need to store salt and params
    salt: ?[]const u8 = null,
    params: ?Argon2Params = null,
};

pub const HashAlg = enum(u8) {
    SHA3_256 = 0,
    SHA3_512 = 1,
    BLAKE3 = 2,
    BLAKE2B_256 = 3,
    BLAKE2B_512 = 4,
    BLAKE2S_256 = 5,
    ARGON2ID = 6,
};

pub const Argon2Params = struct {
    iterations: u32 = 3,
    memory_kb: u32 = 4096,
    parallelism: u8 = 1,
};

pub const Currency = struct {
    code: [3]u8,
};

pub const LanguageTag = struct {
    tag: []const u8,
};

pub const LatLon = struct {
    lat: f64,
    lon: f64,
};

pub const LatLonAlt = struct {
    lat: f64,
    lon: f64,
    alt: f64,
    ref: AltRef,
};

pub const AltRef = enum(u8) {
    ellipsoid = 0,
    geoid = 1,
};

pub const Geometry = struct {
    wkb: []const u8,
};

pub const Temperature = struct {
    value_K: f64,
    unit_in: TempUnit,
};

pub const TempUnit = enum(u8) {
    K = 0,
    C = 1,
    F = 2,
};

pub const Pressure = struct {
    value_Pa: f64,
    unit_in: PressureUnit,
};

pub const PressureUnit = enum(u8) {
    Pa = 0,
    kPa = 1,
    bar = 2,
    atm = 3,
};

pub const VectorF32 = struct {
    dim: u16,
    data: []const f32,
};

// CANARY: REQ=REQ-VECTOR-I32-001; FEATURE="VectorI32"; ASPECT=IntegerVectorType; STATUS=IMPL; OWNER=storage; UPDATED=2025-12-23
pub const VectorI32 = struct {
    dim: u16,
    data: []const i32,
};

pub fn encodeValue(allocator: std.mem.Allocator, v: Value) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    switch (v) {
        .Null => {
            try buf.append(0x00);
        },
        .Bool => |b| {
            try buf.append(0x01);
            try buf.append(if (b) 1 else 0);
        },
        .Int => |i| {
            try buf.append(0x02);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &tmp, i, .little);
            try buf.appendSlice(&tmp);
        },
        .Str => |s| {
            try buf.append(0x03);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(s.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(s);
        },
        .IpAddr => |ip| {
            switch (ip) {
                .v4 => |bytes| {
                    try buf.append(0x04); // TAG_IPv4
                    try buf.appendSlice(&bytes);
                },
                .v6 => |bytes| {
                    try buf.append(0x05); // TAG_IPv6
                    try buf.appendSlice(&bytes);
                },
            }
        },
        .Subnet => |subnet| {
            switch (subnet.addr) {
                .v4 => |bytes| {
                    try buf.append(0x06); // TAG_Subnet4
                    try buf.appendSlice(&bytes);
                    try buf.append(subnet.prefix_len);
                },
                .v6 => |bytes| {
                    try buf.append(0x07); // TAG_Subnet6
                    try buf.appendSlice(&bytes);
                    try buf.append(subnet.prefix_len);
                },
            }
        },
        .Mac => |mac| {
            try buf.append(0x08); // TAG_Mac
            try buf.appendSlice(&mac.bytes);
        },
        .Hash => |hash| {
            try buf.append(0x09); // TAG_Hash
            try buf.append(@intFromEnum(hash.alg));
            try buf.appendSlice(hash.digest);
        },
        .Currency => |cur| {
            try buf.append(0x0A); // TAG_Currency
            try buf.appendSlice(&cur.code);
        },
        .LanguageTag => |lang| {
            try buf.append(0x0B); // TAG_LangTag
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(lang.tag.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(lang.tag);
        },
        .LatLon => |ll| {
            if (std.math.isNan(ll.lat) or std.math.isNan(ll.lon)) return error.FloatNaN;
            if (std.math.isInf(ll.lat) or std.math.isInf(ll.lon)) return error.FloatNaN;
            try buf.append(0x0C); // TAG_LatLon
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u64, &tmp, @bitCast(ll.lat), .little);
            try buf.appendSlice(&tmp);
            std.mem.writeInt(u64, &tmp, @bitCast(ll.lon), .little);
            try buf.appendSlice(&tmp);
        },
        .LatLonAlt => |lla| {
            if (std.math.isNan(lla.lat) or std.math.isNan(lla.lon) or std.math.isNan(lla.alt)) return error.FloatNaN;
            if (std.math.isInf(lla.lat) or std.math.isInf(lla.lon) or std.math.isInf(lla.alt)) return error.FloatNaN;
            try buf.append(0x0D); // TAG_LatLonAlt
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u64, &tmp, @bitCast(lla.lat), .little);
            try buf.appendSlice(&tmp);
            std.mem.writeInt(u64, &tmp, @bitCast(lla.lon), .little);
            try buf.appendSlice(&tmp);
            std.mem.writeInt(u64, &tmp, @bitCast(lla.alt), .little);
            try buf.appendSlice(&tmp);
            try buf.append(@intFromEnum(lla.ref));
        },
        .Geometry => |geom| {
            try buf.append(0x0E); // TAG_Geom
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(geom.wkb.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(geom.wkb);
        },
        .Temperature => |temp| {
            if (std.math.isNan(temp.value_K)) return error.FloatNaN;
            if (std.math.isInf(temp.value_K)) return error.FloatNaN;
            try buf.append(0x0F); // TAG_Temp
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u64, &tmp, @bitCast(temp.value_K), .little);
            try buf.appendSlice(&tmp);
            try buf.append(@intFromEnum(temp.unit_in));
        },
        .Pressure => |press| {
            if (std.math.isNan(press.value_Pa)) return error.FloatNaN;
            if (std.math.isInf(press.value_Pa)) return error.FloatNaN;
            try buf.append(0x10); // TAG_Press
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u64, &tmp, @bitCast(press.value_Pa), .little);
            try buf.appendSlice(&tmp);
            try buf.append(@intFromEnum(press.unit_in));
        },
        .VectorF32 => |vec| {
            try buf.append(0x11); // TAG_VecF32
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, vec.dim, .little);
            try buf.appendSlice(&tmp);
            for (vec.data) |f| {
                if (std.math.isNan(f)) return error.FloatNaN;
                if (std.math.isInf(f)) return error.FloatNaN;
                var ftmp: [4]u8 = undefined;
                std.mem.writeInt(u32, &ftmp, @bitCast(f), .little);
                try buf.appendSlice(&ftmp);
            }
        },
        .VectorI32 => |vec| {
            try buf.append(0x12); // TAG_VecI32
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, vec.dim, .little);
            try buf.appendSlice(&tmp);
            for (vec.data) |i| {
                var itmp: [4]u8 = undefined;
                std.mem.writeInt(i32, &itmp, i, .little);
                try buf.appendSlice(&itmp);
            }
        },
        // Additional data types (tags >= 0x20)
        .SmallInt => |i| {
            try buf.append(0x20);
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(i16, &tmp, i, .little);
            try buf.appendSlice(&tmp);
        },
        .BigInt => |i| {
            try buf.append(0x21);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &tmp, i, .little);
            try buf.appendSlice(&tmp);
        },
        .Real => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) return error.FloatNaN;
            try buf.append(0x22);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @bitCast(f), .little);
            try buf.appendSlice(&tmp);
        },
        .Double => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) return error.FloatNaN;
            try buf.append(0x23);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u64, &tmp, @bitCast(f), .little);
            try buf.appendSlice(&tmp);
        },
        .Decimal128 => |d| {
            try buf.append(0x24);
            var tmp: [16]u8 = undefined;
            std.mem.writeInt(i128, &tmp, d.coeff, .little);
            try buf.appendSlice(&tmp);
            var scale_tmp: [2]u8 = undefined;
            std.mem.writeInt(i16, &scale_tmp, d.scale, .little);
            try buf.appendSlice(&scale_tmp);
        },
        .Char => |ch| {
            try buf.append(0x25);
            var n_tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &n_tmp, ch.n, .little);
            try buf.appendSlice(&n_tmp);
            var len_tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_tmp, @intCast(ch.data.len), .little);
            try buf.appendSlice(&len_tmp);
            try buf.appendSlice(ch.data);
        },
        .Varchar => |vc| {
            try buf.append(0x26);
            var n_tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &n_tmp, vc.n, .little);
            try buf.appendSlice(&n_tmp);
            var len_tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_tmp, @intCast(vc.data.len), .little);
            try buf.appendSlice(&len_tmp);
            try buf.appendSlice(vc.data);
        },
        .Text => |s| {
            try buf.append(0x27);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(s.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(s);
        },
        .Date => |d| {
            try buf.append(0x28);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(i32, &tmp, d.days_since_epoch, .little);
            try buf.appendSlice(&tmp);
        },
        .Time => |t| {
            try buf.append(0x29);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &tmp, t.micros_since_midnight, .little);
            try buf.appendSlice(&tmp);
        },
        .TimeTZ => |tz| {
            try buf.append(0x2A);
            var time_tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &time_tmp, tz.time.micros_since_midnight, .little);
            try buf.appendSlice(&time_tmp);
            var offset_tmp: [4]u8 = undefined;
            std.mem.writeInt(i32, &offset_tmp, tz.offset_seconds, .little);
            try buf.appendSlice(&offset_tmp);
        },
        .Timestamp => |ts| {
            try buf.append(0x2B);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &tmp, ts.micros_since_epoch, .little);
            try buf.appendSlice(&tmp);
        },
        .TimestampTZ => |tsz| {
            try buf.append(0x2C);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &tmp, tsz.micros_since_epoch_utc, .little);
            try buf.appendSlice(&tmp);
        },
        .Interval => |iv| {
            try buf.append(0x2D);
            var months_tmp: [4]u8 = undefined;
            std.mem.writeInt(i32, &months_tmp, iv.months, .little);
            try buf.appendSlice(&months_tmp);
            var days_tmp: [4]u8 = undefined;
            std.mem.writeInt(i32, &days_tmp, iv.days, .little);
            try buf.appendSlice(&days_tmp);
            var micros_tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &micros_tmp, iv.micros, .little);
            try buf.appendSlice(&micros_tmp);
        },
        .Bytea => |b| {
            try buf.append(0x2E);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(b.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(b);
        },
        .Json => |j| {
            try buf.append(0x2F);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(j.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(j);
        },
        .Jsonb => |jb| {
            try buf.append(0x30);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(jb.data.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(jb.data);
        },
        .Xml => |x| {
            try buf.append(0x31);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(x.data.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(x.data);
        },
        .Url => |u| {
            try buf.append(0x32);
            const url_str = try u.toString(allocator);
            defer allocator.free(url_str);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(url_str.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(url_str);
        },
        .Domain => |d| {
            try buf.append(0x33);
            const domain_str = try d.toString(allocator);
            defer allocator.free(domain_str);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(domain_str.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(domain_str);
        },
        .UUID => |u| {
            try buf.append(0x34);
            try buf.appendSlice(&u.bytes);
        },
        .Enum => |e| {
            try buf.append(0x35);
            var type_tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &type_tmp, e.type_id, .little);
            try buf.appendSlice(&type_tmp);
            var ord_tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &ord_tmp, e.value_ordinal, .little);
            try buf.appendSlice(&ord_tmp);
        },
        .Array => |a| {
            try buf.append(0x36);
            var type_tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &type_tmp, @intFromEnum(a.elem_type), .little);
            try buf.appendSlice(&type_tmp);
            var count_tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &count_tmp, @intCast(a.length()), .little);
            try buf.appendSlice(&count_tmp);
            try buf.appendSlice(a.data);
        },
        .BitString => |bs| {
            try buf.append(0x37);
            var len_tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_tmp, bs.bit_length, .little);
            try buf.appendSlice(&len_tmp);
            try buf.appendSlice(bs.bytes);
        },
        .VarBit => |vb| {
            try buf.append(0x38);
            var len_tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_tmp, vb.bit_length, .little);
            try buf.appendSlice(&len_tmp);
            try buf.appendSlice(vb.bytes);
        },
        .IntRange => |r| {
            try buf.append(0x39);
            var bounds_tmp: [1]u8 = undefined;
            bounds_tmp[0] = @intFromEnum(r.bounds);
            try buf.appendSlice(&bounds_tmp);

            const has_lower = r.lower != null;
            const has_upper = r.upper != null;
            try buf.append(if (has_lower) 1 else 0);
            try buf.append(if (has_upper) 1 else 0);

            if (has_lower) {
                var val_tmp: [4]u8 = undefined;
                std.mem.writeInt(i32, &val_tmp, r.lower.?, .little);
                try buf.appendSlice(&val_tmp);
            }
            if (has_upper) {
                var val_tmp: [4]u8 = undefined;
                std.mem.writeInt(i32, &val_tmp, r.upper.?, .little);
                try buf.appendSlice(&val_tmp);
            }
        },
    }
    return buf.toOwnedSlice();
}

pub fn decodeValue(allocator: std.mem.Allocator, bytes: []const u8) !Value {
    if (bytes.len == 0) return error.Underflow;
    const tag = bytes[0];
    switch (tag) {
        0x00 => return .{ .Null = {} },
        0x01 => {
            if (bytes.len < 2) return error.Underflow;
            return .{ .Bool = (bytes[1] != 0) };
        },
        0x02 => {
            if (bytes.len < 1 + 8) return error.Underflow;
            const i = std.mem.readInt(i64, bytes[1 .. 1 + 8][0..8], .little);
            return .{ .Int = i };
        },
        0x03 => {
            if (bytes.len < 1 + 4) return error.Underflow;
            const n = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const nn: usize = @intCast(n);
            if (bytes.len < 5 + nn) return error.Underflow;
            const s = try allocator.dupe(u8, bytes[5 .. 5 + nn]);
            return .{ .Str = s };
        },
        0x04 => { // TAG_IPv4
            if (bytes.len < 1 + 4) return error.Underflow;
            var addr: [4]u8 = undefined;
            @memcpy(&addr, bytes[1..5]);
            return .{ .IpAddr = .{ .v4 = addr } };
        },
        0x05 => { // TAG_IPv6
            if (bytes.len < 1 + 16) return error.Underflow;
            var addr: [16]u8 = undefined;
            @memcpy(&addr, bytes[1..17]);
            return .{ .IpAddr = .{ .v6 = addr } };
        },
        0x06 => { // TAG_Subnet4
            if (bytes.len < 1 + 4 + 1) return error.Underflow;
            var addr: [4]u8 = undefined;
            @memcpy(&addr, bytes[1..5]);
            const prefix_len = bytes[5];
            if (prefix_len > 32) return error.InvalidPrefix;
            return .{ .Subnet = .{ .addr = .{ .v4 = addr }, .prefix_len = prefix_len } };
        },
        0x07 => { // TAG_Subnet6
            if (bytes.len < 1 + 16 + 1) return error.Underflow;
            var addr: [16]u8 = undefined;
            @memcpy(&addr, bytes[1..17]);
            const prefix_len = bytes[17];
            if (prefix_len > 128) return error.InvalidPrefix;
            return .{ .Subnet = .{ .addr = .{ .v6 = addr }, .prefix_len = prefix_len } };
        },
        0x08 => { // TAG_Mac
            if (bytes.len < 1 + 6) return error.Underflow;
            var mac: [6]u8 = undefined;
            @memcpy(&mac, bytes[1..7]);
            return .{ .Mac = .{ .bytes = mac } };
        },
        0x09 => { // TAG_Hash
            if (bytes.len < 1 + 1) return error.Underflow;
            const alg_code = bytes[1];
            const alg = std.meta.intToEnum(HashAlg, alg_code) catch return error.InvalidHashAlg;
            const digest_len: usize = switch (alg) {
                .SHA3_256 => 32,
                .SHA3_512 => 64,
                .BLAKE3 => 32,
            };
            if (bytes.len < 1 + 1 + digest_len) return error.Underflow;
            const digest = try allocator.dupe(u8, bytes[2 .. 2 + digest_len]);
            return .{ .Hash = .{ .alg = alg, .digest = digest } };
        },
        0x0A => { // TAG_Currency
            if (bytes.len < 1 + 3) return error.Underflow;
            var code: [3]u8 = undefined;
            @memcpy(&code, bytes[1..4]);
            return .{ .Currency = .{ .code = code } };
        },
        0x0B => { // TAG_LangTag
            if (bytes.len < 1 + 4) return error.Underflow;
            const n = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const nn: usize = @intCast(n);
            if (bytes.len < 5 + nn) return error.Underflow;
            const lang_tag_dup = try allocator.dupe(u8, bytes[5 .. 5 + nn]);
            return .{ .LanguageTag = .{ .tag = lang_tag_dup } };
        },
        0x0C => { // TAG_LatLon
            if (bytes.len < 1 + 16) return error.Underflow;
            const lat_bits = std.mem.readInt(u64, bytes[1..9][0..8], .little);
            const lon_bits = std.mem.readInt(u64, bytes[9..17][0..8], .little);
            return .{ .LatLon = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits) } };
        },
        0x0D => { // TAG_LatLonAlt
            if (bytes.len < 1 + 24 + 1) return error.Underflow;
            const lat_bits = std.mem.readInt(u64, bytes[1..9][0..8], .little);
            const lon_bits = std.mem.readInt(u64, bytes[9..17][0..8], .little);
            const alt_bits = std.mem.readInt(u64, bytes[17..25][0..8], .little);
            const ref_code = bytes[25];
            const ref = std.meta.intToEnum(AltRef, ref_code) catch return error.InvalidAltRef;
            return .{ .LatLonAlt = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits), .alt = @bitCast(alt_bits), .ref = ref } };
        },
        0x0E => { // TAG_Geom
            if (bytes.len < 1 + 4) return error.Underflow;
            const n = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const nn: usize = @intCast(n);
            if (bytes.len < 5 + nn) return error.Underflow;
            const wkb = try allocator.dupe(u8, bytes[5 .. 5 + nn]);
            return .{ .Geometry = .{ .wkb = wkb } };
        },
        0x0F => { // TAG_Temp
            if (bytes.len < 1 + 8 + 1) return error.Underflow;
            const value_bits = std.mem.readInt(u64, bytes[1..9][0..8], .little);
            const unit_code = bytes[9];
            const unit = std.meta.intToEnum(TempUnit, unit_code) catch return error.InvalidTempUnit;
            return .{ .Temperature = .{ .value_K = @bitCast(value_bits), .unit_in = unit } };
        },
        0x10 => { // TAG_Press
            if (bytes.len < 1 + 8 + 1) return error.Underflow;
            const value_bits = std.mem.readInt(u64, bytes[1..9][0..8], .little);
            const unit_code = bytes[9];
            const unit = std.meta.intToEnum(PressureUnit, unit_code) catch return error.InvalidPressureUnit;
            return .{ .Pressure = .{ .value_Pa = @bitCast(value_bits), .unit_in = unit } };
        },
        0x11 => { // TAG_VecF32
            if (bytes.len < 1 + 2) return error.Underflow;
            const dim = std.mem.readInt(u16, bytes[1..3][0..2], .little);
            const data_size = @as(usize, dim) * 4;
            if (bytes.len < 3 + data_size) return error.Underflow;
            var data = try allocator.alloc(f32, dim);
            var i: usize = 0;
            while (i < dim) : (i += 1) {
                const bits = std.mem.readInt(u32, bytes[3 + i * 4 .. 3 + i * 4 + 4][0..4], .little);
                data[i] = @bitCast(bits);
            }
            return .{ .VectorF32 = .{ .dim = dim, .data = data } };
        },
        0x12 => { // TAG_VecI32
            if (bytes.len < 1 + 2) return error.Underflow;
            const dim = std.mem.readInt(u16, bytes[1..3][0..2], .little);
            const data_size = @as(usize, dim) * 4;
            if (bytes.len < 3 + data_size) return error.Underflow;
            var data = try allocator.alloc(i32, dim);
            var i: usize = 0;
            while (i < dim) : (i += 1) {
                data[i] = std.mem.readInt(i32, bytes[3 + i * 4 .. 3 + i * 4 + 4][0..4], .little);
            }
            return .{ .VectorI32 = .{ .dim = dim, .data = data } };
        },
        // Additional data types (tags >= 0x20)
        0x20 => { // SmallInt
            if (bytes.len < 3) return error.Underflow;
            const i = std.mem.readInt(i16, bytes[1..3][0..2], .little);
            return .{ .SmallInt = i };
        },
        0x21 => { // BigInt
            if (bytes.len < 9) return error.Underflow;
            const i = std.mem.readInt(i64, bytes[1..9][0..8], .little);
            return .{ .BigInt = i };
        },
        0x22 => { // Real
            if (bytes.len < 5) return error.Underflow;
            const bits = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            return .{ .Real = @bitCast(bits) };
        },
        0x23 => { // Double
            if (bytes.len < 9) return error.Underflow;
            const bits = std.mem.readInt(u64, bytes[1..9][0..8], .little);
            return .{ .Double = @bitCast(bits) };
        },
        0x24 => { // Decimal128
            if (bytes.len < 19) return error.Underflow;
            const coeff = std.mem.readInt(i128, bytes[1..17][0..16], .little);
            const scale = std.mem.readInt(i16, bytes[17..19][0..2], .little);
            return .{ .Decimal128 = decimal128.Decimal128{ .coeff = coeff, .scale = scale } };
        },
        0x25 => { // Char
            if (bytes.len < 7) return error.Underflow;
            const n = std.mem.readInt(u16, bytes[1..3][0..2], .little);
            const len = std.mem.readInt(u32, bytes[3..7][0..4], .little);
            if (bytes.len < 7 + len) return error.Underflow;
            const data = try allocator.dupe(u8, bytes[7 .. 7 + len]);
            return .{ .Char = .{ .data = data, .n = n } };
        },
        0x26 => { // Varchar
            if (bytes.len < 7) return error.Underflow;
            const n = std.mem.readInt(u16, bytes[1..3][0..2], .little);
            const len = std.mem.readInt(u32, bytes[3..7][0..4], .little);
            if (bytes.len < 7 + len) return error.Underflow;
            const data = try allocator.dupe(u8, bytes[7 .. 7 + len]);
            return .{ .Varchar = .{ .data = data, .n = n } };
        },
        0x27 => { // Text
            if (bytes.len < 5) return error.Underflow;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            if (bytes.len < 5 + len) return error.Underflow;
            const data = try allocator.dupe(u8, bytes[5 .. 5 + len]);
            return .{ .Text = data };
        },
        0x28 => { // Date
            if (bytes.len < 5) return error.Underflow;
            const days = std.mem.readInt(i32, bytes[1..5][0..4], .little);
            return .{ .Date = datetime.Date{ .days_since_epoch = days } };
        },
        0x29 => { // Time
            if (bytes.len < 9) return error.Underflow;
            const micros = std.mem.readInt(i64, bytes[1..9][0..8], .little);
            return .{ .Time = datetime.Time{ .micros_since_midnight = micros } };
        },
        0x2A => { // TimeTZ
            if (bytes.len < 13) return error.Underflow;
            const micros = std.mem.readInt(i64, bytes[1..9][0..8], .little);
            const offset = std.mem.readInt(i32, bytes[9..13][0..4], .little);
            return .{ .TimeTZ = datetime.TimeTZ{ .time = .{ .micros_since_midnight = micros }, .offset_seconds = offset } };
        },
        0x2B => { // Timestamp
            if (bytes.len < 9) return error.Underflow;
            const micros = std.mem.readInt(i64, bytes[1..9][0..8], .little);
            return .{ .Timestamp = datetime.Timestamp{ .micros_since_epoch = micros } };
        },
        0x2C => { // TimestampTZ
            if (bytes.len < 9) return error.Underflow;
            const micros = std.mem.readInt(i64, bytes[1..9][0..8], .little);
            return .{ .TimestampTZ = datetime.TimestampTZ{ .micros_since_epoch_utc = micros } };
        },
        0x2D => { // Interval
            if (bytes.len < 17) return error.Underflow;
            const months = std.mem.readInt(i32, bytes[1..5][0..4], .little);
            const days = std.mem.readInt(i32, bytes[5..9][0..4], .little);
            const micros = std.mem.readInt(i64, bytes[9..17][0..8], .little);
            return .{ .Interval = datetime.Interval{ .months = months, .days = days, .micros = micros } };
        },
        0x2E => { // Bytea
            if (bytes.len < 5) return error.Underflow;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            if (bytes.len < 5 + len) return error.Underflow;
            const data = try allocator.dupe(u8, bytes[5 .. 5 + len]);
            return .{ .Bytea = data };
        },
        0x2F => { // Json
            if (bytes.len < 5) return error.Underflow;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            if (bytes.len < 5 + len) return error.Underflow;
            const data = try allocator.dupe(u8, bytes[5 .. 5 + len]);
            return .{ .Json = data };
        },
        0x30 => { // Jsonb
            if (bytes.len < 5) return error.Underflow;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            if (bytes.len < 5 + len) return error.Underflow;
            const data = try allocator.dupe(u8, bytes[5 .. 5 + len]);
            return .{ .Jsonb = jsonb.JsonbDocument{ .data = data, .allocator = allocator } };
        },
        0x31 => { // Xml
            if (bytes.len < 5) return error.Underflow;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            if (bytes.len < 5 + len) return error.Underflow;
            const data = try allocator.dupe(u8, bytes[5 .. 5 + len]);
            return .{ .Xml = xml.XmlDocument{ .data = data } };
        },
        0x32 => { // Url
            if (bytes.len < 5) return error.Underflow;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            if (bytes.len < 5 + len) return error.Underflow;
            const url_str = bytes[5 .. 5 + len];
            const parsed_url = try url.Url.fromString(allocator, url_str);
            return .{ .Url = parsed_url };
        },
        0x33 => { // Domain
            if (bytes.len < 5) return error.Underflow;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            if (bytes.len < 5 + len) return error.Underflow;
            const domain_str = bytes[5 .. 5 + len];
            const parsed_domain = try url.Domain.fromString(allocator, domain_str);
            return .{ .Domain = parsed_domain };
        },
        0x34 => { // UUID
            if (bytes.len < 17) return error.Underflow;
            var uuid_bytes: [16]u8 = undefined;
            @memcpy(&uuid_bytes, bytes[1..17]);
            return .{ .UUID = uuid.UUID{ .bytes = uuid_bytes } };
        },
        0x35 => { // Enum
            if (bytes.len < 9) return error.Underflow;
            const type_id = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const value_ordinal = std.mem.readInt(u32, bytes[5..9][0..4], .little);
            return .{ .Enum = .{ .type_id = type_id, .value_ordinal = value_ordinal } };
        },
        0x36 => { // Array
            if (bytes.len < 7) return error.Underflow;
            const elem_type_code = std.mem.readInt(u16, bytes[1..3][0..2], .little);
            const elem_type = std.meta.intToEnum(arrays.DynamicArray.ElemType, elem_type_code) catch return error.InvalidArrayType;
            const count = std.mem.readInt(u32, bytes[3..7][0..4], .little);
            _ = count;
            const data_start = 7;
            const data_len = bytes.len - data_start;
            const data = try allocator.dupe(u8, bytes[data_start .. data_start + data_len]);
            return .{ .Array = arrays.DynamicArray{ .elem_type = elem_type, .data = data, .allocator = allocator } };
        },
        0x37 => { // BitString
            if (bytes.len < 5) return error.Underflow;
            const bit_length = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const byte_len = (bit_length + 7) / 8;
            if (bytes.len < 5 + byte_len) return error.Underflow;
            const bit_bytes = try allocator.dupe(u8, bytes[5 .. 5 + byte_len]);
            return .{ .BitString = bitstring.BitString{ .bit_length = bit_length, .bytes = bit_bytes } };
        },
        0x38 => { // VarBit
            if (bytes.len < 5) return error.Underflow;
            const bit_length = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const byte_len = (bit_length + 7) / 8;
            if (bytes.len < 5 + byte_len) return error.Underflow;
            const bit_bytes = try allocator.dupe(u8, bytes[5 .. 5 + byte_len]);
            return .{ .VarBit = bitstring.BitString{ .bit_length = bit_length, .bytes = bit_bytes } };
        },
        0x39 => { // IntRange
            if (bytes.len < 4) return error.Underflow;
            const bounds_code = bytes[1];
            const bounds = std.meta.intToEnum(range.IntRange.Bounds, bounds_code) catch return error.InvalidRangeBounds;
            const has_lower = bytes[2] != 0;
            const has_upper = bytes[3] != 0;

            var offset: usize = 4;
            var lower: ?i32 = null;
            var upper: ?i32 = null;

            if (has_lower) {
                if (bytes.len < offset + 4) return error.Underflow;
                lower = std.mem.readInt(i32, bytes[offset .. offset + 4][0..4], .little);
                offset += 4;
            }
            if (has_upper) {
                if (bytes.len < offset + 4) return error.Underflow;
                upper = std.mem.readInt(i32, bytes[offset .. offset + 4][0..4], .little);
                offset += 4;
            }

            const int_range = try range.IntRange.init(lower, upper, bounds);
            return .{ .IntRange = int_range };
        },
        else => return error.TagUnknown,
    }
}
