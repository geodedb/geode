const std = @import("std");
pub fn main() !void {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    _ = stdin.reader();
    _ = stdout.writer();
}
