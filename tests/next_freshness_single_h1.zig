const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="NEXT Freshness + Single H1"; ASPECT=NextFreshnessGuard; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_NextFreshnessAndSingleH1; OWNER=tooling; UPDATED=2026-11-14

fn fileAgeSeconds(fs: *std.fs.File) !u64 {
    const meta = try fs.metadata();
    const mtime_ns = meta.modified_time orelse return 0;
    const now_ns = std.time.nanoTimestamp();
    if (now_ns <= mtime_ns) return 0;
    return @intCast(u64, (now_ns - mtime_ns) / 1_000_000_000);
}

test "TestCANARY_REQ_GQL_010_NextFreshnessAndSingleH1" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    const path = "docs/NEXT.md";
    var file = try std.fs.cwd().openFile(path, .{ .read = true });
    defer file.close();

    const age = try fileAgeSeconds(&file);
    // Expect < 86400 seconds (24h)
    try std.testing.expect(age < 86400);

    // Read entire file
    const data = try file.readToEndAlloc(alloc, 1024 * 64);
    defer alloc.free(data);

    var it = std.mem.split(u8, data, "\n");
    var h1_count: usize = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "# ")) h1_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), h1_count);
}
