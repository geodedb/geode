const std = @import("std");
const testing = std.testing;
const graph_common = @import("../src/types/graph_common.zig");
const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;

// Tests for composite index optimization
// CANARY: REQ=REQ-GQL-016; FEATURE="CompositeIndexOptimizer"; ASPECT=MultiPropertyOptimization; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_CompositeIndexOptimization; OWNER=engine; UPDATED=2025-10-03

// Enhanced mock index manager supporting composite indexes
const CompositeIndexManager = struct {
    property_indexes: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompositeIndexManager {
        return CompositeIndexManager{
            .property_indexes = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompositeIndexManager) void {
        self.property_indexes.deinit();
    }

    pub fn lookupPropertyIndex(self: *CompositeIndexManager, index_name: []const u8, search_key: []const u8) !?u64 {
        _ = search_key;
        if (self.property_indexes.contains(index_name)) {
            return 1; // Mock node ID
        }
        return null;
    }

    // Helper to add single-property indexes
    pub fn addIndex(self: *CompositeIndexManager, label: []const u8, property: []const u8, index_type: graph_common.IndexType) !void {
        var index_name_buf: [256]u8 = undefined;
        const index_name = try std.fmt.bufPrint(&index_name_buf, "{s}_{s}_{s}_idx", .{ label, property, @tagName(index_type) });
        try self.property_indexes.put(try self.allocator.dupe(u8, index_name), {});
    }

    // Helper to add composite indexes
    pub fn addCompositeIndex(self: *CompositeIndexManager, label: []const u8, properties: []const []const u8) !void {
        var composite_name_buf: [512]u8 = undefined;
        var name_len: usize = 0;
        
        // Build: label_prop1_prop2_..._composite_idx
        name_len += (std.fmt.bufPrint(composite_name_buf[name_len..], "{s}", .{label}) catch return).len;
        for (properties) |prop| {
            name_len += (std.fmt.bufPrint(composite_name_buf[name_len..], "_{s}", .{prop}) catch return).len;
        }
        name_len += (std.fmt.bufPrint(composite_name_buf[name_len..], "_composite_idx", .{}) catch return).len;
        
        const composite_name = composite_name_buf[0..name_len];
        try self.property_indexes.put(try self.allocator.dupe(u8, composite_name), {});
    }
};

test "TestCANARY_REQ_GQL_016_CompositeIndexOptimization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = CompositeIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add individual property indexes
    try index_manager.addIndex("Person", "name", .btree);
    try index_manager.addIndex("Person", "age", .btree);

    // Add composite index covering both properties
    const properties = [_][]const u8{ "name", "age" };
    try index_manager.addCompositeIndex("Person", &properties);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_keys = [_][]const u8{ "name", "age" };
    const prop_vals = [_]graph_common.PropertyValue{ 
        .{ .String = "Alice" }, 
        .{ .Int = 30 } 
    };

    // Test that composite index is selected for multi-property queries
    const plan = optimizer.optimizeNodeScanWithFilters(&labels, &prop_keys, &prop_vals);

    try testing.expect(plan.type == .index);
    
    if (plan.type == .index) {
        try testing.expect(plan.type.index.is_composite);
        try testing.expect(plan.type.index.properties.len == 2);
        
        // Composite index should have very high selectivity (product of individual selectivities)
        // name: 0.1, age: 0.02 -> composite: 0.1 * 0.02 = 0.002
        try testing.expect(plan.type.index.selectivity == 0.002);
        
        // Cost should be lower than sequential scan
        try testing.expect(plan.estimated_cost < 100.0);
        
        std.debug.print("\nComposite index optimization:\n");
        std.debug.print("  Index name: {s}\n", .{plan.type.index.name});
        std.debug.print("  Properties: {any}\n", .{plan.type.index.properties});
        std.debug.print("  Selectivity: {d:.4}\n", .{plan.type.index.selectivity});
        std.debug.print("  Estimated cost: {d:.2}\n", .{plan.estimated_cost});
        std.debug.print("  Estimated rows: {d}\n", .{plan.estimated_rows});
    }
}

test "CompositeIndexOptimizer: single vs composite comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = CompositeIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add single-property indexes
    try index_manager.addIndex("User", "email", .hash);
    try index_manager.addIndex("User", "status", .btree);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"User"};

    // Test single property optimization
    const single_plan = optimizer.optimizeNodeScan(&labels, "u", "email", .{ .String = "user@example.com" });

    // Test what happens when no composite index exists for multi-property query
    const prop_keys = [_][]const u8{ "email", "status" };
    const prop_vals = [_]graph_common.PropertyValue{ 
        .{ .String = "user@example.com" }, 
        .{ .String = "active" } 
    };
    const multi_plan_no_composite = optimizer.optimizeNodeScanWithFilters(&labels, &prop_keys, &prop_vals);

    try testing.expect(single_plan.type == .index);
    try testing.expect(multi_plan_no_composite.type == .sequential); // No composite index available

    std.debug.print("\nSingle vs multi-property without composite:\n");
    std.debug.print("  Single property cost: {d:.2}\n", .{single_plan.estimated_cost});
    std.debug.print("  Multi-property cost (no composite): {d:.2}\n", .{multi_plan_no_composite.estimated_cost});
}

test "CompositeIndexOptimizer: three-property composite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = CompositeIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add three-property composite index
    const properties = [_][]const u8{ "country", "state", "city" };
    try index_manager.addCompositeIndex("Address", &properties);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Address"};
    const prop_keys = [_][]const u8{ "country", "state", "city" };
    const prop_vals = [_]graph_common.PropertyValue{ 
        .{ .String = "USA" }, 
        .{ .String = "CA" },
        .{ .String = "San Francisco" }
    };

    const plan = optimizer.optimizeNodeScanWithFilters(&labels, &prop_keys, &prop_vals);

    try testing.expect(plan.type == .index);
    
    if (plan.type == .index) {
        try testing.expect(plan.type.index.is_composite);
        try testing.expect(plan.type.index.properties.len == 3);
        
        // Three-property composite should have extremely high selectivity
        // 0.1 * 0.1 * 0.1 = 0.001
        try testing.expect(plan.type.index.selectivity == 0.001);
        
        // Base cost should account for three properties: 8.0 + (3 * 2.0) = 14.0
        const expected_base_cost = 14.0;
        const expected_total_cost = expected_base_cost * 0.001;
        try testing.expect(std.math.approxEqAbs(f64, plan.estimated_cost, expected_total_cost, 0.001));
        
        std.debug.print("\nThree-property composite index:\n");
        std.debug.print("  Properties: {any}\n", .{plan.type.index.properties});
        std.debug.print("  Selectivity: {d:.4}\n", .{plan.type.index.selectivity});
        std.debug.print("  Estimated cost: {d:.4}\n", .{plan.estimated_cost});
        std.debug.print("  Estimated rows: {d}\n", .{plan.estimated_rows});
    }
}

test "CompositeIndexOptimizer: cost scaling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = CompositeIndexManager.init(allocator);
    defer index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    // Test cost scaling for different numbers of properties
    const costs = [_]f64{
        optimizer.estimateCompositeIndexBaseCost(1),
        optimizer.estimateCompositeIndexBaseCost(2),
        optimizer.estimateCompositeIndexBaseCost(3),
        optimizer.estimateCompositeIndexBaseCost(4),
        optimizer.estimateCompositeIndexBaseCost(5),
    };

    std.debug.print("\nComposite index base cost scaling:\n");
    for (costs, 1..) |cost, prop_count| {
        std.debug.print("  {d} properties: {d:.2}\n", .{ prop_count, cost });
    }

    // Verify cost increases with property count
    try testing.expect(costs[1] > costs[0]); // 2 > 1
    try testing.expect(costs[2] > costs[1]); // 3 > 2
    try testing.expect(costs[3] > costs[2]); // 4 > 3
    try testing.expect(costs[4] > costs[3]); // 5 > 4

    // But should still be much better than sequential scan (100.0)
    for (costs) |cost| {
        try testing.expect(cost < 100.0);
    }
}

test "CompositeIndexOptimizer: selectivity calculation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = CompositeIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add composite indexes with different property combinations
    try index_manager.addCompositeIndex("Product", &[_][]const u8{ "category", "brand" });
    try index_manager.addCompositeIndex("Product", &[_][]const u8{ "id", "sku" });

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Product"};

    // Test selectivity for category+brand (both have default 0.1 selectivity)
    const cat_brand_keys = [_][]const u8{ "category", "brand" };
    const cat_brand_vals = [_]graph_common.PropertyValue{ 
        .{ .String = "Electronics" }, 
        .{ .String = "Apple" } 
    };
    const cat_brand_plan = optimizer.optimizeNodeScanWithFilters(&labels, &cat_brand_keys, &cat_brand_vals);

    // Test selectivity for id+sku (id has 0.001, sku defaults to 0.1)
    const id_sku_keys = [_][]const u8{ "id", "sku" };
    const id_sku_vals = [_]graph_common.PropertyValue{ 
        .{ .String = "PROD123" }, 
        .{ .String = "SKU456" } 
    };
    const id_sku_plan = optimizer.optimizeNodeScanWithFilters(&labels, &id_sku_keys, &id_sku_vals);

    try testing.expect(cat_brand_plan.type == .index);
    try testing.expect(id_sku_plan.type == .index);

    if (cat_brand_plan.type == .index and id_sku_plan.type == .index) {
        // category+brand: 0.1 * 0.1 = 0.01
        try testing.expect(cat_brand_plan.type.index.selectivity == 0.01);
        
        // id+sku: 0.001 * 0.1 = 0.0001
        try testing.expect(id_sku_plan.type.index.selectivity == 0.0001);
        
        // id+sku should be more selective and thus cheaper
        try testing.expect(id_sku_plan.estimated_cost < cat_brand_plan.estimated_cost);
        
        std.debug.print("\nSelectivity comparison:\n");
        std.debug.print("  Category+Brand selectivity: {d:.4}, cost: {d:.4}\n", 
            .{ cat_brand_plan.type.index.selectivity, cat_brand_plan.estimated_cost });
        std.debug.print("  ID+SKU selectivity: {d:.4}, cost: {d:.4}\n", 
            .{ id_sku_plan.type.index.selectivity, id_sku_plan.estimated_cost });
    }
}

test "CompositeIndexOptimizer: edge cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = CompositeIndexManager.init(allocator);
    defer index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Test"};

    // Test with empty properties
    const empty_plan = optimizer.optimizeNodeScanWithFilters(&labels, &.{}, &.{});
    try testing.expect(empty_plan.type == .sequential);

    // Test with mismatched property and value counts
    const prop_keys = [_][]const u8{ "prop1", "prop2" };
    const prop_vals = [_]graph_common.PropertyValue{ .{ .String = "value1" } }; // Only one value
    const mismatch_plan = optimizer.optimizeNodeScanWithFilters(&labels, &prop_keys, &prop_vals);
    try testing.expect(mismatch_plan.type == .sequential);

    // Test with no available indexes
    const no_index_keys = [_][]const u8{ "nonexistent1", "nonexistent2" };
    const no_index_vals = [_]graph_common.PropertyValue{ 
        .{ .String = "val1" }, 
        .{ .String = "val2" } 
    };
    const no_index_plan = optimizer.optimizeNodeScanWithFilters(&labels, &no_index_keys, &no_index_vals);
    try testing.expect(no_index_plan.type == .sequential);
}