const std = @import("std");
const path_cache = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheLookup; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheLookup; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_021_PathCacheLookup" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try path_cache.PathCache.init(gpa.allocator(), 4);
    defer cache.deinit();

    // Insert some entries.
    cache.put("k1", "v1");
    cache.put("k2", "v2");
    cache.put("k3", "v3");

    try std.testing.expectEqualStrings("v1", cache.get("k1").?);
    try std.testing.expectEqualStrings("v2", cache.get("k2").?);
    try std.testing.expect(cache.get("nope") == null);

    // Force eviction by exceeding capacity in FIFO order.
    cache.put("k4", "v4");
    cache.put("k5", "v5"); // should evict k1
    try std.testing.expect(cache.get("k1") == null);
    try std.testing.expectEqualStrings("v2", cache.get("k2").?);

    const st = cache.statsSnapshot();
    // Expect at least 3 hits (k1,k2,k2 again) and >=1 eviction.
    try std.testing.expect(st.hits >= 3);
    try std.testing.expect(st.evictions >= 1);
}
