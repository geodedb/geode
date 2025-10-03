const std = @import("std");
const testing = std.testing;
const graph_common = @import("../src/types/graph_common.zig");
const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;

// Tests for multi-index-type IndexOptimizer enhancements
// CANARY: REQ=REQ-GQL-016; FEATURE="MultiIndexOptimizer"; ASPECT=IndexTypeSelection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_MultiIndexTypeSelection; OWNER=engine; UPDATED=2025-10-03

// Enhanced mock index manager supporting multiple index types
const MultiIndexManager = struct {
    property_indexes: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MultiIndexManager {
        return MultiIndexManager{
            .property_indexes = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MultiIndexManager) void {
        self.property_indexes.deinit();
    }

    pub fn lookupPropertyIndex(self: *MultiIndexManager, index_name: []const u8, search_key: []const u8) !?u64 {
        _ = search_key;
        if (self.property_indexes.contains(index_name)) {
            return 1; // Mock node ID
        }
        return null;
    }

    // Helper to add different index types
    pub fn addIndex(self: *MultiIndexManager, label: []const u8, property: []const u8, index_type: graph_common.IndexType) !void {
        var index_name_buf: [256]u8 = undefined;
        const index_name = try std.fmt.bufPrint(&index_name_buf, "{s}_{s}_{s}_idx", .{ label, property, @tagName(index_type) });
        try self.property_indexes.put(try self.allocator.dupe(u8, index_name), {});
    }
};

test "TestCANARY_REQ_GQL_016_MultiIndexTypeSelection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = MultiIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add different index types for the same property
    try index_manager.addIndex("Person", "name", .btree);
    try index_manager.addIndex("Person", "name", .hash);
    try index_manager.addIndex("Person", "location", .spatial);
    try index_manager.addIndex("Person", "description", .fulltext);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    // Test that optimizer selects the best index type for the query
    const plan = optimizer.optimizeNodeScan(&labels, "n", "name", prop_val);

    try testing.expect(plan.type == .index);
    
    // Hash index should be preferred for exact matches (lower cost)
    if (plan.type == .index) {
        try testing.expect(plan.type.index.index_type == .hash);
        try testing.expect(plan.estimated_cost < 10.0); // Hash has lower base cost
    }
}

test "IndexOptimizer: spatial index selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = MultiIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add spatial index for location property
    try index_manager.addIndex("Place", "location", .spatial);
    try index_manager.addIndex("Place", "location", .btree); // Also have a btree

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Place"};
    const prop_val = graph_common.PropertyValue{ .String = "POINT(1.0 2.0)" };

    const plan = optimizer.optimizeNodeScan(&labels, "n", "location", prop_val);

    try testing.expect(plan.type == .index);
    
    // Should prefer spatial index for location data
    if (plan.type == .index) {
        // Check that we have better selectivity for spatial data
        try testing.expect(plan.type.index.selectivity <= 0.05); // Good selectivity for spatial
    }
}

test "IndexOptimizer: fulltext index selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = MultiIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add fulltext index for description property
    try index_manager.addIndex("Document", "description", .fulltext);
    try index_manager.addIndex("Document", "title", .fulltext);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Document"};
    const prop_val = graph_common.PropertyValue{ .String = "search terms" };

    const plan_desc = optimizer.optimizeNodeScan(&labels, "n", "description", prop_val);
    const plan_title = optimizer.optimizeNodeScan(&labels, "n", "title", prop_val);

    // Both should use fulltext indexes
    try testing.expect(plan_desc.type == .index);
    try testing.expect(plan_title.type == .index);

    if (plan_desc.type == .index and plan_title.type == .index) {
        try testing.expect(plan_desc.type.index.index_type == .fulltext);
        try testing.expect(plan_title.type.index.index_type == .fulltext);
        
        // Title should have better selectivity than description
        try testing.expect(plan_title.type.index.selectivity < plan_desc.type.index.selectivity);
    }
}

test "IndexOptimizer: index type cost comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = MultiIndexManager.init(allocator);
    defer index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    // Test cost estimation for different index types
    const btree_cost = optimizer.estimateIndexTypeCost(.btree, 0.1);
    const hash_cost = optimizer.estimateIndexTypeCost(.hash, 0.1);
    const spatial_cost = optimizer.estimateIndexTypeCost(.spatial, 0.1);
    const fulltext_cost = optimizer.estimateIndexTypeCost(.fulltext, 0.1);

    std.debug.print("\nIndex type cost comparison (selectivity=0.1):\n");
    std.debug.print("  B-tree: {d:.2}\n", .{btree_cost});
    std.debug.print("  Hash: {d:.2}\n", .{hash_cost});
    std.debug.print("  Spatial: {d:.2}\n", .{spatial_cost});
    std.debug.print("  Fulltext: {d:.2}\n", .{fulltext_cost});

    // Hash should be cheapest for simple equality
    try testing.expect(hash_cost < btree_cost);
    try testing.expect(hash_cost < spatial_cost);
    try testing.expect(hash_cost < fulltext_cost);

    // Spatial should be more expensive than B-tree
    try testing.expect(spatial_cost > btree_cost);

    // Fulltext should be most expensive
    try testing.expect(fulltext_cost > btree_cost);
    try testing.expect(fulltext_cost > spatial_cost);
}

test "IndexOptimizer: selectivity estimation by property type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = MultiIndexManager.init(allocator);
    defer index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    // Test selectivity estimation for different properties and index types
    const id_btree = optimizer.estimateIndexSelectivity(.btree, "id");
    const id_hash = optimizer.estimateIndexSelectivity(.hash, "id");
    const name_btree = optimizer.estimateIndexSelectivity(.btree, "name");
    const location_spatial = optimizer.estimateIndexSelectivity(.spatial, "location");
    const description_fulltext = optimizer.estimateIndexSelectivity(.fulltext, "description");

    std.debug.print("\nSelectivity estimation by property and index type:\n");
    std.debug.print("  ID (B-tree): {d:.3}\n", .{id_btree});
    std.debug.print("  ID (Hash): {d:.3}\n", .{id_hash});
    std.debug.print("  Name (B-tree): {d:.3}\n", .{name_btree});
    std.debug.print("  Location (Spatial): {d:.3}\n", .{location_spatial});
    std.debug.print("  Description (Fulltext): {d:.3}\n", .{description_fulltext});

    // ID should have excellent selectivity
    try testing.expect(id_btree == 0.001);
    try testing.expect(id_hash == 0.001);

    // Name should have moderate selectivity
    try testing.expect(name_btree == 0.1);

    // Location with spatial index should have good selectivity
    try testing.expect(location_spatial == 0.05);

    // Description with fulltext should have reasonable selectivity
    try testing.expect(description_fulltext == 0.15);
}

test "IndexOptimizer: no suitable index fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = MultiIndexManager.init(allocator);
    defer index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    // No indexes available - should fall back to sequential scan
    const plan = optimizer.optimizeNodeScan(&labels, "n", "unknown_property", prop_val);

    try testing.expect(plan.type == .sequential);
    try testing.expect(plan.estimated_cost == 100.0); // Sequential scan cost
}

test "IndexOptimizer: multiple competing indexes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = MultiIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add multiple indexes for the same property
    try index_manager.addIndex("User", "status", .btree);
    try index_manager.addIndex("User", "status", .hash);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"User"};
    const prop_val = graph_common.PropertyValue{ .String = "active" };

    const plan = optimizer.optimizeNodeScan(&labels, "n", "status", prop_val);

    try testing.expect(plan.type == .index);
    
    // Should prefer hash index for exact match on enumerated values
    if (plan.type == .index) {
        try testing.expect(plan.type.index.index_type == .hash);
        // Hash should have better cost for exact matches
        try testing.expect(plan.estimated_cost < 2.0); // Hash base cost (5.0) * status selectivity (0.2) = 1.0
    }
}