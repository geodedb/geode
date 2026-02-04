const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    const err = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 14);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 3,
    };
    return .{ .code = code, .out = out, .err = err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Golden-ish schema test: ensure stable leading field ordering for first op and totals presence.
// We assert substrings in expected relative order to avoid brittle full-line goldens while freezing key fields.

test "protocol: PROFILE golden simple query" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    try testing.expectEqual(@as(i32, 0), res.code);
    // Output has two JSON lines: SCHEMA then PROFILE
    // Find second line start
    if (std.mem.indexOf(u8, res.out, "\n")) |nl| {
        const second = if (nl + 1 < res.out.len) res.out[nl + 1 ..] else res.out[0..0];
        // Required anchors
        const req = [_][]const u8{
            "\"profile_version\":1",
            "\"ops\":[",
            "\"op\":\"Project\",
            "\"phase\":\"PROJECT\",
            "\"id\":0",
            "\"op_index\":0",
            "\"rows\":1",
            "\"totals\":{",
            "\"time_ns\":",
            "\"peak_bytes\":",
        };
        var last_pos: usize = 0;
        for (req) |needle| {
            const p = std.mem.indexOfPos(u8, second, last_pos, needle) orelse return error.MissingSubstring;
            last_pos = p + needle.len;
        }
    } else return error.InvalidFormat;
}
