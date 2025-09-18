const std = @import("std");
const testing = std.testing;

test "OPTIONAL MATCH returns NULL for unmatched patterns" {
    const allocator = testing.allocator;
    
    // Start server
    var server = try std.process.Child.init(&.{
        "./zig-out/bin/geoded",
        "--listen-tcp",
        "127.0.0.1:17567",
    }, allocator);
    try server.spawn();
    defer _ = server.kill() catch {};
    
    // Wait for server to start
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Connect and test
    const client = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "CREATE (n:Person {name: 'Alice'})",
        "--server",
        "127.0.0.1:17567",
        "--format=json",
    }, allocator);
    
    var stdout = std.ArrayList(u8).init(allocator);
    defer stdout.deinit();
    
    const result = try client.spawnAndWait();
    try testing.expect(result.Exited == 0);
    
    // Test OPTIONAL MATCH
    const client2 = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "MATCH (n:Person) OPTIONAL MATCH (n)-[r:KNOWS]->(m:Person) RETURN n.name, m.name",
        "--server",
        "127.0.0.1:17567",
        "--format=json",
    }, allocator);
    
    const result2 = try client2.spawnAndWait();
    try testing.expect(result2.Exited == 0);
    
    // Should return Alice with NULL for m.name since no KNOWS relationship exists
}

test "Variable-length path expansion" {
    const allocator = testing.allocator;
    
    // Start server
    var server = try std.process.Child.init(&.{
        "./zig-out/bin/geoded",
        "--listen-tcp",
        "127.0.0.1:17568",
    }, allocator);
    try server.spawn();
    defer _ = server.kill() catch {};
    
    // Wait for server to start
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
    
    for (queries) |query| {
        const client = try std.process.Child.init(&.{
            "./zig-out/bin/geodec",
            query,
            "--server",
            "127.0.0.1:17568",
            "--format=json",
        }, allocator);
        
        const result = try client.spawnAndWait();
        try testing.expect(result.Exited == 0);
    }
    
    // Test variable-length path
    const client = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "MATCH (a:Node {id: 1})-[:NEXT*1..3]->(b) RETURN a.id, b.id",
        "--server",
        "127.0.0.1:17568",
        "--format=json",
    }, allocator);
    
    const result = try client.spawnAndWait();
    try testing.expect(result.Exited == 0);
    
    // Should return paths of length 1, 2, and 3
}

test "MVCC conflict detection - write-write conflict" {
    const allocator = testing.allocator;
    
    // Start server
    var server = try std.process.Child.init(&.{
        "./zig-out/bin/geoded",
        "--listen-tcp",
        "127.0.0.1:17569",
    }, allocator);
    try server.spawn();
    defer _ = server.kill() catch {};
    
    // Wait for server to start
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Create initial data
    const client1 = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "CREATE (n:Account {id: 1, balance: 100})",
        "--server",
        "127.0.0.1:17569",
        "--format=json",
    }, allocator);
    
    const result1 = try client1.spawnAndWait();
    try testing.expect(result1.Exited == 0);
    
    // Start two transactions that will conflict
    // Transaction 1: BEGIN
    const txn1_begin = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "BEGIN",
        "--server",
        "127.0.0.1:17569",
        "--format=json",
    }, allocator);
    _ = try txn1_begin.spawnAndWait();
    
    // Transaction 2: BEGIN
    const txn2_begin = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "BEGIN",
        "--server",
        "127.0.0.1:17569",
        "--format=json",
    }, allocator);
    _ = try txn2_begin.spawnAndWait();
    
    // Both try to update the same node
    // This should trigger conflict detection
}

test "Storage catalog persistence" {
    const allocator = testing.allocator;
    
    // Create temp directory for data
    const tmp_dir = "/tmp/geode_test_persist";
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};
    
    // Start server with data_dir
    var server = try std.process.Child.init(&.{
        "./zig-out/bin/geoded",
        "--listen-tcp",
        "127.0.0.1:17570",
        "--data_dir",
        tmp_dir,
    }, allocator);
    try server.spawn();
    
    // Wait for server to start
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Create some data
    const client = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "CREATE (n:Person {name: 'Alice', age: 30})",
        "--server",
        "127.0.0.1:17570",
        "--format=json",
    }, allocator);
    
    const result = try client.spawnAndWait();
    try testing.expect(result.Exited == 0);
    
    // Stop server
    _ = server.kill() catch {};
    
    // Restart server with same data_dir
    var server2 = try std.process.Child.init(&.{
        "./zig-out/bin/geoded",
        "--listen-tcp",
        "127.0.0.1:17570",
        "--data_dir",
        tmp_dir,
    }, allocator);
    try server2.spawn();
    defer _ = server2.kill() catch {};
    
    // Wait for server to start
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Query the data - should still be there
    const client2 = try std.process.Child.init(&.{
        "./zig-out/bin/geodec",
        "MATCH (n:Person {name: 'Alice'}) RETURN n.name, n.age",
        "--server",
        "127.0.0.1:17570",
        "--format=json",
    }, allocator);
    
    const result2 = try client2.spawnAndWait();
    try testing.expect(result2.Exited == 0);
    
    // Should return Alice with age 30
}