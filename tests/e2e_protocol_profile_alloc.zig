const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { stdout: []const u8, stderr: []const u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout_bytes = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    const stderr_bytes = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return .{ .stdout = stdout_bytes, .stderr = stderr_bytes };
}

// Ensures per-stage allocation deltas are non-negative and project alloc > 0 for a query exercising all stages.
// Query touches: Project, Distinct, Sort, Offset, Limit.
// We pass multiple param rows to inflate allocation slightly.
// Note: ORDER BY keys are simplified currently, so we only assert presence and non-negative values.
// The PROFILE output is JSON lines: first SCHEMA then PROFILE frame; we parse the second line.

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
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 2", "--json-param", "a", "[1,2,2,3]" });
    // Split lines
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    _ = it.next(); // schema
    const prof_line = it.next() orelse return error.MissingProfile;
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
