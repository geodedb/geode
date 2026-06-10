const std = @import("std");
const d128 = @import("decimal128");
const Context = struct {};

// Zig 0.16: std.testing.fuzz hands the test a *Smith generator instead of a
// raw byte slice.  Draw a fuzzer-controlled byte slice from the Smith and
// feed it to the original byte-driven harness.
fn fuzz_decimal(context: Context, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    try fuzz_decimal_bytes(context, buf[0..len]);
}

fn fuzz_decimal_bytes(context: Context, data: []const u8) anyerror!void {
    _ = context;
    const s = data[0..@min(data.len, 256)];
    const parsed = d128.Decimal128.fromStr(s) catch return;
    const ally = std.testing.allocator;
    const str1 = try parsed.toString(ally);
    defer ally.free(str1);
    const parsed2 = d128.Decimal128.fromStr(str1) catch return error.Unexpected;
    const str2 = try parsed2.toString(ally);
    defer ally.free(str2);
    if (!std.mem.eql(u8, str1, str2)) return error.Unexpected;
}

test "fuzz decimal roundtrip" {
    try std.testing.fuzz(Context{}, fuzz_decimal, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
