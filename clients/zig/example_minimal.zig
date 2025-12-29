const std = @import("std");
const geode = @import("geode-client");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const client = geode.Client.init(allocator);
    _ = client;
    std.debug.print("Geode Zig Client Example Minimal\n", .{});
}
