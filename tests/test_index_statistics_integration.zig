const std = @import("std");
const testing = std.testing;
const graph_common = @import("../src/types/graph_common.zig");
const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;
const IndexStatisticsManager = @import("../src/server/index_statistics.zig").IndexStatisticsManager;

// Tests for complete IndexStatistics integration with IndexOptimizer
// CANARY: REQ=REQ-GQL-016; FEATURE="IndexStatisticsIntegration"; ASPECT=CostEstimation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_IndexStatisticsIntegration; OWNER=engine; UPDATED=2025-10-03

// Mock index manager for integration tests
const StatisticsIndexManager = struct {
    property_indexes: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StatisticsIndexManager {
        return StatisticsIndexManager{
            .property_indexes = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StatisticsIndexManager) void {
        self.property_indexes.deinit();
    }

    pub fn lookupPropertyIndex(self: *StatisticsIndexManager, index_name: []const u8, search_key: []const u8) !?u64 {
        _ = search_key;
        if (self.property_indexes.contains(index_name)) {
            return 1;
        }
        return null;
    }

    pub fn addIndex(self: *StatisticsIndexManager, label: []const u8, property: []const u8, index_type: graph_common.IndexType) !void {
        var index_name_buf: [256]u8 = undefined;
        const index_name = try std.fmt.bufPrint(&index_name_buf, "{s}_{s}_{s}_idx", .{ label, property, @tagName(index_type) });
        try self.property_indexes.put(try self.allocator.dupe(u8, index_name), {});
    }
};

test "TestCANARY_REQ_GQL_016_IndexStatisticsIntegration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = StatisticsIndexManager.init(allocator);
    defer index_manager.deinit();

    var stats_manager = IndexStatisticsManager.init(allocator);
    defer stats_manager.deinit();

    // Create an index and its corresponding statistics
    try index_manager.addIndex("User", "email", .hash);

    // Create statistics for the index
    const properties = [_][]const u8{"email"};
    try stats_manager.createIndexStatistics("User_email_hash_idx", .hash, "User", &properties);

    // Simulate some data being indexed
    const test_entries = [_][]const u8{ "user1@example.com", "user2@example.com", "admin@company.com" };
    for (test_entries, 0..) |entry, i| {
        const is_unique = (i < test_entries.len); // All entries are unique in this test
        stats_manager.recordIndexEntry("User_email_hash_idx", entry, is_unique);
    }

    // Simulate index access
    stats_manager.recordIndexAccess("User_email_hash_idx", 1, 1); // 100% hit ratio

    // Create optimizer and connect statistics manager
    var optimizer = IndexOptimizer.init(allocator, &index_manager);
    optimizer.setStatisticsManager(&stats_manager);

    // Test that optimizer uses statistics for cost estimation
    const labels = [_][]const u8{"User"};
    const prop_val = graph_common.PropertyValue{ .String = "user@example.com" };

    const plan = optimizer.optimizeNodeScan(&labels, "u", "email", prop_val);

    // Verify index scan was chosen
    try testing.expect(plan.type == .index);

    // Verify statistics were used - cost should be influenced by the actual selectivity
    // With 3 unique entries out of 3 total, selectivity should be 1.0
    if (plan.explain_info) |explain_info| {
        if (explain_info.index_usage) |usage| {
            try testing.expect(usage.selectivity == 1.0); // Perfect selectivity from statistics

            std.debug.print("\nUsing statistics-based selectivity: {d:.3}\n", .{usage.selectivity});
            std.debug.print("Index chosen: {s}\n", .{usage.index_name});
        }
    }

    // Test that cost estimation includes statistics-based factors
    const expected_base_cost = 5.0; // Hash index base cost
    const stats = stats_manager.getIndexStatistics("User_email_hash_idx").?;
    const expected_cost_factor = stats.getEstimatedCostFactor();

    std.debug.print("Estimated cost factor from statistics: {d:.3}\n", .{expected_cost_factor});

    // Cost should be base_cost * selectivity * cost_factor
    const expected_cost = expected_base_cost * 1.0 * expected_cost_factor;
    try testing.expect(std.math.approxEqAbs(f64, plan.estimated_cost, expected_cost, 0.1));
}

test "index statistics collection workflow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stats_manager = IndexStatisticsManager.init(allocator);
    defer stats_manager.deinit();

    // Create statistics for different index types
    const email_props = [_][]const u8{"email"};
    const name_props = [_][]const u8{"name"};

    try stats_manager.createIndexStatistics("user_email_hash", .hash, "User", &email_props);
    try stats_manager.createIndexStatistics("user_name_btree", .btree, "User", &name_props);

    // Simulate different access patterns

    // Hash index: High selectivity, good hit ratio
    stats_manager.recordIndexEntry("user_email_hash", "unique1@example.com", true);
    stats_manager.recordIndexEntry("user_email_hash", "unique2@example.com", true);
    stats_manager.recordIndexEntry("user_email_hash", "unique3@example.com", true);
    stats_manager.recordIndexAccess("user_email_hash", 3, 3); // Perfect hit ratio

    // B-tree index: Lower selectivity, moderate hit ratio
    stats_manager.recordIndexEntry("user_name_btree", "John", true);
    stats_manager.recordIndexEntry("user_name_btree", "John", false); // Duplicate
    stats_manager.recordIndexEntry("user_name_btree", "Alice", true);
    stats_manager.recordIndexAccess("user_name_btree", 2, 4); // 50% hit ratio

    // Verify statistics calculations
    const hash_stats = stats_manager.getIndexStatistics("user_email_hash").?;
    const btree_stats = stats_manager.getIndexStatistics("user_name_btree").?;

    // Hash index should have better selectivity and cost factor
    try testing.expect(hash_stats.selectivity == 1.0); // 3 unique / 3 total
    try testing.expect(btree_stats.selectivity == 0.6666666666666666); // 2 unique / 3 total

    try testing.expect(hash_stats.hit_ratio == 1.0);
    try testing.expect(btree_stats.hit_ratio == 0.5);

    // Cost factors should reflect the performance differences
    const hash_cost_factor = hash_stats.getEstimatedCostFactor();
    const btree_cost_factor = btree_stats.getEstimatedCostFactor();

    try testing.expect(hash_cost_factor < btree_cost_factor); // Hash should be more efficient

    std.debug.print("\nHash index selectivity: {d:.3}, cost factor: {d:.3}\n", .{ hash_stats.selectivity, hash_cost_factor });
    std.debug.print("B-tree index selectivity: {d:.3}, cost factor: {d:.3}\n", .{ btree_stats.selectivity, btree_cost_factor });
}

test "index statistics usage analysis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stats_manager = IndexStatisticsManager.init(allocator);
    defer stats_manager.deinit();

    // Create indexes with different usage patterns
    const props = [_][]const u8{"test_prop"};

    // Unused index
    try stats_manager.createIndexStatistics("unused_index", .btree, "Test", &props);

    // Inefficient index
    try stats_manager.createIndexStatistics("inefficient_index", .hash, "Test", &props);
    for (0..10) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        stats_manager.recordIndexEntry("inefficient_index", key, i == 0); // Only first is unique
    }
    stats_manager.recordIndexAccess("inefficient_index", 1, 20); // Very low hit ratio

    // Excellent index
    try stats_manager.createIndexStatistics("excellent_index", .hash, "Test", &props);
    for (0..100) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        stats_manager.recordIndexEntry("excellent_index", key, true); // All unique
    }
    stats_manager.recordIndexAccess("excellent_index", 95, 100); // High hit ratio

    // Generate usage analysis
    const analysis = try stats_manager.analyzeIndexUsage(allocator);
    defer allocator.free(analysis);

    std.debug.print("\nIndex Usage Analysis:\n{s}\n", .{analysis});

    // Verify analysis contains expected recommendations
    try testing.expect(std.mem.indexOf(u8, analysis, "unused_index") != null);
    try testing.expect(std.mem.indexOf(u8, analysis, "Index is unused") != null);
    try testing.expect(std.mem.indexOf(u8, analysis, "Low hit ratio") != null);
    try testing.expect(std.mem.indexOf(u8, analysis, "High selectivity") != null);
}
