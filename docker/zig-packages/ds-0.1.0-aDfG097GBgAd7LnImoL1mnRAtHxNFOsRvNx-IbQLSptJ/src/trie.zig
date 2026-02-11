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

    fn deinit(self: *TrieNode) void {
        var it = self.children.valueIterator();
        while (it.next()) |child| {
            child.*.deinit();
        }
        self.children.deinit();
        self.allocator.destroy(self);
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
    pub fn insert(self: *Self, string: []const u8, value: usize) !void {
        var node = self.root;
        const view = std.unicode.Utf8View.init(string) catch return error.OutOfMemory;
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
    pub fn search(self: *Self, string: []const u8) ?usize {
        var node = self.root;
        const view = std.unicode.Utf8View.init(string) catch return null;
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
    pub fn startsWith(self: *Self, prefix: []const u8) bool {
        var node = self.root;
        const view = std.unicode.Utf8View.init(prefix) catch return false;
        var it = view.iterator();

        while (it.nextCodepoint()) |codepoint| {
            const child = node.children.get(codepoint) orelse return false;
            node = child;
        }
        return true;
    }

    /// Check if the trie contains a string.
    pub fn contains(self: *Self, string: []const u8) bool {
        return self.search(string) != null;
    }

    /// Check if the trie is empty.
    pub fn isEmpty(self: *Self) bool {
        return self.root.children.count() == 0 and !self.root.is_end;
    }

    /// Delete a string from the trie. Returns true if deleted.
    pub fn delete(self: *Self, string: []const u8) bool {
        const view = std.unicode.Utf8View.init(string) catch return false;
        var codepoints: std.ArrayListUnmanaged(u21) = .{};
        defer codepoints.deinit(self.allocator);

        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            codepoints.append(self.allocator, cp) catch return false;
        }

        const deleted = self.deleteRecursive(self.root, codepoints.items, 0);
        return deleted.deleted;
    }

    const DeleteResult = struct {
        should_prune: bool,
        deleted: bool,
    };

    fn deleteRecursive(self: *Self, node: *TrieNode, codepoints: []const u21, index: usize) DeleteResult {
        if (index == codepoints.len) {
            if (!node.is_end) {
                return .{ .should_prune = false, .deleted = false };
            }
            node.is_end = false;
            node.value = null;
            return .{
                .should_prune = node.children.count() == 0,
                .deleted = true,
            };
        }

        const cp = codepoints[index];
        const child = node.children.get(cp) orelse return .{ .should_prune = false, .deleted = false };

        const result = self.deleteRecursive(child, codepoints, index + 1);
        if (result.should_prune) {
            child.deinit();
            _ = node.children.remove(cp);
        }

        const should_prune = node.children.count() == 0 and !node.is_end and node != self.root;
        return .{ .should_prune = should_prune, .deleted = result.deleted };
    }
};

test "Trie - basic operations" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("cat", 1);
    try trie.insert("car", 2);
    try trie.insert("dog", 3);

    try testing.expectEqual(@as(?usize, 1), trie.search("cat"));
    try testing.expectEqual(@as(?usize, 2), trie.search("car"));
    try testing.expectEqual(@as(?usize, 3), trie.search("dog"));
    try testing.expectEqual(@as(?usize, null), trie.search("ca"));
    try testing.expectEqual(@as(?usize, null), trie.search("cats"));
}

test "Trie - startsWith" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("cat", 1);
    try trie.insert("car", 2);

    try testing.expect(trie.startsWith("ca"));
    try testing.expect(trie.startsWith("cat"));
    try testing.expect(trie.startsWith("car"));
    try testing.expect(!trie.startsWith("do"));
}

test "Trie - delete" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("cat", 1);
    try trie.insert("car", 2);
    try trie.insert("dog", 3);

    try testing.expect(trie.delete("cat"));
    try testing.expectEqual(@as(?usize, null), trie.search("cat"));
    try testing.expectEqual(@as(?usize, 2), trie.search("car"));
    try testing.expect(trie.startsWith("ca"));
}

test "Trie - unicode" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try trie.insert("hello", 1);
    try trie.insert("世界", 2);

    try testing.expectEqual(@as(?usize, 1), trie.search("hello"));
    try testing.expectEqual(@as(?usize, 2), trie.search("世界"));
}

test "Trie - contains and isEmpty" {
    const testing = std.testing;
    var trie = try Trie.init(testing.allocator);
    defer trie.deinit();

    try testing.expect(trie.isEmpty());

    try trie.insert("cat", 1);
    try testing.expect(!trie.isEmpty());
    try testing.expect(trie.contains("cat"));
    try testing.expect(!trie.contains("car"));
    try testing.expect(!trie.contains("cats"));
}
