// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Set is a generic hash set.
pub fn Set(comptime T: type) type {
    return struct {
        const Self = @This();

        map: std.AutoHashMap(T, void),

        /// Initialize a new set.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .map = std.AutoHashMap(T, void).init(allocator),
            };
        }

        /// Free all memory used by the set.
        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Add a value to the set.
        pub fn add(self: *Self, value: T) Allocator.Error!void {
            try self.map.put(value, {});
        }

        /// Remove a value from the set.
        pub fn remove(self: *Self, value: T) void {
            _ = self.map.remove(value);
        }

        /// Check if the set contains a value.
        pub fn contains(self: *Self, value: T) bool {
            return self.map.contains(value);
        }

        /// Get the number of items in the set.
        pub fn len(self: *Self) usize {
            return self.map.count();
        }

        /// Check if the set is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.map.count() == 0;
        }

        /// Clear all items from the set.
        pub fn clear(self: *Self) void {
            self.map.clearRetainingCapacity();
        }

        /// Get an iterator over the set values.
        pub fn iterator(self: *Self) std.AutoHashMap(T, void).KeyIterator {
            return self.map.keyIterator();
        }
    };
}

/// MultiSet counts occurrences of each value.
pub fn MultiSet(comptime T: type) type {
    return struct {
        const Self = @This();

        map: std.AutoHashMap(T, usize),

        /// Initialize a new multiset.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .map = std.AutoHashMap(T, usize).init(allocator),
            };
        }

        /// Free all memory used by the multiset.
        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Add a value to the multiset (increment its count).
        pub fn add(self: *Self, value: T) Allocator.Error!void {
            const entry = try self.map.getOrPut(value);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }

        /// Remove a value from the multiset (decrement its count).
        /// Returns true if the value was present and removed/decremented.
        pub fn remove(self: *Self, value: T) bool {
            if (self.map.get(value)) |cnt| {
                if (cnt <= 1) {
                    _ = self.map.remove(value);
                } else {
                    // Put on existing key shouldn't allocate, but handle error gracefully
                    self.map.put(value, cnt - 1) catch |err| {
                        std.debug.panic("Unexpected error in MultiSet remove: {}", .{err});
                    };
                }
                return true;
            }
            return false;
        }

        /// Get the count of a value in the multiset.
        pub fn count(self: *Self, value: T) usize {
            return self.map.get(value) orelse 0;
        }

        /// Get the number of unique items in the multiset.
        pub fn len(self: *Self) usize {
            return self.map.count();
        }

        /// Check if the multiset is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.map.count() == 0;
        }

        /// Clear all items from the multiset.
        pub fn clear(self: *Self) void {
            self.map.clearRetainingCapacity();
        }

        /// Get an iterator over the multiset entries.
        pub fn iterator(self: *Self) std.AutoHashMap(T, usize).Iterator {
            return self.map.iterator();
        }
    };
}

test "Set - basic operations" {
    const testing = std.testing;
    var set = Set(i32).init(testing.allocator);
    defer set.deinit();

    try testing.expect(set.isEmpty());
    try testing.expectEqual(@as(usize, 0), set.len());

    try set.add(1);
    try set.add(2);
    try set.add(3);
    try set.add(2); // Duplicate

    try testing.expectEqual(@as(usize, 3), set.len());
    try testing.expect(set.contains(1));
    try testing.expect(set.contains(2));
    try testing.expect(set.contains(3));
    try testing.expect(!set.contains(4));

    set.remove(2);
    try testing.expect(!set.contains(2));
    try testing.expectEqual(@as(usize, 2), set.len());
}

test "Set - clear" {
    const testing = std.testing;
    var set = Set(i32).init(testing.allocator);
    defer set.deinit();

    try set.add(1);
    try set.add(2);
    try set.add(3);
    try testing.expectEqual(@as(usize, 3), set.len());

    set.clear();
    try testing.expectEqual(@as(usize, 0), set.len());
    try testing.expect(set.isEmpty());
}

test "MultiSet - basic operations" {
    const testing = std.testing;
    var mset = MultiSet(i32).init(testing.allocator);
    defer mset.deinit();

    try testing.expect(mset.isEmpty());
    try testing.expectEqual(@as(usize, 0), mset.len());

    try mset.add(1);
    try mset.add(2);
    try mset.add(2);
    try mset.add(2);

    try testing.expectEqual(@as(usize, 2), mset.len()); // 2 unique values
    try testing.expectEqual(@as(usize, 1), mset.count(1));
    try testing.expectEqual(@as(usize, 3), mset.count(2));
    try testing.expectEqual(@as(usize, 0), mset.count(3));

    _ = mset.remove(2);
    try testing.expectEqual(@as(usize, 2), mset.count(2));

    _ = mset.remove(2);
    _ = mset.remove(2);
    try testing.expectEqual(@as(usize, 0), mset.count(2));
    try testing.expectEqual(@as(usize, 1), mset.len()); // Only 1 unique value now
}

test "MultiSet - clear" {
    const testing = std.testing;
    var mset = MultiSet(i32).init(testing.allocator);
    defer mset.deinit();

    try mset.add(1);
    try mset.add(2);
    try mset.add(2);
    try testing.expectEqual(@as(usize, 2), mset.len());

    mset.clear();
    try testing.expectEqual(@as(usize, 0), mset.len());
    try testing.expect(mset.isEmpty());
}
