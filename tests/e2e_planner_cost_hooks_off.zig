const std = @import("std");
const stats_registry = @import("../src/planner/stats_registry.zig");

test "planner cost hooks disabled by default" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clear environment variable to test default
    std.process.setEnvironVar("GEODE_STATS_REGISTRY", "") catch {};
    
    var registry = stats_registry.StatsRegistry.init(allocator);
    defer registry.deinit();
    
    // By default, stats registry should be disabled (rule-based planning)
    try std.testing.expect(registry.enabled == false);
    
    // Add some stats
    try registry.put(12345, 1000);
    try registry.put(67890, 2000);
    
    // Even with stats present, if disabled they shouldn't affect planning
    // The planner will use rule-based defaults
    const stat = registry.get(12345);
    try std.testing.expect(stat != null); // Stats are stored
    try std.testing.expect(stat.? == 1000);
    
    // But they won't be used in cost estimation due to enabled=false
    
    std.debug.print("COST_HOOKS_OFF_RULE_PLANS\n", .{});
}