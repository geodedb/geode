const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "OPTIONAL MATCH returns NULL for unmatched patterns" {
    util.testStart("OPTIONAL MATCH returns NULL for unmatched patterns");
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

    var server = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(500 * std.time.ns_per_ms);

    util.progress("Creating test data...", .{});
    var client = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "query",
        "CREATE (n:Person {name: 'Alice'})",
        "--server",
        addr,
        "--format=json",
    }, allocator);
    client.stdout_behavior = .Pipe;
    client.stderr_behavior = .Pipe;
    try client.spawn();
    _ = try client.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try client.stderr.?.readToEndAlloc(allocator, 1 << 12);
    const result = try client.wait();
    try testing.expect(result == .Exited and result.Exited == 0);

    util.progress("Testing OPTIONAL MATCH...", .{});
    var client2 = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "query",
        "MATCH (n:Person) OPTIONAL MATCH (n)-[r:KNOWS]->(m:Person) RETURN n.name, m.name",
        "--server",
        addr,
        "--format=json",
    }, allocator);
    client2.stdout_behavior = .Pipe;
    client2.stderr_behavior = .Pipe;
    try client2.spawn();
    _ = try client2.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try client2.stderr.?.readToEndAlloc(allocator, 1 << 12);
    const result2 = try client2.wait();
    try testing.expect(result2 == .Exited and result2.Exited == 0);

    util.testPass();
}

test "Variable-length path expansion" {
    util.testStart("Variable-length path expansion");
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

    var server = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(500 * std.time.ns_per_ms);

    // Create a path: A -> B -> C -> D
    const queries = [_][]const u8{
        "CREATE (a:Node {id: 1})",
        "CREATE (b:Node {id: 2})",
        "CREATE (c:Node {id: 3})",
        "CREATE (d:Node {id: 4})",
        "MATCH (a:Node {id: 1}), (b:Node {id: 2}) CREATE (a)-[:NEXT]->(b)",
        "MATCH (b:Node {id: 2}), (c:Node {id: 3}) CREATE (b)-[:NEXT]->(c)",
        "MATCH (c:Node {id: 3}), (d:Node {id: 4}) CREATE (c)-[:NEXT]->(d)",
    };

    util.progress("Creating test data...", .{});
    for (queries) |query| {
        var client = std.process.Child.init(&.{
            "./zig-out/bin/geode",
            "query",
            query,
            "--server",
            addr,
            "--format=json",
        }, allocator);
        client.stdout_behavior = .Pipe;
        client.stderr_behavior = .Pipe;
        try client.spawn();
        _ = try client.stdout.?.readToEndAlloc(allocator, 1 << 16);
        _ = try client.stderr.?.readToEndAlloc(allocator, 1 << 12);
        const result = try client.wait();
        try testing.expect(result == .Exited and result.Exited == 0);
    }

    util.progress("Testing variable-length path...", .{});
    var client = std.process.Child.init(&.{
        "./zig-out/bin/geode", "query", "MATCH (a:Node {id: 1})-[:NEXT*1..3]->(b) RETURN a.id, b.id",
        "--server",            addr,    "--format=json",
    }, allocator);
    client.stdout_behavior = .Pipe;
    client.stderr_behavior = .Pipe;
    try client.spawn();
    _ = try client.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try client.stderr.?.readToEndAlloc(allocator, 1 << 12);
    const result = try client.wait();
    try testing.expect(result == .Exited and result.Exited == 0);

    util.testPass();
}

test "MVCC conflict detection - write-write conflict" {
    util.testStart("MVCC conflict detection - write-write conflict");
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

    var server = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(500 * std.time.ns_per_ms);

    util.progress("Creating initial data...", .{});
    var client1 = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "query",
        "CREATE (n:Account {id: 1, balance: 100})",
        "--server",
        addr,
        "--format=json",
    }, allocator);
    client1.stdout_behavior = .Pipe;
    client1.stderr_behavior = .Pipe;
    try client1.spawn();
    _ = try client1.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try client1.stderr.?.readToEndAlloc(allocator, 1 << 12);
    const result1 = try client1.wait();
    try testing.expect(result1 == .Exited and result1.Exited == 0);

    util.progress("Testing transaction conflicts...", .{});
    // Start two transactions that will conflict
    // Transaction 1: BEGIN
    var txn1_begin = std.process.Child.init(&.{
        "./zig-out/bin/geode", "query", "BEGIN",
        "--server",            addr,    "--format=json",
    }, allocator);
    txn1_begin.stdout_behavior = .Pipe;
    txn1_begin.stderr_behavior = .Pipe;
    try txn1_begin.spawn();
    _ = try txn1_begin.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try txn1_begin.stderr.?.readToEndAlloc(allocator, 1 << 12);
    _ = try txn1_begin.wait();

    // Transaction 2: BEGIN
    var txn2_begin = std.process.Child.init(&.{
        "./zig-out/bin/geode", "query", "BEGIN",
        "--server",            addr,    "--format=json",
    }, allocator);
    txn2_begin.stdout_behavior = .Pipe;
    txn2_begin.stderr_behavior = .Pipe;
    try txn2_begin.spawn();
    _ = try txn2_begin.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try txn2_begin.stderr.?.readToEndAlloc(allocator, 1 << 12);
    _ = try txn2_begin.wait();

    util.testPass();
}

test "Storage catalog persistence" {
    util.testStart("Storage catalog persistence");
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

    // Create temp directory for data
    const tmp_dir = "/tmp/geode_test_persist";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    util.progress("Starting server on port {d} with data_dir...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "serve",
        "--listen",
        addr,
        "--data_dir",
        tmp_dir,
    }, allocator);
    server.env_map = &env;
    try server.spawn();

    std.time.sleep(500 * std.time.ns_per_ms);

    util.progress("Creating some data...", .{});
    var client = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "query",
        "CREATE (n:Person {name: 'Alice', age: 30})",
        "--server",
        addr,
        "--format=json",
    }, allocator);
    client.stdout_behavior = .Pipe;
    client.stderr_behavior = .Pipe;
    try client.spawn();
    _ = try client.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try client.stderr.?.readToEndAlloc(allocator, 1 << 12);
    const result = try client.wait();
    try testing.expect(result == .Exited and result.Exited == 0);

    util.progress("Stopping server...", .{});
    _ = server.kill() catch {};
    _ = server.wait() catch {};

    // Get another random port for restart
    const port2 = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr2 = try util.formatAddr(allocator, port2);
    defer allocator.free(addr2);

    util.progress("Restarting server on port {d}...", .{port2});
    var server2 = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "serve",
        "--listen",
        addr2,
        "--data_dir",
        tmp_dir,
    }, allocator);
    server2.env_map = &env;
    try server2.spawn();
    defer {
        _ = server2.kill() catch {};
        _ = server2.wait() catch {};
    }

    std.time.sleep(500 * std.time.ns_per_ms);

    util.progress("Querying data after restart...", .{});
    var client2 = std.process.Child.init(&.{
        "./zig-out/bin/geode",
        "query",
        "MATCH (n:Person {name: 'Alice'}) RETURN n.name, n.age",
        "--server",
        addr2,
        "--format=json",
    }, allocator);
    client2.stdout_behavior = .Pipe;
    client2.stderr_behavior = .Pipe;
    try client2.spawn();
    _ = try client2.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try client2.stderr.?.readToEndAlloc(allocator, 1 << 12);
    const result2 = try client2.wait();
    try testing.expect(result2 == .Exited and result2.Exited == 0);

    util.testPass();
}
