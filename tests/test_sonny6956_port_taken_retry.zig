//! SONNY-6956: spawnServerRandom draws a free UDP port, releases it, and
//! passes it to `geode serve`; another process can bind it in between
//! (test_sonny6551_dsn_query_credentials in main pipeline 3107392185: the
//! server exited with BindFailed, and the test failed). A server that could
//! not bind its port has not started, so the spawn draws another port and
//! starts it again. Take the port for real: hold the first port the spawn
//! draws, so the server's bind fails.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

var held_port: u16 = 0;
var draws: std.atomic.Value(u32) = .init(0);

fn heldThenFree() anyerror!u16 {
    if (draws.fetchAdd(1, .monotonic) == 0) return held_port;
    return util.getRandomPort();
}

test "SONNY-6956: a spawned server whose port was taken before it bound is started again on another port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const held = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer held.close(io);
    held_port = held.address.getPort();

    var handle = try util.spawnServerPickingPort(testing.allocator, null, heldThenFree);
    defer handle.deinit();
    try testing.expect(handle.port != held_port);
    try testing.expect(draws.load(.monotonic) >= 2);
}
