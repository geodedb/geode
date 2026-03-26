// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Node for Trie
const TrieNode = struct {
    children: std.AutoHashMap(u21, *TrieNode),
    is_end: bool = false,
    value: ?usize = null,
    allocator: Allocator,

    fn init(allocator: Allocator) Allocator.Error!*TrieNode {
        const node = try allocator.create(TrieNode);
        node.* = .{
            .children = std.AutoHashMap(u21, *TrieNode).init(allocator),
            .allocator = allocator,
        };
        return node;
    }

    /// Iterative tree destruction using an explicit stack.
    /// Avoids unbounded recursion for tries with long key chains (SEC-029).
    fn deinit(self: *TrieNode) void {
        const alloc = self.allocator; // capture before self is destroyed
        var stack: std.ArrayListUnmanaged(*TrieNode) = .{};
        defer stack.deinit(alloc);
        stack.append(alloc, self) catch {
            // Fallback: if stack alloc fails, use recursive destroy (best effort)
            var it = self.children.valueIterator();
            while (it.next()) |child| child.*.deinit();
            self.children.deinit();
            alloc.destroy(self);
            return;
        };
        while (stack.items.len > 0) {
            const node = stack.items[stack.items.len - 1];
            stack.items.len -= 1;
            var it = node.children.valueIterator();
            while (it.next()) |child| {
                stack.append(node.allocator, child.*) catch {};
            }
            node.children.deinit();
            node.allocator.destroy(node);
        }
    }
};

/// Trie (prefix tree) for string storage and prefix matching.
pub const Trie = struct {
    const Self = @This();

    allocator: Allocator,
    root: *TrieNode,

    pub fn init(allocator: Allocator) Allocator.Error!Self {
        return Self{
            .allocator = allocator,
            .root = try TrieNode.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit();
    }

    /// Insert a string with an associated value.
    /// Returns `error.InvalidUtf8` if the string is not valid UTF-8.
    pub fn insert(self: *Self, string: []const u8, value: usize) !void {
        var node = self.root;
        const view = try std.unicode.Utf8View.init(string);
        var it = view.iterator();

        while (it.nextCodepoint()) |codepoint| {
            const entry = try node.children.getOrPut(codepoint);
            if (!entry.found_existing) {
                entry.value_ptr.* = try TrieNode.init(self.allocator);
            }
            node = entry.value_ptr.*;
        }
        node.is_end = true;
        node.value = value;
    }

    /// Search for a string. Returns the associated value if found.
    /// Returns `error.InvalidUtf8` if the string is not valid UTF-8.
    pub fn search(self: *Self, string: []const u8) error{InvalidUtf8}!?usize {
        var node = self.root;
        const view = try std.unicode.Utf8View.init(string);
        var it = view.iterator();

        while (it.nextCodepoint()) |codepoint| {
            const child = node.children.get(codepoint) orelse return null;
            node = child;
        }

        if (node.is_end) {
            return node.value;
        }
        return null;
    }

    /// Check if any string in the trie starts with the given prefix.
    /// Returns `error.InvalidUtf8` if the prefix is not valid UTF-8.
    pub fn startsWith(self: *Self, prefix: []const u8) error{InvalidUtf8}!bool {
        var node = self.root;
        const view = try std.unicode.Utf8View.init(prefix);
        var it = view.iterator();

        while (it.nextCodepoint()) |codepoint| {
            const child = node.children.get(codepoint) orelse return false;
            node = child;
        }
        return true;
    }

    /// Check if the trie contains a string.
    /// Returns `error.InvalidUtf8` if the string is not valid UTF-8.
    pub fn contains(self: *Self, string: []const u8) error{InvalidUtf8}!bool {
        return (try self.search(string)) != null;
    }

    /// Check if the trie is empty.
    pub fn isEmpty(self: *Self) bool {
        return self.root.children.count() == 0 and !self.root.is_end;
    }

    /// Delete a string from the trie. Returns true if deleted.
    /// Returns `error.InvalidUtf8` if the string is not valid UTF-8.
    /// Uses an iterative approach: walks down the trie collecting the path,
    /// then walks back up pruning empty nodes. This avoids unbounded recursion
    /// for long keys.
    pub fn delete(self: *Self, string: []const u8) (Allocator.Error || error{InvalidUtf8})!bool {
        const view = try std.unicode.Utf8View.init(string);

        // Phase 1: Walk down, collecting the path of (parent_node, codepoint) pairs.
        const PathEntry = struct { parent: *TrieNode, cp: u21 };
        var path: std.ArrayListUnmanaged(PathEntry) = .{};
        defer path.deinit(self.allocator);

        var node = self.root;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const child = node.children.get(cp) orelse return false;
            try path.append(self.allocator, .{ .parent = node, .cp = cp });
            node = child;
        }

        // `node` is now the terminal node for the key.
        if (!node.is_end) return false;

        node.is_end = false;
        node.value = null;

        // Phase 2: Walk back up, pruning nodes that are empty leaves and not end-of-word.
        var i: usize = path.items.len;
        while (i > 0) {
            i -= 1;
            const entry = path.items[i];
            const child = entry.parent.children.get(entry.cp).?;

            // Only prune if the child has no children and is not an end-of-word marker.
            if (child.children.count() == 0 and !child.is_end) {
                child.deinit();
                _ = entry.parent.children.remove(entry.cp);
            } else {
                // Once we can't prune, no ancestors can be pruned either.
                break;
            }
        }

        return true;
    }
};

test "Trie - basic operations" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("cat", 1);
    try trie.insert("car", 2);
    try trie.insert("dog", 3);

    try testing.expectEqual(@as(?usize, 1), try trie.search("cat"));
    try testing.expectEqual(@as(?usize, 2), try trie.search("car"));
    try testing.expectEqual(@as(?usize, 3), try trie.search("dog"));
    try testing.expectEqual(@as(?usize, null), try trie.search("ca"));
    try testing.expectEqual(@as(?usize, null), try trie.search("cats"));
}

test "Trie - startsWith" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("cat", 1);
    try trie.insert("car", 2);

    try testing.expect(try trie.startsWith("ca"));
    try testing.expect(try trie.startsWith("cat"));
    try testing.expect(try trie.startsWith("car"));
    try testing.expect(!try trie.startsWith("do"));
}

test "Trie - delete" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("cat", 1);
    try trie.insert("car", 2);
    try trie.insert("dog", 3);

    try testing.expect(try trie.delete("cat"));
    try testing.expectEqual(@as(?usize, null), try trie.search("cat"));
    try testing.expectEqual(@as(?usize, 2), try trie.search("car"));
    try testing.expect(try trie.startsWith("ca"));
}

test "Trie - unicode" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("hello", 1);
    try trie.insert("世界", 2);

    try testing.expectEqual(@as(?usize, 1), try trie.search("hello"));
    try testing.expectEqual(@as(?usize, 2), try trie.search("世界"));
}

test "Trie - contains and isEmpty" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try testing.expect(trie.isEmpty());

    try trie.insert("cat", 1);
    try testing.expect(!trie.isEmpty());
    try testing.expect(try trie.contains("cat"));
    try testing.expect(!try trie.contains("car"));
    try testing.expect(!try trie.contains("cats"));
}

test "Trie - insert rejects invalid UTF-8 with InvalidUtf8 error" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    // 0xFF is not valid in UTF-8; must return InvalidUtf8, not OutOfMemory
    const invalid_utf8 = &[_]u8{ 0xFF, 0xFE };
    const result = trie.insert(invalid_utf8, 42);
    try testing.expectError(error.InvalidUtf8, result);
}

test "Trie - search/startsWith/delete reject invalid UTF-8" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    const invalid_utf8 = &[_]u8{ 0xFF, 0xFE };
    try testing.expectError(error.InvalidUtf8, trie.search(invalid_utf8));
    try testing.expectError(error.InvalidUtf8, trie.startsWith(invalid_utf8));
    try testing.expectError(error.InvalidUtf8, trie.delete(invalid_utf8));
    try testing.expectError(error.InvalidUtf8, trie.contains(invalid_utf8));
}
