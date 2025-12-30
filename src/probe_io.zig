const std = @import("std");
pub fn main() void {
    const io = std.io;
    const info = @typeInfo(io);
    inline for (info.@"struct".decls) |decl| {
        std.debug.print("{s}\n", .{decl.name});
    }
}
