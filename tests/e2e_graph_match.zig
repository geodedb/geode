const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn run_server_and_query(allocator: std.mem.Allocator, addr: []const u8, query: []const u8) ![]const u8 {
    var argv = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        query,
        "--server",
        addr,
        "--insecure",
        "--user",
        util.defaultUsername(),
        "--password",
        util.defaultPassword(),
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    var out = std.ArrayList(u8).init(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    _ = try child.wait();
    return try out.toOwnedSlice();
}

test "MATCH node scan returns nodes" {
    util.testStart("MATCH node scan returns nodes");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    try env.put("GEODE_ADMIN_USERNAME", util.defaultUsername());
    try env.put("GEODE_DEFAULT_PASSWORD", util.defaultPassword());

    var server = std.process.Child.init(&.{
        geode_test_bin.geode_exe,
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    util.progress("Running warmup query...", .{});
    const res = try run_server_and_query(allocator, addr, "RETURN 1");
    allocator.free(res);

    util.progress("Running MATCH query...", .{});
    const out = try run_server_and_query(allocator, addr, "MATCH (n) RETURN n");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status_class\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\":[") != null);

    util.testPass();
}

test "MATCH edge traversal returns pairs" {
    util.testStart("MATCH edge traversal returns pairs");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    try env.put("GEODE_ADMIN_USERNAME", util.defaultUsername());
    try env.put("GEODE_DEFAULT_PASSWORD", util.defaultPassword());

    var server = std.process.Child.init(&.{
        geode_test_bin.geode_exe,
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    util.progress("Running query...", .{});
    const out = try run_server_and_query(allocator, addr, "MATCH (n)-[r]->(m) RETURN n, m");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status_class\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\":[") != null);

    util.testPass();
}

test "MATCH with label and property filter" {
    util.testStart("MATCH with label and property filter");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    try env.put("GEODE_ADMIN_USERNAME", util.defaultUsername());
    try env.put("GEODE_DEFAULT_PASSWORD", util.defaultPassword());

    var server = std.process.Child.init(&.{
        geode_test_bin.geode_exe,
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    util.progress("Running query...", .{});
    const out = try run_server_and_query(allocator, addr, "MATCH (n:Person) WHERE n.age > 30 RETURN n.name");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status_class\"") != null);

    util.testPass();
}

test "MATCH traversal with edge type filter" {
    util.testStart("MATCH traversal with edge type filter");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    try env.put("GEODE_ADMIN_USERNAME", util.defaultUsername());
    try env.put("GEODE_DEFAULT_PASSWORD", util.defaultPassword());

    var server = std.process.Child.init(&.{
        geode_test_bin.geode_exe,
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    util.progress("Running query...", .{});
    const out = try run_server_and_query(allocator, addr, "MATCH (n)-[r:KNOWS]->(m) RETURN n, r, m");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status_class\"") != null);

    util.testPass();
}
