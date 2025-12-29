const std = @import("std");

pub const Client = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{ .allocator = allocator };
    }
};
