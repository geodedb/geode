const std = @import("std");
comptime {
    const T = @TypeOf(std.io);
    const decls = std.meta.declarations(T);
    inline for (decls) |d| {
        @compileLog(d.name);
    }
}
pub fn main() void {}
