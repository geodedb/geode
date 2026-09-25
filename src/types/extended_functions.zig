const std = @import("std");
const ext = @import("extended.zig");
const decimal128 = @import("decimal128.zig");
const cb = @import("crypto_backend");
// DATE-PART-EXACT: date_part must use the SAME calendar conversion that member access
// (`date(...).month`) uses, so it shares datetime.Date rather than
// re-approximating one.
const datetime = @import("datetime.zig");

// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=ENGINE; STATUS=TESTED; TEST=tests/types/extended_functions.zig; OWNER=engine; UPDATED=2025-09-26

// Zig 0.16: std.Io.fixedBufferStream was removed. Minimal in-memory buffer
// writer that implements writeAll for use with ext.formatUuid and similar
// functions that accept an anytype writer.
const FixedBufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn writeAll(self: *FixedBufWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }
};

// Built-in style function value union (re-uses ext.Value for return values where possible)
pub const BuiltinValue = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    Str: []const u8,
    Decimal: ext.Decimal,
    Uuid: ext.Uuid,
    Date: ext.Date,
    Time: ext.Time,
    Timestamp: ext.Timestamp,
    Duration: ext.Duration,
    Json: ext.Json,
    GeoBox: ext.GeoBox,
    GeoPolygon: ext.GeoPolygon,
    VectorF64: ext.VectorF64,
};

pub const FnPtr = *const fn (allocator: std.mem.Allocator, args: []const BuiltinValue) anyerror!BuiltinValue;

pub const Registry = std.StringHashMap(FnPtr);

pub fn initRegistry(allocator: std.mem.Allocator) !Registry {
    var r = Registry.init(allocator);
    try r.put("uuid_v4", &fn_uuid_v4);
    try r.put("geobox_contains", &fn_geobox_contains);
    try r.put("polygon_area", &fn_polygon_area);
    try r.put("vector_cosine", &fn_vector_cosine);
    try r.put("date_part", &fn_date_part);
    try r.put("time_part", &fn_time_part);
    try r.put("duration_add", &fn_duration_add);
    try r.put("duration_sub", &fn_duration_sub);
    try r.put("json_get", &fn_json_get);
    return r;
}

fn expectArgs(len: usize, args: []const BuiltinValue) !void {
    if (args.len != len) return error.InvalidArity;
}

// uuid_v4() -> Str (canonical text form)
fn fn_uuid_v4(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    try expectArgs(0, args);
    // RFC 4122 v4: 122 random bits. SONNY-2394: the bytes used to come from a
    // FIXED sequence (a Zig 0.15 stop-gap), so every call returned the same
    // "random" UUID. Draw them from the (FIPS-seamed) CSPRNG.
    var u: ext.Uuid = undefined;
    try cb.Csprng.bytes(&u.bytes);
    u.bytes[6] = (u.bytes[6] & 0x0F) | 0x40;
    u.bytes[8] = (u.bytes[8] & 0x3F) | 0x80;
    // Zig 0.16: std.Io.fixedBufferStream was removed. Use a minimal
    // buffer writer that implements writeAll for ext.formatUuid.
    var buf: [36]u8 = undefined;
    var bw = FixedBufWriter{ .buf = &buf };
    try ext.formatUuid(u, &bw);
    const slice = try allocator.dupe(u8, buf[0..bw.pos]);
    return .{ .Str = slice };
}

// geobox_contains(GeoBox, x: Decimal|Int, y: Decimal|Int)
fn fn_geobox_contains(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    _ = allocator;
    try expectArgs(3, args);
    if (args[0] != .GeoBox) return error.TypeMismatch;
    const box = args[0].GeoBox;
    const x = switch (args[1]) {
        .Int => |v| @as(f64, @floatFromInt(v)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };
    const y = switch (args[2]) {
        .Int => |v| @as(f64, @floatFromInt(v)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => return error.TypeMismatch,
    };
    const inside = ext.geoboxContains(box, .{ .x = x, .y = y });
    return .{ .Bool = inside };
}

// polygon_area(GeoPolygon) -> Decimal (scale 6)
fn fn_polygon_area(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    _ = allocator;
    try expectArgs(1, args);
    if (args[0] != .GeoPolygon) return error.TypeMismatch;
    const area = ext.polygonArea(.{ .points = args[0].GeoPolygon.points });
    // SONNY-2739: checked (22003) instead of a bare `@intFromFloat`.
    return .{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(area, 1_000_000.0), .scale = 6 } };
}

// vector_cosine(VectorF64, VectorF64) -> Decimal scale 6 (mirrors existing VectorF32 cosine semantics)
fn fn_vector_cosine(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    _ = allocator;
    try expectArgs(2, args);
    if (args[0] != .VectorF64 or args[1] != .VectorF64) return .{ .Null = {} };
    const sim = try ext.vectorCosine(args[0].VectorF64, args[1].VectorF64);
    return .{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(sim, 1_000_000.0), .scale = 6 } };
}

// CANARY: REQ=REQ-DATE-PART-EXACT-CALENDAR; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_DATE_PART; STATUS=TESTED; TEST=tests/test_date_part_exact.zig; OWNER=engine; UPDATED=2026-08-25
// date_part(part: Str, Date|Timestamp) -> Int
//
// DATE-PART-EXACT: this used to derive the components from `1970 + days/365` with
// 30-day months, so date_part('month', DATE '2024-12-31') answered 13 and
// date_part('day', …) answered 6 while `date('2024-12-31').month` (member
// access, which already went through the calendar-exact
// datetime.Date.dateFromDays) answered 12 / 31. Two different calendars for the
// same value. The exact conversion is now the only one.
fn fn_date_part(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    _ = allocator;
    try expectArgs(2, args);
    if (args[0] != .Str) return error.TypeMismatch;
    const part = args[0].Str;
    const days: i64 = switch (args[1]) {
        .Date => |d| d.days,
        // @divFloor (not @divTrunc): a pre-epoch timestamp truncating toward
        // zero would land on the wrong calendar day.
        .Timestamp => |t| @as(i64, @intCast(@divFloor(t.nanos, (24 * 60 * 60 * 1_000_000_000)))),
        else => return error.TypeMismatch,
    };
    if (days > std.math.maxInt(i32) or days < std.math.minInt(i32)) return error.TypeMismatch;
    const epoch_days: i32 = @intCast(days);
    const ymd = datetime.Date.dateFromDays(epoch_days);
    if (std.mem.eql(u8, part, "year")) return .{ .Int = ymd.year };
    if (std.mem.eql(u8, part, "month")) return .{ .Int = ymd.month };
    if (std.mem.eql(u8, part, "day")) return .{ .Int = ymd.day };
    if (std.mem.eql(u8, part, "doy")) {
        const jan1 = datetime.Date.daysSinceEpoch(ymd.year, 1, 1) catch return error.TypeMismatch;
        return .{ .Int = @as(i64, epoch_days - jan1) + 1 };
    }
    return error.UnknownDatePart;
}

// time_part(part: Str, Time|Timestamp) -> Int
fn fn_time_part(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    _ = allocator;
    try expectArgs(2, args);
    if (args[0] != .Str) return error.TypeMismatch;
    const part = args[0].Str;
    const nanos: i128 = switch (args[1]) {
        .Time => |t| t.nanos,
        .Timestamp => |ts| @mod(ts.nanos, (24 * 60 * 60 * 1_000_000_000)),
        else => return error.TypeMismatch,
    };
    const total_ns = @as(i64, @intCast(nanos));
    const hour = @mod(@divTrunc(total_ns, 3_600_000_000_000), 24);
    const minute = @mod(@divTrunc(total_ns, 60_000_000_000), 60);
    const second = @mod(@divTrunc(total_ns, 1_000_000_000), 60);
    const millis = @mod(@divTrunc(total_ns, 1_000_000), 1000);
    if (std.mem.eql(u8, part, "hour")) return .{ .Int = hour };
    if (std.mem.eql(u8, part, "minute")) return .{ .Int = minute };
    if (std.mem.eql(u8, part, "second")) return .{ .Int = second };
    if (std.mem.eql(u8, part, "millis")) return .{ .Int = millis };
    return error.UnknownTimePart;
}

// duration_add(Duration, Duration) -> Duration
fn fn_duration_add(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    _ = allocator;
    try expectArgs(2, args);
    if (args[0] != .Duration or args[1] != .Duration) return error.TypeMismatch;
    return .{ .Duration = .{ .nanos = args[0].Duration.nanos + args[1].Duration.nanos } };
}

// duration_sub(Duration, Duration) -> Duration
fn fn_duration_sub(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    _ = allocator;
    try expectArgs(2, args);
    if (args[0] != .Duration or args[1] != .Duration) return error.TypeMismatch;
    return .{ .Duration = .{ .nanos = args[0].Duration.nanos - args[1].Duration.nanos } };
}

// json_get(Json, key) -> Json (naive substring extraction for flat objects). If not found returns Null.
fn fn_json_get(allocator: std.mem.Allocator, args: []const BuiltinValue) !BuiltinValue {
    try expectArgs(2, args);
    if (args[0] != .Json or args[1] != .Str) return error.TypeMismatch;
    const text = args[0].Json.text;
    const key = args[1].Str;
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(pattern);
    if (std.mem.indexOf(u8, text, pattern)) |idx| {
        var i: usize = idx + pattern.len;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        if (i >= text.len) return .{ .Null = {} };
        // Capture until comma or closing brace at top level (naive; good for flat test JSON)
        const start = i;
        var in_string = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == '"' and (i == 0 or text[i - 1] != '\\')) in_string = !in_string;
            if (!in_string and (c == ',' or c == '}')) break;
        }
        const raw = text[start..i];
        const dup = try allocator.dupe(u8, raw);
        return .{ .Json = .{ .text = dup } };
    }
    return .{ .Null = {} };
}

// Helper constructors for tests (not exported in registry)
pub fn makeDate(days: i32) BuiltinValue {
    return .{ .Date = .{ .days = days } };
}
pub fn makeTime(nanos: u64) BuiltinValue {
    return .{ .Time = .{ .nanos = nanos } };
}
pub fn makeDuration(ns: i128) BuiltinValue {
    return .{ .Duration = .{ .nanos = ns } };
}
pub fn makeGeoBox(min_x: f64, min_y: f64, max_x: f64, max_y: f64) BuiltinValue {
    return .{ .GeoBox = .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y } };
}
pub fn makeGeoPolygon(points: []const ext.Point) BuiltinValue {
    return .{ .GeoPolygon = .{ .points = points } };
}
// ENG-3922(c): `dim` is a u16, so the cast below overflows above 65535. This
// helper is test-only, but the bound is the type's, not the caller's, and an
// unchecked narrowing cast is a panic wherever it lives.
pub fn makeVector(data: []const f64) error{VectorTooLarge}!BuiltinValue {
    if (data.len > std.math.maxInt(u16)) return error.VectorTooLarge;
    return .{ .VectorF64 = .{ .dim = @intCast(data.len), .data = data } };
}
pub fn makeJson(text: []const u8) BuiltinValue {
    return .{ .Json = .{ .text = text } };
}

fn freeValue(allocator: std.mem.Allocator, v: BuiltinValue) void {
    switch (v) {
        .Str => |s| allocator.free(s),
        .Json => |j| allocator.free(j.text),
        else => {},
    }
}

test "uuid_v4 random v4 format" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const fnp = reg.get("uuid_v4") orelse return error.NotFound;
    const v = try fnp(std.testing.allocator, &[_]BuiltinValue{});
    defer freeValue(std.testing.allocator, v);
    try std.testing.expect(v == .Str);
    try std.testing.expectEqual(@as(usize, 36), v.Str.len);
    try std.testing.expect(v.Str[14] == '4');
}

// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_UUID_V4; STATUS=TESTED; TEST=extended_functions.uuid_v4 random v4 format; OWNER=engine; UPDATED=2026-09-23

test "vector cosine identical" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const fnp = reg.get("vector_cosine") orelse return error.NotFound;
    const arr = [_]f64{ 1.0, 2.0, 3.0 };
    const a = try makeVector(&arr);
    const b = try makeVector(&arr);
    const v = try fnp(std.testing.allocator, &[_]BuiltinValue{ a, b });
    defer freeValue(std.testing.allocator, v);
    try std.testing.expect(v == .Decimal);
    try std.testing.expect(@abs(v.Decimal.coeff - 1_000_000) <= 1); // ~1.0
}
// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_VECTOR_COSINE; STATUS=TESTED; TEST=extended_functions.vector cosine identical; OWNER=engine; UPDATED=2025-09-26

test "vector cosine non-vector returns null" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const fnp = reg.get("vector_cosine") orelse return error.NotFound;
    // Pass non-vector args (Int values) — should return Null, not TypeMismatch error
    const v = try fnp(std.testing.allocator, &[_]BuiltinValue{ .{ .Int = 42 }, .{ .Int = 99 } });
    defer freeValue(std.testing.allocator, v);
    try std.testing.expect(v == .Null);
}

test "geobox contains true" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const fnp = reg.get("geobox_contains") orelse return error.NotFound;
    const box = makeGeoBox(0, 0, 10, 10);
    const inside = try fnp(std.testing.allocator, &[_]BuiltinValue{ box, .{ .Int = 5 }, .{ .Int = 6 } });
    defer freeValue(std.testing.allocator, inside);
    try std.testing.expect(inside == .Bool and inside.Bool);
}
// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_GEOBOX_CONTAINS; STATUS=TESTED; TEST=extended_functions.geobox contains true; OWNER=engine; UPDATED=2025-09-26

test "polygon area triangle" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const fnp = reg.get("polygon_area") orelse return error.NotFound;
    const pts = [_]ext.Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 3 } };
    const poly = makeGeoPolygon(&pts);
    const v = try fnp(std.testing.allocator, &[_]BuiltinValue{poly});
    defer freeValue(std.testing.allocator, v);
    try std.testing.expect(v == .Decimal);
    try std.testing.expect(@abs(v.Decimal.coeff - 6_000_000) <= 10); // 6.0 area
}
// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_POLYGON_AREA; STATUS=TESTED; TEST=extended_functions.polygon area triangle; OWNER=engine; UPDATED=2025-09-26

test "duration add/sub" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const add_fn = reg.get("duration_add") orelse return error.NotFound;
    const sub_fn = reg.get("duration_sub") orelse return error.NotFound;
    const a = makeDuration(1_000);
    const b = makeDuration(2_500);
    const sum = try add_fn(std.testing.allocator, &[_]BuiltinValue{ a, b });
    defer freeValue(std.testing.allocator, sum);
    try std.testing.expect(sum == .Duration and sum.Duration.nanos == 3_500);
    const diff = try sub_fn(std.testing.allocator, &[_]BuiltinValue{ b, a });
    defer freeValue(std.testing.allocator, diff);
    try std.testing.expect(diff == .Duration and diff.Duration.nanos == 1_500);
}
// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_DURATION_ARITH; STATUS=TESTED; TEST=extended_functions.duration add/sub; OWNER=engine; UPDATED=2025-09-26

test "json_get simple" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const fnp = reg.get("json_get") orelse return error.NotFound;
    const js = makeJson("{\"a\":1,\"b\":\"x\"}");
    const v = try fnp(std.testing.allocator, &[_]BuiltinValue{ js, .{ .Str = "b" } });
    defer freeValue(std.testing.allocator, v);
    try std.testing.expect(v == .Json);
    try std.testing.expect(std.mem.eql(u8, v.Json.text, "\"x\""));
}
// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_JSON_GET; STATUS=TESTED; TEST=extended_functions.json_get simple; OWNER=engine; UPDATED=2025-09-26

// DATE-PART-EXACT: renamed from "date_part coarse" — the conversion is no longer
// coarse, and the assertions now pin a leap-year boundary that the old
// 365-day-year / 30-day-month arithmetic got wrong.
test "date_part uses the exact proleptic Gregorian calendar" {
    var reg = try initRegistry(std.testing.allocator);
    defer reg.deinit();
    const fnp = reg.get("date_part") orelse return error.NotFound;

    const Case = struct { days: i32, year: i64, month: i64, day: i64, doy: i64 };
    const cases = [_]Case{
        .{ .days = 0, .year = 1970, .month = 1, .day = 1, .doy = 1 }, // epoch
        .{ .days = 365, .year = 1971, .month = 1, .day = 1, .doy = 1 },
        .{ .days = 19_722, .year = 2023, .month = 12, .day = 31, .doy = 365 },
        .{ .days = 19_723, .year = 2024, .month = 1, .day = 1, .doy = 1 },
        .{ .days = 19_782, .year = 2024, .month = 2, .day = 29, .doy = 60 }, // leap day
        .{ .days = 20_088, .year = 2024, .month = 12, .day = 31, .doy = 366 }, // leap year has 366 days
        .{ .days = 20_089, .year = 2025, .month = 1, .day = 1, .doy = 1 },
        .{ .days = -1, .year = 1969, .month = 12, .day = 31, .doy = 365 }, // pre-epoch
    };

    for (cases) |c| {
        const d = makeDate(c.days);
        inline for (.{ "year", "month", "day", "doy" }) |part| {
            const got = try fnp(std.testing.allocator, &[_]BuiltinValue{ .{ .Str = part }, d });
            defer freeValue(std.testing.allocator, got);
            const want = if (comptime std.mem.eql(u8, part, "year"))
                c.year
            else if (comptime std.mem.eql(u8, part, "month"))
                c.month
            else if (comptime std.mem.eql(u8, part, "day"))
                c.day
            else
                c.doy;
            try std.testing.expect(got == .Int);
            try std.testing.expectEqual(want, got.Int);
        }
    }
}
// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_DATE_PART; STATUS=TESTED; TEST=extended_functions.date_part uses the exact proleptic Gregorian calendar; OWNER=engine; UPDATED=2026-08-25
