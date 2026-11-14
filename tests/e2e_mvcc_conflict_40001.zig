const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn run_cli(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out = std.ArrayList(u8).init(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    _ = try child.wait();
    return try out.toOwnedSlice();
}

fn send(allocator: std.mem.Allocator, server: []const u8, text: []const u8) ![]const u8 {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&.{ geode_test_bin.geode_exe, "query", text, "--server", server });
    return try run_cli(allocator, args.items);
}

test "concurrent UPDATE_VALUE conflicts yield 40001 on one commit" {
    util.testStart("concurrent UPDATE_VALUE conflicts yield 40001");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = std.process.Child.init(&.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(300 * std.time.ns_per_ms);

    util.progress("Running concurrent transactions...", .{});

    // Client A: BEGIN; UPDATE; sleep; COMMIT
    var a_commit: []const u8 = &.{};
    var thr_a = try std.Thread.spawn(.{}, struct {
        fn run(ptr: *[]const u8, server_addr: []const u8) !void {
            const a = std.heap.page_allocator;
            _ = try send(a, server_addr, "BEGIN");
            _ = try send(a, server_addr, "UPDATE_VALUE(\"row:1\",\"A\")");
            std.time.sleep(400 * std.time.ns_per_ms);
            const o = try send(a, server_addr, "COMMIT");
            ptr.* = o;
        }
    }.run, .{ &a_commit, addr });

    // Client B: delay slightly; BEGIN; UPDATE; COMMIT (should conflict with A)
    std.time.sleep(100 * std.time.ns_per_ms);
    const out_b1 = try send(allocator, addr, "BEGIN");
    allocator.free(out_b1);
    const out_b2 = try send(allocator, addr, "UPDATE_VALUE(\"row:1\",\"B\")");
    allocator.free(out_b2);
    const out_b3 = try send(allocator, addr, "COMMIT");

    thr_a.join();

    // Exactly one COMMIT should return 40001
    const has_40001_a = std.mem.indexOf(u8, a_commit, "\"status_class\":\"40001\"") != null;
    const has_40001_b = std.mem.indexOf(u8, out_b3, "\"status_class\":\"40001\"") != null;
    // XOR: one true, one false
    try testing.expect((has_40001_a and !has_40001_b) or (!has_40001_a and has_40001_b));

    // free outputs
    if (a_commit.len > 0) allocator.free(a_commit);
    allocator.free(out_b3);

    util.testPass();
}
