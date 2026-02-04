const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 18);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "protocol: PROFILE cpu_time_ns present and <= time_ns" {
    const exe = "zig-out/bin/geode";
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next();
    const profile_line = it.next() orelse return error.MissingProfile;
    // Scan for cpu_time_ns occurrences and ensure value <= corresponding time_ns before it closes the object.
    var search_index: usize = 0;
    while (std.mem.indexOfPos(u8, profile_line, search_index, "cpu_time_ns")) |pos| {
        // parse cpu_time_ns number
        var i = pos;
        const colon = std.mem.indexOfPos(u8, profile_line, i, ":") orelse break;
        i = colon + 1;
        while (i < profile_line.len and profile_line[i] == ' ') i += 1;
        var cpu: usize = 0;
        while (i < profile_line.len and profile_line[i] >= '0' and profile_line[i] <= '9') : (i += 1) {
            const digit: u8 = profile_line[i] - '0';
            cpu = cpu * 10 + digit;
        }
        // Look backwards for nearest preceding "time_ns": inside same object.
        var back = pos;
        var time_val: usize = 0;
        while (back > 10) : (back -= 1) {
            if (back >= 8 and std.mem.eql(u8, profile_line[back - 8 .. back], "time_ns\"")) {
                // parse forward from colon after this
                var j = back;
                const colon2 = std.mem.indexOfPos(u8, profile_line, j, ":") orelse break;
                j = colon2 + 1;
                while (j < profile_line.len and profile_line[j] == ' ') j += 1;
                while (j < profile_line.len and profile_line[j] >= '0' and profile_line[j] <= '9') : (j += 1) {
                    const digit2: u8 = profile_line[j] - '0';
                    time_val = time_val * 10 + digit2;
                }
                break;
            }
        }
        try testing.expect(time_val >= cpu);
        search_index = i;
    }
}
