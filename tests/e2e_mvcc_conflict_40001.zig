const std = @import("std");
const testing = std.testing;

fn start_server(allocator: std.mem.Allocator) !std.ChildProcess {
    var server = std.ChildProcess.init(&[_][]const u8{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:7570" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    try server.spawn();
    std.Thread.sleep(300 * std.time.ns_per_ms);
    return server;
}

fn run_cli(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var child = std.ChildProcess.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    defer child.deinit();
    var out = std.ArrayList(u8).init(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    _ = try child.wait();
    return try allocator.dupe(u8, out.items);
}

fn send(allocator: std.mem.Allocator, server: []const u8, text: []const u8) ![]const u8 {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&.{ "./zig-out/bin/geode", text, "--server", server });
    return try run_cli(allocator, args.items);
}

test "concurrent UPDATE_VALUE conflicts yield 40001 on one commit" {
    const allocator = testing.allocator;
    var server = try start_server(allocator);
    defer server.kill() catch {};

    const addr = "127.0.0.1:7570";

    // Client A: BEGIN; UPDATE; sleep; COMMIT
    var a_commit: []const u8 = &.{};
    var thr_a = try std.Thread.spawn(.{}, struct {
        fn run(ptr: *[]const u8) !void {
            const a = std.heap.page_allocator;
            _ = try send(a, addr, "BEGIN");
            _ = try send(a, addr, "UPDATE_VALUE(\"row:1\",\"A\")");
            std.Thread.sleep(400 * std.time.ns_per_ms);
            const o = try send(a, addr, "COMMIT");
            ptr.* = o;
        }
    }.run, .{&a_commit});

    // Client B: delay slightly; BEGIN; UPDATE; COMMIT (should conflict with A)
    std.Thread.sleep(100 * std.time.ns_per_ms);
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
}
