const std = @import("std");
pub fn main() !void {
    const file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var buf: [1024]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.writeAll("hello");
    try writer.flush();
}
