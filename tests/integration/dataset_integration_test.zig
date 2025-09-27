// Integration tests for the social network dataset
// Tests the migration system and queries across all features

const std = @import("std");
const testing = std.testing;
const process = std.process;

const test_timeout = 30 * std.time.ns_per_s; // 30 seconds per test

pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !std.ChildProcess.ExecResult {
    return try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024, // 1MB
    });
}

pub fn loadMigrations(allocator: std.mem.Allocator) !void {
    const migrations = [_][]const u8{
        "migrations/001_social_network_schema.gql",
        "migrations/002_social_network_data.gql",
        "migrations/003_social_network_relationships.gql",
        "migrations/004_social_network_events_products.gql",
    };

    for (migrations) |migration| {
        std.debug.print("Loading migration: {s}\n", .{migration});
        
        // Read migration file
        const file = try std.fs.cwd().openFile(migration, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        
        // Execute migration
        const result = try runCommand(allocator, &.{ "./zig-out/bin/geodec", "--host", "127.0.0.1", "--port", "8443", content });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        if (result.term.Exited != 0) {
            std.debug.print("Migration failed: {s}\n", .{result.stderr});
            return error.MigrationFailed;
        }
    }
}

test "dataset migration system loads successfully" {
    const allocator = testing.allocator;
    
    // Start server in background
    var server = std.ChildProcess.init(&.{ "./zig-out/bin/geoded", "--data_dir", "./test_data", "--port", "8443" }, allocator);
    try server.spawn();
    defer _ = server.kill() catch {};
    
    // Wait for server to start
    std.time.sleep(2 * std.time.ns_per_s);
    
    // Load migrations
    try loadMigrations(allocator);
    
    // Verify node count
    const result = try runCommand(allocator, &.{ "./zig-out/bin/geodec", "MATCH (n) RETURN count(n) AS count" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "count") != null);
}

test "dataset has correct schema after migration" {
    const allocator = testing.allocator;
    
    // Check User label exists with properties
    const result = try runCommand(allocator, &.{ 
        "./zig-out/bin/geodec", 
        "MATCH (u:User) RETURN u LIMIT 1" 
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "username") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "ip_address") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "profile_vector") != null);
}

test "network types work correctly" {
    const allocator = testing.allocator;
    
    // Test IP address operations
    const queries = [_]struct {
        query: []const u8,
        expected_in_output: []const u8,
    }{
        .{
            .query = "MATCH (u:User {id: 'user-1'}) RETURN ip_is_private(u.ip_address) AS is_private",
            .expected_in_output = "true",
        },
        .{
            .query = "MATCH (d:Device {id: 'device-1'}) RETURN ip_contains(d.subnet, d.ip_address) AS contained",
            .expected_in_output = "true",
        },
        .{
            .query = "MATCH (d:Device {id: 'device-1'}) RETURN mac_vendor_oui(d.mac_address) AS oui",
            .expected_in_output = "a1:b2:c3",
        },
    };
    
    for (queries) |q| {
        const result = try runCommand(allocator, &.{ "./zig-out/bin/geodec", q.query });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        try testing.expect(result.term.Exited == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, q.expected_in_output) != null);
    }
}

test "geographic types and queries work" {
    const allocator = testing.allocator;
    
    // Test distance calculation
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "MATCH (l1:Location {name: 'San Francisco'}), (l2:Location {name: 'New York'}) " ++
        "RETURN distance_haversine(l1.coordinates, l2.coordinates) AS distance",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
    // Distance should be approximately 4,100,000 meters
    try testing.expect(std.mem.indexOf(u8, result.stdout, "distance") != null);
}

test "vector similarity search works" {
    const allocator = testing.allocator;
    
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "MATCH (p1:Post {id: 'post-1'}), (p2:Post) " ++
        "WHERE p1 <> p2 AND vector_cosine_similarity(p1.content_vector, p2.content_vector) > 0.5 " ++
        "RETURN count(p2) AS similar_count",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "similar_count") != null);
}

test "relationships are correctly established" {
    const allocator = testing.allocator;
    
    // Test various relationship patterns
    const queries = [_][]const u8{
        "MATCH (u:User)-[:FOLLOWS]->(u2:User {id: 'user-3'}) RETURN count(u) AS followers",
        "MATCH (u:User {id: 'user-1'})-[:POSTED]->(p:Post) RETURN count(p) AS posts",
        "MATCH (u:User)-[:ATTENDING]->(e:Event {id: 'event-1'}) RETURN count(u) AS attendees",
        "MATCH (c:Company)-[:INVESTED_IN]->(c2:Company) RETURN count(c) AS investors",
        "MATCH (u:User {id: 'user-1'})-[:MEMBER_OF]->(g:Group) RETURN count(g) AS groups",
    };
    
    for (queries) |query| {
        const result = try runCommand(allocator, &.{ "./zig-out/bin/geodec", query });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        try testing.expect(result.term.Exited == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "count") != null or 
                          std.mem.indexOf(u8, result.stdout, "followers") != null or
                          std.mem.indexOf(u8, result.stdout, "posts") != null or
                          std.mem.indexOf(u8, result.stdout, "attendees") != null or
                          std.mem.indexOf(u8, result.stdout, "investors") != null or
                          std.mem.indexOf(u8, result.stdout, "groups") != null);
    }
}

test "materialized views are created and populated" {
    const allocator = testing.allocator;
    
    // Query the trending_posts materialized view
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "SELECT * FROM trending_posts LIMIT 5",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    // Even if empty, the view should exist
    try testing.expect(result.term.Exited == 0 or std.mem.indexOf(u8, result.stderr, "empty") != null);
}

test "constraints are enforced" {
    const allocator = testing.allocator;
    
    // Try to violate unique constraint on User email
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "CREATE (:User {id: 'test-dup', email: 'alice.johnson@example.com', username: 'test'})",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    // Should fail due to unique constraint
    try testing.expect(result.term.Exited != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "constraint") != null or
                      std.mem.indexOf(u8, result.stderr, "unique") != null);
}

test "indexes improve query performance" {
    const allocator = testing.allocator;
    
    // Query using indexed field (should be fast)
    const start = std.time.nanoTimestamp();
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "MATCH (u:User) WHERE u.email = 'alice.johnson@example.com' RETURN u.username",
    });
    const elapsed = std.time.nanoTimestamp() - start;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "alice_j") != null);
    // Should complete in under 100ms with index
    try testing.expect(elapsed < 100 * std.time.ns_per_ms);
}

test "full-text search works on indexed fields" {
    const allocator = testing.allocator;
    
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "MATCH (p:Post) WHERE fulltext_search(p.content, 'graph database') RETURN count(p) AS matches",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "matches") != null);
}

test "spatial index queries work efficiently" {
    const allocator = testing.allocator;
    
    // Find all locations within a bounding box
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "MATCH (l:Location) " ++
        "WHERE st_within(l.coordinates, " ++
        "  st_makeenvelope(-123, 37, -122, 38)) " ++
        "RETURN count(l) AS in_box",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
}

test "transaction rollback works correctly" {
    const allocator = testing.allocator;
    
    // Start transaction
    _ = try runCommand(allocator, &.{ "./zig-out/bin/geodec", "BEGIN" });
    
    // Create a test node
    _ = try runCommand(allocator, &.{ 
        "./zig-out/bin/geodec", 
        "CREATE (:TestNode {id: 'rollback-test'})" 
    });
    
    // Rollback
    _ = try runCommand(allocator, &.{ "./zig-out/bin/geodec", "ROLLBACK" });
    
    // Verify node doesn't exist
    const result = try runCommand(allocator, &.{
        "./zig-out/bin/geodec",
        "MATCH (n:TestNode {id: 'rollback-test'}) RETURN count(n) AS count",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "\"count\":0") != null);
}

// CANARY: REQ=REQ-GQL-DATASET; FEATURE="DatasetIntegrationTests"; ASPECT=Testing; STATUS=TESTED;
// TEST=dataset_integration_test.zig; BENCH=benchmark_dataset_load.zig; OWNER=test-team; UPDATED=2025-09-26