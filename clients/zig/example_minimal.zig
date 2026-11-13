const std = @import("std");
const geode = @import("geode-client");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var cfg = geode.config.Config.init();
    cfg.username = "geode";
    cfg.password = "Geode Example Client Passphrase";

    var client = try geode.GeodeClient.initFromConfig(allocator, cfg);
    defer client.deinit();

    std.debug.print("Geode Zig Client Example using geode-client-zig\n", .{});
}
