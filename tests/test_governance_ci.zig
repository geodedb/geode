const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=GovernanceCombinedCheck; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceCombinedCheck; OWNER=tooling; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_010_GovernanceCombinedCheck" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var child = std.process.Child.init(&[_][]const u8{ "zig", "run", "scripts/governance_ci.zig" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var buf: [8192]u8 = undefined;
    var stdout_file = child.stdout.?;
    var total: usize = 0;
    while (true) {
        const read_n = try stdout_file.read(buf[total..]);
        if (read_n == 0) break;
        total += read_n;
        if (total == buf.len) break; // guard
    }
    const n = total;
    const term = try child.wait();
    try std.testing.expectEqual(@as(u8, 0), term.Exited);
    const slice = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, slice, "\"status\":\"success\"") != null);
    inline for (.{ "freshness", "canary", "doc_consistency", "gap_consistency", "next_slices" }) |step_name| {
        try std.testing.expect(std.mem.indexOf(u8, slice, step_name) != null);
    }
    inline for (.{ "doc_consistency", "gap_consistency", "next_slices" }) |step_name| {
        var pattern_buf: [64]u8 = undefined;
        const pat = std.fmt.bufPrint(&pattern_buf, "\"name\":\"{s}\",\"ok\":true", .{step_name}) catch return error.FormatFail;
        try std.testing.expect(std.mem.indexOf(u8, slice, pat) != null);
    }
}
