const std = @import("std");
const geode = @import("geode");
const LruU32U32 = geode.graph.containers.lru.LruU32U32;

// Extended correctness test: eviction order after access pattern & capacity zero behavior.

test "TestCANARY_REQ_GQL_068_LRU eviction_and_zero_capacity" {
    // Eviction ordering
    var cache = LruU32U32.init(std.testing.allocator, 2);
    defer cache.deinit();
    try cache.put(10, 100);
    try cache.put(11, 110);
    // Access key 10 to make it MRU
    _ = cache.get(10);
    try cache.put(12, 120); // should evict 11
    try std.testing.expect(cache.get(11) == null);
    try std.testing.expect((cache.get(10)).?.* == 100);
    try std.testing.expect((cache.get(12)).?.* == 120);

    // Capacity zero: should behave like always-empty cache
    var zero = LruU32U32.init(std.testing.allocator, 0);
    defer zero.deinit();
    try zero.put(1, 1); // ignored
    try std.testing.expect(zero.size() == 0);
    try std.testing.expect(zero.get(1) == null);
}
