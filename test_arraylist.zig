const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test ArrayList initialization with initCapacity
    var list = try std.ArrayList(u32).initCapacity(allocator, 0);
    defer list.deinit();

    try list.append(42);
    std.debug.print("ArrayList works: {}\n", .{list.items[0]});
}
