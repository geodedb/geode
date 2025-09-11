const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return .{ .out = out };
}

test "protocol: PROFILE memory percent_peak validity" {
    const exe = "zig-out/bin/geoded";
    // Exercise multiple stages to get non-trivial allocations.
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 2", "--json-param", "a", "[1,2,2,3,4,5,6]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next(); // schema line
    const profile_line = it.next() orelse return error.MissingProfileLine;
    // Extract peak_bytes
    const peak_tag = "\"peak_bytes\":";
    const peak_pos = std.mem.indexOf(u8, profile_line, peak_tag) orelse return error.MissingPeak;
    var i: usize = peak_pos + peak_tag.len;
    while (i < profile_line.len and (profile_line[i] == ' ')) i += 1;
    const peak_start = i;
    while (i < profile_line.len and profile_line[i] >= '0' and profile_line[i] <= '9') i += 1;
    const peak_bytes = try std.fmt.parseInt(usize, profile_line[peak_start..i], 10);
    try testing.expect(peak_bytes > 0);
    // Iterate over ops collecting bytes_alloc and percent_peak
    var total_bytes_alloc: usize = 0;
    var search_index: usize = 0;
    while (true) {
        const op_pos = std.mem.indexOfPos(u8, profile_line, search_index, "\"op\":");
        if (op_pos == null) break;
        const op_idx = op_pos.?;
        // bytes_alloc after this op marker
        const ba_tag = "\"bytes_alloc\":";
        const ba_pos = std.mem.indexOfPos(u8, profile_line, op_idx, ba_tag) orelse break;
        var j: usize = ba_pos + ba_tag.len;
        while (j < profile_line.len and (profile_line[j] == ' ')) j += 1;
        const ba_start = j;
        while (j < profile_line.len and profile_line[j] >= '0' and profile_line[j] <= '9') j += 1;
        if (j == ba_start) break; // malformed
        const bytes_alloc = try std.fmt.parseInt(usize, profile_line[ba_start..j], 10);
        total_bytes_alloc += bytes_alloc;
        const pp_tag = "\"percent_peak\":";
        const pp_pos = std.mem.indexOfPos(u8, profile_line, ba_pos, pp_tag) orelse break;
        var k: usize = pp_pos + pp_tag.len;
        while (k < profile_line.len and (profile_line[k] == ' ')) k += 1;
        const pp_start = k;
        while (k < profile_line.len and profile_line[k] >= '0' and profile_line[k] <= '9') k += 1;
        if (k == pp_start) break;
        const percent_peak = try std.fmt.parseInt(usize, profile_line[pp_start..k], 10);
        try testing.expect(percent_peak <= 100);
        // If peak_bytes > 0 and bytes_alloc >0 ensure percent_peak >=1
        if (peak_bytes > 0 and bytes_alloc > 0) try testing.expect(percent_peak >= 1);
        search_index = k;
    }
    // Total allocated across stages should not exceed peak * number_of_ops (trivial upper bound) but must be >= largest stage
    try testing.expect(total_bytes_alloc >= 1);
    try testing.expect(total_bytes_alloc <= peak_bytes * 10); // 10 is generous upper guard for current small queries
}
