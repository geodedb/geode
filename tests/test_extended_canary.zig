const std = @import("std");
const extf = @import("../src/types/extended_functions.zig");
const eval_ext = @import("../src/eval_extended.zig");

// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=ADAPTER_BRIDGE; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_082_AdapterBridgeUuidV4; OWNER=engine; UPDATED=2026-11-14
// Verifies adapterFactory wiring exposes uuid_v4 via main function registry.

pub fn main() !void {}

test "TestCANARY_REQ_GQL_082_AdapterBridgeUuidV4" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = try eval_ext.initFunctionRegistry(alloc);
    defer reg.deinit();

    const fnp = reg.get("uuid_v4") orelse return error.NotFound;
    const v = try fnp(alloc, &[_]eval_ext.ExtValue{});
    try std.testing.expect(v == .Str);
    try std.testing.expect(v.Str.len == 36);
}

test "TestCANARY_REQ_GQL_083_DecimalFormatterRoundTrip" {
    // Ensure decimal parsing/formatting round-trip with scale edge cases.
    const cases = [_][]const u8{ "0", "0.0", "123.45", "-0.01", "-999999.0001" };
    var i: usize = 0;
    while (i < cases.len) : (i += 1) {
        const txt = cases[i];
        const dec_mod = @import("../src/types/extended.zig");
        const d = try dec_mod.decimalFromString(txt);
        const out = try dec_mod.decimalToString(d, std.testing.allocator);
        defer std.testing.allocator.free(out);
        // Accept either exact or normalized removal of trailing zeros for scale edge cases.
        // For this simplistic formatter we expect exact reproduction of integer+fraction digits.
        if (std.mem.indexOf(u8, txt, ".")) |_| {
            // Compare without leading + sign differences.
            try std.testing.expect(std.mem.eql(u8, txt, out));
        } else {
            try std.testing.expect(std.mem.eql(u8, txt, out));
        }
    }
}
