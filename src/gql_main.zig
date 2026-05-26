const std = @import("std");
const gql_main = @import("gql/main.zig");

pub fn main(proc_init: std.process.Init.Minimal) !void {
    return gql_main.main(proc_init);
}
