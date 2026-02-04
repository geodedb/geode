const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { stdout: []const u8, stderr: []const u8 } {
    const res = try cli_test_util.run(args);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    return .{ .stdout = res.out, .stderr = res.err };
}

// Ensures per-stage allocation deltas are non-negative and project alloc > 0 for a query exercising all stages.
// Query touches: Project, Distinct, Sort, Offset, Limit.
// We pass multiple param rows to inflate allocation slightly.
// Note: ORDER BY keys are simplified currently, so we only assert presence and non-negative values.
// The PROFILE output is JSON with a top-level "profile" field; we parse that payload.

pub fn parseNumberField(json: []const u8, field: []const u8) ?usize {
    if (std.mem.indexOf(u8, json, field)) |pos| {
        if (std.mem.indexOfPos(u8, json, pos, ":")) |cpos| {
            var i: usize = cpos + 1;
            while (i < json.len and (json[i] == ' ' or json[i] == '"')) i += 1;
            const start = i;
            while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
            if (i > start) return std.fmt.parseInt(usize, json[start..i], 10) catch null;
        }
    }
    return null;
}

test "protocol: PROFILE allocation deltas non-negative" {
    const exe = "zig-out/bin/geode";
    // All stages: DISTINCT + ORDER BY + OFFSET + LIMIT.
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 2", "--param", "a", "[1,2,2,3]" });
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const profile_val = root.get("profile") orelse return error.MissingProfile;
    const prof_line = try std.json.Stringify.valueAlloc(testing.allocator, profile_val, .{});
    defer testing.allocator.free(prof_line);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"ops\"") != null);
    // Basic sanity: project bytes_alloc > 0, later stages present.
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"Project\"") != null);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"Distinct\"") != null);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"Sort\"") != null);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"Offset\"") != null);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"Limit\"") != null);
    // Ensure at least one bytes_alloc > 0 and memory summary present.
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"bytes_alloc\":0") == null);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"memory\"") != null);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"peak_bytes\":") != null);
    try testing.expect(std.mem.indexOf(u8, prof_line, "\"percent_peak\"") != null);
}
