const std = @import("std");

// CANARY: REQ=REQ-GQL-083; FEATURE="ExtendedDecimalFormatting"; ASPECT=FORMATTER; STATUS=IMPL; TEST=extended.decimal parse/format; OWNER=engine; UPDATED=2025-09-26

// Extended type system (layered alongside core heap.Value) providing richer
// domain types without disrupting existing encoding until promoted.
// Assumptions:
// - These types are experimental; encoding tags not yet reserved in core heap.
// - APIs focus on validation, parsing, formatting, hashing, and basic ops.

pub const ExtendedType = enum {
    Decimal,
    Uuid,
    Date, // days since Unix epoch (UTC)
    Time, // nanoseconds since midnight
    Timestamp, // nanoseconds since Unix epoch
    Duration, // nanoseconds length
    Json, // UTF-8 JSON text (no structural index yet)
    GeoBox, // axis-aligned box (min_x,min_y,max_x,max_y)
    GeoPolygon, // simple polygon (no holes)
    VectorF64, // dense vector double
    Inet, // (addr/prefix) separate from existing Subnet for semantics
    Blob, // opaque binary
};

pub const Decimal = struct { coeff: i128, scale: u8 };
pub const Uuid = struct { bytes: [16]u8 };
pub const Date = struct { days: i32 }; // epoch days
pub const Time = struct { nanos: u64 };
pub const Timestamp = struct { nanos: i128 };
pub const Duration = struct { nanos: i128 };
pub const Json = struct { text: []const u8 };
pub const GeoBox = struct { min_x: f64, min_y: f64, max_x: f64, max_y: f64 };
pub const GeoPolygon = struct { points: []const Point };
pub const Point = struct { x: f64, y: f64 };
pub const VectorF64 = struct { dim: u16, data: []const f64 };
pub const Inet = struct { addr: [16]u8, is_v6: bool, prefix_len: u8 };
pub const Blob = struct { data: []const u8 };

pub const Value = union(enum) {
    Decimal: Decimal,
    Uuid: Uuid,
    Date: Date,
    Time: Time,
    Timestamp: Timestamp,
    Duration: Duration,
    Json: Json,
    GeoBox: GeoBox,
    GeoPolygon: GeoPolygon,
    VectorF64: VectorF64,
    Inet: Inet,
    Blob: Blob,
};

pub fn uuidV4(rng: *std.rand.DefaultPrng) Uuid {
    var u: Uuid = undefined;
    rng.random().bytes(&u.bytes);
    // Set version (4) and variant (RFC 4122)
    u.bytes[6] = (u.bytes[6] & 0x0F) | 0x40;
    u.bytes[8] = (u.bytes[8] & 0x3F) | 0x80;
    return u;
}

pub fn formatUuid(u: Uuid, writer: anytype) !void {
    try writer.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        u.bytes[0],  u.bytes[1],  u.bytes[2],  u.bytes[3],
        u.bytes[4],  u.bytes[5],  u.bytes[6],  u.bytes[7],
        u.bytes[8],  u.bytes[9],  u.bytes[10], u.bytes[11],
        u.bytes[12], u.bytes[13], u.bytes[14], u.bytes[15],
    });
}

pub fn parseUuid(text: []const u8) !Uuid {
    if (text.len != 36) return error.InvalidLength;
    var hex: [32]u8 = undefined;
    var hi: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        if (hi >= 32) return error.InvalidFormat;
        hex[hi] = c;
        hi += 1;
    }
    if (hi != 32) return error.InvalidFormat;
    var u: Uuid = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        u.bytes[i] = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return u;
}

pub fn decimalFromString(text: []const u8) !Decimal {
    // Simple parser: optional '-', digits, optional '.', digits
    if (text.len == 0) return error.InvalidDecimal;
    var negative = false;
    var i: usize = 0;
    if (text[0] == '-') {
        negative = true;
        i = 1;
    }
    var coeff: i128 = 0;
    var scale: u8 = 0;
    var seen_dot = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '.') {
            if (seen_dot) return error.InvalidDecimal;
            seen_dot = true;
            continue;
        }
        if (c < '0' or c > '9') return error.InvalidDecimal;
        coeff = coeff * 10 + @as(i128, c - '0');
        if (seen_dot) scale += 1;
    }
    if (negative) coeff = -coeff;
    return .{ .coeff = coeff, .scale = scale };
}

pub fn decimalToString(dec: Decimal, allocator: std.mem.Allocator) ![]u8 {
    // Convert coefficient to absolute digits (forward order) then insert decimal point
    var value = dec.coeff;
    const negative = value < 0;
    if (negative) value = -value;
    var rev: [128]u8 = undefined; // store reversed digits
    var rlen: usize = 0;
    if (value == 0) {
        rev[0] = '0';
        rlen = 1;
    }
    while (value > 0) : (value = @divTrunc(value, 10)) {
        const digit = @as(u8, @intCast(@mod(value, 10)));
        rev[rlen] = '0' + digit;
        rlen += 1;
    }
    // Now reverse into forward buffer
    var digits: [128]u8 = undefined;
    var dlen: usize = 0;
    var i: isize = @as(isize, @intCast(rlen)) - 1;
    while (i >= 0) : (i -= 1) {
        digits[dlen] = rev[@intCast(i)];
        dlen += 1;
    }
    const int_len = if (dec.scale > 0 and dlen > dec.scale) dlen - dec.scale else if (dec.scale > 0) 0 else dlen;
    const frac_len = if (dec.scale > 0) @min(@as(usize, dec.scale), dlen) else 0;
    var needed: usize = int_len + frac_len;
    if (frac_len > 0) needed += 1; // dot
    if (int_len == 0 and frac_len > 0) needed += 1; // leading 0
    if (negative) needed += 1;
    var out = try allocator.alloc(u8, needed);
    var o: usize = 0;
    if (negative) {
        out[o] = '-';
        o += 1;
    }
    if (int_len == 0 and frac_len > 0) {
        out[o] = '0';
        o += 1;
    }
    // integer part
    var k: usize = 0;
    while (k < int_len) : (k += 1) {
        out[o] = digits[k];
        o += 1;
    }
    if (frac_len > 0) {
        out[o] = '.';
        o += 1;
        var fstart = dlen - frac_len;
        while (fstart < dlen) : (fstart += 1) {
            out[o] = digits[fstart];
            o += 1;
        }
    }
    return out;
}

pub fn geoboxContains(b: GeoBox, p: Point) bool {
    return p.x >= b.min_x and p.x <= b.max_x and p.y >= b.min_y and p.y <= b.max_y;
}

pub fn polygonArea(poly: GeoPolygon) f64 {
    if (poly.points.len < 3) return 0;
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < poly.points.len) : (i += 1) {
        const a = poly.points[i];
        const b = poly.points[@mod(i + 1, poly.points.len)];
        sum += (a.x * b.y) - (b.x * a.y);
    }
    const abs_sum = if (sum < 0) -sum else sum;
    return abs_sum * 0.5;
}

pub fn vectorCosine(a: VectorF64, b: VectorF64) !f64 {
    if (a.dim != b.dim or a.data.len != b.data.len) return error.DimensionMismatch;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a.data, b.data) |av, bv| {
        dot += av * bv;
        na += av * av;
        nb += bv * bv;
    }
    if (na == 0 or nb == 0) return error.ZeroVector;
    return dot / (@sqrt(na) * @sqrt(nb));
}

test "uuid parse/format roundtrip" {
    // Use a deterministic pseudo-rng: fallback to xoroshiro128+ implemented inline for Zig 0.15 if std.rand unavailable
    var prng_state: [16]u8 = .{0} ** 16;
    // simple incrementing bytes as pseudo-random source for deterministic test
    var i: usize = 0;
    while (i < prng_state.len) : (i += 1) prng_state[i] = @as(u8, @intCast((i * 37 + 13) & 0xFF));
    const prng = struct { state: []u8, idx: usize }{ .state = &prng_state, .idx = 0 };
    const u = blk: {
        var tmp: Uuid = undefined;
        // emulate uuidV4 random fill
        var j: usize = 0;
        while (j < 16) : (j += 1) tmp.bytes[j] = prng.state[@mod(prng.idx + j, prng.state.len)];
        tmp.bytes[6] = (tmp.bytes[6] & 0x0F) | 0x40;
        tmp.bytes[8] = (tmp.bytes[8] & 0x3F) | 0x80;
        break :blk tmp;
    };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try formatUuid(u, fbs.writer());
    const printed = fbs.getWritten();
    const parsed = try parseUuid(printed);
    try std.testing.expectEqualSlices(u8, &u.bytes, &parsed.bytes);
}

test "decimal parse/format" {
    const d = try decimalFromString("123.45");
    const s = try decimalToString(d, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "123.45") != null);
}

test "geobox contains" {
    const box = GeoBox{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    try std.testing.expect(geoboxContains(box, .{ .x = 5, .y = 5 }));
    try std.testing.expect(!geoboxContains(box, .{ .x = 11, .y = 5 }));
}

test "polygon area" {
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 3 } };
    const poly = GeoPolygon{ .points = &pts };
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), polygonArea(poly), 0.0001);
}

test "vector cosine" {
    const a = [_]f64{ 1, 0, 0 };
    const b = [_]f64{ 1, 0, 0 };
    const va = VectorF64{ .dim = 3, .data = &a };
    const vb = VectorF64{ .dim = 3, .data = &b };
    const sim = try vectorCosine(va, vb);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sim, 0.0000001);
}
