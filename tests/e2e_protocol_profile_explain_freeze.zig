const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 16);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 16);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

fn normalize(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}

// Expected fragments (schema omitted for brevity; we match key structural invariants)
const expect_explain_has = &.{ "\"profile_version\":2", "\"logical\":[", "\"op\":\"Project\",\"id\":0", "\"properties\":{"", "\"ordered\":true", "\"limit\":1" };
const expect_profile_has = &.{ "\"profile_version\":2", "\"ops\":[", "\"op\":\"Project\",\"phase\":\"PROJECT\",\"id\":0", "\"totals\":{"", "\"time_ns\":", "\"peak_bytes\":" };
const expect_explain_no_sort = &.{ "\"profile_version\":2", "\"logical\":[", "\"op\":\"Project\",\"id\":0", "\"properties\":{"", "\"limit\":1" };

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

fn assertAll(hay: []const u8, needles: []const []const u8) !void {
    for (needles) |n| {
        if (!contains(hay, n)) return error.MissingNeedle;
    }
}

test "EXPLAIN freeze ordered pipeline" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 1" });
    try testing.expectEqual(@as(i32, 0), res.code);
    const line = normalize(res.out);
    try assertAll(line, expect_explain_has);
}

test "PROFILE freeze ordered pipeline" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    try testing.expectEqual(@as(i32, 0), res.code);
    const line = normalize(res.out);
    try assertAll(line, expect_profile_has);
}

test "EXPLAIN freeze unordered (no sort)" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x LIMIT 1" });
    try testing.expectEqual(@as(i32, 0), res.code);
    const line = normalize(res.out);
    try assertAll(line, expect_explain_no_sort);
    // Ensure absence of Sort op
    try testing.expect(!contains(line, "\"op\":\"Sort\""));
}
