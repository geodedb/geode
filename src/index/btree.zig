const std = @import("std");
const Allocator = std.mem.Allocator;

// B-tree index implementation for property lookups
pub fn BTree(comptime Key: type, comptime Value: type, comptime order: usize) type {
    return struct {
        const Self = @This();
        const min_keys = order - 1;
        const max_keys = 2 * order - 1;
        const min_children = order;
        const max_children = 2 * order;

        pub const Node = struct {
            keys: [max_keys]?Key,
            values: [max_keys]?Value,
            children: [max_children]?*Node,
            num_keys: usize,
            is_leaf: bool,
            allocator: Allocator,

            pub fn init(allocator: Allocator, is_leaf: bool) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .keys = [_]?Key{null} ** max_keys,
                    .values = [_]?Value{null} ** max_keys,
                    .children = [_]?*Node{null} ** max_children,
                    .num_keys = 0,
                    .is_leaf = is_leaf,
                    .allocator = allocator,
                };
                return node;
            }

            pub fn deinit(self: *Node) void {
                if (!self.is_leaf) {
                    for (self.children) |child| {
                        if (child) |c| {
                            c.deinit();
                            self.allocator.destroy(c);
                        }
                    }
                }
            }

            pub fn isFull(self: *Node) bool {
                return self.num_keys == max_keys;
            }

            pub fn search(self: *Node, key: Key) ?Value {
                var i: usize = 0;

                // Find the first key greater than or equal to search key
                while (i < self.num_keys and compareKeys(self.keys[i].?, key) < 0) {
                    i += 1;
                }

                // If key found
                if (i < self.num_keys and compareKeys(self.keys[i].?, key) == 0) {
                    return self.values[i];
                }

                // If leaf node, key not found
                if (self.is_leaf) {
                    return null;
                }

                // Recursively search in child
                if (self.children[i]) |child| {
                    return child.search(key);
                }

                return null;
            }

            pub fn insertNonFull(self: *Node, key: Key, value: Value) !void {
                var i = self.num_keys;

                if (self.is_leaf) {
                    // Find location to insert new key
                    while (i > 0 and compareKeys(self.keys[i - 1].?, key) > 0) {
                        self.keys[i] = self.keys[i - 1];
                        self.values[i] = self.values[i - 1];
                        i -= 1;
                    }

                    // Insert new key and value
                    self.keys[i] = key;
                    self.values[i] = value;
                    self.num_keys += 1;
                } else {
                    // Find child to insert into
                    while (i > 0 and compareKeys(self.keys[i - 1].?, key) > 0) {
                        i -= 1;
                    }

                    const child = self.children[i].?;

                    if (child.isFull()) {
                        // Split child
                        try self.splitChild(i);

                        // After split, key might go to right child
                        if (compareKeys(self.keys[i].?, key) < 0) {
                            i += 1;
                        }
                    }

                    try self.children[i].?.insertNonFull(key, value);
                }
            }

            pub fn splitChild(self: *Node, child_index: usize) !void {
                const child = self.children[child_index].?;
                const new_child = try Node.init(self.allocator, child.is_leaf);

                // Copy second half of keys to new child
                var j: usize = 0;
                while (j < min_keys) : (j += 1) {
                    new_child.keys[j] = child.keys[j + order];
                    new_child.values[j] = child.values[j + order];
                    child.keys[j + order] = null;
                    child.values[j + order] = null;
                }

                // Copy children if not leaf
                if (!child.is_leaf) {
                    j = 0;
                    while (j < order) : (j += 1) {
                        new_child.children[j] = child.children[j + order];
                        child.children[j + order] = null;
                    }
                }

                new_child.num_keys = min_keys;
                child.num_keys = min_keys;

                // Move parent's keys and children to make room
                var i = self.num_keys;
                while (i > child_index) : (i -= 1) {
                    self.children[i + 1] = self.children[i];
                }
                self.children[child_index + 1] = new_child;

                i = self.num_keys;
                while (i > child_index) : (i -= 1) {
                    self.keys[i] = self.keys[i - 1];
                    self.values[i] = self.values[i - 1];
                }

                // Move middle key up to parent
                self.keys[child_index] = child.keys[min_keys];
                self.values[child_index] = child.values[min_keys];
                child.keys[min_keys] = null;
                child.values[min_keys] = null;

                self.num_keys += 1;
            }

            pub fn delete(self: *Node, key: Key) !bool {
                var i: usize = 0;

                // Find key position
                while (i < self.num_keys and compareKeys(self.keys[i].?, key) < 0) {
                    i += 1;
                }

                if (i < self.num_keys and compareKeys(self.keys[i].?, key) == 0) {
                    if (self.is_leaf) {
                        // Delete from leaf
                        return self.deleteFromLeaf(i);
                    } else {
                        // Delete from non-leaf
                        return try self.deleteFromNonLeaf(i);
                    }
                } else if (!self.is_leaf) {
                    // Key might be in subtree
                    const is_in_subtree = i < self.num_keys;
                    const child = self.children[i].?;

                    if (child.num_keys == min_keys) {
                        // Child has minimum keys, might need to merge or borrow
                        try self.fill(i);
                    }

                    if (is_in_subtree and i > self.num_keys) {
                        return try self.children[i - 1].?.delete(key);
                    } else {
                        return try self.children[i].?.delete(key);
                    }
                }

                return false;
            }

            fn deleteFromLeaf(self: *Node, index: usize) bool {
                // Shift keys left
                var i = index + 1;
                while (i < self.num_keys) : (i += 1) {
                    self.keys[i - 1] = self.keys[i];
                    self.values[i - 1] = self.values[i];
                }

                self.num_keys -= 1;
                self.keys[self.num_keys] = null;
                self.values[self.num_keys] = null;

                return true;
            }

            fn deleteFromNonLeaf(self: *Node, index: usize) !bool {
                const key = self.keys[index].?;

                if (self.children[index].?.num_keys >= order) {
                    // Get predecessor
                    const pred = try self.getPredecessor(index);
                    self.keys[index] = pred.key;
                    self.values[index] = pred.value;
                    return try self.children[index].?.delete(pred.key);
                } else if (self.children[index + 1].?.num_keys >= order) {
                    // Get successor
                    const succ = try self.getSuccessor(index);
                    self.keys[index] = succ.key;
                    self.values[index] = succ.value;
                    return try self.children[index + 1].?.delete(succ.key);
                } else {
                    // Merge with sibling
                    try self.merge(index);
                    return try self.children[index].?.delete(key);
                }
            }

            fn getPredecessor(self: *Node, index: usize) !struct { key: Key, value: Value } {
                var current = self.children[index].?;
                while (!current.is_leaf) {
                    current = current.children[current.num_keys].?;
                }
                return .{
                    .key = current.keys[current.num_keys - 1].?,
                    .value = current.values[current.num_keys - 1].?,
                };
            }

            fn getSuccessor(self: *Node, index: usize) !struct { key: Key, value: Value } {
                var current = self.children[index + 1].?;
                while (!current.is_leaf) {
                    current = current.children[0].?;
                }
                return .{
                    .key = current.keys[0].?,
                    .value = current.values[0].?,
                };
            }

            fn fill(self: *Node, index: usize) !void {
                // If previous sibling has more than min keys, borrow from it
                if (index != 0 and self.children[index - 1].?.num_keys >= order) {
                    try self.borrowFromPrev(index);
                }
                // If next sibling has more than min keys, borrow from it
                else if (index != self.num_keys and self.children[index + 1].?.num_keys >= order) {
                    try self.borrowFromNext(index);
                }
                // Merge with sibling
                else {
                    if (index != self.num_keys) {
                        try self.merge(index);
                    } else {
                        try self.merge(index - 1);
                    }
                }
            }

            fn borrowFromPrev(self: *Node, child_index: usize) !void {
                const child = self.children[child_index].?;
                const sibling = self.children[child_index - 1].?;

                // Move a key from parent to child
                var i = child.num_keys;
                while (i > 0) : (i -= 1) {
                    child.keys[i] = child.keys[i - 1];
                    child.values[i] = child.values[i - 1];
                }

                child.keys[0] = self.keys[child_index - 1];
                child.values[0] = self.values[child_index - 1];

                if (!child.is_leaf) {
                    i = child.num_keys + 1;
                    while (i > 0) : (i -= 1) {
                        child.children[i] = child.children[i - 1];
                    }
                    child.children[0] = sibling.children[sibling.num_keys];
                }

                // Move a key from sibling to parent
                self.keys[child_index - 1] = sibling.keys[sibling.num_keys - 1];
                self.values[child_index - 1] = sibling.values[sibling.num_keys - 1];

                child.num_keys += 1;
                sibling.num_keys -= 1;
            }

            fn borrowFromNext(self: *Node, child_index: usize) !void {
                const child = self.children[child_index].?;
                const sibling = self.children[child_index + 1].?;

                // Move a key from parent to child
                child.keys[child.num_keys] = self.keys[child_index];
                child.values[child.num_keys] = self.values[child_index];

                if (!child.is_leaf) {
                    child.children[child.num_keys + 1] = sibling.children[0];
                }

                // Move a key from sibling to parent
                self.keys[child_index] = sibling.keys[0];
                self.values[child_index] = sibling.values[0];

                // Shift sibling's keys left
                var i: usize = 1;
                while (i < sibling.num_keys) : (i += 1) {
                    sibling.keys[i - 1] = sibling.keys[i];
                    sibling.values[i - 1] = sibling.values[i];
                }

                if (!sibling.is_leaf) {
                    i = 1;
                    while (i <= sibling.num_keys) : (i += 1) {
                        sibling.children[i - 1] = sibling.children[i];
                    }
                }

                child.num_keys += 1;
                sibling.num_keys -= 1;
            }

            fn merge(self: *Node, index: usize) !void {
                const child = self.children[index].?;
                const sibling = self.children[index + 1].?;

                // Pull key from parent and merge with right sibling
                child.keys[min_keys] = self.keys[index];
                child.values[min_keys] = self.values[index];

                // Copy keys from sibling to child
                var i: usize = 0;
                while (i < sibling.num_keys) : (i += 1) {
                    child.keys[i + order] = sibling.keys[i];
                    child.values[i + order] = sibling.values[i];
                }

                // Copy children pointers if not leaf
                if (!child.is_leaf) {
                    i = 0;
                    while (i <= sibling.num_keys) : (i += 1) {
                        child.children[i + order] = sibling.children[i];
                    }
                }

                // Move parent's keys and children
                i = index + 1;
                while (i < self.num_keys) : (i += 1) {
                    self.keys[i - 1] = self.keys[i];
                    self.values[i - 1] = self.values[i];
                }

                i = index + 2;
                while (i <= self.num_keys) : (i += 1) {
                    self.children[i - 1] = self.children[i];
                }

                child.num_keys += sibling.num_keys + 1;
                self.num_keys -= 1;

                // Free sibling
                sibling.deinit();
                self.allocator.destroy(sibling);
            }
        };

        allocator: Allocator,
        root: ?*Node,
        size: usize,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .root = null,
                .size = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                root.deinit();
                self.allocator.destroy(root);
            }
        }

        pub fn insert(self: *Self, key: Key, value: Value) !void {
            if (self.root == null) {
                self.root = try Node.init(self.allocator, true);
                self.root.?.keys[0] = key;
                self.root.?.values[0] = value;
                self.root.?.num_keys = 1;
            } else {
                const root = self.root.?;

                if (root.isFull()) {
                    // Create new root
                    const new_root = try Node.init(self.allocator, false);
                    new_root.children[0] = root;
                    try new_root.splitChild(0);

                    // Determine which child to insert into
                    var i: usize = 0;
                    if (compareKeys(new_root.keys[0].?, key) < 0) {
                        i = 1;
                    }

                    try new_root.children[i].?.insertNonFull(key, value);
                    self.root = new_root;
                } else {
                    try root.insertNonFull(key, value);
                }
            }

            self.size += 1;
        }

        pub fn search(self: *Self, key: Key) ?Value {
            if (self.root) |root| {
                return root.search(key);
            }
            return null;
        }

        pub fn delete(self: *Self, key: Key) !bool {
            if (self.root) |root| {
                const deleted = try root.delete(key);

                if (deleted) {
                    self.size -= 1;

                    // If root is empty, make its only child the new root
                    if (root.num_keys == 0) {
                        if (!root.is_leaf and root.children[0] != null) {
                            const old_root = self.root;
                            self.root = root.children[0];
                            self.allocator.destroy(old_root.?);
                        } else if (root.is_leaf) {
                            // Tree is now empty
                            self.allocator.destroy(root);
                            self.root = null;
                        }
                    }
                }

                return deleted;
            }
            return false;
        }

        pub fn range(self: *Self, min_key: Key, max_key: Key) ![]struct { key: Key, value: Value } {
            var results = std.ArrayList(struct { key: Key, value: Value }){};
            if (self.root) |root| {
                try self.rangeHelper(root, min_key, max_key, &results);
            }
            return try results.toOwnedSlice();
        }

        fn rangeHelper(
            self: *Self,
            node: *Node,
            min_key: Key,
            max_key: Key,
            results: *std.ArrayList(struct { key: Key, value: Value }),
        ) !void {
            _ = self;
            var i: usize = 0;

            // Find first key >= min_key
            while (i < node.num_keys and compareKeys(node.keys[i].?, min_key) < 0) {
                i += 1;
            }

            while (i < node.num_keys) {
                // If we've passed max_key, stop
                if (compareKeys(node.keys[i].?, max_key) > 0) {
                    break;
                }

                // Recursively search left child if not leaf
                if (!node.is_leaf and node.children[i] != null) {
                    try self.rangeHelper(node.children[i].?, min_key, max_key, results);
                }

                // Add current key if in range
                if (compareKeys(node.keys[i].?, min_key) >= 0 and
                    compareKeys(node.keys[i].?, max_key) <= 0)
                {
                    try results.append(.{
                        .key = node.keys[i].?,
                        .value = node.values[i].?,
                    });
                }

                i += 1;
            }

            // Search rightmost child if not leaf
            if (!node.is_leaf and i < max_children and node.children[i] != null) {
                try self.rangeHelper(node.children[i].?, min_key, max_key, results);
            }
        }

        fn compareKeys(a: Key, b: Key) i8 {
            // This should be customized based on Key type
            if (@TypeOf(a) == i64 or @TypeOf(a) == u64) {
                if (a < b) return -1;
                if (a > b) return 1;
                return 0;
            } else if (@TypeOf(a) == []const u8) {
                return std.mem.order(u8, a, b);
            } else {
                @compileError("Unsupported key type");
            }
        }
    };
}

// Property index using B-tree
pub const PropertyIndex = struct {
    allocator: Allocator,
    name: []const u8,
    btree: BTree([]const u8, u64, 32), // String key -> entity ID
    stats: IndexStats,

    pub const IndexStats = struct {
        total_entries: u64 = 0,
        unique_values: u64 = 0,
        null_values: u64 = 0,
        last_update: i64 = 0,
        selectivity: f32 = 1.0,
    };

    pub fn init(allocator: Allocator, name: []const u8) PropertyIndex {
        return .{
            .allocator = allocator,
            .name = name,
            .btree = BTree([]const u8, u64, 32).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *PropertyIndex) void {
        self.btree.deinit();
    }

    pub fn insert(self: *PropertyIndex, value: []const u8, entity_id: u64) !void {
        try self.btree.insert(value, entity_id);
        self.stats.total_entries += 1;
        self.stats.last_update = std.time.milliTimestamp();
        self.updateSelectivity();
    }

    pub fn search(self: *PropertyIndex, value: []const u8) ?u64 {
        return self.btree.search(value);
    }

    pub fn delete(self: *PropertyIndex, value: []const u8) !bool {
        const deleted = try self.btree.delete(value);
        if (deleted) {
            self.stats.total_entries -= 1;
            self.updateSelectivity();
        }
        return deleted;
    }

    pub fn range(self: *PropertyIndex, min: []const u8, max: []const u8) ![]u64 {
        const results = try self.btree.range(min, max);
        var ids = try self.allocator.alloc(u64, results.len);
        for (results, 0..) |r, i| {
            ids[i] = r.value;
        }
        return ids;
    }

    fn updateSelectivity(self: *PropertyIndex) void {
        if (self.stats.total_entries > 0) {
            self.stats.selectivity = @as(f32, @floatFromInt(self.stats.unique_values)) /
                @as(f32, @floatFromInt(self.stats.total_entries));
        } else {
            self.stats.selectivity = 1.0;
        }
    }
};
