const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Validate that profile_version bumped to 2 is present and memory block includes total_alloc_bytes key.
// Full summation of per-op bytes_alloc vs total_alloc_bytes would require JSON parsing; lightweight substring checks here.
// (Future: structured parse when JSON DOM helper exists.)

test "profile: memory block contains total_alloc_bytes (v2)" {
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(res.out);
    defer testing.allocator.free(res.err);
    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expect(contains(res.out, "\"profile_version\":2"));
    try testing.expect(contains(res.out, "total_alloc_bytes"));
}

// Invariant: the per-op "bytes_alloc" values sum to memory.total_alloc_bytes.
// SONNY-6548: the token scan also summed the `{op, bytes_alloc}` entries of
// peak_contributors (the top ops repeated), so it never held; parse the JSON
// and sum `ops` only. A UNION takes the version-1 payload, whose memory
// figures are the synthetic model (docs/EXPLAIN_PROFILE.md).
test "profile: per-op bytes_alloc sum equals memory.total_alloc_bytes" {
    const a = testing.allocator;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 2 AS x ORDER BY x" });
    defer a.free(res.out);
    defer a.free(res.err);
    try testing.expectEqual(@as(i32, 0), res.code);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, res.out, " \n\r\t"), .{});
    defer parsed.deinit();
    const profile = parsed.value.object.get("profile").?.object;
    var sum_ops: i64 = 0;
    for (profile.get("ops").?.array.items) |op| sum_ops += op.object.get("bytes_alloc").?.integer;
    const total = profile.get("memory").?.object.get("total_alloc_bytes").?.integer;
    try testing.expect(total > 0);
    try testing.expectEqual(total, sum_ops);
}
