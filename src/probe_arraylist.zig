const std = @import("std");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = try std.ArrayList(u8).initCapacity(allocator, 10);
    defer list.deinit();

    try list.append(10);
    std.debug.print("Items: {d}\n", .{list.items.len});
}
