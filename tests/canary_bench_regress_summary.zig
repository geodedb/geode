const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Benchmark Regression JSON Summary"; ASPECT=Tooling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_BenchRegressionJsonSummaryEndToEnd; OWNER=engine; UPDATED=2025-09-20

fn writeTempFile(dir: std.fs.Dir, name: []const u8, content: []const u8) ![]const u8 {
    var file = try dir.createFile(name, .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll(content);
    return name;
}

// End-to-end test invoking bench_regress binary through spawn to validate JSON summary output and baseline write.
// This avoids embedding build logic; assumes bench_regress is built and available in PATH when `zig test` runs.
// If not available, test is skipped gracefully.

test "TestCANARY_REQ_GQL_010_BenchRegressionJsonSummaryEndToEnd" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp_dir_path_buf: [256]u8 = undefined;
    const tmp_dir_path = try std.fmt.bufPrint(&tmp_dir_path_buf, "bench_regress_tmp_{d}", .{std.time.milliTimestamp()});
    try std.fs.cwd().makeDir(tmp_dir_path);
    var tmp = try std.fs.cwd().openDir(tmp_dir_path, .{ .iterate = true, .read = true });
    defer tmp.close();

    const baseline_content = "{\"kind\":\"K1\",\"elapsed_ns\":1000}\n" ++
        "{\"kind\":\"K2\",\"elapsed_ns\":500}\n";
    const current_content = "{\"kind\":\"K1\",\"elapsed_ns\":1080}\n" ++ // within 15%
        "{\"kind\":\"K2\",\"elapsed_ns\":520}\n"; // within 15%

    _ = try writeTempFile(tmp, "base.jsonl", baseline_content);
    _ = try writeTempFile(tmp, "cur.jsonl", current_content);

    var child = std.ChildProcess.init(&[_][]const u8{ "bench_regress", tmp_dir_path ++ "/base.jsonl", tmp_dir_path ++ "/cur.jsonl", "15" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const run_result = child.spawnAndWait() catch |e| switch (e) {
        error.FileNotFound => return std.testing.skip("bench_regress binary not found in PATH"),
        else => return e,
    };
    try std.testing.expectEqual(@as(i32, 0), run_result.exit_code);

    if (child.stdout) |stdout_pipe| {
        var reader = stdout_pipe.reader();
        var line_buf: [512]u8 = undefined;
        const line = try reader.readUntilDelimiterOrEof(&line_buf, '\n');
        try std.testing.expect(line != null);
        if (line) |ln| {
            try std.testing.expect(std.mem.indexOf(u8, ln, "\"type\":\"bench_regress_summary\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, ln, "\"regressions\":0") != null);
            try std.testing.expect(std.mem.indexOf(u8, ln, "\"compared\":2") != null);
        }
    }
}
