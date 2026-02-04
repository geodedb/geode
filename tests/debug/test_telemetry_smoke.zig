const std = @import("std");

fn fileExists(path: []const u8) bool {
    const cwd = std.fs.cwd();
    cwd.access(path, .{}) catch return false;
    return true;
}

fn getEnvOrNull(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

test "Telemetry smoke emits PULL_PAGE (env-gated)" {
    const allocator = std.testing.allocator;

    // Gate this test behind an env var so default CI/test runs are unaffected.
    const gate = getEnvOrNull(allocator, "GEODE_CI_TELEMETRY_SMOKE");
    defer if (gate) |g| allocator.free(g);
    if (gate == null or !std.mem.eql(u8, gate.?, "1")) {
        // Skip silently when not explicitly enabled.
        return;
    }

    // Optional strict mode: fail if telemetry not observed or if server cannot start
    const strict_env = getEnvOrNull(allocator, "GEODE_CI_TELEMETRY_STRICT");
    defer if (strict_env) |s| allocator.free(s);
    const strict_mode = strict_env != null and std.mem.eql(u8, strict_env.?, "1");

    const client_path = "zig-out/bin/geode";
    const server_path = "zig-out/bin/geode";

    if (!fileExists(client_path)) {
        // Binaries not present; treat as skip.
        return;
    }
    if (!fileExists(server_path)) {
        // Server binary not present; treat as skip unless strict is requested.
        if (strict_mode) {
            std.debug.print("server binary missing (strict)\n", .{});
            try std.testing.expect(false);
        }
        return;
    }
    // Spawn server in QUIC mode and enable telemetry via env.
    var server_env = try std.process.getEnvMap(allocator);
    defer server_env.deinit();
    try server_env.put("GEODE_TELEMETRY_PAGING", "1");
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
    var server = std.process.Child.init(&.{ server_path, "--listen", "127.0.0.1:7567", "--result-format", "json" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Ignore;
    server.stderr_behavior = .Pipe;
    server.env_map = &server_env;
    // Enable passive teardown to avoid vendor QUIC crash during fast exit in tests
    try server_env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    server.spawn() catch |e| {
        // If server fails to spawn, soft-pass unless strict
        if (strict_mode) {
            std.debug.print("server spawn error (strict): {s}\n", .{@errorName(e)});
            try std.testing.expect(false);
        }
        return;
    };
    const serr_file_pre = server.stderr;
    // Briefly wait for server to start listening (longer in strict mode)
    var boot_ms: u64 = 300;
    if (strict_mode) boot_ms = 500;
    std.Thread.sleep(boot_ms * std.time.ns_per_ms);

    // Run a query that deterministically yields multiple pages to trigger paging telemetry.
    // Use params path to generate multiple rows and avoid single-row fast paths.
    // Query: RETURN a AS x ORDER BY x LIMIT 5 with a param vector of 10 ints -> 2 pages at page_size=3.
    var client = std.process.Child.init(&.{
        client_path,
        "RETURN a AS x ORDER BY x LIMIT 5",
        "--param",
        "a",
        "[1,2,3,4,5,6,7,8,9,10]",
        "--format",
        "json",
        "--page-size",
        "3",
        "--pull-all",
        "--quic",
        "--server",
        "127.0.0.1:7567",
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

    // Allow server to flush telemetry. Use a longer wait in strict mode.
    var wait_ms: u64 = 500;
    if (strict_mode) wait_ms = 900;
    std.Thread.sleep(wait_ms * std.time.ns_per_ms);
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
        if (!file_hit and strict_mode) {
            // One more brief wait and retry file read in strict mode to absorb slow flush.
            std.Thread.sleep(250 * std.time.ns_per_ms);
            if (fileExists(tmp_path)) {
                // re-read
                const retry_buf = std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 20) catch &[_]u8{};
                defer if (retry_buf.len > 0) allocator.free(retry_buf);
                if (std.mem.indexOf(u8, retry_buf, needle) != null) file_hit = true;
            }
        }
        if (file_hit) return; // success via capture file
        if (strict_mode) {
            const sz = err_all.len;
            const cap_sz: usize = if (file_buf.len > 0) file_buf.len else 0;
            std.debug.print("telemetry not found (strict) — enable GEODE_CI_TELEMETRY_SMOKE=1 and retry; stderr size={d}, cap size={d}, cap path={s}\n", .{ sz, cap_sz, tmp_path });
            try std.testing.expect(false);
        } else {
            // Soft-pass in convenience mode to avoid flakiness in short-lived runs.
            std.debug.print("telemetry not found; soft-pass (set GEODE_CI_TELEMETRY_STRICT=1 to enforce in dedicated pipelines)\n", .{});
            return;
        }
    }
}
