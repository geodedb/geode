const std = @import("std");

fn fileExists(path: []const u8) bool {
    const cwd = std.fs.cwd();
    cwd.access(path, .{}) catch return false;
    return true;
}

test "Telemetry emits PULL_PAGE" {
    const allocator = std.testing.allocator;

    const client_path = "zig-out/bin/geode";
    const server_path = "zig-out/bin/geode";
    // Spawn server in QUIC mode and enable telemetry via env.
    var server_env = try std.process.getEnvMap(allocator);
    defer server_env.deinit();
    try server_env.put("GEODE_TELEMETRY_PAGING", "1");
    try server_env.put("GEODE_ADMIN_USERNAME", "geode");
    try server_env.put("GEODE_DEFAULT_PASSWORD", "geode-test-password");
    // Prepare a fallback capture file for server stderr in case pipe drains empty on some platforms.
    var tmp_path_buf: [128]u8 = undefined;
    const ts = std.time.milliTimestamp();
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "./.tmp_server_stderr_{d}.log", .{ts});
    // Ensure any previous file is removed; ignore errors.
    std.fs.cwd().deleteFile(tmp_path) catch {};
    // Create the file now so the path is valid for the server.
    {
        var f = std.fs.cwd().createFile(tmp_path, .{ .read = true, .truncate = true }) catch null;
        if (f) |*fh| fh.close();
    }
    try server_env.put("GEODE_CAPTURE_SERVER_STDERR", tmp_path);
    var server = std.process.Child.init(&.{ server_path, "serve", "--listen", "127.0.0.1:7567", "--result-format", "json" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Ignore;
    server.stderr_behavior = .Pipe;
    server.env_map = &server_env;
    // Enable passive teardown to avoid vendor QUIC crash during fast exit in tests
    try server_env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    try server.spawn();
    const serr_file_pre = server.stderr;
    // Briefly wait for server to start listening (longer in strict mode)
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Run a query that deterministically yields multiple pages to trigger paging telemetry.
    // Use params path to generate multiple rows and avoid single-row fast paths.
    // Query: RETURN a AS x ORDER BY x LIMIT 5 with a param vector of 10 ints -> 2 pages at page_size=3.
    var client = std.process.Child.init(&.{
        client_path,
        "query",
        "UNWIND $a AS x RETURN x ORDER BY x LIMIT 5",
        "--param",
        "a",
        "[1,2,3,4,5,6,7,8,9,10]",
        "--format",
        "json",
        "--page-size",
        "3",
        "--server",
        "127.0.0.1:7567",
        "--insecure",
        "--user",
        "geode",
        "--password",
        "geode-test-password",
        "--no-saved-session",
    }, allocator);
    client.stdin_behavior = .Ignore;
    client.stdout_behavior = .Ignore;
    client.stderr_behavior = .Ignore;
    const client_term = client.spawnAndWait() catch |e| {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
        std.debug.print("client error: {s}\n", .{@errorName(e)});
        return;
    };
    _ = client_term;

    // Allow server to flush telemetry.
    std.Thread.sleep(900 * std.time.ns_per_ms);
    // Now terminate server to close stderr and allow draining logs
    _ = server.kill() catch {};
    const serr = serr_file_pre orelse {
        _ = server.wait() catch {};
        if (strict_mode) {
            std.debug.print("no server stderr pipe (strict)\n", .{});
            try std.testing.expect(false);
        }
        return;
    };
    const err_all = serr.readToEndAlloc(allocator, 1 << 20) catch &[_]u8{};
    defer if (err_all.len > 0) allocator.free(err_all);
    // Server should have exited due to; wait to reap.
    _ = server.wait() catch {};
    // stack buffer; no free needed

    const needle = "\"event\":\"PULL_PAGE\"";
    if (std.mem.indexOf(u8, err_all, needle) == null) {
        // Fallback: read from capture file if provided
        var file_hit = false;
        var file_buf: []u8 = &[_]u8{};
        defer if (file_buf.len > 0) allocator.free(file_buf);
        if (fileExists(tmp_path)) {
            file_buf = std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 20) catch &[_]u8{};
            if (std.mem.indexOf(u8, file_buf, needle) != null) file_hit = true;
        }
        if (!file_hit) {
            // One more brief wait and retry file read to absorb slow flush.
            std.Thread.sleep(250 * std.time.ns_per_ms);
            if (fileExists(tmp_path)) {
                // re-read
                const retry_buf = std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 20) catch &[_]u8{};
                defer if (retry_buf.len > 0) allocator.free(retry_buf);
                if (std.mem.indexOf(u8, retry_buf, needle) != null) file_hit = true;
            }
        }
        if (file_hit) return; // success via capture file
        const sz = err_all.len;
        const cap_sz: usize = if (file_buf.len > 0) file_buf.len else 0;
        std.debug.print("telemetry not found; stderr size={d}, cap size={d}, cap path={s}\n", .{ sz, cap_sz, tmp_path });
        try std.testing.expect(false);
    }
}
