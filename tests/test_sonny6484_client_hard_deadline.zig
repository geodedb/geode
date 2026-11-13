// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6484 item 3: an explicit timeout given to the shared QUIC test
// client (tests/proto_test_util.zig) is a hard deadline.
//
// Every QuicProtoClient connected to a loopback address is bound to its
// server's liveness (SONNY-6301), and every reply wait of a bound client
// treated its deadline as soft: past it, the wait went on for as long as
// the server was alive, up to 120 s. So `executeAndCollectWithTimeout(..,
// 2)` and `readPacket(.., 1000)` never gave up on a live server, and a test
// that meant "this must answer within N s" measured "this must answer
// within 120 s". The calls that take no timeout (`hello`, `executeAndCollect`,
// `ping`, ...) still wait while the server is alive, and so does
// `readPacketWait(.., .{ .while_server_alive_ms = .. })`.
//
// Real `geode serve`, stopped with SIGSTOP (alive, holding its port, not
// answering) for longer than the deadline under test, then resumed.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");
const posix = std.posix;

fn monoMs() u64 {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// SIGCONT `pid` after `ms`, unless `cancel` is set first (polled every 50 ms).
fn resumeAfter(pid: posix.pid_t, ms: u64, cancel: *std.atomic.Value(bool)) void {
    var waited: u64 = 0;
    while (waited < ms and !cancel.load(.acquire)) : (waited += 50) sleepMs(50);
    posix.kill(pid, .CONT) catch {};
}

const Stopped = struct {
    pid: posix.pid_t,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Stop the server; it resumes after `resume_ms` (or at `finish`).
    fn begin(self: *Stopped, resume_ms: u64) !void {
        try posix.kill(self.pid, .STOP);
        self.thread = try std.Thread.spawn(.{}, resumeAfter, .{ self.pid, resume_ms, &self.cancel });
    }

    fn finish(self: *Stopped) void {
        self.cancel.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
};

fn connectHello(allocator: std.mem.Allocator, addr: []const u8) !util.QuicProtoClient {
    var client = try util.QuicProtoClient.connect(allocator, addr);
    errdefer client.deinit();
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(allocator);
    if (!h.success) return error.HelloFailed;
    return client;
}

test "SONNY-6484: executeAndCollectWithTimeout gives up at its timeout although the server is alive" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var server = try util.spawnServerRandom(allocator, null);
    defer server.deinit();
    var client = try connectHello(allocator, server.getAddr());
    defer client.deinit();

    var stopped = Stopped{ .pid = server.child.id.? };
    try stopped.begin(20_000);
    defer stopped.finish();
    const t0 = monoMs();
    if (client.executeAndCollectWithTimeout(allocator, "RETURN 1 AS x", util.emptyParams(), 16, 2)) |res| {
        var r = res;
        r.deinit(allocator);
        std.debug.print("a 2 s query against a stopped server returned after {d} ms\n", .{monoMs() - t0});
        return error.TimeoutNotEnforced;
    } else |err| {
        const elapsed = monoMs() - t0;
        std.debug.print("2 s query against a stopped server: {s} after {d} ms\n", .{ @errorName(err), elapsed });
        try std.testing.expectEqual(error.Timeout, err);
        try std.testing.expect(elapsed >= 1_900);
        try std.testing.expect(elapsed < 10_000);
    }
}

test "SONNY-6484: readPacket gives up at its timeout although the server is alive" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var server = try util.spawnServerRandom(allocator, null);
    defer server.deinit();
    var client = try connectHello(allocator, server.getAddr());
    defer client.deinit();

    var stopped = Stopped{ .pid = server.child.id.? };
    try stopped.begin(20_000);
    defer stopped.finish();
    try client.writeMessage(.{ .ping = .{} });
    const t0 = monoMs();
    if (client.readPacket(allocator, 1_000)) |packet| {
        var p = packet;
        p.deinit(allocator);
        std.debug.print("a 1 s read against a stopped server returned after {d} ms\n", .{monoMs() - t0});
        return error.TimeoutNotEnforced;
    } else |err| {
        const elapsed = monoMs() - t0;
        try std.testing.expectEqual(error.Timeout, err);
        try std.testing.expect(elapsed >= 900);
        try std.testing.expect(elapsed < 8_000);
    }
}

test "SONNY-6484: a while_server_alive wait and a call without a timeout still wait for a live server" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var server = try util.spawnServerRandom(allocator, null);
    defer server.deinit();
    var client = try connectHello(allocator, server.getAddr());
    defer client.deinit();

    // The explicit opt-in: a 1 s slice, the server stopped for 3.5 s.
    {
        var stopped = Stopped{ .pid = server.child.id.? };
        try stopped.begin(3_500);
        defer stopped.finish();
        try client.writeMessage(.{ .ping = .{} });
        const t0 = monoMs();
        var packet = try client.readPacketWait(allocator, .{ .while_server_alive_ms = 1_000 });
        defer packet.deinit(allocator);
        try std.testing.expect(monoMs() - t0 >= 3_000);
    }
    // No timeout given: `executeAndCollect` waits for the stopped server.
    {
        var stopped = Stopped{ .pid = server.child.id.? };
        try stopped.begin(7_000);
        defer stopped.finish();
        const t0 = monoMs();
        var res = try client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 16);
        defer res.deinit(allocator);
        try std.testing.expect(res.error_code == null);
        try std.testing.expect(monoMs() - t0 >= 6_000);
    }
}
