const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;

fn runCli(alloc: std.mem.Allocator, query: []const u8) !struct { code: u8, out: []u8, err: []u8 } {
    var argv = [_][]const u8{ geode_test_bin.geode_exe, query };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout_bytes = try child.stdout.?.reader().readAllAlloc(alloc, 64 * 1024);
    const stderr_bytes = try child.stderr.?.reader().readAllAlloc(alloc, 64 * 1024);
    const term = try child.wait();
    return .{ .code = @intFromEnum(term), .out = stdout_bytes, .err = stderr_bytes };
}

// Triggers planner GroupByIllegal (b not grouped or aggregated) plus US001 (LIMIT without ORDER) -> multi-diagnostic.
// Expect precedence to pick US001 as primary and additional_statuses to include GroupByIllegal.

test "protocol: planner multi-diagnostic GroupByIllegal + US001" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const q = "RETURN a, b GROUP BY a LIMIT 5";
    const res = try runCli(alloc, q);
    try testing.expect(res.code == 2);
    try testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try testing.expect(std.mem.indexOf(u8, res.err, "GroupByIllegal") != null);
    const idx_us = std.mem.indexOf(u8, res.err, "US001").?;
    const idx_grp = std.mem.indexOf(u8, res.err, "GroupByIllegal").?;
    try testing.expect(idx_us < idx_grp);
}
