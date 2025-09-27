const std = @import("std");

pub const Value = union(enum) {
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
};

pub const HashAlg = enum(u8) {
    SHA3_256 = 0,
    SHA3_512 = 1,
    BLAKE3 = 2,
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

pub fn encodeValue(ally: std.mem.Allocator, v: Value) ![]u8 {
    var buf = std.ArrayList(u8).init(ally);
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
    }
    return buf.toOwnedSlice();
}

pub fn decodeValue(ally: std.mem.Allocator, bytes: []const u8) !Value {
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
            const s = try ally.dupe(u8, bytes[5 .. 5 + nn]);
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
            const digest = try ally.dupe(u8, bytes[2 .. 2 + digest_len]);
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
            const tag = try ally.dupe(u8, bytes[5 .. 5 + nn]);
            return .{ .LanguageTag = .{ .tag = tag } };
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
            return .{ .LatLonAlt = .{ 
                .lat = @bitCast(lat_bits), 
                .lon = @bitCast(lon_bits), 
                .alt = @bitCast(alt_bits),
                .ref = ref
            } };
        },
        0x0E => { // TAG_Geom
            if (bytes.len < 1 + 4) return error.Underflow;
            const n = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const nn: usize = @intCast(n);
            if (bytes.len < 5 + nn) return error.Underflow;
            const wkb = try ally.dupe(u8, bytes[5 .. 5 + nn]);
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
            var data = try ally.alloc(f32, dim);
            var i: usize = 0;
            while (i < dim) : (i += 1) {
                const bits = std.mem.readInt(u32, bytes[3 + i*4 .. 3 + i*4 + 4][0..4], .little);
                data[i] = @bitCast(bits);
            }
            return .{ .VectorF32 = .{ .dim = dim, .data = data } };
        },
        else => return error.TagUnknown,
    }
}
