// End-to-end integration tests for the social network dataset
// Tests migration loading and queries using geodec

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const test_timeout = 30 * std.time.ns_per_s;

// Helper to run geodec commands
fn runGeodec(allocator: std.mem.Allocator, query: []const u8) !std.ChildProcess.ExecResult {
    const argv = [_][]const u8{ "./zig-out/bin/geodec", "--host", "127.0.0.1", "--port", "8443", query };
    return try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 1024 * 1024,
    });
}

// Helper to load a migration file
fn loadMigrationFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);
    
    // Use geodec to execute the migration
    const result = try runGeodec(allocator, content);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("Migration failed: {s}\n", .{result.stderr});
        return error.MigrationFailed;
    }
}

test "dataset migration and basic queries" {
    // Skip if not in CI or explicit test mode
    if (std.os.getenv("GEODE_RUN_DATASET_TESTS") == null and 
        std.os.getenv("CI") == null) {
        return error.SkipZigTest;
    }
    
    const allocator = testing.allocator;
    
    // Start server
    var server = std.ChildProcess.init(
        &[_][]const u8{ "./zig-out/bin/geoded", "--data_dir", "./test_data", "--port", "8443" },
        allocator
    );
    try server.spawn();
    defer _ = server.kill() catch {};
    
    // Wait for server to start
    std.time.sleep(3 * std.time.ns_per_s);
    
    // Load migrations
    const migrations = [_][]const u8{
        "migrations/001_social_network_schema.gql",
        "migrations/002_social_network_data.gql",
        "migrations/003_social_network_relationships.gql",
        "migrations/004_social_network_events_products.gql",
    };
    
    for (migrations) |migration| {
        std.debug.print("Loading migration: {s}\n", .{migration});
        try loadMigrationFile(allocator, migration);
    }
    
    // Test queries
    const test_queries = [_]struct {
        name: []const u8,
        query: []const u8,
        expected_pattern: []const u8,
    }{
        .{
            .name = "Node count",
            .query = "MATCH (n) RETURN count(n) AS count",
            .expected_pattern = "count",
        },
        .{
            .name = "IP private check",
            .query = "MATCH (u:User {id: 'user-1'}) RETURN ip_is_private(u.ip_address) AS is_private",
            .expected_pattern = "true",
        },
        .{
            .name = "Distance calculation",
            .query = "MATCH (l1:Location {name: 'San Francisco'}), (l2:Location {name: 'New York'}) RETURN distance_haversine(l1.coordinates, l2.coordinates) AS distance",
            .expected_pattern = "distance",
        },
        .{
            .name = "Vector similarity",
            .query = "MATCH (p1:Post {id: 'post-1'}), (p2:Post) WHERE p1 <> p2 AND vector_cosine_similarity(p1.content_vector, p2.content_vector) > 0.5 RETURN count(p2) AS similar",
            .expected_pattern = "similar",
        },
        .{
            .name = "Currency type",
            .query = "MATCH (c:Company {id: 'comp-1'}) RETURN c.revenue",
            .expected_pattern = "USD",
        },
    };
    
    for (test_queries) |test_case| {
        std.debug.print("Testing: {s}\n", .{test_case.name});
        
        const result = try runGeodec(allocator, test_case.query);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("Query failed: {s}\n", .{result.stderr});
            return error.QueryFailed;
        }
        
        if (std.mem.indexOf(u8, result.stdout, test_case.expected_pattern) == null) {
            std.debug.print("Expected pattern '{s}' not found in output\n", .{test_case.expected_pattern});
            return error.UnexpectedOutput;
        }
    }
}

// CANARY: REQ=REQ-GQL-DATASET-E2E; FEATURE="DatasetIntegrationE2E"; ASPECT=Testing; STATUS=TESTED;
// TEST=e2e_dataset_integration.zig; BENCH=benchmark_dataset_e2e.zig; OWNER=test-team; UPDATED=2025-09-26