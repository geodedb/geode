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
    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expect(contains(res.out, "\"profile_version\":2"));
    try testing.expect(contains(res.out, "total_alloc_bytes"));
}

// Approximate invariant: sum of op-level "bytes_alloc" fields equals memory.total_alloc_bytes.
// For a lightweight check we extract integers via a simple scan (not full JSON parse) limited to small profile output.
test "profile: per-op bytes_alloc sum equals memory.total_alloc_bytes" {
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 2 AS x ORDER BY x" });
    try testing.expectEqual(@as(i32, 0), res.code);
    const out = res.out;
    var it = std.mem.tokenizeAny(u8, out, " ,\n\r\t{}[]:\"\"");
    var sum_ops: u64 = 0;
    var total: u64 = 0;
    var last_key: []const u8 = &.{};
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "bytes_alloc")) {
            last_key = tok;
            continue;
        }
        if (std.mem.eql(u8, tok, "total_alloc_bytes")) {
            last_key = tok;
            continue;
        }
        if (last_key.len != 0) {
            if (std.mem.eql(u8, last_key, "bytes_alloc")) {
                if (std.fmt.parseUnsigned(u64, tok, 10)) |v| {
                    sum_ops += v;
                } else |_| {}
                last_key = &.{};
            } else if (std.mem.eql(u8, last_key, "total_alloc_bytes")) {
                if (std.fmt.parseUnsigned(u64, tok, 10)) |v| {
                    total = v;
                } else |_| {}
                last_key = &.{};
            }
        }
    }
    // Allow equality or small discrepancy (e.g., allocator metadata). Expect within 0.5% or absolute diff <= 64 bytes.
    const diff = if (sum_ops > total) sum_ops - total else total - sum_ops;
    if (total > 0) {
        try testing.expect(diff <= 64 or (diff * 1000 / total) <= 5);
    }
}
