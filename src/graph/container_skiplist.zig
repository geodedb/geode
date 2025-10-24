const std = @import("std");
const Allocator = std.mem.Allocator;

// Probabilistic Skip List (deterministic variant for test reproducibility)
// Supports insert, search, delete, ordered iteration. Generic over K,V with
// user-provided comparator for keys. Uses fixed max level and deterministic
// pseudo-random level generator seeded for reproducibility.
//
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SkipList; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_SkipList; BENCH=BenchmarkCANARY_REQ_GQL_068_SkipList; OWNER=graph; UPDATED=2025-09-21

pub fn SkipList(comptime K: type, comptime V: type, comptime lessThan: fn (a: K, b: K) bool) type {
    return struct {
        const Self = @This();
        const MaxLevel = 16; // adequate for typical test sizes

        alloc: Allocator,
        header: *Node,
        level: usize,
        seed: u64,

        const Node = struct {
            key: K,
            value: V,
            forwards: [MaxLevel]?*Node,
        };

        pub fn init(alloc: Allocator, seed: u64) !Self {
            const header = try alloc.create(Node);
            header.* = .{ .key = undefined, .value = undefined, .forwards = [_]?*Node{null} ** MaxLevel };
            return Self{ .alloc = alloc, .header = header, .level = 1, .seed = seed };
        }

        pub fn deinit(self: *Self) void {
            // Free all nodes by traversing level 0
            var cur = self.header.forwards[0];
            while (cur) |node| {
                const next = node.forwards[0];
                self.alloc.destroy(node);
                cur = next;
            }
            self.alloc.destroy(self.header);
        }

        fn nextRand(self: *Self) u64 {
            // xorshift64*
            var x = self.seed;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            self.seed = x;
            return x * 2685821657736338717;
        }

        fn randomLevel(self: *Self) usize {
            var lvl: usize = 1;
            const threshold: u32 = 0x3fffffff; // 25% probability to ascend
            while (lvl < MaxLevel and (@as(u32, @intCast(self.nextRand() & 0xffffffff)) < threshold)) : (lvl += 1) {}
            return lvl;
        }

        pub fn search(self: *Self, key: K) ?*V {
            var cur = self.header;
            var lvl: isize = @as(isize, @intCast(self.level)) - 1;
            while (lvl >= 0) : (lvl -= 1) {
                while (true) {
                    const next = cur.forwards[@as(usize, @intCast(lvl))];
                    if (next) |n| {
                        if (lessThan(n.key, key)) {
                            cur = n;
                            continue;
                        } else if (!lessThan(key, n.key)) {
                            return &n.value; // equal
                        } else break;
                    } else break;
                }
            }
            return null;
        }

        pub fn insert(self: *Self, key: K, value: V) !void {
            var update: [MaxLevel]*Node = undefined;
            var cur = self.header;
            var lvl_i: isize = @as(isize, @intCast(self.level)) - 1;
            while (lvl_i >= 0) : (lvl_i -= 1) {
                while (true) {
                    const next = cur.forwards[@as(usize, @intCast(lvl_i))];
                    if (next) |n| {
                        if (lessThan(n.key, key)) {
                            cur = n;
                            continue;
                        } else if (!lessThan(key, n.key)) { // equal -> update value
                            n.value = value;
                            return;
                        } else break;
                    } else break;
                }
                update[@as(usize, @intCast(lvl_i))] = cur;
            }
            const lvl = self.randomLevel();
            if (lvl > self.level) {
                var i = self.level;
                while (i < lvl) : (i += 1) update[i] = self.header;
                self.level = lvl;
            }
            var node = try self.alloc.create(Node);
            node.* = .{ .key = key, .value = value, .forwards = [_]?*Node{null} ** MaxLevel };
            var i: usize = 0;
            while (i < lvl) : (i += 1) {
                node.forwards[i] = update[i].forwards[i];
                update[i].forwards[i] = node;
            }
        }

        pub fn remove(self: *Self, key: K) bool {
            var update: [MaxLevel]*Node = undefined;
            var cur = self.header;
            var lvl_i: isize = @as(isize, @intCast(self.level)) - 1;
            while (lvl_i >= 0) : (lvl_i -= 1) {
                while (true) {
                    const next = cur.forwards[@as(usize, @intCast(lvl_i))];
                    if (next) |n| {
                        if (lessThan(n.key, key)) {
                            cur = n;
                            continue;
                        } else if (!lessThan(key, n.key)) { // equal
                            update[@as(usize, @intCast(lvl_i))] = cur;
                            break;
                        } else break;
                    } else break;
                }
                update[@as(usize, @intCast(lvl_i))] = cur;
            }
            const candidate = cur.forwards[0];
            if (candidate) |n| {
                if (!lessThan(key, n.key) and !lessThan(n.key, key)) {
                    var i: usize = 0;
                    while (i < self.level) : (i += 1) {
                        if (update[i].forwards[i] == n) update[i].forwards[i] = n.forwards[i];
                    }
                    self.alloc.destroy(n);
                    while (self.level > 1 and self.header.forwards[self.level - 1] == null) self.level -= 1;
                    return true;
                }
            }
            return false;
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator{ .cur = self.header.forwards[0] };
        }
        pub const Iterator = struct {
            cur: ?*Node,
            pub fn next(self: *Iterator) ?struct { key: K, value: *V } {
                if (self.cur) |n| {
                    self.cur = n.forwards[0];
                    return .{ .key = n.key, .value = &n.value };
                }
                return null;
            }
        };
    };
}

test "skiplist basic ordered insert/search/remove" {
    const List = SkipList(u32, u32, struct {
        fn lt(a: u32, b: u32) bool {
            return a < b;
        }
    }.lt);
    const gpa = std.testing.allocator;
    var sl = try List.init(gpa, 12345);
    defer sl.deinit();
    // Insert
    var i: u32 = 0;
    while (i < 50) : (i += 1) try sl.insert(i, i * 10);
    // Search
    try std.testing.expect(sl.search(10).?.* == 100);
    try std.testing.expect(sl.search(49).?.* == 490);
    try std.testing.expect(sl.search(77) == null);
    // Remove
    try std.testing.expect(sl.remove(10));
    try std.testing.expect(sl.search(10) == null);
    // Iterator order
    var prev: u32 = 0;
    var first = true;
    var it = sl.iterator();
    while (it.next()) |entry| {
        if (!first) try std.testing.expect(prev < entry.key);
        first = false;
        prev = entry.key;
    }
}
