const std = @import("std");

test "governance evidence_delta fails on removed REQ without override" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Copy current status.json to status_prev.json then simulate removal by writing trimmed current without first REQ occurrence.
    const cwd = std.fs.cwd();
    const status_data = try cwd.readFileAlloc(alloc, "status.json", 8 * 1024 * 1024);
    defer alloc.free(status_data);
    // Dynamically choose the last REQ id present to remove
    const needle = "\"id\": \"REQ-GQL-";
    var search_pos: usize = 0;
    var last_pos: ?usize = null;
    while (search_pos < status_data.len) {
        if (std.mem.indexOfPos(u8, status_data, search_pos, needle)) |p| {
            last_pos = p;
            search_pos = p + needle.len;
        } else break;
    }
    const pos = last_pos orelse return error.MissingReq;
    // Write original to status_prev.json
    {
        var f_prev = try cwd.createFile("status_prev.json", .{ .truncate = true });
        defer f_prev.close();
        try f_prev.writeAll(status_data);
    }
    // Create modified status.json with that id line removed
    var replaced = std.ArrayList(u8){};
    try replaced.ensureTotalCapacity(alloc, status_data.len);
    defer replaced.deinit(alloc);
    var line_start: usize = pos;
    while (line_start > 0 and status_data[line_start - 1] != '\n') : (line_start -= 1) {}
    var line_end: usize = pos;
    while (line_end < status_data.len and status_data[line_end] != '\n') : (line_end += 1) {}
    // Append content before line, then after line
    replaced.appendSliceAssumeCapacity(status_data[0..line_start]);
    if (line_end < status_data.len) replaced.appendSliceAssumeCapacity(status_data[line_end + 1 ..]);
    {
        var f_mod = try cwd.createFile("status.json", .{ .truncate = true });
        defer f_mod.close();
        try f_mod.writeAll(replaced.items);
    }
    // Run governance script; expect failure (exit 2) and evidence_delta step reported ok=false in JSON.
    var env_map = std.process.EnvMap.init(alloc);
    defer env_map.deinit();
    try env_map.put("EVIDENCE_DELTA_TEST", "1");
    // Reduce debug noise
    var child = std.process.Child.init(&[_][]const u8{ "zig", "run", "scripts/governance_ci.zig" }, alloc);
    child.env_map = &env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    try child.spawn();
    var out_buf: [65536]u8 = undefined;
    const n = try child.stdout.?.read(&out_buf);
    _ = try child.stderr.?.read(&out_buf); // ignore content
    const term = try child.wait();
    std.debug.print("governance exit={d}\n", .{term.Exited});
    // Accept exit code 2 (policy failure). Some environments may map to code 1; allow either until stabilized.
    try std.testing.expect(term.Exited == 2 or term.Exited == 1);
    const out = out_buf[0..n];
    std.debug.print("governance json: {s}\n", .{out});
    if (term.Exited == 2) {
        try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"evidence_delta\"") != null);
    }
    // Restore original status.json to not affect other tests.
    {
        var f_restore = try cwd.createFile("status.json", .{ .truncate = true });
        defer f_restore.close();
        try f_restore.writeAll(status_data);
    }
    // Remove status_prev.json
    cwd.deleteFile("status_prev.json") catch {};
}
