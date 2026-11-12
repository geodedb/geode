// End-to-end integration tests for the social network dataset
// Tests migration loading and queries using unified geode CLI

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");

const test_timeout = 30 * std.time.ns_per_s;

// Helper to run geode query commands against a QUIC server
fn runGeodeQuery(allocator: std.mem.Allocator, server: []const u8, query: []const u8) !std.process.Child.RunResult {
    const argv = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "--server",
        server,
        "--insecure",
        "--user",
        "geode",
        "--password",
        "Geode Test Admin Passphrase",
        "--format",
        "json",
        query,
    };
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 1024 * 1024,
    });
}

// Helper to load a migration file
fn loadMigrationFile(allocator: std.mem.Allocator, server: []const u8, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Use geode query to execute the migration
    const result = try runGeodeQuery(allocator, server, content);
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
    util.testStart("dataset migration and basic queries");
    errdefer util.testFail();

    // Skip if not in CI or explicit test mode
    if (std.posix.getenv("GEODE_RUN_DATASET_TESTS") == null and
        std.posix.getenv("CI") == null)
    {
        util.testSkip();
        return error.SkipZigTest;
    }

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

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("GEODE_ADMIN_USERNAME", "geode");
    try env_map.put("GEODE_DEFAULT_PASSWORD", "Geode Test Admin Passphrase");
    try env_map.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = std.process.Child.init(
        &[_][]const u8{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data_dir", "./test_data" },
        allocator,
    );
    server.env_map = &env_map;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    // Wait for server to start
    std.time.sleep(3 * std.time.ns_per_s);

    // Load migrations
    const migrations = [_][]const u8{
        "migrations/001_social_network_schema.gql",
        "migrations/002_social_network_data.gql",
        "migrations/003_social_network_relationships.gql",
        "migrations/004_social_network_events_products.gql",
    };

    util.progress("Loading migrations...", .{});
    for (migrations) |migration| {
        util.progress("Loading migration: {s}", .{migration});
        try loadMigrationFile(allocator, addr, migration);
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

    util.progress("Running test queries...", .{});
    for (test_queries) |test_case| {
        util.progress("Testing: {s}", .{test_case.name});

        const result = try runGeodeQuery(allocator, addr, test_case.query);
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

    util.testPass();
}

// CANARY: REQ=REQ-GQL-DATASET-E2E; FEATURE="DatasetIntegrationE2E"; ASPECT=Testing; STATUS=TESTED; TEST=e2e_dataset_integration.zig; BENCH=benchmark_dataset_e2e.zig; OWNER=test-team; UPDATED=2025-09-29
