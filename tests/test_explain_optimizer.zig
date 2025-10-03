const std = @import("std");
const testing = std.testing;
const graph_common = @import("../src/types/graph_common.zig");
const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;
const formatExplainOutput = @import("../src/server/index_optimizer.zig").formatExplainOutput;

// Tests for EXPLAIN functionality in IndexOptimizer
// CANARY: REQ=REQ-GQL-016; FEATURE="ExplainOptimizer"; ASPECT=QueryPlanVisualization; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_ExplainQueryPlan; OWNER=engine; UPDATED=2025-10-03

// Mock index manager for EXPLAIN tests
const ExplainIndexManager = struct {
    property_indexes: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExplainIndexManager {
        return ExplainIndexManager{
            .property_indexes = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ExplainIndexManager) void {
        self.property_indexes.deinit();
    }

    pub fn lookupPropertyIndex(self: *ExplainIndexManager, index_name: []const u8, search_key: []const u8) !?u64 {
        _ = search_key;
        if (self.property_indexes.contains(index_name)) {
            return 1;
        }
        return null;
    }

    pub fn addIndex(self: *ExplainIndexManager, label: []const u8, property: []const u8, index_type: graph_common.IndexType) !void {
        var index_name_buf: [256]u8 = undefined;
        const index_name = try std.fmt.bufPrint(&index_name_buf, "{s}_{s}_{s}_idx", .{ label, property, @tagName(index_type) });
        try self.property_indexes.put(try self.allocator.dupe(u8, index_name), {});
    }

    pub fn addCompositeIndex(self: *ExplainIndexManager, label: []const u8, properties: []const []const u8) !void {
        var composite_name_buf: [512]u8 = undefined;
        var name_len: usize = 0;
        
        name_len += (std.fmt.bufPrint(composite_name_buf[name_len..], "{s}", .{label}) catch return).len;
        for (properties) |prop| {
            name_len += (std.fmt.bufPrint(composite_name_buf[name_len..], "_{s}", .{prop}) catch return).len;
        }
        name_len += (std.fmt.bufPrint(composite_name_buf[name_len..], "_composite_idx", .{}) catch return).len;
        
        const composite_name = composite_name_buf[0..name_len];
        try self.property_indexes.put(try self.allocator.dupe(u8, composite_name), {});
    }
};

test "TestCANARY_REQ_GQL_016_ExplainQueryPlan" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = ExplainIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add a hash index for fast lookups
    try index_manager.addIndex("User", "email", .hash);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"User"};
    const prop_val = graph_common.PropertyValue{ .String = "user@example.com" };

    // Test index scan EXPLAIN
    const plan = optimizer.optimizeNodeScan(&labels, "u", "email", prop_val);

    try testing.expect(plan.type == .index);
    try testing.expect(plan.explain_info != null);

    if (plan.explain_info) |explain_info| {
        // Verify basic explain structure
        try testing.expect(std.mem.eql(u8, explain_info.operation, "Index Scan"));
        try testing.expect(std.mem.startsWith(u8, explain_info.details, "Using index on property"));
        try testing.expect(explain_info.cost_breakdown.len == 2); // Index Lookup + Result Processing
        try testing.expect(explain_info.index_usage != null);

        // Verify index usage info
        if (explain_info.index_usage) |usage| {
            try testing.expect(std.mem.startsWith(u8, usage.index_name, "User_email_hash_idx"));
            try testing.expect(std.mem.eql(u8, usage.index_type, "hash"));
            try testing.expect(usage.properties.len == 1);
            try testing.expect(std.mem.eql(u8, usage.properties[0], "email"));
            try testing.expect(usage.selectivity == 0.001); // ID-like selectivity for email
        }

        // Test formatted output
        const formatted = try formatExplainOutput(allocator, explain_info);
        defer allocator.free(formatted);

        std.debug.print("\nEXPLAIN output for hash index scan:\n{s}\n", .{formatted});

        // Verify formatted output contains key information
        try testing.expect(std.mem.indexOf(u8, formatted, "Index Scan") != null);
        try testing.expect(std.mem.indexOf(u8, formatted, "hash") != null);
        try testing.expect(std.mem.indexOf(u8, formatted, "0.001") != null); // Selectivity
    }
}

test "EXPLAIN: sequential scan output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = ExplainIndexManager.init(allocator);
    defer index_manager.deinit();

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_val = graph_common.PropertyValue{ .String = "Alice" };

    // Test sequential scan EXPLAIN (no indexes available)
    const plan = optimizer.optimizeNodeScan(&labels, "p", "name", prop_val);

    try testing.expect(plan.type == .sequential);
    try testing.expect(plan.explain_info != null);

    if (plan.explain_info) |explain_info| {
        // Verify sequential scan explain structure
        try testing.expect(std.mem.eql(u8, explain_info.operation, "Sequential Scan"));
        try testing.expect(std.mem.indexOf(u8, explain_info.details, "No indexes available") != null);
        try testing.expect(explain_info.cost_breakdown.len == 1); // Just Node Scan
        try testing.expect(explain_info.index_usage == null); // No index used

        // Verify cost breakdown
        try testing.expect(std.mem.eql(u8, explain_info.cost_breakdown[0].component, "Node Scan"));
        try testing.expect(explain_info.cost_breakdown[0].cost == 100.0); // Sequential scan cost

        const formatted = try formatExplainOutput(allocator, explain_info);
        defer allocator.free(formatted);

        std.debug.print("\nEXPLAIN output for sequential scan:\n{s}\n", .{formatted});

        // Verify formatted output suggests creating indexes
        try testing.expect(std.mem.indexOf(u8, formatted, "consider creating indexes") != null);
    }
}

test "EXPLAIN: composite index scan" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = ExplainIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add composite index
    const properties = [_][]const u8{ "first_name", "last_name" };
    try index_manager.addCompositeIndex("Person", &properties);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Person"};
    const prop_keys = [_][]const u8{ "first_name", "last_name" };
    const prop_vals = [_]graph_common.PropertyValue{ 
        .{ .String = "John" }, 
        .{ .String = "Doe" } 
    };

    // Test composite index scan EXPLAIN
    const plan = optimizer.optimizeNodeScanWithFilters(&labels, &prop_keys, &prop_vals);

    try testing.expect(plan.type == .index);
    try testing.expect(plan.explain_info != null);

    if (plan.explain_info) |explain_info| {
        // Verify composite index explain structure
        try testing.expect(std.mem.eql(u8, explain_info.operation, "Composite Index Scan"));
        try testing.expect(std.mem.indexOf(u8, explain_info.details, "composite index on properties") != null);
        try testing.expect(explain_info.index_usage != null);

        if (explain_info.index_usage) |usage| {
            try testing.expect(std.mem.endsWith(u8, usage.index_name, "_composite_idx"));
            try testing.expect(usage.properties.len == 2);
            try testing.expect(usage.selectivity == 0.01); // 0.1 * 0.1 for two properties
            try testing.expect(std.mem.indexOf(u8, usage.reason, "across 2 properties") != null);
        }

        const formatted = try formatExplainOutput(allocator, explain_info);
        defer allocator.free(formatted);

        std.debug.print("\nEXPLAIN output for composite index scan:\n{s}\n", .{formatted});

        // Verify composite-specific information
        try testing.expect(std.mem.indexOf(u8, formatted, "Composite Index Scan") != null);
        try testing.expect(std.mem.indexOf(u8, formatted, "across 2 properties") != null);
    }
}

test "EXPLAIN: cost breakdown accuracy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = ExplainIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add B-tree index
    try index_manager.addIndex("Product", "price", .btree);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"Product"};
    const prop_val = graph_common.PropertyValue{ .Int = 100 };

    const plan = optimizer.optimizeNodeScan(&labels, "p", "price", prop_val);

    try testing.expect(plan.type == .index);
    try testing.expect(plan.explain_info != null);

    if (plan.explain_info) |explain_info| {
        try testing.expect(explain_info.cost_breakdown.len == 2);
        
        var total_cost: f64 = 0;
        for (explain_info.cost_breakdown) |component| {
            total_cost += component.cost;
            
            // Verify cost components are reasonable
            try testing.expect(component.cost >= 0);
            if (std.mem.eql(u8, component.component, "Index Lookup")) {
                try testing.expect(component.cost == 10.0); // B-tree base cost
            }
        }
        
        // Total should match plan cost
        try testing.expect(std.math.approxEqAbs(f64, total_cost, plan.estimated_cost, 0.001));

        const formatted = try formatExplainOutput(allocator, explain_info);
        defer allocator.free(formatted);

        std.debug.print("\nEXPLAIN output with cost breakdown:\n{s}\n", .{formatted});

        // Verify total cost is displayed
        try testing.expect(std.mem.indexOf(u8, formatted, "Total Cost:") != null);
    }
}

test "EXPLAIN: index selection reasoning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = ExplainIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add multiple index types for same property
    try index_manager.addIndex("User", "status", .btree);
    try index_manager.addIndex("User", "status", .hash);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"User"};
    const prop_val = graph_common.PropertyValue{ .String = "active" };

    const plan = optimizer.optimizeNodeScan(&labels, "u", "status", prop_val);

    try testing.expect(plan.type == .index);
    try testing.expect(plan.explain_info != null);

    if (plan.explain_info) |explain_info| {
        if (explain_info.index_usage) |usage| {
            // Hash should be chosen for exact matches
            try testing.expect(std.mem.eql(u8, usage.index_type, "hash"));
            
            // Verify reasoning explains why hash was chosen
            try testing.expect(std.mem.indexOf(u8, usage.reason, "hash index type") != null);
            try testing.expect(std.mem.indexOf(u8, usage.reason, "selectivity") != null);
            
            std.debug.print("\nIndex selection reasoning: {s}\n", .{usage.reason});
        }

        const formatted = try formatExplainOutput(allocator, explain_info);
        defer allocator.free(formatted);

        // Verify reasoning is included in formatted output
        try testing.expect(std.mem.indexOf(u8, formatted, "Reason:") != null);
    }
}

test "EXPLAIN: no suitable index found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index_manager = ExplainIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add an index that won't be suitable (different property)
    try index_manager.addIndex("User", "email", .hash);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const labels = [_][]const u8{"User"};
    const prop_val = graph_common.PropertyValue{ .String = "John" };

    // Query on different property than what's indexed
    const plan = optimizer.optimizeNodeScan(&labels, "u", "name", prop_val);

    try testing.expect(plan.type == .sequential);
    try testing.expect(plan.explain_info != null);

    if (plan.explain_info) |explain_info| {
        // Should mention that indexes were considered but not suitable
        try testing.expect(std.mem.indexOf(u8, explain_info.details, "Considered") != null or
                          std.mem.indexOf(u8, explain_info.details, "No indexes available") != null);

        const formatted = try formatExplainOutput(allocator, explain_info);
        defer allocator.free(formatted);

        std.debug.print("\nEXPLAIN output when no suitable index:\n{s}\n", .{formatted});
    }
}