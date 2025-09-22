const std = @import("std");

// Negative test: reality_freshness fails when IMPLEMENTATION_REALITY.md lacks current generated_at date and max_days=0
test "governance reality_freshness fails on stale reality doc" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const cwd = std.fs.cwd();
    // Read status.json to extract current date prefix
    const status_data = try cwd.readFileAlloc(alloc, "status.json", 8 * 1024 * 1024);
    defer alloc.free(status_data);
    const key = "\"generated_at\": \"";
    const pos_opt = std.mem.indexOf(u8, status_data, key) orelse return error.MissingGeneratedAt;
    const pos = pos_opt + key.len;
    const date_prefix = status_data[pos .. pos + 10];
    // Modify IMPLEMENTATION_REALITY.md temporarily removing date occurrences
    const reality_path = "docs/IMPLEMENTATION_REALITY.md";
    const orig = try cwd.readFileAlloc(alloc, reality_path, 4 * 1024 * 1024);
    defer alloc.free(orig);
    // Remove date_prefix occurrences by replacing with STALE-DATE
    var modified = std.ArrayList(u8).init(alloc);
    defer modified.deinit();
    var idx: usize = 0;
    while (idx < orig.len) : (idx += 1) {
        if (idx + date_prefix.len <= orig.len and std.mem.eql(u8, orig[idx .. idx + date_prefix.len], date_prefix)) {
            try modified.appendSlice("STALE-DATE");
            idx += date_prefix.len - 1;
        } else {
            try modified.append(orig[idx]);
        }
    }
    {
        var f = try cwd.createFile(reality_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(modified.items);
    }
    // Run governance with REALITY_FRESHNESS_MAX_DAYS=0 to force exact match requirement
    var env_map = [_][]const u8{"REALITY_FRESHNESS_MAX_DAYS=0"};
    var child = std.process.Child.init(&[_][]const u8{ "zig", "run", "scripts/governance_ci.zig" }, alloc);
    child.env_map = &env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    try child.spawn();
    var out_buf: [65536]u8 = undefined;
    _ = try child.stdout.?.read(&out_buf);
    _ = try child.stderr.?.read(&out_buf);
    const term = try child.wait();
    try std.testing.expectEqual(@as(u8, 2), term.Exited);
    // Restore original file
    {
        var f2 = try cwd.createFile(reality_path, .{ .truncate = true });
        defer f2.close();
        try f2.writeAll(orig);
    }
}
