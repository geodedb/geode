const std = @import("std");
const raft_lib = @import("raft");

pub const FileStorage = raft_lib.FileStorage;

pub fn open(allocator: std.mem.Allocator, storage_path: []const u8) !FileStorage {
    return try FileStorage.init(allocator, storage_path);
}

test {
    std.testing.refAllDecls(@This());
}
