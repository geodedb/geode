const std = @import("std");
const lfu_mod = @import("../src/graph/containers/lfu.zig");

pub const LfuU32U32 = lfu_mod.LfuU32U32;

// Extended CANARY test focusing on frequency increments, tie-break eviction, and capacity edge cases.
// Scenarios:
// 1. Basic put/get frequency escalation.
// 2. Eviction chooses lowest frequency; tie broken by LRU within that frequency bucket.
// 3. Capacity 0 causes puts to be ignored.
// 4. Capacity 1 retains most frequently accessed key after competing accesses.
// 5. Removal adjusts structure without panic.

test "TestCANARY_REQ_GQL_068_LFU extended scenarios" {
    var cache = LfuU32U32.init(std.testing.allocator, 3);
    defer cache.deinit();

    // Insert three
    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);
    // freq: all 1; order of insertion for LRU inside freq bucket: 3(LRU),2,1(MRU) because we insert at front.
    // Access key 1 twice, key 2 once (freq: 1->3,2->2,3->1)
    _ = cache.get(1);
    _ = cache.get(1);
    _ = cache.get(2);

    // Add new key triggers eviction of key 3 (freq=1 lowest)
    try cache.put(4, 40);
    try std.testing.expect(cache.get(3) == null);

    // Now increment key 4 to create another freq-2 element.
    _ = cache.get(4);
    // state frequencies: 1->3,2->2,4->2

    // Insert new key 5 capacity overflow; eviction target is one of freq-2 keys with oldest recency among freq-2 (key 2 vs 4).
    // Key 2 was promoted before key 4 got to freq-2 (timeline: 2->freq2 earlier than 4->freq2), and tie-break uses LRU within bucket => evict key 2.
    try cache.put(5, 50);
    try std.testing.expect(cache.get(2) == null);
    try std.testing.expect(cache.get(4) != null);

    // Removal
    const removed = cache.remove(4);
    try std.testing.expect(removed);
    try std.testing.expect(cache.get(4) == null);
}

test "TestCANARY_REQ_GQL_068_LFU capacity zero" {
    var cache = LfuU32U32.init(std.testing.allocator, 0);
    defer cache.deinit();
    try cache.put(1, 10); // ignored
    try std.testing.expect(cache.size() == 0);
    try std.testing.expect(cache.get(1) == null);
}

test "TestCANARY_REQ_GQL_068_LFU capacity one frequency retention" {
    var cache = LfuU32U32.init(std.testing.allocator, 1);
    defer cache.deinit();
    try cache.put(1, 10);
    _ = cache.get(1); // freq becomes 2
    try cache.put(2, 20); // should evict key 1? No, first we insert 2 then eviction triggers since count>capacity; lowest freq among {1(freq2),2(freq1)} is key 2 so new insert is evicted.
    try std.testing.expect(cache.get(1) != null);
    try std.testing.expect(cache.get(2) == null);
}
