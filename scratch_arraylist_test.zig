const std = @import("std");

pub fn main() void {}

test "arraylist api" {
    const AL = std.ArrayList(u8);
    comptime {
        @compileLog(@hasDecl(AL, "init"), @hasDecl(AL, "initCapacity"), @hasDecl(AL, "fromOwnedSlice"));
        // list fields
        @compileLog(@typeInfo(AL));
    }
}
