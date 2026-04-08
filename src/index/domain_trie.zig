const std = @import("std");
const url = @import("../types/url.zig");

pub const DomainTrie = struct {
    root: ?*Node,
    allocator: std.mem.Allocator,

    pub const Node = struct {
        label: []const u8,
        is_terminal: bool,
        data: ?usize,
        children: std.StringHashMap(*Node),

        pub fn init(allocator: std.mem.Allocator, label: []const u8) !*Node {
            const node = try allocator.create(Node);
            node.* = Node{
                .label = try allocator.dupe(u8, label),
                .is_terminal = false,
                .data = null,
                .children = std.StringHashMap(*Node).init(allocator),
            };
            return node;
        }

        pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
            var iter = self.children.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
                allocator.destroy(entry.value_ptr.*);
                allocator.free(entry.key_ptr.*);
            }
            self.children.deinit();
            allocator.free(self.label);
        }
    };

    pub fn init(allocator: std.mem.Allocator) DomainTrie {
        return DomainTrie{ .root = null, .allocator = allocator };
    }

    pub fn insert(self: *DomainTrie, domain: url.Domain, data: usize) !void {
        if (self.root == null) {
            self.root = try Node.init(self.allocator, "");
        }

        var current = self.root.?;

        var i: usize = domain.labels.len;
        while (i > 0) {
            i -= 1;
            const label = domain.labels[i];

            if (current.children.get(label)) |child| {
                current = child;
            } else {
                const new_node = try Node.init(self.allocator, label);
                try current.children.put(try self.allocator.dupe(u8, label), new_node);
                current = new_node;
            }
        }

        current.is_terminal = true;
        current.data = data;
    }

    pub fn queryExact(self: DomainTrie, domain: url.Domain) ?usize {
        if (self.root == null) return null;

        var current = self.root.?;

        var i: usize = domain.labels.len;
        while (i > 0) {
            i -= 1;
            const label = domain.labels[i];

            if (current.children.get(label)) |child| {
                current = child;
            } else {
                return null;
            }
        }

        return if (current.is_terminal) current.data else null;
    }

    pub fn querySuffix(self: DomainTrie, domain: url.Domain, allocator: std.mem.Allocator) ![]usize {
        var results = std.ArrayList(usize).initCapacity(allocator, 0) catch std.ArrayList(usize){};

        if (self.root == null) return results.toOwnedSlice(allocator);

        var current = self.root.?;

        var i: usize = domain.labels.len;
        while (i > 0) {
            i -= 1;
            const label = domain.labels[i];

            if (current.children.get(label)) |child| {
                current = child;
                if (current.is_terminal and current.data != null) {
                    try results.append(allocator, current.data.?);
                }
            } else {
                break;
            }
        }

        return results.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *DomainTrie) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
    }
};

test "domain trie operations" {
    const allocator = std.testing.allocator;
    var trie = DomainTrie.init(allocator);
    defer trie.deinit();

    const domain = try url.Domain.fromString(allocator, "mail.google.com");
    defer domain.deinit(allocator);

    try trie.insert(domain, 123);

    const result = trie.queryExact(domain);
    std.testing.expect(result.? == 123) catch unreachable;
}
