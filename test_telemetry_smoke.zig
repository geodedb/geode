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
    // Prepare client env: enable telemetry in server (inherited) and capture forwarding to client stderr.
    var client_env = try std.process.getEnvMap(allocator);
    defer client_env.deinit();
    try client_env.put("GEODE_TELEMETRY_PAGING", "1");

    // Run a tiny ordered+limited query via client in stdio mode (client will spawn server).
    var client = std.process.Child.init(&.{ client_path, "RETURN 1 AS x ORDER BY x LIMIT 1", "--format", "json", "--server", "./zig-out/bin/geoded", "--no-quic" }, allocator);
    client.stdin_behavior = .Ignore;
    client.stdout_behavior = .Ignore;
    client.stderr_behavior = .Pipe;
    client.env_map = &client_env;
    try client.spawn();
    const err_all = client.stderr.?.readToEndAlloc(allocator, 1 << 20) catch &[_]u8{};
    defer if (err_all.len > 0) allocator.free(err_all);
    _ = client.wait() catch {};
    // stack buffer; no free needed

    const needle = "\"event\":\"PULL_PAGE\"";
    if (std.mem.indexOf(u8, err_all, needle) == null) {
        // If not found, emit a helpful message and fail the test (since gate is enabled).
        std.debug.print("telemetry not found; stderr size={d}\n", .{err_all.len});
        try std.testing.expect(false);
    }
}
