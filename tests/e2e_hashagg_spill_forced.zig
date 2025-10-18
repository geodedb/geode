const std = @import("std");

// Forces a HashAgg spill by setting GEODE_SPILL_THRESHOLD_BYTES very low and running a GROUP query.
// Asserts PROFILE totals hashagg_spills=1 and hashagg_spill_reason="threshold".

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const cwd = std.fs.cwd();
    // Create a temp data dir
    const tmpdir_name = try std.fmt.allocPrint(allocator, "spilltest-{d}", .{std.time.milliTimestamp()});
    defer allocator.free(tmpdir_name);
    try cwd.makeDir(tmpdir_name);
    // Spawn server process with env override
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var env_map = std.process.getEnvMap(arena.allocator()) catch unreachable;
    try env_map.put("GEODE_SPILL_THRESHOLD_BYTES", "1024"); // very low
    // Build command: run geoded with PROFILE query piped via stdin
    var child = std.process.Child.init(&.{"./zig-out/bin/geoded"}, arena.allocator());
    child.env_map = &env_map;
    child.cwd = tmpdir_name;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const query = "PROFILE RETURN 1 AS x, 2 AS y GROUP BY x"; // triggers HashAgg
    // Send RUN_GQL frame (simplified text-only fast path: just the query line)
    if (child.stdin) |*in| {
        try in.writeAll(query);
        try in.writeAll("\n");
    }
    // Read some output lines until we observe totals or timeout
    var buf: [8192]u8 = undefined;
    var out_acc = std.ArrayList(u8).init(allocator);
    defer out_acc.deinit();
    const deadline = std.time.nanoTimestamp() + 5_000_000_000; // 5s
    while (true) {
        if (std.time.nanoTimestamp() > deadline) break;
        if (child.stdout) |*so| {
            const n = so.read(&buf) catch 0;
            if (n == 0) break;
            try out_acc.appendSlice(buf[0..n]);
            if (std.mem.indexOf(u8, out_acc.items, "hashagg_spills") != null and std.mem.indexOf(u8, out_acc.items, "hashagg_spill_reason") != null) {
                break;
            }
        } else break;
    }
    _ = child.kill() catch {};
    const out_bytes = out_acc.items;
    if (std.mem.indexOf(u8, out_bytes, "\"hashagg_spills\":1") == null) return error.ExpectedSpillMetric;
    if (std.mem.indexOf(u8, out_bytes, "\"hashagg_spill_reason\":\"threshold\"") == null) return error.ExpectedSpillReason;
}
