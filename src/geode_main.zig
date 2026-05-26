const std = @import("std");
const server_main = @import("server/main.zig");

pub fn main(proc_init: std.process.Init.Minimal) !void {
    return server_main.main(proc_init);
}
