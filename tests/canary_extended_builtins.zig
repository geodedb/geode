const std = @import("std");
const geode = @import("geode");
const eval_ext = geode.eval_ext;
const ext_types = geode.ext_types;

// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=ADAPTER_BRIDGE; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_082_AdapterBridgeUuidV4; OWNER=engine; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-083; FEATURE="ExtendedDecimalFormatting"; ASPECT=FORMATTER; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_083_DecimalFormatterRoundTrip; OWNER=engine; UPDATED=2025-09-27

test "TestCANARY_REQ_GQL_082_AdapterBridgeUuidV4" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var reg = try eval_ext.initFunctionRegistry(allocator);
    defer reg.deinit();
    const fnp = reg.get("uuid_v4") orelse return error.NotFound;
    const v = try fnp(allocator, &[_]eval_ext.ExtValue{});
    try std.testing.expect(v == .Str);
    // Extended-function results are caller-owned (fn_uuid_v4 dupes its text).
    defer allocator.free(v.Str);
    try std.testing.expect(v.Str.len == 36);
    try expectUuidV4Text(v.Str);
    // SONNY-2394: uuid_v4() returned the SAME constant UUID on every call
    // (bytes filled from a fixed sequence). Successive calls must differ.
    const w = try fnp(allocator, &[_]eval_ext.ExtValue{});
    defer allocator.free(w.Str);
    try expectUuidV4Text(w.Str);
    try std.testing.expect(!std.mem.eql(u8, v.Str, w.Str));
}

/// RFC 4122 v4 text form: 8-4-4-4-12 lowercase hex, version nibble 4, variant 10xx.
fn expectUuidV4Text(text: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 36), text.len);
    for (text, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            try std.testing.expectEqual(@as(u8, '-'), c);
        } else {
            try std.testing.expect(std.ascii.isHex(c));
        }
    }
    try std.testing.expectEqual(@as(u8, '4'), text[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89abAB", text[19]) != null);
}

test "TestCANARY_REQ_GQL_083_DecimalFormatterRoundTrip" {
    // "-0.01" / "0.001" / "10.50" pin the leading/trailing fractional zeros
    // (SONNY-2394: 0.01 used to format as "0.1").
    const cases = [_][]const u8{ "0", "0.0", "123.45", "-0.01", "-999999.0001", "0.001", "10.50" };
    for (cases) |txt| {
        const d = try ext_types.decimalFromString(txt);
        const out = try ext_types.decimalToString(d, std.testing.allocator);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.eql(u8, txt, out));
    }
}
