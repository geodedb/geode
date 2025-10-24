const std = @import("std");
const Allocator = std.mem.Allocator;

// Trie (prefix tree) for ASCII byte keys -> generic value V.
// Deterministic iteration order (lexicographic by byte). Supports insert/update,
// exact lookup, prefix collection, and remove (lazy cleanup). Implementation uses
// sorted dynamic child array per node (binary search) for memory compactness.
//
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=Trie; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_Trie; BENCH=BenchmarkCANARY_REQ_GQL_068_Trie; OWNER=graph; UPDATED=2025-09-21

pub fn Trie(comptime V: type) type {
    return struct {
        const Self = @This();

        const Child = struct { ch: u8, node: *Node };
        const Node = struct {
            value_present: bool,
            value: V,
            children: std.ArrayList(Child),
        };

        alloc: Allocator,
        root: *Node,

        pub fn init(alloc: Allocator) !Self {
            const root = try alloc.create(Node);
            root.* = .{ .value_present = false, .value = undefined, .children = std.ArrayList(Child).init(alloc) };
            return Self{ .alloc = alloc, .root = root };
        }

        pub fn deinit(self: *Self) void {
            self.freeNode(self.root);
        }

        fn freeNode(self: *Self, n: *Node) void {
            for (n.children.items) |c| self.freeNode(c.node);
            n.children.deinit();
            self.alloc.destroy(n);
        }

        fn findChild(n: *Node, ch: u8) ?*Node { // binary search
            var lo: usize = 0;
            var hi: usize = n.children.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const mc = n.children.items[mid].ch;
                if (mc == ch) return n.children.items[mid].node;
                if (mc < ch) lo = mid + 1 else hi = mid;
            }
            return null;
        }

        fn ensureChild(self: *Self, n: *Node, ch: u8) !*Node {
            var lo: usize = 0;
            var hi: usize = n.children.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const mc = n.children.items[mid].ch;
                if (mc == ch) return n.children.items[mid].node;
                if (mc < ch) lo = mid + 1 else hi = mid;
            }
            const child = try self.alloc.create(Node);
            child.* = .{ .value_present = false, .value = undefined, .children = std.ArrayList(Child).init(self.alloc) };
            try n.children.insert(lo, .{ .ch = ch, .node = child });
            return child;
        }

        pub fn insert(self: *Self, key: []const u8, value: V) !void {
            var cur = self.root;
            for (key) |ch| cur = try self.ensureChild(cur, ch);
            cur.value = value;
            cur.value_present = true;
        }

        pub fn get(self: *Self, key: []const u8) ?*V {
            var cur = self.root;
            for (key) |ch| {
                const next = findChild(cur, ch) orelse return null;
                cur = next;
            }
            if (!cur.value_present) return null;
            return &cur.value;
        }

        pub fn remove(self: *Self, key: []const u8) bool {
            // Path stack for potential cleanup
            var stack = std.ArrayList(struct { node: *Node, ch: u8, idx: usize }).init(self.alloc);
            defer stack.deinit();
            var cur = self.root;
            for (key) |ch| {
                var lo: usize = 0;
                var hi: usize = cur.children.items.len;
                var found: ?usize = null;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const mc = cur.children.items[mid].ch;
                    if (mc == ch) {
                        found = mid;
                        break;
                    }
                    if (mc < ch) lo = mid + 1 else hi = mid;
                }
                if (found == null) return false;
                try stack.append(.{ .node = cur, .ch = ch, .idx = found.? });
                cur = cur.children.items[found.?].node;
            }
            if (!cur.value_present) return false;
            cur.value_present = false;
            // Cleanup: remove nodes without value & children
            var i: isize = @as(isize, @intCast(stack.items.len)) - 1;
            var child = cur;
            while (i >= 0) : (i -= 1) {
                const ent = stack.items[@as(usize, @intCast(i))];
                if (child.value_present or child.children.items.len > 0) break;
                // free child and remove from parent
                const parent = ent.node;
                const removed = parent.children.orderedRemove(ent.idx);
                _ = removed; // discard
                self.freeNode(child);
                child = parent;
            }
            return true;
        }

        pub fn collectPrefix(self: *Self, alloc: Allocator, prefix: []const u8) ![][]const u8 {
            // Navigate to node
            var cur = self.root;
            for (prefix) |ch| {
                const next = findChild(cur, ch) orelse return alloc.alloc([]const u8, 0);
                cur = next;
            }
            var out = std.ArrayList([]const u8).init(alloc);
            var buf = std.ArrayList(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(prefix);
            try self.collectRec(&out, &buf, cur);
            return out.toOwnedSlice();
        }

        fn collectRec(self: *Self, out: *std.ArrayList([]const u8), buf: *std.ArrayList(u8), node: *Node) !void {
            if (node.value_present) {
                const dup = try self.alloc.dupe(u8, buf.items);
                try out.append(dup);
            }
            for (node.children.items) |child| {
                try buf.append(child.ch);
                try self.collectRec(out, buf, child.node);
                _ = buf.pop();
            }
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator.init(self.alloc, self.root);
        }
        const Iterator = struct {
            stack: std.ArrayList(struct { node: *Node, idx: usize }),
            buf: std.ArrayList(u8),
            init_node: *Node,
            /// P2-3: Now accepts allocator parameter for iterator ArrayLists
            pub fn init(allocator: Allocator, root: *Node) Iterator {
                return Iterator{ .stack = std.ArrayList(struct { node: *Node, idx: usize }).init(allocator), .buf = std.ArrayList(u8).init(allocator), .init_node = root };
            }
            pub fn next(self: *Iterator) ?struct { key: []const u8 } {
                if (self.stack.items.len == 0) {
                    if (self.buf.items.len == 0) {
                        // Seed with root children
                        for (self.init_node.children.items) |c| {
                            self.stack.append(.{ .node = c.node, .idx = 0 }) catch return null;
                            self.buf.append(c.ch) catch return null;
                            break; // process first child path
                        }
                        if (self.stack.items.len == 0) return null;
                    }
                }
                while (self.stack.items.len > 0) {
                    var frame = &self.stack.items[self.stack.items.len - 1];
                    const node = frame.node;
                    if (frame.idx == 0 and node.value_present) {
                        // Return current key
                        return .{ .key = self.buf.items };
                    }
                    if (frame.idx < node.children.items.len) {
                        const child = node.children.items[frame.idx];
                        frame.idx += 1;
                        self.stack.append(.{ .node = child.node, .idx = 0 }) catch return null;
                        self.buf.append(child.ch) catch return null;
                        continue;
                    }
                    // Pop frame
                    _ = self.stack.pop();
                    _ = self.buf.pop();
                }
                return null;
            }
        };
    };
}

test "trie basic insert/get/remove/prefix" {
    const T = Trie(u32);
    const gpa = std.testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    try t.insert("cat", 1);
    try t.insert("car", 2);
    try t.insert("dog", 3);
    try t.insert("cart", 4);
    try std.testing.expect(t.get("car").?.* == 2);
    try std.testing.expect(t.get("cart").?.* == 4);
    try std.testing.expect(t.get("cap") == null);
    try std.testing.expect(t.remove("car"));
    try std.testing.expect(t.get("car") == null);
    const pref = try t.collectPrefix(gpa, "ca");
    defer {
        for (pref) |s| gpa.free(s);
        gpa.free(pref);
    }
    // Expect remaining: cat, cart
    var found_cat = false;
    var found_cart = false;
    for (pref) |s| {
        if (std.mem.eql(u8, s, "cat")) found_cat = true;
        if (std.mem.eql(u8, s, "cart")) found_cart = true;
    }
    try std.testing.expect(found_cat and found_cart);
}
