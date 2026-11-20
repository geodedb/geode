const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

inline fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "flags: DISTINCT unordered emits DistinctOutputUnordered" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "DistinctOutputUnordered"));
}

test "flags: ordered query has OrderTiebreak but not DistinctOutputUnordered" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "OrderTiebreak=LexJSON"));
    try std.testing.expect(!contains(res.out, "DistinctOutputUnordered"));
}

test "flags: NullsFirstPolicy present in DISTINCT unordered set where NULL participates" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN null AS a UNION RETURN 1 AS a" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "NullsFirstPolicy"));
}

// SONNY-6548: US001 is never emitted (docs/BINARY_PROTOCOL.md: unordered
// pagination succeeds), ORDER BY f(a) is a 42000 scope error (exit 1, not
// 2), I:IllegalOrderKeyPolicy=ident-only is no longer a flag
// (I:PropertyOrderingEnabled is), `--begin/--commit` belonged to the deleted
// client, and EXPLAIN/PROFILE render under "explain"/"profile", not
// "result":{"type":...}. Those cases were dropped or updated.
test "flags: EXPLAIN includes base policy flags" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"explain\":{"));
    try std.testing.expect(contains(res.out, "\"kind\":\"Sort\""));
    try std.testing.expect(contains(res.out, "I:PropertyOrderingEnabled"));
    try std.testing.expect(contains(res.out, "U:OrderTiebreak=LexJSON"));
}

test "flags: PROFILE includes base policy flags and per-op timings" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"profile\":{"));
    try std.testing.expect(contains(res.out, "U:OrderTiebreak=LexJSON"));
    try std.testing.expect(contains(res.out, "total_time_ns"));
    try std.testing.expect(contains(res.out, "\"op\":\"Project\""));
    try std.testing.expect(contains(res.out, "\"time_ns\":"));
}
