const std = @import("std");
pub fn main() void {
    const info = @typeInfo(std.fmt);
    inline for (info.@"struct".decls) |decl| {
        std.debug.print("{s}\n", .{decl.name});
    }
}
