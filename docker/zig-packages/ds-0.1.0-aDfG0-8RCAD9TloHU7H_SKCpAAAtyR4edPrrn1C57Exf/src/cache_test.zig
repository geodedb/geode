// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const cache = @import("cache.zig");

// =========================================================================
// LRU Tests
// =========================================================================

test "LRU - basic operations" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 3);
    defer lru.deinit();

    try lru.put(1, "one");
    try lru.put(2, "two");
    try lru.put(3, "three");

    try testing.expectEqualStrings("one", (lru.get(1)).?);
    try testing.expectEqualStrings("two", (lru.get(2)).?);
    try testing.expectEqualStrings("three", (lru.get(3)).?);
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

    try testing.expect((lru.get(2)) == null);
    try testing.expect((lru.get(1)) != null);
    try testing.expect((lru.get(3)) != null);
}

test "LRU - update existing key" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 2);
    defer lru.deinit();

    try lru.put(1, "one");
    try lru.put(2, "two");

    // Update key 1
    try lru.put(1, "ONE");

    try testing.expectEqualStrings("ONE", (lru.get(1)).?);
    try testing.expectEqual(@as(usize, 2), lru.len());
}

test "LRU - capacity of 1" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 1);
    defer lru.deinit();

    try lru.put(1, "one");
    try testing.expectEqualStrings("one", (lru.get(1)).?);

    try lru.put(2, "two");
    try testing.expect((lru.get(1)) == null);
    try testing.expectEqualStrings("two", (lru.get(2)).?);
}

test "LRU - empty cache" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 10);
    defer lru.deinit();

    try testing.expect((lru.get(1)) == null);
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

    try testing.expect((lru.get(3)) == null);
    try testing.expectEqual(@as(i32, 10), (lru.get(1)).?);
    try testing.expectEqual(@as(i32, 20), (lru.get(2)).?);
    try testing.expectEqual(@as(i32, 40), (lru.get(4)).?);
}

test "LRU - remove" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 3);
    defer lru.deinit();

    try lru.put(1, "one");
    try lru.put(2, "two");
    try lru.put(3, "three");

    try testing.expect(lru.remove(2));
    try testing.expect((lru.get(2)) == null);
    try testing.expectEqual(@as(usize, 2), lru.len());

    // Remaining entries still accessible
    try testing.expectEqualStrings("one", (lru.get(1)).?);
    try testing.expectEqualStrings("three", (lru.get(3)).?);

    // Removing non-existent key returns false
    try testing.expect(!lru.remove(99));
}

test "LRU - remove head" {
    var lru = cache.LRU(i32, i32).init(testing.allocator, 3);
    defer lru.deinit();

    try lru.put(1, 10);
    try lru.put(2, 20); // head is now 2

    try testing.expect(lru.remove(2));
    try testing.expectEqual(@as(usize, 1), lru.len());
    try testing.expectEqual(@as(i32, 10), (lru.get(1)).?);
}

test "LRU - remove tail" {
    var lru = cache.LRU(i32, i32).init(testing.allocator, 3);
    defer lru.deinit();

    try lru.put(1, 10); // tail
    try lru.put(2, 20);

    try testing.expect(lru.remove(1));
    try testing.expectEqual(@as(usize, 1), lru.len());
    try testing.expectEqual(@as(i32, 20), (lru.get(2)).?);
}

test "LRU - clear" {
    var lru = cache.LRU(i32, []const u8).init(testing.allocator, 3);
    defer lru.deinit();

    try lru.put(1, "one");
    try lru.put(2, "two");
    try lru.put(3, "three");

    lru.clear();
    try testing.expectEqual(@as(usize, 0), lru.len());
    try testing.expect((lru.get(1)) == null);
    try testing.expect((lru.get(2)) == null);
    try testing.expect((lru.get(3)) == null);

    // Can still use the cache after clearing
    try lru.put(4, "four");
    try testing.expectEqualStrings("four", (lru.get(4)).?);
    try testing.expectEqual(@as(usize, 1), lru.len());
}

// =========================================================================
// LFU Tests
// =========================================================================

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

test "LFU - remove" {
    var lfu = cache.LFU(i32, []const u8).init(testing.allocator, 3);
    defer lfu.deinit();

    try lfu.put(1, "one");
    try lfu.put(2, "two");
    try lfu.put(3, "three");

    try testing.expect(lfu.remove(2));
    try testing.expect((try lfu.get(2)) == null);
    try testing.expectEqual(@as(usize, 2), lfu.len());

    // Remaining entries still accessible
    try testing.expectEqualStrings("one", (try lfu.get(1)).?);
    try testing.expectEqualStrings("three", (try lfu.get(3)).?);

    // Removing non-existent key returns false
    try testing.expect(!lfu.remove(99));
}

test "LFU - clear" {
    var lfu = cache.LFU(i32, []const u8).init(testing.allocator, 3);
    defer lfu.deinit();

    try lfu.put(1, "one");
    try lfu.put(2, "two");
    try lfu.put(3, "three");

    // Bump frequencies
    _ = try lfu.get(1);
    _ = try lfu.get(2);

    lfu.clear();
    try testing.expectEqual(@as(usize, 0), lfu.len());
    try testing.expect((try lfu.get(1)) == null);
    try testing.expect((try lfu.get(2)) == null);

    // Can still use after clearing
    try lfu.put(4, "four");
    try testing.expectEqualStrings("four", (try lfu.get(4)).?);
    try testing.expectEqual(@as(usize, 1), lfu.len());
}

// =========================================================================
// BloomFilter Tests
// =========================================================================

test "BloomFilter - basic operations" {
    var bf = try cache.BloomFilter.init(testing.allocator, 1000, 0.01, 42);
    defer bf.deinit();

    bf.add("alpha");
    bf.add("beta");
    bf.add("gamma");

    try testing.expect(bf.mightContain("alpha"));
    try testing.expect(bf.mightContain("beta"));
    try testing.expect(bf.mightContain("gamma"));
}

test "BloomFilter - false negatives impossible" {
    var bf = try cache.BloomFilter.init(testing.allocator, 100, 0.01, 42);
    defer bf.deinit();

    const items = [_][]const u8{ "apple", "banana", "cherry", "date" };
    for (items) |item| {
        bf.add(item);
    }

    // All added items must be found (no false negatives)
    for (items) |item| {
        try testing.expect(bf.mightContain(item));
    }
}

test "BloomFilter - empty filter" {
    var bf = try cache.BloomFilter.init(testing.allocator, 100, 0.01, 42);
    defer bf.deinit();

    try testing.expect(!bf.mightContain("anything"));
}

test "BloomFilter - multiple additions same item" {
    var bf = try cache.BloomFilter.init(testing.allocator, 100, 0.01, 42);
    defer bf.deinit();

    bf.add("duplicate");
    bf.add("duplicate");
    bf.add("duplicate");

    try testing.expect(bf.mightContain("duplicate"));
}

test "BloomFilter - clear resets filter" {
    var bf = try cache.BloomFilter.init(testing.allocator, 100, 0.01, 42);
    defer bf.deinit();

    bf.add("hello");
    try testing.expect(bf.mightContain("hello"));
    try testing.expect(bf.bitCount() > 0);

    bf.clear();
    try testing.expectEqual(@as(usize, 0), bf.bitCount());
    // After clear, previously added items are no longer found
    try testing.expect(!bf.mightContain("hello"));
}

test "BloomFilter - bitSize and hashFunctions" {
    var bf = try cache.BloomFilter.init(testing.allocator, 1000, 0.01, 42);
    defer bf.deinit();

    try testing.expect(bf.bitSize() > 0);
    try testing.expect(bf.hashFunctions() > 0);
}

test "BloomFilter - false positive rate envelope" {
    var bf = try cache.BloomFilter.init(testing.allocator, 1000, 0.01, 0xDEADBEEFCAFEBABE);
    defer bf.deinit();

    // Insert 1000 items
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        bf.add(buf[0..]);
    }

    // All inserted items must be found
    i = 0;
    while (i < 1000) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        try testing.expect(bf.mightContain(buf[0..]));
    }

    // Check false positive rate on disjoint range
    var fp: usize = 0;
    i = 2000;
    while (i < 3000) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        if (bf.mightContain(buf[0..])) fp += 1;
    }

    const fp_rate = @as(f64, @floatFromInt(fp)) / 1000.0;
    // Target 1%, accept <5% to avoid flakes
    try testing.expect(fp_rate < 0.05);
}

// =========================================================================
// CountMinSketch Tests
// =========================================================================

test "CountMinSketch - basic add and estimate" {
    var cms = try cache.CountMinSketch.init(testing.allocator, 5, 1024, 1234);
    defer cms.deinit();

    cms.add("apple", 3);
    cms.add("banana", 5);
    cms.add("apple", 2);

    const est_a = cms.estimate("apple");
    const est_b = cms.estimate("banana");

    // Count-min sketch never under-counts
    try testing.expect(est_a >= 5);
    try testing.expect(est_b >= 5);

    // With 1024 width and 5 depth, over-estimation should be small
    try testing.expect(est_a <= 7);
    try testing.expect(est_b <= 7);
}

test "CountMinSketch - zero for unseen keys" {
    var cms = try cache.CountMinSketch.init(testing.allocator, 4, 256, 42);
    defer cms.deinit();

    try testing.expectEqual(@as(u32, 0), cms.estimate("never_added"));
}

test "CountMinSketch - clear resets counters" {
    var cms = try cache.CountMinSketch.init(testing.allocator, 4, 256, 42);
    defer cms.deinit();

    cms.add("key", 100);
    try testing.expect(cms.estimate("key") >= 100);

    cms.clear();
    try testing.expectEqual(@as(u32, 0), cms.estimate("key"));
}

test "CountMinSketch - saturating add" {
    var cms = try cache.CountMinSketch.init(testing.allocator, 2, 64, 42);
    defer cms.deinit();

    // Add near max value
    cms.add("overflow", std.math.maxInt(u32));
    cms.add("overflow", 1);

    // Should saturate at max, not wrap around
    try testing.expectEqual(std.math.maxInt(u32), cms.estimate("overflow"));
}

test "CountMinSketch - multiple keys" {
    var cms = try cache.CountMinSketch.init(testing.allocator, 5, 1024, 9999);
    defer cms.deinit();

    cms.add("a", 10);
    cms.add("b", 20);
    cms.add("c", 30);
    cms.add("d", 40);
    cms.add("e", 50);

    // All estimates should be >= true count
    try testing.expect(cms.estimate("a") >= 10);
    try testing.expect(cms.estimate("b") >= 20);
    try testing.expect(cms.estimate("c") >= 30);
    try testing.expect(cms.estimate("d") >= 40);
    try testing.expect(cms.estimate("e") >= 50);
}

test "CountMinSketch - invalid parameters" {
    // depth=0 should fail
    const result1 = cache.CountMinSketch.init(testing.allocator, 0, 1024, 42);
    try testing.expect(result1 == error.InvalidDepth);

    // width=0 should fail
    const result2 = cache.CountMinSketch.init(testing.allocator, 4, 0, 42);
    try testing.expect(result2 == error.InvalidWidth);

    // non-power-of-two width should fail
    const result3 = cache.CountMinSketch.init(testing.allocator, 4, 100, 42);
    try testing.expect(result3 == error.WidthNotPowerOfTwo);
}
