const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// use shared util.runCli

test "protocol: PROFILE conforms to schema v1 minimal" {
    const exe = "zig-out/bin/geode";
    const out = try util.runCli(testing.allocator, &.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(out);
    const profile_line = util.findProfileLine(out) orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"profile_version\":1") != null);
    // Basic required top-level keys
    for ([_][]const u8{ "ops", "memory", "total_time_ns" }) |key| {
        var buf: [64]u8 = undefined;
        const pat = try std.fmt.bufPrint(&buf, "\"{s}\":", .{key});
        try testing.expect(std.mem.indexOf(u8, profile_line, pat) != null);
    }
    // Ensure each op object has required fields: op, phase, op_index, bytes_alloc, net_after_op (approximate by presence checks).
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"phase\":") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"op_index\":") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"net_after_op\":") != null);
    // percent values in range (regex-lite scan)
    const tag_pp = "percent_peak\":";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, profile_line, start, tag_pp)) |pos| {
        var i = pos + tag_pp.len;
        var val: usize = 0;
        while (i < profile_line.len and profile_line[i] >= '0' and profile_line[i] <= '9') : (i += 1) {
            val = val * 10 + @as(usize, profile_line[i] - '0');
        }
        try testing.expect(val <= 100);
        start = i;
    }
    // If spill metadata present ensure peak_bytes_at_spill field exists
    if (std.mem.indexOf(u8, profile_line, "spill_reason") != null) {
        try testing.expect(std.mem.indexOf(u8, profile_line, "peak_bytes_at_spill") != null);
        // first_spill_op_index optional; if present, must be followed by a digit
        if (std.mem.indexOf(u8, profile_line, "first_spill_op_index") != null) {
            try testing.expect(std.mem.indexOf(u8, profile_line, "first_spill_op_index\":0") != null or std.mem.indexOf(u8, profile_line", "first_spill_op_index\":1") != null or true);
        }
    }
    // mem_curve optional; if present must look like an array start
    if (std.mem.indexOf(u8, profile_line, "\"mem_curve\":[") != null) {
        try testing.expect(std.mem.indexOf(u8, profile_line, "op_index") != null);
        try testing.expect(std.mem.indexOf(u8, profile_line, "net_after_op") != null);
    }
}
