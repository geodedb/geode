const std = @import("std");
const geode = @import("geode");
const cbo = geode.cbo;

// GAP-0867: explainEstimateJSON now derives per-scan-node row estimates from
// real StatsRegistry statistics for a parsed query (no canned skeleton).

test "explainEstimateJSON emits real per-node estimates from statistics" {
    const allocator = std.testing.allocator;

    var registry = cbo.StatsRegistry.init(allocator);
    defer registry.deinit();
    try registry.injectTableStats("Person", 250, 3, 0);

    var parsed = try geode.parseGql("MATCH (n:Person) RETURN n", allocator);
    defer parsed.deinit();
    const q = parsed.program.statements[0].Query;

    const json = try cbo.explainEstimateJSON(allocator, &registry, q);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"node_scan\",\"label\":\"Person\",\"estimated_rows\":250,\"estimate_source\":\"statistics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"estimated_total_rows\":250") != null);
}

test "explainEstimateJSON labels unknown labels as default_heuristic" {
    const allocator = std.testing.allocator;

    var registry = cbo.StatsRegistry.init(allocator);
    defer registry.deinit();

    var parsed = try geode.parseGql("MATCH (n:NoStatsLabel) RETURN n", allocator);
    defer parsed.deinit();
    const q = parsed.program.statements[0].Query;

    const json = try cbo.explainEstimateJSON(allocator, &registry, q);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"estimate_source\":\"default_heuristic\"") != null);
}
