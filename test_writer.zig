const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var buf: [1024]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.writeAll("hello");
    try writer.flush();
}
