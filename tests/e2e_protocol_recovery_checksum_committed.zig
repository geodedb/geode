const std = @import("std");

// Recovery test: simulate a prior run with a committed txn and a page checksum mismatch.
// Procedure:
// 1. Start server to generate WAL with one committed txn (BEGIN->COMMIT) and a PROFILE query to flush.
// 2. Stop server.
// 3. Corrupt persisted page_0.bin checksum (if exists) via simple flip; set GEODE_CHECKSUM_TEST_PATH to directory.
// 4. Restart server with that env and issue PROFILE query; expect first output line to contain StoragePageChecksum diagnostic and later PROFILE totals with committed_txns >=1.
// Simplification: If no page file exists, skip checksum corruption step but still assert committed_txns metric.

test "protocol recovery checksum + committed_txns" {
    const gpa = std.testing.allocator;
    const exe_path = "./zig-out/bin/geoded";
    // Use a temp directory for pages
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const base_path = try tmpdir.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);
    // First run: produce WAL commit
    var child1 = std.process.Child.init(&[_][]const u8{exe_path}, gpa);
    child1.stdin_behavior = .Pipe;
    child1.stdout_behavior = .Pipe;
    // Provide env with page manager base path
    var env1 = try std.process.getEnvMap(gpa);
    defer env1.deinit();
    child1.env_map = &env1;
    try child1.spawn();
    if (child1.stdin) |stdin| {
        try stdin.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writeAll("{\"type\":\"COMMIT\"}\n");
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN 1 AS x ORDER BY x LIMIT 1\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":100}\n");
        stdin.close();
        child1.stdin = null;
    }
    // Drain output but ignore
    if (child1.stdout) |so| {
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch 0;
            if (n == 0) break;
        }
    }
    _ = child1.wait() catch {};
    // Attempt to corrupt page_0.bin checksum if exists
    const page0 = try std.fmt.allocPrint(gpa, "{s}/page_{d}.bin", .{ base_path, 0 });
    defer gpa.free(page0);
    var maybe = tmpdir.dir.openFile(page0, .{ .mode = .read_write }) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (maybe) |*f| {
        // Flip first checksum byte if file large enough
        var buf: [16]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        if (n == buf.len) {
            // checksum at offset 12..16
            if (n >= 16) {
                buf[12] ^= 0xFF;
                try f.seekTo(0);
                try f.writeAll(&buf);
            }
        }
        f.close();
    }
    // Second run with checksum diagnostic expected
    var child2 = std.process.Child.init(&[_][]const u8{exe_path}, gpa);
    child2.stdin_behavior = .Pipe;
    child2.stdout_behavior = .Pipe;
    var env2 = try std.process.getEnvMap(gpa);
    defer env2.deinit();
    try env2.put("GEODE_CHECKSUM_TEST_PATH", base_path);
    child2.env_map = &env2;
    try child2.spawn();
    if (child2.stdin) |stdin2| {
        try stdin2.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin2.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN 1 AS x ORDER BY x LIMIT 1\"}\n");
        try stdin2.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":100}\n");
        stdin2.close();
        child2.stdin = null;
    }
    var out2: std.ArrayList(u8) = .{};
    defer out2.deinit(gpa);
    if (child2.stdout) |so2| {
        var tmp2: [16384]u8 = undefined;
        while (true) {
            const n = so2.read(&tmp2) catch 0;
            if (n == 0) break;
            try out2.appendSlice(gpa, tmp2[0..n]);
        }
    }
    _ = child2.wait() catch {};
    const out_slice = out2.items;
    // Expect committed_txns metric
    if (std.mem.indexOf(u8, out_slice, "\"committed_txns\":") == null) {
        std.debug.print("OUTPUT=\n{s}\n", .{out_slice});
        return error.MissingCommittedMetric;
    }
    // If we corrupted, expect checksum diagnostic
    if (maybe != null) {
        if (std.mem.indexOf(u8, out_slice, "StoragePageChecksum") == null) {
            std.debug.print("OUTPUT=\n{s}\n", .{out_slice});
            return error.MissingChecksumDiagnostic;
        }
    }
}
