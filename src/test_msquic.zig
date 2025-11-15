const std = @import("std");
const msquic = @import("transport/msquic_wrapper.zig");

test "msquic basic init" {
    const allocator = std.testing.allocator;
    
    const mq = try msquic.MsQuic.init(allocator);
    defer mq.deinit();
    
    std.debug.print("✅ msquic initialized successfully\n", .{});
    std.debug.print("✅ API table ptr: {*}\n", .{mq.api});
}

test "msquic basic deinit" {
    const allocator = std.testing.allocator;
    
    const mq = try msquic.MsQuic.init(allocator);
    mq.deinit();
    
    std.debug.print("✅ msquic deinitialized successfully\n", .{});
}
