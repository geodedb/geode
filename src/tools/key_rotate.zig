const std = @import("std");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    if (args.len < 2) return error.InvalidKey;
    const key = args[1];
    if (key.len != 64) return error.InvalidKey;
    var i: usize = 0;
    while (i < 32) : (i += 1) _ = try std.fmt.parseInt(u8, key[i * 2 .. i * 2 + 2], 16);
    std.debug.print("export GEODE_DISK_KEY_HEX={s}\n", .{key});
}
