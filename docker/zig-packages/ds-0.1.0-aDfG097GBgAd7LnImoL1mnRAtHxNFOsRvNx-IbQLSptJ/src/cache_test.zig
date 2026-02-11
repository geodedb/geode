// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const cache = @import("cache.zig");

test "LRU - basic operations" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 3);
    defer lru.deinit();

    try lru.put(1, "one");
    try lru.put(2, "two");
    try lru.put(3, "three");

    try testing.expectEqualStrings("one", lru.get(1).?);
    try testing.expectEqualStrings("two", lru.get(2).?);
    try testing.expectEqualStrings("three", lru.get(3).?);
}

test "LRU - eviction order" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 2);
    defer lru.deinit();

    try lru.put(1, "one");
    try lru.put(2, "two");

    // Touch 1 so 2 becomes LRU
    _ = lru.get(1);

    // Insert 3, should evict 2
    try lru.put(3, "three");

    try testing.expect(lru.get(2) == null);
    try testing.expect(lru.get(1) != null);
    try testing.expect(lru.get(3) != null);
}

test "LRU - update existing key" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 2);
    defer lru.deinit();

    try lru.put(1, "one");
    try lru.put(2, "two");

    // Update key 1
    try lru.put(1, "ONE");

    try testing.expectEqualStrings("ONE", lru.get(1).?);
    try testing.expectEqual(@as(usize, 2), lru.len());
}

test "LRU - capacity of 1" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 1);
    defer lru.deinit();

    try lru.put(1, "one");
    try testing.expectEqualStrings("one", lru.get(1).?);

    try lru.put(2, "two");
    try testing.expect(lru.get(1) == null);
    try testing.expectEqualStrings("two", lru.get(2).?);
}

test "LRU - empty cache" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 10);
    defer lru.deinit();

    try testing.expect(lru.get(1) == null);
    try testing.expectEqual(@as(usize, 0), lru.len());
}

test "LRU - multiple accesses maintain order" {
    var lru = cache.LRU(i32, i32).init(testing.allocator, 3);
    defer lru.deinit();

    try lru.put(1, 10);
    try lru.put(2, 20);
    try lru.put(3, 30);

    // Access 1 and 2 multiple times
    _ = lru.get(1);
    _ = lru.get(2);
    _ = lru.get(1);

    // Add 4, should evict 3 (least recently used)
    try lru.put(4, 40);

    try testing.expect(lru.get(3) == null);
    try testing.expectEqual(@as(i32, 10), lru.get(1).?);
    try testing.expectEqual(@as(i32, 20), lru.get(2).?);
    try testing.expectEqual(@as(i32, 40), lru.get(4).?);
}

test "LFU - basic operations" {
    var lfu = cache.LFU(i32, []const u8).init(testing.allocator, 3);
    defer lfu.deinit();

    try lfu.put(1, "one");
    try lfu.put(2, "two");
    try lfu.put(3, "three");

    try testing.expectEqualStrings("one", (try lfu.get(1)).?);
    try testing.expectEqualStrings("two", (try lfu.get(2)).?);
    try testing.expectEqualStrings("three", (try lfu.get(3)).?);
}

test "LFU - eviction by frequency" {
    var lfu = cache.LFU(i32, []const u8).init(testing.allocator, 2);
    defer lfu.deinit();

    try lfu.put(1, "one");
    try lfu.put(2, "two");

    // Access 1 twice, so it has higher frequency
    _ = try lfu.get(1);
    _ = try lfu.get(1);

    // Insert 3, should evict 2 (lower frequency)
    try lfu.put(3, "three");

    try testing.expect((try lfu.get(2)) == null);
    try testing.expect((try lfu.get(1)) != null);
    try testing.expect((try lfu.get(3)) != null);
}

test "LFU - update existing key" {
    var lfu = cache.LFU(i32, []const u8).init(testing.allocator, 2);
    defer lfu.deinit();

    try lfu.put(1, "one");
    try lfu.put(2, "two");

    // Update key 1
    try lfu.put(1, "ONE");

    try testing.expectEqualStrings("ONE", (try lfu.get(1)).?);
    try testing.expectEqual(@as(usize, 2), lfu.len());
}

test "LFU - capacity of 1" {
    var lfu = cache.LFU(i32, []const u8).init(testing.allocator, 1);
    defer lfu.deinit();

    try lfu.put(1, "one");
    try testing.expectEqualStrings("one", (try lfu.get(1)).?);

    try lfu.put(2, "two");
    try testing.expect((try lfu.get(1)) == null);
    try testing.expectEqualStrings("two", (try lfu.get(2)).?);
}

test "LFU - empty cache" {
    var lfu = cache.LFU(i32, []const u8).init(testing.allocator, 10);
    defer lfu.deinit();

    try testing.expect((try lfu.get(1)) == null);
    try testing.expectEqual(@as(usize, 0), lfu.len());
}

test "LFU - frequency tracking" {
    var lfu = cache.LFU(i32, i32).init(testing.allocator, 3);
    defer lfu.deinit();

    try lfu.put(1, 10);
    try lfu.put(2, 20);
    try lfu.put(3, 30);

    // Access 1 three times, 2 twice
    _ = try lfu.get(1);
    _ = try lfu.get(1);
    _ = try lfu.get(1);
    _ = try lfu.get(2);
    _ = try lfu.get(2);

    // Add 4, should evict 3 (lowest frequency)
    try lfu.put(4, 40);

    try testing.expect((try lfu.get(3)) == null);
    try testing.expectEqual(@as(i32, 10), (try lfu.get(1)).?);
    try testing.expectEqual(@as(i32, 20), (try lfu.get(2)).?);
    try testing.expectEqual(@as(i32, 40), (try lfu.get(4)).?);
}

test "LFU - tie breaking by recency" {
    var lfu = cache.LFU(i32, i32).init(testing.allocator, 2);
    defer lfu.deinit();

    try lfu.put(1, 10);
    try lfu.put(2, 20);

    // Both have same frequency (1), so LRU within frequency
    // Key 1 was inserted first, so should be evicted first
    try lfu.put(3, 30);

    try testing.expect((try lfu.get(1)) == null);
    try testing.expectEqual(@as(i32, 20), (try lfu.get(2)).?);
    try testing.expectEqual(@as(i32, 30), (try lfu.get(3)).?);
}

test "BloomFilter - basic operations" {
    var bf = try cache.BloomFilter.init(testing.allocator, 128, 3);
    defer bf.deinit();

    try bf.add("alpha");
    try bf.add("beta");
    try bf.add("gamma");

    try testing.expect(try bf.test_("alpha"));
    try testing.expect(try bf.test_("beta"));
    try testing.expect(try bf.test_("gamma"));
}

test "BloomFilter - false negatives impossible" {
    var bf = try cache.BloomFilter.init(testing.allocator, 256, 4);
    defer bf.deinit();

    const items = [_][]const u8{ "apple", "banana", "cherry", "date" };
    for (items) |item| {
        try bf.add(item);
    }

    // All added items must be found (no false negatives)
    for (items) |item| {
        try testing.expect(try bf.test_(item));
    }
}

test "BloomFilter - different sizes" {
    var bf_small = try cache.BloomFilter.init(testing.allocator, 64, 2);
    defer bf_small.deinit();

    var bf_large = try cache.BloomFilter.init(testing.allocator, 1024, 5);
    defer bf_large.deinit();

    try bf_small.add("test");
    try bf_large.add("test");

    try testing.expect(try bf_small.test_("test"));
    try testing.expect(try bf_large.test_("test"));
}

test "BloomFilter - empty filter" {
    var bf = try cache.BloomFilter.init(testing.allocator, 128, 3);
    defer bf.deinit();

    // Should return false for any query on empty filter
    try testing.expect(!try bf.test_("anything"));
}

test "BloomFilter - multiple additions same item" {
    var bf = try cache.BloomFilter.init(testing.allocator, 128, 3);
    defer bf.deinit();

    try bf.add("duplicate");
    try bf.add("duplicate");
    try bf.add("duplicate");

    // Should still work correctly
    try testing.expect(try bf.test_("duplicate"));
}
