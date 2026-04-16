const std = @import("std");
const gql = @import("../src/gql.zig");
const diagnostics = @import("../src/diagnostics.zig");
const testing = std.testing;

// This test triggers both TypeMismatch (runtime) and US001 (pagination without ORDER) to validate
// multi-diagnostic aggregation in simple (non-PROFILE) execution path.
// Query uses LIMIT without ORDER plus an expression guaranteed to produce TypeMismatch.

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

test "protocol: runtime multi-diagnostic TypeMismatch + US001" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Expression ("a" + 1) yields TypeMismatch; LIMIT without ORDER triggers US001
    const q = "RETURN (\"a\" + 1) AS x LIMIT 5";
    const res = try runCli(alloc, q);
    try testing.expect(res.code == 2);
    try testing.expect(std.mem.indexOf(u8, res.err, "TypeMismatch") != null);
    try testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    // Ensure primary precedes additional in output ordering (TypeMismatch is higher precedence -> should be last in sorted? Precedence table: US001, IllegalOrderKey, GroupByIllegal, TypeMismatch => US001 first, TypeMismatch last; primary should be US001 if ordering chooses lowest index)
    // We assert US001 appears before TypeMismatch in stderr textual order.
    const idx_us = std.mem.indexOf(u8, res.err, "US001").?;
    const idx_tm = std.mem.indexOf(u8, res.err, "TypeMismatch").?;
    try testing.expect(idx_us < idx_tm);
}
