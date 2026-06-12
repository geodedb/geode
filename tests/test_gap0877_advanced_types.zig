//! GAP-0877 regression: advanced-type semantics.
//!
//! CANARY: REQ=REQ-GAP-0877; FEATURE="AdvancedTypeSemantics"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0877_advanced_types.zig; OWNER=types; UPDATED=2026-06-11
//!
//! Pins the four GAP-0877 fixes:
//!  1. value_types.stringify renders canonical ISO-8601 for
//!     Date/Time/TimeTZ/Timestamp/TimestampTZ/Interval and the actual value
//!     for Url/Domain/Bytea (previously placeholder strings like "date").
//!  2. Unsupported geometry relation combinations return the stable
//!     error.UnsupportedGeometryRelation (previously silent false).
//!     LineString-LineString intersection and polygon edge-crossing are now
//!     real implementations.
//!  3. domain_root implements eTLD+1 with a bundled public-suffix snapshot
//!     (exact, wildcard, and exception rules; unknown TLD falls back to the
//!     last two labels).
//!  4. GeometryFromText (heap.Value constructor path) produces real WKB,
//!     never raw WKT bytes; unparseable WKT is a stable InvalidFormat error.

const std = @import("std");
const geode = @import("geode");

const value_types = geode.value_types;
const Value = value_types.Value;
const stringify = value_types.stringify;
const EvalError = value_types.EvalError;
const datetime = geode.types.datetime;
const url = geode.types.url;
const public_suffix = geode.types.public_suffix;
const wkt = geode.types.wkt;
const eval_ext = geode.eval_ext;
const ExtValue = eval_ext.ExtValue;
const eval_funcs = geode.types.evaluator_functions;

// ===========================================================================
// 1. Canonical stringify
// ===========================================================================

test "GAP-0877: Date stringifies as ISO-8601" {
    var buf: [64]u8 = undefined;
    const d = try datetime.Date.fromStr("2026-06-10");
    try std.testing.expectEqualStrings("2026-06-10", try stringify(.{ .Date = d }, &buf));
}

test "GAP-0877: Time stringifies as ISO-8601 (with and without micros)" {
    var buf: [64]u8 = undefined;
    const t1 = try datetime.Time.fromStr("13:45:30");
    try std.testing.expectEqualStrings("13:45:30", try stringify(.{ .Time = t1 }, &buf));
    const t2 = try datetime.Time.fromStr("13:45:30.123456");
    try std.testing.expectEqualStrings("13:45:30.123456", try stringify(.{ .Time = t2 }, &buf));
}

test "GAP-0877: TimeTZ stringifies with UTC offset" {
    var buf: [64]u8 = undefined;
    const t = try datetime.TimeTZ.fromStr("13:45:30+02:00");
    try std.testing.expectEqualStrings("13:45:30+02:00", try stringify(.{ .TimeTZ = t }, &buf));
    const tz = try datetime.TimeTZ.fromStr("01:02:03Z");
    try std.testing.expectEqualStrings("01:02:03+00:00", try stringify(.{ .TimeTZ = tz }, &buf));
}

test "GAP-0877: Timestamp stringifies as ISO-8601" {
    var buf: [64]u8 = undefined;
    const ts = try datetime.Timestamp.fromStr("2026-06-10T13:45:30");
    try std.testing.expectEqualStrings("2026-06-10T13:45:30", try stringify(.{ .Timestamp = ts }, &buf));
}

test "GAP-0877: TimestampTZ stringifies as ISO-8601 UTC" {
    var buf: [64]u8 = undefined;
    const ts = try datetime.TimestampTZ.fromStr("2026-06-10T13:45:30+02:00");
    try std.testing.expectEqualStrings("2026-06-10T11:45:30Z", try stringify(.{ .TimestampTZ = ts }, &buf));
}

test "GAP-0877: Interval stringifies as ISO-8601 duration" {
    var buf: [64]u8 = undefined;
    const iv = try datetime.Interval.fromStr("P1Y2M3DT4H5M6S");
    try std.testing.expectEqualStrings("P1Y2M3DT4H5M6S", try stringify(.{ .Interval = iv }, &buf));
    const zero = datetime.Interval{ .months = 0, .days = 0, .micros = 0 };
    try std.testing.expectEqualStrings("PT0S", try stringify(.{ .Interval = zero }, &buf));
}

test "GAP-0877: Url stringifies its actual value" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const u = try url.Url.fromString(allocator, "https://Example.COM/path?q=1#frag");
    defer {
        allocator.free(u.scheme);
        allocator.free(u.host);
        allocator.free(u.path);
        if (u.query) |q| allocator.free(q);
        if (u.fragment) |f| allocator.free(f);
    }
    try std.testing.expectEqualStrings("https://example.com/path?q=1#frag", try stringify(.{ .Url = u }, &buf));
}

test "GAP-0877: Url that cannot fit the buffer is a stable error, not a placeholder" {
    var buf: [64]u8 = undefined;
    const long_host = "a" ** 80;
    const u = url.Url{
        .scheme = "https",
        .host = long_host,
        .port = null,
        .path = "",
        .query = null,
        .fragment = null,
    };
    try std.testing.expectError(EvalError.Unsupported, stringify(.{ .Url = u }, &buf));
}

test "GAP-0877: Domain stringifies its actual value" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const d = try url.Domain.fromString(allocator, "Sub.Example.COM");
    defer d.deinit(allocator);
    try std.testing.expectEqualStrings("sub.example.com", try stringify(.{ .Domain = d }, &buf));
}

test "GAP-0877: Bytea stringifies as hex, not the placeholder string" {
    var buf: [64]u8 = undefined;
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try std.testing.expectEqualStrings("\\xdeadbeef", try stringify(.{ .Bytea = &bytes }, &buf));
}

// ===========================================================================
// 2. Geometry relations: real implementations or stable errors
// ===========================================================================

test "GAP-0877: st_contains rejects unsupported geometry combination with stable error" {
    const allocator = std.testing.allocator;
    var registry = try eval_ext.initFunctionRegistry(allocator);
    defer registry.deinit();

    const line = try wkt.parseWktToWkb(allocator, "LINESTRING(0 0, 1 1)");
    defer allocator.free(line);
    const point = try wkt.parseWktToWkb(allocator, "POINT(0 0)");
    defer allocator.free(point);

    const st_contains = registry.get("st_contains").?;
    const args = [_]ExtValue{
        .{ .Geometry = .{ .wkb = line } },
        .{ .Geometry = .{ .wkb = point } },
    };
    try std.testing.expectError(error.UnsupportedGeometryRelation, st_contains(allocator, &args));
}

test "GAP-0877: st_intersects implements LineString-LineString" {
    const allocator = std.testing.allocator;
    var registry = try eval_ext.initFunctionRegistry(allocator);
    defer registry.deinit();
    const st_intersects = registry.get("st_intersects").?;

    const crossing_a = try wkt.parseWktToWkb(allocator, "LINESTRING(0 0, 1 1)");
    defer allocator.free(crossing_a);
    const crossing_b = try wkt.parseWktToWkb(allocator, "LINESTRING(0 1, 1 0)");
    defer allocator.free(crossing_b);
    const r1 = try st_intersects(allocator, &[_]ExtValue{
        .{ .Geometry = .{ .wkb = crossing_a } },
        .{ .Geometry = .{ .wkb = crossing_b } },
    });
    try std.testing.expect(r1.Bool);

    const parallel_a = try wkt.parseWktToWkb(allocator, "LINESTRING(0 0, 1 0)");
    defer allocator.free(parallel_a);
    const parallel_b = try wkt.parseWktToWkb(allocator, "LINESTRING(0 1, 1 1)");
    defer allocator.free(parallel_b);
    const r2 = try st_intersects(allocator, &[_]ExtValue{
        .{ .Geometry = .{ .wkb = parallel_a } },
        .{ .Geometry = .{ .wkb = parallel_b } },
    });
    try std.testing.expect(!r2.Bool);
}

test "GAP-0877: st_intersects detects polygon edge crossings without contained vertices" {
    const allocator = std.testing.allocator;
    var registry = try eval_ext.initFunctionRegistry(allocator);
    defer registry.deinit();
    const st_intersects = registry.get("st_intersects").?;

    // Two overlapping bars forming a plus sign: no vertex of either polygon
    // lies inside the other, only the edges cross. Previously silent false.
    const horizontal = try wkt.parseWktToWkb(allocator, "POLYGON((0 0, 3 0, 3 1, 0 1, 0 0))");
    defer allocator.free(horizontal);
    const vertical = try wkt.parseWktToWkb(allocator, "POLYGON((1 -1, 2 -1, 2 2, 1 2, 1 -1))");
    defer allocator.free(vertical);

    const r = try st_intersects(allocator, &[_]ExtValue{
        .{ .Geometry = .{ .wkb = horizontal } },
        .{ .Geometry = .{ .wkb = vertical } },
    });
    try std.testing.expect(r.Bool);
}

test "GAP-0877: st_intersects rejects unsupported combination with stable error" {
    const allocator = std.testing.allocator;
    var registry = try eval_ext.initFunctionRegistry(allocator);
    defer registry.deinit();
    const st_intersects = registry.get("st_intersects").?;

    const point = try wkt.parseWktToWkb(allocator, "POINT(0 0)");
    defer allocator.free(point);
    const line = try wkt.parseWktToWkb(allocator, "LINESTRING(0 0, 1 1)");
    defer allocator.free(line);

    try std.testing.expectError(error.UnsupportedGeometryRelation, st_intersects(allocator, &[_]ExtValue{
        .{ .Geometry = .{ .wkb = point } },
        .{ .Geometry = .{ .wkb = line } },
    }));
}

// ===========================================================================
// 3. domain_root eTLD+1 (public-suffix snapshot)
// ===========================================================================

test "GAP-0877: domain_root handles multi-label public suffixes" {
    const allocator = std.testing.allocator;
    const root = (try public_suffix.registrableDomain(
        allocator,
        &.{ "a", "b", "example", "co", "uk" },
    )).?;
    defer allocator.free(root);
    try std.testing.expectEqualStrings("example.co.uk", root);
}

test "GAP-0877: domain_root basic eTLD+1" {
    const allocator = std.testing.allocator;

    const r1 = (try public_suffix.registrableDomain(allocator, &.{ "x", "example", "com" })).?;
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("example.com", r1);

    const r2 = (try public_suffix.registrableDomain(allocator, &.{ "example", "com" })).?;
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("example.com", r2);
}

test "GAP-0877: domain_root unknown TLD falls back to last two labels" {
    const allocator = std.testing.allocator;
    const root = (try public_suffix.registrableDomain(
        allocator,
        &.{ "foo", "bar", "unknowntld" },
    )).?;
    defer allocator.free(root);
    try std.testing.expectEqualStrings("bar.unknowntld", root);
}

test "GAP-0877: domain_root honors private-domain suffixes (github.io)" {
    const allocator = std.testing.allocator;
    const root = (try public_suffix.registrableDomain(
        allocator,
        &.{ "deep", "user", "github", "io" },
    )).?;
    defer allocator.free(root);
    try std.testing.expectEqualStrings("user.github.io", root);
}

test "GAP-0877: domain_root wildcard and exception rules" {
    const allocator = std.testing.allocator;

    // *.ck: public suffix is <label>.ck
    const r1 = (try public_suffix.registrableDomain(allocator, &.{ "x", "a", "b", "ck" })).?;
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("a.b.ck", r1);

    // !www.ck exception: public suffix is just "ck"
    const r2 = (try public_suffix.registrableDomain(allocator, &.{ "foo", "www", "ck" })).?;
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("www.ck", r2);
}

test "GAP-0877: domain_root of a bare public suffix has no registrable part" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try public_suffix.registrableDomain(allocator, &.{"com"}),
    );
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try public_suffix.registrableDomain(allocator, &.{ "co", "uk" }),
    );
}

// ===========================================================================
// 4. GeometryFromText: real WKB, never raw WKT bytes
// ===========================================================================

test "GAP-0877: GeometryFromText produces real WKB" {
    const allocator = std.testing.allocator;
    const v = try eval_funcs.GeometryFromText(allocator, "POINT(1 2)");
    const wkb = v.Geometry.wkb;
    defer allocator.free(wkb);

    try std.testing.expectEqual(@as(usize, 21), wkb.len);
    try std.testing.expectEqual(@as(u8, 1), wkb[0]); // little endian
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, wkb[1..5], .little)); // Point
    const x: f64 = @bitCast(std.mem.readInt(u64, wkb[5..13], .little));
    const y: f64 = @bitCast(std.mem.readInt(u64, wkb[13..21], .little));
    try std.testing.expectEqual(@as(f64, 1.0), x);
    try std.testing.expectEqual(@as(f64, 2.0), y);
}

test "GAP-0877: GeometryFromText rejects unparseable WKT with a stable error" {
    try std.testing.expectError(
        eval_funcs.EvaluatorError.InvalidFormat,
        eval_funcs.GeometryFromText(std.testing.allocator, "CIRCLE(1 2 3)"),
    );
}

test "GAP-0877: GeometryFromText polygon round-trips through st_contains" {
    const allocator = std.testing.allocator;
    var registry = try eval_ext.initFunctionRegistry(allocator);
    defer registry.deinit();
    const st_contains = registry.get("st_contains").?;

    const square = try eval_funcs.GeometryFromText(allocator, "POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))");
    defer allocator.free(square.Geometry.wkb);
    const inside = try eval_funcs.GeometryFromText(allocator, "POINT(0.5 0.5)");
    defer allocator.free(inside.Geometry.wkb);
    const outside = try eval_funcs.GeometryFromText(allocator, "POINT(2 2)");
    defer allocator.free(outside.Geometry.wkb);

    const r1 = try st_contains(allocator, &[_]ExtValue{
        .{ .Geometry = .{ .wkb = square.Geometry.wkb } },
        .{ .Geometry = .{ .wkb = inside.Geometry.wkb } },
    });
    try std.testing.expect(r1.Bool);

    const r2 = try st_contains(allocator, &[_]ExtValue{
        .{ .Geometry = .{ .wkb = square.Geometry.wkb } },
        .{ .Geometry = .{ .wkb = outside.Geometry.wkb } },
    });
    try std.testing.expect(!r2.Bool);
}
