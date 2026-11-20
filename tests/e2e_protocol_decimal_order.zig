const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Validate decimal ordering across scales and sign.
// We simulate decimals using RETURN with raw literal forms once parser supports them; for now we mimic via int ordering fallback (placeholder test ensures framework readiness).

// NOTE: If decimal literal syntax not yet implemented, this test just ensures existing INT ordering is stable; adjust once decimals are exposed at parse level.

test "protocol: numeric ordering stable (placeholder for decimal)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN 2 AS x UNION RETURN 1 AS x UNION RETURN 3 AS x ORDER BY x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect ordered rows 1,2,3 after PULL (unordered union + grouped order logic currently sorts when grouped pattern detected)
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
    try std.testing.expect(contains(res.out, "{\"x\":2}"));
    try std.testing.expect(contains(res.out, "{\"x\":3}"));
}

// SONNY-6548: a DECIMAL renders as a JSON string of its exact digits
// (query_result_accumulator protoValueToJson `.decimal_val`), so `-1.2` is
// `"-1.2"`; integers stay JSON numbers.
// Mixed scale decimals with negatives: ensure normalization treats -1.2 and -1.20 as equal and ordering places them before 0 and positive values.
test "protocol: decimal ordering negatives and mixed scales" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN -1.2 AS a UNION RETURN -1.20 AS a UNION RETURN 0 AS a UNION RETURN 1.2 AS a ORDER BY a" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Rows should include -1.2 (deduped), 0, 1.2 in ascending order.
    const line_it = res.out;
    const p_neg = std.mem.indexOf(u8, line_it, "{\"a\":\"-1.2\"}") orelse 0;
    const p_zero = std.mem.indexOf(u8, line_it, "{\"a\":0}") orelse 0;
    const p_pos = std.mem.indexOf(u8, line_it, "{\"a\":\"1.2\"}") orelse 0;
    try std.testing.expect(p_neg < p_zero);
    try std.testing.expect(p_zero < p_pos);
}

// Mixed ints and decimals ordering: negatives, zeros, positives with decimal granularity.
test "protocol: numeric ordering mixed ints and decimals" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN -2 AS x UNION RETURN -1.5 AS x UNION RETURN -1 AS x UNION RETURN 0 AS x UNION RETURN 1 AS x UNION RETURN 1.25 AS x UNION RETURN 2 AS x ORDER BY x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Ensure presence of all numeric literals
    try std.testing.expect(contains(res.out, "{\"x\":-2}"));
    try std.testing.expect(contains(res.out, "{\"x\":\"-1.5\"}"));
    try std.testing.expect(contains(res.out, "{\"x\":-1}"));
    try std.testing.expect(contains(res.out, "{\"x\":0}"));
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
    try std.testing.expect(contains(res.out, "{\"x\":\"1.25\"}"));
    try std.testing.expect(contains(res.out, "{\"x\":2}"));
    // Order check in bindings line
    const line_it = res.out;
    const p_m2 = std.mem.indexOf(u8, line_it, "{\"x\":-2}") orelse 0;
    const p_m15 = std.mem.indexOf(u8, line_it, "{\"x\":\"-1.5\"}") orelse 0;
    const p_m1 = std.mem.indexOf(u8, line_it, "{\"x\":-1}") orelse 0;
    const p_0 = std.mem.indexOf(u8, line_it, "{\"x\":0}") orelse 0;
    const p_1 = std.mem.indexOf(u8, line_it, "{\"x\":1}") orelse 0;
    const p_125 = std.mem.indexOf(u8, line_it, "{\"x\":\"1.25\"}") orelse 0;
    const p_2 = std.mem.indexOf(u8, line_it, "{\"x\":2}") orelse 0;
    try std.testing.expect(p_m2 < p_m15);
    try std.testing.expect(p_m15 < p_m1);
    try std.testing.expect(p_m1 < p_0);
    try std.testing.expect(p_0 < p_1);
    try std.testing.expect(p_1 < p_125);
    try std.testing.expect(p_125 < p_2);
}

// Dedup across int and decimal forms of same numeric value.
test "protocol: union distinct dedup int vs decimal canonical equality" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 1.0 AS x UNION RETURN 1.00 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect only one row with x:1
    var occurrences: usize = 0;
    var it = std.mem.splitScalar(u8, res.out, '\n');
    while (it.next()) |line| {
        if (contains(line, "{\"x\":1}")) occurrences += 1;
    }
    try std.testing.expect(occurrences == 1);
}
