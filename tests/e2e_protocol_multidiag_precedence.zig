const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;

fn runCli(alloc: std.mem.Allocator, query: []const u8) !struct { code: u8, err: []u8 } {
    var argv = [_][]const u8{ geode_test_bin.geode_exe, query };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stderr_bytes = try child.stderr.?.readToEndAlloc(alloc, 64 * 1024);
    const term = try child.wait();
    return .{ .code = @intFromEnum(term), .err = stderr_bytes };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

fn assertPrimary(err: []const u8, primary: []const u8) !void {
    // status_subclass appears near start: "status_subclass":"CODE"
    const key = "\"status_subclass\":\"";
    const idx = std.mem.indexOf(u8, err, key) orelse return error.MissingPrimary;
    const rest = err[idx + key.len ..];
    var it = std.mem.splitScalar(u8, rest, '"');
    const found = it.next() orelse return error.MissingPrimaryCode;
    if (!std.mem.eql(u8, found, primary)) return error.UnexpectedPrimary;
}

fn assertAdditionalOrder(err: []const u8, expected: []const []const u8) !void {
    const key = "\"additional_statuses\":[";
    const start = std.mem.indexOf(u8, err, key) orelse return; // no additional -> nothing to check
    const segment = err[start + key.len ..];
    const end_idx = std.mem.indexOf(u8, segment, "]") orelse return error.MalformedAdditional;
    const list = segment[0..end_idx];
    var pos: usize = 0;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        const needle = expected[i];
        // Build pattern "needle"
        var tmp: [48]u8 = undefined;
        var w: usize = 0;
        tmp[w] = '"';
        w += 1;
        if (needle.len > tmp.len - 2) return error.NeedleTooLong;
        std.mem.copyForwards(u8, tmp[w .. w + needle.len], needle);
        w += needle.len;
        tmp[w] = '"';
        w += 1;
        const pat = tmp[0..w];
        const slice_remaining = list[pos..];
        const found_idx = std.mem.indexOf(u8, slice_remaining, pat) orelse return error.OrderMismatch;
        pos += found_idx + pat.len;
    }
}

fn assertUs001Flag(err: []const u8, present: bool) !void {
    const has = contains(err, "US001/enforced");
    if (present and !has) return error.MissingUS001Flag;
    if (!present and has) return error.UnexpectedUS001Flag;
}

// Precedence reference: US001, IllegalOrderKey, GroupByIllegal, TypeMismatch

test "multidiag precedence: US001 only" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const res = try runCli(gpa.allocator(), "RETURN 1 LIMIT 2");
    try testing.expect(res.code == 2);
    try assertPrimary(res.err, "US001");
    try assertUs001Flag(res.err, true);
}

test "multidiag precedence: IllegalOrderKey only" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const res = try runCli(gpa.allocator(), "RETURN a ORDER BY f(a)");
    try testing.expect(res.code == 2);
    try assertPrimary(res.err, "IllegalOrderKey");
    try assertUs001Flag(res.err, false);
}

test "multidiag precedence: US001 + IllegalOrderKey" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const res = try runCli(gpa.allocator(), "RETURN a ORDER BY f(a) LIMIT 5");
    try testing.expect(res.code == 2);
    try assertPrimary(res.err, "US001");
    try assertAdditionalOrder(res.err, &.{"IllegalOrderKey"});
    try assertUs001Flag(res.err, true);
}

test "multidiag precedence: TypeMismatch + US001" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const res = try runCli(gpa.allocator(), "RETURN (\"a\" + 1) LIMIT 1");
    try testing.expect(res.code == 2);
    try assertPrimary(res.err, "US001");
    // Expect TypeMismatch additional (order after US001)
    try assertAdditionalOrder(res.err, &.{"TypeMismatch"});
    try assertUs001Flag(res.err, true);
}

test "multidiag precedence: All three US001 + IllegalOrderKey + TypeMismatch" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const res = try runCli(gpa.allocator(), "RETURN (\"a\" + 1) AS a ORDER BY f(a) LIMIT 1");
    try testing.expect(res.code == 2);
    try assertPrimary(res.err, "US001");
    try assertAdditionalOrder(res.err, &.{ "IllegalOrderKey", "TypeMismatch" });
    try assertUs001Flag(res.err, true);
}
