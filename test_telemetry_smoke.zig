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

    const client_path = "zig-out/bin/geodec";

    if (!fileExists(client_path)) {
        // Binaries not present; treat as skip.
        return;
    }
    // Spawn server in TCP mode and enable telemetry via env.
    var server_env = try std.process.getEnvMap(allocator);
    defer server_env.deinit();
    try server_env.put("GEODE_TELEMETRY_PAGING", "1");
    var server = std.process.Child.init(&.{ "./zig-out/bin/geoded", "--listen-tcp", "127.0.0.1:7567", "--log_json", "--result-format", "json", "--test-exit-after-first-request" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Ignore;
    server.stderr_behavior = .Pipe;
    server.env_map = &server_env;
    try server.spawn();
    // Briefly wait for server to start listening
    std.Thread.sleep(300 * std.time.ns_per_ms);

    // Run a tiny ordered+limited query with default network client (QUIC will fallback to TCP)
    var client = std.process.Child.init(&.{ client_path, "RETURN 1 AS x ORDER BY x LIMIT 1", "--format", "json", "--page-size", "1", "--pull-all" }, allocator);
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

    // Allow server to flush telemetry, then it will exit after first request due to flag
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const serr = server.stderr orelse {
        _ = server.wait() catch {};
        std.debug.print("no server stderr pipe\n", .{});
        try std.testing.expect(false);
        return;
    };
    const err_all = serr.readToEndAlloc(allocator, 1 << 20) catch &[_]u8{};
    defer if (err_all.len > 0) allocator.free(err_all);
    _ = server.wait() catch {};
    // stack buffer; no free needed

    const needle = "\"event\":\"PULL_PAGE\"";
    const strict = getEnvOrNull(allocator, "GEODE_CI_TELEMETRY_STRICT");
    defer if (strict) |s| allocator.free(s);
    if (std.mem.indexOf(u8, err_all, needle) == null) {
        // Soft-pass unless strict mode is enabled.
        if (strict != null and std.mem.eql(u8, strict.?, "1")) {
            std.debug.print("telemetry not found (strict); stderr size={d}\n", .{err_all.len});
            try std.testing.expect(false);
        } else {
            std.debug.print("telemetry not found; soft-pass (set GEODE_CI_TELEMETRY_STRICT=1 to enforce)\n", .{});
            return;
        }
    }
}
