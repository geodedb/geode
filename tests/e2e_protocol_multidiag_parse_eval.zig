const std = @import("std");
const testing = std.testing;

fn runCli(alloc: std.mem.Allocator, query: []const u8) !struct { code: u8, out: []u8, err: []u8 } {
    var argv = [_][]const u8{ "./zig-out/bin/geode", query };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout_bytes = try child.stdout.?.reader().readAllAlloc(alloc, 64 * 1024);
    const stderr_bytes = try child.stderr.?.reader().readAllAlloc(alloc, 64 * 1024);
    const term = try child.wait();
    return .{ .code = @intFromEnum(term), .out = stdout_bytes, .err = stderr_bytes };
}

// Intentionally crafts a query expected to produce multiple diagnostics across parse/eval:
//  - IllegalOrderKey (function call in ORDER BY if policy forbids) using f(a)
//  - US001 (LIMIT without valid ORDER BY)
//  - TypeMismatch via runtime expression ("a" + 1)
// Final precedence should yield US001 primary (lowest rank), with others additional.
// If planning refuses due to parse-time IllegalOrderKey, we still expect both US001 and IllegalOrderKey.

test "protocol: parse+eval multi-diagnostic US001 + IllegalOrderKey + TypeMismatch" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const q = "RETURN (\"a\" + 1) AS a ORDER BY f(a) LIMIT 2";
    const res = try runCli(alloc, q);
    try testing.expect(res.code == 2);
    try testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try testing.expect(std.mem.indexOf(u8, res.err, "IllegalOrderKey") != null);
    // TypeMismatch may surface depending on whether evaluation reached; tolerate absence if parse/planner blocked.
    const idx_us = std.mem.indexOf(u8, res.err, "US001").?;
    const idx_il = std.mem.indexOf(u8, res.err, "IllegalOrderKey").?;
    try testing.expect(idx_us <= idx_il);
}
