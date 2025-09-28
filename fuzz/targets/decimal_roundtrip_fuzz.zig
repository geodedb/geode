const std = @import("std");
const d128 = @import("decimal128");
const Context = struct {};

fn fuzz_decimal(context: Context, data: []const u8) anyerror!void {
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
